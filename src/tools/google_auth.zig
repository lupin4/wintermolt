// Copyright The Fantastic Planet - By David Clabaugh
//
// google_auth.zig — Google OAuth2 authentication
//
// Manages OAuth2 access tokens for Google APIs (Gmail, Calendar, Drive).
// Supports two auth modes:
//   1. OAuth2 refresh token flow (for personal accounts)
//      Requires: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
//   2. Service account JSON key (for workspace/bot accounts)
//      Requires: GOOGLE_SERVICE_ACCOUNT_KEY (path to JSON key file)
//
// Tokens are cached in memory and auto-refreshed when expired.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// libcurl externs
const CURL = opaque {};
const CurlSlist = opaque {};
extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) CurlCode;
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: *CurlSlist) void;

const CurlCode = enum(c_int) { ok = 0, _ };
const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_POST: c_int = 47;
const CURLOPT_TIMEOUT: c_int = 13;

const ResponseBuffer = struct {
    data: ArrayList(u8),
    alloc: Allocator,
};

fn writeCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *ResponseBuffer) callconv(.c) usize {
    const total = size * nmemb;
    userdata.data.appendSlice(userdata.alloc, ptr[0..total]) catch return 0;
    return total;
}

const sse = @import("../api/sse.zig");

// ---------------------------------------------------------------------------
// Auth client
// ---------------------------------------------------------------------------

pub const GoogleAuth = struct {
    alloc: Allocator,
    client_id: ?[]const u8,
    client_secret: ?[]const u8,
    refresh_token: ?[]const u8,
    // Cached access token
    access_token: ?[]u8,
    token_expiry: i64,

    pub fn init(alloc: Allocator) GoogleAuth {
        return .{
            .alloc = alloc,
            .client_id = std.posix.getenv("GOOGLE_CLIENT_ID"),
            .client_secret = std.posix.getenv("GOOGLE_CLIENT_SECRET"),
            .refresh_token = std.posix.getenv("GOOGLE_REFRESH_TOKEN"),
            .access_token = null,
            .token_expiry = 0,
        };
    }

    pub fn deinit(self: *GoogleAuth) void {
        if (self.access_token) |tok| self.alloc.free(tok);
    }

    /// Check if Google auth is configured.
    pub fn isConfigured(self: *const GoogleAuth) bool {
        return self.client_id != null and self.client_secret != null and self.refresh_token != null;
    }

    /// Get a valid access token. Refreshes if expired.
    pub fn getAccessToken(self: *GoogleAuth) ![]const u8 {
        const now = std.time.timestamp();

        // Return cached token if still valid (with 60s buffer)
        if (self.access_token) |tok| {
            if (now < self.token_expiry - 60) return tok;
        }

        // Refresh the token
        try self.refreshAccessToken();
        return self.access_token orelse error.NoToken;
    }

    /// Build an Authorization header value. Caller owns the result.
    pub fn getAuthHeader(self: *GoogleAuth) ![]u8 {
        const token = try self.getAccessToken();
        return std.fmt.allocPrint(self.alloc, "Authorization: Bearer {s}", .{token});
    }

    fn refreshAccessToken(self: *GoogleAuth) !void {
        const client_id = self.client_id orelse return error.NotConfigured;
        const client_secret = self.client_secret orelse return error.NotConfigured;
        const refresh_token = self.refresh_token orelse return error.NotConfigured;

        const body = try std.fmt.allocPrint(self.alloc,
            "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
            .{ client_id, client_secret, refresh_token },
        );
        defer self.alloc.free(body);

        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        var response = ResponseBuffer{ .data = .{}, .alloc = self.alloc };

        _ = curl_easy_setopt(handle, CURLOPT_URL, "https://oauth2.googleapis.com/token");
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
        _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 10));

        var headers: ?*CurlSlist = null;
        headers = curl_slist_append(headers, "Content-Type: application/x-www-form-urlencoded");
        if (headers) |h| {
            _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
            defer curl_slist_free_all(h);
        }

        const result = curl_easy_perform(handle);
        defer response.data.deinit(self.alloc);

        if (result != .ok) return error.TokenRefreshFailed;

        // Parse response for access_token and expires_in
        const resp = response.data.items;
        const token = sse.findJsonString(resp, "access_token") orelse return error.NoTokenInResponse;
        const expires_str = sse.findJsonString(resp, "expires_in") orelse "3600";
        const expires_in = std.fmt.parseInt(i64, expires_str, 10) catch 3600;

        // Cache the token
        if (self.access_token) |old| self.alloc.free(old);
        self.access_token = try self.alloc.dupe(u8, token);
        self.token_expiry = std.time.timestamp() + expires_in;
    }
};

/// Make an authenticated GET request to a Google API endpoint.
/// Returns the response body. Caller owns the result.
pub fn googleGet(alloc: Allocator, auth: *GoogleAuth, url: []const u8) ![]u8 {
    const auth_header = try auth.getAuthHeader();
    defer alloc.free(auth_header);
    const auth_z = try alloc.dupeZ(u8, auth_header);
    defer alloc.free(auth_z);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);

    const handle = curl_easy_init() orelse return error.CurlInitFailed;
    defer curl_easy_cleanup(handle);

    var response = ResponseBuffer{ .data = .{}, .alloc = alloc };

    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 15));

    var headers: ?*CurlSlist = null;
    headers = curl_slist_append(headers, auth_z.ptr);
    if (headers) |h| {
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
        defer curl_slist_free_all(h);
    }

    const result = curl_easy_perform(handle);
    if (result != .ok) {
        response.data.deinit(alloc);
        return error.RequestFailed;
    }

    return response.data.toOwnedSlice(alloc);
}

/// Make an authenticated POST request to a Google API endpoint.
pub fn googlePost(alloc: Allocator, auth: *GoogleAuth, url: []const u8, body: []const u8) ![]u8 {
    const auth_header = try auth.getAuthHeader();
    defer alloc.free(auth_header);
    const auth_z = try alloc.dupeZ(u8, auth_header);
    defer alloc.free(auth_z);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);

    const handle = curl_easy_init() orelse return error.CurlInitFailed;
    defer curl_easy_cleanup(handle);

    var response = ResponseBuffer{ .data = .{}, .alloc = alloc };

    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 15));

    var headers: ?*CurlSlist = null;
    headers = curl_slist_append(headers, auth_z.ptr);
    headers = curl_slist_append(headers, "Content-Type: application/json");
    if (headers) |h| {
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
        defer curl_slist_free_all(h);
    }

    const result = curl_easy_perform(handle);
    if (result != .ok) {
        response.data.deinit(alloc);
        return error.RequestFailed;
    }

    return response.data.toOwnedSlice(alloc);
}
