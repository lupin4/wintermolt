// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/agent/control.zig (stopping a run, asking before a command
// runs) and the bash tool's stop. A module rooted inside src/agent/ cannot
// import ../fsio.zig, so the root sits here.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const control = @import("agent/control.zig");
const bash = @import("tools/bash.zig");
const fsio = @import("fsio.zig");

// ── stop ───────────────────────────────────────────────────────────────────

test "a stop asked for between runs does not end the next one" {
    control.requestStop();
    try testing.expect(control.stopRequested());
    control.beginRun();
    try testing.expect(!control.stopRequested());
}

test "a stop does not outlive the reply it stopped (the scheduler runs after it)" {
    control.beginRun();
    control.requestStop();
    control.endRun();
    try testing.expect(!control.stopRequested());
}

// ── the mode ───────────────────────────────────────────────────────────────

test "approval mode: unset or off runs commands; any other value asks" {
    try testing.expectEqual(control.Mode.off, control.parseMode(null));
    try testing.expectEqual(control.Mode.off, control.parseMode(""));
    try testing.expectEqual(control.Mode.off, control.parseMode("off"));
    try testing.expectEqual(control.Mode.off, control.parseMode(" OFF\r\n"));
    try testing.expectEqual(control.Mode.ask, control.parseMode("ask"));
    try testing.expectEqual(control.Mode.ask, control.parseMode("on"));
    // A typo must not quietly mean "run everything".
    try testing.expectEqual(control.Mode.ask, control.parseMode("aks"));
}

// ── asking ─────────────────────────────────────────────────────────────────

/// An asker that answers on the spot, as the plain REPL does.
const Instant = struct {
    answer: control.Decision,
    asked: usize = 0,
    last_command: [64]u8 = undefined,
    last_len: usize = 0,

    fn asker(self: *Instant) control.Asker {
        return .{ .ctx = self, .post = post };
    }
    fn post(ctx: *anyopaque, id: []const u8, command: []const u8) void {
        const self: *Instant = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        self.last_len = @min(command.len, self.last_command.len);
        @memcpy(self.last_command[0..self.last_len], command[0..self.last_len]);
        // A made-up id answers nothing.
        std.debug.assert(!control.answer("nope00", .allow_once));
        std.debug.assert(control.answer(id, self.answer));
    }
};

test "approval off: a command runs without anyone being asked" {
    var a: Instant = .{ .answer = .deny };
    control.setAsker(a.asker());
    defer control.setAsker(null);
    control.beginRun();
    try testing.expect(control.check(.off, "echo hi") == null);
    try testing.expectEqual(@as(usize, 0), a.asked);
}

test "ask with no one to ask: not run, and the reason says how to change it" {
    control.setAsker(null);
    control.beginRun();
    const why = control.check(.ask, "echo hi").?;
    try testing.expect(std.mem.indexOf(u8, why, "WINTERMOLT_BASH_APPROVAL") != null);
}

test "ask: allow once runs it, and the same command is asked about again" {
    var a: Instant = .{ .answer = .allow_once };
    control.setAsker(a.asker());
    defer control.setAsker(null);
    control.beginRun();
    try testing.expect(control.check(.ask, "echo once") == null);
    try testing.expectEqualStrings("echo once", a.last_command[0..a.last_len]);
    try testing.expect(control.check(.ask, "echo once") == null);
    try testing.expectEqual(@as(usize, 2), a.asked);
}

test "ask: allow always runs it and stops asking for that exact command only" {
    var a: Instant = .{ .answer = .allow_always };
    control.setAsker(a.asker());
    defer control.setAsker(null);
    control.beginRun();
    try testing.expect(control.check(.ask, "echo always-1") == null);
    try testing.expect(control.check(.ask, "echo always-1") == null);
    try testing.expectEqual(@as(usize, 1), a.asked);
    a.answer = .deny;
    try testing.expect(control.check(.ask, "echo always-2") != null);
    try testing.expectEqual(@as(usize, 2), a.asked);
}

test "ask: deny means not run, and the model is told the user said no" {
    var a: Instant = .{ .answer = .deny };
    control.setAsker(a.asker());
    defer control.setAsker(null);
    control.beginRun();
    const why = control.check(.ask, "echo denied").?;
    try testing.expect(std.mem.indexOf(u8, why, "denied") != null);
}

