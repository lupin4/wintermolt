// Copyright The Fantastic Planet - By David Clabaugh
//
// tui.zig — Terminal A2UI renderer, drawn by zortui.
//
// Parses A2UI messages (subset of v0.9) and renders them to an ANSI string.
// The public contract is unchanged: renderSurface(alloc, json) -> owned []u8.
//
// Supported A2UI components:
//   Text    -> wrapped paragraph
//   Heading -> bold heading
//   Column  -> vertical stack (nesting honoured)
//   Row     -> horizontal split (nesting honoured)
//   Button  -> inverse-video [ Label ]
//   Table   -> real table with header, borders and column alignment
//   Code    -> panel with the language as its title
//   Image   -> [Image: alt] placeholder, as before
//   Divider -> horizontal rule
//
// WHY zortui AND NOT HAND-ROLLED ESCAPES. The previous version wrote ANSI and
// box-drawing characters directly, and every width calculation in it counted
// BYTES:
//
//   const width: usize = @max(title_text.len + 4, 60);
//   const pad = if (text.len + 1 < width) width - text.len - 1 else 0;
//
// `len` is bytes. Every box-drawing character it emitted is 3 bytes and one
// column, and any non-ASCII in a title, label or paragraph shifted that row's
// right border by the difference. The wrap routine had the same flaw plus a
// second one — it broke at a fixed column regardless of word boundaries, and
// could split a multi-byte codepoint down the middle, which is not a cosmetic
// problem but invalid UTF-8 on the wire.
//
// zortui measures in display columns through its unicode module, so none of
// those calculations exist here any more. Alignment is correct for CJK and
// emoji by construction rather than by arithmetic nobody re-checks.
//
// TABLES WERE A PLACEHOLDER. renderTable ignored its input entirely and
// printed "[Table: see web UI for full rendering]". Tables are now parsed and
// drawn for real; see parseTable.
//
// PARSING. The old renderer scanned for "type":"..." with string search and
// looked for neighbouring keys within a 500-byte window. That cannot see
// structure, so nesting was explicitly given up on — Column and Row children
// were flattened into one vertical run. This parses with std.json and walks the
// tree, so a Row inside a Column now renders as a row. The legacy scanner is
// kept as a fallback for input that is not valid JSON, because the tool that
// feeds this can emit partial documents and losing the whole surface to a
// parse error would be worse than losing its nesting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zortui = @import("zortui");
const sse = @import("../api/sse.zig");

const ui = zortui.ui;
const w = zortui.widgets;

/// Columns of the rendered surface. The old renderer used
/// `@max(title.len + 4, 60)`, i.e. it grew the box to fit the title's BYTE
/// count. A fixed width is both predictable and correct: zortui wraps and
/// elides to fit, so a long title no longer changes the shape of everything
/// below it.
const surface_width: usize = 76;

/// Upper bound for the measuring pass. Nothing is drawn at this height; it is
/// the ceiling for how tall a surface may grow before content is dropped.
const max_height: usize = 400;

const theme_name = "dark";

// ---------------------------------------------------------------- the model

const Code = struct {
    language: []const u8,
    body: []const u8,
};

const Table = struct {
    columns: []const w.TableColumn,
    rows: []const w.TableRow,
};

const Node = union(enum) {
    heading: []const u8,
    text: []const u8,
    button: []const u8,
    image: []const u8,
    divider,
    code: Code,
    table: Table,
    column: []const Node,
    row: []const Node,
};

// --------------------------------------------------------------- the render

/// Renders `nodes` into whichever container it is handed. One type serves every
/// nesting level: a Column body and a Row body differ only in the container
/// they are given, which zortui has already decided by the time this runs.
///
/// THE ALLOCATOR IS NOT A CONVENIENCE. ui.Container.panel/column/row do not
/// call the body they are given — they STORE it and run it at flush time, once
/// the layout solver has worked out the rectangles. So a body's context must
/// outlive the call that registers it. Building these on the stack compiled
/// cleanly, rendered the panel border and its title, and dropped every child:
/// by the time the body ran, the frame it pointed at was gone. In ReleaseFast
/// the same code segfaulted instead.
///
/// Every context therefore comes from the caller's arena, which lives until
/// renderSurface returns.
const Frame = struct {
    alloc: Allocator,
    nodes: []const Node,

    fn draw(self: *Frame, c: *ui.Container) anyerror!void {
        for (self.nodes) |node| try drawNode(self.alloc, c, node);
    }
};

