// forlearn.zig — Zig interface for forLearn library
// Copyright (C) The Fantastic Planet 2025 - By David Clabaugh
//
// Provides:
//   1. Safe Zig wrappers around Fortran C-API learning kernels
//   2. Harness generation — scaffolds forAgent adapter projects for new software
//
// The harness generator lets Wintermute create persistent connections to
// any software by generating forAgent boilerplate (build.zig, adapter, tools).

const std = @import("std");

// =========================================================================
// Fortran C-API extern declarations
// =========================================================================

// Opaque handles (void* in C)
const OpaqueHandle = ?*anyopaque;

extern fn forlearn_init_buffer(buf: *OpaqueHandle, max_size: c_int, feature_dim: c_int) void;
extern fn forlearn_add_sample(buf: OpaqueHandle, sample: [*]const f32, dim: c_int) void;

extern fn forlearn_init_hebbian(net: *OpaqueHandle, input_dim: c_int, output_dim: c_int, lr: f32, decay: f32) void;
extern fn forlearn_hebbian_train(net: OpaqueHandle, input: [*]const f32, output: [*]const f32, dim_in: c_int, dim_out: c_int) void;

extern fn forlearn_init_kmeans(model: *OpaqueHandle, n_clusters: c_int, feature_dim: c_int, lr: f32) void;
extern fn forlearn_kmeans_update(model: OpaqueHandle, sample: [*]const f32, dim: c_int) void;
extern fn forlearn_kmeans_predict(model: OpaqueHandle, sample: [*]const f32, dim: c_int) c_int;

extern fn forlearn_init_som(net: *OpaqueHandle, width: c_int, height: c_int, feature_dim: c_int, lr: f32, radius: f32) void;
extern fn forlearn_som_train(net: OpaqueHandle, sample: [*]const f32, dim: c_int) void;

extern fn forlearn_init_anomaly_detector(det: *OpaqueHandle, feature_dim: c_int, threshold: f32) void;
extern fn forlearn_update_detector(det: OpaqueHandle, sample: [*]const f32, dim: c_int) void;
extern fn forlearn_detect_anomaly(det: OpaqueHandle, sample: [*]const f32, dim: c_int) c_int;

extern fn forlearn_init_predictor(pred: *OpaqueHandle, window: c_int, feature_dim: c_int, lr: f32) void;
extern fn forlearn_predictor_update(pred: OpaqueHandle, obs: [*]const f32, dim: c_int) void;

extern fn forlearn_init_q_learner(agent: *OpaqueHandle, n_states: c_int, n_actions: c_int, lr: f32, discount: f32, epsilon: f32) void;
extern fn forlearn_q_select_action(agent: OpaqueHandle, state: c_int) c_int;
extern fn forlearn_q_update(agent: OpaqueHandle, state: c_int, action: c_int, reward: f32, next_state: c_int) void;

extern fn forlearn_init_curiosity(module: *OpaqueHandle, feature_dim: c_int, lr: f32, decay: f32) void;
extern fn forlearn_compute_novelty(module: OpaqueHandle, current: [*]const f32, next: [*]const f32, dim: c_int) f32;

// =========================================================================
// Safe Zig wrappers
// =========================================================================

pub const Hebbian = struct {
    handle: OpaqueHandle = null,
    pub fn init(input_dim: u32, output_dim: u32, lr: f32, decay: f32) Hebbian {
        var h = Hebbian{};
        forlearn_init_hebbian(&h.handle, @intCast(input_dim), @intCast(output_dim), lr, decay);
        return h;
    }
    pub fn train(self: *Hebbian, input: []const f32, output: []const f32) void {
        forlearn_hebbian_train(self.handle, input.ptr, output.ptr, @intCast(input.len), @intCast(output.len));
    }
};

pub const KMeans = struct {
    handle: OpaqueHandle = null,
    pub fn init(n_clusters: u32, feature_dim: u32, lr: f32) KMeans {
        var k = KMeans{};
        forlearn_init_kmeans(&k.handle, @intCast(n_clusters), @intCast(feature_dim), lr);
        return k;
    }
    pub fn update(self: *KMeans, sample: []const f32) void {
        forlearn_kmeans_update(self.handle, sample.ptr, @intCast(sample.len));
    }
    pub fn predict(self: *KMeans, sample: []const f32) u32 {
        return @intCast(forlearn_kmeans_predict(self.handle, sample.ptr, @intCast(sample.len)));
    }
};

