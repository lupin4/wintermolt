// Copyright The Fantastic Planet - By David Clabaugh
//
// forai.zig — in-process forAI inference engine (adapter stub)
//
// /model forai runs models in-process: forAI (model graph) + forNLP
// (tokenizer / sampling / chat templates) on forMetal (macOS) or forCUDA
// (Linux/Windows). No external model loader.
//
// forAI is being rebuilt (2026-06-04). The extern fn list is pinned when
// its new exports land; until then is_supported = false and /model forai
// reports the engine as not yet delivered instead of crashing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const kernel_mod = @import("kernel.zig");

/// Becomes a real comptime capability check (per-target archive presence)
/// once forAI's rebuilt C-ABI is pinned.
pub const is_supported = false;

pub const Error = error{ForAIEngineUnavailable};

pub const ForAIClient = struct {
    alloc: Allocator,
    model_path: []const u8,
    model_alias: []const u8,

    pub fn init(alloc: Allocator, model_path: []const u8, model_alias: []const u8) ForAIClient {
        return .{ .alloc = alloc, .model_path = model_path, .model_alias = model_alias };
    }

    pub fn deinit(self: *ForAIClient) void {
        // Weights handle freed here once the engine lands (GB-scale —
        // switchBackend/deinit drain this before replacement, like kernel).
        _ = self;
    }

    pub fn sendMessage(
        self: *ForAIClient,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        tool_defs: []const protocol.ToolDefinition,
        text_cb: ?sse.TextCallback,
    ) !protocol.Response {
        _ = self;
        _ = system_prompt;
        _ = messages;
        _ = tool_defs;
        _ = text_cb;
        return Error.ForAIEngineUnavailable;
    }
};

// Model files share the kernel backend's resolver (~/.wintermolt/models,
// WINTERMOLT_KERNEL_MODEL_DIR) — unsloth GGUF exports dropped there work
// for both /model kernel and /model forai.
pub const resolveModelPath = kernel_mod.resolveModelPath;
pub const defaultModelDir = kernel_mod.defaultModelDir;
