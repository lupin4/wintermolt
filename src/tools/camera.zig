// Copyright The Fantastic Planet - By David Clabaugh
//
// camera.zig — Camera capture tool
//
// Captures images from the system camera using platform-appropriate tools:
//   - macOS: imagesnap (brew install imagesnap)
//   - Linux: ffmpeg -f v4l2
//   - Luxonis OAK-D: via depthai Python script (oakd, oakd-depth, oakd-rgbd)
//
// Returns base64-encoded JPEG data for inclusion as Claude Vision content blocks.

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const base64 = std.base64.standard;

pub const CaptureResult = struct {
    data: []u8, // base64-encoded image data (caller owns)
    media_type: []const u8, // "image/jpeg"
};

/// Magic prefix for image results passed through the tool dispatch system.
/// The agentic loop detects this to construct image content blocks.
pub const IMAGE_RESULT_PREFIX = "__IMAGE_BASE64:";

/// Capture a frame from the default camera and return base64-encoded JPEG.
/// Supports Luxonis OAK-D via device names: "oakd", "oakd-depth", "oakd-rgbd"
pub fn capture(alloc: Allocator, device: ?[]const u8) !CaptureResult {
    const tmp_path = "/tmp/wintermolt_capture.jpg";

    // Check for OAK-D / Luxonis DepthAI device specifier
    if (device) |d| {
        if (std.mem.startsWith(u8, d, "oakd")) {
            try captureOakd(alloc, tmp_path, d);
            return readAndEncode(alloc, tmp_path);
        }
    }

    // Determine platform capture command
    const is_macos = @import("builtin").os.tag == .macos;

    if (is_macos) {
        captureImagesnap(alloc, tmp_path, device) catch {
            // imagesnap failed — try OAK-D as fallback (non-UVC cameras)
            captureOakd(alloc, tmp_path, "oakd") catch {
                return error.CaptureCommandFailed;
            };
        };
    } else {
        captureFfmpeg(alloc, tmp_path, device) catch {
            // v4l2 failed — try OAK-D as fallback
            captureOakd(alloc, tmp_path, "oakd") catch {
                return error.CaptureCommandFailed;
            };
        };
    }

    return readAndEncode(alloc, tmp_path);
}

/// Read a captured image file and return base64-encoded result.
fn readAndEncode(alloc: Allocator, tmp_path: []const u8) !CaptureResult {
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;
    if (file_size == 0 or file_size > 10 * 1024 * 1024) {
        return error.InvalidCaptureSize;
    }

    const image_bytes = try alloc.alloc(u8, @intCast(file_size));
    defer alloc.free(image_bytes);

    const bytes_read = try file.readAll(image_bytes);
    if (bytes_read == 0) return error.EmptyCapture;

    // Base64 encode
    const encoded_size = base64.Encoder.calcSize(bytes_read);
    const encoded = try alloc.alloc(u8, encoded_size);
    _ = base64.Encoder.encode(encoded, image_bytes[0..bytes_read]);

    return .{
        .data = encoded,
        .media_type = "image/jpeg",
    };
}

/// Capture using Luxonis OAK-D via depthai Python script.
/// Device names: "oakd" (RGB), "oakd-depth" (depth colormap), "oakd-rgbd" (side-by-side)
fn captureOakd(alloc: Allocator, output_path: []const u8, device: []const u8) !void {
    // Determine capture mode from device name
    const mode: []const u8 = if (std.mem.eql(u8, device, "oakd-depth"))
        "--depth"
    else if (std.mem.eql(u8, device, "oakd-rgbd"))
        "--rgbd"
    else
        "--rgb";

    // Find the Python script — look relative to the binary, then fallback paths
    const script_paths = [_][]const u8{
        "scripts/oakd_capture.py",
        "./oakd_capture.py",
    };

    var script_path: []const u8 = script_paths[0]; // default
    for (script_paths) |sp| {
        std.fs.cwd().access(sp, .{}) catch continue;
        script_path = sp;
        break;
    }

    // Find Python with depthai installed
    const python_paths = [_][]const u8{
        "python3",
        "python",
    };

    var python_path: []const u8 = python_paths[0]; // default
    for (python_paths) |pp| {
        // Check if the binary exists on PATH by trying to spawn
        std.fs.cwd().access(pp, .{}) catch continue;
        python_path = pp;
        break;
    }

    var child = Child.init(&[_][]const u8{
        python_path,
        script_path,
        output_path,
        mode,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("[oakd] capture failed: {s}\n", .{stderr_list.items}) catch {};
                return error.CaptureCommandFailed;
            }
        },
        else => return error.CaptureCommandFailed,
    }
}

