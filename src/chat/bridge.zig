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
const fsio = @import("../fsio.zig");
const stdio = @import("../stdio.zig");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const access = @import("access.zig");

/// A parsed incoming chat message from the sidecar. Its slices live in the
/// bridge's arena and are valid until the next readMessage.
pub const ChatMessage = struct {
    platform: []const u8,
    from: []const u8,
    from_name: ?[]const u8,
    /// Where a reply goes: the group, room or DM conversation the message
    /// arrived in. Not `from` -- that is the person.
    channel: []const u8,
    text: []const u8,
    // Threading & routing context (for multi-agent routing, threaded replies)
    thread_id: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
    guild: ?[]const u8 = null,
    roles: ?[]const u8 = null, // Comma-separated role list
    attachments: ?[]const u8 = null, // JSON array of attachment URLs
    /// null when the adapter did not say (access.zig drops such a message).
    chat_type: ?access.ChatType = null,
    /// The adapter saw the bot mentioned, or the message replies to the bot.
    mentioned: bool = false,
};

/// Longest line accepted from the sidecar. Attachments travel as URLs, so a
/// real message is far below this; a longer line is a broken sidecar.
const MAX_LINE = 4 * 1024 * 1024;

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
    stdout_file: fsio.File,
    stdin_file: fsio.File,
    chat_argv: []const []const u8, // heap-allocated, freed in deinit
    /// One reader for the bridge's life. FileReader buffers 64 KiB, so a
    /// reader made per call drops every byte read past the first newline --
    /// the second of two lines that arrive in one read() was lost that way.
    reader: *stdio.FileReader,
    /// Backs the current ChatMessage; reset at each readMessage.
    arena: std.heap.ArenaAllocator,

    /// Spawn the chat sidecar process.
    /// Looks for wintermolt-chat binary in order:
    ///   1. WINTERMOLT_CHAT_BINARY env var
    ///   2. ./wintermolt-chat (same directory as wintermolt)
    ///   3. ./chat/wintermolt-chat
    ///   4. bun run chat/src/index.ts (dev mode fallback)
    pub fn init(alloc: Allocator) !ChatBridge {
        const stderr = stdio.stderr();

        // Determine chat binary path
        const chat_binary = getChatBinaryPath();
        // Heap-allocate argv — getChatArgs with comptime &[_] returns a dangling
        // pointer when binary is a runtime value (stack-local array is freed on return)
        const chat_args = try allocChatArgs(alloc, chat_binary);
        errdefer alloc.free(chat_args);

        try stderr.print("[chat] Starting sidecar: {s}\n", .{chat_binary});

        const reader = try alloc.create(stdio.FileReader);
        errdefer alloc.destroy(reader);

        // Long-lived sidecar with both pipes open, stderr inherited so its logs
        // land on ours -- spawnPiped is exactly this shape.
        const child = try fsio.spawnPiped(alloc, chat_args);
        reader.* = stdio.readerFor(child.stdout.?);

        return .{
            .alloc = alloc,
            .child = child,
            .stdout_file = child.stdout.?,
            .stdin_file = child.stdin.?,
            .chat_argv = chat_args,
            .reader = reader,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    /// Read the next incoming message from the chat sidecar, skipping status
    /// events and lines that are not messages. Blocks until one arrives.
    /// Returns null only when the sidecar is gone (or broke the protocol).
    pub fn readMessage(self: *ChatBridge) ?ChatMessage {
        const stderr = stdio.stderr();
        while (true) {
            _ = self.arena.reset(.retain_capacity);
            const arena = self.arena.allocator();
            const line = self.reader.readUntilDelimiterAlloc(arena, '\n', MAX_LINE) catch |e| {
                if (e != error.EndOfStream) stderr.print("[chat] Read error: {s}\n", .{@errorName(e)}) catch {};
                return null;
            };
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (parseLine(arena, trimmed)) |msg| return msg;
        }
    }

    /// Send a reply to the chat sidecar.
    pub fn sendReply(self: *ChatBridge, platform: []const u8, to: []const u8, text: []const u8) !void {
        try self.sendReplyThreaded(platform, to, text, null);
    }

    /// Send a threaded reply to the chat sidecar.
    pub fn sendReplyThreaded(self: *ChatBridge, platform: []const u8, to: []const u8, text: []const u8, thread_id: ?[]const u8) !void {
        const writer = stdio.writerFor(self.stdin_file);
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
        const writer = stdio.writerFor(self.stdin_file);
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
        fsio.close(self.stdin_file);
        // Wait for child to exit
        _ = fsio.waitChild(&self.child) catch {};
        // Free heap-allocated argv
        self.alloc.free(self.chat_argv);
        self.alloc.destroy(self.reader);
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Parse a JSON line into a ChatMessage. Returns null if not a "message" type.
/// The sidecar's JSON line, field for field (chat/src/types.ts). Parsed with
/// std.json rather than by searching for keys: the key search returned
/// unescaped strings in one shared buffer, so a later field with an escape in
/// it (attachments always has some) overwrote an earlier one, `text` included.
const Wire = struct {
    type: []const u8,
    platform: []const u8 = "unknown",
    // A message without a sender or a conversation is not a message: these
    // have no default, so such a line fails to parse and is skipped.
    from: ?[]const u8 = null,
    fromName: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    text: []const u8 = "",
    threadId: ?[]const u8 = null,
    replyTo: ?[]const u8 = null,
    guild: ?[]const u8 = null,
    roles: ?[]const u8 = null,
    attachments: ?[]const u8 = null,
    chatType: ?[]const u8 = null,
    mentioned: bool = false,
    // status events
    status: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

/// A message, or null for a status event (logged here) or a line that is not
/// a well-formed message (logged, so a broken adapter is visible).
fn parseLine(arena: Allocator, json: []const u8) ?ChatMessage {
    const stderr = stdio.stderr();
    const w = std.json.parseFromSliceLeaky(Wire, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| {
        stderr.print("[chat] Unreadable line from the sidecar ({s})\n", .{@errorName(e)}) catch {};
        return null;
    };

    if (std.mem.eql(u8, w.type, "status")) {
        const status = w.status orelse "unknown";
        if (w.data) |d| {
            stderr.print("[{s}] {s}: {s}\n", .{ w.platform, status, d }) catch {};
        } else {
            stderr.print("[{s}] {s}\n", .{ w.platform, status }) catch {};
        }
        return null;
    }
    if (!std.mem.eql(u8, w.type, "message")) return null;

    const from = w.from orelse {
        stderr.print("[chat] {s} message without a sender, skipped\n", .{w.platform}) catch {};
        return null;
    };
    const channel = w.channel orelse {
        stderr.print("[chat] {s} message without a channel, skipped\n", .{w.platform}) catch {};
        return null;
    };
    return ChatMessage{
        .platform = w.platform,
        .from = from,
        .from_name = w.fromName,
        .channel = channel,
        .text = w.text,
        .thread_id = w.threadId,
        .reply_to = w.replyTo,
        .guild = w.guild,
        .roles = w.roles,
        .attachments = w.attachments,
        .chat_type = if (w.chatType) |t| std.meta.stringToEnum(access.ChatType, t) else null,
        .mentioned = w.mentioned,
    };
}

test "parseLine: status events and other types are not messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(parseLine(a, "{\"type\":\"status\",\"platform\":\"telegram\",\"status\":\"connected\"}") == null);
    try std.testing.expect(parseLine(a, "{\"type\":\"typing\",\"platform\":\"telegram\"}") == null);
    try std.testing.expect(parseLine(a, "not json") == null);
}

test "parseLine: every field survives, escapes included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseLine(arena.allocator(),
        \\{"type":"message","platform":"discord","from":"U1","fromName":"a\"b","channel":"C1","text":"line1\nline2","guild":"G1","attachments":"[\"https://x/y.png\"]","chatType":"group","mentioned":true}
    ).?;
    try std.testing.expectEqualStrings("U1", m.from);
    try std.testing.expectEqualStrings("a\"b", m.from_name.?);
    try std.testing.expectEqualStrings("C1", m.channel);
    try std.testing.expectEqualStrings("line1\nline2", m.text);
    try std.testing.expectEqualStrings("[\"https://x/y.png\"]", m.attachments.?);
    try std.testing.expectEqual(access.ChatType.group, m.chat_type.?);
    try std.testing.expect(m.mentioned);
}

test "parseLine: an unknown or missing chat type stays null, a missing sender is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = parseLine(a, "{\"type\":\"message\",\"platform\":\"x\",\"from\":\"1\",\"channel\":\"1\",\"chatType\":\"channel\"}").?;
    try std.testing.expect(m.chat_type == null);
    try std.testing.expect(!m.mentioned);
    try std.testing.expect(parseLine(a, "{\"type\":\"message\",\"platform\":\"x\",\"channel\":\"1\"}") == null);
    // Duplicate keys are an error, not a choice between two senders.
    try std.testing.expect(parseLine(a, "{\"type\":\"message\",\"platform\":\"x\",\"from\":\"1\",\"from\":\"2\",\"channel\":\"1\"}") == null);
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
    fsio.access(path, .{}) catch return false;
    return true;
}

/// Search $PATH for an executable by name.
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
