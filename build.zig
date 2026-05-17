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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------
    // WINTERMOLT EXECUTABLE
    // -------------------------------------------------------------------
    // Links:
    //   - All Zig source (API client, agent loop, tools, bridges, MCP)
    //   - libcurl (system — HTTPS)
    //   - sqlite3 (system — persistent history)
    //
    // NO Fortran archives. NO forKernels compute libs.
    // forAgent and forLearn are linked as prebuilt .a archives (pure Zig, no Fortran).

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- forAgent + forLearn: built from sibling repos.
    // The 2026-05-16 decree made winX86/linX86/thor/macos the canonical
    // delivery dirs, but older builds still publish at the Zig triple-style
    // {arch-os-abi}. Try canonical first, then fall back. Names are
    // probed in both Unix (libfoo.a) and Zig-native Windows (foo.lib) form.
    const target_name = getTargetName(target.result);
    addSiblingArchive(exe_mod, b, "forAgent", "libforagent.a", target_name);
    addSiblingArchive(exe_mod, b, "forLearn", "libforlearn.a", target_name);

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

/// Try sibling delivery paths in canonical-first order. Probes both Unix
/// (libfoo.a) and Zig-native Windows (foo.lib) naming.
fn addSiblingArchive(mod: *std.Build.Module, b: *std.Build, sibling: []const u8, name: []const u8, target_name: []const u8) void {
    const delivery_dirs = [_][]const u8{ target_name, "winX86", "linX86", "thor", "macos", "windows-x86_64", "linux-x86_64" };
    const win_name: ?[]const u8 = blk: {
        if (!std.mem.startsWith(u8, name, "lib")) break :blk null;
        if (!std.mem.endsWith(u8, name, ".a")) break :blk null;
        const base = name[3 .. name.len - 2];
        break :blk b.fmt("{s}.lib", .{base});
    };
    for (delivery_dirs) |od| {
        const p = b.fmt("../{s}/zig-out/{s}/lib/{s}", .{ sibling, od, name });
        if (std.fs.cwd().access(p, .{})) |_| {
            mod.addObjectFile(.{ .cwd_relative = p });
            return;
        } else |_| {}
        if (win_name) |wn| {
            const pw = b.fmt("../{s}/zig-out/{s}/lib/{s}", .{ sibling, od, wn });
            if (std.fs.cwd().access(pw, .{})) |_| {
                mod.addObjectFile(.{ .cwd_relative = pw });
                return;
            } else |_| {}
        }
    }
    std.log.warn("archive not found: {s}/{s} (build the source repo first)", .{ sibling, name });
}

fn getTargetName(t: std.Target) []const u8 {
    return switch (t.os.tag) {
        .macos => switch (t.cpu.arch) {
            .aarch64 => "macos-arm64",
            else => "macos-unknown",
        },
        .linux => switch (t.cpu.arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-arm64",
            else => "linux-unknown",
        },
        .windows => switch (t.cpu.arch) {
            // Per 2026-05-16 delivery-dir decree: canonical Windows delivery
            // is "winX86" (matches sibling repos' zig-out/{delivery}/lib/).
            .x86_64 => "winX86",
            else => "windows-unknown",
        },
        else => "unknown",
    };
}
