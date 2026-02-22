// Copyright The Fantastic Planet - By David Clabaugh
//
// client.zig — libcurl-based HTTP client for the Anthropic Messages API
//
// Uses extern fn declarations for curl C functions to avoid @cImport
// header dependency issues across platforms. Only declares the ~12
// functions we actually use.
//
// Streaming: Uses CURLOPT_WRITEFUNCTION callback to feed SSE chunks
// to the stream parser in real-time, enabling live text output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");

// ---------------------------------------------------------------------------
// libcurl extern declarations (avoids @cImport / header dependency)
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

// curl_easy_* functions
extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) CurlCode;

// curl_easy_setopt — variadic, so we declare typed wrappers
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) CurlCode;

// curl_slist_* for headers
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: *CurlSlist) void;

// Error string
extern fn curl_easy_strerror(code: CurlCode) [*:0]const u8;

const CurlCode = enum(c_int) {
    ok = 0,
    _,
};

// CURLOPT constants (from curl.h)
const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_POST: c_int = 47;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_CONNECTTIMEOUT: c_int = 78;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const Client = struct {
    alloc: Allocator,
    api_key: []const u8,
    model: []const u8,
    api_url: []const u8,
    max_tokens: u32,

    pub fn init(
        alloc: Allocator,
        api_key: []const u8,
        model: []const u8,
    ) Client {
        return .{
            .alloc = alloc,
            .api_key = api_key,
            .model = model,
            .api_url = "https://api.anthropic.com/v1/messages",
            .max_tokens = 8192,
        };
    }

    /// Send a streaming Messages API request.
    /// text_cb is called for each text delta (for live terminal output).
    /// Returns the accumulated response.
    pub fn sendMessage(
        self: *const Client,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        tools: []const protocol.ToolDefinition,
        text_cb: ?sse.TextCallback,
    ) !protocol.Response {
        // Serialize request body
        const body = try protocol.serializeRequest(
            self.alloc,
            self.model,
            system_prompt,
            messages,
            tools,
            self.max_tokens,
        );
        defer self.alloc.free(body);

        // Debug: log request size (visible only on stderr)
        {
            const dbg = std.fs.File.stderr().deprecatedWriter();
            dbg.print("[api] request: {d} bytes (~{d}k tokens est)\n", .{ body.len, body.len / 3000 }) catch {};
        }

        // Initialize curl
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        // Set URL
        const url_z = try self.alloc.dupeZ(u8, self.api_url);
        defer self.alloc.free(url_z);
        _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

        // Build headers
        var headers: ?*CurlSlist = null;
        defer if (headers) |h| curl_slist_free_all(h);

        headers = curl_slist_append(headers, "Content-Type: application/json");
        headers = curl_slist_append(headers, "anthropic-version: 2023-06-01");

        // API key header
        var key_header_buf: [512]u8 = undefined;
        const key_header = std.fmt.bufPrintZ(&key_header_buf, "X-Api-Key: {s}", .{self.api_key}) catch return error.ApiKeyTooLong;
        headers = curl_slist_append(headers, key_header);

        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);

        // Set POST body
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));

        const body_z = try self.alloc.dupeZ(u8, body);
        defer self.alloc.free(body_z);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body_z.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

        // Set write callback for SSE streaming
        var parser = sse.StreamParser.init(self.alloc, text_cb);
        defer parser.deinit();

        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &parser);

        // Timeouts: 10s to connect, 120s total (SSE streaming can be slow)
        _ = curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
        _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 120));

        // Perform request with retry for HTTP 429 (rate limit)
        // Only 2 retries (6s total) — then fall through to fallback chain
        // which can route to local models with zero rate limits
        const max_retries: usize = 2;
        var attempt: usize = 0;
        while (true) {
            const result = curl_easy_perform(handle);
            if (result != .ok) {
                // curl-level failure (network, DNS, etc.) — not retryable
                const err_msg = curl_easy_strerror(result);
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("\n[curl error] {s}\n", .{err_msg}) catch {};
                return error.CurlRequestFailed;
            }

            var http_code: c_long = 0;
            _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);

            if (http_code == 200) break; // success — exit retry loop

            if (http_code == 429 and attempt < max_retries) {
                attempt += 1;
                // Exponential backoff: 2s, 4s
                const wait_secs: u64 = std.math.shl(u64, 2, @as(u6, @intCast(attempt - 1)));
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("\n[Rate limited] Waiting {d}s before retry ({d}/{d})...\n", .{ wait_secs, attempt, max_retries }) catch {};
                std.Thread.sleep(wait_secs * 1_000_000_000);
                // Reset SSE parser state for clean retry
                parser.reset();
                continue;
            }

            // Print error details from response body (parser captured it as raw text)
            const stderr = std.fs.File.stderr().deprecatedWriter();
            const error_body = parser.getAccumulatedText();
            if (error_body.len > 0) {
                stderr.print("\n[HTTP {d}] {s}\n", .{ http_code, error_body[0..@min(error_body.len, 500)] }) catch {};
            } else {
                stderr.print("\n[HTTP {d}] API request failed\n", .{http_code}) catch {};
            }

            // Context overflow: prompt too large (400 or 413)
            if (http_code == 400 or http_code == 413) return error.ContextOverflow;

            // Rate limit exhausted retries — return specific error so fallback
            // chain can prioritize local models (zero rate limits)
            if (http_code == 429) return error.RateLimited;

            return error.HttpError;
        }

        // Build response from accumulated parser state
        return parser.toResponse();
    }
};

/// curl write callback — receives chunks of SSE data
fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *sse.StreamParser,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.feed(ptr[0..total]) catch return 0;
    return total;
}
