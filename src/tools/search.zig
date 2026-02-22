// Copyright The Fantastic Planet - By David Clabaugh
//
// search.zig — Web search tool via DuckDuckGo HTML
//
// Provides web search by fetching DuckDuckGo's HTML endpoint (no JS,
// no API key, no bot blocking). Parses result titles, URLs, and snippets
// from the HTML response. Returns clean structured text for Claude.
//
// DDG HTML format:
//   <a rel="nofollow" class="result__a" href="URL">Title</a>
//   <a class="result__snippet" href="...">Snippet text</a>

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");

// ---------------------------------------------------------------------------
// libcurl extern declarations (same as http.zig)
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
extern fn curl_easy_escape(handle: ?*CURL, string: [*]const u8, length: c_int) ?[*:0]u8;
extern fn curl_free(ptr: *anyopaque) void;

const CurlCode = enum(c_int) { ok = 0, _ };

const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_FOLLOWLOCATION: c_int = 52;
const CURLOPT_MAXREDIRS: c_int = 68;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_USERAGENT: c_int = 10018;

const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

// ---------------------------------------------------------------------------
// Response buffer
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
// Search result
// ---------------------------------------------------------------------------

const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Execute a web search tool call.
/// Input JSON: {"query": "search terms", "num_results": 5}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const query = sse.findJsonString(input_json, "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query' field", .{});

    // Parse num_results (default 8)
    var num_results: usize = 8;
    if (sse.findJsonString(input_json, "num_results")) |s| {
        num_results = std.fmt.parseInt(usize, s, 10) catch 8;
    }
    if (num_results > 20) num_results = 20;
    if (num_results < 1) num_results = 1;

    return webSearch(alloc, query, num_results);
}

/// Perform a web search via DuckDuckGo HTML and return formatted results.
pub fn webSearch(alloc: Allocator, query: []const u8, max_results: usize) ![]u8 {
    const handle = curl_easy_init() orelse
        return std.fmt.allocPrint(alloc, "Error: failed to initialize HTTP client", .{});
    defer curl_easy_cleanup(handle);

    // URL-encode the query using curl's built-in encoder
    const encoded_query = curl_easy_escape(handle, query.ptr, @intCast(query.len)) orelse
        return std.fmt.allocPrint(alloc, "Error: failed to URL-encode query", .{});
    defer curl_free(@ptrCast(encoded_query));
    const encoded_slice = std.mem.span(encoded_query);

    // Build URL: https://html.duckduckgo.com/html/?q=QUERY
    const url = try std.fmt.allocPrint(alloc, "https://html.duckduckgo.com/html/?q={s}", .{encoded_slice});
    defer alloc.free(url);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);
    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

    // Follow redirects, 15s timeout
    _ = curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_MAXREDIRS, @as(c_long, 5));
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 15));

    // User agent — DDG respects standard browser UAs
    _ = curl_easy_setopt(handle, CURLOPT_USERAGENT, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Wintermolt/0.1");

    // Headers
    var headers: ?*CurlSlist = null;
    headers = curl_slist_append(headers, "Accept: text/html");
    headers = curl_slist_append(headers, "Accept-Language: en-US,en;q=0.9");
    defer if (headers) |h| curl_slist_free_all(h);
    if (headers) |h| {
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
    }

    // Response buffer
    var resp_buf = ResponseBuffer{
        .data = .{},
        .alloc = alloc,
    };
    defer resp_buf.data.deinit(alloc);

    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &resp_buf);

    // Perform request
    const result = curl_easy_perform(handle);
    if (result != .ok) {
        const err_msg = curl_easy_strerror(result);
        return std.fmt.allocPrint(alloc, "Search error: {s}", .{err_msg});
    }

    var http_code: c_long = 0;
    _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);

    if (http_code != 200) {
        return std.fmt.allocPrint(alloc, "Search failed: HTTP {d}", .{http_code});
    }

    const html = resp_buf.data.items;

    // Parse search results from DDG HTML
    var results: ArrayList(SearchResult) = .{};
    defer results.deinit(alloc);

    parseResults(alloc, html, max_results, &results);

    if (results.items.len == 0) {
        return std.fmt.allocPrint(alloc, "No results found for: {s}", .{query});
    }

    // Format results as clean text
    var output: ArrayList(u8) = .{};
    const w = output.writer(alloc);

    try std.fmt.format(w, "Web search: \"{s}\" ({d} results)\n\n", .{ query, results.items.len });

    for (results.items, 1..) |r, i| {
        try std.fmt.format(w, "{d}. {s}\n   {s}\n", .{ i, r.title, r.url });
        if (r.snippet.len > 0) {
            try std.fmt.format(w, "   {s}\n", .{r.snippet});
        }
        try w.writeByte('\n');
    }

    return output.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// HTML parsing — extract DDG search results
