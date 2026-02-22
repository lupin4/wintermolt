// Copyright The Fantastic Planet - By David Clabaugh
//
// history.zig — Conversation history management
//
// Maintains the message history for the agentic loop. The Anthropic API
// requires alternating user/assistant roles, and tool results must be
// sent as user messages following the assistant's tool_use response.
//
// Context window management: when history exceeds a threshold, older
// messages (except the system prompt, which is separate) are dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("../api/protocol.zig");

pub const History = struct {
    alloc: Allocator,
    messages: ArrayList(protocol.Message) = .{},
    /// Approximate token count (rough estimate: 1 token ~ 3 chars for JSON-heavy content)
    approx_tokens: usize = 0,
    /// Fixed overhead: system prompt + tool definitions + max output tokens (set by loop.zig)
    overhead_tokens: usize = 0,
    /// Effective max = API limit - overhead. Defaults conservatively until setOverhead() called.
    max_tokens: usize = 150_000,

    pub fn init(alloc: Allocator) History {
        return .{ .alloc = alloc };
    }

    /// Set fixed overhead from system prompt, tool definitions, and max output tokens.
    /// Called once from loop.zig init to compute the real history budget.
    pub fn setOverhead(self: *History, system_prompt_len: usize, tool_defs_len: usize, max_output: u32) void {
        self.overhead_tokens = system_prompt_len / 3 + tool_defs_len / 3 + max_output;
        const api_limit: usize = 200_000;
        self.max_tokens = if (api_limit > self.overhead_tokens) api_limit - self.overhead_tokens else 50_000;
    }

    /// Emergency compaction — aggressively drop to 40% of budget.
    /// Called by loop.zig when the API returns a context overflow error.
    pub fn emergencyCompact(self: *History) void {
        if (self.messages.items.len <= 4) return;
        const target = self.max_tokens * 2 / 5; // compact to 40% of budget
        while (self.approx_tokens > target and self.messages.items.len > 4) {
            var msg = self.messages.orderedRemove(0);
            for (msg.content.items) |block| {
                switch (block) {
                    .text => |t| self.approx_tokens -|= t.len / 3,
                    .tool_use => |tu| self.approx_tokens -|= (tu.input_json.len + tu.name.len) / 3,
                    .tool_result => |tr| self.approx_tokens -|= tr.content.len / 3,
                    .image => self.approx_tokens -|= 1600,
                }
            }
            msg.deinit(self.alloc);
        }
    }

    pub fn deinit(self: *History) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.alloc);
        }
        self.messages.deinit(self.alloc);
    }

    /// Add a pre-built message directly (used by /look and /watch for image messages).
    pub fn addMessage(self: *History, msg: protocol.Message) !void {
        // Deep-copy content blocks
        var copy = protocol.Message{ .role = msg.role };
        for (msg.content.items) |block| {
            switch (block) {
                .text => |text| {
                    const t = try self.alloc.dupe(u8, text);
                    try copy.content.append(self.alloc, .{ .text = t });
                    self.approx_tokens += text.len / 3;
                },
                .image => |img| {
                    try copy.content.append(self.alloc, .{ .image = .{
                        .media_type = try self.alloc.dupe(u8, img.media_type),
                        .data = try self.alloc.dupe(u8, img.data),
                    } });
                    // Images cost ~(w*h)/750 tokens, estimate ~1600 for a typical frame
                    self.approx_tokens += 1600;
                },
                .tool_use => |tu| {
                    try copy.content.append(self.alloc, .{ .tool_use = .{
                        .id = try self.alloc.dupe(u8, tu.id),
                        .name = try self.alloc.dupe(u8, tu.name),
                        .input_json = try self.alloc.dupe(u8, tu.input_json),
                    } });
                    self.approx_tokens += (tu.input_json.len + tu.name.len) / 3;
                },
                .tool_result => |tr| {
                    try copy.content.append(self.alloc, .{ .tool_result = .{
                        .tool_use_id = try self.alloc.dupe(u8, tr.tool_use_id),
                        .content = try self.alloc.dupe(u8, tr.content),
                        .is_error = tr.is_error,
                    } });
                    self.approx_tokens += tr.content.len / 3;
                },
            }
        }
        try self.messages.append(self.alloc, copy);
        self.maybeCompact();
    }

    /// Add a user text message.
    pub fn addUserMessage(self: *History, text: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, text);
        var msg = protocol.Message{ .role = .user };
        try msg.content.append(self.alloc, .{ .text = text_copy });
        try self.messages.append(self.alloc, msg);
        self.approx_tokens += text.len / 3;
        self.maybeCompact();
    }

    /// Add an assistant response (text + tool_use blocks).
    pub fn addAssistantResponse(self: *History, response: *const protocol.Response) !void {
        var msg = protocol.Message{ .role = .assistant };

        for (response.content.items) |block| {
            switch (block) {
                .text => |text| {
                    const copy = try self.alloc.dupe(u8, text);
                    try msg.content.append(self.alloc, .{ .text = copy });
                    self.approx_tokens += text.len / 3;
                },
                .tool_use => |tu| {
                    try msg.content.append(self.alloc, .{ .tool_use = .{
                        .id = try self.alloc.dupe(u8, tu.id),
                        .name = try self.alloc.dupe(u8, tu.name),
                        .input_json = try self.alloc.dupe(u8, tu.input_json),
                    } });
                    self.approx_tokens += (tu.input_json.len + tu.name.len) / 3;
                },
                .image => |img| {
                    try msg.content.append(self.alloc, .{ .image = .{
                        .media_type = try self.alloc.dupe(u8, img.media_type),
                        .data = try self.alloc.dupe(u8, img.data),
                    } });
                    self.approx_tokens += 1600;
                },
                .tool_result => {
                    // Tool results don't appear in assistant messages
                },
            }
        }

        try self.messages.append(self.alloc, msg);
    }

    /// Add tool results as a user message (API requires this pattern).
    pub fn addToolResults(self: *History, results: []const protocol.ToolResult) !void {
        var msg = protocol.Message{ .role = .user };

        for (results) |result| {
            // Deep-copy content_blocks if present
            var blocks_copy: ?[]const protocol.ContentBlock = null;
            if (result.content_blocks) |blocks| {
                const copy = try self.alloc.alloc(protocol.ContentBlock, blocks.len);
                for (blocks, 0..) |block, i| {
                    switch (block) {
                        .text => |text| {
                            copy[i] = .{ .text = try self.alloc.dupe(u8, text) };
                        },
                        .image => |img| {
                            copy[i] = .{ .image = .{
                                .media_type = try self.alloc.dupe(u8, img.media_type),
                                .data = try self.alloc.dupe(u8, img.data),
                            } };
                            self.approx_tokens += 1600;
                        },
                        else => {
                            copy[i] = .{ .text = try self.alloc.dupe(u8, "[unsupported block]") };
                        },
                    }
                }
                blocks_copy = copy;
            }

            try msg.content.append(self.alloc, .{ .tool_result = .{
                .tool_use_id = try self.alloc.dupe(u8, result.tool_use_id),
                .content = try self.alloc.dupe(u8, result.content),
                .is_error = result.is_error,
                .content_blocks = blocks_copy,
            } });
            self.approx_tokens += result.content.len / 4;
        }

        try self.messages.append(self.alloc, msg);
    }

    /// Get messages as a slice for API serialization.
    pub fn getMessages(self: *const History) []const protocol.Message {
        return self.messages.items;
    }

    /// Drop older messages if we're over budget, keeping the most recent
    /// conversation turns. Always keeps at least the last 4 messages
    /// (2 turn pairs) for coherence.
    /// Triggers at 50% of budget (aggressive — prevents rate limit hits on smaller plans).
    fn maybeCompact(self: *History) void {
        const threshold = self.max_tokens * 50 / 100;
        if (self.approx_tokens <= threshold) return;
        if (self.messages.items.len <= 4) return;

        // Drop messages from the front until under 75% of threshold
        const target = threshold * 3 / 4;
        while (self.approx_tokens > target and self.messages.items.len > 4) {
            var msg = self.messages.orderedRemove(0);
            for (msg.content.items) |block| {
                switch (block) {
                    .text => |t| self.approx_tokens -|= t.len / 3,
                    .tool_use => |tu| self.approx_tokens -|= (tu.input_json.len + tu.name.len) / 3,
                    .tool_result => |tr| self.approx_tokens -|= tr.content.len / 3,
                    .image => self.approx_tokens -|= 1600,
                }
            }
            msg.deinit(self.alloc);
        }
    }
};
