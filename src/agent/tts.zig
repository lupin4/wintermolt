// Copyright The Fantastic Planet - By David Clabaugh
//
// tts.zig — Text-to-speech provider abstraction
//
// Supports multiple TTS backends:
//   - Deepgram Aura-2 (api.deepgram.com/v1/speak)
//   - OpenAI TTS (api.openai.com/v1/audio/speech)
//   - ElevenLabs (api.elevenlabs.io/v1/text-to-speech)
//   - Piper TTS (local, via piper CLI — offline)
//   - Edge TTS (Microsoft, via edge-tts Python CLI)
//   - The computer's own voice (Windows SAPI, macOS say, espeak-ng): no key
//
// All providers return raw audio bytes (mp3/wav/aiff).
// Inline directives allow per-utterance overrides: [[voice:alloy]] [[speed:1.2]]
//
// The text is model output. It reaches a CLI provider as one argument (or an
// environment variable, or a file), never through a shell, and a request body
// as JSON-escaped text.

const std = @import("std");
const builtin = @import("builtin");
const curl_tls = @import("../curl_tls.zig");
const fsio = @import("../fsio.zig");
const compat = @import("../compat.zig");
const camera = @import("../tools/camera.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// ---------------------------------------------------------------------------
// libcurl extern declarations
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) CurlCode;
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
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

const ResponseBuffer = struct {
    data: ArrayList(u8),
    alloc: Allocator,
};

fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *ResponseBuffer,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.data.appendSlice(userdata.alloc, ptr[0..total]) catch return 0;
    return total;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const TtsProvider = enum {
    deepgram,
    openai,
    elevenlabs,
    piper,
    edge_tts,
    system,
};

/// A provider as WINTERMOLT_TTS_PROVIDER and [[provider:…]] spell it.
pub fn parseProvider(name: []const u8) ?TtsProvider {
    if (std.mem.eql(u8, name, "edge")) return .edge_tts;
    return std.meta.stringToEnum(TtsProvider, name);
}

pub const Keys = struct { deepgram: bool = false, openai: bool = false, elevenlabs: bool = false };

/// The provider named, or with none (or a name it does not know) the first
/// whose key is set, and with no key the computer's own voice.
pub fn pickProvider(name: ?[]const u8, keys: Keys) TtsProvider {
    if (name) |n| if (parseProvider(n)) |p| return p;
    if (keys.deepgram) return .deepgram;
    if (keys.openai) return .openai;
    if (keys.elevenlabs) return .elevenlabs;
    return .system;
}

/// pickProvider over WINTERMOLT_TTS_PROVIDER and the keys in the environment.
pub fn providerFromEnv() TtsProvider {
    return pickProvider(compat.getenv("WINTERMOLT_TTS_PROVIDER"), .{
        .deepgram = compat.getenv("DEEPGRAM_API_KEY") != null,
        .openai = compat.getenv("OPENAI_API_KEY") != null,
        .elevenlabs = compat.getenv("ELEVENLABS_API_KEY") != null,
    });
}

/// Parsed inline directives from text: [[voice:alloy]] [[speed:1.2]] [[provider:openai]]
pub const TtsDirectives = struct {
    voice: ?[]const u8 = null,
    speed: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    clean_text: []const u8, // Text with directives stripped
};

pub const TtsResult = struct {
    audio_data: []u8, // Owned raw audio bytes (mp3/wav/aiff)
    format: []const u8, // "mp3", "wav", "aiff"
    alloc: Allocator,

    pub fn deinit(self: *TtsResult) void {
        self.alloc.free(self.audio_data);
    }
};

// ---------------------------------------------------------------------------
// TTS Client
// ---------------------------------------------------------------------------

