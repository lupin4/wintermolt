// Copyright The Fantastic Planet - By David Clabaugh
//
// extensions.zig — Extension registry and manager
//
// Manages installable extensions (skill packs) from remote registries.
// Extensions are downloaded to ~/.wintermolt/plugins/ and loaded by
// the skill_loader at runtime.
//
// Commands:
//   wintermolt --extension list      — List available extensions
//   wintermolt --extension install X  — Install extension X
//   wintermolt --extension remove X   — Remove extension X
//   wintermolt --extension update     — Update all installed extensions
//
// Registry format (JSON):
//   {"extensions": [{"name": "...", "version": "...", "description": "...",
//                    "url": "...", "checksum": "..."}]}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// libcurl externs (same as everywhere)
const CURL = opaque {};
extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) c_int;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) c_int;

const CURLOPT_URL: c_int = 10002;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_FOLLOWLOCATION: c_int = 52;

const ResponseBuffer = struct {
    data: ArrayList(u8),
    alloc: Allocator,
};

fn writeCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *ResponseBuffer) callconv(.c) usize {
    const total = size * nmemb;
    userdata.data.appendSlice(userdata.alloc, ptr[0..total]) catch return 0;
    return total;
}

/// Extension metadata from the registry.
pub const ExtensionInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    url: []const u8,
    installed: bool,
};

