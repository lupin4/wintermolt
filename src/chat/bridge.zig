// Copyright The Fantastic Planet - By David Clabaugh
//
// bridge.zig — Chat sidecar IPC bridge
//
// Spawns the wintermolt-chat TypeScript sidecar process and communicates
// via JSON lines over stdin/stdout pipes.
//
// Protocol:
//   <- FROM CHAT (incoming messages):
//      {"type":"message","platform":"discord","from":"user123","channel":"guild:456","text":"hello"}
//      {"type":"status","platform":"whatsapp","status":"connected"}
//
//   -> TO CHAT (outgoing replies):
//      {"type":"reply","platform":"discord","to":"channel:789","text":"The answer is 42"}
//
// Uses same std.process.Child pattern as tools/bash.zig but keeps the
// child alive (long-running) and reads/writes continuously.

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const sse = @import("../api/sse.zig");

/// A parsed incoming chat message from the sidecar.
pub const ChatMessage = struct {
    platform: []const u8,
    from: []const u8,
    from_name: ?[]const u8,
    channel: []const u8,
    text: []const u8,
    // Threading & routing context (for multi-agent routing, threaded replies)
    thread_id: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
    guild: ?[]const u8 = null,
    roles: ?[]const u8 = null, // Comma-separated role list
    attachments: ?[]const u8 = null, // JSON array of attachment URLs
    raw_json: []const u8, // Full JSON line (owned, for lifetime management)
};

/// A status event from the sidecar.
pub const StatusEvent = struct {
    platform: []const u8,
    status: []const u8,
    data: ?[]const u8,
};

/// IPC bridge to the wintermolt-chat sidecar process.
pub const ChatBridge = struct {
    alloc: Allocator,
    child: Child,
    stdout_file: std.fs.File,
    stdin_file: std.fs.File,
    chat_argv: []const []const u8, // heap-allocated, freed in deinit
    line_buf: [8192]u8 = undefined,

    /// Spawn the chat sidecar process.
    /// Looks for wintermolt-chat binary in order:
    ///   1. WINTERMOLT_CHAT_BINARY env var
    ///   2. ./wintermolt-chat (same directory as wintermolt)
    ///   3. ./chat/wintermolt-chat
    ///   4. bun run chat/src/index.ts (dev mode fallback)
    pub fn init(alloc: Allocator) !ChatBridge {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Determine chat binary path
        const chat_binary = getChatBinaryPath();
        // Heap-allocate argv — getChatArgs with comptime &[_] returns a dangling
        // pointer when binary is a runtime value (stack-local array is freed on return)
        const chat_args = try allocChatArgs(alloc, chat_binary);
        errdefer alloc.free(chat_args);

        try stderr.print("[chat] Starting sidecar: {s}\n", .{chat_binary});

        var child = Child.init(chat_args, alloc);
        child.stdout_behavior = .Pipe;
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Inherit; // Chat sidecar logs go to our stderr

        try child.spawn();

        return .{
            .alloc = alloc,
            .child = child,
            .stdout_file = child.stdout.?,
            .stdin_file = child.stdin.?,
            .chat_argv = chat_args,
        };
    }

    /// Read the next incoming message from the chat sidecar.
    /// Blocks until a message arrives. Returns null on EOF (process exited).
    pub fn readMessage(self: *ChatBridge) ?ChatMessage {
        const reader = self.stdout_file.deprecatedReader();
        const line = reader.readUntilDelimiter(&self.line_buf, '\n') catch |e| {
            if (e == error.EndOfStream) return null;
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[chat] Read error: {s}\n", .{@errorName(e)}) catch {};
            return null;
        };

        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return self.readMessage(); // Skip empty lines

        return parseMessage(trimmed);
    }

    /// Send a reply to the chat sidecar.
    pub fn sendReply(self: *ChatBridge, platform: []const u8, to: []const u8, text: []const u8) !void {
        try self.sendReplyThreaded(platform, to, text, null);
    }

    /// Send a threaded reply to the chat sidecar.
    pub fn sendReplyThreaded(self: *ChatBridge, platform: []const u8, to: []const u8, text: []const u8, thread_id: ?[]const u8) !void {
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll("{\"type\":\"reply\",\"platform\":\"");
        try writeJsonEscaped(writer, platform);
        try writer.writeAll("\",\"to\":\"");
        try writeJsonEscaped(writer, to);
        try writer.writeAll("\",\"text\":\"");
        try writeJsonEscaped(writer, text);
        if (thread_id) |tid| {
            try writer.writeAll("\",\"threadId\":\"");
            try writeJsonEscaped(writer, tid);
        }
        try writer.writeAll("\"}\n");
    }

    /// Send a voice message to the chat sidecar (base64-encoded audio).
    pub fn sendVoice(self: *ChatBridge, platform: []const u8, to: []const u8, audio_b64: []const u8) !void {
        const writer = self.stdin_file.deprecatedWriter();
        try writer.writeAll("{\"type\":\"voice\",\"platform\":\"");
        try writeJsonEscaped(writer, platform);
        try writer.writeAll("\",\"to\":\"");
        try writeJsonEscaped(writer, to);
        try writer.writeAll("\",\"audio\":\"");
        try writeJsonEscaped(writer, audio_b64);
        try writer.writeAll("\"}\n");
    }

    /// Shut down the chat sidecar.
    pub fn deinit(self: *ChatBridge) void {
        // Close stdin to signal the child to exit
        self.stdin_file.close();
        // Wait for child to exit
        _ = self.child.wait() catch {};
        // Free heap-allocated argv
        self.alloc.free(self.chat_argv);
    }
};

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Parse a JSON line into a ChatMessage. Returns null if not a "message" type.
fn parseMessage(json: []const u8) ?ChatMessage {
    const msg_type = sse.findJsonString(json, "type") orelse return null;

    if (std.mem.eql(u8, msg_type, "message")) {
        return ChatMessage{
            .platform = sse.findJsonString(json, "platform") orelse "unknown",
            .from = sse.findJsonString(json, "from") orelse "unknown",
            .from_name = sse.findJsonString(json, "fromName"),
            .channel = sse.findJsonString(json, "channel") orelse "dm",
            .text = sse.findJsonString(json, "text") orelse "",
            .thread_id = sse.findJsonString(json, "threadId"),
            .reply_to = sse.findJsonString(json, "replyTo"),
            .guild = sse.findJsonString(json, "guild"),
            .roles = sse.findJsonString(json, "roles"),
            .attachments = sse.findJsonString(json, "attachments"),
            .raw_json = json,
        };
    }

    if (std.mem.eql(u8, msg_type, "status")) {
        // Print status events to stderr for visibility
        const platform = sse.findJsonString(json, "platform") orelse "unknown";
        const status = sse.findJsonString(json, "status") orelse "unknown";
        const data = sse.findJsonString(json, "data");

        const stderr = std.fs.File.stderr().deprecatedWriter();
        if (data) |d| {
            stderr.print("[{s}] {s}: {s}\n", .{ platform, status, d }) catch {};
        } else {
            stderr.print("[{s}] {s}\n", .{ platform, status }) catch {};
        }
        return null; // Status events don't generate agent responses
    }

    return null;
}

