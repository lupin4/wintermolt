//! wintermolt.json — one unified runtime config for models, personas, agents,
//! and sampling. Loaded from $WINTERMOLT_CONFIG_JSON or ~/.wintermolt/wintermolt.json.
//!
//! Entirely optional: an absent or invalid file means every field falls back to
//! .env / built-in defaults (config.zig). Secrets (API keys) stay in .env — this
//! file is the kind of thing you diff, share, or commit as an example.
//!
//! Precedence for any single value:  wintermolt.json > .env / env var > default.
//! Within the JSON, an agent layers over models, which layer over `defaults`.

const std = @import("std");
const compat = @import("../compat.zig");

pub const Sampling = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?i32 = null,
    repeat_penalty: ?f32 = null,
    max_tokens: ?u32 = null,
};

pub const ModelSpec = struct {
    name: ?[]const u8 = null,
    backend: ?[]const u8 = null,
};

/// Chat can run two models at once: a local on-device model (always available)
/// and a cloud API model (used only when its key is present in .env).
///   prefer "cloud" — API overrides local for chat; local still supports (tools,
///                    vision, and automatic fallback when the API is down/limited).
///   prefer "local" — local is primary; cloud is used only for hard queries the
///                    router escalates (looksComplex).
/// No cloud key present → local, always (full offline).
pub const ChatModel = struct {
    local: ?[]const u8 = null,
    cloud: ?[]const u8 = null,
    prefer: ?[]const u8 = null, // "cloud" | "local"
};

pub const Models = struct {
    chat: ?ChatModel = null,
    tool: ?ModelSpec = null, // local-only
    vision: ?ModelSpec = null, // local-only
};

/// Per-agent tool policy. `lut` selects how the tool menu is rendered into the
/// prompt: "broad" (names by area), "retrieved" (top-k relevant), "inline" (full).
pub const ToolConfig = struct {
    allow: ?[]const []const u8 = null,
    block: ?[]const []const u8 = null,
    lut: ?[]const u8 = null,
    max_decls: ?u32 = null,
};

pub const Defaults = struct {
    backend: ?[]const u8 = null,
    sampling: ?Sampling = null,
};

/// A runnable profile: persona + model + sampling + tools + backend. `persona`
/// is either a name referencing `personas{}` or inline text.
pub const Agent = struct {
    name: []const u8,
    persona: ?[]const u8 = null,
    model: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    sampling: ?Sampling = null,
    tools: ?ToolConfig = null,
};

pub const Schema = struct {
    version: ?u32 = null,
    defaults: ?Defaults = null,
    models: ?Models = null,
    persona: ?[]const u8 = null, // shortcut: direct persona text (highest precedence)
    active_persona: ?[]const u8 = null,
    personas: ?std.json.Value = null, // object: name -> prompt string
    active_agent: ?[]const u8 = null,
    agents: ?[]Agent = null,
};

/// Flattened, ready-to-consume view — the result of layering defaults → models →
/// active_agent. Every field is optional; null means "config.zig keeps its .env /
/// default value". config.zig applies this over its existing fields.
pub const Profile = struct {
    persona: ?[]const u8 = null,
    chat_local: ?[]const u8 = null, // on-device model (forai)
    chat_cloud: ?[]const u8 = null, // API model, used when its key is present
    chat_prefer: ?[]const u8 = null, // "cloud" | "local"
    tool_model: ?[]const u8 = null,
    vision_model: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    temperature: ?f32 = null,
    top_k: ?i32 = null,
    top_p: ?f32 = null,
    tool_allow: ?[]const []const u8 = null,
    tool_block: ?[]const []const u8 = null,
    lut: ?[]const u8 = null,
    max_decls: ?u32 = null,
};

