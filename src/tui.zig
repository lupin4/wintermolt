// Copyright The Fantastic Planet - By David Clabaugh
//
// tui.zig — wintermolt's full-screen chat, drawn with zortui (vendor/zortui).
//
// main.zig opens this in place of the plain REPL when BOTH stdin and stdout are
// a real terminal and neither `--plain` nor WINTERMOLT_PLAIN=1 is set. Piped
// stdin, `-e` and every other mode never reach it.
//
// THREADING
// ---------
// A request runs on a WORKER THREAD; the UI thread only polls input, pumps the
// inbox and draws. Pumping output incrementally from one thread is not an
// option: a backend blocks inside libcurl for the whole streamed reply, and a
// tool can block for minutes, so the terminal would stop redrawing and stop
// reading keys for exactly as long as the user is waiting. One job runs at a
// time. Slash commands run on the worker too, so the AgentLoop, its arena
// allocator, sqlite and the tools-module globals are only ever touched from one
// thread at a time -- the same single-threaded use the REPL makes of them.
//
// OUTPUT
// ------
// Agent code writes through stdio.stdout()/stderr() -- tokens, tool notices,
// fallback warnings, slash-command output. While the TUI is up, stdio's sink
// routes those writes into `Inbox` instead of the console, where a raw write
// would corrupt the alternate screen. The UI thread drains the inbox every
// frame, strips ANSI escapes and splits it into transcript lines.
//
// This file does not import the agent. `Runner` is the seam: main.zig supplies
// one that drives AgentLoop, and the tests below supply a fake one, so the
// whole screen is tested headless through zortui's testing module.

const std = @import("std");
const zortui = @import("zortui");
// Deliberately not fsio.zig: this file stays free of the agent's platform layer
// (and of fsio's POSIX-only tests) so the headless tests build everywhere.
const stdio = @import("stdio.zig");

const Allocator = std.mem.Allocator;
const Container = zortui.Container;
const Surface = zortui.Surface;

pub const Stream = stdio.Stream;

/// How a transcript line is drawn.
pub const Kind = enum { user, assistant, tool, info, err };

pub const Line = struct {
    kind: Kind,
    text: []u8,
};

/// What the running job is. Decides how its stdout lines are classified: a
/// model turn's stdout is the assistant speaking, a command's is plain output.
pub const JobKind = enum { agent, command };

/// Backend and model, for the status bar.
pub const Info = struct {
    backend: []const u8 = "",
    model: []const u8 = "",
};

/// What the TUI drives. main.zig's implementation runs AgentLoop.
pub const Runner = struct {
    ctx: *anyopaque,
    /// Runs on the worker thread, one line at a time. Output goes to `inbox`,
    /// either directly or through stdio's sink (which the session points at
    /// the same inbox).
    run: *const fn (ctx: *anyopaque, line: []const u8, inbox: *Inbox) void,
    /// Runs on the UI thread, and only while no job is running. The returned
    /// slices are copied before the next job starts.
    info: *const fn (ctx: *anyopaque) Info,
};

/// Set while the alternate screen is up, so a panic can put the terminal back.
pub var active = std.atomic.Value(bool).init(false);

/// Restore the terminal from a crash path. No-op unless the TUI is up.
pub fn emergencyRestore() void {
    if (active.swap(false, .acquire)) zortui.terminal.emergencyRestore();
}

/// The zortui App options the TUI runs with. `clock` is not optional: zortui
/// reads ALL of its time through it -- frame timing, animation, and the Windows
/// input-wait deadlines. wintermolt reads time only through forTime, so
/// main.zig passes fsio.monoNs (ftim_mono_ns). This file cannot name forTime
/// itself: its headless tests link no prebuilt archives.
pub fn appOptions(env: zortui.capabilities.Env, clock: zortui.Clock) zortui.AppOptions {
    return .{
        .terminal = .{ .env = env, .title = "wintermolt" },
        // Quitting is ours: `q` has to be typeable; Esc, Ctrl+C and /quit quit.
        .quit_keys = &.{},
        .focus_navigation = false,
        .clock = clock,
    };
}

// ── inbox ──────────────────────────────────────────────────────────────────