/// Capture using imagesnap on macOS.
fn captureImagesnap(alloc: Allocator, output_path: []const u8, device: ?[]const u8) !void {
    // Build args: imagesnap [-d device] -w 0.5 <output>
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "imagesnap";
    argc += 1;

    if (device) |d| {
        argv_buf[argc] = "-d";
        argc += 1;
        argv_buf[argc] = d;
        argc += 1;
    }

    argv_buf[argc] = "-w";
    argc += 1;
    argv_buf[argc] = "0.5";
    argc += 1;
    argv_buf[argc] = output_path;
    argc += 1;

    var child = Child.init(argv_buf[0..argc], alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CaptureCommandFailed;
        },
        else => return error.CaptureCommandFailed,
    }
}

/// Capture using ffmpeg on Linux (v4l2 device).
fn captureFfmpeg(alloc: Allocator, output_path: []const u8, device: ?[]const u8) !void {
    const dev = device orelse "/dev/video0";

    var child = Child.init(&[_][]const u8{
        "ffmpeg",    "-y",
        "-f",        "v4l2",
        "-i",        dev,
        "-frames:v", "1",
        "-q:v",      "2", // JPEG quality
        output_path,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CaptureCommandFailed;
        },
        else => return error.CaptureCommandFailed,
    }
}

/// List available camera devices. Returns human-readable string.
pub fn listDevices(alloc: Allocator) ![]u8 {
    const is_macos = @import("builtin").os.tag == .macos;

    if (is_macos) {
        // imagesnap -l lists available devices
        var child = Child.init(&[_][]const u8{ "imagesnap", "-l" }, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout_list: ArrayList(u8) = .{};
        defer stdout_list.deinit(alloc);
        var stderr_list: ArrayList(u8) = .{};
        defer stderr_list.deinit(alloc);

        child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    return std.fmt.allocPrint(alloc, "imagesnap not found. Install with: brew install imagesnap", .{});
                }
            },
            else => {
                return std.fmt.allocPrint(alloc, "Failed to list devices", .{});
            },
        }

        // imagesnap -l prints to stderr on some versions
        if (stderr_list.items.len > stdout_list.items.len) {
            return alloc.dupe(u8, stderr_list.items);
        }
        return alloc.dupe(u8, stdout_list.items);
    } else {
        // Linux: list v4l2 devices
        var child = Child.init(&[_][]const u8{ "v4l2-ctl", "--list-devices" }, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout_list: ArrayList(u8) = .{};
        defer stdout_list.deinit(alloc);
        var stderr_list: ArrayList(u8) = .{};
        defer stderr_list.deinit(alloc);

        child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

        _ = try child.wait();

        if (stdout_list.items.len > 0) {
            return alloc.dupe(u8, stdout_list.items);
        }
        return std.fmt.allocPrint(alloc, "No video devices found (install v4l-utils for device listing)", .{});
    }
}

/// Capture a screenshot and return base64-encoded PNG.
/// macOS: screencapture (built-in), Linux: scrot or gnome-screenshot.
pub fn captureScreenshot(alloc: Allocator) !CaptureResult {
    const tmp_path = "/tmp/wintermolt_screenshot.png";
    const is_macos = @import("builtin").os.tag == .macos;

    if (is_macos) {
        var child = Child.init(&[_][]const u8{ "screencapture", "-x", tmp_path }, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var stdout_list: ArrayList(u8) = .{};
        defer stdout_list.deinit(alloc);
        var stderr_list: ArrayList(u8) = .{};
        defer stderr_list.deinit(alloc);
        child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.ScreenshotFailed;
            },
            else => return error.ScreenshotFailed,
        }
    } else {
        // Linux: try scrot first, then gnome-screenshot
        var child = Child.init(&[_][]const u8{ "scrot", tmp_path }, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var stdout_list: ArrayList(u8) = .{};
        defer stdout_list.deinit(alloc);
        var stderr_list: ArrayList(u8) = .{};
        defer stderr_list.deinit(alloc);
        child.collectOutput(alloc, &stdout_list, &stderr_list, 4096) catch {};

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.ScreenshotFailed;
            },
            else => return error.ScreenshotFailed,
        }
    }

    // Read the screenshot file
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;
    if (file_size == 0 or file_size > 20 * 1024 * 1024) {
        return error.InvalidCaptureSize;
    }

    const image_bytes = try alloc.alloc(u8, @intCast(file_size));
    defer alloc.free(image_bytes);

    const bytes_read = try file.readAll(image_bytes);
    if (bytes_read == 0) return error.EmptyCapture;

    // Base64 encode
    const encoded_size = base64.Encoder.calcSize(bytes_read);
    const encoded = try alloc.alloc(u8, encoded_size);
    _ = base64.Encoder.encode(encoded, image_bytes[0..bytes_read]);

    // Temp file persists at /tmp/wintermolt_screenshot.png for chaining to image_process

    return .{
        .data = encoded,
        .media_type = "image/png",
    };
}

