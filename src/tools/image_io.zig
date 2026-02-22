// Copyright The Fantastic Planet - By David Clabaugh
//
// image_io.zig — BMP image file I/O for forKernels CV tools
//
// Reads/writes 24-bit BMP files in pure Zig. For non-BMP formats
// (JPEG, PNG, TIFF, etc.), uses sips (macOS) or ffmpeg (Linux)
// as a format conversion bridge.
//
// The forcv kernels operate on interleaved u8 pixel buffers (RGB).
// This module bridges the gap between file paths (what Claude sends)
// and raw pixel buffers (what the kernels need).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u32, // 3 for RGB, 1 for grayscale
    pixels: []u8, // Interleaved, top-down row order (RGB or grayscale)
    alloc: Allocator,

    pub fn deinit(self: *Image) void {
        self.alloc.free(self.pixels);
    }

    /// Total number of bytes in the pixel buffer.
    pub fn byteLen(self: *const Image) usize {
        return self.width * self.height * self.channels;
    }
};

/// Read an image file. Supports BMP natively; JPEG/PNG/TIFF converted via sips/ffmpeg.
pub fn readImage(alloc: Allocator, path: []const u8) !Image {
    if (hasBmpExtension(path)) {
        return readBmp(alloc, path);
    }

    // Convert to BMP via system tools, then parse BMP
    const tmp_path = "/tmp/wintermolt_img_input.bmp";
    try convertToBmp(alloc, path, tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    return readBmp(alloc, tmp_path);
}

/// Write an image to a file. Writes BMP natively; other formats converted via sips/ffmpeg.
pub fn writeImage(alloc: Allocator, image: *const Image, path: []const u8) !void {
    if (hasBmpExtension(path)) {
        try writeBmp(image, path);
        return;
    }

    // Write as BMP first, then convert to target format
    const tmp_path = "/tmp/wintermolt_img_output.bmp";
    try writeBmp(image, tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try convertFromBmp(alloc, tmp_path, path);
}

fn hasBmpExtension(path: []const u8) bool {
    const lower = getExtension(path);
    return std.mem.eql(u8, lower, "bmp");
}

// ---------------------------------------------------------------------------
// BMP reader — parses 24-bit or 32-bit Windows BMP
// ---------------------------------------------------------------------------

fn readBmp(alloc: Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // File header (14 bytes)
    var fh: [14]u8 = undefined;
    const fh_n = try file.readAll(&fh);
    if (fh_n != 14) return error.InvalidBmp;
    if (fh[0] != 'B' or fh[1] != 'M') return error.InvalidBmp;

    const pixel_offset = std.mem.readInt(u32, fh[10..14], .little);

    // DIB header (BITMAPINFOHEADER, 40 bytes minimum)
    var dib: [40]u8 = undefined;
    const dib_n = try file.readAll(&dib);
    if (dib_n < 40) return error.InvalidBmp;

    const width: u32 = @bitCast(std.mem.readInt(i32, dib[4..8], .little));
    const height_raw: i32 = std.mem.readInt(i32, dib[8..12], .little);
    const bpp = std.mem.readInt(u16, dib[14..16], .little);

    if (bpp != 24 and bpp != 32) return error.UnsupportedBpp;

    const height: u32 = @intCast(if (height_raw < 0) -height_raw else height_raw);
    const bottom_up = height_raw > 0;
    const src_channels: u32 = if (bpp == 32) 4 else 3;

    if (width == 0 or height == 0) return error.InvalidBmp;
    if (width > 65536 or height > 65536) return error.ImageTooLarge;

    // BMP rows padded to 4-byte boundaries
    const row_bytes = width * src_channels;
    const padded_row = (row_bytes + 3) & ~@as(u32, 3);

    // Seek to pixel data
    try file.seekTo(pixel_offset);

    // Read raw pixel data
    const pixel_data_size: usize = padded_row * height;
    const raw = try alloc.alloc(u8, pixel_data_size);
    defer alloc.free(raw);
    const n = try file.readAll(raw);
    if (n < pixel_data_size) return error.TruncatedBmp;

    // Convert BGR(A) → RGB, handle bottom-up orientation
    const out_channels: u32 = 3; // Always output RGB
    const pixels = try alloc.alloc(u8, width * height * out_channels);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (bottom_up) height - 1 - y else y;
        const src_off: usize = src_y * padded_row;
        const dst_off: usize = y * width * out_channels;

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const si = src_off + x * src_channels;
            const di = dst_off + x * out_channels;
            pixels[di + 0] = raw[si + 2]; // R ← B
            pixels[di + 1] = raw[si + 1]; // G ← G
            pixels[di + 2] = raw[si + 0]; // B ← R
        }
    }

    return .{
        .width = width,
        .height = height,
        .channels = out_channels,
        .pixels = pixels,
        .alloc = alloc,
    };
}

