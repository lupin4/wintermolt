// Copyright The Fantastic Planet - By David Clabaugh
//
// browser.zig — CDP browser automation tool
//
// Controls Chrome/Chromium browsers via Chrome DevTools Protocol (CDP).
// Connects to Chrome's debugging port (default: localhost:9222).
// Start Chrome with: google-chrome --remote-debugging-port=9222
//
// Operations:
//   list_tabs   — List all open tabs
//   new_tab     — Open a URL in a new tab
//   close_tab   — Close a tab by ID
//   navigate    — Navigate current tab to URL
//   snapshot    — Get page text content
//   click       — Click an element by CSS selector
//   type_text   — Type text into an element
//   evaluate    — Execute JavaScript expression
//   screenshot  — Capture page screenshot (base64 PNG)
//
// Architecture:
//   - HTTP endpoints (/json/*) via libcurl for tab management
//   - WebSocket CDP commands via std.process.Child spawning a helper script
//   - Falls back gracefully when Chrome is not running

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const sse = @import("../api/sse.zig");

// ---------------------------------------------------------------------------
// libcurl extern declarations (same as http.zig)
// ---------------------------------------------------------------------------

const CURL = opaque {};

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) CurlCode;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) CurlCode;

const CurlCode = enum(c_int) { ok = 0, _ };

const CURLOPT_URL: c_int = 10002;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_USERAGENT: c_int = 10018;
const CURLOPT_FOLLOWLOCATION: c_int = 52;
const CURLOPT_MAXREDIRS: c_int = 68;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

// ---------------------------------------------------------------------------
// Response buffer for libcurl callbacks
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
// Configuration
// ---------------------------------------------------------------------------

/// Default CDP debugging port. Override with WINTERMOLT_CDP_PORT env var.
const DEFAULT_CDP_PORT: u16 = 9222;

/// Max response size from CDP commands (prevent runaway output)
const MAX_CDP_RESPONSE: usize = 100_000;

/// Timeout for CDP HTTP requests (seconds)
const CDP_HTTP_TIMEOUT: c_long = 10;

/// Timeout for CDP WebSocket commands (seconds)
const CDP_WS_TIMEOUT: u32 = 15;

fn getCdpPort() u16 {
    const port_str = compat.getenv("WINTERMOLT_CDP_PORT") orelse return DEFAULT_CDP_PORT;
    return std.fmt.parseInt(u16, port_str, 10) catch DEFAULT_CDP_PORT;
}

fn getCdpBaseUrl(alloc: Allocator) ![]u8 {
    const port = getCdpPort();
    return std.fmt.allocPrint(alloc, "http://localhost:{d}", .{port});
}

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Execute a browser automation tool call.
/// Input JSON fields:
///   operation: "list_tabs"|"new_tab"|"close_tab"|"navigate"|"snapshot"|"click"|"type_text"|"evaluate"|"screenshot"
///   url:        URL for navigate/new_tab
///   selector:   CSS selector for click/type_text
///   text:       Text for type_text
///   expression: JavaScript expression for evaluate
///   tab_id:     Tab target ID for close_tab (and optionally for other ops)
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const operation = sse.findJsonString(input_json, "operation") orelse
        return std.fmt.allocPrint(alloc,
        "Error: missing 'operation' field. Available operations: list_tabs, new_tab, close_tab, navigate, snapshot, click, type_text, evaluate, screenshot", .{});

    if (std.mem.eql(u8, operation, "list_tabs")) return listTabs(alloc);
    if (std.mem.eql(u8, operation, "new_tab")) return newTab(alloc, input_json);
    if (std.mem.eql(u8, operation, "close_tab")) return closeTab(alloc, input_json);
    if (std.mem.eql(u8, operation, "navigate")) return navigate(alloc, input_json);
    if (std.mem.eql(u8, operation, "snapshot")) return snapshot(alloc, input_json);
    if (std.mem.eql(u8, operation, "click")) return click(alloc, input_json);
    if (std.mem.eql(u8, operation, "type_text")) return typeText(alloc, input_json);
    if (std.mem.eql(u8, operation, "evaluate")) return evaluate(alloc, input_json);
    if (std.mem.eql(u8, operation, "screenshot")) return screenshot(alloc, input_json);

    return std.fmt.allocPrint(alloc,
        "Unknown browser operation: '{s}'. Available: list_tabs, new_tab, close_tab, navigate, snapshot, click, type_text, evaluate, screenshot", .{operation});
}