pub const TtsClient = struct {
    alloc: Allocator,
    provider: TtsProvider,
    /// WINTERMOLT_TTS_VOICE; null leaves each provider its own default.
    voice: ?[]const u8,
    // API keys (from config)
    deepgram_api_key: ?[]const u8,
    openai_api_key: ?[]const u8,
    elevenlabs_api_key: ?[]const u8,
    elevenlabs_voice_id: ?[]const u8,
    piper_model: ?[]const u8,

    pub fn init(alloc: Allocator) TtsClient {
        return .{
            .alloc = alloc,
            .provider = providerFromEnv(),
            .voice = compat.getenv("WINTERMOLT_TTS_VOICE"),
            .deepgram_api_key = compat.getenv("DEEPGRAM_API_KEY"),
            .openai_api_key = compat.getenv("OPENAI_API_KEY"),
            .elevenlabs_api_key = compat.getenv("ELEVENLABS_API_KEY"),
            .elevenlabs_voice_id = compat.getenv("ELEVENLABS_VOICE_ID"),
            .piper_model = compat.getenv("PIPER_MODEL"),
        };
    }

    /// Synthesize text to audio. Handles inline directives.
    /// Returns owned TtsResult. Caller must call .deinit().
    pub fn synthesize(self: *const TtsClient, text: []const u8) !TtsResult {
        // Parse inline directives
        const directives = parseDirectives(self.alloc, text) catch TtsDirectives{
            .clean_text = text,
        };
        defer if (directives.clean_text.ptr != text.ptr) self.alloc.free(directives.clean_text);
        const clean = directives.clean_text;

        // Select provider (directives can override)
        const provider = if (directives.provider) |p| parseProvider(p) orelse self.provider else self.provider;
        // ElevenLabs and Piper keep their own setting ahead of WINTERMOLT_TTS_VOICE.
        const voice = directives.voice orelse switch (provider) {
            .deepgram => self.voice orelse "aura-2-thalia-en",
            .openai => self.voice orelse "alloy",
            .elevenlabs => self.elevenlabs_voice_id orelse self.voice orelse "21m00Tcm4TlvDq8ikWAM", // Rachel
            .piper => self.piper_model orelse self.voice orelse return error.NoPiperModel,
            .edge_tts => self.voice orelse "en-US-AriaNeural",
            .system => self.voice orelse "",
        };

        return switch (provider) {
            .deepgram => self.synthesizeDeepgram(clean, voice),
            .openai => self.synthesizeOpenAI(clean, voice, directives.speed),
            .elevenlabs => self.synthesizeElevenLabs(clean, voice),
            .piper => self.synthesizePiper(clean, voice),
            .edge_tts => self.synthesizeEdgeTts(clean, voice),
            .system => self.synthesizeSystem(clean, voice),
        };
    }

    /// Save synthesized audio to a temp file. Returns the file path (owned).
    pub fn synthesizeToFile(self: *const TtsClient, text: []const u8) ![]u8 {
        var result = try self.synthesize(text);
        defer result.deinit();

        var path_buf: [512]u8 = undefined;
        const path = try self.alloc.dupe(u8, try tempAudioPath(&path_buf, "tts", result.format));
        errdefer self.alloc.free(path);

        const file = try fsio.createFile(path, .{});
        defer fsio.close(file);
        try fsio.writeAll(file, result.audio_data);

        return path;
    }

    // -----------------------------------------------------------------------
    // Deepgram Aura-2
    // -----------------------------------------------------------------------

    fn synthesizeDeepgram(self: *const TtsClient, text: []const u8, voice: []const u8) !TtsResult {
        const api_key = self.deepgram_api_key orelse return error.NoApiKey;
        if (text.len > 2000) return error.TextTooLong; // Aura's limit; past it, a 413

        var model_buf: [64]u8 = undefined;
        const url = try std.fmt.allocPrint(self.alloc, "https://api.deepgram.com/v1/speak?model={s}&encoding=mp3", .{try deepgramModel(&model_buf, voice)});
        defer self.alloc.free(url);

        const body = try std.json.Stringify.valueAlloc(self.alloc, .{ .text = text }, .{});
        defer self.alloc.free(body);

        const auth_z = try std.fmt.allocPrintSentinel(self.alloc, "Authorization: Token {s}", .{api_key}, 0);
        defer self.alloc.free(auth_z);

        return self.curlPost(url, body, auth_z, "mp3");
    }

    // -----------------------------------------------------------------------
    // OpenAI TTS
    // -----------------------------------------------------------------------

    fn synthesizeOpenAI(self: *const TtsClient, text: []const u8, voice: []const u8, speed: ?[]const u8) !TtsResult {
        const api_key = self.openai_api_key orelse return error.NoApiKey;

        const body = try openaiBody(self.alloc, text, voice, speed);
        defer self.alloc.free(body);

        const auth_z = try std.fmt.allocPrintSentinel(self.alloc, "Authorization: Bearer {s}", .{api_key}, 0);
        defer self.alloc.free(auth_z);

        return self.curlPost(
            "https://api.openai.com/v1/audio/speech",
            body,
            auth_z,
            "mp3",
        );
    }

    // -----------------------------------------------------------------------
    // ElevenLabs TTS
    // -----------------------------------------------------------------------

    fn synthesizeElevenLabs(self: *const TtsClient, text: []const u8, voice_id: []const u8) !TtsResult {
        const api_key = self.elevenlabs_api_key orelse return error.NoApiKey;
        try checkName(voice_id); // it is a path segment of the URL

        const url = try std.fmt.allocPrint(self.alloc, "https://api.elevenlabs.io/v1/text-to-speech/{s}", .{voice_id});
        defer self.alloc.free(url);

        const body = try std.json.Stringify.valueAlloc(self.alloc, .{ .text = text, .model_id = "eleven_monolingual_v1" }, .{});
        defer self.alloc.free(body);

        const auth_z = try std.fmt.allocPrintSentinel(self.alloc, "xi-api-key: {s}", .{api_key}, 0);
        defer self.alloc.free(auth_z);

        return self.curlPost(url, body, auth_z, "mp3");
    }

    // -----------------------------------------------------------------------
    // Piper TTS (local, offline)
    // -----------------------------------------------------------------------

    fn synthesizePiper(self: *const TtsClient, text: []const u8, model: []const u8) !TtsResult {
        if (model.len == 0 or model[0] == '-') return error.BadVoiceName;
        var out_buf: [512]u8 = undefined;
        const out = try tempAudioPath(&out_buf, "voice", "wav");
        var argv_buf: [7][]const u8 = undefined;
        return self.runForAudio(piperArgv(&argv_buf, model, out, text), null, out, "wav");
    }

    // -----------------------------------------------------------------------
    // Edge TTS (Microsoft, via Python CLI)
    // -----------------------------------------------------------------------

    fn synthesizeEdgeTts(self: *const TtsClient, text: []const u8, voice: []const u8) !TtsResult {
        var out_buf: [512]u8 = undefined;
        const out = try tempAudioPath(&out_buf, "voice", "mp3");

        // --opt=value: a reply that starts with '-' (a list) is still the text.
        const voice_arg = try std.fmt.allocPrint(self.alloc, "--voice={s}", .{voice});
        defer self.alloc.free(voice_arg);
        const text_arg = try std.fmt.allocPrint(self.alloc, "--text={s}", .{text});
        defer self.alloc.free(text_arg);
        const media_arg = try std.fmt.allocPrint(self.alloc, "--write-media={s}", .{out});
        defer self.alloc.free(media_arg);

        return self.runForAudio(&.{ "edge-tts", voice_arg, text_arg, media_arg }, null, out, "mp3");
    }

    // -----------------------------------------------------------------------
    // The computer's own voice
    // -----------------------------------------------------------------------

    fn synthesizeSystem(self: *const TtsClient, text: []const u8, voice: []const u8) !TtsResult {
        var out_buf: [512]u8 = undefined;
        if (builtin.os.tag == .windows) {
            // The script is fixed; the text, file and voice arrive as data.
            const script = "Add-Type -AssemblyName System.Speech; " ++
                "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " ++
                "if ($env:WM_TTS_VOICE) { $s.SelectVoice($env:WM_TTS_VOICE) }; " ++
                "$s.SetOutputToWaveFile($env:WM_TTS_OUT); $s.Speak($env:WM_TTS_TEXT); $s.Dispose()";
            const out = try tempAudioPath(&out_buf, "voice", "wav");
            var env = try fsio.currentEnvMap(self.alloc);
            defer env.deinit();
            try env.put("WM_TTS_TEXT", text);
            try env.put("WM_TTS_OUT", out);
            if (voice.len > 0) try env.put("WM_TTS_VOICE", voice);
            return self.runForAudio(&.{ "powershell", "-NoProfile", "-NonInteractive", "-Command", script }, &env, out, "wav");
        }

        // say and espeak-ng read the text from a file: as an argument, a reply
        // that starts with '-' would be taken for an option.
        const mac = builtin.os.tag == .macos;
        const format = if (mac) "aiff" else "wav";
        const out = try tempAudioPath(&out_buf, "voice", format);
        var txt_buf: [512]u8 = undefined;
        const txt = try tempAudioPath(&txt_buf, "voice", "txt");
        {
            const file = try fsio.createFile(txt, .{});
            defer fsio.close(file);
            try fsio.writeAll(file, text);
        }
        defer fsio.deleteFile(txt) catch {};

        const argv = [_][]const u8{ if (mac) "say" else "espeak-ng", "-f", txt, if (mac) "-o" else "-w", out, "-v", voice };
        return self.runForAudio(argv[0..if (voice.len > 0) 7 else 5], null, out, format);
    }

    /// Run a voice CLI that writes `out`, and read the audio back.
    fn runForAudio(self: *const TtsClient, argv: []const []const u8, env: ?*const fsio.EnvMap, out: []const u8, format: []const u8) !TtsResult {
        defer fsio.deleteFile(out) catch {};
        const run = try fsio.runCapture(self.alloc, argv, 64 * 1024, env);
        defer run.deinit(self.alloc);
        if (!run.exited or run.exit_code != 0) return error.TtsFailed;

        const file = fsio.openFile(out, .{}) catch return error.TtsFailed;
        defer fsio.close(file);
        return .{
            .audio_data = try fsio.readToEndAlloc(file, self.alloc, 64 * 1024 * 1024),
            .format = format,
            .alloc = self.alloc,
        };
    }

    // -----------------------------------------------------------------------
    // Shared curl helper
    // -----------------------------------------------------------------------

    fn curlPost(self: *const TtsClient, url: []const u8, body: []const u8, auth_header_z: [*:0]const u8, format: []const u8) !TtsResult {
        return .{
            .audio_data = try httpPost(self.alloc, url, "Content-Type: application/json", auth_header_z, body),
            .format = format,
            .alloc = self.alloc,
        };
    }
};

