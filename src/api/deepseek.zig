// Copyright The Fantastic Planet - By David Clabaugh
//
// deepseek.zig — DeepSeek API client (OpenAI-compatible)
//
// DeepSeek V3: $0.14/$0.28 per MTok — 35x cheaper than Opus.
// Uses OpenAI chat completions format with tool_use support.
// Endpoint: https://api.deepseek.com/chat/completions
//
// This client reuses the same libcurl extern declarations from client.zig
// and the OpenAI SSE parser from openai_sse.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("protocol.zig");
const openai_sse = @import("openai_sse.zig");
const sse = @import("sse.zig");

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
// DeepSeek Client
// ---------------------------------------------------------------------------

pub const DeepSeekClient = struct {
    alloc: Allocator,
    api_key: []const u8,
    model: []const u8,
    api_url: []const u8,
    max_tokens: u32,

    pub fn init(
        alloc: Allocator,
        api_key: []const u8,
        model: []const u8,
    ) DeepSeekClient {
        return .{
            .alloc = alloc,
            .api_key = api_key,
            .model = model,
            .api_url = "https://api.deepseek.com/chat/completions",
            .max_tokens = 8192,
        };
    }

    /// Send a streaming chat completion request.
    pub fn sendMessage(
        self: *const DeepSeekClient,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        tools_defs: []const protocol.ToolDefinition,
        text_cb: ?sse.TextCallback,
    ) !protocol.Response {
        // Serialize request in OpenAI format
        const body = try serializeOpenAiRequest(
            self.alloc,
            self.model,
            system_prompt,
            messages,
            tools_defs,
            self.max_tokens,
        );
        defer self.alloc.free(body);

        {
            const dbg = std.fs.File.stderr().deprecatedWriter();
            dbg.print("[deepseek] request: {d} bytes (~{d}k tokens est)\n", .{ body.len, body.len / 3000 }) catch {};
        }

        // Initialize curl
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        // Set URL
        const url_z = try self.alloc.dupeZ(u8, self.api_url);
        defer self.alloc.free(url_z);
        _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

        // Build headers
        var headers: ?*CurlSlist = null;
        defer if (headers) |h| curl_slist_free_all(h);

        headers = curl_slist_append(headers, "Content-Type: application/json");

        // Bearer auth (OpenAI format)
        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{self.api_key}) catch
            return error.ApiKeyTooLong;
        headers = curl_slist_append(headers, auth_header);

        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);

        // Set POST body
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
        const body_z = try self.alloc.dupeZ(u8, body);
        defer self.alloc.free(body_z);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body_z.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

        // Set write callback for SSE streaming
        var parser = openai_sse.OpenAiStreamParser.init(self.alloc, text_cb);
        defer parser.deinit();

        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &parser);

        // Timeouts: 10s to connect, 90s total (shorter than Claude — non-primary)
        _ = curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
        _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 90));

        // Perform with retry for rate limits
        const max_retries: usize = 3;
        var attempt: usize = 0;
        while (true) {
            const result = curl_easy_perform(handle);
            if (result != .ok) {
                const err_msg = curl_easy_strerror(result);
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("\n[deepseek curl error] {s}\n", .{err_msg}) catch {};
                return error.CurlRequestFailed;
            }

            var http_code: c_long = 0;
            _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);

            if (http_code == 200) break;

            if (http_code == 429 and attempt < max_retries) {
                attempt += 1;
                const wait_secs: u64 = std.math.shl(u64, 2, @as(u6, @intCast(attempt - 1)));
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("\n[deepseek] Rate limited, waiting {d}s ({d}/{d})...\n", .{ wait_secs, attempt, max_retries }) catch {};
                std.Thread.sleep(wait_secs * 1_000_000_000);
                parser.reset();
                continue;
            }

            const stderr = std.fs.File.stderr().deprecatedWriter();
            const error_body = parser.getAccumulatedText();
            if (error_body.len > 0) {
                stderr.print("\n[deepseek HTTP {d}] {s}\n", .{ http_code, error_body[0..@min(error_body.len, 500)] }) catch {};
            } else {
                stderr.print("\n[deepseek HTTP {d}] Request failed\n", .{http_code}) catch {};
            }

            if (http_code == 400 or http_code == 413) return error.ContextOverflow;
            return error.HttpError;
        }

        return parser.toResponse();
    }
};

