// fsio.zig — one filesystem/process surface that compiles on Zig 0.15.2 AND 0.16.
//
// WINTERMOLT'S OWN COPY. Same author. wintermolt is public OSS and references no
// forKernels source and no sibling paths, so it carries its own -- exactly the
// reasoning behind its own stdio.zig. There is nothing forKernels-specific in
// here: it is comptime wrappers over `std` and libc, which is also why it cannot
// ship as an archive and must be a source file.
// Copyright The Fantastic Planet - By David Clabaugh
//
// WHY THIS EXISTS
// ---------------
// Zig 0.16 moved the filesystem out of `std.fs` and into `std.Io`, and every
// operation now takes an `Io` parameter. forIO cannot simply move with it:
// consumers compile forIO's SOURCE as a module (forNet imports forio_async),
// and forMed, forQuant, forSec and forSim are still on 0.15.2. A hard move
// would force the whole fleet onto 0.16 on one day.
//
// So forIO owns the Io internally and its public API does not change. Callers
// keep writing `openFile(path, .{})` on both compilers; the io parameter is
// supplied here and nowhere else. Same principle as routing the fleet's clocks
// through forTime -- absorb the churn in one place so consumers migrate on
// their own schedule.
//
// The dead branch is pruned because `zig16` is comptime-known: 0.15.2 never
// analyses std.Io, and 0.16 never analyses std.fs.cwd.
//
// LIMIT: because the Io is owned here, a caller cannot supply its own event
// loop through these helpers. That is deliberate for the migration. If forIO
// later wants callers to drive an io_uring/kqueue loop -- which 0.16's std now
// ships as std.Io.Uring / std.Io.Kqueue -- that is an API change to make
// on purpose, not a side effect of a compiler bump.

const std = @import("std");

pub const zig16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const File = if (zig16) std.Io.File else std.fs.File;
pub const Dir = if (zig16) std.Io.Dir else std.fs.Dir;

/// The process-wide Io backing every helper below. 0.16 ships a ready-made
/// global single-threaded instance, which is the right shape here: these are
/// blocking file operations, and none of them use the async vtable entries
/// that would require a real allocator.
pub inline fn io() if (zig16) std.Io else void {
    if (zig16) return std.Io.Threaded.global_single_threaded.io();
    return {};
}

pub inline fn cwd() Dir {
    return if (zig16) std.Io.Dir.cwd() else std.fs.cwd();
}

pub inline fn openFile(path: []const u8, flags: File.OpenFlags) !File {
    return if (zig16) cwd().openFile(io(), path, flags) else cwd().openFile(path, flags);
}

pub inline fn createFile(path: []const u8, flags: File.CreateFlags) !File {
    return if (zig16) cwd().createFile(io(), path, flags) else cwd().createFile(path, flags);
}

pub inline fn deleteFile(path: []const u8) !void {
    return if (zig16) cwd().deleteFile(io(), path) else cwd().deleteFile(path);
}

pub inline fn makePath(path: []const u8) !void {
    // 0.16 renamed makePath -> createDirPath.
    return if (zig16) cwd().createDirPath(io(), path) else cwd().makePath(path);
}

pub inline fn rename(old_path: []const u8, new_path: []const u8) !void {
    // 0.16 names both directories and puts the Io LAST.
    return if (zig16)
        cwd().rename(old_path, cwd(), new_path, io())
    else
        cwd().rename(old_path, new_path);
}

pub inline fn deleteTree(path: []const u8) !void {
    return if (zig16) cwd().deleteTree(io(), path) else cwd().deleteTree(path);
}

/// The two versions disagree on the options type: 0.15.2 takes File.OpenFlags,
/// 0.16 takes Dir.AccessOptions. Naming it concretely (rather than `anytype`)
/// is what lets a caller's `.{}` coerce -- an empty anon-struct literal passed
/// through `anytype` keeps its own type and coerces to neither.
/// Directory-open options, under whichever name the toolchain uses.
pub const DirOpenOptions = if (zig16) Dir.OpenOptions else Dir.OpenDirOptions;

/// Open a directory relative to the process cwd.
pub inline fn openDirCwd(sub_path: []const u8, options: DirOpenOptions) !Dir {
    if (comptime zig16) return cwd().openDir(io(), sub_path, options);
    return cwd().openDir(sub_path, options);
}

/// Close a directory. 0.16 threads the Io through close as well.
pub inline fn closeDir(dir: Dir) void {
    if (comptime zig16) dir.close(io()) else dir.close();
}

/// Stat a path relative to the process cwd, without opening it.
pub inline fn statFileCwd(sub_path: []const u8) !File.Stat {
    if (comptime zig16) return cwd().statFile(io(), sub_path, .{});
    return cwd().statFile(sub_path);
}

/// Advance a flat directory iterator. 0.16 threads the Io through next().
pub inline fn iterNext(it: *Dir.Iterator) !?Dir.Entry {
    if (comptime zig16) return it.next(io());
    return it.next();
}

