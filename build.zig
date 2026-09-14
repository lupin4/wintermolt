// Copyright The Fantastic Planet - By David Clabaugh
//
// Wintermolt build.zig — Lite AI assistant binary
//
// Targets:
//   zig build          → zig-out/bin/wintermolt (main binary)
//   zig build run      → build and run wintermolt
//
// Wintermolt is the MIT lite version of Wintermute. No forKernels,
// no Fortran archives, no TPU/fleet/cortex — just the core agentic loop
// with multi-backend AI, tool dispatch, MCP, and skills.
//
// Dependencies:
//   libcurl  → system (HTTPS to Ollama / Claude API / OpenAI-compat)
//   sqlite3  → system (persistent chat history)
//
// Usage:
//   zig build                              # native (Mac M4)
//   zig build -Dtarget=aarch64-linux-gnu   # cross-compile for Jetson / Pi
//   zig build -Dtarget=x86_64-linux-gnu    # cross-compile for Linux x86_64
//   zig build run                          # build and run interactively
//   ANTHROPIC_API_KEY=sk-ant-... zig build run   # with API key

const std = @import("std");

/// Does `sub_path` exist under the build root? Error union, not bool, so call
/// sites keep their `if (...) |_| ... else |_|` shape.
///
/// `b.build_root.handle` is an `std.fs.Dir` on 0.15.2 and an `std.Io.Dir` on
/// 0.16, and the 0.16 form threads an `Io` through every operation -- so the same
/// `access` call needs two arguments on one toolchain and three on the other.
/// Branch is on `@hasDecl` -- a feature test, not a version number.
fn buildRootHas(b: *std.Build, sub_path: []const u8) !void {
    if (comptime @hasField(std.Build, "build_root")) {
        // 0.15.2 and 0.16 both hang the build-root Dir handle off the Build
        // object; they differ only in whether `access` takes an Io.
        if (comptime @hasDecl(std.fs, "cwd")) {
            return b.build_root.handle.access(sub_path, .{});
        }
        return b.build_root.handle.access(b.graph.io, sub_path, .{});
    }
    // 0.17 removed Build.build_root, and LazyPath lost getPath, so there is no
    // handle to ask any more. The build runner's CWD *is* the build root --
    // verified against 0.17 with a sentinel file, not assumed -- so ask cwd.
    return std.Io.Dir.cwd().access(b.graph.io, sub_path, .{});
}

