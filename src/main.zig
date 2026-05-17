// Copyright The Fantastic Planet - By David Clabaugh
//
// main.zig — Wintermolt entry point
//
// Lite AI assistant CLI powered by Ollama (local) + multi-backend AI.
// Open-core: MIT. No forKernels, no proprietary subsystems.
//
// Usage:
//   wintermolt              — interactive REPL
//   wintermolt --help       — show help
//   wintermolt -e "prompt"  — single-shot execution
//   wintermolt --keys       — configure API keys
//   wintermolt --chat       — chat bridge mode (18 platforms)
//   wintermolt --web        — web UI mode
//   wintermolt --mcp-server — MCP JSON-RPC server over stdio

const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = std.ArrayList;
const config_mod = @import("agent/config.zig");
const loop_mod = @import("agent/loop.zig");
const chat_bridge = @import("chat/bridge.zig");
const web_bridge = @import("web/bridge.zig");
const menubar_bridge = @import("menubar/bridge.zig");
const router_mod = @import("agent/router.zig");
const pool_mod = @import("agent/agent_pool.zig");
const subagent_mod = @import("agent/subagent.zig");
const tts_mod = @import("agent/tts.zig");
const session_mod = @import("agent/session.zig");
const gateway_bridge = @import("gateway/bridge.zig");
const i18n = @import("agent/i18n.zig");
const extensions_mod = @import("agent/extensions.zig");
const tailscale_tool = @import("tools/tailscale.zig");
const camera = @import("tools/camera.zig");
const http_tool = @import("tools/http.zig");
const protocol = @import("api/protocol.zig");
const setup = @import("setup.zig");
const export_mod = @import("agent/export.zig");

