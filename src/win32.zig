// win32.zig — the few kernel32 calls the Windows build makes directly.
//
// WINTERMOLT'S OWN COPY. Wintermute carries the same file; wintermolt is public
// OSS and references no sibling source, so it owns its copy.
//
// Copyright The Fantastic Planet — By David Clabaugh
//
// WHY THIS EXISTS
// ---------------
// Zig 0.16 took GetStdHandle, WriteFile, ReadFile and the console mode and
// code-page calls out of std.os.windows.kernel32, and removed std.fs.File and
// std.process.getEnvVarOwned, the two std paths that used to reach them. 0.15.2
// still has all of it. Declaring the handful used here gives ONE Windows path
// that compiles on both toolchains. Signatures follow 0.15.2's declarations.
//
// Everything here is referenced only behind `builtin.os.tag == .windows`, so a
// POSIX build never analyses it.

const std = @import("std");

pub const HANDLE = *anyopaque;

pub const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
pub const WAIT_OBJECT_0: u32 = 0;

const INVALID_HANDLE_VALUE: usize = std.math.maxInt(usize);
const CP_UTF8: u32 = 65001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: *anyopaque, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
pub extern "kernel32" fn WaitForSingleObject(hObject: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) c_int;

/// The process's standard handle, or null when it has none (a GUI-subsystem
/// launch, or a handle the parent closed).
pub fn stdHandle(which: u32) ?HANDLE {
    const h = GetStdHandle(which) orelse return null;
    if (@intFromPtr(h) == INVALID_HANDLE_VALUE) return null;
    return h;
}

/// True when `handle` is a console. GetConsoleMode fails on a pipe or a file,
/// which is how a redirected standard handle is told apart from a terminal.
pub fn isConsole(handle: ?HANDLE) bool {
    const h = handle orelse return false;
    var mode: u32 = 0;
    return GetConsoleMode(h, &mode) != 0;
}

pub const IoError = error{IoFailed};

/// WriteFile until every byte is gone. A single call may write a short count to
/// a pipe, and the count is a DWORD, so this loops and chunks.
pub fn writeAll(handle: ?HANDLE, bytes: []const u8) IoError!void {
    const h = handle orelse return IoError.IoFailed;
    var off: usize = 0;
    while (off < bytes.len) {
        const chunk: u32 = @intCast(@min(bytes.len - off, std.math.maxInt(u32)));
        var n: u32 = 0;
        if (WriteFile(h, bytes.ptr + off, chunk, &n, null) == 0) return IoError.IoFailed;
        if (n == 0) return IoError.IoFailed; // no progress
        off += n;
    }
}

/// One ReadFile; 0 means no more input.
///
/// A FAILED read also returns 0. When the write end of an anonymous pipe closes,
/// Windows reports it as a failure (ERROR_BROKEN_PIPE), not as a zero-byte
/// success — and for stdin both mean the same thing: input is over.
pub fn read(handle: ?HANDLE, buf: []u8) usize {
    const h = handle orelse return 0;
    if (buf.len == 0) return 0;
    const want: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
    var n: u32 = 0;
    if (ReadFile(h, buf.ptr, want, &n, null) == 0) return 0;
    return n;
}

/// An owned UTF-8 copy of an environment variable, or null when it is unset,
/// empty, or not representable as UTF-8 (an unpaired surrogate).
pub fn getenvOwned(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(name_w);
    var cap: u32 = 256;
    while (true) {
        const buf = alloc.alloc(u16, cap) catch return null;
        defer alloc.free(buf);
        const n = GetEnvironmentVariableW(name_w.ptr, buf.ptr, cap);
        if (n == 0) return null; // unset, or set to the empty string
        if (n < cap) return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch null;
        cap = n; // too small: n is the size needed, terminator included
    }
}

/// Set a variable in this process's environment block. False when either
/// string is not valid UTF-8 or Windows refuses it. Children spawned afterwards
/// inherit it: fsio spawns with the `.global` environ, which copies this block.
pub fn setenv(alloc: std.mem.Allocator, name: []const u8, value: []const u8) bool {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return false;
    defer alloc.free(name_w);
    const value_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return false;
    defer alloc.free(value_w);
    return SetEnvironmentVariableW(name_w.ptr, value_w.ptr) != 0;
}

/// True when `name` is set, INCLUDING set to the empty string, which
/// getenvOwned cannot tell from unset. Asked with no buffer, the call returns
/// the size the value needs, terminator included, so any set variable gives >= 1.
pub fn envExists(alloc: std.mem.Allocator, name: []const u8) bool {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return false;
    defer alloc.free(name_w);
    return GetEnvironmentVariableW(name_w.ptr, null, 0) != 0;
}

var saved_out_cp: u32 = 0;
var saved_in_cp: u32 = 0;

/// Put the console into UTF-8 with ANSI escapes for the life of the process.
///
/// A Windows console decodes output bytes with its code page — 437 or 1252 out
/// of the box — so every box-drawing character in the banner and every
/// non-ASCII byte a model streams back came out as mojibake unless the user had
/// first typed `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`.
/// Nobody running a downloaded binary knows to do that. A redirected handle is
/// not a console; GetConsoleMode fails on it and it is left alone.
pub fn initConsole() void {
    saved_out_cp = GetConsoleOutputCP(); // 0 when there is no console
    saved_in_cp = GetConsoleCP();
    if (saved_out_cp != 0 and saved_out_cp != CP_UTF8) _ = SetConsoleOutputCP(CP_UTF8);
    if (saved_in_cp != 0 and saved_in_cp != CP_UTF8) _ = SetConsoleCP(CP_UTF8);
    for ([_]u32{ STD_OUTPUT_HANDLE, STD_ERROR_HANDLE }) |which| {
        const h = stdHandle(which) orelse continue;
        var mode: u32 = 0;
        if (GetConsoleMode(h, &mode) == 0) continue;
        _ = SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}

/// Give the launching shell its code pages back.
pub fn restoreConsole() void {
    if (saved_out_cp != 0 and saved_out_cp != CP_UTF8) _ = SetConsoleOutputCP(saved_out_cp);
    if (saved_in_cp != 0 and saved_in_cp != CP_UTF8) _ = SetConsoleCP(saved_in_cp);
}

// ── randomness ──────────────────────────────────────────────────────────────
//
// fsio's version goes to libc getentropy, which does not exist on Windows.
// (Clocks are NOT here: they come from forTime's prebuilt archive; see fsio.zig.)

extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pbBuffer: [*]u8, cbBuffer: u32, dwFlags: u32) callconv(.winapi) i32;

/// Fill `buf` from the system CSPRNG. False if it refused -- a caller must not
/// build an identifier out of whatever was already in the buffer.
pub fn randomBytes(buf: []u8) bool {
    const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x00000002;
    var off: usize = 0;
    while (off < buf.len) {
        const chunk: u32 = @intCast(@min(buf.len - off, std.math.maxInt(u32)));
        if (BCryptGenRandom(null, buf.ptr + off, chunk, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return false;
        off += chunk;
    }
    return true;
}