/// Write a JSON-escaped string (no surrounding quotes).
/// Accepts any writer type (including deprecatedWriter).
fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Control characters — skip for safety
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Chat binary resolution
// ---------------------------------------------------------------------------

fn getChatBinaryPath() []const u8 {
    // Check env var first
    if (compat.getenv("WINTERMOLT_CHAT_BINARY")) |path| return path;

    // Check for compiled binary
    if (fileExists("./wintermolt-chat")) return "./wintermolt-chat";
    if (fileExists("./zig-out/bin/wintermolt-chat")) return "./zig-out/bin/wintermolt-chat";
    if (fileExists("./chat/wintermolt-chat")) return "./chat/wintermolt-chat";

    // Dev mode: use bun or node
    if (fileExists("./chat/src/index.ts")) {
        if (commandExists("bun")) return "bun";
        return "node";
    }

    return "./wintermolt-chat";
}

/// Heap-allocate argv for Child.init. Caller must free with alloc.free().
/// Using comptime &[_][]const u8{runtime_val} returns a dangling pointer to
/// a stack-local array — this version is safe for all cases.
fn allocChatArgs(alloc: Allocator, binary: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, binary, "bun")) {
        const args = try alloc.alloc([]const u8, 3);
        args[0] = "bun";
        args[1] = "run";
        args[2] = "chat/src/index.ts";
        return args;
    }
    if (std.mem.eql(u8, binary, "node")) {
        const args = try alloc.alloc([]const u8, 4);
        args[0] = "node";
        args[1] = "--loader";
        args[2] = "ts-node/esm";
        args[3] = "chat/src/index.ts";
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

/// Search $PATH for an executable by name.
fn commandExists(name: []const u8) bool {
    const path_env = compat.getenv("PATH") orelse return false;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        var path_buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.cwd().access(full, .{}) catch continue;
        return true;
    }
    return false;
}
