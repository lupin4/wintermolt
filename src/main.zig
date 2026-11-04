// Copyright The Fantastic Planet - By David Clabaugh
//
// main.zig — Wintermolt entry point
//
// Lite AI assistant CLI powered by Ollama (local) + multi-backend AI.
// Open-core: MIT. No forKernels, no proprietary subsystems.
//
// Usage:
//   wintermolt              — interactive: full-screen TUI in a terminal,
//                             plain REPL when stdin/stdout are not a terminal
//   wintermolt --plain      — plain REPL even in a terminal (or WINTERMOLT_PLAIN=1)
//   wintermolt --help       — show help
//   wintermolt -e "prompt"  — single-shot execution
//   wintermolt --keys       — configure API keys
//   wintermolt --chat       — chat bridge mode (16 platforms)
//   wintermolt --web        — web UI mode
//   wintermolt --mcp-server — MCP JSON-RPC server over stdio

const std = @import("std");
const fsio = @import("fsio.zig");
const stdio = @import("stdio.zig");
const compat = @import("compat.zig");
const ArrayList = std.ArrayList;
const config_mod = @import("agent/config.zig");
const loop_mod = @import("agent/loop.zig");
const chat_bridge = @import("chat/bridge.zig");
const chat_access = @import("chat/access.zig");
const web_bridge = @import("web/bridge.zig");
const menubar_bridge = @import("menubar/bridge.zig");
const router_mod = @import("agent/router.zig");
const pool_mod = @import("agent/agent_pool.zig");
const subagent_mod = @import("agent/subagent.zig");
const tts_mod = @import("agent/tts.zig");
const stt_mod = @import("agent/stt.zig");
const skill_md = @import("agent/skill_md.zig");
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
const tui = @import("tui.zig");
const theme_pref = @import("theme_pref.zig");
const banner = @import("banner.zig");
const zortui = @import("zortui");

const VERSION = "0.6.0";

/// A panic while the TUI owns the terminal would leave the shell in raw mode on
/// the alternate screen, with the panic message drawn somewhere invisible. Put
/// the terminal back first; everything else is the default handler. No-op
/// unless the TUI is up.
pub const panic = std.debug.FullPanic(panicRestoringTerminal);

