// Copyright The Fantastic Planet - By David Clabaugh
//
// skill_md.zig — SKILL.md skills, OpenClaw's and Anthropic's Agent Skills format
//
// A skill is a folder with a SKILL.md: YAML frontmatter, then instructions.
// The prompt lists each skill's name, description and location, and the model
// loads the instructions when a task calls for them, so they cost nothing until
// used (docs.openclaw.ai/tools/skills). OpenClaw has the model `read` the file;
// here the prompt names the `skills` tool (operation "use"), which returns the
// file with {baseDir} filled in: qwen3:8b reached for that tool unprompted, and
// told to use file_read it often ended its turn with nothing.
//
// Frontmatter read: name (else the folder's name), description (required),
// disable-model-invocation (true: not listed), and metadata, whose "openclaw"
// object gates the skill: os (always applies), then unless always is true,
// requires.bins (each on PATH), requires.anyBins (one on PATH), requires.env
// (each set). A gate this file cannot read lets the skill through.
//
// Folders searched, first match of a name winning:
//   ./skills  ./.agents/skills                        (the project)
//   <workspace>/skills  <workspace>/.agents/skills    (workspace.zig)
//   ~/.agents/skills  ~/.wintermolt/skills
// Read every turn, so a skill installed mid-session is listed on the next one.

const std = @import("std");
const builtin = @import("builtin");
const fsio = @import("../fsio.zig");
const compat = @import("../compat.zig");
const workspace = @import("workspace.zig");
const Allocator = std.mem.Allocator;

pub const Front = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    hidden: bool = false,
    /// The raw value: JSON on the key's line, or the indented block below it.
    metadata: ?[]const u8 = null,
};

/// The frontmatter between the leading `---` lines; null when there is none.
/// A value is the rest of its line, unquoted, or for an empty, `>` or `|`
/// value the indented lines below. Slices into `text`.
pub fn parseFront(text: []const u8) ?Front {
    var rest = text;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    const first = nextLine(&rest) orelse return null;
    if (!std.mem.eql(u8, first, "---")) return null;

    var f: Front = .{};
    while (nextLine(&rest)) |line| {
        if (std.mem.eql(u8, line, "---")) return f;
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0 or value[0] == '>' or value[0] == '|') {
            // The block: every following line that is indented or blank.
            const start = rest;
            var end: usize = 0;
            var probe = rest;
            while (probe.len > 0) {
                const before = probe;
                const l = nextLine(&probe) orelse break;
                if (l.len > 0 and l[0] != ' ' and l[0] != '\t') break;
                rest = probe;
                end = start.len - before.len + l.len;
            }
            value = std.mem.trim(u8, start[0..end], " \t\r\n");
        } else if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) f.name = value;
        if (std.mem.eql(u8, key, "description")) f.description = value;
        if (std.mem.eql(u8, key, "metadata")) f.metadata = value;
        if (std.mem.eql(u8, key, "disable-model-invocation")) f.hidden = std.mem.eql(u8, value, "true");
    }
    return null; // never closed
}

fn nextLine(rest: *[]const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    const nl = std.mem.indexOfScalar(u8, rest.*, '\n') orelse rest.len;
    const line = std.mem.trimEnd(u8, rest.*[0..nl], "\r");
    rest.* = if (nl < rest.len) rest.*[nl + 1 ..] else rest.*[rest.len..];
    return line;
}

/// The skill may run here: metadata.openclaw's os and requires are met.
pub fn eligible(alloc: Allocator, metadata: ?[]const u8) bool {
    const raw = metadata orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    const oc = parsed.value.object.get("openclaw") orelse return true;
    if (oc != .object) return true;

    if (oc.object.get("os")) |os| if (os == .array) {
        const here: []const []const u8 = switch (builtin.os.tag) {
            .macos => &.{ "darwin", "macos" },
            .linux => &.{"linux"},
            .windows => &.{"win32"},
            else => &.{},
        };
        var match = false;
        for (os.array.items) |v| if (v == .string) for (here) |h| {
            if (std.mem.eql(u8, v.string, h)) match = true;
        };
        if (!match) return false;
    };
    if (oc.object.get("always")) |a| if (a == .bool and a.bool) return true;

    const req = oc.object.get("requires") orelse return true;
    if (req != .object) return true;
    if (req.object.get("bins")) |bins| if (bins == .array) for (bins.array.items) |b| {
        if (b == .string and !compat.onPath(b.string)) return false;
    };
    if (req.object.get("anyBins")) |bins| if (bins == .array and bins.array.items.len > 0) {
        var any = false;
        for (bins.array.items) |b| if (b == .string and compat.onPath(b.string)) {
            any = true;
        };
        if (!any) return false;
    };
    if (req.object.get("env")) |env| if (env == .array) for (env.array.items) |e| {
        if (e != .string) continue;
        const v = compat.getenv(e.string) orelse return false;
        if (v.len == 0) return false;
    };
    return true;
}

pub const Skill = struct {
    name: []u8,
    description: []u8,
    /// The SKILL.md path the model reads.
    location: []u8,

    pub fn deinit(self: Skill, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.location);
    }
};