/// Body context for a code block, for the same lifetime reason as Frame.
const CodeFrame = struct {
    code: Code,

    /// The panel wrapper, so the `sized` container owns the height and the
    /// panel just draws inside it.
    fn panelDraw(self: *CodeFrame, outer: *ui.Container) anyerror!void {
        try outer.panel(
            .{ .title = self.code.language },
            ui.Body.with(self, CodeFrame.draw),
        );
    }

    fn draw(self: *CodeFrame, inner: *ui.Container) anyerror!void {
        // Code is preformatted: no wrapping, no reflow. Lines arrive with the
        // escape still in them ("\\n"), which is how the surface JSON carries
        // them.
        var it = std.mem.splitSequence(u8, self.code.body, "\\n");
        while (it.next()) |line| {
            try inner.text(line, .{ .fg = inner.theme().foreground });
        }
    }
};

/// Body context for a table, for the same lifetime reason as Frame.
const TableFrame = struct {
    table: Table,

    fn draw(self: *TableFrame, inner: *ui.Container) anyerror!void {
        try inner.table(.{
            .columns = self.table.columns,
            .rows = self.table.rows,
            .header = true,
            .zebra = true,
        }, "a2ui-table");
    }
};

fn drawNode(a: Allocator, c: *ui.Container, node: Node) anyerror!void {
    switch (node) {
        .heading => |t| try c.heading(t),

        // wrap = true is the whole reason the old renderWrapped is gone.
        .text => |t| try c.text(t, .{ .wrap = true }),

        .button => |label| try c.text(
            try c.fmt("[ {s} ]", .{label}),
            .{ .attrs = .{ .reverse = true }, .bold = true },
        ),

        .image => |alt| try c.text(
            try c.fmt("[Image: {s}]", .{alt}),
            .{ .fg = c.theme().warning, .italic = true },
        ),

        .divider => try c.divider(.{}),

        .code => |code| {
            const frame = try a.create(CodeFrame);
            frame.* = .{ .code = code };
            // Sized for the same reason the table is: a panel takes .fill down
            // a column, so an unsized code block eats the rest of the surface
            // and anything after it never draws. Height is its line count plus
            // its own top and bottom border.
            const lines: i64 = @intCast(std.mem.count(u8, code.body, "\\n") + 1);
            try c.sized(
                .{ .cells = lines + 2 },
                ui.Body.with(frame, CodeFrame.panelDraw),
            );
        },

        .table => |t| {
            // Wrapped in `sized`, because ui.Container.table takes .fill down a
            // column. That is right for a dashboard, where a table scrolls
            // inside the space it is given — it has offset, follow_selection
            // and a scrollbar for exactly that. It is wrong for a document,
            // where a table is as tall as its rows and whatever follows it has
            // to appear underneath: left filling, the first table on a surface
            // swallowed the rest of the panel and the divider, prose, code
            // block and button after it never drew.
            const frame = try a.create(TableFrame);
            frame.* = .{ .table = t };
            const rows: i64 = @intCast(t.rows.len + 1); // + the header row
            try c.sized(.{ .cells = rows }, ui.Body.with(frame, TableFrame.draw));
        },

        .column => |kids| {
            const f = try a.create(Frame);
            f.* = .{ .alloc = a, .nodes = kids };
            // No .size here. Containers cannot auto-size — only leaf widgets
            // report an intrinsic height — so .auto would collapse this to zero
            // rows and silently drop everything inside it.
            try c.column(.{}, ui.Body.with(f, Frame.draw));
        },

        .row => |kids| {
            const f = try a.create(Frame);
            f.* = .{ .alloc = a, .nodes = kids };
            try c.row(.{}, ui.Body.with(f, Frame.draw));
        },
    }
}

