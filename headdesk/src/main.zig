//! headdesk: a headless desktop for agents. `start` makes a desktop (a
//! process that is its own Wayland display server) with an app in it; the
//! other commands talk to that process.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const desk = @import("desk.zig");
const box = @import("box.zig");
const boxes = @import("boxes.zig");
const dbus = @import("dbus.zig");
const a11y = @import("a11y.zig");

pub const version = "0.1.0";

const usage =
    \\usage: headdesk <command> [options]
    \\
    \\  start NAME [--size WxH] [--cwd DIR] [--frozen] [--sandbox ...] -- CMD...
    \\                        a new desktop with CMD running in it
    \\      --frozen          frozen from the start: the apps draw once and
    \\                        then only when stepped
    \\      --sandbox         the apps run in a box: they read the system but
    \\                        what they write stays in the box, their home is
    \\                        empty, and they see none of your files
    \\      --box BOX         which box (default: the desktop's name); a box
    \\                        keeps what was written in it between runs
    \\      --share DIR, --share-ro DIR
    \\                        a directory of yours the apps may use (or only read)
    \\      --no-network      no network in the box
    \\      --as-root         the apps are root inside the box (to install things)
    \\  exec NAME -- CMD...   one more program on that desktop
    \\  list                  the desktops that are running
    \\  status NAME           its apps, windows, and what apps asked for that
    \\                        this server does not have
    \\  kill NAME             end the desktop and its apps
    \\
    \\  windows NAME          every window, menu and popup: number, place, size, title
    \\  shot NAME FILE.png [--window N]
    \\                        the desktop, or one window alone even when covered
    \\  wait NAME [--idle MS] [--timeout MS] [--windows N]
    \\                        until nothing has been drawn for MS (300) and at
    \\                        least N windows are open; says what area changed
    \\
    \\  tree NAME [--all] [--max N]
    \\                        what the apps say is on the desktop: every button,
    \\                        field, menu entry and label by role and name, with
    \\                        its place (needs apps that speak AT-SPI)
    \\  find NAME TEXT [--role ROLE]
    \\                        the things whose name holds TEXT, and where to click
    \\  click NAME --name TEXT [--role ROLE] [--nth N]
    \\                        click the one thing called TEXT; if several are,
    \\                        the Nth of them as `find` lists them
    \\  press NAME TEXT [--role ROLE] [--nth N]
    \\                        do what a click on it would, without the pointer
    \\  fill NAME FIELD TEXT [--role ROLE] [--nth N]
    \\                        put TEXT into the field called FIELD, whatever the
    \\                        keyboard layout (any characters)
    \\                        TEXT and FIELD may be "" with --role: any of that role
    \\  click NAME X Y [--window N] [--button left|right|middle] [--double]
    \\  move NAME X Y [--window N]
    \\  scroll NAME STEPS     wheel notches down (negative: up)
    \\  key NAME KEY...       Return, Tab, Escape, F5, a, ctrl+s, ctrl+shift+t
    \\  type NAME TEXT        ASCII text, key by key
    \\  focus NAME N          bring window N to the front
    \\  close NAME N          ask window N to close
    \\
    \\  freeze NAME           apps are not told to draw any more, and the time
    \\                        they are given with frames and input stands still
    \\  step NAME [N] [--until-quiet]
    \\                        let N frames (1) through while frozen, each 16 ms
    \\                        later on the apps' frame clock; with --until-quiet
    \\                        until no app asks for another (at most N, 600)
    \\  thaw NAME             back to normal
    \\  hash NAME             a number for how the desktop looks now: the same
    \\                        picture, the same number
    \\  log NAME [--since N]  every input and every drawing, in order
    \\  output NAME           what the apps printed
    \\
    \\  record NAME DIR [--fps N]
    \\                        from now on keep the log, every input, and a picture
    \\                        whenever the desktop changed (at most N a second, 10)
    \\                        in DIR, with a page to look at them (index.html)
    \\  record NAME --stop    end the recording (kill ends it too)
    \\  replay NAME DIR [--settle | --frozen] [--speed X]
    \\                        send a recording's inputs to this desktop again,
    \\                        at the recorded times (X times as fast), or with
    \\                        --settle each once the desktop is quiet, or with
    \\                        --frozen on a frozen desktop, stepping frames until
    \\                        the apps are quiet after each; then say whether
    \\                        the desktop ends up looking the same
    \\
    \\  box list              the boxes, their snapshots, and which are open
    \\  box diff BOX          what was added, changed or deleted in the box
    \\                        since its last snapshot
    \\  box snapshot BOX LABEL   keep the box as it is now under LABEL
    \\  box restore BOX LABEL    back to that snapshot; what came after is gone
    \\  box reset BOX         empty the box, snapshots included
    \\  box delete BOX        remove the box
    \\  check                 whether this system lets you make boxes
    \\
    \\  help, version
    \\
    \\X and Y are desktop pixels from the top left, or with --window pixels
    \\of that window. Exit: 0 done, 1 not reached (a wait timed out), 2 a
    \\wrong command, 4 no such desktop.
    \\
;

var environ: [:null]const ?[*:0]const u8 = &.{};

fn getenv(name: []const u8) ?[]const u8 {
    for (environ) |entry| {
        const e = std.mem.span(entry.?);
        if (e.len > name.len and e[name.len] == '=' and std.mem.startsWith(u8, e, name)) return e[name.len + 1 ..];
    }
    return null;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    sys.writeAll(1, std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    sys.writeAll(2, std.fmt.bufPrint(&buf, "headdesk: " ++ fmt ++ "\n", args) catch "headdesk: error\n") catch {};
    sys.exit(code);
}

/// Where desktops keep their sockets: $XDG_RUNTIME_DIR/headdesk, else
/// $TMPDIR/headdesk-UID (TMPDIR defaulting to /tmp).
fn baseDir(buf: []u8) []const u8 {
    if (getenv("HEADDESK_DIR")) |d| {
        if (d.len > 0) return d;
    }
    if (getenv("XDG_RUNTIME_DIR")) |x| {
        if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/headdesk", .{std.mem.trimEnd(u8, x, "/")}) catch die(2, "XDG_RUNTIME_DIR is too long", .{});
    }
    const tmp = getenv("TMPDIR") orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/headdesk-{d}", .{ std.mem.trimEnd(u8, if (tmp.len == 0) "/tmp" else tmp, "/"), sys.getuid() }) catch die(2, "TMPDIR is too long", .{});
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or name[0] == '.' or name[0] == '-') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return true;
}

fn deskDir(buf: []u8, name: []const u8) []const u8 {
    if (!validName(name)) die(2, "a desktop's name is 1 to 32 letters, digits, '_', '-' or '.': {s}", .{name});
    var base_buf: [512]u8 = undefined;
    const d = std.fmt.bufPrint(buf, "{s}/{s}", .{ baseDir(&base_buf), name }) catch die(2, "the directory name is too long", .{});
    // a Unix socket path holds about 107 bytes
    if (d.len + "/control.sock".len > 100) die(2, "the directory for sockets is too long ({d} bytes): set HEADDESK_DIR to a shorter one", .{d.len});
    return d;
}

/// Sends one command to desktop `name` and returns its whole answer.
fn request(gpa: std.mem.Allocator, name: []const u8, fields: []const []const u8) ![]u8 {
    var dir_buf: [512]u8 = undefined;
    var path_buf: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/control.sock", .{deskDir(&dir_buf, name)});
    const fd = try sys.connectUnix(path);
    defer sys.close(fd);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    for (fields, 0..) |f, i| {
        if (i > 0) try line.append(gpa, desk.field_sep);
        for (f) |c| try line.append(gpa, if (c == '\n') desk.newline_mark else c);
    }
    try line.append(gpa, '\n');
    try sys.writeAll(fd, line.items);
    var answer: std.ArrayList(u8) = .empty;
    errdefer answer.deinit(gpa);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &chunk) catch break;
        if (n == 0) break;
        try answer.appendSlice(gpa, chunk[0..n]);
    }
    return answer.toOwnedSlice(gpa);
}