/// Advance a recursive directory walker.
///
/// `Dir.walk(gpa)` still takes no Io on 0.16 -- only `next` does -- so walker
/// creation needs no wrapper and this does.
pub inline fn walkerNext(walker: *Dir.Walker) !?Dir.Walker.Entry {
    if (comptime zig16) return walker.next(io());
    return walker.next();
}

pub const AccessFlags = if (zig16) Dir.AccessOptions else File.OpenFlags;

pub inline fn access(path: []const u8, flags: AccessFlags) !void {
    return if (zig16) cwd().access(io(), path, flags) else cwd().access(path, flags);
}

/// Does a path exist? The overwhelmingly common use of `access`.
pub inline fn exists(path: []const u8) bool {
    // Not routed through `access` above: `.{}` has to coerce against each
    // version's own options type, which only happens where that type is known.
    if (zig16) {
        cwd().access(io(), path, .{}) catch return false;
    } else {
        cwd().access(path, .{}) catch return false;
    }
    return true;
}

// ── File operations ─────────────────────────────────────────────────────────
//
// 0.16 moved File I/O behind Reader/Writer and removed the convenience methods.
// These are free functions rather than methods on a wrapper struct so that a
// File stays the std type: code that passes it to a std API, or reaches for
// .handle, keeps working untouched on both compilers.

pub inline fn writeAll(file: File, bytes: []const u8) !void {
    return if (zig16) file.writeStreamingAll(io(), bytes) else file.writeAll(bytes);
}

/// Read at an EXPLICIT offset. There is deliberately no position-tracking
/// `readAll(file, buf)` here.
///
/// 0.15.2's File carries a position and readAll advances it; 0.16's File has no
/// position at all -- reads are positional. A shim that papered over that by
/// passing offset 0 would compile on both, pass every 0.15.2 test, and silently
/// re-read the start of the file on every call under 0.16. Requiring the offset
/// makes the compiler point at each sequential-read site so it can be converted
/// deliberately rather than guessed at.
pub inline fn readAllAt(file: File, buffer: []u8, offset: u64) !usize {
    return if (zig16) file.readPositionalAll(io(), buffer, offset) else file.pread(buffer, offset);
}

pub inline fn getEndPos(file: File) !u64 {
    return if (zig16) file.length(io()) else file.getEndPos();
}

pub inline fn setEndPos(file: File, len: u64) !void {
    return if (zig16) file.setLength(io(), len) else file.setEndPos(len);
}

pub inline fn close(file: File) void {
    if (zig16) file.close(io()) else file.close();
}

/// Read a whole file into a fresh allocation. `max` caps the read so a huge or
/// growing file cannot exhaust the allocator.
pub fn readToEndAlloc(file: File, gpa: std.mem.Allocator, max: usize) ![]u8 {
    if (!zig16) return file.readToEndAlloc(gpa, max);
    const len = try getEndPos(file);
    if (len > max) return error.FileTooBig;
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    const n = try readAllAt(file, buf, 0);
    return buf[0..n];
}

