// Copyright The Fantastic Planet - By David Clabaugh
//
// Wintermolt build.zig — Lite AI assistant binary
//
// Targets:
//   zig build          → zig-out/bin/wintermolt (main binary)
//   zig build run      → build and run wintermolt
//
// Wintermolt is the Apache-2.0 lite version of Wintermute. No forKernels,
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast (org optimize policy): wintermolt links ZERO forKernels archives at
    // build time, so there is no Fortran under this layer — the compute IS the Zig
    // and safety checks sit on the hot path rather than off it.
    //
    // NOT a bare standardOptimizeOption(.{}): that defaults to Debug, which
    // materializes `undefined` as real bytes and once shipped a 68MB archive.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (delivery default: ReleaseFast)",
    ) orelse .ReleaseFast;

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
    for ([_][]const u8{ "foragent", "forlearn", "formcp", "forai", "fornlp" }) |dep| {
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
    }

    // --- GPU kernels: forMetal on macOS, forCUDA everywhere else ---
    // forMetal is the macOS-only exception (decision 2026-06-04); its
    // fmet_kernels.metallib is a runtime resource (renamed from fm_kernels.metallib in forMetal v1.2) shipped beside the binary.
    if (t.os.tag == .macos) {
        addPrebuiltArchive(exe_mod, b, "formetal", short_target);
        if (b.build_root.handle.access("prebuilt/macos/lib/fmet_kernels.metallib", .{})) |_| {
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
        if (b.build_root.handle.access(llama_path, .{})) |_| {
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
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Build and run Wintermolt");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // Test step: `zig build test`
    // -------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
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
        if (b.build_root.handle.access(p, .{})) |_| {
            mod.addObjectFile(b.path(p));
            return;
        } else |_| {}
    }
    std.debug.print("[build] {s} not found — run scripts/sync-prebuilts.sh (feature stubs out)\n", .{candidates[0]});
}