pub fn freeAll(alloc: Allocator, skills: []Skill) void {
    for (skills) |s| s.deinit(alloc);
    alloc.free(skills);
}

/// The folders searched, in order. Caller frees with freeRoots.
pub fn roots(alloc: Allocator) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |r| alloc.free(r);
        list.deinit(alloc);
    }
    try list.append(alloc, try alloc.dupe(u8, "skills"));
    try list.append(alloc, try alloc.dupe(u8, ".agents/skills"));
    if (try workspace.dirPath(alloc)) |ws| {
        defer alloc.free(ws);
        try list.append(alloc, try std.fmt.allocPrint(alloc, "{s}/skills", .{ws}));
        try list.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.agents/skills", .{ws}));
    }
    if (compat.getenv("HOME")) |home| {
        try list.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.agents/skills", .{home}));
        try list.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.wintermolt/skills", .{home}));
    }
    return list.toOwnedSlice(alloc);
}

pub fn freeRoots(alloc: Allocator, list: [][]u8) void {
    for (list) |r| alloc.free(r);
    alloc.free(list);
}

/// The skills the model may use, from every root. Caller frees with freeAll.
pub fn discover(alloc: Allocator) ![]Skill {
    const r = try roots(alloc);
    defer freeRoots(alloc, r);
    return discoverIn(alloc, r);
}