/// The whole surface: a titled panel wrapping the parsed nodes.
const Surface = struct {
    alloc: Allocator,
    title: []const u8,
    nodes: []const Node,

    fn draw(self: *Surface, c: *ui.Container) anyerror!void {
        const f = try self.alloc.create(Frame);
        f.* = .{ .alloc = self.alloc, .nodes = self.nodes };
        // size = .auto so the panel is as tall as its contents. The default is
        // .fill, which made the panel occupy the whole FrameBuffer — its bottom
        // border landed on the last row, so measureHeight below saw the frame as
        // full and every surface came back max_height rows tall.
        try c.panel(
            .{
                .title = self.title,
                .title_color = c.theme().accent,
            },
            ui.Body.with(f, Frame.draw),
        );
    }
};

// ------------------------------------------------------------------- public

/// Render an A2UI surface from the input JSON. Returns an owned ANSI string.
/// `input_json` is the full canvas_update tool input, with "components" and an
/// optional "data" field.
pub fn renderSurface(alloc: Allocator, input_json: []const u8) ![]u8 {
    // Everything the parse produces — node slices, table cells, duped strings —
    // lives here and dies in one call. The nodes borrow from the parsed JSON,
    // so the arena must outlive rendering, not just parsing.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const title = sse.findJsonString(input_json, "title") orelse "Canvas";

    const nodes = parseJson(a, input_json) catch null orelse
        try parseLegacy(a, input_json);

    // Two passes. A FrameBuffer is a fixed size and this returns a string for
    // something else to print, so rendering at a fixed height would emit a
    // screenful of blank lines after every short surface.
    //
    // Pass one measures the CONTENT, with no panel around it. A panel cannot
    // measure itself: Size.auto means "whatever the widget says it needs" and
    // only leaf widgets report an intrinsic height — ui.Container.panel passes
    // intrinsic = null, so .auto on a panel resolves to zero and the whole
    // surface collapses to one blank row. Left at its .fill default it does the
    // opposite, stretching its bottom border to the last row of whatever frame
    // it is given, which is equally useless to measure.
    //
    // Bare content has neither problem: the leaves take their natural heights
    // and everything below them stays blank.
    const content_frame = try a.create(Frame);
    content_frame.* = .{ .alloc = a, .nodes = nodes };
    const content_rows = try measureHeight(
        alloc,
        surface_width - 2, // inside the panel's left and right borders
        ui.Body.with(content_frame, Frame.draw),
    );

    var surface = Surface{ .alloc = a, .title = title, .nodes = nodes };
    const body = ui.Body.with(&surface, Surface.draw);

    var screen = try zortui.testing.renderWith(
        alloc,
        surface_width,
        @min(content_rows + 2, max_height), // + the panel's top and bottom border
        theme_name,
        0,
        render_overrides,
        body,
    );
    defer screen.deinit();
    return inlineAnsi(alloc, screen);
}

/// Serialise a rendered screen as newline-separated rows with colour.
///
/// NOT RenderedScreen.ansi(). That runs the diff encoder against a blank
/// screen, which is how a terminal app REPAINTS: absolute cursor positioning,
/// `ESC[1;1H` and friends, and almost no newlines. Correct for an app that owns
/// the display, wrong here — canvas.zig writes this string into a scrolling
/// session with a `\n` either side, so cursor addressing would jump to the top
/// left of the terminal and overwrite whatever the user was reading.
///
/// Rows are emitted in order, each reset at the end, so the result drops into a
/// transcript the way the hand-rolled renderer's output did.
fn inlineAnsi(alloc: Allocator, screen: zortui.testing.RenderedScreen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var y: usize = 0;
    while (y < screen.height) : (y += 1) {
        // Style is tracked per row and reset at the end of each, so a row never
        // inherits colour from the one above. Emitting SGR per cell instead
        // would roughly triple the output for no visible difference.
        var fg: zortui.Color = .default;
        var bg: zortui.Color = .default;
        var attrs: zortui.Attrs = .{};

        var x: usize = 0;
        while (x < screen.width) : (x += 1) {
            const c = screen.cell(x, y);
            if (c.fg != fg or c.bg != bg or bits(c.attrs) != bits(attrs)) {
                try out.appendSlice(alloc, "\x1b[0m");
                if (c.attrs.bold) try out.appendSlice(alloc, "\x1b[1m");
                if (c.attrs.dim) try out.appendSlice(alloc, "\x1b[2m");
                if (c.attrs.italic) try out.appendSlice(alloc, "\x1b[3m");
                if (c.attrs.underline) try out.appendSlice(alloc, "\x1b[4m");
                if (c.attrs.blink) try out.appendSlice(alloc, "\x1b[5m");
                if (c.attrs.reverse) try out.appendSlice(alloc, "\x1b[7m");
                if (c.attrs.strike) try out.appendSlice(alloc, "\x1b[9m");
                if (!c.fg.isDefault())
                    try zortui.ansi.fgTrue(&out, alloc, c.fg.red(), c.fg.green(), c.fg.blue());
                if (!c.bg.isDefault())
                    try zortui.ansi.bgTrue(&out, alloc, c.bg.red(), c.bg.green(), c.bg.blue());
                fg = c.fg;
                bg = c.bg;
                attrs = c.attrs;
            }
            // Empty text is the right half of a wide glyph: the left half
            // already wrote both columns' worth, so writing anything here would
            // push the rest of the row over by one.
            try out.appendSlice(alloc, c.text);
        }
        try out.appendSlice(alloc, "\x1b[0m\n");
    }
    return out.toOwnedSlice(alloc);
}

