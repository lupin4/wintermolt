// Copyright The Fantastic Planet - By David Clabaugh
//
// tts_tool.zig — Text-to-speech tool
//
// Synthesizes text to audio using the configured TTS provider.
// Saves the audio to a temp file and returns the path.
// Can also play audio directly via system audio (afplay on macOS, aplay on Linux).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");
const tts = @import("../agent/tts.zig");

/// Execute the text_to_speech tool call.
/// Input JSON: {"text": "Hello", "voice": "alloy", "provider": "openai", "play": true}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const text = sse.findJsonString(input_json, "text") orelse
        return alloc.dupe(u8, "Error: 'text' field is required.");

    if (text.len == 0)
        return alloc.dupe(u8, "Error: 'text' must not be empty.");

    if (text.len > 4096)
        return alloc.dupe(u8, "Error: Text too long. Maximum 4096 characters per synthesis.");

    // Check if TTS is configured
    const provider_str = std.posix.getenv("WINTERMOLT_TTS_PROVIDER");
    if (provider_str == null) {
        const has_openai = std.posix.getenv("OPENAI_API_KEY") != null;
        if (!has_openai) {
            return alloc.dupe(u8, "Error: TTS not configured. Set WINTERMOLT_TTS_PROVIDER (openai, elevenlabs, piper, edge) and the relevant API key.");
        }
    }

    // Build text with optional inline directives
    var full_text: ArrayList(u8) = .{};
    defer full_text.deinit(alloc);

    // Apply voice/provider overrides as inline directives
    const voice_override = sse.findJsonString(input_json, "voice");
    const provider_override = sse.findJsonString(input_json, "provider");

    if (provider_override) |p| {
        try full_text.appendSlice(alloc, "[[provider:");
        try full_text.appendSlice(alloc, p);
        try full_text.appendSlice(alloc, "]] ");
    }
    if (voice_override) |v| {
        try full_text.appendSlice(alloc, "[[voice:");
        try full_text.appendSlice(alloc, v);
        try full_text.appendSlice(alloc, "]] ");
    }
    try full_text.appendSlice(alloc, text);

    // Synthesize
    var client = tts.TtsClient.init(alloc);
    const file_path = client.synthesizeToFile(full_text.items) catch |e| {
        return std.fmt.allocPrint(alloc, "Error: TTS synthesis failed: {s}", .{@errorName(e)});
    };
    defer alloc.free(file_path);

    // Optionally play the audio
    const play_str = sse.findJsonString(input_json, "play");
    const should_play = if (play_str) |p| std.mem.eql(u8, p, "true") else false;

    if (should_play) {
        playAudio(alloc, file_path) catch {};
    }

    return std.fmt.allocPrint(alloc, "Audio saved to: {s}\nFormat: mp3\nProvider: {s}\nVoice: {s}", .{
        file_path,
        provider_override orelse (std.posix.getenv("WINTERMOLT_TTS_PROVIDER") orelse "openai"),
        voice_override orelse (std.posix.getenv("WINTERMOLT_TTS_VOICE") orelse "alloy"),
    });
}

/// Play an audio file using the system audio player.
fn playAudio(alloc: Allocator, path: []const u8) !void {
    const cmd = switch (comptime @import("builtin").os.tag) {
        .macos => try std.fmt.allocPrint(alloc, "afplay \"{s}\" &", .{path}),
        .linux => try std.fmt.allocPrint(alloc, "aplay \"{s}\" &", .{path}),
        else => return,
    };
    defer alloc.free(cmd);

    const cmd_z = try alloc.dupeZ(u8, cmd);
    defer alloc.free(cmd_z);

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd_z };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    // Don't wait — play in background
}
