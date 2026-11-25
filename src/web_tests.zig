// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for the two HTTP servers: src/web/server.zig (--web: who may open
// the socket, the page and socket over a real connection) and
// src/gateway/server.zig (--gateway: the API key, OpenAI's request and reply
// shapes, streaming). A module rooted inside src/web/ cannot import
// ../fsio.zig, so the root sits here and pulls the files' tests in: a test
// block referencing an import is what makes Zig collect them.

test {
    _ = @import("web/server.zig");
    _ = @import("gateway/server.zig");
}
