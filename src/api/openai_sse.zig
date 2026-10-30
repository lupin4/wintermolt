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
    text_buf: ArrayList(u8) = .empty,
    /// Line buffer for SSE parsing
    line_buf: ArrayList(u8) = .empty,
    /// Accumulated tool call JSON fragments
    tool_calls: ArrayList(ToolCallAccum) = .empty,
    /// Final stop reason
    stop_reason: protocol.StopReason = .unknown,
    /// Whether we've received the [DONE] signal
    done: bool = false,
    /// A provider error frame arrived inside a 200 stream. Hosted gateways
    /// answer 200 and put the failure in a `data:` line instead of a status
    /// code, so without this the request looks like an empty successful answer
    /// and the caller reports nothing. The client turns it into a failed
    /// request. Test this flag, not `stream_error`: the message is dropped when
    /// it cannot be copied.
    stream_failed: bool = false,
    /// That frame's provider message, owned. Optional — stream_failed stands on
    /// its own.
    stream_error: ?[]u8 = null,
    /// The first bytes of the body as sent. A non-2xx body is JSON, not SSE, so
    /// no line of it is parsed; httpErrorText reads it from here.
    raw_head: ArrayList(u8) = .empty,

    const raw_head_cap = 4096;

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
        if (self.stream_error) |msg| self.alloc.free(msg);
        self.raw_head.deinit(self.alloc);
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
        self.stream_failed = false;
        if (self.stream_error) |msg| self.alloc.free(msg);
        self.stream_error = null;
        self.raw_head.clearRetainingCapacity();
    }

    /// Feed raw SSE data from curl callback.
    pub fn feed(self: *OpenAiStreamParser, data: []const u8) !void {
        const room = raw_head_cap - self.raw_head.items.len;
        try self.raw_head.appendSlice(self.alloc, data[0..@min(room, data.len)]);
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
        // Nothing after [DONE] or a provider error frame is ours to read.
        if (self.done) return;

        const payload = sse_utils.fieldValue(line, "data") orelse return;

        // Provider error frame, in either shape seen in the wild:
        //   {"type":"error","error":{"message":"..."}}
        //   {"error": {"message":"...","type":"invalid_request_error"}}
        if (hasErrorFrame(payload)) {
            const message = sse_utils.findJsonString(payload, "message") orelse payload;
            if (self.stream_error) |old| self.alloc.free(old);
            self.stream_error = self.alloc.dupe(u8, message) catch null;
            self.stream_failed = true;
            self.done = true;
            return;
        }

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
                .name = .empty,
                .arguments = .empty,
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

    /// What a non-2xx response said: the body's error message when it is JSON
    /// that carries one, else up to 500 bytes of the body ("" when it had none).
    pub fn httpErrorText(self: *const OpenAiStreamParser) []const u8 {
        const body = std.mem.trim(u8, self.raw_head.items, " \t\r\n");
        return sse_utils.findJsonString(body, "message") orelse body[0..@min(body.len, 500)];
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

/// True when the JSON object in `payload` carries an error at its own level:
/// a top-level `"error"` key, or a top-level `"type"` whose value is
/// `"error"`.
///
/// Deliberately not a substring search. Azure OpenAI documents an `error`
/// object nested in `content_filter_results` on a chunk of a *successful*
/// answer; a search for `"error":{` anywhere in the frame would throw that
/// answer away. A provider error frame is the whole frame, so only the object's
/// own keys count. Whitespace around a colon, or inside the object, is however
/// the provider writes it.
fn hasErrorFrame(payload: []const u8) bool {
    const body = std.mem.trim(u8, payload, " \t\r\n");
    if (body.len < 2 or body[0] != '{') return false;

    var i: usize = 1;
    var depth: usize = 1;
    while (i < body.len) {
        if (body[i] == '"') {
            const start = i + 1;
            const end = stringEnd(body, start) orelse return false;
            const text = body[start..end];
            i = end + 1;
            // Only the object's own keys count, and only a string followed by
            // a colon is a key: a string in value position is not.
            if (depth != 1) continue;
            var j = skipJsonSpace(body, i);
            if (j >= body.len or body[j] != ':') continue;
            if (std.mem.eql(u8, text, "error")) return true;
            if (std.mem.eql(u8, text, "type")) {
                j = skipJsonSpace(body, j + 1);
                if (j < body.len and body[j] == '"') {
                    const vs = j + 1;
                    const ve = stringEnd(body, vs) orelse return false;
                    if (std.mem.eql(u8, body[vs..ve], "error")) return true;
                    i = ve + 1;
                }
            }
            continue;
        }
        switch (body[i]) {
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
        i += 1;
    }
    return false;
}

/// Index of the first non-space byte at or after `from`.
fn skipJsonSpace(body: []const u8, from: usize) usize {
    var i = from;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) i += 1;
    return i;
}

/// Index of the closing quote of the JSON string that starts at `start` (the
/// first byte after the opening quote), or null when it never closes.
fn stringEnd(body: []const u8, start: usize) ?usize {
    var i = start;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            continue;
        }
        if (body[i] == '"') return i;
    }
    return null;
}

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

// Hosted gateways (LiteLLM, OpenRouter, vLLM) report quota, rate-limit and
// model-not-found failures inside an HTTP 200 as an SSE error frame. Without
// stream_failed such a frame parses to an empty successful answer, so a caller
// cannot tell a refused request from a model that said nothing.
test "stream error: {\"type\":\"error\"} inside a 200 stream is captured, and yields no answer" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data: {\"type\":\"error\",\"error\":{\"message\":\"Insufficient credits for request\"}}\n\n");

    try std.testing.expect(parser.stream_failed);
    try std.testing.expectEqualStrings("Insufficient credits for request", parser.stream_error orelse "");
    try std.testing.expect(parser.done);
    // What made this silent: the frame carries no content and no finish_reason.
    try std.testing.expectEqual(@as(usize, 0), parser.text_buf.items.len);
    try std.testing.expectEqual(protocol.StopReason.unknown, parser.stop_reason);
}