/// Read a file a line at a time in bounded memory.
///
/// WHY THIS AND NOT std.Io.Reader.takeDelimiterExclusive
/// -----------------------------------------------------
/// Both compilers ship a delimiter-taking Reader, but they are reached
/// differently -- 0.15.2 hands back a `File.Reader` whose `.interface` is the
/// `std.Io.Reader`, 0.16 takes an `Io` and returns its own -- and they disagree
/// about long lines. Since iocompat exists precisely so callers never see that
/// seam, this is built on `readAllAt`, which both compilers already agree on.
///
/// MEMORY: `buffer` (caller-sized, reused for the whole file) plus, only when a
/// line does not fit in it, an overflow that grows to the LONGEST LINE. That is
/// the honest bound for a line-oriented format -- a USDA `points` array is one
/// line and can be megabytes -- and it is still the widest line rather than the
/// whole file. A caller that was reading the file whole in order to split it
/// trades O(file) for O(longest line).
pub const LineReader = struct {
    file: File,
    gpa: std.mem.Allocator,
    buf: []u8,
    /// Valid bytes currently in `buf`.
    filled: usize = 0,
    /// Scan position within `buf`.
    pos: usize = 0,
    /// Next byte offset to read. 0.16's File has no cursor, so the position
    /// lives here rather than in the handle.
    offset: u64 = 0,
    /// Absolute file offset of the first byte of the line `next()` just
    /// returned. This is what lets a caller record a byte RANGE for something
    /// it chose not to parse, and come back for it later.
    line_offset: u64 = 0,
    eof: bool = false,
    /// Allocated only for a line too long for `buf`.
    overflow: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *LineReader) void {
        self.overflow.deinit(self.gpa);
        self.* = undefined;
    }

    fn refill(self: *LineReader) !void {
        // Keep the partial line at the front, then top up behind it.
        const keep = self.filled - self.pos;
        if (keep > 0 and self.pos > 0) {
            std.mem.copyForwards(u8, self.buf[0..keep], self.buf[self.pos..self.filled]);
        }
        self.filled = keep;
        self.pos = 0;
        if (self.eof) return;
        if (self.filled == self.buf.len) return; // caller must drain first
        const n = try readAllAt(self.file, self.buf[self.filled..], self.offset);
        if (n == 0) {
            self.eof = true;
            return;
        }
        self.offset += n;
        self.filled += n;
    }

    /// The next line without its newline, or null at end of file. A trailing
    /// `\r` is LEFT IN PLACE -- stripping it here would quietly alter payload
    /// bytes for a caller that did not ask, and callers trim their own
    /// whitespace. A final line with no newline is returned before null.
    ///
    /// The returned slice borrows from this reader and is invalid after the
    /// next call. Copy it if it must outlive the iteration.
    pub fn next(self: *LineReader) !?[]const u8 {
        self.overflow.clearRetainingCapacity();
        var spilled = false;
        // `offset` points just past the last byte read into the buffer, so the
        // absolute position of buf[pos] is that minus what is still unconsumed.
        self.line_offset = self.offset - (self.filled - self.pos);

        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf[self.pos..self.filled], '\n')) |rel| {
                const line = self.buf[self.pos .. self.pos + rel];
                self.pos += rel + 1;
                if (!spilled) return line;
                try self.overflow.appendSlice(self.gpa, line);
                return self.overflow.items;
            }

            if (self.eof) {
                // Whatever is left is the last line, newline or not.
                const tail = self.buf[self.pos..self.filled];
                self.pos = self.filled;
                if (spilled) {
                    try self.overflow.appendSlice(self.gpa, tail);
                    return if (self.overflow.items.len == 0) null else self.overflow.items;
                }
                return if (tail.len == 0) null else tail;
            }

            // The buffer holds one partial line and nothing else: move it aside
            // so refill has room, rather than truncating a value the caller is
            // about to parse.
            if (self.pos == 0 and self.filled == self.buf.len) {
                try self.overflow.appendSlice(self.gpa, self.buf[0..self.filled]);
                spilled = true;
                self.filled = 0;
            }
            try self.refill();
        }
    }
};

/// `buffer` is the caller's scratch and must outlive the reader. 64 KiB is a
/// sensible default: large enough that ordinary lines never spill, small enough
/// to be nothing beside the file.
pub fn lineReader(file: File, gpa: std.mem.Allocator, buffer: []u8) LineReader {
    return .{ .file = file, .gpa = gpa, .buf = buffer };
}

test "LineReader: splits, keeps a newline-less tail, and spills a long line" {
    const gpa = std.testing.allocator;
    const path = "iocompat_linereader_test.txt";

    // The third line is deliberately longer than the 16-byte buffer below, so
    // the overflow path is exercised rather than merely present.
    const long = "C" ** 100;
    const body = "alpha\nbeta\n" ++ long ++ "\nomega-no-newline";
    {
        const f = try createFile(path, .{});
        defer close(f);
        try writeAll(f, body);
    }
    defer deleteFile(path) catch {};

    const f = try openFile(path, .{});
    defer close(f);
    var buf: [16]u8 = undefined;
    var lr = lineReader(f, gpa, &buf);
    defer lr.deinit();

    try std.testing.expectEqualStrings("alpha", (try lr.next()).?);
    try std.testing.expectEqualStrings("beta", (try lr.next()).?);
    try std.testing.expectEqualStrings(long, (try lr.next()).?);
    try std.testing.expectEqualStrings("omega-no-newline", (try lr.next()).?);
    try std.testing.expect((try lr.next()) == null);
    // Idempotent at the end, so a caller's while-loop cannot spin.
    try std.testing.expect((try lr.next()) == null);
}

test "LineReader: empty file, and a file that is only newlines" {
    const gpa = std.testing.allocator;

    {
        const path = "iocompat_linereader_empty.txt";
        const f = try createFile(path, .{});
        close(f);
        defer deleteFile(path) catch {};
        const r = try openFile(path, .{});
        defer close(r);
        var buf: [8]u8 = undefined;
        var lr = lineReader(r, gpa, &buf);
        defer lr.deinit();
        try std.testing.expect((try lr.next()) == null);
    }
    {
        const path = "iocompat_linereader_blanks.txt";
        const f = try createFile(path, .{});
        try writeAll(f, "\n\n\n");
        close(f);
        defer deleteFile(path) catch {};
        const r = try openFile(path, .{});
        defer close(r);
        var buf: [8]u8 = undefined;
        var lr = lineReader(r, gpa, &buf);
        defer lr.deinit();
        // Three empty lines, then end -- not three nulls.
        try std.testing.expectEqualStrings("", (try lr.next()).?);
        try std.testing.expectEqualStrings("", (try lr.next()).?);
        try std.testing.expectEqualStrings("", (try lr.next()).?);
        try std.testing.expect((try lr.next()) == null);
    }
}