/// Sends a command, prints the answer and returns the exit code.
fn talk(gpa: std.mem.Allocator, name: []const u8, fields: []const []const u8) u8 {
    const answer = request(gpa, name, fields) catch |err| switch (err) {
        error.NotFound, error.Refused => die(4, "no desktop named {s} (see `headdesk list`)", .{name}),
        else => die(2, "can't reach desktop {s}: {s}", .{ name, @errorName(err) }),
    };
    defer gpa.free(answer);
    if (std.mem.startsWith(u8, answer, "error ")) {
        sys.writeAll(2, "headdesk: ") catch {};
        sys.writeAll(2, answer["error ".len..]) catch {};
        return 2;
    }
    if (std.mem.startsWith(u8, answer, "fail ")) {
        sys.writeAll(1, answer["fail ".len..]) catch {};
        return 1;
    }
    if (std.mem.startsWith(u8, answer, "ok\n")) {
        sys.writeAll(1, answer[3..]) catch {};
        return 0;
    }
    if (std.mem.startsWith(u8, answer, "ok ")) {
        sys.writeAll(1, answer[3..]) catch {};
        return 0;
    }
    die(2, "desktop {s} gave no answer", .{name});
}

fn absolute(gpa: std.mem.Allocator, path: []const u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    var buf: [4096]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) die(2, "can't tell the current directory", .{});
    const cwd = std.mem.sliceTo(&buf, 0);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path }) catch die(2, "out of memory", .{});
}

const Parsed = struct {
    positional: [8][]const u8 = undefined,
    count: usize = 0,
    rest: []const [:0]const u8 = &.{},
    size: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    window: ?[]const u8 = null,
    button: ?[]const u8 = null,
    double: bool = false,
    idle: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
    windows: ?[]const u8 = null,
    since: ?[]const u8 = null,
    box: ?[]const u8 = null,
    fps: ?[]const u8 = null,
    name: ?[]const u8 = null,
    role: ?[]const u8 = null,
    max: ?[]const u8 = null,
    nth: ?[]const u8 = null,
    all: bool = false,
    speed: ?[]const u8 = null,
    stop: bool = false,
    settle: bool = false,
    frozen: bool = false,
    until_quiet: bool = false,
    sandbox: bool = false,
    no_network: bool = false,
    as_root: bool = false,
    shares: [16]box.Share = undefined,
    share_count: usize = 0,

    fn pos(p: *const Parsed, i: usize, what: []const u8) []const u8 {
        if (i >= p.count) die(2, "{s} is missing (see `headdesk help`)", .{what});
        return p.positional[i];
    }
};

fn parse(args: []const [:0]const u8, flags: []const []const u8) Parsed {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--")) {
            p.rest = args[i + 1 ..];
            break;
        }
        // a negative number is not an option
        if (a.len > 2 and std.mem.startsWith(u8, a, "--")) {
            const known = for (flags) |f| {
                if (std.mem.eql(u8, f, a)) break true;
            } else false;
            if (!known) die(2, "unknown option {s}", .{a});
            const switches = [_]struct { name: []const u8, at: *bool }{
                .{ .name = "--double", .at = &p.double },
                .{ .name = "--stop", .at = &p.stop },
                .{ .name = "--all", .at = &p.all },
                .{ .name = "--settle", .at = &p.settle },
                .{ .name = "--frozen", .at = &p.frozen },
                .{ .name = "--until-quiet", .at = &p.until_quiet },
                .{ .name = "--sandbox", .at = &p.sandbox },
                .{ .name = "--no-network", .at = &p.no_network },
                .{ .name = "--as-root", .at = &p.as_root },
            };
            var was_switch = false;
            for (switches) |sw| {
                if (std.mem.eql(u8, a, sw.name)) {
                    sw.at.* = true;
                    was_switch = true;
                }
            }
            if (was_switch) continue;
            if (i + 1 >= args.len) die(2, "{s} needs a value", .{a});
            i += 1;
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--size")) p.size = v;
            if (std.mem.eql(u8, a, "--cwd")) p.cwd = v;
            if (std.mem.eql(u8, a, "--window")) p.window = v;
            if (std.mem.eql(u8, a, "--button")) p.button = v;
            if (std.mem.eql(u8, a, "--idle")) p.idle = v;
            if (std.mem.eql(u8, a, "--timeout")) p.timeout = v;
            if (std.mem.eql(u8, a, "--windows")) p.windows = v;
            if (std.mem.eql(u8, a, "--since")) p.since = v;
            if (std.mem.eql(u8, a, "--box")) p.box = v;
            if (std.mem.eql(u8, a, "--fps")) p.fps = v;
            if (std.mem.eql(u8, a, "--name")) p.name = v;
            if (std.mem.eql(u8, a, "--role")) p.role = v;
            if (std.mem.eql(u8, a, "--max")) p.max = v;
            if (std.mem.eql(u8, a, "--nth")) p.nth = v;
            if (std.mem.eql(u8, a, "--speed")) p.speed = v;
            if (std.mem.eql(u8, a, "--share") or std.mem.eql(u8, a, "--share-ro")) {
                if (p.share_count == p.shares.len) die(2, "too many shared directories", .{});
                p.shares[p.share_count] = .{ .path = v, .read_only = std.mem.eql(u8, a, "--share-ro") };
                p.share_count += 1;
            }
            continue;
        }
        if (p.count == p.positional.len) die(2, "too many arguments", .{});
        p.positional[p.count] = a;
        p.count += 1;
    }
    return p;
}