/// POST `body` and return the response body, which must come with a 200: an
/// error's JSON is not audio, or a transcript. Caller owns the result.
pub fn httpPost(alloc: Allocator, url: []const u8, content_type_z: [*:0]const u8, auth_header_z: [*:0]const u8, body: []const u8) ![]u8 {
    const handle = curl_easy_init() orelse return error.CurlInitFailed;
    curl_tls.configure(handle);
    defer curl_easy_cleanup(handle);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);

    var response = ResponseBuffer{
        .data = .empty,
        .alloc = alloc,
    };
    errdefer response.data.deinit(alloc);

    _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
    _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body.ptr);
    _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
    _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
    _ = curl_easy_setopt(handle, CURLOPT_TIMEOUT, @as(c_long, 30));

    // Headers
    var headers: ?*CurlSlist = null;
    headers = curl_slist_append(headers, content_type_z);
    headers = curl_slist_append(headers, auth_header_z);
    // Freed after curl_easy_perform: libcurl reads the list during the transfer.
    defer if (headers) |h| curl_slist_free_all(h);
    if (headers) |h| {
        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, h);
    }

    if (curl_easy_perform(handle) != .ok) return error.CurlFailed;

    var status: c_long = 0;
    _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
    if (status == 401 or status == 403) return error.ApiKeyRejected;
    if (status != 200) return error.HttpError;
    if (response.data.items.len == 0) return error.EmptyResponse;

    return response.data.toOwnedSlice(alloc);
}

