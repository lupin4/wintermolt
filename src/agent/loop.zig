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
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

// Core imports (self-contained, no proprietary deps)
const client_mod = @import("../api/client.zig");
const protocol = @import("../api/protocol.zig");
const sse = @import("../api/sse.zig");
const ollama_mod = @import("../api/ollama.zig");
const deepseek_mod = @import("../api/deepseek.zig");
const history_mod = @import("history.zig");
const tools = @import("tools.zig");
const config_mod = @import("config.zig");
const storage_mod = @import("storage.zig");
const rag_mod = @import("rag.zig");
const skill_loader = @import("skill_loader.zig");
const scheduler_mod = @import("scheduler.zig");
const camera_tool = @import("../tools/camera.zig");

const MAX_ITERATIONS = 25;

pub const Backend = union(enum) {
    claude: client_mod.Client,
    ollama: ollama_mod.OllamaClient,
    openai: deepseek_mod.DeepSeekClient,
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

        if (skill_registry) |*reg| {
            tools.setSkillRegistry(reg);
        }

        // Initialize scheduler (SQLite-persisted cron jobs)
        var scheduler: ?scheduler_mod.Scheduler = null;
        scheduler = scheduler_mod.Scheduler.init(alloc) catch |e| blk: {
            stderr.print("[scheduler] Init failed: {s}\n", .{@errorName(e)}) catch {};
            break :blk null;
        };
        if (scheduler) |*s| tools.setScheduler(s);

        // Share storage and RAG with tools module for memory_search tool
        if (storage) |*s| tools.setStorage(s);
        if (rag) |*r| tools.setRag(r);

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
        if (self.scheduler) |*s| s.deinit();
        if (self.storage) |*s| s.deinit();
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
                    // Done — notify voice callback
                    if (self.voice_callback) |cb| {
                        for (response.content.items) |block| {
                            switch (block) {
                                .text => |text| {
                                    if (text.len > 0) cb(text);
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

        // Try primary backend first
        const primary_result = switch (self.backend) {
            .claude => |*c| c.sendMessage(system_prompt, messages, tool_defs, text_cb),
            .ollama => |*o| o.sendMessage(system_prompt, messages, tool_defs, text_cb),
            .openai => |*o| o.sendMessage(system_prompt, messages, tool_defs, text_cb),
        };

        if (primary_result) |resp| {
            return resp;
        } else |primary_err| {
            if (primary_err == error.ContextOverflow) return primary_err;

            const backend_name: []const u8 = switch (self.backend) {
                .claude => "Claude",
                .ollama => "Ollama",
                .openai => "OpenAI",
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
                if (ollama_client.sendMessage(system_prompt, messages, tool_defs, text_cb)) |resp| {
                    stderr.writeAll("[fallback] Ollama succeeded\n") catch {};
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
                    if (openai_client.sendMessage(system_prompt, messages, tool_defs, text_cb)) |resp| {
                        stderr.writeAll("[fallback] OpenAI succeeded\n") catch {};
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
    pub fn switchBackend(self: *AgentLoop, backend_name: []const u8, model_name: ?[]const u8) void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
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
                stderr.writeAll("[backend] OPENAI_API_KEY not set\n") catch {};
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
                stderr.writeAll("[backend] DEEPSEEK_API_KEY not set\n") catch {};
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
                stderr.writeAll("[backend] QWEN_API_KEY not set\n") catch {};
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
                stderr.writeAll("[backend] GOOGLE_GEMINI_API_KEY not set\n") catch {};
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
            const forai_url = std.posix.getenv("WINTERMOLT_FORAI_URL") orelse "http://localhost:8000";
            const forai_model = model_name orelse std.posix.getenv("WINTERMOLT_FORAI_MODEL") orelse "qwen3:8b";
            var client = deepseek_mod.DeepSeekClient.init(
                self.alloc,
                "",
                forai_model,
            );
            client.api_url = std.fmt.allocPrint(self.alloc, "{s}/v1/chat/completions", .{forai_url}) catch "http://localhost:8000/v1/chat/completions";
            self.backend = .{ .openai = client };
            stderr.print("[backend] Switched to forAI ({s} at {s})\n", .{ forai_model, forai_url }) catch {};
        } else if (std.mem.eql(u8, backend_name, "claude")) {
            if (self.config.api_key.len == 0) {
                stderr.writeAll("[backend] ANTHROPIC_API_KEY not set. Use /keys to configure.\n") catch {};
                return;
            }
            self.backend = .{ .claude = client_mod.Client.init(
                self.alloc,
                self.config.api_key,
                model_name orelse "claude-sonnet-4-20250514",
            ) };
            stderr.print("[backend] Switched to Claude ({s})\n", .{model_name orelse "claude-sonnet-4-20250514"}) catch {};
        } else {
            stderr.print("[backend] Unknown: {s}. Options: ollama, forai, claude, openai, deepseek, qwen, gemini\n", .{backend_name}) catch {};
        }
    }

    /// Get current backend name and model.
    pub fn getBackendInfo(self: *const AgentLoop) struct { name: []const u8, model: []const u8 } {
        return switch (self.backend) {
            .claude => |c| .{ .name = "claude", .model = c.model },
            .ollama => |o| .{ .name = "ollama", .model = o.model },
            .openai => |o| .{ .name = "openai", .model = o.model },
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

    fn captureText(text: []const u8) void {
        // This is a placeholder — capture_buf is used via stream_callback
        _ = text;
    }
};
