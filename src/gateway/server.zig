// Copyright The Fantastic Planet - By David Clabaugh
//
// server.zig — `--gateway`: an OpenAI-compatible API, served by wintermolt itself
//
//   POST /v1/chat/completions   {"messages": [{"role", "content"}], "stream": bool}
//   GET  /v1/models
//
// Every request needs `Authorization: Bearer <key>`: the key wintermolt prints
// when it starts, or WINTERMOLT_GATEWAY_KEY. A web page cannot add that header
// to a request for another site without a CORS preflight, which this server
// never answers, so no page you visit can drive the agent.
//
// The agent answers with its own backend and model (a request's `model` is not
// used) and keeps nothing: the client sends the conversation every time. One
// request at a time.

const std = @import("std");
const builtin = @import("builtin");
const fsio = @import("../fsio.zig");
const web = @import("../web/server.zig");
const protocol = @import("../api/protocol.zig");
const storage = @import("../agent/storage.zig");
const net = std.Io.net;
const http = std.http;

const max_body = 16 * 1024 * 1024;

/// A request's conversation, as text.
pub const Chat = struct {
    stream: bool,
    /// Everything before the last message, starting with the user's.
    history: []storage.Turn,
    /// The last message, the user's.
    prompt: []const u8,
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Chat) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }
};

/// What answers: main.zig's GatewayAgent, over the AgentLoop.
pub const Agent = struct {
    ctx: *anyopaque,
    /// Answer chat.prompt after chat.history, each piece of text to `out` as it
    /// is written. Returns why it failed, or "" when it did not.
    answer: *const fn (ctx: *anyopaque, chat: *const Chat, out: *const fn ([]const u8) void) []const u8,
    /// "backend:model", as /v1/models and every reply name it.
    model: *const fn (ctx: *anyopaque) []const u8,
};

/// OpenAI's messages as text turns. A system message counts as the user's (the
/// agent keeps its own system prompt); tool messages and parts other than text
/// are dropped. error.NoUserMessage when the last message is not the user's.
pub fn parseChat(gpa: std.mem.Allocator, body: []const u8) !Chat {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const Message = struct { role: []const u8, content: std.json.Value = .null };
    const Request = struct { stream: bool = false, messages: []const Message };
    const req = try std.json.parseFromSliceLeaky(Request, a, body, .{ .ignore_unknown_fields = true });

    var turns: std.ArrayList(storage.Turn) = .empty;
    for (req.messages) |m| {
        const role: protocol.Role = if (eql(m.role, "assistant"))
            .assistant
        else if (eql(m.role, "user") or eql(m.role, "system"))
            .user
        else
            continue;
        if (turns.items.len == 0 and role != .user) continue;
        const text = try contentText(a, m.content);
        if (text.len == 0) continue;
        if (turns.items.len > 0 and turns.items[turns.items.len - 1].role == role) {
            const last = &turns.items[turns.items.len - 1];
            last.text = try std.mem.concat(a, u8, &.{ last.text, "\n\n", text });
        } else try turns.append(a, .{ .role = role, .text = text });
    }
    const last = turns.pop() orelse return error.NoUserMessage;
    if (last.role != .user) return error.NoUserMessage;
    return .{ .stream = req.stream, .history = turns.items, .prompt = last.text, .arena = arena, .gpa = gpa };
}

/// A message's content: a string, or the text of its parts.
fn contentText(a: std.mem.Allocator, v: std.json.Value) ![]u8 {
    switch (v) {
        .string => |s| return a.dupe(u8, s),
        .array => |parts| {
            var out: std.ArrayList(u8) = .empty;
            for (parts.items) |p| {
                if (p != .object) continue;
                const kind = p.object.get("type") orelse continue;
                const text = p.object.get("text") orelse continue;
                if (kind != .string or text != .string or !eql(kind.string, "text")) continue;
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, text.string);
            }
            return out.items;
        },
        else => return a.alloc(u8, 0),
    }
}

/// Is this `Authorization` header the key? Compared in constant time.
pub fn bearerOk(header: ?[]const u8, key: []const u8) bool {
    const h = header orelse return false;
    const prefix = "Bearer ";
    if (h.len < prefix.len or !std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) return false;
    return web.sameToken(std.mem.trim(u8, h[prefix.len..], " "), key);
}

