// Copyright The Fantastic Planet - By David Clabaugh
//
// theme_pref.zig -- which zortui theme the full-screen view and the canvas use.
//
// SOURCES, highest first:
//   --theme <name>     the command line
//   WINTERMOLT_THEME   the environment (read BEFORE config.loadDotEnv copies
//                      ~/.wintermolt/.env into it, so the two stay distinct)
//   ~/.wintermolt/.env WINTERMOLT_THEME=<name>, written by /theme
//   "dark"             zortui's default
// A name that is not a built-in theme is reported and skipped, and the next
// source decides. Nothing here fails a start-up.
//
// NAMES. Every built-in has a key (tokyoNight) and a name (tokyo-night);
// either spelling, in any case, reaches it. The name is the canonical form,
// the one stored and shown.
//
// STORAGE is the existing ~/.wintermolt/.env: the one WINTERMOLT_THEME line is
// replaced in place, or appended, and every other byte of the file is kept.
//
// No fsio: file access takes a std.Io and a Dir, so main passes fsio's and the
// headless tests pass std.testing's.

const std = @import("std");
const zortui = @import("zortui");

pub const env_key = "WINTERMOLT_THEME";
pub const default_name = "dark";

const themes = zortui.theme.themes;

/// The canonical name of a built-in theme, from its name or key in any case.
/// Surrounding spaces and quotes are ignored. Null for anything else.
pub fn canonical(name: []const u8) ?[]const u8 {
    const i = indexOf(name) orelse return null;
    return themes[i].theme.name;
}

fn indexOf(name: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, name, " \t\r\n\"'");
    if (trimmed.len == 0) return null;
    for (themes, 0..) |t, i| {
        if (std.ascii.eqlIgnoreCase(t.theme.name, trimmed) or std.ascii.eqlIgnoreCase(t.key, trimmed)) return i;
    }
    return null;
}

// ── the process-wide selection ────────────────────────────────────────────

/// An index into zortui's table rather than a slice, so a reader on another
/// thread (the canvas renders on the TUI's worker) never sees half a write.
var selected_index = std.atomic.Value(usize).init(0);

/// The selected theme's canonical name. "dark" until something selects.
pub fn selected() []const u8 {
    return themes[selected_index.load(.acquire)].theme.name;
}

/// Select a theme by name or key. False, and no change, for an unknown name.
pub fn select(name: []const u8) bool {
    const i = indexOf(name) orelse return false;
    selected_index.store(i, .release);
    return true;
}

// ── resolution ────────────────────────────────────────────────────────────

pub const Source = enum { flag, env, saved, default };

pub const Rejected = struct { source: Source, value: []const u8 };

pub const Resolved = struct {
    name: []const u8 = default_name,
    source: Source = .default,
    rejected_buf: [3]Rejected = undefined,
    rejected_len: usize = 0,

    /// Names that were given but are not themes, highest source first.
    pub fn rejected(self: *const Resolved) []const Rejected {
        return self.rejected_buf[0..self.rejected_len];
    }
};

/// Pick the theme from its sources. Null or blank means "not given".
pub fn resolve(flag: ?[]const u8, env: ?[]const u8, saved: ?[]const u8) Resolved {
    var r: Resolved = .{};
    const sources = [_]Source{ .flag, .env, .saved };
    const values = [_]?[]const u8{ flag, env, saved };
    for (sources, values) |source, maybe| {
        const value = maybe orelse continue;
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) continue;
        if (canonical(value)) |name| {
            r.name = name;
            r.source = source;
            return r;
        }
        r.rejected_buf[r.rejected_len] = .{ .source = source, .value = value };
        r.rejected_len += 1;
    }
    return r;
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .flag => "--theme",
        .env => env_key,
        .saved => "~/.wintermolt/.env",
        .default => "the default",
    };
}

// ── messages ──────────────────────────────────────────────────────────────

/// "dark, dracula, nord, ..." -- every canonical name, in zortui's order.
pub fn writeNames(w: anytype) !void {
    for (themes, 0..) |t, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(t.theme.name);
    }
}

