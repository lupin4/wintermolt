// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/web/server.zig, the --web server: who may open the
// socket, and the page and socket over a real connection. A module rooted
// inside src/web/ cannot import ../fsio.zig, so the root sits here and pulls
// the file's tests in: a test block referencing an import is what makes Zig
// collect them.

test {
    _ = @import("web/server.zig");
}
