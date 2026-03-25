// Copyright The Fantastic Planet - By David Clabaugh
//
// router.zig — Multi-agent routing with 7-tier priority binding
//
// Routes incoming chat messages to the correct agent based on a priority
// hierarchy matching OpenClaw's binding system:
//
//   Tier 1: peer        — Direct peer/user binding (highest priority)
//   Tier 2: parent_peer — Thread parent inheritance
//   Tier 3: guild_role  — Guild + role-based binding
//   Tier 4: guild       — Guild-only binding
//   Tier 5: team        — Teams team binding
//   Tier 6: account     — Account-scoped binding
//   Tier 7: channel     — Channel-wide catch-all (lowest priority)
//
// If no binding matches, falls through to the default agent ("main").
//
// Bindings are persisted in SQLite (~/.wintermolt/routing.db) and can be
// managed at runtime via the /route REPL command or the route_manage tool.

const std = @import("std");
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
extern fn sqlite3_bind_int(stmt: *sqlite3_stmt, index: c_int, value: c_int) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_int(stmt: *sqlite3_stmt, col: c_int) c_int;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_TRANSIENT: isize = -1;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Binding priority tier (evaluated in this order, first match wins).
pub const BindingTier = enum(u8) {
    peer = 1,
    parent_peer = 2,
    guild_role = 3,
    guild = 4,
    team = 5,
    account = 6,
    channel = 7,
};

/// A routing binding: maps a match pattern to an agent ID.
pub const Binding = struct {
    id: []const u8, // UUID
    agent_id: []const u8, // Target agent
    tier: BindingTier,
    // Match criteria (null = wildcard / not applicable)
    platform: ?[]const u8,
    channel_id: ?[]const u8,
    peer_id: ?[]const u8,
    guild_id: ?[]const u8,
    team_id: ?[]const u8,
    account_id: ?[]const u8,
    roles: ?[]const u8, // Comma-separated role names
    enabled: bool,
};

/// Result of a route resolution.
pub const ResolvedRoute = struct {
    agent_id: []const u8,
    matched_tier: ?BindingTier,
    session_key: [128]u8, // Stack-allocated session key buffer
    session_key_len: usize,

    pub fn getSessionKey(self: *const ResolvedRoute) []const u8 {
        return self.session_key[0..self.session_key_len];
    }
};

