// Copyright The Fantastic Planet - By David Clabaugh
//
// access.zig — who may reach the agent through --chat.
//
// A chat message ends in an agent that can run bash on this host, so a sender
// is untrusted until the operator says otherwise. The rules are OpenClaw's
// (docs/gateway/security, docs/channels/pairing, docs/channels/groups), with
// the same defaults:
//
//   DIRECT MESSAGES — WINTERMOLT_CHAT_DM_POLICY
//     pairing   (default) an unknown sender gets a one-hour code and is
//               ignored until `wintermolt --pairing approve <platform> <code>`
//     allowlist only WINTERMOLT_CHAT_ALLOW_FROM; no handshake
//     open      anyone
//     disabled  no direct message is processed
//
//   GROUPS — WINTERMOLT_CHAT_GROUP_POLICY, checked in this order
//     disabled  -> drop
//     allowlist (default) the group must be in WINTERMOLT_CHAT_GROUPS, and the
//               sender in WINTERMOLT_CHAT_GROUP_ALLOW_FROM (unset: falls back
//               to WINTERMOLT_CHAT_ALLOW_FROM — never to pairing approvals,
//               which grant direct messages only)
//     open      any group, any member
//     then, unless WINTERMOLT_CHAT_REQUIRE_MENTION=0, the bot must be mentioned
//
// Entries are "platform:id", comma separated, or "*" for everyone. Only the
// first ':' splits, so "matrix:@alice:example.org" is one Matrix user. A group
// entry matches the chat's channel ID or its guild (a Discord server, a Zulip
// stream), so one entry can admit a whole server.
//
// A value this file does not know is a startup error, not a default: a typo in
// a security setting must not quietly become the permissive reading of it.

const std = @import("std");
const compat = @import("../compat.zig");
const fsio = @import("../fsio.zig");
const device_pairing = @import("../gateway/pairing.zig");

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

pub const DmPolicy = enum { pairing, allowlist, open, disabled };
pub const GroupPolicy = enum { allowlist, open, disabled };
pub const ChatType = enum { direct, group };

pub const Policy = struct {
    dm: DmPolicy = .pairing,
    group: GroupPolicy = .allowlist,
    require_mention: bool = true,
    allow_from: []const u8 = "",
    groups: []const u8 = "",
    /// null = not set, so group senders fall back to allow_from.
    group_allow_from: ?[]const u8 = null,
};

/// The raw settings, kept apart from the environment so tests can feed them.
pub const Env = struct {
    dm_policy: ?[]const u8 = null,
    allow_from: ?[]const u8 = null,
    group_policy: ?[]const u8 = null,
    groups: ?[]const u8 = null,
    group_allow_from: ?[]const u8 = null,
    require_mention: ?[]const u8 = null,

    pub fn read() Env {
        return .{
            .dm_policy = compat.getenv("WINTERMOLT_CHAT_DM_POLICY"),
            .allow_from = compat.getenv("WINTERMOLT_CHAT_ALLOW_FROM"),
            .group_policy = compat.getenv("WINTERMOLT_CHAT_GROUP_POLICY"),
            .groups = compat.getenv("WINTERMOLT_CHAT_GROUPS"),
            .group_allow_from = compat.getenv("WINTERMOLT_CHAT_GROUP_ALLOW_FROM"),
            .require_mention = compat.getenv("WINTERMOLT_CHAT_REQUIRE_MENTION"),
        };
    }
};

pub const PolicyError = error{ InvalidDmPolicy, InvalidGroupPolicy, InvalidRequireMention };

pub fn parsePolicy(env: Env) PolicyError!Policy {
    var p: Policy = .{};
    if (env.dm_policy) |v| p.dm = std.meta.stringToEnum(DmPolicy, v) orelse return error.InvalidDmPolicy;
    if (env.group_policy) |v| p.group = std.meta.stringToEnum(GroupPolicy, v) orelse return error.InvalidGroupPolicy;
    if (env.require_mention) |v| {
        if (std.mem.eql(u8, v, "1")) {
            p.require_mention = true;
        } else if (std.mem.eql(u8, v, "0")) {
            p.require_mention = false;
        } else return error.InvalidRequireMention;
    }
    if (env.allow_from) |v| p.allow_from = v;
    if (env.groups) |v| p.groups = v;
    p.group_allow_from = env.group_allow_from;
    return p;
}

