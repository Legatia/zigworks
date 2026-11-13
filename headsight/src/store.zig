//! Crop files and named references under $TMPDIR/headsight. Crops older than
//! a day and references older than an hour are removed when a store opens.
const std = @import("std");
const frame = @import("frame.zig");
const args = @import("args.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;

pub const crop_max_age_s: i64 = 86_400;
pub const ref_max_age_s: i64 = 3_600;
const magic = "HSREF001";

pub const RefMeta = struct {
    source: args.Source,
    window_id: u32 = 0,
    region: Rect,
    created_s: i64,
    src_w: u32,
    src_h: u32,
};

pub const Ref = struct {
    meta: RefMeta,
    /// The region's pixels, tight stride.
    frame: Frame,
    buf: []u8,

    pub fn deinit(r: *Ref, alloc: std.mem.Allocator) void {
        alloc.free(r.buf);
    }
};

pub const Error = error{ BadName, NoSuchRef, RefExpired, BadRef };

pub const Store = struct {
    alloc: std.mem.Allocator,
    base: []const u8,
    dir: std.fs.Dir,
    counter: u32 = 0,

    pub fn open(alloc: std.mem.Allocator, base: []const u8, now_s: i64) !Store {
        try std.fs.cwd().makePath(base);
        var dir = try std.fs.cwd().openDir(base, .{ .iterate = true });
        errdefer dir.close();
        var s = Store{ .alloc = alloc, .base = try alloc.dupe(u8, base), .dir = dir };
        s.cleanup(now_s);
        return s;
    }

    fn cleanup(s: *Store, now_s: i64) void {
        var it = s.dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".png")) continue;
            const st = s.dir.statFile(e.name) catch continue;
            if (now_s - @as(i64, @intCast(@divFloor(st.mtime, std.time.ns_per_s))) > crop_max_age_s)
                s.dir.deleteFile(e.name) catch {};
        }
        var refs = s.dir.openDir("ref", .{ .iterate = true }) catch return;
        defer refs.close();
        var rit = refs.iterate();
        while (rit.next() catch null) |e| {
            if (e.kind != .file) continue;
            const created = if (std.mem.endsWith(u8, e.name, ".ref")) createdOf(refs, e.name) else blk: {
                const st = refs.statFile(e.name) catch continue;
                break :blk @as(i64, @intCast(@divFloor(st.mtime, std.time.ns_per_s)));
            };
            if (now_s - created > ref_max_age_s) refs.deleteFile(e.name) catch {};
        }
    }

    pub fn close(s: *Store) void {
        s.dir.close();
        s.alloc.free(s.base);
    }

    /// A new crop file path, owned by the caller.
    pub fn cropPath(s: *Store) ![]const u8 {
        s.counter += 1;
        return std.fmt.allocPrint(s.alloc, "{s}/{x}-{d}.png", .{ s.base, @as(u32, @intCast(std.c.getpid())), s.counter });
    }

    pub fn saveRef(s: *Store, name: []const u8, meta: RefMeta, f: Frame) !void {
        if (!args.validName(name)) return error.BadName;
        std.debug.assert(f.full().contains(meta.region));
        var refs = try s.dir.makeOpenPath("ref", .{});
        defer refs.close();
        var tmp_buf: [80]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{name});
        var final_buf: [80]u8 = undefined;
        const final = try std.fmt.bufPrint(&final_buf, "{s}.ref", .{name});

        var file = try refs.createFile(tmp, .{ .mode = 0o600, .truncate = true });
        errdefer refs.deleteFile(tmp) catch {};
        defer file.close();
        try file.chmod(0o600);
        const label: []const u8 = switch (meta.source) {
            .screen => "",
            .window => |t| t,
            .camera => |n| n orelse "",
        };
        var hdr: [header_len]u8 = undefined;
        @memcpy(hdr[0..8], magic);
        const fields = [_]u32{ meta.src_w, meta.src_h, meta.region.x, meta.region.y, meta.region.w, meta.region.h, meta.window_id, @intFromEnum(meta.source) };
        for (fields, 0..) |v, i| std.mem.writeInt(u32, hdr[8 + i * 4 ..][0..4], v, .little);
        std.mem.writeInt(i64, hdr[40..48], meta.created_s, .little);
        std.mem.writeInt(u16, hdr[48..50], @intCast(@min(label.len, 4096)), .little);
        try file.writeAll(&hdr);
        try file.writeAll(label[0..@min(label.len, 4096)]);
        const r = meta.region;
        var y = r.y;
        while (y < r.bottom()) : (y += 1)
            try file.writeAll(f.px[@as(usize, y) * f.stride + @as(usize, r.x) * 4 ..][0 .. @as(usize, r.w) * 4]);
        try refs.rename(tmp, final);
    }

    pub fn loadRef(s: *Store, name: []const u8, now_s: i64) !Ref {
        if (!args.validName(name)) return error.BadName;
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "ref/{s}.ref", .{name});
        const buf = s.dir.readFileAlloc(s.alloc, path, 1 << 31) catch |e| switch (e) {
            error.FileNotFound => return error.NoSuchRef,
            else => return e,
        };
        errdefer s.alloc.free(buf);
        if (buf.len < header_len or !std.mem.eql(u8, buf[0..8], magic)) return error.BadRef;
        var v: [8]u32 = undefined;
        for (&v, 0..) |*x, i| x.* = std.mem.readInt(u32, buf[8 + i * 4 ..][0..4], .little);
        const created = std.mem.readInt(i64, buf[40..48], .little);
        const label_len = std.mem.readInt(u16, buf[48..50], .little);
        if (now_s - created > ref_max_age_s) {
            s.dir.deleteFile(path) catch {};
            return error.RefExpired;
        }
        const region = Rect{ .x = v[2], .y = v[3], .w = v[4], .h = v[5] };
        const px_start = header_len + @as(usize, label_len);
        if (buf.len != px_start + @as(usize, region.w) * region.h * 4) return error.BadRef;
        const label = buf[header_len..px_start];
        const source: args.Source = switch (v[7]) {
            0 => .screen,
            1 => .{ .window = label },
            2 => .{ .camera = if (label.len == 0) null else label },
            else => return error.BadRef,
        };
        return .{
            .meta = .{ .source = source, .window_id = v[6], .region = region, .created_s = created, .src_w = v[0], .src_h = v[1] },
            .frame = .{ .px = buf[px_start..], .w = region.w, .h = region.h, .stride = region.w * 4 },
            .buf = buf,
        };
    }

    pub fn dropRef(s: *Store, name: []const u8) !bool {
        if (!args.validName(name)) return error.BadName;
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "ref/{s}.ref", .{name});
        s.dir.deleteFile(path) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        return true;
    }
};

