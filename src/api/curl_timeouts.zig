// Copyright The Fantastic Planet - By David Clabaugh
//
// curl_timeouts.zig -- how long a model request may run.
//
// Call apply(handle, connect_secs) on every streaming chat request.
//
// WHY. Each client capped the WHOLE request: 90 s for the OpenAI-compatible
// ones, 120 s for Claude, 180 s for Ollama. A streamed answer is still
// healthy at minute three if tokens keep arriving, and a local engine can
// take half a minute to warm up before its first byte; both were cut off
// with "Timeout was reached". What a cap has to catch is a server that has
// gone quiet, so this drops a request only when nothing at all has arrived
// for WINTERMOLT_STALL_TIMEOUT seconds, however long it has been running.
// The connect timeout stays per client: a dead host still fails in seconds.

const compat = @import("../compat.zig");
const std = @import("std");

/// Seconds without a byte before a request is abandoned, when unset. The old
/// Ollama cap, so no backend gives up sooner than it did.
pub const default_stall_secs: u32 = 180;

/// WINTERMOLT_STALL_TIMEOUT, read per request so a value from ~/.wintermolt/.env
/// applies like any other.
pub fn stallSecs() u32 {
    return parseStallSecs(compat.getenv("WINTERMOLT_STALL_TIMEOUT"));
}

/// 0 means never give up on a quiet stream. Anything that is not a whole
/// number of seconds means the default.
pub fn parseStallSecs(raw: ?[]const u8) u32 {
    const text = std.mem.trim(u8, raw orelse return default_stall_secs, " \t\r\n");
    return std.fmt.parseInt(u32, text, 10) catch default_stall_secs;
}

// curl.h: CURLOPT(name, CURLOPTTYPE_LONG, n), and CURLOPTTYPE_LONG is 0.
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_LOW_SPEED_LIMIT: c_int = 19;
const CURLOPT_LOW_SPEED_TIME: c_int = 20;
const CURLOPT_CONNECTTIMEOUT: c_int = 78;

extern fn curl_easy_setopt(handle: *anyopaque, option: c_int, ...) c_int;

/// No cap on the whole request; drop it after stallSecs() below 1 byte/s.
pub fn apply(handle: *anyopaque, connect_secs: c_long) void {
    _ = curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, connect_secs);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 0));
    _ = curl_easy_setopt(handle, CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_LOW_SPEED_TIME, @as(c_long, @intCast(stallSecs())));
}

const testing = std.testing;

test "parseStallSecs: unset means the default" {
    try testing.expectEqual(default_stall_secs, parseStallSecs(null));
}

test "parseStallSecs: a whole number of seconds is taken as given" {
    try testing.expectEqual(@as(u32, 600), parseStallSecs("600"));
    try testing.expectEqual(@as(u32, 30), parseStallSecs(" 30\r\n"));
}

test "parseStallSecs: 0 means never give up on a quiet stream" {
    try testing.expectEqual(@as(u32, 0), parseStallSecs("0"));
}

test "parseStallSecs: anything else means the default" {
    try testing.expectEqual(default_stall_secs, parseStallSecs(""));
    try testing.expectEqual(default_stall_secs, parseStallSecs("abc"));
    try testing.expectEqual(default_stall_secs, parseStallSecs("-5"));
    try testing.expectEqual(default_stall_secs, parseStallSecs("2m"));
}
