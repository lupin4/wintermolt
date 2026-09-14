//! The handful of kernel32 calls the Windows build makes directly.
//!
//! Zig 0.16 took `GetStdHandle`, `ReadFile`, `WriteFile` and the console mode,
//! code page and screen buffer calls out of `std.os.windows.kernel32`, along
//! with the `std.fs.File` paths that used to reach them. A terminal backend is
//! nothing but those calls, so they are declared here, with the signatures the
//! Windows SDK gives them.
//!
//! Nothing outside a `builtin.os.tag == .windows` branch refers to this file,
//! so a POSIX build never analyses it and never asks its linker for kernel32.
//! It is deliberately not re-exported from `root.zig` for the same reason:
//! `refAllDecls` would otherwise drag every extern into a Linux test build.

const std = @import("std");

pub const HANDLE = *anyopaque;
/// Win32 `BOOL`: nonzero is success.
pub const BOOL = c_int;

// ---------------------------------------------------------------- handles

pub const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

const INVALID_HANDLE_VALUE: usize = std.math.maxInt(usize);

pub const FILE_TYPE_DISK: u32 = 0x0001;
pub const FILE_TYPE_CHAR: u32 = 0x0002;
pub const FILE_TYPE_PIPE: u32 = 0x0003;

pub const WAIT_OBJECT_0: u32 = 0;

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) u32;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hObject: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
pub extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// The process's standard handle, or null when it has none: a GUI-subsystem
/// launch, or a handle the parent closed.
pub fn stdHandle(which: u32) ?HANDLE {
    const h = GetStdHandle(which) orelse return null;
    if (@intFromPtr(h) == INVALID_HANDLE_VALUE) return null;
    return h;
}

// ---------------------------------------------------------------- console

pub const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
pub const ENABLE_LINE_INPUT: u32 = 0x0002;
pub const ENABLE_ECHO_INPUT: u32 = 0x0004;
pub const ENABLE_WINDOW_INPUT: u32 = 0x0008;
pub const ENABLE_QUICK_EDIT_MODE: u32 = 0x0040;
pub const ENABLE_EXTENDED_FLAGS: u32 = 0x0080;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;

pub const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: u32 = 0x0008;

pub const CP_UTF8: u32 = 65001;

pub const CTRL_C_EVENT: u32 = 0;
pub const CTRL_BREAK_EVENT: u32 = 1;
pub const CTRL_CLOSE_EVENT: u32 = 2;
pub const CTRL_LOGOFF_EVENT: u32 = 5;
pub const CTRL_SHUTDOWN_EVENT: u32 = 6;

pub const KEY_EVENT: u16 = 0x0001;
pub const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

pub const VK_MENU: u16 = 0x12;

pub const COORD = extern struct { X: i16, Y: i16 };
pub const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    UnicodeChar: u16,
    dwControlKeyState: u32,
};

/// Only the key member is ever read; the other four event kinds share the
/// same 16 bytes and are recognised by `EventType` alone.
pub const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        bytes: [16]u8,
    },
};

comptime {
    // The SDK's sizes. A wrong layout here would read garbage records rather
    // than fail, so it is pinned at compile time.
    std.debug.assert(@sizeOf(CONSOLE_SCREEN_BUFFER_INFO) == 22);
    std.debug.assert(@sizeOf(KEY_EVENT_RECORD) == 16);
    std.debug.assert(@sizeOf(INPUT_RECORD) == 20);
}

pub const HandlerRoutine = *const fn (dwCtrlType: u32) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
pub extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?HandlerRoutine, Add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn PeekConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: u32, lpNumberOfEventsRead: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: u32, lpNumberOfEventsRead: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: HANDLE) callconv(.winapi) BOOL;

// ------------------------------------------------------------------ clock

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;

/// Monotonic nanoseconds since boot, or 0 if the counter is unavailable (it
/// never is on anything since Windows XP, but 0 is the POSIX path's failure
/// value too).
///
/// Split into whole seconds and remainder before scaling: the counter ticks
/// at 10 MHz on current Windows, so `counter * 1e9` would overflow a u64 after
/// about thirty minutes of uptime.
pub fn monotonicNs() u64 {
    var counter: i64 = 0;
    var frequency: i64 = 0;
    if (QueryPerformanceCounter(&counter) == 0) return 0;
    if (QueryPerformanceFrequency(&frequency) == 0) return 0;
    if (counter <= 0 or frequency <= 0) return 0;
    const c: u64 = @intCast(counter);
    const f: u64 = @intCast(frequency);
    return (c / f) * std.time.ns_per_s + (c % f) * std.time.ns_per_s / f;
}