/// A Deepgram voice: "thalia" is aura-2-thalia-en, and a full model name is
/// taken as it is. It goes into the request URL.
pub fn deepgramModel(buf: []u8, voice: []const u8) ![]const u8 {
    try checkName(voice);
    if (std.mem.startsWith(u8, voice, "aura")) return voice;
    return std.fmt.bufPrint(buf, "aura-2-{s}-en", .{voice});
}

/// A voice that goes into a URL: letters, digits, '-' and '_'. The
/// [[voice:…]] directive and the tool's `voice` are model output.
fn checkName(name: []const u8) !void {
    if (name.len == 0) return error.BadVoiceName;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.BadVoiceName;
}

/// The /v1/audio/speech request. Speed comes from a [[speed:…]] directive, so
/// it is parsed as a number, and anything that is not one is 1.0.
pub fn openaiBody(alloc: Allocator, text: []const u8, voice: []const u8, speed: ?[]const u8) ![]u8 {
    const parsed = if (speed) |s| std.fmt.parseFloat(f64, s) catch 1.0 else 1.0;
    const s = if (std.math.isFinite(parsed)) std.math.clamp(parsed, 0.25, 4.0) else 1.0;
    return std.json.Stringify.valueAlloc(alloc, .{ .model = "tts-1", .input = text, .voice = voice, .speed = s, .response_format = "mp3" }, .{});
}

