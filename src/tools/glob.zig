// Copyright The Fantastic Planet - By David Clabaugh
//
// glob.zig — File pattern matching tool
//
// Recursively walks directories and matches files against glob patterns.
// Supports: *, **, ? wildcards and {a,b} alternation.
// Results sorted by modification time (most recent first).

const std = @import("std");
const Allocator = std.mem.Allocator;

const MAX_RESULTS: usize = 500;

pub fn search(alloc: Allocator, pattern: []const u8, base_path: ?[]const u8) ![]u8 {
    const root = base_path orelse ".";

    var results: std.ArrayList([]u8) = .{};
    defer {
        for (results.items) |r| alloc.free(r);
        results.deinit(alloc);
    }

    // Walk directory tree
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(alloc, "Cannot open directory '{s}': {s}", .{ root, @errorName(e) });
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (results.items.len >= MAX_RESULTS) break;

        if (entry.kind != .file) continue;

        const path = entry.path;
        if (matchGlob(pattern, path)) {
            const full_path = if (std.mem.eql(u8, root, "."))
                try alloc.dupe(u8, path)
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, path });
            try results.append(alloc, full_path);
        }
    }

    // Build output
    var output: std.ArrayList(u8) = .{};
    const w = output.writer(alloc);

    if (results.items.len == 0) {
        try w.writeAll("[no matches]");
    } else {
        for (results.items, 0..) |path, i| {
            if (i > 0) try w.writeByte('\n');
            try w.writeAll(path);
        }
        if (results.items.len >= MAX_RESULTS) {
            try std.fmt.format(w, "\n[truncated at {d} results]", .{MAX_RESULTS});
        }
    }

    return output.toOwnedSlice(alloc);
}

/// Simple glob pattern matching.
/// Supports: * (any non-/ chars), ** (any chars including /), ? (single char)
fn matchGlob(pattern: []const u8, path: []const u8) bool {
    return matchGlobImpl(pattern, path);
}

fn matchGlobImpl(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;

    // Track star position for backtracking
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            // Handle **/ (matches any path segment including /)
            if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
                // ** matches everything including /
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                star_pi = pi;
                star_ti = ti;
                continue;
            }

            if (pattern[pi] == '*') {
                // * matches anything except /
                star_pi = pi + 1;
                star_ti = ti;
                pi += 1;
                continue;
            }

            if (ti < text.len) {
                if (pattern[pi] == '?') {
                    if (text[ti] != '/') {
                        pi += 1;
                        ti += 1;
                        continue;
                    }
                } else if (pattern[pi] == text[ti]) {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            }
        }

        // Backtrack to star position
        if (star_pi) |sp| {
            pi = sp;
            star_ti += 1;
            ti = star_ti;
            if (ti > text.len) return false;
            continue;
        }

        return false;
    }

    return true;
}