/// True when `list` has "*" or the entry "platform:id".
pub fn listed(list: []const u8, platform: []const u8, id: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, entry, "*")) return true;
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse continue;
        if (std.mem.eql(u8, entry[0..colon], platform) and std.mem.eql(u8, entry[colon + 1 ..], id)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The decision
// ---------------------------------------------------------------------------

/// What the sidecar said about a message, as far as access is concerned.
pub const Inbound = struct {
    platform: []const u8,
    from: []const u8,
    channel: []const u8,
    guild: ?[]const u8 = null,
    /// null when the adapter did not say: such a message is dropped, because
    /// either guess opens something the operator did not.
    chat_type: ?ChatType,
    mentioned: bool = false,
};

pub const Drop = enum {
    unknown_chat_type,
    dm_disabled,
    dm_not_allowed,
    group_disabled,
    group_not_allowed,
    group_sender_not_allowed,
    not_mentioned,

    pub fn describe(self: Drop) []const u8 {
        return switch (self) {
            .unknown_chat_type => "the adapter did not say whether this is a direct message or a group",
            .dm_disabled => "direct messages are disabled (WINTERMOLT_CHAT_DM_POLICY=disabled)",
            .dm_not_allowed => "sender is not in WINTERMOLT_CHAT_ALLOW_FROM",
            .group_disabled => "groups are disabled (WINTERMOLT_CHAT_GROUP_POLICY=disabled)",
            .group_not_allowed => "group is not in WINTERMOLT_CHAT_GROUPS",
            .group_sender_not_allowed => "sender is not allowed in groups (WINTERMOLT_CHAT_GROUP_ALLOW_FROM, else WINTERMOLT_CHAT_ALLOW_FROM)",
            .not_mentioned => "the bot was not mentioned",
        };
    }
};

pub const Verdict = union(enum) {
    /// Hand the message to the agent.
    process,
    /// Unknown direct sender under the pairing policy: issue a code.
    pair,
    drop: Drop,
};

/// `approved` is whether the pairing store has this sender. It only counts
/// under the pairing policy, and only for direct messages.
pub fn decide(p: *const Policy, m: Inbound, approved: bool) Verdict {
    const chat_type = m.chat_type orelse return .{ .drop = .unknown_chat_type };
    switch (chat_type) {
        .direct => {
            const in_list = listed(p.allow_from, m.platform, m.from);
            return switch (p.dm) {
                .disabled => .{ .drop = .dm_disabled },
                .open => .process,
                .allowlist => if (in_list) .process else .{ .drop = .dm_not_allowed },
                .pairing => if (in_list or approved) .process else .pair,
            };
        },
        .group => {
            switch (p.group) {
                .disabled => return .{ .drop = .group_disabled },
                .open => {},
                .allowlist => {
                    const group_in = listed(p.groups, m.platform, m.channel) or
                        (if (m.guild) |g| listed(p.groups, m.platform, g) else false);
                    if (!group_in) return .{ .drop = .group_not_allowed };
                    const senders = p.group_allow_from orelse p.allow_from;
                    if (!listed(senders, m.platform, m.from)) return .{ .drop = .group_sender_not_allowed };
                },
            }
            if (p.require_mention and !m.mentioned) return .{ .drop = .not_mentioned };
            return .process;
        },
    }
}

// ---------------------------------------------------------------------------
// Pairing store — ~/.wintermolt/chat_access.db
// ---------------------------------------------------------------------------
//
// SQLite, as OpenClaw keeps it, because two processes share it: the --chat
// process issues codes and reads approvals, and `wintermolt --pairing approve`
// writes them from another terminal. A busy timeout covers the overlap.

/// Same alphabet and length as device pairing (gateway/pairing.zig): no
/// confusable characters, since the requester types the code to the operator.
pub const CODE_LEN = device_pairing.CODE_LEN;
pub const CODE_ALPHABET = device_pairing.CODE_ALPHABET;
/// OpenClaw's numbers: a code lives one hour, and a platform holds at most
/// three pending requests, so a stranger cannot flood the operator's list.
pub const CODE_TTL_SECONDS: i64 = 3600;
pub const MAX_PENDING_PER_PLATFORM = 3;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*[*:0]const u8) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, value: [*]const u8, n: c_int, destructor: isize) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, col: c_int) i64;
extern fn sqlite3_changes(db: *sqlite3) c_int;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_CONSTRAINT: c_int = 19;
const SQLITE_TRANSIENT: isize = -1;

