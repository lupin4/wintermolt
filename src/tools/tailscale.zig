// Copyright The Fantastic Planet - By David Clabaugh
//
// tailscale.zig — Tailscale mesh VPN tool
//
// Provides Tailscale network status, device listing, and connectivity
// checking via CLI and REST API. Falls back gracefully if Tailscale
// is not installed.
//
// Actions:
//   status  — Run `tailscale status --json`, parse peer list
//   devices — Query REST API for full device inventory
//   ping    — Run `tailscale ping <hostname>` for connectivity check

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");
const http_tool = @import("http.zig");
const bash_tool = @import("bash.zig");

/// Execute the tailscale tool. Entry point matching standard tool pattern.
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const action = sse.findJsonString(input_json, "action") orelse "status";

    if (std.mem.eql(u8, action, "status")) {
        return getTailscaleStatus(alloc);
    } else if (std.mem.eql(u8, action, "devices")) {
        return getTailscaleDevices(alloc, input_json);
    } else if (std.mem.eql(u8, action, "ping")) {
        const target = sse.findJsonString(input_json, "target") orelse
            return std.fmt.allocPrint(alloc, "Error: 'ping' action requires a 'target' field (hostname or IP).", .{});
        return tailscalePing(alloc, target);
    }

    return std.fmt.allocPrint(alloc, "Unknown tailscale action: '{s}'. Available: status, devices, ping", .{action});
}

/// Run `tailscale status --json` and format the output.
fn getTailscaleStatus(alloc: Allocator) ![]u8 {
    // Check if tailscale CLI is available
    const check_result = bash_tool.execute(alloc, "which tailscale 2>/dev/null") catch {
        return alloc.dupe(u8, "Tailscale CLI not found. Install from https://tailscale.com/download");
    };
    defer alloc.free(check_result);

    if (check_result.len == 0 or std.mem.indexOf(u8, check_result, "tailscale") == null) {
        return alloc.dupe(u8, "Tailscale CLI not found. Install from https://tailscale.com/download");
    }

    // Get JSON status
    const json_output = bash_tool.execute(alloc, "tailscale status --json 2>/dev/null") catch |e| {
        return std.fmt.allocPrint(alloc, "Failed to run tailscale status: {s}", .{@errorName(e)});
    };
    defer alloc.free(json_output);

    if (json_output.len == 0) {
        return alloc.dupe(u8, "Tailscale returned empty output. Is it running? Try: tailscale up");
    }

    // Also get the human-readable status for a quick overview
    const readable_output = bash_tool.execute(alloc, "tailscale status 2>/dev/null") catch {
        return alloc.dupe(u8, json_output);
    };
    defer alloc.free(readable_output);

    // Combine both outputs
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll("=== Tailscale Network Status ===\n\n");
    try w.writeAll(readable_output);
    try w.writeAll("\n\n--- Raw JSON ---\n");

    // Truncate JSON to reasonable size
    const max_json: usize = 8000;
    if (json_output.len > max_json) {
        try w.writeAll(json_output[0..max_json]);
        try std.fmt.format(w, "\n... ({d} bytes truncated)\n", .{json_output.len - max_json});
    } else {
        try w.writeAll(json_output);
    }

    return buf.toOwnedSlice(alloc);
}

/// Query Tailscale REST API for device list.
/// Requires TAILSCALE_API_KEY environment variable.
fn getTailscaleDevices(alloc: Allocator, input_json: []const u8) ![]u8 {
    _ = input_json;

    const api_key = compat.getenv("TAILSCALE_API_KEY") orelse {
        return alloc.dupe(u8,
            "TAILSCALE_API_KEY not set. To use the devices API:\n" ++
            "  1. Go to https://login.tailscale.com/admin/settings/keys\n" ++
            "  2. Generate an API access token\n" ++
            "  3. Set TAILSCALE_API_KEY in ~/.wintermolt/.env\n\n" ++
            "Alternatively, use action='status' which uses the local CLI.",
        );
    };

    // Build curl command for Tailscale API
    const curl_cmd = std.fmt.allocPrint(alloc,
        "curl -s -H \"Authorization: Bearer {s}\" " ++
        "\"https://api.tailscale.com/api/v2/tailnet/-/devices\"",
        .{api_key},
    ) catch return error.OutOfMemory;
    defer alloc.free(curl_cmd);

    const result = bash_tool.execute(alloc, curl_cmd) catch |e| {
        return std.fmt.allocPrint(alloc, "Tailscale API request failed: {s}", .{@errorName(e)});
    };

    if (result.len == 0) {
        return alloc.dupe(u8, "Tailscale API returned empty response.");
    }

    // Prepend header
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll("=== Tailscale Devices (API) ===\n\n");

    // Truncate large responses
    const max_size: usize = 12000;
    if (result.len > max_size) {
        try w.writeAll(result[0..max_size]);
        try std.fmt.format(w, "\n... ({d} bytes truncated)\n", .{result.len - max_size});
    } else {
        try w.writeAll(result);
    }

    alloc.free(result);
    return buf.toOwnedSlice(alloc);
}

/// Run `tailscale ping <target>` and return the result.
fn tailscalePing(alloc: Allocator, target: []const u8) ![]u8 {
    // Validate target — prevent command injection
    for (target) |c| {
        if (c == ';' or c == '|' or c == '&' or c == '$' or c == '`' or
            c == '\'' or c == '"' or c == '(' or c == ')' or c == '\n')
        {
            return alloc.dupe(u8, "Error: Invalid characters in target. Use a hostname or IP address.");
        }
    }

    const cmd = std.fmt.allocPrint(alloc, "tailscale ping -c 3 --timeout 5s {s} 2>&1", .{target}) catch
        return error.OutOfMemory;
    defer alloc.free(cmd);

    const result = bash_tool.execute(alloc, cmd) catch |e| {
        return std.fmt.allocPrint(alloc, "tailscale ping failed: {s}", .{@errorName(e)});
    };

    if (result.len == 0) {
        return std.fmt.allocPrint(alloc, "tailscale ping {s}: no response (timeout or unreachable)", .{target});
    }

    return result;
}