// ---------------------------------------------------------------------------

/// Parse DuckDuckGo HTML search results.
/// DDG uses two patterns for results:
///   1. <a class="result__a" href="URL">Title</a>
///   2. <a class="result__snippet" href="...">Snippet</a>
fn parseResults(alloc: Allocator, html: []const u8, max_results: usize, results: *ArrayList(SearchResult)) void {
    var pos: usize = 0;

    while (results.items.len < max_results and pos < html.len) {
        // Find next result link: class="result__a"
        const class_marker = "class=\"result__a\"";
        const marker_pos = indexOf(html, pos, class_marker) orelse break;
        pos = marker_pos + class_marker.len;

        // Extract URL from href="..."
        const href_url = extractHref(html, marker_pos) orelse {
            continue;
        };

        // Clean DDG redirect URL (//duckduckgo.com/l/?uddg=REAL_URL&...)
        const clean_url = cleanDdgUrl(alloc, href_url) catch href_url;

        // Extract title text (between > and </a>)
        const title = extractTagContent(alloc, html, pos) catch "Untitled";

        // Look for snippet near this result
        const snippet = findSnippet(alloc, html, pos) catch "";

        results.append(alloc, .{
            .title = title,
            .url = clean_url,
            .snippet = snippet,
        }) catch break;
    }
}

/// Find index of needle in haystack starting from pos.
fn indexOf(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (start + needle.len > haystack.len) return null;
    return if (std.mem.indexOf(u8, haystack[start..], needle)) |i| start + i else null;
}

/// Extract href value from the tag surrounding the given position.
/// Searches backward and forward from pos for href="..."
fn extractHref(html: []const u8, pos: usize) ?[]const u8 {
    // Search backward for the opening <a tag
    const search_start = if (pos > 500) pos - 500 else 0;
    const tag_region = html[search_start..@min(pos + 200, html.len)];

    // Find href=" in this region
    const href_needle = "href=\"";
    const href_pos = std.mem.lastIndexOf(u8, tag_region, href_needle) orelse return null;
    const value_start = href_pos + href_needle.len;

    // Find closing quote
    const close = std.mem.indexOfScalarPos(u8, tag_region, value_start, '"') orelse return null;
    return tag_region[value_start..close];
}

/// Extract text content after a > tag, stripping HTML tags.
fn extractTagContent(alloc: Allocator, html: []const u8, pos: usize) ![]const u8 {
    // Find the next > after pos (opening tag close)
    const gt = std.mem.indexOfScalarPos(u8, html, pos, '>') orelse return "Untitled";
    const content_start = gt + 1;

    // Find </a>
    const end_tag = indexOf(html, content_start, "</a>") orelse
        indexOf(html, content_start, "</A>") orelse return "Untitled";

    const raw = html[content_start..end_tag];

    // Strip HTML tags from content
    return stripHtml(alloc, raw);
}

