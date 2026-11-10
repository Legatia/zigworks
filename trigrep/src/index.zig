//! The on-disk trigram index: one file per indexed root, read through mmap.
//!
//! Layout (little-endian):
//!   header      magic, version, counts, section offsets, build id, base id (header_len bytes)
//!   files       file_count x { path_off u32, path_len u32, size u64, mtime i64 }
//!   paths       relative paths, concatenated
//!   root        the absolute root path
//!   trigrams    tri_count x { trigram u32, count u32, postings_off u64 }, sorted
//!   postings    per trigram: file ids as varint deltas
//!
//! Trigrams are ASCII-lowercased and never span a newline.
//!
//! A *delta* index (same format, `<index>.delta`, base id set) holds files that differ
//! from the base index: changed or new files with their trigrams, and deleted ones as
//! tombstones (size `tombstone`). A delta whose base id doesn't match the base's build
//! id is stale and ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const walk = @import("walk.zig");
const Query = @import("query.zig").Query;

pub const magic = "TRIGREP\x01";
pub const format_version: u32 = 4;
const header_len = 88;
const file_rec = 24;
const tri_rec = 16;
const tri_space = 1 << 24;

pub const binary_probe = 8192;

/// Size recorded for a file deleted since the base index was built (deltas only).
pub const tombstone: u64 = std.math.maxInt(u64);

pub fn deltaPath(arena: Allocator, index_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}.delta", .{index_path});
}

pub fn isBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, binary_probe)], 0) != null;
}

const fold_table = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = std.ascii.toLower(@intCast(i));
    break :blk t;
};

/// Appends the distinct trigrams of `data` to `out`. `seen` is a 2^24-bit scratch set,
/// all zero on entry and on return.
pub fn extractTrigrams(gpa: Allocator, data: []const u8, seen: []u64, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    var t: u32 = 0;
    var run: u32 = 0;
    for (data) |b| {
        if (b == '\n') {
            run = 0;
            continue;
        }
        t = ((t << 8) | fold_table[b]) & (tri_space - 1);
        run += 1;
        if (run < 3) continue;
        const bit = @as(u64, 1) << @intCast(t & 63);
        if (seen[t >> 6] & bit == 0) {
            seen[t >> 6] |= bit;
            try out.append(gpa, t);
        }
    }
    for (out.items) |x| seen[x >> 6] &= ~(@as(u64, 1) << @intCast(x & 63));
}

/// Where the index for `root` (an absolute path) lives: $TRIGREP_INDEX_DIR,
/// $XDG_CACHE_HOME/trigrep or ~/.cache/trigrep, named by a hash of the root.
pub fn pathFor(arena: Allocator, root: []const u8) ![]u8 {
    const dir = try cacheDir(arena);
    const h = std.hash.Wyhash.hash(0, root);
    return std.fmt.allocPrint(arena, "{s}/{x:0>16}.idx", .{ dir, h });
}

/// The directory all indexes live in.
pub fn cacheDir(arena: Allocator) ![]u8 {
    return if (std.posix.getenv("TRIGREP_INDEX_DIR")) |d|
        try arena.dupe(u8, d)
    else if (std.posix.getenv("XDG_CACHE_HOME")) |d|
        try std.fs.path.join(arena, &.{ d, "trigrep" })
    else if (std.posix.getenv("HOME")) |h|
        try std.fs.path.join(arena, &.{ h, ".cache", "trigrep" })
    else
        error.NoCacheDir;
}

pub const Pruned = struct {
    removed: usize = 0,
    removed_bytes: u64 = 0,
    kept: usize = 0,
    kept_bytes: u64 = 0,
};