/// Write `bytes` at an absolute offset. 0.16's File is positional-only -- there
/// is no seekTo -- so a 0.15.2 `seekTo(off)` + `writeAll(b)` pair collapses into
/// this single call on both compilers.
pub inline fn writeAllAt(file: File, bytes: []const u8, offset: u64) !void {
    if (zig16) return file.writePositionalAll(io(), bytes, offset);
    try file.seekTo(offset);
    return file.writeAll(bytes);
}

pub inline fn stat(file: File) !File.Stat {
    return if (zig16) file.stat(io()) else file.stat();
}

// ── the remaining Dir surface ───────────────────────────────────────────────

/// 0.16 dropped the null-terminated variants; a sentinel slice is just a slice.
pub inline fn openFileZ(path: [*:0]const u8, flags: File.OpenFlags) !File {
    return if (zig16) cwd().openFile(io(), std.mem.span(path), flags) else cwd().openFileZ(path, flags);
}

pub inline fn createFileZ(path: [*:0]const u8, flags: File.CreateFlags) !File {
    return if (zig16) cwd().createFile(io(), std.mem.span(path), flags) else cwd().createFileZ(path, flags);
}

/// 0.16 reorders the arguments and takes an `Io.Limit` rather than a usize cap.
pub inline fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return if (zig16)
        cwd().readFileAlloc(io(), path, gpa, std.Io.Limit.limited(max))
    else
        cwd().readFileAlloc(gpa, path, max);
}

pub inline fn writeFile(options: Dir.WriteFileOptions) !void {
    return if (zig16) cwd().writeFile(io(), options) else cwd().writeFile(options);
}

/// 0.16 renamed this to realPathFileAlloc and moved the allocator last.
pub inline fn realpathAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return if (zig16) cwd().realPathFileAlloc(io(), path, gpa) else cwd().realpathAlloc(gpa, path);
}

// ── clocks and randomness, for a binary with no forTime to lean on ─────────
//
// 0.16 removed the whole std.time timestamp family (timestamp, milliTimestamp,
// microTimestamp, nanoTimestamp); std.time now holds only the ns_per_* constants.
// The replacements want an Io threaded from main, which a helper called at
// arbitrary depth does not have -- so these go straight to libc, the same
// reasoning that puts getenv on std.c.getenv.
//
// WALL CLOCK. Anything measuring an INTERVAL should use monoNs(): the wall clock
// steps backwards on an NTP correction, so a duration measured with it can come
// out negative.

/// Nanoseconds since the Unix epoch.
pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
}

/// Milliseconds since the Unix epoch -- std.time.milliTimestamp's replacement.
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), 1_000_000));
}

/// Whole seconds since the Unix epoch -- std.time.timestamp's replacement.
pub fn timestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), 1_000_000_000));
}

/// Monotonic nanoseconds, for measuring intervals.
pub fn monoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Random bytes -- std.crypto.random's replacement.
///
/// 0.16 removed the global CSPRNG. getentropy is the kernel's own source and
/// needs no seeding or state, which is what a global was providing. It is capped
/// at 256 bytes per call, so this loops.
///
/// Returns false if the kernel refused, rather than silently leaving the buffer
/// as it was -- a caller generating an ID from unwritten stack memory is the
/// failure this prevents.
pub fn randomBytes(buf: []u8) bool {
    if (comptime @import("builtin").os.tag == .windows) {
        // BCryptGenRandom is the Windows source; left to winX86, which can test
        // it. Reporting failure is the honest answer here -- see the note above
        // about callers building IDs out of unwritten stack memory.
        return false;
    }
    var off: usize = 0;
    while (off < buf.len) {
        const chunk = @min(buf.len - off, 256);
        if (c_getentropy(buf.ptr + off, chunk) != 0) return false;
        off += chunk;
    }
    return true;
}

/// libc's getentropy, declared here rather than reached through std.c.
///
/// std.c.getentropy is literally `{}` on Darwin in 0.16 -- the platform switch
/// has `else => {}` -- even though libSystem exports the symbol. So going
/// through std.c gives "type 'void' not a function" rather than a call.
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;
const c_getentropy = getentropy;


// ── other 0.16 relocations ──────────────────────────────────────────────────
//
// These are not filesystem, but they are the same problem -- one name that moved
// -- and putting them anywhere else would mean a second version-gate file.

/// std.Thread.Mutex moved to std.Io.Mutex. (std.Thread itself still exists;
/// Mutex and Pool are what left it. Pool is GONE with no direct replacement --
/// that is a redesign onto the std.Io async model, not an alias.)
pub const Mutex = if (zig16) std.Io.Mutex else std.Thread.Mutex;