pub fn checkSize(ref: Ref, src_w: u32, src_h: u32) error{SizeChanged}!void {
    if (ref.meta.src_w != src_w or ref.meta.src_h != src_h) return error.SizeChanged;
}

const header_len = 8 + 8 * 4 + 8 + 2;

fn createdOf(dir: std.fs.Dir, name: []const u8) i64 {
    var f = dir.openFile(name, .{}) catch return 0;
    defer f.close();
    var hdr: [header_len]u8 = undefined;
    const n = f.readAll(&hdr) catch return 0;
    if (n < header_len or !std.mem.eql(u8, hdr[0..8], magic)) return 0;
    return std.mem.readInt(i64, hdr[40..48], .little);
}

// ---- tests ----

const testing = std.testing;

const T = struct {
    tmp: std.testing.TmpDir,
    base: []const u8,

    fn init() !T {
        var tmp = std.testing.tmpDir(.{});
        const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
        defer testing.allocator.free(root);
        return .{ .tmp = tmp, .base = try std.fs.path.join(testing.allocator, &.{ root, "headsight" }) };
    }
    fn deinit(t: *T) void {
        testing.allocator.free(t.base);
        t.tmp.cleanup();
    }
};

fn pattern(w: u32, h: u32) ![]u8 {
    const px = try testing.allocator.alloc(u8, w * h * 4);
    for (px, 0..) |*p, i| p.* = @truncate(i *% 7);
    return px;
}

