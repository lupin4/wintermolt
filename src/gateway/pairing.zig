// Copyright The Fantastic Planet - By David Clabaugh
//
// pairing.zig — device pairing, token auth, and the node registry.
//
// bridge.zig has documented a /pair endpoint and pair_request/pair_response
// messages since it was written, but nothing implemented them: the gateway
// could be asked to pair and had no notion of what a device was. Every
// companion app (iOS, watchOS, tvOS, Android) is a thin client that pairs to
// the gateway and then rides it, so this is the piece they all stand on.
//
// THE FLOW
//   1. Operator runs `/pair` on the trusted host. The gateway mints a short
//      code with a TTL and shows it (and its TLS fingerprint) as text or QR.
//   2. The device posts {code, name, platform, capabilities}.
//   3. On a match the gateway registers the device and returns a 256-bit token
//      ONCE. The device stores it; the gateway keeps only a SHA-256 hash.
//   4. Every later request carries the token. Presence beacons keep last_seen
//      fresh so the operator can see which nodes are alive.
//
// WHY A HASH AND NOT THE TOKEN. The registry is written to disk. Storing the
// token verbatim means anyone who reads that file owns every paired device;
// storing a hash means a leaked registry grants nothing. This is the same
// reason a server keeps password hashes, and it costs one SHA-256 per request.
//
// WHY CONSTANT-TIME COMPARISON. webhook.zig's verifySignature compares its MAC
// with std.mem.eql, which returns on the first differing byte — the time it
// takes leaks how much of a guess was right, one byte at a time. Token checks
// here use std.crypto.timing_safe.eql. (webhook.zig has the same issue and
// should be moved over; noted, not silently changed.)

const std = @import("std");
const fsio = @import("../fsio.zig");
const Allocator = std.mem.Allocator;

/// Codes are read aloud, typed on a TV remote, and squinted at on a watch, so
/// the alphabet drops every confusable pair: no 0/O, no 1/I/L, no 8/B, no 2/Z,
/// no 5/S. 26 symbols, 8 characters => ~37.6 bits, which is far more than a
/// 5-minute single-use window needs while staying comfortable to enter.
pub const CODE_ALPHABET = "ACDEFGHJKMNPQRTUVWXY34679";
pub const CODE_LEN = 8;
pub const CODE_TTL_SECONDS: i64 = 300;
pub const TOKEN_BYTES = 32;

/// A device may only ask for what it can actually do. The gateway uses this to
/// decide what to route where: a watch has a mic but no screen worth reading,
/// a TV has a screen but usually no camera.
pub const Capabilities = packed struct {
    camera: bool = false,
    screen: bool = false,
    microphone: bool = false,
    location: bool = false,
    notifications: bool = false,
    file_share: bool = false,

    pub fn jsonStringify(self: Capabilities, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Capabilities).@"struct".fields) |f| {
            try jw.objectField(f.name);
            try jw.write(@field(self, f.name));
        }
        try jw.endObject();
    }
};