/// Attrs is a packed struct, so comparing it means comparing its bits.
fn bits(a: zortui.Attrs) u16 {
    return @bitCast(a);
}

/// Capabilities are pinned rather than detected. This function returns a STRING
/// that some other sink prints — a pipe, a log, an MCP response — so probing
/// the current terminal would make the output depend on where wintermolt
/// happens to be running rather than on the surface being rendered.
const render_overrides: zortui.capabilities.Overrides = .{
    .colors = .truecolor,
    .unicode = true,
    .tty = true,
};

/// Height of the drawn content, in rows, at a given width.
///
/// Renders once at max_height and finds the last row with anything on it. The
/// plain-text form is what makes this cheap: a blank row is a row of spaces, so
/// there are no escape sequences to reason about.
///
/// The WIDTH matters and is not cosmetic: wrapped text occupies a different
/// number of rows at a different column count, so measuring at the outer width
/// and drawing at the inner one would under-count every paragraph that wraps.
fn measureHeight(alloc: Allocator, width: usize, body: ui.Body) !usize {
    var probe = try zortui.testing.renderWith(
        alloc,
        width,
        max_height,
        theme_name,
        0,
        render_overrides,
        body,
    );
    defer probe.deinit();

    const text = try probe.text();
    var last_used: usize = 0;
    var row: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (row += 1) {
        if (std.mem.trimEnd(u8, line, " ").len != 0) last_used = row;
    }
    // last_used is an index; +1 makes it a count. Never zero — an empty surface
    // still has its panel border.
    return @min(last_used + 1, max_height);
}

// -------------------------------------------------------------- json parsing

fn parseJson(a: Allocator, input_json: []const u8) !?[]const Node {
    const parsed = std.json.parseFromSlice(std.json.Value, a, input_json, .{}) catch return null;
    // No defer parsed.deinit(): the nodes borrow their strings from it, and the
    // arena frees the whole lot together.
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const components = root.get("components") orelse return null;
    return try parseNodes(a, components);
}

fn parseNodes(a: Allocator, value: std.json.Value) anyerror![]const Node {
    var out: std.ArrayList(Node) = .empty;
    switch (value) {
        .array => |items| {
            for (items.items) |item| {
                if (try parseNode(a, item)) |n| try out.append(a, n);
            }
        },
        .object => {
            if (try parseNode(a, value)) |n| try out.append(a, n);
        },
        else => {},
    }
    return out.items;
}

