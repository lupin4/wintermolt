// Copyright The Fantastic Planet - By David Clabaugh
//
// http.zig — HTTP request tool using libcurl
//
// Allows Claude to make HTTP GET/POST/PUT/DELETE requests to any URL.
// This enables: checking websites, calling APIs, pulling data, testing
// endpoints. Uses the same libcurl already linked for the Claude API client.
//
// Security: No authentication headers by default. User input is passed
// through — Claude decides what to request. Response bodies are truncated
// to prevent context overflow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");

// ---------------------------------------------------------------------------
// libcurl extern declarations (same as client.zig)
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) CurlCode;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) CurlCode;
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: *CurlSlist) void;
extern fn curl_easy_strerror(code: CurlCode) [*:0]const u8;

const CurlCode = enum(c_int) { ok = 0, _ };

const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_POST: c_int = 47;
const CURLOPT_CUSTOMREQUEST: c_int = 10036;
const CURLOPT_FOLLOWLOCATION: c_int = 52;
const CURLOPT_MAXREDIRS: c_int = 68;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_USERAGENT: c_int = 10018;
const CURLOPT_NOBODY: c_int = 44;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;
const CURLINFO_CONTENT_TYPE: c_int = 0x100012;

// ---------------------------------------------------------------------------
// Response buffer (same pattern as rag.zig)
// ---------------------------------------------------------------------------

const ResponseBuffer = struct {
    data: ArrayList(u8),
    alloc: Allocator,
};

fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *ResponseBuffer,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.data.appendSlice(userdata.alloc, ptr[0..total]) catch return 0;
    return total;
}

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Execute an HTTP request tool call.
/// Input JSON: {"url": "...", "method": "GET|POST|PUT|DELETE|HEAD", "body": "...", "headers": {"...": "..."}}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const url = sse.findJsonString(input_json, "url") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'url' field", .{});
    const method = sse.findJsonString(input_json, "method") orelse "GET";
    const body = sse.findJsonString(input_json, "body");

    return httpRequest(alloc, url, method, body, input_json);
}

/// Make an HTTP request and return the response.
pub fn httpRequest(
    alloc: Allocator,
    url: []const u8,
    method: []const u8,
    body: ?[]const u8,
    input_json: []const u8,
) ![]u8 {
    const handle = curl_easy_init() orelse
        return std.fmt.allocPrint(alloc, "Error: failed to initialize HTTP client", .{});
    defer curl_easy_cleanup(handle);

    // Set URL (null-terminated)
    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);
    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

    // Follow redirects (up to 5)
    _ = curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_MAXREDIRS, @as(c_long, 5));

    // Timeout: 30 seconds
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 30));

    // User agent
    _ = curl_easy_setopt(handle, CURLOPT_USERAGENT, "Wintermolt/0.1");

    // Method
    const is_head = std.mem.eql(u8, method, "HEAD");
    if (is_head) {
        _ = curl_easy_setopt(handle, CURLOPT_NOBODY, @as(c_long, 1));
    } else if (!std.mem.eql(u8, method, "GET")) {
        const method_z = try alloc.dupeZ(u8, method);
        defer alloc.free(method_z);
        _ = curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, method_z.ptr);
    }

    // Headers from JSON (parse "headers" object if present)
    var curl_headers: ?*CurlSlist = null;
    defer if (curl_headers) |h| curl_slist_free_all(h);

    // Parse custom headers from input_json if present
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, input_json, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    if (parsed) |p| {
        if (p.value.object.get("headers")) |headers_val| {
            if (headers_val == .object) {
                var it = headers_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const header_str = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.string });
                        defer alloc.free(header_str);
                        const header_z = try alloc.dupeZ(u8, header_str);
                        defer alloc.free(header_z);
                        curl_headers = curl_slist_append(curl_headers, header_z.ptr);
                    }
                }
            }
        }
    }

    if (curl_headers) |h| {
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
    }

    // POST/PUT body
    var body_z: ?[:0]u8 = null;
    defer if (body_z) |b| alloc.free(b);

    if (body) |b| {
        body_z = try alloc.dupeZ(u8, b);
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body_z.?.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)));
    }

    // Response buffer
    var resp_buf = ResponseBuffer{
        .data = .{},
        .alloc = alloc,
    };
    defer resp_buf.data.deinit(alloc);

    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &resp_buf);

    // Perform
    const result = curl_easy_perform(handle);
    if (result != .ok) {
        const err_msg = curl_easy_strerror(result);
        return std.fmt.allocPrint(alloc, "HTTP error: {s}", .{err_msg});
    }

    // Get response info
    var http_code: c_long = 0;
    _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);

    var content_type_ptr: ?[*:0]const u8 = null;
    _ = curl_easy_getinfo(handle, CURLINFO_CONTENT_TYPE, &content_type_ptr);
    const content_type = if (content_type_ptr) |ct| std.mem.span(ct) else "unknown";

    // Build response
    var output: ArrayList(u8) = .{};
    const w = output.writer(alloc);

    try std.fmt.format(w, "HTTP {d} {s}\nContent-Type: {s}\nSize: {d} bytes\n\n", .{
        http_code, method, content_type, resp_buf.data.items.len,
    });

    if (is_head) {
        // HEAD request — no body
        try w.writeAll("(HEAD request — no response body)");
    } else {
        // Truncate large responses
        const max_body: usize = 30_000;
        const body_data = resp_buf.data.items;
        if (body_data.len > max_body) {
            try w.writeAll(body_data[0..max_body]);
            try std.fmt.format(w, "\n\n[truncated: {d} bytes total, showing first {d}]", .{ body_data.len, max_body });
        } else {
            try w.writeAll(body_data);
        }
    }

    return output.toOwnedSlice(alloc);
}