// ---------------------------------------------------------------------------
// HTTP-based operations (tab management via /json/ endpoints)
// ---------------------------------------------------------------------------

/// GET a CDP HTTP endpoint and return the response body.
/// On failure, returns an error — callers format user-friendly messages.
fn cdpHttpGet(alloc: Allocator, path: []const u8) ![]u8 {
    const base_url = try getCdpBaseUrl(alloc);
    defer alloc.free(base_url);

    const full_url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base_url, path });
    defer alloc.free(full_url);

    const url_z = try alloc.dupeZ(u8, full_url);
    defer alloc.free(url_z);

    const handle = curl_easy_init() orelse
        return error.CurlInitFailed;
    defer curl_easy_cleanup(handle);

    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, CDP_HTTP_TIMEOUT);
    _ = curl_easy_setopt(handle, CURLOPT_USERAGENT, "Wintermolt/0.1");
    _ = curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_MAXREDIRS, @as(c_long, 3));

    var resp_buf = ResponseBuffer{
        .data = .{},
        .alloc = alloc,
    };
    defer resp_buf.data.deinit(alloc);

    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &resp_buf);

    const result = curl_easy_perform(handle);
    if (result != .ok) {
        return error.ConnectionRefused;
    }

    var http_code: c_long = 0;
    _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);

    if (http_code < 200 or http_code >= 300) {
        return error.HttpError;
    }

    return alloc.dupe(u8, resp_buf.data.items);
}

/// List all open browser tabs.
/// Returns JSON array of tab info from /json/list.
fn listTabs(alloc: Allocator) ![]u8 {
    const response = cdpHttpGet(alloc, "/json/list") catch |e| {
        return std.fmt.allocPrint(alloc, "Error listing tabs: {s}\nMake sure Chrome is running with --remote-debugging-port={d}", .{ @errorName(e), getCdpPort() });
    };
    defer alloc.free(response);

    // Parse the JSON array and format a readable summary
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch {
        // Return raw response if parsing fails
        return alloc.dupe(u8, response);
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        return alloc.dupe(u8, response);
    }

    var output: ArrayList(u8) = .{};
    const w = output.writer(alloc);

    try std.fmt.format(w, "Open tabs ({d}):\n", .{parsed.value.array.items.len});

    for (parsed.value.array.items, 0..) |item, idx| {
        if (item != .object) continue;
        const obj = item.object;

        const title = if (obj.get("title")) |v| switch (v) {
            .string => |s| s,
            else => "(untitled)",
        } else "(untitled)";

        const tab_url = if (obj.get("url")) |v| switch (v) {
            .string => |s| s,
            else => "(no url)",
        } else "(no url)";

        const tab_id = if (obj.get("id")) |v| switch (v) {
            .string => |s| s,
            else => "(no id)",
        } else "(no id)";

        const tab_type = if (obj.get("type")) |v| switch (v) {
            .string => |s| s,
            else => "unknown",
        } else "unknown";

        try std.fmt.format(w, "\n  [{d}] {s}\n      URL: {s}\n      ID: {s}\n      Type: {s}\n", .{
            idx, title, tab_url, tab_id, tab_type,
        });
    }

    return output.toOwnedSlice(alloc);
}