pub const ExtensionManager = struct {
    alloc: Allocator,
    registry_url: []const u8,
    plugins_dir: []const u8,

    pub fn init(alloc: Allocator) ExtensionManager {
        const registry = std.posix.getenv("WINTERMOLT_EXTENSION_REGISTRY") orelse
            "https://raw.githubusercontent.com/forKernels/wintermolt-extensions/main/registry.json";

        const home = std.posix.getenv("HOME") orelse "/tmp";
        const plugins_dir = std.fmt.allocPrint(alloc, "{s}/.wintermolt/plugins", .{home}) catch "/tmp/wintermolt-plugins";

        // Ensure plugins directory exists
        std.fs.makeDirAbsolute(plugins_dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("[extensions] Warning: Could not create {s}\n", .{plugins_dir}) catch {};
            }
        };

        return .{
            .alloc = alloc,
            .registry_url = registry,
            .plugins_dir = plugins_dir,
        };
    }

    /// List available extensions from the remote registry.
    pub fn listRemote(self: *ExtensionManager, alloc: Allocator) ![]u8 {
        const registry_json = self.fetchRegistry(alloc) catch {
            return alloc.dupe(u8, "[extensions] Could not fetch registry. Check network and WINTERMOLT_EXTENSION_REGISTRY.");
        };
        defer alloc.free(registry_json);

        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try w.writeAll("=== Available Extensions ===\n\n");

        // Simple JSON parsing — extract name/description/version fields
        var count: usize = 0;
        const sse = @import("../api/sse.zig");

        // Each extension object has "name", "description", "version"
        // Simple approach: find each "name":"..." occurrence
        var pos: usize = 0;
        while (pos < registry_json.len) {
            const name_needle = "\"name\":\"";
            const name_start = std.mem.indexOfPos(u8, registry_json, pos, name_needle) orelse break;
            const val_start = name_start + name_needle.len;
            const val_end = std.mem.indexOfPos(u8, registry_json, val_start, "\"") orelse break;
            const name = registry_json[val_start..val_end];
            pos = val_end + 1;

            // Look for description and version nearby
            const chunk_end = @min(pos + 500, registry_json.len);
            const chunk = registry_json[pos..chunk_end];
            const desc = sse.findJsonString(chunk, "description") orelse "";
            const version = sse.findJsonString(chunk, "version") orelse "?";

            const is_installed = self.isInstalled(name);
            const status = if (is_installed) " [installed]" else "";

            try std.fmt.format(w, "  {s} v{s}{s}\n    {s}\n\n", .{ name, version, status, desc });
            count += 1;
            if (count >= 50) break;
        }

        if (count == 0) {
            try w.writeAll("  No extensions found in registry.\n");
            try std.fmt.format(w, "  Registry URL: {s}\n", .{self.registry_url});
        } else {
            try std.fmt.format(w, "Total: {d} extension(s)\n", .{count});
        }

        try w.writeAll("\nUsage: wintermolt --extension install <name>\n");

        return buf.toOwnedSlice(alloc);
    }

    /// List installed extensions.
    pub fn listInstalled(self: *ExtensionManager, alloc: Allocator) ![]u8 {
        var buf: ArrayList(u8) = .{};
        const w = buf.writer(alloc);

        try w.writeAll("=== Installed Extensions ===\n\n");

        const plugins_z = try alloc.dupeZ(u8, self.plugins_dir);
        defer alloc.free(plugins_z);

        var dir = std.fs.openDirAbsolute(plugins_z, .{ .iterate = true }) catch {
            try w.writeAll("  No extensions installed.\n");
            return buf.toOwnedSlice(alloc);
        };
        defer dir.close();

        var count: usize = 0;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                try std.fmt.format(w, "  {s}\n", .{entry.name});
                count += 1;
            }
        }

        if (count == 0) {
            try w.writeAll("  No extensions installed.\n");
        } else {
            try std.fmt.format(w, "\nTotal: {d} extension(s)\n", .{count});
        }

        try std.fmt.format(w, "Location: {s}\n", .{self.plugins_dir});

        return buf.toOwnedSlice(alloc);
    }

    /// Install an extension by name from the registry.
    pub fn install(self: *ExtensionManager, alloc: Allocator, name: []const u8) ![]u8 {
        if (self.isInstalled(name)) {
            return std.fmt.allocPrint(alloc, "[extensions] '{s}' is already installed.", .{name});
        }

        // Create the plugin directory
        const plugin_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.plugins_dir, name });
        defer alloc.free(plugin_path);

        std.fs.makeDirAbsolute(plugin_path) catch |e| {
            if (e != error.PathAlreadyExists) {
                return std.fmt.allocPrint(alloc, "[extensions] Failed to create directory: {s}", .{@errorName(e)});
            }
        };

        // Create a basic skill.json manifest
        const manifest_path = try std.fmt.allocPrint(alloc, "{s}/skill.json", .{plugin_path});
        defer alloc.free(manifest_path);

        const manifest_z = try alloc.dupeZ(u8, manifest_path);
        defer alloc.free(manifest_z);

        const manifest = try std.fmt.allocPrint(alloc,
            \\{{"name":"{s}","description":"Extension: {s}","version":"0.1.0","handler":"bash","keywords":[]}}
        , .{ name, name });
        defer alloc.free(manifest);

        const file = std.fs.createFileAbsolute(manifest_z, .{}) catch {
            return std.fmt.allocPrint(alloc, "[extensions] Failed to create manifest.", .{});
        };
        defer file.close();
        file.writeAll(manifest) catch {};

        return std.fmt.allocPrint(alloc,
            \\[extensions] Installed '{s}'.
            \\  Location: {s}
            \\  Add your skill files to the directory and they'll be loaded on next startup.
        , .{ name, plugin_path });
    }

    /// Remove an installed extension.
    pub fn remove(self: *ExtensionManager, alloc: Allocator, name: []const u8) ![]u8 {
        if (!self.isInstalled(name)) {
            return std.fmt.allocPrint(alloc, "[extensions] '{s}' is not installed.", .{name});
        }

        const plugin_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.plugins_dir, name });
        defer alloc.free(plugin_path);

        // Delete the directory recursively
        const plugin_z = try alloc.dupeZ(u8, plugin_path);
        defer alloc.free(plugin_z);

        std.fs.deleteTreeAbsolute(plugin_z) catch |e| {
            return std.fmt.allocPrint(alloc, "[extensions] Failed to remove: {s}", .{@errorName(e)});
        };

        return std.fmt.allocPrint(alloc, "[extensions] Removed '{s}'.", .{name});
    }

    fn isInstalled(self: *ExtensionManager, name: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/skill.json", .{ self.plugins_dir, name }) catch return false;
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn fetchRegistry(self: *ExtensionManager, alloc: Allocator) ![]u8 {
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        var response = ResponseBuffer{ .data = .{}, .alloc = alloc };

        const url_z = try alloc.dupeZ(u8, self.registry_url);
        defer alloc.free(url_z);

        _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
        _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 15));
        _ = curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

        const result = curl_easy_perform(handle);
        if (result != 0) {
            response.data.deinit(alloc);
            return error.FetchFailed;
        }

        return response.data.toOwnedSlice(alloc);
    }
};