pub const StoreError = error{ OpenFailed, QueryFailed, NoRandomness, NoHomeDir, OutOfMemory };

pub const PairingOutcome = union(enum) {
    /// A new request: send this code to the requester.
    issued: [CODE_LEN]u8,
    /// A live request exists; its code was already sent. Stay quiet.
    pending,
    /// The platform already has MAX_PENDING_PER_PLATFORM live requests.
    full,
};

pub const Store = struct {
    db: *sqlite3,

    pub fn open(path: [*:0]const u8) StoreError!Store {
        var db: ?*sqlite3 = null;
        if (sqlite3_open(path, &db) != SQLITE_OK) {
            if (db) |d| _ = sqlite3_close(d);
            return error.OpenFailed;
        }
        var self = Store{ .db = db.? };
        errdefer self.close();
        _ = sqlite3_busy_timeout(self.db, 2000);
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS pairing_requests (
            \\  platform TEXT NOT NULL, sender TEXT NOT NULL, sender_name TEXT,
            \\  code TEXT NOT NULL, created_at INTEGER NOT NULL,
            \\  PRIMARY KEY (platform, sender), UNIQUE (platform, code));
            \\CREATE TABLE IF NOT EXISTS allowed_senders (
            \\  platform TEXT NOT NULL, sender TEXT NOT NULL, sender_name TEXT,
            \\  approved_at INTEGER NOT NULL, PRIMARY KEY (platform, sender));
        );
        return self;
    }

    /// ~/.wintermolt/chat_access.db, creating the directory if needed.
    pub fn openDefault(alloc: std.mem.Allocator) StoreError!Store {
        const home = compat.getenv("HOME") orelse compat.getenv("USERPROFILE") orelse return error.NoHomeDir;
        const dir = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
        defer alloc.free(dir);
        fsio.makePath(dir) catch return error.OpenFailed;
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/chat_access.db", .{dir}, 0);
        defer alloc.free(path);
        return open(path.ptr);
    }

    pub fn close(self: *Store) void {
        _ = sqlite3_close(self.db);
    }

    pub fn isApproved(self: *Store, platform: []const u8, sender: []const u8) StoreError!bool {
        const stmt = try self.prepare("SELECT 1 FROM allowed_senders WHERE platform = ?1 AND sender = ?2;");
        defer _ = sqlite3_finalize(stmt);
        bindText(stmt, 1, platform);
        bindText(stmt, 2, sender);
        return switch (sqlite3_step(stmt)) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => error.QueryFailed,
        };
    }

    pub fn requestPairing(
        self: *Store,
        platform: []const u8,
        sender: []const u8,
        sender_name: ?[]const u8,
        now: i64,
    ) StoreError!PairingOutcome {
        try self.pruneExpired(now);
        {
            const stmt = try self.prepare("SELECT 1 FROM pairing_requests WHERE platform = ?1 AND sender = ?2;");
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, platform);
            bindText(stmt, 2, sender);
            switch (sqlite3_step(stmt)) {
                SQLITE_ROW => return .pending,
                SQLITE_DONE => {},
                else => return error.QueryFailed,
            }
        }
        {
            const stmt = try self.prepare("SELECT COUNT(*) FROM pairing_requests WHERE platform = ?1;");
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, platform);
            if (sqlite3_step(stmt) != SQLITE_ROW) return error.QueryFailed;
            if (sqlite3_column_int64(stmt, 0) >= MAX_PENDING_PER_PLATFORM) return .full;
        }
        // UNIQUE (platform, code) turns a collision into a retry rather than
        // two requesters sharing one code. At 25^8 codes it does not happen in
        // practice; the loop is there so it cannot happen at all.
        var attempt: usize = 0;
        while (attempt < 4) : (attempt += 1) {
            const code = try mintCode();
            const stmt = try self.prepare(
                "INSERT INTO pairing_requests (platform, sender, sender_name, code, created_at) VALUES (?1, ?2, ?3, ?4, ?5);",
            );
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, platform);
            bindText(stmt, 2, sender);
            if (sender_name) |n| bindText(stmt, 3, n);
            bindText(stmt, 4, &code);
            _ = sqlite3_bind_int64(stmt, 5, now);
            switch (sqlite3_step(stmt)) {
                SQLITE_DONE => return .{ .issued = code },
                SQLITE_CONSTRAINT => continue,
                else => return error.QueryFailed,
            }
        }
        return error.QueryFailed;
    }

    /// Moves a live request into the allowlist. Returns the approved sender
    /// (caller frees), or null when `code` names no live request on `platform`.
    pub fn approve(
        self: *Store,
        alloc: std.mem.Allocator,
        platform: []const u8,
        code: []const u8,
        now: i64,
    ) StoreError!?[]u8 {
        try self.pruneExpired(now);
        var upper: [CODE_LEN]u8 = undefined;
        if (code.len != CODE_LEN) return null;
        for (code, 0..) |c, i| upper[i] = std.ascii.toUpper(c);

        const sender = blk: {
            const stmt = try self.prepare("SELECT sender, sender_name FROM pairing_requests WHERE platform = ?1 AND code = ?2;");
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, platform);
            bindText(stmt, 2, &upper);
            switch (sqlite3_step(stmt)) {
                SQLITE_ROW => {},
                SQLITE_DONE => return null,
                else => return error.QueryFailed,
            }
            const s = try alloc.dupe(u8, columnText(stmt, 0));
            errdefer alloc.free(s);
            const name = try alloc.dupe(u8, columnText(stmt, 1));
            break :blk .{ s, name };
        };
        errdefer alloc.free(sender[0]);
        defer alloc.free(sender[1]);

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        {
            const stmt = try self.prepare(
                "INSERT OR REPLACE INTO allowed_senders (platform, sender, sender_name, approved_at) VALUES (?1, ?2, ?3, ?4);",
            );
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, platform);
            bindText(stmt, 2, sender[0]);
            if (sender[1].len > 0) bindText(stmt, 3, sender[1]);
            _ = sqlite3_bind_int64(stmt, 4, now);
            if (sqlite3_step(stmt) != SQLITE_DONE) return error.QueryFailed;
        }
        {
            const stmt = try self.prepare("DELETE FROM pairing_requests WHERE platform = ?1 AND sender = ?2;");
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, platform);
            bindText(stmt, 2, sender[0]);
            if (sqlite3_step(stmt) != SQLITE_DONE) return error.QueryFailed;
        }
        try self.exec("COMMIT;");
        return sender[0];
    }

    /// True when the sender was in the allowlist.
    pub fn revoke(self: *Store, platform: []const u8, sender: []const u8) StoreError!bool {
        const stmt = try self.prepare("DELETE FROM allowed_senders WHERE platform = ?1 AND sender = ?2;");
        defer _ = sqlite3_finalize(stmt);
        bindText(stmt, 1, platform);
        bindText(stmt, 2, sender);
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.QueryFailed;
        return sqlite3_changes(self.db) > 0;
    }

    /// Live requests, then approved senders; `platform` null lists every one.
    pub fn writeList(self: *Store, w: *std.Io.Writer, platform: ?[]const u8, now: i64) !void {
        try self.pruneExpired(now);
        const filter = platform orelse "";
        try w.writeAll("Pending (code expires an hour after the request):\n");
        {
            const stmt = try self.prepare(
                "SELECT platform, code, sender, sender_name, created_at FROM pairing_requests " ++
                    "WHERE ?1 = '' OR platform = ?1 ORDER BY created_at;",
            );
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, filter);
            var n: usize = 0;
            while (sqlite3_step(stmt) == SQLITE_ROW) : (n += 1) {
                const left = CODE_TTL_SECONDS - (now - sqlite3_column_int64(stmt, 4));
                try w.print("  {s}  {s}  {s}", .{ columnText(stmt, 0), columnText(stmt, 1), columnText(stmt, 2) });
                const name = columnText(stmt, 3);
                if (name.len > 0) try w.print(" ({s})", .{name});
                try w.print("  {d} min left\n", .{@divTrunc(left + 59, 60)});
            }
            if (n == 0) try w.writeAll("  none\n");
        }
        try w.writeAll("Approved:\n");
        {
            const stmt = try self.prepare(
                "SELECT platform, sender, sender_name FROM allowed_senders " ++
                    "WHERE ?1 = '' OR platform = ?1 ORDER BY platform, approved_at;",
            );
            defer _ = sqlite3_finalize(stmt);
            bindText(stmt, 1, filter);
            var n: usize = 0;
            while (sqlite3_step(stmt) == SQLITE_ROW) : (n += 1) {
                try w.print("  {s}:{s}", .{ columnText(stmt, 0), columnText(stmt, 1) });
                const name = columnText(stmt, 2);
                if (name.len > 0) try w.print(" ({s})", .{name});
                try w.writeByte('\n');
            }
            if (n == 0) try w.writeAll("  none\n");
        }
    }

    fn pruneExpired(self: *Store, now: i64) StoreError!void {
        const stmt = try self.prepare("DELETE FROM pairing_requests WHERE created_at <= ?1;");
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, now - CODE_TTL_SECONDS);
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.QueryFailed;
    }

    fn exec(self: *Store, sql: [*:0]const u8) StoreError!void {
        if (sqlite3_exec(self.db, sql, null, null, null) != SQLITE_OK) return error.QueryFailed;
    }

    fn prepare(self: *Store, sql: [*:0]const u8) StoreError!*sqlite3_stmt {
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return error.QueryFailed;
        return stmt.?;
    }
};