/// Where boxes are kept: $HEADDESK_BOXES, else $XDG_DATA_HOME/headdesk/boxes,
/// else ~/.local/share/headdesk/boxes.
fn boxesDir(buf: []u8) []const u8 {
    if (getenv("HEADDESK_BOXES")) |d| {
        if (d.len > 0) return d;
    }
    if (getenv("XDG_DATA_HOME")) |x| {
        if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/headdesk/boxes", .{std.mem.trimEnd(u8, x, "/")}) catch die(2, "XDG_DATA_HOME is too long", .{});
    }
    const home = getenv("HOME") orelse die(2, "HOME is not set; set HEADDESK_BOXES to where boxes are kept", .{});
    return std.fmt.bufPrint(buf, "{s}/.local/share/headdesk/boxes", .{std.mem.trimEnd(u8, home, "/")}) catch die(2, "HOME is too long", .{});
}

fn boxDir(gpa: std.mem.Allocator, name: []const u8) []const u8 {
    if (!validName(name)) die(2, "a box's name is 1 to 32 letters, digits, '_', '-' or '.': {s}", .{name});
    var buf: [512]u8 = undefined;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ boxesDir(&buf), name }) catch die(2, "out of memory", .{});
}

fn boxCommand(gpa: std.mem.Allocator, args: []const [:0]const u8) u8 {
    if (args.len == 0) die(2, "box needs list, diff, snapshot, restore, reset or delete", .{});
    const sub_cmd: []const u8 = args[0];
    if (std.mem.eql(u8, sub_cmd, "list")) {
        var buf: [512]u8 = undefined;
        boxes.list(boxesDir(&buf));
        return 0;
    }
    if (args.len < 2) die(2, "box {s} needs a box's name", .{sub_cmd});
    const name: []const u8 = args[1];
    const dir = boxDir(gpa, name);
    const result: boxes.Error!void = blk: {
        if (std.mem.eql(u8, sub_cmd, "diff")) {
            const n = boxes.diff(dir) catch |err| break :blk err;
            out("{d} changed in box {s}\n", .{ n, name });
            break :blk {};
        }
        if (std.mem.eql(u8, sub_cmd, "snapshots")) {
            if (!boxes.exists(dir)) break :blk error.NoSuchBox;
            boxes.listSnapshots(dir);
            break :blk {};
        }
        if (std.mem.eql(u8, sub_cmd, "reset")) break :blk boxes.reset(dir);
        if (std.mem.eql(u8, sub_cmd, "delete")) break :blk boxes.delete(dir);
        if (std.mem.eql(u8, sub_cmd, "snapshot") or std.mem.eql(u8, sub_cmd, "restore")) {
            if (args.len < 3) die(2, "box {s} needs a label", .{sub_cmd});
            const label: []const u8 = args[2];
            if (!boxes.validLabel(label)) die(2, "a label is 1 to 40 letters, digits, '_', '-' or '.': {s}", .{label});
            break :blk if (std.mem.eql(u8, sub_cmd, "snapshot")) boxes.snapshot(dir, label) else boxes.restore(dir, label);
        }
        die(2, "unknown box command: {s}", .{sub_cmd});
    };
    result catch |err| switch (err) {
        error.NoSuchBox => die(4, "no box named {s} (see `headdesk box list`)", .{name}),
        error.InUse => die(2, "box {s} is open in a desktop; end that desktop first", .{name}),
        error.NoSuchSnapshot => die(2, "box {s} has no snapshot with that label (see `headdesk box snapshots {s}`)", .{ name, name }),
        error.Exists => die(2, "box {s} already has a snapshot with that label", .{name}),
        error.Failed => die(2, "the box's directory could not be changed", .{}),
    };
    return 0;
}