/// "Unknown theme 'x' (from --theme). Themes: dark, ..., light." with no
/// prefix and no newline. `source` null means it was typed as /theme <x>.
pub fn writeUnknown(w: anytype, value: []const u8, source: ?Source) !void {
    try w.print("Unknown theme '{s}'", .{std.mem.trim(u8, value, " \t\r\n")});
    if (source) |s| try w.print(" (from {s})", .{sourceLabel(s)});
    try w.writeAll(". Themes: ");
    try writeNames(w);
    try w.writeByte('.');
}

/// The /theme listing: every theme on its own line, the current one marked
/// with `*`, and the other spelling shown where the key differs from the name.
pub fn writeList(w: anytype, current: []const u8) !void {
    try w.writeAll("Themes (* current; /theme <name> switches and saves):\n");
    for (themes) |t| {
        const mark: []const u8 = if (std.mem.eql(u8, t.theme.name, current)) "* " else "  ";
        try w.writeAll(mark);
        try w.writeAll(t.theme.name);
        if (!std.mem.eql(u8, t.key, t.theme.name)) {
            var pad = 14 -| t.theme.name.len;
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
            try w.print("(or {s})", .{t.key});
        }
        try w.writeByte('\n');
    }
}

// ── ~/.wintermolt/.env ────────────────────────────────────────────────────

/// "<home>/.wintermolt/.env", the path config.loadDotEnv reads. Caller owns.
pub fn envPath(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/.wintermolt/.env", .{home});
}

/// A line's key and value, parsed the way config.loadDotEnv parses it.
fn parseLine(raw: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const effective = if (std.mem.startsWith(u8, line, "export "))
        std.mem.trim(u8, line["export ".len..], " \t")
    else
        line;
    const eq = std.mem.indexOfScalar(u8, effective, '=') orelse return null;
    var value = std.mem.trim(u8, effective[eq + 1 ..], " \t");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = value[1 .. value.len - 1];
    }
    return .{ .key = std.mem.trim(u8, effective[0..eq], " \t"), .value = value };
}

/// WINTERMOLT_THEME's value in .env text. The first one, as loadDotEnv uses.
pub fn savedFromEnvText(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const kv = parseLine(raw) orelse continue;
        if (std.mem.eql(u8, kv.key, env_key)) return kv.value;
    }
    return null;
}

/// `text` with WINTERMOLT_THEME set to `name`: the first such line replaced,
/// its line ending kept, or a line appended. Every other byte is kept.
/// Caller owns the result.
pub fn setInEnvText(gpa: std.mem.Allocator, text: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = nl orelse text.len;
        const line = text[start..end];
        const is_theme = if (parseLine(line)) |kv| std.mem.eql(u8, kv.key, env_key) else false;
        if (is_theme and !replaced) {
            try out.print(gpa, "{s}={s}", .{ env_key, name });
            if (std.mem.endsWith(u8, line, "\r")) try out.append(gpa, '\r');
            replaced = true;
        } else {
            try out.appendSlice(gpa, line);
        }
        if (nl != null) try out.append(gpa, '\n');
        start = end + 1;
    }
    if (!replaced) {
        const crlf = std.mem.indexOf(u8, text, "\r\n") != null;
        const eol: []const u8 = if (crlf) "\r\n" else "\n";
        if (text.len > 0 and text[text.len - 1] != '\n') try out.appendSlice(gpa, eol);
        try out.print(gpa, "{s}={s}{s}", .{ env_key, name, eol });
    }
    return out.toOwnedSlice(gpa);
}

const max_env_bytes = 1 << 20;

/// The saved theme (as written, not validated), or null when the file or the
/// line is missing. Caller owns the result.
pub fn loadSaved(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]u8 {
    const text = dir.readFileAlloc(io, path, gpa, .limited(max_env_bytes)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer gpa.free(text);
    const value = savedFromEnvText(text) orelse return null;
    return try gpa.dupe(u8, value);
}

/// Save `name` as WINTERMOLT_THEME in the .env at `path`, creating the file
/// and its directory if needed and keeping everything else in it.
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, name: []const u8) !void {
    const old: []u8 = dir.readFileAlloc(io, path, gpa, .limited(max_env_bytes)) catch |e| switch (e) {
        error.FileNotFound => try gpa.alloc(u8, 0),
        else => return e,
    };
    defer gpa.free(old);
    const new = try setInEnvText(gpa, old, name);
    defer gpa.free(new);

    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sep| {
        if (sep > 0) dir.createDirPath(io, path[0..sep]) catch {};
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = new });
}
