// Copyright The Fantastic Planet - By David Clabaugh
//
// scheduler.zig — SQLite-persisted job scheduler
//
// Provides cron-like job scheduling for Wintermolt. Jobs persist across
// restarts in ~/.wintermolt/scheduler.db. The tick() method is called
// periodically from the agentic loop to check for and execute due jobs.
//
// Schedule types:
//   every  — repeat interval ("5m", "1h", "30s", "1d")
//   at     — daily at time ("09:00", "14:30")
//   cron   — standard cron expression ("*/5 * * * *")

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const bash_tool = @import("../tools/bash.zig");

// ---------------------------------------------------------------------------
// SQLite3 extern declarations (same pattern as storage.zig — no @cImport)
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
const SQLITE_TRANSIENT: isize = -1;

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

pub const Scheduler = struct {
    alloc: Allocator,
    db: ?*sqlite3,

    /// Open (or create) the scheduler database at ~/.wintermolt/scheduler.db.
    /// Runs schema migrations. Returns error if SQLite cannot be initialized.
    pub fn init(alloc: Allocator) !Scheduler {
        const db_path = try getDbPath(alloc);
        defer alloc.free(db_path);

        const path_z = try alloc.dupeZ(u8, db_path);
        defer alloc.free(path_z);

        var db: ?*sqlite3 = null;
        const rc = sqlite3_open(path_z.ptr, &db);
        if (rc != SQLITE_OK or db == null) {
            if (db) |d| _ = sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        var self = Scheduler{
            .alloc = alloc,
            .db = db,
        };

        try self.runMigrations();
        return self;
    }

    /// Close the database.
    pub fn deinit(self: *Scheduler) void {
        if (self.db) |db| {
            _ = sqlite3_close(db);
            self.db = null;
        }
    }

    /// Add a new scheduled job. Returns the generated job ID (caller owns).
    pub fn addJob(
        self: *Scheduler,
        name: []const u8,
        schedule_type: []const u8,
        schedule_value: []const u8,
        command: []const u8,
    ) ![]u8 {
        const db = self.db orelse return error.NoDB;

        // Validate schedule_type
        if (!std.mem.eql(u8, schedule_type, "every") and
            !std.mem.eql(u8, schedule_type, "at") and
            !std.mem.eql(u8, schedule_type, "cron"))
        {
            return error.InvalidScheduleType;
        }

        // Validate schedule_value based on type
        if (std.mem.eql(u8, schedule_type, "every")) {
            if (parseInterval(schedule_value) == null) return error.InvalidInterval;
        } else if (std.mem.eql(u8, schedule_type, "at")) {
            if (!validateTimeStr(schedule_value)) return error.InvalidTimeFormat;
        }
        // cron validation happens implicitly during computeNextRun

        const now = std.time.timestamp();
        const job_id = generateJobId(name, now);
        const next_run = computeNextRun(schedule_type, schedule_value, now);

        const sql =
            "INSERT INTO jobs (id, name, schedule_type, schedule_value, command, " ++
            "last_run, next_run, enabled, created_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);";

        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(db, stmt, 1, &job_id);
        try self.bindText(db, stmt, 2, name);
        try self.bindText(db, stmt, 3, schedule_type);
        try self.bindText(db, stmt, 4, schedule_value);
        try self.bindText(db, stmt, 5, command);
        _ = sqlite3_bind_int64(stmt, 6, 0); // last_run = never
        _ = sqlite3_bind_int64(stmt, 7, next_run);
        _ = sqlite3_bind_int64(stmt, 8, 1); // enabled
        _ = sqlite3_bind_int64(stmt, 9, now);

        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;

        return self.alloc.dupe(u8, &job_id);
    }

    /// Remove a job by ID.
    pub fn removeJob(self: *Scheduler, job_id: []const u8) !void {
        const db = self.db orelse return error.NoDB;

        const sql = "DELETE FROM jobs WHERE id = ?1;";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);

        try self.bindText(db, stmt, 1, job_id);
        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;
    }

    /// List all jobs as a formatted text table. Caller owns returned slice.
    pub fn listJobs(self: *Scheduler, alloc: Allocator) ![]u8 {
        const db = self.db orelse return alloc.dupe(u8, "[scheduler] No database connection.");

        const sql =
            "SELECT id, name, schedule_type, schedule_value, command, " ++
            "last_run, next_run, enabled, created_at FROM jobs ORDER BY created_at ASC;";

        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);

        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try w.writeAll("=== Scheduled Jobs ===\n\n");

        var count: usize = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            count += 1;

            const id_raw = sqlite3_column_text(stmt, 0);
            const name_raw = sqlite3_column_text(stmt, 1);
            const stype_raw = sqlite3_column_text(stmt, 2);
            const sval_raw = sqlite3_column_text(stmt, 3);
            const cmd_raw = sqlite3_column_text(stmt, 4);
            const last_run = sqlite3_column_int64(stmt, 5);
            const next_run = sqlite3_column_int64(stmt, 6);
            const enabled = sqlite3_column_int64(stmt, 7);

            const id_str = if (id_raw) |p| std.mem.span(p) else "?";
            const name_str = if (name_raw) |p| std.mem.span(p) else "?";
            const stype_str = if (stype_raw) |p| std.mem.span(p) else "?";
            const sval_str = if (sval_raw) |p| std.mem.span(p) else "?";
            const cmd_str = if (cmd_raw) |p| std.mem.span(p) else "?";

            const status_str = if (enabled != 0) "ON" else "OFF";
            const now = std.time.timestamp();
            const secs_until = next_run - now;

            try std.fmt.format(w, "  [{s}] {s} ({s})\n", .{ id_str, name_str, status_str });
            try std.fmt.format(w, "    Schedule: {s} {s}\n", .{ stype_str, sval_str });
            try std.fmt.format(w, "    Command:  {s}\n", .{cmd_str});

            if (last_run > 0) {
                const ago = now - last_run;
                try std.fmt.format(w, "    Last run: {d}s ago\n", .{ago});
            } else {
                try w.writeAll("    Last run: never\n");
            }

            if (secs_until > 0) {
                const dur = formatDuration(secs_until);
                try std.fmt.format(w, "    Next run: in {s}\n", .{dur.buf[0..dur.len]});
            } else {
                try w.writeAll("    Next run: overdue (will run on next tick)\n");
            }

            try w.writeByte('\n');
        }

        if (count == 0) {
            try w.writeAll("  No jobs scheduled.\n");
        } else {
            try std.fmt.format(w, "Total: {d} job(s)\n", .{count});
        }

        return buf.toOwnedSlice(alloc);
    }

    /// Enable or disable a job.
    pub fn enableJob(self: *Scheduler, job_id: []const u8, enabled: bool) !void {
        const db = self.db orelse return error.NoDB;

        const sql = "UPDATE jobs SET enabled = ?1 WHERE id = ?2;";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);

        _ = sqlite3_bind_int64(stmt, 1, if (enabled) 1 else 0);
        try self.bindText(db, stmt, 2, job_id);

        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;
    }

    /// Called periodically (~60s) from the agentic loop.
    /// Checks for due jobs and executes them. Returns a summary of executed
    /// jobs, or null if nothing ran. Caller owns returned slice.
    pub fn tick(self: *Scheduler, alloc: Allocator) !?[]u8 {
        const db = self.db orelse return null;
        const now = std.time.timestamp();

        // Query all due, enabled jobs
        const sql =
            "SELECT id, name, command, schedule_type, schedule_value " ++
            "FROM jobs WHERE enabled = 1 AND next_run <= ?1;";

        const stmt = self.prepare(db, sql) catch return null;
        defer _ = sqlite3_finalize(stmt);

        _ = sqlite3_bind_int64(stmt, 1, now);

        // Collect due jobs into a temporary list so we can finalize the
        // SELECT statement before modifying the table (avoids locks).
        const DueJob = struct {
            id: []u8,
            name: []u8,
            command: []u8,
            schedule_type: []u8,
            schedule_value: []u8,
        };

        var due_jobs: ArrayList(DueJob) = .{};
        defer {
            for (due_jobs.items) |job| {
                alloc.free(job.id);
                alloc.free(job.name);
                alloc.free(job.command);
                alloc.free(job.schedule_type);
                alloc.free(job.schedule_value);
            }
            due_jobs.deinit(alloc);
        }

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const id_raw = sqlite3_column_text(stmt, 0);
            const name_raw = sqlite3_column_text(stmt, 1);
            const cmd_raw = sqlite3_column_text(stmt, 2);
            const stype_raw = sqlite3_column_text(stmt, 3);
            const sval_raw = sqlite3_column_text(stmt, 4);

            const job = DueJob{
                .id = alloc.dupe(u8, if (id_raw) |p| std.mem.span(p) else "") catch continue,
                .name = alloc.dupe(u8, if (name_raw) |p| std.mem.span(p) else "") catch continue,
                .command = alloc.dupe(u8, if (cmd_raw) |p| std.mem.span(p) else "") catch continue,
                .schedule_type = alloc.dupe(u8, if (stype_raw) |p| std.mem.span(p) else "") catch continue,
                .schedule_value = alloc.dupe(u8, if (sval_raw) |p| std.mem.span(p) else "") catch continue,
            };
            due_jobs.append(alloc, job) catch continue;
        }

        if (due_jobs.items.len == 0) return null;

        // Execute each due job and build summary
        var result: ArrayList(u8) = .{};
        const w = result.writer(alloc);

        try std.fmt.format(w, "[scheduler] {d} job(s) due at {d}:\n\n", .{ due_jobs.items.len, now });

        for (due_jobs.items) |job| {
            try std.fmt.format(w, "--- Job: {s} ({s}) ---\n", .{ job.name, job.id });
            try std.fmt.format(w, "Command: {s}\n", .{job.command});

            // Execute the job command via bash tool
            const output = self.executeJob(alloc, job.id, job.command) catch |e| blk: {
                const err_msg = std.fmt.allocPrint(alloc, "[scheduler] Execution error: {s}\n", .{@errorName(e)}) catch break :blk "";
                break :blk err_msg;
            };
            defer if (output.len > 0) alloc.free(output);

            // Truncate long output in the summary
            const max_preview: usize = 500;
            if (output.len > max_preview) {
                try w.writeAll(output[0..max_preview]);
                try std.fmt.format(w, "\n... ({d} bytes truncated)\n", .{output.len - max_preview});
            } else {
                try w.writeAll(output);
                if (output.len > 0 and output[output.len - 1] != '\n') {
                    try w.writeByte('\n');
                }
            }

            // Update last_run and compute next_run
            const new_next_run = computeNextRun(job.schedule_type, job.schedule_value, now);
            self.updateJobAfterRun(db, job.id, now, new_next_run) catch |e| {
                std.fmt.format(w, "[scheduler] Failed to update job {s}: {s}\n", .{ job.id, @errorName(e) }) catch {};
            };

            try w.writeByte('\n');
        }

        const slice = try result.toOwnedSlice(alloc);
        return slice;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Execute a command via bash and return the output. Caller owns result.
    fn executeJob(self: *Scheduler, alloc: Allocator, job_id: []const u8, command: []const u8) ![]u8 {
        _ = self;
        _ = job_id;
        return bash_tool.execute(alloc, command);
    }

    /// Update last_run and next_run for a job after execution.
    fn updateJobAfterRun(self: *Scheduler, db: *sqlite3, job_id: []const u8, last_run: i64, next_run: i64) !void {
        const sql = "UPDATE jobs SET last_run = ?1, next_run = ?2 WHERE id = ?3;";
        const stmt = try self.prepare(db, sql);
        defer _ = sqlite3_finalize(stmt);

        _ = sqlite3_bind_int64(stmt, 1, last_run);
        _ = sqlite3_bind_int64(stmt, 2, next_run);
        try self.bindText(db, stmt, 3, job_id);

        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteStepFailed;
    }

    /// Run the schema migration (CREATE TABLE IF NOT EXISTS).
    fn runMigrations(self: *Scheduler) !void {
        const db = self.db orelse return error.NoDB;

        const schema =
            "PRAGMA journal_mode=WAL;" ++
            "CREATE TABLE IF NOT EXISTS jobs (" ++
            "  id             TEXT PRIMARY KEY," ++
            "  name           TEXT NOT NULL," ++
            "  schedule_type  TEXT NOT NULL," ++
            "  schedule_value TEXT NOT NULL," ++
            "  command        TEXT NOT NULL," ++
            "  last_run       INTEGER DEFAULT 0," ++
            "  next_run       INTEGER NOT NULL," ++
            "  enabled        INTEGER DEFAULT 1," ++
            "  created_at     INTEGER NOT NULL" ++
            ");" ++
            "CREATE INDEX IF NOT EXISTS idx_jobs_next_run ON jobs(enabled, next_run);" ++
            "PRAGMA user_version = 1;";

        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(db, schema, null, null, &errmsg);
        if (rc != SQLITE_OK) {
            if (errmsg) |msg| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("[scheduler] Migration error: {s}\n", .{msg}) catch {};
                sqlite3_free(@ptrCast(msg));
            }
            return error.SqliteMigrationFailed;
        }
    }

    /// Prepare a SQL statement with error logging.
    fn prepare(self: *Scheduler, db: *sqlite3, sql: [*:0]const u8) !*sqlite3_stmt {
        _ = self;
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(db, sql, -1, &stmt, null);
        if (rc != SQLITE_OK or stmt == null) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[scheduler] Prepare error: {s}\n", .{sqlite3_errmsg(db)}) catch {};
            return error.SqlitePrepareFailed;
        }
        return stmt.?;
    }

    /// Bind a Zig string slice to a statement parameter with SQLITE_TRANSIENT.
    fn bindText(self: *Scheduler, db: *sqlite3, stmt: *sqlite3_stmt, index: c_int, value: []const u8) !void {
        _ = self;
        const rc = sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[scheduler] Bind error: {s}\n", .{sqlite3_errmsg(db)}) catch {};
            return error.SqliteBindFailed;
        }
    }
};

