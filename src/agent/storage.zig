// Copyright The Fantastic Planet - By David Clabaugh
//
// storage.zig — SQLite-based persistent chat history
//
// Stores conversations and messages in ~/.wintermolt/history.db using the same
// extern fn pattern as client.zig (no @cImport). Storage failures never break
// the agentic loop — all public methods are designed for catch-and-ignore.
//
// Schema:
//   conversations — one row per conversation (UUID, title, mode, timestamps)
//   messages      — one row per message (role, sequence, content as JSON)
//
// Future columns (embedding BLOB, content_hash TEXT) are present in the schema
// for planned RAG vector search and MongoDB cloud sync.

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("../api/protocol.zig");

// ---------------------------------------------------------------------------
// SQLite3 extern declarations (same pattern as client.zig for libcurl)
// ---------------------------------------------------------------------------

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(
    db: *sqlite3,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: *?[*:0]u8,
) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(
    db: *sqlite3,
    sql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*[*:0]const u8,
) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(
    stmt: *sqlite3_stmt,
    index: c_int,
    value: [*]const u8,
    n: c_int,
    destructor: isize,
) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, index: c_int) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, col: c_int) i64;
extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
// SQLITE_TRANSIENT tells sqlite to make its own copy of bound text
const SQLITE_TRANSIENT: isize = -1;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const ConversationSummary = struct {
    id: []const u8,
    title: []const u8,
    mode: []const u8,
    platform: []const u8,
    created_at: i64,
    updated_at: i64,
    message_count: i64,
};

pub const SavedMessage = struct {
    role: []const u8,
    sequence_num: i64,
    content_json: []const u8,
    created_at: i64,
};

pub const DatabaseStats = struct {
    file_size: u64 = 0,
    conversation_count: i64 = 0,
    archived_count: i64 = 0,
    message_count: i64 = 0,
    oldest_ts: i64 = 0,
    newest_ts: i64 = 0,
};

pub const CompactResult = struct {
    size_before: u64 = 0,
    size_after: u64 = 0,
};

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