/// Open a new tab with an optional URL.
fn newTab(alloc: Allocator, input_json: []const u8) ![]u8 {
    const url = sse.findJsonString(input_json, "url") orelse "about:blank";

    // URL-encode the target URL for the query parameter
    var path: ArrayList(u8) = .{};
    defer path.deinit(alloc);
    const pw = path.writer(alloc);
    try std.fmt.format(pw, "/json/new?{s}", .{url});
    const path_slice = path.items;

    const response = cdpHttpGet(alloc, path_slice) catch |e| {
        return std.fmt.allocPrint(alloc, "Error opening new tab: {s}\nIs Chrome running with --remote-debugging-port={d}?", .{ @errorName(e), getCdpPort() });
    };
    defer alloc.free(response);

    // Extract the new tab ID from the response
    const tab_id = sse.findJsonString(response, "id") orelse "unknown";
    const title = sse.findJsonString(response, "title") orelse "(loading)";

    return std.fmt.allocPrint(alloc, "New tab opened.\n  ID: {s}\n  Title: {s}\n  URL: {s}", .{ tab_id, title, url });
}

/// Close a tab by ID.
fn closeTab(alloc: Allocator, input_json: []const u8) ![]u8 {
    const tab_id = sse.findJsonString(input_json, "tab_id") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'tab_id' field. Use list_tabs to see available tab IDs.", .{});

    var path: ArrayList(u8) = .{};
    defer path.deinit(alloc);
    const pw = path.writer(alloc);
    try std.fmt.format(pw, "/json/close/{s}", .{tab_id});
    const path_slice = path.items;

    const response = cdpHttpGet(alloc, path_slice) catch |e| {
        return std.fmt.allocPrint(alloc, "Error closing tab '{s}': {s}\nIs Chrome running with --remote-debugging-port={d}?", .{ tab_id, @errorName(e), getCdpPort() });
    };
    defer alloc.free(response);

    // Chrome returns "Target is closing" on success
    if (std.mem.indexOf(u8, response, "Target is closing") != null) {
        return std.fmt.allocPrint(alloc, "Tab '{s}' closed successfully.", .{tab_id});
    }

    return std.fmt.allocPrint(alloc, "Close tab response: {s}", .{response});
}

// ---------------------------------------------------------------------------
// WebSocket-based operations (CDP commands via subprocess)
// ---------------------------------------------------------------------------

/// Resolve the WebSocket debugger URL for a specific tab (or first page tab).
/// Queries /json/list and extracts webSocketDebuggerUrl.
fn resolveWsUrl(alloc: Allocator, tab_id: ?[]const u8) ![]u8 {
    const response = try cdpHttpGet(alloc, "/json/list");
    defer alloc.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidResponse;

    // If a specific tab_id was requested, find it
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        if (tab_id) |tid| {
            const item_id = if (obj.get("id")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            if (!std.mem.eql(u8, item_id, tid)) continue;
        } else {
            // No tab_id specified — find first "page" type tab
            const tab_type = if (obj.get("type")) |v| switch (v) {
                .string => |s| s,
                else => "unknown",
            } else "unknown";

            if (!std.mem.eql(u8, tab_type, "page")) continue;
        }

        // Found our target tab — extract webSocketDebuggerUrl
        const ws_url = if (obj.get("webSocketDebuggerUrl")) |v| switch (v) {
            .string => |s| s,
            else => return error.NoWsUrl,
        } else return error.NoWsUrl;

        return alloc.dupe(u8, ws_url);
    }

    return error.TabNotFound;
}

