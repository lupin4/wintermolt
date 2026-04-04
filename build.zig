// Copyright The Fantastic Planet - By David Clabaugh
//
// Wintermolt build.zig — Lite AI assistant binary
//
// Targets:
//   zig build          → zig-out/bin/wintermolt (main binary)
//   zig build run      → build and run wintermolt
//
// Wintermolt is the AGPL-3.0 lite version of Wintermute. No forKernels,
// no Fortran archives, no TPU/fleet/cortex — just the core agentic loop
// with multi-backend AI, tool dispatch, MCP, and skills.
//
// Dependencies:
//   libcurl  → system (HTTPS to Claude API / Ollama / OpenAI-compat)
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
    // NO Fortran archives. NO forKernels. Pure Zig + system libs.

    // --- forLearn: harness generation (scaffolds CLI-Anything projects) ---
    const forlearn_module = b.createModule(.{
        .root_source_file = b.path("lib/forlearn/forlearn.zig"),
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("forlearn", forlearn_module);

    // System libraries — dynamic linking
    exe_mod.linkSystemLibrary("curl", .{});
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "wintermolt",
        .root_module = exe_mod,
    });

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
