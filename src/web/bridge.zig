// Copyright The Fantastic Planet - By David Clabaugh
//
// bridge.zig — Web sidecar IPC bridge
//
// Spawns the wintermolt-web TypeScript sidecar process and communicates
// via JSON lines over stdin/stdout pipes. Similar to chat/bridge.zig but
// adds streaming support — each text_delta token is written as a JSON line
// so the browser can render responses in real-time.
//
// Data flow:
//   Browser <─WebSocket─> wintermolt-web (TypeScript) <─JSON lines─> this bridge
//
// Protocol:
//   <- FROM WEB (browser messages):
//      {"type":"message","id":"m1","text":"hello","images":[...]}
//      {"type":"command","command":"/tier auto"}
//
//   -> TO WEB (streaming tokens + events):
//      {"type":"token","id":"m1","text":"Hello","done":false}
//      {"type":"tool_start","id":"m1","tool":"bash","tool_id":"t1","preview":"ls"}
//      {"type":"tool_done","id":"m1","tool_id":"t1","ok":true,"preview":"..."}
//      {"type":"status","tier":"sonnet","model":"claude-sonnet-4-5","backend":"claude"}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const sse = @import("../api/sse.zig");
const loop_mod = @import("../agent/loop.zig");
const protocol = @import("../api/protocol.zig");

/// State shared with streaming callbacks via threadlocal (Zig has no closures).
threadlocal var active_bridge_stdin: ?std.fs.File = null;
threadlocal var active_message_id: ?[]const u8 = null;
threadlocal var active_bridge_alloc: ?Allocator = null;

