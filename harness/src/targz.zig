//! A GitHub repo as codeload.github.com serves it (a tar.gz whose pax
//! global header names the commit), read for `harness skill add`: the
//! commit, and the files under one path, within limits. Only those files
//! are looked at; a link, an absolute path, `..` or a name Windows can't
//! hold among them refuses the whole archive. `write` makes such an
//! archive (stored, not compressed), for the tests and harness-fake.
const std = @import("std");
const skillsrc = @import("skillsrc.zig");
const Io = std.Io;

pub const Opts = struct {
    /// Keep the files under this path in the repo ("" for all of it).
    path: []const u8 = "",
    /// Most files and bytes kept from the whole archive (a skill's own
    /// limits are its reader's: skill_cmd.zig).
    max_files: usize = 5000,
    max_bytes: usize = 200 * 1024 * 1024,
    /// A `SKILL.md` or another file over these is kept as its size alone
    /// (`Archive.oversize`), so the skill holding it is refused, not the archive.
    max_skill_md: usize = 64 * 1024,
    max_file: usize = 256 * 1024,
    /// Every entry's size together (what would be unpacked to read it).
    max_total: u64 = 1024 * 1024 * 1024,
    /// Keep only the files of skill folders of this name under `path` ("" for all).
    folder: []const u8 = "",
};

/// A file kept as its size alone, being over a skill's limit for one file.
pub const Oversize = struct { rel: []const u8, size: u64 };

pub const Archive = struct { commit: []const u8, files: []skillsrc.File, oversize: []const Oversize = &.{} };

/// Why an archive was refused.
pub const Diag = struct { why: []const u8 = "" };

/// One entry of an archive `write` makes: a file, a folder or a link.
pub const Entry = struct {
    name: []const u8,
    data: []const u8 = "",
    kind: enum { file, dir, link } = .file,
    link: []const u8 = "",
    exec: bool = false,
};

/// Reads `gz`: the commit its pax global header names (error.NoCommit
/// without one), and the files under `o.path` (paths relative to it, with
/// `/`), the top folder (`REPO-REF/`) taken off every name.
pub fn read(a: std.mem.Allocator, gz: []const u8, o: Opts, diag: *Diag) !Archive {
    if (o.path.len > 0 and !skillsrc.safeRel(std.mem.trim(u8, o.path, "/"))) return error.BadPath;
    const want = std.mem.trim(u8, o.path, "/");
    var in: Io.Reader = .fixed(gz);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, window);
    const r = &dec.reader;
    // the pax global header comes first: its comment is the commit
    var head: [512]u8 = undefined;
    r.readSliceAll(&head) catch return fail(diag, error.BadArchive, "it isn't a tar.gz");
    if (head[156] != 'g') return fail(diag, error.NoCommit, "the archive names no commit");
    const size = octal(head[124..136]) orelse return fail(diag, error.BadArchive, "its first header doesn't read");
    if (size > 64 * 1024) return fail(diag, error.BadArchive, "its first header is too long");
    const pax = try a.alloc(u8, std.mem.alignForward(usize, size, 512));
    r.readSliceAll(pax) catch return fail(diag, error.BadArchive, "it ends early");
    const found = paxComment(pax[0..size]) orelse "";
    if (found.len != 40) return fail(diag, error.NoCommit, "the archive names no commit");
    for (found) |c| if (!std.ascii.isHex(c)) return fail(diag, error.NoCommit, "the archive names no commit");
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(r, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var files: std.ArrayList(skillsrc.File) = .empty;
    var oversize: std.ArrayList(Oversize) = .empty;
    var total: u64 = 0;
    var bytes: u64 = 0;
    var kept: usize = 0;
    while (true) {
        const f = (it.next() catch return fail(diag, error.BadArchive, "an entry doesn't read")) orelse break;
        total += f.size;
        if (total > o.max_total) return fail(diag, error.TooLarge, try std.fmt.allocPrint(a, "it unpacks to more than {d} MB", .{o.max_total / (1024 * 1024)}));
        // the name without its top folder; an absolute one is refused
        if (f.name.len > 0 and f.name[0] == '/') return fail(diag, error.BadEntry, try std.fmt.allocPrint(a, "it holds an absolute path ({s})", .{f.name}));
        const slash = std.mem.indexOfScalar(u8, f.name, '/') orelse continue;
        const inner = std.mem.trimEnd(u8, f.name[slash + 1 ..], "/");
        if (inner.len == 0) continue;
        const rel = if (want.len == 0) inner else if (std.mem.startsWith(u8, inner, want) and inner.len > want.len and inner[want.len] == '/') inner[want.len + 1 ..] else continue;
        if (!inFolder(rel, want, o.folder)) continue;
        if (f.kind == .sym_link) return fail(diag, error.BadEntry, try std.fmt.allocPrint(a, "it holds a link ({s})", .{inner}));
        if (try skillsrc.badName(a, rel)) |why| return fail(diag, error.BadEntry, why);
        if (f.kind == .directory) continue;
        kept += 1;
        if (kept > o.max_files) return fail(diag, error.TooLarge, try std.fmt.allocPrint(a, "it has more than {d} files", .{o.max_files}));
        const is_md = std.mem.eql(u8, std.fs.path.basename(rel), "SKILL.md");
        const cap = if (is_md) o.max_skill_md else o.max_file;
        if (f.size > cap) {
            try oversize.append(a, .{ .rel = try a.dupe(u8, rel), .size = f.size });
            continue;
        }
        bytes += f.size;
        if (bytes > o.max_bytes) return fail(diag, error.TooLarge, try std.fmt.allocPrint(a, "its files are over {d} MB together", .{o.max_bytes / (1024 * 1024)}));
        var w: Io.Writer.Allocating = .init(a);
        it.streamRemaining(f, &w.writer) catch return fail(diag, error.BadArchive, "an entry ends early");
        try files.append(a, .{ .rel = try a.dupe(u8, rel), .data = w.written(), .exec = f.mode & 0o111 != 0 });
    }
    std.mem.sort(skillsrc.File, files.items, {}, struct {
        fn lt(_: void, x: skillsrc.File, y: skillsrc.File) bool {
            return std.mem.lessThan(u8, x.rel, y.rel);
        }
    }.lt);
    return .{ .commit = try a.dupe(u8, found), .files = files.items, .oversize = oversize.items };
}

