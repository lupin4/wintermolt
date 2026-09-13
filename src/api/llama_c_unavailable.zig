// llama_c_unavailable.zig — the `llama_c` module on targets without llama.cpp.
//
// Copyright The Fantastic Planet — By David Clabaugh
//
// Zig 0.17 removed @cImport (0.16's AstGen still has it, 0.17's does not), so
// api/kernel.zig's llama.h bindings now arrive as a translate-c MODULE built in
// build.zig rather than a builtin call inside the file.
//
// That move has one consequence worth stating: `@import("llama_c")` is resolved
// at AstGen, before any comptime branch is evaluated, so the name must resolve
// on EVERY target -- including the ones that have no llama.cpp at all. It
// cannot be put behind `if (is_supported)` the way @cImport was.
//
// So build.zig registers the translate-c module on darwin-arm64 and this file
// everywhere else. It is deliberately EMPTY: every use of `c.<anything>` in
// kernel.zig sits inside an `if (is_supported)` comptime branch, and Zig does
// not analyse the body of a branch it has already folded away. If a reference
// to this module ever does get analysed, the resulting "no member named ..."
// error is the correct outcome -- it means something reached for llama.cpp on a
// target that does not have it, which is a bug to see rather than to paper over.
