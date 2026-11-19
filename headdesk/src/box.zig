//! Sandboxes ("boxes"): a desktop's apps in their own Linux namespaces,
//! with a view of the system in which every write goes to a directory of
//! the box instead of to the system.
//!
//! What an app in a box sees:
//!   - the system's top-level directories (/usr, /etc, /var, ...) through
//!     overlays: reads come from the real ones, writes go to the box;
//!   - an empty home directory of its own, also kept in the box;
//!   - fresh /tmp, /run, /dev (a few devices) and /proc (its own processes);
//!   - nothing of /home, /root, /mnt or /media, except directories shared
//!     on purpose;
//!   - the desktop's Wayland socket.
//!
//! This is a namespace sandbox, as bubblewrap and containers are: the
//! kernel is shared with the host. It is not a virtual machine.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Share = struct { path: []const u8, read_only: bool };

pub const Spec = struct {
    /// The box's directory (holds `upper`, `work`, `layers`, `root`).
    box_dir: []const u8,
    /// The directory with the Wayland socket, shown at the same path.
    rt_dir: []const u8,
    /// The home directory's path inside.
    home: []const u8,
    network: bool = true,
    /// Appear as root inside (to install things); files written are still
    /// the caller's outside.
    as_root: bool = false,
    shares: []const Share = &.{},
    /// Where the pid of the box's first process is written (4 bytes).
    report_fd: sys.fd_t = -1,
};

/// Top-level names that are not taken from the system.
const fresh = [_][]const u8{ "proc", "sys", "dev", "run", "tmp", "mnt", "media", "home", "root", "lost+found", "boot", "snap" };

pub const Path = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn z(p: *const Path) [:0]const u8 {
        return p.buf[0..p.len :0];
    }
};

pub fn path(comptime fmt: []const u8, args: anytype) Path {
    var p: Path = .{};
    const s = std.fmt.bufPrintSentinel(&p.buf, fmt, args, 0) catch die("a path is too long", .{});
    p.len = s.len;
    return p;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1200]u8 = undefined;
    sys.writeAll(2, std.fmt.bufPrint(&buf, "headdesk: sandbox: " ++ fmt ++ "\n", args) catch "headdesk: sandbox failed\n") catch {};
    linux.exit_group(126);
}

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

fn must(rc: usize, comptime what: []const u8, arg: []const u8) void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) die(what ++ " {s}: {s}", .{ arg, @tagName(e) });
}

fn mkdir(p: [:0]const u8, mode: u32) void {
    const rc = linux.mkdir(p.ptr, mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) die("can't create {s}: {s}", .{ p, @tagName(e) });
}

/// Creates `p` and every directory above it that is missing.
pub fn mkdirAll(p: []const u8) void {
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (i == p.len or p[i] == '/') {
            const part = path("{s}", .{p[0..i]});
            mkdir(part.z(), 0o755);
        }
    }
}

pub fn writeFile(p: [:0]const u8, bytes: []const u8) bool {
    const rc = linux.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (!ok(rc)) return false;
    const fd: sys.fd_t = @intCast(rc);
    defer sys.close(fd);
    sys.writeAll(fd, bytes) catch return false;
    return true;
}

fn mount(src: ?[*:0]const u8, target: [:0]const u8, fstype: ?[*:0]const u8, flags: u32, data: ?[*:0]const u8) void {
    const rc = linux.mount(src, target.ptr, fstype, flags, if (data) |d| @intFromPtr(d) else 0);
    must(rc, "can't mount on", target);
}

pub const Kind = enum { dir, link, other, none };

const Info = struct { kind: Kind, dev: u64 = 0 };

pub fn info(p: [:0]const u8) Info {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st);
    if (!ok(rc)) return .{ .kind = .none };
    const dev = (@as(u64, st.dev_major) << 32) | st.dev_minor;
    return switch (st.mode & linux.S.IFMT) {
        linux.S.IFDIR => .{ .kind = .dir, .dev = dev },
        linux.S.IFLNK => .{ .kind = .link, .dev = dev },
        else => .{ .kind = .other, .dev = dev },
    };
}

const max_layers = 64;

