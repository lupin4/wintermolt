// Copyright The Fantastic Planet - By David Clabaugh
//
// tools.zig — Tool registry and dispatch for Wintermolt
//
// Maps tool names to handler functions. Each tool receives a JSON string
// of input parameters and returns a result string.
//
// Tool definitions (name, description, JSON Schema) are sent to Claude
// with each API request so it knows what tools are available.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const protocol = @import("../api/protocol.zig");

// Import tool implementations (core only — no forKernels, no proprietary)
const bash_tool = @import("../tools/bash.zig");
const file_tool = @import("../tools/file.zig");
const glob_tool = @import("../tools/glob.zig");
const grep_tool = @import("../tools/grep.zig");
const camera = @import("../tools/camera.zig");
const http_tool = @import("../tools/http.zig");
const search_tool = @import("../tools/search.zig");
const browser_tool = @import("../tools/browser.zig");
const image_io = @import("../tools/image_io.zig");
const skills_mod = @import("skills.zig");
const skill_loader = @import("skill_loader.zig");
const scheduler_mod = @import("scheduler.zig");
const sse = @import("../api/sse.zig");
const mcp_client = @import("../mcp/client.zig");
const rag_mod = @import("rag.zig");
const storage_mod = @import("storage.zig");
const tailscale_tool = @import("../tools/tailscale.zig");
const canvas_tool = @import("../tools/canvas.zig");
const tts_tool = @import("../tools/tts_tool.zig");
const image_gen = @import("../tools/image_gen.zig");
const subagent_mod = @import("subagent.zig");

/// Runtime skill registry pointer — set by AgentLoop during initialization.
var skill_registry_ptr: ?*skill_loader.SkillRegistry = null;

/// RAG pointer for memory_search tool dispatch (Pinecone deep recall).
var rag_ptr: ?*rag_mod.RagClient = null;

/// Storage pointer for memory_search tool dispatch (SQLite history).
var storage_ptr: ?*storage_mod.Storage = null;

/// MCP client manager pointer — routes prefixed tool calls to external MCP servers.
/// Set by main.zig after McpClientManager.loadFromConfig().
var mcp_manager: ?*mcp_client.McpClientManager = null;

pub fn setMcpManager(m: ?*mcp_client.McpClientManager) void {
    mcp_manager = m;
}

pub fn getMcpManager() ?*mcp_client.McpClientManager {
    return mcp_manager;
}

/// Scheduler pointer — set by AgentLoop or main.zig after scheduler init.
var scheduler_ptr: ?*scheduler_mod.Scheduler = null;

pub fn setScheduler(s: ?*scheduler_mod.Scheduler) void {
    scheduler_ptr = s;
}

pub fn getScheduler() ?*scheduler_mod.Scheduler {
    return scheduler_ptr;
}

pub fn setSkillRegistry(r: ?*skill_loader.SkillRegistry) void {
    skill_registry_ptr = r;
}

pub fn setRag(r: ?*rag_mod.RagClient) void {
    rag_ptr = r;
}

pub fn setStorage(s: ?*storage_mod.Storage) void {
    storage_ptr = s;
}

/// Subagent manager pointer — set by AgentLoop for spawn_agent tool.
var subagent_mgr: ?*subagent_mod.SubagentManager = null;
/// Current agent depth — set by AgentLoop to track subagent nesting.
var current_agent_depth: u8 = 0;

pub fn setSubagentManager(m: ?*subagent_mod.SubagentManager, depth: u8) void {
    subagent_mgr = m;
    current_agent_depth = depth;
}

// ---------------------------------------------------------------------------
// Tool policy (allowlist / blocklist)
// ---------------------------------------------------------------------------

var tool_allowlist_str: ?[]const u8 = null;
var tool_blocklist_str: ?[]const u8 = null;

pub fn setPolicy(allowlist: ?[]const u8, blocklist: ?[]const u8) void {
    tool_allowlist_str = allowlist;
    tool_blocklist_str = blocklist;
}

