// Copyright The Fantastic Planet - By David Clabaugh
//
// bridge.zig — the web UI's messages: the page (server.zig) on one side, the agent on the other
//
// One agent serves every open page, one message at a time (`busy`). JSON both ways.
//
// From the page:
//   {"type":"message","id":"m1","text":"...","image":{"media_type":"image/png","data":"<base64>"}}
//       text starting with "/" is one of the terminal's commands (Commands), except /keys and /quit
//   {"type":"history"}                         {"type":"transcript","conversation_id":"..."}
//   {"type":"resume","id":"m2","conversation_id":"..."}
//   {"type":"skills"}                          {"type":"keys"}
//   {"type":"workspace"}                       {"type":"workspace_read","name":"SOUL.md"}
//   {"type":"workspace_write","name":"SOUL.md","content":"..."}
//   {"type":"stop"}                            stop the reply running now
//   {"type":"approve","approval_id":"a1b2c3","decision":"allow-once|allow-always|deny"}
//       stop and approve come on a second socket: the page's own is busy with the reply
// To the page:
//   status {backend, model, busy}   token {id, text}   tool_start {id, tool, tool_id}
//   tool_done {id, tool_id, ok}     notice {id, text}  error {id, error}   done {id}
//   history {items}   transcript {conversation_id, text}   skills {items}   keys {items}
//   resumed {id, items: [{role, text}]}
//   workspace {dir, files}   workspace_file {name, content}
//   approval {id, approval_id, command}: WINTERMOLT_BASH_APPROVAL=ask, the reply waits for an approve
//   control {ok}: a stop or approve was taken (false: no question has that id any more)

const std = @import("std");
const fsio = @import("../fsio.zig");
const compat = @import("../compat.zig");
const setup = @import("../setup.zig");
const server = @import("server.zig");
const loop_mod = @import("../agent/loop.zig");
const skill_md = @import("../agent/skill_md.zig");
const workspace = @import("../agent/workspace.zig");
const control = @import("../agent/control.zig");

/// Thread-safe, unlike the arena main gives the agent: pages are handled on their own threads.
const gpa = std.heap.c_allocator;

/// The largest workspace file the page may read or write.
const workspace_max = 1024 * 1024;

const In = struct {
    type: []const u8,
    id: []const u8 = "",
    text: []const u8 = "",
    image: ?struct { media_type: []const u8, data: []const u8 } = null,
    conversation_id: []const u8 = "",
    name: []const u8 = "",
    content: ?[]const u8 = null,
    approval_id: []const u8 = "",
    decision: []const u8 = "",
};

/// The terminal's slash commands (main.zig's dispatchCommand, as the TUI runs
/// them). Writes what the command prints to `out`; false if `line` is no command.
pub const Commands = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, line: []const u8, out: *std.Io.Writer) anyerror!bool,
};

