// Copyright The Fantastic Planet - By David Clabaugh
//
// banner.zig -- the startup banner: WINTERMOLT in front of Villa Straylight.
//
// The art is generated, not drawn here: docs/ANSI_art/wintermolt/
// generate_banner.py turns villa-straylight.png into src/banner/*.txt plus a
// matching *.roles file. A role names the theme slot that colors a character
// (A accent, P primary, S secondary, F foreground, M muted, W warning, ' ' a
// space), so the plain REPL can paint it in the terminal's 16 colors and the
// full-screen view in the active theme's, and both follow the user's palette.
//
// Three sizes, largest first; pick() takes the largest that fits:
//   full      the name, the ship and its planet
//   wordmark  the name alone
//   tiny      one line
//
// Pure: no I/O and no zortui. Its tests run as their own root in build.zig.

const std = @import("std");

pub const Art = struct {
    name: []const u8,
    /// Lines joined by '\n', no trailing newline. ASCII: a byte is a column.
    text: []const u8,
    /// One role per byte of `text`, same line breaks.
    roles: []const u8,
    width: usize,
    height: usize,
};

fn embed(comptime name: []const u8, comptime text_file: []const u8, comptime roles_file: []const u8) Art {
    @setEvalBranchQuota(100_000);
    const text = std.mem.trimEnd(u8, text_file, "\n");
    var width: usize = 0;
    var height: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        width = @max(width, line.len);
        height += 1;
    }
    return .{ .name = name, .text = text, .roles = std.mem.trimEnd(u8, roles_file, "\n"), .width = width, .height = height };
}

pub const full = embed("full", @embedFile("banner/straylight.txt"), @embedFile("banner/straylight.roles"));
pub const wordmark = embed("wordmark", @embedFile("banner/wordmark.txt"), @embedFile("banner/wordmark.roles"));
pub const tiny = embed("tiny", " WINTERMOLT", " AAAPPPPSSS");

/// The largest banner that fits in `cols` x `rows`. tiny always "fits": a
/// window too narrow even for it wraps one short line, which is still readable.
pub fn pick(cols: usize, rows: usize) *const Art {
    for ([_]*const Art{ &full, &wordmark }) |art| {
        if (cols >= art.width and rows >= art.height) return art;
    }
    return &tiny;
}

pub const Size = struct { columns: usize, rows: usize };

pub const Choice = struct { art: *const Art, color: bool };

/// What the plain REPL prints. `size` is null when stdout is not a terminal;
/// `color` is false for NO_COLOR, TERM=dumb or a redirected stdout. Either way
/// the lettering, uncolored. Otherwise the largest banner that fits with a
/// spare column (no wrap at the right margin) and four rows to spare for the
/// version line, the help line, a blank line and the prompt.
pub fn forPlain(size: ?Size, color: bool) Choice {
    const s = size orelse return .{ .art = &wordmark, .color = false };
    if (!color) return .{ .art = &wordmark, .color = false };
    return .{ .art = pick(s.columns -| 1, s.rows -| 4), .color = true };
}

/// Color only on a terminal, and not under NO_COLOR (when set non-empty, per
/// no-color.org) or TERM=dumb.
pub fn colorWanted(stdout_is_terminal: bool, no_color: ?[]const u8, term: ?[]const u8) bool {
    if (!stdout_is_terminal) return false;
    if (no_color) |v| if (v.len > 0) return false;
    if (term) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return true;
}

pub fn write(w: *std.Io.Writer, choice: Choice) !void {
    if (choice.color) return writeAnsi(w, choice.art);
    try w.writeAll(choice.art.text);
    try w.writeByte('\n');
}

/// The art in the terminal's own 16 colors, so it takes on the user's scheme.
/// A code goes out only when the role changes; spaces keep whatever is set,
/// since they paint nothing.
pub fn writeAnsi(w: *std.Io.Writer, art: *const Art) !void {
    var t = std.mem.splitScalar(u8, art.text, '\n');
    var r = std.mem.splitScalar(u8, art.roles, '\n');
    while (t.next()) |tl| {
        const rl = r.next() orelse "";
        var current: u8 = ' ';
        for (tl, 0..) |c, i| {
            const role = if (i < rl.len) rl[i] else ' ';
            if (role != ' ' and role != current) {
                if (roleOf(role)) |slot| try w.writeAll(sgr(slot));
                current = role;
            }
            try w.writeByte(c);
        }
        if (current != ' ') try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
    }
}

/// The theme slot a character takes its color from.
pub const Role = enum { accent, primary, secondary, foreground, muted, warning };

pub fn roleOf(byte: u8) ?Role {
    return switch (byte) {
        'A' => .accent,
        'P' => .primary,
        'S' => .secondary,
        'F' => .foreground,
        'M' => .muted,
        'W' => .warning,
        else => null,
    };
}

