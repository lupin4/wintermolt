# zortui

Terminal UI for Zig: btop-grade dashboards with a one-import API, dark by
default, **standard library only** — no package dependencies, nothing in
`build.zig.zon` to fetch. Runs on Linux, macOS and Windows (any console that
accepts VT processing).

zortui is our own copy of the Zig port of
[hqtui](https://github.com/profullstack/hqtui), maintained independently — see
`NOTICE`. It keeps hqtui's API and replays hqtui's conformance fixtures, so
rendering matches hqtui's reference implementation as of the copy.

Requires Zig 0.16.

```bash
git clone https://github.com/lupin4/zortui
cd zortui && zig build test
```

## Hello, terminal

```zig
const std = @import("std");
const zortui = @import("zortui");

fn view(ui: *zortui.Container) anyerror!void {
    try ui.panel(.{ .title = "Hello" }, zortui.Body.plain(body));
}

fn body(p: *zortui.Container) anyerror!void {
    try p.text("Hello, terminal.", .{});
    try p.label("Press q to quit.");
}

pub fn main(init: std.process.Init) !void {
    var app = try zortui.App.init(init.gpa, .{
        .terminal = .{ .env = .fromEnviron(&init.minimal.environ) },
    });
    defer app.deinit();
    try app.run(zortui.Body.plain(view));
}
```

`App.init` already gives you a dark theme, truecolor with automatic 256/16
fallback, mouse tracking, the alternate screen, resize handling, 30fps adaptive
rendering (15 over SSH), and a terminal that is restored however the process
dies.

Run the examples:

```bash
zig build run-hello              # the smallest app
zig build run-dashboard-mini     # a small dashboard
zig build run-widgets            # every widget
zig build run-screenshot         # renders to stdout, no TTY needed
zig build run-screenshot -- --html   # a standalone HTML page
```

## Your state stays yours

Zig has no closures, so the two places the reference uses them work differently
here. Both changes point the same way: the data flows through you rather than
around you.

**A nested container takes a `Body`** — your context pointer beside a plain
function. **Interaction is inverted**: a control is given an `id`, and the app
tells you what happened to it. Nothing calls back into your state while you are
holding it.

```zig
const State = struct {
    selected: usize = 0,
    rows: []const Process,

    fn view(self: *State, ui: *zortui.Container) anyerror!void {
        try ui.panel(.{ .title = "Processes" }, zortui.Body.with(self, table));
    }

    fn table(self: *State, p: *zortui.Container) anyerror!void {
        try p.table(.{ .rows = self.buildRows(p), .selected = self.selected }, "procs");
    }
};

while (app.running()) {
    for (try app.poll()) |event| switch (event) {
        .key => |k| if (std.mem.eql(u8, k.name, "down")) { state.selected += 1; },
        else => {},
    };
    // The wheel and clicks act on whatever is under the pointer.
    if (app.clickedRow("procs")) |row| state.selected = row;
    state.selected +|= @intCast(@max(0, app.scrolled("procs")));

    _ = try app.draw(zortui.Body.with(&state, State.view));
}
```

The loop is a few lines, and it is visible. No reference counting, no callbacks
into the app, no lifetime puzzles.

## Frame memory

A child is drawn *after* the function that declared it returns — that is how
`fr` sizing works without a retained tree — so anything a widget points at has
to outlive the frame, not the call. Slices into your state and string literals
are fine. A stack buffer is not.

Two arenas make that safe:

- The **frame arena** is reset at the top of `draw`. `p.fmt("{d}%", .{n})` and
  `p.dupe(text)` allocate there, which is how you put a computed string on
  screen. Hit regions and focus ids also live there and stay readable until the
  *next* `draw`, which is what lets `poll` dispatch a click against the layout
  that is actually on screen.
- The **event arena** is reset at the top of `poll` and owns the ids
  `app.pressed("save")` matches against, so a button's id is still valid after
  the frame that drew it has been torn down.

## Testing without a terminal

```zig
var screen = try zortui.renderToScreen(allocator, 80, 24, "dark", Body.plain(view));
defer screen.deinit();
try std.testing.expect(screen.contains("72%"));
```

`renderToScreen` also gives you `.ansi()` for a colored screenshot,
`.cell(x, y)` for structural assertions, `renderToHtml` for a standalone page,
and `.regions` so a test can prove a widget is actually reachable by a click.
The returned screen owns one arena, so a test frees one thing.

## How this stays honest

zortui replays the corpus of fixtures hqtui generates from its TypeScript
implementation (vendored in `conformance/fixtures`): the same widget arguments must produce the same cells, the same
colors and the same escape bytes.

```bash
zig build test         # conformance suite + example regression tests
```

That covers colors and all 256 palette quantizations, Unicode widths and
grapheme clustering, the layout solver, the framebuffer, the diff encoder's
exact output bytes, Braille rasterisation, every border style, the input
parser's 26 byte-chunk scenarios, all 53 widget scenes and 10 whole-screen
layouts.

## Where this differs from the reference, and why

Three places, all documented in the source at the point they matter:

**Bodies instead of closures**, and **ids instead of callbacks** — described
above. This is the only difference a reader of the reference will feel.

**The cluster table is a fixed arena.** Grapheme clusters are interned so a cell
stays one 32-bit value. The other ports grow a map; here it is a 2 MiB static
buffer sized to `MAX_CLUSTERS`, taken under an atomic spin lock. Contention is
effectively nil — one `memcpy` per *distinct* cluster ever seen — and it means
the renderer never allocates for text.

**NaN reaches the same pixels by a different route.** JavaScript propagates NaN
through `Math.min`, Rust saturates, Python raises, and in Zig `@intFromFloat` on
NaN is illegal behaviour rather than a wrong answer. Every comparison that can
see a NaN is written to fold it explicitly, so a `NaN` meter renders the same
empty bar in all five implementations.

Everything else — layout, widgets, colors, glyph selection, escape output — is
identical, and the conformance suite is what says so.

## Terminal handling

Zig's standard library carries the whole POSIX layer this needs, which makes
this the least indirect of the ports:

- **Raw mode** is `std.posix.tcgetattr` / `tcsetattr`. The flags are named
  booleans on a packed struct that std defines per architecture, so there is no
  bit layout to get wrong, and the original `termios` is handed back verbatim
  rather than reconstructed. The Rust port cannot see a correct `termios`
  without a dependency and shells out to `stty -g` instead.
- **Input is polled, not threaded.** `std.posix.poll` waits on stdin with a
  timeout, so the render loop gets an answer within a bounded time with no
  reader thread, no channel, and no synchronization at all. Rust, Go and Python
  each needed one of those. The Escape-key timeout falls out of the same call:
  `poll` returning zero *is* the elapsed time, so it costs no clock syscall
  either.
- **Window size** is one `TIOCGWINSZ` ioctl; **signals** go through
  `std.posix.sigaction` and only ever store to an atomic.

One Zig 0.16 consequence worth knowing: there is no ambient `getenv` any more.
The environment reaches a program through `main`'s `std.process.Init` parameter
and nowhere else, so capability detection needs you to pass it —
`.terminal = .{ .env = .fromEnviron(&init.minimal.environ) }`. Skip it and every
terminal is detected as a dumb one.

On **Windows** the same contract goes through the console API, and the
interactive `App` runs there in any console that accepts VT processing
(Windows 10 and later). The console is switched into VT mode in both directions —
`ENABLE_VIRTUAL_TERMINAL_PROCESSING` out, `ENABLE_VIRTUAL_TERMINAL_INPUT` in,
UTF-8 code pages both ways — so the escape sequences written and the bytes read
back are the ones a Unix tty carries, and the encoder and input parser are
shared unchanged. Both console modes and both code pages are saved on entry and
handed back on exit, on Ctrl+Break, and when the window closes.

Mouse reporting and text selection are either-or in a terminal: while an app
receives clicks, the terminal cannot use them to select. `mouse` in the
terminal options defaults to what the terminal supports. Set
`.terminal = .{ .mouse = false }` to leave selection and copy to the terminal:
no mouse-tracking sequence is sent, and on Windows the console keeps Quick Edit,
which is conhost's click-and-drag selection and is otherwise turned off for as
long as the app runs. With mouse reporting off, Windows Terminal and conhost
turn the wheel on the alternate screen into Up and Down keys by default.

Waiting for input is the one real difference. A console input handle also
wakes for focus, menu and key-release records, and a read after such a wake
blocks until a character comes, so those records are drained before a wake
counts as input. A console that accepts VT processing is detected as a
truecolor, Unicode terminal; `NO_COLOR`, `FORCE_COLOR` and the capability
overrides still win.

## Where time comes from

zortui reads a monotonic clock for three things: `Ctx.elapsed`, which animates
widgets; `FrameStats.render_ns`; and, on Windows, the deadlines that bound each
wait for input. By default that is its own clock — `clock_gettime(MONOTONIC)`
on POSIX, the performance counter on Windows — so there is nothing to link and
nothing to set.

An application that already owns time can hand it over. Pass a function that
returns monotonic nanoseconds:

```zig
fn hostClock() u64 {
    return host.monotonicNs();
}

var app = try zortui.App.init(init.gpa, .{
    .terminal = .{ .env = .fromEnviron(&init.minimal.environ) },
    .clock = hostClock,
});
```

Every time read in the library then goes through it; there is no second clock
behind its back. The origin is yours to choose, but the function must not go
backwards, and while the app is polling a real terminal it must keep pace with
real time, because the input waits count down against it. `App` hands the
function to its `Terminal`; set `.terminal.clock` yourself only when you use a
`Terminal` without an `App`. Neither is ever required: `Terminal.init` and
`size` read no time at all.

Durations are not time reads and do not use it: the `poll` timeout on POSIX,
the Escape-key rule built from those timeouts, and the sleeps and waits handed
to the kernel.

## License

MIT — see `LICENSE` and `NOTICE`.
