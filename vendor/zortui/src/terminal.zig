//! Owns the TTY: raw mode, alternate screen, mouse reporting, and — above all —
//! putting everything back. A crashed app must never leave an unusable shell.
//!
//! # How this talks to the operating system
//!
//! Zig's standard library carries the POSIX layer this needs, so unlike the Rust
//! port — which shells out to `stty -g` rather than hand-declare a `termios`
//! that differs per platform — everything here is a direct call:
//!
//! * **Raw mode** is `std.posix.tcgetattr` / `tcsetattr`. The flags are named
//!   booleans on a packed struct that std defines per architecture, so there is
//!   no bit layout to get wrong. The original `termios` is kept verbatim and
//!   handed straight back, which makes restoring exact rather than reconstructed.
//!
//! * **Input is polled, not threaded.** `std.posix.poll` waits on stdin with a
//!   timeout, so the render loop asks for input and gets an answer within a
//!   bounded time without a reader thread, a channel, or any synchronization at
//!   all. The other three ports each needed one of those; this port needs none,
//!   and the escape-key timeout falls out of the same call.
//!
//! * **Window size** is one `TIOCGWINSZ` ioctl, and **signals** go through
//!   `std.posix.sigaction`. The handler only stores to an atomic, which is
//!   async-signal-safe.
//!
//! # Windows
//!
//! The same contract through the console API, in `windows_console` at the
//! bottom of this file. The console is switched into VT mode in both
//! directions, so the bytes written are the escape sequences a Unix tty
//! interprets and the bytes read back are the ones a Unix tty would send: the
//! encoder and `InputParser` are shared unchanged. What differs is waiting. A
//! console input handle also wakes for records that read as zero bytes, and a
//! read after such a wake blocks, so those records are drained before the
//! question "is there input?" is answered.

const std = @import("std");
const builtin = @import("builtin");

const ansi = @import("ansi.zig");
const capabilities_mod = @import("capabilities.zig");
const input_mod = @import("input.zig");

const Capabilities = capabilities_mod.Capabilities;
const InputEvent = input_mod.InputEvent;
const InputParser = input_mod.InputParser;

const posix = std.posix;
const is_posix = builtin.os.tag != .windows;
/// Referenced only from the Windows branches, so a POSIX build never analyses
/// its externs.
const win32 = @import("win32.zig");

pub const TerminalSize = struct {
    columns: usize,
    rows: usize,
};

pub const Options = struct {
    /// Use the alternate screen so the user's scrollback survives.
    alternate_screen: bool = true,
    mouse: ?bool = null,
    hide_cursor: bool = true,
    bracketed_paste: ?bool = null,
    focus_events: ?bool = null,
    title: ?[]const u8 = null,
    capabilities: capabilities_mod.Overrides = .{},
    /// The process environment, for capability detection. Zig 0.16 hands this
    /// to `main` rather than exposing a global, so it has to be passed in;
    /// leaving it empty means detection sees nothing and falls back to the
    /// conservative defaults.
    env: capabilities_mod.Env = capabilities_mod.Env.empty,
    /// Restore the terminal on SIGTERM/SIGHUP — on Windows, on Ctrl+Break and
    /// on the console window closing. Default true.
    install_exit_handlers: bool = true,
    /// How long to wait before a lone ESC counts as the Escape key.
    escape_timeout_ms: u64 = 30,
};

// --------------------------------------------------------------- OS plumbing

var resized = std.atomic.Value(bool).init(false);
/// The signal that asked us to quit, or 0. Set from a handler, so it may only
/// ever be a plain atomic store.
var terminated = std.atomic.Value(u32).init(0);
var handlers_installed = std.atomic.Value(bool).init(false);

/// The `termios` captured when raw mode was entered, so it can be handed back
/// byte for byte. Global because the exit path has no `self` to reach for.
var saved_mode: ?posix.termios = null;
var raw_active = std.atomic.Value(bool).init(false);

fn onWinch(_: posix.SIG) callconv(.c) void {
    resized.store(true, .monotonic);
}

fn onTerminate(sig: posix.SIG) callconv(.c) void {
    terminated.store(@intFromEnum(sig), .monotonic);
}

