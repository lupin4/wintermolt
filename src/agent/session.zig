// Copyright The Fantastic Planet - By David Clabaugh
//
// session.zig — Session lifecycle manager
//
// Tracks active sessions across chat platforms with UUID-based IDs.
// Sessions bind an agent to a specific platform + channel + user context.
//
// Features:
//   - UUID-based session IDs
//   - Per-session state tracking (active, paused, ended)
//   - Send policy rules (rate limiting per session)
//   - Cross-session messaging (one session can inject messages to another)
//   - SQLite-backed persistence (~/.wintermolt/sessions.db)
//   - Lifecycle events: on_create, on_message, on_end

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// SQLite extern declarations (same pattern as storage.zig)
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*[*:0]const u8) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, value: [*]const u8, n: c_int, destructor: isize) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, col: c_int) i64;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_TRANSIENT: isize = -1;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const SessionState = enum {
    active,
    paused,
    ended,

    pub fn toString(self: SessionState) []const u8 {
        return switch (self) {
            .active => "active",
            .paused => "paused",
            .ended => "ended",
        };
    }

    pub fn fromString(s: []const u8) SessionState {
        if (std.mem.eql(u8, s, "paused")) return .paused;
        if (std.mem.eql(u8, s, "ended")) return .ended;
        return .active;
    }
};

pub const SessionInfo = struct {
    id: []const u8,
    agent_id: []const u8,
    platform: []const u8,
    channel: []const u8,
    user_id: []const u8,
    state: SessionState,
    message_count: i64,
    created_at: i64,
    last_active: i64,
};

/// Send policy rule: rate limiting per session.
pub const SendPolicy = struct {
    max_messages_per_minute: u32 = 20,
    max_message_length: usize = 8192,
    cooldown_seconds: u32 = 0,
};

// ---------------------------------------------------------------------------
// Session Manager
// ---------------------------------------------------------------------------