/// curl write callback for OpenAI SSE streaming
fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *openai_sse.OpenAiStreamParser,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.feed(ptr[0..total]) catch return 0;
    return total;
}

// ---------------------------------------------------------------------------
// OpenAI-format request serialization
// ---------------------------------------------------------------------------

/// Serialize messages into OpenAI chat completions format.
fn serializeOpenAiRequest(
    alloc: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const protocol.Message,
    tools_defs: []const protocol.ToolDefinition,
    max_tokens: u32,
) ![]u8 {
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll("{\"model\":\"");
    try writeJsonStr(w, model);
    try w.writeAll("\",\"max_tokens\":");
    try std.fmt.format(w, "{d}", .{max_tokens});
    try w.writeAll(",\"stream\":true");

    // Messages array (system message first, then conversation)
    try w.writeAll(",\"messages\":[");

    // System message
    if (system_prompt.len > 0) {
        try w.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonStr(w, system_prompt);
        try w.writeAll("\"}");
    }

    // Conversation messages — properly handle tool_use and tool_result blocks
    var need_comma = (system_prompt.len > 0);
    for (messages) |msg| {
        // First pass: classify what this message contains
        var has_tool_use = false;
        var has_tool_result = false;
        var has_text = false;
        for (msg.content.items) |block| {
            switch (block) {
                .tool_use => has_tool_use = true,
                .tool_result => has_tool_result = true,
                .text => has_text = true,
                .image => {},
            }
        }

        // Assistant message with tool_use → serialize as tool_calls array
        if (msg.role == .assistant and has_tool_use) {
            if (need_comma) try w.writeByte(',');
            need_comma = true;
            try w.writeAll("{\"role\":\"assistant\"");

            // Include text content if present alongside tool calls
            if (has_text) {
                try w.writeAll(",\"content\":\"");
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
            } else {
                try w.writeAll(",\"content\":null");
            }

            try w.writeAll(",\"tool_calls\":[");
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
                        try w.writeAll("\",\"arguments\":\"");
                        try writeJsonStr(w, tu.input_json);
                        try w.writeAll("\"}}");
                    },
                    else => {},
                }
            }
            try w.writeAll("]}");
            continue;
        }

        // User message with tool_result → each result becomes a {"role":"tool",...} message
        if (has_tool_result) {
            for (msg.content.items) |block| {
                switch (block) {
                    .tool_result => |tr| {
                        if (need_comma) try w.writeByte(',');
                        need_comma = true;
                        try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":\"");
                        try writeJsonStr(w, tr.tool_use_id);
                        try w.writeAll("\",\"content\":\"");
                        try writeJsonStr(w, tr.content);
                        try w.writeAll("\"}");
                    },
                    .text => |text| {
                        // Non-tool text in same message → separate user message
                        if (text.len > 0) {
                            if (need_comma) try w.writeByte(',');
                            need_comma = true;
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

        // Regular message (user/assistant text only)
        if (need_comma) try w.writeByte(',');
        need_comma = true;
        try w.writeAll("{\"role\":\"");
        try w.writeAll(msg.role.toString());
        try w.writeAll("\",\"content\":\"");
        for (msg.content.items, 0..) |block, bi| {
            if (bi > 0) try w.writeAll("\\n");
            switch (block) {
                .text => |text| try writeJsonStr(w, text),
                .image => try w.writeAll("[image]"),
                else => {},
            }
        }
        try w.writeAll("\"}");
    }
    try w.writeByte(']');

    // Tools array (OpenAI function calling format)
    if (tools_defs.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools_defs, 0..) |tool, ti| {
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
    return buf.toOwnedSlice(alloc);
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