/// piper (OHF-Voice/piper1-gpl) takes the text after `--`.
pub fn piperArgv(buf: *[7][]const u8, model: []const u8, out: []const u8, text: []const u8) []const []const u8 {
    buf.* = .{ "piper", "-m", model, "-f", out, "--", text };
    return buf;
}

/// A fresh temp file for audio: wintermolt_<kind>_<ms>.<ext>.
fn tempAudioPath(buf: []u8, kind: []const u8, ext: []const u8) ![]const u8 {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "wintermolt_{s}_{d}.{s}", .{ kind, fsio.milliTimestamp(), ext });
    return camera.tempPath(buf, name);
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

/// The command that plays an audio file: afplay on macOS, else ffplay, which
/// comes with ffmpeg and plays mp3 and wav alike.
pub fn playerArgv(buf: *[6][]const u8, os: std.Target.Os.Tag, path: []const u8) []const []const u8 {
    if (os == .macos) {
        buf[0] = "afplay";
        buf[1] = path;
        return buf[0..2];
    }
    buf.* = .{ "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path };
    return buf;
}

/// Play an audio file and return when it has finished.
pub fn play(alloc: Allocator, path: []const u8) !void {
    var buf: [6][]const u8 = undefined;
    const run = try fsio.runCapture(alloc, playerArgv(&buf, builtin.os.tag, path), 64 * 1024, null);
    defer run.deinit(alloc);
    if (!run.exited or run.exit_code != 0) return error.PlaybackFailed;
}

/// Start playing an audio file and return at once.
pub fn playDetached(alloc: Allocator, path: []const u8) !void {
    var buf: [6][]const u8 = undefined;
    try fsio.spawnDetached(alloc, playerArgv(&buf, builtin.os.tag, path));
}

/// What to say of a reply: markdown's marks dropped and, past `buf.len`, cut
/// where a sentence (or else a word) ends.
pub fn spokenText(buf: []u8, text: []const u8) []const u8 {
    var cut = text;
    if (cut.len > buf.len) {
        cut = text[0..buf.len];
        if (std.mem.lastIndexOfAny(u8, cut, ".!?\n")) |i| {
            cut = cut[0 .. i + 1];
        } else if (std.mem.lastIndexOfScalar(u8, cut, ' ')) |i| cut = cut[0..i];
    }
    var n: usize = 0;
    for (cut) |c| if (c != '*' and c != '#' and c != '`') {
        buf[n] = c;
        n += 1;
    };
    return buf[0..n];
}

/// Say a reply aloud and return when it has been said: /listen's answer.
pub fn speak(alloc: Allocator, text: []const u8) !void {
    var buf: [2000]u8 = undefined; // Deepgram's limit, and plenty to listen to
    const words = spokenText(&buf, text);
    if (words.len == 0) return;
    var client = TtsClient.init(alloc);
    const path = try client.synthesizeToFile(words);
    defer alloc.free(path);
    defer fsio.deleteFile(path) catch {};
    try play(alloc, path);
}

// ---------------------------------------------------------------------------
// Directive parsing
// ---------------------------------------------------------------------------

/// Parse inline directives: [[voice:alloy]] [[speed:1.2]] [[provider:openai]]
/// Returns clean text with directives stripped.
pub fn parseDirectives(alloc: Allocator, text: []const u8) !TtsDirectives {
    var result = TtsDirectives{
        .clean_text = text,
    };

    var clean: ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < text.len) {
        if (i + 2 < text.len and text[i] == '[' and text[i + 1] == '[') {
            // Find closing ]]
            const end = std.mem.indexOf(u8, text[i..], "]]") orelse {
                try clean.append(alloc, text[i]);
                i += 1;
                continue;
            };

            const directive = text[i + 2 .. i + end];
            const colon = std.mem.indexOf(u8, directive, ":") orelse {
                try clean.appendSlice(alloc, text[i .. i + end + 2]);
                i += end + 2;
                continue;
            };

            const key = directive[0..colon];
            const val = directive[colon + 1 ..];

            if (std.mem.eql(u8, key, "voice")) {
                result.voice = val;
            } else if (std.mem.eql(u8, key, "speed")) {
                result.speed = val;
            } else if (std.mem.eql(u8, key, "provider")) {
                result.provider = val;
            }

            i += end + 2;
        } else {
            try clean.append(alloc, text[i]);
            i += 1;
        }
    }

    if (clean.items.len > 0) {
        result.clean_text = try clean.toOwnedSlice(alloc);
    } else {
        clean.deinit(alloc);
    }

    return result;
}

