// Copyright The Fantastic Planet - By David Clabaugh
//
// control.zig -- stopping a run, and asking before a command runs.
//
// STOP. One switch for the whole process: wintermolt runs one reply at a time
// (the TUI's worker, the web page, the chat queue), so "stop" always means the
// reply running now. Whoever starts a reply calls beginRun(), which clears a
// stop that arrived while nothing was running. The model request (curl's
// progress callback, api/curl_timeouts.zig), the loop between turns and tools
// (agent/loop.zig) and a running bash command (fsio.runCaptureCancelable) all
// read it.
//
// ASKING. WINTERMOLT_BASH_APPROVAL=ask puts a question in front of every shell
// command the model starts (bash, the schedule tool's `add`, a runtime skill).
// Each front end registers an Asker that shows the question; the answer comes
// back through answer(id, decision), from the same thread (the REPL reads a
// line before post() returns) or another one later (the TUI, the web page, a
// chat /approve). Nobody to ask, nobody answering in 30 minutes, or a stop
// while waiting all mean the command does not run. OpenClaw's names: its
// `tools.exec.mode=ask`, `/approve <id> allow-once|allow-always|deny`.

const std = @import("std");
const fsio = @import("../fsio.zig");
const compat = @import("../compat.zig");

// ── stop ───────────────────────────────────────────────────────────────────

var stop_flag = std.atomic.Value(bool).init(false);
var run_active = std.atomic.Value(bool).init(false);

/// Stop the reply that is running now. Safe from any thread or a signal handler.
pub fn requestStop() void {
    stop_flag.store(true, .release);
}

pub fn stopRequested() bool {
    return stop_flag.load(.acquire);
}

/// A reply starts: a stop from before it does not apply to it.
pub fn beginRun() void {
    stop_flag.store(false, .release);
    run_active.store(true, .release);
}

/// The reply ended: Ctrl+C quits again rather than stopping, and its stop is
/// spent, so curl calls and scheduled commands outside a reply are not cut off.
pub fn endRun() void {
    run_active.store(false, .release);
    stop_flag.store(false, .release);
}

pub fn runActive() bool {
    return run_active.load(.acquire);
}

// ── the mode ───────────────────────────────────────────────────────────────

pub const Mode = enum { off, ask };

/// WINTERMOLT_BASH_APPROVAL. Unset or "off" runs commands as before; any other
/// value asks, so a typo fails closed.
pub fn parseMode(raw: ?[]const u8) Mode {
    const v = std.mem.trim(u8, raw orelse return .off, " \t\r\n");
    if (v.len == 0 or std.ascii.eqlIgnoreCase(v, "off")) return .off;
    return .ask;
}

pub fn modeFromEnv() Mode {
    return parseMode(compat.getenv("WINTERMOLT_BASH_APPROVAL"));
}

// ── asking ─────────────────────────────────────────────────────────────────

pub const Decision = enum(u8) { allow_once = 1, allow_always = 2, deny = 3 };

pub const Asker = struct {
    ctx: *anyopaque,
    /// Show the question. The answer is answer(id, ...), from this thread
    /// before returning or from another one later.
    post: *const fn (ctx: *anyopaque, id: []const u8, command: []const u8) void,
};

const no_one = "Not run: WINTERMOLT_BASH_APPROVAL=ask, and nobody is here to approve commands. Run wintermolt in a terminal, the web page or a chat with approvers, or set WINTERMOLT_BASH_APPROVAL=off.";
const denied = "Not run: the user denied this command. Do not retry it; ask what they want instead.";
const stopped = "Not run: the user stopped this reply.";
const unanswered = "Not run: nobody answered the approval request within 30 minutes.";

/// How long to wait for an answer, in 50 ms polls: 30 minutes, OpenClaw's.
pub var wait_polls: u32 = 30 * 60 * 20;

var asker: ?Asker = null;
/// A spin lock over the pending question and the allowed list. Each critical
/// section is a compare and a copy.
var locked = std.atomic.Value(bool).init(false);
var pending_id: [6]u8 = undefined;
var pending: bool = false;
var decision = std.atomic.Value(u8).init(0);
/// Commands answered allow-always, until wintermolt exits.
var always: std.ArrayListUnmanaged([]u8) = .empty;