/// Deletes the indexes in `dir_path` whose root directory no longer exists (a
/// removed checkout or worktree). With `report`, lists every index and what
/// happened to it. Indexes this version can't read are left alone.
pub fn prune(arena: Allocator, dir_path: []const u8, report: ?*std.Io.Writer) !Pruned {
    var res: Pruned = .{};
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return res,
        else => return err,
    };
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".idx")) try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ dir_path, name });
        const delta = try deltaPath(arena, path);
        const bytes = fileSize(path) + fileSize(delta);
        var ix = Index.open(path) catch {
            if (report) |w| try w.print("skipped  {d:>7.1} MB  {s} (not readable by this version)\n", .{ mb(bytes), path });
            continue;
        };
        const root = try arena.dupe(u8, ix.root);
        ix.close();
        if (rootGone(root)) {
            std.fs.cwd().deleteFile(path) catch {};
            std.fs.cwd().deleteFile(delta) catch {};
            std.fs.cwd().deleteFile(try std.fmt.allocPrint(arena, "{s}.building", .{path})) catch {};
            res.removed += 1;
            res.removed_bytes += bytes;
            if (report) |w| try w.print("removed  {d:>7.1} MB  {s}\n", .{ mb(bytes), root });
        } else {
            res.kept += 1;
            res.kept_bytes += bytes;
            if (report) |w| try w.print("kept     {d:>7.1} MB  {s}\n", .{ mb(bytes), root });
        }
    }
    return res;
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e6;
}

fn fileSize(path: []const u8) u64 {
    const st = std.fs.cwd().statFile(path) catch return 0;
    return st.size;
}

fn missing(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch |err| return err == error.FileNotFound;
    return false;
}

/// True if `root` has been deleted. A root on a volume that isn't mounted
/// right now is not gone.
fn rootGone(root: []const u8) bool {
    if (!missing(root)) return false;
    for ([_][]const u8{ "/Volumes/", "/mnt/", "/media/", "/run/media/" }) |mounts| {
        if (!std.mem.startsWith(u8, root, mounts)) continue;
        const end = std.mem.indexOfScalarPos(u8, root, mounts.len, '/') orelse root.len;
        if (missing(root[0..end])) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Building

pub const BuildStats = struct {
    files: usize = 0,
    binary: usize = 0,
    unreadable: usize = 0,
    bytes: u64 = 0,
    trigrams: usize = 0,
    postings: u64 = 0,
    index_bytes: u64 = 0,
    /// Random, nonzero; identifies this build of the index.
    build_id: u64 = 0,
};

const PostList = struct {
    last: u32 = 0,
    count: u32 = 0,
    bytes: std.ArrayList(u8) = .empty,
};

fn putVarint(list: *std.ArrayList(u8), gpa: Allocator, value: u32) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try list.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try list.append(gpa, @truncate(v));
}

const Extractor = struct {
    gpa: Allocator,
    root: std.fs.Dir,
    entries: []const walk.Entry,
    results: []?[]u32,
    base: usize,
    end: usize,
    next: *std.atomic.Value(usize),
    seen: []u64,
    buf: std.ArrayList(u8) = .empty,
    tris: std.ArrayList(u32) = .empty,
    bytes: u64 = 0,
    binary: usize = 0,

    fn run(x: *Extractor) void {
        while (true) {
            const i = x.next.fetchAdd(1, .monotonic);
            if (i >= x.end) break;
            x.results[i - x.base] = x.process(x.entries[i]) catch null;
        }
    }

    fn process(x: *Extractor, entry: walk.Entry) ![]u32 {
        if (entry.size == tombstone) return try x.gpa.alloc(u32, 0);
        var f = try x.root.openFile(entry.path, .{});
        defer f.close();
        const size = (try f.stat()).size;
        try x.buf.resize(x.gpa, @intCast(size));
        const n = try f.readAll(x.buf.items);
        const data = x.buf.items[0..n];
        x.bytes += n;
        if (isBinary(data)) {
            x.binary += 1;
            return try x.gpa.alloc(u32, 0);
        }
        try extractTrigrams(x.gpa, data, x.seen, &x.tris);
        return try x.gpa.dupe(u32, x.tris.items);
    }
};

fn writeU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

fn writeU64(buf: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], v, .little);
}

pub const BuildOptions = struct {
    /// Nonzero for a delta: the build id of the base index it applies to.
    base_id: u64 = 0,
};

