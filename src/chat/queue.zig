// Copyright The Fantastic Planet - By David Clabaugh
//
// queue.zig -- --chat's messages, waiting their turn, and the commands a chat
// message can be.
//
// --chat reads the sidecar on one thread and runs replies on another, so a
// slow reply no longer stops every platform's messages from being read: they
// wait here, in order (OpenClaw's `followup` queue mode). /stop is acted on
// by the reader the moment it arrives, which is why it cannot wait in line.
// Replies stay one at a time; the tools module's globals are per process.

const std = @import("std");
const control = @import("../agent/control.zig");
const fsio = @import("../fsio.zig");

/// A chat message that is a wintermolt command rather than text for the model.
pub const Command = enum { stop, new, status, help, approve };

/// By its first word, OpenClaw's way: "/stop please" stops, "please /stop" is text.
pub fn command(text: []const u8) ?Command {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const word = it.next() orelse return null;
    const names = [_]struct { []const u8, Command }{
        .{ "/stop", .stop },     .{ "/new", .new },   .{ "/reset", .new },
        .{ "/status", .status }, .{ "/help", .help }, .{ "/approve", .approve },
    };
    for (names) |n| if (std.mem.eql(u8, word, n[0])) return n[1];
    return null;
}

pub const help_text =
    \\wintermolt commands:
    \\/stop - stop the reply that is running, and drop your messages still waiting
    \\/new (or /reset) - start this conversation over
    \\/status - is a reply running, and how many messages wait
    \\/approve <id> allow-once|allow-always|deny - answer a request to run a command
;

/// One message waiting for its reply, with everything the reply needs. Owns
/// its strings: the sidecar's buffer is reused by the next read.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    platform: []const u8,
    from: []const u8,
    channel: []const u8,
    thread_id: ?[]const u8 = null,
    text: []const u8,
    agent_id: []const u8,
    session_key: []const u8,
    /// The agent's own DM session: MEMORY.md is in its prompt.
    private: bool = false,
    is_new: bool = false,

    pub const Fields = struct {
        platform: []const u8,
        from: []const u8,
        channel: []const u8,
        thread_id: ?[]const u8 = null,
        text: []const u8,
        agent_id: []const u8,
        session_key: []const u8,
        private: bool = false,
        is_new: bool = false,
    };

    pub fn create(gpa: std.mem.Allocator, f: Fields) !*Job {
        const self = try gpa.create(Job);
        self.arena = .init(gpa);
        errdefer {
            self.arena.deinit();
            gpa.destroy(self);
        }
        const a = self.arena.allocator();
        self.platform = try a.dupe(u8, f.platform);
        self.from = try a.dupe(u8, f.from);
        self.channel = try a.dupe(u8, f.channel);
        self.thread_id = if (f.thread_id) |t| try a.dupe(u8, t) else null;
        self.text = try a.dupe(u8, f.text);
        self.agent_id = try a.dupe(u8, f.agent_id);
        self.session_key = try a.dupe(u8, f.session_key);
        self.private = f.private;
        self.is_new = f.is_new;
        return self;
    }

    pub fn destroy(self: *Job) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Queue = struct {
    gpa: std.mem.Allocator,
    /// A spin lock: each critical section is an append, a remove or a compare.
    locked: std.atomic.Value(bool) = .init(false),
    jobs: std.ArrayList(*Job) = .empty,
    /// The session whose reply runs now, owned by the job the worker holds.
    current: ?[]const u8 = null,
    closed: bool = false,
    /// OpenClaw's default cap.
    cap: usize = 20,

    pub fn init(gpa: std.mem.Allocator) Queue {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Queue) void {
        for (self.jobs.items) |j| j.destroy();
        self.jobs.deinit(self.gpa);
    }

    fn lock(self: *Queue) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Queue) void {
        self.locked.store(false, .release);
    }

    /// False when the queue is full: the caller still owns `job`.
    pub fn push(self: *Queue, job: *Job) !bool {
        self.lock();
        defer self.unlock();
        if (self.jobs.items.len >= self.cap) return false;
        try self.jobs.append(self.gpa, job);
        return true;
    }

    /// The next message, waiting for one; null once closed and empty. Its
    /// session counts as running until finish(). The caller destroys it.
    pub fn pop(self: *Queue) ?*Job {
        while (true) {
            self.lock();
            if (self.jobs.items.len > 0) {
                const j = self.jobs.orderedRemove(0);
                self.current = j.session_key;
                // Here, under the lock: a /stop that sees this session running
                // must not be cleared by the reply starting a moment later.
                control.beginRun();
                self.unlock();
                return j;
            }
            const done = self.closed;
            self.unlock();
            if (done) return null;
            fsio.sleepNs(20 * std.time.ns_per_ms);
        }
    }

    /// The reply finished. Call before destroying its job.
    pub fn finish(self: *Queue) void {
        self.lock();
        defer self.unlock();
        self.current = null;
        control.endRun();
    }

    pub fn close(self: *Queue) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
    }

    pub fn isRunning(self: *Queue, session_key: []const u8) bool {
        self.lock();
        defer self.unlock();
        return if (self.current) |c| std.mem.eql(u8, c, session_key) else false;
    }

    pub fn waiting(self: *Queue) usize {
        self.lock();
        defer self.unlock();
        return self.jobs.items.len;
    }

    /// /stop from `session_key`: stop its reply if it is the one running, and
    /// drop its messages still waiting. Other sessions are not touched.
    pub fn stopSession(self: *Queue, session_key: []const u8) struct { was_running: bool, dropped: usize } {
        self.lock();
        defer self.unlock();
        const running = if (self.current) |c| std.mem.eql(u8, c, session_key) else false;
        if (running) control.requestStop();
        var dropped: usize = 0;
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (std.mem.eql(u8, self.jobs.items[i].session_key, session_key)) {
                self.jobs.orderedRemove(i).destroy();
                dropped += 1;
            } else i += 1;
        }
        return .{ .was_running = running, .dropped = dropped };
    }
};

