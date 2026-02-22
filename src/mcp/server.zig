// Copyright The Fantastic Planet - By David Clabaugh
//
// server.zig — MCP (Model Context Protocol) server
//
// Exposes Wintermolt's 30+ tools via JSON-RPC 2.0 over stdio.
// Launch with: wintermolt --mcp-server
//
// Protocol: Read JSON lines from stdin, write JSON lines to stdout.
// Same pattern as Wintermolt's chat bridge but in reverse direction.
//
// Supported methods:
//   initialize          → server info + capabilities
//   notifications/initialized → handshake complete
//   tools/list          → all tool definitions
//   tools/call          → execute a tool
//   resources/list      → empty list
//   ping                → empty result
//
// Zero tool duplication — reuses existing tools.zig dispatch + definitions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mcp = @import("protocol.zig");
const json_rpc = @import("json_rpc.zig");
const tools = @import("../agent/tools.zig");
const api_protocol = @import("../api/protocol.zig");

const SERVER_NAME = "wintermolt";
const SERVER_VERSION = "1.0.0";

/// Run the MCP server loop on stdin/stdout.
/// This function does not return until stdin is closed (client disconnects).
pub fn run(alloc: Allocator) !void {
    const stdin = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    try stderr.print("[mcp] Wintermolt MCP server starting (protocol {s})\n", .{mcp.PROTOCOL_VERSION});

    var line_buf: [65536]u8 = undefined;
    const reader = stdin.deprecatedReader();

    while (true) {
        // Read one JSON line from stdin
        const line = reader.readUntilDelimiter(&line_buf, '\n') catch |e| {
            if (e == error.EndOfStream) {
                try stderr.writeAll("[mcp] Client disconnected (EOF)\n");
                return;
            }
            try stderr.print("[mcp] Read error: {s}\n", .{@errorName(e)});
            continue;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Check if notification (no id → no response needed)
        if (json_rpc.isNotification(trimmed)) {
            const method = json_rpc.findJsonString(trimmed, "method") orelse continue;
            try stderr.print("[mcp] Notification: {s}\n", .{method});
            // notifications/initialized — handshake complete, nothing to do
            continue;
        }

        // Parse as request
        const req = json_rpc.parseRequest(trimmed) orelse {
            // Invalid JSON-RPC — send parse error
            const err_resp = try json_rpc.formatError(alloc, .{ .null_id = {} }, mcp.ErrorCode.parse_error, "Parse error");
            defer alloc.free(err_resp);
            try writeLine(stdout_file, err_resp);
            continue;
        };

        try stderr.print("[mcp] Request: {s} (id={s})\n", .{ req.method, req.id.format() });

        // Dispatch by method
        const response = try dispatchMethod(alloc, req);
        defer alloc.free(response);

        try writeLine(stdout_file, response);
    }
}

/// Dispatch a JSON-RPC request to the appropriate handler.
fn dispatchMethod(alloc: Allocator, req: mcp.JsonRpcRequest) ![]u8 {
    if (std.mem.eql(u8, req.method, mcp.Method.initialize)) {
        return handleInitialize(alloc, req.id);
    } else if (std.mem.eql(u8, req.method, mcp.Method.tools_list)) {
        return handleToolsList(alloc, req.id);
    } else if (std.mem.eql(u8, req.method, mcp.Method.tools_call)) {
        return handleToolsCall(alloc, req.id, req.params_json);
    } else if (std.mem.eql(u8, req.method, mcp.Method.resources_list)) {
        return handleResourcesList(alloc, req.id);
    } else if (std.mem.eql(u8, req.method, mcp.Method.ping)) {
        return json_rpc.formatResponse(alloc, req.id, "{}");
    } else if (std.mem.eql(u8, req.method, mcp.Method.prompts_list)) {
        return json_rpc.formatResponse(alloc, req.id,
            \\{"prompts":[]}
        );
    } else {
        return json_rpc.formatError(alloc, req.id, mcp.ErrorCode.method_not_found,
            "Method not found");
    }
}

// ============================================================================
// Method handlers
// ============================================================================

fn handleInitialize(alloc: Allocator, id: mcp.JsonRpcId) ![]u8 {
    // Build initialize response with server info and capabilities
    const result =
        \\{"protocolVersion":"
    ++ mcp.PROTOCOL_VERSION ++
        \\","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"
    ++ SERVER_NAME ++
        \\","version":"
    ++ SERVER_VERSION ++
        \\"}}
    ;
    return json_rpc.formatResponse(alloc, id, result);
}

fn handleToolsList(alloc: Allocator, id: mcp.JsonRpcId) ![]u8 {
    // Get all tool definitions from Wintermolt's registry
    const defs = tools.getDefinitions();

    // Build JSON array of MCP tool definitions
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);
    try w.writeAll("{\"tools\":[");

    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try w.writeAll(def.name);
        try w.writeAll("\",\"description\":\"");
        // Escape description for JSON
        const escaped = try json_rpc.jsonEscapeString(alloc, def.description);
        defer alloc.free(escaped);
        try w.writeAll(escaped);
        try w.writeAll("\",\"inputSchema\":");
        try w.writeAll(def.input_schema_json);
        try w.writeByte('}');
    }

    try w.writeAll("]}");
    const result_json = try buf.toOwnedSlice(alloc);
    defer alloc.free(result_json);

    return json_rpc.formatResponse(alloc, id, result_json);
}