// ---------------------------------------------------------------------------
// Schedule computation
// ---------------------------------------------------------------------------

fn computeNextRun(schedule_type: []const u8, schedule_value: []const u8, now: i64) i64 {
    if (std.mem.eql(u8, schedule_type, "every")) {
        const interval = parseInterval(schedule_value) orelse 60;
        return now + interval;
    } else if (std.mem.eql(u8, schedule_type, "at")) {
        return computeNextDailyRun(schedule_value, now);
    } else if (std.mem.eql(u8, schedule_type, "cron")) {
        return parseCron(schedule_value, now);
    }
    return now + 3600;
}

fn parseInterval(value: []const u8) ?i64 {
    if (value.len < 2) return null;
    const suffix = value[value.len - 1];
    const num_str = value[0 .. value.len - 1];
    const num = std.fmt.parseInt(i64, num_str, 10) catch return null;
    if (num <= 0) return null;
    return switch (suffix) {
        's' => num,
        'm' => num * 60,
        'h' => num * 3600,
        'd' => num * 86400,
        else => null,
    };
}

fn validateTimeStr(value: []const u8) bool {
    if (value.len != 5) return false;
    if (value[2] != ':') return false;
    const hour = std.fmt.parseInt(u8, value[0..2], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[3..5], 10) catch return false;
    return hour < 24 and minute < 60;
}

