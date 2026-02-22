// Copyright The Fantastic Planet - By David Clabaugh
//
// openai_sse.zig — SSE parser for OpenAI-compatible APIs
//
// Parses streaming responses from OpenAI-format APIs (DeepSeek, Qwen,
// Mistral, Together.ai, etc.). Translates into Wintermolt protocol.Response.
//
// OpenAI SSE format:
//   data: {"id":"...","choices":[{"delta":{"content":"hello"},"finish_reason":null}]}
//   data: {"id":"...","choices":[{"delta":{"tool_calls":[{...}]},"finish_reason":null}]}
//   data: [DONE]
//
// Key differences from Anthropic SSE:
// - No event: line — all events are just data: lines
// - Content in choices[0].delta.content
// - Tool calls in choices[0].delta.tool_calls array (incremental)
// - finish_reason in choices[0].finish_reason

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("protocol.zig");
const sse_utils = @import("sse.zig");

pub const TextCallback = sse_utils.TextCallback;

/// Parser for OpenAI-format SSE streaming responses.
pub const OpenAiStreamParser = struct {
    alloc: Allocator,
    text_cb: ?TextCallback,
    /// Accumulated text content
    text_buf: ArrayList(u8) = .{},
    /// Line buffer for SSE parsing
    line_buf: ArrayList(u8) = .{},
    /// Accumulated tool call JSON fragments
    tool_calls: ArrayList(ToolCallAccum) = .{},
    /// Final stop reason
    stop_reason: protocol.StopReason = .unknown,
    /// Whether we've received the [DONE] signal
    done: bool = false,

    const ToolCallAccum = struct {
        id: []u8,
        name: ArrayList(u8),
        arguments: ArrayList(u8),
    };

    pub fn init(alloc: Allocator, text_cb: ?TextCallback) OpenAiStreamParser {
        return .{
            .alloc = alloc,
            .text_cb = text_cb,
        };
    }

    pub fn deinit(self: *OpenAiStreamParser) void {
        self.text_buf.deinit(self.alloc);
        self.line_buf.deinit(self.alloc);
        for (self.tool_calls.items) |*tc| {
            self.alloc.free(tc.id);
            tc.name.deinit(self.alloc);
            tc.arguments.deinit(self.alloc);
        }
        self.tool_calls.deinit(self.alloc);
    }

    pub fn reset(self: *OpenAiStreamParser) void {
        self.text_buf.clearRetainingCapacity();
        self.line_buf.clearRetainingCapacity();
        for (self.tool_calls.items) |*tc| {
            self.alloc.free(tc.id);
            tc.name.deinit(self.alloc);
            tc.arguments.deinit(self.alloc);
        }
        self.tool_calls.clearRetainingCapacity();
        self.stop_reason = .unknown;
        self.done = false;
    }

    /// Feed raw SSE data from curl callback.
    pub fn feed(self: *OpenAiStreamParser, data: []const u8) !void {
        for (data) |byte| {
            if (byte == '\n') {
                const line = self.line_buf.items;
                if (line.len > 0) {
                    self.processLine(line);
                }
                self.line_buf.clearRetainingCapacity();
            } else if (byte != '\r') {
                try self.line_buf.append(self.alloc, byte);
            }
        }
    }

    fn processLine(self: *OpenAiStreamParser, line: []const u8) void {
        // SSE data: prefix
        if (!std.mem.startsWith(u8, line, "data: ")) return;
        const payload = line["data: ".len..];

        // [DONE] signal
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.done = true;
            if (self.stop_reason == .unknown) {
                // If we have tool calls, it's tool_use; otherwise end_turn
                if (self.tool_calls.items.len > 0) {
                    self.stop_reason = .tool_use;
                } else {
                    self.stop_reason = .end_turn;
                }
            }
            return;
        }

        // Parse JSON payload — extract delta content and tool_calls
        self.parseChunk(payload);
    }

    fn parseChunk(self: *OpenAiStreamParser, json: []const u8) void {
        // Extract finish_reason if present
        if (sse_utils.findJsonString(json, "finish_reason")) |reason| {
            if (std.mem.eql(u8, reason, "stop")) {
                self.stop_reason = .end_turn;
            } else if (std.mem.eql(u8, reason, "tool_calls")) {
                self.stop_reason = .tool_use;
            } else if (std.mem.eql(u8, reason, "length")) {
                self.stop_reason = .max_tokens;
            }
        }

        // Extract text content from delta
        // Look for "delta":{"content":"..." pattern
        if (findDeltaContent(json)) |content| {
            // Unescape JSON string (returns module-level buffer or original slice)
            const unescaped = sse_utils.unescapeJson(content);
            self.text_buf.appendSlice(self.alloc, unescaped) catch {};
            if (self.text_cb) |cb| cb(unescaped);
        }

        // Extract tool calls from delta
        // OpenAI sends incremental tool_calls: index, id (first chunk), function.name, function.arguments
        self.parseToolCallDelta(json);
    }

    fn parseToolCallDelta(self: *OpenAiStreamParser, json: []const u8) void {
        // Look for "tool_calls" in the JSON
        const tc_needle = "\"tool_calls\":[";
        const tc_start = std.mem.indexOf(u8, json, tc_needle) orelse return;
        const tc_body = json[tc_start + tc_needle.len ..];

        // Extract index
        const index: usize = blk: {
            if (sse_utils.findJsonString(tc_body, "index")) |idx_str| {
                break :blk std.fmt.parseInt(usize, idx_str, 10) catch 0;
            }
            // Try numeric field
            const idx_needle = "\"index\":";
            if (std.mem.indexOf(u8, tc_body, idx_needle)) |pos| {
                const num_start = pos + idx_needle.len;
                var num_end = num_start;
                while (num_end < tc_body.len and tc_body[num_end] >= '0' and tc_body[num_end] <= '9') : (num_end += 1) {}
                if (num_end > num_start) {
                    break :blk std.fmt.parseInt(usize, tc_body[num_start..num_end], 10) catch 0;
                }
            }
            break :blk 0;
        };

        // Ensure we have enough slots
        while (self.tool_calls.items.len <= index) {
            self.tool_calls.append(self.alloc, .{
                .id = self.alloc.dupe(u8, "") catch return,
                .name = .{},
                .arguments = .{},
            }) catch return;
        }

        var tc = &self.tool_calls.items[index];

        // Extract id (only present in first chunk for each tool call)
        if (sse_utils.findJsonString(tc_body, "id")) |id| {
            if (id.len > 0 and tc.id.len == 0) {
                self.alloc.free(tc.id);
                tc.id = self.alloc.dupe(u8, id) catch return;
            }
        }

        // Extract function name (incremental)
        // Look for "function":{"name":"..."
        if (findNestedString(tc_body, "function", "name")) |name| {
            tc.name.appendSlice(self.alloc, name) catch {};
        }

        // Extract function arguments (incremental — appended chunk by chunk)
        if (findNestedString(tc_body, "function", "arguments")) |args| {
            // Unescape the JSON string fragment (returns module-level buffer or original slice)
            const unescaped = sse_utils.unescapeJson(args);
            tc.arguments.appendSlice(self.alloc, unescaped) catch {};
        }
    }

    /// Get accumulated text (for error display).
    pub fn getAccumulatedText(self: *const OpenAiStreamParser) []const u8 {
        return self.text_buf.items;
    }

    /// Build a Wintermolt protocol.Response from accumulated state.
    pub fn toResponse(self: *OpenAiStreamParser) protocol.Response {
        var response = protocol.Response.init(self.alloc);
        response.stop_reason = self.stop_reason;

        // Add accumulated text as a content block
        if (self.text_buf.items.len > 0) {
            const text_copy = self.alloc.dupe(u8, self.text_buf.items) catch "";
            response.content.append(self.alloc, .{ .text = text_copy }) catch {};
        }

        // Add tool calls as tool_use content blocks
        for (self.tool_calls.items) |*tc| {
            if (tc.name.items.len > 0) {
                response.content.append(self.alloc, .{ .tool_use = .{
                    .id = self.alloc.dupe(u8, tc.id) catch "",
                    .name = self.alloc.dupe(u8, tc.name.items) catch "",
                    .input_json = if (tc.arguments.items.len > 0)
                        self.alloc.dupe(u8, tc.arguments.items) catch "{}"
                    else
                        "{}",
                } }) catch {};
            }
        }

        return response;
    }
};