fn start(gpa: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const p = parse(args, &.{ "--size", "--cwd", "--frozen", "--sandbox", "--box", "--share", "--share-ro", "--no-network", "--as-root" });
    const name = p.pos(0, "the desktop's name");
    if (p.rest.len == 0) die(2, "start needs a program after --", .{});
    const boxed = p.sandbox or p.box != null;
    if (!boxed and (p.share_count > 0 or p.no_network or p.as_root)) die(2, "--share, --no-network and --as-root go with --sandbox", .{});
    var sandbox: ?box.Spec = null;
    const box_name = p.box orelse name;
    if (boxed) {
        if (box.unsupported()) |why| die(2, "can't make a sandbox here: {s}", .{why});
        const dir = boxDir(gpa, box_name);
        if (boxes.inUse(dir)) |pid| die(2, "box {s} is already open in a desktop (pid {d})", .{ box_name, pid });
        const shares = gpa.alloc(box.Share, p.share_count) catch die(2, "out of memory", .{});
        for (p.shares[0..p.share_count], 0..) |s, i| shares[i] = .{ .path = absolute(gpa, s.path), .read_only = s.read_only };
        const home = if (p.as_root) "/root" else (getenv("HOME") orelse "/home/user");
        sandbox = .{ .box_dir = dir, .rt_dir = "", .home = home, .network = !p.no_network, .as_root = p.as_root, .shares = shares };
        var base_buf: [512]u8 = undefined;
        box.mkdirAll(boxesDir(&base_buf));
    }
    var width: i32 = 1280;
    var height: i32 = 800;
    if (p.size) |sz| {
        const x = std.mem.findScalar(u8, sz, 'x') orelse die(2, "--size is WIDTHxHEIGHT, as in 1280x800", .{});
        width = std.fmt.parseInt(i32, sz[0..x], 10) catch die(2, "--size is WIDTHxHEIGHT, as in 1280x800", .{});
        height = std.fmt.parseInt(i32, sz[x + 1 ..], 10) catch die(2, "--size is WIDTHxHEIGHT, as in 1280x800", .{});
        if (width < 64 or height < 64 or width > 8192 or height > 8192) die(2, "--size is between 64x64 and 8192x8192", .{});
    }
    var dir_buf: [512]u8 = undefined;
    const dir = gpa.dupe(u8, deskDir(&dir_buf, name)) catch die(2, "out of memory", .{});
    var base_buf: [512]u8 = undefined;
    var z_buf: [600]u8 = undefined;
    sys.mkdir(std.fmt.bufPrintSentinel(&z_buf, "{s}", .{baseDir(&base_buf)}, 0) catch unreachable) catch die(2, "can't create {s}", .{baseDir(&base_buf)});
    sys.mkdir(std.fmt.bufPrintSentinel(&z_buf, "{s}", .{dir}, 0) catch unreachable) catch die(2, "can't create {s}", .{dir});

    if (request(gpa, name, &.{"ping"})) |answer| {
        gpa.free(answer);
        die(2, "a desktop named {s} is already running", .{name});
    } else |_| {}

    const argv = gpa.alloc([]const u8, p.rest.len) catch die(2, "out of memory", .{});
    for (p.rest, 0..) |a, i| argv[i] = a;
    const cwd: ?[]const u8 = if (p.cwd) |c| absolute(gpa, c) else null;

    const pid = sys.forkDetached() catch die(2, "can't start the desktop's process", .{});
    if (pid == 0) {
        // the desktop: no terminal, so that the caller is not kept waiting
        const null_fd: sys.fd_t = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
        _ = linux.dup2(null_fd, 0);
        _ = linux.dup2(null_fd, 1);
        const err_path = std.fmt.bufPrintSentinel(&z_buf, "{s}/desktop.log", .{dir}, 0) catch unreachable;
        const err_fd = sys.create(err_path) catch null_fd;
        _ = linux.dup2(err_fd, 2);
        sys.ignoreSigpipe();
        var d = desk.Desk.init(gpa, .{ .name = name, .dir = dir, .width = width, .height = height, .argv = argv, .cwd = cwd, .envp = environ, .sandbox = sandbox, .box_name = box_name, .frozen = p.frozen }) catch |err| die(2, "can't set up the desktop: {s}", .{@errorName(err)});
        _ = d.spawn(argv, cwd) catch |err| die(2, "can't start {s}: {s}", .{ argv[0], @errorName(err) });
        d.run();
        sys.exit(0);
    }
    // wait until the desktop answers
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        if (request(gpa, name, &.{"ping"})) |answer| {
            defer gpa.free(answer);
            if (boxed) out("started {s} pid={d} size={d}x{d} box={s}\n", .{ name, pid, width, height, box_name }) else out("started {s} pid={d} size={d}x{d}\n", .{ name, pid, width, height });
            return 0;
        } else |_| {}
        if (sys.reap(pid) != .running) break;
        sys.sleepMs(25);
    }
    die(2, "the desktop did not come up; see {s}/desktop.log", .{dir});
}

// ---------------------------------------------------------------------
// What apps say about themselves (the accessibility bus)

const Win = struct {
    n: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    title: []const u8,
    /// The surface the window is drawn on: the same, or larger by shadows.
    /// Apps count places from its corner.
    sx: i32 = 0,
    sy: i32 = 0,
    sw: i32 = 0,
    sh: i32 = 0,
};

const Seen = struct {
    conn: dbus.Conn,
    tree: a11y.Tree,
    wins: []Win,

    /// The desktop window a node is in. Apps give places relative to "the
    /// window", which for something in a menu is the menu's own window: the
    /// nearest thing around the node that sits at 0,0 with exactly the size
    /// of a desktop window is that window. Else the window with the title
    /// of the node's top-level frame.
    fn window(s: *const Seen, node: a11y.Node, index: usize) ?Win {
        const nodes = s.tree.nodes.items;
        var up: ?usize = index;
        while (up) |i| : (up = a11y.parentOf(nodes, i)) {
            const n = nodes[i];
            if (n.depth < 2 or !n.has_rect or n.rect.x != 0 or n.rect.y != 0) continue;
            // the last windows are the topmost: a menu before what is under it
            var k = s.wins.len;
            while (k > 0) {
                k -= 1;
                const w = s.wins[k];
                if ((w.sw == n.rect.w and w.sh == n.rect.h) or (w.w == n.rect.w and w.h == n.rect.h)) {
                    // the main window's own frame is found by its title below
                    if (i == node.top and w.title.len > 0 and !std.mem.eql(u8, w.title, n.name)) continue;
                    return w;
                }
            }
        }
        const top = nodes[node.top];
        for (s.wins) |w| {
            if (w.title.len > 0 and std.mem.eql(u8, w.title, top.name)) return w;
        }
        return if (s.wins.len == 1) s.wins[0] else null;
    }
};

fn parseWindows(gpa: std.mem.Allocator, text: []const u8) []Win {
    var wins: std.ArrayList(Win) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "window ")) continue;
        var w: Win = .{ .n = 0, .x = 0, .y = 0, .w = 0, .h = 0, .title = "" };
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        _ = words.next();
        w.n = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        while (words.next()) |word| {
            if (std.mem.startsWith(u8, word, "at=")) {
                const comma = std.mem.findScalar(u8, word, ',') orelse continue;
                w.x = std.fmt.parseInt(i32, word[3..comma], 10) catch 0;
                w.y = std.fmt.parseInt(i32, word[comma + 1 ..], 10) catch 0;
            } else if (std.mem.startsWith(u8, word, "size=")) {
                const x = std.mem.findScalar(u8, word, 'x') orelse continue;
                w.w = std.fmt.parseInt(i32, word[5..x], 10) catch 0;
                w.h = std.fmt.parseInt(i32, word[x + 1 ..], 10) catch 0;
            } else if (std.mem.startsWith(u8, word, "surface=")) {
                // X,Y,WxH
                var parts = std.mem.tokenizeAny(u8, word[8..], ",x");
                w.sx = std.fmt.parseInt(i32, parts.next() orelse "0", 10) catch 0;
                w.sy = std.fmt.parseInt(i32, parts.next() orelse "0", 10) catch 0;
                w.sw = std.fmt.parseInt(i32, parts.next() orelse "0", 10) catch 0;
                w.sh = std.fmt.parseInt(i32, parts.next() orelse "0", 10) catch 0;
            }
        }
        if (w.sw == 0) {
            w.sx = w.x;
            w.sy = w.y;
            w.sw = w.w;
            w.sh = w.h;
        }
        if (std.mem.find(u8, line, "title=\"")) |t| {
            const rest = line[t + 7 ..];
            w.title = rest[0 .. std.mem.findScalarLast(u8, rest, '"') orelse rest.len];
        }
        wins.append(gpa, w) catch break;
    }
    return wins.items;
}