/// Output written by the worker, waiting for the UI thread. Thread-safe.
pub const Inbox = struct {
    gpa: Allocator,
    /// A spin lock. Each critical section is one append or one swap, so there is
    /// nothing to wait on long enough to justify parking a thread.
    locked: std.atomic.Value(bool) = .init(false),
    chunks: std.ArrayList(Chunk) = .empty,

    fn lock(self: *Inbox) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Inbox) void {
        self.locked.store(false, .release);
    }

    pub const Chunk = struct { stream: Stream, bytes: []u8 };

    pub fn init(gpa: Allocator) Inbox {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Inbox) void {
        freeChunks(self.gpa, &self.chunks);
    }

    /// Copy `bytes` in. Drops them on OOM rather than failing the writer:
    /// losing a line of output must not abort a model turn.
    pub fn write(self: *Inbox, stream: Stream, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const copy = self.gpa.dupe(u8, bytes) catch return;
        self.lock();
        defer self.unlock();
        self.chunks.append(self.gpa, .{ .stream = stream, .bytes = copy }) catch self.gpa.free(copy);
    }

    /// The signature stdio.Sink calls.
    pub fn sinkWrite(ctx: *anyopaque, stream: Stream, bytes: []const u8) void {
        const self: *Inbox = @ptrCast(@alignCast(ctx));
        self.write(stream, bytes);
    }

    /// Hand over everything written so far. `into` must be empty.
    fn takeAll(self: *Inbox, into: *std.ArrayList(Chunk)) void {
        self.lock();
        defer self.unlock();
        std.mem.swap(std.ArrayList(Chunk), &self.chunks, into);
    }

    fn freeChunks(gpa: Allocator, list: *std.ArrayList(Chunk)) void {
        for (list.items) |c| gpa.free(c.bytes);
        list.deinit(gpa);
        list.* = .empty;
    }
};

// ── transcript ─────────────────────────────────────────────────────────────

pub const Transcript = struct {
    gpa: Allocator,
    lines: std.ArrayList(Line) = .empty,
    /// The unterminated tail of each stream. Drawn live, which is how a
    /// streaming reply appears token by token.
    pending: [2]Pending = .{ .{}, .{} },

    /// Old lines are dropped past this, so a long session stays cheap to lay out.
    pub const max_lines = 5000;

    const Pending = struct {
        bytes: std.ArrayList(u8) = .empty,
        escape: Escape = .none,
    };

    /// Where an ANSI escape sequence is, when a chunk ends inside one.
    const Escape = enum { none, esc, csi, osc, osc_esc };

    pub fn init(gpa: Allocator) Transcript {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.lines.items) |l| self.gpa.free(l.text);
        self.lines.deinit(self.gpa);
        for (&self.pending) |*p| p.bytes.deinit(self.gpa);
    }

    /// Add finished text, one line per `\n`.
    pub fn add(self: *Transcript, kind: Kind, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |piece| self.push(kind, piece);
    }

    fn push(self: *Transcript, kind: Kind, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        sanitizeUtf8(copy);
        self.lines.append(self.gpa, .{ .kind = kind, .text = copy }) catch {
            self.gpa.free(copy);
            return;
        };
        if (self.lines.items.len > max_lines) {
            const drop = self.lines.items.len - max_lines + max_lines / 10;
            for (self.lines.items[0..drop]) |l| self.gpa.free(l.text);
            self.lines.replaceRangeAssumeCapacity(0, drop, &.{});
        }
    }

    /// Feed raw bytes written to a stream: escapes stripped, split into lines.
    pub fn ingest(self: *Transcript, stream: Stream, bytes: []const u8, job: JobKind) void {
        const p = &self.pending[@intFromEnum(stream)];
        for (bytes) |b| switch (p.escape) {
            .none => switch (b) {
                0x1b => p.escape = .esc,
                '\n' => self.finish(stream, job),
                '\t' => p.bytes.appendSlice(self.gpa, "    ") catch {},
                // '\r' and the other C0 controls draw nothing useful.
                0...8, 11...0x1a, 0x1c...0x1f, 0x7f => {},
                else => p.bytes.append(self.gpa, b) catch {},
            },
            .esc => p.escape = switch (b) {
                '[' => .csi,
                ']' => .osc,
                else => .none,
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) p.escape = .none;
            },
            .osc => {
                if (b == 0x07) p.escape = .none else if (b == 0x1b) p.escape = .osc_esc;
            },
            .osc_esc => p.escape = .none,
        };
    }

    fn finish(self: *Transcript, stream: Stream, job: JobKind) void {
        const p = &self.pending[@intFromEnum(stream)];
        self.push(classify(stream, p.bytes.items, job), p.bytes.items);
        p.bytes.clearRetainingCapacity();
    }

    /// End of a job: whatever is still unterminated becomes a line.
    pub fn flush(self: *Transcript, job: JobKind) void {
        for ([_]Stream{ .stdout, .stderr }) |stream| {
            const p = &self.pending[@intFromEnum(stream)];
            p.escape = .none;
            if (p.bytes.items.len > 0) self.finish(stream, job);
        }
    }

    pub fn pendingText(self: *const Transcript, stream: Stream) []const u8 {
        const bytes = self.pending[@intFromEnum(stream)].bytes.items;
        return bytes[0..completeUtf8Len(bytes)];
    }
};

