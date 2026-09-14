// compat.zig — POSIX compat shim used by the winX86 target branch.
//
// Each helper here matches the semantics of the std.posix.* call it replaces,
// but compiles cleanly on Windows (where std.posix.getenv, std.posix.poll,
// std.posix.fcntl and friends are unavailable or have different fd types).
//
// On non-Windows hosts these helpers delegate straight to std.posix so behavior
// is identical to pre-port.

const std = @import("std");
const fsio = @import("fsio.zig");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

// =============================================================================
// getenv — borrowed-slice env var lookup matching std.posix.getenv semantics.
//
// std.posix.getenv returns a slice into the process environment block with
// process lifetime. On Windows the env block is UTF-16 / WTF-16 internally, so
// we cache an owned UTF-8 copy per name and return a borrowed slice into it.
// =============================================================================

var env_cache: std.StringHashMap([]const u8) = undefined;
var env_cache_inited: bool = false;
var env_mutex: fsio.Mutex = fsio.mutex_init;
const env_allocator = std.heap.page_allocator;

fn ensureEnvCache() void {
    if (!env_cache_inited) {
        env_cache = std.StringHashMap([]const u8).init(env_allocator);
        env_cache_inited = true;
    }
}

pub fn getenv(name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) {
        // 0.16 removed std.posix.getenv along with the rest of the positionless
        // posix surface; its replacement reads a std.process.Environ threaded
        // from main, which a helper called from arbitrary depth does not have.
        // std.c.getenv is present and identically typed on every toolchain and
        // needs no Io -- the same reasoning that puts clocks on clock_gettime.
        if (comptime @hasDecl(std.posix, "getenv")) return std.posix.getenv(name);
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const v = std.c.getenv(@ptrCast(&buf)) orelse return null;
        return std.mem.span(v);
    }

    // WINDOWS HAS NO $HOME. It sets USERPROFILE.
    //
    // Dozens of call sites read getenv("HOME"), and several turn a miss into a
    // hard failure -- storage, scheduler, session and router all
    // `orelse return error.NoHomeDir`. Run from PowerShell or cmd, the program
    // came up with:
    //
    //   [storage] Init failed: NoHomeDir
    //   [scheduler] Init failed: NoHomeDir
    //
    // It only appeared to work when launched from MSYS2 or Git-Bash, which set
    // HOME themselves -- invisible to anyone developing in a POSIX-ish shell,
    // unavoidable for everyone else.
    //
    // Resolved HERE, not at the call sites: one place, no caller needs to know
    // the platform, and an explicitly set HOME still wins so a deliberate
    // override keeps working.
    if (std.mem.eql(u8, name, "HOME")) {
        if (lookupEnv("HOME")) |v| return v;
        return lookupEnv("USERPROFILE");
    }
    return lookupEnv(name);
}

fn lookupEnv(name: []const u8) ?[]const u8 {
    fsio.lock(&env_mutex);
    defer fsio.unlock(&env_mutex);
    ensureEnvCache();

    if (env_cache.get(name)) |cached| {
        return if (cached.len == 0) null else cached;
    }

    // std.process.getEnvVarOwned is gone in 0.16; GetEnvironmentVariableW via
    // win32.zig reads the same value on both toolchains.
    const value = win32.getenvOwned(env_allocator, name) orelse {
        const key_dup = env_allocator.dupe(u8, name) catch return null;
        env_cache.put(key_dup, "") catch {};
        return null;
    };
    const key_dup = env_allocator.dupe(u8, name) catch {
        env_allocator.free(value);
        return null;
    };
    env_cache.put(key_dup, value) catch {
        env_allocator.free(key_dup);
        env_allocator.free(value);
        return null;
    };
    return value;
}

// =============================================================================
// initConsole / restoreConsole — a UTF-8 console with no setup from the user.
//
// The banner's box drawing and anything non-ASCII a model streams back is UTF-8,
// and a Windows console decodes with its code page (437 / 1252 by default), so
// it all rendered as mojibake unless the user had first typed
// `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`. The program now
// does that itself on the way in and puts the old code pages back on the way
// out. No-op everywhere but Windows.
// =============================================================================

pub fn initConsole() void {
    if (comptime builtin.os.tag == .windows) win32.initConsole();
}

pub fn restoreConsole() void {
    if (comptime builtin.os.tag == .windows) win32.restoreConsole();
}