fn see(gpa: std.mem.Allocator, name: []const u8, max: usize) Seen {
    const where = ask(gpa, name, &.{"a11y"}) orelse die(4, "no desktop named {s} (see `headdesk list`)", .{name});
    var words = std.mem.tokenizeScalar(u8, where, ' ');
    const socket = words.next() orelse die(2, "desktop {s} gave no answer", .{name});
    const uid = std.fmt.parseInt(u32, words.next() orelse "0", 10) catch 0;
    var conn = dbus.Conn.connect(gpa, socket, uid) catch |err| switch (err) {
        error.Refused => die(2, "no app on {s} has an accessibility bus: start the app under `dbus-run-session --` on a system with at-spi2-core, and see the README for what each toolkit needs", .{name}),
        else => die(2, "the accessibility bus of {s} does not answer ({s})", .{ name, @errorName(err) }),
    };
    const tree = a11y.read(gpa, &conn, max, true);
    const windows = request(gpa, name, &.{"windows"}) catch "";
    return .{ .conn = conn, .tree = tree, .wins = parseWindows(gpa, windows) };
}

fn stateWords(buf: []u8, n: a11y.Node) []const u8 {
    var len: usize = 0;
    const words = [_]struct { bit: u6, word: []const u8 }{
        .{ .bit = a11y.State.focused, .word = " focused" },
        .{ .bit = a11y.State.checked, .word = " checked" },
        .{ .bit = a11y.State.selected, .word = " selected" },
        .{ .bit = a11y.State.expanded, .word = " expanded" },
        .{ .bit = a11y.State.editable, .word = " editable" },
    };
    for (words) |w| {
        if (n.is(w.bit)) {
            @memcpy(buf[len..][0..w.word.len], w.word);
            len += w.word.len;
        }
    }
    if (!n.is(a11y.State.sensitive) and !n.is(a11y.State.enabled)) {
        const word = " disabled";
        @memcpy(buf[len..][0..word.len], word);
        len += word.len;
    }
    return buf[0..len];
}

fn describe(gpa: std.mem.Allocator, s: *const Seen, index: usize) []const u8 {
    const n = s.tree.nodes.items[index];
    var line: std.ArrayList(u8) = .empty;
    var states: [64]u8 = undefined;
    line.print(gpa, "{s} \"{s}\"", .{ if (n.role.len > 0) n.role else "thing", n.name }) catch return "";
    if (n.text.len > 0) {
        line.appendSlice(gpa, " text=\"") catch {};
        for (n.text) |ch| line.append(gpa, if (ch < 0x20) ' ' else ch) catch {};
        line.append(gpa, '"') catch {};
    }
    if (n.has_rect) {
        if (s.window(n, index)) |w| {
            line.print(gpa, " at={d},{d} size={d}x{d} window={d}", .{ w.sx + n.rect.x, w.sy + n.rect.y, n.rect.w, n.rect.h, w.n }) catch {};
        } else line.print(gpa, " in-window={d},{d} size={d}x{d}", .{ n.rect.x, n.rect.y, n.rect.w, n.rect.h }) catch {};
    }
    line.appendSlice(gpa, stateWords(&states, n)) catch {};
    return line.items;
}

fn treeCommand(gpa: std.mem.Allocator, name: []const u8, all: bool, max: usize) u8 {
    var s = see(gpa, name, max);
    defer s.conn.close();
    if (s.tree.nodes.items.len == 0) {
        out("no app on {s} describes itself (see the README for what each toolkit needs)\n", .{name});
        return 1;
    }
    // indent by the ancestors that were printed
    var level: [64]u32 = @splat(0);
    var hidden_below: u32 = 0;
    var printed: usize = 0;
    for (s.tree.nodes.items, 0..) |n, index| {
        const d = @min(n.depth, 62);
        if (hidden_below != 0 and d > hidden_below) continue;
        hidden_below = 0;
        // a window or part that is not on screen hides all that is in it
        if (!all and d >= 2 and !n.shown()) {
            hidden_below = d;
            continue;
        }
        if (d == 1) {
            level[1] = 1;
            out("app \"{s}\"\n", .{n.name});
            continue;
        }
        const plain = n.name.len == 0 and n.text.len == 0 and a11y.isContainer(n.role);
        level[d] = level[d - 1] + @intFromBool(!plain);
        if (plain) continue;
        var indent: [128]u8 = @splat(' ');
        out("{s}{s}\n", .{ indent[0..@min(indent.len, (level[d] - 1) * 2)], describe(gpa, &s, index) });
        printed += 1;
    }
    if (s.tree.cut) out("... more than {d} things: the rest is left out (--max N)\n", .{max});
    return 0;
}

const Pick = struct { index: usize, fit: a11y.Fit };

/// The things on screen called `text` (and of role `role`), the best fits
/// first. A label inside a button of the same name is the button.
fn pick(gpa: std.mem.Allocator, s: *const Seen, text: []const u8, role: ?[]const u8) []Pick {
    const nodes = s.tree.nodes.items;
    var found: std.ArrayList(Pick) = .empty;
    for ([_]a11y.Fit{ .same, .same_but_case, .holds }) |want| {
        for (nodes, 0..) |n, i| {
            if (n.depth < 2 or !n.shown()) continue;
            if (role) |r| {
                if (a11y.fit(n.role, r) == .none) continue;
            }
            // no text asked for: everything of the role, once
            if (text.len == 0) {
                if (role == null or want != .same) continue;
                found.append(gpa, .{ .index = i, .fit = .same }) catch break;
                continue;
            }
            const by_name = a11y.fit(n.name, text);
            const by_text = if (n.text.len > 0) a11y.fit(n.text, text) else a11y.Fit.none;
            const best = if (@backingInt(by_text) < @backingInt(by_name)) by_text else by_name;
            if (best != want) continue;
            // inside something that fits as well: that is the thing
            var inside = false;
            var up = a11y.parentOf(nodes, i);
            while (up) |pi| : (up = a11y.parentOf(nodes, pi)) {
                const pn = nodes[pi];
                if (pn.depth >= 2 and pn.shown() and @backingInt(a11y.fit(pn.name, text)) <= @backingInt(want)) {
                    if (role == null or a11y.fit(pn.role, role.?) != .none) inside = true;
                }
            }
            if (inside) continue;
            // an app may list one thing twice
            var twice = false;
            for (found.items) |f| {
                const o = nodes[f.index];
                if (std.mem.eql(u8, o.role, n.role) and std.mem.eql(u8, o.name, n.name) and std.meta.eql(o.rect, n.rect)) twice = true;
            }
            if (twice) continue;
            found.append(gpa, .{ .index = i, .fit = want }) catch break;
        }
    }
    return found.items;
}

