// Copyright The Fantastic Planet - By David Clabaugh
//
// bash.zig — Shell command execution tool
//
// Runs commands via /bin/sh -c, capturing stdout+stderr.
// Output is truncated at 30000 bytes to stay within API limits.
// Uses std.process.Child.collectOutput (Zig 0.15.2 API).
// Secrets are redacted before returning output to the API context.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;

const MAX_OUTPUT: usize = 30_000;

/// Sandbox mode — when set, bash commands are routed through Docker.
/// Configured via WINTERMOLT_SANDBOX env var at startup.
pub var sandbox_enabled: bool = false;
pub var sandbox_image: []const u8 = "wintermolt-sandbox:latest";
pub var sandbox_timeout: u32 = 30;
pub var sandbox_memory: []const u8 = "256m";
pub var sandbox_network: []const u8 = "none";

pub fn execute(alloc: Allocator, command: []const u8) ![]u8 {
    // Route through Docker sandbox if enabled
    if (sandbox_enabled) {
        return executeSandboxed(alloc, command);
    }
    return executeHost(alloc, command);
}

fn executeHost(alloc: Allocator, command: []const u8) ![]u8 {
    const cmd_z = try alloc.dupeZ(u8, command);
    defer alloc.free(cmd_z);

    // Use login shell to inherit user's PATH (Homebrew, pyenv, etc.)
    var child = Child.init(
        &[_][]const u8{ "/bin/sh", "-l", "-c", cmd_z },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Collect stdout and stderr using the 0.15.2 poll-based API
    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, MAX_OUTPUT) catch |e| {
        // If stream too long, that's ok — we have partial data
        switch (e) {
            error.StdoutStreamTooLong, error.StderrStreamTooLong => {},
            else => return e,
        }
    };

    const term = try child.wait();

    const stdout = stdout_list.items;
    const stderr_out = stderr_list.items;

    // Build output: combine stdout + stderr + exit code
    var result: ArrayList(u8) = .{};
    const w = result.writer(alloc);

    if (stdout.len > 0) {
        try w.writeAll(stdout);
    }
    if (stderr_out.len > 0) {
        if (stdout.len > 0) try w.writeByte('\n');
        try w.writeAll(stderr_out);
    }

    const exit_code: i64 = switch (term) {
        .Exited => |code| @as(i64, code),
        .Signal => |sig| -@as(i64, @intCast(sig)),
        else => -1,
    };

    if (exit_code != 0) {
        try std.fmt.format(w, "\n[exit code: {d}]", .{exit_code});
    }

    if (result.items.len == 0) {
        try w.writeAll("[no output]");
    }

    // Redact secrets before returning to API context
    const raw = try result.toOwnedSlice(alloc);
    return redactSecrets(alloc, raw);
}

/// Execute command in a Docker container sandbox.
/// Mounts CWD as read-only, restricts network/memory/CPU, enforces timeout.
fn executeSandboxed(alloc: Allocator, command: []const u8) ![]u8 {
    // Build timeout string
    var timeout_buf: [16]u8 = undefined;
    const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{sandbox_timeout}) catch "30";

    // Get CWD for volume mount
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "/tmp";

    // Build docker run command args
    var vol_buf: [4200]u8 = undefined;
    const vol_mount = std.fmt.bufPrint(&vol_buf, "{s}:/workspace:ro", .{cwd}) catch "/tmp:/workspace:ro";

    var net_buf: [64]u8 = undefined;
    const net_flag = std.fmt.bufPrint(&net_buf, "--network={s}", .{sandbox_network}) catch "--network=none";

    var mem_buf: [64]u8 = undefined;
    const mem_flag = std.fmt.bufPrint(&mem_buf, "--memory={s}", .{sandbox_memory}) catch "--memory=256m";

    const cmd_z = try alloc.dupeZ(u8, command);
    defer alloc.free(cmd_z);

    var child = Child.init(
        &[_][]const u8{
            "docker",    "run",          "--rm",
            net_flag,    mem_flag,        "--cpus=1",
            "--stop-timeout", timeout_str, "-v",
            vol_mount,   "-w",           "/workspace",
            sandbox_image, "sh",          "-c",
            cmd_z,
        },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |e| {
        // Docker not available — fall back to host if sandbox not strictly required
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("[sandbox] Docker unavailable ({s}), falling back to host execution\n", .{@errorName(e)}) catch {};
        return executeHost(alloc, command);
    };

    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, MAX_OUTPUT) catch |e| {
        switch (e) {
            error.StdoutStreamTooLong, error.StderrStreamTooLong => {},
            else => return e,
        }
    };

    const term = try child.wait();

    var result: ArrayList(u8) = .{};
    const w = result.writer(alloc);

    if (stdout_list.items.len > 0) try w.writeAll(stdout_list.items);
    if (stderr_list.items.len > 0) {
        if (stdout_list.items.len > 0) try w.writeByte('\n');
        try w.writeAll(stderr_list.items);
    }

    const exit_code: i64 = switch (term) {
        .Exited => |code| @as(i64, code),
        .Signal => |sig| -@as(i64, @intCast(sig)),
        else => -1,
    };

    if (exit_code != 0) {
        try std.fmt.format(w, "\n[exit code: {d}]", .{exit_code});
    }

    if (result.items.len == 0) {
        try w.writeAll("[no output]");
    }

    const raw = try result.toOwnedSlice(alloc);
    return redactSecrets(alloc, raw);
}

// ---------------------------------------------------------------------------
// Secrets redaction — prevents API keys from leaking into conversation context
// ---------------------------------------------------------------------------