/// 0.16's Io.Mutex has no all-default init -- its state field is explicit, and
/// the unlocked value is the declared `Mutex.init`. 0.15.2's is `.{}`.
pub const mutex_init: Mutex = if (zig16) std.Io.Mutex.init else .{};

/// std.mem.trimRight -> std.mem.trimEnd.
pub inline fn trimEnd(comptime T: type, slice: []const T, strip: []const T) []const T {
    return if (zig16) std.mem.trimEnd(T, slice, strip) else std.mem.trimRight(T, slice, strip);
}

/// std.meta.intToEnum -> std.enums.fromInt, which returns an OPTIONAL rather
/// than an error union. Normalised to the error union so `try` at the call sites
/// keeps working on both compilers.
pub inline fn intToEnum(comptime E: type, int: anytype) !E {
    if (zig16) return std.enums.fromInt(E, int) orelse error.InvalidEnumTag;
    return std.meta.intToEnum(E, int);
}

/// Read at an EXPLICIT offset; see readAllAt for why there is no positionless
/// variant. Vectored in 0.16: the buffer becomes a slice OF slices.
pub inline fn readAt(file: File, buffer: []u8, offset: u64) !usize {
    return if (zig16) file.readPositional(io(), &.{buffer}, offset) else file.pread(buffer, offset);
}

/// 0.16's Io.Mutex takes an Io and its `lock` is cancelable; `lockUncancelable`
/// is the one that matches 0.15.2's infallible `lock()`.
pub inline fn lock(m: *Mutex) void {
    if (zig16) m.lockUncancelable(io()) else m.lock();
}

pub inline fn unlock(m: *Mutex) void {
    if (zig16) m.unlock(io()) else m.unlock();
}

/// 0.16's reader/writer take the Io alongside the caller's buffer.
pub inline fn reader(file: File, buffer: []u8) File.Reader {
    return if (zig16) file.reader(io(), buffer) else file.reader(buffer);
}

pub inline fn writer(file: File, buffer: []u8) File.Writer {
    return if (zig16) file.writer(io(), buffer) else file.writer(buffer);
}

// ── a cursor, for code that reads sequentially ──────────────────────────────
//
// 0.15.2's File carries a position; 0.16's does not, and there is no seek on a
// File at all. Code written against the old model -- rewind, read a header, read
// on -- has nowhere to put its position.
//
// This is that place. The cursor lives in the caller's struct rather than in the
// file descriptor, which is what 0.16 wants anyway, and it behaves identically
// on both compilers because every read underneath it is positional.
//
// Use this for sequential patterns. Use readAt/readAllAt directly when the
// offset is already known -- most "open it and read the whole thing" code is
// that, and does not need a cursor.
pub const Cursor = struct {
    file: File,
    pos: u64 = 0,

    pub fn init(file: File) Cursor {
        return .{ .file = file };
    }

    pub fn seekTo(self: *Cursor, offset: u64) void {
        self.pos = offset;
    }

    pub fn seekBy(self: *Cursor, delta: i64) void {
        const p: i64 = @intCast(self.pos);
        self.pos = @intCast(@max(0, p + delta));
    }

    pub fn getPos(self: *const Cursor) u64 {
        return self.pos;
    }

    pub fn read(self: *Cursor, buffer: []u8) !usize {
        const n = try readAt(self.file, buffer, self.pos);
        self.pos += n;
        return n;
    }

    /// Append at the cursor and advance it. Sequential writing has the same
    /// problem as sequential reading: 0.16's File has no position to advance.
    pub fn writeAll(self: *Cursor, bytes: []const u8) !void {
        try writeAllAt(self.file, bytes, self.pos);
        self.pos += bytes.len;
    }

    pub fn readAll(self: *Cursor, buffer: []u8) !usize {
        const n = try readAllAt(self.file, buffer, self.pos);
        self.pos += n;
        return n;
    }
};

// ── worker pool ─────────────────────────────────────────────────────────────
//
// std.Thread.Pool was REMOVED in 0.16 (std.Thread itself survives -- Pool and
// Mutex are what left it). The intended replacement is the std.Io async model.
//
// This is deliberately NOT that. Rewriting AsyncWriter onto std.Io is a real
// redesign of how work is submitted and awaited, and it should be done on
// purpose -- with 0.16's std.Io.Uring / std.Io.Kqueue in view, which is forIO's
// own subject matter -- rather than smuggled in under a compiler bump. So 0.16
// gets detached threads, which preserve the existing fire-and-forget semantics
// exactly: the caller already tracks completion itself with an atomic pending
// count, and already caps concurrency with MAX_PENDING_WRITES.
//
// What it costs: no thread reuse on 0.16, so a spawn per submitted write. That
// is bounded by MAX_PENDING_WRITES and is the honest cost of not redesigning
// here. 0.15.2 keeps the real pool, unchanged.
pub const Pool = struct {
    inner: if (zig16) void else std.Thread.Pool,

    pub fn init(self: *Pool, gpa: std.mem.Allocator) !void {
        if (zig16) {
            self.inner = {};
        } else {
            try self.inner.init(.{ .allocator = gpa, .n_jobs = null });
        }
    }

    pub fn deinit(self: *Pool) void {
        if (!zig16) self.inner.deinit();
    }

    pub fn spawn(self: *Pool, comptime func: anytype, args: anytype) !void {
        if (zig16) {
            const t = try std.Thread.spawn(.{}, func, args);
            t.detach();
        } else {
            try self.inner.spawn(func, args);
        }
    }
};

