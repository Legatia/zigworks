//! Boxes on disk: which there are, snapshots of them, and what an app
//! changed in one. A box is a directory: `upper` holds what was written
//! since the last snapshot, `layers/NNNN-LABEL` the snapshots.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const box = @import("box.zig");

const path = box.path;
const info = box.info;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [2400]u8 = undefined;
    sys.writeAll(1, std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return) catch {};
}

/// The pid of the desktop that has the box open, if one does.
pub fn inUse(box_dir: []const u8) ?sys.pid_t {
    const lock_file = path("{s}/lock", .{box_dir});
    const fd = sys.openRead(lock_file.z()) catch return null;
    defer sys.close(fd);
    var buf: [32]u8 = undefined;
    const n = sys.read(fd, &buf) catch return null;
    const pid = std.fmt.parseInt(sys.pid_t, std.mem.trim(u8, buf[0..n], " \n"), 10) catch return null;
    return if (sys.alive(pid)) pid else null;
}

/// Marks the box as open by this process and notes where its home is shown.
pub fn lock(box_dir: []const u8, home: []const u8) void {
    box.mkdirAll(box_dir);
    var buf: [32]u8 = undefined;
    const l = path("{s}/lock", .{box_dir});
    _ = box.writeFile(l.z(), std.fmt.bufPrint(&buf, "{d}\n", .{linux.getpid()}) catch return);
    const h = path("{s}/home-path", .{box_dir});
    _ = box.writeFile(h.z(), home);
}

pub fn unlock(box_dir: []const u8) void {
    const l = path("{s}/lock", .{box_dir});
    _ = linux.unlink(l.z().ptr);
}

pub fn exists(box_dir: []const u8) bool {
    const p = path("{s}", .{box_dir});
    return info(p.z()).kind == .dir;
}

pub fn validLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 40) return false;
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return label[0] != '.' and label[0] != '-';
}

/// "0003-name" is the snapshot "name".
fn labelOf(layer: []const u8) []const u8 {
    return if (layer.len > 5 and layer[4] == '-') layer[5..] else layer;
}

pub const Error = error{ InUse, NoSuchBox, NoSuchSnapshot, Exists, Failed };

/// Freezes what the box holds now under `label`; the box goes on from there.
pub fn snapshot(box_dir: []const u8, label: []const u8) Error!void {
    if (!exists(box_dir)) return error.NoSuchBox;
    if (inUse(box_dir) != null) return error.InUse;
    const layers = box.readLayers(box_dir);
    var next: u32 = 1;
    for (0..layers.count) |i| {
        const name = layers.name(i);
        if (std.mem.eql(u8, labelOf(name), label)) return error.Exists;
        if (name.len >= 4) next = @max(next, (std.fmt.parseInt(u32, name[0..4], 10) catch 0) + 1);
    }
    const dir = path("{s}/layers", .{box_dir});
    box.mkdirAll(dir.z());
    const upper = path("{s}/upper", .{box_dir});
    box.mkdirAll(upper.z());
    const to = path("{s}/layers/{d:0>4}-{s}", .{ box_dir, next, label });
    if (linux.errno(linux.rename(upper.z().ptr, to.z().ptr)) != .SUCCESS) return error.Failed;
    box.mkdirAll(upper.z());
}

/// Goes back to snapshot `label`: everything after it is thrown away.
pub fn restore(box_dir: []const u8, label: []const u8) Error!void {
    if (!exists(box_dir)) return error.NoSuchBox;
    if (inUse(box_dir) != null) return error.InUse;
    const layers = box.readLayers(box_dir);
    var found: ?usize = null;
    for (0..layers.count) |i| {
        if (std.mem.eql(u8, labelOf(layers.name(i)), label)) found = i;
    }
    const keep = found orelse return error.NoSuchSnapshot;
    // newest first: everything before `keep` is newer
    for (0..keep) |i| {
        const p = path("{s}/layers/{s}", .{ box_dir, layers.name(i) });
        box.removeTree(p.z());
    }
    const upper = path("{s}/upper", .{box_dir});
    box.removeTree(upper.z());
    box.mkdirAll(upper.z());
}