/// "[tool: bash] [ok]" is a tool line whichever stream it came from; after that
/// stderr is a notice (or an error), and stdout is the assistant during a model
/// turn and plain output during a command.
pub fn classify(stream: Stream, text: []const u8, job: JobKind) Kind {
    const trimmed = std.mem.trimStart(u8, text, " ");
    if (std.mem.startsWith(u8, trimmed, "[tool:")) return .tool;
    return switch (stream) {
        .stderr => if (looksLikeError(trimmed)) .err else .info,
        .stdout => if (job == .agent) .assistant else .info,
    };
}

fn looksLikeError(text: []const u8) bool {
    for ([_][]const u8{ "[Error]", "[error]", "Error:", "[Warning]", "[WARN]" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// Length of `bytes` without a trailing, still-incomplete UTF-8 sequence, so a
/// token split mid-character never reaches the renderer half-formed.
fn completeUtf8Len(bytes: []const u8) usize {
    var back: usize = 0;
    while (back < 4 and back < bytes.len) : (back += 1) {
        const b = bytes[bytes.len - 1 - back];
        if (b & 0xC0 != 0x80) {
            const need = std.unicode.utf8ByteSequenceLength(b) catch return bytes.len;
            return if (need > back + 1) bytes.len - 1 - back else bytes.len;
        }
    }
    return bytes.len;
}

/// Replace every byte that is not part of valid UTF-8 with '?', in place.
fn sanitizeUtf8(bytes: []u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            bytes[i] = '?';
            i += 1;
            continue;
        };
        if (i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            bytes[i] = '?';
            i += 1;
            continue;
        }
        i += len;
    }
}

// ── input line ─────────────────────────────────────────────────────────────

/// A single-line editor. `cursor` is a byte offset, always on a codepoint
/// boundary.
pub const Editor = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

    pub fn init(gpa: Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.gpa);
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn clear(self: *Editor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
    }

    /// Insert at the cursor. Control characters are dropped and a pasted
    /// newline becomes a space: this is one line.
    pub fn insert(self: *Editor, bytes: []const u8) void {
        for (bytes) |b| {
            const c: u8 = if (b == '\n' or b == '\r' or b == '\t') ' ' else b;
            if (c < 0x20 or c == 0x7f) continue;
            self.buf.insert(self.gpa, self.cursor, c) catch return;
            self.cursor += 1;
        }
    }

    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        const start = prevBoundary(self.buf.items, self.cursor);
        self.buf.replaceRangeAssumeCapacity(start, self.cursor - start, &.{});
        self.cursor = start;
    }

    pub fn delete(self: *Editor) void {
        if (self.cursor >= self.buf.items.len) return;
        const next = nextBoundary(self.buf.items, self.cursor);
        self.buf.replaceRangeAssumeCapacity(self.cursor, next - self.cursor, &.{});
    }

    pub fn left(self: *Editor) void {
        self.cursor = prevBoundary(self.buf.items, self.cursor);
    }

    pub fn right(self: *Editor) void {
        self.cursor = nextBoundary(self.buf.items, self.cursor);
    }

    pub fn home(self: *Editor) void {
        self.cursor = 0;
    }

    pub fn end(self: *Editor) void {
        self.cursor = self.buf.items.len;
    }

    fn prevBoundary(bytes: []const u8, at: usize) usize {
        var i = at;
        while (i > 0) {
            i -= 1;
            if (bytes[i] & 0xC0 != 0x80) break;
        }
        return i;
    }

    fn nextBoundary(bytes: []const u8, at: usize) usize {
        var i = @min(at + 1, bytes.len);
        while (i < bytes.len and bytes[i] & 0xC0 == 0x80) i += 1;
        return i;
    }
};

// ── session ────────────────────────────────────────────────────────────────