pub const WebBridge = struct {
    alloc: Allocator,
    child: Child,
    stdout_file: std.fs.File,
    stdin_file: std.fs.File,
    web_argv: []const []const u8,
    // 4MB line buffer (heap-allocated) — large enough for audio base64
    line_buf: []u8,
    agent: *loop_mod.AgentLoop,
    // Per-user RAG namespace — allocated once per unique session_id
    web_rag_namespace: ?[]const u8 = null,

    /// Spawn the web sidecar process.
    /// Looks for wintermolt-web server in order:
    ///   1. WINTERMOLT_WEB_BINARY env var
    ///   2. ./web/dist/server.js (production build)
    ///   3. npx tsx web/server/index.ts (dev mode)
    pub fn init(alloc: Allocator, agent: *loop_mod.AgentLoop) !WebBridge {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        const web_path = getWebPath();
        const web_args = try allocWebArgs(alloc, web_path);
        errdefer alloc.free(web_args);

        // 4MB buffer for IPC lines — audio base64 can be 100KB-2MB
        const buf = try alloc.alloc(u8, 4 * 1024 * 1024);
        errdefer alloc.free(buf);

        try stderr.print("[web] Starting sidecar: {s} {s}\n", .{ web_path.binary, web_path.server_path });

        var child = Child.init(web_args, alloc);
        child.stdout_behavior = .Pipe;
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        return .{
            .alloc = alloc,
            .child = child,
            .stdout_file = child.stdout.?,
            .stdin_file = child.stdin.?,
            .web_argv = web_args,
            .line_buf = buf,
            .agent = agent,
        };
    }

    pub fn deinit(self: *WebBridge) void {
        _ = self.child.kill() catch {};
        if (self.web_rag_namespace) |ns| self.alloc.free(@constCast(ns));
        self.alloc.free(self.line_buf);
        self.alloc.free(self.web_argv);
    }

    /// Main run loop — read IPC messages from sidecar, dispatch to agent.
    pub fn run(self: *WebBridge) void {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Send initial status
        self.sendStatus() catch {};

        const reader = self.stdout_file.deprecatedReader();
        while (true) {
            const line = reader.readUntilDelimiter(self.line_buf, '\n') catch |e| {
                if (e == error.EndOfStream) break;
                stderr.print("[web] Read error: {s}\n", .{@errorName(e)}) catch {};
                break;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            self.handleLine(trimmed) catch |e| {
                stderr.print("[web] Handle error: {s}\n", .{@errorName(e)}) catch {};
            };
        }

        stderr.writeAll("[web] Sidecar exited\n") catch {};
    }

    fn handleLine(self: *WebBridge, line: []const u8) !void {
        // Parse JSON to determine message type
        const msg_type = extractType(line) orelse return;

        if (std.mem.eql(u8, msg_type, "message")) {
            try self.handleMessage(line);
        } else if (std.mem.eql(u8, msg_type, "listen")) {
            try self.handleListen(line);
        } else if (std.mem.eql(u8, msg_type, "command")) {
            try self.handleCommand(line);
        } else if (std.mem.eql(u8, msg_type, "history_list")) {
            try self.handleHistoryList();
        } else if (std.mem.eql(u8, msg_type, "history_resume")) {
            try self.handleHistoryResume(line);
        } else if (std.mem.eql(u8, msg_type, "feedback")) {
            self.handleFeedback(line);
        }
    }

    fn handleMessage(self: *WebBridge, line: []const u8) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Extract "id" and "text" from JSON
        const id = extractJsonString(line, "id") orelse return;
        const text = extractJsonString(line, "text") orelse return;

        try stderr.print("[web] Message {s}: {s}\n", .{ id, text });

        // Lazy conversation creation
        if (self.agent.storage != null and self.agent.conversation_id == null) {
            self.agent.startConversation();
        }

        // Set threadlocal state for streaming callback
        active_bridge_stdin = self.stdin_file;
        active_message_id = id;
        active_bridge_alloc = self.alloc;
        defer {
            active_bridge_stdin = null;
            active_message_id = null;
            active_bridge_alloc = null;
        }

        // Wire streaming callback into agent
        self.agent.stream_callback = &webStreamText;
        self.agent.tool_start_callback = &webToolStart;
        self.agent.tool_done_callback = &webToolDone;
        self.agent.perspective_callback = &webPerspective;
        self.agent.voice_callback = &webVoiceAudio;
        self.agent.web_message_id = id;
        defer {
            self.agent.stream_callback = null;
            self.agent.tool_start_callback = null;
            self.agent.tool_done_callback = null;
            self.agent.perspective_callback = null;
            self.agent.voice_callback = null;
            self.agent.web_message_id = null;
        }

        // Extract images if present (for Vision)
        try stderr.print("[web] IPC line length: {d} bytes\n", .{line.len});
        const images = self.parseImages(line);
        if (images) |imgs| {
            try stderr.print("[web] Found {d} image(s) in message — routing to Vision\n", .{imgs.len});
            for (imgs, 0..) |img, i| {
                try stderr.print("[web]   image[{d}]: media_type={s}, data_len={d}\n", .{ i, img.media_type, img.data.len });
            }
        } else {
            // Check if the raw JSON even contains an images field
            if (std.mem.indexOf(u8, line, "\"images\":[") != null) {
                try stderr.print("[web] WARNING: images field found in JSON but parseImages() returned null\n", .{});
                // Log a snippet around the images field for debugging
                if (std.mem.indexOf(u8, line, "\"images\":[")) |idx| {
                    const snippet_end = @min(idx + 100, line.len);
                    try stderr.print("[web]   snippet: {s}\n", .{line[idx..snippet_end]});
                }
            } else {
                try stderr.print("[web] No images in message\n", .{});
            }
        }

        // Add user message to history (with images if present)
        if (images) |imgs| {
            // Build content blocks: image(s) + text
            var msg = protocol.Message{ .role = .user };
            for (imgs) |img| {
                msg.content.append(self.alloc, .{ .image = img }) catch {};
            }
            msg.content.append(self.alloc, .{ .text = self.alloc.dupe(u8, text) catch text }) catch {};
            self.agent.history.messages.append(self.alloc, msg) catch {};
            self.agent.history.approx_tokens += text.len / 3 + imgs.len * 1000; // ~1k tokens per image
        } else {
            self.agent.history.addUserMessage(text) catch {};
        }

        // Persist user message
        if (self.agent.storage) |*s| {
            if (self.agent.conversation_id) |conv_id| {
                const user_block = [_]protocol.ContentBlock{.{ .text = text }};
                s.saveMessage(conv_id, "user", self.agent.message_sequence, &user_block) catch {};
                self.agent.message_sequence += 1;
                if (self.agent.message_sequence == 1) {
                    s.updateTitle(conv_id, text) catch {};
                }
            }
        }

        // Set per-user Pinecone namespace from persistent session_id
        // (stored in browser localStorage, stable across page reloads)
        if (self.agent.rag != null) {
            if (extractJsonString(line, "session_id")) |sid| {
                if (self.web_rag_namespace == null or !std.mem.eql(u8, self.web_rag_namespace.?, sid)) {
                    if (self.web_rag_namespace) |old| self.alloc.free(@constCast(old));
                    self.web_rag_namespace = self.alloc.dupe(u8, sid) catch null;
                }
                if (self.web_rag_namespace) |ns| {
                    self.agent.rag.?.namespace = ns;
                    try stderr.print("[web] RAG namespace set to: {s}\n", .{ns});
                }
            }
        }

        // Parse binary file attachments — decode base64, write to temp files
        // so agent tools (fft_analyze, ml_train, etc.) can access them.
        const file_paths = self.parseAndSaveFiles(line);
        const effective_text = if (file_paths) |fp| blk: {
            // Append temp file paths to agent text so Claude knows where files are
            const combined = std.fmt.allocPrint(self.alloc, "{s}\n\n[Uploaded files saved to temp paths: {s}]", .{ text, fp }) catch text;
            break :blk combined;
        } else text;
        const needs_free = file_paths != null and effective_text.ptr != text.ptr;
        defer if (needs_free) self.alloc.free(@constCast(effective_text));

        // Process through agentic loop — skip addUserMessage (already added above)
        self.agent.processInputWeb(effective_text, id) catch |e| {
            try stderr.print("[web] Agent error: {s}\n", .{@errorName(e)});
            self.sendError(id, @errorName(e)) catch {};
            // Always send done token — even on error — so frontend resets streaming state
            self.sendToken(id, "", true, "end_turn") catch {};
            self.sendStatus() catch {};
            return;
        };

        // Send done token
        stderr.writeAll("[web] Sending done token\n") catch {};
        self.sendToken(id, "", true, "end_turn") catch {};

        // Send status update (tier may have changed)
        self.sendStatus() catch {};
    }

    /// Handle "listen" message — decode base64 audio, transcribe with Whisper, feed to agent.
    fn handleListen(self: *WebBridge, line: []const u8) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const id = extractJsonString(line, "id") orelse return;
        const audio_data = extractJsonString(line, "data") orelse {
            self.sendError(id, "No audio data") catch {};
            return;
        };

        try stderr.print("[web] Listen {s}: {d} bytes audio\n", .{ id, audio_data.len });

        // Check for Whisper API key
        if (std.posix.getenv("OPENAI_API_KEY") == null) {
            self.sendError(id, "Set OPENAI_API_KEY to enable Whisper transcription") catch {};
            return;
        }

        // Decode base64 audio and write to temp file
        const audio_path = "/tmp/wintermolt_web_mic.webm";
        const decoded = decodeBase64(self.alloc, audio_data) catch {
            self.sendError(id, "Failed to decode audio") catch {};
            return;
        };
        defer self.alloc.free(decoded);

        // Write decoded audio to temp file
        const file = std.fs.cwd().createFile(audio_path, .{}) catch {
            self.sendError(id, "Failed to write audio file") catch {};
            return;
        };
        file.writeAll(decoded) catch {
            file.close();
            self.sendError(id, "Failed to write audio data") catch {};
            return;
        };
        file.close();

        try stderr.writeAll("[web] Transcribing with Whisper...\n");

        // Transcribe with Whisper using curl (same as main.zig transcribeWhisper)
        const text = transcribeWhisperWeb(self.alloc, audio_path) orelse {
            self.sendError(id, "Whisper transcription failed") catch {};
            return;
        };
        defer self.alloc.free(text);

        if (text.len == 0) {
            self.sendError(id, "No speech detected") catch {};
            return;
        }

        try stderr.print("[web] Transcribed: {s}\n", .{text});

        // Send transcription back to browser so it shows the user's spoken text
        self.sendTranscription(id, text) catch {};

        // Lazy conversation creation
        if (self.agent.storage != null and self.agent.conversation_id == null) {
            self.agent.startConversation();
        }

        // Set threadlocal state for streaming callback
        active_bridge_stdin = self.stdin_file;
        active_message_id = id;
        active_bridge_alloc = self.alloc;
        defer {
            active_bridge_stdin = null;
            active_message_id = null;
            active_bridge_alloc = null;
        }

        // Wire streaming callback into agent
        self.agent.stream_callback = &webStreamText;
        self.agent.tool_start_callback = &webToolStart;
        self.agent.tool_done_callback = &webToolDone;
        self.agent.perspective_callback = &webPerspective;
        self.agent.voice_callback = &webVoiceAudio;
        self.agent.web_message_id = id;
        defer {
            self.agent.stream_callback = null;
            self.agent.tool_start_callback = null;
            self.agent.tool_done_callback = null;
            self.agent.perspective_callback = null;
            self.agent.voice_callback = null;
            self.agent.web_message_id = null;
        }

        // Set per-user Pinecone namespace (same as handleMessage)
        if (self.agent.rag != null) {
            if (extractJsonString(line, "session_id")) |sid| {
                if (self.web_rag_namespace == null or !std.mem.eql(u8, self.web_rag_namespace.?, sid)) {
                    if (self.web_rag_namespace) |old| self.alloc.free(@constCast(old));
                    self.web_rag_namespace = self.alloc.dupe(u8, sid) catch null;
                }
                if (self.web_rag_namespace) |ns| {
                    self.agent.rag.?.namespace = ns;
                }
            }
        }

        // Feed transcribed text into the agentic loop
        self.agent.processInput(text) catch |e| {
            try stderr.print("[web] Agent error: {s}\n", .{@errorName(e)});
            self.sendError(id, @errorName(e)) catch {};
            // Always send done token — even on error — so frontend resets streaming state
            self.sendToken(id, "", true, "end_turn") catch {};
            self.sendStatus() catch {};
            return;
        };

        // Send done token
        stderr.writeAll("[web] Sending done token\n") catch {};
        self.sendToken(id, "", true, "end_turn") catch {};
        self.sendStatus() catch {};
    }

    fn handleCommand(self: *WebBridge, line: []const u8) !void {
        const command = extractJsonString(line, "command") orelse return;
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("[web] Command: {s}\n", .{command});

        // Dispatch known commands
        var result_buf: [4096]u8 = undefined;
        const result = self.dispatchCommand(command, &result_buf);
        self.sendCommandResult(command, result) catch {};
    }

    fn handleHistoryList(self: *WebBridge) !void {
        // TODO: Query storage and send history list
        _ = self;
    }

    fn handleHistoryResume(self: *WebBridge, line: []const u8) !void {
        _ = self;
        _ = line;
        // TODO: Resume conversation from storage
    }

    /// Handle feedback from web UI (thumbs up/down).
    /// Wintermolt lite: feedback acknowledged but not persisted (no learning subsystem).
    fn handleFeedback(self: *WebBridge, line: []const u8) void {
        _ = self;
        _ = line;
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.writeAll("[web] Feedback received (not stored in lite version)\n") catch {};
    }

    // ---------------------------------------------------------------------------
    // Command dispatch
    // ---------------------------------------------------------------------------

    fn dispatchCommand(self: *WebBridge, command: []const u8, buf: []u8) []const u8 {
        if (std.mem.startsWith(u8, command, "/model")) {
            const arg = std.mem.trim(u8, command[6..], " \t");
            if (arg.len > 0) {
                self.agent.switchBackend(arg, null);
                return std.fmt.bufPrint(buf, "Backend switched to {s}", .{arg}) catch "Switched";
            }
            return "Usage: /model ollama|openai|deepseek|qwen|gemini";
        }

        if (std.mem.eql(u8, command, "/clear") or std.mem.eql(u8, command, "/new")) {
            self.agent.archiveAndReset();
            const history_mod = @import("../agent/history.zig");
            self.agent.history.deinit();
            self.agent.history = history_mod.History.init(self.alloc);
            return if (std.mem.eql(u8, command, "/clear"))
                "Conversation archived and cleared"
            else
                "New conversation started";
        }

        if (std.mem.startsWith(u8, command, "/schedule")) {
            const tools_mod = @import("../agent/tools.zig");
            const sched = tools_mod.getScheduler() orelse return "Scheduler not available";
            const sched_arg = std.mem.trim(u8, command[9..], " \t");
            if (sched_arg.len == 0 or std.mem.eql(u8, sched_arg, "list")) {
                return sched.listJobs(self.alloc) catch "Failed to list jobs";
            }
            return "Usage: /schedule list (other actions via AI prompt)";
        }

        if (std.mem.eql(u8, command, "/help")) {
            return "Commands: /model, /clear, /new, /schedule, /help";
        }

        return "Unknown command. Type /help for available commands";
    }

    // ---------------------------------------------------------------------------
    // JSON output to sidecar (-> browser via WebSocket)
    // ---------------------------------------------------------------------------

    pub fn sendToken(self: *WebBridge, id: []const u8, text: []const u8, done: bool, stop_reason: ?[]const u8) !void {
        var buf: [16384]u8 = undefined;
        const json = if (stop_reason) |sr|
            std.fmt.bufPrint(&buf, "{{\"type\":\"token\",\"id\":\"{s}\",\"text\":\"{s}\",\"done\":{s},\"stop_reason\":\"{s}\"}}\n", .{
                id, escapeJsonString(text), if (done) "true" else "false", sr,
            }) catch return
        else
            std.fmt.bufPrint(&buf, "{{\"type\":\"token\",\"id\":\"{s}\",\"text\":\"{s}\",\"done\":{s}}}\n", .{
                id, escapeJsonString(text), if (done) "true" else "false",
            }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendToolStartMsg(self: *WebBridge, id: []const u8, tool: []const u8, tool_id: []const u8, preview: []const u8) !void {
        var buf: [8192]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"tool_start\",\"id\":\"{s}\",\"tool\":\"{s}\",\"tool_id\":\"{s}\",\"preview\":\"{s}\"}}\n", .{
            id, tool, tool_id, escapeJsonString(preview),
        }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendToolDoneMsg(self: *WebBridge, id: []const u8, tool_id: []const u8, ok: bool, preview: []const u8) !void {
        var buf: [8192]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"tool_done\",\"id\":\"{s}\",\"tool_id\":\"{s}\",\"ok\":{s},\"preview\":\"{s}\"}}\n", .{
            id, tool_id, if (ok) "true" else "false", escapeJsonString(preview),
        }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendStatus(self: *WebBridge) !void {
        var buf: [2048]u8 = undefined;
        const model_label: []const u8 = self.agent.config.model;
        const backend_name: []const u8 = switch (self.agent.backend) {
            .ollama => "ollama",
            .openai => "openai",
        };
        const json = std.fmt.bufPrint(&buf,
            "{{\"type\":\"status\",\"model\":\"{s}\",\"backend\":\"{s}\"}}\n",
            .{ model_label, backend_name },
        ) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendError(self: *WebBridge, id: []const u8, err: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"id\":\"{s}\",\"error\":\"{s}\"}}\n", .{
            id, err,
        }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendTranscription(self: *WebBridge, id: []const u8, text: []const u8) !void {
        var buf: [8192]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"transcription\",\"id\":\"{s}\",\"text\":\"{s}\"}}\n", .{
            id, escapeJsonString(text),
        }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    /// Forward an A2UI canvas message to the web sidecar for browser rendering.
    pub fn sendCanvasMessage(self: *WebBridge, surface_id: []const u8, a2ui_json: []const u8) !void {
        var buf: [32768]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"canvas\",\"surface\":\"{s}\",\"msg\":{s}}}\n", .{
            surface_id, a2ui_json,
        }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    fn sendCommandResult(self: *WebBridge, command: []const u8, result: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"command_result\",\"command\":\"{s}\",\"result\":\"{s}\"}}\n", .{
            command, result,
        }) catch return;
        self.stdin_file.writeAll(json) catch {};
    }

    /// Parse images array from JSON message line.
    /// Expects: "images":[{"media_type":"image/jpeg","data":"base64..."},...]
    /// Returns slice of ImageSource or null if no images.
    fn parseImages(self: *WebBridge, line: []const u8) ?[]protocol.ImageSource {
        // Find "images":[ in the JSON line
        const needle = "\"images\":[";
        const arr_start = std.mem.indexOf(u8, line, needle) orelse return null;
        const start = arr_start + needle.len;

        // Count images by finding {"media_type" patterns
        var count: usize = 0;
        var pos: usize = start;
        while (pos < line.len) {
            if (std.mem.indexOf(u8, line[pos..], "\"media_type\"")) |_| {
                count += 1;
                pos += 12;
                // Skip past this occurrence
                if (std.mem.indexOf(u8, line[pos..], "\"media_type\"")) |next| {
                    pos += next;
                } else break;
            } else break;
        }
        if (count == 0) return null;

        var images = self.alloc.alloc(protocol.ImageSource, count) catch return null;
        var idx: usize = 0;
        pos = start;

        while (idx < count and pos < line.len) {
            // Find next image object
            const obj_start = std.mem.indexOf(u8, line[pos..], "{") orelse break;
            const abs_obj = pos + obj_start;
            const obj_end = std.mem.indexOf(u8, line[abs_obj..], "}") orelse break;
            const obj = line[abs_obj .. abs_obj + obj_end + 1];

            const media_type = extractJsonString(obj, "media_type") orelse {
                pos = abs_obj + obj_end + 1;
                continue;
            };
            const data = extractJsonString(obj, "data") orelse {
                pos = abs_obj + obj_end + 1;
                continue;
            };

            images[idx] = .{
                .media_type = self.alloc.dupe(u8, media_type) catch media_type,
                .data = self.alloc.dupe(u8, data) catch data,
            };
            idx += 1;
            pos = abs_obj + obj_end + 1;
        }

        if (idx == 0) {
            self.alloc.free(images);
            return null;
        }
        return images[0..idx];
    }

    /// Parse "files" array from JSON, decode binary content, write to /tmp.
    /// Returns comma-separated list of temp file paths, or null if no binary files.
    fn parseAndSaveFiles(self: *WebBridge, line: []const u8) ?[]const u8 {
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Quick check: does the JSON even contain a files array?
        const needle = "\"files\":[";
        if (std.mem.indexOf(u8, line, needle) == null) return null;

        // Find binary file objects — look for "is_binary":true
        var paths_buf: [4096]u8 = undefined;
        var paths_len: usize = 0;
        var saved_count: usize = 0;

        // Scan for each file object with is_binary:true
        var search_start: usize = 0;
        while (std.mem.indexOf(u8, line[search_start..], "\"is_binary\":true")) |rel_pos| {
            const abs_pos = search_start + rel_pos;

            // Find the enclosing object bounds (search backwards for { and forward for matching })
            var obj_start: usize = abs_pos;
            var brace_depth: i32 = 0;
            while (obj_start > 0) {
                obj_start -= 1;
                if (line[obj_start] == '{') {
                    brace_depth += 1;
                    if (brace_depth == 1) break;
                } else if (line[obj_start] == '}') {
                    brace_depth -= 1;
                }
            }

            // Find matching closing brace
            var obj_end: usize = abs_pos;
            brace_depth = 0;
            while (obj_end < line.len) {
                if (line[obj_end] == '{') brace_depth += 1;
                if (line[obj_end] == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) break;
                }
                obj_end += 1;
            }

            if (obj_end >= line.len) {
                search_start = abs_pos + 15;
                continue;
            }

            const obj = line[obj_start .. obj_end + 1];

            // Extract filename and content (base64)
            const filename = extractJsonString(obj, "filename") orelse {
                search_start = obj_end + 1;
                continue;
            };
            const content = extractJsonString(obj, "content") orelse {
                search_start = obj_end + 1;
                continue;
            };

            // Sanitize filename — remove path separators
            var safe_name_buf: [256]u8 = undefined;
            var safe_len: usize = 0;
            for (filename) |c| {
                if (c == '/' or c == '\\' or c == ':' or c == '\x00') continue;
                if (safe_len < safe_name_buf.len - 1) {
                    safe_name_buf[safe_len] = c;
                    safe_len += 1;
                }
            }
            if (safe_len == 0) {
                search_start = obj_end + 1;
                continue;
            }
            const safe_name = safe_name_buf[0..safe_len];

            // Build temp path
            var path_buf: [512]u8 = undefined;
            const tmp_path = std.fmt.bufPrint(&path_buf, "/tmp/wintermolt_upload_{s}", .{safe_name}) catch {
                search_start = obj_end + 1;
                continue;
            };

            // Decode base64 and write to file
            const decoded = decodeBase64(self.alloc, content) catch {
                stderr.print("[web] Failed to decode base64 for {s}\n", .{safe_name}) catch {};
                search_start = obj_end + 1;
                continue;
            };
            defer self.alloc.free(decoded);

            const file = std.fs.cwd().createFile(tmp_path, .{}) catch {
                stderr.print("[web] Failed to create temp file: {s}\n", .{tmp_path}) catch {};
                search_start = obj_end + 1;
                continue;
            };
            file.writeAll(decoded) catch {
                file.close();
                search_start = obj_end + 1;
                continue;
            };
            file.close();

            stderr.print("[web] Saved uploaded file: {s} ({d} bytes)\n", .{ tmp_path, decoded.len }) catch {};

            // Append path to result string
            if (saved_count > 0 and paths_len + 2 < paths_buf.len) {
                paths_buf[paths_len] = ',';
                paths_buf[paths_len + 1] = ' ';
                paths_len += 2;
            }
            if (paths_len + tmp_path.len <= paths_buf.len) {
                @memcpy(paths_buf[paths_len .. paths_len + tmp_path.len], tmp_path);
                paths_len += tmp_path.len;
            }
            saved_count += 1;

            search_start = obj_end + 1;
        }

        if (saved_count == 0) return null;

        return self.alloc.dupe(u8, paths_buf[0..paths_len]) catch null;
    }
};

// ---------------------------------------------------------------------------
// Streaming callbacks (threadlocal state — Zig has no closures)
// ---------------------------------------------------------------------------

/// Callback for streaming text output to the web sidecar.
/// Called by the SSE parser for each text_delta.
fn webStreamText(text: []const u8) void {
    const stdin = active_bridge_stdin orelse return;
    const id = active_message_id orelse return;

    var buf: [16384]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"token\",\"id\":\"{s}\",\"text\":\"{s}\",\"done\":false}}\n", .{
        id, escapeJsonString(text),
    }) catch return;

    stdin.writeAll(json) catch {};
}

/// Callback for tool execution start events.
fn webToolStart(tool_name: []const u8, tool_id: []const u8) void {
    const stdin = active_bridge_stdin orelse return;
    const id = active_message_id orelse return;

    var buf: [8192]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"tool_start\",\"id\":\"{s}\",\"tool\":\"{s}\",\"tool_id\":\"{s}\",\"preview\":\"\"}}\n", .{
        id, tool_name, tool_id,
    }) catch return;

    stdin.writeAll(json) catch {};
}

/// Callback for tool execution done events.
fn webToolDone(tool_id: []const u8, ok: bool) void {
    const stdin = active_bridge_stdin orelse return;
    const id = active_message_id orelse return;

    var buf: [8192]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"tool_done\",\"id\":\"{s}\",\"tool_id\":\"{s}\",\"ok\":{s},\"preview\":\"\"}}\n", .{
        id, tool_id, if (ok) "true" else "false",
    }) catch return;

    stdin.writeAll(json) catch {};
}

/// Callback for perspective/phase events (pre-formatted JSON).
fn webPerspective(json: []const u8) void {
    const stdin = active_bridge_stdin orelse return;
    stdin.writeAll(json) catch {};
    stdin.writeAll("\n") catch {};
}

/// Voice callback — sends base64 audio data to the web UI for playback.
fn webVoiceAudio(audio_path: []const u8) void {
    const stdin = active_bridge_stdin orelse return;
    const alloc = active_bridge_alloc orelse return;
    const mid = active_message_id orelse "unknown";

    // Read the audio file and base64-encode it
    const path_z = alloc.dupeZ(u8, audio_path) catch return;
    defer alloc.free(path_z);

    const file = std.fs.openFileAbsolute(path_z, .{}) catch return;
    defer file.close();

    const stat = file.stat() catch return;
    if (stat.size > 10_000_000) return; // Skip files > 10MB

    const audio_data = alloc.alloc(u8, stat.size) catch return;
    defer alloc.free(audio_data);
    _ = file.readAll(audio_data) catch return;

    const b64 = std.base64.standard.Encoder;
    const encoded_len = b64.calcSize(audio_data.len);
    const encoded = alloc.alloc(u8, encoded_len) catch return;
    defer alloc.free(encoded);
    _ = b64.encode(encoded, audio_data);

    // Send as JSON line: {"type":"audio","id":"m1","data":"base64...","format":"mp3"}
    stdin.writeAll("{\"type\":\"audio\",\"id\":\"") catch return;
    stdin.writeAll(mid) catch return;
    stdin.writeAll("\",\"data\":\"") catch return;
    stdin.writeAll(encoded) catch return;
    stdin.writeAll("\",\"format\":\"mp3\"}\n") catch return;
}

// ---------------------------------------------------------------------------
// Path detection
// ---------------------------------------------------------------------------

const WebPath = struct {
    binary: []const u8,
    server_path: []const u8,
};

fn getWebPath() WebPath {
    // 1. Explicit env var (supports "node /path/to/server.js" split on first space)
    if (std.posix.getenv("WINTERMOLT_WEB_BINARY")) |p| {
        if (std.mem.indexOfScalar(u8, p, ' ')) |space_idx| {
            return .{ .binary = p[0..space_idx], .server_path = p[space_idx + 1 ..] };
        }
        return .{ .binary = p, .server_path = p };
    }

    // 2. Production build — check both CWD layouts
    //    (running from repo root: web/dist/server.js)
    //    (running from web/ dir: dist/server.js)
    if (std.fs.cwd().access("web/dist/server.js", .{})) |_| {
        return .{ .binary = "node", .server_path = "web/dist/server.js" };
    } else |_| {}
    if (std.fs.cwd().access("dist/server.js", .{})) |_| {
        return .{ .binary = "node", .server_path = "dist/server.js" };
    } else |_| {}

    // 3. Dev mode — check both layouts
    if (std.fs.cwd().access("web/server/index.ts", .{})) |_| {
        return .{ .binary = "npx", .server_path = "web/server/index.ts" };
    } else |_| {}
    if (std.fs.cwd().access("server/index.ts", .{})) |_| {
        return .{ .binary = "npx", .server_path = "server/index.ts" };
    } else |_| {}

    // 4. Fallback — assume repo root
    return .{ .binary = "npx", .server_path = "web/server/index.ts" };
}

fn allocWebArgs(alloc: Allocator, path: WebPath) ![]const []const u8 {
    if (std.mem.eql(u8, path.binary, "node")) {
        const args = try alloc.alloc([]const u8, 2);
        args[0] = "node";
        args[1] = path.server_path;
        return args;
    }
    if (std.mem.eql(u8, path.binary, "npx")) {
        const args = try alloc.alloc([]const u8, 3);
        args[0] = "npx";
        args[1] = "tsx";
        args[2] = path.server_path;
        return args;
    }
    // Custom binary path
    const args = try alloc.alloc([]const u8, 1);
    args[0] = path.binary;
    return args;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Extract the "type" field from a JSON object (quick scan, no full parse).
fn extractType(json: []const u8) ?[]const u8 {
    return extractJsonString(json, "type");
}

/// Extract a string field from a JSON object (simple scan — finds "key":"value").
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Build needle: "key":" at runtime (can't use comptimePrint with runtime key)
    var needle_buf: [270]u8 = undefined;
    if (key.len + 4 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    needle_buf[3 + key.len] = '"';
    const needle = needle_buf[0 .. 4 + key.len];

    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const value_start = start + needle.len;

    // Find closing quote (handle escaped quotes)
    var i = value_start;
    while (i < json.len) {
        if (json[i] == '"' and (i == 0 or json[i - 1] != '\\')) {
            return json[value_start..i];
        }
        i += 1;
    }
    return null;
}

/// Escape a string for JSON embedding (newlines, quotes, backslashes).
fn escapeJsonString(text: []const u8) []const u8 {
    // Fast path: if no special chars, return as-is
    for (text) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
            return escapeJsonStringSlow(text);
        }
    }
    return text;
}

/// Slow path: escape special JSON characters. Uses a static buffer.
var escape_buf: [32768]u8 = undefined;
fn escapeJsonStringSlow(text: []const u8) []const u8 {
    var i: usize = 0;
    for (text) |c| {
        if (i + 6 >= escape_buf.len) break;
        switch (c) {
            '"' => {
                escape_buf[i] = '\\';
                escape_buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                escape_buf[i] = '\\';
                escape_buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                escape_buf[i] = '\\';
                escape_buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                escape_buf[i] = '\\';
                escape_buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                escape_buf[i] = '\\';
                escape_buf[i + 1] = 't';
                i += 2;
            },
            else => {
                escape_buf[i] = c;
                i += 1;
            },
        }
    }
    return escape_buf[0..i];
}

// ---------------------------------------------------------------------------
// Base64 decoding (standard alphabet)
// ---------------------------------------------------------------------------

const base64_decode_table = blk: {
    var table: [256]u8 = [_]u8{0xFF} ** 256;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

fn decodeBase64(alloc: Allocator, encoded: []const u8) ![]u8 {
    // Strip whitespace and padding, calculate output size
    var clean_len: usize = 0;
    for (encoded) |c| {
        if (base64_decode_table[c] != 0xFF) clean_len += 1;
    }
    if (clean_len == 0) return error.InvalidInput;

    const output_len = (clean_len * 3) / 4;
    const output = try alloc.alloc(u8, output_len);
    errdefer alloc.free(output);

    var accum: u32 = 0;
    var bits: u5 = 0;
    var out_i: usize = 0;

    for (encoded) |c| {
        const val = base64_decode_table[c];
        if (val == 0xFF) continue; // skip padding, whitespace
        accum = (accum << 6) | @as(u32, val);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (out_i < output.len) {
                output[out_i] = @intCast((accum >> bits) & 0xFF);
                out_i += 1;
            }
        }
    }

    return output[0..out_i];
}

// ---------------------------------------------------------------------------
// Whisper transcription (mirrors main.zig transcribeWhisper)
// ---------------------------------------------------------------------------

fn transcribeWhisperWeb(alloc: Allocator, audio_path: []const u8) ?[]u8 {
    const api_key = std.posix.getenv("OPENAI_API_KEY") orelse return null;

    const auth_header = std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{api_key}) catch return null;
    defer alloc.free(auth_header);

    const file_arg = std.fmt.allocPrint(alloc, "file=@{s}", .{audio_path}) catch return null;
    defer alloc.free(file_arg);

    // curl -s -X POST https://api.openai.com/v1/audio/transcriptions
    //   -H "Authorization: Bearer $OPENAI_API_KEY"
    //   -F "file=@/tmp/wintermolt_web_mic.webm"
    //   -F "model=whisper-1"
    const argv = alloc.alloc([]const u8, 11) catch return null;
    defer alloc.free(argv);
    argv[0] = "curl";
    argv[1] = "-s";
    argv[2] = "-X";
    argv[3] = "POST";
    argv[4] = "https://api.openai.com/v1/audio/transcriptions";
    argv[5] = "-H";
    argv[6] = auth_header;
    argv[7] = "-F";
    argv[8] = file_arg;
    argv[9] = "-F";
    argv[10] = "model=whisper-1";

    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return null;

    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, 65536) catch return null;

    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    // Parse JSON response: {"text":"transcribed text here"}
    const response = stdout_list.items;
    if (response.len == 0) return null;

    const text = sse.findJsonString(response, "text") orelse return null;
    return alloc.dupe(u8, text) catch null;
}