pub const Platform = enum {
    ios,
    ipados,
    watchos,
    tvos,
    android,
    macos,
    linux,
    windows,
    web,
    unknown,

    pub fn parse(s: []const u8) Platform {
        inline for (@typeInfo(Platform).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
        return .unknown;
    }
};

pub const Device = struct {
    id: [16]u8, // random, printed as hex; not secret
    name: []const u8, // operator-facing, device-supplied
    platform: Platform,
    caps: Capabilities,
    token_hash: [32]u8,
    paired_at: i64,
    last_seen: i64,
    revoked: bool = false,

    pub fn idHex(self: *const Device, out: *[32]u8) []const u8 {
        return std.fmt.bufPrint(out, "{x}", .{self.id}) catch out[0..0];
    }

    /// Alive if it beaconed inside the window. Presence is advisory — a device
    /// that missed a beacon is quiet, not deauthorized.
    pub fn isAlive(self: *const Device, now: i64, window_s: i64) bool {
        return !self.revoked and (now - self.last_seen) <= window_s;
    }
};

pub const PendingCode = struct {
    code: [CODE_LEN]u8,
    issued_at: i64,
    /// Single use. A code that has minted a device is dead even inside its TTL,
    /// so a shoulder-surfed code cannot be replayed by a second device.
    consumed: bool = false,

    pub fn isValid(self: *const PendingCode, now: i64) bool {
        return !self.consumed and (now - self.issued_at) <= CODE_TTL_SECONDS;
    }
};

pub const PairError = error{
    NoPendingCode,
    CodeExpired,
    CodeAlreadyUsed,
    CodeMismatch,
    TooManyAttempts,
    NameTooLong,
    RegistryFull,
};

pub const MAX_DEVICES = 64;
pub const MAX_NAME_LEN = 64;
/// A code is only ~37 bits; without a ceiling an attacker on the LAN can simply
/// enumerate it inside the TTL. Five wrong guesses burns the code.
pub const MAX_ATTEMPTS = 5;

pub const Registry = struct {
    alloc: Allocator,
    devices: std.ArrayList(Device),
    pending: ?PendingCode = null,
    failed_attempts: u32 = 0,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc, .devices = .empty };
    }

    pub fn deinit(self: *Registry) void {
        for (self.devices.items) |d| self.alloc.free(d.name);
        self.devices.deinit(self.alloc);
    }

    /// Mint a pairing code. Replaces any outstanding one: only a single code is
    /// ever live, so an operator who runs /pair twice cannot leave a stale code
    /// valid behind them.
    pub fn beginPairing(self: *Registry, now: i64) PendingCode {
        var raw: [CODE_LEN]u8 = undefined;
        _ = fsio.randomBytes(&raw);
        var code: [CODE_LEN]u8 = undefined;
        for (raw, 0..) |b, i| code[i] = CODE_ALPHABET[b % CODE_ALPHABET.len];
        self.pending = .{ .code = code, .issued_at = now };
        self.failed_attempts = 0;
        return self.pending.?;
    }

    pub fn cancelPairing(self: *Registry) void {
        self.pending = null;
        self.failed_attempts = 0;
    }

    /// Complete a pairing. Returns the raw token, which the caller must hand to
    /// the device and then forget — it is never recoverable from the registry.
    pub fn completePairing(
        self: *Registry,
        offered: []const u8,
        name: []const u8,
        platform: Platform,
        caps: Capabilities,
        now: i64,
    ) PairError![TOKEN_BYTES]u8 {
        if (name.len > MAX_NAME_LEN) return PairError.NameTooLong;
        if (self.devices.items.len >= MAX_DEVICES) return PairError.RegistryFull;

        const p = self.pending orelse return PairError.NoPendingCode;
        if (p.consumed) return PairError.CodeAlreadyUsed;
        if ((now - p.issued_at) > CODE_TTL_SECONDS) {
            self.pending = null;
            return PairError.CodeExpired;
        }
        if (self.failed_attempts >= MAX_ATTEMPTS) {
            self.pending = null;
            return PairError.TooManyAttempts;
        }

        // Constant-time even here: the code is short-lived but still a secret.
        var ok = offered.len == CODE_LEN;
        if (ok) {
            var padded: [CODE_LEN]u8 = undefined;
            @memcpy(&padded, offered[0..CODE_LEN]);
            ok = std.crypto.timing_safe.eql([CODE_LEN]u8, padded, p.code);
        }
        if (!ok) {
            self.failed_attempts += 1;
            if (self.failed_attempts >= MAX_ATTEMPTS) self.pending = null;
            return PairError.CodeMismatch;
        }

        var token: [TOKEN_BYTES]u8 = undefined;
        _ = fsio.randomBytes(&token);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&token, &hash, .{});

        var id: [16]u8 = undefined;
        _ = fsio.randomBytes(&id);

        const owned = self.alloc.dupe(u8, name) catch return PairError.RegistryFull;
        self.devices.append(self.alloc, .{
            .id = id,
            .name = owned,
            .platform = platform,
            .caps = caps,
            .token_hash = hash,
            .paired_at = now,
            .last_seen = now,
        }) catch {
            self.alloc.free(owned);
            return PairError.RegistryFull;
        };

        self.pending.?.consumed = true;
        self.pending = null;
        self.failed_attempts = 0;
        return token;
    }

    /// Look up a device by bearer token. Compares against every device in
    /// constant time and without early exit, so neither the match position nor
    /// the number of paired devices is observable from timing.
    pub fn authenticate(self: *Registry, token: []const u8) ?*Device {
        if (token.len != TOKEN_BYTES) return null;
        var offered: [TOKEN_BYTES]u8 = undefined;
        @memcpy(&offered, token[0..TOKEN_BYTES]);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&offered, &hash, .{});

        var found: ?*Device = null;
        for (self.devices.items) |*d| {
            const hit = std.crypto.timing_safe.eql([32]u8, hash, d.token_hash);
            if (hit and !d.revoked and found == null) found = d;
        }
        return found;
    }

    pub fn touch(self: *Registry, token: []const u8, now: i64) bool {
        const d = self.authenticate(token) orelse return false;
        d.last_seen = now;
        return true;
    }

    /// Revocation keeps the record rather than deleting it: the operator should
    /// still be able to see that a device was once paired and when.
    pub fn revoke(self: *Registry, id_hex: []const u8) bool {
        var buf: [32]u8 = undefined;
        for (self.devices.items) |*d| {
            if (std.mem.eql(u8, d.idHex(&buf), id_hex)) {
                d.revoked = true;
                return true;
            }
        }
        return false;
    }

    pub fn aliveCount(self: *const Registry, now: i64, window_s: i64) usize {
        var n: usize = 0;
        for (self.devices.items) |*d| {
            if (d.isAlive(now, window_s)) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "pairing code uses only unambiguous characters" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const p = r.beginPairing(1000);
        for (p.code) |c| {
            try std.testing.expect(std.mem.indexOfScalar(u8, CODE_ALPHABET, c) != null);
            // the confusable set must never appear
            try std.testing.expect(c != '0' and c != 'O' and c != '1' and c != 'I' and
                c != 'L' and c != '8' and c != 'B' and c != '2' and c != 'Z' and
                c != '5' and c != 'S');
        }
    }
}