fn isToolPermitted(name: []const u8) bool {
    // Allowlist takes precedence: if set, ONLY listed tools are permitted
    if (tool_allowlist_str) |list| {
        var iter = std.mem.splitScalar(u8, list, ',');
        while (iter.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            if (std.mem.eql(u8, trimmed, name)) return true;
        }
        return false;
    }
    // Blocklist: these tools are blocked
    if (tool_blocklist_str) |list| {
        var iter = std.mem.splitScalar(u8, list, ',');
        while (iter.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            if (std.mem.eql(u8, trimmed, name)) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tool dispatch
// ---------------------------------------------------------------------------

/// Execute a tool by name. Returns the result string.
/// Falls through to MCP if no built-in tool matches.
pub fn executeTool(alloc: Allocator, name: []const u8, input_json: []const u8) ![]u8 {
    // Policy check
    if (!isToolPermitted(name)) {
        return std.fmt.allocPrint(alloc, "Tool '{s}' is not permitted by current policy.", .{name});
    }

    // Safety check for destructive tools
    if (std.mem.eql(u8, name, "bash")) {
        return executeBash(alloc, input_json);
    }

    // Core tool dispatch
    if (std.mem.eql(u8, name, "file_read")) return executeFileRead(alloc, input_json);
    if (std.mem.eql(u8, name, "file_write")) return executeFileWrite(alloc, input_json);
    if (std.mem.eql(u8, name, "file_edit")) return executeFileEdit(alloc, input_json);
    if (std.mem.eql(u8, name, "glob")) return executeGlob(alloc, input_json);
    if (std.mem.eql(u8, name, "grep")) return executeGrep(alloc, input_json);
    if (std.mem.eql(u8, name, "http_request")) return executeHttp(alloc, input_json);
    if (std.mem.eql(u8, name, "web_search")) return executeWebSearch(alloc, input_json);
    if (std.mem.eql(u8, name, "camera_capture")) return executeCamera(alloc, input_json);
    if (std.mem.eql(u8, name, "image_process")) return executeImageProcess(alloc, input_json);
    if (std.mem.eql(u8, name, "browser_control")) return executeBrowser(alloc, input_json);
    if (std.mem.eql(u8, name, "skills")) return executeSkills(alloc, input_json);
    if (std.mem.eql(u8, name, "memory_search")) return executeMemorySearch(alloc, input_json);
    if (std.mem.eql(u8, name, "schedule")) return executeSchedule(alloc, input_json);
    if (std.mem.eql(u8, name, "tailscale")) return tailscale_tool.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "canvas_update")) return canvas_tool.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "text_to_speech")) return tts_tool.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "image_generate")) return image_gen.executeTool(alloc, input_json);
    if (std.mem.eql(u8, name, "spawn_agent")) return executeSpawnAgent(alloc, input_json);

    // Runtime skill dispatch (plugins from ~/.wintermolt/skills/)
    if (skill_registry_ptr) |registry| {
        if (registry.findByName(name)) |skill| {
            if (registry.executeSkill(skill, input_json)) |result| {
                return result;
            } else |_| {}
        }
    }

    // MCP fallback: try connected MCP servers (e.g., "filesystem__read_file")
    if (mcp_manager) |mgr| {
        if (mgr.callTool(name, input_json)) |result| {
            return result;
        }
    }

    return std.fmt.allocPrint(alloc, "Unknown tool: '{s}'. Use the 'skills' tool to see available tools.", .{name});
}

// ---------------------------------------------------------------------------
// Tool definitions (sent to Claude API)
// ---------------------------------------------------------------------------

const core_tool_names = [_][]const u8{
    "bash", "file_read", "file_write", "file_edit", "glob", "grep", "http_request", "web_search", "skills",
};

fn isCoreTool(name: []const u8) bool {
    for (&core_tool_names) |core| {
        if (std.mem.eql(u8, name, core)) return true;
    }
    return false;
}

const ToolTrigger = struct {
    tool_name: []const u8,
    keywords: []const []const u8,
};