pub const Server = struct {
    gpa: std.mem.Allocator,
    tcp: net.Server,
    key: []const u8,
    agent: Agent,
    /// Held while the agent answers.
    busy: fsio.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, host: []const u8, port_number: u16, key: []const u8, agent: Agent) !Server {
        const addr = try net.IpAddress.parse(host, port_number);
        // SO_REUSEADDR on Windows lets another process bind the same port.
        const tcp = try addr.listen(fsio.io(), .{ .reuse_address = builtin.os.tag != .windows });
        return .{ .gpa = gpa, .tcp = tcp, .key = key, .agent = agent };
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
                std.debug.print("[gateway] Stopped accepting connections: {s}\n", .{@errorName(e)});
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
        var recv: [16 * 1024]u8 = undefined;
        var send_buf: [16 * 1024]u8 = undefined;
        var r = stream.reader(io, &recv);
        var w = stream.writer(io, &send_buf);
        var server: http.Server = .init(&r.interface, &w.interface);
        while (true) {
            var request = server.receiveHead() catch return;
            // http.Server answers `connection: close` but leaves the closing to us.
            const again = request.head.keep_alive;
            self.handle(&request) catch return;
            if (!again) return;
        }
    }

    fn handle(self: *Server, request: *http.Server.Request) !void {
        const target = request.head.target;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const is_chat = request.head.method == .POST and eql(path, "/v1/chat/completions");
        const is_models = request.head.method == .GET and eql(path, "/v1/models");
        if (!is_chat and !is_models)
            return self.fail(request, .not_found, "invalid_request_error", "Not found. This API has POST /v1/chat/completions and GET /v1/models.");

        // Before the body is read: reading it invalidates the header strings.
        var auth: ?[]const u8 = null;
        var it = request.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            auth = h.value;
        };
        if (!bearerOk(auth, self.key)) {
            std.debug.print("[gateway] Refused a request without the API key\n", .{});
            return self.fail(request, .unauthorized, "invalid_request_error", "Missing or wrong API key. Send the key wintermolt --gateway printed: Authorization: Bearer <key>.");
        }
        if (is_models) return self.models(request);
        return self.chat(request);
    }

    fn models(self: *Server, request: *http.Server.Request) !void {
        self.busy.lockUncancelable(fsio.io());
        const model = self.agent.model(self.agent.ctx);
        defer self.busy.unlock(fsio.io());
        const body = try std.json.Stringify.valueAlloc(self.gpa, .{
            .object = "list",
            .data = .{.{ .id = model, .object = "model", .created = 0, .owned_by = "wintermolt" }},
        }, .{});
        defer self.gpa.free(body);
        try respondJson(request, .ok, body);
    }

    fn chat(self: *Server, request: *http.Server.Request) !void {
        var body_buf: [8192]u8 = undefined;
        const reader = try request.readerExpectContinue(&body_buf);
        const body = reader.allocRemaining(self.gpa, .limited(max_body)) catch |e| switch (e) {
            error.StreamTooLong => return self.fail(request, .payload_too_large, "invalid_request_error", "The request is over 16 MB."),
            else => return e,
        };
        defer self.gpa.free(body);
        var c = parseChat(self.gpa, body) catch |e| return self.fail(request, .bad_request, "invalid_request_error", switch (e) {
            error.NoUserMessage => "The last message must be the user's.",
            else => "The body is not a chat completion request: it needs a messages array.",
        });
        defer c.deinit();

        self.busy.lockUncancelable(fsio.io());
        defer self.busy.unlock(fsio.io());
        var raw: [12]u8 = undefined;
        if (!fsio.randomBytes(&raw)) @memset(&raw, 0);
        var id_buf: [33]u8 = undefined;
        var reply: Reply = .{
            .gpa = self.gpa,
            .id = std.fmt.bufPrint(&id_buf, "chatcmpl-{s}", .{std.fmt.bytesToHex(raw, .lower)}) catch unreachable,
            .created = fsio.timestamp(),
            .model = self.agent.model(self.agent.ctx),
        };
        defer reply.text.deinit(self.gpa);
        current = &reply;
        defer current = null;

        if (c.stream) {
            var sse_buf: [4096]u8 = undefined;
            var bw = try request.respondStreaming(&sse_buf, .{ .respond_options = .{ .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
            } } });
            reply.body = &bw;
            reply.chunk(.{ .role = "assistant", .content = "" }, null);
            const why = self.agent.answer(self.agent.ctx, &c, onText);
            reply.flushCarry();
            // struct {}{}, not .{}: an empty tuple would be written as [].
            if (why.len > 0) reply.event(.{ .@"error" = .{ .message = why, .type = "server_error" } }) else reply.chunk(struct {}{}, "stop");
            bw.writer.writeAll("data: [DONE]\n\n") catch {};
            return bw.end();
        }

        const why = self.agent.answer(self.agent.ctx, &c, onText);
        if (why.len > 0) return self.fail(request, .bad_gateway, "server_error", why);
        const out = try std.json.Stringify.valueAlloc(self.gpa, .{
            .id = reply.id,
            .object = "chat.completion",
            .created = reply.created,
            .model = reply.model,
            .choices = .{.{
                .index = 0,
                .message = .{ .role = "assistant", .content = reply.text.items },
                .finish_reason = "stop",
            }},
        }, .{});
        defer self.gpa.free(out);
        try respondJson(request, .ok, out);
    }

    /// OpenAI's error shape: {"error": {"message", "type"}}.
    fn fail(self: *Server, request: *http.Server.Request, status: http.Status, kind: []const u8, message: []const u8) !void {
        const body = try std.json.Stringify.valueAlloc(self.gpa, .{ .@"error" = .{ .message = message, .type = kind } }, .{});
        defer self.gpa.free(body);
        try respondJson(request, status, body);
    }
};