/// Whether `rel` (a path under `path`) is in a skill folder named
/// `folder`: any part of it before the file, or `path`'s own last part.
fn inFolder(rel: []const u8, path: []const u8, folder: []const u8) bool {
    if (folder.len == 0) return true;
    if (std.mem.eql(u8, std.fs.path.basenamePosix(path), folder)) return true;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (it.index == null) return false;
        if (std.mem.eql(u8, part, folder)) return true;
    }
    return false;
}

fn fail(diag: *Diag, e: anyerror, why: []const u8) anyerror {
    diag.why = why;
    return e;
}

fn octal(field: []const u8) ?usize {
    const s = std.mem.trim(u8, field, " \x00");
    if (s.len == 0) return 0;
    return std.fmt.parseInt(usize, s, 8) catch null;
}

/// The `comment` record of a pax header ("LEN comment=VALUE\n" lines).
fn paxComment(text: []const u8) ?[]const u8 {
    var rest = text;
    while (rest.len > 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return null;
        if (len <= sp + 1 or len > rest.len) return null;
        const rec = rest[sp + 1 .. len - 1];
        if (std.mem.startsWith(u8, rec, "comment=")) return rec["comment=".len..];
        rest = rest[len..];
    }
    return null;
}

/// A tar.gz of `entries` with a pax global header naming `commit_id` (none
/// when ""), as codeload writes them; stored, not compressed.
pub fn write(a: std.mem.Allocator, commit_id: []const u8, entries: []const Entry) ![]u8 {
    var tar: std.ArrayList(u8) = .empty;
    if (commit_id.len > 0) {
        const rec = try paxRecord(a, "comment", commit_id);
        try header(a, &tar, "pax_global_header", rec.len, 'g', "", 0o666);
        try tar.appendSlice(a, rec);
        try pad(a, &tar);
    }
    for (entries) |e| {
        switch (e.kind) {
            .dir => try header(a, &tar, e.name, 0, '5', "", 0o755),
            .link => try header(a, &tar, e.name, 0, '2', e.link, 0o777),
            .file => {
                try header(a, &tar, e.name, e.data.len, '0', "", if (e.exec) 0o755 else 0o644);
                try tar.appendSlice(a, e.data);
                try pad(a, &tar);
            },
        }
    }
    try tar.appendNTimes(a, 0, 1024);
    return gzipStored(a, tar.items);
}

