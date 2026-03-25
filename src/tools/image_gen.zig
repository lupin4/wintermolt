// Copyright The Fantastic Planet - By David Clabaugh
//
// image_gen.zig — AI image generation tool
//
// Generates images via DALL-E 3 (OpenAI) or other providers.
// Downloads the result and saves to a temp file. Returns the path
// and optionally base64 data for vision feedback loops.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");

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

/// Execute the image_generate tool.
/// Input: {"prompt": "...", "size": "1024x1024", "model": "dall-e-3", "quality": "standard"}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const prompt = sse.findJsonString(input_json, "prompt") orelse
        return alloc.dupe(u8, "Error: 'prompt' field is required.");

    const api_key = std.posix.getenv("OPENAI_API_KEY") orelse
        return alloc.dupe(u8, "Error: OPENAI_API_KEY not set. Required for image generation.");

    const size = sse.findJsonString(input_json, "size") orelse "1024x1024";
    const model = sse.findJsonString(input_json, "model") orelse "dall-e-3";
    const quality = sse.findJsonString(input_json, "quality") orelse "standard";

    // Build request body
    const body = try std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","n":1,"size":"{s}","quality":"{s}","response_format":"url"}}
    , .{ model, prompt, size, quality });
    defer alloc.free(body);

    // Call OpenAI API
    const handle = curl_easy_init() orelse
        return alloc.dupe(u8, "Error: Failed to initialize HTTP client.");
    defer curl_easy_cleanup(handle);

    var response = ResponseBuffer{ .data = .{}, .alloc = alloc };

    const auth_header = try std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{api_key});
    defer alloc.free(auth_header);
    const auth_z = try alloc.dupeZ(u8, auth_header);
    defer alloc.free(auth_z);

    _ = curl_easy_setopt(handle, CURLOPT_URL, "https://api.openai.com/v1/images/generations");
    _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 60));

    var headers: ?*CurlSlist = null;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    headers = curl_slist_append(headers, auth_z.ptr);
    if (headers) |h| {
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
        defer curl_slist_free_all(h);
    }

    const result = curl_easy_perform(handle);
    if (result != .ok) {
        response.data.deinit(alloc);
        return alloc.dupe(u8, "Error: API request failed.");
    }

    const resp_body = response.data.items;
    defer response.data.deinit(alloc);

    // Extract URL from response: {"data":[{"url":"https://..."}]}
    const image_url = sse.findJsonString(resp_body, "url") orelse {
        // Check for error message
        const err_msg = sse.findJsonString(resp_body, "message") orelse "Unknown API error";
        return std.fmt.allocPrint(alloc, "Error: {s}", .{err_msg});
    };

    // Download the image
    const output_path = try std.fmt.allocPrint(alloc, "/tmp/wintermolt_gen_{d}.png", .{std.time.milliTimestamp()});
    defer alloc.free(output_path);

    const download_result = downloadImage(alloc, image_url, output_path) catch {
        return std.fmt.allocPrint(alloc, "Image generated but download failed.\nURL: {s}", .{image_url});
    };

    if (download_result) {
        return std.fmt.allocPrint(alloc,
            \\Image generated successfully.
            \\  Path: {s}
            \\  Model: {s}
            \\  Size: {s}
            \\  Quality: {s}
            \\  Prompt: {s}
        , .{ output_path, model, size, quality, prompt });
    }

    return std.fmt.allocPrint(alloc, "Image generated.\nURL: {s}", .{image_url});
}

fn downloadImage(alloc: Allocator, url: []const u8, output_path: []const u8) !bool {
    const handle = curl_easy_init() orelse return false;
    defer curl_easy_cleanup(handle);

    var response = ResponseBuffer{ .data = .{}, .alloc = alloc };

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);

    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 30));
    _ = curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    const result = curl_easy_perform(handle);
    defer response.data.deinit(alloc);

    if (result != .ok or response.data.items.len == 0) return false;

    // Write to file
    const path_z = try alloc.dupeZ(u8, output_path);
    defer alloc.free(path_z);

    const file = std.fs.createFileAbsolute(path_z, .{}) catch return false;
    defer file.close();
    file.writeAll(response.data.items) catch return false;

    return true;
}