// shortcut: one level below each root (root/<skill>/SKILL.md, the layout ClawHub installs); OpenClaw also finds grouped layouts 6 deep, walk deeper if those turn up.
pub fn discoverIn(alloc: Allocator, root_list: []const []const u8) ![]Skill {
    var out: std.ArrayList(Skill) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(alloc);
        out.deinit(alloc);
    }
    for (root_list) |root| {
        var dir = fsio.openDirCwd(root, .{ .iterate = true }) catch continue;
        defer fsio.closeDir(dir);
        var it = dir.iterate();
        while (fsio.iterNext(&it) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const location = try std.fmt.allocPrint(alloc, "{s}/{s}/SKILL.md", .{ root, entry.name });
            var keep = false;
            defer if (!keep) alloc.free(location);

            const head = readHead(alloc, location) orelse continue;
            defer alloc.free(head);
            const f = parseFront(head) orelse continue;
            const description = f.description orelse continue;
            const name = f.name orelse entry.name;
            if (f.hidden or !eligible(alloc, f.metadata)) continue;
            if (for (out.items) |s| {
                if (std.mem.eql(u8, s.name, name)) break true;
            } else false) continue; // an earlier root has it

            const name_copy = try alloc.dupe(u8, name);
            errdefer alloc.free(name_copy);
            const desc_copy = try collapseSpace(alloc, description);
            errdefer alloc.free(desc_copy);
            try out.append(alloc, .{ .name = name_copy, .description = desc_copy, .location = location });
            keep = true;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The first 16 KiB of a file, which holds any sane frontmatter.
fn readHead(alloc: Allocator, path: []const u8) ?[]u8 {
    const file = fsio.openFile(path, .{}) catch return null;
    defer fsio.close(file);
    const size = fsio.getEndPos(file) catch return null;
    const buf = alloc.alloc(u8, @intCast(@min(size, 16 * 1024))) catch return null;
    const n = fsio.readAllAt(file, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n == buf.len) return buf;
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

/// A folded block's newlines and indentation, as single spaces.
fn collapseSpace(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |word| {
        if (out.items.len > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, word);
    }
    return out.toOwnedSlice(alloc);
}

/// The Skills section for this turn, from every root. Caller owns it.
pub fn load(alloc: Allocator) ![]u8 {
    const skills = try discover(alloc);
    defer freeAll(alloc, skills);
    return promptSection(alloc, skills);
}

const prompt_cap = 8_000;
const description_cap = 400;

/// The Skills section of the system prompt; empty without skills. Caller owns it.
pub fn promptSection(alloc: Allocator, skills: []const Skill) ![]u8 {
    if (skills.len == 0) return alloc.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\n\n## Skills\n\nThese skills are installed. When a task matches one, load it before you start, with the skills tool (operation \"use\" and the skill's name), and follow it. Skip the ones that do not fit the task.\n\n<available_skills>\n");
    var listed: usize = 0;
    for (skills) |s| {
        if (out.written().len > prompt_cap) break;
        const d = s.description[0..@min(s.description.len, description_cap)];
        try w.writeAll("<skill>\n<name>");
        try writeXml(w, s.name);
        try w.writeAll("</name>\n<description>");
        try writeXml(w, d);
        try w.writeAll("</description>\n<location>");
        try writeXml(w, s.location);
        try w.writeAll("</location>\n</skill>\n");
        listed += 1;
    }
    try w.writeAll("</available_skills>\n");
    if (listed < skills.len) try w.print("({d} more skills are installed but not listed, to keep the prompt short.)\n", .{skills.len - listed});
    return out.toOwnedSlice();
}

fn writeXml(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

/// The skill named `name`, from every root. Caller frees it.
pub fn find(alloc: Allocator, name: []const u8) !?Skill {
    const all = try discover(alloc);
    defer alloc.free(all);
    var found: ?Skill = null;
    for (all) |s| {
        if (found == null and std.mem.eql(u8, s.name, name)) found = s else s.deinit(alloc);
    }
    return found;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseFront: plain, quoted and folded values; metadata as JSON; CRLF" {
    const f = parseFront(
        "---\r\nname: image-lab\r\ndescription: \"Generate or edit images\"\r\nmetadata:\r\n  { \"openclaw\": { \"requires\": { \"bins\": [\"uv\"] } } }\r\n---\r\n# Body\r\n",
    ).?;
    try testing.expectEqualStrings("image-lab", f.name.?);
    try testing.expectEqualStrings("Generate or edit images", f.description.?);
    try testing.expectEqualStrings("{ \"openclaw\": { \"requires\": { \"bins\": [\"uv\"] } } }", f.metadata.?);

    const folded = parseFront("---\nname: x\ndescription: >\n  Two lines\n  of text.\ndisable-model-invocation: true\n---\n").?;
    try testing.expectEqualStrings("Two lines\n  of text.", folded.description.?);
    try testing.expect(folded.hidden);
}

test "parseFront: no frontmatter, or one never closed" {
    try testing.expect(parseFront("# Just a heading\n") == null);
    try testing.expect(parseFront("---\nname: x\n") == null);
}

test "eligible: os always applies; always skips requires; bins, anyBins and env" {
    const a = testing.allocator;
    try testing.expect(eligible(a, null));
    try testing.expect(eligible(a, "not json"));
    try testing.expect(eligible(a, "{\"other\": {}}"));
    try testing.expect(!eligible(a, "{\"openclaw\": {\"os\": [\"plan9\"], \"always\": true}}"));
    try testing.expect(!eligible(a, "{\"openclaw\": {\"requires\": {\"bins\": [\"wintermolt-no-such-program-4f1c\"]}}}"));
    try testing.expect(eligible(a, "{\"openclaw\": {\"always\": true, \"requires\": {\"bins\": [\"wintermolt-no-such-program-4f1c\"]}}}"));
    try testing.expect(!eligible(a, "{\"openclaw\": {\"requires\": {\"anyBins\": [\"wintermolt-no-such-program-4f1c\"]}}}"));
    try testing.expect(!eligible(a, "{\"openclaw\": {\"requires\": {\"env\": [\"WINTERMOLT_NO_SUCH_VAR_4F1C\"]}}}"));
    const shell = if (builtin.os.tag == .windows) "cmd" else "sh";
    try testing.expect(eligible(a, "{\"openclaw\": {\"requires\": {\"anyBins\": [\"wintermolt-no-such-program-4f1c\", \"" ++ shell ++ "\"]}}}"));
}

test "discoverIn: the first root wins a name; hidden, gated and description-less skills are left out" {
    const alloc = testing.allocator;
    const base = ".zig-cache/tmp/skill_md_test";
    try fsio.makePath(base ++ "/a/lab");
    try fsio.makePath(base ++ "/a/hidden");
    try fsio.makePath(base ++ "/a/gated");
    try fsio.makePath(base ++ "/a/nodesc");
    try fsio.makePath(base ++ "/b/lab");
    try fsio.makePath(base ++ "/b/other");
    defer fsio.deleteTree(base) catch {};
    const files_ = [_][2][]const u8{
        .{ base ++ "/a/lab/SKILL.md", "---\nname: lab\ndescription: from a\n---\n" },
        .{ base ++ "/a/hidden/SKILL.md", "---\ndescription: d\ndisable-model-invocation: true\n---\n" },
        .{ base ++ "/a/gated/SKILL.md", "---\ndescription: d\nmetadata: {\"openclaw\": {\"os\": [\"plan9\"]}}\n---\n" },
        .{ base ++ "/a/nodesc/SKILL.md", "---\nname: nodesc\n---\n" },
        .{ base ++ "/b/lab/SKILL.md", "---\nname: lab\ndescription: from b\n---\n" },
        .{ base ++ "/b/other/SKILL.md", "---\ndescription: Uses <tags> & more\n---\n" },
    };
    for (files_) |pair| {
        const f = try fsio.createFile(pair[0], .{});
        defer fsio.close(f);
        try fsio.writeAll(f, pair[1]);
    }
    const skills = try discoverIn(alloc, &.{ base ++ "/a", base ++ "/b" });
    defer freeAll(alloc, skills);
    try testing.expectEqual(@as(usize, 2), skills.len);
    try testing.expectEqualStrings("lab", skills[0].name);
    try testing.expectEqualStrings("from a", skills[0].description);
    try testing.expectEqualStrings(base ++ "/a/lab/SKILL.md", skills[0].location);
    try testing.expectEqualStrings("other", skills[1].name); // the folder's name

    const section = try promptSection(alloc, skills);
    defer alloc.free(section);
    try testing.expect(std.mem.indexOf(u8, section, "<name>lab</name>") != null);
    try testing.expect(std.mem.indexOf(u8, section, "Uses &lt;tags&gt; &amp; more") != null);
}