/// Everything the TUI shows and does. Must not move once `submit` has started a
/// job: the worker holds a pointer to it.
pub const Session = struct {
    gpa: Allocator,
    runner: Runner,
    version: []const u8,

    inbox: Inbox,
    sink: stdio.Sink,
    transcript: Transcript,
    editor: Editor,

    backend: []u8 = &.{},
    model: []u8 = &.{},

    busy: bool = false,
    job_kind: JobKind = .agent,
    job_line: ?[]u8 = null,
    worker: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),

    quit_requested: bool = false,
    redraw_requested: bool = false,
    /// Rows scrolled back from the newest line. Zero follows the bottom.
    scroll: usize = 0,
    /// Rows the transcript had last frame, for paging.
    view_rows: usize = 0,
    frame: u64 = 0,
    frame_alloc: Allocator = undefined,

    pub fn init(gpa: Allocator, runner: Runner, version: []const u8) Session {
        var self: Session = .{
            .gpa = gpa,
            .runner = runner,
            .version = version,
            .inbox = .init(gpa),
            .sink = undefined,
            .transcript = .init(gpa),
            .editor = .init(gpa),
        };
        self.refreshInfo();
        self.transcript.add(.info, banner);
        self.transcript.add(.info, "  Type /help for commands. Esc, Ctrl+C or /quit exits. PgUp/PgDn or the mouse wheel scroll.");
        self.transcript.add(.info, "");
        return self;
    }

    pub fn deinit(self: *Session) void {
        if (self.worker) |t| t.join();
        if (self.job_line) |l| self.gpa.free(l);
        self.inbox.deinit();
        self.transcript.deinit();
        self.editor.deinit();
        self.gpa.free(self.backend);
        self.gpa.free(self.model);
    }

    /// Route stdio.stdout()/stderr() into this session's transcript. Call once
    /// the session has its final address.
    pub fn installSink(self: *Session) void {
        self.sink = .{ .ctx = &self.inbox, .write = Inbox.sinkWrite };
        stdio.setSink(&self.sink);
    }

    pub fn uninstallSink(self: *Session) void {
        _ = self;
        stdio.setSink(null);
    }

    fn refreshInfo(self: *Session) void {
        const info = self.runner.info(self.runner.ctx);
        const backend = self.gpa.dupe(u8, info.backend) catch return;
        const model = self.gpa.dupe(u8, info.model) catch {
            self.gpa.free(backend);
            return;
        };
        self.gpa.free(self.backend);
        self.gpa.free(self.model);
        self.backend = backend;
        self.model = model;
    }

    // ── input ──────────────────────────────────────────────────────────

    pub fn handleEvent(self: *Session, event: zortui.InputEvent) void {
        switch (event) {
            .key => |k| self.handleKey(k),
            .paste => |text| self.editor.insert(text),
            .mouse => |m| if (m.action == .scroll) {
                if (m.scroll < 0) self.scrollUp(3) else if (m.scroll > 0) self.scrollDown(3);
            },
            .focus => {},
        }
    }

    fn handleKey(self: *Session, k: zortui.KeyEvent) void {
        const is = struct {
            fn name(key: zortui.KeyEvent, want: []const u8) bool {
                return !key.ctrl and !key.alt and std.mem.eql(u8, key.name, want);
            }
        }.name;

        if (zortui.matchKey(k, "ctrl+c") or is(k, "escape")) {
            self.quit_requested = true;
        } else if (zortui.matchKey(k, "ctrl+l")) {
            self.redraw_requested = true;
        } else if (is(k, "enter")) {
            self.submit();
        } else if (is(k, "backspace")) {
            self.editor.backspace();
        } else if (is(k, "delete")) {
            self.editor.delete();
        } else if (is(k, "left")) {
            self.editor.left();
        } else if (is(k, "right")) {
            self.editor.right();
        } else if (is(k, "home")) {
            self.editor.home();
        } else if (is(k, "end")) {
            self.editor.end();
        } else if (is(k, "up")) {
            self.scrollUp(1);
        } else if (is(k, "down")) {
            self.scrollDown(1);
        } else if (is(k, "pageup")) {
            self.scrollUp(@max(1, self.view_rows -| 1));
        } else if (is(k, "pagedown")) {
            self.scrollDown(@max(1, self.view_rows -| 1));
        } else if (k.char) |c| {
            if (!k.ctrl and !k.alt) self.editor.insert(c);
        }
    }

    fn scrollUp(self: *Session, rows: usize) void {
        // Clamped against the content when drawn.
        self.scroll +|= rows;
    }

    fn scrollDown(self: *Session, rows: usize) void {
        self.scroll -|= rows;
    }

    /// Enter: quit, refuse while busy, or start a job.
    pub fn submit(self: *Session) void {
        const line = std.mem.trim(u8, self.editor.text(), " \t\r");
        if (line.len == 0) return;
        if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/exit")) {
            self.quit_requested = true;
            return;
        }
        if (self.busy) {
            self.transcript.add(.info, "(still working on the previous request; wait for it to finish)");
            return;
        }
        const owned = self.gpa.dupe(u8, line) catch return;
        self.transcript.push(.user, owned);
        self.editor.clear();
        self.scroll = 0;
        self.start(owned) catch |e| {
            self.transcript.add(.err, @errorName(e));
            self.gpa.free(owned);
        };
    }

    fn start(self: *Session, line: []u8) !void {
        const media = std.mem.startsWith(u8, line, "/look") or std.mem.startsWith(u8, line, "/screenshot");
        self.job_kind = if (line[0] == '/' and !media) .command else .agent;
        self.finished.store(false, .release);
        self.job_line = line;
        self.busy = true;
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch |e| {
            self.busy = false;
            self.job_line = null;
            return e;
        };
    }

    fn workerMain(self: *Session) void {
        self.runner.run(self.runner.ctx, self.job_line.?, &self.inbox);
        self.finished.store(true, .release);
    }

    /// Move the worker's output into the transcript and settle a finished job.
    /// UI thread, once per frame. True when a job just finished.
    pub fn pump(self: *Session) bool {
        self.drain();
        if (!self.busy or !self.finished.load(.acquire)) return false;
        if (self.worker) |t| t.join();
        self.worker = null;
        // Whatever arrived between the drain above and the worker finishing.
        self.drain();
        self.transcript.flush(self.job_kind);
        if (self.job_line) |l| self.gpa.free(l);
        self.job_line = null;
        self.busy = false;
        self.refreshInfo();
        return true;
    }

    fn drain(self: *Session) void {
        var taken: std.ArrayList(Inbox.Chunk) = .empty;
        defer Inbox.freeChunks(self.gpa, &taken);
        self.inbox.takeAll(&taken);
        for (taken.items) |c| self.transcript.ingest(c.stream, c.bytes, self.job_kind);
    }

    /// For tests: pump until the running job has finished, giving up after
    /// `max_spins` yields. No clock involved.
    pub fn waitIdle(self: *Session, max_spins: u64) bool {
        var spins: u64 = 0;
        while (self.busy) {
            if (self.pump()) return true;
            if (spins >= max_spins) return false;
            std.Thread.yield() catch {};
            spins += 1;
        }
        return true;
    }

    pub fn takeRedraw(self: *Session) bool {
        defer self.redraw_requested = false;
        return self.redraw_requested;
    }

    // ── view ───────────────────────────────────────────────────────────

    pub fn view(self: *Session, ui: *Container) anyerror!void {
        self.frame +%= 1;
        try ui.row(.{ .layout = .{ .size = .{ .cells = 1 } } }, zortui.Body.with(self, header));
        try ui.panel(.{ .title = "Transcript" }, zortui.Body.with(self, transcriptBody));
        try ui.panel(.{ .layout = .{ .size = .{ .cells = 3 } } }, zortui.Body.with(self, inputBody));

        // Frame arena: the status bar is drawn after this function returns.
        const alloc = ui.ctx.allocator;
        const items = try alloc.alloc(zortui.widgets.StatusItem, 3);
        items[0] = .{ .key = "Enter", .label = "send" };
        items[1] = .{ .key = "PgUp/PgDn", .label = "scroll" };
        items[2] = .{ .key = "Esc", .label = "quit" };
        const theme = ui.theme();
        const right = try alloc.alloc(zortui.widgets.StatusItem, 2);
        right[0] = .{ .label = try ui.fmt("{s} · {s}", .{ self.backend, self.model }) };
        right[1] = if (self.busy)
            .{ .label = try ui.fmt("{s} working", .{spinner[@intCast(self.frame / 3 % spinner.len)]}), .color = theme.warning, .active = true }
        else
            .{ .label = "● ready", .color = theme.success };
        try ui.statusBar(.{ .items = items, .right = right });
    }

    fn header(self: *Session, r: *Container) anyerror!void {
        try r.heading(try r.fmt(" wintermolt v{s} — Lite AI Agent CLI (MIT)", .{self.version}));
        try r.badge(.{
            .text = if (self.busy) "WORKING" else "READY",
            .color = if (self.busy) r.theme().warning else r.theme().success,
            .alignment = .right,
        });
    }

    fn transcriptBody(self: *Session, p: *Container) anyerror!void {
        self.frame_alloc = p.ctx.allocator;
        try p.draw(zortui.ui.DrawBody.with(self, drawTranscript));
    }

    const Entry = struct { kind: Kind, text: []const u8 };

    fn drawTranscript(self: *Session, s: Surface) anyerror!void {
        const width = s.width();
        const height = s.height();
        if (width < 2 or height == 0) return;
        const text_w = width - 1; // the last column is the scrollbar

        // Finished lines, then the live tail of each stream.
        var tails: [2]Entry = undefined;
        var tail_count: usize = 0;
        for ([_]Stream{ .stdout, .stderr }) |stream| {
            const t = self.transcript.pendingText(stream);
            if (t.len == 0) continue;
            tails[tail_count] = .{ .kind = classify(stream, t, self.job_kind), .text = t };
            tail_count += 1;
        }

        var total: usize = 0;
        for (self.transcript.lines.items) |l| total += rowsOf(l.kind, l.text, text_w);
        for (tails[0..tail_count]) |e| total += rowsOf(e.kind, e.text, text_w);

        self.scroll = @min(self.scroll, total -| height);
        self.view_rows = height;
        const end_row = total - self.scroll;
        const first = end_row -| height;

        var row: usize = 0;
        for (self.transcript.lines.items) |l| {
            if (row >= end_row) break;
            row = try self.drawEntry(s, .{ .kind = l.kind, .text = l.text }, row, first, end_row, text_w);
        }
        for (tails[0..tail_count]) |e| {
            if (row >= end_row) break;
            row = try self.drawEntry(s, e, row, first, end_row, text_w);
        }

        zortui.widgets.drawScrollbarWidget(s.sub(@intCast(text_w), 0, 1, height), .{
            .total = total,
            .viewport = height,
            .offset = first,
        });
    }

    /// Draw the visible rows of one entry. Returns the row after it.
    fn drawEntry(self: *Session, s: Surface, e: Entry, row: usize, first: usize, end_row: usize, w: usize) !usize {
        const n = rowsOf(e.kind, e.text, w);
        if (row + n <= first) return row + n;

        const theme = s.theme;
        const opts: zortui.TextOptions = switch (e.kind) {
            .user => .{ .fg = theme.primary, .attrs = .bold_only, .ellipsis = false },
            .assistant => .{ .fg = theme.foreground, .ellipsis = false },
            .tool => .{ .fg = theme.secondary, .ellipsis = false },
            .info => .{ .fg = theme.muted, .ellipsis = false },
            .err => .{ .fg = theme.danger, .ellipsis = false },
        };
        const shown = if (e.kind == .user)
            try std.fmt.allocPrint(self.frame_alloc, "> {s}", .{e.text})
        else
            e.text;
        const wrapped = try zortui.unicode.wrap(self.frame_alloc, shown, w);
        for (wrapped, 0..) |segment, i| {
            const r = row + i;
            if (r < first or r >= end_row) continue;
            _ = s.text(0, @intCast(r - first), segment, opts);
        }
        return row + n;
    }

    fn rowsOf(kind: Kind, text: []const u8, w: usize) usize {
        // "> " is added to user lines when drawn; count it the same way.
        const extra: usize = if (kind == .user) 2 else 0;
        if (text.len + extra == 0) return 1;
        if (kind == .user) {
            var buf: [512]u8 = undefined;
            if (text.len + 2 <= buf.len) {
                buf[0] = '>';
                buf[1] = ' ';
                @memcpy(buf[2..][0..text.len], text);
                return @max(1, zortui.unicode.wrapCount(buf[0 .. text.len + 2], w));
            }
        }
        return @max(1, zortui.unicode.wrapCount(text, w));
    }

    fn inputBody(self: *Session, p: *Container) anyerror!void {
        // The field shows `width - 2` columns and keeps the caret after the
        // text, so scroll the value horizontally to keep the caret in view.
        const bytes = self.editor.text();
        const avail = p.width() -| 3;
        var from: usize = 0;
        while (from < self.editor.cursor and
            zortui.unicode.stringWidth(bytes[from..self.editor.cursor]) > avail)
        {
            from = Editor.nextBoundary(bytes, from);
        }
        try p.textInput(.{
            .value = bytes[from..],
            .cursor = zortui.unicode.stringWidth(bytes[from..self.editor.cursor]),
            .placeholder = if (self.busy) "working… (Esc or Ctrl+C exits)" else "Type a message, or /help",
            .focused = true,
        }, "input");
    }
};

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const banner =
    \\  ╦ ╦┬┌┐┌┌┬┐┌─┐┬─┐┌┬┐┌─┐┬ ┌┬┐
    \\  ║║║││││ │ ├┤ ├┬┘││││ ││  │
    \\  ╚╩╝┴┘└┘ ┴ └─┘┴└─┴ ┴└─┘┴─┘┴