/// An asker that only shows the question; the answer comes later from
/// another thread, as from a chat message or the web page.
const Later = struct {
    id: [16]u8 = undefined,
    id_len: std.atomic.Value(usize) = .init(0),

    fn asker(self: *Later) control.Asker {
        return .{ .ctx = self, .post = post };
    }
    fn post(ctx: *anyopaque, id: []const u8, _: []const u8) void {
        const self: *Later = @ptrCast(@alignCast(ctx));
        @memcpy(self.id[0..id.len], id);
        self.id_len.store(id.len, .release);
    }
    /// Wait for the question, then answer it (or stop the run).
    fn reply(self: *Later, d: ?control.Decision) void {
        while (self.id_len.load(.acquire) == 0) fsio.sleepNs(5 * std.time.ns_per_ms);
        fsio.sleepNs(50 * std.time.ns_per_ms);
        if (d) |decision| {
            std.debug.assert(control.answer(self.id[0..self.id_len.load(.acquire)], decision));
        } else control.requestStop();
    }
};

test "ask: an answer that arrives later from another thread is waited for" {
    var l: Later = .{};
    control.setAsker(l.asker());
    defer control.setAsker(null);
    control.beginRun();
    const t = try std.Thread.spawn(.{}, Later.reply, .{ &l, @as(?control.Decision, .allow_once) });
    defer t.join();
    try testing.expect(control.check(.ask, "echo later") == null);
    // Settled: nothing is pending any more, so a late duplicate answers nothing.
    try testing.expect(!control.answer(l.id[0..l.id_len.load(.acquire)], .deny));
}

test "ask: stopping the run while it waits means not run" {
    var l: Later = .{};
    control.setAsker(l.asker());
    defer control.setAsker(null);
    control.beginRun();
    const t = try std.Thread.spawn(.{}, Later.reply, .{ &l, @as(?control.Decision, null) });
    defer t.join();
    const why = control.check(.ask, "echo stopped").?;
    try testing.expect(std.mem.indexOf(u8, why, "stopped") != null);
}

test "ask: nobody answering is a no once the wait runs out" {
    var l: Later = .{};
    control.setAsker(l.asker());
    defer control.setAsker(null);
    control.beginRun();
    const saved = control.wait_polls;
    control.wait_polls = 4;
    defer control.wait_polls = saved;
    const why = control.check(.ask, "echo nobody").?;
    try testing.expect(std.mem.indexOf(u8, why, "answer") != null);
}

// ── the words people type ──────────────────────────────────────────────────

test "parseApprove reads OpenClaw's /approve <id> allow-once|allow-always|deny" {
    const once = control.parseApprove("/approve a1b2c3 allow-once").?;
    try testing.expectEqualStrings("a1b2c3", once.id);
    try testing.expectEqual(control.Decision.allow_once, once.decision);
    try testing.expectEqual(control.Decision.allow_always, control.parseApprove("/approve a1b2c3 allow-always").?.decision);
    try testing.expectEqual(control.Decision.deny, control.parseApprove("  /approve   a1b2c3   deny ").?.decision);
    // A bare /approve, or no decision, approves nothing.
    try testing.expect(control.parseApprove("/approve") == null);
    try testing.expect(control.parseApprove("/approve a1b2c3") == null);
    try testing.expect(control.parseApprove("/approve a1b2c3 maybe") == null);
    try testing.expect(control.parseApprove("/approved a1b2c3 deny") == null);
}

test "parseAnswer reads the terminal's y / a / n" {
    try testing.expectEqual(control.Decision.allow_once, control.parseAnswer("y").?);
    try testing.expectEqual(control.Decision.allow_once, control.parseAnswer("Yes\r").?);
    try testing.expectEqual(control.Decision.allow_always, control.parseAnswer("a").?);
    try testing.expectEqual(control.Decision.allow_always, control.parseAnswer("always").?);
    try testing.expectEqual(control.Decision.deny, control.parseAnswer("n").?);
    try testing.expectEqual(control.Decision.deny, control.parseAnswer("").?);
    try testing.expect(control.parseAnswer("what?") == null);
}

// ── the bash tool ──────────────────────────────────────────────────────────

fn stopSoon() void {
    fsio.sleepNs(300 * std.time.ns_per_ms);
    control.requestStop();
}

test "stop kills a bash command that is still running" {
    control.beginRun();
    const long = if (builtin.os.tag == .windows) "ping -n 30 127.0.0.1" else "sleep 30";
    const t = try std.Thread.spawn(.{}, stopSoon, .{});
    defer t.join();
    const start = fsio.monoNs();
    const out = try bash.execute(testing.allocator, long);
    defer testing.allocator.free(out);
    const secs = @as(f64, @floatFromInt(fsio.monoNs() - start)) / std.time.ns_per_s;
    try testing.expect(secs < 10);
    try testing.expect(std.mem.indexOf(u8, out, "[stopped by the user]") != null);
    control.beginRun();
}

test "a bash command nobody stops runs to the end as before" {
    control.beginRun();
    const out = try bash.execute(testing.allocator, "echo still-works");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "still-works") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stopped") == null);
}