// ---------------------------------------------------------------------------
// BMP writer — writes 24-bit Windows BMP
// ---------------------------------------------------------------------------

fn writeBmp(image: *const Image, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const w = image.width;
    const h = image.height;
    const ch = image.channels;
    const padded_row = (w * 3 + 3) & ~@as(u32, 3);
    const pixel_data_size = padded_row * h;
    const file_size = 14 + 40 + pixel_data_size;

    // File header (14 bytes)
    var fh: [14]u8 = undefined;
    fh[0] = 'B';
    fh[1] = 'M';
    std.mem.writeInt(u32, fh[2..6], file_size, .little);
    std.mem.writeInt(u16, fh[6..8], 0, .little);
    std.mem.writeInt(u16, fh[8..10], 0, .little);
    std.mem.writeInt(u32, fh[10..14], 54, .little);
    try file.writeAll(&fh);

    // DIB header (40 bytes — BITMAPINFOHEADER)
    var dib: [40]u8 = .{0} ** 40;
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], @intCast(w), .little);
    std.mem.writeInt(i32, dib[8..12], @intCast(h), .little); // positive = bottom-up
    std.mem.writeInt(u16, dib[12..14], 1, .little); // planes
    std.mem.writeInt(u16, dib[14..16], 24, .little); // bpp
    std.mem.writeInt(u32, dib[20..24], pixel_data_size, .little);
    try file.writeAll(&dib);

    // Pixel data (RGB → BGR, bottom-up, padded rows)
    const padding: usize = padded_row - w * 3;
    const pad_bytes = [_]u8{ 0, 0, 0 };

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_y = h - 1 - y; // bottom-up
        const src_off: usize = src_y * w * ch;

        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const si = src_off + x * ch;
            // For grayscale (1 channel), replicate to BGR
            const bgr = if (ch == 1)
                [3]u8{ image.pixels[si], image.pixels[si], image.pixels[si] }
            else
                [3]u8{
                    image.pixels[si + 2], // B
                    image.pixels[si + 1], // G
                    image.pixels[si + 0], // R
                };
            try file.writeAll(&bgr);
        }
        if (padding > 0) try file.writeAll(pad_bytes[0..padding]);
    }
}

// ---------------------------------------------------------------------------
// Format conversion via system tools
// ---------------------------------------------------------------------------

/// Convert any image to BMP using sips (macOS) or ffmpeg (Linux).
fn convertToBmp(alloc: Allocator, input: []const u8, output: []const u8) !void {
    // Try sips first (macOS built-in)
    if (runCommand(alloc, &[_][]const u8{
        "sips", "--setProperty", "format", "bmp", input, "--out", output,
    })) {
        return;
    } else |_| {}

    // Fall back to ffmpeg
    runCommand(alloc, &[_][]const u8{
        "ffmpeg", "-y", "-loglevel", "error", "-i", input, "-pix_fmt", "bgr24", output,
    }) catch return error.ConversionFailed;
}

/// Convert BMP to target format using sips (macOS) or ffmpeg (Linux).
fn convertFromBmp(alloc: Allocator, input: []const u8, output: []const u8) !void {
    // Determine sips format name from extension
    const ext = getExtension(output);
    const sips_fmt = if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg"))
        "jpeg"
    else if (std.mem.eql(u8, ext, "png"))
        "png"
    else if (std.mem.eql(u8, ext, "tiff") or std.mem.eql(u8, ext, "tif"))
        "tiff"
    else if (std.mem.eql(u8, ext, "gif"))
        "gif"
    else
        "png";

    // Try sips first
    if (runCommand(alloc, &[_][]const u8{
        "sips", "--setProperty", "format", sips_fmt, input, "--out", output,
    })) {
        return;
    } else |_| {}

    // Fall back to ffmpeg
    runCommand(alloc, &[_][]const u8{
        "ffmpeg", "-y", "-loglevel", "error", "-i", input, output,
    }) catch return error.ConversionFailed;
}

/// Run a command and return success/error. Discards output.
fn runCommand(alloc: Allocator, argv: []const []const u8) !void {
    var child = Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_list: ArrayList(u8) = .{};
    defer stdout_list.deinit(alloc);
    var stderr_list: ArrayList(u8) = .{};
    defer stderr_list.deinit(alloc);

    child.collectOutput(alloc, &stdout_list, &stderr_list, 64 * 1024) catch {};

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

/// Extract file extension (lowercase-ish, after last dot).
fn getExtension(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        return path[dot + 1 ..];
    }
    return "";
}
