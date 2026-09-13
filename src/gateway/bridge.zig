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
const fsio = @import("../fsio.zig");
const stdio = @import("../stdio.zig");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const sse = @import("../api/sse.zig");
const loop_mod = @import("../agent/loop.zig");
const pairing = @import("pairing.zig");

pub const GatewayBridge = struct {
    alloc: Allocator,
    child: Child,
    stdout_file: fsio.File,
    stdin_file: fsio.File,
    agent: *loop_mod.AgentLoop,
    gateway_argv: []const []const u8,
    line_buf: [65536]u8 = undefined, // 64KB for large API requests
    /// Paired companion devices (iOS, watchOS, tvOS, Android). See pairing.zig.
    registry: pairing.Registry,

    pub fn init(alloc: Allocator, agent: *loop_mod.AgentLoop) !GatewayBridge {
        const stderr = stdio.stderr();
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
            .registry = pairing.Registry.init(alloc),
        };
    }

    pub fn deinit(self: *GatewayBridge) void {
        fsio.close(self.stdin_file);
        _ = self.child.wait() catch {};
        self.alloc.free(self.gateway_argv);
        self.registry.deinit();
    }

    /// Main event loop — reads requests from gateway sidecar, processes them, sends responses.
    pub fn run(self: *GatewayBridge) void {
        var reader = stdio.readerFor(self.stdout_file);
        const stderr = stdio.stderr();

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
                // AUTH GATE. Requests arriving here came off the sidecar's
                // network surface, not the local CLI (that path never touches
                // this bridge), so an unauthenticated api_request is a remote
                // caller driving the agent. Enforcement switches on as soon as
                // ONE device is paired: pairing is the operator opting in, and
                // turning it on unconditionally would break every existing
                // deployment using the OpenAI-compatible endpoint on upgrade.
                // Zero paired devices keeps the legacy open behaviour, with the
                // warning printed at startup.
                if (!self.isRequestAuthorized(trimmed)) {
                    stderr.print("[gateway] REJECTED unauthenticated api_request\n", .{}) catch {};
                    self.sendErrorResponse(msg_id, "unauthorized: pair this device first") catch {};
                    continue;
                }
                self.handleApiRequest(msg_id, trimmed) catch |e| {
                    stderr.print("[gateway] API error: {s}\n", .{@errorName(e)}) catch {};
                    self.sendErrorResponse(msg_id, @errorName(e)) catch {};
                };
            } else if (std.mem.eql(u8, msg_type, "pair_request")) {
                self.handlePairRequest(msg_id, trimmed) catch |e| {
                    self.sendPairResponse(msg_id, "error", @errorName(e), null) catch {};
                };
            } else if (std.mem.eql(u8, msg_type, "beacon")) {
                self.handleBeacon(msg_id, trimmed) catch {};
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

        var response_buf: ArrayList(u8) = .empty;
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

    /// True when the caller may drive the agent. See the note at the call site
    /// for why zero paired devices means "legacy open".
    fn isRequestAuthorized(self: *GatewayBridge, json: []const u8) bool {
        if (self.registry.devices.items.len == 0) return true;
        const token_hex = sse.findJsonString(json, "device_token") orelse return false;
        const token = decodeToken(token_hex) orelse return false;
        return self.registry.touch(&token, std.time.timestamp());
    }

    /// `{"type":"pair_request","id":"p1","code":"ACDE4679","name":"Living Room
    ///   TV","platform":"tvos","caps":{"microphone":true,"screen":true}}`
    fn handlePairRequest(self: *GatewayBridge, request_id: []const u8, json: []const u8) !void {
        const code = sse.findJsonString(json, "code") orelse
            return self.sendPairResponse(request_id, "rejected", "missing code", null);
        const name = sse.findJsonString(json, "name") orelse "unnamed device";
        const platform = pairing.Platform.parse(sse.findJsonString(json, "platform") orelse "unknown");

        // Capabilities are declared, then clamped to what the platform can
        // actually offer, so a client cannot claim a camera the device has not
        // got. tvOS keeps microphone: the Siri Remote has one.
        var caps = pairing.Capabilities{
            .camera = jsonFlag(json, "camera"),
            .screen = jsonFlag(json, "screen"),
            .microphone = jsonFlag(json, "microphone"),
            .location = jsonFlag(json, "location"),
            .notifications = jsonFlag(json, "notifications"),
            .file_share = jsonFlag(json, "file_share"),
        };
        switch (platform) {
            .tvos => {
                caps.camera = false; // no camera on Apple TV
                caps.location = false;
            },
            .watchos => {
                caps.camera = false;
                caps.file_share = false;
            },
            else => {},
        }

        const token = self.registry.completePairing(code, name, platform, caps, std.time.timestamp()) catch |e| {
            // Deliberately coarse to the client: a caller must not learn WHICH
            // way it was wrong (expired vs mismatch vs burned), only that it
            // failed. The operator still sees the specific reason on stderr.
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[gateway] pairing refused: {s}\n", .{@errorName(e)}) catch {};
            return self.sendPairResponse(request_id, "rejected", "pairing refused", null);
        };

        var hex: [pairing.TOKEN_BYTES * 2]u8 = undefined;
        const token_hex = try std.fmt.bufPrint(&hex, "{x}", .{token});
        try self.sendPairResponse(request_id, "accepted", "paired", token_hex);
    }

    /// Presence beacon: keeps last_seen fresh so the operator can see which
    /// nodes are alive. Advisory — a missed beacon is a quiet device, not a
    /// deauthorized one.
    fn handleBeacon(self: *GatewayBridge, request_id: []const u8, json: []const u8) !void {
        const token_hex = sse.findJsonString(json, "device_token") orelse return;
        const token = decodeToken(token_hex) orelse return;
        const ok = self.registry.touch(&token, std.time.timestamp());
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll("{\"type\":\"beacon_ack\",\"id\":\"");
        try writeJsonEscaped(writer, request_id);
        try writer.print("\",\"alive\":{s}}}\n", .{if (ok) "true" else "false"});
    }

    fn sendPairResponse(
        self: *GatewayBridge,
        request_id: []const u8,
        status: []const u8,
        detail: []const u8,
        token_hex: ?[]const u8,
    ) !void {
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll("{\"type\":\"pair_response\",\"id\":\"");
        try writeJsonEscaped(writer, request_id);
        try writer.writeAll("\",\"status\":\"");
        try writeJsonEscaped(writer, status);
        try writer.writeAll("\",\"detail\":\"");
        try writeJsonEscaped(writer, detail);
        if (token_hex) |t| {
            // The one and only time this value exists outside the device.
            try writer.writeAll("\",\"device_token\":\"");
            try writeJsonEscaped(writer, t);
        }
        try writer.writeAll("\"}\n");
    }

    fn handleCommand(_: *GatewayBridge, json: []const u8) !void {
        const cmd = sse.findJsonString(json, "command") orelse return;
        const stderr = stdio.stderr();
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

/// Decode a wire token, or nothing.
///
/// std.fmt.hexToBytes does NOT error on input shorter than the output buffer:
/// given "abcd" it decodes ONE byte and returns a 1-byte slice, leaving the
/// other 31 bytes of the destination UNINITIALIZED. Discarding that slice and
/// hashing the whole array meant a short token hashed uninitialized stack --
/// non-deterministic authentication, and a caller-controlled way to reach it.
/// The length check is the fix; a unit test pins the decoder's real behaviour.
fn decodeToken(hex: []const u8) ?[pairing.TOKEN_BYTES]u8 {
    if (hex.len != pairing.TOKEN_BYTES * 2) return null;
    var token: [pairing.TOKEN_BYTES]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&token, hex) catch return null;
    if (decoded.len != pairing.TOKEN_BYTES) return null;
    return token;
}

/// Crude boolean probe for `"key":true` inside the caps object. The bridge
/// parses JSON with substring helpers throughout (sse.findJsonString); this
/// matches that idiom rather than pulling a parser in for six flags.
fn jsonFlag(json: []const u8, key: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":true", .{key}) catch return false;
    if (std.mem.indexOf(u8, json, needle) != null) return true;
    const spaced = std.fmt.bufPrint(&buf, "\"{s}\": true", .{key}) catch return false;
    return std.mem.indexOf(u8, json, spaced) != null;
}

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
    if (compat.getenv("WINTERMOLT_GATEWAY_BINARY")) |p| return p;
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
    fsio.access(path, .{}) catch return false;
    return true;
}

fn commandExists(name: []const u8) bool {
    const path_env = compat.getenv("PATH") orelse return false;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        var path_buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        fsio.access(full, .{}) catch continue;
        return true;
    }
    return false;
}