/// The 16-color code for each slot. These are the palette indices the
/// "terminal" theme (theme_pref.zig) gives the same slots, so plain mode and
/// the full-screen view paint the banner alike.
fn sgr(role: Role) []const u8 {
    return switch (role) {
        .accent => "\x1b[36m",
        .primary => "\x1b[34m",
        .secondary => "\x1b[35m",
        .foreground => "\x1b[39m",
        .muted => "\x1b[90m",
        .warning => "\x1b[33m",
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "every banner's roles line up with its characters" {
    // A misaligned or CRLF-converted .roles file colors the wrong characters.
    for ([_]*const Art{ &full, &wordmark, &tiny }) |art| {
        var t = std.mem.splitScalar(u8, art.text, '\n');
        var r = std.mem.splitScalar(u8, art.roles, '\n');
        while (t.next()) |tl| {
            const rl = r.next() orelse return error.RolesShort;
            try testing.expectEqual(tl.len, rl.len);
            for (tl, rl) |c, role| {
                try testing.expect(c < 0x80);
                try testing.expectEqual(c == ' ', role == ' ');
                try testing.expect(std.mem.indexOfScalar(u8, " APSFMW", role) != null);
            }
        }
        try testing.expect(r.next() == null);
    }
}

test "pick: the largest banner that fits, down to one line" {
    // full is 75x26 and the wordmark 63x5, counted from src/banner/.
    const cases = [_]struct { cols: usize, rows: usize, want: []const u8 }{
        .{ .cols = 200, .rows = 60, .want = "full" },
        .{ .cols = 75, .rows = 26, .want = "full" },
        .{ .cols = 74, .rows = 26, .want = "wordmark" },
        .{ .cols = 75, .rows = 25, .want = "wordmark" },
        .{ .cols = 63, .rows = 5, .want = "wordmark" },
        .{ .cols = 62, .rows = 40, .want = "tiny" },
        .{ .cols = 63, .rows = 4, .want = "tiny" },
        .{ .cols = 0, .rows = 0, .want = "tiny" },
    };
    for (cases) |c| try testing.expectEqualStrings(c.want, pick(c.cols, c.rows).name);
}

test "forPlain: the full banner when it fits with the lines under it; piped or NO_COLOR get the plain lettering" {
    // The plain REPL keeps a spare column against wrapping, and four rows for
    // the version line, the help line, a blank line and the prompt.
    const cases = [_]struct { size: ?Size, color: bool, want: []const u8, want_color: bool }{
        .{ .size = .{ .columns = 80, .rows = 30 }, .color = true, .want = "full", .want_color = true },
        .{ .size = .{ .columns = 76, .rows = 30 }, .color = true, .want = "full", .want_color = true },
        .{ .size = .{ .columns = 75, .rows = 30 }, .color = true, .want = "wordmark", .want_color = true },
        .{ .size = .{ .columns = 80, .rows = 29 }, .color = true, .want = "wordmark", .want_color = true },
        .{ .size = .{ .columns = 40, .rows = 40 }, .color = true, .want = "tiny", .want_color = true },
        .{ .size = .{ .columns = 200, .rows = 60 }, .color = false, .want = "wordmark", .want_color = false },
        .{ .size = null, .color = true, .want = "wordmark", .want_color = false },
        .{ .size = null, .color = false, .want = "wordmark", .want_color = false },
    };
    for (cases) |c| {
        const got = forPlain(c.size, c.color);
        try testing.expectEqualStrings(c.want, got.art.name);
        try testing.expectEqual(c.want_color, got.color);
    }
}

test "writeAnsi: one color code per change of role, none for spaces, reset at each line end" {
    const art: Art = .{ .name = "t", .text = "ab c\n.", .roles = "AP M\nW", .width = 4, .height = 2 };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeAnsi(&out.writer, &art);
    try testing.expectEqualStrings("\x1b[36ma\x1b[34mb \x1b[90mc\x1b[0m\n\x1b[33m.\x1b[0m\n", out.written());
}

test "write: without color the bytes are the art's text and nothing else" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .art = &wordmark, .color = false });
    try testing.expect(std.mem.indexOfScalar(u8, out.written(), 0x1b) == null);
    try testing.expectEqualStrings(wordmark.text, std.mem.trimEnd(u8, out.written(), "\n"));
}

test "colorWanted: a terminal gets color unless NO_COLOR is set non-empty or TERM is dumb" {
    // no-color.org: NO_COLOR counts when present and not an empty string.
    const cases = [_]struct { tty: bool, no_color: ?[]const u8, term: ?[]const u8, want: bool }{
        .{ .tty = true, .no_color = null, .term = "xterm-256color", .want = true },
        .{ .tty = true, .no_color = null, .term = null, .want = true },
        .{ .tty = true, .no_color = "", .term = null, .want = true },
        .{ .tty = true, .no_color = "1", .term = null, .want = false },
        .{ .tty = true, .no_color = null, .term = "dumb", .want = false },
        .{ .tty = false, .no_color = null, .term = "xterm", .want = false },
    };
    for (cases) |c| try testing.expectEqual(c.want, colorWanted(c.tty, c.no_color, c.term));
}

test "roleOf: each role byte names its theme slot; a space has none" {
    try testing.expectEqual(Role.accent, roleOf('A').?);
    try testing.expectEqual(Role.primary, roleOf('P').?);
    try testing.expectEqual(Role.secondary, roleOf('S').?);
    try testing.expectEqual(Role.foreground, roleOf('F').?);
    try testing.expectEqual(Role.muted, roleOf('M').?);
    try testing.expectEqual(Role.warning, roleOf('W').?);
    try testing.expect(roleOf(' ') == null);
}