;

// ── tests ──────────────────────────────────────────────────────────────────
// Headless: zortui's testing module renders to cells, no terminal involved.
// Run by `zig build test` (build.zig roots a test binary at this file).

const testing = std.testing;

/// A stand-in for the agent: records what it was asked and answers like one.
const FakeAgent = struct {
    received: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    fn runner(self: *FakeAgent) Runner {
        return .{ .ctx = self, .run = run, .info = info };
    }

    fn run(ctx: *anyopaque, line: []const u8, inbox: *Inbox) void {
        const self: *FakeAgent = @ptrCast(@alignCast(ctx));
        self.received.appendSlice(self.alloc, line) catch {};
        // Through stdio, the way AgentLoop writes: tokens split mid-line, a
        // colored tool notice, a notice on stderr.
        _ = inbox;
        const out = stdio.stdout();
        out.writeAll("echo: ") catch {};
        out.print("{s}\n", .{line}) catch {};
        out.print("\x1b[90m[tool: {s}]\x1b[0m ", .{"bash"}) catch {};
        stdio.stderr().writeAll("[backend] note\n") catch {};
        out.writeAll("\x1b[32m[ok]\x1b[0m\n") catch {};
    }

    fn info(_: *anyopaque) Info {
        return .{ .backend = "ollama", .model = "qwen3:8b" };
    }
};

