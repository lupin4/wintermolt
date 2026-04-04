// Copyright The Fantastic Planet - By David Clabaugh
//
// setup.zig — First-run OOBE (Out-of-Box Experience) setup wizard
//
// Interactive CLI wizard that walks users through configuring API keys
// and optional services. Saves to ~/.wintermolt/.env which loadDotEnv()
// reads on every startup.
//
// Triggers:
//   - Automatically when ANTHROPIC_API_KEY not set AND no ~/.wintermolt/.env
//   - Explicitly via `wintermolt --setup`

const std = @import("std");

/// Key-value pair for .env file generation
const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Run the interactive OOBE setup wizard.
/// After completion, ~/.wintermolt/.env will contain all configured keys.
pub fn runSetup(alloc: std.mem.Allocator, force: bool) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

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
    var keys: std.ArrayList(KeyValue) = .{};
    var line_buf: [4096]u8 = undefined;

    // ─── Required ────────────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Required ────────────────────────────────\x1b[0m\n");

    // 1. Anthropic API Key
    const anthropic_key = try promptKey(
        stdin,
        stdout,
        &line_buf,
        " \x1b[1m1.\x1b[0m Anthropic API Key (Claude)",
        "sk-ant-",
        existing.get("ANTHROPIC_API_KEY"),
        true,
    );
    if (anthropic_key) |key| {
        try keys.append(alloc, .{ .key = "ANTHROPIC_API_KEY", .value = key });
    } else {
        // Anthropic key is required — abort setup
        try stderr.writeAll("\n \x1b[31mAnthropic API key is required. Setup aborted.\x1b[0m\n");
        try stderr.writeAll(" Get a key at: https://console.anthropic.com/settings/keys\n\n");
        return error.SetupAborted;
    }

    // ─── Optional ────────────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Optional (press Enter to skip) ──────────\x1b[0m\n");

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

    // ─── Model Selection ────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Model Selection ────────────────────────\x1b[0m\n");
    try stdout.writeAll(" \x1b[1m5.\x1b[0m Default Claude model:\n");
    try stdout.writeAll("    \x1b[90m[1]\x1b[0m Sonnet (balanced, default)\n");
    try stdout.writeAll("    \x1b[90m[2]\x1b[0m Haiku  (fast, cheaper)\n");
    try stdout.writeAll("    \x1b[90m[3]\x1b[0m Opus   (most capable, expensive)\n");

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

    const discord_token = try promptKey(stdin, stdout, &line_buf, " \x1b[1m6.\x1b[0m Discord Bot Token", null, existing.get("DISCORD_BOT_TOKEN"), false);
    if (discord_token) |key| try keys.append(alloc, .{ .key = "DISCORD_BOT_TOKEN", .value = key });

    const telegram_token = try promptKey(stdin, stdout, &line_buf, " \x1b[1m7.\x1b[0m Telegram Bot Token", null, existing.get("TELEGRAM_BOT_TOKEN"), false);
    if (telegram_token) |key| try keys.append(alloc, .{ .key = "TELEGRAM_BOT_TOKEN", .value = key });

    const slack_token = try promptKey(stdin, stdout, &line_buf, " \x1b[1m8.\x1b[0m Slack Bot Token", "xoxb-", existing.get("SLACK_BOT_TOKEN"), false);
    if (slack_token) |key| {
        try keys.append(alloc, .{ .key = "SLACK_BOT_TOKEN", .value = key });
        const slack_app = try promptKey(stdin, stdout, &line_buf, "     \x1b[1m8b.\x1b[0m Slack App Token", "xapp-", existing.get("SLACK_APP_TOKEN"), false);
        if (slack_app) |app| try keys.append(alloc, .{ .key = "SLACK_APP_TOKEN", .value = app });
    }

    // ─── Tool Policies ──────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Tool Policies ──────────────────────────\x1b[0m\n");
    try stdout.writeAll(" \x1b[1m9.\x1b[0m Restrict tools? (for shared/cloud deployments)\n");
    try stdout.writeAll("    \x1b[90m[Enter]\x1b[0m All tools enabled (default)\n");
    try stdout.writeAll("    \x1b[90m[block]\x1b[0m Block specific tools (e.g. \"bash\")\n");

    const policy_choice = try promptKey(stdin, stdout, &line_buf, "    Blocklist", null, existing.get("WINTERMOLT_TOOL_BLOCKLIST"), false);
    if (policy_choice) |blocklist| {
        if (blocklist.len > 0 and !std.mem.eql(u8, blocklist, "none")) {
            try keys.append(alloc, .{ .key = "WINTERMOLT_TOOL_BLOCKLIST", .value = blocklist });
        }
    }

    // ─── Local AI ────────────────────────────
    try stdout.writeAll("\n \x1b[1;33m─── Local AI ───────────────────────────────\x1b[0m\n");

    // Check for Ollama
    try stdout.writeAll(" \x1b[1m10.\x1b[0m Checking for Ollama... ");
    const ollama_result = checkOllama(alloc);
    if (ollama_result.detected) {
        try stdout.writeAll("\x1b[32m✓\x1b[0m Ollama detected at localhost:11434");
        if (ollama_result.models) |models| {
            try stdout.print(" ({s})", .{models});
        }
        try stdout.writeByte('\n');
    } else {
        try stdout.writeAll("\x1b[90m✗ Ollama not found.\x1b[0m\n");
        try stdout.writeAll("   Install from \x1b[4mhttps://ollama.ai\x1b[0m for local models\n");
    }

    // ─── Write .env ──────────────────────────
    try stdout.writeAll("\n");

    if (keys.items.len == 0) {
        try stdout.writeAll(" \x1b[33mNo keys configured. Nothing to save.\x1b[0m\n\n");
        return;
    }

    // Ensure ~/.wintermolt/ directory exists
    const env_path = try ensureWintermoltDir(alloc);

    // Write the .env file
    try writeEnvFile(env_path, keys.items);

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
    const home = std.posix.getenv("HOME") orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/.env", .{home}) catch return false;
    std.fs.cwd().access(path, .{}) catch return false;
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
/// password managers). Temporarily sets stdin to non-blocking, reads until
/// EAGAIN/EWOULDBLOCK, then restores blocking mode.
fn drainPastedInput() void {
    const fd = std.posix.STDIN_FILENO;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK: u32 = if (comptime @import("builtin").os.tag == .macos) 0x0004 else 0o4000;

    const flags = std.posix.system.fcntl(fd, F_GETFL);
    if (flags == -1) return;

    // Set non-blocking
    if (std.posix.system.fcntl(fd, F_SETFL, @as(u32, @bitCast(flags)) | O_NONBLOCK) == -1) return;

    // Drain all buffered input
    var drain_buf: [4096]u8 = undefined;
    while (true) {
        const rc = std.posix.system.read(fd, &drain_buf, drain_buf.len);
        if (rc <= 0) break;
    }

    // Restore blocking mode
    _ = std.posix.system.fcntl(fd, F_SETFL, flags);
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
    const args_slice = alloc.alloc([]const u8, curl_args.len) catch return .{ .detected = false, .models = null };
    for (curl_args, 0..) |arg, i| args_slice[i] = arg;

    var child = std.process.Child.init(args_slice, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return .{ .detected = false, .models = null };

    var stdout_buf: std.ArrayList(u8) = .{};
    var stderr_buf: std.ArrayList(u8) = .{};
    child.collectOutput(alloc, &stdout_buf, &stderr_buf, 32768) catch
        return .{ .detected = false, .models = null };
    const term = child.wait() catch
        return .{ .detected = false, .models = null };

    if (term != .Exited or term.Exited != 0) {
        return .{ .detected = false, .models = null };
    }

    // Try to extract model names from JSON response
    // Format: {"models":[{"name":"deepseek-r1:latest",...},...]
    const body = stdout_buf.items;
    if (body.len == 0) return .{ .detected = false, .models = null };

    // Simple extraction — find model names
    var model_names: std.ArrayList(u8) = .{};
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
    const home = std.posix.getenv("HOME") orelse return error.NoHome;

    // Create ~/.wintermolt/ if it doesn't exist
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt", .{home});
    std.fs.cwd().makePath(dir_path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    return try std.fmt.allocPrint(alloc, "{s}/.wintermolt/.env", .{home});
}

/// Write key-value pairs to the .env file.
/// Preserves existing keys not in the new set.
fn writeEnvFile(path: []const u8, keys: []const KeyValue) !void {
    // Build file content
    var content_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&content_buf);
    const w = stream.writer();

    try w.writeAll("# Wintermolt configuration — generated by `wintermolt --setup`\n");
    try w.writeAll("# Edit manually or re-run `wintermolt --setup` to reconfigure.\n");
    try w.writeAll("#\n");
    try w.writeAll("# Shell env vars take precedence over values in this file.\n");
    try w.writeAll("# To override: export ANTHROPIC_API_KEY=sk-ant-your-key-here\n\n");

    // Write config version stamp for migration tracking
    const config_mod = @import("agent/config.zig");
    try w.print("WINTERMOLT_CONFIG_VERSION={d}\n\n", .{config_mod.CONFIG_VERSION});

    for (keys) |kv| {
        try w.print("{s}={s}\n", .{ kv.key, kv.value });
    }

    // Convert path to null-terminated for open
    var path_z: [512]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const file = std.fs.cwd().createFile(path_z[0..path.len :0], .{ .truncate = true }) catch |e| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print(" \x1b[31mFailed to write {s}: {s}\x1b[0m\n", .{ path, @errorName(e) }) catch {};
        return e;
    };
    defer file.close();

    const written = stream.getWritten();
    file.writeAll(written) catch |e| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print(" \x1b[31mWrite failed: {s}\x1b[0m\n", .{@errorName(e)}) catch {};
        return e;
    };
}

/// Load existing key-value pairs from ~/.wintermolt/.env
fn loadExistingEnv(alloc: std.mem.Allocator) std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);

    const home = std.posix.getenv("HOME") orelse return map;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/.env", .{home}) catch return map;

    const file = std.fs.cwd().openFile(path, .{}) catch return map;
    defer file.close();

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

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

        // Strip quotes
        if (value.len >= 2) {
            if ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
            {
                value = value[1 .. value.len - 1];
            }
        }

        map.put(key, value) catch continue;
    }

    return map;
}