/// Execute camera tool from JSON input. Returns tool result string.
/// For capture operations, returns magic-prefixed base64 data that the
/// agentic loop converts into image content blocks.
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const sse = @import("../api/sse.zig");
    const operation = sse.findJsonString(input_json, "operation") orelse "capture";
    const device = sse.findJsonString(input_json, "device");

    if (std.mem.eql(u8, operation, "list_devices")) {
        return listDevices(alloc);
    }

    if (std.mem.eql(u8, operation, "capture")) {
        const result = capture(alloc, device) catch |e| {
            return std.fmt.allocPrint(alloc, "Camera capture failed: {s}. Devices: default (imagesnap/ffmpeg), 'oakd' (OAK-D RGB), 'oakd-depth' (depth map), 'oakd-rgbd' (RGB+depth).", .{@errorName(e)});
        };
        defer alloc.free(result.data);

        // Return with magic prefix so the agentic loop can construct image content blocks
        return std.fmt.allocPrint(alloc, "{s}{s}:{s}", .{ IMAGE_RESULT_PREFIX, result.media_type, result.data });
    }

    if (std.mem.eql(u8, operation, "object_detect")) {
        return objectDetect(alloc, input_json, device);
    }

    return std.fmt.allocPrint(alloc, "Unknown camera operation: '{s}'. Use 'capture', 'object_detect', or 'list_devices'.", .{operation});
}

/// Object detection via camera + Ollama LLaVA.
/// Captures a frame, sends to local LLaVA model with a structured detection prompt,
/// returns parsed object list with approximate bounding boxes.
fn objectDetect(alloc: Allocator, input_json: []const u8, device: ?[]const u8) ![]u8 {
    const sse = @import("../api/sse.zig");

    // Optional custom prompt
    const custom_prompt = sse.findJsonString(input_json, "prompt");

    // Step 1: Capture frame
    const result = capture(alloc, device) catch |e| {
        return std.fmt.allocPrint(alloc, "Object detect: camera capture failed: {s}", .{@errorName(e)});
    };
    defer alloc.free(result.data);

    // Step 2: Get Ollama config from environment
    const ollama_url = compat.getenv("WINTERMOLT_OLLAMA_URL") orelse "http://localhost:11434";
    const vision_model = compat.getenv("WINTERMOLT_VISION_MODEL") orelse "llava";

    // Step 3: Build the detection prompt
    const detect_prompt = custom_prompt orelse
        "Analyze this image and list every visible object. For each object provide:\n" ++
        "- name: object type (e.g. 'person', 'chair', 'laptop')\n" ++
        "- bbox: approximate bounding box as [x%, y%, width%, height%] percentage of image\n" ++
        "- confidence: your confidence (high/medium/low)\n" ++
        "Format as a numbered list. Be specific and thorough.";

    // Step 4: Build JSON request for Ollama /api/generate with image
    // We use the simpler /api/generate endpoint which accepts images array directly
    const request_body = try std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","images":["{s}"],"stream":false,"options":{{"temperature":0.1}}}}
    , .{ vision_model, detect_prompt, result.data });
    defer alloc.free(request_body);

    // Step 5: HTTP POST to Ollama via shell curl (consistent with other tools)
    const url = try std.fmt.allocPrint(alloc, "{s}/api/generate", .{ollama_url});
    defer alloc.free(url);

    // Write request body to temp file (too large for command line)
    const tmp_req = "/tmp/wintermolt_detect_req.json";
    {
        const f = std.fs.cwd().createFile(tmp_req, .{}) catch
            return std.fmt.allocPrint(alloc, "Object detect: cannot create temp request file", .{});
        defer f.close();
        f.writeAll(request_body) catch
            return std.fmt.allocPrint(alloc, "Object detect: cannot write temp request file", .{});
    }

    // Execute curl
    const at_file = try std.fmt.allocPrint(alloc, "@{s}", .{tmp_req});
    defer alloc.free(at_file);
    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST",
        url,
        "-H", "Content-Type: application/json",
        "-d", at_file,
        "--max-time", "30",
    };

    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_list: std.ArrayListAligned(u8, null) = .{};
    var stderr_list: std.ArrayListAligned(u8, null) = .{};
    child.collectOutput(alloc, &stdout_list, &stderr_list, 1024 * 1024) catch {};
    _ = child.wait() catch {};
    const stdout = stdout_list.items;
    defer stdout_list.deinit(alloc);

    // Step 6: Parse Ollama response — extract "response" field
    const response_text = sse.findJsonString(stdout, "response") orelse
        return std.fmt.allocPrint(alloc, "Object Detection (via {s} on {s}):\n\nOllama did not return a response. Is Ollama running at {s}?\nRaw: {s}", .{
        vision_model, ollama_url, ollama_url,
        if (stdout.len > 200) stdout[0..200] else stdout,
    });

    return std.fmt.allocPrint(alloc,
        "Object Detection (via {s}):\n\n{s}", .{ vision_model, response_text });
}