/// The one thing meant by `text`: the only one among the best fits. Its
/// index in the tree.
fn pickOne(gpa: std.mem.Allocator, s: *const Seen, name: []const u8, text: []const u8, role: ?[]const u8, nth: ?[]const u8) usize {
    if (text.len == 0 and role == null) die(2, "an empty name needs --role", .{});
    const all = pick(gpa, s, text, role);
    if (all.len == 0) die(1, "nothing on {s} is called \"{s}\" (see `headdesk tree {s}`)", .{ name, text, name });
    if (nth) |n_text| {
        const n = std.fmt.parseInt(usize, n_text, 10) catch die(2, "--nth is a number, 1 for the first", .{});
        if (n == 0 or n > all.len) die(1, "there are {d} such things on {s}, not {d}", .{ all.len, name, n });
        return all[n - 1].index;
    }
    var best: usize = 0;
    for (all) |p| best += @intFromBool(p.fit == all[0].fit);
    if (best == 1) return all[0].index;
    const picks = all[0..best];
    var buf: [2000]u8 = undefined;
    var len: usize = 0;
    for (picks[0..@min(picks.len, 8)]) |p| {
        const line = std.fmt.bufPrint(buf[len..], "\n  {s}", .{describe(gpa, s, p.index)}) catch break;
        len += line.len;
    }
    die(2, "{d} things on {s} are called \"{s}\"; say which with --role or --nth, or click by position:{s}", .{ picks.len, name, text, buf[0..len] });
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var buf: [1100]u8 = undefined;
    const fd = sys.openRead(std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null) catch return null;
    defer sys.close(fd);
    var all: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &chunk) catch break;
        if (n == 0) break;
        all.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    return all.items;
}

/// The first word after "ok " of what a desktop answers to `fields`.
fn ask(gpa: std.mem.Allocator, name: []const u8, fields: []const []const u8) ?[]const u8 {
    const answer = request(gpa, name, fields) catch return null;
    if (!std.mem.startsWith(u8, answer, "ok ")) return null;
    return std.mem.trim(u8, answer[3..], " \n");
}

/// Sends the inputs of the recording in `dir` to desktop `name` again and
/// compares how the desktop looks at the end with the recording's last picture.
const Pace = enum { timed, settle, frozen };

fn replay(gpa: std.mem.Allocator, name: []const u8, dir: []const u8, pace: Pace, speed: f64) u8 {
    const inputs = readFile(gpa, std.fmt.allocPrint(gpa, "{s}/inputs.txt", .{dir}) catch return 2) orelse die(2, "no recording in {s} (inputs.txt is missing)", .{dir});
    const frames = readFile(gpa, std.fmt.allocPrint(gpa, "{s}/frames.txt", .{dir}) catch return 2) orelse die(2, "no recording in {s} (frames.txt is missing)", .{dir});
    const meta = readFile(gpa, std.fmt.allocPrint(gpa, "{s}/meta.txt", .{dir}) catch return 2) orelse "";
    const ping = ask(gpa, name, &.{"ping"}) orelse die(4, "no desktop named {s} (see `headdesk list`)", .{name});
    // "size WxH" in the recording, "NAME WxH pid=N" from the desktop
    var ping_words = std.mem.tokenizeScalar(u8, ping, ' ');
    _ = ping_words.next();
    const size_now = ping_words.next() orelse "";
    if (std.mem.startsWith(u8, meta, "size ")) {
        const size_then = meta[5 .. std.mem.findScalar(u8, meta, '\n') orelse meta.len];
        if (!std.mem.eql(u8, size_then, size_now)) die(2, "the recording is of a {s} desktop and {s} is {s}", .{ size_then, name, size_now });
    }
    if (pace == .frozen) _ = request(gpa, name, &.{"freeze"}) catch {};
    const begun = sys.nowMs();
    var sent: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, inputs, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        const at = std.fmt.parseInt(u64, line[0..tab], 10) catch continue;
        switch (pace) {
            .settle => _ = request(gpa, name, &.{ "wait", "200", "10000", "0" }) catch {},
            .frozen => {},
            .timed => {
                const due: u64 = @intFromFloat(@as(f64, @floatFromInt(at)) / speed);
                const now = sys.nowMs() - begun;
                if (due > now) sys.sleepMs(due - now);
            },
        }
        var fields: [64][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line[tab + 1 ..], desk.field_sep);
        while (it.next()) |f| {
            if (count == fields.len) break;
            fields[count] = f;
            count += 1;
        }
        const answer = request(gpa, name, fields[0..count]) catch die(2, "desktop {s} went away during the replay", .{name});
        if (!std.mem.startsWith(u8, answer, "ok")) die(2, "input {d} of the recording was refused: {s}", .{ sent + 1, std.mem.trim(u8, answer, "\n") });
        sent += 1;
        // frozen: the apps draw what the input asks for, frame by frame
        if (pace == .frozen) _ = request(gpa, name, &.{ "step", "600", "quiet" }) catch {};
    }
    if (pace != .frozen) _ = request(gpa, name, &.{ "wait", "300", "10000", "0" }) catch {};
    const now_hash = ask(gpa, name, &.{"hash"}) orelse die(2, "desktop {s} went away during the replay", .{name});
    // the hash is the third word of the last line of frames.txt
    var last: []const u8 = "";
    var frame_lines = std.mem.tokenizeScalar(u8, frames, '\n');
    while (frame_lines.next()) |l| last = l;
    var words = std.mem.tokenizeScalar(u8, last, ' ');
    _ = words.next();
    _ = words.next();
    const then_hash = words.next() orelse "";
    const same = std.mem.eql(u8, now_hash, then_hash);
    out("replayed inputs={d} picture={s}\n", .{ sent, if (same) "same" else "differs" });
    return if (same) 0 else 1;
}

