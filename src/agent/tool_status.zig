// Copyright The Fantastic Planet - By David Clabaugh
//
// tool_status.zig -- did a tool call fail?
//
// Most tools report failure as an ordinary result string rather than a Zig
// error, so the model can read the reason: "Search error: Problem with the SSL
// CA cert (path? access rights?)", "HTTP error: ...", "Error: missing 'url'
// field". The REPL and the TUI printed [ok] after every one of those.
//
// This decides from the tools' own conventions, collected from the result
// strings in src/tools/*.zig and src/agent/tools.zig: a failure is a result
// that STARTS with one of the prefixes below. Only the start is checked, so a
// successful result that mentions an error further down -- a fetched web page,
// a log file -- is still ok.
//
// bash is the exception. Its result is the command's own output, which can
// begin with anything, so only the tool's refusals count there; a command
// that exits non-zero is reported by "[exit code: N]" in the output and is a
// result, not a tool failure.
//
// Pure: no I/O, no other wintermolt imports, so build.zig roots a test binary
// at this file.

const std = @import("std");

pub const Status = enum { ok, failed };

/// Result prefixes the tools use for a failed call.
const failure_prefixes = [_][]const u8{
    // Generic: missing fields, bad input, "Error reading 'x'", "Error listing tabs".
    "Error:",
    "Error ",
    // loop.zig, when executeTool returns a Zig error.
    "Tool execution error:",
    // agent/tools.zig dispatch.
    "Unknown tool:",
    // tools/search.zig
    "Search error:",
    "Search failed:",
    // tools/http.zig
    "HTTP error:",
    "Download failed:",
    "Failed to ",
    // tools/glob.zig, tools/grep.zig
    "Cannot open directory",
    "Cannot access",
    // tools/browser.zig
    "CDP command failed",
    "CDP command returned empty response",
    "CDP error:",
    "Navigation failed:",
    "Screenshot failed:",
    "Screenshot write error:",
    "Screenshot captured but failed",
    "JavaScript error:",
    "JavaScript exception:",
    // tools/camera.zig
    "Camera capture failed:",
    "Object detect: camera capture failed",
    "Object detect: cannot",
    "imagesnap not found",
    "No video devices found",
    "Unknown camera operation:",
    // tools/canvas.zig
    "Canvas TUI render error:",
    "Unknown canvas action:",
    // tools/tailscale.zig
    "Tailscale API request failed:",
    "tailscale ping failed:",
    "Unknown tailscale action:",
    // tools/image_gen.zig
    "Image generated but download failed",
    // agent/tools.zig image_process
    "Unsupported image operation:",
};

/// bash's own refusals (agent/tools.zig executeBash).
const bash_failure_prefixes = [_][]const u8{
    "BLOCKED:",
    "Error: missing 'command' field",
};

pub fn classify(tool_name: []const u8, result: []const u8) Status {
    const text = std.mem.trimStart(u8, result, " \t\r\n");
    // agent/tools.zig checks policy before dispatching, for every tool.
    if (std.mem.startsWith(u8, text, "Tool '") and
        std.mem.indexOf(u8, text, "is not permitted by current policy") != null) return .failed;
    const prefixes: []const []const u8 = if (std.mem.eql(u8, tool_name, "bash"))
        &bash_failure_prefixes
    else
        &failure_prefixes;
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, text, p)) return .failed;
    }
    return .ok;
}

const testing = std.testing;

test "the reported web_search SSL failure is a failure" {
    try testing.expectEqual(Status.failed, classify("web_search", "Search error: Problem with the SSL CA cert (path? access rights?)"));
    try testing.expectEqual(Status.failed, classify("web_search", "Search failed: HTTP 403"));
    try testing.expectEqual(Status.failed, classify("http_request", "HTTP error: Couldn't resolve host name"));
    try testing.expectEqual(Status.failed, classify("http_request", "Error: missing 'url' field"));
    try testing.expectEqual(Status.failed, classify("browser_control", "Error listing tabs: ConnectionRefused\nMake sure Chrome is running"));
    try testing.expectEqual(Status.failed, classify("glob", "Cannot open directory 'x': FileNotFound"));
    try testing.expectEqual(Status.failed, classify("nope", "Unknown tool: 'nope'. Use the 'skills' tool to see available tools."));
    try testing.expectEqual(Status.failed, classify("file_read", "Tool execution error: FileNotFound"));
}

test "successful results are ok, including ones that mention errors later" {
    try testing.expectEqual(Status.ok, classify("web_search", "1. Zig\n   https://ziglang.org\n   A general-purpose language..."));
    try testing.expectEqual(Status.ok, classify("web_search", "No results found for: qwxzv"));
    try testing.expectEqual(Status.ok, classify("http_request", "HTTP 200 GET\nContent-Type: text/html\nSize: 5 bytes\n\nError: none"));
    try testing.expectEqual(Status.ok, classify("file_write", "Wrote 12 bytes to notes.txt"));
    try testing.expectEqual(Status.ok, classify("glob", ""));
}

test "bash: only the tool's own refusals fail, not the command's output" {
    try testing.expectEqual(Status.failed, classify("bash", "BLOCKED: Command refused by safety check.\nCommand: rm -rf /"));
    try testing.expectEqual(Status.failed, classify("bash", "Error: missing 'command' field"));
    try testing.expectEqual(Status.ok, classify("bash", "Error: no such file\n[exit code: 1]"));
    try testing.expectEqual(Status.ok, classify("bash", "Failed to connect\n[exit code: 7]"));
}

test "a policy refusal fails for every tool" {
    try testing.expectEqual(Status.failed, classify("bash", "Tool 'bash' is not permitted by current policy."));
    try testing.expectEqual(Status.failed, classify("web_search", "Tool 'web_search' is not permitted by current policy."));
}
