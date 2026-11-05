// Copyright The Fantastic Planet - By David Clabaugh
//
// setup.zig — API key configuration
//
// Interactive CLI for configuring API keys and optional services.
// Saves to ~/.wintermolt/.env which loadDotEnv() reads on every startup.
//
// Triggers:
//   - Explicitly via `wintermolt --keys` or `wintermolt --setup`

const std = @import("std");
const compat = @import("compat.zig");
const stdio = @import("stdio.zig");
const fsio = @import("fsio.zig");
const config_mod = @import("agent/config.zig");

pub const ApiKey = struct { key: []const u8, label: []const u8, hint: ?[]const u8 };

/// The keys /keys sets and the web UI's Keys panel shows (set or not, never the value).
pub const api_keys = [_]ApiKey{
    .{ .key = "ANTHROPIC_API_KEY", .label = "Anthropic (Claude)", .hint = "sk-ant-" },
    .{ .key = "OPENAI_API_KEY", .label = "OpenAI (GPT + TTS)", .hint = "sk-" },
    .{ .key = "GOOGLE_GEMINI_API_KEY", .label = "Google Gemini", .hint = "AIza" },
    .{ .key = "DEEPSEEK_API_KEY", .label = "DeepSeek", .hint = "sk-" },
    .{ .key = "QWEN_API_KEY", .label = "Qwen", .hint = null },
    .{ .key = "PINECONE_API_KEY", .label = "Pinecone (RAG)", .hint = null },
    .{ .key = "PINECONE_HOST", .label = "Pinecone Host URL", .hint = "https://" },
    .{ .key = "ELEVENLABS_API_KEY", .label = "ElevenLabs (voice)", .hint = null },
    .{ .key = "DEEPGRAM_API_KEY", .label = "Deepgram (voice in and out)", .hint = null },
    .{ .key = "DISCORD_BOT_TOKEN", .label = "Discord Bot", .hint = null },
    .{ .key = "TELEGRAM_BOT_TOKEN", .label = "Telegram Bot", .hint = null },
    .{ .key = "SLACK_BOT_TOKEN", .label = "Slack Bot", .hint = "xoxb-" },
    .{ .key = "SLACK_APP_TOKEN", .label = "Slack App", .hint = "xapp-" },
};