/// Indexes `entries` (files under `root`) and writes the index to `out_path`
/// atomically.
pub fn build(gpa: Allocator, root: []const u8, entries: []const walk.Entry, out_path: []const u8, threads: usize, opts: BuildOptions) !BuildStats {
    var stats = BuildStats{ .files = entries.len, .build_id = std.crypto.random.int(u64) | 1 };
    if (entries.len > std.math.maxInt(u32)) return error.TooManyFiles;

    var root_dir = try std.fs.cwd().openDir(root, .{});
    defer root_dir.close();

    const slot = try gpa.alloc(u32, tri_space);
    defer gpa.free(slot);
    @memset(slot, 0);
    var posts: std.ArrayList(PostList) = .empty;
    defer {
        for (posts.items) |*p| p.bytes.deinit(gpa);
        posts.deinit(gpa);
    }

    const n_threads = @max(1, threads);
    const extractors = try gpa.alloc(Extractor, n_threads);
    defer gpa.free(extractors);
    const seen_all = try gpa.alloc(u64, n_threads * (tri_space / 64));
    defer gpa.free(seen_all);
    @memset(seen_all, 0);

    const batch = 4096;
    const results = try gpa.alloc(?[]u32, batch);
    defer gpa.free(results);
    var next = std.atomic.Value(usize).init(0);

    for (extractors, 0..) |*x, i| x.* = .{
        .gpa = gpa,
        .root = root_dir,
        .entries = entries,
        .results = results,
        .base = 0,
        .end = 0,
        .next = &next,
        .seen = seen_all[i * (tri_space / 64) ..][0 .. tri_space / 64],
    };
    defer for (extractors) |*x| {
        x.buf.deinit(gpa);
        x.tris.deinit(gpa);
    };

    var start: usize = 0;
    while (start < entries.len) : (start += batch) {
        const end = @min(start + batch, entries.len);
        next.store(start, .monotonic);
        for (extractors) |*x| {
            x.base = start;
            x.end = end;
        }
        if (n_threads == 1) {
            extractors[0].run();
        } else {
            const handles = try gpa.alloc(std.Thread, n_threads);
            defer gpa.free(handles);
            for (extractors, 0..) |*x, i| handles[i] = try std.Thread.spawn(.{}, Extractor.run, .{x});
            for (handles) |h| h.join();
        }

        for (results[0 .. end - start], 0..) |r, k| {
            const id: u32 = @intCast(start + k);
            const tris = r orelse {
                stats.unreadable += 1;
                continue;
            };
            defer gpa.free(tris);
            for (tris) |t| {
                var s = slot[t];
                if (s == 0) {
                    try posts.append(gpa, .{});
                    s = @intCast(posts.items.len);
                    slot[t] = s;
                }
                const p = &posts.items[s - 1];
                try putVarint(&p.bytes, gpa, id - p.last);
                p.last = id;
                p.count += 1;
            }
            stats.postings += tris.len;
        }
    }
    for (extractors) |x| {
        stats.bytes += x.bytes;
        stats.binary += x.binary;
    }
    stats.trigrams = posts.items.len;

    // Layout.
    var paths_len: usize = 0;
    for (entries) |e| paths_len += e.path.len;
    var post_len: usize = 0;
    for (posts.items) |p| post_len += p.bytes.items.len;
    const files_off: usize = header_len;
    const paths_off = files_off + entries.len * file_rec;
    const root_off = paths_off + paths_len;
    const tris_off = root_off + root.len;
    const post_off = tris_off + posts.items.len * tri_rec;
    const total = post_off + post_len;
    stats.index_bytes = total;

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{out_path});
    defer gpa.free(tmp_path);
    if (std.fs.path.dirname(out_path)) |d| try std.fs.cwd().makePath(d);
    var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    {
        defer file.close();
        var wbuf: [1 << 16]u8 = undefined;
        var fw = file.writer(&wbuf);
        const w = &fw.interface;

        var head = [_]u8{0} ** header_len;
        @memcpy(head[0..8], magic);
        writeU32(&head, 8, format_version);
        writeU32(&head, 12, @intCast(entries.len));
        writeU32(&head, 16, @intCast(posts.items.len));
        writeU32(&head, 20, @intCast(root.len));
        writeU64(&head, 24, files_off);
        writeU64(&head, 32, paths_off);
        writeU64(&head, 40, tris_off);
        writeU64(&head, 48, post_off);
        writeU64(&head, 56, root_off);
        writeU64(&head, 64, total);
        writeU64(&head, 72, stats.build_id);
        writeU64(&head, 80, opts.base_id);
        try w.writeAll(&head);

        var po: u32 = 0;
        for (entries) |e| {
            var rec: [file_rec]u8 = undefined;
            writeU32(&rec, 0, po);
            writeU32(&rec, 4, @intCast(e.path.len));
            writeU64(&rec, 8, e.size);
            writeU64(&rec, 16, @bitCast(e.mtime));
            try w.writeAll(&rec);
            po += @intCast(e.path.len);
        }
        for (entries) |e| try w.writeAll(e.path);
        try w.writeAll(root);

        var off: u64 = 0;
        var t: u32 = 0;
        while (t < tri_space) : (t += 1) {
            const s = slot[t];
            if (s == 0) continue;
            const p = posts.items[s - 1];
            var rec: [tri_rec]u8 = undefined;
            writeU32(&rec, 0, t);
            writeU32(&rec, 4, p.count);
            writeU64(&rec, 8, off);
            try w.writeAll(&rec);
            off += p.bytes.items.len;
        }
        t = 0;
        while (t < tri_space) : (t += 1) {
            const s = slot[t];
            if (s == 0) continue;
            try w.writeAll(posts.items[s - 1].bytes.items);
        }
        try w.flush();
    }
    try std.fs.cwd().rename(tmp_path, out_path);
    return stats;
}