/// Throws away everything the box holds, snapshots included.
pub fn reset(box_dir: []const u8) Error!void {
    if (!exists(box_dir)) return error.NoSuchBox;
    if (inUse(box_dir) != null) return error.InUse;
    for ([_][]const u8{ "upper", "work", "layers" }) |part| {
        const p = path("{s}/{s}", .{ box_dir, part });
        box.removeTree(p.z());
    }
}

pub fn delete(box_dir: []const u8) Error!void {
    if (!exists(box_dir)) return error.NoSuchBox;
    if (inUse(box_dir) != null) return error.InUse;
    const p = path("{s}", .{box_dir});
    box.removeTree(p.z());
}

/// Prints the box's snapshots, oldest first.
pub fn listSnapshots(box_dir: []const u8) void {
    const layers = box.readLayers(box_dir);
    var i = layers.count;
    while (i > 0) {
        i -= 1;
        say("snapshot {s}", .{labelOf(layers.name(i))});
    }
}

/// Prints every box in `boxes_dir`: name, number of snapshots, whether a
/// desktop has it open.
pub fn list(boxes_dir: []const u8) void {
    const dir = path("{s}", .{boxes_dir});
    const rc = linux.open(dir.z().ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: sys.fd_t = @intCast(rc);
    defer sys.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (name[0] == '.') continue;
            const box_dir = path("{s}/{s}", .{ boxes_dir, name });
            if (info(box_dir.z()).kind != .dir) continue;
            const layers = box.readLayers(box_dir.z());
            if (inUse(box_dir.z())) |pid| {
                say("{s} snapshots={d} open pid={d}", .{ name, layers.count, pid });
            } else say("{s} snapshots={d} closed", .{ name, layers.count });
        }
    }
}

const Diff = struct {
    box_dir: []const u8,
    layers: box.Layers,
    home: []const u8,
    count: usize = 0,
    /// Walking "@split".
    split: bool = false,
};

/// Prints what the box has changed since its last snapshot (or since it
/// was made): `added`, `changed` or `deleted`, and the path as the app
/// sees it. Returns how many entries.
pub fn diff(box_dir: []const u8) Error!usize {
    if (!exists(box_dir)) return error.NoSuchBox;
    var home_buf: [512]u8 = undefined;
    var home: []const u8 = "~";
    const hp = path("{s}/home-path", .{box_dir});
    if (sys.openRead(hp.z())) |fd| {
        const n = sys.read(fd, &home_buf) catch 0;
        sys.close(fd);
        if (n > 0) home = std.mem.trim(u8, home_buf[0..n], " \n");
    } else |_| {}
    var d: Diff = .{ .box_dir = box_dir, .layers = box.readLayers(box_dir), .home = home };
    const upper = path("{s}/upper", .{box_dir});
    diffDir(&d, upper.z(), "");
    return d.count;
}

/// Whether `rel` ("usr/bin/x" or "@home/notes") was there before this
/// upper layer: in an older snapshot or in the system itself.
fn wasThere(d: *const Diff, rel: []const u8) bool {
    for (0..d.layers.count) |i| {
        const p = path("{s}/layers/{s}/{s}", .{ d.box_dir, d.layers.name(i), rel });
        if (info(p.z()).kind != .none) return true;
    }
    if (std.mem.startsWith(u8, rel, "@home")) return false;
    if (d.split) {
        for (0..d.layers.count) |i| {
            const p = path("{s}/layers/{s}/@split/{s}", .{ d.box_dir, d.layers.name(i), rel });
            if (info(p.z()).kind != .none) return true;
        }
    }
    const p = path("/{s}", .{rel});
    return info(p.z()).kind != .none;
}