fn parseTimeStr(value: []const u8) ?struct { hour: u8, minute: u8 } {
    if (value.len != 5 or value[2] != ':') return null;
    const hour = std.fmt.parseInt(u8, value[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[3..5], 10) catch return null;
    if (hour >= 24 or minute >= 60) return null;
    return .{ .hour = hour, .minute = minute };
}

fn computeNextDailyRun(time_str: []const u8, now: i64) i64 {
    const parsed = parseTimeStr(time_str) orelse return now + 3600;
    const secs_per_day: i64 = 86400;
    const today_midnight = @divFloor(now, secs_per_day) * secs_per_day;
    const target_secs: i64 = @as(i64, parsed.hour) * 3600 + @as(i64, parsed.minute) * 60;
    var next = today_midnight + target_secs;
    if (next <= now) next += secs_per_day;
    return next;
}

fn parseCron(expression: []const u8, now: i64) i64 {
    var fields: [5]CronField = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, expression, ' ');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (count >= 5) break;
        fields[count] = parseCronField(part);
        count += 1;
    }
    while (count < 5) {
        fields[count] = CronField{ .kind = .wildcard, .value = 0 };
        count += 1;
    }
    const start = roundUpToMinute(now + 1);
    const max_scan = start + 366 * 86400;
    var ts = start;
    while (ts < max_scan) : (ts += 60) {
        const dt = timestampToDatetime(ts);
        if (matchesCronField(fields[0], dt.minute) and
            matchesCronField(fields[1], dt.hour) and
            matchesCronField(fields[2], dt.day) and
            matchesCronField(fields[3], dt.month) and
            matchesCronField(fields[4], dt.dow))
        {
            return ts;
        }
    }
    return now + 3600;
}

