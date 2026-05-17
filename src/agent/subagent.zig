// Copyright The Fantastic Planet - By David Clabaugh
//
// subagent.zig — Subagent lifecycle manager
//
// Enables parent-child agent spawning for parallel task execution.
// An agent can spawn subagents via the spawn_agent tool. Each subagent
// gets its own AgentLoop with independent history, runs a task to completion,
// and returns the result to the parent as a tool result.
//
// Architecture note: This module does NOT import loop.zig to avoid circular
// dependency (loop→tools→subagent→loop). Instead, a spawn callback function
// pointer is provided at runtime by main.zig.
//
// Safety:
//   - Depth limit (default 3) prevents runaway recursive spawning
//   - Max concurrent subagents per parent (default 4)
//   - Subagents inherit parent's Config but get fresh History
//   - Subagents do NOT inherit parent's conversation context

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const DEFAULT_MAX_DEPTH: u8 = 3;
pub const DEFAULT_MAX_CONCURRENT: u8 = 4;

/// Status of a subagent.
pub const SubagentStatus = enum {
    running,
    completed,
    failed,
    orphaned,
};

/// Handle to a spawned subagent, tracking its lifecycle.
pub const SubagentHandle = struct {
    id: [36]u8,
    parent_id: ?[36]u8,
    task: []const u8, // Owned copy of the task prompt
    depth: u8,
    status: SubagentStatus,
    result: ?[]const u8, // Owned; set on completion
    created_at: i64,
};

/// Callback type for spawning a child agent.
/// Receives: allocator, task text, model override, child depth, pointer to this manager.
/// Returns: owned result string (the agent's captured output).
pub const SpawnFn = *const fn (
    alloc: Allocator,
    task: []const u8,
    model_override: ?[]const u8,
    child_depth: u8,
    mgr: *SubagentManager,
) []u8;

/// Manages subagent spawning and lifecycle.
pub const SubagentManager = struct {
    alloc: Allocator,
    handles: ArrayList(SubagentHandle),
    max_depth: u8,
    max_concurrent: u8,
    active_count: u8,
    spawn_fn: ?SpawnFn,

    pub fn init(alloc: Allocator) SubagentManager {
        const max_depth_str = compat.getenv("WINTERMOLT_SUBAGENT_MAX_DEPTH") orelse "3";
        const max_depth = std.fmt.parseInt(u8, max_depth_str, 10) catch DEFAULT_MAX_DEPTH;

        const max_concurrent_str = compat.getenv("WINTERMOLT_SUBAGENT_MAX_CONCURRENT") orelse "4";
        const max_concurrent = std.fmt.parseInt(u8, max_concurrent_str, 10) catch DEFAULT_MAX_CONCURRENT;

        return .{
            .alloc = alloc,
            .handles = .{},
            .max_depth = max_depth,
            .max_concurrent = max_concurrent,
            .active_count = 0,
            .spawn_fn = null,
        };
    }

    pub fn deinit(self: *SubagentManager) void {
        for (self.handles.items) |h| {
            self.alloc.free(h.task);
            if (h.result) |r| self.alloc.free(r);
        }
        self.handles.deinit(self.alloc);
    }

    /// Spawn a subagent to execute a task. Runs synchronously — blocks the
    /// parent's tool execution slot until the subagent completes.
    ///
    /// Returns the subagent's text output. Caller owns the returned slice.
    pub fn spawnAndRun(
        self: *SubagentManager,
        parent_depth: u8,
        parent_id: ?[36]u8,
        task: []const u8,
        model_override: ?[]const u8,
    ) ![]u8 {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const child_depth = parent_depth + 1;

        // Safety checks
        if (child_depth > self.max_depth) {
            return self.alloc.dupe(u8, "Error: Maximum subagent depth exceeded. Cannot spawn deeper subagents.");
        }
        if (self.active_count >= self.max_concurrent) {
            return self.alloc.dupe(u8, "Error: Maximum concurrent subagents reached. Wait for existing subagents to complete.");
        }

        const spawn = self.spawn_fn orelse {
            return self.alloc.dupe(u8, "Error: Subagent spawn function not configured.");
        };

        // Generate subagent ID
        const sub_id = generateUuid();

        // Track the handle
        const task_copy = try self.alloc.dupe(u8, task);
        try self.handles.append(self.alloc, .{
            .id = sub_id,
            .parent_id = parent_id,
            .task = task_copy,
            .depth = child_depth,
            .status = .running,
            .result = null,
            .created_at = std.time.timestamp(),
        });
        self.active_count += 1;

        stderr.print("[subagent] Spawning depth={d} id={s}\n", .{ child_depth, sub_id[0..8] }) catch {};

        // Call the spawn function (provided by main.zig, breaks the circular dep)
        const result = spawn(self.alloc, task, model_override, child_depth, self);

        self.active_count -= 1;

        // Update handle status
        const last_idx = self.handles.items.len - 1;
        if (result.len > 0 and !std.mem.startsWith(u8, result, "Error:")) {
            self.handles.items[last_idx].status = .completed;
        } else {
            self.handles.items[last_idx].status = .failed;
        }

        stderr.print("[subagent] Completed id={s} ({d} bytes output)\n", .{ sub_id[0..8], result.len }) catch {};

        return result;
    }

    /// Get info about active and completed subagents.
    pub fn getStats(self: *const SubagentManager, alloc: Allocator) ![]u8 {
        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try std.fmt.format(w, "Subagents: {d} active, {d} total (max depth: {d}, max concurrent: {d})\n", .{
            self.active_count,
            self.handles.items.len,
            self.max_depth,
            self.max_concurrent,
        });

        for (self.handles.items) |h| {
            const status_str = switch (h.status) {
                .running => "RUNNING",
                .completed => "DONE",
                .failed => "FAILED",
                .orphaned => "ORPHAN",
            };
            try std.fmt.format(w, "  [{s}] depth={d} status={s}: {s}\n", .{
                h.id[0..8],
                h.depth,
                status_str,
                truncateStr(h.task, 60),
            });
        }

        return buf.toOwnedSlice(alloc);
    }
};

fn truncateStr(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
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
