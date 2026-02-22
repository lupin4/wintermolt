// Copyright The Fantastic Planet - By David Clabaugh
//
// protocol.zig — Model Context Protocol types
//
// MCP (Model Context Protocol) JSON-RPC 2.0 types for both server and client.
// Protocol version: 2024-11-05
//
// MCP uses JSON-RPC 2.0 over stdio (newline-delimited JSON lines).
// This is nearly identical to Wintermolt's chat bridge IPC pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PROTOCOL_VERSION = "2024-11-05";
pub const JSONRPC_VERSION = "2.0";

// ============================================================================
// Server Info
// ============================================================================

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const ServerCapabilities = struct {
    tools: bool = true,
    resources: bool = false,
    prompts: bool = false,
};

// ============================================================================
// Client Info (received in initialize request)
// ============================================================================

pub const ClientInfo = struct {
    name: []const u8 = "unknown",
    version: []const u8 = "0.0.0",
};

// ============================================================================
// Tool types (reused from Wintermolt's existing tool definitions)
// ============================================================================

pub const McpToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

pub const ToolCallResult = struct {
    content: []const ContentBlock,
    is_error: bool = false,
};

pub const ContentBlock = struct {
    type: []const u8 = "text",
    text: []const u8,
};

// ============================================================================
// JSON-RPC 2.0 message types
// ============================================================================

/// Parsed JSON-RPC request (method call with id)
pub const JsonRpcRequest = struct {
    id: JsonRpcId,
    method: []const u8,
    params_json: ?[]const u8 = null, // raw JSON of params object
};

/// Parsed JSON-RPC notification (no id, no response expected)
pub const JsonRpcNotification = struct {
    method: []const u8,
    params_json: ?[]const u8 = null,
};

/// JSON-RPC id can be string or integer
pub const JsonRpcId = union(enum) {
    integer: i64,
    string: []const u8,
    null_id: void,

    pub fn format(self: JsonRpcId) []const u8 {
        return switch (self) {
            .integer => "integer",
            .string => "string",
            .null_id => "null",
        };
    }
};

// ============================================================================
// MCP method names (the protocol's RPC methods)
// ============================================================================

pub const Method = struct {
    pub const initialize = "initialize";
    pub const initialized = "notifications/initialized";
    pub const tools_list = "tools/list";
    pub const tools_call = "tools/call";
    pub const resources_list = "resources/list";
    pub const resources_read = "resources/read";
    pub const prompts_list = "prompts/list";
    pub const ping = "ping";
    pub const cancelled = "notifications/cancelled";
};

// ============================================================================
// Error codes (JSON-RPC 2.0 + MCP-specific)
// ============================================================================

pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};
