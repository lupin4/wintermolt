// Copyright The Fantastic Planet - By David Clabaugh
//
// env_tests.zig -- a value put into the environment at runtime must be visible
// to wintermolt's own getenv AND to every child process started afterwards.
//
// On Windows setenv was a no-op: ~/.wintermolt/.env "loaded" and none of its
// keys reached anything. These go through the same exported `setenv` symbol
// config.loadDotEnv links against, and through fsio.runCapture, the spawn path
// the bash tool uses, so they test the shipped route rather than a helper.
//
// Portable on purpose: on POSIX the same tests run against libc setenv.
//
// `zig build test-env` runs this file alone.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const compat = @import("compat.zig");
const fsio = @import("fsio.zig");
const config = @import("agent/config.zig");

const libc_setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });

fn setenvZ(name: [:0]const u8, value: [:0]const u8, overwrite: c_int) c_int {
    return libc_setenv(name.ptr, value.ptr, overwrite);
}

/// What a child shell prints for `key`, trimmed. Windows cmd.exe leaves
/// `%KEY%` unexpanded when the child's environment does not have it.
fn childEcho(gpa: std.mem.Allocator, key: []const u8) ![]u8 {
    const is_windows = builtin.os.tag == .windows;
    const command = if (is_windows)
        try std.fmt.allocPrint(gpa, "echo %{s}%", .{key})
    else
        try std.fmt.allocPrint(gpa, "printf '%s' \"${s}\"", .{key});
    defer gpa.free(command);
    const argv: []const []const u8 = if (is_windows)
        &[_][]const u8{ "cmd.exe", "/c", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };
    const run = try fsio.runCapture(gpa, argv, 4096, null);
    defer run.deinit(gpa);
    return gpa.dupe(u8, std.mem.trim(u8, run.stdout, " \r\n"));
}

test "setenv: a value set at runtime is visible to getenv, even after a cached miss" {
    const key = "WINTERMOLT_ENVTEST_VISIBLE";
    try testing.expect(compat.getenv(key) == null); // Windows caches this miss
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "visible-1", 1));
    try testing.expectEqualStrings("visible-1", compat.getenv(key) orelse return error.NotVisible);
}

test "setenv: overwrite=0 keeps an existing value and overwrite=1 replaces it" {
    const key = "WINTERMOLT_ENVTEST_OVERWRITE";
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "first", 1));
    try testing.expectEqualStrings("first", compat.getenv(key) orelse return error.NotVisible);
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "second", 0));
    try testing.expectEqualStrings("first", compat.getenv(key) orelse return error.NotVisible);
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "third", 1));
    try testing.expectEqualStrings("third", compat.getenv(key) orelse return error.NotVisible);
}

test "setenv: overwrite=0 treats a variable set to the empty string as set" {
    const key = "WINTERMOLT_ENVTEST_EMPTY";
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "", 1));
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "from-dotenv", 0));
    // getenv reports an empty value as null on Windows and as "" on POSIX;
    // either way it must not have become "from-dotenv".
    if (compat.getenv(key)) |v| try testing.expectEqualStrings("", v);
}

test "setenv: an empty name, or one containing '=', is refused" {
    try testing.expectEqual(@as(c_int, -1), setenvZ("", "x", 1));
    try testing.expectEqual(@as(c_int, -1), setenvZ("WINTERMOLT_ENVTEST=BAD", "x", 1));
}

test "setenv: a child process inherits a value set at runtime" {
    const gpa = testing.allocator;
    const key = "WINTERMOLT_ENVTEST_CHILD";
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "child-sees-me", 1));
    const out = try childEcho(gpa, key);
    defer gpa.free(out);
    try testing.expectEqualStrings("child-sees-me", out);
}

test "loadDotEnv: a key only in .env loads and reaches a child; the real environment beats .env" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // HOME points loadDotEnv at the temp dir, never at the real ~/.wintermolt.
    const home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(home);
    const home_z = try gpa.dupeZ(u8, home);
    defer gpa.free(home_z);
    const dir = try std.fmt.allocPrint(gpa, "{s}/.wintermolt", .{home});
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/.env", .{dir});
    defer gpa.free(path);

    try fsio.makePath(dir);
    {
        const file = try fsio.createFile(path, .{});
        defer fsio.close(file);
        try fsio.writeAll(file, "# written by env_tests.zig\r\n" ++
            "WINTERMOLT_ENVTEST_DOTENV_ONLY=\"from-dotenv\"\r\n" ++
            "export WINTERMOLT_ENVTEST_SHELL_WINS=from-dotenv\n");
    }

    const prev_home: ?[:0]u8 = if (compat.getenv("HOME")) |h| try gpa.dupeZ(u8, h) else null;
    defer if (prev_home) |h| {
        _ = libc_setenv("HOME", h.ptr, 1);
        gpa.free(h);
    };
    try testing.expectEqual(@as(c_int, 0), libc_setenv("HOME", home_z.ptr, 1));
    // The "real" environment: set before the file is read, as a shell would.
    try testing.expectEqual(@as(c_int, 0), setenvZ("WINTERMOLT_ENVTEST_SHELL_WINS", "from-shell", 1));

    config.loadDotEnv();

    try testing.expectEqualStrings("from-dotenv", compat.getenv("WINTERMOLT_ENVTEST_DOTENV_ONLY") orelse return error.DotEnvKeyNotLoaded);
    try testing.expectEqualStrings("from-shell", compat.getenv("WINTERMOLT_ENVTEST_SHELL_WINS") orelse return error.ShellValueLost);

    const only = try childEcho(gpa, "WINTERMOLT_ENVTEST_DOTENV_ONLY");
    defer gpa.free(only);
    try testing.expectEqualStrings("from-dotenv", only);
    const wins = try childEcho(gpa, "WINTERMOLT_ENVTEST_SHELL_WINS");
    defer gpa.free(wins);
    try testing.expectEqualStrings("from-shell", wins);
}