const extended_triggers = [_]ToolTrigger{
    .{ .tool_name = "image_process", .keywords = &.{ "image", "photo", "picture", "histogram", "sobel", "edge detect", "resize", "blur" } },
    .{ .tool_name = "camera_capture", .keywords = &.{ "camera", "capture", "webcam", "see me", "look at", "take a photo", "what can you see", "what do you see" } },
    .{ .tool_name = "browser_control", .keywords = &.{ "browser", "chrome", "tab", "webpage", "screenshot", "click", "navigate", "type text", "javascript", "cdp", "devtools", "web page", "open url", "scrape", "page content", "dom", "element" } },
    .{ .tool_name = "memory_search", .keywords = &.{ "remember", "recall", "past conversation", "last time", "earlier", "before", "did we", "we talked", "you said", "i told you", "history", "previous", "forgot", "forget", "memory", "do you know me", "what did", "discussed" } },
    .{ .tool_name = "schedule", .keywords = &.{ "schedule", "cron", "timer", "periodic", "every hour", "every day", "every minute", "remind me", "recurring", "automation", "job" } },
    .{ .tool_name = "tailscale", .keywords = &.{ "tailscale", "network", "mesh", "vpn", "devices", "peers", "tailnet", "wireguard" } },
    .{ .tool_name = "canvas_update", .keywords = &.{ "canvas", "ui", "dashboard", "chart", "form", "display", "render", "visualize", "widget", "layout" } },
    .{ .tool_name = "text_to_speech", .keywords = &.{ "speak", "say", "read aloud", "voice", "tts", "audio", "narrate", "pronounce", "speech", "synthesize" } },
    .{ .tool_name = "image_generate", .keywords = &.{ "generate image", "create image", "draw", "dall-e", "dalle", "picture of", "illustration", "artwork", "image of", "photo of", "render image" } },
    .{ .tool_name = "spawn_agent", .keywords = &.{ "subagent", "spawn", "delegate", "parallel", "subtask", "child agent", "in parallel", "concurrently", "split task" } },
};

