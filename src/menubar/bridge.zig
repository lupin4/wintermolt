// Copyright The Fantastic Planet - By David Clabaugh
//
// bridge.zig — macOS menu bar sidecar bridge
//
// Spawns the wintermolt-menubar Swift sidecar and communicates via JSON
// lines over stdin/stdout pipes. Same architecture as chat/bridge.zig
// and web/bridge.zig.
//
// Data flow:
//   macOS Menu Bar (Swift) <─ JSON lines over stdio ─> this bridge (Zig)
//
// Protocol:
//   -> TO SWIFT (Zig → Swift):
//      {"type":"status","model":"claude","backend":"claude-sonnet","tokens":1247}
//      {"type":"notify","title":"Tool complete","body":"bash ran in 0.4s"}
//      {"type":"set_icon","state":"idle|working|error"}
//      {"type":"response","text":"..."}
//
//   <- FROM SWIFT (Swift → Zig):
//      {"type":"message","text":"user input from menu bar"}
//      {"type":"command","cmd":"/clear"}
//      {"type":"quit"}
//
// On non-macOS platforms, init() returns an error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const builtin = @import("builtin");
const sse = @import("../api/sse.zig");
const loop_mod = @import("../agent/loop.zig");

/// State shared with streaming callbacks via threadlocal.
threadlocal var menubar_stdin: ?std.fs.File = null;
threadlocal var menubar_alloc: ?Allocator = null;

pub const MenuBarBridge = struct {
    alloc: Allocator,
    child: Child,
    stdout_file: std.fs.File,
    stdin_file: std.fs.File,
    line_buf: []u8,
    agent: *loop_mod.AgentLoop,
    argv: []const []const u8,

    pub fn init(alloc: Allocator, agent: *loop_mod.AgentLoop) !MenuBarBridge {
        // Only supported on macOS
        if (builtin.os.tag != .macos) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("[menubar] Menu bar mode requires macOS.\n");
            return error.UnsupportedPlatform;
        }

        const stderr = std.fs.File.stderr().deprecatedWriter();

        const binary_path = getMenuBarBinary();
        const argv = try allocMenuBarArgs(alloc, binary_path);
        errdefer alloc.free(argv);

        const buf = try alloc.alloc(u8, 64 * 1024); // 64KB line buffer
        errdefer alloc.free(buf);

        try stderr.print("[menubar] Starting sidecar: {s}\n", .{binary_path});

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
            .line_buf = buf,
            .agent = agent,
            .argv = argv,
        };
    }

    pub fn deinit(self: *MenuBarBridge) void {
        _ = self.child.kill() catch {};
        self.alloc.free(self.line_buf);
        self.alloc.free(self.argv);
    }

    /// Main run loop — read from Swift sidecar, dispatch to agent.
    pub fn run(self: *MenuBarBridge) void {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Send initial status
        self.sendStatus() catch {};
        self.sendIcon("idle") catch {};

        const reader = self.stdout_file.deprecatedReader();
        while (true) {
            const line = reader.readUntilDelimiter(self.line_buf, '\n') catch |e| {
                if (e == error.EndOfStream) break;
                stderr.print("[menubar] Read error: {s}\n", .{@errorName(e)}) catch {};
                break;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            self.handleLine(trimmed) catch |e| {
                stderr.print("[menubar] Handle error: {s}\n", .{@errorName(e)}) catch {};
            };
        }

        stderr.writeAll("[menubar] Sidecar exited\n") catch {};
    }

    fn handleLine(self: *MenuBarBridge, line: []const u8) !void {
        const msg_type = extractJsonString(line, "type") orelse return;

        if (std.mem.eql(u8, msg_type, "message")) {
            try self.handleMessage(line);
        } else if (std.mem.eql(u8, msg_type, "command")) {
            try self.handleCommand(line);
        } else if (std.mem.eql(u8, msg_type, "quit")) {
            std.process.exit(0);
        }
    }

    fn handleMessage(self: *MenuBarBridge, line: []const u8) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const text = extractJsonString(line, "text") orelse return;

        try stderr.print("[menubar] Input: {s}\n", .{text});

        // Lazy conversation creation
        if (self.agent.storage != null and self.agent.conversation_id == null) {
            self.agent.startConversation();
        }

        // Set threadlocal state for streaming callback
        menubar_stdin = self.stdin_file;
        menubar_alloc = self.alloc;
        defer {
            menubar_stdin = null;
            menubar_alloc = null;
        }

        // Wire streaming callback
        self.agent.stream_callback = &menubarStreamText;
        defer self.agent.stream_callback = null;

        // Set icon to working
        self.sendIcon("working") catch {};

        // Capture agent output for the response
        var response_buf: ArrayList(u8) = .{};
        defer response_buf.deinit(self.alloc);

        self.agent.processInputCapture(text, &response_buf) catch |e| {
            try stderr.print("[menubar] Agent error: {s}\n", .{@errorName(e)});
            self.sendNotify("Error", @errorName(e)) catch {};
            self.sendIcon("error") catch {};
            return;
        };

        // Send final response
        if (response_buf.items.len > 0) {
            self.sendResponse(response_buf.items) catch {};
        }

        // Set icon back to idle
        self.sendIcon("idle") catch {};
        self.sendStatus() catch {};
    }

    fn handleCommand(self: *MenuBarBridge, line: []const u8) !void {
        const cmd = extractJsonString(line, "cmd") orelse return;

        if (std.mem.eql(u8, cmd, "/clear") or std.mem.eql(u8, cmd, "/new")) {
            self.agent.archiveAndReset();
            self.sendNotify("Conversation", "History cleared") catch {};
        }
    }

    // -----------------------------------------------------------------------
    // JSON output to Swift sidecar
    // -----------------------------------------------------------------------

    fn sendStatus(self: *MenuBarBridge) !void {
        var buf: [2048]u8 = undefined;
        const info = self.agent.getBackendInfo();
        const json = std.fmt.bufPrint(&buf,
            "{{\"type\":\"status\",\"model\":\"{s}\",\"backend\":\"{s}\",\"tokens\":{d}}}\n",
            .{ info.model, info.name, self.agent.history.approx_tokens },
        ) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendIcon(self: *MenuBarBridge, state: []const u8) !void {
        var buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            "{{\"type\":\"set_icon\",\"state\":\"{s}\"}}\n",
            .{state},
        ) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    pub fn sendNotify(self: *MenuBarBridge, title: []const u8, body: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            "{{\"type\":\"notify\",\"title\":\"{s}\",\"body\":\"{s}\"}}\n",
            .{ title, body },
        ) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendResponse(self: *MenuBarBridge, text: []const u8) !void {
        // Truncate for menu bar display
        const max_len: usize = 4000;
        const display = if (text.len > max_len) text[0..max_len] else text;

        var buf: [8192]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            "{{\"type\":\"response\",\"text\":\"{s}\"}}\n",
            .{escapeJsonString(display)},
        ) catch return;
        self.stdin_file.writeAll(json) catch {};
    }
};