pub const Storage = struct {
    alloc: Allocator,
    db: *sqlite3,
    db_path: []u8,

    /// Open (or create) the history database at ~/.wintermolt/history.db.
    /// Returns error if SQLite cannot be initialized — caller should fall back
    /// to null storage (memory-only mode).
    pub fn init(alloc: Allocator) !Storage {
        const db_path = try getDbPath(alloc);
        errdefer alloc.free(db_path);

        const path_z = try alloc.dupeZ(u8, db_path);
        defer alloc.free(path_z);

        var db: ?*sqlite3 = null;
        const rc = sqlite3_open(path_z.ptr, &db);
        if (rc != SQLITE_OK or db == null) {
            if (db) |d| _ = sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        var self = Storage{
            .alloc = alloc,
            .db = db.?,
            .db_path = db_path,
        };

        try self.runMigrations();
        return self;
    }

    pub fn deinit(self: *Storage) void {
        _ = sqlite3_close(self.db);
        self.alloc.free(self.db_path);
    }

    /// Create a new conversation, returns its UUID.
    /// Caller owns the returned slice.
    pub fn createConversation(
        self: *Storage,
        mode: []const u8,
        platform: ?[]const u8,
        user_id: ?[]const u8,
        model: []const u8,
    ) ![]u8 {
        const uuid = generateUuid();
        const now = std.time.timestamp();

        const sql =
            "INSERT INTO conversations (id, mode, platform, user_id, model, created_at, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);";

        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, &uuid);
        try self.bindText(stmt, 2, mode);
        if (platform) |p| {
            try self.bindText(stmt, 3, p);
        } else {
            _ = sqlite3_bind_null(stmt, 3);
        }
        if (user_id) |u| {
            try self.bindText(stmt, 4, u);
        } else {
            _ = sqlite3_bind_null(stmt, 4);
        }
        try self.bindText(stmt, 5, model);
        _ = sqlite3_bind_int64(stmt, 6, now);
        _ = sqlite3_bind_int64(stmt, 7, now);

        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;

        return self.alloc.dupe(u8, &uuid);
    }

    /// Save a message to the database.
    pub fn saveMessage(
        self: *Storage,
        conv_id: []const u8,
        role: []const u8,
        seq: usize,
        content_blocks: []const protocol.ContentBlock,
    ) !void {
        const content_json = try serializeContentBlocks(self.alloc, content_blocks);
        defer self.alloc.free(content_json);

        const now = std.time.timestamp();

        const sql =
            "INSERT INTO messages (conversation_id, role, sequence_num, created_at, content_json) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5);";

        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, conv_id);
        try self.bindText(stmt, 2, role);
        _ = sqlite3_bind_int64(stmt, 3, @intCast(seq));
        _ = sqlite3_bind_int64(stmt, 4, now);
        try self.bindText(stmt, 5, content_json);

        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;

        // Update conversation timestamp
        const update_sql = "UPDATE conversations SET updated_at = ?1 WHERE id = ?2;";
        const update_stmt = self.prepare(update_sql) catch return;
        defer _ = sqlite3_finalize(update_stmt);
        self.bindText(update_stmt, 1, conv_id) catch return;
        // Reuse now for the update
        _ = sqlite3_bind_int64(update_stmt, 1, now);
        self.bindText(update_stmt, 2, conv_id) catch return;
        _ = sqlite3_step(update_stmt);
    }

    /// Set the conversation title (first user message, truncated to 80 chars).
    pub fn updateTitle(self: *Storage, conv_id: []const u8, text: []const u8) !void {
        const max_len: usize = 80;
        const title = if (text.len > max_len) text[0..max_len] else text;

        const sql = "UPDATE conversations SET title = ?1 WHERE id = ?2 AND title IS NULL;";
        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, title);
        try self.bindText(stmt, 2, conv_id);
        _ = sqlite3_step(stmt);
    }

    /// Archive a conversation (set archived=1). Used by /clear and /new.
    pub fn archiveConversation(self: *Storage, conv_id: []const u8) !void {
        const sql = "UPDATE conversations SET archived = 1 WHERE id = ?1;";
        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, conv_id);
        _ = sqlite3_step(stmt);
    }

    /// List recent conversations (non-archived), ordered by last update.
    /// Caller owns returned slice and all strings within.
    pub fn listConversations(self: *Storage, limit: usize) ![]ConversationSummary {
        const sql =
            "SELECT c.id, c.title, c.mode, c.platform, c.created_at, c.updated_at, " ++
            "  (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) " ++
            "FROM conversations c WHERE c.archived = 0 " ++
            "ORDER BY c.updated_at DESC LIMIT ?1;";

        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        _ = sqlite3_bind_int64(stmt, 1, @intCast(limit));

        var results: ArrayList(ConversationSummary) = .{};
        errdefer {
            for (results.items) |item| {
                self.alloc.free(item.id);
                self.alloc.free(item.title);
                self.alloc.free(item.mode);
                self.alloc.free(item.platform);
            }
            results.deinit(self.alloc);
        }

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try results.append(self.alloc, .{
                .id = try self.dupeColumnText(stmt, 0),
                .title = try self.dupeColumnText(stmt, 1),
                .mode = try self.dupeColumnText(stmt, 2),
                .platform = try self.dupeColumnText(stmt, 3),
                .created_at = sqlite3_column_int64(stmt, 4),
                .updated_at = sqlite3_column_int64(stmt, 5),
                .message_count = sqlite3_column_int64(stmt, 6),
            });
        }

        return results.toOwnedSlice(self.alloc);
    }

    /// Load all messages for a conversation, ordered by sequence.
    /// Caller owns returned slice and all strings within.
    pub fn loadConversation(self: *Storage, conv_id: []const u8) ![]SavedMessage {
        const sql =
            "SELECT role, sequence_num, content_json, created_at " ++
            "FROM messages WHERE conversation_id = ?1 ORDER BY sequence_num;";

        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, conv_id);

        var results: ArrayList(SavedMessage) = .{};
        errdefer {
            for (results.items) |item| {
                self.alloc.free(item.role);
                self.alloc.free(item.content_json);
            }
            results.deinit(self.alloc);
        }

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try results.append(self.alloc, .{
                .role = try self.dupeColumnText(stmt, 0),
                .sequence_num = sqlite3_column_int64(stmt, 1),
                .content_json = try self.dupeColumnText(stmt, 2),
                .created_at = sqlite3_column_int64(stmt, 3),
            });
        }

        return results.toOwnedSlice(self.alloc);
    }

    /// Get the last active conversation for a given mode (or platform+user for chat).
    /// Returns null if none found. Caller owns the returned slice.
    pub fn getLastConversation(self: *Storage, mode: []const u8, platform: ?[]const u8, user_id: ?[]const u8) !?[]u8 {
        const sql = if (platform != null)
            "SELECT id FROM conversations WHERE archived = 0 AND mode = ?1 AND platform = ?2 AND user_id = ?3 " ++
                "ORDER BY updated_at DESC LIMIT 1;"
        else
            "SELECT id FROM conversations WHERE archived = 0 AND mode = ?1 AND platform IS NULL " ++
                "ORDER BY updated_at DESC LIMIT 1;";

        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, mode);
        if (platform) |p| {
            try self.bindText(stmt, 2, p);
            if (user_id) |u| {
                try self.bindText(stmt, 3, u);
            } else {
                _ = sqlite3_bind_null(stmt, 3);
            }
        }

        if (sqlite3_step(stmt) == SQLITE_ROW) {
            return try self.dupeColumnText(stmt, 0);
        }
        return null;
    }

    /// Search messages by text (LIKE-based). Returns matching conversation summaries.
    /// Caller owns returned slice and all strings within.
    pub fn searchMessages(self: *Storage, query_text: []const u8) ![]ConversationSummary {
        // Build LIKE pattern: %query%
        const pattern = try std.fmt.allocPrint(self.alloc, "%{s}%", .{query_text});
        defer self.alloc.free(pattern);

        const sql =
            "SELECT DISTINCT c.id, c.title, c.mode, c.platform, c.created_at, c.updated_at, " ++
            "  (SELECT COUNT(*) FROM messages m2 WHERE m2.conversation_id = c.id) " ++
            "FROM conversations c " ++
            "JOIN messages m ON m.conversation_id = c.id " ++
            "WHERE m.content_json LIKE ?1 " ++
            "ORDER BY c.updated_at DESC LIMIT 20;";

        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, pattern);

        var results: ArrayList(ConversationSummary) = .{};
        errdefer {
            for (results.items) |item| {
                self.alloc.free(item.id);
                self.alloc.free(item.title);
                self.alloc.free(item.mode);
                self.alloc.free(item.platform);
            }
            results.deinit(self.alloc);
        }

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try results.append(self.alloc, .{
                .id = try self.dupeColumnText(stmt, 0),
                .title = try self.dupeColumnText(stmt, 1),
                .mode = try self.dupeColumnText(stmt, 2),
                .platform = try self.dupeColumnText(stmt, 3),
                .created_at = sqlite3_column_int64(stmt, 4),
                .updated_at = sqlite3_column_int64(stmt, 5),
                .message_count = sqlite3_column_int64(stmt, 6),
            });
        }

        return results.toOwnedSlice(self.alloc);
    }

    /// Free a ConversationSummary slice returned by list/search.
    pub fn freeConversations(self: *Storage, items: []ConversationSummary) void {
        for (items) |item| {
            self.alloc.free(item.id);
            self.alloc.free(item.title);
            self.alloc.free(item.mode);
            self.alloc.free(item.platform);
        }
        self.alloc.free(items);
    }

    /// Free a SavedMessage slice returned by loadConversation.
    pub fn freeMessages(self: *Storage, items: []SavedMessage) void {
        for (items) |item| {
            self.alloc.free(item.role);
            self.alloc.free(item.content_json);
        }
        self.alloc.free(items);
    }

    /// Get database statistics: file size, conversation count, message count, oldest/newest.
    pub fn getStats(self: *Storage) !DatabaseStats {
        var stats = DatabaseStats{};

        // File size
        const file = std.fs.cwd().openFile(self.db_path, .{}) catch {
            return stats;
        };
        defer file.close();
        const file_stat = file.stat() catch {
            return stats;
        };
        stats.file_size = file_stat.size;

        // Conversation count
        const conv_sql = "SELECT COUNT(*) FROM conversations WHERE archived = 0;";
        const conv_stmt = try self.prepare(conv_sql);
        defer _ = sqlite3_finalize(conv_stmt);
        if (sqlite3_step(conv_stmt) == SQLITE_ROW) {
            stats.conversation_count = sqlite3_column_int64(conv_stmt, 0);
        }

        // Archived count
        const arch_sql = "SELECT COUNT(*) FROM conversations WHERE archived = 1;";
        const arch_stmt = try self.prepare(arch_sql);
        defer _ = sqlite3_finalize(arch_stmt);
        if (sqlite3_step(arch_stmt) == SQLITE_ROW) {
            stats.archived_count = sqlite3_column_int64(arch_stmt, 0);
        }

        // Message count
        const msg_sql = "SELECT COUNT(*) FROM messages;";
        const msg_stmt = try self.prepare(msg_sql);
        defer _ = sqlite3_finalize(msg_stmt);
        if (sqlite3_step(msg_stmt) == SQLITE_ROW) {
            stats.message_count = sqlite3_column_int64(msg_stmt, 0);
        }

        // Oldest and newest timestamps
        const time_sql = "SELECT MIN(created_at), MAX(updated_at) FROM conversations;";
        const time_stmt = try self.prepare(time_sql);
        defer _ = sqlite3_finalize(time_stmt);
        if (sqlite3_step(time_stmt) == SQLITE_ROW) {
            stats.oldest_ts = sqlite3_column_int64(time_stmt, 0);
            stats.newest_ts = sqlite3_column_int64(time_stmt, 1);
        }

        return stats;
    }

    /// Run VACUUM and PRAGMA optimize to reclaim space and optimize indexes.
    pub fn compact(self: *Storage) !CompactResult {
        // Get size before
        const file_before = std.fs.cwd().openFile(self.db_path, .{}) catch return CompactResult{};
        const stat_before = file_before.stat() catch {
            file_before.close();
            return CompactResult{};
        };
        file_before.close();
        const size_before = stat_before.size;

        // Run PRAGMA optimize + VACUUM
        var errmsg: ?[*:0]u8 = null;
        _ = sqlite3_exec(self.db, "PRAGMA optimize;", null, null, &errmsg);
        if (errmsg) |msg| sqlite3_free(@ptrCast(msg));

        errmsg = null;
        const rc = sqlite3_exec(self.db, "VACUUM;", null, null, &errmsg);
        if (errmsg) |msg| {
            sqlite3_free(@ptrCast(msg));
        }

        if (rc != SQLITE_OK) return error.VacuumFailed;

        // Get size after
        const file_after = std.fs.cwd().openFile(self.db_path, .{}) catch return CompactResult{ .size_before = size_before };
        const stat_after = file_after.stat() catch {
            file_after.close();
            return CompactResult{ .size_before = size_before };
        };
        file_after.close();

        return .{
            .size_before = size_before,
            .size_after = stat_after.size,
        };
    }

    /// Export a conversation to markdown format.
    pub fn exportConversation(self: *Storage, alloc: Allocator, conv_id: []const u8) ![]u8 {
        // Load conversation metadata
        const meta_sql =
            "SELECT title, mode, model, created_at FROM conversations WHERE id = ?1;";
        const meta_stmt = try self.prepare(meta_sql);
        defer _ = sqlite3_finalize(meta_stmt);
        try self.bindText(meta_stmt, 1, conv_id);

        var title: []const u8 = "(untitled)";
        var mode: []const u8 = "repl";
        var model: []const u8 = "unknown";
        var created_at: i64 = 0;

        if (sqlite3_step(meta_stmt) == SQLITE_ROW) {
            const t = sqlite3_column_text(meta_stmt, 0);
            if (t) |ptr| title = std.mem.span(ptr);
            const m = sqlite3_column_text(meta_stmt, 1);
            if (m) |ptr| mode = std.mem.span(ptr);
            const md = sqlite3_column_text(meta_stmt, 2);
            if (md) |ptr| model = std.mem.span(ptr);
            created_at = sqlite3_column_int64(meta_stmt, 3);
        }

        // Load messages
        const messages = try self.loadConversation(conv_id);
        defer self.freeMessages(messages);

        // Build markdown
        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try std.fmt.format(w, "# {s}\n\n", .{title});
        try std.fmt.format(w, "- **Mode:** {s}\n", .{mode});
        try std.fmt.format(w, "- **Model:** {s}\n", .{model});
        try std.fmt.format(w, "- **Messages:** {d}\n", .{messages.len});
        try std.fmt.format(w, "- **ID:** `{s}`\n", .{conv_id});
        if (created_at > 0) {
            try std.fmt.format(w, "- **Created:** timestamp {d}\n", .{created_at});
        }
        try w.writeAll("\n---\n\n");

        for (messages) |msg| {
            const role_label: []const u8 = if (std.mem.eql(u8, msg.role, "user")) "**User**" else "**Assistant**";
            try std.fmt.format(w, "### {s}\n\n", .{role_label});

            // Extract text from content_json
            if (extractText(msg.content_json)) |text| {
                try w.writeAll(text);
                try w.writeAll("\n\n");
            } else {
                try w.writeAll("*(non-text content)*\n\n");
            }
        }

        return buf.toOwnedSlice(alloc);
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn runMigrations(self: *Storage) !void {
        const schema =
            "PRAGMA journal_mode=WAL;" ++
            "CREATE TABLE IF NOT EXISTS conversations (" ++
            "  id          TEXT PRIMARY KEY," ++
            "  title       TEXT," ++
            "  mode        TEXT NOT NULL," ++
            "  platform    TEXT," ++
            "  user_id     TEXT," ++
            "  model       TEXT," ++
            "  created_at  INTEGER NOT NULL," ++
            "  updated_at  INTEGER NOT NULL," ++
            "  token_count INTEGER DEFAULT 0," ++
            "  archived    INTEGER DEFAULT 0," ++
            "  agent_id    TEXT DEFAULT 'main'," ++
            "  summary     TEXT," ++
            "  embedding   BLOB" ++
            ");" ++
            "CREATE TABLE IF NOT EXISTS messages (" ++
            "  id              INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "  conversation_id TEXT NOT NULL REFERENCES conversations(id)," ++
            "  role            TEXT NOT NULL," ++
            "  sequence_num    INTEGER NOT NULL," ++
            "  created_at      INTEGER NOT NULL," ++
            "  content_json    TEXT NOT NULL," ++
            "  content_hash    TEXT," ++
            "  embedding       BLOB" ++
            ");" ++
            "CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, sequence_num);" ++
            "CREATE INDEX IF NOT EXISTS idx_conv_updated ON conversations(updated_at DESC);" ++
            "CREATE INDEX IF NOT EXISTS idx_conv_platform ON conversations(platform, user_id);" ++
            "CREATE INDEX IF NOT EXISTS idx_conv_agent ON conversations(agent_id, updated_at DESC);" ++
            "PRAGMA user_version = 1;";

        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(self.db, schema, null, null, &errmsg);
        if (rc != SQLITE_OK) {
            if (errmsg) |msg| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("[storage] Migration error: {s}\n", .{msg}) catch {};
                sqlite3_free(@ptrCast(msg));
            }
            return error.SqliteMigrationFailed;
        }
    }

    fn prepare(self: *Storage, sql: [*:0]const u8) !*sqlite3_stmt {
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != SQLITE_OK or stmt == null) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[storage] Prepare error: {s}\n", .{sqlite3_errmsg(self.db)}) catch {};
            return error.SqlitePrepareFailed;
        }
        return stmt.?;
    }

    fn bindText(self: *Storage, stmt: *sqlite3_stmt, index: c_int, value: []const u8) !void {
        const rc = sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[storage] Bind error: {s}\n", .{sqlite3_errmsg(self.db)}) catch {};
            return error.SqliteBindFailed;
        }
    }

    fn dupeColumnText(self: *Storage, stmt: *sqlite3_stmt, col: c_int) ![]u8 {
        const raw = sqlite3_column_text(stmt, col);
        if (raw) |ptr| {
            return self.alloc.dupe(u8, std.mem.span(ptr));
        }
        return self.alloc.dupe(u8, "");
    }
};

