// Copyright The Fantastic Planet - By David Clabaugh
//
// stt.zig — Speech to text, for /listen
//
// ffmpeg records the microphone to a 16 kHz mono WAV, the format whisper.cpp
// reads, and one of these transcribes it:
//   - whisper.cpp (whisper-server kept running, else whisper-cli; local; a
//     ggml model in ~/.wintermolt/models)
//   - Deepgram (api.deepgram.com/v1/listen, nova-3; DEEPGRAM_API_KEY)
//
// WINTERMOLT_STT_PROVIDER picks one. Unset, a local model wins: nothing said
// leaves the machine.

const std = @import("std");
const builtin = @import("builtin");
const fsio = @import("../fsio.zig");
const stdio = @import("../stdio.zig");
const compat = @import("../compat.zig");
const camera = @import("../tools/camera.zig");
const tts = @import("tts.zig");
const Allocator = std.mem.Allocator;

pub const Provider = enum { whisper, deepgram };

/// The provider named, else whisper.cpp when a model is on disk, else
/// Deepgram when its key is set; null when there is neither.
pub fn pickProvider(name: ?[]const u8, have_model: bool, have_deepgram_key: bool) ?Provider {
    if (name) |n| if (std.meta.stringToEnum(Provider, n)) |p| return p;
    if (have_model) return .whisper;
    if (have_deepgram_key) return .deepgram;
    return null;
}

/// ffmpeg recording `seconds` from `input` to a 16 kHz mono WAV at `path`.
/// -progress reports on stdout, the first time once the output is open:
/// that is when the microphone is capturing.
pub fn recordArgv(buf: *[18][]const u8, os: std.Target.Os.Tag, input: []const u8, seconds: []const u8, path: []const u8) []const []const u8 {
    const format = switch (os) {
        .windows => "dshow",
        .macos => "avfoundation",
        else => "pulse",
    };
    buf.* = .{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-y", "-f", format, "-i", input, "-t", seconds, "-ac", "1", "-ar", "16000", path };
    return buf;
}

/// ffmpeg recording the microphone, already capturing.
pub const Recording = struct {
    child: std.process.Child,

    /// Wait for the recording to end.
    pub fn finish(self: *Recording) !void {
        var progress = stdio.readerFor(self.child.stdout.?);
        var sink: [4096]u8 = undefined;
        while ((progress.read(&sink) catch 0) > 0) {} // until ffmpeg exits
        const term = try fsio.waitChild(&self.child);
        if (term != .exited or term.exited != 0) {
            mic_len = 0; // look the device up again next time
            return error.RecordingFailed;
        }
    }
};

/// Start recording the microphone for `seconds` to a WAV at `path`, and
/// return once it is capturing: opening a DirectShow device takes seconds on
/// some machines, and "speak now" must not come before it does.
/// WINTERMOLT_MIC names the microphone: a DirectShow device on Windows (else
/// the first one listed), an AVFoundation index such as ":1" on macOS (else
/// ":0"), a PulseAudio source elsewhere (else "default").
pub fn startRecording(alloc: Allocator, path: []const u8, seconds: u32) !Recording {
    var secs_buf: [12]u8 = undefined;
    var argv_buf: [18][]const u8 = undefined;
    const argv = recordArgv(&argv_buf, builtin.os.tag, try micInput(alloc), try std.fmt.bufPrint(&secs_buf, "{d}", .{seconds}), path);
    var child = try fsio.spawnStdout(alloc, argv);
    var progress = stdio.readerFor(child.stdout.?);
    var line: [512]u8 = undefined;
    _ = progress.readUntilDelimiter(&line, '\n') catch {
        // ffmpeg ended before reporting: the device did not open.
        _ = fsio.waitChild(&child) catch {};
        mic_len = 0;
        return error.RecordingFailed;
    };
    return .{ .child = child };
}

// The DirectShow input /listen found: listing the devices takes seconds, so a
// session does it once.
var mic_buf: [256]u8 = undefined;
var mic_len: usize = 0;

fn micInput(alloc: Allocator) ![]const u8 {
    const mic = compat.getenv("WINTERMOLT_MIC");
    return switch (builtin.os.tag) {
        .windows => {
            if (mic) |m| return std.fmt.bufPrint(&mic_buf, "audio={s}", .{m});
            if (mic_len == 0) {
                const listing = try camera.listDshow(alloc);
                defer listing.deinit(alloc);
                var lines = std.mem.splitScalar(u8, listing.stderr, '\n');
                while (lines.next()) |line| if (camera.dshowDeviceName(line, "audio")) |name| {
                    mic_len = (try std.fmt.bufPrint(&mic_buf, "audio={s}", .{name})).len;
                    break;
                };
                if (mic_len == 0) return error.NoMicrophone;
            }
            return mic_buf[0..mic_len];
        },
        .macos => mic orelse ":0",
        else => mic orelse "default",
    };
}

/// What was said in a WAV, by WINTERMOLT_STT_PROVIDER or the first provider
/// there is. Caller owns the result, which is empty when nothing was said.
pub fn transcribe(alloc: Allocator, wav_path: []const u8) ![]u8 {
    const model = try findModel(alloc);
    defer if (model) |m| alloc.free(m);
    const key = compat.getenv("DEEPGRAM_API_KEY");
    const provider = pickProvider(compat.getenv("WINTERMOLT_STT_PROVIDER"), model != null, key != null) orelse
        return error.NoSpeechToText;
    return switch (provider) {
        .whisper => transcribeWhisper(alloc, model orelse return error.NoWhisperModel, wav_path),
        .deepgram => transcribeDeepgram(alloc, key orelse return error.NoApiKey, wav_path),
    };
}

/// WINTERMOLT_WHISPER_MODEL, else the first ggml-*.bin in ~/.wintermolt/models.
fn findModel(alloc: Allocator) !?[]u8 {
    if (compat.getenv("WINTERMOLT_WHISPER_MODEL")) |m| return try alloc.dupe(u8, m);
    const home = compat.getenv("HOME") orelse return null;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.wintermolt/models", .{home});
    defer alloc.free(dir_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "ggml-") and std.mem.endsWith(u8, entry.name, ".bin"))
            return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
    }
    return null;
}

