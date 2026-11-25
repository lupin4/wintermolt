// Copyright The Fantastic Planet - By David Clabaugh
//
// workspace.zig — OpenClaw's workspace files, in the system prompt every turn
//
// WINTERMOLT_WORKSPACE_DIR, else ~/.wintermolt/workspace, holds the files
// OpenClaw injects (docs.openclaw.ai/concepts/agent-workspace):
//
//   AGENTS.md    operating instructions, how to use memory
//   SOUL.md      persona, tone, boundaries
//   USER.md      who the user is and what they want (4,000 characters at most)
//   IDENTITY.md  the agent's name, vibe, emoji
//   MEMORY.md    long-term memory: private sessions only, never a group
//
// They are read again on every turn, so an edit (or a note the agent writes
// with file_write) counts from the next one. Each file is cut at 20,000
// characters and all of them at 60,000, with a note naming what was cut. A
// missing file is left out. A sub-agent gets AGENTS.md only.

const std = @import("std");
const fsio = @import("../fsio.zig");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;

/// Who the conversation is with, which decides what it may see.
pub const Scope = enum {
    /// The local CLI, or the owner's main DM session.
    private,
    /// A group, or a DM session of its own (WINTERMOLT_CHAT_DM_SCOPE=per-peer).
    shared,
    /// A spawn_agent child.
    subagent,
};

const File = struct { name: []const u8, cap: usize };
pub const files = [_]File{
    .{ .name = "AGENTS.md", .cap = per_file_cap },
    .{ .name = "SOUL.md", .cap = per_file_cap },
    .{ .name = "USER.md", .cap = 4_000 },
    .{ .name = "IDENTITY.md", .cap = per_file_cap },
    .{ .name = "MEMORY.md", .cap = per_file_cap },
};
const per_file_cap = 20_000;
const total_cap = 60_000;

fn included(name: []const u8, scope: Scope) bool {
    return switch (scope) {
        .private => true,
        .shared => !std.mem.eql(u8, name, "MEMORY.md"),
        .subagent => std.mem.eql(u8, name, "AGENTS.md"),
    };
}

/// The workspace directory. Caller owns it; null without HOME.
pub fn dirPath(alloc: Allocator) !?[]u8 {
    if (compat.getenv("WINTERMOLT_WORKSPACE_DIR")) |d| if (d.len > 0) return try alloc.dupe(u8, d);
    const home = compat.getenv("HOME") orelse return null;
    return try std.fmt.allocPrint(alloc, "{s}/.wintermolt/workspace", .{home});
}

/// The Project Context section for `scope`, from the files in the workspace;
/// empty when there are none. Caller owns it.
pub fn load(alloc: Allocator, scope: Scope) ![]u8 {
    const dir = (try dirPath(alloc)) orelse return alloc.dupe(u8, "");
    defer alloc.free(dir);
    return loadFrom(alloc, dir, scope);
}

pub fn loadFrom(alloc: Allocator, dir: []const u8, scope: Scope) ![]u8 {
    var contents: [files.len]?[]u8 = @splat(null);
    defer for (contents) |c| if (c) |t| alloc.free(t);
    for (files, 0..) |f, i| {
        if (!included(f.name, scope)) continue;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, f.name });
        defer alloc.free(path);
        const file = fsio.openFile(path, .{}) catch continue;
        defer fsio.close(file);
        // Only the head: one byte past the cap is enough for compose to see
        // the file was cut (readToEndAlloc would refuse a big file outright).
        const size = fsio.getEndPos(file) catch continue;
        const buf = try alloc.alloc(u8, @intCast(@min(size, total_cap + 1)));
        const n = fsio.readAllAt(file, buf, 0) catch {
            alloc.free(buf);
            continue;
        };
        // n < buf.len only if the file shrank since getEndPos.
        contents[i] = if (n == buf.len) buf else alloc.realloc(buf, n) catch {
            alloc.free(buf);
            continue;
        };
    }
    var view: [files.len]?[]const u8 = undefined;
    for (contents, 0..) |c, i| view[i] = c;
    return compose(alloc, dir, &view, scope);
}

