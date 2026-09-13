// stdio.zig — unbuffered stdout/stderr/stdin for the 0.15.2 / 0.16 seam.
//
// WINTERMOLT'S OWN COPY. Same author; wintermolt is public OSS and deliberately
// references no forKernels source and no sibling paths, so it carries its own.
// Like any console shim this is comptime wrappers over std -- there is no object
// file to ship and therefore no archive to link, which is why owning a copy is
// the boundary here rather than a dependency.
//
// Copyright The Fantastic Planet — By David Clabaugh
//
// WHY THIS EXISTS
// ---------------
// Wintermute wrote to the console through `std.fs.File.stderr().deprecatedWriter()`
// in 186 places and the stdout twin in 14 more. Zig 0.16 removed both halves:
// std.fs no longer has `File`, and the writer it returned is gone.
//
// The 0.16 replacement is File.writer(io, buffer) -- an explicit Io AND a
// caller-owned buffer. Adopting that shape directly would mean threading an Io
// through sixty files and taking on flush discipline at every exit path, and
// getting that wrong loses the last lines of output on a crash, which is
// precisely when they matter most.
//
// So this reproduces what deprecatedWriter ACTUALLY DID -- an unbuffered write
// straight to the fd -- rather than what 0.16 offers instead. Same observable
// behaviour as before the port, no Io, no flush, nothing pending at exit.
//
// HOW THE UNBUFFERED PART IS ACHIEVED, because it looks like a trick and is
// not: std.Io.Writer only calls its vtable's `drain` when bytes do not fit in
// `buffer`. Give it a ZERO-LENGTH buffer and nothing ever fits, so every
// print/writeAll/writeByte reaches the fd immediately. That is a documented
// property of the interface, not a loophole -- and it means `flush` is a no-op
// by construction rather than by remembering to call it.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const Error = error{WriteFailed};

/// Raw file descriptor. On Windows this is a std.fs.File, which still exists
/// on 0.15.2 and whose 0.16 port is winX86's to make on hardware that can test
/// it.
const Fd = if (is_windows) std.fs.File else c_int;

const STDIN: c_int = 0;
const STDOUT: c_int = 1;
const STDERR: c_int = 2;

/// write(2) until every byte is gone.
///
/// Loops because a single write may return a SHORT count -- on a pipe whose
/// reader is slow, which is exactly what `wintermute | less` is -- and
/// truncating a log line on backpressure is a silent failure. EINTR restarts.
fn writeAllFd(fd: c_int, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return Error.WriteFailed;
        }
        if (n == 0) return Error.WriteFailed; // no progress
        off += @intCast(n);
    }
}

/// std.Io.Writer over a bare fd. Lives on the caller's stack for the duration
/// of one print(); `@fieldParentPtr` in drain only needs the Writer to be
/// embedded in it, not to outlive the call.
const FdSink = struct {
    fd: c_int,
    writer: std.Io.Writer,

    fn init(fd: c_int) FdSink {
        return .{
            .fd = fd,
            // Zero-length buffer: see the header. Every byte goes to drain.
            .writer = .{ .vtable = &.{ .drain = FdSink.drain }, .buffer = &.{} },
        };
    }

    /// The contract, which is easy to get subtly wrong: `w.buffer[0..w.end]`
    /// is written FIRST, then each slice of `data` in order, and the LAST
    /// element of `data` is a pattern repeated `splat` times. The return value
    /// counts only the bytes taken from `data` -- the buffer is not included,
    /// and reporting it is how a drain silently double-counts.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdSink = @alignCast(@fieldParentPtr("writer", w));

        try writeAllFd(self.fd, w.buffer[0..w.end]);
        w.end = 0;

        var written: usize = 0;
        const head = data[0 .. data.len - 1];
        for (head) |bytes| {
            try writeAllFd(self.fd, bytes);
            written += bytes.len;
        }

        const pattern = data[data.len - 1];
        if (pattern.len != 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) try writeAllFd(self.fd, pattern);
        }
        written += pattern.len * splat;

        return written;
    }
};

/// An unbuffered console writer. Copyable and stateless beyond its fd, so the
/// `const stderr = stdio.stderr();` idiom at every call site keeps working
/// exactly as it did with deprecatedWriter().
pub const FileWriter = struct {
    fd: Fd,

    pub fn writeAll(self: FileWriter, bytes: []const u8) Error!void {
        if (comptime is_windows) {
            self.fd.writeAll(bytes) catch return Error.WriteFailed;
            return;
        }
        return writeAllFd(self.fd, bytes);
    }

    pub fn writeByte(self: FileWriter, byte: u8) Error!void {
        return self.writeAll(&[_]u8{byte});
    }

    pub fn print(self: FileWriter, comptime fmt: []const u8, args: anytype) Error!void {
        if (comptime is_windows) {
            self.fd.deprecatedWriter().print(fmt, args) catch return Error.WriteFailed;
            return;
        }
        var sink = FdSink.init(self.fd);
        sink.writer.print(fmt, args) catch return Error.WriteFailed;
        // No flush: the zero-length buffer means nothing was ever held back.
        return;
    }

    /// Present because one call site reads from the stdin handle.
    pub fn read(self: FileWriter, buffer: []u8) Error!usize {
        if (comptime is_windows) {
            return self.fd.read(buffer) catch Error.WriteFailed;
        }
        const n = std.c.read(self.fd, buffer.ptr, buffer.len);
        if (n < 0) return Error.WriteFailed;
        return @intCast(n);
    }
};