// whisper-cli loads its backends and the model on every run (2-10 s here);
// whisper-server loads them once. /listen starts it, the rest of the session
// reuses it, and it ends with wintermolt, crash or not (fsio.spawnTied).
const server_port = "8178";
const server_url = "http://127.0.0.1:" ++ server_port ++ "/inference";
const boundary = "wintermolt-whisper-6b1f0c93d2a4"; // the form body must never contain it
var server: ?std.process.Child = null;
var server_answered = false;

/// Start whisper-server, if whisper.cpp is what will transcribe and it is not
/// running yet. /listen calls this first, so the model loads while you speak.
/// Without whisper-server installed, whisper-cli does the work.
pub fn startServer(alloc: Allocator) void {
    if (server != null) return;
    if (pickProvider(compat.getenv("WINTERMOLT_STT_PROVIDER"), true, false) != .whisper) return;
    const model = (findModel(alloc) catch null) orelse return;
    defer alloc.free(model);
    server = fsio.spawnTied(alloc, &.{ "whisper-server", "-m", model, "--host", "127.0.0.1", "--port", server_port }) catch null;
}

/// The server is starting and has not transcribed anything yet: the next
/// transcription waits for the model to load, the first time only.
pub fn serverLoading() bool {
    return server != null and !server_answered;
}

pub fn stopServer() void {
    if (server) |*child| fsio.stopTied(child);
    server = null;
    server_answered = false;
}