pub const AnomalyDetector = struct {
    handle: OpaqueHandle = null,
    pub fn init(feature_dim: u32, threshold: f32) AnomalyDetector {
        var d = AnomalyDetector{};
        forlearn_init_anomaly_detector(&d.handle, @intCast(feature_dim), threshold);
        return d;
    }
    pub fn update(self: *AnomalyDetector, sample: []const f32) void {
        forlearn_update_detector(self.handle, sample.ptr, @intCast(sample.len));
    }
    pub fn isAnomaly(self: *AnomalyDetector, sample: []const f32) bool {
        return forlearn_detect_anomaly(self.handle, sample.ptr, @intCast(sample.len)) != 0;
    }
};

pub const QLearner = struct {
    handle: OpaqueHandle = null,
    pub fn init(n_states: u32, n_actions: u32, lr: f32, discount: f32, epsilon: f32) QLearner {
        var q = QLearner{};
        forlearn_init_q_learner(&q.handle, @intCast(n_states), @intCast(n_actions), lr, discount, epsilon);
        return q;
    }
    pub fn selectAction(self: *QLearner, state: u32) u32 {
        return @intCast(forlearn_q_select_action(self.handle, @intCast(state)));
    }
    pub fn update_q(self: *QLearner, state: u32, action: u32, reward: f32, next_state: u32) void {
        forlearn_q_update(self.handle, @intCast(state), @intCast(action), reward, @intCast(next_state));
    }
};

pub const Curiosity = struct {
    handle: OpaqueHandle = null,
    pub fn init(feature_dim: u32, lr: f32, decay: f32) Curiosity {
        var c = Curiosity{};
        forlearn_init_curiosity(&c.handle, @intCast(feature_dim), lr, decay);
        return c;
    }
    pub fn novelty(self: *Curiosity, current: []const f32, next: []const f32) f32 {
        return forlearn_compute_novelty(self.handle, current.ptr, next.ptr, @intCast(current.len));
    }
};

// =========================================================================
// Harness Generator — scaffolds CLI-Anything harness projects
// =========================================================================
//
// Generates a complete CLI-Anything harness for connecting to external software.
// Output: a directory following the CLI-Anything pattern:
//   <name>/agent-harness/
//     setup.py
//     cli_anything/<name>/__init__.py
//     cli_anything/<name>/__main__.py
//     cli_anything/<name>/<name>_cli.py    (Click CLI with --json support)
//     cli_anything/<name>/core/backend.py  (backend connection logic)
//     cli_anything/<name>/skills/SKILL.md  (AI-discoverable metadata)
//
// The generated harness is pip-installable and follows the CLI-Anything
// convention: `cli-anything-<name>` console script, --json flag for
// structured output, Click command groups for tool dispatch.

pub const HarnessConfig = struct {
    name: []const u8, // e.g., "maya", "obs", "docker"
    display_name: []const u8, // e.g., "Maya", "OBS Studio", "Docker"
    description: []const u8, // one-line description
    backend_type: BackendType,
    endpoint: []const u8, // base URL, socket path, or CLI command
    commands: []const CommandSpec,
    prerequisites: []const u8, // e.g., "maya (Autodesk Maya 2024+)"
};

pub const BackendType = enum {
    rest_api, // HTTP REST (requests.get/post)
    cli_subprocess, // shell commands (subprocess.run)
    socket, // TCP/Unix socket
    grpc, // gRPC (grpcio)
};

pub const CommandSpec = struct {
    group: []const u8, // Click group name (e.g., "scene", "render")
    name: []const u8, // command name (e.g., "list", "start")
    description: []const u8,
    params: []const u8, // Click params as Python code fragment
};