/// Ask the kernel for the window size. Null when stdout is not a terminal.
fn windowSize() ?TerminalSize {
    if (!is_posix) return windows_console.windowSize();
    var ws: posix.winsize = undefined;
    const request = posix.T.IOCGWINSZ;
    // `std.posix.system` is `std.os.linux` on bare Linux and `std.c` elsewhere,
    // and the two spell `ioctl` differently — one takes the argument as a
    // `usize`, the other is variadic.
    const failed = if (comptime builtin.os.tag == .linux and !builtin.link_libc)
        posix.errno(std.os.linux.ioctl(1, request, @intFromPtr(&ws))) != .SUCCESS
    else
        std.c.ioctl(1, @intCast(request), &ws) != 0;
    if (failed or ws.col == 0 or ws.row == 0) return null;
    return .{ .columns = ws.col, .rows = ws.row };
}

fn enterRawMode() bool {
    if (!is_posix) return windows_console.enter();
    const original = posix.tcgetattr(0) catch return false;
    saved_mode = original;

    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    // `ISIG` off matters: Ctrl+C has to arrive as a keystroke, because quitting
    // is the application's decision and the quit keys are configurable.
    raw.lflag.ISIG = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    posix.tcsetattr(0, .FLUSH, raw) catch return false;
    raw_active.store(true, .monotonic);
    return true;
}

fn leaveRawMode() void {
    if (!is_posix) return windows_console.leave();
    if (!raw_active.swap(false, .monotonic)) return;
    if (saved_mode) |mode| {
        posix.tcsetattr(0, .FLUSH, mode) catch {};
        saved_mode = null;
    }
}

/// Restoring is not negotiable — a crash must not leave an unusable shell — but
/// deciding the process should die is the host's call, not a rendering
/// library's. So the handlers here only record the signal; the app loop notices
/// and exits on its own terms.
fn installExitHandlers() void {
    if (!is_posix) return windows_console.installCtrlHandler();
    if (handlers_installed.swap(true, .monotonic)) return;

    var winch: posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &winch, null);

    var quit: posix.Sigaction = .{
        .handler = .{ .handler = onTerminate },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(.TERM, &quit, null);
    posix.sigaction(.HUP, &quit, null);
    // SIGINT is delivered only if raw mode failed; with ISIG cleared, Ctrl+C
    // arrives as a keystroke instead.
    posix.sigaction(.INT, &quit, null);
}

/// Zig 0.16 moved buffered file writing behind an `Io` handle, which a terminal
/// restore path cannot always reach for — `emergencyRestore` has no allocator
/// and no context. The raw syscall is what both need, and this module is
/// already at that level for `poll`, `ioctl` and `termios`.
fn writeOut(data: []const u8) void {
    if (!is_posix) return windows_console.write(data);
    var at: usize = 0;
    while (at < data.len) {
        const rc = posix.system.write(1, data[at..].ptr, data.len - at);
        const written: isize = @bitCast(@as(usize, @bitCast(rc)));
        if (written <= 0) return;
        at += @intCast(written);
    }
}

/// True when stdout is a terminal. `isatty` is gone from `std.posix` in 0.16,
/// and asking for the terminal attributes is what it did anyway. On Windows a
/// "terminal" is a console that accepts VT processing: one that does not would
/// print every escape sequence as text, which is worse than no color at all.
fn isTty() bool {
    if (!is_posix) return windows_console.isVtConsole();
    _ = posix.tcgetattr(1) catch return false;
    return true;
}

/// Restores the terminal for a process that lost its `Terminal`. Safe to call
/// twice, and safe to call from a crash path.
pub fn emergencyRestore() void {
    writeOut(ansi.reset ++ ansi.focus_off ++ ansi.bracketed_paste_off ++
        ansi.mouse_off ++ ansi.cursor_show ++ ansi.alternate_screen_off);
    leaveRawMode();
}

