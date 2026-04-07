// Copyright The Fantastic Planet - By David Clabaugh
//
// config.zig — Wintermolt configuration loading
//
// Reads configuration from environment variables:
//   WINTERMOLT_MODEL         — Optional. Model ID (default: qwen3:0.6b via Ollama)
//   WINTERMOLT_TOKENS        — Optional. Max response tokens (default: 8192)
//   WINTERMOLT_NO_HISTORY    — Optional. Set to "1" to disable SQLite history
//   WINTERMOLT_OLLAMA_URL    — Optional. Ollama base URL (default: http://localhost:11434)
//   WINTERMOLT_OLLAMA_MODEL  — Optional. Ollama model (default: qwen3:0.6b)
//   WINTERMOLT_OLLAMA_CTX    — Optional. Context window cap (default: 4096). Prevents OOM.
//   WINTERMOLT_OLLAMA_KEEP_ALIVE — Optional. Model unload timer (default: "5m"). "0" unloads immediately.
//   WINTERMOLT_VISION_MODEL  — Optional. Vision model for /look (default: llava)
//   WINTERMOLT_VISION_BACKEND — Optional. Vision routing: "ollama" (default) or "openai"
//   OPENAI_API_KEY           — Optional. Enables OpenAI backend (/model openai)
//   WINTERMOLT_OPENAI_MODEL  — Optional. OpenAI model (default: "gpt-4o-mini")
//   DEEPSEEK_API_KEY         — Optional. Enables DeepSeek Cloud backend (/model deepseek)
//   QWEN_API_KEY             — Optional. Enables Qwen Cloud backend (/model qwen)
//   WINTERMOLT_QWEN_MODEL    — Optional. Qwen model (default: "qwen-plus")
//   GOOGLE_GEMINI_API_KEY    — Optional. Enables Gemini backend (/model gemini)
//   WINTERMOLT_GEMINI_MODEL  — Optional. Gemini model (default: "gemini-2.0-flash")
//   WINTERMOLT_WEB_PORT      — Optional. Web UI port (default: 3000)
//   PINECONE_API_KEY         — Optional. Enables RAG semantic search.
//   PINECONE_HOST            — Required if API key set. Index host URL.
//   PINECONE_INDEX           — Optional. Index name (default: "wintermolt")
//   WINTERMOLT_MAX_AGENTS      — Optional. Max concurrent agents in pool (default: 16)
//   WINTERMOLT_AGENT_IDLE_TIMEOUT — Optional. Seconds before idle agent eviction (default: 1800)
//   WINTERMOLT_TOOL_ALLOWLIST — Optional. Comma-separated: ONLY these tools enabled
//   WINTERMOLT_TOOL_BLOCKLIST — Optional. Comma-separated: these tools blocked
//   WINTERMOLT_SANDBOX       — Optional. "docker" or "1" to sandbox bash
//
// Chat platform tokens (for --chat mode):
//   DISCORD_BOT_TOKEN        — Discord bot token
//   TELEGRAM_BOT_TOKEN       — Telegram bot token
//   WHATSAPP_PHONE_ID        — WhatsApp Business phone number ID
//   WHATSAPP_ACCESS_TOKEN    — WhatsApp Business access token
//   SLACK_BOT_TOKEN          — Slack bot token
//   SLACK_APP_TOKEN          — Slack app-level token (for Socket Mode)
//   SIGNAL_PHONE_NUMBER      — Signal phone number (requires signal-cli)
//   IMESSAGE_APPLEID         — iMessage Apple ID (macOS only, via AppleScript)
//   IRC_SERVER               — IRC server address (e.g. irc.libera.chat:6697)
//   IRC_NICK                 — IRC nickname
//   IRC_CHANNELS             — Comma-separated IRC channels
//   GOOGLE_CHAT_CREDENTIALS  — Google Chat service account JSON path
//   TEAMS_APP_ID             — Microsoft Teams app ID
//   TEAMS_APP_PASSWORD       — Microsoft Teams app password
//   MATRIX_HOMESERVER        — Matrix homeserver URL
//   MATRIX_ACCESS_TOKEN      — Matrix access token
//   MATRIX_USER_ID           — Matrix user ID (@user:server)
//   FEISHU_APP_ID            — Feishu/Lark app ID
//   FEISHU_APP_SECRET        — Feishu/Lark app secret
//   LINE_CHANNEL_SECRET      — LINE channel secret
//   LINE_CHANNEL_TOKEN       — LINE channel access token
//   MATTERMOST_URL           — Mattermost server URL
//   MATTERMOST_TOKEN         — Mattermost bot token
//   NOSTR_PRIVATE_KEY        — Nostr private key (hex)
//   NOSTR_RELAYS             — Comma-separated Nostr relay URLs
//   TWITCH_CLIENT_ID         — Twitch client ID
//   TWITCH_ACCESS_TOKEN      — Twitch OAuth access token
//   TWITCH_CHANNELS          — Comma-separated Twitch channels
//   ROCKETCHAT_URL           — Rocket.Chat server URL
//   ROCKETCHAT_TOKEN         — Rocket.Chat auth token
//   ROCKETCHAT_USER_ID       — Rocket.Chat user ID
//   ZULIP_EMAIL              — Zulip bot email
//   ZULIP_API_KEY            — Zulip bot API key
//   ZULIP_SITE               — Zulip server URL
//   NEXTCLOUD_TALK_URL       — Nextcloud Talk server URL
//   NEXTCLOUD_TALK_TOKEN     — Nextcloud Talk token
//
// Google Workspace (Gmail, Calendar, Drive):
//   GOOGLE_CLIENT_ID         — OAuth2 client ID
//   GOOGLE_CLIENT_SECRET     — OAuth2 client secret
//   GOOGLE_REFRESH_TOKEN     — OAuth2 refresh token (offline access)
//
// TTS / Voice synthesis:
//   WINTERMOLT_TTS_PROVIDER  — Optional. TTS provider: "openai", "elevenlabs", "edge" (default: off)
//   WINTERMOLT_TTS_VOICE     — Optional. Voice name (default: "alloy" for OpenAI)
//   ELEVENLABS_API_KEY       — Optional. ElevenLabs API key
//   ELEVENLABS_VOICE_ID      — Optional. ElevenLabs voice ID

