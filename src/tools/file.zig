// Copyright The Fantastic Planet - By David Clabaugh
//
// file.zig — File operation tools (read, write, edit)
//
// file_read:  Read file contents with optional offset/limit
// file_write: Create/overwrite file with content
// file_edit:  Find-and-replace within a file

const std = @import("std");
const Allocator = std.mem.Allocator;

const MAX_FILE_SIZE: usize = 1_000_000; // 1MB read limit

/// Read a file, optionally with line offset and limit.
pub fn readFile(alloc: Allocator, path: []const u8, offset: ?usize, limit: ?usize) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        return formatError(alloc, "Cannot open file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close();

    const contents = file.readToEndAlloc(alloc, MAX_FILE_SIZE) catch |e| {
        return formatError(alloc, "Cannot read file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer alloc.free(contents);

    // Apply line offset and limit
    const start_line = offset orelse 0;
    const max_lines = limit orelse std.math.maxInt(usize);

    var result: std.ArrayList(u8) = .{};
    const w = result.writer(alloc);

    var line_num: usize = 0;
    var lines_written: usize = 0;
    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |line| {
        line_num += 1;
        if (line_num <= start_line) continue;
        if (lines_written >= max_lines) break;

        try std.fmt.format(w, "{d:>6}\t{s}\n", .{ line_num, line });
        lines_written += 1;
    }

    if (result.items.len == 0) {
        try w.writeAll("[empty file]");
    }

    return result.toOwnedSlice(alloc);
}

/// Write content to a file (creates or overwrites).
pub fn writeFile(alloc: Allocator, path: []const u8, content: []const u8) ![]u8 {
    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |e| {
        return formatError(alloc, "Cannot create file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close();

    file.writeAll(content) catch |e| {
        return formatError(alloc, "Cannot write to '{s}': {s}", .{ path, @errorName(e) });
    };

    return std.fmt.allocPrint(alloc, "Wrote {d} bytes to {s}", .{ content.len, path });
}

/// Edit a file by replacing old_string with new_string.
pub fn editFile(alloc: Allocator, path: []const u8, old_string: []const u8, new_string: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        return formatError(alloc, "Cannot open file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer file.close();

    const contents = file.readToEndAlloc(alloc, MAX_FILE_SIZE) catch |e| {
        return formatError(alloc, "Cannot read file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer alloc.free(contents);

    // Find the old string
    const pos = std.mem.indexOf(u8, contents, old_string) orelse {
        return formatError(alloc, "String not found in '{s}'", .{path});
    };

    // Check for uniqueness — the old_string should appear only once
    if (std.mem.indexOf(u8, contents[pos + old_string.len..], old_string) != null) {
        return formatError(alloc, "String appears multiple times in '{s}'. Provide more context to make it unique.", .{path});
    }

    // Build replacement
    const new_contents = try alloc.alloc(u8, contents.len - old_string.len + new_string.len);
    defer alloc.free(new_contents);

    @memcpy(new_contents[0..pos], contents[0..pos]);
    @memcpy(new_contents[pos .. pos + new_string.len], new_string);
    @memcpy(new_contents[pos + new_string.len ..], contents[pos + old_string.len ..]);

    // Write back
    const out_file = std.fs.cwd().createFile(path, .{}) catch |e| {
        return formatError(alloc, "Cannot write file '{s}': {s}", .{ path, @errorName(e) });
    };
    defer out_file.close();

    out_file.writeAll(new_contents) catch |e| {
        return formatError(alloc, "Write failed for '{s}': {s}", .{ path, @errorName(e) });
    };

    return std.fmt.allocPrint(alloc, "Edited {s}: replaced {d} bytes with {d} bytes", .{
        path, old_string.len, new_string.len,
    });
}

fn formatError(alloc: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(alloc, fmt, args);
}