test "pickProvider: the one named, else the first whose key is set, else the computer's own voice" {
    try std.testing.expectEqual(TtsProvider.piper, pickProvider("piper", .{ .deepgram = true }));
    try std.testing.expectEqual(TtsProvider.edge_tts, pickProvider("edge", .{}));
    try std.testing.expectEqual(TtsProvider.deepgram, pickProvider(null, .{ .deepgram = true, .openai = true }));
    try std.testing.expectEqual(TtsProvider.openai, pickProvider(null, .{ .openai = true, .elevenlabs = true }));
    try std.testing.expectEqual(TtsProvider.elevenlabs, pickProvider(null, .{ .elevenlabs = true }));
    try std.testing.expectEqual(TtsProvider.system, pickProvider(null, .{}));
    try std.testing.expectEqual(TtsProvider.deepgram, pickProvider("deepgramm", .{ .deepgram = true }));
}

test "deepgramModel: a short voice name becomes an Aura-2 model, and nothing else reaches the URL" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("aura-2-thalia-en", try deepgramModel(&buf, "thalia"));
    try std.testing.expectEqualStrings("aura-2-draco-en", try deepgramModel(&buf, "aura-2-draco-en"));
    try std.testing.expectError(error.BadVoiceName, deepgramModel(&buf, "thalia&encoding=wav"));
    try std.testing.expectError(error.BadVoiceName, deepgramModel(&buf, ""));
}

test "openaiBody: quotes and newlines in the text stay text, and speed is only ever a number" {
    const alloc = std.testing.allocator;
    const body = try openaiBody(alloc, "She said \"hi\"\nthen left.", "nova", "1.0,\"model\":\"x\"");
    defer alloc.free(body);
    const Body = struct { model: []const u8, input: []const u8, voice: []const u8, speed: f64 };
    const parsed = try std.json.parseFromSlice(Body, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tts-1", parsed.value.model);
    try std.testing.expectEqualStrings("She said \"hi\"\nthen left.", parsed.value.input);
    try std.testing.expectEqual(@as(f64, 1.0), parsed.value.speed);
}

test "piperArgv: the text is one argument after --, never a shell command" {
    var buf: [7][]const u8 = undefined;
    const text = "- hi; rm -rf ~ $(id) `id`";
    const argv = piperArgv(&buf, "en_US-lessac-medium", "out.wav", text);
    try std.testing.expectEqualStrings("piper", argv[0]);
    try std.testing.expectEqualStrings("--", argv[argv.len - 2]);
    try std.testing.expectEqualStrings(text, argv[argv.len - 1]);
}

test "spokenText: markdown marks dropped, and a long reply cut where a sentence ends" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("Done. The file is ready.", spokenText(&buf, "**Done.** The `file` is ready."));
    try std.testing.expectEqualStrings("First sentence here.", spokenText(&buf, "First sentence here. Second one is long enough to overflow."));
}

test "playerArgv: afplay on macOS, elsewhere ffplay with no window that exits when done" {
    var buf: [6][]const u8 = undefined;
    const mac = playerArgv(&buf, .macos, "a.mp3");
    try std.testing.expectEqual(@as(usize, 2), mac.len);
    try std.testing.expectEqualStrings("afplay", mac[0]);
    const win = playerArgv(&buf, .windows, "a.mp3");
    try std.testing.expectEqualStrings("ffplay", win[0]);
    try std.testing.expectEqualStrings("-nodisp", win[1]);
    try std.testing.expectEqualStrings("-autoexit", win[2]);
    try std.testing.expectEqualStrings("a.mp3", win[win.len - 1]);
}
