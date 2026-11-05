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

// childEcho goes through runCapture, which builds a fresh Threaded per call and
// so always sees the environment of the moment. spawnPiped (MCP servers,
// sidecars) goes through fsio.io()'s Threaded, which lives for the whole process.
// POSIX only: Windows reads its environment block live at every spawn, and has
// no /bin/sh to ask.
test "setenv: a child started through spawnPiped sees values set after fsio.io() was built" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    _ = fsio.io();
    // Several NEW names: each one makes glibc move environ, and each move frees
    // the array before it -- the array io() may still be holding.
    var name_buf: [64]u8 = undefined;
    for (0..8) |i| {
        const name = try std.fmt.bufPrintZ(&name_buf, "WINTERMOLT_ENVTEST_PIPED_{d}", .{i});
        try testing.expectEqual(@as(c_int, 0), setenvZ(name, "piped", 1));
    }
    var child = try fsio.spawnPiped(testing.allocator, &.{ "/bin/sh", "-c", "test \"$WINTERMOLT_ENVTEST_PIPED_7\" = piped" });
    const term = try fsio.waitChild(&child);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

// The OpenAI backend speaks Chat Completions to whatever URL this names, so any
// OpenAI-compatible server (LiteLLM, vLLM, llama.cpp, OpenRouter) can stand in.
test "Config.load: WINTERMOLT_OPENAI_URL names the OpenAI endpoint, api.openai.com when unset" {
    const key = "WINTERMOLT_OPENAI_URL";
    if (compat.getenv(key) == null) {
        const unset = try config.Config.load(null);
        try testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", unset.openai_url);
    }
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "http://127.0.0.1:4000/v1/chat/completions", 1));
    const set = try config.Config.load(null);
    try testing.expectEqualStrings("http://127.0.0.1:4000/v1/chat/completions", set.openai_url);
}

// A non-interactive run (-e, --web, --gateway, --chat) has no /model command to
// type, so the backend it starts on has to come from the environment. AgentLoop
// .init builds it from this, which is what makes every loop of the run follow
// it. Empty means unset: a `WINTERMOLT_BACKEND=` line in .env is not a request.
test "Config.load: WINTERMOLT_BACKEND names the startup backend; null when unset or empty" {
    const key = "WINTERMOLT_BACKEND";
    if (compat.getenv(key) == null) {
        const unset = try config.Config.load(null);
        try testing.expect(unset.backend == null);
    }
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "openai", 1));
    const set = try config.Config.load(null);
    try testing.expectEqualStrings("openai", set.backend orelse "");

    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "", 1));
    const empty = try config.Config.load(null);
    try testing.expect(empty.backend == null);
}

// WINTERMOLT_BACKEND picks where a request goes, not which model it asks for:
// a named model is used as-is by whichever backend is selected, and only then
// does the backend's own variable and documented default apply. AgentLoop.init
// passes config.model for this flag; switchBackend's per-backend defaults need
// it to be null.
test "Config.load: a named model outranks the backend's default; unnamed when WINTERMOLT_MODEL is unset" {
    const key = "WINTERMOLT_MODEL";
    if (compat.getenv(key) == null) {
        const unnamed = try config.Config.load(null);
        try testing.expect(!unnamed.model_named);
        try testing.expectEqualStrings(config.default_local_model, unnamed.model);
    }
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "stub-model", 1));
    const named = try config.Config.load(null);
    try testing.expect(named.model_named);
    try testing.expectEqualStrings("stub-model", named.model);
}

// A harness that asked for one provider has to see that provider fail. With
// the fallback on, an Ollama answer stands in for it and `-e` exits 0.
test "Config.load: WINTERMOLT_NO_FALLBACK=1 turns the fallback chain off; on when unset" {
    const key = "WINTERMOLT_NO_FALLBACK";
    if (compat.getenv(key) == null) {
        const unset = try config.Config.load(null);
        try testing.expect(unset.fallback_enabled);
    }
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "1", 1));
    const set = try config.Config.load(null);
    try testing.expect(!set.fallback_enabled);
}