pub const WebBridge = struct {
    agent: *loop_mod.AgentLoop,
    commands: ?Commands = null,
    /// Held while the agent (or its storage) is in use.
    busy: fsio.Mutex = .init,

    pub fn handler(self: *WebBridge) server.Handler {
        return .{ .ctx = self, .open = open, .message = message };
    }

    /// The question before a command runs, to the page whose reply wants it.
    pub fn asker(self: *WebBridge) control.Asker {
        return .{ .ctx = self, .post = postQuestion };
    }

    /// The reply's thread, so emit() reaches its page.
    fn postQuestion(_: *anyopaque, id: []const u8, shell_command: []const u8) void {
        flushCarry();
        emit(.{ .type = "approval", .id = active_id, .approval_id = id, .command = shell_command });
    }

    fn open(ctx: *anyopaque) void {
        const self: *WebBridge = @ptrCast(@alignCast(ctx));
        // Another page's message may be running; this one learns the model when it next asks.
        if (!self.busy.tryLock()) return emit(.{ .type = "status", .busy = true });
        defer self.busy.unlock(fsio.io());
        self.sendStatus();
    }

    fn message(ctx: *anyopaque, data: []const u8) void {
        const self: *WebBridge = @ptrCast(@alignCast(ctx));
        const parsed = std.json.parseFromSlice(In, gpa, data, .{ .ignore_unknown_fields = true }) catch
            return emit(.{ .type = "error", .id = "", .@"error" = "unreadable message" });
        defer parsed.deinit();
        const m = parsed.value;
        const t = m.type;

        if (eql(t, "skills")) return sendSkills();
        if (eql(t, "keys")) return sendKeys();
        if (eql(t, "workspace")) return sendWorkspace();
        if (eql(t, "workspace_read")) return readWorkspaceFile(m.name);
        if (eql(t, "workspace_write")) return writeWorkspaceFile(m.name, m.content orelse "");
        // Without the lock: the reply holding it is what these act on.
        if (eql(t, "stop")) {
            control.requestStop();
            return emit(.{ .type = "control", .ok = true });
        }
        if (eql(t, "approve")) {
            const line = std.fmt.allocPrint(gpa, "/approve {s} {s}", .{ m.approval_id, m.decision }) catch return;
            defer gpa.free(line);
            const a = control.parseApprove(line) orelse return emit(.{ .type = "control", .ok = false });
            return emit(.{ .type = "control", .ok = control.answer(a.id, a.decision) });
        }

        self.busy.lockUncancelable(fsio.io());
        defer self.busy.unlock(fsio.io());
        if (eql(t, "message")) {
            if (std.mem.startsWith(u8, m.text, "/")) self.command(m.id, m.text) else self.run(m.id, m.text, m);
            return;
        }
        if (eql(t, "history")) return self.sendHistory();
        if (eql(t, "transcript")) return self.sendTranscript(m.conversation_id);
        if (eql(t, "resume")) return self.resumeConversation(m.id, m.conversation_id);
    }

    fn sendStatus(self: *WebBridge) void {
        const info = self.agent.getBackendInfo();
        emit(.{ .type = "status", .backend = info.name, .model = info.model, .busy = false });
    }

    /// Route the agent's output for request `id` to this page. Holds `busy`.
    fn begin(self: *WebBridge, id: []const u8) void {
        if (self.agent.storage != null and self.agent.conversation_id == null) self.agent.startConversation();
        self.agent.turn_failed = false; // a command that runs no turn must not report the last one's failure
        control.beginRun();
        active_id = id;
        carry_len = 0;
        self.agent.stream_callback = &onText;
        self.agent.tool_start_callback = &onToolStart;
        self.agent.tool_done_callback = &onToolDone;
    }

    fn end(self: *WebBridge, id: []const u8) void {
        flushCarry();
        self.agent.stream_callback = null;
        self.agent.tool_start_callback = null;
        self.agent.tool_done_callback = null;
        active_id = "";
        control.endRun();
        if (self.agent.turn_failed) emit(.{ .type = "error", .id = id, .@"error" = self.agent.turn_error });
        self.sendStatus();
        emit(.{ .type = "done", .id = id });
    }

    /// One turn of the agent, streamed to the page. Holds `busy`.
    fn run(self: *WebBridge, id: []const u8, text: []const u8, m: In) void {
        self.begin(id);
        defer self.end(id);
        const result = if (m.image) |img|
            self.agent.processInputImage(if (text.len > 0) text else "What's in this image?", .{ .media_type = img.media_type, .data = img.data })
        else
            self.agent.processInput(text);
        result catch |e| emit(.{ .type = "error", .id = id, .@"error" = @errorName(e) });
    }

    /// A slash command: the terminal's own, its printout shown as a notice. Holds `busy`.
    fn command(self: *WebBridge, id: []const u8, line: []const u8) void {
        self.begin(id);
        defer self.end(id);
        const name = line[0 .. std.mem.indexOfAny(u8, line, " \t") orelse line.len];
        if (eql(name, "/keys")) return notice(id, "Set keys with wintermolt --keys in a terminal. The Keys panel shows which are set; this page never shows a key.");
        if (eql(name, "/quit") or eql(name, "/exit")) return notice(id, "Close the tab to leave. wintermolt keeps running until you stop it in its terminal.");
        const cmds = self.commands orelse return notice(id, "Commands are not available here.");

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const known = cmds.run(cmds.ctx, line, &out.writer) catch |e| {
            emit(.{ .type = "error", .id = id, .@"error" = @errorName(e) });
            return;
        };
        if (!known) {
            var buf: [160]u8 = undefined;
            return notice(id, std.fmt.bufPrint(&buf, "No command {s}. /help lists them.", .{name[0..@min(name.len, 100)]}) catch "No such command. /help lists them.");
        }
        const text = std.mem.trim(u8, out.written(), " \r\n");
        if (text.len > 0) notice(id, text[0..server.wholeChars(text)]);
    }

    /// Continue a saved conversation; the page redraws it from what the model now sees. Holds `busy`.
    fn resumeConversation(self: *WebBridge, id: []const u8, conversation_id: []const u8) void {
        defer emit(.{ .type = "done", .id = id });
        self.agent.resumeConversation(conversation_id) catch |e|
            return emit(.{ .type = "error", .id = id, .@"error" = @errorName(e) });
        const Item = struct { role: []const u8, text: []const u8 };
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        for (self.agent.history.getMessages()) |msg| for (msg.content.items) |block| switch (block) {
            .text => |t| items.append(gpa, .{ .role = @tagName(msg.role), .text = t }) catch return,
            else => {},
        };
        emit(.{ .type = "resumed", .id = id, .items = items.items });
        self.sendStatus();
    }

    /// Holds `busy`: the agent's storage is one SQLite connection.
    fn sendHistory(self: *WebBridge) void {
        const s = if (self.agent.storage) |*s| s else return emit(.{ .type = "history", .items = &[_]bool{} });
        const list = s.listConversations(50) catch return emit(.{ .type = "history", .items = &[_]bool{} });
        defer s.freeConversations(list);
        const Item = struct { id: []const u8, title: []const u8, updated_at: i64, messages: i64 };
        const items = gpa.alloc(Item, list.len) catch return;
        defer gpa.free(items);
        for (list, items) |c, *it| it.* = .{ .id = c.id, .title = c.title, .updated_at = c.updated_at, .messages = c.message_count };
        emit(.{ .type = "history", .items = items });
    }

    fn sendTranscript(self: *WebBridge, conversation_id: []const u8) void {
        const s = if (self.agent.storage) |*s| s else return;
        const text = s.exportConversation(gpa, conversation_id) catch |e|
            return emit(.{ .type = "error", .id = "", .@"error" = @errorName(e) });
        defer gpa.free(text);
        emit(.{ .type = "transcript", .conversation_id = conversation_id, .text = text });
    }
};