const VERSION = "0.4.1";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Parse args
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip executable name

    var exec_prompt: ?[]const u8 = null;
    var chat_mode = false;
    var web_mode = false;
    var menubar_mode = false;
    var mcp_server_mode = false;
    var gateway_mode = false;
    var extension_cmd: ?[]const u8 = null;
    var extension_arg: ?[]const u8 = null;
    var run_setup = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stdout.print("wintermolt {s}\n", .{VERSION});
            return;
        }
        if (std.mem.eql(u8, arg, "--chat")) {
            chat_mode = true;
        }
        if (std.mem.eql(u8, arg, "--web")) {
            web_mode = true;
        }
        if (std.mem.eql(u8, arg, "--menubar")) {
            menubar_mode = true;
        }
        if (std.mem.eql(u8, arg, "--setup") or std.mem.eql(u8, arg, "--keys")) {
            run_setup = true;
        }
        if (std.mem.eql(u8, arg, "--mcp-server")) {
            mcp_server_mode = true;
        }
        if (std.mem.eql(u8, arg, "--gateway")) {
            gateway_mode = true;
        }
        if (std.mem.eql(u8, arg, "--extension")) {
            extension_cmd = args.next();
            extension_arg = args.next();
        }
        if (std.mem.eql(u8, arg, "-e")) {
            exec_prompt = args.next();
            if (exec_prompt == null) {
                try stderr.writeAll("Error: -e requires a prompt argument\n");
                std.process.exit(1);
            }
        }
    }

    // Handle --extension commands early (doesn't need API key or setup)
    if (extension_cmd) |cmd| {
        var ext_mgr = extensions_mod.ExtensionManager.init(alloc);
        if (std.mem.eql(u8, cmd, "list")) {
            const list = ext_mgr.listInstalled(alloc) catch |e| {
                try stderr.print("[extensions] Error: {s}\n", .{@errorName(e)});
                return;
            };
            defer alloc.free(list);
            try stdout.writeAll(list);
        } else if (std.mem.eql(u8, cmd, "available")) {
            const list = ext_mgr.listRemote(alloc) catch |e| {
                try stderr.print("[extensions] Error: {s}\n", .{@errorName(e)});
                return;
            };
            defer alloc.free(list);
            try stdout.writeAll(list);
        } else if (std.mem.eql(u8, cmd, "install")) {
            const name = extension_arg orelse {
                try stderr.writeAll("Usage: wintermolt --extension install <name>\n");
                return;
            };
            const result = ext_mgr.install(alloc, name) catch |e| {
                try stderr.print("[extensions] Error: {s}\n", .{@errorName(e)});
                return;
            };
            defer alloc.free(result);
            try stdout.writeAll(result);
            try stdout.writeByte('\n');
        } else if (std.mem.eql(u8, cmd, "remove")) {
            const name = extension_arg orelse {
                try stderr.writeAll("Usage: wintermolt --extension remove <name>\n");
                return;
            };
            const result = ext_mgr.remove(alloc, name) catch |e| {
                try stderr.print("[extensions] Error: {s}\n", .{@errorName(e)});
                return;
            };
            defer alloc.free(result);
            try stdout.writeAll(result);
            try stdout.writeByte('\n');
        } else {
            try stdout.writeAll("Usage: wintermolt --extension <list|available|install|remove> [name]\n");
        }
        return;
    }

    // Explicit --keys / --setup to configure API keys (no auto-trigger OOBE)
    if (run_setup) {
        setup.runSetup(alloc, true) catch |e| {
            if (e != error.SetupAborted) {
                try stderr.print("[setup] Error: {s}\n", .{@errorName(e)});
            }
        };
        return;
    }

    // Load .env file
    config_mod.loadDotEnv();
    config_mod.migrateConfig();

    // Load config
    var config = config_mod.Config.load(alloc) catch {
        std.process.exit(1);
    };
    defer config.deinit(alloc);

    // Wire Docker sandbox settings
    {
        const bash_mod = @import("tools/bash.zig");
        bash_mod.sandbox_enabled = config.sandbox_enabled;
        bash_mod.sandbox_image = config.sandbox_image;
        bash_mod.sandbox_timeout = config.sandbox_timeout;
        bash_mod.sandbox_memory = config.sandbox_memory;
        bash_mod.sandbox_network = config.sandbox_network;
    }

    // --mcp-server mode
    if (mcp_server_mode) {
        const mcp_server = @import("mcp/server.zig");
        try mcp_server.run(alloc);
        return;
    }

    // Initialize MCP client — connect to external MCP servers from ~/.wintermolt/mcp.json
    const mcp_client_mod = @import("mcp/client.zig");
    const tools_mod = @import("agent/tools.zig");
    var mcp_mgr = mcp_client_mod.McpClientManager.init(alloc);
    mcp_mgr.loadFromConfig() catch |e| {
        stderr.print("[mcp-client] Config load failed: {s}\n", .{@errorName(e)}) catch {};
    };
    if (mcp_mgr.toolCount() > 0) {
        tools_mod.setMcpManager(&mcp_mgr);
        stderr.print("[mcp-client] {d} remote tools available\n", .{mcp_mgr.toolCount()}) catch {};
    } else {
        tools_mod.setMcpManager(null);
    }
    defer {
        tools_mod.setMcpManager(null);
        mcp_mgr.deinit();
    }

    // Initialize agent loop
    var agent = try loop_mod.AgentLoop.init(alloc, &config);
    defer agent.deinit();

    // Re-register scheduler pointer — init() stored a pointer to a stack local that's now dead.
    // This points to agent's struct field which lives for the entire program.
    if (agent.scheduler) |*s| tools_mod.setScheduler(s);

    // Initialize subagent manager for spawn_agent tool
    var subagent_mgr = subagent_mod.SubagentManager.init(alloc);
    defer subagent_mgr.deinit();
    subagent_mgr.spawn_fn = &spawnSubagent;
    agent.subagent_manager = @ptrCast(&subagent_mgr);

    // Initialize session manager
    var session_mgr = session_mod.SessionManager.init(alloc);
    defer session_mgr.deinit();

    // Chat mode — multi-agent routing
    if (chat_mode) {
        try stderr.writeAll("[wintermolt] Starting chat mode (multi-agent)...\n");
        var bridge = chat_bridge.ChatBridge.init(alloc) catch |e| {
            try stderr.print("[wintermolt] Failed to start chat sidecar: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer bridge.deinit();

        // Initialize router, agent pool, and session manager for chat mode
        var router = router_mod.Router.init(alloc);
        defer router.deinit();

        var pool = pool_mod.AgentPool.init(alloc, &config);
        defer pool.deinit();

        var chat_sessions = session_mod.SessionManager.init(alloc);
        defer chat_sessions.deinit();

        if (router.bindings.items.len > 0) {
            try stderr.print("[wintermolt] Loaded {d} routing bindings\n", .{router.bindings.items.len});
        }

        while (bridge.readMessage()) |msg| {
            try stderr.print("[{s}] {s}: {s}\n", .{ msg.platform, msg.from, msg.text });

            // Build routing context from the incoming message
            const route_ctx = router_mod.RouteContext{
                .platform = msg.platform,
                .from = msg.from,
                .channel = msg.channel,
                .thread_id = msg.thread_id,
                .guild = msg.guild,
                .roles = msg.roles,
            };

            // Resolve which agent should handle this message
            const route = router.resolve(&route_ctx);

            // Get or create the agent from the pool
            const routed_agent = pool.getOrCreate(route.agent_id) catch |e| {
                try stderr.print("[Error] Agent pool failed: {s}\n", .{@errorName(e)});
                continue;
            };

            // Ensure agent has a conversation started
            if (routed_agent.conversation_id == null) {
                routed_agent.startConversation();
            }

            // Track session
            const session_id = chat_sessions.getOrCreateSession(
                route.agent_id,
                msg.platform,
                msg.channel,
                msg.from,
            ) catch null;
            if (session_id) |sid| {
                chat_sessions.recordMessage(sid);
                alloc.free(sid);
            }

            var response_buf: ArrayList(u8) = .{};
            defer response_buf.deinit(alloc);

            routed_agent.processInputCapture(msg.text, &response_buf) catch |e| {
                try stderr.print("[Error] Agent {s} failed: {s}\n", .{ route.agent_id, @errorName(e) });
                continue;
            };

            if (response_buf.items.len > 0) {
                bridge.sendReplyThreaded(msg.platform, msg.from, response_buf.items, msg.thread_id) catch |e| {
                    try stderr.print("[Error] Reply failed: {s}\n", .{@errorName(e)});
                };
            }
        }

        try stderr.writeAll("[wintermolt] Chat sidecar exited\n");
        return;
    }

    // Web mode
    if (web_mode) {
        const port = compat.getenv("PORT") orelse compat.getenv("WINTERMOLT_WEB_PORT") orelse "3000";
        try stderr.print("[wintermolt] Starting web mode on port {s}...\n", .{port});
        var bridge = web_bridge.WebBridge.init(alloc, &agent) catch |e| {
            try stderr.print("[wintermolt] Failed to start web sidecar: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer bridge.deinit();

        std.Thread.sleep(500 * std.time.ns_per_ms);
        const is_headless = compat.getenv("K_SERVICE") != null or
            compat.getenv("WINTERMOLT_HEADLESS") != null;
        if (!is_headless) {
            const url = std.fmt.allocPrint(alloc, "http://localhost:{s}", .{port}) catch "http://localhost:3000";
            try stderr.print("[wintermolt] Opening {s}\n", .{url});
            const open_args = try alloc.alloc([]const u8, 2);
            open_args[0] = "open";
            open_args[1] = url;
            var open_child = std.process.Child.init(open_args, alloc);
            open_child.stdin_behavior = .Ignore;
            open_child.stdout_behavior = .Ignore;
            open_child.stderr_behavior = .Ignore;
            open_child.spawn() catch {};
        }

        bridge.run();
        try stderr.writeAll("[wintermolt] Web sidecar exited\n");
        return;
    }

    // Menu bar mode (macOS only)
    if (menubar_mode) {
        try stderr.writeAll("[wintermolt] Starting menu bar mode...\n");
        var bridge = menubar_bridge.MenuBarBridge.init(alloc, &agent) catch |e| {
            try stderr.print("[wintermolt] Failed to start menu bar sidecar: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer bridge.deinit();
        bridge.run();
        try stderr.writeAll("[wintermolt] Menu bar sidecar exited\n");
        return;
    }

    // Gateway mode — OpenAI-compatible API server
    if (gateway_mode) {
        const gw_port = compat.getenv("WINTERMOLT_GATEWAY_PORT") orelse "8080";
        try stderr.print("[wintermolt] Starting gateway mode on port {s}...\n", .{gw_port});
        var gw_bridge = gateway_bridge.GatewayBridge.init(alloc, &agent) catch |e| {
            try stderr.print("[wintermolt] Failed to start gateway sidecar: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer gw_bridge.deinit();
        gw_bridge.run();
        try stderr.writeAll("[wintermolt] Gateway sidecar exited\n");
        return;
    }

    // Single-shot mode
    if (exec_prompt) |prompt| {
        agent.startConversation();
        try agent.processInput(prompt);
        return;
    }

    // Interactive REPL
    try printBanner(stdout);

    const stdin = std.fs.File.stdin().deprecatedReader();
    var line_buf: [8192]u8 = undefined;

    while (true) {
        // Tick scheduler (runs due jobs)
        _ = agent.tickScheduler();

        try stdout.writeAll("\x1b[1;36m> \x1b[0m");

        const line = stdin.readUntilDelimiter(&line_buf, '\n') catch |e| {
            if (e == error.EndOfStream) {
                try stdout.writeAll("\n");
                return;
            }
            return e;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // REPL commands
        if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/exit")) {
            try stdout.writeAll("Goodbye.\n");
            return;
        }
        if (std.mem.eql(u8, trimmed, "/clear") or std.mem.eql(u8, trimmed, "/new")) {
            agent.archiveAndReset();
            try stdout.writeAll("Conversation cleared.\n");
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/help")) {
            try printHelp(stdout);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/model")) {
            const arg = std.mem.trim(u8, trimmed[6..], " \t");
            try handleModel(&agent, stdout, if (arg.len > 0) arg else null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/keys")) {
            const arg = std.mem.trim(u8, trimmed[5..], " \t");
            try handleKeysCmd(alloc, stdout, stdin, if (arg.len > 0) arg else null);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/look")) {
            try handleLook(&agent, alloc, stdout, stderr, null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/look ")) {
            const prompt = std.mem.trim(u8, trimmed[6..], " \t");
            try handleLook(&agent, alloc, stdout, stderr, if (prompt.len > 0) prompt else null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/screenshot")) {
            const prompt = blk: {
                if (trimmed.len > 11) {
                    const p = std.mem.trim(u8, trimmed[11..], " \t");
                    break :blk if (p.len > 0) p else null;
                }
                break :blk null;
            };
            try handleScreenshot(&agent, alloc, stdout, stderr, prompt);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/stats")) {
            try handleStats(&agent, stdout);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/compact")) {
            agent.history.emergencyCompact();
            try stdout.writeAll("History compacted.\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/constitution")) {
            const arg = std.mem.trim(u8, trimmed[13..], " \t");
            try handleConstitution(&agent, alloc, stdout, stderr, arg);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/export")) {
            const arg = std.mem.trim(u8, trimmed[7..], " \t");
            try handleExport(&agent, alloc, stdout, stderr, if (arg.len > 0) arg else null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/download ")) {
            const args_str = std.mem.trim(u8, trimmed[10..], " \t");
            if (args_str.len > 0) {
                try handleDownload(alloc, stdout, stderr, args_str);
            } else {
                try stdout.writeAll("Usage: /download <url> [output_path]\n");
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/schedule")) {
            const arg = std.mem.trim(u8, trimmed[9..], " \t");
            try handleScheduleCmd(alloc, stdout, stderr, arg);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/tailscale")) {
            try handleTailscale(alloc, stdout, stderr);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/route")) {
            const arg = std.mem.trim(u8, trimmed[6..], " \t");
            try handleRouteCmd(alloc, stdout, stderr, arg);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/agents")) {
            try handleAgentsCmd(alloc, stdout);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/tts ")) {
            try handleTtsCmd(alloc, stdout, stderr, trimmed[5..]);
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/tts")) {
            try handleTtsCmd(alloc, stdout, stderr, "");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/session")) {
            const arg = std.mem.trim(u8, trimmed[8..], " \t");
            try handleSessionCmd(&session_mgr, alloc, stdout, arg);
            continue;
        }

        // Process through agentic loop
        agent.processInput(trimmed) catch |e| {
            try stderr.print("[Error] {s}\n", .{@errorName(e)});
        };

        try stdout.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// REPL command handlers
// ---------------------------------------------------------------------------

fn handleModel(agent: *loop_mod.AgentLoop, w: anytype, arg: ?[]const u8) !void {
    if (arg) |a| {
        // Parse "backend" or "backend model-name"
        var iter = std.mem.splitScalar(u8, a, ' ');
        const backend = iter.next() orelse return;
        const model = iter.next();
        agent.switchBackend(backend, model);
    } else {
        const info = agent.getBackendInfo();
        try w.print("Current: {s} ({s})\n", .{ info.name, info.model });
        try w.writeAll("Usage: /model <backend> [model]\n");
        try w.writeAll("Backends: ollama (default), forai, claude, openai, deepseek, qwen, gemini\n");
    }
}

/// /keys command — add, update, or list individual API keys.
fn handleKeysCmd(alloc: std.mem.Allocator, w: anytype, r: anytype, arg: ?[]const u8) !void {
    const ApiEntry = struct { key: []const u8, label: []const u8, hint: ?[]const u8 };
    const api_keys = [_]ApiEntry{
        .{ .key = "ANTHROPIC_API_KEY", .label = "Anthropic (Claude)", .hint = "sk-ant-" },
        .{ .key = "OPENAI_API_KEY", .label = "OpenAI (GPT + TTS)", .hint = "sk-" },
        .{ .key = "GOOGLE_GEMINI_API_KEY", .label = "Google Gemini", .hint = "AIza" },
        .{ .key = "DEEPSEEK_API_KEY", .label = "DeepSeek", .hint = "sk-" },
        .{ .key = "QWEN_API_KEY", .label = "Qwen", .hint = null },
        .{ .key = "PINECONE_API_KEY", .label = "Pinecone (RAG)", .hint = null },
        .{ .key = "PINECONE_HOST", .label = "Pinecone Host URL", .hint = "https://" },
        .{ .key = "ELEVENLABS_API_KEY", .label = "ElevenLabs (voice)", .hint = null },
        .{ .key = "DISCORD_BOT_TOKEN", .label = "Discord Bot", .hint = null },
        .{ .key = "TELEGRAM_BOT_TOKEN", .label = "Telegram Bot", .hint = null },
        .{ .key = "SLACK_BOT_TOKEN", .label = "Slack Bot", .hint = "xoxb-" },
        .{ .key = "SLACK_APP_TOKEN", .label = "Slack App", .hint = "xapp-" },
    };

    var existing = setup.loadExistingEnv(alloc);

    // /keys list
    if (arg) |a| {
        if (std.mem.eql(u8, a, "list") or std.mem.eql(u8, a, "status")) {
            try w.writeAll("\n \x1b[1;36m─── API Keys ───────────────────────────────\x1b[0m\n");
            for (api_keys, 0..) |entry, i| {
                const val = existing.get(entry.key) orelse compat.getenv(entry.key);
                const num = i + 1;
                if (val) |v| {
                    if (v.len > 8) {
                        try w.print("  \x1b[32m✓\x1b[0m {d:>2}. {s}: {s}...{s}\n", .{ num, entry.label, v[0..4], v[v.len - 4 ..] });
                    } else if (v.len > 0) {
                        try w.print("  \x1b[32m✓\x1b[0m {d:>2}. {s}: ***\n", .{ num, entry.label });
                    } else {
                        try w.print("  \x1b[90m·\x1b[0m {d:>2}. {s}\n", .{ num, entry.label });
                    }
                } else {
                    try w.print("  \x1b[90m·\x1b[0m {d:>2}. {s}\n", .{ num, entry.label });
                }
            }
            try w.writeAll("\n  \x1b[90mUse /keys <number> or /keys <name> to configure\x1b[0m\n\n");
            return;
        }

        // /keys <number>
        const num = std.fmt.parseInt(usize, a, 10) catch 0;
        if (num >= 1 and num <= api_keys.len) {
            const entry = api_keys[num - 1];
            try configureKey(alloc, w, r, &existing, entry.key, entry.label, entry.hint);
            return;
        }

        // /keys <name> — match by keyword
        for (api_keys) |entry| {
            if (std.ascii.eqlIgnoreCase(a, entry.key)) {
                try configureKey(alloc, w, r, &existing, entry.key, entry.label, entry.hint);
                return;
            }
            // Match by label keyword (first word)
            const lower_label = entry.label;
            if (lower_label.len > 0) {
                var word_iter = std.mem.splitScalar(u8, lower_label, ' ');
                const first_word = word_iter.next() orelse "";
                if (first_word.len > 0 and std.ascii.eqlIgnoreCase(a, first_word)) {
                    try configureKey(alloc, w, r, &existing, entry.key, entry.label, entry.hint);
                    return;
                }
            }
        }

        try w.print("  \x1b[31mUnknown key: {s}\x1b[0m\n", .{a});
        try w.writeAll("  Use /keys list to see available keys, or /keys <number>\n\n");
        return;
    }

    // /keys with no args — interactive menu
    try w.writeAll("\n \x1b[1;36m─── Configure API Key ──────────────────────\x1b[0m\n");
    for (api_keys, 0..) |entry, i| {
        const val = existing.get(entry.key) orelse compat.getenv(entry.key);
        const num = i + 1;
        const mark: []const u8 = if (val != null and val.?.len > 0) "\x1b[32m✓\x1b[0m" else "\x1b[90m·\x1b[0m";
        try w.print("  {s} {d:>2}. {s}\n", .{ mark, num, entry.label });
    }
    try w.writeAll("\n  Enter number: ");
    var line_buf: [256]u8 = undefined;
    const line = r.readUntilDelimiter(&line_buf, '\n') catch return;
    const choice = std.mem.trim(u8, line, " \t\r");
    const num = std.fmt.parseInt(usize, choice, 10) catch {
        try w.writeAll("  \x1b[31mInvalid choice.\x1b[0m\n\n");
        return;
    };
    if (num < 1 or num > api_keys.len) {
        try w.writeAll("  \x1b[31mInvalid choice.\x1b[0m\n\n");
        return;
    }

    const entry = api_keys[num - 1];
    try configureKey(alloc, w, r, &existing, entry.key, entry.label, entry.hint);
}

/// Configure a single API key (prompt, validate, save to .env).
fn configureKey(
    alloc: std.mem.Allocator,
    w: anytype,
    r: anytype,
    existing: *std.StringHashMap([]const u8),
    env_key: []const u8,
    label: []const u8,
    hint: ?[]const u8,
) !void {
    const current = existing.get(env_key) orelse compat.getenv(env_key);

    try w.print("\n  \x1b[1m{s}\x1b[0m ({s})\n", .{ label, env_key });
    if (current) |v| {
        if (v.len > 8) {
            try w.print("  Current: {s}...{s}\n", .{ v[0..4], v[v.len - 4 ..] });
        } else if (v.len > 0) {
            try w.writeAll("  Current: ***\n");
        }
    }
    if (hint) |h| {
        try w.print("  Expected prefix: {s}\n", .{h});
    }
    try w.writeAll("  Enter value (or 'clear' to remove): ");

    var line_buf: [4096]u8 = undefined;
    const line = r.readUntilDelimiter(&line_buf, '\n') catch return;
    const value = std.mem.trim(u8, line, " \t\r");

    if (value.len == 0) {
        try w.writeAll("  \x1b[90mNo change.\x1b[0m\n\n");
        return;
    }

    var clearing = false;
    if (std.mem.eql(u8, value, "clear") or std.mem.eql(u8, value, "remove") or std.mem.eql(u8, value, "delete")) {
        clearing = true;
        try w.print("  \x1b[33mCleared {s}\x1b[0m\n", .{env_key});
    } else {
        if (hint) |h| {
            if (!std.mem.startsWith(u8, value, h)) {
                try w.print("  \x1b[33m⚠ Expected prefix \"{s}\". Saving anyway.\x1b[0m\n", .{h});
            }
        }
        try w.print("  \x1b[32m✓ Saved {s}\x1b[0m (restart to take effect)\n", .{env_key});
    }

    // Rewrite .env file
    const home = compat.getenv("HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const env_path = std.fmt.bufPrint(&path_buf, "{s}/.wintermolt/.env", .{home}) catch return;

    var all_keys = setup.loadExistingEnv(alloc);

    if (clearing) {
        _ = all_keys.remove(env_key);
    } else {
        all_keys.put(env_key, value) catch {};
    }

    // Write updated file
    var content_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&content_buf);
    const sw = stream.writer();

    try sw.writeAll("# Wintermolt configuration\n");
    try sw.writeAll("# Edit manually or use /keys command to reconfigure.\n\n");
    try sw.print("WINTERMOLT_CONFIG_VERSION={d}\n\n", .{config_mod.CONFIG_VERSION});

    var it = all_keys.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "WINTERMOLT_CONFIG_VERSION")) continue;
        try sw.print("{s}=\"{s}\"\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    }

    // Ensure directory exists
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.wintermolt", .{home}) catch return;
    std.fs.cwd().makePath(dir_path) catch {};

    const file = std.fs.cwd().createFile(env_path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(stream.getWritten()) catch {};

    try w.writeByte('\n');
}

fn handleLook(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, _stderr: anytype, custom_prompt: ?[]const u8) !void {
    _ = _stderr;
    const default_prompt = "Describe what you see in detail. What's in the image?";
    const prompt = custom_prompt orelse default_prompt;

    // Capture image
    const capture_result = camera.capture(alloc, null) catch |e| {
        try w.print("[camera] Capture failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(capture_result.data);

    // Feed image + prompt through the agent
    const full_prompt = try std.fmt.allocPrint(alloc, "[Camera capture attached: {s}] {s}", .{ capture_result.media_type, prompt });
    defer alloc.free(full_prompt);

    try agent.processInput(full_prompt);
}

fn handleScreenshot(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, _stderr: anytype, custom_prompt: ?[]const u8) !void {
    _ = _stderr;
    const default_prompt = "Describe what you see on the screen.";
    const prompt = custom_prompt orelse default_prompt;

    const capture_result = camera.captureScreenshot(alloc) catch |e| {
        try w.print("[screenshot] Capture failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(capture_result.data);

    const full_prompt = try std.fmt.allocPrint(alloc, "[Screenshot attached] {s}", .{prompt});
    defer alloc.free(full_prompt);

    try agent.processInput(full_prompt);
}

fn handleStats(agent: *const loop_mod.AgentLoop, w: anytype) !void {
    const info = agent.getBackendInfo();
    try w.writeAll("Wintermolt Stats\n");
    try w.writeAll("════════════════\n");
    try w.print("  Backend:     {s}\n", .{info.name});
    try w.print("  Model:       {s}\n", .{info.model});
    try w.print("  Messages:    {d}\n", .{agent.history.getMessages().len});
    try w.print("  Tokens:      ~{d}\n", .{agent.history.approx_tokens});
    try w.print("  Sequence:    {d}\n", .{agent.message_sequence});
    if (agent.conversation_id) |id|
        try w.print("  Conversation: {s}\n", .{id});
}

fn handleConstitution(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, _stderr: anytype, arg: []const u8) !void {
    _ = _stderr;
    if (arg.len == 0 or std.mem.eql(u8, arg, "show")) {
        try w.writeAll("Current system prompt:\n\n");
        try w.writeAll(agent.config.system_prompt);
        try w.writeByte('\n');
        if (agent.config.isCustomConstitution()) {
            try w.writeAll("\n(Loaded from ~/.wintermolt/constitution.md)\n");
        } else {
            try w.writeAll("\n(Built-in default)\n");
        }
    } else if (std.mem.eql(u8, arg, "reload")) {
        if (agent.config.reloadConstitution(alloc)) {
            try w.writeAll("Reloaded constitution from file.\n");
        } else {
            try w.writeAll("Using built-in default (no ~/.wintermolt/constitution.md found).\n");
        }
    } else {
        try w.writeAll("Usage: /constitution [show|reload]\n");
    }
}

fn handleExport(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, _stderr: anytype, arg: ?[]const u8) !void {
    _ = _stderr;
    const path = arg orelse "/tmp/wintermolt_export.jsonl";
    if (agent.storage) |*s| {
        const count = export_mod.exportHistory(alloc, s, path) catch |e| {
            try w.print("[export] Failed: {s}\n", .{@errorName(e)});
            return;
        };
        try w.print("[export] Exported {d} messages to {s}\n", .{ count, path });
    } else {
        try w.writeAll("[export] No storage available (history disabled).\n");
    }
}

fn handleDownload(alloc: std.mem.Allocator, w: anytype, _stderr: anytype, args_str: []const u8) !void {
    _ = _stderr;
    var iter = std.mem.splitScalar(u8, args_str, ' ');
    const url = iter.next() orelse return;
    const output = iter.next();

    const output_path = output orelse "/tmp/wintermolt_download";
    const result = http_tool.downloadFile(alloc, url, output_path) catch |e| {
        try w.print("[download] Failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(result);
    try w.writeAll(result);
    try w.writeByte('\n');
}

fn handleScheduleCmd(alloc: std.mem.Allocator, w: anytype, _stderr: anytype, arg: []const u8) !void {
    _ = _stderr;
    const tools_mod = @import("agent/tools.zig");
    const sched = tools_mod.getScheduler() orelse {
        try w.writeAll("[schedule] Scheduler not available.\n");
        return;
    };

    if (arg.len == 0 or std.mem.eql(u8, arg, "list")) {
        const list = sched.listJobs(alloc) catch |e| {
            try w.print("[schedule] Error: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(list);
        try w.writeAll(list);
        try w.writeByte('\n');
        return;
    }

    // /schedule add <name> <type> <value> <command...>
    if (std.mem.startsWith(u8, arg, "add ")) {
        const rest = std.mem.trim(u8, arg[4..], " \t");
        var iter = std.mem.splitScalar(u8, rest, ' ');
        const name = iter.next() orelse {
            try w.writeAll("Usage: /schedule add <name> <every|at|cron> <value> <command...>\n");
            return;
        };
        const stype = iter.next() orelse {
            try w.writeAll("Usage: /schedule add <name> <every|at|cron> <value> <command...>\n");
            return;
        };
        const svalue = iter.next() orelse {
            try w.writeAll("Usage: /schedule add <name> <every|at|cron> <value> <command...>\n");
            return;
        };
        const command = iter.rest();
        if (command.len == 0) {
            try w.writeAll("Usage: /schedule add <name> <every|at|cron> <value> <command...>\n");
            return;
        }

        const job_id = sched.addJob(name, stype, svalue, command) catch |e| {
            try w.print("[schedule] Failed to add: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(job_id);
        try w.print("[schedule] Added job [{s}]: {s} ({s} {s}) -> {s}\n", .{ job_id, name, stype, svalue, command });
        return;
    }

    // /schedule remove <job_id>
    if (std.mem.startsWith(u8, arg, "remove ")) {
        const job_id = std.mem.trim(u8, arg[7..], " \t");
        sched.removeJob(job_id) catch |e| {
            try w.print("[schedule] Failed to remove: {s}\n", .{@errorName(e)});
            return;
        };
        try w.print("[schedule] Removed job: {s}\n", .{job_id});
        return;
    }

    // /schedule enable|disable <job_id>
    if (std.mem.startsWith(u8, arg, "enable ") or std.mem.startsWith(u8, arg, "disable ")) {
        const is_enable = std.mem.startsWith(u8, arg, "enable");
        const offset: usize = if (is_enable) 7 else 8;
        const job_id = std.mem.trim(u8, arg[offset..], " \t");
        sched.enableJob(job_id, is_enable) catch |e| {
            try w.print("[schedule] Failed: {s}\n", .{@errorName(e)});
            return;
        };
        try w.print("[schedule] Job {s}: {s}\n", .{ if (is_enable) "enabled" else "disabled", job_id });
        return;
    }

    try w.writeAll("Usage: /schedule [list|add|remove|enable|disable]\n");
    try w.writeAll("  /schedule list                          — List all jobs\n");
    try w.writeAll("  /schedule add <name> <type> <val> <cmd> — Add a job\n");
    try w.writeAll("  /schedule remove <id>                   — Remove a job\n");
    try w.writeAll("  /schedule enable|disable <id>           — Enable/disable\n");
}

/// Spawn function for subagents — called by SubagentManager.
/// Creates a fresh AgentLoop, runs the task, captures output, returns result.
/// This lives in main.zig to break the circular dependency (subagent.zig ← loop.zig).
fn spawnSubagent(
    alloc: std.mem.Allocator,
    task: []const u8,
    model_override: ?[]const u8,
    child_depth: u8,
    mgr: *subagent_mod.SubagentManager,
) []u8 {
    // Load config (re-use from env, already loaded)
    var child_config = config_mod.Config.load(null) catch {
        return alloc.dupe(u8, "Error: Failed to load config for subagent") catch return @constCast("");
    };

    var child_agent = loop_mod.AgentLoop.init(alloc, &child_config) catch {
        return alloc.dupe(u8, "Error: Failed to create subagent") catch return @constCast("");
    };
    defer child_agent.deinit();

    // Set depth and subagent manager for recursive spawning
    child_agent.depth = child_depth;
    child_agent.subagent_manager = @ptrCast(mgr);

    // Apply model override
    if (model_override) |model| {
        child_agent.switchBackend(model, null);
    }

    child_agent.startConversation();

    // Capture output
    var output_buf: ArrayList(u8) = .{};
    child_agent.processInputCapture(task, &output_buf) catch {
        output_buf.deinit(alloc);
        return alloc.dupe(u8, "Error: Subagent execution failed") catch return @constCast("");
    };

    if (output_buf.items.len == 0) {
        output_buf.deinit(alloc);
        return alloc.dupe(u8, "(Subagent produced no output)") catch return @constCast("");
    }

    // Truncate very long output
    const max_output: usize = 50_000;
    if (output_buf.items.len > max_output) {
        const truncated = alloc.dupe(u8, output_buf.items[0..max_output]) catch {
            output_buf.deinit(alloc);
            return @constCast("");
        };
        output_buf.deinit(alloc);
        return truncated;
    }

    return output_buf.toOwnedSlice(alloc) catch return @constCast("");
}

fn handleSessionCmd(mgr: *session_mod.SessionManager, alloc: std.mem.Allocator, w: anytype, arg: []const u8) !void {
    if (arg.len == 0 or std.mem.eql(u8, arg, "list")) {
        const list = try mgr.listSessions(alloc, 20);
        defer alloc.free(list);
        try w.writeAll(list);
        return;
    }

    if (std.mem.startsWith(u8, arg, "end ")) {
        const sid = std.mem.trim(u8, arg[4..], " \t");
        mgr.endSession(sid) catch |e| {
            try std.fmt.format(w, "[session] Error: {s}\n", .{@errorName(e)});
            return;
        };
        try std.fmt.format(w, "[session] Ended: {s}\n", .{sid});
        return;
    }

    if (std.mem.startsWith(u8, arg, "cleanup")) {
        const timeout: i64 = 3600; // 1 hour default
        mgr.cleanupStale(timeout);
        try w.writeAll("[session] Cleaned up stale sessions.\n");
        return;
    }

    try w.writeAll("Usage: /session [list|end|cleanup]\n");
    try w.writeAll("  /session list             — Show active sessions\n");
    try w.writeAll("  /session end <session_id>  — End a session\n");
    try w.writeAll("  /session cleanup           — End stale sessions (idle > 1h)\n");
}

fn handleTtsCmd(alloc: std.mem.Allocator, w: anytype, _stderr: anytype, arg: []const u8) !void {
    _ = _stderr;
    const text = std.mem.trim(u8, arg, " \t");

    if (text.len == 0) {
        const provider = compat.getenv("WINTERMOLT_TTS_PROVIDER") orelse "not configured";
        const voice = compat.getenv("WINTERMOLT_TTS_VOICE") orelse "alloy";
        try std.fmt.format(w, "TTS Status\n", .{});
        try std.fmt.format(w, "  Provider: {s}\n", .{provider});
        try std.fmt.format(w, "  Voice: {s}\n", .{voice});
        try w.writeAll("\nUsage: /tts <text to speak>\n");
        try w.writeAll("Inline directives: [[voice:nova]] [[speed:1.2]] [[provider:openai]]\n");
        try w.writeAll("\nProviders: openai, elevenlabs, piper, edge\n");
        try w.writeAll("OpenAI voices: alloy, echo, fable, onyx, nova, shimmer\n");
        return;
    }

    try w.writeAll("[tts] Synthesizing...\n");
    var client = tts_mod.TtsClient.init(alloc);
    const path = client.synthesizeToFile(text) catch |e| {
        try std.fmt.format(w, "[tts] Error: {s}\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(path);
    try std.fmt.format(w, "[tts] Audio saved: {s}\n", .{path});

    // Auto-play on macOS
    const play_cmd = std.fmt.allocPrint(alloc, "afplay \"{s}\" &", .{path}) catch return;
    defer alloc.free(play_cmd);
    const play_z = alloc.dupeZ(u8, play_cmd) catch return;
    defer alloc.free(play_z);

    const play_argv = [_][]const u8{ "/bin/sh", "-c", play_z };
    var child = std.process.Child.init(&play_argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
}

fn handleRouteCmd(alloc: std.mem.Allocator, w: anytype, _stderr: anytype, arg: []const u8) !void {
    _ = _stderr;
    var router = router_mod.Router.init(alloc);
    defer router.deinit();

    if (arg.len == 0 or std.mem.eql(u8, arg, "list")) {
        const list = try router.listBindings(alloc);
        defer alloc.free(list);
        try w.writeAll(list);
        try w.writeByte('\n');
        return;
    }

    // /route add <agent_id> <tier> [platform] [channel] [peer]
    if (std.mem.startsWith(u8, arg, "add ")) {
        const rest = std.mem.trim(u8, arg[4..], " \t");
        var iter = std.mem.splitScalar(u8, rest, ' ');

        const agent_id = iter.next() orelse {
            try w.writeAll("Usage: /route add <agent_id> <tier> [platform] [channel] [peer]\n");
            try w.writeAll("Tiers: peer, guild_role, guild, team, account, channel\n");
            return;
        };
        const tier_str = iter.next() orelse {
            try w.writeAll("Usage: /route add <agent_id> <tier> [platform] [channel] [peer]\n");
            return;
        };
        const tier: router_mod.BindingTier = if (std.mem.eql(u8, tier_str, "peer"))
            .peer
        else if (std.mem.eql(u8, tier_str, "guild_role"))
            .guild_role
        else if (std.mem.eql(u8, tier_str, "guild"))
            .guild
        else if (std.mem.eql(u8, tier_str, "team"))
            .team
        else if (std.mem.eql(u8, tier_str, "account"))
            .account
        else if (std.mem.eql(u8, tier_str, "channel"))
            .channel
        else {
            try w.writeAll("Invalid tier. Use: peer, guild_role, guild, team, account, channel\n");
            return;
        };

        const platform = iter.next();
        const channel_id = iter.next();
        const peer_id = iter.next();

        const binding_id = router.addBinding(
            agent_id,
            tier,
            platform,
            channel_id,
            peer_id,
            null, // guild_id
            null, // team_id
            null, // account_id
            null, // roles
        ) catch |e| {
            try std.fmt.format(w, "[route] Failed to add: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(binding_id);
        try std.fmt.format(w, "[route] Added binding [{s}] → agent:{s} (tier:{s})\n", .{ binding_id[0..8], agent_id, tier_str });
        return;
    }

    // /route remove <binding_id>
    if (std.mem.startsWith(u8, arg, "remove ")) {
        const id = std.mem.trim(u8, arg[7..], " \t");
        _ = router.removeBinding(id);
        try std.fmt.format(w, "[route] Removed binding: {s}\n", .{id});
        return;
    }

    try w.writeAll("Usage: /route [list|add|remove]\n");
    try w.writeAll("  /route list                                  — Show all bindings\n");
    try w.writeAll("  /route add <agent> <tier> [platform] [chan]   — Add a binding\n");
    try w.writeAll("  /route remove <id>                           — Remove a binding\n");
}

fn handleAgentsCmd(alloc: std.mem.Allocator, w: anytype) !void {
    // In REPL mode there's only the single main agent, but show pool info
    // if it were running in chat mode. For REPL, just show current stats.
    _ = alloc;
    try w.writeAll("Agent pool is active in --chat mode.\n");
    try w.writeAll("Use /route to configure multi-agent routing bindings.\n");
}

fn handleTailscale(alloc: std.mem.Allocator, w: anytype, _stderr: anytype) !void {
    _ = _stderr;
    const result = tailscale_tool.executeTool(alloc, "{\"action\":\"status\"}") catch |e| {
        try w.print("[tailscale] Error: {s}\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(result);
    try w.writeAll(result);
    try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Banner and help
// ---------------------------------------------------------------------------

fn printBanner(w: anytype) !void {
    try w.writeAll(
        \\
        \\  ╦ ╦┬┌┐┌┌┬┐┌─┐┬─┐┌┬┐┌─┐┬ ┌┬┐
        \\  ║║║││││ │ ├┤ ├┬┘││││ ││  │
        \\  ╚╩╝┴┘└┘ ┴ └─┘┴└─┴ ┴└─┘┴─┘┴
        \\
    );
    try w.print("  v{s} — Lite AI Agent CLI (Apache-2.0)\n", .{VERSION});
    try w.writeAll("  Type /help for commands, /quit to exit.\n\n");
}

fn printHelp(w: anytype) !void {
    try w.writeAll(
        \\Wintermolt — Lite AI Agent CLI
        \\
        \\Commands:
        \\  /help          — Show this help
        \\  /quit, /exit   — Exit
        \\  /clear, /new   — Clear conversation history
        \\  /model [name]  — Switch AI backend (ollama, claude, openai, deepseek, qwen, gemini)
        \\  /keys          — Add/update API keys (interactive menu)
        \\  /keys list     — Show all configured keys
        \\  /look [prompt] — Capture camera image and describe it
        \\  /screenshot    — Capture screen and describe it
        \\  /stats         — Show session statistics
        \\  /compact       — Compact conversation history
        \\  /constitution  — View/reload system prompt
        \\  /export [fmt]  — Export conversation (jsonl, csv)
        \\  /download URL  — Download a file
        \\  /schedule      — Manage scheduled jobs (list, add, remove)
        \\  /tts <text>    — Synthesize text to speech (plays audio)
        \\  /session       — Manage chat sessions (list, end, cleanup)
        \\  /route         — Manage multi-agent routing bindings
        \\  /agents        — Show agent pool status
        \\  /tailscale     — Show Tailscale network status
        \\
        \\Modes:
        \\  wintermolt              — Interactive REPL
        \\  wintermolt -e "prompt"  — Single-shot execution
        \\  wintermolt --keys       — Configure API keys
        \\  wintermolt --setup      — Alias for --keys
        \\  wintermolt --chat       — Chat bridge (18 platforms)
        \\  wintermolt --web        — Web UI
        \\  wintermolt --menubar    — macOS menu bar sidecar
        \\  wintermolt --gateway    — OpenAI-compatible API gateway
        \\  wintermolt --mcp-server — MCP JSON-RPC server
        \\  wintermolt --extension  — Manage extensions (list, available, install, remove)
        \\
        \\Chat platforms (set env var to enable):
        \\  Discord        DISCORD_BOT_TOKEN
        \\  Telegram       TELEGRAM_BOT_TOKEN
        \\  WhatsApp       WHATSAPP_PHONE_ID + WHATSAPP_ACCESS_TOKEN
        \\  Slack          SLACK_BOT_TOKEN (+ SLACK_APP_TOKEN for Socket Mode)
        \\  Signal         SIGNAL_PHONE_NUMBER (requires signal-cli)
        \\  iMessage       IMESSAGE_APPLEID (macOS only)
        \\  IRC            IRC_SERVER + IRC_NICK + IRC_CHANNELS
        \\  Matrix         MATRIX_HOMESERVER + MATRIX_ACCESS_TOKEN + MATRIX_USER_ID
        \\  Teams          TEAMS_APP_ID + TEAMS_APP_PASSWORD
        \\  Google Chat    GOOGLE_CHAT_CREDENTIALS
        \\  LINE           LINE_CHANNEL_SECRET + LINE_CHANNEL_TOKEN
        \\  Feishu/Lark    FEISHU_APP_ID + FEISHU_APP_SECRET
        \\  Mattermost     MATTERMOST_URL + MATTERMOST_TOKEN
        \\  Twitch         TWITCH_ACCESS_TOKEN + TWITCH_CHANNELS
        \\  Nostr          NOSTR_PRIVATE_KEY (+ NOSTR_RELAYS)
        \\  XMPP/Jabber    XMPP_JID + XMPP_PASSWORD
        \\  Zulip          ZULIP_EMAIL + ZULIP_API_KEY + ZULIP_SITE
        \\  Rocket.Chat    ROCKETCHAT_URL + ROCKETCHAT_TOKEN + ROCKETCHAT_USER_ID
        \\
        \\Environment:
        \\  OPENAI_API_KEY       — OpenAI API key (optional)
        \\  WINTERMOLT_MODEL     — Default model
        \\  OLLAMA_HOST          — Ollama URL (default: http://localhost:11434)
        \\  OPENAI_API_KEY       — OpenAI API key
        \\  DEEPSEEK_API_KEY     — DeepSeek API key
        \\  QWEN_API_KEY         — Qwen API key
        \\  TAILSCALE_API_KEY    — Tailscale API key (optional, for device list)
        \\
    );
}