/// Key-value pair for .env file generation
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Run the interactive OOBE setup wizard.
/// After completion, ~/.wintermolt/.env will contain all configured keys.
pub fn runSetup(alloc: std.mem.Allocator, force: bool) !void {
    const stdout = stdio.stdout();
    var stdin_reader = stdio.stdinReader();
    const stdin = &stdin_reader;

    // Load existing values if re-running setup
    var existing = loadExistingEnv(alloc);

    // Print banner
    try stdout.writeAll("\x1b[36m");
    try stdout.writeAll(
        \\
        \\ ╔══════════════════════════════════════════════╗
        \\ ║         WINTERMOLT  ·  First-Run Setup        ║
        \\ ╚══════════════════════════════════════════════╝
        \\
    );
    try stdout.writeAll("\x1b[0m");
    try stdout.writeAll(
        \\
        \\ Welcome! Let's configure your AI assistant.
        \\ Settings are saved to ~/.wintermolt/.env
        \\
    );

    if (force and existing.count() > 0) {
        try stdout.writeAll(" \x1b[90m(Existing values shown as defaults — press Enter to keep)\x1b[0m\n");
    }

    // Collect keys
    var keys: std.ArrayList(KeyValue) = .empty;
    var line_buf: [4096]u8 = undefined;

    // ─── AI Providers (all optional, press Enter to skip) ──
    try stdout.writeAll("\n \x1b[1;33m─── AI Providers (press Enter to skip) ──────\x1b[0m\n");
    try stdout.writeAll(" \x1b[90mDefault backend: Ollama (local, no key needed)\x1b[0m\n");

    // 1. Anthropic API Key (optional)
    const anthropic_key = try promptKey(
        stdin,
        stdout,
        &line_buf,
        " \x1b[1m1.\x1b[0m Anthropic API Key (Claude)",
        "sk-ant-",
        existing.get("ANTHROPIC_API_KEY"),
        false,
    );
    if (anthropic_key) |key| {
        try keys.append(alloc, .{ .key = "ANTHROPIC_API_KEY", .value = key });
    }

    // 2. OpenAI API Key
    const openai_key = try promptKey(
        stdin,
        stdout,
        &line_buf,
        " \x1b[1m2.\x1b[0m OpenAI API Key (GPT fallback)",
        "sk-",
        existing.get("OPENAI_API_KEY"),
        false,
    );
    if (openai_key) |key| {
        try keys.append(alloc, .{ .key = "OPENAI_API_KEY", .value = key });
    }

    // 3. Google Gemini API Key
    const gemini_key = try promptKey(
        stdin,
        stdout,
        &line_buf,
        " \x1b[1m3.\x1b[0m Google Gemini API Key",
        "AIza",
        existing.get("GOOGLE_GEMINI_API_KEY"),
        false,
    );
    if (gemini_key) |key| {
        try keys.append(alloc, .{ .key = "GOOGLE_GEMINI_API_KEY", .value = key });
    }

    // 4. Pinecone (RAG memory)
    const pinecone_key = try promptKey(
        stdin,
        stdout,
        &line_buf,
        " \x1b[1m4.\x1b[0m Pinecone API Key (RAG memory)",
        null,
        existing.get("PINECONE_API_KEY"),
        false,
    );
    if (pinecone_key) |key| {
        try keys.append(alloc, .{ .key = "PINECONE_API_KEY", .value = key });

        // 4b. Pinecone Host (required if key provided)
        const pinecone_host = try promptKey(
            stdin,
            stdout,
            &line_buf,
            "    \x1b[1m4b.\x1b[0m Pinecone Host URL",
            "https://",
            existing.get("PINECONE_HOST"),
            true, // required since key was provided
        );
        if (pinecone_host) |host| {
            try keys.append(alloc, .{ .key = "PINECONE_HOST", .value = host });
        }
    }

    // ─── Voice ──────────────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Voice (press Enter to skip) ────────────\x1b[0m\n");
    try stdout.writeAll(" \x1b[90mYour own key, from console.deepgram.com. It speaks the replies, and hears /listen\x1b[0m\n");
    try stdout.writeAll(" \x1b[90mwhen no local whisper.cpp model is installed (or WINTERMOLT_STT_PROVIDER=deepgram).\x1b[0m\n");
    const deepgram_key = try promptKey(stdin, stdout, &line_buf, " \x1b[1m5.\x1b[0m Deepgram API Key (voice in and out)", null, existing.get("DEEPGRAM_API_KEY"), false);
    if (deepgram_key) |key| try keys.append(alloc, .{ .key = "DEEPGRAM_API_KEY", .value = key });

    // ─── Model Selection ────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Model Selection ────────────────────────\x1b[0m\n");
    try stdout.writeAll(" \x1b[1m6.\x1b[0m Default model tier (Ollama local):\n");
    try stdout.writeAll("    \x1b[90m[1]\x1b[0m Sonnet — qwen3:0.6b (balanced, default)\n");
    try stdout.writeAll("    \x1b[90m[2]\x1b[0m Haiku  — qwen3:0.6b (fast, lightweight)\n");
    try stdout.writeAll("    \x1b[90m[3]\x1b[0m Opus   — qwen3:8b (most capable)\n");

    const tier_choice = try promptKey(stdin, stdout, &line_buf, "     Choice (1/2/3)", null, existing.get("WINTERMOLT_TIER"), false);
    if (tier_choice) |choice| {
        if (std.mem.eql(u8, choice, "2") or std.mem.eql(u8, choice, "haiku")) {
            try keys.append(alloc, .{ .key = "WINTERMOLT_TIER", .value = "haiku" });
        } else if (std.mem.eql(u8, choice, "3") or std.mem.eql(u8, choice, "opus")) {
            try keys.append(alloc, .{ .key = "WINTERMOLT_TIER", .value = "opus" });
        }
        // Default (1/sonnet) = no WINTERMOLT_TIER needed
    }

    // ─── Chat Platforms ─────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Chat Platforms (press Enter to skip) ───\x1b[0m\n");

    const discord_token = try promptKey(stdin, stdout, &line_buf, " \x1b[1m7.\x1b[0m Discord Bot Token", null, existing.get("DISCORD_BOT_TOKEN"), false);
    if (discord_token) |key| try keys.append(alloc, .{ .key = "DISCORD_BOT_TOKEN", .value = key });

    const telegram_token = try promptKey(stdin, stdout, &line_buf, " \x1b[1m8.\x1b[0m Telegram Bot Token", null, existing.get("TELEGRAM_BOT_TOKEN"), false);
    if (telegram_token) |key| try keys.append(alloc, .{ .key = "TELEGRAM_BOT_TOKEN", .value = key });

    const slack_token = try promptKey(stdin, stdout, &line_buf, " \x1b[1m9.\x1b[0m Slack Bot Token", "xoxb-", existing.get("SLACK_BOT_TOKEN"), false);
    if (slack_token) |key| {
        try keys.append(alloc, .{ .key = "SLACK_BOT_TOKEN", .value = key });
        const slack_app = try promptKey(stdin, stdout, &line_buf, "     \x1b[1m9b.\x1b[0m Slack App Token", "xapp-", existing.get("SLACK_APP_TOKEN"), false);
        if (slack_app) |app| try keys.append(alloc, .{ .key = "SLACK_APP_TOKEN", .value = app });
    }

    // ─── Tool Policies ──────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Tool Policies ──────────────────────────\x1b[0m\n");
    try stdout.writeAll(" \x1b[1m10.\x1b[0m Restrict tools? (for shared/cloud deployments)\n");
    try stdout.writeAll("    \x1b[90m[Enter]\x1b[0m All tools enabled (default)\n");
    try stdout.writeAll("    \x1b[90m[block]\x1b[0m Block specific tools (e.g. \"bash\")\n");

    const policy_choice = try promptKey(stdin, stdout, &line_buf, "    Blocklist", null, existing.get("WINTERMOLT_TOOL_BLOCKLIST"), false);
    if (policy_choice) |blocklist| {
        if (blocklist.len > 0 and !std.mem.eql(u8, blocklist, "none")) {
            try keys.append(alloc, .{ .key = "WINTERMOLT_TOOL_BLOCKLIST", .value = blocklist });
        }
    }

    // ─── Local AI ────────────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Local AI (default backend) ─────────────\x1b[0m\n");

    // Check for Ollama
    try stdout.writeAll(" Checking for Ollama... ");
    const ollama_result = checkOllama(alloc);
    if (ollama_result.detected) {
        try stdout.writeAll("\x1b[32m✓\x1b[0m Ollama detected at localhost:11434");
        if (ollama_result.models) |models| {
            try stdout.print(" ({s})", .{models});
        }
        try stdout.writeByte('\n');
    } else {
        try stdout.writeAll("\x1b[33m✗ Ollama not found.\x1b[0m\n");
        try stdout.writeAll("   \x1b[1mOllama is the default backend.\x1b[0m Install from \x1b[4mhttps://ollama.ai\x1b[0m\n");
        try stdout.writeAll("   Then: ollama pull qwen3:0.6b\n");
    }

    // ─── Write .env ──────────────────────────
    try stdout.writeAll("\n");

    if (keys.items.len == 0) {
        try stdout.writeAll(" \x1b[33mNo keys configured. Nothing to save.\x1b[0m\n\n");
        return;
    }

    // Ensure ~/.wintermolt/ directory exists
    const env_path = try ensureWintermoltDir(alloc);

    saveEnv(alloc, fsio.io(), fsio.cwd(), env_path, keys.items) catch |e| {
        stdio.stderr().print(" \x1b[31mFailed to write {s}: {s}\x1b[0m\n", .{ env_path, @errorName(e) }) catch {};
        return e;
    };

    // ─── Summary ─────────────────────────────
    try stdout.writeAll(" \x1b[1;33m─── Summary ────────────────────────────────\x1b[0m\n");
    try stdout.print(" \x1b[32mSaved to\x1b[0m {s}\n", .{env_path});

    for (keys.items) |kv| {
        // Show masked values
        if (kv.value.len > 8) {
            try stdout.print("   {s}={s}...{s}\n", .{ kv.key, kv.value[0..4], kv.value[kv.value.len - 4 ..] });
        } else {
            try stdout.print("   {s}=***\n", .{kv.key});
        }
    }

    const key_count = keys.items.len;
    try stdout.print("   \x1b[90m({d} key{s} configured", .{ key_count, if (key_count != 1) "s" else "" });
    if (ollama_result.detected) {
        try stdout.writeAll(", Ollama: yes");
    }
    try stdout.writeAll(")\x1b[0m\n");

    try stdout.writeAll("\n \x1b[1;32mRun 'wintermolt' to start!\x1b[0m");
    try stdout.writeAll(" Or '\x1b[90mwintermolt --setup\x1b[0m' to reconfigure.\n\n");
}