fn keyChar(c: []const u8) zortui.InputEvent {
    return .{ .key = .{ .name = c, .key = c, .char = c } };
}

fn keyNamed(name: []const u8) zortui.InputEvent {
    return .{ .key = .{ .name = name, .key = name } };
}

fn typeText(session: *Session, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) session.handleEvent(keyChar(text[i .. i + 1]));
}

fn render(session: *Session) !zortui.RenderedScreen {
    return zortui.renderToScreen(testing.allocator, 80, 24, "dark", zortui.Body.with(session, Session.view));
}

test "transcript renders user, assistant and tool lines distinguishably" {
    var fake: FakeAgent = .{ .alloc = testing.allocator };
    defer fake.received.deinit(testing.allocator);
    var session = Session.init(testing.allocator, fake.runner(), "0.5.0");
    defer session.deinit();

    session.transcript.push(.user, "hello");
    session.transcript.ingest(.stdout, "Hi there, human.\n", .agent);
    session.transcript.ingest(.stdout, "\x1b[90m[tool: bash]\x1b[0m \x1b[32m[ok]\x1b[0m\n", .agent);

    var screen = try render(&session);
    defer screen.deinit();

    const user = screen.find("> hello") orelse return error.UserLineMissing;
    const assistant = screen.find("Hi there, human.") orelse return error.AssistantLineMissing;
    const tool = screen.find("[tool: bash] [ok]") orelse return error.ToolLineMissing;
    // No escape bytes leak into cells.
    try testing.expect(!screen.contains("[90m"));

    const fg_user = screen.cell(user.x, user.y).fg;
    const fg_assistant = screen.cell(assistant.x, assistant.y).fg;
    const fg_tool = screen.cell(tool.x, tool.y).fg;
    try testing.expect(fg_user.raw() != fg_assistant.raw());
    try testing.expect(fg_tool.raw() != fg_assistant.raw());
    try testing.expect(fg_tool.raw() != fg_user.raw());
    try testing.expect(screen.cell(user.x, user.y).attrs.bold);
}

