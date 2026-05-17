// Copyright The Fantastic Planet - By David Clabaugh
//
// agent_pool.zig — Pool of named AgentLoop instances for multi-agent routing
//
// Manages multiple concurrent agents, each with its own conversation history,
// system prompt, and backend. Agents are lazily created on first message and
// evicted after idle timeout.
//
// Key features:
//   - Lazy instantiation: agents created on first route match
//   - Idle eviction: agents freed after WINTERMOLT_AGENT_IDLE_TIMEOUT (default: 30m)
//   - Max pool size: configurable via WINTERMOLT_MAX_AGENTS (default: 16)
//   - All agents share the same Config and MCP manager
//   - Each agent gets its own History, Storage conversation, and session state

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const loop_mod = @import("loop.zig");
const config_mod = @import("config.zig");
const router_mod = @import("router.zig");

/// A pooled agent with metadata.
pub const PooledAgent = struct {
    agent: loop_mod.AgentLoop,
    agent_id: []const u8, // Owned copy
    last_active: i64, // Unix timestamp
    message_count: u64,
};

/// Pool of named AgentLoop instances.
pub const AgentPool = struct {
    alloc: Allocator,
    config: *config_mod.Config,
    agents: ArrayList(PooledAgent),
    max_agents: usize,
    idle_timeout: i64, // seconds

    pub fn init(alloc: Allocator, config: *config_mod.Config) AgentPool {
        const max_str = compat.getenv("WINTERMOLT_MAX_AGENTS") orelse "16";
        const max_agents = std.fmt.parseInt(usize, max_str, 10) catch 16;

        const idle_str = compat.getenv("WINTERMOLT_AGENT_IDLE_TIMEOUT") orelse "1800";
        const idle_timeout = std.fmt.parseInt(i64, idle_str, 10) catch 1800;

        return .{
            .alloc = alloc,
            .config = config,
            .agents = .{},
            .max_agents = max_agents,
            .idle_timeout = idle_timeout,
        };
    }

    pub fn deinit(self: *AgentPool) void {
        for (self.agents.items) |*pa| {
            pa.agent.deinit();
            self.alloc.free(pa.agent_id);
        }
        self.agents.deinit(self.alloc);
    }

    /// Get or create an agent for the given agent_id.
    /// Returns a pointer to the AgentLoop. The pointer is stable until eviction.
    pub fn getOrCreate(self: *AgentPool, agent_id: []const u8) !*loop_mod.AgentLoop {
        const now = std.time.timestamp();

        // Look for existing agent
        for (self.agents.items) |*pa| {
            if (std.mem.eql(u8, pa.agent_id, agent_id)) {
                pa.last_active = now;
                pa.message_count += 1;
                return &pa.agent;
            }
        }

        // Evict idle agents if at capacity
        if (self.agents.items.len >= self.max_agents) {
            self.evictIdle(now);

            // If still at capacity, evict the oldest
            if (self.agents.items.len >= self.max_agents) {
                self.evictOldest();
            }
        }

        // Create new agent
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("[pool] Creating agent: {s}\n", .{agent_id}) catch {};

        var agent = try loop_mod.AgentLoop.init(self.alloc, self.config);
        agent.startConversation();

        const id_copy = try self.alloc.dupe(u8, agent_id);
        errdefer self.alloc.free(id_copy);

        try self.agents.append(self.alloc, .{
            .agent = agent,
            .agent_id = id_copy,
            .last_active = now,
            .message_count = 1,
        });

        return &self.agents.items[self.agents.items.len - 1].agent;
    }

    /// Evict agents that have been idle for longer than idle_timeout.
    fn evictIdle(self: *AgentPool, now: i64) void {
        var i: usize = 0;
        while (i < self.agents.items.len) {
            if (now - self.agents.items[i].last_active > self.idle_timeout) {
                self.evictAt(i);
            } else {
                i += 1;
            }
        }
    }

    /// Evict the least recently used agent.
    fn evictOldest(self: *AgentPool) void {
        if (self.agents.items.len == 0) return;

        var oldest_idx: usize = 0;
        var oldest_ts: i64 = self.agents.items[0].last_active;

        for (self.agents.items, 0..) |pa, idx| {
            if (pa.last_active < oldest_ts) {
                oldest_ts = pa.last_active;
                oldest_idx = idx;
            }
        }

        self.evictAt(oldest_idx);
    }

    fn evictAt(self: *AgentPool, idx: usize) void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("[pool] Evicting agent: {s}\n", .{self.agents.items[idx].agent_id}) catch {};

        self.agents.items[idx].agent.deinit();
        self.alloc.free(self.agents.items[idx].agent_id);
        _ = self.agents.swapRemove(idx);
    }

    /// Tick schedulers on all active agents.
    pub fn tickAll(self: *AgentPool) void {
        for (self.agents.items) |*pa| {
            _ = pa.agent.tickScheduler();
        }
    }

    /// Get pool stats as a formatted string. Caller owns the result.
    pub fn getStats(self: *const AgentPool, alloc: Allocator) ![]u8 {
        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try std.fmt.format(w, "Agent Pool: {d}/{d} agents\n", .{ self.agents.items.len, self.max_agents });
        try w.writeAll("════════════════════════\n");

        const now = std.time.timestamp();
        for (self.agents.items) |pa| {
            const idle_secs = now - pa.last_active;
            try std.fmt.format(w, "  {s}: {d} msgs, idle {d}s\n", .{
                pa.agent_id,
                pa.message_count,
                idle_secs,
            });
        }

        return buf.toOwnedSlice(alloc);
    }
};
