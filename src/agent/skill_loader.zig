// Copyright The Fantastic Planet - By David Clabaugh
//
// skill_loader.zig — Runtime skill/plugin loader
//
// Loads skill definitions from the filesystem at runtime, extending the
// comptime-only catalog in skills.zig. Skills are directories containing
// a skill.json manifest that defines the skill's metadata, keywords, and
// handler (bash command, MCP server, script, or prompt-only).
//
// Directory precedence (highest wins):
//   1. ./skills/           (workspace-local)
//   2. ~/.wintermolt/skills/ (user-global)
//   3. Built-in comptime catalog (skills.zig — always available)
//
// Handler types:
//   bash   — Execute a shell command, pass input via args
//   mcp    — Start an MCP server process, discover tools via JSON-RPC
//   script — Execute a script file (bash/python) in the skill directory
//   prompt — Description-only (injected into system prompt, no execution)

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");
const protocol = @import("../api/protocol.zig");
const bash_tool = @import("../tools/bash.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const HandlerType = enum {
    bash,
    mcp,
    script,
    prompt,
};

pub const RuntimeSkill = struct {
    name: []const u8,
    description: []const u8,
    category: []const u8,
    keywords: []const []const u8,
    handler_type: HandlerType,
    /// For bash: the command string. For script: relative path. For mcp: command.
    handler_command: []const u8,
    /// For mcp: args array serialized. For script: interpreter.
    handler_args: []const u8,
    /// JSON Schema for tool input (raw JSON string).
    tool_schema: []const u8,
    /// Absolute path to the skill directory.
    source_dir: []const u8,
    /// Whether user can invoke via /skillname.
    user_invokable: bool,
    /// Timeout for bash/script handlers (ms).
    timeout_ms: u32,
    /// Preferred backend for this skill's subagent ("ollama", "claude", "openai", etc.). Empty = inherit.
    backend: []const u8,
    /// Preferred model ID (e.g. "gemma2:2b", "nemo:12b", "claude-sonnet-4-20250514"). Empty = inherit.
    model: []const u8,
    /// Role/persona system prompt for agent-type skills. Empty = none.
    role_prompt: []const u8,
};