/// Routing context extracted from an incoming message.
pub const RouteContext = struct {
    platform: []const u8,
    from: []const u8,
    channel: []const u8,
    thread_id: ?[]const u8 = null,
    guild: ?[]const u8 = null,
    roles: ?[]const u8 = null,
    team_id: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    parent_peer: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

pub const Router = struct {
    alloc: Allocator,
    db: ?*sqlite3,
    bindings: ArrayList(Binding),
    default_agent_id: []const u8,

    /// Initialize the router. Opens (or creates) ~/.wintermolt/routing.db.
    pub fn init(alloc: Allocator) Router {
        var db: ?*sqlite3 = null;
        const db_path = getRoutingDbPath(alloc) catch null;

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

        var self = Router{
            .alloc = alloc,
            .db = db,
            .bindings = .{},
            .default_agent_id = "main",
        };

        if (db != null) {
            self.runMigrations() catch {};
            self.loadBindings() catch {};
        }

        return self;
    }

    pub fn deinit(self: *Router) void {
        self.freeBindings();
        self.bindings.deinit(self.alloc);
        if (self.db) |d| _ = sqlite3_close(d);
    }

    /// Resolve which agent should handle this message.
    /// Evaluates bindings in tier order (1-7). First match wins.
    /// Falls back to default agent ("main") if no binding matches.
    pub fn resolve(self: *const Router, ctx: *const RouteContext) ResolvedRoute {
        // Tier 1: Peer binding (direct user match)
        if (self.findBinding(.peer, ctx)) |b| {
            return self.makeRoute(b, ctx);
        }

        // Tier 2: Parent peer (thread parent inheritance)
        if (ctx.parent_peer != null) {
            if (self.findBinding(.parent_peer, ctx)) |b| {
                return self.makeRoute(b, ctx);
            }
        }

        // Tier 3: Guild + roles
        if (ctx.guild != null and ctx.roles != null) {
            if (self.findBinding(.guild_role, ctx)) |b| {
                return self.makeRoute(b, ctx);
            }
        }

        // Tier 4: Guild only
        if (ctx.guild != null) {
            if (self.findBinding(.guild, ctx)) |b| {
                return self.makeRoute(b, ctx);
            }
        }

        // Tier 5: Team
        if (ctx.team_id != null) {
            if (self.findBinding(.team, ctx)) |b| {
                return self.makeRoute(b, ctx);
            }
        }

        // Tier 6: Account
        if (ctx.account_id != null) {
            if (self.findBinding(.account, ctx)) |b| {
                return self.makeRoute(b, ctx);
            }
        }

        // Tier 7: Channel catch-all
        if (self.findBinding(.channel, ctx)) |b| {
            return self.makeRoute(b, ctx);
        }

        // Default: route to "main" agent
        return self.makeDefaultRoute(ctx);
    }

    /// Add a new routing binding. Persists to SQLite.
    pub fn addBinding(
        self: *Router,
        agent_id: []const u8,
        tier: BindingTier,
        platform: ?[]const u8,
        channel_id: ?[]const u8,
        peer_id: ?[]const u8,
        guild_id: ?[]const u8,
        team_id: ?[]const u8,
        account_id: ?[]const u8,
        roles: ?[]const u8,
    ) ![]u8 {
        const uuid = generateUuid();

        if (self.db) |db| {
            const sql =
                "INSERT INTO bindings (id, agent_id, tier, platform, channel_id, peer_id, guild_id, team_id, account_id, roles, enabled) " ++
                "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1);";

            var stmt: ?*sqlite3_stmt = null;
            const rc = sqlite3_prepare_v2(db, sql, -1, &stmt, null);
            if (rc == SQLITE_OK and stmt != null) {
                const s = stmt.?;
                defer _ = sqlite3_finalize(s);
                self.bindOptionalText(s, 1, &uuid);
                self.bindOptionalText(s, 2, agent_id);
                _ = sqlite3_bind_int(s, 3, @intCast(@intFromEnum(tier)));
                self.bindNullableText(s, 4, platform);
                self.bindNullableText(s, 5, channel_id);
                self.bindNullableText(s, 6, peer_id);
                self.bindNullableText(s, 7, guild_id);
                self.bindNullableText(s, 8, team_id);
                self.bindNullableText(s, 9, account_id);
                self.bindNullableText(s, 10, roles);
                _ = sqlite3_step(s);
            }
        }

        // Reload bindings from DB to stay in sync
        self.freeBindings();
        self.bindings = .{};
        self.loadBindings() catch {};

        return self.alloc.dupe(u8, &uuid);
    }

    /// Remove a binding by ID. Returns true if found and removed.
    pub fn removeBinding(self: *Router, binding_id: []const u8) bool {
        if (self.db) |db| {
            const sql = "DELETE FROM bindings WHERE id = ?1;";
            var stmt: ?*sqlite3_stmt = null;
            const rc = sqlite3_prepare_v2(db, sql, -1, &stmt, null);
            if (rc == SQLITE_OK and stmt != null) {
                const s = stmt.?;
                defer _ = sqlite3_finalize(s);
                self.bindOptionalText(s, 1, binding_id);
                _ = sqlite3_step(s);
            }
        }

        // Reload
        self.freeBindings();
        self.bindings = .{};
        self.loadBindings() catch {};
        return true;
    }

    /// List all bindings as a formatted string. Caller owns the result.
    pub fn listBindings(self: *const Router, alloc: Allocator) ![]u8 {
        if (self.bindings.items.len == 0) {
            return alloc.dupe(u8, "No routing bindings configured. All messages route to default agent.\nUse /route add <agent> <tier> [platform] [channel] [peer] to add bindings.");
        }

        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try w.writeAll("Routing Bindings\n");
        try w.writeAll("════════════════\n");

        for (self.bindings.items) |b| {
            const tier_name = switch (b.tier) {
                .peer => "peer",
                .parent_peer => "parent",
                .guild_role => "guild+role",
                .guild => "guild",
                .team => "team",
                .account => "account",
                .channel => "channel",
            };
            const status = if (b.enabled) "ON" else "OFF";
            try std.fmt.format(w, "  [{s}] → agent:{s}  tier:{s}  [{s}]", .{ b.id[0..8], b.agent_id, tier_name, status });

            if (b.platform) |p| try std.fmt.format(w, "  platform:{s}", .{p});
            if (b.channel_id) |c| try std.fmt.format(w, "  channel:{s}", .{c});
            if (b.peer_id) |p| try std.fmt.format(w, "  peer:{s}", .{p});
            if (b.guild_id) |g| try std.fmt.format(w, "  guild:{s}", .{g});
            if (b.team_id) |t| try std.fmt.format(w, "  team:{s}", .{t});
            if (b.roles) |r| try std.fmt.format(w, "  roles:{s}", .{r});

            try w.writeByte('\n');
        }

        try std.fmt.format(w, "\nDefault agent: {s}\n", .{self.default_agent_id});

        return buf.toOwnedSlice(alloc);
    }

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    fn findBinding(self: *const Router, tier: BindingTier, ctx: *const RouteContext) ?*const Binding {
        for (self.bindings.items) |*b| {
            if (!b.enabled) continue;
            if (b.tier != tier) continue;

            // Platform match (null = any platform)
            if (b.platform) |bp| {
                if (!std.mem.eql(u8, bp, ctx.platform)) continue;
            }

            // Channel match
            if (b.channel_id) |bc| {
                if (!std.mem.eql(u8, bc, ctx.channel)) continue;
            }

            // Tier-specific matching
            switch (tier) {
                .peer => {
                    if (b.peer_id) |bp| {
                        if (!std.mem.eql(u8, bp, ctx.from)) continue;
                    } else continue; // peer tier requires peer_id
                },
                .parent_peer => {
                    if (b.peer_id) |bp| {
                        if (ctx.parent_peer) |pp| {
                            if (!std.mem.eql(u8, bp, pp)) continue;
                        } else continue;
                    } else continue;
                },
                .guild_role => {
                    if (b.guild_id) |bg| {
                        if (ctx.guild) |cg| {
                            if (!std.mem.eql(u8, bg, cg)) continue;
                        } else continue;
                    } else continue;
                    // Check role overlap
                    if (b.roles) |br| {
                        if (ctx.roles) |cr| {
                            if (!rolesOverlap(br, cr)) continue;
                        } else continue;
                    } else continue;
                },
                .guild => {
                    if (b.guild_id) |bg| {
                        if (ctx.guild) |cg| {
                            if (!std.mem.eql(u8, bg, cg)) continue;
                        } else continue;
                    } else continue;
                },
                .team => {
                    if (b.team_id) |bt| {
                        if (ctx.team_id) |ct| {
                            if (!std.mem.eql(u8, bt, ct)) continue;
                        } else continue;
                    } else continue;
                },
                .account => {
                    if (b.account_id) |ba| {
                        if (ctx.account_id) |ca| {
                            if (!std.mem.eql(u8, ba, ca)) continue;
                        } else continue;
                    } else continue;
                },
                .channel => {
                    // Channel-level catch-all: platform + channel already matched above
                },
            }

            return b;
        }
        return null;
    }

    fn makeRoute(self: *const Router, binding: *const Binding, ctx: *const RouteContext) ResolvedRoute {
        _ = self;
        var result = ResolvedRoute{
            .agent_id = binding.agent_id,
            .matched_tier = binding.tier,
            .session_key = undefined,
            .session_key_len = 0,
        };
        result.session_key_len = buildSessionKey(&result.session_key, binding.agent_id, ctx);
        return result;
    }

    fn makeDefaultRoute(self: *const Router, ctx: *const RouteContext) ResolvedRoute {
        var result = ResolvedRoute{
            .agent_id = self.default_agent_id,
            .matched_tier = null,
            .session_key = undefined,
            .session_key_len = 0,
        };
        result.session_key_len = buildSessionKey(&result.session_key, self.default_agent_id, ctx);
        return result;
    }

    fn loadBindings(self: *Router) !void {
        const db = self.db orelse return;

        const sql = "SELECT id, agent_id, tier, platform, channel_id, peer_id, guild_id, team_id, account_id, roles, enabled FROM bindings ORDER BY tier ASC;";
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(db, sql, -1, &stmt, null);
        if (rc != SQLITE_OK or stmt == null) return;
        const s = stmt.?;
        defer _ = sqlite3_finalize(s);

        while (sqlite3_step(s) == SQLITE_ROW) {
            const tier_int = sqlite3_column_int(s, 2);
            const tier: BindingTier = std.meta.intToEnum(BindingTier, @as(u8, @intCast(tier_int))) catch continue;

            try self.bindings.append(self.alloc, .{
                .id = try dupeCol(self.alloc, s, 0),
                .agent_id = try dupeCol(self.alloc, s, 1),
                .tier = tier,
                .platform = try dupeColNullable(self.alloc, s, 3),
                .channel_id = try dupeColNullable(self.alloc, s, 4),
                .peer_id = try dupeColNullable(self.alloc, s, 5),
                .guild_id = try dupeColNullable(self.alloc, s, 6),
                .team_id = try dupeColNullable(self.alloc, s, 7),
                .account_id = try dupeColNullable(self.alloc, s, 8),
                .roles = try dupeColNullable(self.alloc, s, 9),
                .enabled = sqlite3_column_int(s, 10) != 0,
            });
        }
    }

    fn freeBindings(self: *Router) void {
        for (self.bindings.items) |b| {
            self.alloc.free(b.id);
            self.alloc.free(b.agent_id);
            if (b.platform) |p| self.alloc.free(p);
            if (b.channel_id) |c| self.alloc.free(c);
            if (b.peer_id) |p| self.alloc.free(p);
            if (b.guild_id) |g| self.alloc.free(g);
            if (b.team_id) |t| self.alloc.free(t);
            if (b.account_id) |a| self.alloc.free(a);
            if (b.roles) |r| self.alloc.free(r);
        }
    }

    fn runMigrations(self: *Router) !void {
        const db = self.db orelse return;
        const schema =
            "PRAGMA journal_mode=WAL;" ++
            "CREATE TABLE IF NOT EXISTS bindings (" ++
            "  id         TEXT PRIMARY KEY," ++
            "  agent_id   TEXT NOT NULL," ++
            "  tier       INTEGER NOT NULL," ++
            "  platform   TEXT," ++
            "  channel_id TEXT," ++
            "  peer_id    TEXT," ++
            "  guild_id   TEXT," ++
            "  team_id    TEXT," ++
            "  account_id TEXT," ++
            "  roles      TEXT," ++
            "  enabled    INTEGER DEFAULT 1," ++
            "  created_at INTEGER DEFAULT (strftime('%s','now'))" ++
            ");" ++
            "CREATE INDEX IF NOT EXISTS idx_bindings_tier ON bindings(tier);" ++
            "CREATE INDEX IF NOT EXISTS idx_bindings_agent ON bindings(agent_id);";

        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(db, schema, null, null, &errmsg);
        if (rc != SQLITE_OK) {
            if (errmsg) |msg| sqlite3_free(@ptrCast(msg));
            return error.MigrationFailed;
        }
    }

    fn bindOptionalText(self: *const Router, stmt: *sqlite3_stmt, index: c_int, value: []const u8) void {
        _ = self;
        _ = sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), SQLITE_TRANSIENT);
    }

    fn bindNullableText(self: *const Router, stmt: *sqlite3_stmt, index: c_int, value: ?[]const u8) void {
        _ = self;
        if (value) |v| {
            _ = sqlite3_bind_text(stmt, index, v.ptr, @intCast(v.len), SQLITE_TRANSIENT);
        } else {
            const sqlite3_bind_null = @extern(*const fn (*sqlite3_stmt, c_int) callconv(.c) c_int, .{ .name = "sqlite3_bind_null" });
            _ = sqlite3_bind_null(stmt, index);
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a session key: "agent:{agentId}:{platform}:{channel}:{from}"
fn buildSessionKey(buf: *[128]u8, agent_id: []const u8, ctx: *const RouteContext) usize {
    const result = std.fmt.bufPrint(buf, "agent:{s}:{s}:{s}:{s}", .{
        agent_id,
        ctx.platform,
        truncate(ctx.channel, 24),
        truncate(ctx.from, 24),
    }) catch return 0;
    return result.len;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
}

/// Check if any role in binding_roles (comma-separated) appears in context_roles (comma-separated).
fn rolesOverlap(binding_roles: []const u8, context_roles: []const u8) bool {
    var b_iter = std.mem.splitScalar(u8, binding_roles, ',');
    while (b_iter.next()) |br| {
        const btrimmed = std.mem.trim(u8, br, " \t");
        if (btrimmed.len == 0) continue;
        var c_iter = std.mem.splitScalar(u8, context_roles, ',');
        while (c_iter.next()) |cr| {
            const ctrimmed = std.mem.trim(u8, cr, " \t");
            if (std.mem.eql(u8, btrimmed, ctrimmed)) return true;
        }
    }
    return false;
}

fn dupeCol(alloc: Allocator, stmt: *sqlite3_stmt, col: c_int) ![]u8 {
    const raw = sqlite3_column_text(stmt, col);
    if (raw) |ptr| return alloc.dupe(u8, std.mem.span(ptr));
    return alloc.dupe(u8, "");
}

fn dupeColNullable(alloc: Allocator, stmt: *sqlite3_stmt, col: c_int) !?[]u8 {
    const raw = sqlite3_column_text(stmt, col);
    if (raw) |ptr| {
        const span = std.mem.span(ptr);
        if (span.len == 0) return null;
        return try alloc.dupe(u8, span);
    }
    return null;
}

fn getRoutingDbPath(alloc: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
    defer alloc.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    return std.fmt.allocPrint(alloc, "{s}/.wintermolt/routing.db", .{home});
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
