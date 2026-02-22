// Copyright The Fantastic Planet - By David Clabaugh
//
// tui.zig — Terminal A2UI renderer
//
// Parses A2UI JSONL messages (subset of v0.9 spec) and renders them to
// stdout using ANSI escape codes + Unicode box-drawing characters.
//
// Supported A2UI components:
//   Text    → plain text output
//   Column  → vertical layout with │ border
//   Row     → horizontal layout with ─ border
//   Button  → [ Label ] with highlight
//   Table   → formatted table with ┌─┬─┐ borders
//   Code    → code block with background
//   Image   → [Image: description] placeholder
//
// This is a subset — the web renderer handles the full A2UI spec.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");

/// Render an A2UI surface from the input JSON. Returns formatted ANSI string.
/// The input_json contains the full canvas_update tool input with "components"
/// and optional "data" fields.
pub fn renderSurface(alloc: Allocator, input_json: []const u8) ![]u8 {
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    // Extract title if present
    const title = sse.findJsonString(input_json, "title");

    // Render top border
    try w.writeAll("\x1b[36m┌");
    const title_text = title orelse "Canvas";
    const width: usize = @max(title_text.len + 4, 60);
    for (0..width) |_| try w.writeAll("─");
    try w.writeAll("┐\x1b[0m\n");

    // Title bar
    try w.writeAll("\x1b[36m│\x1b[0m \x1b[1;37m");
    try w.writeAll(title_text);
    try w.writeAll("\x1b[0m");
    const title_pad = width - title_text.len;
    for (0..title_pad) |_| try w.writeByte(' ');
    try w.writeAll("\x1b[36m│\x1b[0m\n");

    // Separator
    try w.writeAll("\x1b[36m├");
    for (0..width) |_| try w.writeAll("─");
    try w.writeAll("┤\x1b[0m\n");

    // Parse and render components from the JSON
    // We use a simple approach: scan for component type strings and render them
    try renderComponents(alloc, w, input_json, width);

    // Bottom border
    try w.writeAll("\x1b[36m└");
    for (0..width) |_| try w.writeAll("─");
    try w.writeAll("┘\x1b[0m\n");

    return buf.toOwnedSlice(alloc);
}

fn renderComponents(alloc: Allocator, w: anytype, json: []const u8, width: usize) !void {
    _ = alloc;

    // Scan for "type":"<component>" patterns in the JSON
    var pos: usize = 0;

    while (pos < json.len) {
        // Find next "type":"
        const type_needle = "\"type\":\"";
        const type_start = std.mem.indexOf(u8, json[pos..], type_needle) orelse break;
        const abs_start = pos + type_start + type_needle.len;

        // Find closing quote for the type value
        const type_end = std.mem.indexOfScalar(u8, json[abs_start..], '"') orelse break;
        const component_type = json[abs_start .. abs_start + type_end];

        // Advance past this type declaration
        pos = abs_start + type_end + 1;

        // Render based on component type
        if (std.mem.eql(u8, component_type, "text") or std.mem.eql(u8, component_type, "Text")) {
            try renderText(w, json[pos..], width);
        } else if (std.mem.eql(u8, component_type, "button") or std.mem.eql(u8, component_type, "Button")) {
            try renderButton(w, json[pos..], width);
        } else if (std.mem.eql(u8, component_type, "code") or std.mem.eql(u8, component_type, "Code")) {
            try renderCode(w, json[pos..], width);
        } else if (std.mem.eql(u8, component_type, "table") or std.mem.eql(u8, component_type, "Table")) {
            try renderTable(w, json[pos..], width);
        } else if (std.mem.eql(u8, component_type, "image") or std.mem.eql(u8, component_type, "Image")) {
            try renderImage(w, json[pos..], width);
        } else if (std.mem.eql(u8, component_type, "divider") or std.mem.eql(u8, component_type, "Divider")) {
            try renderDivider(w, width);
        } else if (std.mem.eql(u8, component_type, "heading") or std.mem.eql(u8, component_type, "Heading")) {
            try renderHeading(w, json[pos..], width);
        }
        // Column/Row are layout containers — we render their children recursively
        // For the TUI, we just render children sequentially (vertical stacking)
    }
}

fn renderText(w: anytype, context: []const u8, width: usize) !void {
    const value = findNearbyString(context, "value") orelse
        findNearbyString(context, "content") orelse
        findNearbyString(context, "text") orelse return;

    try w.writeAll("\x1b[36m│\x1b[0m ");
    try renderWrapped(w, value, width - 1);
    try w.writeAll("\x1b[36m│\x1b[0m\n");
}

fn renderButton(w: anytype, context: []const u8, width: usize) !void {
    const label = findNearbyString(context, "label") orelse
        findNearbyString(context, "text") orelse "Button";

    try w.writeAll("\x1b[36m│\x1b[0m  \x1b[7;37m [ ");
    try w.writeAll(label);
    try w.writeAll(" ] \x1b[0m");
    const pad = if (label.len + 7 < width) width - label.len - 7 else 0;
    for (0..pad) |_| try w.writeByte(' ');
    try w.writeAll("\x1b[36m│\x1b[0m\n");
}