const CronFieldKind = enum { wildcard, exact, step };
const CronField = struct { kind: CronFieldKind, value: u8 };

fn parseCronField(token: []const u8) CronField {
    if (std.mem.eql(u8, token, "*")) return .{ .kind = .wildcard, .value = 0 };
    if (std.mem.startsWith(u8, token, "*/")) {
        const step = std.fmt.parseInt(u8, token[2..], 10) catch 1;
        return .{ .kind = .step, .value = if (step == 0) 1 else step };
    }
    return .{ .kind = .exact, .value = std.fmt.parseInt(u8, token, 10) catch 0 };
}

fn matchesCronField(field: CronField, value: u8) bool {
    return switch (field.kind) {
        .wildcard => true,
        .exact => field.value == value,
        .step => if (field.value == 0) true else (value % field.value == 0),
    };
}

const Datetime = struct { minute: u8, hour: u8, day: u8, month: u8, dow: u8 };

fn timestampToDatetime(ts: i64) Datetime {
    const secs_per_day: i64 = 86400;
    const day_offset = @mod(ts, secs_per_day);
    const time_of_day: u64 = @intCast(if (day_offset < 0) day_offset + secs_per_day else day_offset);
    const hour: u8 = @intCast(time_of_day / 3600);
    const minute: u8 = @intCast((time_of_day % 3600) / 60);
    const z_raw = @divFloor(ts, secs_per_day) + 719468;
    const era: i64 = @divFloor(if (z_raw >= 0) z_raw else z_raw - 146096, 146097);
    const doe_i: i64 = z_raw - era * 146097;
    const doe: u32 = @intCast(doe_i);
    const yoe: u32 = @intCast(@divFloor(
        @as(i64, doe) - @divFloor(@as(i64, doe), 1460) + @divFloor(@as(i64, doe), 36524) - @divFloor(@as(i64, doe), 146096),
        365,
    ));
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y_era: i64 = @as(i64, yoe) + era * 400;
    const y: i64 = if (m <= 2) y_era + 1 else y_era;
    return .{ .minute = minute, .hour = hour, .day = d, .month = m, .dow = computeDow(y, m, d) };
}

