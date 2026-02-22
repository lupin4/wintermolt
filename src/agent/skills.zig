// Copyright The Fantastic Planet - By David Clabaugh
//
// skills.zig — Modular skill registry for Wintermolt
//
// Provides a browsable catalog of all tool capabilities. Instead of listing
// every tool's details in the system prompt (which wastes tokens per API call),
// skills are queryable on-demand via the `skills` tool.
//
// The registry uses comptime string literals — zero allocation, zero I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SkillEntry = struct {
    name: []const u8,
    category: []const u8,
    short_desc: []const u8,
    full_desc: []const u8,
    operations: []const u8,
};

/// Built-in skill catalog — core tools organized by category.
pub const skills = [_]SkillEntry{
    // --- system ---
    .{
        .name = "bash",
        .category = "system",
        .short_desc = "Run shell commands",
        .full_desc = "Execute any shell command and return stdout/stderr. Use for git, system administration, running programs, installing packages.",
        .operations = "execute: run a shell command string",
    },
    .{
        .name = "file_read",
        .category = "system",
        .short_desc = "Read file contents",
        .full_desc = "Read a file and return numbered lines. Supports offset/limit for large files (useful for reading specific sections).",
        .operations = "read: path, optional offset (line number) and limit (max lines)",
    },
    .{
        .name = "file_write",
        .category = "system",
        .short_desc = "Create or overwrite files",
        .full_desc = "Write content to a file, creating it if it doesn't exist or overwriting if it does.",
        .operations = "write: path + content",
    },
    .{
        .name = "file_edit",
        .category = "system",
        .short_desc = "Surgical text replacement in files",
        .full_desc = "Find a unique string in a file and replace it. The old_string must appear exactly once. Safer than full file rewrites.",
        .operations = "edit: path + old_string + new_string (old_string must be unique)",
    },
    .{
        .name = "glob",
        .category = "system",
        .short_desc = "Find files by pattern",
        .full_desc = "Recursive file search with glob patterns. Supports *, **, ? wildcards. Returns matching file paths.",
        .operations = "search: pattern (e.g. '**/*.zig'), optional base path",
    },
    .{
        .name = "grep",
        .category = "system",
        .short_desc = "Search file contents",
        .full_desc = "Search for text patterns in files. Returns matching lines with file paths and line numbers. Supports case-insensitive mode.",
        .operations = "search: pattern, optional path, optional case_insensitive flag",
    },
    .{
        .name = "http_request",
        .category = "system",
        .short_desc = "Make HTTP requests",
        .full_desc = "Call any URL with GET/POST/PUT/DELETE/HEAD. Returns status, headers, body. Follows redirects (5 max), 30s timeout, body truncated to 30KB. Custom headers supported.",
        .operations = "request: url + method + optional body + optional headers",
    },
    .{
        .name = "web_search",
        .category = "system",
        .short_desc = "Search the web via DuckDuckGo",
        .full_desc = "Search the web using DuckDuckGo's HTML endpoint. No API key needed, no JavaScript, no bot blocking. Returns titles, URLs, and snippets for top results.",
        .operations = "search: query string + optional num_results (1-20, default 8)",
    },
    .{
        .name = "memory_search",
        .category = "system",
        .short_desc = "Search past conversations and semantic memory",
        .full_desc = "Search across SQLite conversation history (text match) and Pinecone RAG (semantic similarity). Use to recall what was discussed, facts the user shared, preferences, and previous interactions.",
        .operations = "search: query string + optional top_k (1-20, default 5)",
    },
    // --- media ---
    .{
        .name = "camera_capture",
        .category = "media",
        .short_desc = "Capture from system camera",
        .full_desc = "Take a photo from the system camera. Returns image as a vision content block (you can see it). Saved to /tmp/wintermolt_capture.jpg for chaining to image_process. Requires imagesnap on macOS.",
        .operations = "capture: take photo (optional device name)\nlist_devices: show available cameras",
    },
    .{
        .name = "image_process",
        .category = "media",
        .short_desc = "Image processing (read/write BMP, sips/ffmpeg bridge)",
        .full_desc = "Read and write BMP images. For advanced format support (JPEG/PNG/TIFF), uses sips (macOS) or ffmpeg as a bridge for format conversion.",
        .operations = "Process images via external tools (sips for macOS, ffmpeg for Linux)",
    },
    // --- automation ---
    .{
        .name = "browser_control",
        .category = "automation",
        .short_desc = "Chrome browser automation via CDP",
        .full_desc = "Control Chrome/Chromium via Chrome DevTools Protocol (CDP). Requires Chrome running with --remote-debugging-port=9222. Manages tabs, navigates pages, captures screenshots, extracts content, clicks elements, types text, and evaluates JavaScript.",
        .operations = "list_tabs: list all open browser tabs\nnew_tab: open URL in new tab\nclose_tab: close a tab by ID\nnavigate: go to URL in a tab\nsnapshot: get page text content (accessibility tree)\nclick: click element by CSS selector\ntype_text: type into element by CSS selector\nevaluate: execute JavaScript expression\nscreenshot: capture page as base64 PNG",
    },
    // --- meta ---
    .{
        .name = "skills",
        .category = "meta",
        .short_desc = "Browse available tool capabilities",
        .full_desc = "Query this skill catalog. Use 'list' to see all tools with short descriptions, or 'detail' with a skill name to get full documentation and available operations.",
        .operations = "list: show all skills with short descriptions\ndetail: get full description + operations for a specific skill",
    },
};

/// List all skills with short descriptions (for the `list` operation).
pub fn listSkills(alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const writer = buf.writer(alloc);
    try writer.writeAll("# Wintermolt Skill Catalog\n\n");

    var current_cat: []const u8 = "";
    for (&skills) |*s| {
        if (!std.mem.eql(u8, s.category, current_cat)) {
            current_cat = s.category;
            try writer.print("\n## {s}\n", .{current_cat});
        }
        try writer.print("  {s} — {s}\n", .{ s.name, s.short_desc });
    }

    try writer.print("\nUse skills tool with operation='detail' and name='<skill>' for full docs.\n", .{});
    return try alloc.dupe(u8, buf.items);
}

/// Get detailed info for a specific skill (for the `detail` operation).
pub fn getSkillDetail(alloc: Allocator, name: []const u8) ![]u8 {
    for (&skills) |*s| {
        if (std.mem.eql(u8, s.name, name)) {
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(alloc);

            const writer = buf.writer(alloc);
            try writer.print("# {s}\n", .{s.name});
            try writer.print("Category: {s}\n\n", .{s.category});
            try writer.print("{s}\n\n", .{s.full_desc});
            try writer.print("## Operations\n{s}\n", .{s.operations});
            return try alloc.dupe(u8, buf.items);
        }
    }
    return try std.fmt.allocPrint(alloc, "Unknown skill: '{s}'. Use operation='list' to see available skills.", .{name});
}