/// Buffered line reader over a bare fd.
///
/// Buffered, and therefore requires `var` at the call site where
/// deprecatedReader() allowed `const`. That is not gratuitous: one call site
/// reads an entire MCP tool result -- a fetched page, a Playwright snapshot --
/// and an unbuffered reader would make that one read(2) PER BYTE. The five
/// affected declarations changed from const to var.
pub const FileReader = struct {
    fd: c_int,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub const ReadError = error{ EndOfStream, StreamTooLong, ReadFailed, OutOfMemory };

    /// Refill when empty. Returns false at EOF.
    fn fill(self: *FileReader) ReadError!bool {
        if (self.start < self.end) return true;
        self.start = 0;
        self.end = 0;
        while (true) {
            const n = std.c.read(self.fd, &self.buf, self.buf.len);
            if (n < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                return ReadError.ReadFailed;
            }
            if (n == 0) return false;
            self.end = @intCast(n);
            return true;
        }
    }

    pub fn read(self: *FileReader, out: []u8) ReadError!usize {
        if (!try self.fill()) return 0;
        const n = @min(out.len, self.end - self.start);
        @memcpy(out[0..n], self.buf[self.start..][0..n]);
        self.start += n;
        return n;
    }

    /// Read up to `delim`, which is CONSUMED but not returned -- matching
    /// std's readUntilDelimiter, so call sites need no change in handling.
    pub fn readUntilDelimiter(self: *FileReader, out: []u8, delim: u8) ReadError![]u8 {
        var n: usize = 0;
        while (true) {
            if (!try self.fill()) {
                // EOF with nothing buffered is EndOfStream; EOF after partial
                // input returns what arrived, so a final unterminated line is
                // not silently dropped.
                if (n == 0) return ReadError.EndOfStream;
                return out[0..n];
            }
            const chunk = self.buf[self.start..self.end];
            if (std.mem.indexOfScalar(u8, chunk, delim)) |i| {
                if (n + i > out.len) return ReadError.StreamTooLong;
                @memcpy(out[n..][0..i], chunk[0..i]);
                self.start += i + 1; // consume the delimiter
                return out[0 .. n + i];
            }
            if (n + chunk.len > out.len) return ReadError.StreamTooLong;
            @memcpy(out[n..][0..chunk.len], chunk);
            n += chunk.len;
            self.start = self.end;
        }
    }

    pub fn readUntilDelimiterAlloc(
        self: *FileReader,
        alloc: std.mem.Allocator,
        delim: u8,
        max_size: usize,
    ) ReadError![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(alloc);
        while (true) {
            if (!try self.fill()) {
                if (list.items.len == 0) return ReadError.EndOfStream;
                return list.toOwnedSlice(alloc) catch ReadError.OutOfMemory;
            }
            const chunk = self.buf[self.start..self.end];
            if (std.mem.indexOfScalar(u8, chunk, delim)) |i| {
                if (list.items.len + i > max_size) return ReadError.StreamTooLong;
                list.appendSlice(alloc, chunk[0..i]) catch return ReadError.OutOfMemory;
                self.start += i + 1;
                return list.toOwnedSlice(alloc) catch ReadError.OutOfMemory;
            }
            if (list.items.len + chunk.len > max_size) return ReadError.StreamTooLong;
            list.appendSlice(alloc, chunk) catch return ReadError.OutOfMemory;
            self.start = self.end;
        }
    }
};

/// A writer over an already-open File -- a child process pipe, typically.
/// `handle` is std.posix.fd_t on BOTH toolchains (std.fs.File and std.Io.File
/// agree on it), so one fd path serves process stdio and child pipes alike.
pub fn writerFor(file: File) FileWriter {
    return .{ .fd = if (comptime is_windows) file else file.handle };
}

pub fn readerFor(file: File) FileReader {
    return .{ .fd = if (comptime is_windows) @panic("readerFor: windows unported") else file.handle };
}

pub fn stdout() FileWriter {
    return .{ .fd = if (comptime is_windows) std.fs.File.stdout() else STDOUT };
}

pub fn stderr() FileWriter {
    return .{ .fd = if (comptime is_windows) std.fs.File.stderr() else STDERR };
}