fn paxRecord(a: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    // the length counts its own digits
    var n = key.len + value.len + 3;
    while (true) {
        const s = try std.fmt.allocPrint(a, "{d} {s}={s}\n", .{ n, key, value });
        if (s.len == n) return s;
        n = s.len;
    }
}

fn pad(a: std.mem.Allocator, tar: *std.ArrayList(u8)) !void {
    try tar.appendNTimes(a, 0, std.mem.alignForward(usize, tar.items.len, 512) - tar.items.len);
}

fn header(a: std.mem.Allocator, tar: *std.ArrayList(u8), name: []const u8, size: usize, kind: u8, link: []const u8, mode: u32) !void {
    var h: [512]u8 = @splat(0);
    // a long name: a pax header before it with its path
    if (name.len > 100) {
        const rec = try paxRecord(a, "path", name);
        try header(a, tar, "././@PaxHeader", rec.len, 'x', "", 0o644);
        try tar.appendSlice(a, rec);
        try pad(a, tar);
        @memcpy(h[0..100], name[0..100]);
    } else @memcpy(h[0..name.len], name);
    _ = try std.fmt.bufPrint(h[100..107], "{o:0>7}", .{mode});
    _ = try std.fmt.bufPrint(h[108..115], "{o:0>7}", .{0});
    _ = try std.fmt.bufPrint(h[116..123], "{o:0>7}", .{0});
    _ = try std.fmt.bufPrint(h[124..135], "{o:0>11}", .{size});
    _ = try std.fmt.bufPrint(h[136..147], "{o:0>11}", .{1795521600});
    h[156] = kind;
    @memcpy(h[157 .. 157 + link.len], link);
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    _ = try std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{sum});
    try tar.appendSlice(a, &h);
}

/// gzip with stored deflate blocks: right for any reader, never smaller.
fn gzipStored(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff });
    var i: usize = 0;
    while (true) {
        const n = @min(data.len - i, 65535);
        const last = i + n == data.len;
        try out.append(a, if (last) 1 else 0);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u16, len[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, len[2..4], ~@as(u16, @intCast(n)), .little);
        try out.appendSlice(a, &len);
        try out.appendSlice(a, data[i .. i + n]);
        i += n;
        if (last) break;
    }
    var tail: [8]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, tail[4..8], @truncate(data.len), .little);
    try out.appendSlice(a, &tail);
    return out.items;
}

const t = std.testing;

const commit ="e4bb5d960d87126ff3b3a8af1a104b7db67560ba";

fn repo(a: std.mem.Allocator, extra: []const Entry) ![]u8 {
    var list: std.ArrayList(Entry) = .empty;
    try list.appendSlice(a, &.{
        .{ .name = "skills-main/", .kind = .dir },
        .{ .name = "skills-main/README.md", .data = "# skills\n" },
        .{ .name = "skills-main/skills/pdf/SKILL.md", .data = "---\nname: pdf\ndescription: PDFs.\n---\nUse it.\n" },
        .{ .name = "skills-main/skills/pdf/scripts/run.sh", .data = "#!/bin/sh\necho\n", .exec = true },
        .{ .name = "skills-main/skills/pdfx/SKILL.md", .data = "---\nname: pdfx\ndescription: Not this one.\n---\n" },
        .{ .name = "skills-main/elsewhere/link", .kind = .link, .link = "/etc/passwd" },
    });
    try list.appendSlice(a, extra);
    return write(a, commit, list.items);
}

test "an_archive_reads_its_commit_and_the_files_under_a_path" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const ar = try read(a, try repo(a, &.{}), .{ .path = "skills/pdf" }, &d);
    try t.expectEqualStrings(commit, ar.commit);
    try t.expectEqual(2, ar.files.len);
    try t.expectEqualStrings("SKILL.md", ar.files[0].rel);
    try t.expectEqualStrings("scripts/run.sh", ar.files[1].rel);
    try t.expect(ar.files[1].exec);
    try t.expect(!ar.files[0].exec);
    // the whole repo, a link outside what is kept refusing nothing
    try t.expectError(error.BadEntry, read(a, try repo(a, &.{}), .{}, &d));
    const no_link = try write(a, commit, &.{ .{ .name = "r-HEAD/SKILL.md", .data = "x" }, .{ .name = "r-HEAD/a/b.md", .data = "y" } });
    const whole = try read(a, no_link, .{}, &d);
    try t.expectEqual(2, whole.files.len);
    try t.expectEqualStrings("a/b.md", whole.files[1].rel);
    // a path naming nothing: no files
    try t.expectEqual(0, (try read(a, no_link, .{ .path = "missing" }, &d)).files.len);
}