pub const Layers = struct {
    names: [max_layers][72]u8 = undefined,
    lens: [max_layers]usize = undefined,
    count: usize = 0,

    pub fn name(l: *const Layers, i: usize) []const u8 {
        return l.names[i][0..l.lens[i]];
    }
};

/// The box's snapshot layers, newest first. Their names start with a
/// number, so sorting them sorts them by age.
pub fn readLayers(box_dir: []const u8) Layers {
    var layers: Layers = .{};
    const dir = path("{s}/layers", .{box_dir});
    const rc = linux.open(dir.z().ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (!ok(rc)) return layers;
    const fd: sys.fd_t = @intCast(rc);
    defer sys.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (!ok(n) or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const nm = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (nm[0] == '.' or nm.len > 72 or layers.count == max_layers) continue;
            @memcpy(layers.names[layers.count][0..nm.len], nm);
            layers.lens[layers.count] = nm.len;
            layers.count += 1;
        }
    }
    // newest (largest) first: a few dozen at most
    var i: usize = 0;
    while (i < layers.count) : (i += 1) {
        var j = i + 1;
        while (j < layers.count) : (j += 1) {
            if (std.mem.order(u8, layers.name(j), layers.name(i)) == .gt) {
                std.mem.swap([72]u8, &layers.names[i], &layers.names[j]);
                std.mem.swap(usize, &layers.lens[i], &layers.lens[j]);
            }
        }
    }
    return layers;
}

/// Mounts at `target` the system's directory `lower` (null: nothing) under
/// the box's layers and its writable `upper/NAME`. False if the kernel
/// refuses because `lower` has other file systems mounted inside it.
fn overlay(spec: *const Spec, layers: *const Layers, name: []const u8, lower: ?[]const u8, target: [:0]const u8) bool {
    const upper = path("{s}/upper/{s}", .{ spec.box_dir, name });
    const work = path("{s}/work/{s}", .{ spec.box_dir, name });
    mkdirAll(upper.z());
    removeTree(work.z());
    mkdirAll(work.z());
    var opts: [8192]u8 = undefined;
    var len: usize = 0;
    const add = struct {
        fn f(o: *[8192]u8, l: *usize, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(o[l.*..], fmt, args) catch die("too many snapshot layers", .{});
            l.* += s.len;
        }
    }.f;
    add(&opts, &len, "userxattr,upperdir={s},workdir={s},lowerdir=", .{ upper.z(), work.z() });
    var first = true;
    for (0..layers.count) |i| {
        const layer = path("{s}/layers/{s}/{s}", .{ spec.box_dir, layers.name(i), name });
        if (info(layer.z()).kind != .dir) continue;
        add(&opts, &len, "{s}{s}", .{ if (first) "" else ":", layer.z() });
        first = false;
    }
    if (lower) |l| {
        add(&opts, &len, "{s}{s}", .{ if (first) "" else ":", l });
    } else {
        const empty = path("{s}/empty", .{spec.box_dir});
        mkdirAll(empty.z());
        add(&opts, &len, "{s}{s}", .{ if (first) "" else ":", empty.z() });
    }
    opts[len] = 0;
    mkdirAll(target);
    const rc = linux.mount("overlay", target.ptr, "overlay", 0, @intFromPtr(&opts));
    if (lower != null and linux.errno(rc) == .INVAL) return false;
    must(rc, "can't mount on", target);
    return true;
}