// =============================================================================
// stdioIsTerminal — are stdin AND stdout both an interactive terminal?
//
// Decides between the full-screen TUI and the plain REPL. Both ends, because
// the TUI reads raw keys from stdin and draws on stdout: `printf ... | wintermolt`
// (stdin a pipe) and `wintermolt > log` (stdout a file) must stay line-oriented.
// Windows: GetConsoleMode succeeds only on a console handle, so pipes, files and
// mintty's pty pipes all read as "not a terminal". POSIX: isatty.
// =============================================================================

pub fn stdioIsTerminal() bool {
    if (comptime builtin.os.tag == .windows) {
        return win32.isConsole(win32.stdHandle(win32.STD_INPUT_HANDLE)) and
            win32.isConsole(win32.stdHandle(win32.STD_OUTPUT_HANDLE));
    }
    return std.c.isatty(std.posix.STDIN_FILENO) != 0 and std.c.isatty(std.posix.STDOUT_FILENO) != 0;
}

// =============================================================================
// stdinReadyToRead — non-blocking "is there input on stdin?" check.
//
// On POSIX this is poll() with a 0ms timeout. On Windows we use
// WaitForSingleObject on the console input handle; it returns immediately and
// signals when any input event is pending in the queue.
// =============================================================================

pub fn stdinReadyToRead() bool {
    if (comptime builtin.os.tag == .windows) {
        // kernel32.GetStdHandle / WaitForSingleObject left std in 0.16.
        const h = win32.stdHandle(win32.STD_INPUT_HANDLE) orelse return false;
        return win32.WaitForSingleObject(h, 0) == win32.WAIT_OBJECT_0;
    }
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&poll_fds, 0) catch return false;
    return n > 0;
}

// =============================================================================
// drainStdinNonBlocking — flush any buffered stdin without blocking.
//
// Used after password-style prompts to clear extra pasted lines.
// =============================================================================

pub fn drainStdinNonBlocking() void {
    if (comptime builtin.os.tag == .windows) {
        const h = win32.stdHandle(win32.STD_INPUT_HANDLE) orelse return;
        _ = FlushConsoleInputBuffer(h);
        return;
    }
    const fd = std.posix.STDIN_FILENO;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK: u32 = if (comptime builtin.os.tag == .macos) 0x0004 else 0o4000;

    const flags = std.posix.system.fcntl(fd, F_GETFL);
    if (flags == -1) return;
    if (std.posix.system.fcntl(fd, F_SETFL, @as(u32, @bitCast(flags)) | O_NONBLOCK) == -1) return;
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = std.posix.system.read(fd, &buf, buf.len);
        if (rc <= 0) break;
    }
    _ = std.posix.system.fcntl(fd, F_SETFL, @as(u32, @bitCast(flags)));
}

extern "kernel32" fn FlushConsoleInputBuffer(handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;

// =============================================================================
// POSIX libc shims — Fortran/C code from forKernels sibling repos calls these
// directly. On Windows we provide no-op implementations so the link resolves;
// real behavior matters only on POSIX where the libc versions are used.
// =============================================================================

comptime {
    if (builtin.os.tag == .windows) {
        @export(&windowsSetenv, .{ .name = "setenv", .linkage = .strong });
        @export(&windowsSysconf, .{ .name = "sysconf", .linkage = .strong });
    }
}

fn windowsSetenv(name: ?[*:0]const u8, value: ?[*:0]const u8, overwrite: c_int) callconv(.c) c_int {
    _ = name;
    _ = value;
    _ = overwrite;
    return 0;
}

fn windowsSysconf(name: c_int) callconv(.c) c_long {
    _ = name;
    return -1;
}

// =============================================================================
// setSocketNonBlocking — put a socket in non-blocking mode.
//
// POSIX: fcntl(F_SETFL, O_NONBLOCK). Windows: ioctlsocket(FIONBIO, 1).
// =============================================================================

pub fn setSocketNonBlocking(sock: std.posix.socket_t) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        var mode: c_ulong = 1;
        if (ws2.ioctlsocket(sock, ws2.FIONBIO, &mode) != 0) return error.SetNonBlockFailed;
        return;
    }
    const fl = try std.posix.fcntl(sock, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(sock, std.posix.F.SETFL, fl | (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK")));
}
