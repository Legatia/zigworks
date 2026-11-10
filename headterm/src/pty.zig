//! Pseudo-terminal allocation and child spawning (macOS and Linux).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

const is_linux = builtin.os.tag == .linux;
// std only defines these for Linux; the macOS values come from <sys/ttycom.h>.
const TIOCSCTTY: u32 = if (is_linux) std.os.linux.T.IOCSCTTY else 0x20007461;
const TIOCSWINSZ: u32 = if (is_linux) std.os.linux.T.IOCSWINSZ else 0x80087467;

pub const Pty = struct {
    master: posix.fd_t,
    /// Kept open by the server so reading the master never fails with EIO
    /// when the child exits; the tail of the output can still be drained.
    slave: posix.fd_t,
    pid: posix.pid_t,
};

pub const SpawnError = error{ PtyOpenFailed, ExecFailed, ChdirFailed } || posix.OpenError || posix.ForkError || posix.PipeError || Allocator.Error;

fn ioctl(fd: posix.fd_t, request: u32, arg: usize) c_int {
    return std.c.ioctl(fd, @bitCast(request), arg);
}

pub fn setSize(fd: posix.fd_t, cols: u16, rows: u16) void {
    var ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws));
}

fn setCloexec(fd: posix.fd_t) void {
    _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch {};
}

/// Opens a PTY of the given size and starts `argv` on it as a session
/// leader with the PTY as controlling terminal. On exec failure the child's
/// error is reported here (via a close-on-exec pipe) rather than on screen.
/// `err_msg` receives a human-readable reason on failure.
pub fn spawn(
    gpa: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    cols: u16,
    rows: u16,
    err_msg: *[256]u8,
) (SpawnError || error{SpawnFailed})!Pty {
    const flags: u32 = @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    const master = posix_openpt(@bitCast(flags));
    if (master < 0) return error.PtyOpenFailed;
    errdefer posix.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyOpenFailed;
    const name_ptr = ptsname(master) orelse return error.PtyOpenFailed;
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{std.mem.sliceTo(name_ptr, 0)}) catch return error.PtyOpenFailed;
    setCloexec(master);

    const slave = try posix.openZ(name, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    errdefer posix.close(slave);
    // On macOS the first open of the slave resets the window size, so set it
    // only after opening.
    setSize(slave, cols, rows);

    // Everything the child needs is prepared before fork.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| argv_z[i] = (try arena.dupeZ(u8, a)).ptr;
    const cwd_z: ?[*:0]const u8 = if (cwd) |d| (try arena.dupeZ(u8, d)).ptr else null;

    const err_pipe = try posix.pipe2(.{ .CLOEXEC = true });

    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(err_pipe[0]);
        childExec(slave, argv_z, cwd_z, err_pipe[1]);
    }
    posix.close(err_pipe[1]);
    defer posix.close(err_pipe[0]);

    // EOF means exec succeeded; otherwise the child sent "<stage>:<reason>".
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = posix.read(err_pipe[0], buf[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    if (n > 0) {
        _ = posix.waitpid(pid, 0);
        const msg = buf[0..n];
        const colon = std.mem.indexOfScalar(u8, msg, ':') orelse msg.len;
        const stage = msg[0..colon];
        const reason = msg[@min(colon + 1, msg.len)..];
        const is_chdir = std.mem.eql(u8, stage, "chdir");
        const target = if (is_chdir) (cwd orelse "") else argv[0];
        _ = std.fmt.bufPrintZ(err_msg, "{s} {s}: {s}", .{ stage, target, reason }) catch {};
        return if (is_chdir) error.ChdirFailed else error.ExecFailed;
    }

    return .{ .master = master, .slave = slave, .pid = pid };
}

fn childExec(slave: posix.fd_t, argv: [*:null]?[*:0]const u8, cwd: ?[*:0]const u8, err_fd: posix.fd_t) noreturn {
    _ = posix.setsid() catch {};
    _ = ioctl(slave, TIOCSCTTY, 0);
    posix.dup2(slave, 0) catch {};
    posix.dup2(slave, 1) catch {};
    posix.dup2(slave, 2) catch {};
    if (slave > 2) posix.close(slave);

    // The server ignores SIGPIPE and SIGHUP, and ignored signals survive
    // exec; the program must get default dispositions.
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    for ([_]u8{ posix.SIG.PIPE, posix.SIG.HUP, posix.SIG.CHLD, posix.SIG.INT, posix.SIG.QUIT, posix.SIG.TERM }) |sig| {
        posix.sigaction(sig, &dfl, null);
    }

    if (cwd) |d| {
        if (std.c.chdir(d) != 0) reportAndExit(err_fd, "chdir", @tagName(posix.errno(-1)));
    }
    const env: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const err = posix.execvpeZ(argv[0].?, argv, env);
    reportAndExit(err_fd, "exec", @errorName(err));
}

fn reportAndExit(fd: posix.fd_t, stage: []const u8, reason: []const u8) noreturn {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}:{s}", .{ stage, reason }) catch stage;
    _ = posix.write(fd, msg) catch {};
    std.c._exit(127);
}