/// A buffered reader on the process stdin.
///
/// Returns BY VALUE, so the caller must bind it with `var` and pass a POINTER
/// onward. Passing a FileReader by value copies its buffer, which silently
/// strands any bytes already read into the copy -- with the old unbuffered
/// deprecatedReader that was harmless, and it is not any more.
pub fn stdinReader() FileReader {
    return .{ .fd = STDIN };
}

pub fn stdin() FileWriter {
    return .{ .fd = if (comptime is_windows) std.fs.File.stdin() else STDIN };
}

/// The file HANDLE type, for the places that store one in a struct rather than
/// writing through it. 0.16 moved File out of std.fs into std.Io.
pub const File = if (@hasDecl(std.fs, "File")) std.fs.File else std.Io.File;

// ── tests ──────────────────────────────────────────────────────────────────
// These write to a real pipe and read the bytes back, because the failure this
// port could plausibly introduce is not "does not compile" -- it is output
// that is reordered, duplicated by a miscounted drain, or silently truncated.
// Only reading the far end of a pipe can see that.

/// Comptime string repetition, replacing the `s ** n` operator that 0.17
/// removed (it now lexes as two `*`). The array has to land in a `const` DECL
/// rather than a comptime var, or there is no runtime address to take.
/// Verified identical on 0.16 and 0.17.
fn repeated(comptime s: []const u8, comptime n: usize) []const u8 {
    const Holder = struct {
        const value = blk: {
            var out: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            break :blk out;
        };
    };
    return &Holder.value;
}

fn pipeRoundTrip(comptime body: fn (FileWriter) anyerror!void) ![]u8 {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    const w: FileWriter = .{ .fd = fds[1] };
    try body(w);
    _ = std.c.close(fds[1]); // EOF for the reader
    var buf: [8192]u8 = undefined;
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fds[0], buf[off..].ptr, buf.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    return std.testing.allocator.dupe(u8, buf[0..off]);
}

test "print formats and reaches the fd in order" {
    const out = try pipeRoundTrip(struct {
        fn f(w: FileWriter) anyerror!void {
            try w.print("a={d} b={s}\n", .{ 42, "xy" });
            try w.writeAll("tail");
            try w.writeByte('!');
        }
    }.f);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a=42 b=xy\ntail!", out);
}

test "splat repeats the pattern exactly once per count" {
    // {s:*>5} and friends drive `splat`; a drain that returns the wrong count
    // or repeats the pattern the wrong number of times shows up HERE and
    // nowhere else. The control is the exact expected string, not a length.
    const out = try pipeRoundTrip(struct {
        fn f(w: FileWriter) anyerror!void {
            try w.print("[{s:->6}]", .{"ab"});
            try w.print("{d: >4}", .{7});
        }
    }.f);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[----ab]   7", out);
}

test "a write larger than any internal buffer is not truncated" {
    const big = repeated("0123456789", 900); // 9000 bytes, over a typical pipe buffer
    const out = try pipeRoundTrip(struct {
        fn f(w: FileWriter) anyerror!void {
            try w.writeAll(big);
        }
    }.f);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 8192), out.len); // capped by the test reader
    try std.testing.expectEqualStrings(big[0..8192], out);
}

test "readUntilDelimiter splits lines and consumes the delimiter" {
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer _ = std.c.close(fds[0]);
    const w: FileWriter = .{ .fd = fds[1] };
    try w.writeAll("alpha\nbeta\nlast-no-newline");
    _ = std.c.close(fds[1]);

    var r: FileReader = .{ .fd = fds[0] };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("alpha", try r.readUntilDelimiter(&buf, '\n'));
    try std.testing.expectEqualStrings("beta", try r.readUntilDelimiter(&buf, '\n'));
    // A trailing unterminated line must be RETURNED, not dropped.
    try std.testing.expectEqualStrings("last-no-newline", try r.readUntilDelimiter(&buf, '\n'));
    try std.testing.expectError(error.EndOfStream, r.readUntilDelimiter(&buf, '\n'));
}

test "readUntilDelimiter spans multiple refills" {
    // The bug this guards: a line longer than one read(2) chunk, where a naive
    // implementation returns only the first chunk. 100KB exceeds both the
    // 64KB internal buffer and a typical pipe buffer.
    const long = repeated("x", 100_000);
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer _ = std.c.close(fds[0]);

    const t = try std.Thread.spawn(.{}, struct {
        fn f(fd: c_int, payload: []const u8) void {
            const w: FileWriter = .{ .fd = fd };
            w.writeAll(payload) catch {};
            w.writeByte('\n') catch {};
            _ = std.c.close(fd);
        }
    }.f, .{ fds[1], long });
    defer t.join();

    var r: FileReader = .{ .fd = fds[0] };
    const got = try r.readUntilDelimiterAlloc(std.testing.allocator, '\n', 1 << 20);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 100_000), got.len);
    try std.testing.expectEqualStrings(long, got);
}
