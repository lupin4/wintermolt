// Copyright The Fantastic Planet - By David Clabaugh
//
// grep.zig — File content search tool
//
// Searches file contents line-by-line for substring matches.
// Supports recursive directory search with optional file type filtering.
// Returns matching lines with file paths and line numbers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MAX_FILE_SIZE: usize = 1_000_000;
const MAX_RESULTS: usize = 200;

pub fn search(
    alloc: Allocator,
    pattern: []const u8,
    path: ?[]const u8,
    case_insensitive: bool,
) ![]u8 {
    const root = path orelse ".";

    var results: std.ArrayList(u8) = .{};
    const w = results.writer(alloc);
    var match_count: usize = 0;

    // Check if root is a file or directory
    const stat = std.fs.cwd().statFile(root) catch {
        return std.fmt.allocPrint(alloc, "Cannot access '{s}'", .{root});
    };

    if (stat.kind == .file) {
        try searchFile(alloc, root, pattern, case_insensitive, w, &match_count);
    } else {
        var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| {
            return std.fmt.allocPrint(alloc, "Cannot open directory '{s}': {s}", .{ root, @errorName(e) });
        };
        defer dir.close();

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (match_count >= MAX_RESULTS) break;
            if (entry.kind != .file) continue;

            // Skip binary-looking files and common non-text dirs
            if (shouldSkip(entry.path)) continue;

            const full_path = if (std.mem.eql(u8, root, "."))
                entry.path
            else blk: {
                // We need to construct the full path
                break :blk entry.path;
            };

            const abs_path = if (std.mem.eql(u8, root, "."))
                try alloc.dupe(u8, full_path)
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, full_path });
            defer alloc.free(abs_path);

            searchFile(alloc, abs_path, pattern, case_insensitive, w, &match_count) catch continue;
        }
    }

    if (match_count == 0) {
        try w.writeAll("[no matches]");
    } else if (match_count >= MAX_RESULTS) {
        try std.fmt.format(w, "\n[truncated at {d} matches]", .{MAX_RESULTS});
    }

    return results.toOwnedSlice(alloc);
}

fn searchFile(
    alloc: Allocator,
    file_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    w: anytype,
    match_count: *usize,
) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return;
    defer file.close();

    const contents = file.readToEndAlloc(alloc, MAX_FILE_SIZE) catch return;
    defer alloc.free(contents);

    // Prepare case-insensitive pattern if needed
    const search_pattern = if (case_insensitive)
        try toLower(alloc, pattern)
    else
        try alloc.dupe(u8, pattern);
    defer alloc.free(search_pattern);

    var line_num: usize = 0;
    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |line| {
        if (match_count.* >= MAX_RESULTS) return;
        line_num += 1;

        const search_line = if (case_insensitive)
            toLower(alloc, line) catch continue
        else
            alloc.dupe(u8, line) catch continue;
        defer alloc.free(search_line);

        if (std.mem.indexOf(u8, search_line, search_pattern) != null) {
            try std.fmt.format(w, "{s}:{d}:{s}\n", .{
                file_path,
                line_num,
                if (line.len > 200) line[0..200] else line,
            });
            match_count.* += 1;
        }
    }
}

fn toLower(alloc: Allocator, s: []const u8) ![]u8 {
    const result = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}

fn shouldSkip(path: []const u8) bool {
    // Skip hidden dirs and common non-text directories
    if (std.mem.indexOf(u8, path, "/.") != null) return true;
    if (std.mem.indexOf(u8, path, "node_modules/") != null) return true;
    if (std.mem.indexOf(u8, path, ".git/") != null) return true;
    if (std.mem.indexOf(u8, path, "zig-cache/") != null) return true;
    if (std.mem.indexOf(u8, path, "zig-out/") != null) return true;

    // Skip binary file extensions
    const binary_exts = [_][]const u8{
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico",
        ".zip", ".tar", ".gz",  ".bz2", ".xz",
        ".exe", ".dll", ".so",  ".dylib", ".a", ".o",
        ".wasm", ".pdf", ".mp3", ".mp4",  ".wav",
    };
    for (binary_exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }

    return false;
}
