// Copyright The Fantastic Planet - By David Clabaugh
//
// sse.zig — Server-Sent Events parser for Anthropic streaming API
//
// Parses the SSE wire format:
//   "event: <type>\n"
//   "data: <json>\n"
//   "\n"  (blank line = dispatch event)
//
// The Anthropic streaming API sends these event types:
//   message_start        — contains message metadata
//   content_block_start  — new content block (text or tool_use)
//   content_block_delta  — incremental content (text_delta or input_json_delta)
//   content_block_stop   — block complete
//   message_delta        — stop_reason, usage
//   message_stop         — stream complete
//   ping                 — keepalive
//   error                — API error

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("protocol.zig");

pub const EventType = enum {
    message_start,
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_delta,
    message_stop,
    ping,
    @"error",
    unknown,
};

pub const Event = struct {
    event_type: EventType,
    data: []const u8,
};

/// Callback type for streaming text output.
pub const TextCallback = *const fn (text: []const u8) void;

/// Accumulated state for parsing a streaming response.
pub const StreamParser = struct {
    alloc: Allocator,
    /// Accumulated text blocks (full text of each text content block)
    text_blocks: ArrayList([]u8) = .{},
    /// Accumulated tool_use blocks: each entry is {id, name, accumulated_input_json}
    tool_ids: ArrayList([]u8) = .{},
    tool_names: ArrayList([]u8) = .{},
    tool_inputs: ArrayList(ArrayList(u8)) = .{},
    /// Current block type being accumulated ("text" or "tool_use")
    current_block_type: ?[]const u8 = null,
    current_block_index: ?usize = null,
    /// Stop reason from message_delta
    stop_reason: protocol.StopReason = .unknown,
    /// Callback for streaming text to terminal
    text_cb: ?TextCallback = null,
    /// Line buffer for partial lines from curl chunks
    line_buf: ArrayList(u8) = .{},
    /// Current event type (set by "event:" line)
    pending_event_type: ?EventType = null,

    pub fn init(alloc: Allocator, text_cb: ?TextCallback) StreamParser {
        return .{
            .alloc = alloc,
            .text_cb = text_cb,
        };
    }

    pub fn deinit(self: *StreamParser) void {
        for (self.text_blocks.items) |tb| self.alloc.free(tb);
        self.text_blocks.deinit(self.alloc);
        for (self.tool_ids.items) |id| self.alloc.free(id);
        self.tool_ids.deinit(self.alloc);
        for (self.tool_names.items) |n| self.alloc.free(n);
        self.tool_names.deinit(self.alloc);
        for (self.tool_inputs.items) |*inp| inp.deinit(self.alloc);
        self.tool_inputs.deinit(self.alloc);
        self.line_buf.deinit(self.alloc);
    }

    /// Reset accumulated state for retry (e.g., after HTTP 429).
    /// Frees all collected data but retains ArrayList capacity for reuse.
    pub fn reset(self: *StreamParser) void {
        for (self.text_blocks.items) |tb| self.alloc.free(tb);
        self.text_blocks.clearRetainingCapacity();
        for (self.tool_ids.items) |id| self.alloc.free(id);
        self.tool_ids.clearRetainingCapacity();
        for (self.tool_names.items) |n| self.alloc.free(n);
        self.tool_names.clearRetainingCapacity();
        for (self.tool_inputs.items) |*inp| inp.deinit(self.alloc);
        self.tool_inputs.clearRetainingCapacity();
        self.line_buf.clearRetainingCapacity();
        self.current_block_type = null;
        self.current_block_index = null;
        self.stop_reason = .unknown;
        self.pending_event_type = null;
    }

    /// Feed a chunk of raw SSE data from curl. May contain partial lines.
    pub fn feed(self: *StreamParser, chunk: []const u8) !void {
        for (chunk) |byte| {
            if (byte == '\n') {
                const line = self.line_buf.items;
                try self.processLine(line);
                self.line_buf.clearRetainingCapacity();
            } else {
                try self.line_buf.append(self.alloc, byte);
            }
        }
    }

    fn processLine(self: *StreamParser, line: []const u8) !void {
        // Skip carriage returns
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (trimmed.len == 0) {
            // Blank line = dispatch pending event
            self.pending_event_type = null;
            return;
        }

        if (std.mem.startsWith(u8, trimmed, "event: ")) {
            const event_name = trimmed[7..];
            self.pending_event_type = parseEventType(event_name);
            return;
        }

        if (std.mem.startsWith(u8, trimmed, "data: ")) {
            const data = trimmed[6..];
            const etype = self.pending_event_type orelse return;
            try self.handleEvent(etype, data);
            return;
        }
    }

    fn handleEvent(self: *StreamParser, etype: EventType, data: []const u8) !void {
        switch (etype) {
            .content_block_start => try self.handleBlockStart(data),
            .content_block_delta => try self.handleBlockDelta(data),
            .content_block_stop => self.handleBlockStop(),
            .message_delta => self.handleMessageDelta(data),
            .@"error" => self.handleError(data),
            else => {},
        }
    }

    fn handleBlockStart(self: *StreamParser, data: []const u8) !void {
        // Parse: {"type":"content_block_start","index":N,"content_block":{"type":"text",...}}
        // or:   {"type":"content_block_start","index":N,"content_block":{"type":"tool_use","id":"...","name":"..."}}
        const idx = extractIndex(data);
        self.current_block_index = idx;

        if (findJsonString(data, "content_block")) |block_json| {
            if (findJsonString(block_json, "type")) |btype| {
                if (std.mem.eql(u8, btype, "text")) {
                    self.current_block_type = "text";
                    // Ensure we have a text block at this index
                    while (self.text_blocks.items.len <= (idx orelse 0)) {
                        const empty = try self.alloc.alloc(u8, 0);
                        try self.text_blocks.append(self.alloc, empty);
                    }
                } else if (std.mem.eql(u8, btype, "tool_use")) {
                    self.current_block_type = "tool_use";
                    // Extract id and name
                    const id = findJsonString(block_json, "id") orelse "";
                    const name = findJsonString(block_json, "name") orelse "";
                    const id_copy = try self.alloc.dupe(u8, id);
                    const name_copy = try self.alloc.dupe(u8, name);
                    try self.tool_ids.append(self.alloc, id_copy);
                    try self.tool_names.append(self.alloc, name_copy);
                    try self.tool_inputs.append(self.alloc, .{});
                }
            }
        }
    }

    fn handleBlockDelta(self: *StreamParser, data: []const u8) !void {
        // text_delta: {"type":"content_block_delta","index":N,"delta":{"type":"text_delta","text":"..."}}
        // input_json_delta: {"type":"content_block_delta","index":N,"delta":{"type":"input_json_delta","partial_json":"..."}}

        if (findJsonString(data, "delta")) |delta_json| {
            if (findJsonString(delta_json, "type")) |dtype| {
                if (std.mem.eql(u8, dtype, "text_delta")) {
                    if (findJsonString(delta_json, "text")) |text| {
                        // Stream text to terminal immediately
                        if (self.text_cb) |cb| {
                            cb(text);
                        }
                        // Accumulate for history
                        const idx = self.current_block_index orelse 0;
                        if (idx < self.text_blocks.items.len) {
                            const old = self.text_blocks.items[idx];
                            const new = try self.alloc.alloc(u8, old.len + text.len);
                            @memcpy(new[0..old.len], old);
                            @memcpy(new[old.len..], text);
                            self.alloc.free(old);
                            self.text_blocks.items[idx] = new;
                        }
                    }
                } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                    if (findJsonString(delta_json, "partial_json")) |pjson| {
                        // Accumulate tool input JSON fragments
                        if (self.tool_inputs.items.len > 0) {
                            const last_idx = self.tool_inputs.items.len - 1;
                            try self.tool_inputs.items[last_idx].appendSlice(self.alloc, pjson);
                        }
                    }
                }
            }
        }
    }

    fn handleBlockStop(self: *StreamParser) void {
        self.current_block_type = null;
        self.current_block_index = null;
    }

    fn handleMessageDelta(self: *StreamParser, data: []const u8) void {
        // {"type":"message_delta","delta":{"stop_reason":"end_turn",...}}
        if (findJsonString(data, "stop_reason")) |sr| {
            self.stop_reason = protocol.StopReason.fromString(sr);
        }
    }

    fn handleError(self: *StreamParser, data: []const u8) void {
        _ = self;
        // Print API error to stderr
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("\n[API Error] {s}\n", .{data}) catch {};
    }

    /// Get accumulated raw text from text_blocks (useful for error response bodies).
    /// Returns the first text block if present, or the current line buffer content.
    pub fn getAccumulatedText(self: *StreamParser) []const u8 {
        for (self.text_blocks.items) |tb| {
            if (tb.len > 0) return tb;
        }
        // On error responses, the body isn't SSE so it stays in the line buffer
        if (self.line_buf.items.len > 0) return self.line_buf.items;
        return "";
    }

    /// Build a Response from the accumulated stream state.
    pub fn toResponse(self: *StreamParser) !protocol.Response {
        var resp = protocol.Response.init(self.alloc);
        resp.stop_reason = self.stop_reason;

        // Add text blocks
        for (self.text_blocks.items) |tb| {
            if (tb.len > 0) {
                const text_copy = try self.alloc.dupe(u8, tb);
                try resp.content.append(self.alloc, .{ .text = text_copy });
            }
        }

        // Add tool_use blocks
        for (self.tool_ids.items, 0..) |id, i| {
            const raw_input = if (i < self.tool_inputs.items.len)
                self.tool_inputs.items[i].items
            else
                "";
            // Default to "{}" if accumulated input is empty (tool called with no args)
            const input = if (raw_input.len == 0)
                try self.alloc.dupe(u8, "{}")
            else
                try self.alloc.dupe(u8, raw_input);

            try resp.content.append(self.alloc, .{ .tool_use = .{
                .id = try self.alloc.dupe(u8, id),
                .name = try self.alloc.dupe(u8, self.tool_names.items[i]),
                .input_json = input,
            } });
        }

        return resp;
    }
};

