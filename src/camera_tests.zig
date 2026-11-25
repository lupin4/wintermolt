// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/tools/camera.zig. A module rooted inside src/tools/
// cannot import ../fsio.zig, so the root sits here and pulls the file's tests
// in: a test block referencing an import is what makes Zig collect them.

test {
    _ = @import("tools/camera.zig");
}