fn parseNode(a: Allocator, value: std.json.Value) anyerror!?Node {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const type_name = strOf(obj.get("type")) orelse return null;

    // A2UI capitalises component names inconsistently between producers, which
    // is why the old scanner tested both spellings of every one.
    var lower_buf: [32]u8 = undefined;
    if (type_name.len > lower_buf.len) return null;
    const kind = std.ascii.lowerString(lower_buf[0..type_name.len], type_name);

    if (std.mem.eql(u8, kind, "text")) {
        return .{ .text = firstString(obj, &.{ "value", "content", "text" }) orelse return null };
    }
    if (std.mem.eql(u8, kind, "heading")) {
        return .{ .heading = firstString(obj, &.{ "value", "text", "content" }) orelse return null };
    }
    if (std.mem.eql(u8, kind, "button")) {
        return .{ .button = firstString(obj, &.{ "label", "text" }) orelse "Button" };
    }
    if (std.mem.eql(u8, kind, "image")) {
        return .{ .image = firstString(obj, &.{ "alt", "description" }) orelse "image" };
    }
    if (std.mem.eql(u8, kind, "divider")) return .divider;
    if (std.mem.eql(u8, kind, "code")) {
        return .{ .code = .{
            .language = firstString(obj, &.{"language"}) orelse "",
            .body = firstString(obj, &.{ "value", "content", "code" }) orelse return null,
        } };
    }
    if (std.mem.eql(u8, kind, "table")) {
        return if (try parseTable(a, obj)) |t| .{ .table = t } else null;
    }
    if (std.mem.eql(u8, kind, "column")) {
        return .{ .column = try parseChildren(a, obj) };
    }
    if (std.mem.eql(u8, kind, "row")) {
        return .{ .row = try parseChildren(a, obj) };
    }
    return null;
}

fn parseChildren(a: Allocator, obj: std.json.ObjectMap) anyerror![]const Node {
    const kids = obj.get("children") orelse obj.get("components") orelse
        return &[_]Node{};
    return parseNodes(a, kids);
}

/// Both table shapes A2UI producers emit:
///   columns: ["A","B"]            rows: [["1","2"], ...]
///   columns: [{title:"A"}, ...]   rows: [{cells:[...]}, ...]
/// Returns null when there is nothing to draw, so the caller drops the
/// component rather than rendering an empty frame.
fn parseTable(a: Allocator, obj: std.json.ObjectMap) anyerror!?Table {
    const cols_value = obj.get("columns") orelse obj.get("headers");
    const rows_value = obj.get("rows") orelse obj.get("data");

    var columns: std.ArrayList(w.TableColumn) = .empty;
    if (cols_value) |cv| switch (cv) {
        .array => |items| for (items.items) |item| {
            const title = switch (item) {
                .string => |s| s,
                .object => |o| strOf(o.get("title")) orelse strOf(o.get("label")) orelse "",
                else => "",
            };
            try columns.append(a, .{ .title = title });
        },
        else => {},
    };

    var rows: std.ArrayList(w.TableRow) = .empty;
    if (rows_value) |rv| switch (rv) {
        .array => |items| for (items.items) |item| {
            const cells = try parseCells(a, item);
            if (cells.len == 0) continue;
            try rows.append(a, .{ .cells = cells });
        },
        else => {},
    };

    if (columns.items.len == 0 and rows.items.len == 0) return null;

    // A header-less table still needs a column per cell, or the widget has
    // nothing to lay the row out against.
    if (columns.items.len == 0) {
        var widest: usize = 0;
        for (rows.items) |r| widest = @max(widest, r.cells.len);
        for (0..widest) |_| try columns.append(a, .{});
    }

    return .{ .columns = columns.items, .rows = rows.items };
}

fn parseCells(a: Allocator, value: std.json.Value) anyerror![]const []const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    const items = switch (value) {
        .array => |arr| arr,
        .object => |o| switch (o.get("cells") orelse return &.{}) {
            .array => |arr| arr,
            else => return &.{},
        },
        else => return &.{},
    };
    for (items.items) |cell| {
        try cells.append(a, switch (cell) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
            .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
            .bool => |b| if (b) "true" else "false",
            .null => "",
            else => "",
        });
    }
    return cells.items;
}

fn strOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn firstString(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (strOf(obj.get(k))) |s| return s;
    }
    return null;
}

// ------------------------------------------------------------ legacy parsing