/// POST the WAV to whisper-server, waiting while it loads: it listens only
/// once the model is in, so until then the connection is refused.
fn transcribeServer(alloc: Allocator, wav_path: []const u8) ![]u8 {
    const file = try fsio.openFile(wav_path, .{});
    defer fsio.close(file);
    const audio = try fsio.readToEndAlloc(file, alloc, 64 * 1024 * 1024);
    defer alloc.free(audio);
    const body = try multipartWav(alloc, audio);
    defer alloc.free(body);

    const deadline = fsio.monoNs() + 30 * std.time.ns_per_s;
    const reply = while (true) {
        if (tts.httpPost(alloc, server_url, "Content-Type: multipart/form-data; boundary=" ++ boundary, "Accept: application/json", body)) |r| break r else |e| {
            if (e != error.CurlFailed or fsio.monoNs() > deadline) return e;
            fsio.sleepNs(250 * std.time.ns_per_ms);
        }
    };
    defer alloc.free(reply);
    const said = try parseServerTranscript(alloc, reply);
    server_answered = true;
    return said;
}

/// whisper-server's /inference takes the audio as a form upload named "file".
pub fn multipartWav(alloc: Allocator, audio: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{
        "--" ++ boundary ++ "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n",
        audio,
        "\r\n--" ++ boundary ++ "--\r\n",
    });
}

/// whisper-server's reply, {"text": " what was said\n"}.
pub fn parseServerTranscript(alloc: Allocator, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(struct { text: []const u8 }, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parseWhisperOutput(alloc, parsed.value.text);
}

fn transcribeWhisper(alloc: Allocator, model: []const u8, wav_path: []const u8) ![]u8 {
    if (server != null) {
        if (transcribeServer(alloc, wav_path)) |said| return said else |_| stopServer(); // the next /listen starts a fresh one
    }
    const cli = compat.getenv("WINTERMOLT_WHISPER_CLI") orelse "whisper-cli";
    const run = try fsio.runCapture(alloc, &.{ cli, "-m", model, "-f", wav_path, "-nt", "-np" }, 1 << 20, null);
    defer run.deinit(alloc);
    if (!run.exited or run.exit_code != 0) return error.WhisperFailed;
    return parseWhisperOutput(alloc, run.stdout);
}

/// whisper-cli -nt prints a line per segment, and a tag such as
/// [BLANK_AUDIO] for a stretch with no speech.
pub fn parseWhisperOutput(alloc: Allocator, out: []const u8) ![]u8 {
    var said: std.Io.Writer.Allocating = .init(alloc);
    errdefer said.deinit();
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or (line[0] == '[' and line[line.len - 1] == ']')) continue;
        if (said.written().len > 0) try said.writer.writeByte(' ');
        try said.writer.writeAll(line);
    }
    return said.toOwnedSlice();
}

fn transcribeDeepgram(alloc: Allocator, key: []const u8, wav_path: []const u8) ![]u8 {
    const file = try fsio.openFile(wav_path, .{});
    defer fsio.close(file);
    const audio = try fsio.readToEndAlloc(file, alloc, 64 * 1024 * 1024);
    defer alloc.free(audio);

    const auth_z = try std.fmt.allocPrintSentinel(alloc, "Authorization: Token {s}", .{key}, 0);
    defer alloc.free(auth_z);
    const body = try tts.httpPost(alloc, "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true", "Content-Type: audio/wav", auth_z, audio);
    defer alloc.free(body);
    return parseDeepgramTranscript(alloc, body);
}