fn respondJson(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
    } });
}

/// The reply being written: streamed as server-sent events, or kept whole.
const Reply = struct {
    gpa: std.mem.Allocator,
    id: []const u8,
    created: i64,
    model: []const u8,
    /// Set when streaming.
    body: ?*http.BodyWriter = null,
    /// The whole reply, when not streaming.
    text: std.ArrayList(u8) = .empty,
    /// The start of a UTF-8 character the last piece cut off (web.wholeChars).
    carry: [4]u8 = undefined,
    carry_len: usize = 0,

    fn add(self: *Reply, piece: []const u8) void {
        if (self.body == null) return self.text.appendSlice(self.gpa, piece) catch {};
        // A JSON string must be UTF-8, so each event carries whole characters.
        const joined = std.mem.concat(self.gpa, u8, &.{ self.carry[0..self.carry_len], piece }) catch return;
        defer self.gpa.free(joined);
        const n = web.wholeChars(joined);
        self.carry_len = joined.len - n;
        @memcpy(self.carry[0..self.carry_len], joined[n..]);
        if (n > 0) self.chunk(.{ .content = joined[0..n] }, null);
    }

    fn flushCarry(self: *Reply) void {
        if (self.carry_len > 0) self.chunk(.{ .content = self.carry[0..self.carry_len] }, null);
        self.carry_len = 0;
    }

    fn chunk(self: *Reply, delta: anytype, finish_reason: ?[]const u8) void {
        self.event(.{
            .id = self.id,
            .object = "chat.completion.chunk",
            .created = self.created,
            .model = self.model,
            .choices = .{.{ .index = 0, .delta = delta, .finish_reason = finish_reason }},
        });
    }

    fn event(self: *Reply, value: anytype) void {
        const b = self.body orelse return;
        b.writer.writeAll("data: ") catch return;
        std.json.Stringify.value(value, .{}, &b.writer) catch return;
        b.writer.writeAll("\n\n") catch return;
        b.flush() catch {};
    }
};

/// The agent's text callback takes no context; the reply is the thread's.
threadlocal var current: ?*Reply = null;

fn onText(piece: []const u8) void {
    if (current) |r| r.add(piece);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseChat: text turns, a system message as the user's, the last message the prompt" {
    var c = try parseChat(testing.allocator,
        \\{"model":"gpt-4","stream":true,"messages":[
        \\ {"role":"assistant","content":"stray"},
        \\ {"role":"system","content":"Be brief."},
        \\ {"role":"user","content":"hello"},
        \\ {"role":"assistant","content":"hi"},
        \\ {"role":"tool","content":"ignored"},
        \\ {"role":"user","content":[{"type":"text","text":"part one"},{"type":"image_url","image_url":{"url":"x"}},{"type":"text","text":"part two"}]}
        \\]}
    );
    defer c.deinit();
    try testing.expect(c.stream);
    try testing.expectEqual(@as(usize, 2), c.history.len);
    try testing.expectEqualStrings("Be brief.\n\nhello", c.history[0].text);
    try testing.expectEqual(protocol.Role.assistant, c.history[1].role);
    try testing.expectEqualStrings("part one\npart two", c.prompt);

    try testing.expectError(error.NoUserMessage, parseChat(testing.allocator,
        \\{"messages":[{"role":"user","content":"q"},{"role":"assistant","content":"a"}]}
    ));
    try testing.expectError(error.NoUserMessage, parseChat(testing.allocator,
        \\{"messages":[]}
    ));
    try testing.expect(std.meta.isError(parseChat(testing.allocator, "not json")));
}