fn list(gpa: std.mem.Allocator) u8 {
    var base_buf: [512]u8 = undefined;
    var z_buf: [600]u8 = undefined;
    const base = baseDir(&base_buf);
    const path = std.fmt.bufPrintSentinel(&z_buf, "{s}", .{base}, 0) catch return 0;
    const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
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
            if (!validName(name)) continue;
            const answer = request(gpa, name, &.{"status"}) catch continue;
            defer gpa.free(answer);
            if (!std.mem.startsWith(u8, answer, "ok ")) continue;
            const first = answer[3 .. std.mem.findScalar(u8, answer, '\n') orelse answer.len];
            out("{s}\n", .{first});
        }
    }
    return 0;
}

fn output(name: []const u8) u8 {
    var dir_buf: [512]u8 = undefined;
    var z_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&z_buf, "{s}/app.log", .{deskDir(&dir_buf, name)}, 0) catch return 2;
    const fd = sys.openRead(path) catch die(4, "no desktop named {s} (see `headdesk list`)", .{name});
    defer sys.close(fd);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &chunk) catch break;
        if (n == 0) break;
        sys.writeAll(1, chunk[0..n]) catch break;
    }
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    environ = init.environ.block.slice;
    // a desktop or a bus that went away is an error to report, not a signal to die of
    sys.ignoreSigpipe();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const gpa = arena_state.allocator();
    const args = init.args.toSlice(gpa) catch die(2, "out of memory", .{});
    if (args.len < 2) {
        sys.writeAll(2, usage) catch {};
        return 2;
    }
    const cmd: []const u8 = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        sys.writeAll(1, usage) catch {};
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        out("headdesk {s}\n", .{version});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "start")) return start(gpa, rest);
    if (std.mem.eql(u8, cmd, "box")) return boxCommand(gpa, rest);
    if (std.mem.eql(u8, cmd, "check")) {
        if (box.unsupported()) |why| {
            out("sandbox no: {s}\n", .{why});
            return 1;
        }
        out("sandbox yes\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "list")) return list(gpa);

    if (std.mem.eql(u8, cmd, "exec")) {
        const p = parse(rest, &.{});
        const name = p.pos(0, "the desktop's name");
        if (p.rest.len == 0) die(2, "exec needs a program after --", .{});
        var fields: std.ArrayList([]const u8) = .empty;
        fields.append(gpa, "exec") catch return 2;
        for (p.rest) |a| fields.append(gpa, a) catch return 2;
        return talk(gpa, name, fields.items);
    }
    if (std.mem.eql(u8, cmd, "shot")) {
        const p = parse(rest, &.{"--window"});
        const name = p.pos(0, "the desktop's name");
        const file = absolute(gpa, p.pos(1, "the file to write"));
        return if (p.window) |w| talk(gpa, name, &.{ "shot", file, w }) else talk(gpa, name, &.{ "shot", file });
    }
    if (std.mem.eql(u8, cmd, "tree")) {
        const p = parse(rest, &.{ "--all", "--max" });
        const max = if (p.max) |m| (std.fmt.parseInt(usize, m, 10) catch die(2, "--max is a number", .{})) else 1500;
        return treeCommand(gpa, p.pos(0, "the desktop's name"), p.all, @max(1, max));
    }
    if (std.mem.eql(u8, cmd, "find")) {
        const p = parse(rest, &.{"--role"});
        const name = p.pos(0, "the desktop's name");
        var s = see(gpa, name, 5000);
        defer s.conn.close();
        const picks = pick(gpa, &s, p.pos(1, "the text to look for"), p.role);
        for (picks) |pk| {
            const n = s.tree.nodes.items[pk.index];
            if (n.has_rect) {
                if (s.window(n, pk.index)) |w| {
                    out("click={d},{d} {s}\n", .{ w.sx + n.rect.x + @divTrunc(n.rect.w, 2), w.sy + n.rect.y + @divTrunc(n.rect.h, 2), describe(gpa, &s, pk.index) });
                    continue;
                }
            }
            out("{s}\n", .{describe(gpa, &s, pk.index)});
        }
        if (picks.len == 0) out("nothing is called that\n", .{});
        return if (picks.len == 0) 1 else 0;
    }
    if (std.mem.eql(u8, cmd, "press") or std.mem.eql(u8, cmd, "fill")) {
        const p = parse(rest, &.{ "--role", "--nth" });
        const name = p.pos(0, "the desktop's name");
        var s = see(gpa, name, 5000);
        defer s.conn.close();
        const index = pickOne(gpa, &s, name, p.pos(1, "the thing's name"), p.role, p.nth);
        const n = s.tree.nodes.items[index];
        if (std.mem.eql(u8, cmd, "press")) {
            if (!n.actions) die(2, "{s} \"{s}\" can't be pressed that way; click it by position (`headdesk find`)", .{ n.role, n.name });
            if (!a11y.press(&s.conn, n)) die(1, "the app did not do it", .{});
            out("pressed {s} \"{s}\"\n", .{ n.role, n.name });
            return 0;
        }
        const text = p.pos(2, "the text to put in");
        if (a11y.setText(&s.conn, n, text)) {
            out("filled {s} \"{s}\"\n", .{ n.role, n.name });
            return 0;
        }
        // The app does not take text directly: click the field, select what
        // it holds and type over it, which only ASCII can do.
        for (text) |ch| {
            if (ch >= 0x80) die(1, "{s} \"{s}\" does not take text directly, and typing can only do ASCII", .{ n.role, n.name });
        }
        const w = s.window(n, index) orelse die(1, "{s} \"{s}\" does not take text directly, and its window can't be told", .{ n.role, n.name });
        if (!n.has_rect) die(1, "{s} \"{s}\" does not take text directly, and the app does not say where it is", .{ n.role, n.name });
        var xb: [16]u8 = undefined;
        var yb: [16]u8 = undefined;
        const x = std.fmt.bufPrint(&xb, "{d}", .{w.sx + n.rect.x + @divTrunc(n.rect.w, 2)}) catch unreachable;
        const y = std.fmt.bufPrint(&yb, "{d}", .{w.sy + n.rect.y + @divTrunc(n.rect.h, 2)}) catch unreachable;
        for ([_][]const []const u8{ &.{ "click", x, y, "", "1", "" }, &.{ "key", "ctrl+a" }, &.{ "type", text } }) |fields| {
            const answer = request(gpa, name, fields) catch die(2, "desktop {s} went away", .{name});
            if (!std.mem.startsWith(u8, answer, "ok")) die(1, "{s} \"{s}\" could not be typed into: {s}", .{ n.role, n.name, std.mem.trim(u8, answer, "\n") });
        }
        out("typed into {s} \"{s}\"\n", .{ n.role, n.name });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "click") or std.mem.eql(u8, cmd, "move")) {
        const p = parse(rest, &.{ "--window", "--button", "--double", "--name", "--role", "--nth" });
        const name = p.pos(0, "the desktop's name");
        if (p.name) |text| {
            // by name: where the app says the thing is
            var s = see(gpa, name, 5000);
            defer s.conn.close();
            const index = pickOne(gpa, &s, name, text, p.role, p.nth);
            const n = s.tree.nodes.items[index];
            const w = s.window(n, index) orelse die(2, "can't tell which window {s} \"{s}\" is in; click it by position", .{ n.role, n.name });
            if (!n.has_rect) die(2, "the app does not say where {s} \"{s}\" is", .{ n.role, n.name });
            var xb: [16]u8 = undefined;
            var yb: [16]u8 = undefined;
            const x = std.fmt.bufPrint(&xb, "{d}", .{w.sx + n.rect.x + @divTrunc(n.rect.w, 2)}) catch unreachable;
            const y = std.fmt.bufPrint(&yb, "{d}", .{w.sy + n.rect.y + @divTrunc(n.rect.h, 2)}) catch unreachable;
            return talk(gpa, name, &.{ cmd, x, y, p.button orelse "", if (p.double) "2" else "1", "" });
        }
        return talk(gpa, name, &.{ cmd, p.pos(1, "X"), p.pos(2, "Y"), p.button orelse "", if (p.double) "2" else "1", p.window orelse "" });
    }
    if (std.mem.eql(u8, cmd, "wait")) {
        const p = parse(rest, &.{ "--idle", "--timeout", "--windows" });
        return talk(gpa, p.pos(0, "the desktop's name"), &.{ "wait", p.idle orelse "300", p.timeout orelse "10000", p.windows orelse "0" });
    }
    if (std.mem.eql(u8, cmd, "log")) {
        const p = parse(rest, &.{"--since"});
        return talk(gpa, p.pos(0, "the desktop's name"), &.{ "log", p.since orelse "0" });
    }
    if (std.mem.eql(u8, cmd, "record")) {
        const p = parse(rest, &.{ "--fps", "--stop" });
        const name = p.pos(0, "the desktop's name");
        if (p.stop) return talk(gpa, name, &.{ "record", "stop" });
        return talk(gpa, name, &.{ "record", absolute(gpa, p.pos(1, "the directory to record into")), p.fps orelse "10" });
    }
    if (std.mem.eql(u8, cmd, "replay")) {
        const p = parse(rest, &.{ "--settle", "--frozen", "--speed" });
        const name = p.pos(0, "the desktop's name");
        if (p.settle and p.frozen) die(2, "--settle and --frozen are two ways to do the same thing; choose one", .{});
        const speed = if (p.speed) |s| (std.fmt.parseFloat(f64, s) catch die(2, "--speed is a number, as in 2 or 0.5", .{})) else 1.0;
        if (!(speed > 0.01 and speed <= 100)) die(2, "--speed is between 0.01 and 100", .{});
        return replay(gpa, name, absolute(gpa, p.pos(1, "the recording's directory")), if (p.frozen) .frozen else if (p.settle) .settle else .timed, speed);
    }
    if (std.mem.eql(u8, cmd, "output")) {
        const p = parse(rest, &.{});
        return output(p.pos(0, "the desktop's name"));
    }
    if (std.mem.eql(u8, cmd, "key")) {
        // keys such as "-" are not options
        if (rest.len < 2) die(2, "key needs a desktop and a key", .{});
        var fields: std.ArrayList([]const u8) = .empty;
        fields.append(gpa, "key") catch return 2;
        for (rest[1..]) |a| fields.append(gpa, a) catch return 2;
        return talk(gpa, rest[0], fields.items);
    }
    if (std.mem.eql(u8, cmd, "type")) {
        if (rest.len != 2) die(2, "type needs a desktop and one text", .{});
        return talk(gpa, rest[0], &.{ "type", rest[1] });
    }
    if (std.mem.eql(u8, cmd, "scroll")) {
        if (rest.len != 2) die(2, "scroll needs a desktop and a number of steps", .{});
        return talk(gpa, rest[0], &.{ "scroll", rest[1] });
    }
    if (std.mem.eql(u8, cmd, "kill")) {
        const p = parse(rest, &.{});
        const name = p.pos(0, "the desktop's name");
        const code = talk(gpa, name, &.{"kill"});
        // back only when the desktop is gone, so that its name is free again
        var tries: u32 = 0;
        while (code == 0 and tries < 200) : (tries += 1) {
            const answer = request(gpa, name, &.{"ping"}) catch break;
            gpa.free(answer);
            sys.sleepMs(10);
        }
        return code;
    }
    if (std.mem.eql(u8, cmd, "step")) {
        const p = parse(rest, &.{"--until-quiet"});
        const name = p.pos(0, "the desktop's name");
        if (p.until_quiet) return talk(gpa, name, &.{ "step", if (p.count >= 2) p.positional[1] else "600", "quiet" });
        return talk(gpa, name, &.{ "step", if (p.count >= 2) p.positional[1] else "1" });
    }
    const simple = [_][]const u8{ "windows", "status", "freeze", "thaw", "hash", "close", "focus" };
    for (simple) |s| {
        if (!std.mem.eql(u8, cmd, s)) continue;
        const p = parse(rest, &.{});
        const name = p.pos(0, "the desktop's name");
        if (p.count >= 2) return talk(gpa, name, &.{ cmd, p.positional[1] });
        return talk(gpa, name, &.{cmd});
    }
    die(2, "unknown command: {s} (see `headdesk help`)", .{cmd});
}

test {
    _ = @import("sys.zig");
    _ = @import("wire.zig");
    _ = @import("png.zig");
    _ = @import("keymap.zig");
    _ = @import("server.zig");
    _ = @import("desk.zig");
    _ = @import("box.zig");
    _ = @import("boxes.zig");
    _ = @import("record.zig");
    _ = @import("dbus.zig");
    _ = @import("a11y.zig");
}

test "desktop names" {
    try std.testing.expect(validName("a"));
    try std.testing.expect(validName("my-desk_2.x"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("-x"));
    try std.testing.expect(!validName("abcdefghijklmnopqrstuvwxyz0123456"));
}