fn bindText(stmt: *sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), SQLITE_TRANSIENT);
}

fn columnText(stmt: *sqlite3_stmt, col: c_int) []const u8 {
    const p = sqlite3_column_text(stmt, col) orelse return "";
    return std.mem.span(p);
}

/// What an unknown direct sender is sent: OpenClaw's wording
/// (src/pairing/pairing-messages.ts), as plain lines, since IRC and SMS
/// render no markdown. Caller frees.
pub fn pairingReply(alloc: std.mem.Allocator, platform: []const u8, sender: []const u8, code: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\Wintermolt: access not configured.
        \\
        \\Your {s} ID: {s}
        \\Pairing code: {s} (valid for one hour)
        \\
        \\Ask the bot owner to approve with:
        \\wintermolt --pairing approve {s} {s}
    , .{ platform, sender, code, platform, code });
}

fn mintCode() StoreError![CODE_LEN]u8 {
    var raw: [CODE_LEN]u8 = undefined;
    if (!fsio.randomBytes(&raw)) return error.NoRandomness;
    var code: [CODE_LEN]u8 = undefined;
    for (raw, 0..) |b, i| code[i] = CODE_ALPHABET[b % CODE_ALPHABET.len];
    return code;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn dm(platform: []const u8, from: []const u8) Inbound {
    return .{ .platform = platform, .from = from, .channel = from, .chat_type = .direct };
}

fn group(platform: []const u8, from: []const u8, channel: []const u8, mentioned: bool) Inbound {
    return .{ .platform = platform, .from = from, .channel = channel, .chat_type = .group, .mentioned = mentioned };
}

test "defaults: an unknown direct sender is paired, an approved one is processed" {
    const p = try parsePolicy(.{});
    try testing.expectEqual(Verdict.pair, decide(&p, dm("telegram", "111"), false));
    try testing.expectEqual(Verdict.process, decide(&p, dm("telegram", "111"), true));
}

test "defaults: a group is dropped until it is listed" {
    const p = try parsePolicy(.{});
    try testing.expectEqual(Verdict{ .drop = .group_not_allowed }, decide(&p, group("telegram", "111", "-100", true), true));
}

test "allow_from admits a direct sender under every policy but disabled" {
    inline for (.{ "pairing", "allowlist", "open" }) |name| {
        const p = try parsePolicy(.{ .dm_policy = name, .allow_from = "telegram:111" });
        try testing.expectEqual(Verdict.process, decide(&p, dm("telegram", "111"), false));
    }
    const off = try parsePolicy(.{ .dm_policy = "disabled", .allow_from = "*" });
    try testing.expectEqual(Verdict{ .drop = .dm_disabled }, decide(&off, dm("telegram", "111"), true));
}

test "allowlist ignores pairing approvals; open admits anyone" {
    const strict = try parsePolicy(.{ .dm_policy = "allowlist" });
    try testing.expectEqual(Verdict{ .drop = .dm_not_allowed }, decide(&strict, dm("slack", "U1"), true));
    const open = try parsePolicy(.{ .dm_policy = "open" });
    try testing.expectEqual(Verdict.process, decide(&open, dm("slack", "U1"), false));
}

test "an entry is platform-scoped: the same ID on another platform is not listed" {
    const p = try parsePolicy(.{ .dm_policy = "allowlist", .allow_from = "telegram:111" });
    try testing.expectEqual(Verdict{ .drop = .dm_not_allowed }, decide(&p, dm("discord", "111"), false));
}

test "only the first colon splits an entry" {
    try testing.expect(listed("matrix:@alice:example.org", "matrix", "@alice:example.org"));
    try testing.expect(!listed("matrix:@alice:example.org", "matrix", "@alice"));
    try testing.expect(listed(" telegram:1 , matrix:@a:b ", "matrix", "@a:b"));
    try testing.expect(!listed("", "telegram", "1"));
    try testing.expect(!listed("telegram", "telegram", ""));
}

test "group allowlist: group, then sender, then mention" {
    const p = try parsePolicy(.{ .groups = "telegram:-100", .allow_from = "telegram:111" });
    try testing.expectEqual(Verdict{ .drop = .group_sender_not_allowed }, decide(&p, group("telegram", "222", "-100", true), false));
    try testing.expectEqual(Verdict{ .drop = .not_mentioned }, decide(&p, group("telegram", "111", "-100", false), false));
    try testing.expectEqual(Verdict.process, decide(&p, group("telegram", "111", "-100", true), false));
}

test "group senders never inherit pairing approvals" {
    const p = try parsePolicy(.{ .groups = "telegram:-100" });
    try testing.expectEqual(Verdict{ .drop = .group_sender_not_allowed }, decide(&p, group("telegram", "111", "-100", true), true));
}

test "group_allow_from replaces allow_from for groups, and * admits every member" {
    const p = try parsePolicy(.{ .groups = "telegram:-100", .allow_from = "telegram:111", .group_allow_from = "*" });
    try testing.expectEqual(Verdict.process, decide(&p, group("telegram", "999", "-100", true), false));
    const narrow = try parsePolicy(.{ .groups = "telegram:-100", .allow_from = "telegram:111", .group_allow_from = "telegram:222" });
    try testing.expectEqual(Verdict{ .drop = .group_sender_not_allowed }, decide(&narrow, group("telegram", "111", "-100", true), false));
}

test "a guild entry admits every channel in it" {
    const p = try parsePolicy(.{ .groups = "discord:G1", .group_allow_from = "*" });
    var m = group("discord", "U1", "C7", true);
    m.guild = "G1";
    try testing.expectEqual(Verdict.process, decide(&p, m, false));
    m.guild = "G2";
    try testing.expectEqual(Verdict{ .drop = .group_not_allowed }, decide(&p, m, false));
}

test "open groups still need a mention unless it is turned off" {
    const p = try parsePolicy(.{ .group_policy = "open" });
    try testing.expectEqual(Verdict{ .drop = .not_mentioned }, decide(&p, group("irc", "nick", "#c", false), false));
    try testing.expectEqual(Verdict.process, decide(&p, group("irc", "nick", "#c", true), false));
    const chatty = try parsePolicy(.{ .group_policy = "open", .require_mention = "0" });
    try testing.expectEqual(Verdict.process, decide(&chatty, group("irc", "nick", "#c", false), false));
    const off = try parsePolicy(.{ .group_policy = "disabled" });
    try testing.expectEqual(Verdict{ .drop = .group_disabled }, decide(&off, group("irc", "nick", "#c", true), false));
}

test "a message whose chat type is unknown is dropped under every policy" {
    const p = try parsePolicy(.{ .dm_policy = "open", .group_policy = "open", .require_mention = "0" });
    const m = Inbound{ .platform = "x", .from = "1", .channel = "1", .chat_type = null };
    try testing.expectEqual(Verdict{ .drop = .unknown_chat_type }, decide(&p, m, true));
}

test "an unknown setting is an error, not a default" {
    try testing.expectError(error.InvalidDmPolicy, parsePolicy(.{ .dm_policy = "opne" }));
    try testing.expectError(error.InvalidGroupPolicy, parsePolicy(.{ .group_policy = "all" }));
    try testing.expectError(error.InvalidRequireMention, parsePolicy(.{ .require_mention = "no" }));
}

test "store: a code is issued once, then the request stays quiet until approved" {
    var s = try Store.open(":memory:");
    defer s.close();
    const now: i64 = 1_000_000;
    const first = try s.requestPairing("telegram", "111", "alice", now);
    const code = switch (first) {
        .issued => |c| c,
        else => return error.TestExpectedIssued,
    };
    for (code) |c| try testing.expect(std.mem.indexOfScalar(u8, CODE_ALPHABET, c) != null);
    try testing.expectEqual(PairingOutcome.pending, try s.requestPairing("telegram", "111", "alice", now + 60));
    try testing.expect(!try s.isApproved("telegram", "111"));

    // Wrong platform, wrong code: nothing approved.
    try testing.expect((try s.approve(testing.allocator, "discord", &code, now + 120)) == null);
    try testing.expect((try s.approve(testing.allocator, "telegram", "AAAAAAAA", now + 120)) == null);

    var lower: [CODE_LEN]u8 = undefined;
    for (code, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const sender = (try s.approve(testing.allocator, "telegram", &lower, now + 120)).?;
    defer testing.allocator.free(sender);
    try testing.expectEqualStrings("111", sender);
    try testing.expect(try s.isApproved("telegram", "111"));
    try testing.expect(!try s.isApproved("discord", "111"));

    // The code is spent.
    try testing.expect((try s.approve(testing.allocator, "telegram", &code, now + 180)) == null);

    try testing.expect(try s.revoke("telegram", "111"));
    try testing.expect(!try s.isApproved("telegram", "111"));
    try testing.expect(!try s.revoke("telegram", "111"));
}

test "store: a code expires after an hour, and a new request gets a new code" {
    var s = try Store.open(":memory:");
    defer s.close();
    const now: i64 = 1_000_000;
    const code = (try s.requestPairing("slack", "U1", null, now)).issued;
    try testing.expect((try s.approve(testing.allocator, "slack", &code, now + CODE_TTL_SECONDS)) == null);
    switch (try s.requestPairing("slack", "U1", null, now + CODE_TTL_SECONDS)) {
        .issued => {},
        else => return error.TestExpectedIssued,
    }
}

test "store: three live requests per platform, the fourth is refused" {
    var s = try Store.open(":memory:");
    defer s.close();
    const now: i64 = 1_000_000;
    for ([_][]const u8{ "1", "2", "3" }) |id| {
        switch (try s.requestPairing("telegram", id, null, now)) {
            .issued => {},
            else => return error.TestExpectedIssued,
        }
    }
    try testing.expectEqual(PairingOutcome.full, try s.requestPairing("telegram", "4", null, now));
    // Another platform has its own three.
    switch (try s.requestPairing("discord", "4", null, now)) {
        .issued => {},
        else => return error.TestExpectedIssued,
    }
    // Once one expires there is room again.
    switch (try s.requestPairing("telegram", "4", null, now + CODE_TTL_SECONDS)) {
        .issued => {},
        else => return error.TestExpectedIssued,
    }
}

test "the pairing reply names the sender and the exact approve command" {
    const r = try pairingReply(testing.allocator, "telegram", "111", "ACDE3467");
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Your telegram ID: 111\n") != null);
    try testing.expect(std.mem.endsWith(u8, r, "\nwintermolt --pairing approve telegram ACDE3467"));
}

test "store: the list shows live requests and approved senders" {
    var s = try Store.open(":memory:");
    defer s.close();
    const now: i64 = 1_000_000;
    const code = (try s.requestPairing("telegram", "111", "alice", now)).issued;
    _ = try s.requestPairing("discord", "222", null, now);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeList(&w, "telegram", now + 60);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, &code) != null);
    try testing.expect(std.mem.indexOf(u8, out, "(alice)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "222") == null);
    try testing.expect(std.mem.indexOf(u8, out, "59 min left") != null);
}
