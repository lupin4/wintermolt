// Copyright The Fantastic Planet - By David Clabaugh
//
// loop.zig — Wintermolt agentic loop
//
// Core agent loop: user message → send to AI backend → execute tools → repeat.
// Supports multi-backend (Claude, Ollama, OpenAI-compatible) with automatic
// fallback when the primary backend fails.
//
// Stripped from Wintermolt: no router/triage, no cortex, no hippocampus,
// no RL, no council/debate, no compressor, no dreamer, no forKernels.

const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

// Core imports (self-contained, no proprietary deps)
const client_mod = @import("../api/client.zig");
const protocol = @import("../api/protocol.zig");
const sse = @import("../api/sse.zig");
const ollama_mod = @import("../api/ollama.zig");
const deepseek_mod = @import("../api/deepseek.zig");
const kernel_mod = @import("../api/kernel.zig");
const forai_mod = @import("../api/forai.zig");
const history_mod = @import("history.zig");
const tools = @import("tools.zig");
const config_mod = @import("config.zig");
const storage_mod = @import("storage.zig");
const rag_mod = @import("rag.zig");
const skill_loader = @import("skill_loader.zig");
const redact = @import("redact.zig");
const scheduler_mod = @import("scheduler.zig");
const camera_tool = @import("../tools/camera.zig");

const MAX_ITERATIONS = 25;

// Output leak guard (redact.zig): per-reply redactor + inner callback at module
// scope (TextCallback carries no userdata). Replies are sequential per process.
var g_redactor: ?redact.Redactor = null;
var g_inner_cb: ?sse.TextCallback = null;

pub const Backend = union(enum) {
    claude: client_mod.Client,
    ollama: ollama_mod.OllamaClient,
    openai: deepseek_mod.DeepSeekClient,
    kernel: kernel_mod.KernelClient,
    forai: forai_mod.ForAIClient,
};