// ---------------------------------------------------------------------------
// Minimal JSON helpers (no full parser needed — we extract known fields)
// ---------------------------------------------------------------------------

fn parseEventType(name: []const u8) EventType {
    if (std.mem.eql(u8, name, "message_start")) return .message_start;
    if (std.mem.eql(u8, name, "content_block_start")) return .content_block_start;
    if (std.mem.eql(u8, name, "content_block_delta")) return .content_block_delta;
    if (std.mem.eql(u8, name, "content_block_stop")) return .content_block_stop;
    if (std.mem.eql(u8, name, "message_delta")) return .message_delta;
    if (std.mem.eql(u8, name, "message_stop")) return .message_stop;
    if (std.mem.eql(u8, name, "ping")) return .ping;
    if (std.mem.eql(u8, name, "error")) return .@"error";
    return .unknown;
}

/// Extract the value of "index":N from JSON
fn extractIndex(json: []const u8) ?usize {
    const needle = "\"index\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = pos + needle.len;
    if (start >= json.len) return null;
    var end = start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(usize, json[start..end], 10) catch null;
}

/// Find the string value for a given key in JSON. Returns the unescaped content
/// between quotes. For nested objects, finds the key and returns a reasonable
/// substring. This is a lightweight extractor, not a full JSON parser.
pub fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key": or "key":"
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = pos + needle.len;

    // Skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return null;

    if (json[i] == '"') {
        // String value — find the closing quote (handling escapes)
        i += 1;
        const start = i;
        while (i < json.len) {
            if (json[i] == '\\') {
                i += 2; // skip escaped char
                continue;
            }
            if (json[i] == '"') {
                return unescapeJson(json[start..i]);
            }
            i += 1;
        }
        return null;
    }

    if (json[i] == '{') {
        // Object value — find matching closing brace
        var depth: u32 = 1;
        const start = i;
        i += 1;
        while (i < json.len and depth > 0) {
            if (json[i] == '{') depth += 1;
            if (json[i] == '}') depth -= 1;
            if (json[i] == '"') {
                // Skip string contents
                i += 1;
                while (i < json.len and json[i] != '"') {
                    if (json[i] == '\\') i += 1;
                    i += 1;
                }
            }
            i += 1;
        }
        return json[start..i];
    }

    return null;
}