const std = @import("std");

/// Current config version.
pub const CONFIG_VERSION: u32 = 1;

/// Check config version from .env and print migration notices if needed.
pub fn migrateConfig() void {
    const version_str = std.posix.getenv("WINTERMOLT_CONFIG_VERSION") orelse "0";
    const version = std.fmt.parseInt(u32, version_str, 10) catch 0;

    if (version >= CONFIG_VERSION) return;

    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (version < 1) {
        stderr.writeAll("[config] Run 'wintermolt --setup' to configure, or set WINTERMOLT_CONFIG_VERSION=1 in .env\n") catch {};
    }
}

/// Load environment variables from ~/.wintermolt/.env if present.
/// Shell env vars take precedence (overwrite=0 in setenv).
/// Supports: KEY=VALUE, KEY="VALUE", KEY='VALUE', # comments, blank lines, export prefix.
pub fn loadDotEnv() void {
    const home = std.posix.getenv("HOME") orelse return;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/.env", .{home}) catch return;

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    var loaded: usize = 0;
    var iter = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const effective = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trim(u8, line["export ".len..], " \t")
        else
            line;

        const eq = std.mem.indexOfScalar(u8, effective, '=') orelse continue;
        const key = std.mem.trim(u8, effective[0..eq], " \t");
        var value = std.mem.trim(u8, effective[eq + 1 ..], " \t");

        if (value.len >= 2) {
            if ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
            {
                value = value[1 .. value.len - 1];
            }
        }

        if (key.len == 0 or key.len > 255 or value.len > 4095) continue;

        var key_z: [256]u8 = undefined;
        var val_z: [4096]u8 = undefined;
        @memcpy(key_z[0..key.len], key);
        key_z[key.len] = 0;
        @memcpy(val_z[0..value.len], value);
        val_z[value.len] = 0;

        if (std.posix.getenv(key_z[0..key.len :0]) != null) continue;

        _ = libc_setenv(key_z[0..key.len :0].ptr, val_z[0..value.len :0].ptr, 0);
        loaded += 1;
    }

    if (loaded > 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("[config] Loaded {d} vars from ~/.wintermolt/.env\n", .{loaded}) catch {};
    }
}

const libc_setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });

