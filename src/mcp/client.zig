// Copyright The Fantastic Planet - By David Clabaugh
//
// client.zig — MCP client for consuming external MCP servers
//
// Spawns external MCP servers as child processes, communicates via
// stdio JSON-RPC 2.0 (same pattern as chat/bridge.zig).
//
// Config from ~/.wintermolt/mcp.json:
//   {
//     "servers": {
//       "filesystem": {
//         "command": "npx",
//         "args": ["@modelcontextprotocol/server-filesystem", "/Users/discomini"]
//       }
//     }
//   }
//
// Tool names are prefixed: "filesystem__read_file", "database__query"

const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const mcp = @import("protocol.zig");
const json_rpc = @import("json_rpc.zig");

/// A discovered tool from an external MCP server.
pub const RemoteTool = struct {
    server_name: []const u8,
    tool_name: []const u8, // original name (without prefix)
    prefixed_name: []const u8, // "servername__toolname"
    description: []const u8,
    input_schema_json: []const u8,
};

/// A connected MCP server.
pub const McpServer = struct {
    name: []const u8,
    child: Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    tools: std.ArrayList(RemoteTool),
    alloc: Allocator,
    next_id: i64 = 1,
    line_buf: [65536]u8 = undefined,

    /// Send a JSON-RPC request and read the response.
    pub fn call(self: *McpServer, method: []const u8, params_json: ?[]const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        // Build request
        const request = if (params_json) |p|
            try std.fmt.allocPrint(self.alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
            , .{ id, method, p })
        else
            try std.fmt.allocPrint(self.alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}"}}
            , .{ id, method });
        defer self.alloc.free(request);

        // Write request + newline
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll(request);
        try writer.writeByte('\n');

        // Read response line
        const reader = self.stdout_file.deprecatedReader();
        const line = try reader.readUntilDelimiter(&self.line_buf, '\n');
        return try self.alloc.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }

    /// Send a notification (no response expected).
    pub fn notify(self: *McpServer, method: []const u8) !void {
        const notif = try std.fmt.allocPrint(self.alloc,
            \\{{"jsonrpc":"2.0","method":"{s}"}}
        , .{method});
        defer self.alloc.free(notif);

        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll(notif);
        try writer.writeByte('\n');
    }

    /// Perform the 3-step MCP handshake: initialize → response → initialized notification.
    pub fn handshake(self: *McpServer) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Step 1: Send initialize request
        const init_params =
            \\{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wintermolt","version":"1.0.0"}}
        ;
        const response = try self.call(mcp.Method.initialize, init_params);
        defer self.alloc.free(response);

        try stderr.print("[mcp-client] {s} handshake: {s}\n", .{ self.name, response[0..@min(response.len, 200)] });

        // Step 2: Check for protocol version in response
        // (just log for now — we accept any version)

        // Step 3: Send initialized notification
        try self.notify(mcp.Method.initialized);
    }

    /// Discover tools from the remote server.
    pub fn discoverTools(self: *McpServer) !void {
        const response = try self.call(mcp.Method.tools_list, "{}");
        defer self.alloc.free(response);

        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Parse the tools array from the result
        // Find "result":{"tools":[...]}
        const result_json = json_rpc.findJsonObject(response, "result") orelse {
            try stderr.print("[mcp-client] {s}: no result in tools/list response\n", .{self.name});
            return;
        };
        const tools_array = json_rpc.findJsonArray(result_json, "tools") orelse {
            try stderr.print("[mcp-client] {s}: no tools array in result\n", .{self.name});
            return;
        };

        // Parse each tool object in the array
        // Simple approach: find each {"name": ...} object
        var i: usize = 1; // skip opening [
        while (i < tools_array.len) {
            if (tools_array[i] == '{') {
                // Find matching }
                var depth: i32 = 0;
                const start = i;
                while (i < tools_array.len) : (i += 1) {
                    if (tools_array[i] == '"') {
                        i += 1;
                        while (i < tools_array.len) : (i += 1) {
                            if (tools_array[i] == '\\') { i += 1; continue; }
                            if (tools_array[i] == '"') break;
                        }
                        continue;
                    }
                    if (tools_array[i] == '{') depth += 1;
                    if (tools_array[i] == '}') {
                        depth -= 1;
                        if (depth == 0) { i += 1; break; }
                    }
                }
                const tool_json = tools_array[start..i];

                // Extract tool name and description
                const name = json_rpc.findJsonString(tool_json, "name") orelse continue;
                const desc = json_rpc.findJsonString(tool_json, "description") orelse "";
                const schema = json_rpc.findJsonObject(tool_json, "inputSchema") orelse "{}";

                // Build prefixed name
                const prefixed = std.fmt.allocPrint(self.alloc, "{s}__{s}", .{ self.name, name }) catch continue;

                // Store copies (tool_json is from stack-local response)
                const name_copy = self.alloc.dupe(u8, name) catch continue;
                const desc_copy = self.alloc.dupe(u8, desc) catch continue;
                const schema_copy = self.alloc.dupe(u8, schema) catch continue;

                self.tools.append(self.alloc, .{
                    .server_name = self.name,
                    .tool_name = name_copy,
                    .prefixed_name = prefixed,
                    .description = desc_copy,
                    .input_schema_json = schema_copy,
                }) catch continue;
            } else {
                i += 1;
            }
        }

        try stderr.print("[mcp-client] {s}: discovered {d} tools\n", .{ self.name, self.tools.items.len });
    }

    /// Call a remote tool by its original (unprefixed) name.
    pub fn callTool(self: *McpServer, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        const params = try std.fmt.allocPrint(self.alloc,
            \\{{"name":"{s}","arguments":{s}}}
        , .{ tool_name, arguments_json });
        defer self.alloc.free(params);

        const response = try self.call(mcp.Method.tools_call, params);
        defer self.alloc.free(response);

        // Extract result text from response
        const result_obj = json_rpc.findJsonObject(response, "result") orelse
            return try self.alloc.dupe(u8, "Error: no result in MCP response");

        // Find text content in result.content[0].text
        if (json_rpc.findJsonString(result_obj, "text")) |text| {
            return try self.alloc.dupe(u8, text);
        }

        return try self.alloc.dupe(u8, result_obj);
    }

    /// Gracefully shut down the MCP server.
    pub fn shutdown(self: *McpServer) void {
        // Free tool data
        for (self.tools.items) |t| {
            self.alloc.free(t.tool_name);
            self.alloc.free(t.prefixed_name);
            self.alloc.free(t.description);
            self.alloc.free(t.input_schema_json);
        }
        self.tools.deinit(self.alloc);

        // Close pipes and terminate
        self.stdin_file.close();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }
};

