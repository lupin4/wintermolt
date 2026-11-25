// Copyright The Fantastic Planet - By David Clabaugh
//
// server.zig — the web UI's own HTTP and WebSocket server (`wintermolt --web`)
//
// Serves the page (index.html and app.js, compiled into the binary) and one
// WebSocket at /ws. Nothing else runs: no Node, no sidecar.
//
// The agent behind the socket can run bash, so the socket is locked:
//   - /ws needs the token printed at start-up (?token=), compared in constant time;
//   - a browser's Origin must be this server's own Host, so another site open
//     in the same browser cannot drive it;
//   - main.zig listens on 127.0.0.1 unless WINTERMOLT_WEB_HOST says otherwise.
// The page holds no secret, and is served to anyone who can reach the port.
//
// Each connection has its own thread. A message goes to the Handler, and what
// the Handler sends (send()) goes back to the page that sent it.

const std = @import("std");
const builtin = @import("builtin");
const fsio = @import("../fsio.zig");
const banner = @import("../banner.zig");
const net = std.Io.net;
const http = std.http;

pub const page_html = @embedFile("index.html");
pub const page_js = @embedFile("app.js");

pub const Handler = struct {
    ctx: *anyopaque,
    /// A page connected; what it sends now goes to that page.
    open: *const fn (ctx: *anyopaque) void,
    /// One message from the page, valid until the call returns.
    message: *const fn (ctx: *anyopaque, data: []const u8) void,
};

/// The largest message a page may send: a pasted photo, base64-encoded.
const max_message = 16 * 1024 * 1024;

threadlocal var current: ?*http.Server.WebSocket = null;

/// Send `data` to the page whose message this thread is handling.
pub fn send(data: []const u8) void {
    const ws = current orelse return;
    ws.writeMessage(data, .text) catch {};
}

/// How much of `s` ends on a whole UTF-8 character. A streamed token can stop
/// partway through one, and a text frame that is not UTF-8 makes the browser
/// drop the socket; the caller holds the rest back for the next token.
pub fn wholeChars(s: []const u8) usize {
    var i = s.len;
    while (i > 0 and s.len - i < 4) {
        i -= 1;
        if (s[i] & 0xC0 == 0x80) continue; // continuation byte: keep looking for the lead
        const need = std.unicode.utf8ByteSequenceLength(s[i]) catch return s.len;
        return if (s.len - i < need) i else s.len;
    }
    return s.len;
}

pub const Verdict = enum { ok, no_token, bad_origin };

/// May this upgrade request open the socket? `target` is the request line's
/// path and query; `origin` and `host` are those headers, when sent.
pub fn authorize(target: []const u8, origin: ?[]const u8, host: ?[]const u8, token: []const u8) Verdict {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return .no_token;
    var given: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| if (std.mem.startsWith(u8, kv, "token=")) {
        given = kv["token=".len..];
    };
    if (!sameToken(given orelse return .no_token, token)) return .no_token;
    // A browser always sends Origin on a WebSocket; a script need not.
    if (origin) |o| {
        const h = host orelse return .bad_origin;
        const rest = if (std.mem.startsWith(u8, o, "http://")) o[7..] else if (std.mem.startsWith(u8, o, "https://")) o[8..] else return .bad_origin;
        if (!std.ascii.eqlIgnoreCase(rest, h)) return .bad_origin;
    }
    return .ok;
}

pub fn sameToken(given: []const u8, token: []const u8) bool {
    if (token.len == 0 or given.len != token.len) return false;
    var diff: u8 = 0;
    for (given, token) |a, b| diff |= a ^ b;
    return diff == 0;
}