/// Shows the system's directory `src` at `dst` under an overlay. Where
/// that can't be done in one piece (other file systems are mounted inside
/// `src`), the directory is taken apart: an overlay of its own for what is
/// written directly in it, one for each directory in it, and the other
/// file systems and the files directly in it shown read-only.
fn overlayTree(spec: *const Spec, layers: *const Layers, rel: []const u8, src: [:0]const u8, dst: [:0]const u8, root_dev: u64, depth: u32) void {
    if (overlay(spec, layers, rel, src, dst)) return;
    if (depth >= 5) die("can't show {s}: file systems are mounted too deep inside it", .{src});
    const own = path("@split/{s}", .{rel});
    _ = overlay(spec, layers, own.z(), null, dst);
    const rc = linux.open(src.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    must(rc, "can't read", src);
    const fd: sys.fd_t = @intCast(rc);
    defer sys.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (!ok(n) or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const from = path("{s}/{s}", .{ src, name });
            const to = path("{s}/{s}", .{ dst, name });
            const what = info(from.z());
            switch (what.kind) {
                .link => {
                    var target: [1024]u8 = undefined;
                    const len = linux.readlink(from.z().ptr, &target, target.len - 1);
                    if (!ok(len)) continue;
                    target[len] = 0;
                    _ = linux.symlink(@ptrCast(&target), to.z().ptr);
                },
                .dir => {
                    if (what.dev == root_dev) {
                        const child = path("{s}/{s}", .{ rel, name });
                        overlayTree(spec, layers, child.z(), from.z(), to.z(), root_dev, depth + 1);
                    } else {
                        // another file system: as it is, but not to be written
                        mkdir(to.z(), 0o755);
                        if (!ok(linux.mount(from.z().ptr, to.z().ptr, null, linux.MS.BIND | linux.MS.REC, 0))) continue;
                        _ = linux.mount(null, to.z().ptr, null, linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY, 0);
                    }
                },
                .other => {
                    if (!writeFile(to.z(), "")) continue;
                    if (!ok(linux.mount(from.z().ptr, to.z().ptr, null, linux.MS.BIND, 0))) continue;
                    _ = linux.mount(null, to.z().ptr, null, linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY, 0);
                },
                .none => {},
            }
        }
    }
}

