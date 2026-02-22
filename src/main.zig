// Copyright The Fantastic Planet - By David Clabaugh
//
// main.zig — Wintermolt entry point
//
// Lite AI assistant CLI powered by Claude API + multi-backend AI.
// Open-core: AGPL-3.0. No forKernels, no proprietary subsystems.
//
// Usage:
//   wintermolt              — interactive REPL
//   wintermolt --help       — show help
//   wintermolt -e "prompt"  — single-shot execution
//   wintermolt --setup      — run OOBE wizard
//   wintermolt --chat       — chat bridge mode (Discord/WhatsApp/Telegram/Slack)
//   wintermolt --web        — web UI mode
//   wintermolt --mcp-server — MCP JSON-RPC server over stdio

const std = @import("std");
const ArrayList = std.ArrayList;
const config_mod = @import("agent/config.zig");
const loop_mod = @import("agent/loop.zig");
const chat_bridge = @import("chat/bridge.zig");
const web_bridge = @import("web/bridge.zig");
const menubar_bridge = @import("menubar/bridge.zig");
const tailscale_tool = @import("tools/tailscale.zig");
const camera = @import("tools/camera.zig");
const http_tool = @import("tools/http.zig");
const protocol = @import("api/protocol.zig");
const setup = @import("setup.zig");
const export_mod = @import("agent/export.zig");

const VERSION = "0.1.0";

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
        if (std.mem.eql(u8, arg, "--setup")) {
            run_setup = true;
        }
        if (std.mem.eql(u8, arg, "--mcp-server")) {
            mcp_server_mode = true;
        }
        if (std.mem.eql(u8, arg, "-e")) {
            exec_prompt = args.next();
            if (exec_prompt == null) {
                try stderr.writeAll("Error: -e requires a prompt argument\n");
                std.process.exit(1);
            }
        }
    }

    // Auto-trigger OOBE setup if no API key AND no .env file, or explicit --setup
    if (run_setup or (std.posix.getenv("ANTHROPIC_API_KEY") == null and !setup.envFileExists())) {
        setup.runSetup(alloc, run_setup) catch |e| {
            if (e != error.SetupAborted) {
                try stderr.print("[setup] Error: {s}\n", .{@errorName(e)});
            }
            if (!run_setup) std.process.exit(1);
        };
        if (run_setup) return;
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

    // Chat mode
    if (chat_mode) {
        try stderr.writeAll("[wintermolt] Starting chat mode...\n");
        var bridge = chat_bridge.ChatBridge.init(alloc) catch |e| {
            try stderr.print("[wintermolt] Failed to start chat sidecar: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer bridge.deinit();

        while (bridge.readMessage()) |msg| {
            try stderr.print("[{s}] {s}: {s}\n", .{ msg.platform, msg.from, msg.text });
            agent.startConversation();

            var response_buf: ArrayList(u8) = .{};
            defer response_buf.deinit(alloc);

            agent.processInputCapture(msg.text, &response_buf) catch |e| {
                try stderr.print("[Error] Agent failed: {s}\n", .{@errorName(e)});
                continue;
            };

            if (response_buf.items.len > 0) {
                bridge.sendReply(msg.platform, msg.from, response_buf.items) catch |e| {
                    try stderr.print("[Error] Reply failed: {s}\n", .{@errorName(e)});
                };
            }
        }

        try stderr.writeAll("[wintermolt] Chat sidecar exited\n");
        return;
    }

    // Web mode
    if (web_mode) {
        const port = std.posix.getenv("PORT") orelse std.posix.getenv("WINTERMOLT_WEB_PORT") orelse "3000";
        try stderr.print("[wintermolt] Starting web mode on port {s}...\n", .{port});
        var bridge = web_bridge.WebBridge.init(alloc, &agent) catch |e| {
            try stderr.print("[wintermolt] Failed to start web sidecar: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        defer bridge.deinit();

        std.Thread.sleep(500 * std.time.ns_per_ms);
        const is_headless = std.posix.getenv("K_SERVICE") != null or
            std.posix.getenv("WINTERMOLT_HEADLESS") != null;
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
        try w.writeAll("Backends: claude, ollama, openai, deepseek, qwen, gemini\n");
    }
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
    try w.print("  v{s} — Lite AI Agent CLI (AGPL-3.0)\n", .{VERSION});
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
        \\  /model [name]  — Switch AI backend (claude, ollama, openai, deepseek, qwen, gemini)
        \\  /look [prompt] — Capture camera image and describe it
        \\  /screenshot    — Capture screen and describe it
        \\  /stats         — Show session statistics
        \\  /compact       — Compact conversation history
        \\  /constitution  — View/reload system prompt
        \\  /export [fmt]  — Export conversation (jsonl, csv)
        \\  /download URL  — Download a file
        \\  /schedule      — Manage scheduled jobs (list, add, remove)
        \\  /tailscale     — Show Tailscale network status
        \\
        \\Modes:
        \\  wintermolt              — Interactive REPL
        \\  wintermolt -e "prompt"  — Single-shot execution
        \\  wintermolt --setup      — Run setup wizard
        \\  wintermolt --chat       — Chat bridge (Discord/WhatsApp/Telegram/Slack)
        \\  wintermolt --web        — Web UI
        \\  wintermolt --menubar    — macOS menu bar sidecar
        \\  wintermolt --mcp-server — MCP JSON-RPC server
        \\
        \\Environment:
        \\  ANTHROPIC_API_KEY    — Claude API key (required)
        \\  WINTERMOLT_MODEL     — Default model
        \\  OLLAMA_HOST          — Ollama URL (default: http://localhost:11434)
        \\  OPENAI_API_KEY       — OpenAI API key
        \\  DEEPSEEK_API_KEY     — DeepSeek API key
        \\  QWEN_API_KEY         — Qwen API key
        \\  TAILSCALE_API_KEY    — Tailscale API key (optional, for device list)
        \\
    );
}