// ---------------------------------------------------------------------------
// Standalone helpers
// ---------------------------------------------------------------------------

/// Get the database path: ~/.wintermolt/history.db
/// Creates the directory if it doesn't exist.
fn getDbPath(alloc: Allocator) ![]u8 {
    const home = compat.getenv("HOME") orelse return error.NoHomeDir;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
    defer alloc.free(dir_path);

    // Create directory if needed
    std.fs.makeDirAbsolute(dir_path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    return std.fmt.allocPrint(alloc, "{s}/.wintermolt/history.db", .{home});
}

/// Generate a UUID v4 string (32 hex chars + 4 hyphens = 36 chars).
fn generateUuid() [36]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version (4) and variant (2) bits per RFC 4122
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 2

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

/// Serialize content blocks to a JSON array string for storage.
/// Caller owns returned slice.
fn serializeContentBlocks(alloc: Allocator, blocks: []const protocol.ContentBlock) ![]u8 {
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeByte('[');
    for (blocks, 0..) |block, i| {
        if (i > 0) try w.writeByte(',');
        switch (block) {
            .text => |text| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonStringQuoted(w, text);
                try w.writeByte('}');
            },
            .tool_use => |tu| {
                try w.writeAll("{\"type\":\"tool_use\",\"id\":");
                try writeJsonStringQuoted(w, tu.id);
                try w.writeAll(",\"name\":");
                try writeJsonStringQuoted(w, tu.name);
                try w.writeAll(",\"input\":");
                try w.writeAll(tu.input_json);
                try w.writeByte('}');
            },
            .tool_result => |tr| {
                try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                try writeJsonStringQuoted(w, tr.tool_use_id);
                try w.writeAll(",\"content\":");
                try writeJsonStringQuoted(w, tr.content);
                if (tr.is_error) {
                    try w.writeAll(",\"is_error\":true");
                }
                try w.writeByte('}');
            },
            .image => {
                // Don't persist full base64 image data to SQLite (too large).
                // Store a placeholder instead.
                try w.writeAll("{\"type\":\"image\",\"text\":\"[image frame]\"}");
            },
        }
    }
    try w.writeByte(']');

    return buf.toOwnedSlice(alloc);
}