test "input line edits: insert, backspace, left/right, home/end" {
    var fake: FakeAgent = .{ .alloc = testing.allocator };
    defer fake.received.deinit(testing.allocator);
    var session = Session.init(testing.allocator, fake.runner(), "0.5.0");
    defer session.deinit();

    typeText(&session, "helo");
    session.handleEvent(keyNamed("left"));
    typeText(&session, "l"); // hel|o -> hell|o
    try testing.expectEqualStrings("hello", session.editor.text());

    session.handleEvent(keyNamed("end"));
    typeText(&session, "!!");
    session.handleEvent(keyNamed("backspace"));
    try testing.expectEqualStrings("hello!", session.editor.text());

    session.handleEvent(keyNamed("home"));
    session.handleEvent(keyNamed("delete"));
    session.handleEvent(keyNamed("right"));
    session.handleEvent(.{ .key = .{ .name = "space", .key = "space", .char = " " } });
    try testing.expectEqualStrings("e llo!", session.editor.text());

    // Multi-byte: backspace removes a whole codepoint.
    session.handleEvent(keyNamed("end"));
    session.handleEvent(keyChar("é"));
    session.handleEvent(keyNamed("backspace"));
    try testing.expectEqualStrings("e llo!", session.editor.text());

    // Ctrl chords are not typed.
    session.handleEvent(.{ .key = .{ .name = "x", .key = "ctrl+x", .ctrl = true, .char = "x" } });
    try testing.expectEqualStrings("e llo!", session.editor.text());

    var screen = try render(&session);
    defer screen.deinit();
    try testing.expect(screen.contains("e llo!"));
}

test "status bar shows backend and model, and the busy state" {
    var fake: FakeAgent = .{ .alloc = testing.allocator };
    defer fake.received.deinit(testing.allocator);
    var session = Session.init(testing.allocator, fake.runner(), "0.5.0");
    defer session.deinit();

    {
        var screen = try render(&session);
        defer screen.deinit();
        const bar = try screen.line(23);
        try testing.expect(std.mem.indexOf(u8, bar, "qwen3:8b") != null);
        try testing.expect(std.mem.indexOf(u8, bar, "ollama") != null);
        try testing.expect(std.mem.indexOf(u8, bar, "ready") != null);
        try testing.expect(screen.contains("wintermolt v0.5.0"));
    }
    session.busy = true;
    defer session.busy = false;
    var screen = try render(&session);
    defer screen.deinit();
    try testing.expect(std.mem.indexOf(u8, try screen.line(23), "working") != null);
}

