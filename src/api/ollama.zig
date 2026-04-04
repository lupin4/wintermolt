// Copyright The Fantastic Planet - By David Clabaugh
//
// ollama.zig — libcurl-based HTTP client for the Ollama API
//
// Talks to a local Ollama instance (default: http://localhost:11434).
// Supports streaming NDJSON responses and multimodal models (LLaVA)
// by including base64 images in the messages array.
//
// Unlike the Claude client, Ollama:
//   - Requires no API key (local inference)
//   - Uses NDJSON streaming (not SSE)
//   - Supports images via "images" array in messages (not content blocks)
//   - Supports tool_use via OpenAI-compatible tool_calls format

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const ndjson = @import("ndjson.zig");

// ---------------------------------------------------------------------------
// libcurl extern declarations (same as client.zig)
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) CurlCode;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) CurlCode;
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: *CurlSlist) void;
extern fn curl_easy_strerror(code: CurlCode) [*:0]const u8;

const CurlCode = enum(c_int) { ok = 0, _ };

const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_POST: c_int = 47;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_CONNECTTIMEOUT: c_int = 78;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

// ---------------------------------------------------------------------------
// OllamaClient
// ---------------------------------------------------------------------------

pub const OllamaClient = struct {
    alloc: Allocator,
    base_url: []const u8, // "http://localhost:11434"
    model: []const u8, // "llava", "llama3", etc.

    pub fn init(alloc: Allocator, base_url: []const u8, model: []const u8) OllamaClient {
        return .{
            .alloc = alloc,
            .base_url = base_url,
            .model = model,
        };
    }

    /// Lightweight one-shot completion via /api/generate (stream:false).
    /// Used for quick safety checks — returns the response text or error.
    /// Short timeout (default 5s) — if Ollama is slow or down, caller should fail open.
    pub fn quickCheck(self: *const OllamaClient, prompt: []const u8, model_override: ?[]const u8, timeout_secs: u32) ![]u8 {
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        const use_model = model_override orelse self.model;

        // Build JSON body: {"model":"...","prompt":"...","stream":false}
        var body_buf: ArrayList(u8) = .{};
        defer body_buf.deinit(self.alloc);
        const bw = body_buf.writer(self.alloc);
        try bw.writeAll("{\"model\":\"");
        try writeJsonStr(bw, use_model);
        try bw.writeAll("\",\"prompt\":\"");
        try writeJsonStr(bw, prompt);
        try bw.writeAll("\",\"stream\":false}");
        const body = try body_buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(body);

        // Build URL: {base_url}/api/generate
        const url = try std.fmt.allocPrint(self.alloc, "{s}/api/generate", .{self.base_url});
        defer self.alloc.free(url);
        const url_z = try self.alloc.dupeZ(u8, url);
        defer self.alloc.free(url_z);
        _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

        // Headers
        var headers: ?*CurlSlist = null;
        defer if (headers) |h| curl_slist_free_all(h);
        headers = curl_slist_append(headers, "Content-Type: application/json");
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);

        // POST body
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
        const body_z = try self.alloc.dupeZ(u8, body);
        defer self.alloc.free(body_z);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body_z.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

        // Response collector
        var collector = QuickCheckCollector.init(self.alloc);
        defer collector.deinit();
        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &quickCheckWriteCb);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &collector);

        // Short timeouts for safety checks
        _ = curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, @as(c_long, 2));
        _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, @intCast(timeout_secs)));

        // Perform
        const result = curl_easy_perform(handle);
        if (result != .ok) return error.CurlRequestFailed;

        var http_code: c_long = 0;
        _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);
        if (http_code != 200) return error.HttpError;

        // Parse "response" field from JSON
        const resp_data = collector.buf.items;
        if (sse.findJsonString(resp_data, "response")) |response_text| {
            return self.alloc.dupe(u8, response_text);
        }
        return error.MalformedResponse;
    }

    /// Send a streaming chat request to Ollama with tool_use support.
    pub fn sendMessage(
        self: *const OllamaClient,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        tool_defs: []const protocol.ToolDefinition,
        text_cb: ?sse.TextCallback,
    ) !protocol.Response {
        // Serialize request body
        const body = try self.serializeRequest(system_prompt, messages, tool_defs);
        defer self.alloc.free(body);

        // Initialize curl
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        // Build URL: {base_url}/api/chat
        const url = try std.fmt.allocPrint(self.alloc, "{s}/api/chat", .{self.base_url});
        defer self.alloc.free(url);
        const url_z = try self.alloc.dupeZ(u8, url);
        defer self.alloc.free(url_z);
        _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

        // Headers
        var headers: ?*CurlSlist = null;
        defer if (headers) |h| curl_slist_free_all(h);
        headers = curl_slist_append(headers, "Content-Type: application/json");
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);

        // POST body
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
        const body_z = try self.alloc.dupeZ(u8, body);
        defer self.alloc.free(body_z);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body_z.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

        // Write callback for NDJSON streaming
        var parser = ndjson.NdjsonParser.init(self.alloc, text_cb);
        defer parser.deinit();

        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &parser);

        // Timeouts: 5s connect (local), 180s total (local models can be slow to generate)
        _ = curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, @as(c_long, 5));
        _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 180));

        // Perform request
        const result = curl_easy_perform(handle);
        if (result != .ok) {
            const err_msg = curl_easy_strerror(result);
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("\n[ollama curl error] {s}\n", .{err_msg}) catch {};
            return error.CurlRequestFailed;
        }

        // Check HTTP status
        var http_code: c_long = 0;
        _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);
        if (http_code == 400 and tool_defs.len > 0) {
            // Model likely doesn't support tools — retry without them
            // Also strip tool_use/tool_result messages from history since
            // models reject tool-related messages when tools aren't declared.
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[ollama] Model doesn't support tools, retrying without\n", .{}) catch {};
            return self.sendMessageNoTools(system_prompt, messages, text_cb);
        }
        if (http_code != 200) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("\n[ollama HTTP {d}] Request failed\n", .{http_code}) catch {};
            return error.HttpError;
        }

        return parser.toResponse();
    }

    /// Retry without tools — filters out tool_use/tool_result messages from
    /// history so models that don't support tools won't reject the request.
    fn sendMessageNoTools(
        self: *const OllamaClient,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        text_cb: ?sse.TextCallback,
    ) anyerror!protocol.Response {
        // Build filtered message list: skip messages that contain tool blocks
        var filtered: ArrayList(protocol.Message) = .{};
        defer filtered.deinit(self.alloc);

        for (messages) |msg| {
            var has_tool = false;
            for (msg.content.items) |block| {
                switch (block) {
                    .tool_use, .tool_result => {
                        has_tool = true;
                        break;
                    },
                    else => {},
                }
            }
            if (!has_tool) {
                try filtered.append(self.alloc, msg);
            }
        }

        return self.sendMessage(system_prompt, filtered.items, &.{}, text_cb);
    }

    /// Serialize Ollama chat request with tool_use support.
    /// Format: {"model":"...", "messages":[...], "tools":[...], "stream":true}
    fn serializeRequest(
        self: *const OllamaClient,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        tool_defs: []const protocol.ToolDefinition,
    ) ![]u8 {
        var buf: ArrayList(u8) = .{};
        const w = buf.writer(self.alloc);

        try w.writeAll("{\"model\":\"");
        try writeJsonStr(w, self.model);
        try w.writeAll("\",\"stream\":true,\"messages\":[");

        var first = true;

        // System prompt as a system message
        if (system_prompt.len > 0) {
            try w.writeAll("{\"role\":\"system\",\"content\":\"");
            try writeJsonStr(w, system_prompt);
            try w.writeAll("\"}");
            first = false;
        }

        // Convert protocol messages to Ollama format
        for (messages) |msg| {
            // Check what block types this message contains
            var has_tool_use = false;
            var has_tool_result = false;
            var has_images = false;
            for (msg.content.items) |block| {
                switch (block) {
                    .tool_use => has_tool_use = true,
                    .tool_result => has_tool_result = true,
                    .image => has_images = true,
                    else => {},
                }
            }

            // Tool results: each becomes a separate {"role":"tool",...} message
            if (has_tool_result) {
                for (msg.content.items) |block| {
                    switch (block) {
                        .tool_result => |tr| {
                            if (!first) try w.writeByte(',');
                            first = false;
                            try w.writeAll("{\"role\":\"tool\",\"content\":\"");
                            try writeJsonStr(w, tr.content);
                            try w.writeAll("\"}");
                        },
                        .text => |text| {
                            // Non-tool text in same message → regular user message
                            if (text.len > 0) {
                                if (!first) try w.writeByte(',');
                                first = false;
                                try w.writeAll("{\"role\":\"user\",\"content\":\"");
                                try writeJsonStr(w, text);
                                try w.writeAll("\"}");
                            }
                        },
                        else => {},
                    }
                }
                continue;
            }

            if (!first) try w.writeByte(',');
            first = false;

            // Assistant messages with tool_use → tool_calls format
            if (msg.role == .assistant and has_tool_use) {
                try w.writeAll("{\"role\":\"assistant\",\"content\":\"");
                // Include any text blocks
                var text_first = true;
                for (msg.content.items) |block| {
                    switch (block) {
                        .text => |text| {
                            if (!text_first) try writeJsonStr(w, "\n");
                            try writeJsonStr(w, text);
                            text_first = false;
                        },
                        else => {},
                    }
                }
                try w.writeAll("\",\"tool_calls\":[");
                var tc_first = true;
                for (msg.content.items) |block| {
                    switch (block) {
                        .tool_use => |tu| {
                            if (!tc_first) try w.writeByte(',');
                            tc_first = false;
                            try w.writeAll("{\"id\":\"");
                            try writeJsonStr(w, tu.id);
                            try w.writeAll("\",\"type\":\"function\",\"function\":{\"name\":\"");
                            try writeJsonStr(w, tu.name);
                            try w.writeAll("\",\"arguments\":");
                            // arguments must be a string in OpenAI format
                            try w.writeByte('"');
                            try writeJsonStr(w, tu.input_json);
                            try w.writeAll("\"}}");
                        },
                        else => {},
                    }
                }
                try w.writeAll("]}");
                continue;
            }

            // Regular message (user or assistant text)
            try w.writeAll("{\"role\":\"");
            try w.writeAll(msg.role.toString());
            try w.writeAll("\",\"content\":\"");
            var text_first = true;
            for (msg.content.items) |block| {
                switch (block) {
                    .text => |text| {
                        if (!text_first) try writeJsonStr(w, "\n");
                        try writeJsonStr(w, text);
                        text_first = false;
                    },
                    else => {},
                }
            }
            try w.writeByte('"');

            // Images array (for multimodal models like LLaVA)
            if (has_images) {
                try w.writeAll(",\"images\":[");
                var img_first = true;
                for (msg.content.items) |block| {
                    switch (block) {
                        .image => |img| {
                            if (!img_first) try w.writeByte(',');
                            try w.writeByte('"');
                            try w.writeAll(img.data); // base64, JSON-safe
                            try w.writeByte('"');
                            img_first = false;
                        },
                        else => {},
                    }
                }
                try w.writeByte(']');
            }

            try w.writeByte('}');
        }

        try w.writeByte(']');

        // Tools array (OpenAI function calling format)
        if (tool_defs.len > 0) {
            try w.writeAll(",\"tools\":[");
            for (tool_defs, 0..) |tool, ti| {
                if (ti > 0) try w.writeByte(',');
                try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
                try writeJsonStr(w, tool.name);
                try w.writeAll("\",\"description\":\"");
                try writeJsonStr(w, tool.description);
                try w.writeAll("\",\"parameters\":");
                try w.writeAll(tool.input_schema_json);
                try w.writeAll("}}");
            }
            try w.writeByte(']');
        }

        try w.writeByte('}');
        return buf.toOwnedSlice(self.alloc);
    }
};

/// curl write callback for NDJSON streaming
fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *ndjson.NdjsonParser,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.feed(ptr[0..total]) catch return 0;
    return total;
}

/// Response collector for quickCheck — wraps ArrayList + allocator for curl callback.
const QuickCheckCollector = struct {
    buf: ArrayList(u8),
    alloc: Allocator,

    fn init(alloc: Allocator) QuickCheckCollector {
        return .{ .buf = .{}, .alloc = alloc };
    }
    fn deinit(self: *QuickCheckCollector) void {
        self.buf.deinit(self.alloc);
    }
};

/// curl write callback for quickCheck (non-streaming, collects into buffer).
fn quickCheckWriteCb(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *QuickCheckCollector,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.buf.appendSlice(userdata.alloc, ptr[0..total]) catch return 0;
    return total;
}

/// Write a JSON-escaped string (without surrounding quotes).
fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(w, "\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}