pub const Server = struct {
    gpa: std.mem.Allocator,
    tcp: net.Server,
    token: []const u8,
    handler: Handler,

    pub fn init(gpa: std.mem.Allocator, host: []const u8, port_number: u16, token: []const u8, handler: Handler) !Server {
        const addr = try net.IpAddress.parse(host, port_number);
        // SO_REUSEADDR on Windows lets another process bind the same port.
        const tcp = try addr.listen(fsio.io(), .{ .reuse_address = builtin.os.tag != .windows });
        return .{ .gpa = gpa, .tcp = tcp, .token = token, .handler = handler };
    }

    pub fn deinit(self: *Server) void {
        self.tcp.deinit(fsio.io());
    }

    pub fn port(self: *const Server) u16 {
        return self.tcp.socket.address.getPort();
    }

    /// Accept connections, a thread each, until the listener fails.
    pub fn run(self: *Server) void {
        const io = fsio.io();
        while (true) {
            const stream = self.tcp.accept(io) catch |e| {
                std.debug.print("[web] Stopped accepting connections: {s}\n", .{@errorName(e)});
                return;
            };
            const t = std.Thread.spawn(.{}, connection, .{ self, stream }) catch {
                var s = stream;
                s.close(io);
                continue;
            };
            t.detach();
        }
    }

    fn connection(self: *Server, stream: net.Stream) void {
        const io = fsio.io();
        defer {
            var s = stream;
            s.close(io);
        }
        const recv = self.gpa.alloc(u8, max_message) catch return;
        defer self.gpa.free(recv);
        var send_buf: [16 * 1024]u8 = undefined;
        var r = stream.reader(io, recv);
        var w = stream.writer(io, &send_buf);
        var server: http.Server = .init(&r.interface, &w.interface);

        while (true) {
            var request = server.receiveHead() catch return;
            switch (request.upgradeRequested()) {
                .websocket => |key_opt| {
                    const key = key_opt orelse return refuse(&request, .bad_request, "missing sec-websocket-key");
                    const path = request.head.target[0 .. std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len];
                    if (!std.mem.eql(u8, path, "/ws")) return refuse(&request, .not_found, "not found");
                    switch (self.check(&request)) {
                        .ok => {},
                        .no_token => {
                            std.debug.print("[web] Refused a connection without the token\n", .{});
                            return refuse(&request, .unauthorized, "open the link wintermolt printed; it carries the token");
                        },
                        .bad_origin => {
                            std.debug.print("[web] Refused a connection from another site\n", .{});
                            return refuse(&request, .forbidden, "wrong origin");
                        },
                    }
                    var ws = request.respondWebSocket(.{ .key = key }) catch return;
                    ws.flush() catch return;
                    self.serveSocket(&ws);
                    return;
                },
                .other => return refuse(&request, .bad_request, "unsupported upgrade"),
                .none => {
                    // http.Server answers `connection: close` but leaves the closing to us.
                    const again = request.head.keep_alive;
                    servePage(&request) catch return;
                    if (!again) return;
                },
            }
        }
    }

    fn check(self: *const Server, request: *const http.Server.Request) Verdict {
        var origin: ?[]const u8 = null;
        var host: ?[]const u8 = null;
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
        }
        return authorize(request.head.target, origin, host, self.token);
    }

    fn serveSocket(self: *Server, ws: *http.Server.WebSocket) void {
        current = ws;
        defer current = null;
        self.handler.open(self.handler.ctx);
        while (true) {
            const msg = ws.readSmallMessage() catch return;
            switch (msg.opcode) {
                .text, .binary => self.handler.message(self.handler.ctx, msg.data),
                .ping => ws.writeMessage(msg.data, .pong) catch return,
                else => {},
            }
        }
    }
};

const common_headers = [_]http.Header{
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
};

fn servePage(request: *http.Server.Request) !void {
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        // Scripts only from app.js: text the model writes can never run as code.
        return request.respond(page_html, .{ .extra_headers = &(common_headers ++ [_]http.Header{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "content-security-policy", .value = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" },
        }) });
    }
    const files = [_]struct { path: []const u8, body: []const u8, kind: []const u8 }{
        .{ .path = "/app.js", .body = page_js, .kind = "text/javascript; charset=utf-8" },
        // The TUI's start-up art, so the page opens on the same picture.
        .{ .path = "/banner/full.txt", .body = banner.full.text, .kind = "text/plain; charset=utf-8" },
        .{ .path = "/banner/full.roles", .body = banner.full.roles, .kind = "text/plain; charset=utf-8" },
        .{ .path = "/banner/wordmark.txt", .body = banner.wordmark.text, .kind = "text/plain; charset=utf-8" },
        .{ .path = "/banner/wordmark.roles", .body = banner.wordmark.roles, .kind = "text/plain; charset=utf-8" },
    };
    for (files) |f| if (std.mem.eql(u8, path, f.path)) {
        return request.respond(f.body, .{ .extra_headers = &(common_headers ++ [_]http.Header{
            .{ .name = "content-type", .value = f.kind },
        }) });
    };
    return request.respond("not found", .{ .status = .not_found, .extra_headers = &(common_headers ++ [_]http.Header{
        .{ .name = "content-type", .value = "text/plain" },
    }) });
}

fn refuse(request: *http.Server.Request, status: http.Status, why: []const u8) void {
    request.respond(why, .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain" },
    } }) catch {};
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "authorize: the token, in constant time; a browser's Origin must be this host" {
    try testing.expectEqual(Verdict.no_token, authorize("/ws", null, "h", "abc"));
    try testing.expectEqual(Verdict.no_token, authorize("/ws?token=abd", null, "h", "abc"));
    try testing.expectEqual(Verdict.no_token, authorize("/ws?token=ab", null, "h", "abc"));
    try testing.expectEqual(Verdict.no_token, authorize("/ws?token=", null, "h", ""));
    try testing.expectEqual(Verdict.ok, authorize("/ws?x=1&token=abc", null, "h", "abc"));
    try testing.expectEqual(Verdict.ok, authorize("/ws?token=abc", "http://127.0.0.1:3000", "127.0.0.1:3000", "abc"));
    try testing.expectEqual(Verdict.bad_origin, authorize("/ws?token=abc", "http://evil.example", "127.0.0.1:3000", "abc"));
    try testing.expectEqual(Verdict.bad_origin, authorize("/ws?token=abc", "http://127.0.0.1:3000.evil.example", "127.0.0.1:3000", "abc"));
    try testing.expectEqual(Verdict.bad_origin, authorize("/ws?token=abc", "http://127.0.0.1:3000", null, "abc"));
}