/// MCP client manager — manages multiple connected MCP servers.
pub const McpClientManager = struct {
    servers: std.ArrayList(McpServer),
    alloc: Allocator,

    pub fn init(alloc: Allocator) McpClientManager {
        return .{
            .servers = .{},
            .alloc = alloc,
        };
    }

    /// Load and connect to all servers from ~/.wintermolt/mcp.json
    pub fn loadFromConfig(self: *McpClientManager) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Check env override first
        const config_path = std.posix.getenv("WINTERMOLT_MCP_CONFIG") orelse blk: {
            const home = std.posix.getenv("HOME") orelse return;
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/.wintermolt/mcp.json", .{home}) catch return;
            break :blk path;
        };

        // Read config file
        const file = std.fs.cwd().openFile(config_path, .{}) catch |e| {
            if (e == error.FileNotFound) {
                try stderr.print("[mcp-client] No config at {s}\n", .{config_path});
                return;
            }
            try stderr.print("[mcp-client] Error reading {s}: {s}\n", .{ config_path, @errorName(e) });
            return;
        };
        defer file.close();

        const stat = file.stat() catch return;
        if (stat.size > 64 * 1024) return; // Max 64KB config
        const content = self.alloc.alloc(u8, @intCast(stat.size)) catch return;
        defer self.alloc.free(content);
        const n = file.readAll(content) catch return;
        const json = content[0..n];

        try stderr.print("[mcp-client] Loaded config: {s} ({d} bytes)\n", .{ config_path, n });

        // Parse servers from config JSON
        // Find "servers":{...} object
        const servers_obj = json_rpc.findJsonObject(json, "servers") orelse {
            try stderr.writeAll("[mcp-client] No 'servers' object in config\n");
            return;
        };

        // Iterate server entries — find each "name":{...} pair
        var i: usize = 1; // skip opening {
        while (i < servers_obj.len) {
            if (servers_obj[i] == '"') {
                // Found server name
                const name_start = i + 1;
                const name_end = std.mem.indexOfScalarPos(u8, servers_obj, name_start, '"') orelse break;
                const server_name = servers_obj[name_start..name_end];

                // Find the server config object
                i = name_end + 1;
                while (i < servers_obj.len and servers_obj[i] != '{') : (i += 1) {}
                if (i >= servers_obj.len) break;

                // Parse the config object
                var depth: i32 = 0;
                const obj_start = i;
                while (i < servers_obj.len) : (i += 1) {
                    if (servers_obj[i] == '"') {
                        i += 1;
                        while (i < servers_obj.len) : (i += 1) {
                            if (servers_obj[i] == '\\') { i += 1; continue; }
                            if (servers_obj[i] == '"') break;
                        }
                        continue;
                    }
                    if (servers_obj[i] == '{') depth += 1;
                    if (servers_obj[i] == '}') {
                        depth -= 1;
                        if (depth == 0) { i += 1; break; }
                    }
                }
                const server_config = servers_obj[obj_start..i];

                // Extract command and args
                const command = json_rpc.findJsonString(server_config, "command") orelse continue;

                // Spawn server
                self.spawnServer(server_name, command, server_config) catch |e| {
                    stderr.print("[mcp-client] Failed to spawn {s}: {s}\n", .{ server_name, @errorName(e) }) catch {};
                    continue;
                };
            } else {
                i += 1;
            }
        }
    }

    fn spawnServer(self: *McpClientManager, name: []const u8, command: []const u8, config_json: []const u8) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Build argv: [command, ...args]
        var argv_list: std.ArrayList([]const u8) = .{};
        const cmd_copy = try self.alloc.dupe(u8, command);
        try argv_list.append(self.alloc, cmd_copy);

        // Parse args array
        if (json_rpc.findJsonArray(config_json, "args")) |args_json| {
            var j: usize = 1;
            while (j < args_json.len) {
                if (args_json[j] == '"') {
                    const arg_start = j + 1;
                    j += 1;
                    while (j < args_json.len) : (j += 1) {
                        if (args_json[j] == '\\') { j += 1; continue; }
                        if (args_json[j] == '"') break;
                    }
                    const arg = try self.alloc.dupe(u8, args_json[arg_start..j]);
                    try argv_list.append(self.alloc, arg);
                    j += 1;
                } else {
                    j += 1;
                }
            }
        }

        const argv = try argv_list.toOwnedSlice(self.alloc);

        try stderr.print("[mcp-client] Spawning {s}: {s}\n", .{ name, command });

        var child = Child.init(argv, self.alloc);
        child.stdout_behavior = .Pipe;
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        const name_copy = try self.alloc.dupe(u8, name);

        var server = McpServer{
            .name = name_copy,
            .child = child,
            .stdin_file = child.stdin.?,
            .stdout_file = child.stdout.?,
            .tools = .{},
            .alloc = self.alloc,
        };

        // Handshake + discover tools
        server.handshake() catch |e| {
            try stderr.print("[mcp-client] {s} handshake failed: {s}\n", .{ name, @errorName(e) });
            server.shutdown();
            return;
        };

        server.discoverTools() catch |e| {
            try stderr.print("[mcp-client] {s} tool discovery failed: {s}\n", .{ name, @errorName(e) });
        };

        try self.servers.append(self.alloc, server);
    }

    /// Get total number of remote tools across all servers.
    pub fn toolCount(self: *const McpClientManager) usize {
        var total: usize = 0;
        for (self.servers.items) |s| {
            total += s.tools.items.len;
        }
        return total;
    }

    /// Find and call a remote tool by its prefixed name.
    pub fn callTool(self: *McpClientManager, prefixed_name: []const u8, arguments_json: []const u8) ?[]u8 {
        for (self.servers.items) |*server| {
            for (server.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, prefixed_name)) {
                    return server.callTool(tool.tool_name, arguments_json) catch null;
                }
            }
        }
        return null;
    }

    /// Shut down all connected servers.
    pub fn deinit(self: *McpClientManager) void {
        for (self.servers.items) |*server| {
            server.shutdown();
        }
        self.servers.deinit(self.alloc);
    }

    /// Get all remote tools as a flat list.
    pub fn getAllTools(self: *const McpClientManager) []const RemoteTool {
        // Build a flat list from all servers
        var total: usize = 0;
        for (self.servers.items) |s| total += s.tools.items.len;
        if (total == 0) return &.{};

        // Return first server's tools as a simple slice (for iteration)
        // Callers should iterate servers.items[*].tools.items for full access
        if (self.servers.items.len > 0) {
            return self.servers.items[0].tools.items;
        }
        return &.{};
    }
};