/// Send a CDP command via WebSocket using a subprocess.
/// Uses websocat if available, falls back to node -e one-liner.
///
/// The CDP protocol is JSON-RPC over WebSocket:
///   Send: {"id":1,"method":"Page.navigate","params":{"url":"https://..."}}
///   Recv: {"id":1,"result":{...}}
fn cdpCommand(alloc: Allocator, ws_url: []const u8, method: []const u8, params_json: []const u8) ![]u8 {
    // Build the JSON-RPC message
    const cdp_msg = try std.fmt.allocPrint(alloc,
        \\{{"id":1,"method":"{s}","params":{s}}}
    , .{ method, params_json });
    defer alloc.free(cdp_msg);

    // Strategy 1: Try websocat (lightweight WebSocket CLI tool)
    // Strategy 2: Fall back to node -e with built-in WebSocket (Node 22+) or ws module
    //
    // The bash command:
    //   echo '<cdp_msg>' | websocat -n1 '<ws_url>'
    // OR:
    //   node -e "const ws=new WebSocket('URL');ws.onopen=()=>{ws.send(JSON.stringify(MSG));};
    //            ws.onmessage=(e)=>{console.log(e.data);ws.close();};"
    //
    // We try websocat first because it's simpler and faster.

    // Escape single quotes in the CDP message for shell embedding
    var escaped_msg: ArrayList(u8) = .{};
    defer escaped_msg.deinit(alloc);
    const ew = escaped_msg.writer(alloc);
    for (cdp_msg) |ch| {
        if (ch == '\'') {
            try ew.writeAll("'\"'\"'");
        } else {
            try ew.writeByte(ch);
        }
    }

    // Escape single quotes in the WS URL too
    var escaped_url: ArrayList(u8) = .{};
    defer escaped_url.deinit(alloc);
    const uw = escaped_url.writer(alloc);
    for (ws_url) |ch| {
        if (ch == '\'') {
            try uw.writeAll("'\"'\"'");
        } else {
            try uw.writeByte(ch);
        }
    }

    // Build the shell command: try websocat, fall back to node
    const shell_cmd = try std.fmt.allocPrint(alloc,
        \\if command -v websocat >/dev/null 2>&1; then
        \\  echo '{s}' | websocat -n1 '{s}'
        \\elif command -v node >/dev/null 2>&1; then
        \\  node -e "
        \\    const ws = new WebSocket('{s}');
        \\    const timer = setTimeout(() => {{ process.exit(1); }}, {d}000);
        \\    ws.onopen = () => {{ ws.send('{s}'); }};
        \\    ws.onmessage = (e) => {{ console.log(e.data); ws.close(); clearTimeout(timer); }};
        \\    ws.onerror = (e) => {{ console.error('WebSocket error:', e.message); process.exit(1); }};
        \\  "
        \\else
        \\  echo 'ERROR: Neither websocat nor node found. Install one: brew install websocat OR brew install node'
        \\  exit 1
        \\fi
    , .{
        escaped_msg.items,
        escaped_url.items,
        escaped_url.items,
        CDP_WS_TIMEOUT,
        escaped_msg.items,
    });
    defer alloc.free(shell_cmd);

    const shell_z = try alloc.dupeZ(u8, shell_cmd);
    defer alloc.free(shell_z);

    // Spawn the subprocess
    var child = Child.init(
        &[_][]const u8{ "/bin/sh", "-c", shell_z },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    var stderr_buf: ArrayList(u8) = .{};
    defer stderr_buf.deinit(alloc);

    child.collectOutput(alloc, &stdout_buf, &stderr_buf, MAX_CDP_RESPONSE) catch |e| {
        switch (e) {
            error.StdoutStreamTooLong, error.StderrStreamTooLong => {},
            else => return e,
        }
    };

    const term = try child.wait();

    const exit_code: i64 = switch (term) {
        .Exited => |code| @as(i64, code),
        .Signal => |sig| -@as(i64, @intCast(sig)),
        else => -1,
    };

    if (exit_code != 0) {
        const stderr_out = stderr_buf.items;
        if (stderr_out.len > 0) {
            return std.fmt.allocPrint(alloc, "CDP command failed (exit {d}): {s}", .{ exit_code, stderr_out });
        }
        return std.fmt.allocPrint(alloc, "CDP command failed with exit code {d}", .{exit_code});
    }

    if (stdout_buf.items.len == 0) {
        return std.fmt.allocPrint(alloc, "CDP command returned empty response", .{});
    }

    return alloc.dupe(u8, stdout_buf.items);
}

/// Helper: resolve WS URL and send a CDP command, returning the parsed result.
/// If the CDP response has a "result" field, returns its content.
/// If it has an "error" field, returns a formatted error.
fn cdpCommandToTab(alloc: Allocator, input_json: []const u8, method: []const u8, params_json: []const u8) ![]u8 {
    const tab_id = sse.findJsonString(input_json, "tab_id");

    const ws_url = resolveWsUrl(alloc, tab_id) catch |e| {
        return switch (e) {
            error.TabNotFound => std.fmt.allocPrint(alloc, "Error: No matching tab found. Use list_tabs to see available tabs.", .{}),
            error.NoWsUrl => std.fmt.allocPrint(alloc, "Error: Tab has no WebSocket debugger URL. It may not be a page tab.", .{}),
            error.InvalidResponse => std.fmt.allocPrint(alloc, "Error: Invalid response from Chrome. Is it running with --remote-debugging-port={d}?", .{getCdpPort()}),
            error.ConnectionRefused => std.fmt.allocPrint(alloc, "Error: Cannot connect to Chrome. Is it running with --remote-debugging-port={d}?", .{getCdpPort()}),
            else => std.fmt.allocPrint(alloc, "Error resolving tab WebSocket URL: {s}", .{@errorName(e)}),
        };
    };
    defer alloc.free(ws_url);

    return cdpCommand(alloc, ws_url, method, params_json);
}

// ---------------------------------------------------------------------------
// CDP command implementations
// ---------------------------------------------------------------------------

/// Navigate the current (or specified) tab to a URL.
fn navigate(alloc: Allocator, input_json: []const u8) ![]u8 {
    const url = sse.findJsonString(input_json, "url") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'url' field for navigate operation", .{});

    // Build CDP params — escape the URL for JSON embedding
    var params: ArrayList(u8) = .{};
    defer params.deinit(alloc);
    const pw = params.writer(alloc);
    try pw.writeAll("{\"url\":\"");
    try writeJsonEscaped(pw, url);
    try pw.writeAll("\"}");

    const response = try cdpCommandToTab(alloc, input_json, "Page.navigate", params.items);
    defer alloc.free(response);

    // Check for frameId in response (indicates success)
    if (sse.findJsonString(response, "frameId")) |frame_id| {
        return std.fmt.allocPrint(alloc, "Navigated to: {s}\nFrame ID: {s}", .{ url, frame_id });
    }

    // Check for error
    if (sse.findJsonString(response, "error")) |err_obj| {
        const msg = sse.findJsonString(err_obj, "message") orelse "unknown error";
        return std.fmt.allocPrint(alloc, "Navigation failed: {s}", .{msg});
    }

    return std.fmt.allocPrint(alloc, "Navigation sent to: {s}\nRaw response: {s}", .{ url, response });
}

/// Get the text content of the current page.
fn snapshot(alloc: Allocator, input_json: []const u8) ![]u8 {
    // Use Runtime.evaluate to get document.body.innerText
    const js_expression =
        \\(function() {
        \\  var title = document.title || '';
        \\  var url = window.location.href || '';
        \\  var text = document.body ? document.body.innerText : '(no body)';
        \\  return 'Title: ' + title + '\\nURL: ' + url + '\\n\\n' + text;
        \\})()
    ;

    var params: ArrayList(u8) = .{};
    defer params.deinit(alloc);
    const pw = params.writer(alloc);
    try pw.writeAll("{\"expression\":\"");
    try writeJsonEscaped(pw, js_expression);
    try pw.writeAll("\",\"returnByValue\":true}");

    const response = try cdpCommandToTab(alloc, input_json, "Runtime.evaluate", params.items);
    defer alloc.free(response);

    // Extract the result value from the CDP response
    // Response shape: {"id":1,"result":{"result":{"type":"string","value":"..."}}}
    return extractEvalResult(alloc, response);
}

/// Click an element by CSS selector.
fn click(alloc: Allocator, input_json: []const u8) ![]u8 {
    const selector = sse.findJsonString(input_json, "selector") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'selector' field for click operation", .{});

    // Build a JS expression that finds and clicks the element
    var js: ArrayList(u8) = .{};
    defer js.deinit(alloc);
    const jw = js.writer(alloc);
    try jw.writeAll(
        \\(function() {
        \\  var el = document.querySelector('
    );
    // Escape the selector for JS string embedding (handle single quotes)
    for (selector) |ch| {
        if (ch == '\'') {
            try jw.writeAll("\\'");
        } else if (ch == '\\') {
            try jw.writeAll("\\\\");
        } else {
            try jw.writeByte(ch);
        }
    }
    try jw.writeAll(
        \\');
        \\  if (!el) return 'Error: element not found for selector:
    );
    for (selector) |ch| {
        if (ch == '\'') {
            try jw.writeAll("\\'");
        } else if (ch == '\\') {
            try jw.writeAll("\\\\");
        } else {
            try jw.writeByte(ch);
        }
    }
    try jw.writeAll(
        \\';
        \\  el.click();
        \\  var tag = el.tagName.toLowerCase();
        \\  var id = el.id ? '#' + el.id : '';
        \\  var cls = el.className ? '.' + el.className.split(' ').join('.') : '';
        \\  return 'Clicked: ' + tag + id + cls;
        \\})()
    );

    var params: ArrayList(u8) = .{};
    defer params.deinit(alloc);
    const pw = params.writer(alloc);
    try pw.writeAll("{\"expression\":\"");
    try writeJsonEscaped(pw, js.items);
    try pw.writeAll("\",\"returnByValue\":true}");

    const response = try cdpCommandToTab(alloc, input_json, "Runtime.evaluate", params.items);
    defer alloc.free(response);

    return extractEvalResult(alloc, response);
}

/// Type text into an element specified by CSS selector.
/// Sets the element's value property and dispatches an input event.
fn typeText(alloc: Allocator, input_json: []const u8) ![]u8 {
    const selector = sse.findJsonString(input_json, "selector") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'selector' field for type_text operation", .{});
    const text = sse.findJsonString(input_json, "text") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'text' field for type_text operation", .{});

    // Build JS that sets the value and dispatches events
    var js: ArrayList(u8) = .{};
    defer js.deinit(alloc);
    const jw = js.writer(alloc);
    try jw.writeAll("(function() { var el = document.querySelector('");
    for (selector) |ch| {
        if (ch == '\'') {
            try jw.writeAll("\\'");
        } else if (ch == '\\') {
            try jw.writeAll("\\\\");
        } else {
            try jw.writeByte(ch);
        }
    }
    try jw.writeAll("'); if (!el) return 'Error: element not found for selector: ");
    for (selector) |ch| {
        if (ch == '\'') {
            try jw.writeAll("\\'");
        } else if (ch == '\\') {
            try jw.writeAll("\\\\");
        } else {
            try jw.writeByte(ch);
        }
    }
    try jw.writeAll("'; el.focus(); ");

    // Use the native input setter to bypass frameworks that override .value
    try jw.writeAll("var nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value') || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value'); ");
    try jw.writeAll("if (nativeSet && nativeSet.set) { nativeSet.set.call(el, '");
    for (text) |ch| {
        if (ch == '\'') {
            try jw.writeAll("\\'");
        } else if (ch == '\\') {
            try jw.writeAll("\\\\");
        } else if (ch == '\n') {
            try jw.writeAll("\\n");
        } else if (ch == '\r') {
            try jw.writeAll("\\r");
        } else {
            try jw.writeByte(ch);
        }
    }
    try jw.writeAll("'); } else { el.value = '");
    for (text) |ch| {
        if (ch == '\'') {
            try jw.writeAll("\\'");
        } else if (ch == '\\') {
            try jw.writeAll("\\\\");
        } else if (ch == '\n') {
            try jw.writeAll("\\n");
        } else if (ch == '\r') {
            try jw.writeAll("\\r");
        } else {
            try jw.writeByte(ch);
        }
    }
    try jw.writeAll("'; } ");

    // Dispatch events so frameworks (React, Vue, etc.) pick up the change
    try jw.writeAll("el.dispatchEvent(new Event('input', {bubbles: true})); ");
    try jw.writeAll("el.dispatchEvent(new Event('change', {bubbles: true})); ");
    try jw.writeAll("return 'Typed ' + '");
    // Write escaped text length
    try std.fmt.format(jw, "{d}", .{text.len});
    try jw.writeAll("' + ' characters into ' + el.tagName.toLowerCase(); })()");

    var params: ArrayList(u8) = .{};
    defer params.deinit(alloc);
    const pw = params.writer(alloc);
    try pw.writeAll("{\"expression\":\"");
    try writeJsonEscaped(pw, js.items);
    try pw.writeAll("\",\"returnByValue\":true}");

    const response = try cdpCommandToTab(alloc, input_json, "Runtime.evaluate", params.items);
    defer alloc.free(response);

    return extractEvalResult(alloc, response);
}

/// Execute an arbitrary JavaScript expression in the page context.
fn evaluate(alloc: Allocator, input_json: []const u8) ![]u8 {
    const expression = sse.findJsonString(input_json, "expression") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'expression' field for evaluate operation", .{});

    var params: ArrayList(u8) = .{};
    defer params.deinit(alloc);
    const pw = params.writer(alloc);
    try pw.writeAll("{\"expression\":\"");
    try writeJsonEscaped(pw, expression);
    try pw.writeAll("\",\"returnByValue\":true,\"awaitPromise\":true}");

    const response = try cdpCommandToTab(alloc, input_json, "Runtime.evaluate", params.items);
    defer alloc.free(response);

    return extractEvalResult(alloc, response);
}

/// Capture a screenshot of the current page as base64-encoded PNG.
fn screenshot(alloc: Allocator, input_json: []const u8) ![]u8 {
    const response = try cdpCommandToTab(alloc, input_json, "Page.captureScreenshot", "{\"format\":\"png\"}");
    defer alloc.free(response);

    // Response: {"id":1,"result":{"data":"<base64 PNG>"}}
    if (sse.findJsonString(response, "result")) |result_obj| {
        if (sse.findJsonString(result_obj, "data")) |b64_data| {
            // Optionally save to file if output_path is specified
            const output_path = sse.findJsonString(input_json, "output_path");
            if (output_path) |path| {
                // Decode base64 and write to file
                const decoded = decodeBase64(alloc, b64_data) catch |e| {
                    return std.fmt.allocPrint(alloc, "Screenshot captured but failed to decode base64: {s}", .{@errorName(e)});
                };
                defer alloc.free(decoded);

                const file = std.fs.cwd().createFile(path, .{}) catch |e| {
                    return std.fmt.allocPrint(alloc, "Screenshot captured but failed to write to '{s}': {s}", .{ path, @errorName(e) });
                };
                defer file.close();
                file.writeAll(decoded) catch |e| {
                    return std.fmt.allocPrint(alloc, "Screenshot write error: {s}", .{@errorName(e)});
                };

                return std.fmt.allocPrint(alloc, "Screenshot saved to: {s} ({d} bytes)", .{ path, decoded.len });
            }

            // Return base64 data with size info
            return std.fmt.allocPrint(alloc, "Screenshot captured ({d} bytes base64).\nBase64 data (first 200 chars): {s}...\n\nTo save, use output_path parameter.", .{
                b64_data.len,
                b64_data[0..@min(b64_data.len, 200)],
            });
        }
    }

    // Check for error
    if (sse.findJsonString(response, "error")) |err_obj| {
        const msg = sse.findJsonString(err_obj, "message") orelse "unknown error";
        return std.fmt.allocPrint(alloc, "Screenshot failed: {s}", .{msg});
    }

    return std.fmt.allocPrint(alloc, "Screenshot response (unexpected format): {s}", .{
        response[0..@min(response.len, 500)],
    });
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/// Write a string with JSON escape sequences (for embedding in JSON string values).
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    // Control characters — use \u00XX encoding
                    try std.fmt.format(writer, "\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

/// Extract the string result from a CDP Runtime.evaluate response.
/// Response shape: {"id":1,"result":{"result":{"type":"string","value":"..."}}}
/// Also handles: {"id":1,"result":{"result":{"type":"undefined"}}}
/// And errors: {"id":1,"result":{"exceptionDetails":{...}}}
fn extractEvalResult(alloc: Allocator, response: []const u8) ![]u8 {
    // Check for exception in evaluation
    if (std.mem.indexOf(u8, response, "\"exceptionDetails\"") != null) {
        // Try to extract the exception text
        if (sse.findJsonString(response, "exceptionDetails")) |exc| {
            if (sse.findJsonString(exc, "text")) |text| {
                return std.fmt.allocPrint(alloc, "JavaScript error: {s}", .{text});
            }
        }
        // Fallback: show truncated raw response
        const show_len = @min(response.len, 500);
        return std.fmt.allocPrint(alloc, "JavaScript exception: {s}", .{response[0..show_len]});
    }

    // Try to extract result.result.value (nested "result" objects)
    if (sse.findJsonString(response, "result")) |outer_result| {
        // outer_result is the {"result":{...}} object
        if (sse.findJsonString(outer_result, "result")) |inner_result| {
            // inner_result is the {"type":"string","value":"..."}
            const result_type = sse.findJsonString(inner_result, "type") orelse "unknown";

            if (std.mem.eql(u8, result_type, "string")) {
                if (sse.findJsonString(inner_result, "value")) |value| {
                    // Truncate very large results
                    if (value.len > MAX_CDP_RESPONSE) {
                        var output: ArrayList(u8) = .{};
                        const w = output.writer(alloc);
                        try w.writeAll(value[0..MAX_CDP_RESPONSE]);
                        try std.fmt.format(w, "\n\n[truncated: {d} chars total, showing first {d}]", .{ value.len, MAX_CDP_RESPONSE });
                        return output.toOwnedSlice(alloc);
                    }
                    return alloc.dupe(u8, value);
                }
            } else if (std.mem.eql(u8, result_type, "undefined")) {
                return std.fmt.allocPrint(alloc, "(undefined)", .{});
            } else if (std.mem.eql(u8, result_type, "object")) {
                // For objects, try to get the description or preview
                if (sse.findJsonString(inner_result, "description")) |desc| {
                    return alloc.dupe(u8, desc);
                }
                if (sse.findJsonString(inner_result, "value")) |value| {
                    return alloc.dupe(u8, value);
                }
                return std.fmt.allocPrint(alloc, "[object] (use JSON.stringify() to see contents)", .{});
            } else if (std.mem.eql(u8, result_type, "number") or
                std.mem.eql(u8, result_type, "boolean"))
            {
                if (sse.findJsonString(inner_result, "description")) |desc| {
                    return alloc.dupe(u8, desc);
                }
                if (sse.findJsonString(inner_result, "value")) |value| {
                    return alloc.dupe(u8, value);
                }
            }

            // Fallback: return the inner result JSON
            return alloc.dupe(u8, inner_result);
        }

        // Single-level result (e.g., Page.navigate response)
        return alloc.dupe(u8, outer_result);
    }

    // Check for CDP error response
    if (sse.findJsonString(response, "error")) |err_obj| {
        const msg = sse.findJsonString(err_obj, "message") orelse "unknown CDP error";
        return std.fmt.allocPrint(alloc, "CDP error: {s}", .{msg});
    }

    // Fallback: return raw response (trimmed)
    const show_len = @min(response.len, 1000);
    return alloc.dupe(u8, response[0..show_len]);
}

/// Base64 decode table (comptime lookup for standard alphabet).
/// Same pattern as web/bridge.zig — proven to compile on Zig 0.15.2.
const base64_decode_table = blk: {
    var table: [256]u8 = [_]u8{0xFF} ** 256;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

/// Decode base64-encoded data for screenshot PNGs.
/// Strips whitespace and padding, handles standard alphabet.
fn decodeBase64(alloc: Allocator, encoded: []const u8) ![]u8 {
    // Count valid base64 characters (skip padding '=' and whitespace)
    var clean_len: usize = 0;
    for (encoded) |c| {
        if (base64_decode_table[c] != 0xFF) clean_len += 1;
    }
    if (clean_len == 0) return error.InvalidBase64;

    const output_len = (clean_len * 3) / 4;
    const output = try alloc.alloc(u8, output_len);
    errdefer alloc.free(output);

    var accum: u32 = 0;
    var bits: u5 = 0;
    var out_i: usize = 0;

    for (encoded) |c| {
        const val = base64_decode_table[c];
        if (val == 0xFF) continue; // skip padding, whitespace
        accum = (accum << 6) | @as(u32, val);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (out_i < output.len) {
                output[out_i] = @intCast((accum >> bits) & 0xFF);
                out_i += 1;
            }
        }
    }

    return output[0..out_i];
}
