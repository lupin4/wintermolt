// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for src/api/curl_timeouts.zig. A module rooted inside src/api/
// cannot import ../compat.zig, so the root sits here and pulls the file's
// tests in: a test block referencing an import is what makes Zig collect them.

test {
    _ = @import("api/curl_timeouts.zig");
}