/// Download a file from URL to disk. Returns result message.
pub fn downloadFile(alloc: Allocator, url: []const u8, output_path: []const u8) ![]u8 {
    const handle = curl_easy_init() orelse
        return std.fmt.allocPrint(alloc, "Error: failed to initialize HTTP client", .{});
    defer curl_easy_cleanup(handle);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);
    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_MAXREDIRS, @as(c_long, 10));
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 300)); // 5 min for downloads
    _ = curl_easy_setopt(handle, CURLOPT_USERAGENT, "Wintermolt/0.1");

    var resp_buf = ResponseBuffer{
        .data = .{},
        .alloc = alloc,
    };
    defer resp_buf.data.deinit(alloc);

    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &resp_buf);

    const result = curl_easy_perform(handle);
    if (result != .ok) {
        const err_msg = curl_easy_strerror(result);
        return std.fmt.allocPrint(alloc, "Download failed: {s}", .{err_msg});
    }

    var http_code: c_long = 0;
    _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);

    if (http_code < 200 or http_code >= 300) {
        return std.fmt.allocPrint(alloc, "Download failed: HTTP {d}", .{http_code});
    }

    // Write to file
    const file = std.fs.cwd().createFile(output_path, .{}) catch |e| {
        return std.fmt.allocPrint(alloc, "Failed to create file '{s}': {s}", .{ output_path, @errorName(e) });
    };
    defer file.close();

    file.writeAll(resp_buf.data.items) catch |e| {
        return std.fmt.allocPrint(alloc, "Failed to write file: {s}", .{@errorName(e)});
    };

    // Format size nicely
    const size = resp_buf.data.items.len;
    if (size >= 1_048_576) {
        return std.fmt.allocPrint(alloc, "Downloaded {d:.1} MB to {s} (HTTP {d})", .{
            @as(f64, @floatFromInt(size)) / 1_048_576.0,
            output_path,
            http_code,
        });
    } else if (size >= 1024) {
        return std.fmt.allocPrint(alloc, "Downloaded {d:.1} KB to {s} (HTTP {d})", .{
            @as(f64, @floatFromInt(size)) / 1024.0,
            output_path,
            http_code,
        });
    } else {
        return std.fmt.allocPrint(alloc, "Downloaded {d} bytes to {s} (HTTP {d})", .{
            size,
            output_path,
            http_code,
        });
    }
}