/// Owns the parsed-JSON arena. Slices in `schema()`/`profile()` point into it,
/// so keep it alive for the config's lifetime, then `deinit`.
pub const Loaded = struct {
    parsed: std.json.Parsed(Schema),

    pub fn schema(self: *const Loaded) Schema {
        return self.parsed.value;
    }
    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
    }
};

/// Resolve a persona reference: if `ref` names an entry in `personas{}`, return
/// that prompt; otherwise treat `ref` as inline persona text.
pub fn resolvePersonaRef(s: Schema, ref: []const u8) []const u8 {
    if (s.personas) |pv| {
        if (pv == .object) {
            if (pv.object.get(ref)) |v| {
                if (v == .string) return v.string;
            }
        }
    }
    return ref; // inline text
}

/// Flatten the schema into a Profile by layering: defaults → models → active_agent.
pub fn resolve(s: Schema) Profile {
    var p: Profile = .{};

    // Layer 0 — defaults.
    if (s.defaults) |d| {
        if (d.backend) |b| p.backend = b;
        if (d.sampling) |sm| applySampling(&p, sm);
    }

    // Layer 1 — models{}.
    if (s.models) |m| {
        if (m.chat) |c| {
            if (c.local) |l| p.chat_local = l;
            if (c.cloud) |cl| p.chat_cloud = cl;
            if (c.prefer) |pf| p.chat_prefer = pf;
        }
        if (m.tool) |t| p.tool_model = t.name; // null name = parked
        if (m.vision) |v| p.vision_model = v.name;
    }

    // Persona: direct `persona` wins, else `active_persona` -> personas{}.
    if (s.persona) |direct| {
        p.persona = direct;
    } else if (s.active_persona) |name| {
        p.persona = resolvePersonaRef(s, name);
    }

    // Layer 2 — active_agent overrides everything it specifies.
    if (s.active_agent) |want| {
        if (s.agents) |agents| {
            for (agents) |a| {
                if (!std.mem.eql(u8, a.name, want)) continue;
                if (a.persona) |pr| p.persona = resolvePersonaRef(s, pr);
                if (a.model) |md| p.chat_local = md;
                if (a.backend) |b| p.backend = b;
                if (a.sampling) |sm| applySampling(&p, sm);
                if (a.tools) |tc| {
                    if (tc.allow) |al| p.tool_allow = al;
                    if (tc.block) |bl| p.tool_block = bl;
                    if (tc.lut) |l| p.lut = l;
                    if (tc.max_decls) |md| p.max_decls = md;
                }
                break;
            }
        }
    }
    return p;
}

fn applySampling(p: *Profile, sm: Sampling) void {
    if (sm.temperature) |t| p.temperature = t;
    if (sm.top_k) |k| p.top_k = k;
    if (sm.top_p) |tp| p.top_p = tp;
}

/// Load and parse the config file. Returns null when it is absent or unparseable
/// (the caller then falls back to .env / defaults). Logs on both success and
/// parse failure so a typo isn't silently ignored.
pub fn load(alloc: std.mem.Allocator) ?Loaded {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var path_buf: [512]u8 = undefined;
    const path: []const u8 = blk: {
        if (compat.getenv("WINTERMOLT_CONFIG_JSON")) |explicit| {
            if (explicit.len > 0) break :blk explicit;
        }
        const home = compat.getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/wintermolt.json", .{home}) catch return null;
    };

    const file = std.fs.cwd().openFile(path, .{}) catch return null; // absent = silent
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size == 0 or stat.size > 256 * 1024) return null;

    const bytes = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    defer alloc.free(bytes);
    const n = file.readAll(bytes) catch return null;

    const parsed = std.json.parseFromSlice(Schema, alloc, bytes[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| {
        stderr.print("[config] wintermolt.json parse error ({s}) — using .env / defaults\n", .{@errorName(e)}) catch {};
        return null;
    };

    stderr.print("[config] Loaded wintermolt.json from {s} ({d} bytes)\n", .{ path, n }) catch {};
    return .{ .parsed = parsed };
}