test "wholeChars: a character cut by the end of a token waits for the rest" {
    try testing.expectEqual(@as(usize, 0), wholeChars(""));
    try testing.expectEqual(@as(usize, 3), wholeChars("abc"));
    try testing.expectEqual(@as(usize, 4), wholeChars("ab\xC3\xA9")); // é, whole
    try testing.expectEqual(@as(usize, 2), wholeChars("ab\xC3")); // é, first byte only
    try testing.expectEqual(@as(usize, 1), wholeChars("a\xE2\x82")); // €, two of three
    try testing.expectEqual(@as(usize, 1), wholeChars("a\xF0\x9F\x98")); // 😀, three of four
    try testing.expectEqual(@as(usize, 5), wholeChars("a\xF0\x9F\x98\x80"));
    try testing.expectEqual(@as(usize, 2), wholeChars("a\xFF")); // not UTF-8 at all: sent as is
}

const Echo = struct {
    fn open(_: *anyopaque) void {
        send("hello");
    }
    fn message(_: *anyopaque, data: []const u8) void {
        var buf: [256]u8 = undefined;
        send(std.fmt.bufPrint(&buf, "echo:{s}", .{data}) catch return);
    }
};

/// The server side of the test: `n` connections, one after another, on this thread.
fn serveN(srv: *Server, n: usize) void {
    for (0..n) |_| {
        const s = srv.tcp.accept(fsio.io()) catch return;
        srv.connection(s);
    }
}

/// Send `request` on a new connection and return everything until the server closes it.
fn exchange(alloc: std.mem.Allocator, port_number: u16, request: []const u8) ![]u8 {
    const io = fsio.io();
    const addr = try net.IpAddress.parse("127.0.0.1", port_number);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    return r.interface.allocRemaining(alloc, .limited(1 << 20));
}

test "Server: the page without a token, the socket only with it and from its own origin" {
    var ctx: u8 = 0;
    var srv = try Server.init(testing.allocator, "127.0.0.1", 0, "s3cret", .{ .ctx = &ctx, .open = Echo.open, .message = Echo.message });
    defer srv.deinit();
    const port_number = srv.port();
    const t = try std.Thread.spawn(.{}, serveN, .{ &srv, 5 });
    defer t.join();
    const a = testing.allocator;

    const page = try exchange(a, port_number, "GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    defer a.free(page);
    try testing.expect(std.mem.startsWith(u8, page, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, page, "script-src 'self'") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<title>") != null);

    const upgrade = "GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\nupgrade: websocket\r\nconnection: upgrade\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\norigin: {s}\r\n\r\n";
    var buf: [512]u8 = undefined;

    const no_token = try exchange(a, port_number, try std.fmt.bufPrint(&buf, upgrade, .{ "/ws", port_number, "http://127.0.0.1" }));
    defer a.free(no_token);
    try testing.expect(std.mem.startsWith(u8, no_token, "HTTP/1.1 401"));

    const wrong_token = try exchange(a, port_number, try std.fmt.bufPrint(&buf, upgrade, .{ "/ws?token=s3cre7", port_number, "http://127.0.0.1" }));
    defer a.free(wrong_token);
    try testing.expect(std.mem.startsWith(u8, wrong_token, "HTTP/1.1 401"));

    const other_site = try exchange(a, port_number, try std.fmt.bufPrint(&buf, upgrade, .{ "/ws?token=s3cret", port_number, "http://evil.example" }));
    defer a.free(other_site);
    try testing.expect(std.mem.startsWith(u8, other_site, "HTTP/1.1 403"));

    // The real thing: upgrade, the open message, then one masked frame and its echo.
    var origin_buf: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}", .{port_number});
    const head = try std.fmt.bufPrint(&buf, upgrade, .{ "/ws?token=s3cret", port_number, origin });
    const frame = [_]u8{ 0x81, 0x80 | 2, 1, 2, 3, 4, 'h' ^ 1, 'i' ^ 2 };
    var req: [600]u8 = undefined;
    @memcpy(req[0..head.len], head);
    @memcpy(req[head.len..][0..frame.len], &frame);
    // Not exchange(): the server keeps this connection open for the next frame.
    const io = fsio.io();
    const addr = try net.IpAddress.parse("127.0.0.1", port_number);
    var stream = try addr.connect(io, .{ .mode = .stream });
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(req[0 .. head.len + frame.len]);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const status_line = try r.interface.takeDelimiterInclusive('\n');
    try testing.expect(std.mem.startsWith(u8, status_line, "HTTP/1.1 101"));
    while (true) {
        const line = try r.interface.takeDelimiterInclusive('\n');
        if (std.mem.eql(u8, line, "\r\n")) break;
    }
    for ([_][]const u8{ "hello", "echo:hi" }) |want| {
        const h = try r.interface.takeArray(2);
        try testing.expectEqual(@as(u8, 0x81), h[0]);
        try testing.expectEqualStrings(want, try r.interface.take(h[1]));
    }
    stream.close(io); // the server's read fails, and serveN's last connection ends
}