/// Find "delta":{"content":"<value>"} in JSON.
/// Returns the raw (escaped) string value.
fn findDeltaContent(json: []const u8) ?[]const u8 {
    // Look for "content":" after "delta"
    const delta_pos = std.mem.indexOf(u8, json, "\"delta\"") orelse return null;
    const after_delta = json[delta_pos..];

    const content_needle = "\"content\":\"";
    const start = std.mem.indexOf(u8, after_delta, content_needle) orelse return null;
    const value_start = start + content_needle.len;

    // Find closing quote (handle escapes)
    var i = value_start;
    while (i < after_delta.len) {
        if (after_delta[i] == '\\') {
            i += 2;
            continue;
        }
        if (after_delta[i] == '"') {
            return after_delta[value_start..i];
        }
        i += 1;
    }
    return null;
}

/// Find a nested string value: "outer":{"inner":"<value>"}
fn findNestedString(json: []const u8, outer: []const u8, inner: []const u8) ?[]const u8 {
    // Find outer key
    var buf: [128]u8 = undefined;
    const outer_needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{outer}) catch return null;
    const outer_pos = std.mem.indexOf(u8, json, outer_needle) orelse return null;
    const after_outer = json[outer_pos + outer_needle.len ..];

    // Find inner key
    var buf2: [128]u8 = undefined;
    const inner_needle = std.fmt.bufPrint(&buf2, "\"{s}\":\"", .{inner}) catch return null;
    const inner_pos = std.mem.indexOf(u8, after_outer, inner_needle) orelse return null;
    const value_start = inner_pos + inner_needle.len;

    // Find closing quote
    var i = value_start;
    while (i < after_outer.len) {
        if (after_outer[i] == '\\') {
            i += 2;
            continue;
        }
        if (after_outer[i] == '"') {
            return after_outer[value_start..i];
        }
        i += 1;
    }
    return null;
}