/// std.Thread.sleep -> std.Io.sleep, which needs an Io, a Duration and a Clock.
/// Clock is `.awake`, not `.real`: a polling backoff must not be affected by a
/// wall-clock jump. 0.16's Io.Clock has exactly two variants, real and awake.
pub inline fn sleepNs(nanoseconds: u64) void {
    if (zig16) {
        std.Io.sleep(io(), std.Io.Duration.fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
    } else {
        std.Thread.sleep(nanoseconds);
    }
}

/// std.fs.File.sync -> Io.File.sync, which takes an Io.
pub inline fn sync(file: File) !void {
    return if (zig16) file.sync(io()) else file.sync();
}

// ── appending to a byte list ────────────────────────────────────────────────
//
// 0.16 removed ArrayList.writer(gpa). The 0.16 replacement is
// std.Io.Writer.Allocating.fromArrayList, which has to be constructed, written
// through, and then written BACK with toArrayList -- three steps and a lifetime
// where there used to be one call.
//
// None of that is needed here. The call sites only ever writeAll and writeInt,
// and appendSlice does both on BOTH compilers, so this has no version split at
// all. Reaching for the version-gated replacement would have been the obvious
// move and the wrong one.
pub const ListWriter = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),

    pub fn init(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) ListWriter {
        return .{ .gpa = gpa, .list = list };
    }

    pub fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        return self.list.appendSlice(self.gpa, bytes);
    }

    pub fn writeByte(self: *ListWriter, byte: u8) !void {
        return self.list.append(self.gpa, byte);
    }

    pub fn writeInt(self: *ListWriter, comptime T: type, value: T, endian: std.builtin.Endian) !void {
        var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, endian);
        return self.writeAll(&buf);
    }
};

/// 0.16 slots the Io between the paths and the options.
pub inline fn copyFile(source_path: []const u8, dest_path: []const u8) !void {
    return if (zig16)
        cwd().copyFile(source_path, cwd(), dest_path, io(), .{})
    else
        cwd().copyFile(source_path, cwd(), dest_path, .{});
}

// ── running a child process ─────────────────────────────────────────────────
//
// 0.16 removed std.process.Child.run and moved spawning to std.process.spawn,
// which takes an Io. Child itself now only exposes kill and wait.
//
// These do NOT use io(). The process-wide instance is
// std.Io.Threaded.global_single_threaded, which is documented to work with a
// FAILING allocator -- fine for the blocking file operations everywhere else in
// this file, none of which allocate. Spawning does allocate (argv conversion on
// Windows), so through that instance every spawn came back OutOfMemory: a real
// error, reported honestly, from an Io that cannot do this job. They build a
// Threaded over the caller's allocator instead.

/// Run a command to completion, failing if it exits non-zero.
pub fn runCommand(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    if (zig16) {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const tio = threaded.io();
        var child = try std.process.spawn(tio, .{ .argv = argv });
        const term = try child.wait(tio);
        // 0.16 lower-cased the Term variants.
        if (term != .exited or term.exited != 0) return error.CommandFailed;
    } else {
        var child = std.process.Child.init(argv, gpa);
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) return error.CommandFailed;
    }
}

var capture_seq: std.atomic.Value(u32) = .init(0);

/// Run a command and return its stdout. Caller owns the result.
///
/// 0.16 redirects into a TEMPORARY FILE rather than a pipe. The pipe route was
/// tried first and is a trap: readToEndAlloc sizes its buffer from the file
/// LENGTH, which a pipe does not have, and draining one incrementally has its
/// own end-of-stream semantics to get right. A regular file is seekable, its
/// length is real, and the same code path works on both compilers.
/// Environment map, under whichever name the toolchain uses.
pub const EnvMap = if (@hasDecl(std.process, "EnvMap")) std.process.EnvMap else std.process.Environ.Map;