pub const Config = struct {
    api_key: []const u8,
    model: []const u8,
    max_tokens: u32,
    system_prompt: []const u8,
    history_enabled: bool,
    ollama_url: []const u8,
    ollama_model: []const u8,
    ollama_num_ctx: u32,
    ollama_keep_alive: []const u8,
    vision_model: []const u8,
    vision_backend: []const u8,
    // Multi-backend support
    openai_api_key: ?[]const u8,
    openai_model: []const u8,
    deepseek_cloud_key: ?[]const u8,
    qwen_api_key: ?[]const u8,
    qwen_model: []const u8,
    gemini_api_key: ?[]const u8,
    gemini_model: []const u8,
    // Pinecone RAG
    pinecone_api_key: ?[]const u8,
    pinecone_host: ?[]const u8,
    pinecone_index: []const u8,
    // Tailscale
    tailscale_api_key: ?[]const u8,
    // Tool policies
    tool_allowlist: ?[]const u8,
    tool_blocklist: ?[]const u8,
    // Docker sandbox
    sandbox_enabled: bool,
    sandbox_image: []const u8,
    sandbox_timeout: u32,
    sandbox_memory: []const u8,
    sandbox_network: []const u8,
    // TTS / Voice synthesis
    tts_provider: ?[]const u8,
    tts_voice: []const u8,
    elevenlabs_api_key: ?[]const u8,
    elevenlabs_voice_id: ?[]const u8,
    constitution_alloc: ?[]u8 = null,

    pub fn load(alloc: ?std.mem.Allocator) !Config {
        // Anthropic API key — optional cloud backend (default: local/Ollama)
        const api_key = std.posix.getenv("ANTHROPIC_API_KEY") orelse "";

        const model = std.posix.getenv("WINTERMOLT_MODEL") orelse
            "qwen3:0.6b";

        const max_tokens: u32 = blk: {
            const tokens_str = std.posix.getenv("WINTERMOLT_TOKENS") orelse break :blk 8192;
            break :blk std.fmt.parseInt(u32, tokens_str, 10) catch 8192;
        };

        const history_enabled = blk: {
            const no_hist = std.posix.getenv("WINTERMOLT_NO_HISTORY") orelse break :blk true;
            break :blk !std.mem.eql(u8, no_hist, "1");
        };

        const ollama_url = std.posix.getenv("WINTERMOLT_OLLAMA_URL") orelse
            std.posix.getenv("OLLAMA_HOST") orelse
            "http://localhost:11434";
        const ollama_model = std.posix.getenv("WINTERMOLT_OLLAMA_MODEL") orelse
            "qwen3:0.6b";
        const ollama_num_ctx: u32 = blk: {
            const ctx_str = std.posix.getenv("WINTERMOLT_OLLAMA_CTX") orelse break :blk 4096;
            break :blk std.fmt.parseInt(u32, ctx_str, 10) catch 4096;
        };
        const ollama_keep_alive = std.posix.getenv("WINTERMOLT_OLLAMA_KEEP_ALIVE") orelse
            "5m";
        const vision_model = std.posix.getenv("WINTERMOLT_VISION_MODEL") orelse
            "llava";
        const vision_backend = std.posix.getenv("WINTERMOLT_VISION_BACKEND") orelse
            "ollama";

        const openai_api_key = std.posix.getenv("OPENAI_API_KEY");
        const openai_model = std.posix.getenv("WINTERMOLT_OPENAI_MODEL") orelse
            "gpt-4o-mini";
        const deepseek_cloud_key = std.posix.getenv("DEEPSEEK_API_KEY");
        const qwen_api_key = std.posix.getenv("QWEN_API_KEY");
        const qwen_model = std.posix.getenv("WINTERMOLT_QWEN_MODEL") orelse
            "qwen-plus";
        const gemini_api_key = std.posix.getenv("GOOGLE_GEMINI_API_KEY");
        const gemini_model = std.posix.getenv("WINTERMOLT_GEMINI_MODEL") orelse
            "gemini-2.0-flash";

        // Pinecone RAG
        const pinecone_api_key = std.posix.getenv("PINECONE_API_KEY");
        const pinecone_host = std.posix.getenv("PINECONE_HOST");
        const pinecone_index = std.posix.getenv("PINECONE_INDEX") orelse "wintermolt";

        // Tailscale
        const tailscale_api_key = std.posix.getenv("TAILSCALE_API_KEY");

        // Tool policies
        const tool_allowlist = std.posix.getenv("WINTERMOLT_TOOL_ALLOWLIST");
        const tool_blocklist = std.posix.getenv("WINTERMOLT_TOOL_BLOCKLIST");

        // Docker sandbox
        const sandbox_enabled = blk: {
            const val = std.posix.getenv("WINTERMOLT_SANDBOX") orelse break :blk false;
            break :blk std.mem.eql(u8, val, "docker") or std.mem.eql(u8, val, "1");
        };
        const sandbox_image = std.posix.getenv("WINTERMOLT_SANDBOX_IMAGE") orelse "wintermolt-sandbox:latest";
        const sandbox_timeout: u32 = blk: {
            const val = std.posix.getenv("WINTERMOLT_SANDBOX_TIMEOUT") orelse break :blk 30;
            break :blk std.fmt.parseInt(u32, val, 10) catch 30;
        };
        const sandbox_memory = std.posix.getenv("WINTERMOLT_SANDBOX_MEMORY") orelse "256m";
        const sandbox_network = std.posix.getenv("WINTERMOLT_SANDBOX_NETWORK") orelse "none";

        // TTS / Voice
        const tts_provider = std.posix.getenv("WINTERMOLT_TTS_PROVIDER");
        const tts_voice = std.posix.getenv("WINTERMOLT_TTS_VOICE") orelse "alloy";
        const elevenlabs_api_key = std.posix.getenv("ELEVENLABS_API_KEY");
        const elevenlabs_voice_id = std.posix.getenv("ELEVENLABS_VOICE_ID");

        // Load constitution from file or use built-in default
        const constitution_result = if (alloc) |a| loadConstitution(a) else .{ null, default_constitution };
        const constitution_heap = constitution_result[0];
        const constitution_text = constitution_result[1];

        return .{
            .api_key = api_key,
            .model = model,
            .max_tokens = max_tokens,
            .system_prompt = constitution_text,
            .history_enabled = history_enabled,
            .ollama_url = ollama_url,
            .ollama_model = ollama_model,
            .ollama_num_ctx = ollama_num_ctx,
            .ollama_keep_alive = ollama_keep_alive,
            .vision_model = vision_model,
            .vision_backend = vision_backend,
            .openai_api_key = openai_api_key,
            .openai_model = openai_model,
            .deepseek_cloud_key = deepseek_cloud_key,
            .qwen_api_key = qwen_api_key,
            .qwen_model = qwen_model,
            .gemini_api_key = gemini_api_key,
            .gemini_model = gemini_model,
            .pinecone_api_key = pinecone_api_key,
            .pinecone_host = pinecone_host,
            .pinecone_index = pinecone_index,
            .tailscale_api_key = tailscale_api_key,
            .tool_allowlist = tool_allowlist,
            .tool_blocklist = tool_blocklist,
            .sandbox_enabled = sandbox_enabled,
            .sandbox_image = sandbox_image,
            .sandbox_timeout = sandbox_timeout,
            .sandbox_memory = sandbox_memory,
            .sandbox_network = sandbox_network,
            .tts_provider = tts_provider,
            .tts_voice = tts_voice,
            .elevenlabs_api_key = elevenlabs_api_key,
            .elevenlabs_voice_id = elevenlabs_voice_id,
            .constitution_alloc = constitution_heap,
        };
    }

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.constitution_alloc) |buf| {
            alloc.free(buf);
            self.constitution_alloc = null;
            self.system_prompt = default_constitution;
        }
    }

    /// Reload constitution from file. Returns true if loaded from file, false if using default.
    pub fn reloadConstitution(self: *Config, alloc: std.mem.Allocator) bool {
        if (self.constitution_alloc) |buf| {
            alloc.free(buf);
            self.constitution_alloc = null;
        }
        const result = loadConstitution(alloc);
        self.constitution_alloc = result[0];
        self.system_prompt = result[1];
        return result[0] != null;
    }

    pub fn isCustomConstitution(self: *const Config) bool {
        return self.constitution_alloc != null;
    }
};