// A model without function calling refuses any request that declares tools,
// so it cannot run in the tool loop at all unless none are sent.
test "Config.load: WINTERMOLT_NO_TOOLS=1 stops sending tool definitions; sent when unset" {
    const key = "WINTERMOLT_NO_TOOLS";
    if (compat.getenv(key) == null) {
        const unset = try config.Config.load(null);
        try testing.expect(unset.tools_enabled);
    }
    try testing.expectEqual(@as(c_int, 0), setenvZ(key, "1", 1));
    const set = try config.Config.load(null);
    try testing.expect(!set.tools_enabled);
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

// --keys / --setup rewrote ~/.wintermolt/.env with only the keys it asks about,
// so a setting added by hand (WINTERMOLT_STT_PROVIDER, the /theme line, a
// comment) was lost on every re-run. saveEnv keeps every line it did not ask
// about, byte for byte.

const setup = @import("setup.zig");

test "setup.saveEnv: lines the wizard does not ask about survive a re-run; its own keys are replaced or removed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "home/.wintermolt/.env";

    // Hand-added lines, a wizard key in export form, a wizard key the user no
    // longer chose (WINTERMOLT_TIER), and a duplicated wizard key.
    const existing = "# my own note\r\nWINTERMOLT_STT_PROVIDER=deepgram\r\nexport DEEPGRAM_API_KEY='old-dummy'\r\nWINTERMOLT_TIER=opus\r\n" ++
        "WINTERMOLT_CONFIG_VERSION=1\r\nWINTERMOLT_THEME=nord\r\nDEEPGRAM_API_KEY=older-dummy\r\n";
    try tmp.dir.createDirPath(io, "home/.wintermolt");
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = existing });

    const keys = [_]setup.KeyValue{
        .{ .key = "DEEPGRAM_API_KEY", .value = "new-dummy" },
        .{ .key = "ANTHROPIC_API_KEY", .value = "dummy-anthropic" },
    };
    try setup.saveEnv(gpa, io, tmp.dir, path, &keys);

    const text = try tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    const want = try std.fmt.allocPrint(gpa, "# my own note\r\nWINTERMOLT_STT_PROVIDER=deepgram\r\nDEEPGRAM_API_KEY=new-dummy\r\n" ++
        "WINTERMOLT_CONFIG_VERSION={d}\r\nWINTERMOLT_THEME=nord\r\nANTHROPIC_API_KEY=dummy-anthropic\r\n", .{config.CONFIG_VERSION});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, text);
}

test "setup.saveEnv: with no .env yet it writes the header, the version and the keys" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "home/.wintermolt/.env";

    const keys = [_]setup.KeyValue{.{ .key = "DEEPGRAM_API_KEY", .value = "new-dummy" }};
    try setup.saveEnv(gpa, io, tmp.dir, path, &keys);

    const text = try tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    const tail = try std.fmt.allocPrint(gpa, "\nDEEPGRAM_API_KEY=new-dummy\nWINTERMOLT_CONFIG_VERSION={d}\n", .{config.CONFIG_VERSION});
    defer gpa.free(tail);
    try testing.expect(std.mem.startsWith(u8, text, "# Wintermolt configuration"));
    try testing.expect(std.mem.endsWith(u8, text, tail));
}

/// Overwrite the stack below the caller, where a returned function's locals were.
noinline fn clobberStack() void {
    var junk: [16 * 1024]u8 = undefined;
    @memset(&junk, ' ');
    std.mem.doNotOptimizeAway(&junk);
}

// loadExistingEnv's values pointed into its own stack buffer, so by the time
// --keys offered them as defaults (or /keys wrote them back) they were
// whatever the stack held next: a kept Deepgram key came back as 20 spaces.
test "setup.loadExistingEnv: values outlive the call that read them" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(home);
    const home_z = try gpa.dupeZ(u8, home);
    defer gpa.free(home_z);
    try tmp.dir.createDirPath(testing.io, ".wintermolt");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".wintermolt/.env", .data = "# note\nDEEPGRAM_API_KEY=dummy-deepgram-value\n" });

    const prev_home: ?[:0]u8 = if (compat.getenv("HOME")) |h| try gpa.dupeZ(u8, h) else null;
    defer if (prev_home) |h| {
        _ = libc_setenv("HOME", h.ptr, 1);
        gpa.free(h);
    };
    try testing.expectEqual(@as(c_int, 0), libc_setenv("HOME", home_z.ptr, 1));

    var existing = @call(.never_inline, setup.loadExistingEnv, .{arena.allocator()});
    clobberStack();
    try testing.expectEqualStrings("dummy-deepgram-value", existing.get("DEEPGRAM_API_KEY") orelse return error.KeyNotLoaded);
}

// /keys rebuilt the whole .env from a map: comments gone, order shuffled,
// every value re-quoted. setEnvKey changes one key and keeps the rest.
test "setup.setEnvKey: sets one key in place, clears another, keeps comments and every other line" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "home/.wintermolt/.env";
    try tmp.dir.createDirPath(io, "home/.wintermolt");
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "# my note\r\nDEEPGRAM_API_KEY=keep-dummy\r\nOPENAI_API_KEY=\"old-dummy\"\r\nWINTERMOLT_THEME=nord\r\n" });

    try setup.setEnvKey(gpa, io, tmp.dir, path, "OPENAI_API_KEY", "new-dummy");
    try setup.setEnvKey(gpa, io, tmp.dir, path, "DEEPGRAM_API_KEY", null);

    const text = try tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    const want = try std.fmt.allocPrint(gpa, "# my note\r\nOPENAI_API_KEY=new-dummy\r\nWINTERMOLT_THEME=nord\r\nWINTERMOLT_CONFIG_VERSION={d}\r\n", .{config.CONFIG_VERSION});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, text);
}