pub fn build(b: *std.Build) void {
    // RELEASE BINARIES MUST NOT BE HOST-TUNED.
    //
    // standardTargetOptions with no -Dtarget gives Zig the NATIVE target
    // INCLUDING native CPU features, so a plain `zig build` on a machine with
    // wide vector support bakes those instructions into the binary. That is not
    // hypothetical: the published prebuilt/wintermolt-linux-arm64 was built this
    // way on a Jetson Thor and carried 17 SVE instructions (ptrue, movprfx).
    // Generic aarch64 has no SVE, so it SIGILLs on a Raspberry Pi or any older
    // Jetson — and the same mistake put 76k AVX-512 instructions in the Windows
    // release exe.
    //
    // SO: BUILD THE PUBLISHED BINARY WITH AN EXPLICIT CPU FLOOR:
    //
    //     aarch64:  zig build -Doptimize=ReleaseFast -Dcpu=baseline
    //     x86_64:   zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v3
    //
    // THE FLOOR IS PER-ARCH, not one value. `baseline` is the aarch64 answer
    // only because the ARM floor is still undecided — the fleet currently
    // carries four different -mcpu answers (native, cortex-a78, cortex-a78ae,
    // cortex-a72/apple-m1), so baseline is what is safe until the user picks
    // one. On x86 the floor IS decided: x86_64_v3. Building Windows at generic
    // x86-64 would be a needless downgrade, not a safety measure.
    //
    // and verify it before publishing — on aarch64 this must print 0:
    //
    //     objdump -d zig-out/bin/wintermolt \
    //       | grep -cE '\b(ptrue|movprfx|whilelo|ld1d|st1d|cntd)\b'
    //
    // -Dtarget= is the WRONG knob. Naming a target makes Zig treat the build as
    // a CROSS-compile and stop searching native paths, so libcurl and libsqlite3
    // stop resolving. -Dcpu= keeps the native target and only lowers the CPU.
    //
    // A dedicated `release` step was tried and removed: it has to restate the
    // whole link surface (curl, sqlite3, the sibling archives), which then drifts
    // from this one silently. One target declaration, one flag at the command
    // line.
    const target = b.standardTargetOptions(.{});
    // ReleaseFast (org optimize policy): wintermolt links ZERO forKernels archives at
    // build time, so there is no Fortran under this layer — the compute IS the Zig
    // and safety checks sit on the hot path rather than off it.
    //
    // NOT a bare standardOptimizeOption(.{}): that defaults to Debug, which
    // materializes `undefined` as real bytes and once shipped a 68MB archive.
    // 0.17 lower-cased the Optimize enum (ReleaseFast -> fast). Feature-test the
    // field rather than the compiler version, so this build.zig keeps working for
    // agents still on 0.16.
    const release_fast: std.builtin.OptimizeMode =
        if (@hasField(std.builtin.OptimizeMode, "ReleaseFast")) .ReleaseFast else .fast;
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (delivery default: ReleaseFast)",
    ) orelse release_fast;

    // -------------------------------------------------------------------
    // WINTERMOLT EXECUTABLE
    // -------------------------------------------------------------------
    // Links:
    //   - All Zig source (API client, agent loop, tools, bridges, MCP)
    //   - libcurl (system — HTTPS)
    //   - sqlite3 (system — persistent history)
    //
    // Dep kernels (forAgent/forLearn/forMCP/forAI/forNLP + forMetal/forCUDA)
    // are linked as COMMITTED prebuilt archives — no dep source in this repo.

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- Dep kernels: linked from the COMMITTED local prebuilt tree only.
    // scripts/sync-prebuilts.sh copies sibling deliveries into
    // prebuilt/<short>/lib/ (short = macos | thor | linX86 | winX86).
    // The build never reads sibling paths. Unreferenced archive members
    // are not pulled in, so linking deps ahead of their wiring is free.
    const short_target = getShortTargetName(target.result);
    // fortime: the clocks (fsio.zig declares ftim_now_unix_ns / ftim_mono_ns).
    // fornet / forio_core: basic kernels, linked ahead of their wiring.
    for ([_][]const u8{ "foragent", "forlearn", "formcp", "forai", "fornlp", "fortime", "fornet", "forio_core" }) |dep| {
        addPrebuiltArchive(exe_mod, b, dep, short_target);
    }

    // System libraries — dynamic linking
    const t = target.result;

    // On Windows the linker can't find libs without explicit paths. MSYS2
    // UCRT64 is the assumed toolchain (matches Wintermute).
    if (t.os.tag == .windows) {
        exe_mod.addLibraryPath(.{ .cwd_relative = "C:/msys64/ucrt64/lib" });
        exe_mod.addLibraryPath(.{ .cwd_relative = "C:/msys64/ucrt64/lib/gcc/x86_64-w64-mingw32/15.2.0" });
    }

    exe_mod.linkSystemLibrary("curl", .{});
    exe_mod.linkSystemLibrary("sqlite3", .{});

    // Windows / MSYS2: libcurl is built with HTTP/3 (QUIC) and pulls in a
    // long chain of dependencies that must be linked explicitly.
    if (t.os.tag == .windows) {
        const win_deps = [_][]const u8{
            // libcurl HTTP/3 stack
            "nghttp3",       "ngtcp2",   "ngtcp2_crypto_ossl", "nghttp2",
            // TLS + crypto
            "ssl",           "crypto",
            // compression
            "zstd",          "brotlidec", "brotlicommon",      "z",
            // libcurl misc deps
            "idn2",          "psl",       "ssh2",
            // libidn2/libpsl deps
            "unistring",     "iconv",
            // Windows system
            "ws2_32",        "wldap32",   "crypt32",            "bcrypt",
            "normaliz",      "iphlpapi",  "advapi32",           "secur32",
        };
        for (win_deps) |lib| exe_mod.linkSystemLibrary(lib, .{});
        // MSYS2's static OpenSSL was compiled against mingw headers that declare
        // _vsnwprintf as a DLL import. Zig 0.16's bundled mingw CRT has no import
        // for it -- only a static copy in libmingw32 that lld refuses for a
        // __declspec(dllimport) reference -- so the link failed on
        // OPENSSL_showfatal. MSYS2's own ucrtbase import library supplies it.
        // Archive members load lazily: only still-unresolved imports come from here.
        exe_mod.addObjectFile(.{ .cwd_relative = "C:/msys64/ucrt64/lib/libucrtbase.a" });
    }

    // --- GPU kernels: forMetal on macOS, forCUDA everywhere else ---
    // forMetal is the macOS-only exception (decision 2026-06-04); its
    // fmet_kernels.metallib is a runtime resource (renamed from fm_kernels.metallib in forMetal v1.2) shipped beside the binary.
    if (t.os.tag == .macos) {
        addPrebuiltArchive(exe_mod, b, "formetal", short_target);
        if (buildRootHas(b, "prebuilt/macos/lib/fmet_kernels.metallib")) |_| {
            b.installBinFile("prebuilt/macos/lib/fmet_kernels.metallib", "fmet_kernels.metallib");
        } else |_| {}
    } else {
        addPrebuiltArchive(exe_mod, b, "forcuda", short_target);
    }

    // --- Kernel backend (llama.cpp + Metal): darwin-arm64 only ---
    // libllama.a is built once via scripts/build-llama-cpp-macos.sh and
    // checked into prebuilt/macos/lib/. ggml's Metal shaders are
    // embedded into the archive via GGML_METAL_EMBED_LIBRARY=1 so we
    // ship a single static archive, no separate .metallib at runtime.
    if (t.os.tag == .macos and t.cpu.arch == .aarch64) {
        const llama_path = "prebuilt/macos/lib/libllama.a";
        if (buildRootHas(b, llama_path)) |_| {
            exe_mod.addObjectFile(b.path(llama_path));
            exe_mod.addIncludePath(b.path("prebuilt/macos/include_kernel"));
            exe_mod.linkFramework("Metal", .{});
            exe_mod.linkFramework("MetalKit", .{});
            exe_mod.linkFramework("Foundation", .{});
            exe_mod.linkFramework("Accelerate", .{});
            exe_mod.linkSystemLibrary("c++", .{});
        } else |_| {
            std.debug.print(
                "[build] {s} not found — kernel backend will return KernelBackendUnavailable.\n" ++
                    "        Run scripts/build-llama-cpp-macos.sh to build it.\n",
                .{llama_path},
            );
        }
    }

    // --- llama.cpp C ABI as a MODULE, not @cImport ---
    // 0.17 removed @cImport outright (0.16's AstGen references it, 0.17's does
    // not), so llama.h is translated by a build step instead of a builtin call
    // inside api/kernel.zig. addTranslateC exists identically on 0.16 and 0.17,
    // so this single form serves both and needs no feature test.
    //
    // Registered on EVERY target on purpose: `@import("llama_c")` resolves at
    // AstGen, before comptime folding, so the name has to exist even where
    // llama.cpp does not. Off darwin-arm64 it resolves to an empty stub, which
    // is what kernel.zig's `is_supported == false` branches already assume.
    // The header is checked for PRESENCE, not just for the right target. As of
    // ae15b2f the prebuilt artifacts are untracked from main, so a fresh clone
    // has neither libllama.a nor these headers -- and addTranslateC on a missing
    // file fails at CONFIGURE time, before the archive check below ever runs.
    // Degrade to the stub instead, matching how the missing archive already
    // degrades to KernelBackendUnavailable.
    const have_llama_header = t.os.tag == .macos and t.cpu.arch == .aarch64 and
        if (buildRootHas(b, "prebuilt/macos/include_kernel/llama.h")) |_| true else |_| false;
    const llama_c_mod = if (have_llama_header) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("prebuilt/macos/include_kernel/llama.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tc.addIncludePath(b.path("prebuilt/macos/include_kernel"));
        break :blk tc.createModule();
    } else b.createModule(.{
        .root_source_file = b.path("src/api/llama_c_unavailable.zig"),
    });
    exe_mod.addImport("llama_c", llama_c_mod);

    // --- zortui: the full-screen TUI (src/tui.zig) ---
    // A plain vendored copy (vendor/zortui, see VENDORED.md) imported as a
    // module -- not a package fetched over the network. zortui needs Zig 0.16,
    // which wintermolt already does: main takes a std.process.Init, and 0.15.2
    // has no such type.
    const zortui_mod = b.createModule(.{
        .root_source_file = b.path("vendor/zortui/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zortui", zortui_mod);

    const exe = b.addExecutable(.{
        .name = "wintermolt",
        .root_module = exe_mod,
    });

    // Let LLD warnings (e.g. LNK4217 locally-defined-symbol-imported) pass
    // through without aborting the build. Zig 0.15.2 otherwise treats any
    // LLD stderr as a hard failure.
    exe.allow_so_scripts = true;

    b.installArtifact(exe);

    // -------------------------------------------------------------------
    // Run step: `zig build run -- [args]`
    // -------------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // 0.17 removed Build.args -- the `zig build run -- <args>` passthrough -- and
    // ships no replacement accessor on Build or Step.Run. Feature-test it: the
    // passthrough still works on 0.15.2/0.16, and on 0.17 `zig build run` simply
    // takes no trailing args. Invoking the installed binary directly is
    // unaffected, which is how wintermolt is actually run.
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const run_step = b.step("run", "Build and run Wintermolt");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // Test step: `zig build test`
    // -------------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Same module the exe gets: without it `@import("llama_c")` fails to resolve
    // under `zig build test`. NOTE: this test module still links none of the
    // prebuilt archives, so `zig build test` remains narrower than it looks --
    // a pre-existing gap, flagged not silently widened.
    test_mod.addImport("llama_c", llama_c_mod);
    test_mod.addImport("zortui", zortui_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // The TUI, headless: zortui's testing module renders to cells, so these run
    // without a terminal and with a fake agent instead of a model. Its own
    // binary, for the reason the compat files below have theirs. Also runnable
    // alone as `zig build test-tui`.
    const tui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zortui", .module = zortui_mod }},
        }),
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);
    test_step.dependOn(&run_tui_tests.step);
    b.step("test-tui", "Run the headless TUI tests").dependOn(&run_tui_tests.step);

    // The 0.16 compatibility layer is tested per FILE.
    //
    // addTest rooted at main.zig does not collect the tests in every
    // transitively imported file: with fsio.zig carrying four tests, this step
    // still reported "18/18 passed" and ran none of them. The two regressions
    // at the bottom of fsio.zig -- spawn against a failing allocator, and
    // kill-then-wait aborting -- are exactly the kind that compile clean and
    // only fail when run, so a summary that skips them is worse than no
    // summary.
    //
    // libc because these call getrandom, lseek, read and clock_gettime.
    for ([_][]const u8{
        "src/fsio.zig",
        "src/stdio.zig",
        "src/compat.zig",
    }) |compat_path| {
        const compat_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(compat_path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(compat_test).step);
    }

    // The A2UI renderer, separately because it needs the zortui import that the
    // loop above deliberately does not give anything. Same reason as the loop:
    // its tests assert on RENDERED output — that a row stays on one line, that
    // a table prints its cells, that a wide-character title does not shift the
    // border — and none of that is observable from a build that only compiles.
    const tui_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/canvas_tui_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tui_test.root_module.addImport("zortui", zortui_mod);
    test_step.dependOn(&b.addRunArtifact(tui_test).step);
}

fn getShortTargetName(t: std.Target) []const u8 {
    return switch (t.os.tag) {
        .macos => "macos",
        .linux => switch (t.cpu.arch) {
            .aarch64 => "thor",
            else => "linX86",
        },
        .windows => "winX86",
        else => "unknown",
    };
}

/// Link a committed prebuilt archive from prebuilt/<short>/lib/.
/// Probes Unix (libfoo.a) then Zig-native Windows (foo.lib) naming.
/// Missing archive ⇒ notice + the feature stubs out — public clones and
/// not-yet-delivered targets must never hard-fail.
fn addPrebuiltArchive(mod: *std.Build.Module, b: *std.Build, name: []const u8, short: []const u8) void {
    const candidates = [_][]const u8{
        b.fmt("prebuilt/{s}/lib/lib{s}.a", .{ short, name }),
        b.fmt("prebuilt/{s}/lib/{s}.lib", .{ short, name }),
    };
    for (candidates) |p| {
        if (buildRootHas(b, p)) |_| {
            mod.addObjectFile(b.path(p));
            return;
        } else |_| {}
    }
    std.debug.print("[build] {s} not found — run scripts/sync-prebuilts.sh (feature stubs out)\n", .{candidates[0]});
}