fn loadConstitution(alloc: std.mem.Allocator) struct { ?[]u8, []const u8 } {
    if (std.posix.getenv("WINTERMOLT_CONSTITUTION")) |custom_path| {
        if (custom_path.len > 0) {
            const file = std.fs.cwd().openFile(custom_path, .{}) catch {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("[config] Warning: WINTERMOLT_CONSTITUTION={s} not found, using default\n", .{custom_path}) catch {};
                return loadConstitutionFromHome(alloc);
            };
            defer file.close();
            return readConstitutionFile(alloc, file, custom_path);
        }
    }
    return loadConstitutionFromHome(alloc);
}

fn loadConstitutionFromHome(alloc: std.mem.Allocator) struct { ?[]u8, []const u8 } {
    const home = std.posix.getenv("HOME") orelse return .{ null, default_constitution };

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/constitution.md", .{home}) catch
        return .{ null, default_constitution };

    const file = std.fs.cwd().openFile(path, .{}) catch
        return .{ null, default_constitution };
    defer file.close();
    return readConstitutionFile(alloc, file, path);
}

fn readConstitutionFile(alloc: std.mem.Allocator, file: std.fs.File, path: []const u8) struct { ?[]u8, []const u8 } {
    const stat = file.stat() catch return .{ null, default_constitution };
    if (stat.size == 0 or stat.size > 64 * 1024)
        return .{ null, default_constitution };

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch
        return .{ null, default_constitution };

    const n = file.readAll(buf) catch {
        alloc.free(buf);
        return .{ null, default_constitution };
    };

    if (n == 0) {
        alloc.free(buf);
        return .{ null, default_constitution };
    }

    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("[config] Loaded constitution from {s} ({d} bytes)\n", .{ path, n }) catch {};
    return .{ buf, buf[0..n] };
}