/// Module-level buffer for JSON string unescaping.
/// Safe for single-threaded use; each findJsonString result is consumed before the next call.
var unescape_buf: [32768]u8 = undefined;

/// Unescape JSON string escapes (\n, \t, \\, \", \/, \r, \uXXXX).
/// Returns a slice into the module-level buffer, or the original slice if no escapes.
pub fn unescapeJson(s: []const u8) []const u8 {
    // Fast path: no backslashes
    if (std.mem.indexOf(u8, s, "\\") == null) return s;

    var out: usize = 0;
    var i: usize = 0;
    while (i < s.len and out < unescape_buf.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => {
                    unescape_buf[out] = '\n';
                    out += 1;
                },
                'r' => {
                    unescape_buf[out] = '\r';
                    out += 1;
                },
                't' => {
                    unescape_buf[out] = '\t';
                    out += 1;
                },
                '"' => {
                    unescape_buf[out] = '"';
                    out += 1;
                },
                '\\' => {
                    unescape_buf[out] = '\\';
                    out += 1;
                },
                '/' => {
                    unescape_buf[out] = '/';
                    out += 1;
                },
                'u' => {
                    // \uXXXX — decode BMP codepoint to UTF-8
                    if (i + 4 < s.len) {
                        const hex = s[i + 1 .. i + 5];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch {
                            // Invalid hex — pass through raw
                            unescape_buf[out] = '\\';
                            out += 1;
                            if (out < unescape_buf.len) {
                                unescape_buf[out] = 'u';
                                out += 1;
                            }
                            i += 1;
                            continue;
                        };
                        // Encode codepoint as UTF-8
                        const utf8_len = std.unicode.utf8Encode(cp, unescape_buf[out..@min(out + 4, unescape_buf.len)]) catch {
                            i += 5;
                            continue;
                        };
                        out += utf8_len;
                        i += 5;
                    } else {
                        unescape_buf[out] = '\\';
                        out += 1;
                        if (out < unescape_buf.len) {
                            unescape_buf[out] = 'u';
                            out += 1;
                        }
                        i += 1;
                    }
                    continue;
                },
                else => {
                    // Unknown escape — pass through both chars
                    unescape_buf[out] = '\\';
                    out += 1;
                    if (out < unescape_buf.len) {
                        unescape_buf[out] = s[i];
                        out += 1;
                    }
                },
            }
            i += 1;
        } else {
            unescape_buf[out] = s[i];
            out += 1;
            i += 1;
        }
    }
    return unescape_buf[0..out];
}