// Python servers write the object with a space after the colon, and some
// providers space the whole frame out.
test "stream error: a frame written with spaces is still a frame" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data: {\"error\": {\"message\":\"Model not found\",\"type\":\"invalid_request_error\"}}\n");
    try std.testing.expect(parser.stream_failed);
    try std.testing.expectEqualStrings("Model not found", parser.stream_error orelse "");

    parser.reset();
    try parser.feed("data: { \"type\": \"error\", \"error\": { \"message\": \"rate limited\" } }\n");
    try std.testing.expect(parser.stream_failed);
    try std.testing.expectEqualStrings("rate limited", parser.stream_error orelse "");
}

// Azure OpenAI documents this shape on a chunk of a successful answer: the
// error object is nested in content_filter_results, so the chunk carries an
// answer and must reach the caller. A search for `"error":` anywhere in the
// frame would throw it away.
test "stream error: a nested error object on a successful chunk is not a frame" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Paris\"}," ++
        "\"content_filter_results\":{\"error\": {\"code\":\"content_filter_error\",\"message\":\"The contents are not filtered\"}}}]}\n");

    try std.testing.expect(!parser.stream_failed);
    try std.testing.expectEqual(@as(?[]u8, null), parser.stream_error);
    try std.testing.expectEqualStrings("Paris", parser.text_buf.items);
}

// The parser works on raw lines, where a quote inside a JSON string is escaped.
// A model that merely prints the shape must keep streaming.
test "stream error: content that mentions an error object is not an error frame" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"{\\\"error\\\": {\\\"message\\\": \\\"not a frame\\\"}}\"}}]}\n");

    try std.testing.expect(!parser.stream_failed);
    try std.testing.expectEqual(@as(?[]u8, null), parser.stream_error);
    try std.testing.expect(std.mem.indexOf(u8, parser.text_buf.items, "\"error\": {") != null);
}

test "stream error: a healthy stream sets no error, and reset clears one" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n");
    try parser.feed("data: [DONE]\n\n");
    try std.testing.expect(!parser.stream_failed);
    try std.testing.expectEqual(@as(?[]u8, null), parser.stream_error);
    try std.testing.expectEqualStrings("hi", parser.text_buf.items);
    try std.testing.expectEqual(protocol.StopReason.end_turn, parser.stop_reason);

    // A 429 retry reuses the parser; the previous attempt's error must not
    // outlive it.
    parser.reset();
    try parser.feed("data: {\"type\":\"error\",\"error\":{\"message\":\"rate limited\"}}\n");
    try std.testing.expect(parser.stream_failed);
    parser.reset();
    try std.testing.expect(!parser.stream_failed);
    try std.testing.expectEqual(@as(?[]u8, null), parser.stream_error);
}

// A frame after [DONE] is not part of this answer.
test "stream error: nothing after [DONE] is parsed" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data: [DONE]\n\n");
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n");
    try std.testing.expectEqual(@as(usize, 0), parser.text_buf.items.len);
}

// The SSE spec makes the space after "data:" optional, and some gateways omit
// it (#7). Without it every line was dropped: an empty answer, no error.
test "data lines: a compact data: line streams text, a tool call and [DONE]" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data:{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n");
    try parser.feed("data:{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\"," ++
        "\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n");
    try parser.feed("data:[DONE]\n");

    try std.testing.expectEqualStrings("hi", parser.text_buf.items);
    try std.testing.expectEqual(@as(usize, 1), parser.tool_calls.items.len);
    try std.testing.expectEqualStrings("bash", parser.tool_calls.items[0].name.items);
    try std.testing.expect(parser.done);
    try std.testing.expectEqual(protocol.StopReason.tool_use, parser.stop_reason);
}

test "data lines: a compact error frame is still a frame" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("data:{\"type\":\"error\",\"error\":{\"message\":\"rate limited\"}}\n");
    try std.testing.expect(parser.stream_failed);
    try std.testing.expectEqualStrings("rate limited", parser.stream_error orelse "");
}

// A non-2xx body is JSON, not SSE, so no line of it is parsed. For a local
// engine it is where the models it does serve are named (#4), and OpenAI
// itself pretty-prints it over several lines.
test "http error: the body's message is kept, on one line or pretty-printed" {
    var parser = OpenAiStreamParser.init(std.testing.allocator, null);
    defer parser.deinit();

    try parser.feed("{\"error\":{\"message\":\"Model 'qwen3:8b' not found. Available models: " ++
        "Ornith-1.5-9B-MLX-4bit\",\"type\":\"not_found_error\"}}");
    try std.testing.expectEqualStrings(
        "Model 'qwen3:8b' not found. Available models: Ornith-1.5-9B-MLX-4bit",
        parser.httpErrorText(),
    );

    parser.reset();
    try parser.feed("{\n    \"error\": {\n        \"message\": \"The model `gpt-9` does not exist\",\n" ++
        "        \"type\": \"invalid_request_error\"\n    }\n}\n");
    try std.testing.expectEqualStrings("The model `gpt-9` does not exist", parser.httpErrorText());

    // A body that is not JSON is shown as sent; no body at all is "".
    parser.reset();
    try parser.feed("Bad Gateway\r\n");
    try std.testing.expectEqualStrings("Bad Gateway", parser.httpErrorText());
    parser.reset();
    try std.testing.expectEqualStrings("", parser.httpErrorText());
}