/// Known API key prefixes and their minimum length after prefix.
const SecretPattern = struct {
    prefix: []const u8,
    min_value_len: usize, // minimum chars after prefix to consider a match
};

const secret_prefixes = [_]SecretPattern{
    .{ .prefix = "sk-ant-api03-", .min_value_len = 40 }, // Anthropic
    .{ .prefix = "sk-ant-", .min_value_len = 20 }, // Anthropic (short form)
    .{ .prefix = "sk-proj-", .min_value_len = 20 }, // OpenAI project keys
    .{ .prefix = "sk-", .min_value_len = 20 }, // OpenAI legacy
    .{ .prefix = "xoxb-", .min_value_len = 20 }, // Slack bot token
    .{ .prefix = "xoxp-", .min_value_len = 20 }, // Slack user token
    .{ .prefix = "xapp-", .min_value_len = 20 }, // Slack app token
    .{ .prefix = "ghp_", .min_value_len = 20 }, // GitHub personal access
    .{ .prefix = "gho_", .min_value_len = 20 }, // GitHub OAuth
    .{ .prefix = "ghs_", .min_value_len = 20 }, // GitHub server-to-server
    .{ .prefix = "ghu_", .min_value_len = 20 }, // GitHub user-to-server
    .{ .prefix = "AIza", .min_value_len = 30 }, // Google API keys
};

/// Env var name suffixes that indicate secrets (matched in KEY=VALUE lines).
const secret_env_suffixes = [_][]const u8{
    "_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_CREDENTIAL", "_API_KEY",
};

/// Redact known secret patterns from output text.
/// Operates line-by-line for env-var assignments, and does full-text prefix scanning.
/// Returns a new allocation with secrets replaced by [REDACTED]. Frees the input.
fn redactSecrets(alloc: Allocator, raw: []u8) ![]u8 {
    // Fast path: short output unlikely to contain secrets
    if (raw.len < 10) return raw;

    var output: ArrayList(u8) = .{};
    const w = output.writer(alloc);

    var line_iter = std.mem.splitScalar(u8, raw, '\n');
    var first_line = true;
    while (line_iter.next()) |line| {
        if (!first_line) try w.writeByte('\n');
        first_line = false;

        // Check for KEY=VALUE pattern where KEY ends with a secret suffix
        if (redactEnvLine(line)) |safe_line| {
            try w.writeAll(safe_line.before_eq);
            try w.writeByte('=');
            try w.writeAll("[REDACTED]");
            // value after '=' intentionally dropped
        } else {
            // Scan line for inline secret prefixes
            try redactInlineSecrets(w, line);
        }
    }

    alloc.free(raw);
    return output.toOwnedSlice(alloc);
}

const RedactedLine = struct {
    before_eq: []const u8,
};

/// Check if a line is KEY=VALUE where KEY looks like a secret env var.
fn redactEnvLine(line: []const u8) ?RedactedLine {
    const trimmed = std.mem.trim(u8, line, " \t");

    // Strip optional 'export ' prefix
    const effective = if (std.mem.startsWith(u8, trimmed, "export "))
        std.mem.trim(u8, trimmed["export ".len..], " \t")
    else
        trimmed;

    const eq_pos = std.mem.indexOfScalar(u8, effective, '=') orelse return null;
    if (eq_pos == 0) return null;

    const key = effective[0..eq_pos];
    const value = effective[eq_pos + 1 ..];

    // Skip if value is empty or very short (not a real secret)
    if (value.len < 8) return null;

    // Check if key ends with a known secret suffix (case-insensitive)
    for (&secret_env_suffixes) |suffix| {
        if (key.len >= suffix.len) {
            if (endsWithCaseInsensitive(key, suffix)) {
                // Return pointer into original line up to and including '='
                const offset = @intFromPtr(effective.ptr) - @intFromPtr(line.ptr);
                return .{ .before_eq = line[0 .. offset + eq_pos] };
            }
        }
    }

    return null;
}

fn endsWithCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const tail = haystack[haystack.len - needle.len ..];
    for (tail, needle) |h, n| {
        const hl = if (h >= 'A' and h <= 'Z') h + 32 else h;
        const nl = if (n >= 'A' and n <= 'Z') n + 32 else n;
        if (hl != nl) return false;
    }
    return true;
}

/// Scan a line for inline secret prefixes and redact the token value.
fn redactInlineSecrets(w: anytype, line: []const u8) !void {
    var pos: usize = 0;
    while (pos < line.len) {
        var found_match = false;
        for (&secret_prefixes) |pattern| {
            if (pos + pattern.prefix.len + pattern.min_value_len <= line.len) {
                if (std.mem.startsWith(u8, line[pos..], pattern.prefix)) {
                    // Found prefix — find end of token (next whitespace, quote, or EOL)
                    const token_start = pos;
                    var token_end = pos + pattern.prefix.len;
                    while (token_end < line.len) {
                        const c = line[token_end];
                        if (c == ' ' or c == '\t' or c == '"' or c == '\'' or
                            c == ',' or c == ';' or c == ')' or c == '}')
                            break;
                        token_end += 1;
                    }
                    const token_len = token_end - token_start;
                    if (token_len >= pattern.prefix.len + pattern.min_value_len) {
                        try w.writeAll("[REDACTED]");
                        pos = token_end;
                        found_match = true;
                        break;
                    }
                }
            }
        }
        if (!found_match) {
            try w.writeByte(line[pos]);
            pos += 1;
        }
    }
}