/// The original string scanner, kept for input std.json rejects.
///
/// It cannot see structure, so Column and Row children come out as one flat
/// vertical run — the behaviour this file shipped with before. Reaching it
/// means the document was malformed; rendering it flat beats rendering nothing.
fn parseLegacy(a: Allocator, json: []const u8) ![]const Node {
    var out: std.ArrayList(Node) = .empty;
    var pos: usize = 0;

    while (pos < json.len) {
        const needle = "\"type\":\"";
        const found = std.mem.indexOf(u8, json[pos..], needle) orelse break;
        const start = pos + found + needle.len;
        const end_rel = std.mem.indexOfScalar(u8, json[start..], '"') orelse break;
        const kind_raw = json[start .. start + end_rel];
        pos = start + end_rel + 1;

        var lower_buf: [32]u8 = undefined;
        if (kind_raw.len > lower_buf.len) continue;
        const kind = std.ascii.lowerString(lower_buf[0..kind_raw.len], kind_raw);
        const ctx = json[pos..];

        if (std.mem.eql(u8, kind, "text")) {
            if (nearby(ctx, &.{ "value", "content", "text" })) |v| try out.append(a, .{ .text = v });
        } else if (std.mem.eql(u8, kind, "heading")) {
            if (nearby(ctx, &.{ "value", "text" })) |v| try out.append(a, .{ .heading = v });
        } else if (std.mem.eql(u8, kind, "button")) {
            try out.append(a, .{ .button = nearby(ctx, &.{ "label", "text" }) orelse "Button" });
        } else if (std.mem.eql(u8, kind, "image")) {
            try out.append(a, .{ .image = nearby(ctx, &.{ "alt", "description" }) orelse "image" });
        } else if (std.mem.eql(u8, kind, "divider")) {
            try out.append(a, .divider);
        } else if (std.mem.eql(u8, kind, "code")) {
            if (nearby(ctx, &.{ "value", "content", "code" })) |v| {
                try out.append(a, .{ .code = .{
                    .language = nearby(ctx, &.{"language"}) orelse "",
                    .body = v,
                } });
            }
        }
        // Tables are skipped here on purpose: the window scan below cannot read
        // a nested array, and a table rendered from whatever strings happen to
        // sit within 500 bytes would be wrong rather than merely absent.
    }
    return out.items;
}

/// Find a JSON string value near the start of `context`, within 500 bytes.
fn nearby(context: []const u8, keys: []const []const u8) ?[]const u8 {
    const slice = context[0..@min(context.len, 500)];
    for (keys) |key| {
        var needle_buf: [270]u8 = undefined;
        if (key.len + 4 > needle_buf.len) continue;
        needle_buf[0] = '"';
        @memcpy(needle_buf[1 .. 1 + key.len], key);
        needle_buf[1 + key.len] = '"';
        needle_buf[2 + key.len] = ':';
        needle_buf[3 + key.len] = '"';
        const needle = needle_buf[0 .. 4 + key.len];

        const start = std.mem.indexOf(u8, slice, needle) orelse continue;
        const value_start = start + needle.len;
        var i = value_start;
        while (i < slice.len) : (i += 1) {
            if (slice[i] == '"' and (i == 0 or slice[i - 1] != '\\')) {
                return slice[value_start..i];
            }
        }
    }
    return null;
}

// -------------------------------------------------------------------- tests

test "renders a surface with a title and text" {
    const alloc = std.testing.allocator;
    const json =
        \\{"title":"Status","components":[{"type":"text","value":"all green"}]}
    ;
    const out = try renderSurface(alloc, json);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "all green") != null);
}

test "nesting survives: a row inside a column" {
    const alloc = std.testing.allocator;
    const json =
        \\{"title":"T","components":[{"type":"column","children":[
        \\{"type":"row","children":[{"type":"text","value":"left"},
        \\{"type":"text","value":"right"}]}]}]}
    ;
    const out = try renderSurface(alloc, json);
    defer alloc.free(out);
    // Both cells present, and "left" precedes "right" on the SAME row — the
    // flat renderer stacked them, so this is what distinguishes the two.
    const l = std.mem.indexOf(u8, out, "left") orelse return error.MissingLeft;
    const r = std.mem.indexOf(u8, out, "right") orelse return error.MissingRight;
    try std.testing.expect(l < r);
    const between = out[l..r];
    try std.testing.expect(std.mem.indexOfScalar(u8, between, '\n') == null);
}