test "submitting input reaches the agent on the worker and its output lands in the transcript" {
    var fake: FakeAgent = .{ .alloc = testing.allocator };
    defer fake.received.deinit(testing.allocator);
    var session = Session.init(testing.allocator, fake.runner(), "0.5.0");
    defer session.deinit();
    session.installSink();
    defer session.uninstallSink();

    typeText(&session, "  what is 2+2  ");
    session.handleEvent(keyNamed("enter"));
    try testing.expect(session.busy);
    try testing.expectEqualStrings("", session.editor.text());

    // A second Enter while busy is refused, not queued.
    typeText(&session, "again");
    session.handleEvent(keyNamed("enter"));
    try testing.expectEqualStrings("again", session.editor.text());

    try testing.expect(session.waitIdle(50_000_000));
    try testing.expectEqualStrings("what is 2+2", fake.received.items);

    var kinds: [3]?Kind = .{ null, null, null };
    for (session.transcript.lines.items) |l| {
        if (std.mem.eql(u8, l.text, "echo: what is 2+2")) kinds[0] = l.kind;
        if (std.mem.eql(u8, l.text, "[tool: bash] [ok]")) kinds[1] = l.kind;
        if (std.mem.eql(u8, l.text, "[backend] note")) kinds[2] = l.kind;
    }
    try testing.expectEqual(@as(?Kind, .assistant), kinds[0]);
    try testing.expectEqual(@as(?Kind, .tool), kinds[1]);
    try testing.expectEqual(@as(?Kind, .info), kinds[2]);

    var screen = try render(&session);
    defer screen.deinit();
    try testing.expect(screen.contains("> what is 2+2"));
    try testing.expect(screen.contains("echo: what is 2+2"));
}

test "a slash command's stdout is output, not the assistant; /quit and Esc quit" {
    var fake: FakeAgent = .{ .alloc = testing.allocator };
    defer fake.received.deinit(testing.allocator);
    var session = Session.init(testing.allocator, fake.runner(), "0.5.0");
    defer session.deinit();
    session.installSink();
    defer session.uninstallSink();

    typeText(&session, "/stats");
    session.handleEvent(keyNamed("enter"));
    try testing.expect(session.waitIdle(50_000_000));
    for (session.transcript.lines.items) |l| {
        if (std.mem.eql(u8, l.text, "echo: /stats")) try testing.expectEqual(Kind.info, l.kind);
    }

    typeText(&session, "/quit");
    session.handleEvent(keyNamed("enter"));
    try testing.expect(session.quit_requested);
    try testing.expectEqualStrings("/stats", fake.received.items); // /quit never reached the agent

    session.quit_requested = false;
    session.handleEvent(keyNamed("escape"));
    try testing.expect(session.quit_requested);
    session.quit_requested = false;
    session.handleEvent(.{ .key = .{ .name = "c", .key = "ctrl+c", .ctrl = true } });
    try testing.expect(session.quit_requested);
}

test "a streamed partial line is visible before its newline, and scrolling clamps" {
    var fake: FakeAgent = .{ .alloc = testing.allocator };
    defer fake.received.deinit(testing.allocator);
    var session = Session.init(testing.allocator, fake.runner(), "0.5.0");
    defer session.deinit();

    session.transcript.ingest(.stdout, "stream", .agent);
    session.transcript.ingest(.stdout, "ing tok\xc3", .agent); // split "é"
    {
        var screen = try render(&session);
        defer screen.deinit();
        try testing.expect(screen.contains("streaming tok"));
    }
    session.transcript.ingest(.stdout, "\xa9\n", .agent);
    try testing.expectEqualStrings("streaming toké", session.transcript.lines.items[session.transcript.lines.items.len - 1].text);

    for (0..100) |i| {
        const l = try std.fmt.allocPrint(testing.allocator, "line {d}", .{i});
        defer testing.allocator.free(l);
        session.transcript.add(.assistant, l);
    }
    session.handleEvent(keyNamed("pageup"));
    session.handleEvent(.{ .mouse = .{ .action = .scroll, .button = .none, .x = 5, .y = 5, .scroll = -1 } });
    {
        var screen = try render(&session);
        defer screen.deinit();
        try testing.expect(!screen.contains("line 99"));
    }
    session.scroll = 1_000_000;
    {
        var screen = try render(&session);
        defer screen.deinit();
        try testing.expect(screen.contains("╦ ╦")); // clamped to the top: the banner
    }
    session.handleEvent(keyNamed("pagedown"));
    session.scroll = 0;
    var screen = try render(&session);
    defer screen.deinit();
    try testing.expect(screen.contains("line 99"));
}

var fake_clock_reads: usize = 0;

/// Stands in for fsio.monoNs, which this test binary cannot link.
fn fakeClock() u64 {
    fake_clock_reads += 1;
    return 4_242_000_000;
}

test "the app runs on the clock it is handed" {
    const opts = appOptions(zortui.capabilities.Env.empty, fakeClock);
    try testing.expect(opts.clock.? == @as(zortui.Clock, fakeClock));

    // zortui reads time only through clock.nowNs; with these options that is
    // the handed-in function, and zortui's own clock is not consulted.
    fake_clock_reads = 0;
    try testing.expectEqual(@as(u64, 4_242_000_000), zortui.clock.nowNs(opts.clock));
    try testing.expectEqual(@as(usize, 1), fake_clock_reads);

    // The rest is what main.zig passed before the hook existed.
    try testing.expectEqual(@as(usize, 0), opts.quit_keys.len);
    try testing.expect(!opts.focus_navigation);
    try testing.expectEqualStrings("wintermolt", opts.terminal.title.?);
}