/// Case-insensitive substring search.
fn containsKeyword(text: []const u8, keyword: []const u8) bool {
    if (keyword.len > text.len) return false;
    var i: usize = 0;
    while (i + keyword.len <= text.len) : (i += 1) {
        var match = true;
        for (0..keyword.len) |j| {
            const tc = text[i + j];
            const kc = keyword[j];
            const tl = if (tc >= 'A' and tc <= 'Z') tc + 32 else tc;
            const kl = if (kc >= 'A' and kc <= 'Z') kc + 32 else kc;
            if (tl != kl) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Module-level buffer for filtered tool definitions (safe: single-threaded).
/// Extra 32 slots for runtime skill tool definitions loaded from plugins.
var filtered_buf: [tool_definitions.len + 32]protocol.ToolDefinition = undefined;

/// Get all tool definitions.
pub fn getDefinitions() []const protocol.ToolDefinition {
    return &tool_definitions;
}

/// Get tool definitions relevant to the user's message.
/// Always includes core tools. Extended tools load by keyword match.
pub fn getRelevantDefinitions(user_text: []const u8) []const protocol.ToolDefinition {
    // Empty or very short text = send all (safety net for /commands etc.)
    if (user_text.len < 3) return &tool_definitions;

    var included: [tool_definitions.len]bool = [_]bool{false} ** tool_definitions.len;
    var count: usize = 0;

    // Always include core tools (subject to policy)
    for (&tool_definitions, 0..) |*td, idx| {
        if (isCoreTool(td.name) and isToolPermitted(td.name)) {
            filtered_buf[count] = td.*;
            included[idx] = true;
            count += 1;
        }
    }

    // Check extended tools by keyword matching against user text
    for (&extended_triggers) |*trigger| {
        var matched = false;
        for (trigger.keywords) |keyword| {
            if (containsKeyword(user_text, keyword)) {
                matched = true;
                break;
            }
        }
        if (matched) {
            for (&tool_definitions, 0..) |*td, idx| {
                if (!included[idx] and std.mem.eql(u8, td.name, trigger.tool_name) and isToolPermitted(td.name)) {
                    filtered_buf[count] = td.*;
                    included[idx] = true;
                    count += 1;
                    break;
                }
            }
        }
    }

    // Append runtime skill tool definitions (loaded from plugins)
    if (skill_registry_ptr) |registry| {
        const rt_defs = registry.getToolDefinitions();
        for (rt_defs) |rtd| {
            if (count >= filtered_buf.len) break;
            if (registry.hasKeywordMatch(user_text) or user_text.len < 3) {
                filtered_buf[count] = rtd;
                count += 1;
            }
        }
    }

    return filtered_buf[0..count];
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

fn executeBash(alloc: Allocator, input_json: []const u8) ![]u8 {
    const command = sse.findJsonString(input_json, "command") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'command' field", .{});

    // Simple pattern-matching safety check (no forTernary dependency)
    if (isBashBlocked(command)) {
        return std.fmt.allocPrint(alloc,
            "BLOCKED: Command refused by safety check.\nCommand: {s}",
            .{command});
    }

    return bash_tool.execute(alloc, command);
}

/// Check if a bash command should be blocked (destructive/dangerous patterns).
fn isBashBlocked(command: []const u8) bool {
    const blocked_patterns = [_][]const u8{
        "rm -rf /",  "rm -rf ~",  "dd if=",
        "mkfs",      "wipefs",    "shutdown",
        "reboot",    "halt",      "init 0",
        "init 6",    "git push --force",
        "git push -f", "git reset --hard",
        "git clean -f",
    };
    for (&blocked_patterns) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) return true;
    }
    return false;
}

fn executeFileRead(alloc: Allocator, input_json: []const u8) ![]u8 {
    const path = sse.findJsonString(input_json, "path") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' field", .{});

    const offset = if (sse.findJsonString(input_json, "offset")) |s|
        std.fmt.parseInt(usize, s, 10) catch null
    else
        null;

    const limit = if (sse.findJsonString(input_json, "limit")) |s|
        std.fmt.parseInt(usize, s, 10) catch null
    else
        null;

    return file_tool.readFile(alloc, path, offset, limit);
}

fn executeFileWrite(alloc: Allocator, input_json: []const u8) ![]u8 {
    const path = sse.findJsonString(input_json, "path") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' field", .{});
    const content = sse.findJsonString(input_json, "content") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'content' field", .{});
    return file_tool.writeFile(alloc, path, content);
}

fn executeFileEdit(alloc: Allocator, input_json: []const u8) ![]u8 {
    const path = sse.findJsonString(input_json, "path") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'path' field", .{});
    const old_string = sse.findJsonString(input_json, "old_string") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'old_string' field", .{});
    const new_string = sse.findJsonString(input_json, "new_string") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'new_string' field", .{});
    return file_tool.editFile(alloc, path, old_string, new_string);
}

fn executeGlob(alloc: Allocator, input_json: []const u8) ![]u8 {
    const pattern = sse.findJsonString(input_json, "pattern") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'pattern' field", .{});
    const path = sse.findJsonString(input_json, "path");
    return glob_tool.search(alloc, pattern, path);
}

fn executeGrep(alloc: Allocator, input_json: []const u8) ![]u8 {
    const pattern = sse.findJsonString(input_json, "pattern") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'pattern' field", .{});
    const path = sse.findJsonString(input_json, "path");

    const ci_str = sse.findJsonString(input_json, "case_insensitive");
    const case_insensitive = if (ci_str) |s| std.mem.eql(u8, s, "true") else false;

    return grep_tool.search(alloc, pattern, path, case_insensitive);
}

fn executeHttp(alloc: Allocator, input_json: []const u8) ![]u8 {
    return http_tool.executeTool(alloc, input_json);
}

fn executeWebSearch(alloc: Allocator, input_json: []const u8) ![]u8 {
    return search_tool.executeTool(alloc, input_json);
}

fn executeCamera(alloc: Allocator, input_json: []const u8) ![]u8 {
    return camera.executeTool(alloc, input_json);
}

fn executeImageProcess(alloc: Allocator, input_json: []const u8) ![]u8 {
    const operation = sse.findJsonString(input_json, "operation") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'operation' field", .{});
    const input_path = sse.findJsonString(input_json, "input_path") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'input_path' field", .{});
    const output_path = sse.findJsonString(input_json, "output_path") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'output_path' field", .{});

    // Basic image conversion: read from input format, write to output format
    if (std.mem.eql(u8, operation, "convert")) {
        var img = image_io.readImage(alloc, input_path) catch |e| {
            return std.fmt.allocPrint(alloc, "Error reading '{s}': {s}", .{ input_path, @errorName(e) });
        };
        defer img.deinit();
        image_io.writeImage(alloc, &img, output_path) catch |e| {
            return std.fmt.allocPrint(alloc, "Error writing '{s}': {s}", .{ output_path, @errorName(e) });
        };
        return std.fmt.allocPrint(alloc, "Converted {s} -> {s} ({d}x{d})", .{ input_path, output_path, img.width, img.height });
    }

    return std.fmt.allocPrint(alloc, "Unsupported image operation: {s}. Available: convert", .{operation});
}

fn executeBrowser(alloc: Allocator, input_json: []const u8) ![]u8 {
    return browser_tool.executeTool(alloc, input_json);
}

fn executeSkills(alloc: Allocator, input_json: []const u8) ![]u8 {
    const operation = sse.findJsonString(input_json, "operation") orelse "list";
    if (std.mem.eql(u8, operation, "detail")) {
        const name = sse.findJsonString(input_json, "name") orelse
            return std.fmt.allocPrint(alloc, "Error: 'detail' operation requires a 'name' field", .{});
        return skills_mod.getSkillDetail(alloc, name);
    }
    // Default: list all skills (comptime catalog + runtime plugins)
    var buf: ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    const comptime_list = try skills_mod.listSkills(alloc);
    defer alloc.free(comptime_list);
    try w.writeAll(comptime_list);

    // Runtime plugins
    if (skill_registry_ptr) |registry| {
        if (registry.skills.items.len > 0) {
            try w.writeAll("\n\n--- Runtime Plugins ---\n");
            for (registry.skills.items) |sk| {
                try w.print("  [{s}] {s} — {s}\n", .{ sk.category, sk.name, sk.description });
            }
        }
    }

    return try alloc.dupe(u8, buf.items);
}

fn executeMemorySearch(alloc: Allocator, input_json: []const u8) ![]u8 {
    const query = sse.findJsonString(input_json, "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query' field. Provide a search query.", .{});

    const top_k_str = sse.findJsonString(input_json, "top_k");
    const top_k: u32 = if (top_k_str) |s| std.fmt.parseInt(u32, s, 10) catch 5 else 5;
    const k = @min(top_k, 20);

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    // 1. SQLite conversation history: LIKE-based text search on messages
    if (storage_ptr) |s| {
        const history_results = s.searchMessages(query) catch null;
        if (history_results) |hits| {
            defer s.freeConversations(hits);
            if (hits.len > 0) {
                try w.print("## Conversation History ({d} matches)\n", .{hits.len});
                for (hits, 0..) |conv, idx| {
                    try w.print("{d}. \"{s}\" ({s}, {d} messages)\n", .{
                        idx + 1,
                        conv.title,
                        conv.mode,
                        conv.message_count,
                    });
                }
                try w.writeByte('\n');
            }
        }
    }

    // 2. Pinecone RAG: deep semantic search (if configured)
    if (rag_ptr) |rag| {
        if (rag.search(query, k) catch null) |hits| {
            defer rag.freeHits(hits);
            if (hits.len > 0) {
                if (rag.buildRagContext(hits) catch null) |ctx| {
                    defer alloc.free(ctx);
                    try w.print("## Deep Memory (Pinecone)\n{s}\n", .{ctx});
                }
            }
        }
    }

    if (buf.items.len == 0) {
        return std.fmt.allocPrint(alloc, "No memories found for query: \"{s}\"", .{query});
    }

    return buf.toOwnedSlice(alloc);
}

fn executeSpawnAgent(alloc: Allocator, input_json: []const u8) ![]u8 {
    const mgr = subagent_mgr orelse
        return alloc.dupe(u8, "Error: Subagent spawning not available. The subagent manager must be initialized.");

    const task = sse.findJsonString(input_json, "task") orelse
        return alloc.dupe(u8, "Error: 'task' field is required. Describe what the subagent should do.");

    const model = sse.findJsonString(input_json, "model");

    // spawnAndRun handles all errors internally and always returns a result string
    const result = mgr.spawnAndRun(current_agent_depth, null, task, model) catch
        return alloc.dupe(u8, "Error: Subagent spawn failed due to allocation error.");
    return result;
}

fn executeSchedule(alloc: Allocator, input_json: []const u8) ![]u8 {
    const sched = scheduler_ptr orelse
        return alloc.dupe(u8, "Scheduler not initialized. The scheduler requires SQLite and is enabled in REPL mode.");

    const action = sse.findJsonString(input_json, "action") orelse "list";

    if (std.mem.eql(u8, action, "add")) {
        const name = sse.findJsonString(input_json, "name") orelse
            return alloc.dupe(u8, "Error: 'add' requires a 'name' field.");
        const schedule_type = sse.findJsonString(input_json, "schedule_type") orelse
            return alloc.dupe(u8, "Error: 'add' requires 'schedule_type' (every, at, cron).");
        const schedule_value = sse.findJsonString(input_json, "schedule_value") orelse
            return alloc.dupe(u8, "Error: 'add' requires 'schedule_value' (e.g. '5m', '09:00', '*/5 * * * *').");
        const command = sse.findJsonString(input_json, "command") orelse
            return alloc.dupe(u8, "Error: 'add' requires a 'command' field (shell command to run).");

        const job_id = sched.addJob(name, schedule_type, schedule_value, command) catch |e| {
            return std.fmt.allocPrint(alloc, "Failed to add job: {s}", .{@errorName(e)});
        };
        defer alloc.free(job_id);
        return std.fmt.allocPrint(alloc, "Job added: [{s}] {s} ({s} {s})\nCommand: {s}", .{ job_id, name, schedule_type, schedule_value, command });
    } else if (std.mem.eql(u8, action, "remove")) {
        const job_id = sse.findJsonString(input_json, "job_id") orelse
            return alloc.dupe(u8, "Error: 'remove' requires a 'job_id' field.");
        sched.removeJob(job_id) catch |e| {
            return std.fmt.allocPrint(alloc, "Failed to remove job: {s}", .{@errorName(e)});
        };
        return std.fmt.allocPrint(alloc, "Job removed: {s}", .{job_id});
    } else if (std.mem.eql(u8, action, "list")) {
        return sched.listJobs(alloc);
    } else if (std.mem.eql(u8, action, "enable")) {
        const job_id = sse.findJsonString(input_json, "job_id") orelse
            return alloc.dupe(u8, "Error: 'enable' requires a 'job_id' field.");
        sched.enableJob(job_id, true) catch |e| {
            return std.fmt.allocPrint(alloc, "Failed to enable job: {s}", .{@errorName(e)});
        };
        return std.fmt.allocPrint(alloc, "Job enabled: {s}", .{job_id});
    } else if (std.mem.eql(u8, action, "disable")) {
        const job_id = sse.findJsonString(input_json, "job_id") orelse
            return alloc.dupe(u8, "Error: 'disable' requires a 'job_id' field.");
        sched.enableJob(job_id, false) catch |e| {
            return std.fmt.allocPrint(alloc, "Failed to disable job: {s}", .{@errorName(e)});
        };
        return std.fmt.allocPrint(alloc, "Job disabled: {s}", .{job_id});
    }

    return std.fmt.allocPrint(alloc, "Unknown schedule action: '{s}'. Available: add, remove, list, enable, disable", .{action});
}

// ---------------------------------------------------------------------------
// Tool definitions — core tools only
// ---------------------------------------------------------------------------

pub const tool_definitions = [_]protocol.ToolDefinition{
    .{
        .name = "bash",
        .description = "Run a shell command and return stdout/stderr. Use for git, system commands, running programs.",
        .input_schema_json =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}
        ,
    },
    .{
        .name = "file_read",
        .description = "Read a file's contents. Returns numbered lines. Use offset/limit for large files.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to read"},"offset":{"type":"integer","description":"Line number to start from (optional)"},"limit":{"type":"integer","description":"Max lines to read (optional)"}},"required":["path"]}
        ,
    },
    .{
        .name = "file_write",
        .description = "Create or overwrite a file with the given content.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to write"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "file_edit",
        .description = "Edit a file by finding old_string and replacing with new_string. The old_string must be unique in the file.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"old_string":{"type":"string","description":"Exact text to find (must be unique)"},"new_string":{"type":"string","description":"Replacement text"}},"required":["path","old_string","new_string"]}
        ,
    },
    .{
        .name = "glob",
        .description = "Find files matching a glob pattern. Supports *, **, ? wildcards.",
        .input_schema_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. '**/*.zig', 'src/*.ts')"},"path":{"type":"string","description":"Base directory to search in (optional, defaults to current dir)"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "grep",
        .description = "Search file contents for a pattern. Returns matching lines with file paths and line numbers.",
        .input_schema_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Text pattern to search for"},"path":{"type":"string","description":"File or directory to search (optional, defaults to current dir)"},"case_insensitive":{"type":"boolean","description":"Case-insensitive search (optional, default false)"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "http_request",
        .description = "Make an HTTP request to any URL. Supports GET, POST, PUT, DELETE, HEAD. Returns the response status, headers, and body. Response bodies are truncated to 30KB.",
        .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string","description":"URL to request (must include http:// or https://)"},"method":{"type":"string","enum":["GET","POST","PUT","DELETE","HEAD"],"description":"HTTP method (default: GET)"},"body":{"type":"string","description":"Request body (for POST/PUT)"},"headers":{"type":"object","description":"Custom headers as key-value pairs"}},"required":["url"]}
        ,
    },
    .{
        .name = "web_search",
        .description = "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for the top results. No API key needed.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"num_results":{"type":"integer","description":"Number of results to return (1-20, default 8)"}},"required":["query"]}
        ,
    },
    .{
        .name = "camera_capture",
        .description = "Capture an image from the system camera. Returns the image as a vision content block that you can see and describe. The captured image is also saved to /tmp/wintermolt_capture.jpg.",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["capture","list_devices"],"description":"Camera operation"},"device":{"type":"string","description":"Camera device name (optional)"}},"required":[]}
        ,
    },
    .{
        .name = "image_process",
        .description = "Image processing: read/write BMP images, convert formats via sips (macOS) or ffmpeg. Operations: histogram_equalize, sobel, resize.",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["histogram_equalize","sobel","resize"],"description":"Image processing operation"},"input_path":{"type":"string","description":"Path to input image"},"output_path":{"type":"string","description":"Path for output image"},"dst_width":{"type":"integer","description":"Target width (for resize)"},"dst_height":{"type":"integer","description":"Target height (for resize)"}},"required":["operation","input_path","output_path"]}
        ,
    },
    .{
        .name = "browser_control",
        .description = "Chrome browser automation via Chrome DevTools Protocol (CDP). Requires Chrome with --remote-debugging-port=9222.",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["list_tabs","new_tab","close_tab","navigate","snapshot","click","type_text","evaluate","screenshot"],"description":"Browser operation"},"url":{"type":"string","description":"URL for new_tab/navigate"},"tab_id":{"type":"string","description":"Tab ID for operations"},"selector":{"type":"string","description":"CSS selector for click/type_text"},"text":{"type":"string","description":"Text to type"},"expression":{"type":"string","description":"JavaScript to evaluate"}},"required":["operation"]}
        ,
    },
    .{
        .name = "memory_search",
        .description = "Search your memory: SQLite conversation history (text match) + Pinecone RAG (semantic similarity). Use to recall past conversations, facts the user shared, and previous interactions.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"What to search for in memory"},"top_k":{"type":"integer","description":"Max results to return (1-20, default 5)"}},"required":["query"]}
        ,
    },
    .{
        .name = "skills",
        .description = "Browse available tool capabilities. Use operation='list' for overview or operation='detail' with name='<tool>' for full docs.",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["list","detail"],"description":"List all skills or get detail for one"},"name":{"type":"string","description":"Skill name (for detail operation)"}},"required":[]}
        ,
    },
    .{
        .name = "schedule",
        .description = "Manage scheduled jobs (cron-like). Jobs persist in SQLite and execute shell commands on schedule. Use action='list' to see all jobs, 'add' to create, 'remove' to delete.",
        .input_schema_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["add","remove","list","enable","disable"],"description":"Schedule action"},"name":{"type":"string","description":"Job name (for add)"},"schedule_type":{"type":"string","enum":["every","at","cron"],"description":"Schedule type: every=interval, at=daily time, cron=cron expression"},"schedule_value":{"type":"string","description":"Schedule value: '5m','1h' for every; '09:00' for at; '*/5 * * * *' for cron"},"command":{"type":"string","description":"Shell command to execute"},"job_id":{"type":"string","description":"Job ID (for remove/enable/disable)"}},"required":["action"]}
        ,
    },
    .{
        .name = "tailscale",
        .description = "Tailscale mesh VPN tool. Check network status, list devices, ping peers. Requires Tailscale CLI installed for status/ping, or TAILSCALE_API_KEY for devices API.",
        .input_schema_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["status","devices","ping"],"description":"Tailscale action"},"target":{"type":"string","description":"Hostname or IP to ping (for ping action)"}},"required":["action"]}
        ,
    },
    .{
        .name = "canvas_update",
        .description = "Create or update an A2UI canvas surface for rich UI display. Renders components (text, buttons, code blocks, tables, headings, images) in the terminal or web UI. Use to show dashboards, forms, structured data, and interactive displays.",
        .input_schema_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"],"description":"Canvas action"},"surface_id":{"type":"string","description":"Surface ID (default: main)"},"title":{"type":"string","description":"Surface title"},"components":{"type":"array","description":"A2UI component tree","items":{"type":"object","properties":{"type":{"type":"string","description":"Component type: Text, Button, Code, Table, Image, Heading, Divider"},"value":{"type":"string","description":"Content value"},"label":{"type":"string","description":"Button label"},"language":{"type":"string","description":"Code language"},"alt":{"type":"string","description":"Image alt text"}}}},"data":{"type":"object","description":"Data model for dynamic binding"}},"required":["action"]}
        ,
    },
    .{
        .name = "image_generate",
        .description = "Generate an image using AI (DALL-E 3). Returns the path to the downloaded image file. Requires OPENAI_API_KEY.",
        .input_schema_json =
        \\{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed description of the image to generate"},"size":{"type":"string","enum":["1024x1024","1792x1024","1024x1792"],"description":"Image size (default: 1024x1024)"},"model":{"type":"string","description":"Model: dall-e-3 (default) or dall-e-2"},"quality":{"type":"string","enum":["standard","hd"],"description":"Quality: standard (default) or hd"}},"required":["prompt"]}
        ,
    },
    .{
        .name = "text_to_speech",
        .description = "Synthesize text to speech audio. Supports multiple providers: OpenAI TTS (cloud), ElevenLabs (cloud), Piper (local/offline), Edge TTS (Microsoft). Returns the path to the generated audio file. Use inline directives [[voice:alloy]] [[speed:1.2]] for per-utterance overrides.",
        .input_schema_json =
        \\{"type":"object","properties":{"text":{"type":"string","description":"The text to synthesize (max 4096 chars)"},"voice":{"type":"string","description":"Voice name (e.g. alloy, echo, nova for OpenAI; voice ID for ElevenLabs)"},"provider":{"type":"string","description":"TTS provider: openai, elevenlabs, piper, edge"},"play":{"type":"string","description":"Set to 'true' to play audio immediately via system speaker"}},"required":["text"]}
        ,
    },
    .{
        .name = "spawn_agent",
        .description = "Spawn a subagent to handle a subtask independently. The subagent gets its own conversation context, runs the task to completion, and returns the result. Use for parallelizable work, research tasks, or when you want isolated context. Max depth: 3 levels.",
        .input_schema_json =
        \\{"type":"object","properties":{"task":{"type":"string","description":"The task for the subagent to complete. Be specific and self-contained — the subagent has no access to the parent's conversation context."},"model":{"type":"string","description":"Optional AI backend override (claude, ollama, openai, deepseek, qwen, gemini)"}},"required":["task"]}
        ,
    },
};