fn sendSkills() void {
    const all = skill_md.discover(gpa) catch return emit(.{ .type = "skills", .items = &[_]bool{} });
    defer skill_md.freeAll(gpa, all);
    emit(.{ .type = "skills", .items = all });
}

fn sendKeys() void {
    const Item = struct { name: []const u8, label: []const u8, set: bool };
    var items: [setup.api_keys.len]Item = undefined;
    for (setup.api_keys, &items) |k, *it| {
        const v = compat.getenv(k.key) orelse "";
        it.* = .{ .name = k.key, .label = k.label, .set = v.len > 0 };
    }
    emit(.{ .type = "keys", .items = &items });
}

fn sendWorkspace() void {
    const dir = (workspace.dirPath(gpa) catch null) orelse return emit(.{ .type = "workspace", .dir = "", .files = &[_]bool{} });
    defer gpa.free(dir);
    const Item = struct { name: []const u8, cap: usize, size: ?u64 };
    var items: [workspace.files.len]Item = undefined;
    for (workspace.files, &items) |f, *it| {
        it.* = .{ .name = f.name, .cap = f.cap, .size = null };
        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, f.name }) catch continue;
        defer gpa.free(path);
        const file = fsio.openFile(path, .{}) catch continue;
        defer fsio.close(file);
        it.size = fsio.getEndPos(file) catch null;
    }
    emit(.{ .type = "workspace", .dir = dir, .files = &items });
}

