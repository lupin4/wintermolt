//! Monotonic time: the one place zortui reads a clock.
//!
//! zortui needs "now" for three things: `Ctx.elapsed`, which animates widgets;
//! `FrameStats.render_ns`; and, on Windows, the deadlines that bound each wait
//! for input. Every one of them calls `nowNs`.
//!
//! By default that is zortui's own clock, so the package links nothing and
//! needs nothing set. An application that already owns time — a runtime with
//! its own monotonic source, a simulation, a test — passes a function as
//! `App.Options.clock` and zortui reads that instead.
//!
//! Durations are not time reads and do not come through here: the `poll`
//! timeout on POSIX, the Escape-key rule (accumulated from those timeouts
//! rather than read off a clock), and the sleeps and waits handed to the
//! kernel.

const std = @import("std");
const builtin = @import("builtin");

/// Monotonic nanoseconds from an arbitrary origin. It must not go backwards,
/// and while an `App` is polling a real terminal it must advance with real
/// time, because the input waits count down against it.
pub const Clock = *const fn () u64;

/// Now: from `hook` when one is set, from zortui's own clock otherwise.
pub fn nowNs(hook: ?Clock) u64 {
    if (hook) |read| return read();
    return systemNs();
}

/// zortui's own clock. Zig 0.16 moved the clock behind an `Io` handle, and
/// threading one through every frame for a timestamp is not worth it, so the
/// syscall is made directly — the two systems spell it identically apart from
/// the return type.
///
/// Windows has no `clock_gettime` without linking libc, which this package
/// does not do, so there it is the performance counter instead.
fn systemNs() u64 {
    if (comptime builtin.os.tag == .windows) return @import("win32.zig").monotonicNs();
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(@max(0, ts.sec));
    const nsec: u64 = @intCast(@max(0, ts.nsec));
    return sec * std.time.ns_per_s + nsec;
}

test "monotonic clock advances" {
    const first = nowNs(null);
    try std.testing.expect(first > 0);
    try std.testing.expect(nowNs(null) >= first);
}

var fake_ns: u64 = 0;

fn fakeClock() u64 {
    return fake_ns;
}

test "a hook replaces zortui's own clock" {
    fake_ns = 42;
    try std.testing.expectEqual(@as(u64, 42), nowNs(fakeClock));
    // Far below anything the system clock reads after boot, so a fallback to
    // it could not produce this.
    fake_ns = 7;
    try std.testing.expectEqual(@as(u64, 7), nowNs(fakeClock));
}