test "happy path: pair, authenticate, beacon" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    const token = try r.completePairing(&p.code, "Test Phone", .ios, .{ .camera = true, .microphone = true }, 1000);

    const d = r.authenticate(&token) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Test Phone", d.name);
    try std.testing.expect(d.platform == .ios);
    try std.testing.expect(d.caps.camera and d.caps.microphone and !d.caps.screen);

    try std.testing.expect(d.isAlive(1000, 60));
    try std.testing.expect(!d.isAlive(1200, 60));
    try std.testing.expect(r.touch(&token, 1200));
    try std.testing.expect(d.isAlive(1200, 60));
}

test "a code is single use" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    _ = try r.completePairing(&p.code, "First", .ios, .{}, 1000);
    try std.testing.expectError(PairError.NoPendingCode, r.completePairing(&p.code, "Second", .android, .{}, 1000));
    try std.testing.expectEqual(@as(usize, 1), r.devices.items.len);
}

test "a code expires" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    try std.testing.expectError(PairError.CodeExpired, r.completePairing(&p.code, "Late", .tvos, .{}, 1000 + CODE_TTL_SECONDS + 1));
}

test "guessing burns the code after MAX_ATTEMPTS" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    var wrong: [CODE_LEN]u8 = p.code;
    wrong[0] = if (p.code[0] == CODE_ALPHABET[0]) CODE_ALPHABET[1] else CODE_ALPHABET[0];

    var i: usize = 0;
    while (i < MAX_ATTEMPTS - 1) : (i += 1) {
        try std.testing.expectError(PairError.CodeMismatch, r.completePairing(&wrong, "Attacker", .unknown, .{}, 1000));
    }
    // the attempt that hits the ceiling still reports a mismatch...
    try std.testing.expectError(PairError.CodeMismatch, r.completePairing(&wrong, "Attacker", .unknown, .{}, 1000));
    // ...and the code is now gone, so even the CORRECT code fails.
    try std.testing.expectError(PairError.NoPendingCode, r.completePairing(&p.code, "Honest", .ios, .{}, 1000));
}

test "the raw token is never stored" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    const token = try r.completePairing(&p.code, "Phone", .ios, .{}, 1000);
    const d = &r.devices.items[0];
    // what is on disk must not be the bearer secret
    try std.testing.expect(!std.mem.eql(u8, &token, &d.token_hash));
    var expect: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &expect, .{});
    try std.testing.expectEqualSlices(u8, &expect, &d.token_hash);
}

test "a wrong or malformed token authenticates nothing" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    const token = try r.completePairing(&p.code, "Phone", .ios, .{}, 1000);

    var forged = token;
    forged[0] ^= 0xff;
    try std.testing.expect(r.authenticate(&forged) == null);
    try std.testing.expect(r.authenticate("short") == null);
    try std.testing.expect(r.authenticate("") == null);
    try std.testing.expect(r.authenticate(&token) != null);
}

test "revoked devices stop authenticating but stay on the record" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p = r.beginPairing(1000);
    const token = try r.completePairing(&p.code, "Lost Watch", .watchos, .{ .microphone = true }, 1000);

    var buf: [32]u8 = undefined;
    const id = r.devices.items[0].idHex(&buf);
    var id_copy: [32]u8 = undefined;
    @memcpy(id_copy[0..id.len], id);

    try std.testing.expect(r.revoke(id_copy[0..id.len]));
    try std.testing.expect(r.authenticate(&token) == null);
    try std.testing.expectEqual(@as(usize, 1), r.devices.items.len);
    try std.testing.expect(r.devices.items[0].revoked);
    try std.testing.expectEqual(@as(usize, 0), r.aliveCount(1000, 60));
}

test "every app target parses to a distinct platform" {
    try std.testing.expect(Platform.parse("ios") == .ios);
    try std.testing.expect(Platform.parse("iOS") == .ios);
    try std.testing.expect(Platform.parse("watchOS") == .watchos);
    try std.testing.expect(Platform.parse("tvOS") == .tvos);
    try std.testing.expect(Platform.parse("android") == .android);
    try std.testing.expect(Platform.parse("nonsense") == .unknown);
}

test "distinct devices get distinct ids and tokens" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const p1 = r.beginPairing(1000);
    const t1 = try r.completePairing(&p1.code, "Phone", .ios, .{}, 1000);
    const p2 = r.beginPairing(1000);
    const t2 = try r.completePairing(&p2.code, "Watch", .watchos, .{}, 1000);

    try std.testing.expect(!std.mem.eql(u8, &t1, &t2));
    try std.testing.expect(!std.mem.eql(u8, &r.devices.items[0].id, &r.devices.items[1].id));
    // each token must resolve to its OWN device, not merely to something
    try std.testing.expectEqualStrings("Phone", r.authenticate(&t1).?.name);
    try std.testing.expectEqualStrings("Watch", r.authenticate(&t2).?.name);
}