// ---------------------------------------------------------------------------
// Reading

pub const FileRec = struct { path: []const u8, size: u64, mtime: i64 };

pub const Postings = struct { count: u32, bytes: []const u8 };

pub const Index = struct {
    data: []align(std.heap.page_size_min) const u8,
    file_count: u32,
    tri_count: u32,
    files_off: usize,
    paths_off: usize,
    tris_off: usize,
    post_off: usize,
    root: []const u8,
    build_id: u64,
    /// Nonzero for a delta index.
    base_id: u64,

    pub fn open(path: []const u8) !Index {
        var f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const size: usize = @intCast((try f.stat()).size);
        if (size < header_len) return error.BadIndex;
        const data = try std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, f.handle, 0);
        errdefer std.posix.munmap(data);
        if (!std.mem.eql(u8, data[0..8], magic)) return error.BadIndex;
        if (rd32(data, 8) != format_version) return error.BadIndex;
        const end = rd64(data, 64);
        if (end != size) return error.BadIndex;
        const root_off = rd64(data, 56);
        const root_len = rd32(data, 20);
        if (root_off + root_len > size) return error.BadIndex;
        const ix = Index{
            .data = data,
            .file_count = rd32(data, 12),
            .tri_count = rd32(data, 16),
            .files_off = rd64(data, 24),
            .paths_off = rd64(data, 32),
            .tris_off = rd64(data, 40),
            .post_off = rd64(data, 48),
            .root = data[root_off..][0..root_len],
            .build_id = std.mem.readInt(u64, data[72..80], .little),
            .base_id = std.mem.readInt(u64, data[80..88], .little),
        };
        if (ix.files_off + @as(usize, ix.file_count) * file_rec > size or
            ix.tris_off + @as(usize, ix.tri_count) * tri_rec > size or ix.post_off > size)
            return error.BadIndex;
        return ix;
    }

    pub fn close(ix: *Index) void {
        std.posix.munmap(ix.data);
    }

    fn rd32(d: []const u8, off: usize) u32 {
        return std.mem.readInt(u32, d[off..][0..4], .little);
    }

    fn rd64(d: []const u8, off: usize) usize {
        return @intCast(std.mem.readInt(u64, d[off..][0..8], .little));
    }

    pub fn file(ix: *const Index, id: u32) FileRec {
        const off = ix.files_off + @as(usize, id) * file_rec;
        const po = rd32(ix.data, off);
        const pl = rd32(ix.data, off + 4);
        return .{
            .path = ix.data[ix.paths_off + po ..][0..pl],
            .size = std.mem.readInt(u64, ix.data[off + 8 ..][0..8], .little),
            .mtime = std.mem.readInt(i64, ix.data[off + 16 ..][0..8], .little),
        };
    }

    /// How many indexed files lie under directory `prefix` (relative, no trailing
    /// slash). Files are stored in walk order, so they form one contiguous range.
    pub fn countUnder(ix: *const Index, prefix: []const u8) u32 {
        if (prefix.len == 0) return ix.file_count;
        var lo_key: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (prefix.len + 1 > lo_key.len) return ix.file_count;
        @memcpy(lo_key[0..prefix.len], prefix);
        lo_key[prefix.len] = '/';
        const key = lo_key[0 .. prefix.len + 1];
        const first = ix.lowerBound(key);
        var lo = first;
        var hi: u32 = ix.file_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.startsWith(u8, ix.file(mid).path, key)) lo = mid + 1 else hi = mid;
        }
        return lo - first;
    }

    /// First file id whose path is not before `key` in walk order.
    fn lowerBound(ix: *const Index, key: []const u8) u32 {
        var lo: u32 = 0;
        var hi: u32 = ix.file_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (walk.pathOrder(ix.file(mid).path, key)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn lookup(ix: *const Index, tri: u32) ?Postings {
        var lo: usize = 0;
        var hi: usize = ix.tri_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const off = ix.tris_off + mid * tri_rec;
            const t = rd32(ix.data, off);
            if (t == tri) {
                const count = rd32(ix.data, off + 4);
                const start = ix.post_off + rd64(ix.data, off + 8);
                const stop = if (mid + 1 < ix.tri_count) ix.post_off + rd64(ix.data, off + tri_rec + 8) else ix.data.len;
                return .{ .count = count, .bytes = ix.data[start..stop] };
            }
            if (t < tri) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn decode(arena: Allocator, p: Postings) ![]u32 {
        const out = try arena.alloc(u32, p.count);
        var cur: u32 = 0;
        var i: usize = 0;
        for (out) |*slot| {
            var v: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                const b = p.bytes[i];
                i += 1;
                v |= @as(u32, b & 0x7f) << shift;
                if (b < 0x80) break;
                shift +|= 7;
            }
            cur += v;
            slot.* = cur;
        }
        return out;
    }

    fn estimate(ix: *const Index, q: Query) usize {
        return switch (q) {
            .all => std.math.maxInt(usize),
            .tri => |t| if (ix.lookup(t)) |p| p.count else 0,
            .and_ => |items| blk: {
                var m: usize = std.math.maxInt(usize);
                for (items) |it| m = @min(m, ix.estimate(it));
                break :blk m;
            },
            .or_ => |items| blk: {
                var s: usize = 0;
                for (items) |it| s +|= ix.estimate(it);
                break :blk s;
            },
        };
    }

    /// File ids that may match, sorted; null means every file.
    pub fn candidates(ix: *const Index, arena: Allocator, q: Query) !?[]const u32 {
        switch (q) {
            .all => return null,
            .tri => |t| return if (ix.lookup(t)) |p| try decode(arena, p) else &.{},
            .and_ => |items| {
                const sorted = try arena.dupe(Query, items);
                std.mem.sort(Query, sorted, ix, struct {
                    fn lt(i: *const Index, a: Query, b: Query) bool {
                        return i.estimate(a) < i.estimate(b);
                    }
                }.lt);
                var acc: ?[]const u32 = null;
                for (sorted) |it| {
                    const ids = (try ix.candidates(arena, it)) orelse continue;
                    acc = if (acc) |a| try intersect(arena, a, ids) else ids;
                    if (acc.?.len == 0) break;
                }
                return acc;
            },
            .or_ => |items| {
                var acc: []const u32 = &.{};
                for (items) |it| {
                    const ids = (try ix.candidates(arena, it)) orelse return null;
                    acc = try merge(arena, acc, ids);
                }
                return acc;
            },
        }
    }
};

fn intersect(arena: Allocator, a: []const u32, b: []const u32) ![]u32 {
    const out = try arena.alloc(u32, @min(a.len, b.len));
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] < b[j]) {
            i += 1;
        } else if (a[i] > b[j]) {
            j += 1;
        } else {
            out[n] = a[i];
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return out[0..n];
}