/// Find the snippet for a result near the given position.
fn findSnippet(alloc: Allocator, html: []const u8, pos: usize) ![]const u8 {
    // Look for class="result__snippet" within ~2000 chars ahead
    const search_end = @min(pos + 2000, html.len);
    const search_region = html[pos..search_end];

    const snippet_marker = "class=\"result__snippet\"";
    const marker_pos = std.mem.indexOf(u8, search_region, snippet_marker) orelse return "";
    const after_marker = pos + marker_pos + snippet_marker.len;

    // But stop if we hit another result__a first (means this is the next result)
    const next_result = indexOf(html, pos + 10, "class=\"result__a\"");
    if (next_result) |nr| {
        if (pos + marker_pos > nr) return ""; // Snippet belongs to next result
    }

    // Find > after snippet class
    const gt = std.mem.indexOfScalarPos(u8, html, after_marker, '>') orelse return "";
    const content_start = gt + 1;

    // Find closing tag </a> or </span>
    const end = indexOf(html, content_start, "</a>") orelse
        indexOf(html, content_start, "</span>") orelse return "";

    if (end <= content_start) return "";

    const raw = html[content_start..end];
    return stripHtml(alloc, raw);
}

/// Clean DDG redirect URL: //duckduckgo.com/l/?uddg=ENCODED_URL&... → REAL_URL
fn cleanDdgUrl(alloc: Allocator, url: []const u8) ![]const u8 {
    const uddg = "uddg=";
    if (std.mem.indexOf(u8, url, uddg)) |uddg_pos| {
        const value_start = uddg_pos + uddg.len;
        // Find end of URL param (& or end of string)
        const value_end = std.mem.indexOfScalarPos(u8, url, value_start, '&') orelse url.len;
        const encoded = url[value_start..value_end];
        // URL-decode the value
        return urlDecode(alloc, encoded);
    }
    // Not a redirect — return as-is
    return try alloc.dupe(u8, url);
}

/// Simple URL decoder (%XX → byte).
fn urlDecode(alloc: Allocator, input: []const u8) ![]u8 {
    var output: ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]);
            const lo = hexVal(input[i + 2]);
            if (hi != null and lo != null) {
                try output.append(alloc, (hi.? << 4) | lo.?);
                i += 3;
                continue;
            }
        }
        if (input[i] == '+') {
            try output.append(alloc, ' ');
        } else {
            try output.append(alloc, input[i]);
        }
        i += 1;
    }
    return output.toOwnedSlice(alloc);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Strip HTML tags from text, decode basic HTML entities.
fn stripHtml(alloc: Allocator, input: []const u8) ![]u8 {
    var output: ArrayList(u8) = .{};
    var i: usize = 0;
    var in_tag = false;

    while (i < input.len) {
        if (input[i] == '<') {
            // Check for <b>, </b>, <br>, etc — just skip
            in_tag = true;
            i += 1;
            continue;
        }
        if (in_tag) {
            if (input[i] == '>') {
                in_tag = false;
            }
            i += 1;
            continue;
        }
        if (input[i] == '&') {
            // Decode HTML entities
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try output.append(alloc, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try output.append(alloc, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try output.append(alloc, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try output.append(alloc, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&#x27;") or std.mem.startsWith(u8, input[i..], "&apos;")) {
                try output.append(alloc, '\'');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&nbsp;")) {
                try output.append(alloc, ' ');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&#")) {
                // Numeric entity: &#123; or &#x1A;
                const semi = std.mem.indexOfScalarPos(u8, input, i, ';') orelse {
                    try output.append(alloc, '&');
                    i += 1;
                    continue;
                };
                // Just skip numeric entities for now
                i = semi + 1;
            } else {
                try output.append(alloc, '&');
                i += 1;
            }
            continue;
        }
        try output.append(alloc, input[i]);
        i += 1;
    }

    // Trim whitespace
    const slice = output.items;
    var start: usize = 0;
    while (start < slice.len and (slice[start] == ' ' or slice[start] == '\n' or slice[start] == '\t' or slice[start] == '\r')) : (start += 1) {}
    var end: usize = slice.len;
    while (end > start and (slice[end - 1] == ' ' or slice[end - 1] == '\n' or slice[end - 1] == '\t' or slice[end - 1] == '\r')) : (end -= 1) {}

    if (start == 0 and end == slice.len) {
        return output.toOwnedSlice(alloc);
    }

    const trimmed = try alloc.dupe(u8, slice[start..end]);
    output.deinit(alloc);
    return trimmed;
}
