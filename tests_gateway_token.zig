const std = @import("std");
const TOKEN_BYTES = 32;

// The auth path is: token -> "{x}" over the wire -> hexToBytes -> SHA-256.
// If the encode/decode pair is not exact, every paired device silently fails to
// authenticate, so pin it rather than trust that it compiled.
test "token hex round-trips through the wire format" {
    var token: [TOKEN_BYTES]u8 = undefined;
    std.crypto.random.bytes(&token);
    var hex: [TOKEN_BYTES * 2]u8 = undefined;
    const s = try std.fmt.bufPrint(&hex, "{x}", .{token});
    try std.testing.expectEqual(@as(usize, 64), s.len);
    var back: [TOKEN_BYTES]u8 = undefined;
    _ = try std.fmt.hexToBytes(&back, s);
    try std.testing.expectEqualSlices(u8, &token, &back);
}

// THE TRAP. hexToBytes does not error on a short input: it decodes what it can
// and returns a SHORT SLICE, leaving the rest of the destination uninitialized.
// Discarding that slice and hashing the whole array authenticates against
// uninitialized stack. This documents the real behaviour the fix guards.
test "hexToBytes silently under-fills on short input" {
    var back: [TOKEN_BYTES]u8 = undefined;
    const got = try std.fmt.hexToBytes(&back, "abcd");
    try std.testing.expectEqual(@as(usize, 2), got.len); // NOT an error, NOT 32
    try std.testing.expectError(error.InvalidCharacter, std.fmt.hexToBytes(&back, "zz" ** 32));
}

/// Mirrors bridge.zig's decodeToken.
fn decodeToken(hex: []const u8) ?[TOKEN_BYTES]u8 {
    if (hex.len != TOKEN_BYTES * 2) return null;
    var token: [TOKEN_BYTES]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&token, hex) catch return null;
    if (decoded.len != TOKEN_BYTES) return null;
    return token;
}

test "decodeToken rejects everything that is not a full token" {
    try std.testing.expect(decodeToken("abcd") == null); // short
    try std.testing.expect(decodeToken("") == null); // empty
    try std.testing.expect(decodeToken("ab" ** 33) == null); // long
    try std.testing.expect(decodeToken("zz" ** 32) == null); // non-hex
    var token: [TOKEN_BYTES]u8 = undefined;
    std.crypto.random.bytes(&token);
    var hex: [TOKEN_BYTES * 2]u8 = undefined;
    const s = try std.fmt.bufPrint(&hex, "{x}", .{token});
    const round = decodeToken(s) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &token, &round);
}

// Mirrors bridge.zig's jsonFlag so the capability parsing is covered.
fn jsonFlag(json: []const u8, key: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":true", .{key}) catch return false;
    if (std.mem.indexOf(u8, json, needle) != null) return true;
    const spaced = std.fmt.bufPrint(&buf, "\"{s}\": true", .{key}) catch return false;
    return std.mem.indexOf(u8, json, spaced) != null;
}

test "capability flags parse with and without a space" {
    const j = "{\"caps\":{\"microphone\":true,\"screen\": true,\"camera\":false}}";
    try std.testing.expect(jsonFlag(j, "microphone"));
    try std.testing.expect(jsonFlag(j, "screen"));
    try std.testing.expect(!jsonFlag(j, "camera"));
    try std.testing.expect(!jsonFlag(j, "location"));
}