fn renderCode(w: anytype, context: []const u8, width: usize) !void {
    const code = findNearbyString(context, "value") orelse
        findNearbyString(context, "content") orelse
        findNearbyString(context, "code") orelse return;
    const lang = findNearbyString(context, "language") orelse "";

    if (lang.len > 0) {
        try w.writeAll("\x1b[36m│\x1b[0m \x1b[90m");
        try w.writeAll(lang);
        try w.writeAll(":\x1b[0m");
        const hpad = if (lang.len + 2 < width) width - lang.len - 2 else 0;
        for (0..hpad) |_| try w.writeByte(' ');
        try w.writeAll("\x1b[36m│\x1b[0m\n");
    }

    // Code content with dark background
    try w.writeAll("\x1b[36m│\x1b[0m \x1b[48;5;236m");

    // Render code lines (handle escaped \n)
    var i: usize = 0;
    var line_len: usize = 0;
    while (i < code.len) {
        if (i + 1 < code.len and code[i] == '\\' and code[i + 1] == 'n') {
            // Pad to width
            while (line_len < width - 1) : (line_len += 1) try w.writeByte(' ');
            try w.writeAll("\x1b[0m\x1b[36m│\x1b[0m\n\x1b[36m│\x1b[0m \x1b[48;5;236m");
            line_len = 0;
            i += 2;
        } else {
            try w.writeByte(code[i]);
            line_len += 1;
            i += 1;
        }
    }
    // Pad final line
    while (line_len < width - 1) : (line_len += 1) try w.writeByte(' ');
    try w.writeAll("\x1b[0m\x1b[36m│\x1b[0m\n");
}

fn renderTable(w: anytype, context: []const u8, width: usize) !void {
    _ = context;
    // Simple table placeholder — full parsing requires JSON array handling
    try w.writeAll("\x1b[36m│\x1b[0m \x1b[90m[Table: see web UI for full rendering]\x1b[0m");
    const pad = if (width > 42) width - 42 else 0;
    for (0..pad) |_| try w.writeByte(' ');
    try w.writeAll("\x1b[36m│\x1b[0m\n");
}

fn renderImage(w: anytype, context: []const u8, width: usize) !void {
    const alt = findNearbyString(context, "alt") orelse
        findNearbyString(context, "description") orelse "image";

    try w.writeAll("\x1b[36m│\x1b[0m \x1b[33m[Image: ");
    try w.writeAll(alt);
    try w.writeAll("]\x1b[0m");
    const used = alt.len + 10;
    const pad = if (used < width) width - used else 0;
    for (0..pad) |_| try w.writeByte(' ');
    try w.writeAll("\x1b[36m│\x1b[0m\n");
}

fn renderDivider(w: anytype, width: usize) !void {
    try w.writeAll("\x1b[36m├");
    for (0..width) |_| try w.writeAll("─");
    try w.writeAll("┤\x1b[0m\n");
}

fn renderHeading(w: anytype, context: []const u8, width: usize) !void {
    const text = findNearbyString(context, "value") orelse
        findNearbyString(context, "text") orelse return;

    try w.writeAll("\x1b[36m│\x1b[0m \x1b[1;33m");
    try w.writeAll(text);
    try w.writeAll("\x1b[0m");
    const pad = if (text.len + 1 < width) width - text.len - 1 else 0;
    for (0..pad) |_| try w.writeByte(' ');
    try w.writeAll("\x1b[36m│\x1b[0m\n");
}

/// Render text with word wrapping within a bordered box.
fn renderWrapped(w: anytype, text: []const u8, max_width: usize) !void {
    var col: usize = 0;
    for (text) |c| {
        if (col >= max_width - 2) {
            try w.writeAll("\x1b[36m│\x1b[0m\n\x1b[36m│\x1b[0m ");
            col = 0;
        }
        try w.writeByte(c);
        col += 1;
    }
    // Pad to width
    while (col < max_width - 1) : (col += 1) try w.writeByte(' ');
}

/// Find a JSON string value near the current position.
/// Simple scan for "key":"value" within the next 500 chars.
fn findNearbyString(context: []const u8, key: []const u8) ?[]const u8 {
    const search_range = @min(context.len, 500);
    const slice = context[0..search_range];

    // Build needle: "key":"
    var needle_buf: [270]u8 = undefined;
    if (key.len + 4 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    needle_buf[3 + key.len] = '"';
    const needle = needle_buf[0 .. 4 + key.len];

    const start = std.mem.indexOf(u8, slice, needle) orelse return null;
    const value_start = start + needle.len;

    // Find closing quote (handle escaped quotes)
    var i = value_start;
    while (i < slice.len) {
        if (slice[i] == '"' and (i == 0 or slice[i - 1] != '\\')) {
            return slice[value_start..i];
        }
        i += 1;
    }
    return null;
}
