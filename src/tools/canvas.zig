// Copyright The Fantastic Planet - By David Clabaugh
//
// canvas.zig — A2UI Canvas tool for AI agent
//
// Implements the canvas_update tool that lets the AI agent create, update,
// and delete A2UI surfaces. Routes rendering to either the TUI renderer
// (terminal mode) or the web bridge (web mode) via callback pointer.
//
// A2UI (Agent-to-UI) is Google's open protocol (Dec 2025, v0.9) where an
// AI agent streams JSONL describing platform-agnostic UI components.
// A client renderer consumes this stream and renders using native widgets.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");
const tui = @import("../canvas/tui.zig");

/// Callback for forwarding canvas messages to the web bridge.
/// Set by web/bridge.zig when in web mode.
/// Signature: fn(surface_id: []const u8, msg_json: []const u8) void
pub var web_canvas_callback: ?*const fn ([]const u8, []const u8) void = null;

/// Execute the canvas tool. Entry point matching standard tool pattern.
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const action = sse.findJsonString(input_json, "action") orelse "create";
    const surface_id = sse.findJsonString(input_json, "surface_id") orelse "main";

    if (std.mem.eql(u8, action, "create") or std.mem.eql(u8, action, "update")) {
        return handleCreateOrUpdate(alloc, surface_id, input_json);
    } else if (std.mem.eql(u8, action, "delete")) {
        return handleDelete(alloc, surface_id, input_json);
    }

    return std.fmt.allocPrint(alloc, "Unknown canvas action: '{s}'. Available: create, update, delete", .{action});
}

fn handleCreateOrUpdate(alloc: Allocator, surface_id: []const u8, input_json: []const u8) ![]u8 {
    // Forward to web bridge if in web mode
    if (web_canvas_callback) |cb| {
        cb(surface_id, input_json);
        return std.fmt.allocPrint(alloc, "Canvas surface '{s}' sent to web UI.", .{surface_id});
    }

    // Terminal mode: render with TUI
    const rendered = tui.renderSurface(alloc, input_json) catch |e| {
        return std.fmt.allocPrint(alloc, "Canvas TUI render error: {s}", .{@errorName(e)});
    };

    // Print to stdout for the user to see
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.writeByte('\n') catch {};
    stdout.writeAll(rendered) catch {};
    stdout.writeByte('\n') catch {};

    return std.fmt.allocPrint(alloc, "Canvas surface '{s}' rendered to terminal ({d} chars).", .{ surface_id, rendered.len });
}

fn handleDelete(alloc: Allocator, surface_id: []const u8, input_json: []const u8) ![]u8 {
    // Forward delete to web bridge if in web mode
    if (web_canvas_callback) |cb| {
        cb(surface_id, input_json);
    }

    return std.fmt.allocPrint(alloc, "Canvas surface '{s}' deleted.", .{surface_id});
}