fn handleToolsCall(alloc: Allocator, id: mcp.JsonRpcId, params_json: ?[]const u8) ![]u8 {
    const params = params_json orelse
        return json_rpc.formatError(alloc, id, mcp.ErrorCode.invalid_params, "Missing params");

    // Extract tool name and arguments
    const tool_name = json_rpc.findJsonString(params, "name") orelse
        return json_rpc.formatError(alloc, id, mcp.ErrorCode.invalid_params, "Missing tool name");

    // Get the arguments object
    const arguments_json = json_rpc.findJsonObject(params, "arguments") orelse "{}";

    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print("[mcp] Calling tool: {s}\n", .{tool_name});

    // Execute the tool via Wintermolt's existing dispatch
    const result_text = tools.executeTool(alloc, tool_name, arguments_json) catch |e| {
        const err_msg = try std.fmt.allocPrint(alloc, "Tool execution error: {s}", .{@errorName(e)});
        defer alloc.free(err_msg);
        return formatToolResult(alloc, id, err_msg, true);
    };
    defer alloc.free(result_text);

    return formatToolResult(alloc, id, result_text, false);
}

fn handleResourcesList(alloc: Allocator, id: mcp.JsonRpcId) ![]u8 {
    return json_rpc.formatResponse(alloc, id,
        \\{"resources":[]}
    );
}

// ============================================================================
// Helpers
// ============================================================================

/// Format a tool call result in MCP format.
fn formatToolResult(alloc: Allocator, id: mcp.JsonRpcId, text: []const u8, is_error: bool) ![]u8 {
    // Escape the text for JSON embedding
    const escaped = try json_rpc.jsonEscapeString(alloc, text);
    defer alloc.free(escaped);

    // Build the result object
    const result = if (is_error)
        try std.fmt.allocPrint(alloc,
            \\{{"content":[{{"type":"text","text":"{s}"}}],"isError":true}}
        , .{escaped})
    else
        try std.fmt.allocPrint(alloc,
            \\{{"content":[{{"type":"text","text":"{s}"}}]}}
        , .{escaped});
    defer alloc.free(result);

    return json_rpc.formatResponse(alloc, id, result);
}

/// Write a JSON line to stdout (with newline delimiter).
fn writeLine(file: std.fs.File, data: []const u8) !void {
    const writer = file.deprecatedWriter();
    try writer.writeAll(data);
    try writer.writeByte('\n');
}
