//! headdesk: a headless desktop for agents. `start` makes a desktop (a
//! process that is its own Wayland display server) with an app in it; the
//! other commands talk to that process.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const desk = @import("desk.zig");

pub const version = "0.1.0";

const usage =
    \\usage: headdesk <command> [options]
    \\
    \\  start NAME [--size WxH] [--cwd DIR] -- CMD...
    \\                        a new desktop with CMD running in it
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
    \\  click NAME X Y [--window N] [--button left|right|middle] [--double]
    \\  move NAME X Y [--window N]
    \\  scroll NAME STEPS     wheel notches down (negative: up)
    \\  key NAME KEY...       Return, Tab, Escape, F5, a, ctrl+s, ctrl+shift+t
    \\  type NAME TEXT        ASCII text, key by key
    \\  focus NAME N          bring window N to the front
    \\  close NAME N          ask window N to close
    \\
    \\  freeze NAME           apps are not told to draw any more
    \\  step NAME [N]         let N frames (1) through while frozen
    \\  thaw NAME             back to normal
    \\  log NAME [--since N]  every input and every drawing, in order
    \\  output NAME           what the apps printed
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
            if (std.mem.eql(u8, a, "--double")) {
                p.double = true;
                continue;
            }
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
            continue;
        }
        if (p.count == p.positional.len) die(2, "too many arguments", .{});
        p.positional[p.count] = a;
        p.count += 1;
    }
    return p;
}

fn start(gpa: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const p = parse(args, &.{ "--size", "--cwd" });
    const name = p.pos(0, "the desktop's name");
    if (p.rest.len == 0) die(2, "start needs a program after --", .{});
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
        var d = desk.Desk.init(gpa, .{ .name = name, .dir = dir, .width = width, .height = height, .argv = argv, .cwd = cwd, .envp = environ }) catch |err| die(2, "can't set up the desktop: {s}", .{@errorName(err)});
        _ = d.spawn(argv, cwd) catch |err| die(2, "can't start {s}: {s}", .{ argv[0], @errorName(err) });
        d.run();
        sys.exit(0);
    }
    // wait until the desktop answers
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        if (request(gpa, name, &.{"ping"})) |answer| {
            defer gpa.free(answer);
            out("started {s} pid={d} size={d}x{d}\n", .{ name, pid, width, height });
            return 0;
        } else |_| {}
        if (sys.reap(pid) != .running) break;
        sys.sleepMs(25);
    }
    die(2, "the desktop did not come up; see {s}/desktop.log", .{dir});
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
    if (std.mem.eql(u8, cmd, "click") or std.mem.eql(u8, cmd, "move")) {
        const p = parse(rest, &.{ "--window", "--button", "--double" });
        const name = p.pos(0, "the desktop's name");
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
    const simple = [_][]const u8{ "windows", "status", "kill", "freeze", "thaw", "step", "close", "focus" };
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