// ---------------------------------------------------------------------------
// Streaming callback
// ---------------------------------------------------------------------------

fn menubarStreamText(text: []const u8) void {
    const stdin = menubar_stdin orelse return;
    var buf: [16384]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"token\",\"text\":\"{s}\"}}\n", .{
        escapeJsonString(text),
    }) catch return;
    stdin.writeAll(json) catch {};
}

// ---------------------------------------------------------------------------
// Path detection
// ---------------------------------------------------------------------------

fn getMenuBarBinary() []const u8 {
    // 1. Explicit env var
    if (std.posix.getenv("WINTERMOLT_MENUBAR_BINARY")) |p| return p;

    // 2. Look for binary alongside wintermolt
    // (in distribution, wintermolt-menubar is placed next to wintermolt)
    return "wintermolt-menubar";
}

fn allocMenuBarArgs(alloc: Allocator, binary: []const u8) ![]const []const u8 {
    const args = try alloc.alloc([]const u8, 1);
    args[0] = binary;
    return args;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [270]u8 = undefined;
    if (key.len + 4 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    needle_buf[3 + key.len] = '"';
    const needle = needle_buf[0 .. 4 + key.len];

    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start + needle.len;

    var i = value_start;
    while (i < json.len) {
        if (json[i] == '"' and (i == 0 or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
        i += 1;
    }
    return null;
}

fn escapeJsonString(text: []const u8) []const u8 {
    for (text) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
            return escapeJsonStringSlow(text);
        }
    }
    return text;
}

var escape_buf: [16384]u8 = undefined;
fn escapeJsonStringSlow(text: []const u8) []const u8 {
    var i: usize = 0;
    for (text) |c| {
        if (i + 6 >= escape_buf.len) break;
        switch (c) {
            '"' => { escape_buf[i] = '\\'; escape_buf[i + 1] = '"'; i += 2; },
            '\\' => { escape_buf[i] = '\\'; escape_buf[i + 1] = '\\'; i += 2; },
            '\n' => { escape_buf[i] = '\\'; escape_buf[i + 1] = 'n'; i += 2; },
            '\r' => { escape_buf[i] = '\\'; escape_buf[i + 1] = 'r'; i += 2; },
            '\t' => { escape_buf[i] = '\\'; escape_buf[i + 1] = 't'; i += 2; },
            else => { escape_buf[i] = c; i += 1; },
        }
    }
    return escape_buf[0..i];
}
