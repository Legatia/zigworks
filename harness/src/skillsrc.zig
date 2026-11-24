//! Skills harness installs (`harness skill add`, `harness import hermes`):
//! a skill's files and their hash, installing them into `skills/NAME/`,
//! and `skills/.sources`, one line per installed skill with where it came
//! from, so `harness skill update` can fetch it again and tell an edited
//! one apart.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// One file of a skill: its path in the skill's folder (with `/`), its
/// bytes, and whether it runs (kept for `scripts/` on Linux and macOS).
pub const File = struct { rel: []const u8, data: []const u8, exec: bool = false };

fn lessFile(_: void, x: File, y: File) bool {
    return std.mem.lessThan(u8, x.rel, y.rel);
}

/// A skill's hash: SHA-256 over its files in path order, each its path,
/// its length and its bytes; lowercase hex.
pub fn hashFiles(a: std.mem.Allocator, files: []const File) ![64]u8 {
    const sorted = try a.dupe(File, files);
    std.mem.sort(File, sorted, {}, lessFile);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted) |f| {
        var len: [32]u8 = undefined;
        h.update(f.rel);
        h.update("\x00");
        h.update(std.fmt.bufPrint(&len, "{d}\x00", .{f.data.len}) catch unreachable);
        h.update(f.data);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// Most files read from a folder, and most bytes in all.
pub const max_files = 300;
pub const max_total = 10 * 1024 * 1024;

/// A skill folder's files (paths with `/`), up to the limits
/// (error.TooLarge past them); links and `.tmp` files left out.
pub fn readFolder(io: Io, a: std.mem.Allocator, folder: []const u8) ![]File {
    var out: std.ArrayList(File) = .empty;
    var total: usize = 0;
    try readInto(io, a, folder, "", &out, &total);
    std.mem.sort(File, out.items, {}, lessFile);
    return out.items;
}

fn readInto(io: Io, a: std.mem.Allocator, folder: []const u8, rel: []const u8, out: *std.ArrayList(File), total: *usize) !void {
    const here = if (rel.len == 0) folder else try std.fs.path.join(a, &.{ folder, rel });
    var d = try Io.Dir.cwd().openDir(io, here, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const r = if (rel.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, e.name });
        switch (e.kind) {
            .directory => try readInto(io, a, folder, r, out, total),
            .file => {
                if (std.mem.endsWith(u8, e.name, ".tmp")) continue;
                if (out.items.len >= max_files) return error.TooLarge;
                const data = d.readFileAlloc(io, e.name, a, .limited(max_total - total.* + 1)) catch |err| switch (err) {
                    error.StreamTooLong => return error.TooLarge,
                    else => return err,
                };
                total.* += data.len;
                if (total.* > max_total) return error.TooLarge;
                const exec = builtin.os.tag != .windows and if (d.statFile(io, e.name, .{})) |st| st.permissions.toMode() & 0o111 != 0 else |_| false;
                try out.append(a, .{ .rel = r, .data = data, .exec = exec });
            },
            else => {},
        }
    }
}

/// The hash of a skill folder as it is now (`hashFiles` of its files).
pub fn hashFolder(io: Io, a: std.mem.Allocator, folder: []const u8) ![64]u8 {
    return hashFiles(a, try readFolder(io, a, folder));
}

// ---- skills/.sources ----

/// One installed skill: its name, where it came from (a folder,
/// `OWNER/REPO[/PATH][@REF]`, a link, or `hermes`), the commit or link it
/// was pinned to ("-" for none), its hash when installed, and when.
pub const Line = struct { name: []const u8, source: []const u8, pin: []const u8, hash: []const u8, time: []const u8 };

pub const sources_file = ".sources";

/// `skills/.sources`, a line each (tab-separated); a line that doesn't
/// read is skipped.
pub fn readSources(io: Io, a: std.mem.Allocator, skills_dir: []const u8) ![]Line {
    const p = try std.fs.path.join(a, &.{ skills_dir, sources_file });
    const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0 or l[0] == '#') continue;
        var f = std.mem.splitScalar(u8, l, '\t');
        const line: Line = .{
            .name = f.next() orelse continue,
            .source = f.next() orelse continue,
            .pin = f.next() orelse continue,
            .hash = f.next() orelse continue,
            .time = f.next() orelse continue,
        };
        if (f.next() != null or line.name.len == 0 or line.source.len == 0) continue;
        try out.append(a, line);
    }
    return out.items;
}