/// Check if the .env file exists at ~/.wintermolt/.env
pub fn envFileExists() bool {
    const home = compat.getenv("HOME") orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/.env", .{home}) catch return false;
    fsio.access(path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Prompt for a key value with optional format hint and existing default.
fn promptKey(
    stdin: anytype,
    stdout: anytype,
    buf: *[4096]u8,
    label: []const u8,
    prefix_hint: ?[]const u8,
    existing_val: ?[]const u8,
    required: bool,
) !?[]const u8 {
    // Build prompt line
    try stdout.print("{s}", .{label});

    if (existing_val) |val| {
        if (val.len > 8) {
            try stdout.print(" \x1b[90m[{s}...{s}]\x1b[0m", .{ val[0..4], val[val.len - 4 ..] });
        } else if (val.len > 0) {
            try stdout.print(" \x1b[90m[***]\x1b[0m", .{});
        }
    }

    try stdout.writeAll(": ");

    const line = stdin.readUntilDelimiter(buf, '\n') catch |e| {
        if (e == error.EndOfStream) return null;
        return e;
    };
    drainPastedInput(); // consume any extra lines from multi-line pastes
    const trimmed = std.mem.trim(u8, line, " \t\r");

    // Empty input: return existing value if available, or null
    if (trimmed.len == 0) {
        if (existing_val) |val| {
            if (val.len > 0) return val;
        }
        if (required) {
            try stdout.writeAll("   \x1b[31m^ Required.\x1b[0m ");
            if (prefix_hint) |hint| {
                try stdout.print("Must start with \"{s}\"\n", .{hint});
            } else {
                try stdout.writeByte('\n');
            }
            // Retry once
            try stdout.print("{s}: ", .{label});
            const retry = stdin.readUntilDelimiter(buf, '\n') catch return null;
            drainPastedInput();
            const retry_trimmed = std.mem.trim(u8, retry, " \t\r");
            if (retry_trimmed.len == 0) return null;
            return retry_trimmed;
        }
        return null;
    }

    // Validate format if prefix_hint provided
    if (prefix_hint) |hint| {
        if (!std.mem.startsWith(u8, trimmed, hint)) {
            try stdout.print("   \x1b[33m⚠ Expected prefix \"{s}\". Saving anyway.\x1b[0m\n", .{hint});
        }
    }

    return trimmed;
}

/// Drain any extra pasted input from stdin (e.g., multi-line pastes from
/// password managers). Delegates to compat.drainStdinNonBlocking — uses
/// poll/fcntl on POSIX and FlushConsoleInputBuffer on Windows.
fn drainPastedInput() void {
    compat.drainStdinNonBlocking();
}

const OllamaResult = struct {
    detected: bool,
    models: ?[]const u8,
};

/// Check if Ollama is running by hitting its API endpoint.
fn checkOllama(alloc: std.mem.Allocator) OllamaResult {
    // Spawn curl to check Ollama
    const curl_args = &[_][]const u8{
        "curl", "-s", "-m", "2", "http://localhost:11434/api/tags",
    };
    const run = fsio.runCapture(alloc, curl_args, 32768, null) catch
        return .{ .detected = false, .models = null };
    defer run.deinit(alloc);

    if (!run.exited or run.exit_code != 0) {
        return .{ .detected = false, .models = null };
    }

    // Try to extract model names from JSON response
    // Format: {"models":[{"name":"deepseek-r1:latest",...},...]
    const body = run.stdout;
    if (body.len == 0) return .{ .detected = false, .models = null };

    // Simple extraction — find model names
    var model_names: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var model_count: usize = 0;
    while (pos < body.len) {
        // Find "name":"
        const needle = "\"name\":\"";
        const idx = std.mem.indexOf(u8, body[pos..], needle) orelse break;
        const start = pos + idx + needle.len;
        if (start >= body.len) break;

        // Find closing quote
        const end_idx = std.mem.indexOfScalar(u8, body[start..], '"') orelse break;
        const name = body[start .. start + end_idx];

        if (model_count > 0) {
            model_names.append(alloc, ',') catch break;
            model_names.append(alloc, ' ') catch break;
        }
        model_names.appendSlice(alloc, name) catch break;
        model_count += 1;

        pos = start + end_idx + 1;
        if (model_count >= 5) break; // Show at most 5 models
    }

    if (model_count > 0) {
        return .{ .detected = true, .models = model_names.items };
    }

    return .{ .detected = true, .models = null };
}

/// Ensure ~/.wintermolt/ directory exists and return the .env file path.
fn ensureWintermoltDir(alloc: std.mem.Allocator) ![]const u8 {
    const home = compat.getenv("HOME") orelse return error.NoHome;

    // Create ~/.wintermolt/ if it doesn't exist
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
    fsio.makePath(dir_path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    return try std.fmt.allocPrint(alloc, "{s}/.wintermolt/.env", .{home});
}

const version_key = "WINTERMOLT_CONFIG_VERSION";

/// The keys the wizard asks about, plus its version stamp. On a re-run each
/// one's line is replaced by the new answer, or removed when there is none
/// (a cleared tier or blocklist). Every other line is the user's and is kept.
const wizard_keys = [_][]const u8{
    "ANTHROPIC_API_KEY",  "OPENAI_API_KEY",   "GOOGLE_GEMINI_API_KEY", "PINECONE_API_KEY",
    "PINECONE_HOST",      "DEEPGRAM_API_KEY", "WINTERMOLT_TIER",       "DISCORD_BOT_TOKEN",
    "TELEGRAM_BOT_TOKEN", "SLACK_BOT_TOKEN",  "SLACK_APP_TOKEN",       "WINTERMOLT_TOOL_BLOCKLIST",
    version_key,
};

const env_header =
    "# Wintermolt configuration — generated by `wintermolt --setup`\n" ++
    "# Edit manually or re-run `wintermolt --setup` to reconfigure.\n" ++
    "#\n" ++
    "# Shell env vars take precedence over values in this file.\n" ++
    "# To override: export WINTERMOLT_MODEL=qwen3:8b\n\n";

fn indexOfKey(keys: []const KeyValue, key: []const u8) ?usize {
    for (keys, 0..) |kv, i| if (std.mem.eql(u8, kv.key, key)) return i;
    return null;
}

/// Save the wizard's answers to the .env at `path`, creating it and its
/// directory if needed. A wizard key's first line is replaced in place (CRLF
/// kept) and its later duplicates dropped; new keys are appended; every line
/// the wizard did not ask about is kept byte for byte.
pub fn saveEnv(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, keys: []const KeyValue) !void {
    return mergeIntoEnv(gpa, io, dir, path, keys, &wizard_keys);
}

/// Set one key in the .env at `path` (null removes it), as /keys does.
/// Every other line is kept byte for byte.
pub fn setEnvKey(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, key: []const u8, value: ?[]const u8) !void {
    if (value) |v| return mergeIntoEnv(gpa, io, dir, path, &.{.{ .key = key, .value = v }}, &.{});
    return mergeIntoEnv(gpa, io, dir, path, &.{}, &.{key});
}

/// Write `keys` into the .env at `path`, in place where each already has a
/// line, and remove the lines of `drop` keys that `keys` leaves out.
fn mergeIntoEnv(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, keys: []const KeyValue, drop: []const []const u8) !void {
    const old: []u8 = dir.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => try gpa.alloc(u8, 0),
        else => return e,
    };
    defer gpa.free(old);

    var version_buf: [16]u8 = undefined;
    const version = try std.fmt.bufPrint(&version_buf, "{d}", .{config_mod.CONFIG_VERSION});
    var all: std.ArrayList(KeyValue) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, keys);
    try all.append(gpa, .{ .key = version_key, .value = version });
    const written = try gpa.alloc(bool, all.items.len);
    defer gpa.free(written);
    @memset(written, false);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (old.len == 0) try out.appendSlice(gpa, env_header);

    var start: usize = 0;
    while (start < old.len) {
        const nl = std.mem.indexOfScalarPos(u8, old, start, '\n');
        const end = nl orelse old.len;
        const line = old[start..end];
        start = end + 1;
        const key = if (parseEnvLine(line)) |kv| kv.key else "";
        const i = indexOfKey(all.items, key);
        const ours = key.len > 0 and (i != null or for (drop) |k| {
            if (std.mem.eql(u8, k, key)) break true;
        } else false);
        if (!ours) {
            try out.appendSlice(gpa, line);
            if (nl != null) try out.append(gpa, '\n');
            continue;
        }
        const at = i orelse continue; // asked about, no answer: the line goes
        if (written[at]) continue; // a duplicate
        written[at] = true;
        try out.print(gpa, "{s}={s}", .{ all.items[at].key, all.items[at].value });
        if (std.mem.endsWith(u8, line, "\r")) try out.append(gpa, '\r');
        try out.append(gpa, '\n');
    }

    const eol: []const u8 = if (std.mem.indexOf(u8, old, "\r\n") != null) "\r\n" else "\n";
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(gpa, eol);
    for (all.items, written) |kv, done| {
        if (!done) try out.print(gpa, "{s}={s}{s}", .{ kv.key, kv.value, eol });
    }

    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sep| {
        if (sep > 0) dir.createDirPath(io, path[0..sep]) catch {};
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// A .env line's key and value, parsed the way config.loadDotEnv parses it.
fn parseEnvLine(raw: []const u8) ?KeyValue {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const effective = if (std.mem.startsWith(u8, line, "export "))
        std.mem.trim(u8, line["export ".len..], " \t")
    else
        line;
    const eq = std.mem.indexOfScalar(u8, effective, '=') orelse return null;
    var value = std.mem.trim(u8, effective[eq + 1 ..], " \t");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = value[1 .. value.len - 1];
    }
    return .{ .key = std.mem.trim(u8, effective[0..eq], " \t"), .value = value };
}

/// Load existing key-value pairs from ~/.wintermolt/.env. Keys and values
/// point into the file text, allocated from `alloc` and never freed here, so
/// pass an arena (every caller does).
pub fn loadExistingEnv(alloc: std.mem.Allocator) std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);

    const home = compat.getenv("HOME") orelse return map;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/.env", .{home}) catch return map;

    const text = fsio.cwd().readFileAlloc(fsio.io(), path, alloc, .limited(1 << 20)) catch return map;

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |raw_line| {
        const kv = parseEnvLine(raw_line) orelse continue;
        map.put(kv.key, kv.value) catch continue;
    }

    return map;
}