/// Extract first text value from content_json for export.
fn extractText(json_str: []const u8) ?[]const u8 {
    const needle = "\"text\":\"";
    var pos: usize = 0;
    if (std.mem.indexOfPos(u8, json_str, pos, "\"type\":\"text\"")) |type_pos| {
        pos = type_pos + 13;
    } else {
        const content_needle = "\"content\":\"";
        if (std.mem.indexOf(u8, json_str, content_needle)) |start| {
            const text_start = start + content_needle.len;
            if (findJsonEnd(json_str, text_start)) |text_end| {
                return json_str[text_start..text_end];
            }
        }
        return null;
    }
    if (std.mem.indexOfPos(u8, json_str, pos, needle)) |start| {
        const text_start = start + needle.len;
        if (findJsonEnd(json_str, text_start)) |text_end| {
            return json_str[text_start..text_end];
        }
    }
    return null;
}

fn findJsonEnd(json_str: []const u8, start: usize) ?usize {
    var i = start;
    while (i < json_str.len) {
        if (json_str[i] == '\\') {
            i += 2;
            continue;
        }
        if (json_str[i] == '"') return i;
        i += 1;
    }
    return null;
}

/// Write a JSON string with surrounding quotes, escaping special characters.
fn writeJsonStringQuoted(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(w, "\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