/// results.channels[0].alternatives[0].transcript of a /v1/listen response.
pub fn parseDeepgramTranscript(alloc: Allocator, json: []const u8) ![]u8 {
    const Response = struct {
        results: struct {
            channels: []const struct { alternatives: []const struct { transcript: []const u8 } },
        },
    };
    const parsed = try std.json.parseFromSlice(Response, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const channels = parsed.value.results.channels;
    if (channels.len == 0 or channels[0].alternatives.len == 0) return alloc.dupe(u8, "");
    return alloc.dupe(u8, channels[0].alternatives[0].transcript);
}

test "pickProvider: the one named, else a local Whisper model, else Deepgram's key, else none" {
    try std.testing.expectEqual(Provider.deepgram, pickProvider("deepgram", true, true).?);
    try std.testing.expectEqual(Provider.whisper, pickProvider(null, true, true).?);
    try std.testing.expectEqual(Provider.deepgram, pickProvider(null, false, true).?);
    try std.testing.expect(pickProvider(null, false, false) == null);
}

test "parseWhisperOutput: segments joined, and [BLANK_AUDIO] and other tags dropped" {
    const alloc = std.testing.allocator;
    const said = try parseWhisperOutput(alloc, "\r\n Hello there.\r\n How are you?\r\n");
    defer alloc.free(said);
    try std.testing.expectEqualStrings("Hello there. How are you?", said);
    const blank = try parseWhisperOutput(alloc, " [BLANK_AUDIO]\n");
    defer alloc.free(blank);
    try std.testing.expectEqualStrings("", blank);
}

test "parseDeepgramTranscript: the first alternative of the first channel" {
    const alloc = std.testing.allocator;
    const said = try parseDeepgramTranscript(alloc,
        \\{"metadata":{"request_id":"x"},"results":{"channels":[{"alternatives":[{"transcript":"hello world","confidence":0.99,"words":[]}]}]}}
    );
    defer alloc.free(said);
    try std.testing.expectEqualStrings("hello world", said);
}

test "multipartWav: the WAV as the form's file field, between boundaries" {
    const alloc = std.testing.allocator;
    const body = try multipartWav(alloc, "RIFF\x00\x01");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n" ++
        "Content-Type: audio/wav\r\n\r\n" ++
        "RIFF\x00\x01" ++
        "\r\n--" ++ boundary ++ "--\r\n", body);
}

test "parseServerTranscript: whisper-server's text, trimmed, and silence is nothing" {
    const alloc = std.testing.allocator;
    const said = try parseServerTranscript(alloc, "{\"text\":\" The quick brown fox.\\n\"}");
    defer alloc.free(said);
    try std.testing.expectEqualStrings("The quick brown fox.", said);
    const blank = try parseServerTranscript(alloc, "{\"text\":\" [BLANK_AUDIO]\\n\"}");
    defer alloc.free(blank);
    try std.testing.expectEqualStrings("", blank);
    try std.testing.expectError(error.MissingField, parseServerTranscript(alloc, "{\"error\":\"failed to read audio\"}"));
}

test "recordArgv: a 16 kHz mono WAV, from DirectShow, AVFoundation or PulseAudio, reporting progress on stdout" {
    var buf: [18][]const u8 = undefined;
    const win = recordArgv(&buf, .windows, "audio=Microphone (Yeti)", "5", "mic.wav");
    try std.testing.expectEqualStrings("ffmpeg", win[0]);
    try std.testing.expectEqualStrings("pipe:1", argAfter(win, "-progress"));
    try std.testing.expectEqualStrings("dshow", argAfter(win, "-f"));
    try std.testing.expectEqualStrings("audio=Microphone (Yeti)", argAfter(win, "-i"));
    try std.testing.expectEqualStrings("5", argAfter(win, "-t"));
    try std.testing.expectEqualStrings("1", argAfter(win, "-ac"));
    try std.testing.expectEqualStrings("16000", argAfter(win, "-ar"));
    try std.testing.expectEqualStrings("mic.wav", win[win.len - 1]);
    try std.testing.expectEqualStrings("avfoundation", argAfter(recordArgv(&buf, .macos, ":0", "5", "m.wav"), "-f"));
    try std.testing.expectEqualStrings("pulse", argAfter(recordArgv(&buf, .linux, "default", "5", "m.wav"), "-f"));
}

fn argAfter(argv: []const []const u8, flag: []const u8) []const u8 {
    for (argv[0 .. argv.len - 1], 0..) |a, i| if (std.mem.eql(u8, a, flag)) return argv[i + 1];
    return "";
}
