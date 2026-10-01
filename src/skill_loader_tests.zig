// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/agent/skill_loader.zig. A module rooted inside src/agent/
// cannot import ../fsio.zig, so the root sits here and pulls the file's tests
// in: a test block referencing an import is what makes Zig collect them.

test {
    _ = @import("agent/skill_loader.zig");
}