pub const SessionManager = struct {
    alloc: Allocator,
    db: ?*sqlite3,
    default_policy: SendPolicy,

    pub fn init(alloc: Allocator) SessionManager {
        var db: ?*sqlite3 = null;
        const db_path = getDbPath(alloc) catch null;

        if (db_path) |path| {
            const path_z = alloc.dupeZ(u8, path) catch null;
            alloc.free(path);
            if (path_z) |pz| {
                defer alloc.free(pz);
                const rc = sqlite3_open(pz.ptr, &db);
                if (rc != SQLITE_OK) {
                    if (db) |d| _ = sqlite3_close(d);
                    db = null;
                }
            }
        }

        var self = SessionManager{
            .alloc = alloc,
            .db = db,
            .default_policy = .{},
        };

        if (db != null) self.runMigrations() catch {};
        return self;
    }

    pub fn deinit(self: *SessionManager) void {
        if (self.db) |d| _ = sqlite3_close(d);
    }

    /// Get or create a session for the given context.
    /// Returns the session ID (owned). Re-uses an existing active session if one exists.
    pub fn getOrCreateSession(
        self: *SessionManager,
        agent_id: []const u8,
        platform: []const u8,
        channel: []const u8,
        user_id: []const u8,
    ) ![]u8 {
        const db = self.db orelse return error.NoDB;

        // Check for existing active session
        const find_sql =
            "SELECT id FROM sessions WHERE agent_id = ?1 AND platform = ?2 AND channel = ?3 AND user_id = ?4 AND state = 'active' " ++
            "ORDER BY last_active DESC LIMIT 1;";

        const find_stmt = try self.prepare(db, find_sql);
        defer _ = sqlite3_finalize(find_stmt);

        try self.bindText(db, find_stmt, 1, agent_id);
        try self.bindText(db, find_stmt, 2, platform);
        try self.bindText(db, find_stmt, 3, channel);
        try self.bindText(db, find_stmt, 4, user_id);

        if (sqlite3_step(find_stmt) == SQLITE_ROW) {
            const id_raw = sqlite3_column_text(find_stmt, 0);
            if (id_raw) |ptr| {
                const existing_id = try self.alloc.dupe(u8, std.mem.span(ptr));
                // Touch last_active
                self.touchSession(db, existing_id) catch {};
                return existing_id;
            }
        }

        // Create new session
        const uuid = generateUuid();
        const now = std.time.timestamp();

        const insert_sql =
            "INSERT INTO sessions (id, agent_id, platform, channel, user_id, state, message_count, created_at, last_active) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, 'active', 0, ?6, ?7);";

        const insert_stmt = try self.prepare(db, insert_sql);
        defer _ = sqlite3_finalize(insert_stmt);

        try self.bindText(db, insert_stmt, 1, &uuid);
        try self.bindText(db, insert_stmt, 2, agent_id);
        try self.bindText(db, insert_stmt, 3, platform);
        try self.bindText(db, insert_stmt, 4, channel);
        try self.bindText(db, insert_stmt, 5, user_id);
        _ = sqlite3_bind_int64(insert_stmt, 6, now);
        _ = sqlite3_bind_int64(insert_stmt, 7, now);

        const rc = sqlite3_step(insert_stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;

        return self.alloc.dupe(u8, &uuid);
    }

    /// Record a message in a session (increment count, update last_active).
    pub fn recordMessage(self: *SessionManager, session_id: []const u8) void {
        const db = self.db orelse return;
        const sql = "UPDATE sessions SET message_count = message_count + 1, last_active = ?1 WHERE id = ?2;";
        const stmt = self.prepare(db, sql) catch return;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, std.time.timestamp());
        self.bindText(db, stmt, 2, session_id) catch return;
        _ = sqlite3_step(stmt);
    }

    /// End a session (set state to 'ended').
    pub fn endSession(self: *SessionManager, session_id: []const u8) !void {
        const db = self.db orelse return error.NoDB;
        const sql = "UPDATE sessions SET state = 'ended', last_active = ?1 WHERE id = ?2;";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, std.time.timestamp());
        try self.bindText(db, stmt, 2, session_id);
        _ = sqlite3_step(stmt);
    }

    /// Pause a session.
    pub fn pauseSession(self: *SessionManager, session_id: []const u8) !void {
        const db = self.db orelse return error.NoDB;
        const sql = "UPDATE sessions SET state = 'paused' WHERE id = ?1;";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);
        try self.bindText(db, stmt, 1, session_id);
        _ = sqlite3_step(stmt);
    }

    /// Resume a paused session.
    pub fn resumeSession(self: *SessionManager, session_id: []const u8) !void {
        const db = self.db orelse return error.NoDB;
        const sql = "UPDATE sessions SET state = 'active' WHERE id = ?1 AND state = 'paused';";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);
        try self.bindText(db, stmt, 1, session_id);
        _ = sqlite3_step(stmt);
    }

    /// List active sessions. Caller owns returned slice and strings within.
    pub fn listSessions(self: *SessionManager, alloc: Allocator, limit: usize) ![]u8 {
        const db = self.db orelse return alloc.dupe(u8, "[sessions] No database connection.");

        const sql =
            "SELECT id, agent_id, platform, channel, user_id, state, message_count, created_at, last_active " ++
            "FROM sessions WHERE state != 'ended' ORDER BY last_active DESC LIMIT ?1;";

        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, @intCast(limit));

        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try w.writeAll("=== Active Sessions ===\n\n");
        var count: usize = 0;
        const now = std.time.timestamp();

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            count += 1;
            const id_str = spanCol(stmt, 0);
            const agent_str = spanCol(stmt, 1);
            const platform_str = spanCol(stmt, 2);
            const channel_str = spanCol(stmt, 3);
            const user_str = spanCol(stmt, 4);
            const state_str = spanCol(stmt, 5);
            const msg_count = sqlite3_column_int64(stmt, 6);
            const last_active = sqlite3_column_int64(stmt, 8);
            const idle_secs = now - last_active;

            try std.fmt.format(w, "  [{s}] agent:{s} ({s})\n", .{ id_str[0..@min(8, id_str.len)], agent_str, state_str });
            try std.fmt.format(w, "    {s}/{s} user:{s}\n", .{ platform_str, channel_str, user_str });
            try std.fmt.format(w, "    {d} msgs, idle {d}s\n\n", .{ msg_count, idle_secs });
        }

        if (count == 0) {
            try w.writeAll("  No active sessions.\n");
        } else {
            try std.fmt.format(w, "Total: {d} session(s)\n", .{count});
        }

        return buf.toOwnedSlice(alloc);
    }

    /// Clean up stale sessions (idle for more than timeout seconds).
    pub fn cleanupStale(self: *SessionManager, timeout_secs: i64) void {
        const db = self.db orelse return;
        const cutoff = std.time.timestamp() - timeout_secs;
        const sql = "UPDATE sessions SET state = 'ended' WHERE state = 'active' AND last_active < ?1;";
        const stmt = self.prepare(db, sql) catch return;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, cutoff);
        _ = sqlite3_step(stmt);
    }

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    fn touchSession(self: *SessionManager, db: *sqlite3, session_id: []const u8) !void {
        const sql = "UPDATE sessions SET last_active = ?1 WHERE id = ?2;";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, std.time.timestamp());
        try self.bindText(db, stmt, 2, session_id);
        _ = sqlite3_step(stmt);
    }

    fn runMigrations(self: *SessionManager) !void {
        const db = self.db orelse return error.NoDB;
        const schema =
            "PRAGMA journal_mode=WAL;" ++
            "CREATE TABLE IF NOT EXISTS sessions (" ++
            "  id            TEXT PRIMARY KEY," ++
            "  agent_id      TEXT NOT NULL DEFAULT 'main'," ++
            "  platform      TEXT NOT NULL," ++
            "  channel       TEXT NOT NULL," ++
            "  user_id       TEXT NOT NULL," ++
            "  state         TEXT NOT NULL DEFAULT 'active'," ++
            "  message_count INTEGER DEFAULT 0," ++
            "  created_at    INTEGER NOT NULL," ++
            "  last_active   INTEGER NOT NULL," ++
            "  metadata      TEXT" ++
            ");" ++
            "CREATE INDEX IF NOT EXISTS idx_sessions_lookup ON sessions(agent_id, platform, channel, user_id, state);" ++
            "CREATE INDEX IF NOT EXISTS idx_sessions_active ON sessions(state, last_active DESC);";

        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(db, schema, null, null, &errmsg);
        if (rc != SQLITE_OK) {
            if (errmsg) |msg| sqlite3_free(@ptrCast(msg));
            return error.MigrationFailed;
        }

        // v2 migration: add agent_id column to existing sessions tables that lack it
        var migrate_err: ?[*:0]u8 = null;
        _ = sqlite3_exec(db, "ALTER TABLE sessions ADD COLUMN agent_id TEXT NOT NULL DEFAULT 'main';", null, null, &migrate_err);
        if (migrate_err) |msg| sqlite3_free(@ptrCast(msg)); // ignore "duplicate column" error
    }

    fn prepare(self: *SessionManager, db: *sqlite3, sql: [*:0]const u8) !*sqlite3_stmt {
        _ = self;
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(db, sql, -1, &stmt, null);
        if (rc != SQLITE_OK or stmt == null) return error.SqlitePrepareFailed;
        return stmt.?;
    }

    fn bindText(self: *SessionManager, db: *sqlite3, stmt: *sqlite3_stmt, index: c_int, value: []const u8) !void {
        _ = self;
        _ = db;
        _ = sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), SQLITE_TRANSIENT);
    }
};

fn spanCol(stmt: *sqlite3_stmt, col: c_int) []const u8 {
    const raw = sqlite3_column_text(stmt, col);
    if (raw) |ptr| return std.mem.span(ptr);
    return "";
}

fn generateUuid() [36]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var uuid: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            uuid[pos] = '-';
            pos += 1;
        }
        uuid[pos] = hex[b >> 4];
        uuid[pos + 1] = hex[b & 0x0f];
        pos += 2;
    }
    return uuid;
}

fn getDbPath(alloc: Allocator) ![]u8 {
    const home = compat.getenv("HOME") orelse return error.NoHomeDir;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
    defer alloc.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    return std.fmt.allocPrint(alloc, "{s}/.wintermolt/sessions.db", .{home});
}