/// Only the workspace's own files, by name: never a path the page chose.
fn workspacePath(name: []const u8) ?[]u8 {
    for (workspace.files) |f| if (eql(f.name, name)) {
        const dir = (workspace.dirPath(gpa) catch null) orelse return null;
        defer gpa.free(dir);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch null;
    };
    return null;
}

fn readWorkspaceFile(name: []const u8) void {
    const path = workspacePath(name) orelse return emit(.{ .type = "error", .id = "", .@"error" = "not a workspace file" });
    defer gpa.free(path);
    const file = fsio.openFile(path, .{}) catch return emit(.{ .type = "workspace_file", .name = name, .content = "" });
    defer fsio.close(file);
    const content = fsio.readToEndAlloc(file, gpa, workspace_max) catch |e|
        return emit(.{ .type = "error", .id = "", .@"error" = @errorName(e) });
    defer gpa.free(content);
    emit(.{ .type = "workspace_file", .name = name, .content = content });
}

fn writeWorkspaceFile(name: []const u8, content: []const u8) void {
    if (content.len > workspace_max) return emit(.{ .type = "error", .id = "", .@"error" = "file too large" });
    const path = workspacePath(name) orelse return emit(.{ .type = "error", .id = "", .@"error" = "not a workspace file" });
    defer gpa.free(path);
    if (std.fs.path.dirname(path)) |d| fsio.makePath(d) catch {};
    const file = fsio.createFile(path, .{}) catch |e| return emit(.{ .type = "error", .id = "", .@"error" = @errorName(e) });
    defer fsio.close(file);
    fsio.writeAll(file, content) catch |e| return emit(.{ .type = "error", .id = "", .@"error" = @errorName(e) });
    sendWorkspace();
}

// ─── Streaming: the agent's callbacks take no context, so the turn's id is per thread ───

threadlocal var active_id: []const u8 = "";
/// The start of a UTF-8 character the last token cut off (server.wholeChars).
threadlocal var carry: [4]u8 = undefined;
threadlocal var carry_len: usize = 0;

fn onText(text: []const u8) void {
    const joined = std.mem.concat(gpa, u8, &.{ carry[0..carry_len], text }) catch return;
    defer gpa.free(joined);
    const n = server.wholeChars(joined);
    carry_len = joined.len - n;
    @memcpy(carry[0..carry_len], joined[n..]);
    if (n > 0) emit(.{ .type = "token", .id = active_id, .text = joined[0..n] });
}

fn flushCarry() void {
    if (carry_len > 0) emit(.{ .type = "token", .id = active_id, .text = carry[0..carry_len] });
    carry_len = 0;
}

fn onToolStart(name: []const u8, tool_id: []const u8) void {
    flushCarry();
    emit(.{ .type = "tool_start", .id = active_id, .tool = name, .tool_id = tool_id });
}

fn onToolDone(tool_id: []const u8, ok: bool) void {
    emit(.{ .type = "tool_done", .id = active_id, .tool_id = tool_id, .ok = ok });
}

fn notice(id: []const u8, text: []const u8) void {
    emit(.{ .type = "notice", .id = id, .text = text });
}

fn emit(value: anytype) void {
    const json = std.json.Stringify.valueAlloc(gpa, value, .{}) catch return;
    defer gpa.free(json);
    server.send(json);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