fn panicRestoringTerminal(msg: []const u8, first_trace_addr: ?usize) noreturn {
    tui.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

// 0.16/0.17 hand main a `std.process.Init`: it carries the args, the environment
// and a properly configured Io, replacing the positionless std.process helpers
// that were removed. Both toolchains accept this signature identically, so there
// is no feature test -- start.zig dispatches on the parameter.
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // UTF-8 console on Windows, so nobody has to set [Console]::OutputEncoding
    // before the banner renders. No-op elsewhere; see compat.initConsole.
    compat.initConsole();
    defer compat.restoreConsole();

    // std.fs.File and deprecatedWriter are both gone (0.16 removed std.fs.File;
    // deprecatedWriter went with it). std.Io.File + writerStreaming replaces
    // them, and this exact form compiles and behaves identically on 0.16 and
    // 0.17, so it needs no feature test.
    //
    // The buffers are ZERO-LENGTH on purpose. A File.Writer drains whenever its
    // buffer is full, so a zero-length buffer drains on every write -- which is
    // precisely deprecatedWriter's unbuffered behaviour. That matters here: this
    // function has many early returns, and a real buffer would need a matching
    // flush on every one of them. Verified by writing without any flush and
    // seeing the output arrive.
    // Use the Io main was handed rather than the global single-threaded one:
    // that instance documents that it does not support concurrency.
    const io = init.io;
    var stdout_buf: [0]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [0]u8 = undefined;
    var stderr_fw = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    // Parse args
    // std.process.argsWithAllocator is gone; the iterator comes off Init now and
    // needs no allocator or deinit on POSIX (it walks the existing argv vector).
    //
    // iterate() is POSIX-only: on Windows it is a compile error ("use
    // initAllocator instead"), because argv there is decoded from the UTF-16
    // command line. iterateAllocator works on every target.
    var args = try init.minimal.args.iterateAllocator(alloc);
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
    var pairing_cmd: ?[]const u8 = null;
    var pairing_args: [2]?[]const u8 = .{ null, null };
    var run_setup = false;
    var plain_mode = false;
    var theme_flag: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--plain")) {
            plain_mode = true;
        }
        if (std.mem.eql(u8, arg, "--theme")) {
            theme_flag = args.next() orelse {
                try stderr.writeAll("Error: --theme requires a theme name: ");
                try theme_pref.writeNames(stderr);
                try stderr.writeAll("\n");
                std.process.exit(1);
            };
        }
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
        if (std.mem.eql(u8, arg, "--pairing")) {
            pairing_cmd = args.next() orelse "";
            pairing_args = .{ args.next(), args.next() };
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

    // --pairing: approve who may message the agent through --chat (chat/access.zig).
    // Runs beside a live --chat process; both share ~/.wintermolt/chat_access.db.
    if (pairing_cmd) |cmd| {
        const usage =
            \\Usage: wintermolt --pairing list [platform]
            \\       wintermolt --pairing approve <platform> <code>
            \\       wintermolt --pairing revoke <platform> <sender>
            \\
        ;
        var store = chat_access.Store.openDefault(alloc) catch |e| {
            try stderr.print("[pairing] Cannot open ~/.wintermolt/chat_access.db: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer store.close();
        const now = fsio.timestamp();
        if (std.mem.eql(u8, cmd, "list")) {
            try store.writeList(stdout, pairing_args[0], now);
        } else if (std.mem.eql(u8, cmd, "approve")) {
            const platform = pairing_args[0] orelse {
                try stderr.writeAll(usage);
                std.process.exit(1);
            };
            const code = pairing_args[1] orelse {
                try stderr.writeAll(usage);
                std.process.exit(1);
            };
            const sender = (try store.approve(alloc, platform, code, now)) orelse {
                try stderr.print("[pairing] No live {s} request with code {s}. `wintermolt --pairing list` shows them.\n", .{ platform, code });
                std.process.exit(1);
            };
            defer alloc.free(sender);
            try stdout.print("Approved {s}:{s} for direct messages.\n", .{ platform, sender });
        } else if (std.mem.eql(u8, cmd, "revoke")) {
            const platform = pairing_args[0] orelse {
                try stderr.writeAll(usage);
                std.process.exit(1);
            };
            const sender = pairing_args[1] orelse {
                try stderr.writeAll(usage);
                std.process.exit(1);
            };
            if (try store.revoke(platform, sender)) {
                try stdout.print("Revoked {s}:{s}.\n", .{ platform, sender });
            } else {
                try stderr.print("[pairing] {s}:{s} was not approved.\n", .{ platform, sender });
                std.process.exit(1);
            }
        } else {
            try stderr.writeAll(usage);
            std.process.exit(1);
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

    // Theme for the full-screen view and the canvas. WINTERMOLT_THEME is read
    // BEFORE loadDotEnv copies ~/.wintermolt/.env into the environment, so the
    // shell's value and the one /theme saved stay separate sources.
    const theme_choice = theme_pref.resolve(theme_flag, compat.getenv(theme_pref.env_key), loadSavedTheme(alloc));
    _ = theme_pref.select(theme_choice.name);
    // A name that is not a theme is reported where it will be seen: in the
    // full-screen transcript when that opens, on stderr otherwise.
    var theme_reported = false;
    const tui_possible = exec_prompt == null and !chat_mode and !web_mode and !menubar_mode and
        !gateway_mode and !mcp_server_mode and !plain_mode and compat.stdioIsTerminal();
    if (!tui_possible) {
        try reportThemeRejections(stderr, &theme_choice);
        theme_reported = true;
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
        // No AgentLoop here, so load the skills the `skills` tool reads.
        var skill_registry = @import("agent/skill_loader.zig").SkillRegistry.init(alloc);
        defer skill_registry.deinit();
        skill_registry.loadFromDirectories();
        @import("agent/tools.zig").setSkillRegistry(&skill_registry);
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

    // Initialize agent loop. WINTERMOLT_BACKEND, when set, is built inside init,
    // so every loop this run creates follows it. A backend that cannot be built
    // has already printed why and must fail the run: the variable is an explicit
    // request, and answering from Ollama instead would hide it.
    var agent = loop_mod.AgentLoop.init(alloc, &config) catch |e| {
        try stderr.print("[wintermolt] startup failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer agent.deinit();
    defer stt_mod.stopServer(); // the whisper-server /listen started, if any

    // api-override (wintermolt.json models.chat.prefer + a cloud key present):
    // switch the primary off ollama onto the API for reliable native tool-calling.
    // WINTERMOLT_BACKEND wins over it, having been built in init already: the
    // exported variable is an explicit request, the override a config default.
    if (config.api_override and config.backend == null) {
        stdio.stderr().print("[config] api-override → claude ({s})\n", .{config.model}) catch {};
        agent.switchBackend("claude", config.model) catch {};
    }

    // Re-bind tools-module globals (scheduler, skill registry, storage, RAG) —
    // init() returns by value, so they must point at agent's final address.
    agent.bindTools();

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

        // Who may reach the agent (chat/access.zig). Read before the sidecar
        // starts, so a mistyped setting stops the run instead of opening it.
        const chat_policy = chat_access.parsePolicy(chat_access.Env.read()) catch |e| {
            try stderr.print("[chat] {s}: run `wintermolt --help` for the WINTERMOLT_CHAT_* values\n", .{@errorName(e)});
            std.process.exit(1);
        };
        var access_store = chat_access.Store.openDefault(alloc) catch |e| {
            try stderr.print("[chat] Cannot open ~/.wintermolt/chat_access.db: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer access_store.close();
        try stderr.print("[chat] Direct messages: {s}. Groups: {s}{s}.\n", .{
            @tagName(chat_policy.dm),
            @tagName(chat_policy.group),
            if (chat_policy.require_mention) ", mention required" else "",
        });

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

            // Approvals count only for direct messages under the pairing
            // policy, so the store is read only then. A store that cannot be
            // read approves no one.
            const approved = if (msg.chat_type == .direct and chat_policy.dm == .pairing)
                access_store.isApproved(msg.platform, msg.from) catch |e| blk: {
                    try stderr.print("[chat] Pairing store: {s}; {s}:{s} treated as not approved\n", .{ @errorName(e), msg.platform, msg.from });
                    break :blk false;
                }
            else
                false;
            const inbound = chat_access.Inbound{
                .platform = msg.platform,
                .from = msg.from,
                .channel = msg.channel,
                .guild = msg.guild,
                .chat_type = msg.chat_type,
                .mentioned = msg.mentioned,
            };
            switch (chat_access.decide(&chat_policy, inbound, approved)) {
                .process => {},
                .drop => |why| {
                    try stderr.print("[chat] Ignored {s}:{s}: {s}\n", .{ msg.platform, msg.from, why.describe() });
                    continue;
                },
                .pair => {
                    const outcome = access_store.requestPairing(msg.platform, msg.from, msg.from_name, fsio.timestamp()) catch |e| {
                        try stderr.print("[chat] Pairing store: {s}; {s}:{s} ignored\n", .{ @errorName(e), msg.platform, msg.from });
                        continue;
                    };
                    switch (outcome) {
                        .issued => |code| {
                            const reply = try chat_access.pairingReply(alloc, msg.platform, msg.from, &code);
                            defer alloc.free(reply);
                            bridge.sendReplyThreaded(msg.platform, msg.channel, reply, msg.thread_id) catch |e| {
                                try stderr.print("[Error] Reply failed: {s}\n", .{@errorName(e)});
                            };
                            try stderr.print("[chat] Pairing code sent to {s}:{s}. Approve with: wintermolt --pairing approve {s} {s}\n", .{ msg.platform, msg.from, msg.platform, code });
                        },
                        .pending => try stderr.print("[chat] Ignored {s}:{s}: pairing code already sent, not yet approved\n", .{ msg.platform, msg.from }),
                        .full => try stderr.print("[chat] Ignored {s}:{s}: {s} already has {d} pending pairing requests\n", .{ msg.platform, msg.from, msg.platform, chat_access.MAX_PENDING_PER_PLATFORM }),
                    }
                    continue;
                },
            }

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

            // One pooled conversation per session: a group never shares the
            // DM history (chat_access.sessionKey).
            const session_key = try chat_access.sessionKey(alloc, &chat_policy, route.agent_id, inbound);
            defer alloc.free(session_key);
            // shortcut: an evicted session (idle 30m, or past WINTERMOLT_MAX_AGENTS) restarts empty; resume it from storage when sessions must outlive the pool.
            const routed_agent = pool.getOrCreate(session_key) catch |e| {
                try stderr.print("[Error] Agent pool failed: {s}\n", .{@errorName(e)});
                continue;
            };
            // Only the agent's own DM session is private: MEMORY.md stays
            // out of groups and per-peer sessions (agent/workspace.zig).
            routed_agent.private = std.mem.eql(u8, session_key, route.agent_id);

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

            var response_buf: ArrayList(u8) = .empty;
            defer response_buf.deinit(alloc);

            routed_agent.processInputCapture(msg.text, &response_buf) catch |e| {
                try stderr.print("[Error] Agent {s} failed: {s}\n", .{ route.agent_id, @errorName(e) });
                continue;
            };

            if (response_buf.items.len > 0) {
                // To the conversation, not the person: in a group, `from` is
                // a member and `channel` is the group.
                bridge.sendReplyThreaded(msg.platform, msg.channel, response_buf.items, msg.thread_id) catch |e| {
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

        fsio.sleepNs(500 * std.time.ns_per_ms);
        const is_headless = compat.getenv("K_SERVICE") != null or
            compat.getenv("WINTERMOLT_HEADLESS") != null;
        if (!is_headless) {
            const url = std.fmt.allocPrint(alloc, "http://localhost:{s}", .{port}) catch "http://localhost:3000";
            try stderr.print("[wintermolt] Opening {s}\n", .{url});
            const open_args = try alloc.alloc([]const u8, 2);
            open_args[0] = "open";
            open_args[1] = url;
            // Fire and forget: `open <url>` hands off to the browser and we do
            // not care when it exits.
            fsio.spawnDetached(alloc, open_args) catch {};
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
        // Nothing answered: a script running `-e` sees only the exit status.
        // The agent is freed first because exit() runs static destructors,
        // and the kernel backend must be gone before ggml-metal's runs.
        if (agent.turn_failed) {
            agent.deinit();
            std.process.exit(1);
        }
        return;
    }

    // Interactive. In a real terminal that is the full-screen TUI. Piped stdin, a
    // redirected stdout, --plain or WINTERMOLT_PLAIN=1 keep the plain REPL below,
    // unchanged.
    if (!plain_mode and !plainRequestedByEnv() and compat.stdioIsTerminal()) {
        if (runTui(init, alloc, &agent, &session_mgr, &theme_choice, &theme_reported)) |_| {
            return;
        } else |e| {
            if (e != error.TuiUnavailable) return e;
            try stderr.writeAll("[tui] Could not take over the terminal; using the plain REPL (--plain skips this).\n");
        }
    }

    // Interactive REPL
    if (!theme_reported) try reportThemeRejections(stderr, &theme_choice);
    try printBanner(stdout);

    // stdio.stdinReader is BUFFERED and returned by value, so it is bound to a
    // var and used through a pointer -- copying it would strand buffered bytes.
    // Buffering is wanted here: the REPL reads whole lines.
    var stdin_reader = stdio.stdinReader();
    const stdin = &stdin_reader;
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
        switch (try dispatchCommand(&agent, alloc, &session_mgr, stdout, stderr, stdin, trimmed)) {
            .quit => {
                try stdout.writeAll("Goodbye.\n");
                return;
            },
            .handled => continue,
            .prompt => {},
        }

        // Process through agentic loop
        agent.processInput(trimmed) catch |e| {
            try stderr.print("[Error] {s}\n", .{@errorName(e)});
        };

        try stdout.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Slash-command dispatch (shared by the plain REPL and the TUI)
// ---------------------------------------------------------------------------

const CommandOutcome = enum { quit, handled, prompt };

/// Run `trimmed` if it is a slash command. `.prompt` means it is not one and
/// goes to the model; `.quit` is left to the caller. This is the REPL's command
/// chain moved out of the loop as-is, so the REPL and the TUI run the very same
/// handlers. `stdout`/`stderr` are anything with writeAll/print/writeByte;
/// `stdin` is anything with readUntilDelimiter (only /keys reads it).
fn dispatchCommand(
    agent: *loop_mod.AgentLoop,
    alloc: std.mem.Allocator,
    session_mgr: *session_mod.SessionManager,
    stdout: anytype,
    stderr: anytype,
    stdin: anytype,
    trimmed: []const u8,
) !CommandOutcome {
    if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/exit")) {
        return .quit;
    }
    if (std.mem.eql(u8, trimmed, "/clear") or std.mem.eql(u8, trimmed, "/new")) {
        agent.archiveAndReset();
        try stdout.writeAll("Conversation cleared.\n");
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/help")) {
        try printHelp(stdout);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/model")) {
        const arg = std.mem.trim(u8, trimmed[6..], " \t");
        try handleModel(agent, stdout, if (arg.len > 0) arg else null);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/keys")) {
        const arg = std.mem.trim(u8, trimmed[5..], " \t");
        try handleKeysCmd(alloc, stdout, stdin, if (arg.len > 0) arg else null);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/look")) {
        try handleLook(agent, alloc, stdout, stderr, null);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/look ")) {
        const prompt = std.mem.trim(u8, trimmed[6..], " \t");
        try handleLook(agent, alloc, stdout, stderr, if (prompt.len > 0) prompt else null);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/image") or std.mem.startsWith(u8, trimmed, "/image ")) {
        try handleImage(agent, alloc, stdout, std.mem.trim(u8, trimmed[6..], " \t"));
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/skill") or std.mem.startsWith(u8, trimmed, "/skill ")) {
        try handleSkill(agent, alloc, stdout, std.mem.trim(u8, trimmed[6..], " \t"));
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/screenshot")) {
        const prompt = blk: {
            if (trimmed.len > 11) {
                const p = std.mem.trim(u8, trimmed[11..], " \t");
                break :blk if (p.len > 0) p else null;
            }
            break :blk null;
        };
        try handleScreenshot(agent, alloc, stdout, stderr, prompt);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/stats")) {
        try handleStats(agent, stdout);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/compact")) {
        agent.history.emergencyCompact();
        try stdout.writeAll("History compacted.\n");
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/constitution")) {
        const arg = std.mem.trim(u8, trimmed[13..], " \t");
        try handleConstitution(agent, alloc, stdout, stderr, arg);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/export")) {
        const arg = std.mem.trim(u8, trimmed[7..], " \t");
        try handleExport(agent, alloc, stdout, stderr, if (arg.len > 0) arg else null);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/download ")) {
        const args_str = std.mem.trim(u8, trimmed[10..], " \t");
        if (args_str.len > 0) {
            try handleDownload(alloc, stdout, stderr, args_str);
        } else {
            try stdout.writeAll("Usage: /download <url> [output_path]\n");
        }
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/schedule")) {
        const arg = std.mem.trim(u8, trimmed[9..], " \t");
        try handleScheduleCmd(alloc, stdout, stderr, arg);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/tailscale")) {
        try handleTailscale(alloc, stdout, stderr);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/route")) {
        const arg = std.mem.trim(u8, trimmed[6..], " \t");
        try handleRouteCmd(alloc, stdout, stderr, arg);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/agents")) {
        try handleAgentsCmd(alloc, stdout);
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/tts ")) {
        try handleTtsCmd(alloc, stdout, stderr, trimmed[5..]);
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/tts")) {
        try handleTtsCmd(alloc, stdout, stderr, "");
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, "/listen") or std.mem.startsWith(u8, trimmed, "/listen ")) {
        try handleListen(agent, alloc, stdout, std.mem.trim(u8, trimmed[7..], " \t"));
        return .handled;
    }
    // The full-screen view handles /theme itself (tui.zig); this is the plain
    // REPL's, which lists and saves -- the colours apply in the full-screen view
    // and the canvas.
    if (std.mem.eql(u8, trimmed, "/theme") or std.mem.startsWith(u8, trimmed, "/theme ")) {
        try handleThemeCmd(alloc, stdout, stderr, std.mem.trim(u8, trimmed["/theme".len..], " \t"));
        return .handled;
    }
    if (std.mem.startsWith(u8, trimmed, "/session")) {
        const arg = std.mem.trim(u8, trimmed[8..], " \t");
        try handleSessionCmd(session_mgr, alloc, stdout, arg);
        return .handled;
    }
    return .prompt;
}

// ---------------------------------------------------------------------------
// Full-screen TUI glue (the screen itself is src/tui.zig)
// ---------------------------------------------------------------------------

/// WINTERMOLT_PLAIN=1 -- any value except empty or "0" -- keeps the plain REPL.
fn plainRequestedByEnv() bool {
    const v = compat.getenv("WINTERMOLT_PLAIN") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// WINTERMOLT_TUI_MOUSE=1 -- any value except empty or "0" -- gives the
/// full-screen view the mouse. Off by default so the terminal keeps its own
/// click-and-drag selection and copy.
fn tuiMouseRequestedByEnv() bool {
    const v = compat.getenv("WINTERMOLT_TUI_MOUSE") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

// Theme selection (theme_pref.zig). The saved choice lives in the existing
// ~/.wintermolt/.env, as WINTERMOLT_THEME.

fn themeConfigPath(alloc: std.mem.Allocator) ![]u8 {
    const home = compat.getenv("HOME") orelse return error.NoHomeDir;
    return theme_pref.envPath(alloc, home);
}

/// The saved theme name, as written; null if there is none or it cannot be read.
fn loadSavedTheme(alloc: std.mem.Allocator) ?[]const u8 {
    const path = themeConfigPath(alloc) catch return null;
    return theme_pref.loadSaved(alloc, fsio.io(), fsio.cwd(), path) catch null;
}

fn saveTheme(alloc: std.mem.Allocator, name: []const u8) !void {
    const path = try themeConfigPath(alloc);
    try theme_pref.save(alloc, fsio.io(), fsio.cwd(), path, name);
}

/// "[theme] Unknown theme 'x' (from --theme). Themes: .... Using terminal (the default)."
fn reportThemeRejections(w: anytype, choice: *const theme_pref.Resolved) !void {
    for (choice.rejected()) |r| {
        try w.writeAll("[theme] ");
        try theme_pref.writeUnknown(w, r.value, r.source);
        try w.print(" Using {s} ({s}).\n", .{ choice.name, theme_pref.sourceLabel(choice.source) });
    }
}

/// The plain REPL's /theme: list the themes, or select and save one.
fn handleThemeCmd(alloc: std.mem.Allocator, w: anytype, err_w: anytype, arg: []const u8) !void {
    if (arg.len == 0) return theme_pref.writeList(w, theme_pref.selected());
    const name = theme_pref.canonical(arg) orelse {
        try err_w.writeAll("[theme] ");
        try theme_pref.writeUnknown(err_w, arg, null);
        try err_w.writeByte('\n');
        return;
    };
    _ = theme_pref.select(name);
    saveTheme(alloc, name) catch |e| {
        try err_w.print("[theme] Using {s} for this session; could not save it: {s}\n", .{ name, @errorName(e) });
        return;
    };
    try w.print("Theme set to {s} and saved to ~/.wintermolt/.env. It applies to the full-screen view and the canvas.\n", .{name});
}

/// What the TUI drives: the REPL's own dispatch, on the TUI's worker thread.
/// Handlers and the agent write through stdio.stdout()/stderr(), which the
/// session's sink routes into the transcript.
const TuiRunner = struct {
    agent: *loop_mod.AgentLoop,
    alloc: std.mem.Allocator,
    session_mgr: *session_mod.SessionManager,

    fn runner(self: *TuiRunner) tui.Runner {
        return .{ .ctx = self, .run = run, .info = info, .set_theme = setTheme };
    }

    /// UI thread, between jobs only: select `name` for the canvas and save it.
    fn setTheme(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *TuiRunner = @ptrCast(@alignCast(ctx));
        _ = theme_pref.select(name);
        try saveTheme(self.alloc, name);
    }

    fn run(ctx: *anyopaque, line: []const u8, _: *tui.Inbox) void {
        const self: *TuiRunner = @ptrCast(@alignCast(ctx));
        const err = stdio.stderr();
        self.runLine(line, stdio.stdout(), err) catch |e| {
            err.print("[Error] {s}\n", .{@errorName(e)}) catch {};
        };
        // The REPL runs due jobs before every prompt.
        _ = self.agent.tickScheduler();
    }

    fn runLine(self: *TuiRunner, line: []const u8, out: stdio.FileWriter, err: stdio.FileWriter) !void {
        if (keysCommandPrompts(line)) {
            try out.writeAll("/keys asks for a value on stdin, which the full-screen view owns. " ++
                "Use /keys list here, or run `wintermolt --keys` (or --plain).\n");
            return;
        }
        var no_stdin: NoStdin = .{};
        switch (try dispatchCommand(self.agent, self.alloc, self.session_mgr, out, err, &no_stdin, line)) {
            .quit, .handled => {},
            .prompt => self.agent.processInput(line) catch |e| {
                try err.print("[Error] {s}\n", .{@errorName(e)});
            },
        }
    }

    /// UI thread, between jobs only.
    fn info(ctx: *anyopaque) tui.Info {
        const self: *TuiRunner = @ptrCast(@alignCast(ctx));
        const b = self.agent.getBackendInfo();
        return .{ .backend = b.name, .model = b.model };
    }
};

/// stdin for handlers run inside the TUI, which owns the real one: end of input.
const NoStdin = struct {
    fn readUntilDelimiter(_: *NoStdin, _: []u8, _: u8) error{EndOfStream}![]u8 {
        return error.EndOfStream;
    }
};

/// /keys prompts on stdin unless it is `/keys list` or `/keys status`.
fn keysCommandPrompts(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "/keys")) return false;
    const arg = std.mem.trim(u8, line[5..], " \t");
    return !(std.mem.eql(u8, arg, "list") or std.mem.eql(u8, arg, "status"));
}

/// Run the TUI until the user quits. error.TuiUnavailable means the terminal
/// could not be taken over and nothing was changed, so the caller can fall back
/// to the plain REPL.
fn runTui(
    init: std.process.Init,
    alloc: std.mem.Allocator,
    agent: *loop_mod.AgentLoop,
    session_mgr: *session_mod.SessionManager,
    theme_choice: *const theme_pref.Resolved,
    theme_reported: *bool,
) !void {
    const gpa = init.gpa;
    var runner: TuiRunner = .{ .agent = agent, .alloc = alloc, .session_mgr = session_mgr };
    var session = tui.Session.init(gpa, runner.runner(), VERSION);
    defer session.deinit();
    session.theme = theme_choice.name;

    // Due jobs, as the REPL runs them before its first prompt -- before the
    // screen is taken, so anything they print reaches the normal console.
    _ = agent.tickScheduler();

    // zortui's frame timing, animation and input-wait deadlines all read
    // forTime's monotonic clock (ftim_mono_ns), never a clock of its own.
    var app = zortui.App.init(
        gpa,
        tui.appOptions(.fromEnviron(&init.minimal.environ), fsio.monoNs, tuiMouseRequestedByEnv(), theme_choice.name),
    ) catch return error.TuiUnavailable;
    tui.applyTheme(&app, theme_choice.name);

    // Theme names that were given but are not themes: [error] lines up top.
    for (theme_choice.rejected()) |r| {
        var msg: std.Io.Writer.Allocating = .init(gpa);
        defer msg.deinit();
        msg.writer.writeAll("[error] ") catch continue;
        theme_pref.writeUnknown(&msg.writer, r.value, r.source) catch continue;
        msg.writer.print(" Using {s} ({s}).", .{ theme_choice.name, theme_pref.sourceLabel(theme_choice.source) }) catch continue;
        session.transcript.add(.err, msg.written());
    }
    theme_reported.* = true;

    tui.active.store(true, .release);
    session.installSink();
    const result = tuiLoop(&app, &session);
    tui.active.store(false, .release);
    app.deinit(); // alternate screen off, console modes and code pages back

    if (session.busy) {
        // A request is still running on the worker. It cannot be cancelled in
        // the middle of an HTTP call, and joining would hang until the model
        // finished, so the process ends here. The sink stays installed so the
        // worker's remaining output cannot land on the restored shell.
        compat.restoreConsole();
        const direct: stdio.FileWriter = .{ .fd = stdio.stdout().fd };
        direct.writeAll("Interrupted.\n") catch {};
        std.process.exit(if (result) |_| 0 else |_| 1);
    }
    session.uninstallSink();
    try result;
    stdio.stdout().writeAll("Goodbye.\n") catch {};
}

fn tuiLoop(app: *zortui.App, session: *tui.Session) !void {
    while (app.running() and !session.quit_requested) {
        for (try app.poll()) |event| session.handleEvent(event);
        // A finished job repaints the whole screen: a child process with an
        // inherited stderr (an MCP server) can write to the console behind the
        // sink's back. Ctrl+L does the same on demand.
        if (session.pump() or session.takeRedraw()) app.redraw();
        // /theme: the next frame is drawn, in full, in the new palette.
        if (session.takeThemeChange()) |name| tui.applyTheme(app, name);
        _ = try app.draw(zortui.Body.with(session, tui.Session.view));
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
        // A backend that cannot be built leaves the current one in place and has
        // already said why on stderr; /model is not a place to end the session.
        agent.switchBackend(backend, model) catch {};
    } else {
        const info = agent.getBackendInfo();
        try w.print("Current: {s} ({s})\n", .{ info.name, info.model });
        try w.writeAll("Usage: /model <backend> [model]\n");
        try w.writeAll("Backends: ollama (default), forai (in-process), kernel, claude, openai, deepseek, qwen, gemini\n");
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
        .{ .key = "DEEPGRAM_API_KEY", .label = "Deepgram (voice in and out)", .hint = null },
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
    var stream: std.Io.Writer = .fixed(&content_buf);
    const sw = &stream;

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
    fsio.makePath(dir_path) catch {};

    const file = fsio.createFile(env_path, .{ .truncate = true }) catch return;
    defer fsio.close(file);
    fsio.writeAll(file, stream.buffered()) catch {};

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

    try agent.processInputImage(prompt, .{ .media_type = capture_result.media_type, .data = capture_result.data });
}

/// `/image <path> [prompt]`. The path may be quoted (Windows Terminal drops a
/// dragged file that way) or use `\ ` for a space (macOS Terminal does).
fn parseImageArg(arg: []const u8, buf: []u8) ?struct { path: []const u8, prompt: []const u8 } {
    if (arg.len == 0) return null;
    var path: []const u8 = undefined;
    var i: usize = 0;
    if (arg[0] == '"' or arg[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, arg, 1, arg[0]) orelse return null;
        path = arg[1..end];
        i = end + 1;
    } else {
        var n: usize = 0;
        while (i < arg.len and arg[i] != ' ' and arg[i] != '\t') : (i += 1) {
            if (arg[i] == '\\' and i + 1 < arg.len and arg[i + 1] == ' ') i += 1;
            if (n == buf.len) return null;
            buf[n] = arg[i];
            n += 1;
        }
        path = buf[0..n];
    }
    return .{ .path = path, .prompt = std.mem.trim(u8, arg[i..], " \t") };
}

/// /skill lists the SKILL.md skills; /skill <name> [input] has the model use one.
fn handleSkill(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, arg: []const u8) !void {
    if (arg.len == 0) {
        const all = try skill_md.discover(alloc);
        defer skill_md.freeAll(alloc, all);
        if (all.len == 0) {
            try w.writeAll("No SKILL.md skills. Put one in ./skills/<name>/, ~/.agents/skills/<name>/ or ~/.wintermolt/skills/<name>/ (docs/SKILLS.md).\n");
            return;
        }
        for (all) |s| try w.print("  {s} -- {s}\n    {s}\n", .{ s.name, s.description[0..@min(s.description.len, 100)], s.location });
        try w.writeAll("Use one with /skill <name> [what to do].\n");
        return;
    }
    const space = std.mem.indexOfAny(u8, arg, " \t") orelse arg.len;
    const name = arg[0..space];
    const input = std.mem.trim(u8, arg[space..], " \t");
    const skill = (try skill_md.find(alloc, name)) orelse {
        try w.print("[skill] No skill named {s}. /skill lists them.\n", .{name});
        return;
    };
    defer skill.deinit(alloc);
    const prompt = try std.fmt.allocPrint(alloc, "Use the {s} skill: read {s} with file_read and follow it.{s}{s}", .{
        skill.name, skill.location, if (input.len > 0) "\n\n" else "", input,
    });
    defer alloc.free(prompt);
    try agent.processInput(prompt);
}

fn handleImage(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, arg: []const u8) !void {
    var path_buf: [1024]u8 = undefined;
    const parsed = parseImageArg(arg, &path_buf) orelse {
        try w.writeAll("Usage: /image <file> [prompt]   (png, jpeg, gif or webp; drag the file in for its path)\n");
        return;
    };
    const img = camera.readAndEncode(alloc, parsed.path) catch |e| {
        try w.print("[image] Cannot attach {s}: {s}\n", .{ parsed.path, @errorName(e) });
        return;
    };
    defer alloc.free(img.data);

    const prompt = if (parsed.prompt.len > 0) parsed.prompt else "What's in this image?";
    try agent.processInputImage(prompt, .{ .media_type = img.media_type, .data = img.data });
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

    try agent.processInputImage(prompt, .{ .media_type = capture_result.media_type, .data = capture_result.data });
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

    // Apply backend override
    if (model_override) |override| {
        child_agent.switchBackend(override, null) catch {};
    }

    child_agent.startConversation();

    // Capture output
    var output_buf: ArrayList(u8) = .empty;
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
            try w.print("[session] Error: {s}\n", .{@errorName(e)});
            return;
        };
        try w.print("[session] Ended: {s}\n", .{sid});
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
        const voice = compat.getenv("WINTERMOLT_TTS_VOICE") orelse "the provider's default";
        try w.print("TTS Status\n", .{});
        try w.print("  Provider: {s}\n", .{@tagName(tts_mod.providerFromEnv())});
        try w.print("  Voice: {s}\n", .{voice});
        try w.writeAll("\nUsage: /tts <text to speak>\n");
        try w.writeAll("Inline directives: [[voice:nova]] [[speed:1.2]] [[provider:openai]]\n");
        try w.writeAll("\nProviders: deepgram, openai, elevenlabs, piper, edge, system (the computer's own voice)\n");
        try w.writeAll("Unset, the first with a key: DEEPGRAM_API_KEY, OPENAI_API_KEY, ELEVENLABS_API_KEY; else system.\n");
        try w.writeAll("Deepgram voices: thalia, andromeda, helena, apollo, arcas, aries (aura-2-<name>-en)\n");
        try w.writeAll("OpenAI voices: alloy, echo, fable, onyx, nova, shimmer\n");
        return;
    }

    try w.writeAll("[tts] Synthesizing...\n");
    var client = tts_mod.TtsClient.init(alloc);
    const path = client.synthesizeToFile(text) catch |e| {
        try w.print("[tts] Error: {s}\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(path);
    try w.print("[tts] Audio saved: {s}\n", .{path});
    tts_mod.playDetached(alloc, path) catch |e| try w.print("[tts] Could not play it: {s}\n", .{@errorName(e)});
}

/// /listen [seconds | audio file]: record the microphone (or take a recording
/// already made), send what was said as the prompt, and say the reply aloud.
fn handleListen(agent: *loop_mod.AgentLoop, alloc: std.mem.Allocator, w: anytype, arg: []const u8) !void {
    const seconds: ?u32 = if (arg.len == 0) 5 else std.fmt.parseInt(u32, arg, 10) catch null;
    if (seconds) |s| if (s == 0 or s > 120) {
        try w.writeAll("Usage: /listen [seconds | audio file]  (1-120 seconds, default 5)\n");
        return;
    };
    // First, so both models load while you speak.
    agent.warmForVoice();
    stt_mod.startServer(alloc);
    // The TUI's spinner says what we wait on; the plain REPL has the lines.
    defer tui.setActivity(null);

    var path_buf: [512]u8 = undefined;
    const path = if (seconds) |s| blk: {
        const mic_path = try camera.tempPath(&path_buf, "wintermolt_mic.wav");
        tui.setActivity("opening mic");
        try w.writeAll("[listen] Opening the microphone...\n");
        var rec = stt_mod.startRecording(alloc, mic_path, s) catch |e| {
            try w.print("[listen] Could not record the microphone: {s} (needs ffmpeg; WINTERMOLT_MIC picks the device)\n", .{@errorName(e)});
            return;
        };
        tui.setActivity("recording");
        try w.print("[listen] Recording {d}s, speak now...\n", .{s});
        rec.finish() catch |e| {
            try w.print("[listen] Could not record the microphone: {s} (needs ffmpeg; WINTERMOLT_MIC picks the device)\n", .{@errorName(e)});
            return;
        };
        break :blk mic_path;
    } else arg;
    if (stt_mod.serverLoading()) {
        tui.setActivity("loading speech");
        try w.writeAll("[listen] Loading the speech model, first /listen only (a few seconds)...\n");
    } else {
        tui.setActivity("transcribing");
        try w.writeAll("[listen] Transcribing...\n");
    }
    const said = stt_mod.transcribe(alloc, path);
    tui.setActivity(null);
    if (seconds != null) fsio.deleteFile(path) catch {}; // ours; never the user's file
    const text = said catch |e| {
        // Deepgram is the only provider with a key to refuse.
        if (e == error.ApiKeyRejected)
            try w.writeAll("[listen] Deepgram refused DEEPGRAM_API_KEY (set it with `wintermolt --keys`, or /keys deepgram)\n")
        else
            try w.print("[listen] Could not transcribe it: {s} (needs a whisper.cpp model in ~/.wintermolt/models, or DEEPGRAM_API_KEY)\n", .{@errorName(e)});
        return;
    };
    defer alloc.free(text);
    if (text.len == 0) {
        try w.writeAll("[listen] Heard nothing.\n");
        return;
    }
    try w.print("[listen] You said: {s}\n", .{text});

    spoken_len = 0;
    agent.voice_callback = &collectSpoken;
    defer agent.voice_callback = null;
    try agent.processInput(text);
    try w.writeByte('\n');
    tts_mod.speak(alloc, spoken_buf[0..spoken_len]) catch |e|
        try w.print("[listen] Could not say the reply: {s}\n", .{@errorName(e)});
}

// The reply /listen says aloud. voice_callback carries no context, so it lands
// here; one command runs at a time. tts.speak cuts it to what it will say.
var spoken_buf: [8192]u8 = undefined;
var spoken_len: usize = 0;

fn collectSpoken(text: []const u8) void {
    if (spoken_len > 0 and spoken_len < spoken_buf.len) {
        spoken_buf[spoken_len] = '\n';
        spoken_len += 1;
    }
    const n = @min(text.len, spoken_buf.len - spoken_len);
    @memcpy(spoken_buf[spoken_len..][0..n], text[0..n]);
    spoken_len += n;
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
            try w.print("[route] Failed to add: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(binding_id);
        try w.print("[route] Added binding [{s}] → agent:{s} (tier:{s})\n", .{ binding_id[0..8], agent_id, tier_str });
        return;
    }

    // /route remove <binding_id>
    if (std.mem.startsWith(u8, arg, "remove ")) {
        const id = std.mem.trim(u8, arg[7..], " \t");
        _ = router.removeBinding(id);
        try w.print("[route] Removed binding: {s}\n", .{id});
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

/// The banner sized to the window and painted in the terminal's own colors;
/// piped output and NO_COLOR get the plain lettering (banner.zig).
fn printBanner(w: *std.Io.Writer) !void {
    const color = banner.colorWanted(compat.stdoutIsTerminal(), compat.getenv("NO_COLOR"), compat.getenv("TERM"));
    const size: ?banner.Size = if (compat.terminalSize()) |s| .{ .columns = s.columns, .rows = s.rows } else null;
    try banner.write(w, banner.forPlain(size, color));
    try w.print("  v{s} — Lite AI Agent CLI (MIT)\n", .{VERSION});
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
        \\  /model [name]  — Switch AI backend (ollama, forai [in-process], kernel, claude, openai, deepseek, qwen, gemini)
        \\  /keys          — Add/update API keys (interactive menu)
        \\  /keys list     — Show all configured keys
        \\  /look [prompt] — Capture camera image and describe it
        \\  /image <file> [prompt] — Attach an image file (drag it in for the path)
        \\  /screenshot    — Capture screen and describe it
        \\  /skill [name] [input] — List SKILL.md skills, or have the model use one
        \\  /stats         — Show session statistics
        \\  /compact       — Compact conversation history
        \\  /constitution  — View/reload system prompt
        \\  /export [fmt]  — Export conversation (jsonl, csv)
        \\  /download URL  — Download a file
        \\  /schedule      — Manage scheduled jobs (list, add, remove)
        \\  /tts <text>    — Synthesize text to speech (plays audio)
        \\  /listen [secs|file] — Say a prompt into the microphone (default 5s), or give a recording; the reply is spoken
        \\  /session       — Manage chat sessions (list, end, cleanup)
        \\  /route         — Manage multi-agent routing bindings
        \\  /agents        — Show agent pool status
        \\  /tailscale     — Show Tailscale network status
        \\  /theme [name]  — List themes, or switch the full-screen view and canvas and save it
        \\
        \\Modes:
        \\  wintermolt              — Interactive chat: full-screen in a terminal,
        \\                            plain REPL when stdin or stdout is not a terminal
        \\  wintermolt --plain      — Plain line-by-line REPL, even in a terminal
        \\  wintermolt --theme NAME — Theme for the full-screen view and canvas (this run):
        \\                            dark, dracula, nord, tokyo-night, gruvbox, matrix,
        \\                            monochrome, high-contrast, light
        \\  wintermolt -e "prompt"  — Single-shot execution (exits 1 if no backend answers)
        \\  wintermolt --keys      — Configure API keys
        \\  wintermolt --setup      — Alias for --keys
        \\  wintermolt --chat       — Chat bridge (16 platforms; access rules below)
        \\  wintermolt --pairing list [platform]
        \\  wintermolt --pairing approve <platform> <code>
        \\  wintermolt --pairing revoke <platform> <sender>
        \\                          — Who may message the agent through --chat
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
        \\  Teams          not available yet (inbound is not authenticated)
        \\  Google Chat    not available yet (inbound is not authenticated)
        \\  LINE           LINE_CHANNEL_SECRET + LINE_CHANNEL_TOKEN
        \\  Feishu/Lark    FEISHU_APP_ID + FEISHU_APP_SECRET + FEISHU_VERIFICATION_TOKEN
        \\  Mattermost     MATTERMOST_URL + MATTERMOST_TOKEN
        \\  Twitch         TWITCH_ACCESS_TOKEN + TWITCH_CHANNELS
        \\  Nostr          NOSTR_PRIVATE_KEY (+ NOSTR_RELAYS)
        \\  XMPP/Jabber    XMPP_JID + XMPP_PASSWORD
        \\  Zulip          ZULIP_EMAIL + ZULIP_API_KEY + ZULIP_SITE
        \\  Rocket.Chat    ROCKETCHAT_URL + ROCKETCHAT_TOKEN + ROCKETCHAT_USER_ID
        \\
        \\Chat access (lists are platform:id,... or *; docs/DEPLOYMENT.md):
        \\  WINTERMOLT_CHAT_DM_POLICY     pairing (default) | allowlist | open | disabled
        \\  WINTERMOLT_CHAT_ALLOW_FROM    Who may send direct messages
        \\  WINTERMOLT_CHAT_GROUP_POLICY  allowlist (default) | open | disabled
        \\  WINTERMOLT_CHAT_GROUPS        Which groups (or Discord servers, Zulip streams)
        \\  WINTERMOLT_CHAT_GROUP_ALLOW_FROM  Who may trigger it in a group
        \\                                (default: WINTERMOLT_CHAT_ALLOW_FROM)
        \\  WINTERMOLT_CHAT_REQUIRE_MENTION=0  Answer group messages without a mention
        \\  WINTERMOLT_CHAT_DM_SCOPE      main (default: DMs share one conversation) | per-peer
        \\                                (each sender their own); every group has its own
        \\
        \\Environment:
        \\  ANTHROPIC_API_KEY    — Claude API key (optional)
        \\  WINTERMOLT_BACKEND   — Backend a run starts on: ollama (default), claude,
        \\                         openai, deepseek, qwen, gemini, kernel, forai.
        \\                         A name that cannot be built exits 1
        \\  WINTERMOLT_MODEL     — Default model
        \\  OLLAMA_HOST          — Ollama URL (default: http://localhost:11434)
        \\  OPENAI_API_KEY       — OpenAI API key
        \\  WINTERMOLT_OPENAI_URL — OpenAI-compatible Chat Completions URL
        \\                         (default: https://api.openai.com/v1/chat/completions)
        \\  DEEPSEEK_API_KEY     — DeepSeek API key
        \\  QWEN_API_KEY         — Qwen API key
        \\  TAILSCALE_API_KEY    — Tailscale API key (optional, for device list)
        \\  WINTERMOLT_NO_FALLBACK=1 — A failed request fails (-e exits 1) instead of
        \\                         being answered by Ollama or OpenAI
        \\  WINTERMOLT_NO_TOOLS=1  — Send no tool definitions (models without function calling)
        \\  WINTERMOLT_MAX_ITERATIONS=N — Tool-loop iterations per turn before the agent
        \\                         gives up (default: 25). Raise it for long multi-step tasks
        \\  WINTERMOLT_STALL_TIMEOUT=SECS — Drop a model request after SECS with nothing
        \\                         received (default: 180; 0 = never)
        \\  WINTERMOLT_PLAIN=1   — Same as --plain: never open the full-screen view
        \\  WINTERMOLT_TUI_MOUSE=1 — Full-screen view takes the mouse (wheel, clicks);
        \\                         the terminal can then no longer select text
        \\  WINTERMOLT_THEME=NAME  — Theme, below --theme and above the one /theme saved
        \\                         in ~/.wintermolt/.env (default: terminal)
        \\
    );
}

// ---------------------------------------------------------------------------
// Test aggregation. build.zig roots the `test` step at THIS file, and Zig
// collects test blocks only from the root's own source -- NOT from its imports.
// This file has no test blocks of its own, so before this block existed
// `zig build test` compiled, ran ZERO tests, and reported success. The 17 tests
// in agent/redact.zig had never executed.
//
// Every file that contains `test "..."` must be referenced here or its tests do
// not run, and nothing will say so. Verify a change to this list the only way
// that works: `zig build test --summary all` and read the test COUNT, then break
// one test on purpose and confirm it is reported.
// ---------------------------------------------------------------------------
test {
    _ = @import("agent/redact.zig");
    _ = @import("agent/config.zig");
    _ = @import("api/deepseek.zig");
    _ = @import("api/ollama.zig");
    _ = @import("api/openai_sse.zig");
    _ = @import("api/protocol.zig");
    _ = @import("api/sse.zig");
    _ = @import("tools/browser.zig");
}

test "/image: a path is split from its prompt, as each terminal drops a file in" {
    var buf: [256]u8 = undefined;
    const plain = parseImageArg("shot.png what is this?", &buf).?;
    try std.testing.expectEqualStrings("shot.png", plain.path);
    try std.testing.expectEqualStrings("what is this?", plain.prompt);

    // Windows Terminal quotes a dragged path that has a space.
    const quoted = parseImageArg("\"C:\\Users\\me\\My Pics\\a.png\"  describe", &buf).?;
    try std.testing.expectEqualStrings("C:\\Users\\me\\My Pics\\a.png", quoted.path);
    try std.testing.expectEqualStrings("describe", quoted.prompt);

    // macOS Terminal escapes the space instead.
    const escaped = parseImageArg("/Users/me/My\\ Pics/a.png", &buf).?;
    try std.testing.expectEqualStrings("/Users/me/My Pics/a.png", escaped.path);
    try std.testing.expectEqualStrings("", escaped.prompt);

    try std.testing.expect(parseImageArg("", &buf) == null);
    try std.testing.expect(parseImageArg("\"never closed.png", &buf) == null);
}