/// The section built from `contents`, in `files` order (null = no such file).
pub fn compose(alloc: Allocator, dir: []const u8, contents: *const [files.len]?[]const u8, scope: Scope) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var cut: std.ArrayList(u8) = .empty;
    defer cut.deinit(alloc);
    var left: usize = total_cap;
    var any = false;

    for (files, contents) |f, maybe| {
        const text = maybe orelse continue;
        if (!included(f.name, scope) or text.len == 0) continue;
        if (!any) {
            try w.print("\n\n# Project Context\n\nYour workspace files, from {s}. They are read every turn; to change how you work, or to remember something, edit them there.\n", .{dir});
            any = true;
        }
        const keep = utf8Prefix(text, @min(f.cap, left));
        left -= keep.len;
        try w.print("\n## {s}\n\n{s}\n", .{ f.name, keep });
        if (keep.len < text.len) {
            if (cut.items.len > 0) try cut.appendSlice(alloc, ", ");
            try cut.appendSlice(alloc, f.name);
        }
    }
    if (cut.items.len > 0)
        try w.print("\n(Some workspace files were cut to fit: {s}. Read them with file_read for the rest.)\n", .{cut.items});
    return out.toOwnedSlice();
}

/// The longest prefix of `s` no longer than `max` that ends on a UTF-8 boundary.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

const testing = std.testing;

test "compose: nothing in the workspace, nothing in the prompt" {
    const none: [files.len]?[]const u8 = @splat(null);
    const out = try compose(testing.allocator, "/ws", &none, .private);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "compose: each file under its own heading, MEMORY.md for private sessions only" {
    const c: [files.len]?[]const u8 = .{ "Be terse.", "Dry wit.", null, null, "The user likes Zig." };
    const private = try compose(testing.allocator, "/ws", &c, .private);
    defer testing.allocator.free(private);
    try testing.expect(std.mem.indexOf(u8, private, "/ws") != null);
    try testing.expect(std.mem.indexOf(u8, private, "## AGENTS.md\n\nBe terse.") != null);
    try testing.expect(std.mem.indexOf(u8, private, "## SOUL.md\n\nDry wit.") != null);
    try testing.expect(std.mem.indexOf(u8, private, "## MEMORY.md\n\nThe user likes Zig.") != null);
    try testing.expect(std.mem.indexOf(u8, private, "USER.md") == null);

    const group = try compose(testing.allocator, "/ws", &c, .shared);
    defer testing.allocator.free(group);
    try testing.expect(std.mem.indexOf(u8, group, "Be terse.") != null);
    try testing.expect(std.mem.indexOf(u8, group, "likes Zig") == null);

    const child = try compose(testing.allocator, "/ws", &c, .subagent);
    defer testing.allocator.free(child);
    try testing.expect(std.mem.indexOf(u8, child, "Be terse.") != null);
    try testing.expect(std.mem.indexOf(u8, child, "Dry wit.") == null);
}

test "compose: a file over its cap is cut, on a character boundary, and named" {
    // 3,999 ASCII bytes then a 2-byte character: the cap of 4,000 falls inside it.
    const user = "a" ** 3_999 ++ "é" ++ "tail";
    const c: [files.len]?[]const u8 = .{ null, null, user, null, null };
    const out = try compose(testing.allocator, "/ws", &c, .private);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tail") == null);
    try testing.expect(std.mem.indexOf(u8, out, "é") == null);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.indexOf(u8, out, "were cut to fit: USER.md.") != null);
}

test "loadFrom: a file larger than every cap is cut, not left out" {
    const alloc = testing.allocator;
    const dir = ".zig-cache/tmp/workspace_load_test";
    try fsio.makePath(dir);
    defer fsio.deleteTree(dir) catch {};
    {
        const f = try fsio.createFile(dir ++ "/MEMORY.md", .{});
        defer fsio.close(f);
        try fsio.writeAll(f, "~" ** 70_000);
    }
    const out = try loadFrom(alloc, dir, .private);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "## MEMORY.md") != null);
    try testing.expect(std.mem.indexOf(u8, out, "were cut to fit: MEMORY.md.") != null);
}

test "compose: the files together stop at the total cap" {
    const big = "~" ** per_file_cap; // a byte the headings and notes never use
    const c: [files.len]?[]const u8 = .{ big, big, null, big, big };
    const out = try compose(testing.allocator, "/ws", &c, .private);
    defer testing.allocator.free(out);
    var kept: usize = 0;
    for (out) |ch| kept += @intFromBool(ch == '~');
    try testing.expectEqual(@as(usize, total_cap), kept);
    try testing.expect(std.mem.indexOf(u8, out, "were cut to fit: MEMORY.md.") != null);
}