pub const SkillRegistry = struct {
    alloc: Allocator,
    skills: ArrayList(RuntimeSkill),
    /// Pre-built tool definitions for Claude API.
    tool_defs: ArrayList(protocol.ToolDefinition),

    pub fn init(alloc: Allocator) SkillRegistry {
        return .{
            .alloc = alloc,
            .skills = .{},
            .tool_defs = .{},
        };
    }

    /// Scan skill directories and load all valid skill.json manifests.
    pub fn loadFromDirectories(self: *SkillRegistry) void {
        // 1. User-global skills (~/.wintermolt/skills/)
        self.scanDirectory(getGlobalSkillsDir(self.alloc) orelse "") catch {};

        // 2. Workspace-local skills (./skills/)
        self.scanDirectory("skills") catch {};

        // 3. Plugin-provided skills (~/.wintermolt/plugins/*/skills/)
        self.loadFromPlugins() catch {};

        // Build tool definitions from loaded skills
        self.buildToolDefs() catch {};

        const stderr = std.fs.File.stderr().deprecatedWriter();
        if (self.skills.items.len > 0) {
            stderr.print("[skills] Loaded {d} runtime skill(s)\n", .{self.skills.items.len}) catch {};
        }
    }

    /// Load skills from installed plugins.
    /// Wintermolt scans ~/.wintermolt/plugins/ for skill directories.
    fn loadFromPlugins(self: *SkillRegistry) !void {
        // Scan default plugin directory
        var home_buf: [512]u8 = undefined;
        const home = compat.getenv("HOME") orelse return;
        const plugin_dir = std.fmt.bufPrint(&home_buf, "{s}/.wintermolt/plugins", .{home}) catch return;
        self.scanDirectory(plugin_dir) catch {};
    }

    fn scanDirectory(self: *SkillRegistry, dir_path: []const u8) !void {
        if (dir_path.len == 0) return;

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Check for skill.json in this subdirectory
            const manifest_path = std.fmt.allocPrint(self.alloc, "{s}/{s}/skill.json", .{ dir_path, entry.name }) catch continue;

            const manifest_data = blk: {
                const file = std.fs.cwd().openFile(manifest_path, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                if (stat.size > 64 * 1024) continue; // Skip manifests > 64KB
                break :blk file.readToEndAlloc(self.alloc, 64 * 1024) catch continue;
            };

            self.parseManifest(manifest_data, dir_path, entry.name) catch continue;
        }
    }

    fn parseManifest(self: *SkillRegistry, json: []const u8, base_dir: []const u8, skill_dir_name: []const u8) !void {
        const name = sse.findJsonString(json, "name") orelse return error.MissingName;
        const description = sse.findJsonString(json, "description") orelse "";
        const category = sse.findJsonString(json, "category") orelse "custom";

        // Check for duplicate (higher-precedence directory wins)
        for (self.skills.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.name, name)) {
                // Replace with this one (later directory = higher precedence)
                self.skills.items[i] = try self.buildSkill(json, name, description, category, base_dir, skill_dir_name);
                return;
            }
        }

        const skill = try self.buildSkill(json, name, description, category, base_dir, skill_dir_name);
        try self.skills.append(self.alloc, skill);
    }

    fn buildSkill(self: *SkillRegistry, json: []const u8, name: []const u8, description: []const u8, category: []const u8, base_dir: []const u8, skill_dir_name: []const u8) !RuntimeSkill {
        // Parse handler
        const handler_type_str = sse.findJsonString(json, "handler_type") orelse
            sse.findJsonString(json, "type") orelse "bash";
        const handler_type: HandlerType = if (std.mem.eql(u8, handler_type_str, "mcp"))
            .mcp
        else if (std.mem.eql(u8, handler_type_str, "script"))
            .script
        else if (std.mem.eql(u8, handler_type_str, "prompt"))
            .prompt
        else
            .bash;

        const handler_command = sse.findJsonString(json, "command") orelse "";
        const handler_args = sse.findJsonString(json, "args") orelse "";
        const tool_schema = sse.findJsonString(json, "tool_schema") orelse
            \\{"type":"object","properties":{"input":{"type":"string","description":"Input for the skill"}}}
        ;

        // Parse keywords into array
        var keywords: ArrayList([]const u8) = .{};
        // Simple keyword extraction: look for "keywords" array in JSON
        if (std.mem.indexOf(u8, json, "\"keywords\"")) |kw_start| {
            if (std.mem.indexOfPos(u8, json, kw_start, "[")) |arr_start| {
                if (std.mem.indexOfPos(u8, json, arr_start, "]")) |arr_end| {
                    var pos = arr_start + 1;
                    while (pos < arr_end) {
                        if (std.mem.indexOfPos(u8, json, pos, "\"")) |str_start| {
                            if (str_start >= arr_end) break;
                            if (std.mem.indexOfPos(u8, json, str_start + 1, "\"")) |str_end| {
                                if (str_end >= arr_end) break;
                                const kw = json[str_start + 1 .. str_end];
                                keywords.append(self.alloc, kw) catch {};
                                pos = str_end + 1;
                            } else break;
                        } else break;
                    }
                }
            }
        }

        // Check user_invokable
        const user_invokable = if (sse.findJsonString(json, "user_invokable")) |v|
            std.mem.eql(u8, v, "true")
        else
            true;

        // Parse timeout
        const timeout_ms: u32 = if (sse.findJsonString(json, "timeout_ms")) |t|
            std.fmt.parseInt(u32, t, 10) catch 30000
        else
            30000;

        const source_dir = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ base_dir, skill_dir_name });

        // Agent/model fields
        const backend = sse.findJsonString(json, "backend") orelse "";
        const model = sse.findJsonString(json, "model") orelse "";
        const role_prompt = sse.findJsonString(json, "role_prompt") orelse "";

        return RuntimeSkill{
            .name = try self.alloc.dupe(u8, name),
            .description = try self.alloc.dupe(u8, description),
            .category = try self.alloc.dupe(u8, category),
            .keywords = try keywords.toOwnedSlice(self.alloc),
            .handler_type = handler_type,
            .handler_command = try self.alloc.dupe(u8, handler_command),
            .handler_args = try self.alloc.dupe(u8, handler_args),
            .tool_schema = try self.alloc.dupe(u8, tool_schema),
            .source_dir = source_dir,
            .user_invokable = user_invokable,
            .timeout_ms = timeout_ms,
            .backend = try self.alloc.dupe(u8, backend),
            .model = try self.alloc.dupe(u8, model),
            .role_prompt = try self.alloc.dupe(u8, role_prompt),
        };
    }

    fn buildToolDefs(self: *SkillRegistry) !void {
        self.tool_defs.clearRetainingCapacity();

        for (self.skills.items) |skill| {
            if (skill.handler_type == .prompt) continue; // Prompt-only skills don't become tools

            const name_z = try self.alloc.dupeZ(u8, skill.name);
            const desc = try std.fmt.allocPrint(self.alloc,
                "[Plugin] {s}", .{skill.description});
            const desc_z = try self.alloc.dupeZ(u8, desc);
            const schema_z = try self.alloc.dupeZ(u8, skill.tool_schema);

            try self.tool_defs.append(self.alloc, .{
                .name = name_z,
                .description = desc_z,
                .input_schema_json = schema_z,
            });
        }
    }

    /// Find a skill by name.
    pub fn findByName(self: *SkillRegistry, name: []const u8) ?*RuntimeSkill {
        for (self.skills.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    /// Execute a skill's handler with the given JSON input.
    pub fn executeSkill(self: *SkillRegistry, skill: *RuntimeSkill, input_json: []const u8) ![]u8 {
        return switch (skill.handler_type) {
            .bash => self.executeBash(skill, input_json),
            .script => self.executeScript(skill, input_json),
            .mcp => self.executeMcp(skill, input_json),
            .prompt => std.fmt.allocPrint(self.alloc, "Skill '{s}' is prompt-only (no executable handler).", .{skill.name}),
        };
    }

    fn executeBash(self: *SkillRegistry, skill: *RuntimeSkill, input_json: []const u8) ![]u8 {
        // Extract input text from JSON
        const input = sse.findJsonString(input_json, "input") orelse
            sse.findJsonString(input_json, "command") orelse "";

        // Build command: skill command + input
        const command = if (input.len > 0)
            try std.fmt.allocPrint(self.alloc, "cd {s} && {s} {s}", .{ skill.source_dir, skill.handler_command, input })
        else
            try std.fmt.allocPrint(self.alloc, "cd {s} && {s}", .{ skill.source_dir, skill.handler_command });

        return bash_tool.execute(self.alloc, command);
    }

    fn executeScript(self: *SkillRegistry, skill: *RuntimeSkill, input_json: []const u8) ![]u8 {
        const input = sse.findJsonString(input_json, "input") orelse "";
        const interpreter = if (skill.handler_args.len > 0) skill.handler_args else "bash";

        const command = try std.fmt.allocPrint(self.alloc,
            "cd {s} && {s} {s} {s}", .{ skill.source_dir, interpreter, skill.handler_command, input });

        return bash_tool.execute(self.alloc, command);
    }

    fn executeMcp(self: *SkillRegistry, skill: *RuntimeSkill, input_json: []const u8) ![]u8 {
        _ = input_json;
        // MCP skills are handled by the MCP client manager — they register as MCP servers
        // and their tools are discovered via JSON-RPC. This is a fallback for direct calls.
        return std.fmt.allocPrint(self.alloc,
            "Skill '{s}' is an MCP server. Its tools are auto-discovered and available with the prefix '{s}__'.", .{ skill.name, skill.name });
    }

    /// Get tool definitions for runtime skills (appended to builtin definitions).
    pub fn getToolDefinitions(self: *SkillRegistry) []const protocol.ToolDefinition {
        return self.tool_defs.items;
    }

    /// Get prompt addenda from prompt-type skills (injected into system prompt).
    pub fn getPromptAddenda(self: *SkillRegistry, alloc: Allocator) !?[]u8 {
        var buf: ArrayList(u8) = .{};
        defer buf.deinit(alloc);

        var count: usize = 0;
        for (self.skills.items) |skill| {
            if (skill.handler_type != .prompt) continue;
            const w = buf.writer(alloc);
            try w.print("\n## Skill: {s}\n{s}\n", .{ skill.name, skill.description });
            count += 1;
        }

        if (count == 0) return null;
        return try alloc.dupe(u8, buf.items);
    }

    /// Check if any runtime skill keyword matches user text.
    pub fn hasKeywordMatch(self: *SkillRegistry, user_text: []const u8) bool {
        for (self.skills.items) |skill| {
            for (skill.keywords) |kw| {
                if (containsKeywordCI(user_text, kw)) return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *SkillRegistry) void {
        // Skill data is arena-allocated — no individual frees needed
        self.skills.deinit(self.alloc);
        self.tool_defs.deinit(self.alloc);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getGlobalSkillsDir(alloc: Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.wintermolt/skills", .{home}) catch null;
}

fn containsKeywordCI(text: []const u8, keyword: []const u8) bool {
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