test "tables render their cells instead of a placeholder" {
    const alloc = std.testing.allocator;
    const json =
        \\{"title":"T","components":[{"type":"table",
        \\"columns":["Name","Count"],"rows":[["alpha",3],["beta",4]]}]}
    ;
    const out = try renderSurface(alloc, json);
    defer alloc.free(out);
    for ([_][]const u8{ "Name", "Count", "alpha", "beta", "3", "4" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "see web UI") == null);
}

test "malformed json falls back to the scanner rather than failing" {
    const alloc = std.testing.allocator;
    // Truncated: no closing brace, so std.json rejects it.
    const json =
        \\{"title":"Partial","components":[{"type":"text","value":"still here"}
    ;
    const out = try renderSurface(alloc, json);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "still here") != null);
}

test "height tracks content instead of padding to a fixed frame" {
    const alloc = std.testing.allocator;
    const short = try renderSurface(alloc,
        \\{"title":"T","components":[{"type":"text","value":"one"}]}
    );
    defer alloc.free(short);
    const long = try renderSurface(alloc,
        \\{"title":"T","components":[{"type":"text","value":"one"},
        \\{"type":"divider"},{"type":"text","value":"two"},
        \\{"type":"divider"},{"type":"text","value":"three"}]}
    );
    defer alloc.free(long);
    try std.testing.expect(std.mem.count(u8, short, "\n") < std.mem.count(u8, long, "\n"));
    // And the short one is not a screenful of blanks.
    try std.testing.expect(std.mem.count(u8, short, "\n") < 12);
}

test "content after a table and a code block still renders" {
    // Both ui.Container.table and .panel take .fill down a column. Left
    // unsized, the first of either swallowed the rest of the surface and
    // everything after it silently vanished — the surface still looked
    // plausible, just truncated, which is the worst kind of wrong.
    const alloc = std.testing.allocator;
    const out = try renderSurface(alloc,
        \\{"title":"T","components":[
        \\{"type":"table","columns":["a"],"rows":[["1"]]},
        \\{"type":"code","language":"sh","value":"echo hi"},
        \\{"type":"text","value":"AFTERWARDS"},
        \\{"type":"button","label":"LAST"}]}
    );
    defer alloc.free(out);
    for ([_][]const u8{ "a", "1", "echo hi", "AFTERWARDS", "LAST" }) |needle| {
        if (std.mem.indexOf(u8, out, needle) == null) return error.ContentTruncated;
    }
    // Ordering too: the tail must come after the table, not instead of it.
    const table_at = std.mem.indexOf(u8, out, "echo hi").?;
    const tail_at = std.mem.indexOf(u8, out, "AFTERWARDS").?;
    try std.testing.expect(table_at < tail_at);
}

test "output flows inline: no absolute cursor positioning" {
    // canvas.zig writes this straight into a scrolling session. An ESC[y;xH in
    // here would move the cursor to an absolute screen position and overwrite
    // whatever the user was reading — which is exactly what
    // RenderedScreen.ansi() emits, because it is built to repaint a display.
    // This is the guard that keeps the inline serialiser from being swapped
    // back for the shorter-looking call.
    const alloc = std.testing.allocator;
    const out = try renderSurface(alloc,
        \\{"title":"T","components":[{"type":"text","value":"body"}]}
    );
    defer alloc.free(out);

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out, i, 0x1b)) |esc| : (i = esc + 1) {
        if (esc + 1 >= out.len or out[esc + 1] != '[') continue;
        // Scan the parameter bytes to the final byte of the sequence.
        var j = esc + 2;
        while (j < out.len and (std.ascii.isDigit(out[j]) or out[j] == ';')) : (j += 1) {}
        if (j >= out.len) continue;
        switch (out[j]) {
            'H', 'f', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'd' => return error.CursorMovementEmitted,
            else => {},
        }
    }

    // And the rows really are newline-separated, not run together.
    try std.testing.expect(std.mem.count(u8, out, "\n") >= 3);
}

test "wide characters do not shift the right border" {
    const alloc = std.testing.allocator;
    // The byte-counting renderer mis-padded any row containing these: each CJK
    // codepoint is 3 bytes and 2 display columns, so `len` overcounted by one
    // per character and the border walked left.
    const out = try renderSurface(alloc,
        \\{"title":"幅","components":[{"type":"text","value":"日本語テキスト"}]}
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "日本語テキスト") != null);
}
