// compat.zig — POSIX compat shim used by the winX86 target branch.
//
// Each helper here matches the semantics of the std.posix.* call it replaces,
// but compiles cleanly on Windows (where std.posix.getenv, std.posix.poll,
// std.posix.fcntl and friends are unavailable or have different fd types).
//
// On non-Windows hosts these helpers delegate straight to std.posix so behavior
// is identical to pre-port.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// getenv — borrowed-slice env var lookup matching std.posix.getenv semantics.
//
// std.posix.getenv returns a slice into the process environment block with
// process lifetime. On Windows the env block is UTF-16 / WTF-16 internally, so
// we cache an owned UTF-8 copy per name and return a borrowed slice into it.
// =============================================================================

var env_cache: std.StringHashMap([]const u8) = undefined;
var env_cache_inited: bool = false;
var env_mutex: std.Thread.Mutex = .{};
const env_allocator = std.heap.page_allocator;

fn ensureEnvCache() void {
    if (!env_cache_inited) {
        env_cache = std.StringHashMap([]const u8).init(env_allocator);
        env_cache_inited = true;
    }
}

pub fn getenv(name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) {
        return std.posix.getenv(name);
    }

    env_mutex.lock();
    defer env_mutex.unlock();
    ensureEnvCache();

    if (env_cache.get(name)) |cached| {
        return if (cached.len == 0) null else cached;
    }

    const value = std.process.getEnvVarOwned(env_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => {
            const key_dup = env_allocator.dupe(u8, name) catch return null;
            env_cache.put(key_dup, "") catch {};
            return null;
        },
        else => return null,
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
// stdinReadyToRead — non-blocking "is there input on stdin?" check.
//
// On POSIX this is poll() with a 0ms timeout. On Windows we use
// WaitForSingleObject on the console input handle; it returns immediately and
// signals when any input event is pending in the queue.
// =============================================================================

pub fn stdinReadyToRead() bool {
    if (comptime builtin.os.tag == .windows) {
        const w = std.os.windows;
        const maybe_h = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
        const h = maybe_h orelse return false;
        if (h == w.INVALID_HANDLE_VALUE) return false;
        const r = w.kernel32.WaitForSingleObject(h, 0);
        return r == w.WAIT_OBJECT_0;
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
        const w = std.os.windows;
        const maybe_h = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
        const h = maybe_h orelse return;
        if (h == w.INVALID_HANDLE_VALUE) return;
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