pub fn writeSources(io: Io, a: std.mem.Allocator, skills_dir: []const u8, lines: []const Line) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# Installed skills: name, source, commit or link, hash, time (harness skill list)\n");
    for (lines) |l| try out.print(a, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ l.name, l.source, l.pin, l.hash, l.time });
    try @import("util.zig").writeReplace(io, try std.fs.path.join(a, &.{ skills_dir, sources_file }), out.items);
}

/// Adds `line`, replacing the line of the same name; sorted by name.
pub fn putSource(io: Io, a: std.mem.Allocator, skills_dir: []const u8, line: Line) !void {
    var lines: std.ArrayList(Line) = .empty;
    for (try readSources(io, a, skills_dir)) |l| if (!std.mem.eql(u8, l.name, line.name)) try lines.append(a, l);
    try lines.append(a, line);
    std.mem.sort(Line, lines.items, {}, struct {
        fn lt(_: void, x: Line, y: Line) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    try writeSources(io, a, skills_dir, lines.items);
}

/// Removes `name`'s line; whether it had one.
pub fn dropSource(io: Io, a: std.mem.Allocator, skills_dir: []const u8, name: []const u8) !bool {
    var lines: std.ArrayList(Line) = .empty;
    var found = false;
    for (try readSources(io, a, skills_dir)) |l| {
        if (std.mem.eql(u8, l.name, name)) found = true else try lines.append(a, l);
    }
    if (found) try writeSources(io, a, skills_dir, lines.items);
    return found;
}

pub fn findSource(lines: []const Line, name: []const u8) ?Line {
    for (lines) |l| if (std.mem.eql(u8, l.name, name)) return l;
    return null;
}

// ---- installing ----

/// Whether a path in a skill stays in it: relative, `/` between parts,
/// none empty, `.` or `..`.
pub fn safeRel(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/' or std.mem.indexOfAny(u8, rel, "\\\x00:") != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Writes `files` as `skills_dir/NAME/`, whole or not at all: into a
/// hidden folder beside it, then renamed. error.Exists when there is one;
/// error.BadPath for a path that would leave it. The executable bit is
/// kept for files under `scripts/` (Linux and macOS).
pub fn install(io: Io, a: std.mem.Allocator, skills_dir: []const u8, name: []const u8, files: []const File) !void {
    for (files) |f| if (!safeRel(f.rel)) return error.BadPath;
    const cwd = Io.Dir.cwd();
    const dest = try std.fs.path.join(a, &.{ skills_dir, name });
    if (cwd.statFile(io, dest, .{ .follow_symlinks = false })) |_| return error.Exists else |_| {}
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fs.path.join(a, &.{ skills_dir, try std.fmt.allocPrint(a, ".{s}.install-{s}", .{ name, &std.fmt.bytesToHex(rnd, .lower) }) });
    try cwd.createDirPath(io, tmp);
    errdefer cwd.deleteTree(io, tmp) catch {};
    for (files) |f| {
        const parts = try a.dupe(u8, f.rel);
        for (parts) |*c| if (c.* == '/') {
            c.* = std.fs.path.sep;
        };
        const path = try std.fs.path.join(a, &.{ tmp, parts });
        if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
        const exec = builtin.os.tag != .windows and f.exec and std.mem.startsWith(u8, f.rel, "scripts/");
        var file = try cwd.createFile(io, path, .{ .exclusive = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(if (exec) 0o700 else 0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, f.data);
    }
    try cwd.rename(tmp, cwd, dest, io);
}

const t = std.testing;

test "a_skills_hash_covers_names_and_contents" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_]File{ .{ .rel = "SKILL.md", .data = "---\nname: x\n---\n" }, .{ .rel = "scripts/run.sh", .data = "echo" } };
    const reordered = [_]File{ one[1], one[0] };
    const h = try hashFiles(a, &one);
    // the order given doesn't count; a name or a byte does
    try t.expectEqualStrings(&h, &(try hashFiles(a, &reordered)));
    try t.expect(!std.mem.eql(u8, &h, &(try hashFiles(a, &.{ one[0], .{ .rel = "scripts/run2.sh", .data = "echo" } }))));
    try t.expect(!std.mem.eql(u8, &h, &(try hashFiles(a, &.{ one[0], .{ .rel = "scripts/run.sh", .data = "echo!" } }))));
    // a name and bytes can't be shifted into each other
    try t.expect(!std.mem.eql(u8, &(try hashFiles(a, &.{.{ .rel = "ab", .data = "c" }})), &(try hashFiles(a, &.{.{ .rel = "a", .data = "bc" }}))));
    // a folder hashes as its files
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "s/scripts");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s/SKILL.md", .data = one[0].data });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s/scripts/run.sh", .data = one[1].data });
    const dir = try tmp.dir.realPathFileAlloc(t.io, "s", a);
    try t.expectEqualStrings(&h, &(try hashFolder(t.io, a, dir)));
}

