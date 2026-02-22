// Copyright The Fantastic Planet - By David Clabaugh
//
// ndjson.zig — Newline-Delimited JSON parser for Ollama streaming API
//
// Ollama's streaming response format is NDJSON: one JSON object per line.
// Each line looks like:
//   {"model":"llava","message":{"role":"assistant","content":"Hello"},"done":false}
//   {"model":"llava","message":{"role":"assistant","content":""},"done":true}
//
// We extract the "content" field from each line and accumulate text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");

pub const NdjsonParser = struct {
    alloc: Allocator,
    /// Accumulated full response text
    text_buf: ArrayList(u8) = .{},
    /// Buffer for partial lines across curl chunks
    line_buf: ArrayList(u8) = .{},
    /// Callback for streaming text to terminal
    text_cb: ?sse.TextCallback = null,
    /// Whether we received a done:true message
    done: bool = false,
    /// Accumulated tool calls (Ollama sends complete tool_calls in one NDJSON line)
    tool_calls: ArrayList(ToolCall) = .{},

    const ToolCall = struct {
        id: []u8,
        name: []u8,
        arguments: []u8,
    };

    pub fn init(alloc: Allocator, text_cb: ?sse.TextCallback) NdjsonParser {
        return .{
            .alloc = alloc,
            .text_cb = text_cb,
        };
    }

    pub fn deinit(self: *NdjsonParser) void {
        self.text_buf.deinit(self.alloc);
        self.line_buf.deinit(self.alloc);
        for (self.tool_calls.items) |tc| {
            self.alloc.free(tc.id);
            self.alloc.free(tc.name);
            self.alloc.free(tc.arguments);
        }
        self.tool_calls.deinit(self.alloc);
    }

    /// Feed a chunk of raw NDJSON data from curl.
    pub fn feed(self: *NdjsonParser, chunk: []const u8) !void {
        for (chunk) |byte| {
            if (byte == '\n') {
                if (self.line_buf.items.len > 0) {
                    try self.processLine(self.line_buf.items);
                    self.line_buf.clearRetainingCapacity();
                }
            } else {
                try self.line_buf.append(self.alloc, byte);
            }
        }
    }

    fn processLine(self: *NdjsonParser, line: []const u8) !void {
        // Skip empty lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;

        // Check for done flag
        if (std.mem.indexOf(u8, trimmed, "\"done\":true") != null or
            std.mem.indexOf(u8, trimmed, "\"done\": true") != null)
        {
            self.done = true;
        }

        // Extract message.content using the nested object approach:
        // First find "message" object, then extract "content" from it
        if (sse.findJsonString(trimmed, "message")) |msg_json| {
            if (sse.findJsonString(msg_json, "content")) |content| {
                if (content.len > 0) {
                    // Unescape JSON string
                    const unescaped = sse.unescapeJson(content);
                    // Stream text to terminal
                    if (self.text_cb) |cb| {
                        cb(unescaped);
                    }
                    // Accumulate
                    try self.text_buf.appendSlice(self.alloc, unescaped);
                }
            }

            // Parse tool_calls from the message object (Ollama sends complete calls)
            try self.parseToolCalls(msg_json);
        }
    }

    /// Parse tool_calls from an Ollama NDJSON message object.
    /// Ollama sends complete tool calls (not incremental like OpenAI SSE):
    ///   "tool_calls":[{"function":{"name":"bash","arguments":{"command":"ls"}}}]
    fn parseToolCalls(self: *NdjsonParser, msg_json: []const u8) !void {
        const tc_needle = "\"tool_calls\":[";
        var search_pos: usize = 0;
        const tc_start = std.mem.indexOf(u8, msg_json, tc_needle) orelse return;
        search_pos = tc_start + tc_needle.len;

        // Parse each tool call object in the array
        // Ollama tool_calls format: {"function":{"name":"...","arguments":{...}}}
        // Note: Ollama often omits "id" — we generate a fallback
        var tc_index: usize = 0;
        while (search_pos < msg_json.len) {
            // Find next function object
            const fn_needle = "\"function\":{";
            const fn_pos = std.mem.indexOfPos(u8, msg_json, search_pos, fn_needle) orelse break;
            const fn_body = msg_json[fn_pos + fn_needle.len ..];

            // Extract name
            const name = sse.findJsonString(fn_body, "name") orelse {
                search_pos = fn_pos + fn_needle.len;
                continue;
            };

            // Extract arguments — could be a JSON object (not a string)
            // Look for "arguments": after name
            const args = self.extractArguments(fn_body) orelse "{}";

            // Check for id field (may be absent in Ollama)
            // Search backwards from function for "id":"..."
            const id_search = msg_json[search_pos..fn_pos];
            const id_val = sse.findJsonString(id_search, "id");

            const id_str = if (id_val) |id|
                try self.alloc.dupe(u8, id)
            else blk: {
                // Generate fallback ID: "ollama_call_0", "ollama_call_1", etc.
                break :blk try std.fmt.allocPrint(self.alloc, "ollama_call_{d}", .{tc_index});
            };

            try self.tool_calls.append(self.alloc, .{
                .id = id_str,
                .name = try self.alloc.dupe(u8, name),
                .arguments = try self.alloc.dupe(u8, args),
            });
            tc_index += 1;

            // Move past this tool call
            search_pos = fn_pos + fn_needle.len + @min(fn_body.len, 1);
        }
    }

    /// Extract "arguments" value from function body — handles both string and object values.
    /// Ollama sends arguments as a JSON object: "arguments":{"command":"ls"}
    /// OpenAI sends as a string: "arguments":"{\"command\":\"ls\"}"
    fn extractArguments(self: *NdjsonParser, fn_body: []const u8) ?[]const u8 {
        _ = self;
        const needle = "\"arguments\":";
        const pos = std.mem.indexOf(u8, fn_body, needle) orelse return null;
        var i = pos + needle.len;

        // Skip whitespace
        while (i < fn_body.len and (fn_body[i] == ' ' or fn_body[i] == '\t')) : (i += 1) {}
        if (i >= fn_body.len) return null;

        if (fn_body[i] == '"') {
            // String value — unescape and return the inner string
            i += 1;
            const start = i;
            while (i < fn_body.len) {
                if (fn_body[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (fn_body[i] == '"') {
                    const raw = fn_body[start..i];
                    return sse.unescapeJson(raw);
                }
                i += 1;
            }
            return null;
        }

        if (fn_body[i] == '{') {
            // Object value — find matching closing brace
            var depth: usize = 0;
            const start = i;
            while (i < fn_body.len) {
                if (fn_body[i] == '{') depth += 1;
                if (fn_body[i] == '}') {
                    depth -= 1;
                    if (depth == 0) return fn_body[start .. i + 1];
                }
                if (fn_body[i] == '"') {
                    // Skip string contents
                    i += 1;
                    while (i < fn_body.len) {
                        if (fn_body[i] == '\\') {
                            i += 2;
                            continue;
                        }
                        if (fn_body[i] == '"') break;
                        i += 1;
                    }
                }
                i += 1;
            }
            return null;
        }

        return null;
    }

    /// Build a protocol.Response from accumulated state.
    pub fn toResponse(self: *NdjsonParser) !protocol.Response {
        var resp = protocol.Response.init(self.alloc);

        if (self.text_buf.items.len > 0) {
            const text_copy = try self.alloc.dupe(u8, self.text_buf.items);
            try resp.content.append(self.alloc, .{ .text = text_copy });
        }

        // Add tool calls as tool_use content blocks
        for (self.tool_calls.items) |tc| {
            if (tc.name.len > 0) {
                try resp.content.append(self.alloc, .{ .tool_use = .{
                    .id = try self.alloc.dupe(u8, tc.id),
                    .name = try self.alloc.dupe(u8, tc.name),
                    .input_json = if (tc.arguments.len > 0)
                        try self.alloc.dupe(u8, tc.arguments)
                    else
                        "{}",
                } });
            }
        }

        // Set stop reason based on what we accumulated
        if (self.tool_calls.items.len > 0) {
            resp.stop_reason = .tool_use;
        } else if (self.done) {
            resp.stop_reason = .end_turn;
        } else {
            resp.stop_reason = .unknown;
        }

        return resp;
    }
};