// ------------------------------------------------------------------ terminal

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    capabilities: Capabilities,
    options: Options,
    parser: InputParser,
    entered: bool = false,
    raw_was_set: bool = false,
    /// Bytes that ended mid-character, held until the rest of them arrive.
    partial: std.ArrayList(u8) = .empty,
    /// Decoded text handed to the parser, kept so its slices stay alive.
    decoded: std.ArrayList(u8) = .empty,
    /// Milliseconds spent waiting since the last byte arrived, for the ESC
    /// timeout. Accumulated from the poll budget rather than read off a clock:
    /// `poll` returning zero means the whole timeout elapsed, which is the only
    /// fact the 30 ms Escape rule needs, and it costs no syscall.
    waited_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Terminal {
        const tty = isTty();
        return .{
            .allocator = allocator,
            // On Windows `isTty` already means a console that took VT
            // processing, which is what earns truecolor and Unicode there.
            .capabilities = capabilities_mod.detectWithConsole(
                options.capabilities,
                options.env,
                tty,
                !is_posix and tty,
            ),
            .options = options,
            .parser = InputParser.init(allocator),
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.restore();
        self.parser.deinit();
        self.partial.deinit(self.allocator);
        self.decoded.deinit(self.allocator);
        self.* = undefined;
    }

    /// The current window size, falling back the way the reference does: the
    /// kernel, then `COLUMNS`/`LINES`, then 80x24. Anything that is not a
    /// positive number means "ask somewhere else" — some ptys report zero,
    /// which would otherwise leave a 0x0 framebuffer that renders nothing.
    pub fn size(self: Terminal) TerminalSize {
        if (windowSize()) |s| return s;
        return .{
            .columns = envSize(self.options.env, "COLUMNS") orelse 80,
            .rows = envSize(self.options.env, "LINES") orelse 24,
        };
    }

    /// True when a SIGWINCH — on Windows, a console buffer-size event — has
    /// arrived since this was last called.
    pub fn takeResize(self: Terminal) bool {
        _ = self;
        return resized.swap(false, .monotonic);
    }

    /// The signal that asked the process to quit, if one has arrived.
    pub fn terminationSignal(self: Terminal) ?u32 {
        _ = self;
        const sig = terminated.load(.monotonic);
        return if (sig == 0) null else sig;
    }

    pub fn write(self: Terminal, data: []const u8) void {
        _ = self;
        writeOut(data);
    }

    /// Enter full-screen mode. Idempotent.
    pub fn enter(self: *Terminal) !void {
        if (self.entered) return;
        self.entered = true;

        const mouse = self.options.mouse orelse self.capabilities.mouse;
        const paste = self.options.bracketed_paste orelse self.capabilities.bracketed_paste;
        const focus = self.options.focus_events orelse self.capabilities.focus_events;

        var setup: std.ArrayList(u8) = .empty;
        defer setup.deinit(self.allocator);

        if (self.options.alternate_screen) {
            try setup.appendSlice(self.allocator, ansi.alternate_screen_on);
        }
        if (self.options.hide_cursor) try setup.appendSlice(self.allocator, ansi.cursor_hide);
        if (mouse and self.capabilities.mouse) {
            try setup.appendSlice(self.allocator, ansi.mouse_on);
        }
        if (paste) try setup.appendSlice(self.allocator, ansi.bracketed_paste_on);
        if (focus) try setup.appendSlice(self.allocator, ansi.focus_on);
        if (self.options.title) |title| {
            const seq = try ansi.setTitle(self.allocator, title);
            defer self.allocator.free(seq);
            try setup.appendSlice(self.allocator, seq);
        }
        try setup.appendSlice(self.allocator, ansi.clear_screen);
        try setup.appendSlice(self.allocator, ansi.cursor_home);

        // A Windows console prints escape sequences as literal text until VT
        // processing is on, and turning it on is part of entering raw mode
        // there, so on Windows that has to come first. A POSIX tty interprets
        // the sequences either way and keeps its original order.
        if (!is_posix and self.capabilities.tty) self.raw_was_set = enterRawMode();
        self.write(setup.items);

        if (is_posix and self.capabilities.tty) self.raw_was_set = enterRawMode();
        if (self.options.install_exit_handlers) installExitHandlers();
    }

    /// Put the terminal back exactly as it was found. Safe to call twice.
    pub fn restore(self: *Terminal) void {
        if (!self.entered) return;
        self.entered = false;

        const mouse = self.options.mouse orelse self.capabilities.mouse;
        const paste = self.options.bracketed_paste orelse self.capabilities.bracketed_paste;
        const focus = self.options.focus_events orelse self.capabilities.focus_events;

        var teardown: std.ArrayList(u8) = .empty;
        defer teardown.deinit(self.allocator);

        // Every append here is best-effort: restoring the terminal must not be
        // skipped because a growth failed, so a short teardown still goes out.
        teardown.appendSlice(self.allocator, ansi.reset) catch {};
        if (focus) teardown.appendSlice(self.allocator, ansi.focus_off) catch {};
        if (paste) teardown.appendSlice(self.allocator, ansi.bracketed_paste_off) catch {};
        if (mouse) teardown.appendSlice(self.allocator, ansi.mouse_off) catch {};
        if (self.options.hide_cursor) {
            teardown.appendSlice(self.allocator, ansi.cursor_show) catch {};
        }
        teardown.appendSlice(
            self.allocator,
            if (self.options.alternate_screen) ansi.alternate_screen_off else "\n",
        ) catch {};
        self.write(teardown.items);

        if (self.raw_was_set) {
            leaveRawMode();
            self.raw_was_set = false;
        }
    }

    /// Every input event available within `timeout_ms`, decoded. Returns as soon
    /// as something arrives, so a keystroke is never delayed by the timeout.
    ///
    /// A lone ESC is only the Escape key once nothing follows it, so it is held
    /// back until `escape_timeout_ms` has passed with no further bytes.
    /// Returned slices stay valid until the next call.
    pub fn pollInput(self: *Terminal, timeout_ms: u64) ![]const InputEvent {
        const budget = @min(timeout_ms, std.math.maxInt(i32));

        if (!inputReady(budget)) {
            self.waited_ms += budget;
            if (self.parser.hasPending() and self.waited_ms >= self.options.escape_timeout_ms) {
                self.waited_ms = 0;
                return self.parser.flush();
            }
            return &.{};
        }

        var buf: [4096]u8 = undefined;
        const n = readInput(&buf);
        if (n == 0) return &.{};
        self.waited_ms = 0;

        try self.partial.appendSlice(self.allocator, buf[0..n]);

        // A read can end in the middle of a multi-byte character. Decode what
        // is whole and keep the tail for the next read, or the parser would see
        // a replacement character where a letter belongs.
        const valid = validUtf8Prefix(self.partial.items);
        self.decoded.clearRetainingCapacity();
        try self.decoded.appendSlice(self.allocator, self.partial.items[0..valid.len]);
        // An actually invalid sequence, rather than a truncated one, would
        // otherwise wedge the buffer for ever.
        const drop = valid.len + @as(usize, if (valid.invalid) 1 else 0);
        std.mem.copyForwards(u8, self.partial.items, self.partial.items[drop..]);
        self.partial.shrinkRetainingCapacity(self.partial.items.len - drop);

        return self.parser.parse(self.decoded.items);
    }
};