fn nowS() i64 {
    return std.time.timestamp();
}

fn testMeta(created: i64) RefMeta {
    return .{ .source = .{ .window = "Safari" }, .window_id = 42, .region = .{ .x = 5, .y = 5, .w = 20, .h = 10 }, .created_s = created, .src_w = 40, .src_h = 30 };
}

test "ref_roundtrip" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    const now = nowS();
    try s.saveRef("before", testMeta(now), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    var r = try s.loadRef("before", now + 10);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("Safari", r.meta.source.window);
    try testing.expectEqual(@as(u32, 42), r.meta.window_id);
    try testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 20, .h = 10 }, r.meta.region);
    try testing.expectEqual(@as(u32, 20), r.frame.w);
    try testing.expectEqual(@as(u32, 10), r.frame.h);
    // row 0 of the reference is row 5 of the source from column 5
    try testing.expectEqualSlices(u8, px[(5 * 40 + 5) * 4 ..][0 .. 20 * 4], r.frame.px[0 .. 20 * 4]);
    try testing.expectEqualSlices(u8, px[(14 * 40 + 5) * 4 ..][0 .. 20 * 4], r.frame.px[9 * 80 ..][0 .. 20 * 4]);
}

test "ref_mode_0600" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("m", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    const st = try s.dir.statFile("ref/m.ref");
    try testing.expectEqual(@as(std.fs.File.Mode, 0o600), st.mode & 0o777);
}

test "ref_expires_after_hour" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    const now = nowS();
    try s.saveRef("old", testMeta(now), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    try testing.expectError(error.RefExpired, s.loadRef("old", now + 3601));
    try testing.expectError(error.FileNotFound, s.dir.statFile("ref/old.ref"));
}

test "drop_ref" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("d", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    try testing.expect(try s.dropRef("d"));
    try testing.expect(!(try s.dropRef("d")));
    try testing.expectError(error.NoSuchRef, s.loadRef("d", nowS()));
}

test "cleanup_old_crops" {
    var t = try T.init();
    defer t.deinit();
    {
        var s = try Store.open(testing.allocator, t.base, nowS());
        defer s.close();
        const p = try s.cropPath();
        defer testing.allocator.free(p);
        (try std.fs.cwd().createFile(p, .{})).close();
        var s2 = try Store.open(testing.allocator, t.base, nowS() + 3600);
        s2.close();
        try std.fs.cwd().access(p, .{});
        var s3 = try Store.open(testing.allocator, t.base, nowS() + 25 * 3600);
        s3.close();
        try testing.expectError(error.FileNotFound, std.fs.cwd().access(p, .{}));
    }
}

test "old_refs_removed_on_open" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("r", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    var s2 = try Store.open(testing.allocator, t.base, nowS() + 3700);
    s2.close();
    try testing.expectError(error.FileNotFound, s.dir.statFile("ref/r.ref"));
}

test "size_mismatch_reported" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("z", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    var r = try s.loadRef("z", nowS());
    defer r.deinit(testing.allocator);
    try testing.expectError(error.SizeChanged, checkSize(r, 41, 30));
    try checkSize(r, 40, 30);
}

test "bad_names_rejected" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try testing.expectError(error.BadName, s.saveRef("../x", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 }));
    try testing.expectError(error.BadName, s.loadRef("../x", nowS()));
    try testing.expectError(error.FileNotFound, s.dir.statFile("x.ref"));
}