const testing = std.testing;

fn makeJob(gpa: std.mem.Allocator, key: []const u8, text: []const u8) !*Job {
    return Job.create(gpa, .{ .platform = "discord", .from = "U1", .channel = "C1", .text = text, .agent_id = "main", .session_key = key });
}

test "chat commands are recognised by their first word only" {
    try testing.expectEqual(Command.stop, command("/stop").?);
    try testing.expectEqual(Command.stop, command("  /stop please").?);
    try testing.expectEqual(Command.new, command("/new").?);
    try testing.expectEqual(Command.new, command("/reset").?);
    try testing.expectEqual(Command.status, command("/status").?);
    try testing.expectEqual(Command.help, command("/help").?);
    try testing.expectEqual(Command.approve, command("/approve a1b2c3 deny").?);
    // Everything else is for the model, as before.
    try testing.expect(command("/stopped") == null);
    try testing.expect(command("please /stop") == null);
    try testing.expect(command("/model claude") == null);
    try testing.expect(command("hello") == null);
}

test "the queue hands out messages in order and says which session is running" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    try testing.expect(try q.push(try makeJob(testing.allocator, "s1", "first")));
    try testing.expect(try q.push(try makeJob(testing.allocator, "s2", "second")));
    try testing.expectEqual(@as(usize, 2), q.waiting());

    const a = q.pop().?;
    defer a.destroy();
    try testing.expectEqualStrings("first", a.text);
    try testing.expect(q.isRunning("s1"));
    q.finish();
    try testing.expect(!q.isRunning("s1"));

    const b = q.pop().?;
    defer b.destroy();
    try testing.expectEqualStrings("second", b.text);
    q.finish();
}

test "a full queue refuses the newest message rather than growing" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    q.cap = 2;
    try testing.expect(try q.push(try makeJob(testing.allocator, "s1", "1")));
    try testing.expect(try q.push(try makeJob(testing.allocator, "s1", "2")));
    const extra = try makeJob(testing.allocator, "s1", "3");
    try testing.expect(!try q.push(extra));
    extra.destroy();
    try testing.expectEqual(@as(usize, 2), q.waiting());
}

test "/stop stops that session's reply and drops its waiting messages, no one else's" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    try testing.expect(try q.push(try makeJob(testing.allocator, "group-a", "running")));
    try testing.expect(try q.push(try makeJob(testing.allocator, "group-a", "waiting a")));
    try testing.expect(try q.push(try makeJob(testing.allocator, "group-b", "waiting b")));
    const running = q.pop().?;
    defer running.destroy();
    control.beginRun();

    // From another session: its own reply is not running, nothing of a's is touched.
    const other = q.stopSession("group-b");
    try testing.expect(!other.was_running);
    try testing.expectEqual(@as(usize, 1), other.dropped);
    try testing.expect(!control.stopRequested());

    const mine = q.stopSession("group-a");
    try testing.expect(mine.was_running);
    try testing.expectEqual(@as(usize, 1), mine.dropped);
    try testing.expect(control.stopRequested());
    try testing.expectEqual(@as(usize, 0), q.waiting());
    q.finish();
    control.beginRun();
}

fn pushLater(q: *Queue) void {
    @import("../fsio.zig").sleepNs(50 * std.time.ns_per_ms);
    const j = makeJob(testing.allocator, "s1", "late") catch return;
    _ = q.push(j) catch j.destroy();
}

test "pop waits for a message, and returns null once the sidecar is gone" {
    var q = Queue.init(testing.allocator);
    defer q.deinit();
    const t = try std.Thread.spawn(.{}, pushLater, .{&q});
    const j = q.pop().?;
    t.join();
    defer j.destroy();
    try testing.expectEqualStrings("late", j.text);
    q.finish();
    q.close();
    try testing.expect(q.pop() == null);
}