/// Wait up to `budget_ms` for stdin to hold something a read will return
/// without blocking.
fn inputReady(budget_ms: u64) bool {
    if (!is_posix) return windows_console.inputReady(budget_ms);
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, @intCast(budget_ms)) catch 0;
    return ready != 0 and fds[0].revents & posix.POLL.IN != 0;
}

/// One read of stdin. Zero means nothing: end of input or a failed read.
fn readInput(buf: []u8) usize {
    if (!is_posix) return windows_console.read(buf);
    return posix.read(0, buf) catch 0;
}

const Prefix = struct { len: usize, invalid: bool };

/// How much of `bytes` is complete UTF-8, and whether what follows is a truly
/// malformed byte rather than a sequence still in flight.
fn validUtf8Prefix(bytes: []const u8) Prefix {
    var at: usize = 0;
    while (at < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch {
            return .{ .len = at, .invalid = true };
        };
        if (at + len > bytes.len) return .{ .len = at, .invalid = false };
        _ = std.unicode.utf8Decode(bytes[at..][0..len]) catch {
            return .{ .len = at, .invalid = true };
        };
        at += len;
    }
    return .{ .len = at, .invalid = false };
}

fn envSize(env: capabilities_mod.Env, name: []const u8) ?usize {
    const raw = env.get(name);
    if (raw.len == 0) return null;
    const value = std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch
        return null;
    return if (value > 0) value else null;
}

// ----------------------------------------------------------- Windows console