/// Generate a complete CLI-Anything harness project at the given output directory.
pub fn generateHarness(alloc: std.mem.Allocator, config: HarnessConfig, output_dir: []const u8) !void {
    // Build directory paths
    const harness_dir = try std.fmt.allocPrint(alloc, "{s}/agent-harness", .{output_dir});
    defer alloc.free(harness_dir);
    const pkg_dir = try std.fmt.allocPrint(alloc, "{s}/cli_anything/{s}", .{ harness_dir, config.name });
    defer alloc.free(pkg_dir);
    const core_dir = try std.fmt.allocPrint(alloc, "{s}/core", .{pkg_dir});
    defer alloc.free(core_dir);
    const skills_dir = try std.fmt.allocPrint(alloc, "{s}/skills", .{pkg_dir});
    defer alloc.free(skills_dir);
    const ns_dir = try std.fmt.allocPrint(alloc, "{s}/cli_anything", .{harness_dir});
    defer alloc.free(ns_dir);

    // Create directories
    std.fs.cwd().makePath(output_dir) catch {};
    std.fs.cwd().makePath(core_dir) catch {};
    std.fs.cwd().makePath(skills_dir) catch {};

    // Generate files
    try writeFile(alloc, harness_dir, "setup.py", try genSetupPy(alloc, config));
    try writeFile(alloc, ns_dir, "__init__.py", try alloc.dupe(u8, ""));
    try writeFile(alloc, pkg_dir, "__init__.py", try alloc.dupe(u8, ""));
    try writeFile(alloc, pkg_dir, "__main__.py", try genMainPy(alloc, config));
    try writeFile(alloc, pkg_dir, try std.fmt.allocPrint(alloc, "{s}_cli.py", .{config.name}), try genCliPy(alloc, config));
    try writeFile(alloc, core_dir, "__init__.py", try alloc.dupe(u8, ""));
    try writeFile(alloc, core_dir, "backend.py", try genBackendPy(alloc, config));
    try writeFile(alloc, skills_dir, "SKILL.md", try genSkillMd(alloc, config));
}

fn writeFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    defer alloc.free(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
    alloc.free(content);
}

fn genSetupPy(alloc: std.mem.Allocator, config: HarnessConfig) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\#!/usr/bin/env python3
        \\"""setup.py for cli-anything-{s} — auto-generated by forLearn"""
        \\from setuptools import setup, find_namespace_packages
        \\
        \\setup(
        \\    name="cli-anything-{s}",
        \\    version="0.1.0",
        \\    description="{s}",
        \\    packages=find_namespace_packages(include=["cli_anything.*"]),
        \\    python_requires=">=3.10",
        \\    install_requires=["click>=8.0", "requests>=2.28"],
        \\    entry_points={{
        \\        "console_scripts": [
        \\            "cli-anything-{s}=cli_anything.{s}.{s}_cli:main",
        \\        ],
        \\    }},
        \\    package_data={{"cli_anything.{s}": ["skills/*.md"]}},
        \\    include_package_data=True,
        \\    zip_safe=False,
        \\)
        \\
    , .{ config.name, config.name, config.description, config.name, config.name, config.name, config.name });
}

fn genMainPy(alloc: std.mem.Allocator, config: HarnessConfig) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\"""Allow running as python3 -m cli_anything.{s}"""
        \\from cli_anything.{s}.{s}_cli import main
        \\main()
        \\
    , .{ config.name, config.name, config.name });
}