/// The current process environment as a mutable map -- std.process.getEnvMap's
/// replacement.
///
/// 0.16 removed getEnvMap because the environment is meant to arrive as a
/// std.process.Environ threaded down from main. A helper called from arbitrary
/// depth does not have one, so this reads libc's `environ` directly -- the same
/// reasoning that puts getenv on std.c.getenv and clocks on clock_gettime.
///
/// Caller owns the result; call deinit on it.
pub fn currentEnvMap(gpa: std.mem.Allocator) !EnvMap {
    if (comptime @hasDecl(std.process, "getEnvMap")) return std.process.getEnvMap(gpa);

    var map: EnvMap = .init(gpa);
    errdefer map.deinit();
    if (comptime @import("builtin").os.tag == .windows) {
        // The Windows environment block is UTF-16 and reached through the PEB.
        // Left to winX86, which can test it. This REFUSES rather than returning
        // an empty map, because an empty map would silently hand a child an
        // EMPTY environment instead of an inherited one.
        return error.Unsupported;
    }
    const env = std.c.environ;
    var n: usize = 0;
    while (env[n] != null) n += 1;
    try map.putPosixBlock(.{ .slice = @ptrCast(env[0..n]) });
    return map;
}

/// What a child process produced and how it ended.
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    /// Exit status when `exited` is true; meaningless otherwise.
    exit_code: u8,
    /// False when the child was signalled or stopped rather than exiting.
    exited: bool,
    /// The signal number when the child was killed by one, else null. Kept
    /// because callers that report an exit code use -signo to distinguish
    /// "killed by SIGKILL" from "we do not know", and collapsing both to -1
    /// would lose that silently.
    signal: ?u32 = null,

    pub fn deinit(r: RunResult, gpa: std.mem.Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

/// Run a command to completion, capturing stdout and stderr SEPARATELY and
/// reporting how it terminated. Caller owns the result (see RunResult.deinit).
///
/// captureCommand above is not enough for most callers: it merges away the exit
/// status and discards stderr, and a tool that reports "docker not available"
/// needs both. This keeps all three.
///
/// 0.16 removed Child.collectOutput along with Child.init, and redirects to a
/// TEMPORARY FILE rather than a pipe for the reason captureCommand already
/// documents: readToEndAlloc sizes its buffer from the file LENGTH, which a pipe
/// does not have. Two temp files, one per stream, so interleaving cannot merge
/// them the way 2>&1 would.
pub fn runCapture(gpa: std.mem.Allocator, argv: []const []const u8, max: usize, env: ?*const EnvMap) !RunResult {
    if (zig16) {
        const seq = capture_seq.fetchAdd(1, .monotonic);
        const out_name = try std.fmt.allocPrint(gpa, ".wm-run-{x}-{d}.out", .{ @intFromPtr(argv.ptr), seq });
        defer gpa.free(out_name);
        defer deleteFile(out_name) catch {};
        const err_name = try std.fmt.allocPrint(gpa, ".wm-run-{x}-{d}.err", .{ @intFromPtr(argv.ptr), seq });
        defer gpa.free(err_name);
        defer deleteFile(err_name) catch {};

        var term: std.process.Child.Term = .{ .exited = 0 };
        {
            const out_file = try createFile(out_name, .{ .read = true });
            defer close(out_file);
            const err_file = try createFile(err_name, .{ .read = true });
            defer close(err_file);

            // A Threaded over the CALLER's allocator, not
            // Threaded.global_single_threaded: spawning allocates (argv
            // conversion), and that instance is documented to work with a
            // failing allocator, so every spawn through it returns OutOfMemory.
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            const tio = threaded.io();
            var child = try std.process.spawn(tio, .{
                .argv = argv,
                .stdout = .{ .file = out_file },
                .stderr = .{ .file = err_file },
                .environ_map = env,
            });
            term = try child.wait(tio);
        }

        const of = try openFile(out_name, .{});
        defer close(of);
        const stdout = try readToEndAlloc(of, gpa, max);
        errdefer gpa.free(stdout);
        const ef = try openFile(err_name, .{});
        defer close(ef);
        const stderr = try readToEndAlloc(ef, gpa, max);

        return .{
            .stdout = stdout,
            .stderr = stderr,
            // 0.16 lower-cased the Term variants.
            .exit_code = if (term == .exited) term.exited else 0,
            .exited = term == .exited,
            .signal = if (term == .signal) @intFromEnum(term.signal) else null,
        };
    } else {
        const res = try std.process.Child.run(.{ .allocator = gpa, .argv = argv, .max_output_bytes = max, .env_map = env });
        return .{
            .stdout = res.stdout,
            .stderr = res.stderr,
            .exit_code = if (res.term == .Exited) res.term.Exited else 0,
            .exited = res.term == .Exited,
            .signal = if (res.term == .Signal) res.term.Signal else null,
        };
    }
}

/// Spawn a LONG-LIVED child with stdin and stdout pipes, for a process the caller
/// keeps talking to -- an MCP server over stdio, for instance.
///
/// runCapture is the wrong shape for this: it waits for exit and hands back the
/// finished output. This returns the LIVE Child, whose .stdin and .stdout are
/// open pipes.
///
/// The Io here is the process-wide single-threaded instance, deliberately: the
/// caller stores the Child in a struct, so an Io on the spawning function's stack
/// would be gone by the time anyone called kill or wait. Its documented limit is
/// that it works with a FAILING allocator -- POSIX spawn does not allocate (the
/// argv conversion that does is Windows-only), so this is sound on POSIX and is
/// the spot winX86 will need a longer-lived Threaded instead.
pub fn spawnPiped(gpa: std.mem.Allocator, argv: []const []const u8) !std.process.Child {
    if (comptime zig16) {
        return std.process.spawn(io(), .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
    } else {
        var child = std.process.Child.init(argv, gpa);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        return child;
    }
}

/// Kill a child. 0.16 threads the Io through kill.
pub fn killChild(child: *std.process.Child) void {
    if (comptime zig16) child.kill(io()) else _ = child.kill() catch {};
}

/// Reap a child. 0.16 threads the Io through wait.
pub fn waitChild(child: *std.process.Child) !std.process.Child.Term {
    if (comptime zig16) return child.wait(io());
    return child.wait();
}

/// Start a command and do NOT wait for it -- fire and forget.
///
/// Deliberately leaves the child unreaped, matching the pre-port behaviour of
/// the one caller (audio playback) that used `child.spawn()` and never waited.
/// Changing that to reap would block the caller, which is the opposite of what
/// it wants.
pub fn spawnDetached(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    if (zig16) {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        _ = try std.process.spawn(threaded.io(), .{ .argv = argv });
    } else {
        var child = std.process.Child.init(argv, gpa);
        try child.spawn();
    }
}

pub fn captureCommand(gpa: std.mem.Allocator, argv: []const []const u8, max: usize) ![]u8 {
    if (zig16) {
        // Unique enough without std.crypto.random (which also moved in 0.16):
        // a per-process counter, salted with an address so two concurrent wrap
        // processes cannot pick the same name.
        const seq = capture_seq.fetchAdd(1, .monotonic);
        const tmp_name = try std.fmt.allocPrint(gpa, ".forio-capture-{x}-{d}.tmp", .{ @intFromPtr(argv.ptr), seq });
        defer gpa.free(tmp_name);
        defer deleteFile(tmp_name) catch {};

        const out_file = try createFile(tmp_name, .{ .read = true });
        {
            defer close(out_file);
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            const tio = threaded.io();
            var child = try std.process.spawn(tio, .{ .argv = argv, .stdout = .{ .file = out_file } });
            _ = try child.wait(tio);
        }
        const in_file = try openFile(tmp_name, .{});
        defer close(in_file);
        return readToEndAlloc(in_file, gpa, max);
    } else {
        const res = try std.process.Child.run(.{ .allocator = gpa, .argv = argv, .max_output_bytes = max });
        gpa.free(res.stderr);
        return res.stdout;
    }
}

// ── kqueue, for evloop.zig's BSD backend ───────────────────────────────────
//
// 0.16 deleted std.posix.kqueue and std.posix.kevent along with most of that
// namespace's syscall surface. The note at the top of this file stands: 0.16
// does ship std.Io.Kqueue, and moving evloop onto it is an API change to make
// deliberately, not one to make because a compiler bump forced it today. So
// these are the 0.15.2 bodies with their errno switches intact, reaching
// through std.posix.system, which still resolves to std.c when libc is linked.
//
// `.INTR => continue` matters more here than anywhere else in this file: an
// event loop that surfaces a stray signal as a failed poll drops whatever was
// in flight. Only the two calls evloop makes are shimmed — Kevent, fd_t and
// the rest of the types it names all survived and are still reached through
// std.posix directly.

pub const KQueueError = if (zig16) error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || std.posix.UnexpectedError else std.posix.KQueueError;

pub fn kqueue() KQueueError!i32 {
    if (!zig16) return std.posix.kqueue();
    const rc = std.posix.system.kqueue();
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub const KEventError = if (zig16) error{
    AccessDenied,
    EventNotFound,
    ProcessNotFound,
    SystemResources,
    Overflow,
} else std.posix.KEventError;

pub fn kevent(
    kq: i32,
    changelist: []const std.posix.Kevent,
    eventlist: []std.posix.Kevent,
    timeout: ?*const std.posix.timespec,
) KEventError!usize {
    if (!zig16) return std.posix.kevent(kq, changelist, eventlist, timeout);
    while (true) {
        const rc = std.posix.system.kevent(
            kq,
            changelist.ptr,
            std.math.cast(c_int, changelist.len) orelse return error.Overflow,
            eventlist.ptr,
            std.math.cast(c_int, eventlist.len) orelse return error.Overflow,
            timeout,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .FAULT => unreachable,
            .BADF => unreachable, // Always a race condition.
            .INTR => continue,
            .INVAL => unreachable,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            else => unreachable,
        }
    }
}