pub fn getConstitutionPath() ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.wintermolt/constitution.md", .{home}) catch return null;
    std.fs.cwd().access(path, .{}) catch return null;
    return "~/.wintermolt/constitution.md";
}

/// Build dynamic capabilities section from runtime config.
pub fn buildCapabilities(config: *const Config, alloc: std.mem.Allocator, tool_count: usize) ![]u8 {
    var buf: std.ArrayListAligned(u8, null) = .{};
    const w = buf.writer(alloc);

    try w.writeAll("\n\n## Active System Status (auto-generated)\n\n");

    try w.print("Tools: {d} registered\n", .{tool_count});

    try w.writeAll("\nAI Backends:\n");
    try w.print("  - Claude (primary): {s}\n", .{config.model});
    try w.print("  - Ollama (local): {s} at {s}\n", .{ config.ollama_model, config.ollama_url });
    if (config.openai_api_key != null)
        try w.print("  - OpenAI: {s}\n", .{config.openai_model});
    if (config.deepseek_cloud_key != null)
        try w.writeAll("  - DeepSeek Cloud\n");
    if (config.qwen_api_key != null)
        try w.print("  - Qwen Cloud: {s}\n", .{config.qwen_model});
    if (config.gemini_api_key != null)
        try w.print("  - Google Gemini: {s}\n", .{config.gemini_model});

    if (config.pinecone_api_key != null)
        try w.writeAll("\n  - Pinecone RAG: ON (semantic search)\n")
    else
        try w.writeAll("\n  - Pinecone RAG: OFF (no PINECONE_API_KEY)\n");

    if (config.tts_provider) |tts|
        try w.print("\n  - TTS: {s} (voice: {s})\n", .{ tts, config.tts_voice })
    else
        try w.writeAll("\n  - TTS: OFF\n");

    if (config.history_enabled)
        try w.writeAll("\nChat history: ON (SQLite persistent)\n")
    else
        try w.writeAll("\nChat history: OFF\n");

    return try alloc.dupe(u8, buf.items);
}

pub const default_constitution =
    \\You are Wintermolt, a helpful AI assistant powered by Claude.
    \\
    \\You are running as a local CLI application. You have access to tools for
    \\file operations, shell commands, web search, and more. Use them proactively
    \\when they would help answer the user's question.
    \\
    \\Be concise, accurate, and helpful. When you use tools, explain what you're
    \\doing and why. If a tool fails, try alternative approaches.
    \\
    \\You can see images when the user shares them (camera capture, screenshots).
    \\Describe what you see in detail when asked.
;
