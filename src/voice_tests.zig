// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/agent/tts.zig and src/agent/stt.zig, here in src/ so both
// can reach fsio.zig and camera.zig: a test block referencing an import is
// what makes Zig collect its tests.

test {
    _ = @import("agent/tts.zig");
    _ = @import("agent/stt.zig");
}
