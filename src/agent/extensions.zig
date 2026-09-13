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
const compat = @import("../compat.zig");
const stdio = @import("../stdio.zig");

/// The blocking Io this file's filesystem calls need.
///
/// 0.16 moved the filesystem into std.Io and every operation now takes an Io.
/// None of the calls here allocate -- mkdir, create, access, deleteTree, close --
/// so the single-threaded instance is sufficient and nothing has to be threaded
/// in from main. Named once here rather than repeated at each call site.
fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
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
        const registry = compat.getenv("WINTERMOLT_EXTENSION_REGISTRY") orelse
            "https://raw.githubusercontent.com/forKernels/wintermolt-extensions/main/registry.json";

        const home = compat.getenv("HOME") orelse "/tmp";
        const plugins_dir = std.fmt.allocPrint(alloc, "{s}/.wintermolt/plugins", .{home}) catch "/tmp/wintermolt-plugins";

        // Ensure plugins directory exists.
        //
        // std.fs.makeDirAbsolute is gone; Io.Dir.createDirAbsolute replaces it on
        // both 0.16 and 0.17. .default_dir is 0o777-before-umask, matching what
        // makeDirAbsolute used. mkdir does not allocate, so the single-threaded
        // Io is sufficient here and needs nothing threaded in from main.
        std.Io.Dir.createDirAbsolute(fsIo(), plugins_dir, .default_dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                const stderr = stdio.stderr();
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

        // ArrayList.writer(gpa) is gone on 0.16 AND 0.17. Writer.Allocating owns
        // the buffer and hands out a real Writer, so the writeAll/print call
        // sites below are unchanged. Present on both toolchains.
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        const w = &aw.writer;

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

            try w.print("  {s} v{s}{s}\n    {s}\n\n", .{ name, version, status, desc });
            count += 1;
            if (count >= 50) break;
        }

        if (count == 0) {
            try w.writeAll("  No extensions found in registry.\n");
            try w.print("  Registry URL: {s}\n", .{self.registry_url});
        } else {
            try w.print("Total: {d} extension(s)\n", .{count});
        }

        try w.writeAll("\nUsage: wintermolt --extension install <name>\n");

        return aw.toOwnedSlice();
    }

    /// List installed extensions.
    pub fn listInstalled(self: *ExtensionManager, alloc: Allocator) ![]u8 {
        // ArrayList.writer(gpa) is gone on 0.16 AND 0.17. Writer.Allocating owns
        // the buffer and hands out a real Writer, so the writeAll/print call
        // sites below are unchanged. Present on both toolchains.
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("=== Installed Extensions ===\n\n");

        // std.fs.openDirAbsolute is gone; Io.Dir.openDirAbsolute replaces it and
        // takes a SLICE, so the NUL-terminated dupeZ it used to need is gone too.
        // close/next take the Io as well. Directory iteration does not allocate,
        // so the single-threaded Io suffices and nothing threads in from main.
        var dir = std.Io.Dir.openDirAbsolute(fsIo(), self.plugins_dir, .{ .iterate = true }) catch {
            try w.writeAll("  No extensions installed.\n");
            return aw.toOwnedSlice();
        };
        defer dir.close(fsIo());

        var count: usize = 0;
        var iter = dir.iterate();
        while (iter.next(fsIo()) catch null) |entry| {
            if (entry.kind == .directory) {
                try w.print("  {s}\n", .{entry.name});
                count += 1;
            }
        }

        if (count == 0) {
            try w.writeAll("  No extensions installed.\n");
        } else {
            try w.print("\nTotal: {d} extension(s)\n", .{count});
        }

        try w.print("Location: {s}\n", .{self.plugins_dir});

        return aw.toOwnedSlice();
    }

    /// Install an extension by name from the registry.
    pub fn install(self: *ExtensionManager, alloc: Allocator, name: []const u8) ![]u8 {
        if (self.isInstalled(name)) {
            return std.fmt.allocPrint(alloc, "[extensions] '{s}' is already installed.", .{name});
        }

        // Create the plugin directory
        const plugin_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.plugins_dir, name });
        defer alloc.free(plugin_path);

        std.Io.Dir.createDirAbsolute(fsIo(), plugin_path, .default_dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                return std.fmt.allocPrint(alloc, "[extensions] Failed to create directory: {s}", .{@errorName(e)});
            }
        };

        // Create a basic skill.json manifest
        const manifest_path = try std.fmt.allocPrint(alloc, "{s}/skill.json", .{plugin_path});
        defer alloc.free(manifest_path);

        const manifest = try std.fmt.allocPrint(alloc,
            \\{{"name":"{s}","description":"Extension: {s}","version":"0.1.0","handler":"bash","keywords":[]}}
        , .{ name, name });
        defer alloc.free(manifest);

        const file = std.Io.Dir.createFileAbsolute(fsIo(), manifest_path, .{}) catch {
            return std.fmt.allocPrint(alloc, "[extensions] Failed to create manifest.", .{});
        };
        defer file.close(fsIo());
        file.writeStreamingAll(fsIo(), manifest) catch {};

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

        // Delete the directory recursively. deleteTree is a Dir METHOD in 0.16 and
        // takes a slice, so the NUL-terminated copy is no longer needed.
        std.Io.Dir.cwd().deleteTree(fsIo(), plugin_path) catch |e| {
            return std.fmt.allocPrint(alloc, "[extensions] Failed to remove: {s}", .{@errorName(e)});
        };

        return std.fmt.allocPrint(alloc, "[extensions] Removed '{s}'.", .{name});
    }

    fn isInstalled(self: *ExtensionManager, name: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/skill.json", .{ self.plugins_dir, name }) catch return false;
        std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
        return true;
    }

    fn fetchRegistry(self: *ExtensionManager, alloc: Allocator) ![]u8 {
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        // ArrayList lost its `.{}` zero value; `.empty` is the named one.
        var response = ResponseBuffer{ .data = .empty, .alloc = alloc };

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