fn computeDow(year: i64, month: u8, day: u8) u8 {
    const t = [_]i64{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i64 = year;
    if (month < 3) y -= 1;
    const y_mod = @mod(y, 400);
    const raw = @mod(
        y_mod + @divFloor(y_mod, 4) - @divFloor(y_mod, 100) + @divFloor(y_mod, 400) + t[@as(usize, month) - 1] + @as(i64, day),
        7,
    );
    return @intCast(if (raw < 0) raw + 7 else raw);
}

fn roundUpToMinute(ts: i64) i64 {
    const remainder = @mod(ts, 60);
    if (remainder == 0) return ts;
    return ts + (60 - remainder);
}

fn generateJobId(name: []const u8, timestamp: i64) [8]u8 {
    var hash: u64 = 0xcbf29ce484222325;
    const prime: u64 = 0x100000001b3;
    for (name) |c| { hash ^= c; hash *%= prime; }
    const ts_u: u64 = @bitCast(timestamp);
    for (0..8) |i| {
        const byte: u8 = @intCast((ts_u >> @intCast(i * 8)) & 0xff);
        hash ^= byte; hash *%= prime;
    }
    var rand_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    for (rand_bytes) |c| { hash ^= c; hash *%= prime; }
    const hex = "0123456789abcdef";
    var id: [8]u8 = undefined;
    for (0..4) |i| {
        const byte: u8 = @intCast((hash >> @intCast(i * 8)) & 0xff);
        id[i * 2] = hex[byte >> 4];
        id[i * 2 + 1] = hex[byte & 0x0f];
    }
    return id;
}

fn formatDuration(secs: i64) FormatDurationResult {
    var result = FormatDurationResult{ .buf = undefined, .len = 0 };
    var stream = std.io.fixedBufferStream(&result.buf);
    const writer = stream.writer();
    const abs_secs: u64 = if (secs < 0) @intCast(-secs) else @intCast(secs);
    if (abs_secs >= 86400) {
        writer.print("{d}d {d}h", .{ abs_secs / 86400, (abs_secs % 86400) / 3600 }) catch {};
    } else if (abs_secs >= 3600) {
        writer.print("{d}h {d}m", .{ abs_secs / 3600, (abs_secs % 3600) / 60 }) catch {};
    } else if (abs_secs >= 60) {
        writer.print("{d}m {d}s", .{ abs_secs / 60, abs_secs % 60 }) catch {};
    } else {
        writer.print("{d}s", .{abs_secs}) catch {};
    }
    result.len = stream.pos;
    return result;
}

const FormatDurationResult = struct {
    buf: [32]u8,
    len: usize,
    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.buf[0..self.len]);
    }
};

fn getDbPath(alloc: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
    defer alloc.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    return std.fmt.allocPrint(alloc, "{s}/.wintermolt/scheduler.db", .{home});
}