pub const AgentLoop = struct {
    alloc: Allocator,
    backend: Backend,
    history: history_mod.History,
    config: *config_mod.Config,
    storage: ?storage_mod.Storage,
    rag: ?rag_mod.RagClient,
    skill_registry: ?skill_loader.SkillRegistry,
    scheduler: ?scheduler_mod.Scheduler,
    system_prompt: []const u8,

    // Conversation tracking
    conversation_id: ?[]const u8,
    message_sequence: u32,
    tool_errors_this_turn: u32,
    last_message_ts: i64,

    // Subagent hierarchy
    depth: u8, // 0 = root agent, >0 = subagent
    subagent_manager: ?*anyopaque, // *subagent_mod.SubagentManager (opaque to avoid circular dep)

    // Streaming/bridge callbacks (for chat bridge and web UI)
    capture_buf: ?*ArrayList(u8),
    voice_callback: ?*const fn ([]const u8) void,
    voice_start_callback: ?*const fn () void,
    stream_callback: ?sse.TextCallback,
    tool_start_callback: ?*const fn ([]const u8, []const u8) void,
    tool_done_callback: ?*const fn ([]const u8, bool) void,
    perspective_callback: ?*const fn ([]const u8) void,
    web_message_id: ?[]const u8,

    pub fn init(alloc: Allocator, config: *config_mod.Config) !AgentLoop {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Initialize backend — Ollama is the default (no API key required)
        const backend: Backend = .{ .ollama = ollama_mod.OllamaClient.initWithOptions(
            alloc,
            config.ollama_url,
            config.model,
            config.ollama_num_ctx,
            config.ollama_keep_alive,
        ) };

        // Initialize history
        var history = history_mod.History.init(alloc);

        // Initialize SQLite storage
        var storage: ?storage_mod.Storage = null;
        if (config.history_enabled) {
            storage = storage_mod.Storage.init(alloc) catch |e| blk: {
                stderr.print("[storage] Init failed: {s}\n", .{@errorName(e)}) catch {};
                break :blk null;
            };
        }

        // Initialize Pinecone RAG client if configured
        var rag: ?rag_mod.RagClient = null;
        if (config.pinecone_api_key) |pk| {
            if (config.pinecone_host) |ph| {
                rag = rag_mod.RagClient.init(alloc, pk, ph);
                const log = std.fs.File.stderr().deprecatedWriter();
                log.writeAll("[rag] Pinecone RAG enabled\n") catch {};
            }
        }

        // Build system prompt with capabilities
        const capabilities = config_mod.buildCapabilities(
            config,
            alloc,
            tools.getDefinitions().len,
        ) catch "";

        var system_prompt_buf: ArrayList(u8) = .{};
        system_prompt_buf.appendSlice(alloc, config.system_prompt) catch {};
        if (capabilities.len > 0) {
            system_prompt_buf.appendSlice(alloc, capabilities) catch {};
            alloc.free(capabilities);
        }
        // Tell history about overhead so it can manage context window
        history.setOverhead(system_prompt_buf.items.len, tools.getDefinitions().len * 200, config.max_tokens);

        // Initialize skill loader
        var skill_registry: ?skill_loader.SkillRegistry = null;
        skill_registry = skill_loader.SkillRegistry.init(alloc);

        // Initialize scheduler (SQLite-persisted cron jobs)
        var scheduler: ?scheduler_mod.Scheduler = null;
        scheduler = scheduler_mod.Scheduler.init(alloc) catch |e| blk: {
            stderr.print("[scheduler] Init failed: {s}\n", .{@errorName(e)}) catch {};
            break :blk null;
        };

        // NOTE: do NOT pass pointers to the locals above into tools.set*()
        // here — init returns by value, so those pointers would dangle.
        // Callers must invoke bindTools() once the AgentLoop has its final
        // address; processInput() also re-binds on every call.

        // Set tool policies from config
        tools.setPolicy(config.tool_allowlist, config.tool_blocklist);

        return .{
            .alloc = alloc,
            .backend = backend,
            .history = history,
            .config = config,
            .storage = storage,
            .rag = rag,
            .skill_registry = skill_registry,
            .scheduler = scheduler,
            .system_prompt = system_prompt_buf.items,
            .conversation_id = null,
            .message_sequence = 0,
            .tool_errors_this_turn = 0,
            .last_message_ts = 0,
            .depth = 0,
            .subagent_manager = null,
            .capture_buf = null,
            .voice_callback = null,
            .voice_start_callback = null,
            .stream_callback = null,
            .tool_start_callback = null,
            .tool_done_callback = null,
            .perspective_callback = null,
            .web_message_id = null,
        };
    }

    pub fn deinit(self: *AgentLoop) void {
        // Drain backend resources before any global destructors run.
        // Critical for the kernel backend: llama.cpp asserts
        // [rsets->data count] == 0 in ggml-metal's static destructor.
        switch (self.backend) {
            .kernel => |*k| k.deinit(),
            .forai => |*f| f.deinit(),
            else => {},
        }
        if (self.scheduler) |*s| s.deinit();
        if (self.storage) |*s| s.deinit();
    }

    /// Re-bind the tools module's global pointers to this agent's state.
    /// Must be called after init() once the AgentLoop has its final address
    /// (init returns by value, so pointers taken during init would dangle).
    /// processInput() calls this on every turn, which also keeps the globals
    /// correct when multiple AgentLoops (pool/subagents) share the process.
    pub fn bindTools(self: *AgentLoop) void {
        tools.setSkillRegistry(if (self.skill_registry) |*reg| reg else null);
        tools.setScheduler(if (self.scheduler) |*s| s else null);
        tools.setStorage(if (self.storage) |*s| s else null);
        tools.setRag(if (self.rag) |*r| r else null);
    }

    /// Start a new conversation (creates ID for SQLite persistence).
    pub fn startConversation(self: *AgentLoop) void {
        if (self.storage) |*s| {
            self.conversation_id = s.createConversation("repl", null, null, self.config.model) catch null;
            self.message_sequence = 0;
        }
    }

    /// Tick the scheduler — called from REPL loop to execute due jobs.
    pub fn tickScheduler(self: *AgentLoop) ?[]u8 {
        if (self.scheduler) |*sched| {
            return sched.tick(self.alloc) catch null;
        }
        return null;
    }

    /// Archive current conversation and reset history.
    pub fn archiveAndReset(self: *AgentLoop) void {
        self.history.deinit();
        self.history = history_mod.History.init(self.alloc);
        self.startConversation();
        self.message_sequence = 0;
    }

    /// Process a user input message through the agentic loop.
    pub fn processInput(self: *AgentLoop, user_text: []const u8) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Re-bind tools-module globals to THIS agent (pool/subagents share them)
        self.bindTools();

        // Add user message to history
        try self.history.addUserMessage(user_text);

        // Persist user message
        if (self.storage) |*s| {
            if (self.conversation_id) |conv_id| {
                s.saveMessage(conv_id, "user", self.message_sequence, &.{.{ .text = user_text }}) catch {};
                self.message_sequence += 1;
            }
        }

        // RAG: index user message (fire-and-forget, never blocks)
        if (self.rag) |*rag| {
            if (self.conversation_id) |conv_id| {
                const ts = std.time.timestamp();
                rag.indexMessage(conv_id, "user", self.message_sequence -| 1, user_text, "repl", ts) catch {};
            }
        }

        self.last_message_ts = std.time.milliTimestamp();
        self.tool_errors_this_turn = 0;

        // Wire subagent manager into tools module for spawn_agent tool
        if (self.subagent_manager) |mgr_opaque| {
            const subagent_mod = @import("subagent.zig");
            const mgr: *subagent_mod.SubagentManager = @ptrCast(@alignCast(mgr_opaque));
            tools.setSubagentManager(mgr, self.depth);
        }
        defer tools.setSubagentManager(null, 0);

        // Get relevant tool definitions based on user message
        const relevant_tools = tools.getRelevantDefinitions(user_text);

        var iteration: usize = 0;
        while (iteration < MAX_ITERATIONS) : (iteration += 1) {
            // Fire voice start callback on first iteration
            if (iteration == 0) {
                if (self.voice_start_callback) |cb| cb();
            }

            // Send to backend (streaming)
            const text_cb: ?sse.TextCallback = if (self.stream_callback) |cb| cb else if (self.capture_buf != null) &captureText else &printText;

            var response = self.sendToBackend(
                self.system_prompt,
                self.history.getMessages(),
                text_cb,
                relevant_tools,
            ) catch |e| {
                if (e == error.ContextOverflow) {
                    try stderr.writeAll("\n[Context pressure] Compacting history...\n");
                    self.history.emergencyCompact();
                    var retry_resp = self.sendToBackend(
                        self.system_prompt,
                        self.history.getMessages(),
                        text_cb,
                        relevant_tools,
                    ) catch |e2| {
                        try stderr.print("\n[Error] Retry failed: {s}\n", .{@errorName(e2)});
                        return;
                    };
                    defer retry_resp.deinit();
                    try stdout.writeByte('\n');
                    try self.history.addAssistantResponse(&retry_resp);
                    self.history.evictImages();
                    if (self.storage) |*s| {
                        if (self.conversation_id) |conv_id| {
                            s.saveMessage(conv_id, "assistant", self.message_sequence, retry_resp.content.items) catch {};
                            self.message_sequence += 1;
                        }
                    }
                    switch (retry_resp.stop_reason) {
                        .end_turn, .max_tokens, .stop_sequence => return,
                        .tool_use => {
                            try self.executeTools(&retry_resp, stdout);
                            continue;
                        },
                        .unknown => return,
                    }
                }
                try stderr.print("\n[Error] API call failed: {s}\n", .{@errorName(e)});
                return;
            };
            defer response.deinit();

            try stdout.writeByte('\n');

            // Add assistant response to history
            try self.history.addAssistantResponse(&response);

            // Evict base64 images from history — Claude has seen them,
            // no need to resend ~300KB per image on every subsequent turn.
            self.history.evictImages();

            // Persist
            if (self.storage) |*s| {
                if (self.conversation_id) |conv_id| {
                    s.saveMessage(conv_id, "assistant", self.message_sequence, response.content.items) catch {};
                    self.message_sequence += 1;
                }
            }

            // RAG: index assistant response (fire-and-forget)
            if (self.rag) |*rag| {
                if (self.conversation_id) |conv_id| {
                    for (response.content.items) |rblock| {
                        switch (rblock) {
                            .text => |text| {
                                if (text.len > 0) {
                                    const ts = std.time.timestamp();
                                    rag.indexMessage(conv_id, "assistant", self.message_sequence -| 1, text, "repl", ts) catch {};
                                }
                            },
                            else => {},
                        }
                    }
                }
            }

            // Check stop reason
            switch (response.stop_reason) {
                .end_turn, .max_tokens, .stop_sequence => {
                    // Done — notify voice callback. TTS is a secondary egress
                    // that re-reads response.content directly (not text_cb), so
                    // it must be redacted independently: speaking a key leaks it
                    // just as printing it does. (port of Wintermute leak-guard)
                    if (self.voice_callback) |cb| {
                        for (response.content.items) |block| {
                            switch (block) {
                                .text => |text| {
                                    if (text.len > 0) {
                                        if (redactOneShot(self.alloc, self.config, text)) |red| {
                                            defer self.alloc.free(red);
                                            if (red.len > 0) cb(red);
                                        } // null (OOM) = drop, never speak raw
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                    return;
                },
                .tool_use => {
                    try self.executeTools(&response, stdout);
                },
                .unknown => {
                    try stderr.writeAll("[Warning] Unknown stop reason from API\n");
                    return;
                },
            }
        }

        try stderr.print("[Warning] Hit max iterations ({d})\n", .{MAX_ITERATIONS});
    }

    /// Process input with web UI context (message ID for events).
    pub fn processInputWeb(self: *AgentLoop, user_text: []const u8, message_id: []const u8) !void {
        self.web_message_id = message_id;
        defer self.web_message_id = null;
        try self.processInput(user_text);
    }

    /// Process input capturing output to buffer (for chat bridge).
    pub fn processInputCapture(self: *AgentLoop, user_text: []const u8, buf: *ArrayList(u8)) !void {
        self.capture_buf = buf;
        defer self.capture_buf = null;
        try self.processInput(user_text);
    }

    /// Send a message via the active backend (Claude, Ollama, or OpenAI-compatible).
    pub fn sendToBackend(
        self: *AgentLoop,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        text_cb: ?sse.TextCallback,
        tool_defs: []const protocol.ToolDefinition,
    ) !protocol.Response {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // --- Output leak guard: arm a per-reply redactor over text_cb -------
        // Secret set is rebuilt per reply from self.config, so /model and any
        // future key updates take effect on the next reply. Layer 2 (prompt
        // overlap) is passed null: wintermolt is local-first by design (no
        // cloud/exposed mode concept in Config), so only Layer 1 (exact secret
        // values + key-shape patterns) is armed. (port of Wintermute leak-guard)
        var secret_buf: [8]redact.NamedSecret = undefined;
        const secrets = buildSecretSet(self.config, &secret_buf);

        const effective_cb: ?sse.TextCallback = blk: {
            if (text_cb == null) break :blk null;
            g_redactor = redact.Redactor.init(self.alloc, secrets, null) catch null;
            if (g_redactor == null) break :blk text_cb; // init failed: pass through unwrapped
            g_inner_cb = text_cb;
            break :blk &redactingText;
        };
        // Flush exactly once on success, abort on every error path. `succeeded`
        // is flipped true only when a backend returns a Response.
        var succeeded = false;
        defer {
            if (g_redactor) |*r| {
                if (succeeded) {
                    const tail = r.flush() catch "";
                    if (tail.len > 0) if (g_inner_cb) |cb| cb(tail);
                } else {
                    r.abort();
                }
                r.deinit();
                g_redactor = null;
                g_inner_cb = null;
            }
        }

        // Try primary backend first
        const primary_result = switch (self.backend) {
            .claude => |*c| c.sendMessage(system_prompt, messages, tool_defs, effective_cb),
            .ollama => |*o| o.sendMessage(system_prompt, messages, tool_defs, effective_cb),
            .openai => |*o| o.sendMessage(system_prompt, messages, tool_defs, effective_cb),
            .kernel => |*k| k.sendMessage(system_prompt, messages, tool_defs, effective_cb),
            .forai => |*f| f.sendMessage(system_prompt, messages, tool_defs, effective_cb),
        };

        if (primary_result) |resp| {
            succeeded = true;
            return resp;
        } else |primary_err| {
            if (primary_err == error.ContextOverflow) return primary_err;

            const backend_name: []const u8 = switch (self.backend) {
                .claude => "Claude",
                .ollama => "Ollama",
                .openai => "OpenAI",
                .kernel => "Kernel",
                .forai => "forAI",
            };
            stderr.print("\n[fallback] {s} failed ({s}), trying alternatives...\n", .{ backend_name, @errorName(primary_err) }) catch {};

            // Fallback: try Ollama (local, free)
            if (self.backend != .ollama) {
                stderr.print("[fallback] Trying Ollama ({s})...\n", .{self.config.ollama_model}) catch {};
                var ollama_client = ollama_mod.OllamaClient.initWithOptions(
                    self.alloc,
                    self.config.ollama_url,
                    self.config.ollama_model,
                    self.config.ollama_num_ctx,
                    self.config.ollama_keep_alive,
                );
                if (ollama_client.sendMessage(system_prompt, messages, tool_defs, effective_cb)) |resp| {
                    stderr.writeAll("[fallback] Ollama succeeded\n") catch {};
                    succeeded = true;
                    return resp;
                } else |_| {
                    stderr.writeAll("[fallback] Ollama failed\n") catch {};
                }
            }

            // Fallback: try OpenAI (if key available)
            if (self.backend != .openai) {
                if (self.config.openai_api_key) |api_key| {
                    stderr.writeAll("[fallback] Trying OpenAI...\n") catch {};
                    var openai_client = deepseek_mod.DeepSeekClient.init(
                        self.alloc,
                        api_key,
                        self.config.openai_model,
                    );
                    openai_client.api_url = "https://api.openai.com/v1/chat/completions";
                    if (openai_client.sendMessage(system_prompt, messages, tool_defs, effective_cb)) |resp| {
                        stderr.writeAll("[fallback] OpenAI succeeded\n") catch {};
                        succeeded = true;
                        return resp;
                    } else |_| {
                        stderr.writeAll("[fallback] OpenAI failed\n") catch {};
                    }
                }
            }

            stderr.writeAll("[fallback] All backends failed\n") catch {};
            return primary_err;
        }
    }

    /// Switch backend at runtime (/model command).
    pub fn switchBackend(self: *AgentLoop, backend_name: []const u8, model_name_arg: ?[]const u8) void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        // Own the model name — callers pass a slice into a reused input
        // buffer (REPL line_buf), which the next read would overwrite,
        // leaving the backend with a garbage model string.
        const model_name: ?[]const u8 = if (model_name_arg) |m|
            (self.alloc.dupe(u8, m) catch null)
        else
            null;
        // Free previous backend if it owns heap state (kernel loads ~GBs of weights).
        switch (self.backend) {
            .kernel => |*k| k.deinit(),
            .forai => |*f| f.deinit(),
            else => {},
        }
        if (std.mem.eql(u8, backend_name, "ollama")) {
            self.backend = .{ .ollama = ollama_mod.OllamaClient.initWithOptions(
                self.alloc,
                self.config.ollama_url,
                model_name orelse self.config.ollama_model,
                self.config.ollama_num_ctx,
                self.config.ollama_keep_alive,
            ) };
            stderr.writeAll("[backend] Switched to Ollama\n") catch {};
        } else if (std.mem.eql(u8, backend_name, "openai")) {
            const api_key = self.config.openai_api_key orelse {
                stderr.writeAll("[backend] OPENAI_API_KEY not set. Free local instead: /model ollama (default, no key)\n") catch {};
                return;
            };
            var client = deepseek_mod.DeepSeekClient.init(
                self.alloc,
                api_key,
                model_name orelse self.config.openai_model,
            );
            client.api_url = "https://api.openai.com/v1/chat/completions";
            self.backend = .{ .openai = client };
            stderr.print("[backend] Switched to OpenAI ({s})\n", .{model_name orelse self.config.openai_model}) catch {};
        } else if (std.mem.eql(u8, backend_name, "deepseek")) {
            const api_key = self.config.deepseek_cloud_key orelse {
                stderr.writeAll("[backend] DEEPSEEK_API_KEY not set. Free local instead: /model ollama (default, no key)\n") catch {};
                return;
            };
            self.backend = .{ .openai = deepseek_mod.DeepSeekClient.init(
                self.alloc,
                api_key,
                model_name orelse "deepseek-chat",
            ) };
            stderr.print("[backend] Switched to DeepSeek Cloud ({s})\n", .{model_name orelse "deepseek-chat"}) catch {};
        } else if (std.mem.eql(u8, backend_name, "qwen")) {
            const api_key = self.config.qwen_api_key orelse {
                // Common trap: "qwen" here is the Qwen Cloud API. The free
                // local qwen3 models run via Ollama/kernel with no key.
                stderr.writeAll("[backend] QWEN_API_KEY not set (qwen = Qwen Cloud API). The FREE local qwen3 needs no key: /model ollama qwen3:0.6b (default) or /model kernel qwen3:0.6b\n") catch {};
                return;
            };
            var client = deepseek_mod.DeepSeekClient.init(
                self.alloc,
                api_key,
                model_name orelse self.config.qwen_model,
            );
            client.api_url = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";
            self.backend = .{ .openai = client };
            stderr.print("[backend] Switched to Qwen Cloud ({s})\n", .{model_name orelse self.config.qwen_model}) catch {};
        } else if (std.mem.eql(u8, backend_name, "gemini")) {
            const api_key = self.config.gemini_api_key orelse {
                stderr.writeAll("[backend] GOOGLE_GEMINI_API_KEY not set. Free local instead: /model ollama (default, no key)\n") catch {};
                return;
            };
            var client = deepseek_mod.DeepSeekClient.init(
                self.alloc,
                api_key,
                model_name orelse self.config.gemini_model,
            );
            client.api_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
            self.backend = .{ .openai = client };
            stderr.print("[backend] Switched to Gemini ({s})\n", .{model_name orelse self.config.gemini_model}) catch {};
        } else if (std.mem.eql(u8, backend_name, "forai")) {
            // In-process forAI engine (forMetal on macOS, forCUDA on
            // Linux/Windows) — no external model loader. The old
            // OpenAI-compatible HTTP mode lives on via /model openai with
            // a custom URL.
            if (!forai_mod.is_supported) {
                stderr.writeAll("[backend] forAI engine not delivered yet (forAI rebuild in flight) — use /model kernel for local inference meanwhile\n") catch {};
                return;
            }
            const default_alias = compat.getenv("WINTERMOLT_FORAI_DEFAULT") orelse "qwen3:0.6b";
            const alias = model_name orelse default_alias;
            const model_dir = forai_mod.defaultModelDir(self.alloc) catch {
                stderr.writeAll("[backend] could not resolve WINTERMOLT_KERNEL_MODEL_DIR or $HOME\n") catch {};
                return;
            };
            const path = forai_mod.resolveModelPath(self.alloc, alias, model_dir) catch |err| {
                stderr.print("[backend] forai: could not resolve {s} ({s})\n", .{ alias, @errorName(err) }) catch {};
                return;
            };
            self.backend = .{ .forai = forai_mod.ForAIClient.init(self.alloc, path, alias) };
            stderr.print("[backend] Switched to forAI in-process ({s})\n", .{alias}) catch {};
        } else if (std.mem.eql(u8, backend_name, "kernel")) {
            if (!kernel_mod.is_supported) {
                stderr.writeAll("[backend] kernel backend is darwin-arm64 only on this build\n") catch {};
                return;
            }
            const default_alias = std.posix.getenv("WINTERMOLT_KERNEL_DEFAULT") orelse "qwen3:0.6b";
            const alias = model_name orelse default_alias;
            const model_dir = kernel_mod.defaultModelDir(self.alloc) catch {
                stderr.writeAll("[backend] could not resolve WINTERMOLT_KERNEL_MODEL_DIR or $HOME\n") catch {};
                return;
            };
            const gguf_path = kernel_mod.resolveModelPath(self.alloc, alias, model_dir) catch |err| {
                stderr.print("[backend] kernel: could not resolve {s} ({s})\n", .{ alias, @errorName(err) }) catch {};
                return;
            };
            self.backend = .{ .kernel = kernel_mod.KernelClient.init(self.alloc, gguf_path, alias) };
            stderr.print("[backend] Switched to kernel ({s} via Metal — {s})\n", .{ alias, gguf_path }) catch {};
        } else if (std.mem.eql(u8, backend_name, "claude")) {
            if (self.config.api_key.len == 0) {
                stderr.writeAll("[backend] ANTHROPIC_API_KEY not set. Use /keys to configure, or stay free/local: /model ollama (default, no key)\n") catch {};
                return;
            }
            self.backend = .{ .claude = client_mod.Client.init(
                self.alloc,
                self.config.api_key,
                model_name orelse "claude-sonnet-4-20250514",
            ) };
            stderr.print("[backend] Switched to Claude ({s})\n", .{model_name orelse "claude-sonnet-4-20250514"}) catch {};
        } else {
            stderr.print("[backend] Unknown: {s}. Free local (no key): ollama (default), kernel, forai · Cloud (API key): claude, openai, deepseek, qwen, gemini\n", .{backend_name}) catch {};
        }
    }

    /// Get current backend name and model.
    pub fn getBackendInfo(self: *const AgentLoop) struct { name: []const u8, model: []const u8 } {
        return switch (self.backend) {
            .claude => |c| .{ .name = "claude", .model = c.model },
            .ollama => |o| .{ .name = "ollama", .model = o.model },
            .openai => |o| .{ .name = "openai", .model = o.model },
            .kernel => |k| .{ .name = "kernel", .model = k.model_alias },
            .forai => |f| .{ .name = "forai", .model = f.model_alias },
        };
    }

    /// Execute tool calls from the API response.
    pub fn executeTools(self: *AgentLoop, response: *const protocol.Response, stdout: anytype) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        var results: std.ArrayList(protocol.ToolResult) = .{};
        defer results.deinit(self.alloc);

        // Count tool_use blocks for adaptive truncation
        var tool_count: usize = 0;
        for (response.content.items) |block| {
            switch (block) {
                .tool_use => tool_count += 1,
                else => {},
            }
        }
        const remaining = if (self.history.max_tokens > self.history.approx_tokens)
            self.history.max_tokens - self.history.approx_tokens
        else
            10_000;
        const per_tool_budget = if (tool_count > 0)
            @min(@as(usize, 30_000), @max(@as(usize, 2_000), remaining * 3 / tool_count))
        else
            @as(usize, 30_000);

        for (response.content.items) |block| {
            switch (block) {
                .tool_use => |tu| {
                    try stdout.print("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});

                    // Notify web bridge of tool start
                    if (self.tool_start_callback) |cb| cb(tu.name, tu.id);

                    // Execute the tool
                    const result = tools.executeTool(self.alloc, tu.name, tu.input_json) catch |e| {
                        const err_msg = try std.fmt.allocPrint(self.alloc, "Tool execution error: {s}", .{@errorName(e)});
                        try results.append(self.alloc, .{
                            .tool_use_id = tu.id,
                            .content = err_msg,
                            .is_error = true,
                        });
                        self.tool_errors_this_turn += 1;
                        if (self.tool_done_callback) |cb| cb(tu.id, false);
                        try stderr.print("\x1b[31m[error]\x1b[0m\n", .{});
                        continue;
                    };

                    // Check for image result (camera_capture returns base64 images)
                    if (std.mem.startsWith(u8, result, camera_tool.IMAGE_RESULT_PREFIX)) {
                        const payload = result[camera_tool.IMAGE_RESULT_PREFIX.len..];
                        if (std.mem.indexOfScalar(u8, payload, ':')) |sep| {
                            const media_type = payload[0..sep];
                            const b64_data = payload[sep + 1 ..];

                            var img_blocks = try self.alloc.alloc(protocol.ContentBlock, 2);
                            img_blocks[0] = .{ .text = try self.alloc.dupe(u8, "Camera capture (saved to /tmp/wintermolt_capture.jpg):") };
                            img_blocks[1] = .{ .image = .{
                                .media_type = try self.alloc.dupe(u8, media_type),
                                .data = try self.alloc.dupe(u8, b64_data),
                            } };

                            try results.append(self.alloc, .{
                                .tool_use_id = tu.id,
                                .content = "Image captured and saved to /tmp/wintermolt_capture.jpg.",
                                .is_error = false,
                                .content_blocks = img_blocks,
                            });

                            self.alloc.free(result);
                            if (self.tool_done_callback) |cb| cb(tu.id, true);
                            try stdout.print("\x1b[32m[captured]\x1b[0m\n", .{});
                            continue;
                        }
                    }

                    // Truncate result if needed
                    const truncated = if (result.len > per_tool_budget)
                        result[0..per_tool_budget]
                    else
                        result;

                    try results.append(self.alloc, .{
                        .tool_use_id = tu.id,
                        .content = truncated,
                        .is_error = false,
                    });

                    if (self.tool_done_callback) |cb| cb(tu.id, true);
                    try stdout.print("\x1b[32m[ok]\x1b[0m\n", .{});
                },
                else => {},
            }
        }

        // Add tool results to history
        if (results.items.len > 0) {
            try self.history.addToolResults(results.items);
        }
    }

    // -----------------------------------------------------------------------
    // Text output callbacks
    // -----------------------------------------------------------------------

    fn printText(text: []const u8) void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        stdout.writeAll(text) catch {};
    }

    // --- Output leak guard (redact.zig) ------------------------------------
    // TextCallback carries no userdata, so the per-reply redactor and inner
    // callback live at module scope (same pattern as captureText's buffer).
    // Replies are sequential per process; one in-flight redactor suffices.
    fn redactingText(text: []const u8) void {
        if (g_redactor) |*r| {
            const safe = r.feed(text) catch return; // OOM: hold (never emit unscanned)
            if (g_inner_cb) |cb| if (safe.len > 0) cb(safe);
        } else if (g_inner_cb) |cb| cb(text);
    }

    /// Build the armed secret set from config into `buf`, returning the filled
    /// slice. Shared by the streaming choke (sendToBackend) and the one-shot
    /// helper below so the key fields stay in one place. Layer 2 (prompt
    /// overlap) is never armed: wintermolt is local-first (no cloud mode).
    fn buildSecretSet(cfg: *const config_mod.Config, buf: *[8]redact.NamedSecret) []const redact.NamedSecret {
        var n: usize = 0;
        if (cfg.api_key.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "ANTHROPIC_API_KEY", .value = cfg.api_key };
            n += 1;
        }
        if (cfg.openai_api_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "OPENAI_API_KEY", .value = v };
            n += 1;
        };
        if (cfg.deepseek_cloud_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "DEEPSEEK_API_KEY", .value = v };
            n += 1;
        };
        if (cfg.qwen_api_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "QWEN_API_KEY", .value = v };
            n += 1;
        };
        if (cfg.gemini_api_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "GOOGLE_GEMINI_API_KEY", .value = v };
            n += 1;
        };
        if (cfg.pinecone_api_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "PINECONE_API_KEY", .value = v };
            n += 1;
        };
        if (cfg.tailscale_api_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "TAILSCALE_API_KEY", .value = v };
            n += 1;
        };
        if (cfg.elevenlabs_api_key) |v| if (v.len >= redact.MIN_SECRET_LEN) {
            buf[n] = .{ .name = "ELEVENLABS_API_KEY", .value = v };
            n += 1;
        };
        return buf[0..n];
    }

    /// One-shot redaction of a complete text block (non-streaming secondary
    /// egress: voice/TTS). Returns redacted bytes owned by `alloc` (caller
    /// frees), or null on OOM — callers must treat null as "drop/skip", never
    /// as "emit raw". Same Layer-1 discipline as the streaming choke.
    fn redactOneShot(alloc: Allocator, cfg: *const config_mod.Config, text: []const u8) ?[]u8 {
        var secret_buf: [8]redact.NamedSecret = undefined;
        const secrets = buildSecretSet(cfg, &secret_buf);
        var r = redact.Redactor.init(alloc, secrets, null) catch return null;
        defer r.deinit();
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(alloc);
        const safe = r.feed(text) catch return null;
        out.appendSlice(alloc, safe) catch return null;
        const tail = r.flush() catch return null;
        out.appendSlice(alloc, tail) catch return null;
        return out.toOwnedSlice(alloc) catch null;
    }

    fn captureText(text: []const u8) void {
        // This is a placeholder — capture_buf is used via stream_callback
        _ = text;
    }
};
