// Copyright The Fantastic Planet - By David Clabaugh
//
// json_rpc.zig — JSON-RPC 2.0 parser and formatter for MCP
//
// Parses JSON-RPC requests from MCP clients and formats responses.
// Uses the same findJsonString() pattern as Wintermolt's SSE parser.
//
// JSON-RPC 2.0 wire format:
//   Request:  {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
//   Response: {"jsonrpc":"2.0","id":1,"result":{...}}
//   Error:    {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
//   Notif:    {"jsonrpc":"2.0","method":"notifications/initialized"}

const std = @import("std");
const Allocator = std.mem.Allocator;
const mcp = @import("protocol.zig");

/// Parse a JSON-RPC message from a line of JSON text.
/// Returns a request (has id) or null if it's a notification or invalid.
pub fn parseRequest(line: []const u8) ?mcp.JsonRpcRequest {
    const method = findJsonString(line, "method") orelse return null;
    const id = parseId(line);

    // Find params object (raw JSON)
    const params = findJsonObject(line, "params");

    return .{
        .id = id,
        .method = method,
        .params_json = params,
    };
}

/// Check if a line is a notification (no "id" field)
pub fn isNotification(line: []const u8) bool {
    // Has method but no id
    const has_method = findJsonString(line, "method") != null;
    const has_id = std.mem.indexOf(u8, line, "\"id\"") != null;
    return has_method and !has_id;
}

/// Parse the "id" field from JSON-RPC. Can be integer, string, or null.
fn parseId(json: []const u8) mcp.JsonRpcId {
    const needle = "\"id\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return .{ .null_id = {} };
    var i = pos + needle.len;

    // Skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return .{ .null_id = {} };

    if (json[i] == '"') {
        // String id
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return .{ .null_id = {} };
        return .{ .string = json[start..end] };
    } else if (json[i] == 'n') {
        // null
        return .{ .null_id = {} };
    } else {
        // Integer id — parse digits (parseInt handles sign natively)
        const start = i;
        if (json[i] == '-') i += 1;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
        const num_str = json[start..i];
        const val = std.fmt.parseInt(i64, num_str, 10) catch return .{ .null_id = {} };
        return .{ .integer = val };
    }
}

// ============================================================================
// Response formatters
// ============================================================================

/// Format a successful JSON-RPC response.
pub fn formatResponse(alloc: Allocator, id: mcp.JsonRpcId, result_json: []const u8) ![]u8 {
    return switch (id) {
        .integer => |v| std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":{d},"result":{s}}}
        , .{ v, result_json }),
        .string => |v| std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":"{s}","result":{s}}}
        , .{ v, result_json }),
        .null_id => std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":null,"result":{s}}}
        , .{result_json}),
    };
}

/// Format a JSON-RPC error response.
pub fn formatError(alloc: Allocator, id: mcp.JsonRpcId, code: i32, message: []const u8) ![]u8 {
    return switch (id) {
        .integer => |v| std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":{d},"error":{{"code":{d},"message":"{s}"}}}}
        , .{ v, code, message }),
        .string => |v| std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":"{s}","error":{{"code":{d},"message":"{s}"}}}}
        , .{ v, code, message }),
        .null_id => std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":null,"error":{{"code":{d},"message":"{s}"}}}}
        , .{ code, message }),
    };
}

// ============================================================================
// JSON helpers (reuse SSE parser pattern)
// ============================================================================

/// Find a string value for a key in JSON: "key":"value"
/// Returns the unquoted value, or null if not found.
pub fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Build search needle: "key":"
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start_pos + needle.len;

    // Find closing quote (handle escaped quotes)
    var i = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (json[i] == '"') {
            return json[val_start..i];
        }
    }
    return null;
}

/// Find a JSON object value for a key: "key":{...}
/// Returns the raw JSON object (including braces), or null.
pub fn findJsonObject(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = key_pos + needle.len;

    // Skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return null;

    if (json[i] == '{') {
        // Find matching closing brace
        var depth: i32 = 0;
        const start = i;
        while (i < json.len) : (i += 1) {
            if (json[i] == '"') {
                // Skip string contents
                i += 1;
                while (i < json.len) : (i += 1) {
                    if (json[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (json[i] == '"') break;
                }
                continue;
            }
            if (json[i] == '{') depth += 1;
            if (json[i] == '}') {
                depth -= 1;
                if (depth == 0) return json[start .. i + 1];
            }
        }
    }
    return null;
}

/// Find a JSON array value for a key: "key":[...]
pub fn findJsonArray(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = key_pos + needle.len;

    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != '[') return null;

    var depth: i32 = 0;
    const start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"') {
            i += 1;
            while (i < json.len) : (i += 1) {
                if (json[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (json[i] == '"') break;
            }
            continue;
        }
        if (json[i] == '[') depth += 1;
        if (json[i] == ']') {
            depth -= 1;
            if (depth == 0) return json[start .. i + 1];
        }
    }
    return null;
}

/// Escape a string for JSON output (handles ", \, newlines, tabs).
pub fn jsonEscapeString(alloc: Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);
    for (input) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    return buf.toOwnedSlice(alloc);
}