/// Builds the box's view of the file system and makes it the root.
fn buildRoot(spec: *const Spec) void {
    // nothing mounted here shows outside
    mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, null);

    var resolv: [2048]u8 = undefined;
    var resolv_len: usize = 0;
    if (sys.openRead("/etc/resolv.conf")) |fd| {
        resolv_len = sys.read(fd, &resolv) catch 0;
        sys.close(fd);
    } else |_| {}

    mkdirAll(spec.box_dir);
    const root = path("{s}/root", .{spec.box_dir});
    mkdir(root.z(), 0o755);
    mount("tmpfs", root.z(), "tmpfs", linux.MS.NOSUID, "mode=755");
    const layers = readLayers(spec.box_dir);
    const root_dev = info("/").dev;

    // the system's own directories, each under an overlay
    const rc = linux.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    must(rc, "can't read", "/");
    const fd: sys.fd_t = @intCast(rc);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (!ok(n) or n == 0) break;
        var off: usize = 0;
        entries: while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (name[0] == '.') continue;
            for (fresh) |f| {
                if (std.mem.eql(u8, f, name)) continue :entries;
            }
            const src = path("/{s}", .{name});
            const dst = path("{s}/{s}", .{ root.z(), name });
            const what = info(src.z());
            switch (what.kind) {
                .link => {
                    var target: [512]u8 = undefined;
                    const len = linux.readlink(src.z().ptr, &target, target.len - 1);
                    if (!ok(len)) continue;
                    target[len] = 0;
                    _ = linux.symlink(@ptrCast(&target), dst.z().ptr);
                },
                .dir => {
                    // only what is on the root file system; other mounts stay out
                    if (what.dev != root_dev) continue;
                    // the box can't lie inside what it overlays
                    if (spec.box_dir.len > src.len and std.mem.startsWith(u8, spec.box_dir, src.z()) and spec.box_dir[src.len] == '/')
                        die("the box's directory {s} is inside {s}, which the box shows; put boxes under your home directory or set HEADDESK_BOXES", .{ spec.box_dir, src.z() });
                    overlayTree(spec, &layers, name, src.z(), dst.z(), root_dev, 0);
                },
                else => {},
            }
        }
    }
    sys.close(fd);

    for (fresh) |f| {
        if (std.mem.eql(u8, f, "lost+found") or std.mem.eql(u8, f, "boot") or std.mem.eql(u8, f, "snap")) continue;
        const d = path("{s}/{s}", .{ root.z(), f });
        mkdir(d.z(), 0o755);
    }
    const proc = path("{s}/proc", .{root.z()});
    mount("proc", proc.z(), "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, null);
    const sysfs = path("{s}/sys", .{root.z()});
    // With a network of its own the box gets its own view of /sys; else the
    // host's, read-only.
    if (spec.network or !ok(linux.mount("sysfs", sysfs.z().ptr, "sysfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.RDONLY, 0))) {
        mount("/sys", sysfs.z(), null, linux.MS.BIND | linux.MS.REC, null);
        _ = linux.mount(null, sysfs.z().ptr, null, linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY, 0);
    }
    const tmp = path("{s}/tmp", .{root.z()});
    mount("tmpfs", tmp.z(), "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "mode=1777");
    const run = path("{s}/run", .{root.z()});
    mount("tmpfs", run.z(), "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "mode=755");

    // a few devices, and terminals of its own
    const dev = path("{s}/dev", .{root.z()});
    mount("tmpfs", dev.z(), "tmpfs", linux.MS.NOSUID, "mode=755");
    for ([_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" }) |node| {
        const from = path("/dev/{s}", .{node});
        const to = path("{s}/{s}", .{ dev.z(), node });
        if (!writeFile(to.z(), "")) continue;
        _ = linux.mount(from.z().ptr, to.z().ptr, null, linux.MS.BIND, 0);
    }
    const pts = path("{s}/pts", .{dev.z()});
    mkdir(pts.z(), 0o755);
    _ = linux.mount("devpts", pts.z().ptr, "devpts", linux.MS.NOSUID | linux.MS.NOEXEC, @intFromPtr(@as([*:0]const u8, "newinstance,ptmxmode=0666,mode=620")));
    const shm = path("{s}/shm", .{dev.z()});
    mkdir(shm.z(), 0o1777);
    mount("tmpfs", shm.z(), "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "mode=1777");
    const links = [_][2][]const u8{ .{ "pts/ptmx", "ptmx" }, .{ "/proc/self/fd", "fd" }, .{ "/proc/self/fd/0", "stdin" }, .{ "/proc/self/fd/1", "stdout" }, .{ "/proc/self/fd/2", "stderr" } };
    for (links) |l| {
        const target = path("{s}", .{l[0]});
        const at = path("{s}/{s}", .{ dev.z(), l[1] });
        _ = linux.symlink(target.z().ptr, at.z().ptr);
    }

    // a home of its own, kept in the box
    const home = path("{s}{s}", .{ root.z(), spec.home });
    _ = overlay(spec, &layers, "@home", null, home.z());

    // the desktop's socket, and what was shared on purpose
    const rt = path("{s}{s}", .{ root.z(), spec.rt_dir });
    mkdirAll(rt.z());
    const rt_src = path("{s}", .{spec.rt_dir});
    mount(rt_src.z().ptr, rt.z(), null, linux.MS.BIND, null);
    for (spec.shares) |share| {
        const src = path("{s}", .{share.path});
        if (info(src.z()).kind != .dir) die("--share needs a directory: {s}", .{share.path});
        const dst = path("{s}{s}", .{ root.z(), share.path });
        mkdirAll(dst.z());
        mount(src.z().ptr, dst.z(), null, linux.MS.BIND | linux.MS.REC, null);
        if (share.read_only) must(linux.mount(null, dst.z().ptr, null, linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY, 0), "can't make read-only", share.path);
    }

    // swap roots and let go of the old one
    const old = path("{s}/.old", .{root.z()});
    mkdir(old.z(), 0o700);
    must(linux.pivot_root(root.z().ptr, old.z().ptr), "can't change the root to", root.z());
    _ = linux.chdir("/");
    must(linux.umount2("/.old", linux.MNT.DETACH), "can't let go of", "the old root");
    _ = linux.rmdir("/.old");

    // name resolution, when the system's file points somewhere not shown
    if (resolv_len > 0 and !ok(linux.access("/etc/resolv.conf", 4))) {
        var target: [512]u8 = undefined;
        const len = linux.readlink("/etc/resolv.conf", &target, target.len);
        if (ok(len) and len > 0) {
            const t = target[0..len];
            const abs = if (t[0] == '/') path("{s}", .{t}) else path("/etc/{s}", .{t});
            if (std.mem.findScalarLast(u8, abs.z(), '/')) |slash| {
                if (slash > 0) mkdirAll(abs.z()[0..slash]);
            }
            _ = writeFile(abs.z(), resolv[0..resolv_len]);
        }
    }
    const hostname = "headdesk";
    _ = linux.syscall2(.sethostname, @intFromPtr(hostname.ptr), hostname.len);
}

fn relay(pid: sys.pid_t) noreturn {
    while (true) {
        var status: i32 = 0;
        const rc = linux.waitpid(pid, &status, 0);
        if (linux.errno(rc) == .INTR) continue;
        if (!ok(rc)) linux.exit_group(126);
        const s: u32 = @bitCast(status);
        linux.exit_group(if (s & 0x7f == 0) @intCast((s >> 8) & 0xff) else @intCast(128 + (s & 0x7f)));
    }
}

/// Called in a new child process, before it runs the app: moves into a
/// new box. Returns only in the process that is to run the app; the two
/// processes above it (one outside, to pass on the exit code, and the
/// box's process 1) never return.
pub fn enter(spec: *const Spec) void {
    const uid = linux.getuid();
    const gid = linux.getgid();
    var flags: usize = linux.CLONE.NEWUSER | linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWIPC | linux.CLONE.NEWUTS;
    if (!spec.network) flags |= linux.CLONE.NEWNET;
    const rc = linux.unshare(flags);
    if (!ok(rc)) die("this system does not let {s} make namespaces ({s}); see `headdesk check`", .{ if (uid == 0) "root" else "an ordinary user", @tagName(linux.errno(rc)) });
    _ = writeFile("/proc/self/setgroups", "deny");
    var map: [64]u8 = undefined;
    if (!writeFile("/proc/self/uid_map", std.fmt.bufPrint(&map, "{d} {d} 1\n", .{ if (spec.as_root) 0 else uid, uid }) catch unreachable)) die("can't set the user mapping", .{});
    if (!writeFile("/proc/self/gid_map", std.fmt.bufPrint(&map, "{d} {d} 1\n", .{ if (spec.as_root) 0 else gid, gid }) catch unreachable)) die("can't set the group mapping", .{});

    const first = linux.fork();
    if (!ok(first)) die("can't start the box's first process", .{});
    if (first != 0) {
        const pid: sys.pid_t = @intCast(first);
        if (spec.report_fd >= 0) {
            sys.writeAll(spec.report_fd, std.mem.asBytes(&pid)) catch {};
            sys.close(spec.report_fd);
        }
        relay(pid);
    }
    // process 1 of the box
    if (spec.report_fd >= 0) sys.close(spec.report_fd);
    buildRoot(spec);
    const app = linux.fork();
    if (!ok(app)) die("can't start the app's process", .{});
    if (app != 0) {
        // Reap whatever ends; when the app ends, so does the box, and the
        // kernel ends everything left in it.
        while (true) {
            var status: i32 = 0;
            const done = linux.waitpid(-1, &status, 0);
            if (linux.errno(done) == .INTR) continue;
            if (!ok(done)) linux.exit_group(0);
            if (done == app) {
                const s: u32 = @bitCast(status);
                linux.exit_group(if (s & 0x7f == 0) @intCast((s >> 8) & 0xff) else @intCast(128 + (s & 0x7f)));
            }
        }
    }
    _ = linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
}

/// Called in a new child process: moves into the running box whose
/// process 1 is `init_pid` (as seen from outside). Returns in the process
/// that is to run the program.
pub fn join(init_pid: sys.pid_t) void {
    const spaces = [_]struct { name: []const u8, flag: u32 }{
        .{ .name = "user", .flag = linux.CLONE.NEWUSER },
        .{ .name = "mnt", .flag = linux.CLONE.NEWNS },
        .{ .name = "pid", .flag = linux.CLONE.NEWPID },
        .{ .name = "ipc", .flag = linux.CLONE.NEWIPC },
        .{ .name = "uts", .flag = linux.CLONE.NEWUTS },
        .{ .name = "net", .flag = linux.CLONE.NEWNET },
    };
    var fds: [spaces.len]sys.fd_t = undefined;
    for (spaces, 0..) |sp, i| {
        const p = path("/proc/{d}/ns/{s}", .{ init_pid, sp.name });
        const rc = linux.open(p.z().ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (!ok(rc)) die("the box is gone ({s})", .{p.z()});
        fds[i] = @intCast(rc);
    }
    for (spaces, fds) |sp, fd| {
        const rc = linux.setns(fd, sp.flag);
        // the network is shared with the host unless the box was made without
        if (!ok(rc) and sp.flag != linux.CLONE.NEWNET) die("can't enter the box's {s} namespace: {s}", .{ sp.name, @tagName(linux.errno(rc)) });
        sys.close(fd);
    }
    const child = linux.fork();
    if (!ok(child)) die("can't start a process in the box", .{});
    if (child != 0) relay(@intCast(child));
    _ = linux.chdir("/");
    _ = linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
}

/// Removes `p` and everything in it. Missing is fine.
pub fn removeTree(p: [:0]const u8) void {
    removeAt(linux.AT.FDCWD, p);
}

fn removeAt(dir: sys.fd_t, name: [:0]const u8) void {
    if (ok(linux.unlinkat(dir, name.ptr, 0))) return;
    // a directory: make it enterable (overlay's work directory is not), empty it, remove it
    _ = linux.fchmodat(dir, name.ptr, 0o700);
    const rc = linux.openat(dir, name.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (!ok(rc)) return;
    const fd: sys.fd_t = @intCast(rc);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (!ok(n) or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const child = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
            removeAt(fd, child);
        }
    }
    sys.close(fd);
    _ = linux.unlinkat(dir, name.ptr, linux.AT.REMOVEDIR);
}

/// Whether this system lets the caller make a box: tries the namespaces in
/// a child process. Returns null when it works, else what the kernel said.
pub fn unsupported() ?[]const u8 {
    const child = linux.fork();
    if (!ok(child)) return "fork failed";
    if (child == 0) {
        const uid = linux.getuid();
        const rc = linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNS | linux.CLONE.NEWPID);
        if (!ok(rc)) linux.exit_group(@intCast(@backingInt(linux.errno(rc)) & 0x7f));
        _ = writeFile("/proc/self/setgroups", "deny");
        var map: [64]u8 = undefined;
        if (!writeFile("/proc/self/uid_map", std.fmt.bufPrint(&map, "{d} {d} 1\n", .{ uid, uid }) catch unreachable)) linux.exit_group(126);
        // a mount is what an AppArmor rule against user namespaces takes away
        if (!ok(linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0))) linux.exit_group(125);
        linux.exit_group(0);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(child), &status, 0);
    const s: u32 = @bitCast(status);
    const code = (s >> 8) & 0xff;
    if (s & 0x7f == 0 and code == 0) return null;
    if (code == 125 or code == 126) return "namespaces are made, but nothing may be mounted in them (on Ubuntu: sysctl kernel.apparmor_restrict_unprivileged_userns=0)";
    if (code == @backingInt(linux.E.PERM) or code == @backingInt(linux.E.ACCES)) return "the kernel refuses user namespaces for this user (EPERM)";
    if (code == @backingInt(linux.E.INVAL)) return "the kernel has no user namespaces (EINVAL)";
    if (code == @backingInt(linux.E.NOSPC)) return "the limit on user namespaces is reached (ENOSPC)";
    return "the kernel refuses to make namespaces";
}

test "removeTree takes a directory with files and closed directories away" {
    const base = "/tmp/headdesk-rmtest";
    removeTree(base);
    mkdirAll(base ++ "/a/b");
    try std.testing.expect(writeFile(base ++ "/a/b/f", "x"));
    try std.testing.expect(writeFile(base ++ "/g", "y"));
    mkdirAll(base ++ "/closed/inner");
    _ = linux.chmod(base ++ "/closed", 0);
    removeTree(base);
    try std.testing.expectEqual(Kind.none, info(base).kind);
    // nothing there: nothing happens
    removeTree(base);
}

test "layers come newest first" {
    const base = "/tmp/headdesk-layertest";
    removeTree(base);
    mkdirAll(base ++ "/layers/0001-first");
    mkdirAll(base ++ "/layers/0003-third");
    mkdirAll(base ++ "/layers/0002-second");
    defer removeTree(base);
    const l = readLayers(base);
    try std.testing.expectEqual(@as(usize, 3), l.count);
    try std.testing.expectEqualStrings("0003-third", l.name(0));
    try std.testing.expectEqualStrings("0002-second", l.name(1));
    try std.testing.expectEqualStrings("0001-first", l.name(2));
}