test "bearerOk: the key after Bearer, nothing else" {
    try testing.expect(bearerOk("Bearer s3cret-key-0123456", "s3cret-key-0123456"));
    try testing.expect(bearerOk("bearer s3cret-key-0123456", "s3cret-key-0123456"));
    try testing.expect(!bearerOk("Bearer s3cret-key-0123457", "s3cret-key-0123456"));
    try testing.expect(!bearerOk("s3cret-key-0123456", "s3cret-key-0123456"));
    try testing.expect(!bearerOk("Bearer ", ""));
    try testing.expect(!bearerOk(null, "s3cret-key-0123456"));
}

const Fake = struct {
    fn answer(_: *anyopaque, c: *const Chat, out: *const fn ([]const u8) void) []const u8 {
        if (eql(c.prompt, "fail")) return "CurlRequestFailed";
        out("You said ");
        out("caf\xC3"); // é, cut between two pieces
        out("\xA9 ");
        out(c.prompt);
        return "";
    }
    fn model(_: *anyopaque) []const u8 {
        return "ollama:test";
    }
};

fn serveN(srv: *Server, n: usize) void {
    for (0..n) |_| {
        const s = srv.tcp.accept(fsio.io()) catch return;
        srv.connection(s);
    }
}

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

fn post(alloc: std.mem.Allocator, port_number: u16, auth: []const u8, body: []const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf, "POST /v1/chat/completions HTTP/1.1\r\nhost: x\r\n{s}content-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ auth, body.len, body });
    return exchange(alloc, port_number, req);
}

test "Server: the key, a whole reply, a streamed one, a failure" {
    var ctx: u8 = 0;
    const key = "gw-key-0123456789abcdef";
    var srv = try Server.init(testing.allocator, "127.0.0.1", 0, key, .{ .ctx = &ctx, .answer = Fake.answer, .model = Fake.model });
    defer srv.deinit();
    const p = srv.port();
    const t = try std.Thread.spawn(.{}, serveN, .{ &srv, 6 });
    defer t.join();
    const a = testing.allocator;
    const auth = "authorization: Bearer " ++ key ++ "\r\n";
    const hi = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}";

    // Every request first, checks after: a check that fails mid-way would
    // leave serveN waiting for a connection that never comes, and join hang.
    const no_key = try post(a, p, "", hi);
    defer a.free(no_key);
    const listed = try exchange(a, p, "GET /v1/models HTTP/1.1\r\nhost: x\r\n" ++ auth ++ "connection: close\r\n\r\n");
    defer a.free(listed);
    const whole = try post(a, p, auth, hi);
    defer a.free(whole);
    const streamed = try post(a, p, auth, "{\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}");
    defer a.free(streamed);
    const failed = try post(a, p, auth, "{\"messages\":[{\"role\":\"user\",\"content\":\"fail\"}]}");
    defer a.free(failed);
    const elsewhere = try exchange(a, p, "GET /admin HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    defer a.free(elsewhere);

    try testing.expect(std.mem.startsWith(u8, no_key, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, listed, "\"id\":\"ollama:test\"") != null);
    try testing.expect(std.mem.startsWith(u8, whole, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, whole, "\"content\":\"You said café hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, whole, "\"object\":\"chat.completion\"") != null);
    try testing.expect(std.mem.indexOf(u8, streamed, "text/event-stream") != null);
    try testing.expect(std.mem.indexOf(u8, streamed, "\"delta\":{\"content\":\"caf\"}") != null);
    try testing.expect(std.mem.indexOf(u8, streamed, "\"delta\":{\"content\":\"é \"}") != null);
    try testing.expect(std.mem.indexOf(u8, streamed, "\"delta\":{},\"finish_reason\":\"stop\"") != null);
    try testing.expect(std.mem.indexOf(u8, streamed, "data: [DONE]") != null);
    try testing.expect(std.mem.startsWith(u8, failed, "HTTP/1.1 502"));
    try testing.expect(std.mem.indexOf(u8, failed, "CurlRequestFailed") != null);
    try testing.expect(std.mem.startsWith(u8, elsewhere, "HTTP/1.1 404"));
}