fn diffDir(d: *Diff, dir: [:0]const u8, rel: []const u8) void {
    const rc = linux.open(dir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: sys.fd_t = @intCast(rc);
    defer sys.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            // "@split" holds what was written directly in directories that
            // had to be taken apart; its paths are the system's own
            if (rel.len == 0 and std.mem.eql(u8, name, "@split")) {
                const inner = path("{s}/@split", .{dir});
                d.split = true;
                diffDir(d, inner.z(), "");
                d.split = false;
                continue;
            }
            const full = path("{s}/{s}", .{ dir, name });
            const child = if (rel.len == 0) path("{s}", .{name}) else path("{s}/{s}", .{ rel, name });
            // as the app sees it
            const shown = if (std.mem.startsWith(u8, child.z(), "@home")) path("{s}{s}", .{ d.home, child.z()["@home".len..] }) else path("/{s}", .{child.z()});
            var st: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, full.z().ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &st)) != .SUCCESS) continue;
            const kind = st.mode & linux.S.IFMT;
            if (d.split and kind != linux.S.IFDIR) {
                // stand-ins for what the system has there: an empty file under
                // a read-only file, a copy of a link
                const real = path("/{s}", .{child.z()});
                const there = info(real.z()).kind;
                if ((kind == linux.S.IFLNK and there == .link) or (kind == linux.S.IFREG and st.size == 0 and there == .other)) continue;
            }
            if (kind == linux.S.IFCHR and st.rdev_major == 0 and st.rdev_minor == 0) {
                say("deleted {s}", .{shown.z()});
                d.count += 1;
            } else if (kind == linux.S.IFDIR) {
                if (rel.len > 0 and !wasThere(d, child.z())) {
                    say("added   {s}/", .{shown.z()});
                    d.count += 1;
                }
                diffDir(d, full.z(), child.z());
            } else {
                say("{s} {s}", .{ if (wasThere(d, child.z())) "changed" else "added  ", shown.z() });
                d.count += 1;
            }
        }
    }
}

test "labels" {
    try std.testing.expect(validLabel("clean"));
    try std.testing.expect(validLabel("after-install_2"));
    try std.testing.expect(!validLabel(""));
    try std.testing.expect(!validLabel("a/b"));
    try std.testing.expect(!validLabel("-x"));
    try std.testing.expectEqualStrings("clean", labelOf("0001-clean"));
}

test "snapshot, restore and reset move directories as they should" {
    const base = "/tmp/headdesk-boxtest";
    box.removeTree(base);
    defer box.removeTree(base);
    try std.testing.expectError(error.NoSuchBox, snapshot(base, "a"));
    box.mkdirAll(base ++ "/upper/etc");
    try std.testing.expect(box.writeFile(base ++ "/upper/etc/one", "1"));
    try snapshot(base, "first");
    try std.testing.expectEqual(box.Kind.other, info(base ++ "/layers/0001-first/etc/one").kind);
    try std.testing.expectEqual(box.Kind.none, info(base ++ "/upper/etc").kind);
    try std.testing.expectError(error.Exists, snapshot(base, "first"));
    box.mkdirAll(base ++ "/upper/etc");
    try std.testing.expect(box.writeFile(base ++ "/upper/etc/two", "2"));
    try snapshot(base, "second");
    try std.testing.expect(box.writeFile(base ++ "/upper/three", "3"));
    try std.testing.expectError(error.NoSuchSnapshot, restore(base, "nope"));
    try restore(base, "first");
    try std.testing.expectEqual(box.Kind.other, info(base ++ "/layers/0001-first/etc/one").kind);
    try std.testing.expectEqual(box.Kind.none, info(base ++ "/layers/0002-second").kind);
    try std.testing.expectEqual(box.Kind.none, info(base ++ "/upper/three").kind);
    try reset(base);
    try std.testing.expectEqual(box.Kind.none, info(base ++ "/layers").kind);
    try delete(base);
    try std.testing.expect(!exists(base));
}
