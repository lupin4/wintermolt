// Copyright The Fantastic Planet - By David Clabaugh
//
// bridge.zig — Gateway sidecar IPC bridge
//
// Spawns the wintermolt-gateway TypeScript sidecar process which serves:
//   - /v1/chat/completions  — OpenAI-compatible API endpoint
//   - /v1/models            — List available models
//   - /control              — Admin control UI (HTML dashboard)
//   - /pair                 — Device pairing endpoint
//
// IPC Protocol (JSON lines over stdin/stdout):
//   <- FROM GATEWAY (API requests):
//      {"type":"api_request","id":"req1","model":"claude-sonnet","messages":[...]}
//      {"type":"pair_request","id":"p1","code":"ABC123"}
//      {"type":"command","command":"/stats"}
//
//   -> TO GATEWAY (API responses):
//      {"type":"api_response","id":"req1","choices":[...],"usage":{...}}
//      {"type":"pair_response","id":"p1","status":"accepted"}
//      {"type":"status","agents":2,"uptime":3600}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const sse = @import("../api/sse.zig");
const loop_mod = @import("../agent/loop.zig");

pub const GatewayBridge = struct {
    alloc: Allocator,
    child: Child,
    stdout_file: std.fs.File,
    stdin_file: std.fs.File,
    agent: *loop_mod.AgentLoop,
    gateway_argv: []const []const u8,
    line_buf: [65536]u8 = undefined, // 64KB for large API requests

    pub fn init(alloc: Allocator, agent: *loop_mod.AgentLoop) !GatewayBridge {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const binary = getGatewayPath();
        const argv = try allocGatewayArgs(alloc, binary);

        try stderr.print("[gateway] Starting sidecar: {s}\n", .{binary});

        var child = Child.init(argv, alloc);
        child.stdout_behavior = .Pipe;
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        return .{
            .alloc = alloc,
            .child = child,
            .stdout_file = child.stdout.?,
            .stdin_file = child.stdin.?,
            .agent = agent,
            .gateway_argv = argv,
        };
    }

    pub fn deinit(self: *GatewayBridge) void {
        self.stdin_file.close();
        _ = self.child.wait() catch {};
        self.alloc.free(self.gateway_argv);
    }

    /// Main event loop — reads requests from gateway sidecar, processes them, sends responses.
    pub fn run(self: *GatewayBridge) void {
        const reader = self.stdout_file.deprecatedReader();
        const stderr = std.fs.File.stderr().deprecatedWriter();

        while (true) {
            const line = reader.readUntilDelimiter(&self.line_buf, '\n') catch |e| {
                if (e == error.EndOfStream) return;
                stderr.print("[gateway] Read error: {s}\n", .{@errorName(e)}) catch {};
                return;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const msg_type = sse.findJsonString(trimmed, "type") orelse continue;
            const msg_id = sse.findJsonString(trimmed, "id") orelse "unknown";

            if (std.mem.eql(u8, msg_type, "api_request")) {
                self.handleApiRequest(msg_id, trimmed) catch |e| {
                    stderr.print("[gateway] API error: {s}\n", .{@errorName(e)}) catch {};
                    self.sendErrorResponse(msg_id, @errorName(e)) catch {};
                };
            } else if (std.mem.eql(u8, msg_type, "command")) {
                self.handleCommand(trimmed) catch {};
            } else if (std.mem.eql(u8, msg_type, "status_request")) {
                self.sendStatusResponse(msg_id) catch {};
            }
        }
    }

    fn handleApiRequest(self: *GatewayBridge, request_id: []const u8, json: []const u8) !void {
        // Extract the user message from OpenAI-format messages array
        // For simplicity, take the last user message
        const text = sse.findJsonString(json, "content") orelse
            sse.findJsonString(json, "prompt") orelse "Hello";

        // Process through agent
        self.agent.startConversation();

        var response_buf: ArrayList(u8) = .{};
        defer response_buf.deinit(self.alloc);

        self.agent.processInputCapture(text, &response_buf) catch |e| {
            return self.sendErrorResponse(request_id, @errorName(e));
        };

        const response_text = if (response_buf.items.len > 0) response_buf.items else "(no response)";

        // Send OpenAI-compatible response
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll("{\"type\":\"api_response\",\"id\":\"");
        try writeJsonEscaped(writer, request_id);
        try writer.writeAll("\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"");
        try writeJsonEscaped(writer, response_text);
        try writer.writeAll("\"},\"index\":0,\"finish_reason\":\"stop\"}]}\n");
    }

    fn handleCommand(_: *GatewayBridge, json: []const u8) !void {
        const cmd = sse.findJsonString(json, "command") orelse return;
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("[gateway] Command: {s}\n", .{cmd}) catch {};
    }

    fn sendStatusResponse(self: *GatewayBridge, request_id: []const u8) !void {
        const writer = self.stdin_file.deprecatedWriter();
        const info = self.agent.getBackendInfo();
        try writer.writeAll("{\"type\":\"status\",\"id\":\"");
        try writeJsonEscaped(writer, request_id);
        try writer.writeAll("\",\"backend\":\"");
        try writeJsonEscaped(writer, info.name);
        try writer.writeAll("\",\"model\":\"");
        try writeJsonEscaped(writer, info.model);
        try writer.writeAll("\"}\n");
    }

    fn sendErrorResponse(self: *GatewayBridge, request_id: []const u8, error_msg: []const u8) !void {
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll("{\"type\":\"api_error\",\"id\":\"");
        try writeJsonEscaped(writer, request_id);
        try writer.writeAll("\",\"error\":{\"message\":\"");
        try writeJsonEscaped(writer, error_msg);
        try writer.writeAll("\",\"type\":\"server_error\"}}\n");
    }
};

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {} else try w.writeByte(c);
            },
        }
    }
}

fn getGatewayPath() []const u8 {
    if (std.posix.getenv("WINTERMOLT_GATEWAY_BINARY")) |p| return p;
    if (fileExists("./wintermolt-gateway")) return "./wintermolt-gateway";
    if (fileExists("./gateway/dist/server.js")) return "node";
    if (fileExists("./gateway/src/index.ts")) {
        if (commandExists("bun")) return "bun";
        return "node";
    }
    return "./wintermolt-gateway";
}

fn allocGatewayArgs(alloc: Allocator, binary: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, binary, "bun")) {
        const args = try alloc.alloc([]const u8, 3);
        args[0] = "bun";
        args[1] = "run";
        args[2] = "gateway/src/index.ts";
        return args;
    }
    if (std.mem.eql(u8, binary, "node")) {
        const args = try alloc.alloc([]const u8, 2);
        args[0] = "node";
        args[1] = if (fileExists("./gateway/dist/server.js")) "gateway/dist/server.js" else "gateway/src/index.ts";
        return args;
    }
    const args = try alloc.alloc([]const u8, 1);
    args[0] = binary;
    return args;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn commandExists(name: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        var path_buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.cwd().access(full, .{}) catch continue;
        return true;
    }
    return false;
}