test "sources_lines_round_trip" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "skills");
    const dir = try tmp.dir.realPathFileAlloc(t.io, "skills", a);
    try t.expectEqual(0, (try readSources(t.io, a, dir)).len);
    try putSource(t.io, a, dir, .{ .name = "pdf", .source = "anthropics/skills/skills/pdf", .pin = "e4bb5d960d87126ff3b3a8af1a104b7db67560ba", .hash = "abababababababababababababababababababababababababababababababab", .time = "2026-11-24T12:00:00Z" });
    try putSource(t.io, a, dir, .{ .name = "notes", .source = "/home/me/My Skills/notes", .pin = "-", .hash = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .time = "2026-11-24T12:00:00Z" });
    // the same name again replaces its line
    try putSource(t.io, a, dir, .{ .name = "pdf", .source = "anthropics/skills/skills/pdf", .pin = "1111111111111111111111111111111111111111", .hash = "efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef", .time = "2026-11-25T12:00:00Z" });
    const got = try readSources(t.io, a, dir);
    try t.expectEqual(2, got.len);
    try t.expectEqualStrings("notes", got[0].name);
    try t.expectEqualStrings("/home/me/My Skills/notes", got[0].source);
    try t.expectEqualStrings("pdf", got[1].name);
    try t.expectEqualStrings("1111111111111111111111111111111111111111", got[1].pin);
    try t.expectEqualStrings("efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef", got[1].hash);
    try t.expect(dropSource(t.io, a, dir, "notes") catch false);
    try t.expectEqual(1, (try readSources(t.io, a, dir)).len);
    // a line that doesn't read is skipped, the rest kept
    try tmp.dir.writeFile(t.io, .{ .sub_path = "skills/.sources", .data = "broken line\r\nx\tsrc\t-\t" ++ "0000000000000000000000000000000000000000000000000000000000000000" ++ "\t2026-11-24T12:00:00Z\r\n" });
    try t.expectEqual(1, (try readSources(t.io, a, dir)).len);
}

test "install_writes_the_folder_whole" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "skills");
    const dir = try tmp.dir.realPathFileAlloc(t.io, "skills", a);
    const files = [_]File{ .{ .rel = "SKILL.md", .data = "---\nname: x\ndescription: d\n---\n" }, .{ .rel = "scripts/run.sh", .data = "echo", .exec = true }, .{ .rel = "notes/a.txt", .data = "n", .exec = true } };
    try install(t.io, a, dir, "x", &files);
    try t.expectEqualStrings("echo", try tmp.dir.readFileAlloc(t.io, "skills/x/scripts/run.sh", a, .unlimited));
    if (builtin.os.tag != .windows) {
        // the executable bit is kept for scripts/ alone
        try t.expect((try tmp.dir.statFile(t.io, "skills/x/scripts/run.sh", .{})).permissions.toMode() & 0o100 != 0);
        try t.expect((try tmp.dir.statFile(t.io, "skills/x/notes/a.txt", .{})).permissions.toMode() & 0o111 == 0);
    }
    try t.expectError(error.Exists, install(t.io, a, dir, "x", &files));
    for ([_][]const u8{ "../x", "/abs", "a/../../b", "a\\b", "" }) |bad| {
        try t.expectError(error.BadPath, install(t.io, a, dir, "y", &.{.{ .rel = bad, .data = "" }}));
    }
    // nothing left of a refused one
    var d = try tmp.dir.openDir(t.io, "skills", .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(t.io)) |_| n += 1;
    try t.expectEqual(1, n);
}