/// The Windows half of the OS plumbing above: the same contract, through the
/// console API. Only referenced behind `!is_posix`, so a POSIX build never
/// analyses any of it.
const windows_console = struct {
    /// Everything raw mode changes, captured on entry and handed back
    /// verbatim, the way the POSIX path keeps its `termios`. Null or zero means
    /// "not changed, so not restored".
    const Saved = struct {
        input_mode: ?u32 = null,
        output_mode: ?u32 = null,
        input_cp: u32 = 0,
        output_cp: u32 = 0,
    };
    var saved: Saved = .{};

    const vt_output = win32.ENABLE_PROCESSED_OUTPUT | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING;

    /// How long a close event waits for the app loop to restore the console
    /// by itself before doing it from the handler thread.
    const close_grace_ms = 1000;
    /// Pipe handles cannot be waited on, so they are polled at this interval.
    const pipe_poll_ms = 5;

    fn stdin() ?win32.HANDLE {
        return win32.stdHandle(win32.STD_INPUT_HANDLE);
    }

    fn stdout() ?win32.HANDLE {
        return win32.stdHandle(win32.STD_OUTPUT_HANDLE);
    }

    fn nowMs() u64 {
        return win32.monotonicNs() / std.time.ns_per_ms;
    }

    /// A wait length for the kernel, which reads 0xFFFFFFFF as INFINITE.
    fn waitMs(ms: u64) u32 {
        return @intCast(@min(ms, std.math.maxInt(u32) - 1));
    }

    fn sleepUntil(deadline_ms: u64) void {
        const now = nowMs();
        if (now < deadline_ms) win32.Sleep(waitMs(deadline_ms - now));
    }

    /// `srWindow` is the visible part of the screen buffer, inclusive at both
    /// ends. `dwSize` would be the buffer, scrollback and all.
    fn windowSize() ?TerminalSize {
        const out = stdout() orelse return null;
        var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (win32.GetConsoleScreenBufferInfo(out, &info) == 0) return null;
        const columns = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const rows = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        if (columns <= 0 or rows <= 0) return null;
        return .{ .columns = @intCast(columns), .rows = @intCast(rows) };
    }

    /// stdout is a console that accepts VT processing. Probed by switching it
    /// on and straight back, so detection leaves the console as it found it;
    /// `enter` is what switches it on for the session.
    fn isVtConsole() bool {
        const out = stdout() orelse return false;
        var mode: u32 = 0;
        if (win32.GetConsoleMode(out, &mode) == 0) return false;
        if (mode & win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0) return true;
        if (win32.SetConsoleMode(out, mode | vt_output) == 0) return false;
        _ = win32.SetConsoleMode(out, mode);
        return true;
    }

    fn enter() bool {
        var changed = false;

        if (stdout()) |out| {
            var mode: u32 = 0;
            if (win32.GetConsoleMode(out, &mode) != 0) {
                // DISABLE_NEWLINE_AUTO_RETURN is the console's `OPOST` off: LF
                // stops implying CR, and writing the last column defers the
                // wrap the way a VT terminal does instead of scrolling. A
                // console too old to accept it still gets VT processing.
                const applied = win32.SetConsoleMode(out, mode | vt_output | win32.DISABLE_NEWLINE_AUTO_RETURN) != 0 or
                    win32.SetConsoleMode(out, mode | vt_output) != 0;
                if (applied) {
                    saved.output_mode = mode;
                    changed = true;
                    // The console decodes written bytes with its code page,
                    // 437 or 1252 out of the box, and the encoder writes UTF-8.
                    const cp = win32.GetConsoleOutputCP();
                    if (cp != 0 and cp != win32.CP_UTF8 and win32.SetConsoleOutputCP(win32.CP_UTF8) != 0) {
                        saved.output_cp = cp;
                    }
                }
            }
        }

        if (stdin()) |in| {
            var mode: u32 = 0;
            if (win32.GetConsoleMode(in, &mode) != 0) {
                // Line input and echo off are ICANON and ECHO off. Processed
                // input off is ISIG off: Ctrl+C arrives as the byte 0x03,
                // because quitting is the application's decision.
                var raw = mode & ~(win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT |
                    win32.ENABLE_PROCESSED_INPUT);
                // VT input makes the console encode keys, and mouse reports
                // once the app asks for them, as the byte sequences a Unix tty
                // sends, so `InputParser` needs no Windows dialect. Window
                // input adds a record on resize, which stands in for SIGWINCH.
                raw |= win32.ENABLE_VIRTUAL_TERMINAL_INPUT | win32.ENABLE_WINDOW_INPUT;
                // Quick Edit keeps mouse clicks in conhost for text selection,
                // so mouse reports would never reach the app. The bit only
                // means anything when the console reports extended flags, and
                // only then can the saved mode put it back exactly.
                if (mode & win32.ENABLE_EXTENDED_FLAGS != 0) raw &= ~win32.ENABLE_QUICK_EDIT_MODE;
                // tcsetattr(.FLUSH) drops unread input; so does this.
                _ = win32.FlushConsoleInputBuffer(in);
                if (win32.SetConsoleMode(in, raw) != 0) {
                    saved.input_mode = mode;
                    changed = true;
                    // Without this, a typed non-ASCII character reads back in
                    // the console's legacy code page and the UTF-8 decoder
                    // drops it.
                    const cp = win32.GetConsoleCP();
                    if (cp != 0 and cp != win32.CP_UTF8 and win32.SetConsoleCP(win32.CP_UTF8) != 0) {
                        saved.input_cp = cp;
                    }
                }
            }
        }

        if (changed) raw_active.store(true, .monotonic);
        return changed;
    }

    fn leave() void {
        if (!raw_active.swap(false, .monotonic)) return;
        if (saved.input_mode) |mode| if (stdin()) |in| {
            // Unread mouse reports would otherwise be typed into the shell.
            _ = win32.FlushConsoleInputBuffer(in);
            _ = win32.SetConsoleMode(in, mode);
        };
        if (saved.input_cp != 0) _ = win32.SetConsoleCP(saved.input_cp);
        if (saved.output_mode) |mode| if (stdout()) |out| {
            _ = win32.SetConsoleMode(out, mode);
        };
        if (saved.output_cp != 0) _ = win32.SetConsoleOutputCP(saved.output_cp);
        saved = .{};
    }

    /// WriteFile until every byte is out. A console or pipe may take a short
    /// count, and the count is a DWORD, so this chunks and loops.
    fn write(data: []const u8) void {
        const out = stdout() orelse return;
        var at: usize = 0;
        while (at < data.len) {
            const chunk: u32 = @intCast(@min(data.len - at, std.math.maxInt(u32)));
            var written: u32 = 0;
            if (win32.WriteFile(out, data[at..].ptr, chunk, &written, null) == 0) return;
            if (written == 0) return;
            at += written;
        }
    }

    /// One ReadFile. A failure is end of input too: a pipe whose writer has
    /// gone reports ERROR_BROKEN_PIPE rather than a zero-byte success.
    fn read(buf: []u8) usize {
        const in = stdin() orelse return 0;
        const want: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        var n: u32 = 0;
        if (win32.ReadFile(in, buf.ptr, want, &n, null) == 0) return 0;
        return n;
    }

    fn inputReady(budget_ms: u64) bool {
        const in = stdin() orelse {
            sleepUntil(nowMs() + budget_ms);
            return false;
        };
        var mode: u32 = 0;
        if (win32.GetConsoleMode(in, &mode) != 0) return consoleReady(in, budget_ms);
        return switch (win32.GetFileType(in)) {
            win32.FILE_TYPE_PIPE => pipeReady(in, budget_ms),
            // A file never blocks a read, and at its end the read returns
            // zero — which is what `poll` reports for a file on POSIX too.
            else => true,
        };
    }

    /// A console input handle is signalled whenever its queue holds any
    /// record: focus, menu, key releases, resizes. ReadFile turns those into
    /// zero bytes and keeps blocking until a character comes, which would
    /// freeze the render loop for as long as the user is not typing. So
    /// records at the front of the queue that carry no character are taken
    /// off before a wake counts as input.
    fn consoleReady(in: win32.HANDLE, budget_ms: u64) bool {
        const deadline = nowMs() + budget_ms;
        while (true) {
            switch (drainToCharacter(in)) {
                .character => return true,
                .empty => {},
                .failed => {
                    sleepUntil(deadline);
                    return false;
                },
            }
            const now = nowMs();
            if (now >= deadline) return false;
            const woke = win32.WaitForSingleObject(in, waitMs(deadline - now));
            if (woke != win32.WAIT_OBJECT_0) {
                // WAIT_TIMEOUT has already spent the budget; WAIT_FAILED has
                // not, and returning at once would spin the caller.
                sleepUntil(deadline);
                return false;
            }
        }
    }

    const Front = enum { character, empty, failed };

    fn drainToCharacter(in: win32.HANDLE) Front {
        var record: win32.INPUT_RECORD = undefined;
        while (true) {
            var count: u32 = 0;
            if (win32.PeekConsoleInputW(in, @ptrCast(&record), 1, &count) == 0) return .failed;
            if (count == 0) return .empty;
            if (yieldsCharacter(record)) return .character;
            if (record.EventType == win32.WINDOW_BUFFER_SIZE_EVENT) resized.store(true, .monotonic);
            if (win32.ReadConsoleInputW(in, @ptrCast(&record), 1, &count) == 0) return .failed;
        }
    }

    /// Whether ReadFile turns this record into bytes: a key press carrying a
    /// character. With VT input on, arrows, function keys and mouse reports
    /// arrive as presses carrying the characters of their escape sequences.
    /// The one character delivered on a release is an Alt+numpad code, which
    /// comes when Alt goes up.
    fn yieldsCharacter(record: win32.INPUT_RECORD) bool {
        if (record.EventType != win32.KEY_EVENT) return false;
        const key = record.Event.KeyEvent;
        if (key.UnicodeChar == 0) return false;
        return key.bKeyDown != 0 or key.wVirtualKeyCode == win32.VK_MENU;
    }

    /// A pipe handle is always signalled, so waiting on it says nothing; the
    /// queue is asked for its byte count instead, a few milliseconds apart.
    /// This is stdin under mintty and anything else that pipes into the app.
    fn pipeReady(in: win32.HANDLE, budget_ms: u64) bool {
        const deadline = nowMs() + budget_ms;
        while (true) {
            var available: u32 = 0;
            if (win32.PeekNamedPipe(in, null, 0, null, &available, null) == 0) {
                // The writer has gone and nothing will ever arrive. Waiting
                // out the budget keeps the loop at its frame rate rather than
                // spinning a core.
                sleepUntil(deadline);
                return false;
            }
            if (available > 0) return true;
            const now = nowMs();
            if (now >= deadline) return false;
            win32.Sleep(waitMs(@min(deadline - now, pipe_poll_ms)));
        }
    }

    fn installCtrlHandler() void {
        if (handlers_installed.swap(true, .monotonic)) return;
        _ = win32.SetConsoleCtrlHandler(onCtrl, 1);
    }

    /// Runs on a thread the system starts for it. Like the POSIX handlers it
    /// records rather than decides: the app loop sees `terminated` and exits on
    /// its own terms. Each event is stored as the signal number it corresponds
    /// to, so `terminationSignal` reads the same on both systems.
    fn onCtrl(ctrl_type: u32) callconv(.winapi) win32.BOOL {
        const signal: u32 = switch (ctrl_type) {
            // Only delivered if raw mode failed; otherwise Ctrl+C is a key.
            win32.CTRL_C_EVENT => 2, // SIGINT
            win32.CTRL_BREAK_EVENT => 21, // SIGBREAK, the Windows C runtime's number
            win32.CTRL_CLOSE_EVENT => 1, // SIGHUP: the terminal went away
            else => 15, // SIGTERM: logoff, shutdown
        };
        terminated.store(signal, .monotonic);

        if (ctrl_type != win32.CTRL_C_EVENT and ctrl_type != win32.CTRL_BREAK_EVENT) {
            // Close, logoff and shutdown end the process as soon as this
            // returns, so the loop may never get its turn. Give it a moment to
            // restore by itself, and restore from here if it has not.
            var waited: u32 = 0;
            while (raw_active.load(.monotonic) and waited < close_grace_ms) : (waited += 10) {
                win32.Sleep(10);
            }
            if (raw_active.load(.monotonic)) emergencyRestore();
        }
        // Handled: the default handler would ExitProcess before any restore.
        return 1;
    }
};

test "validUtf8Prefix holds back a split character" {
    // "é" is two bytes; a read that ends between them must decode nothing yet.
    const split = "a\xc3";
    const prefix = validUtf8Prefix(split);
    try std.testing.expectEqual(@as(usize, 1), prefix.len);
    try std.testing.expect(!prefix.invalid);

    const whole = validUtf8Prefix("aé");
    try std.testing.expectEqual(@as(usize, 3), whole.len);

    // A continuation byte with no lead byte can never complete.
    const broken = validUtf8Prefix("\x80");
    try std.testing.expectEqual(@as(usize, 0), broken.len);
    try std.testing.expect(broken.invalid);
}
