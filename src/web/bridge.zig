// Copyright The Fantastic Planet - By David Clabaugh
//
// bridge.zig — the web UI's messages: the page (server.zig) on one side, the agent on the other
//
// One agent serves every open page, one message at a time (`busy`). JSON both ways.
//
// From the page:
//   {"type":"message","id":"m1","text":"...","image":{"media_type":"image/png","data":"<base64>"}}
//       text starting with "/" is a command: /new, /model [name], /skill [name] [input], /help
//   {"type":"history"}                         {"type":"transcript","conversation_id":"..."}
//   {"type":"skills"}                          {"type":"keys"}
//   {"type":"workspace"}                       {"type":"workspace_read","name":"SOUL.md"}
//   {"type":"workspace_write","name":"SOUL.md","content":"..."}
// To the page:
//   status {backend, model, busy}   token {id, text}   tool_start {id, tool, tool_id}
//   tool_done {id, tool_id, ok}     notice {id, text}  error {id, error}   done {id}
//   history {items}   transcript {conversation_id, text}   skills {items}   keys {items}
//   workspace {dir, files}   workspace_file {name, content}

const std = @import("std");
const fsio = @import("../fsio.zig");
const compat = @import("../compat.zig");
const setup = @import("../setup.zig");
const server = @import("server.zig");
const loop_mod = @import("../agent/loop.zig");
const skill_md = @import("../agent/skill_md.zig");
const workspace = @import("../agent/workspace.zig");

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
};

pub const WebBridge = struct {
    agent: *loop_mod.AgentLoop,
    /// Held while the agent (or its storage) is in use.
    busy: fsio.Mutex = .init,

    pub fn handler(self: *WebBridge) server.Handler {
        return .{ .ctx = self, .open = open, .message = message };
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

        self.busy.lockUncancelable(fsio.io());
        defer self.busy.unlock(fsio.io());
        if (eql(t, "message")) {
            if (std.mem.startsWith(u8, m.text, "/")) self.command(m.id, m.text) else self.run(m.id, m.text, m);
            return;
        }
        if (eql(t, "history")) return self.sendHistory();
        if (eql(t, "transcript")) return self.sendTranscript(m.conversation_id);
    }

    fn sendStatus(self: *WebBridge) void {
        const info = self.agent.getBackendInfo();
        emit(.{ .type = "status", .backend = info.name, .model = info.model, .busy = false });
    }

    /// One turn of the agent, streamed to the page. Holds `busy`.
    fn run(self: *WebBridge, id: []const u8, text: []const u8, m: In) void {
        defer emit(.{ .type = "done", .id = id });
        if (self.agent.storage != null and self.agent.conversation_id == null) self.agent.startConversation();

        active_id = id;
        carry_len = 0;
        self.agent.stream_callback = &onText;
        self.agent.tool_start_callback = &onToolStart;
        self.agent.tool_done_callback = &onToolDone;
        defer {
            flushCarry();
            self.agent.stream_callback = null;
            self.agent.tool_start_callback = null;
            self.agent.tool_done_callback = null;
            active_id = "";
        }

        const result = if (m.image) |img|
            self.agent.processInputImage(if (text.len > 0) text else "What's in this image?", .{ .media_type = img.media_type, .data = img.data })
        else
            self.agent.processInput(text);
        result catch |e| return emit(.{ .type = "error", .id = id, .@"error" = @errorName(e) });
        if (self.agent.turn_failed) emit(.{ .type = "error", .id = id, .@"error" = self.agent.turn_error });
        self.sendStatus();
    }

    /// A slash command. Holds `busy`.
    fn command(self: *WebBridge, id: []const u8, line: []const u8) void {
        const space = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const name = line[0..space];
        const arg = std.mem.trim(u8, line[space..], " \t");

        if (eql(name, "/new") or eql(name, "/clear")) {
            self.agent.archiveAndReset();
            notice(id, "New conversation.");
        } else if (eql(name, "/model")) {
            if (arg.len == 0) {
                notice(id, "Backends: ollama, claude, openai, deepseek, qwen, gemini, kernel, forai. Switch with /model <backend> [model].");
            } else {
                const sp = std.mem.indexOfAny(u8, arg, " \t") orelse arg.len;
                const model = std.mem.trim(u8, arg[sp..], " \t");
                self.agent.switchBackend(arg[0..sp], if (model.len > 0) model else null) catch |e| {
                    emit(.{ .type = "error", .id = id, .@"error" = @errorName(e) });
                };
            }
            self.sendStatus();
        } else if (eql(name, "/skill") and arg.len == 0) {
            sendSkills();
        } else if (eql(name, "/skill")) {
            const sp = std.mem.indexOfAny(u8, arg, " \t") orelse arg.len;
            if (skill_md.find(gpa, arg[0..sp]) catch null) |skill| {
                defer skill.deinit(gpa);
                if (skill_md.usePrompt(gpa, skill, std.mem.trim(u8, arg[sp..], " \t"))) |prompt| {
                    defer gpa.free(prompt);
                    return self.run(id, prompt, .{ .type = "message" }); // run sends done
                } else |_| {}
            } else {
                var buf: [256]u8 = undefined;
                notice(id, std.fmt.bufPrint(&buf, "No skill named {s}. /skill lists them.", .{arg[0..@min(sp, 100)]}) catch "No such skill.");
            }
        } else if (eql(name, "/help")) {
            notice(id, "Here: /new, /model [backend] [model], /skill [name] [what to do], /help. Every other command works in the terminal.");
        } else {
            var buf: [256]u8 = undefined;
            notice(id, std.fmt.bufPrint(&buf, "{s} works in the terminal, not here yet. /help lists what does.", .{name[0..@min(name.len, 100)]}) catch "That works in the terminal, not here yet.");
        }
        emit(.{ .type = "done", .id = id });
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