fn genCliPy(alloc: std.mem.Allocator, config: HarnessConfig) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.print(
        \\#!/usr/bin/env python3
        \\"""{s} CLI — auto-generated by forLearn harness generator.
        \\
        \\Usage:
        \\    cli-anything-{s} --help
        \\    cli-anything-{s} --json <command>
        \\"""
        \\import sys, json, click
        \\from cli_anything.{s}.core.backend import Backend
        \\
        \\_backend = None
        \\_json_output = False
        \\
        \\def get_backend():
        \\    global _backend
        \\    if _backend is None:
        \\        _backend = Backend("{s}")
        \\    return _backend
        \\
        \\def output(data, message=""):
        \\    if _json_output:
        \\        click.echo(json.dumps(data, indent=2, default=str))
        \\    elif message:
        \\        click.echo(message)
        \\    elif isinstance(data, dict):
        \\        for k, v in data.items():
        \\            click.echo(f"  {{k}}: {{v}}")
        \\    else:
        \\        click.echo(str(data))
        \\
        \\@click.group(invoke_without_command=True)
        \\@click.option("--json", "use_json", is_flag=True, help="JSON output")
        \\@click.pass_context
        \\def cli(ctx, use_json):
        \\    """{s} — CLI-Anything harness"""
        \\    global _json_output
        \\    _json_output = use_json
        \\    if ctx.invoked_subcommand is None:
        \\        click.echo(ctx.get_help())
        \\
    , .{ config.display_name, config.name, config.name, config.name, config.endpoint, config.display_name });

    // Generate command groups and commands
    // Track which groups we've seen
    var last_group: []const u8 = "";
    for (config.commands) |cmd| {
        if (!std.mem.eql(u8, cmd.group, last_group)) {
            // New group
            try w.print(
                \\
                \\@cli.group()
                \\def {s}():
                \\    """{s} commands"""
                \\    pass
                \\
            , .{ cmd.group, cmd.group });
            last_group = cmd.group;
        }
        try w.print(
            \\
            \\@{s}.command()
            \\def {s}():
            \\    """{s}"""
            \\    result = get_backend().call("{s}", "{s}")
            \\    output(result)
            \\
        , .{ cmd.group, cmd.name, cmd.description, cmd.group, cmd.name });
    }

    try w.print(
        \\
        \\def main():
        \\    cli()
        \\
        \\if __name__ == "__main__":
        \\    main()
        \\
    , .{});

    return buf.toOwnedSlice(alloc);
}

fn genBackendPy(alloc: std.mem.Allocator, config: HarnessConfig) ![]const u8 {
    const backend_impl = switch (config.backend_type) {
        .rest_api =>
        \\import requests
        \\
        \\class Backend:
        \\    def __init__(self, endpoint):
        \\        self.base_url = endpoint
        \\
        \\    def call(self, group, command, **kwargs):
        \\        url = f"{self.base_url}/{group}/{command}"
        \\        try:
        \\            resp = requests.post(url, json=kwargs, timeout=30)
        \\            resp.raise_for_status()
        \\            return resp.json()
        \\        except Exception as e:
        \\            return {"error": str(e)}
        ,
        .cli_subprocess =>
        \\import subprocess, json
        \\
        \\class Backend:
        \\    def __init__(self, base_cmd):
        \\        self.base_cmd = base_cmd
        \\
        \\    def call(self, group, command, **kwargs):
        \\        cmd = [self.base_cmd, group, command]
        \\        for k, v in kwargs.items():
        \\            cmd.extend([f"--{k}", str(v)])
        \\        try:
        \\            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        \\            try:
        \\                return json.loads(result.stdout)
        \\            except json.JSONDecodeError:
        \\                return {"stdout": result.stdout, "stderr": result.stderr, "code": result.returncode}
        \\        except Exception as e:
        \\            return {"error": str(e)}
        ,
        .socket =>
        \\import socket, json
        \\
        \\class Backend:
        \\    def __init__(self, endpoint):
        \\        self.endpoint = endpoint
        \\
        \\    def call(self, group, command, **kwargs):
        \\        # TODO: implement socket protocol for target app
        \\        return {"error": "socket backend not yet implemented", "group": group, "command": command}
        ,
        .grpc =>
        \\class Backend:
        \\    def __init__(self, endpoint):
        \\        self.endpoint = endpoint
        \\
        \\    def call(self, group, command, **kwargs):
        \\        # TODO: implement gRPC protocol for target app
        \\        return {"error": "gRPC backend not yet implemented", "group": group, "command": command}
        ,
    };

    return std.fmt.allocPrint(alloc,
        \\"""{s} backend — auto-generated by forLearn"""
        \\{s}
        \\
    , .{ config.display_name, backend_impl });
}

fn genSkillMd(alloc: std.mem.Allocator, config: HarnessConfig) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\---
        \\name: >-
        \\  cli-anything-{s}
        \\description: >-
        \\  {s}
        \\---
        \\
        \\# cli-anything-{s}
        \\
        \\{s}
        \\
        \\## Installation
        \\
        \\```bash
        \\pip install -e .
        \\```
        \\
        \\**Prerequisites:**
        \\- Python 3.10+
        \\- {s}
        \\
        \\## Usage
        \\
        \\```bash
        \\cli-anything-{s} --help
        \\cli-anything-{s} --json <group> <command>
        \\```
        \\
    , .{ config.name, config.description, config.name, config.description, config.prerequisites, config.name, config.name });
}
