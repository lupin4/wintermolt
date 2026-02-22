// Copyright The Fantastic Planet - By David Clabaugh
//
// protocol.zig — Anthropic Messages API wire types
//
// Defines the request/response structures for the Claude Messages API.
// These are used by client.zig to serialize requests and by the agentic
// loop to interpret responses.
//
// Wire format reference: https://docs.anthropic.com/en/api/messages

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// ---------------------------------------------------------------------------
// Request types
// ---------------------------------------------------------------------------

pub const Role = enum {
    user,
    assistant,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

/// A single content block within a message.
pub const ContentBlock = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,
    image: ImageSource,
};

pub const ImageSource = struct {
    media_type: []const u8, // "image/jpeg", "image/png", "image/gif", "image/webp"
    data: []const u8, // base64-encoded image data
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON string of the input object
    input_json: []const u8,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
    /// When set, serialized as content block array instead of plain string.
    /// Used for rich results (e.g. camera_capture returning images).
    content_blocks: ?[]const ContentBlock = null,
};

pub const Message = struct {
    role: Role,
    content: ArrayList(ContentBlock) = .{},

    pub fn initUser(alloc: Allocator, text: []const u8) !Message {
        var msg = Message{ .role = .user };
        try msg.content.append(alloc, .{ .text = text });
        return msg;
    }

    pub fn deinit(self: *Message, alloc: Allocator) void {
        self.content.deinit(alloc);
    }
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema string for input_schema
    input_schema_json: []const u8,
};

/// Stop reason returned by the API.
pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    unknown,

    pub fn fromString(s: []const u8) StopReason {
        if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
        if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
        return .unknown;
    }
};

// ---------------------------------------------------------------------------
// Response types (parsed from SSE stream)
// ---------------------------------------------------------------------------

/// Accumulated response from a single API call.
pub const Response = struct {
    stop_reason: StopReason = .unknown,
    content: ArrayList(ContentBlock) = .{},
    alloc: Allocator,

    pub fn init(alloc: Allocator) Response {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Response) void {
        self.content.deinit(self.alloc);
    }
};

// ---------------------------------------------------------------------------
// JSON serialization helpers
// ---------------------------------------------------------------------------

/// Serialize a complete Messages API request body to JSON.
/// Caller owns returned slice.
pub fn serializeRequest(
    alloc: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const Message,
    tools: []const ToolDefinition,
    max_tokens: u32,
) ![]u8 {
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll("{\"model\":\"");
    try writeJsonString(w, model);
    try w.writeAll("\",\"max_tokens\":");
    try std.fmt.format(w, "{d}", .{max_tokens});

    // System prompt
    if (system_prompt.len > 0) {
        try w.writeAll(",\"system\":\"");
        try writeJsonString(w, system_prompt);
        try w.writeByte('"');
    }

    // Stream mode
    try w.writeAll(",\"stream\":true");

    // Messages array
    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |msg, mi| {
        if (mi > 0) try w.writeByte(',');
        try serializeMessage(w, msg);
    }
    try w.writeByte(']');

    // Tools array
    if (tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, ti| {
            if (ti > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":\"");
            try writeJsonString(w, tool.name);
            try w.writeAll("\",\"description\":\"");
            try writeJsonString(w, tool.description);
            try w.writeAll("\",\"input_schema\":");
            try w.writeAll(tool.input_schema_json);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');

    return buf.toOwnedSlice(alloc);
}

fn serializeMessage(w: anytype, msg: Message) !void {
    try w.writeAll("{\"role\":\"");
    try w.writeAll(msg.role.toString());
    try w.writeAll("\",\"content\":[");

    for (msg.content.items, 0..) |block, bi| {
        if (bi > 0) try w.writeByte(',');
        switch (block) {
            .text => |text| {
                try w.writeAll("{\"type\":\"text\",\"text\":\"");
                try writeJsonString(w, text);
                try w.writeAll("\"}");
            },
            .tool_use => |tu| {
                try w.writeAll("{\"type\":\"tool_use\",\"id\":\"");
                try writeJsonString(w, tu.id);
                try w.writeAll("\",\"name\":\"");
                try writeJsonString(w, tu.name);
                try w.writeAll("\",\"input\":");
                try w.writeAll(tu.input_json);
                try w.writeByte('}');
            },
            .tool_result => |tr| {
                try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":\"");
                try writeJsonString(w, tr.tool_use_id);
                if (tr.content_blocks) |blocks| {
                    // Rich content: array of content blocks (text + images)
                    try w.writeAll("\",\"content\":[");
                    for (blocks, 0..) |cb, ci| {
                        if (ci > 0) try w.writeByte(',');
                        switch (cb) {
                            .text => |text| {
                                try w.writeAll("{\"type\":\"text\",\"text\":\"");
                                try writeJsonString(w, text);
                                try w.writeAll("\"}");
                            },
                            .image => |img| {
                                try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
                                try writeJsonString(w, img.media_type);
                                try w.writeAll("\",\"data\":\"");
                                try w.writeAll(img.data); // base64 is JSON-safe
                                try w.writeAll("\"}}");
                            },
                            else => {
                                try w.writeAll("{\"type\":\"text\",\"text\":\"[unsupported block]\"}");
                            },
                        }
                    }
                    try w.writeByte(']');
                } else {
                    // Plain string content
                    try w.writeAll("\",\"content\":\"");
                    try writeJsonString(w, tr.content);
                    try w.writeByte('"');
                }
                if (tr.is_error) {
                    try w.writeAll(",\"is_error\":true");
                }
                try w.writeByte('}');
            },
            .image => |img| {
                // Debug: log image serialization details to stderr
                {
                    const dbg = std.fs.File.stderr().deprecatedWriter();
                    dbg.print("[api] Serializing image block: media_type={s}, data_len={d}, data_prefix={s}\n", .{
                        img.media_type,
                        img.data.len,
                        if (img.data.len > 20) img.data[0..20] else img.data,
                    }) catch {};
                }
                try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
                try writeJsonString(w, img.media_type);
                try w.writeAll("\",\"data\":\"");
                try w.writeAll(img.data); // base64 is JSON-safe
                try w.writeAll("\"}}");
            },
        }
    }

    try w.writeAll("]}");
}

/// Write a JSON-escaped string (without surrounding quotes).
fn writeJsonString(w: anytype, s: []const u8) !void {
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
