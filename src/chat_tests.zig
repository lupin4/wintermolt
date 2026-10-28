// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/chat/: the access policy and pairing store (access.zig)
// and the sidecar line parser (bridge.zig). A module rooted inside src/chat/
// cannot import ../compat.zig, so the root sits here and pulls the files'
// tests in: a test block referencing an import is what makes Zig collect them.

test {
    _ = @import("chat/access.zig");
    _ = @import("chat/bridge.zig");
}
