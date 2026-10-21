# Vendored: zortui

- Upstream: https://github.com/lupin4/zortui
- Commit: `8f6df19efd291fa97b22545f623539c6b75220d0` (8f6df19, "zortui: a
  palette index stays a palette index at truecolor depth"), v0.1.0 plus the
  clock hook (9261fe1), the Quick Edit fix (c47945c) and that fix. wintermolt's
  "terminal" theme is built from palette indices, which is what found it.
  Previously c47945c, before that 9261fe1, before that f601d1e.
- Copied with `git archive 8f6df19 build.zig build.zig.zon src LICENSE NOTICE README.md`.
- wintermolt sets the hook: `src/tui.zig` `appOptions` takes the clock, and
  `src/main.zig` passes `fsio.monoNs` (forTime's `ftim_mono_ns`).
- License: MIT (derived from hqtui, MIT). `LICENSE` and `NOTICE` are carried
  unchanged. Compatible with wintermolt's MIT license.

## What is here and what is not

`src/` is copied whole and **unmodified**. Do not edit or rename anything in
this directory. Some `hqtui` string literals are deliberate: zortui's
conformance fixtures match them.

Left out: `conformance/` (the hqtui fixture corpus) and `examples/`. The build
does not need them. `build.zig` and `build.zig.zon` are kept verbatim as a
record of the upstream package, but they still point at those directories, so
run zortui's own `zig build test` from an upstream checkout, not from here.

wintermolt does not run this directory's `build.zig`. Its own `build.zig`
imports `src/root.zig` as the module `zortui`. There is no network package
dependency.

## Updating

Replace `src/`, `LICENSE`, `NOTICE`, `README.md`, `build.zig` and
`build.zig.zon` with the files from the new upstream commit, then update the
commit above.