fn lock() void {
    while (locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    locked.store(false, .release);
}

/// Who shows the question; null when nobody can (--gateway, --mcp-server).
pub fn setAsker(a: ?Asker) void {
    asker = a;
}

/// May `command` run? null when it may; otherwise why not, for the model.
pub fn approveCommand(command: []const u8) ?[]const u8 {
    return check(modeFromEnv(), command);
}

pub fn check(mode: Mode, command: []const u8) ?[]const u8 {
    if (mode == .off) return null;
    lock();
    for (always.items) |c| if (std.mem.eql(u8, c, command)) {
        unlock();
        return null;
    };
    unlock();
    const a = asker orelse return no_one;
    if (stopRequested()) return stopped;

    var id: [6]u8 = undefined;
    var raw: [3]u8 = undefined;
    if (!fsio.randomBytes(&raw)) return no_one;
    _ = std.fmt.bufPrint(&id, "{x}", .{raw}) catch unreachable;

    lock();
    pending_id = id;
    pending = true;
    decision.store(0, .release);
    unlock();
    defer {
        lock();
        pending = false;
        unlock();
    }

    a.post(a.ctx, &id, command);

    var polls: u32 = 0;
    while (decision.load(.acquire) == 0) : (polls += 1) {
        if (stopRequested()) return stopped;
        if (polls >= wait_polls) return unanswered;
        fsio.sleepNs(50 * std.time.ns_per_ms);
    }
    switch (@as(Decision, @enumFromInt(decision.load(.acquire)))) {
        .allow_once => return null,
        .allow_always => {
            lock();
            defer unlock();
            const copy = std.heap.c_allocator.dupe(u8, command) catch return null;
            always.append(std.heap.c_allocator, copy) catch std.heap.c_allocator.free(copy);
            return null;
        },
        .deny => return denied,
    }
}

/// Answer the question with this id. False when no question has that id: it
/// was answered already, it timed out, or the id is wrong.
pub fn answer(id: []const u8, d: Decision) bool {
    lock();
    defer unlock();
    if (!pending or !std.mem.eql(u8, id, &pending_id) or decision.load(.acquire) != 0) return false;
    decision.store(@intFromEnum(d), .release);
    return true;
}

/// Answer whatever is being asked (the TUI, whose user sees one question).
pub fn answerPending(d: Decision) bool {
    lock();
    if (!pending) {
        unlock();
        return false;
    }
    const id = pending_id;
    unlock();
    return answer(&id, d);
}

/// A question is waiting for an answer.
pub fn isAsking() bool {
    lock();
    defer unlock();
    return pending;
}

/// The question, as the REPL and the TUI show it.
pub fn writeQuestion(w: anytype, command: []const u8) !void {
    try w.print("\nRun this command?\n  {s}\ny once · a always (until wintermolt exits) · n no\n", .{command});
}

// ── the words people type ──────────────────────────────────────────────────

/// `/approve <id> allow-once|allow-always|deny`, OpenClaw's form.
pub fn parseApprove(text: []const u8) ?struct { id: []const u8, decision: Decision } {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    if (!std.mem.eql(u8, it.next() orelse return null, "/approve")) return null;
    const id = it.next() orelse return null;
    const word = it.next() orelse return null;
    if (it.next() != null) return null;
    const d: Decision = if (std.mem.eql(u8, word, "allow-once"))
        .allow_once
    else if (std.mem.eql(u8, word, "allow-always"))
        .allow_always
    else if (std.mem.eql(u8, word, "deny"))
        .deny
    else
        return null;
    return .{ .id = id, .decision = d };
}

/// The terminal's answer: y(es), a(lways), n(o). Enter alone is no.
pub fn parseAnswer(text: []const u8) ?Decision {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const eq = std.ascii.eqlIgnoreCase;
    if (t.len == 0 or eq(t, "n") or eq(t, "no")) return .deny;
    if (eq(t, "y") or eq(t, "yes")) return .allow_once;
    if (eq(t, "a") or eq(t, "always")) return .allow_always;
    return null;
}
