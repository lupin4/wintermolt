// Copyright The Fantastic Planet - By David Clabaugh
//
// tts_tool.zig — Text-to-speech tool
//
// Synthesizes text to audio using the configured TTS provider.
// Saves the audio to a temp file and returns the path.
// Can also play it straight away (afplay on macOS, ffplay elsewhere).

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");
const tts = @import("../agent/tts.zig");

/// Execute the text_to_speech tool call.
/// Input JSON: {"text": "Hello", "voice": "thalia", "provider": "deepgram", "play": true}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const text = sse.findJsonString(input_json, "text") orelse
        return alloc.dupe(u8, "Error: 'text' field is required.");

    if (text.len == 0)
        return alloc.dupe(u8, "Error: 'text' must not be empty.");

    if (text.len > 4096)
        return alloc.dupe(u8, "Error: Text too long. Maximum 4096 characters per synthesis.");

    // Build text with optional inline directives
    var full_text: ArrayList(u8) = .empty;
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
        tts.playDetached(alloc, file_path) catch {};
    }

    return std.fmt.allocPrint(alloc, "Audio saved to: {s}\nProvider: {s}\nVoice: {s}", .{
        file_path,
        provider_override orelse @tagName(tts.providerFromEnv()),
        voice_override orelse (compat.getenv("WINTERMOLT_TTS_VOICE") orelse "the provider's default"),
    });
}