fn merge(arena: Allocator, a: []const u32, b: []const u32) ![]u32 {
    const out = try arena.alloc(u32, a.len + b.len);
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < a.len or j < b.len) {
        const take_a = j >= b.len or (i < a.len and a[i] <= b[j]);
        const v = if (take_a) a[i] else b[j];
        if (take_a) i += 1 else j += 1;
        if (n > 0 and out[n - 1] == v) continue;
        out[n] = v;
        n += 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Tests

test "trigram extraction folds case and skips newlines" {
    const gpa = std.testing.allocator;
    const seen = try gpa.alloc(u64, tri_space / 64);
    defer gpa.free(seen);
    @memset(seen, 0);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try extractTrigrams(gpa, "AbCd\nab", seen, &out);
    try std.testing.expectEqualSlices(u32, &.{
        @import("query.zig").trigramKey('a', 'b', 'c'),
        @import("query.zig").trigramKey('b', 'c', 'd'),
    }, out.items);
    for (seen) |w| try std.testing.expectEqual(@as(u64, 0), w);
}

test "prune removes indexes whose root is gone" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("cache");
    try tmp.dir.makePath("here");
    try tmp.dir.makePath("gone");
    try tmp.dir.writeFile(.{ .sub_path = "here/a.txt", .data = "hello\n" });
    try tmp.dir.writeFile(.{ .sub_path = "gone/b.txt", .data = "world\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try tmp.dir.realpathAlloc(arena, ".");
    const cache = try std.fs.path.join(arena, &.{ base, "cache" });
    for ([_][]const u8{ "here", "gone" }) |name| {
        const root = try std.fs.path.join(arena, &.{ base, name });
        const entries = try walk.walk(arena, root, .{});
        _ = try build(gpa, root, entries, try std.fmt.allocPrint(arena, "{s}/{s}.idx", .{ cache, name }), 1, .{});
    }
    try tmp.dir.writeFile(.{ .sub_path = "cache/gone.idx.delta", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "cache/old.idx", .data = "not an index" });
    try tmp.dir.deleteTree("gone");

    var out: std.Io.Writer.Allocating = .init(arena);
    const res = try prune(arena, cache, &out.writer);
    try std.testing.expectEqual(@as(usize, 1), res.removed);
    try std.testing.expectEqual(@as(usize, 1), res.kept);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "removed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "skipped") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("cache/gone.idx", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("cache/gone.idx.delta", .{}));
    try tmp.dir.access("cache/here.idx", .{});
    try tmp.dir.access("cache/old.idx", .{});
    try std.testing.expect(!rootGone("/Volumes/trigrep-no-such-volume/repo"));
}

test "build, open and query an index" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hello world\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "goodbye world\n" });
    try tmp.dir.writeFile(.{ .sub_path = "c.bin", .data = "hello\x00world" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realpathAlloc(arena, ".");
    const entries = try walk.walk(arena, root, .{});
    const out = try std.fmt.allocPrint(arena, "{s}/index.idx", .{root});
    const stats = try build(gpa, root, entries, out, 2, .{});
    try std.testing.expectEqual(@as(usize, 3), stats.files);
    try std.testing.expectEqual(@as(usize, 1), stats.binary);

    var ix = try Index.open(out);
    defer ix.close();
    try std.testing.expectEqualStrings(root, ix.root);
    try std.testing.expectEqual(@as(u32, 3), ix.file_count);
    try std.testing.expectEqualStrings("b.txt", ix.file(1).path);
    try std.testing.expectEqual(@as(u32, 3), ix.countUnder(""));
    try std.testing.expectEqual(@as(u32, 0), ix.countUnder("nope"));

    const q = @import("query.zig");
    const hello = try q.plan(arena, try @import("regex.zig").parse(arena, "hello", .{}));
    const ids = (try ix.candidates(arena, hello.query)).?;
    try std.testing.expectEqualSlices(u32, &.{0}, ids);
    const world = try q.plan(arena, try @import("regex.zig").parse(arena, "WORLD", .{}));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, (try ix.candidates(arena, world.query)).?);
    const either = try q.plan(arena, try @import("regex.zig").parse(arena, "hello|goodbye", .{}));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, (try ix.candidates(arena, either.query)).?);
    const none = try q.plan(arena, try @import("regex.zig").parse(arena, "zebra", .{}));
    try std.testing.expectEqual(@as(usize, 0), (try ix.candidates(arena, none.query)).?.len);
}