test "hostile_entries_are_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { e: Entry, why: []const u8 }{
        .{ .e = .{ .name = "skills-main/skills/pdf/evil", .kind = .link, .link = "../../x" }, .why = "a link" },
        .{ .e = .{ .name = "skills-main/skills/pdf/../../../x", .data = "x" }, .why = ".." },
        .{ .e = .{ .name = "skills-main/skills/pdf/CON.txt", .data = "x" }, .why = "Windows" },
        .{ .e = .{ .name = "skills-main/skills/pdf/a:b", .data = "x" }, .why = "Windows" },
        .{ .e = .{ .name = "skills-main/skills/pdf/dot.", .data = "x" }, .why = "Windows" },
        .{ .e = .{ .name = "skills-main/skills/pdf/a\\b", .data = "x" }, .why = "Windows" },
    }) |c| {
        var d: Diag = .{};
        try t.expectError(error.BadEntry, read(a, try repo(a, &.{c.e}), .{ .path = "skills/pdf" }, &d));
        try t.expect(std.mem.indexOf(u8, d.why, c.why) != null);
    }
    var d: Diag = .{};
    try t.expectError(error.BadEntry, read(a, try write(a, commit, &.{.{ .name = "/abs/SKILL.md", .data = "x" }}), .{}, &d));
    try t.expectError(error.BadPath, read(a, try repo(a, &.{}), .{ .path = "../x" }, &d));
}

test "limits_stop_an_archive" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    // the archive's own caps (a skill's are its reader's): files, bytes, unpacked size
    var many: std.ArrayList(Entry) = .empty;
    for (0..11) |i| try many.append(a, .{ .name = try std.fmt.allocPrint(a, "r-m/s/f{d}.txt", .{i}), .data = "x" });
    try t.expectError(error.TooLarge, read(a, try write(a, commit, many.items), .{ .path = "s", .max_files = 10 }, &d));
    try t.expect(std.mem.indexOf(u8, d.why, "10 files") != null);
    const big = try a.alloc(u8, 256 * 1024 + 1);
    @memset(big, 'x');
    var heavy: std.ArrayList(Entry) = .empty;
    for (0..5) |i| try heavy.append(a, .{ .name = try std.fmt.allocPrint(a, "r-m/s/h{d}.bin", .{i}), .data = big[0 .. 200 * 1024] });
    try t.expectError(error.TooLarge, read(a, try write(a, commit, heavy.items), .{ .path = "s", .max_bytes = 512 * 1024 }, &d));
    try t.expectError(error.TooLarge, read(a, try write(a, commit, heavy.items), .{ .path = "other", .max_total = 512 * 1024 }, &d));
    // a file over a skill's 256 KB is kept as its size alone: the skill holding it is refused, not the archive
    const ar = try read(a, try write(a, commit, &.{ .{ .name = "r-m/s/a/SKILL.md", .data = "x" }, .{ .name = "r-m/s/b/big.bin", .data = big } }), .{ .path = "s" }, &d);
    try t.expectEqual(1, ar.files.len);
    try t.expectEqual(1, ar.oversize.len);
    try t.expectEqualStrings("b/big.bin", ar.oversize[0].rel);
    try t.expectEqual(big.len, ar.oversize[0].size);
    // only one skill's folder kept
    const one = try read(a, try write(a, commit, &.{ .{ .name = "r-m/s/a/SKILL.md", .data = "x" }, .{ .name = "r-m/s/b/big.bin", .data = big }, .{ .name = "r-m/s/b/SKILL.md", .data = "y" } }), .{ .path = "s", .folder = "a" }, &d);
    try t.expectEqual(1, one.files.len);
    try t.expectEqual(0, one.oversize.len);
}

test "an_archive_without_a_commit_is_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    try t.expectError(error.NoCommit, read(a, try write(a, "", &.{.{ .name = "r-m/SKILL.md", .data = "x" }}), .{}, &d));
    try t.expectError(error.NoCommit, read(a, try write(a, "not-a-commit", &.{.{ .name = "r-m/SKILL.md", .data = "x" }}), .{}, &d));
    try t.expectError(error.BadArchive, read(a, "not gzip at all", .{}, &d));
}
