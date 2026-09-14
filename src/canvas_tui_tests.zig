//! Test root for src/canvas/tui.zig.
//!
//! Rooting a test artifact AT canvas/tui.zig does not work: a module's import
//! path is bounded by its root file's directory, and tui.zig reaches sibling
//! code with @import("../api/sse.zig"), which escapes src/canvas/. That is
//!   src/canvas/tui.zig:53:21: error: import of file outside module path
//!
//! Rooting here puts the boundary at src/, so both tui.zig and the api/ it
//! imports are inside it. The file exists only to pull tui.zig's tests in;
//! `_ = @import(...)` references the file, which is what makes the test runner
//! collect the tests declared in it.

test {
    _ = @import("canvas/tui.zig");
}
