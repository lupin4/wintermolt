const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zortui = b.addModule("zortui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The conformance suite replays fixtures generated from hqtui's TypeScript
    // reference implementation. They are vendored under conformance/fixtures so
    // the tests run from a plain checkout of this repository; passing the path
    // as a build option keeps the tests free of assumptions about the working
    // directory.
    const options = b.addOptions();
    options.addOptionPath("fixtures", b.path("conformance/fixtures"));
    const fixture_options = options.createModule();

    const tests = b.addTest(.{ .root_module = zortui });
    tests.root_module.addImport("build_options", fixture_options);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the conformance suite and example regression tests");
    test_step.dependOn(&run_tests.step);

    // Examples are separate executables, so `zig build run-screenshot` works
    // without a TTY while `run-dashboard-mini` takes one over.
    for ([_][]const u8{ "hello", "dashboard", "screenshot", "widgets", "collapse", "justify_parity", "world-probe" }) |name| {
        const command_name = if (std.mem.eql(u8, name, "dashboard")) "dashboard-mini" else name;
        const exe = b.addExecutable(.{
            .name = command_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zortui", .module = zortui }},
            }),
        });
        b.installArtifact(exe);
        if (std.mem.eql(u8, name, "dashboard")) {
            const dashboard_tests = b.addTest(.{ .root_module = exe.root_module });
            const run_dashboard_tests = b.addRunArtifact(dashboard_tests);
            test_step.dependOn(&run_dashboard_tests.step);
        }
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(
            b.fmt("run-{s}", .{command_name}),
            b.fmt("Run the {s} example", .{name}),
        ).dependOn(&run.step);
    }
}
