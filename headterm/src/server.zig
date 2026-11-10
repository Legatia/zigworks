//! Session server: one background process per session. It owns the PTY and
//! the emulated screen, and answers requests on a Unix socket.
//!
//! Wire protocol: the client sends "<len>\n" followed by <len> bytes of
//! arguments, each terminated by a NUL byte, and keeps the connection open.
//! The server answers with a status line ("ok", "timeout" or "error"), "\n"
//! and the body, then closes the connection. A client that disconnects while
//! waiting cancels its wait.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const stylenote = @import("stylenote.zig");
const vt = @import("vt.zig");
const keys = @import("keys.zig");
const pty = @import("pty.zig");
const regex = @import("regex.zig");
const record = @import("record.zig");

pub const version = "0.3.0";
pub const default_wait_timeout_ms = 10_000;
pub const default_esc_delay_ms = 100;
const max_request = 1 << 20;

pub const Config = struct {
    name: []const u8,
    socket_path: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8,
    cols: u16,
    rows: u16,
    /// Raw PTY output is appended here when set (for debugging emulation).
    log_path: ?[]const u8 = null,
    /// End the session after this many seconds with no client request and
    /// no output.
    ttl_s: ?u32 = null,
    /// Write an asciicast v2 recording here.
    record_path: ?[]const u8 = null,
};

/// Diff markers kept per session; the least recently used one is dropped.
const max_markers = 64;
pub const max_client_id = 64;

pub const StartError = error{StartFailed} || posix.ForkError || posix.PipeError;

/// Forks the session server and waits until it has bound its socket and
/// started the child. Returns the child's pid. On failure `msg` holds the
/// reason.
pub fn start(gpa: Allocator, cfg: Config, msg: *[256]u8) StartError!posix.pid_t {
    const ready = try posix.pipe2(.{ .CLOEXEC = true });
    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(ready[0]);
        // Double fork: the server must not be a session leader or a child
        // of the CLI process.
        _ = posix.setsid() catch {};
        const pid2 = posix.fork() catch posix.exit(1);
        if (pid2 != 0) posix.exit(0);
        daemonMain(gpa, cfg, ready[1]);
    }
    posix.close(ready[1]);
    defer posix.close(ready[0]);
    _ = posix.waitpid(pid, 0);

    var buf: [512]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = posix.read(ready[0], buf[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    const reply = std.mem.trimRight(u8, buf[0..n], "\n");
    if (std.mem.startsWith(u8, reply, "ok ")) {
        return std.fmt.parseInt(posix.pid_t, reply[3..], 10) catch error.StartFailed;
    }
    const reason = if (std.mem.startsWith(u8, reply, "err ")) reply[4..] else "session server exited during startup";
    _ = std.fmt.bufPrintZ(msg, "{s}", .{reason[0..@min(reason.len, msg.len - 1)]}) catch {};
    return error.StartFailed;
}

fn daemonMain(gpa: Allocator, cfg: Config, ready_fd: posix.fd_t) noreturn {
    // Detach from the caller's stdio so `$(headterm start ...)` returns, and
    // drop any other inherited descriptors.
    if (posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0)) |null_fd| {
        for (0..3) |fd| posix.dup2(null_fd, @intCast(fd)) catch {};
        if (null_fd > 2) posix.close(null_fd);
    } else |_| {}
    var fd: posix.fd_t = 3;
    while (fd < 1024) : (fd += 1) {
        if (fd != ready_fd) _ = std.c.close(fd);
    }

    var session = Session.init(gpa, cfg) catch |err| {
        var buf: [300]u8 = undefined;
        const reason: []const u8 = switch (err) {
            error.AddressInUse => "session already exists",
            error.SpawnFailed, error.ExecFailed, error.ChdirFailed, error.RecordFailed => std.mem.sliceTo(&spawn_err, 0),
            else => @errorName(err),
        };
        const line = std.fmt.bufPrint(&buf, "err {s}\n", .{reason}) catch "err startup failed\n";
        _ = posix.write(ready_fd, line) catch {};
        posix.exit(1);
    };

    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "ok {d}\n", .{session.pty.pid}) catch unreachable;
    _ = posix.write(ready_fd, line) catch {};
    posix.close(ready_fd);

    session.run() catch {};
    session.deinit();
    posix.exit(0);
}

var spawn_err: [256]u8 = .{0} ** 256;
var sigchld_write_fd: posix.fd_t = -1;

fn onSigchld(_: i32) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = posix.write(sigchld_write_fd, "c") catch {};
    std.c._errno().* = saved;
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

/// How long `--settle` waits for a program to print anything after keys were
/// sent, before taking the keys to have no visible effect.
const settle_grace_ms = 500;

/// A wait for the program's exit gives up early when the program has gone
/// quiet for this long with the terminal in raw mode or echo off: it is
/// then reading keys, not finishing.
const awaiting_input_ms = 2000;

const Waiter = struct {
    fd: posix.fd_t,
    text: ?[]u8 = null,
    regex: ?*regex.Regex = null,
    gone: ?[]u8 = null,
    idle_ms: ?i64 = null,
    /// The program has printed something, then nothing for this long.
    settle_ms: ?i64 = null,
    exit: bool = false,
    /// Owned copy of the --client id that render.client points to.
    client: ?[]u8 = null,
    render: Session.RenderOptions = .{},
    started: i64,
    deadline: i64 = 0,

    fn exitOnly(w: Waiter) bool {
        return w.exit and w.text == null and w.regex == null and w.gone == null and w.idle_ms == null and w.settle_ms == null;
    }

    /// Conditions that only depend on what is on screen.
    fn screenOnly(w: Waiter) bool {
        return (w.text != null or w.regex != null or w.gone != null) and w.idle_ms == null and w.settle_ms == null and !w.exit;
    }
};

fn withWait(opts: Session.RenderOptions, outcome: WaitOutcome) Session.RenderOptions {
    var o = opts;
    o.wait = outcome;
    return o;
}

fn waitCondition(w: Waiter) []const u8 {
    if (w.text != null) return "text";
    if (w.regex != null) return "regex";
    if (w.gone != null) return "gone";
    if (w.idle_ms != null) return "idle";
    if (w.settle_ms != null) return "settle";
    return "exit";
}

const Marker = struct {
    /// Row signatures (text and styles) as last returned to this client.
    rows: std.ArrayList([]u8) = .empty,
    used_ms: i64 = 0,

    fn deinit(m: *Marker, gpa: Allocator) void {
        for (m.rows.items) |l| gpa.free(l);
        m.rows.deinit(gpa);
    }
};

const WaitOutcome = struct {
    condition: []const u8,
    satisfied: bool,
    reason: []const u8,
    elapsed_ms: i64,
};

const Status = enum { ok, timeout, @"error" };

const Session = struct {
    gpa: Allocator,
    cfg: Config,
    term: vt.Terminal,
    pty: pty.Pty,
    listen_fd: posix.fd_t,
    sig_pipe: [2]posix.fd_t,
    pty_open: bool = true,
    child_exited: bool = false,
    exit_code: ?u8 = null,
    exit_signal: ?u8 = null,
    started_ms: i64,
    last_output_ms: i64,
    /// When the screen last changed. `--idle` and the "awaiting-input" check
    /// count from here. Output that leaves the screen as it was doesn't
    /// count, and neither does a change of colors or attributes alone that
    /// puts back the screen before the last one: that is a cursor the program
    /// draws itself and blinks (Bubble Tea), which would keep a waiting form
    /// busy forever.
    last_change_ms: i64,
    screen_sig: vt.Terminal.Signatures = .{ .text = 0, .full = 0 },
    /// `screen_sig.full` before the last change.
    prev_full_sig: u64 = 0,
    /// Last client request or program output, for --ttl.
    last_activity_ms: i64,
    input: std.ArrayList(u8) = .empty,
    /// Rows as returned by the last screen/wait response, for --diff.
    /// Diff markers by client id ("" for clients that pass no --client).
    markers: std.StringHashMapUnmanaged(Marker) = .empty,
    waiters: std.ArrayList(Waiter) = .empty,
    quit: bool = false,
    log_fd: ?posix.fd_t = null,
    /// The program has printed anything at all.
    output_seen: bool = false,
    /// When keys were last sent (0: never), and whether the program has
    /// printed since. `--settle` waits for the reaction to those keys.
    last_send_ms: i64 = 0,
    output_since_send: bool = false,
    /// `last_send_ms` when a wait for exit last gave up as "awaiting-input";
    /// it does so once per send, so a program that is working after all can
    /// be waited for with a second wait.
    awaiting_reported_send_ms: ?i64 = null,
    /// The terminal was in line mode with echo when last checked for the
    /// above; look again after this time.
    awaiting_recheck_ms: i64 = 0,
    recorder: ?record.Recorder = null,

    fn init(gpa: Allocator, cfg: Config) !Session {
        const ignore: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(posix.SIG.PIPE, &ignore, null);
        posix.sigaction(posix.SIG.HUP, &ignore, null);

        const sig_pipe = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        sigchld_write_fd = sig_pipe[1];
        const on_chld: posix.Sigaction = .{ .handler = .{ .handler = onSigchld }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART | posix.SA.NOCLDSTOP };
        posix.sigaction(posix.SIG.CHLD, &on_chld, null);

        const addr = try std.net.Address.initUnix(cfg.socket_path);
        var server = try addr.listen(.{});
        errdefer server.deinit();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintZ(&path_buf, "{s}", .{cfg.socket_path})) |path_z| {
            _ = std.c.chmod(path_z, 0o600);
        } else |_| {}

        var term = try vt.Terminal.init(gpa, .{ .cols = cfg.cols, .rows = cfg.rows });
        errdefer term.deinit();

        _ = setenv("TERM", "xterm-256color", 1);
        _ = unsetenv("COLUMNS");
        _ = unsetenv("LINES");
        // Opened before the program starts so no output is missed.
        var recorder: ?record.Recorder = null;
        if (cfg.record_path) |rp| {
            recorder = record.Recorder.create(gpa, rp, cfg.cols, cfg.rows, cfg.argv) catch |err| {
                _ = std.fmt.bufPrintZ(&spawn_err, "cannot write recording {s}: {s}", .{ rp, @errorName(err) }) catch {};
                posix.unlink(cfg.socket_path) catch {};
                return error.RecordFailed;
            };
        }
        errdefer if (recorder) |*r| r.deinit();

        const p = pty.spawn(gpa, cfg.argv, cfg.cwd, cfg.cols, cfg.rows, &spawn_err) catch |err| {
            posix.unlink(cfg.socket_path) catch {};
            return err;
        };
        _ = try posix.fcntl(p.master, posix.F.SETFL, @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

        const log_fd: ?posix.fd_t = if (cfg.log_path) |lp|
            posix.open(lp, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch null
        else
            null;

        const now = nowMs();
        return .{
            .log_fd = log_fd,
            .recorder = recorder,
            .gpa = gpa,
            .cfg = cfg,
            .term = term,
            .pty = p,
            .listen_fd = server.stream.handle,
            .sig_pipe = sig_pipe,
            .started_ms = now,
            .last_output_ms = now,
            .last_change_ms = now,
            .last_activity_ms = now,
        };
    }

    fn closeListener(self: *Session) void {
        if (self.listen_fd < 0) return;
        posix.unlink(self.cfg.socket_path) catch {};
        posix.close(self.listen_fd);
        self.listen_fd = -1;
    }

    fn deinit(self: *Session) void {
        self.closeListener();
        for (self.waiters.items) |w| {
            posix.close(w.fd);
            if (w.text) |t| self.gpa.free(t);
        }
        self.waiters.deinit(self.gpa);
        var it = self.markers.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.markers.deinit(self.gpa);
        self.input.deinit(self.gpa);
        self.term.deinit();
        if (self.recorder) |*r| r.deinit();
    }

    fn run(self: *Session) !void {
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.gpa);

        while (!self.quit) {
            fds.clearRetainingCapacity();
            var master_events: i16 = 0;
            if (self.pty_open) master_events |= posix.POLL.IN;
            if (self.pty_open and self.input.items.len > 0) master_events |= posix.POLL.OUT;
            try fds.append(self.gpa, .{ .fd = self.pty.master, .events = master_events, .revents = 0 });
            try fds.append(self.gpa, .{ .fd = self.listen_fd, .events = posix.POLL.IN, .revents = 0 });
            try fds.append(self.gpa, .{ .fd = self.sig_pipe[0], .events = posix.POLL.IN, .revents = 0 });
            for (self.waiters.items) |w| {
                try fds.append(self.gpa, .{ .fd = w.fd, .events = posix.POLL.IN, .revents = 0 });
            }

            _ = try posix.poll(fds.items, self.pollTimeout(nowMs()));

            if (fds.items[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) try self.readPty();
            if (fds.items[0].revents & posix.POLL.OUT != 0) self.flushInput();
            if (fds.items[2].revents != 0) {
                var drain: [64]u8 = undefined;
                while (true) _ = posix.read(self.sig_pipe[0], &drain) catch break;
                try self.reapChild();
            }
            // A waiting client that sends data or hangs up has gone away.
            var i = self.waiters.items.len;
            while (i > 0) {
                i -= 1;
                if (fds.items[3 + i].revents != 0) self.dropWaiter(i);
            }
            if (fds.items[1].revents & posix.POLL.IN != 0) self.acceptClient();
            try self.checkWaiters();
            self.checkExpiry();
        }

        // Session killed: answer whoever is still waiting.
        const now = nowMs();
        while (self.waiters.items.len > 0) {
            const w = self.waiters.items[0];
            const outcome: WaitOutcome = .{ .condition = waitCondition(w), .satisfied = false, .reason = "killed", .elapsed_ms = now - w.started };
            self.respondScreen(w.fd, .timeout, withWait(w.render, outcome)) catch {};
            self.dropWaiter(0);
        }
    }

    fn pollTimeout(self: *Session, now: i64) i32 {
        var next: ?i64 = null;
        for (self.waiters.items) |w| {
            var t = w.deadline;
            if (w.idle_ms) |idle| t = @min(t, @max(self.last_change_ms, w.started) + idle);
            if (w.settle_ms) |ms| {
                if (self.settledAt(ms)) |at| t = @min(t, at);
            }
            if (self.awaitingInputAt(w)) |at| t = @min(t, at);
            next = if (next) |n| @min(n, t) else t;
        }
        if (self.expiresAt()) |t| next = if (next) |n| @min(n, t) else t;
        const n = next orelse return -1;
        return @intCast(std.math.clamp(n - now, 0, 60_000));
    }

    /// When the session expires, or null if it has no TTL or a client is
    /// waiting on it.
    fn expiresAt(self: *Session) ?i64 {
        const ttl = self.cfg.ttl_s orelse return null;
        if (self.waiters.items.len > 0 or self.quit) return null;
        return self.last_activity_ms + @as(i64, ttl) * 1000;
    }

    fn checkExpiry(self: *Session) void {
        const at = self.expiresAt() orelse return;
        if (nowMs() < at) return;
        self.terminateChild() catch {};
        self.closeListener();
        self.quit = true;
    }

    fn readPty(self: *Session) !void {
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < 4 << 20) {
            const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.pty_open = false;
                    break;
                },
            };
            if (n == 0) {
                self.pty_open = false;
                break;
            }
            total += n;
            if (self.log_fd) |lf| writeAll(lf, buf[0..n]) catch {};
            if (self.recorder) |*r| r.output(buf[0..n]);
            try self.term.feed(buf[0..n]);
            if (self.term.reply.items.len > 0) {
                try self.input.appendSlice(self.gpa, self.term.reply.items);
                self.term.reply.clearRetainingCapacity();
            }
        }
        if (total > 0) {
            self.last_output_ms = nowMs();
            self.last_activity_ms = self.last_output_ms;
            self.output_seen = true;
            self.output_since_send = true;
            const sig = self.term.signatures();
            if (sig.full != self.screen_sig.full) {
                const blink = sig.text == self.screen_sig.text and sig.full == self.prev_full_sig;
                self.prev_full_sig = self.screen_sig.full;
                self.screen_sig = sig;
                if (!blink) self.last_change_ms = self.last_output_ms;
            }
        }
        if (self.input.items.len > 0) self.flushInput();
    }

    fn flushInput(self: *Session) void {
        while (self.input.items.len > 0) {
            const n = posix.write(self.pty.master, self.input.items) catch break;
            std.mem.copyForwards(u8, self.input.items, self.input.items[n..]);
            self.input.shrinkRetainingCapacity(self.input.items.len - n);
        }
    }

    fn reapChild(self: *Session) !void {
        if (self.child_exited) return;
        const r = posix.waitpid(self.pty.pid, posix.W.NOHANG);
        if (r.pid != self.pty.pid) return;
        self.child_exited = true;
        if (posix.W.IFEXITED(r.status)) {
            self.exit_code = posix.W.EXITSTATUS(r.status);
        } else if (posix.W.IFSIGNALED(r.status)) {
            self.exit_signal = @intCast(posix.W.TERMSIG(r.status));
        }
        // Output written just before exit is still buffered in the PTY.
        try self.readPty();
    }

    fn terminateChild(self: *Session) !void {
        const pid = self.pty.pid;
        const signals = [_]u8{ posix.SIG.HUP, posix.SIG.TERM, posix.SIG.KILL };
        for (signals) |sig| {
            if (self.child_exited) return;
            posix.kill(-pid, sig) catch {};
            posix.kill(pid, sig) catch {};
            const until = nowMs() + 500;
            while (!self.child_exited and nowMs() < until) {
                var pfd = [_]posix.pollfd{.{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 }};
                _ = posix.poll(&pfd, 10) catch {};
                if (pfd[0].revents != 0) try self.readPty();
                try self.reapChild();
            }
        }
    }

    fn acceptClient(self: *Session) void {
        const fd = posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC) catch return;
        self.last_activity_ms = nowMs();
        const tv: posix.timeval = .{ .sec = 2, .usec = 0 };
        // libc directly: macOS fails with EINVAL if the client has already
        // hung up, which std.posix.setsockopt treats as unreachable.
        _ = std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(posix.timeval));

        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(self.gpa);
        const payload = self.readRequest(fd, &req) orelse {
            posix.close(fd);
            return;
        };

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, payload, 0);
        while (it.next()) |a| {
            if (it.peek() == null and a.len == 0) break; // trailing terminator
            args.append(self.gpa, a) catch {
                posix.close(fd);
                return;
            };
        }

        const keep_open = self.handle(fd, args.items) catch |err| blk: {
            var msg: [128]u8 = undefined;
            respond(fd, .@"error", std.fmt.bufPrint(&msg, "internal error: {s}\n", .{@errorName(err)}) catch "internal error\n");
            break :blk false;
        };
        if (!keep_open) posix.close(fd);
    }

    fn readRequest(self: *Session, fd: posix.fd_t, req: *std.ArrayList(u8)) ?[]const u8 {
        var buf: [4096]u8 = undefined;
        var want: ?usize = null;
        var header_len: usize = 0;
        while (true) {
            if (want == null) {
                if (std.mem.indexOfScalar(u8, req.items, '\n')) |nl| {
                    const len = std.fmt.parseInt(usize, req.items[0..nl], 10) catch return null;
                    if (len > max_request) return null;
                    want = len;
                    header_len = nl + 1;
                }
            }
            if (want) |len| {
                if (req.items.len >= header_len + len) return req.items[header_len..][0..len];
            }
            const n = posix.read(fd, &buf) catch return null;
            if (n == 0) return null;
            req.appendSlice(self.gpa, buf[0..n]) catch return null;
            if (req.items.len > max_request + 32) return null;
        }
    }

    /// Handles one request. Returns true if `fd` was handed to a waiter.
    fn handle(self: *Session, fd: posix.fd_t, args: []const []const u8) !bool {
        if (args.len == 0) {
            respond(fd, .@"error", "empty request\n");
            return false;
        }
        const cmd = args[0];
        const rest = args[1..];
        if (std.mem.eql(u8, cmd, "screen")) {
            var opts: RenderOptions = .{};
            var i: usize = 0;
            while (i < rest.len) : (i += 1) {
                const a = rest[i];
                if (std.mem.eql(u8, a, "--json")) {
                    opts.json = true;
                } else if (std.mem.eql(u8, a, "--diff")) {
                    opts.diff = true;
                } else if (std.mem.eql(u8, a, "--styles")) {
                    opts.styles = true;
                } else if (std.mem.eql(u8, a, "--trim")) {
                    opts.trim = true;
                } else if (std.mem.eql(u8, a, "--client") and i + 1 < rest.len) {
                    i += 1;
                    if (!validClientId(rest[i])) return self.usagef(fd, "screen: --client id must be 1 to 64 bytes, got {d}", .{rest[i].len});
                    opts.client = rest[i];
                } else if (std.mem.eql(u8, a, "--scrollback") and i + 1 < rest.len) {
                    i += 1;
                    opts.scrollback = std.fmt.parseInt(usize, rest[i], 10) catch return self.usagef(fd, "screen: --scrollback needs a number of lines, got '{s}'", .{rest[i]});
                } else {
                    return self.usagef(fd, "screen: unknown option '{s}' (see 'headterm help screen')", .{a});
                }
            }
            try self.respondScreen(fd, .ok, opts);
            return false;
        }
        if (std.mem.eql(u8, cmd, "wait")) return self.handleWait(fd, rest);
        if (std.mem.eql(u8, cmd, "send")) {
            try self.handleSend(fd, rest);
            return false;
        }
        if (std.mem.eql(u8, cmd, "resize")) {
            if (rest.len != 2) return self.usage(fd, "resize: expected <cols> <rows>, e.g. 'headterm resize NAME 120 40'");
            const cols = std.fmt.parseInt(u16, rest[0], 10) catch 0;
            const rows = std.fmt.parseInt(u16, rest[1], 10) catch 0;
            if (cols < 2 or rows < 1 or cols > 1000 or rows > 1000) return self.usagef(fd, "resize: '{s}' '{s}' is out of range: cols must be 2..1000 and rows 1..1000", .{ rest[0], rest[1] });
            pty.setSize(self.pty.master, cols, rows);
            try self.term.resize(cols, rows);
            if (self.recorder) |*r| r.resize(cols, rows);
            if (!self.child_exited) posix.kill(-self.pty.pid, posix.SIG.WINCH) catch {};
            respond(fd, .ok, "");
            return false;
        }
        if (std.mem.eql(u8, cmd, "kill")) {
            try self.terminateChild();
            // Stop accepting before answering, so a request sent right after
            // `kill` finds no session instead of a socket nobody serves.
            self.closeListener();
            respond(fd, .ok, "");
            self.quit = true;
            return false;
        }
        if (std.mem.eql(u8, cmd, "info")) {
            var out: std.Io.Writer.Allocating = .init(self.gpa);
            defer out.deinit();
            try self.writeInfo(&out.writer);
            try out.writer.writeByte('\n');
            respond(fd, .ok, out.written());
            return false;
        }
        return self.usagef(fd, "unknown request '{s}' (client and session server versions differ?)", .{cmd});
    }

    fn usagef(self: *Session, fd: posix.fd_t, comptime fmt: []const u8, args: anytype) bool {
        var buf: [512]u8 = undefined;
        return self.usage(fd, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    fn usage(self: *Session, fd: posix.fd_t, msg: []const u8) bool {
        _ = self;
        var buf: [256]u8 = undefined;
        respond(fd, .@"error", std.fmt.bufPrint(&buf, "{s}\n", .{msg}) catch msg);
        return false;
    }

    fn handleSend(self: *Session, fd: posix.fd_t, args: []const []const u8) !void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        // Offsets into `bytes` after which to pause: a bare Esc immediately
        // followed by more input is read as an Alt/escape sequence by many
        // programs (busybox vi, readline), so it is sent separately.
        var pauses: std.ArrayList(usize) = .empty;
        defer pauses.deinit(self.gpa);
        var esc_delay: u32 = default_esc_delay_ms;
        var literal = false;
        var paste = false;
        var options_done = false;
        var pasted: std.ArrayList(u8) = .empty;
        defer pasted.deinit(self.gpa);
        // `down down enter`: key names in another case, in a send without a
        // properly spelled key, are keys. The reply says so.
        const other_case = keys.otherCaseAllowed(args);
        var renamed: std.ArrayList(u8) = .empty;
        defer renamed.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            var a = args[i];
            // Options are recognized until "--" or "--literal"; after that
            // every argument is a key or text.
            if (!options_done and !literal) {
                if (std.mem.eql(u8, a, "--")) {
                    options_done = true;
                    continue;
                }
                if (std.mem.eql(u8, a, "--literal")) {
                    literal = true;
                    continue;
                }
                if (std.mem.eql(u8, a, "--paste")) {
                    paste = true;
                    continue;
                }
                if (std.mem.eql(u8, a, "--esc-delay") and i + 1 < args.len) {
                    i += 1;
                    esc_delay = std.fmt.parseInt(u32, args[i], 10) catch {
                        _ = self.usagef(fd, "send: --esc-delay needs milliseconds, got '{s}'", .{args[i]});
                        return;
                    };
                    continue;
                }
            }
            if (paste) {
                try pasted.appendSlice(self.gpa, a);
                continue;
            }
            if (literal) {
                try bytes.appendSlice(self.gpa, a);
                continue;
            }
            if (other_case) {
                if (keys.otherCaseKey(a)) |name| {
                    a = name;
                    if (renamed.items.len > 0) try renamed.append(self.gpa, ' ');
                    try renamed.appendSlice(self.gpa, name);
                }
            }
            const before = bytes.items.len;
            const ctx: keys.Context = .{
                .app_cursor = self.term.modes.app_cursor,
                .mouse_tracking = self.term.modes.mouse_tracking,
                .mouse_sgr = self.term.modes.mouse_sgr,
                .rows = self.term.rows,
                .cols = self.term.cols,
            };
            keys.encodeArg(self.gpa, &bytes, a, ctx) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = switch (err) {
                    error.UnknownKey => std.fmt.bufPrint(&buf, "unknown key {s} (use --literal to send it as text)\n", .{a}),
                    error.MouseNotEnabled => std.fmt.bufPrint(&buf, "{s}: the program has not enabled mouse reporting, so it does not accept mouse input\n", .{a}),
                    error.BadMousePosition => std.fmt.bufPrint(&buf, "{s}: expected <Click row,col> with 0-based row < {d} and col < {d}\n", .{ a, self.term.rows, self.term.cols }),
                    error.OutOfMemory => return error.OutOfMemory,
                } catch "bad key\n";
                respond(fd, .@"error", msg);
                return;
            };
            if ((keys.isKeySyntax(a) or keys.isBareKey(a)) and bytes.items.len == before + 1 and bytes.items[before] == 0x1b) {
                try pauses.append(self.gpa, bytes.items.len);
            }
        }
        // Pasted text goes out as one block, wrapped in bracketed-paste
        // markers if the program asked for them.
        if (paste) {
            if (self.term.modes.bracketed_paste) try bytes.appendSlice(self.gpa, "\x1b[200~");
            try bytes.appendSlice(self.gpa, pasted.items);
            if (self.term.modes.bracketed_paste) try bytes.appendSlice(self.gpa, "\x1b[201~");
        }
        if (self.child_exited) {
            respond(fd, .@"error", "the program has exited, so nothing was sent; 'screen' still shows its last screen and 'kill' ends the session\n");
            return;
        }
        // Keys sent before a just-started program has drawn anything can be
        // lost (some programs flush typeahead) or misread, so hold them until
        // its first output has settled.
        if (!self.output_seen and nowMs() - self.started_ms < 5_000) try self.settleFirstOutput(2_000);

        self.last_send_ms = nowMs();
        self.output_since_send = false;
        var from: usize = 0;
        for (pauses.items) |at| {
            if (at == bytes.items.len or esc_delay == 0) continue;
            try self.queueInput(bytes.items[from..at]);
            from = at;
            try self.pumpFor(esc_delay);
        }
        try self.queueInput(bytes.items[from..]);
        self.flushInput();
        if (renamed.items.len == 0) return respond(fd, .ok, "");
        var note: std.Io.Writer.Allocating = .init(self.gpa);
        defer note.deinit();
        try note.writer.print("sent as keys: {s} (--literal sends such words as text)\n", .{renamed.items});
        respond(fd, .ok, note.written());
    }

    /// Queues keys from `send` for the program (and the recording).
    fn queueInput(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.input.appendSlice(self.gpa, bytes);
        if (self.recorder) |*r| r.input(bytes);
    }

    /// Reads output until the program has printed something and then been
    /// quiet for 150 ms, or for at most `max_ms`.
    fn settleFirstOutput(self: *Session, max_ms: i64) !void {
        const until = nowMs() + max_ms;
        while (self.pty_open) {
            const now = nowMs();
            if (now >= until) break;
            if (self.output_seen and now - self.last_output_ms >= 150) break;
            var pfd = [_]posix.pollfd{.{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 }};
            _ = try posix.poll(&pfd, @intCast(@min(until - now, 50)));
            if (pfd[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) try self.readPty();
            if (!self.child_exited) try self.reapChild();
            if (self.child_exited and self.output_seen) break;
        }
    }

    /// Keeps reading output and writing queued input for `ms` milliseconds.
    fn pumpFor(self: *Session, ms: u32) !void {
        const until = nowMs() + ms;
        while (true) {
            const now = nowMs();
            if (now >= until or !self.pty_open) break;
            var events: i16 = posix.POLL.IN;
            if (self.input.items.len > 0) events |= posix.POLL.OUT;
            var pfd = [_]posix.pollfd{.{ .fd = self.pty.master, .events = events, .revents = 0 }};
            _ = try posix.poll(&pfd, @intCast(until - now));
            if (pfd[0].revents & posix.POLL.OUT != 0) self.flushInput();
            if (pfd[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) try self.readPty();
        }
    }

    fn handleWait(self: *Session, fd: posix.fd_t, args: []const []const u8) !bool {
        var w: Waiter = .{ .fd = fd, .started = nowMs() };
        errdefer self.freeWaiter(w);
        var timeout: i64 = default_wait_timeout_ms;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            const val: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
            if (std.mem.eql(u8, a, "--exit")) {
                w.exit = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                w.render.json = true;
            } else if (std.mem.eql(u8, a, "--diff")) {
                w.render.diff = true;
            } else if (std.mem.eql(u8, a, "--styles")) {
                w.render.styles = true;
            } else if (std.mem.eql(u8, a, "--trim")) {
                w.render.trim = true;
            } else if (val) |v| {
                i += 1;
                if (std.mem.eql(u8, a, "--text")) {
                    if (w.text != null) return self.waitError(w, "wait: --text given twice");
                    w.text = try self.gpa.dupe(u8, v);
                } else if (std.mem.eql(u8, a, "--text-gone")) {
                    if (w.gone != null) return self.waitError(w, "wait: --text-gone given twice");
                    w.gone = try self.gpa.dupe(u8, v);
                } else if (std.mem.eql(u8, a, "--regex")) {
                    if (w.regex != null) return self.waitError(w, "wait: --regex given twice");
                    var diag: regex.Diagnostic = .{};
                    var re = regex.Regex.compile(self.gpa, v, &diag) catch |err| switch (err) {
                        error.BadRegex => {
                            var buf: [300]u8 = undefined;
                            const text = std.fmt.bufPrint(&buf, "wait: bad --regex: {s}", .{diag.message()}) catch "wait: bad --regex";
                            return self.waitError(w, text);
                        },
                        else => |e| return e,
                    };
                    errdefer re.deinit();
                    const ptr = try self.gpa.create(regex.Regex);
                    ptr.* = re;
                    w.regex = ptr;
                } else if (std.mem.eql(u8, a, "--settle")) {
                    w.settle_ms = std.fmt.parseInt(i64, v, 10) catch return self.waitErrorf(w, "wait: --settle needs milliseconds, got '{s}'", .{v});
                } else if (std.mem.eql(u8, a, "--idle")) {
                    w.idle_ms = std.fmt.parseInt(i64, v, 10) catch return self.waitErrorf(w, "wait: --idle needs milliseconds, got '{s}'", .{v});
                } else if (std.mem.eql(u8, a, "--timeout")) {
                    timeout = std.fmt.parseInt(i64, v, 10) catch return self.waitErrorf(w, "wait: --timeout needs milliseconds, got '{s}'", .{v});
                } else if (std.mem.eql(u8, a, "--scrollback")) {
                    w.render.scrollback = std.fmt.parseInt(usize, v, 10) catch return self.waitErrorf(w, "wait: --scrollback needs a number of lines, got '{s}'", .{v});
                } else if (std.mem.eql(u8, a, "--client")) {
                    if (!validClientId(v)) return self.waitErrorf(w, "wait: --client id must be 1 to 64 bytes, got {d}", .{v.len});
                    if (w.client) |c| self.gpa.free(c);
                    w.client = try self.gpa.dupe(u8, v);
                } else {
                    return self.waitErrorf(w, "wait: unknown option '{s}' (see 'headterm help wait')", .{a});
                }
            } else {
                const known = for ([_][]const u8{ "--text", "--text-gone", "--regex", "--idle", "--settle", "--timeout", "--scrollback", "--client" }) |k| {
                    if (std.mem.eql(u8, a, k)) break true;
                } else false;
                if (known) return self.waitErrorf(w, "wait: {s} needs a value", .{a});
                return self.waitErrorf(w, "wait: unknown option '{s}' (see 'headterm help wait')", .{a});
            }
        }
        if (w.text == null and w.regex == null and w.gone == null and w.idle_ms == null and w.settle_ms == null and !w.exit) {
            return self.waitError(w, "wait: give a condition: --text STR, --regex RE, --text-gone STR, --idle MS, --settle MS or --exit");
        }
        if (w.client) |c| w.render.client = c;
        w.deadline = w.started + timeout;
        try self.waiters.append(self.gpa, w);
        // Checked on the next loop iteration, so an already-true condition
        // returns immediately.
        return true;
    }

    fn waitErrorf(self: *Session, w: Waiter, comptime fmt: []const u8, args: anytype) bool {
        var buf: [512]u8 = undefined;
        return self.waitError(w, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    fn waitError(self: *Session, w: Waiter, msg: []const u8) bool {
        self.freeWaiter(w);
        return self.usage(w.fd, msg);
    }

    fn freeWaiter(self: *Session, w: Waiter) void {
        if (w.text) |t| self.gpa.free(t);
        if (w.gone) |t| self.gpa.free(t);
        if (w.client) |c| self.gpa.free(c);
        if (w.regex) |re| {
            re.deinit();
            self.gpa.destroy(re);
        }
    }

    fn dropWaiter(self: *Session, i: usize) void {
        const w = self.waiters.orderedRemove(i);
        posix.close(w.fd);
        self.freeWaiter(w);
    }

    fn checkWaiters(self: *Session) !void {
        if (self.waiters.items.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const lines = try self.logicalLines(arena_state.allocator());

        const now = nowMs();
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            const w = self.waiters.items[i];
            const outcome = try self.evaluate(w, lines, now) orelse {
                i += 1;
                continue;
            };
            try self.respondScreen(w.fd, if (outcome.satisfied) .ok else .timeout, withWait(w.render, outcome));
            self.dropWaiter(i);
            self.last_activity_ms = now;
        }
    }

    /// When `--settle ms` holds: `ms` after the last output, where that output
    /// must come after the last send. A program that prints nothing in reply
    /// to the keys gets `settle_grace_ms` to do so. Null while nothing has
    /// been printed or sent at all.
    fn settledAt(self: *const Session, ms: i64) ?i64 {
        if (self.last_send_ms == 0 or self.output_since_send)
            return if (self.output_seen) self.last_output_ms + ms else null;
        return self.last_send_ms + @max(ms, settle_grace_ms);
    }

    /// When a wait for exit may give up because the program looks like it is
    /// waiting for input: it has printed something (after the last send, if
    /// there was one) and then nothing for `awaiting_input_ms`.
    fn awaitingInputAt(self: *const Session, w: Waiter) ?i64 {
        if (!w.exitOnly() or self.child_exited or !self.output_seen) return null;
        if (self.last_send_ms != 0 and !self.output_since_send) return null;
        if (self.awaiting_reported_send_ms) |at| {
            if (at == self.last_send_ms) return null;
        }
        return @max(@max(self.last_change_ms, w.started) + awaiting_input_ms, self.awaiting_recheck_ms);
    }

    /// How the program has set the terminal up to read keys itself; null in
    /// ordinary line mode with echo.
    fn inputMode(self: *const Session) ?[]const u8 {
        const tio = posix.tcgetattr(self.pty.slave) catch return null;
        if (!tio.lflag.ICANON) return "the terminal is in raw mode";
        if (!tio.lflag.ECHO) return "echo is off";
        return null;
    }

    fn evaluate(self: *Session, w: Waiter, lines: []const []const u8, now: i64) !?WaitOutcome {
        var out: WaitOutcome = .{ .condition = waitCondition(w), .satisfied = true, .reason = "", .elapsed_ms = now - w.started };
        if (w.text) |t| {
            if (containsText(lines, t)) {
                out.reason = "text";
                return out;
            }
        }
        if (w.regex) |re| {
            for (lines) |l| {
                if (try re.search(self.gpa, std.mem.trimRight(u8, l, " "))) {
                    out.reason = "regex";
                    return out;
                }
            }
        }
        if (w.gone) |t| {
            if (!containsText(lines, t)) {
                out.reason = "gone";
                return out;
            }
        }
        if (w.exit and self.child_exited) {
            out.reason = "exit";
            return out;
        }
        if (w.idle_ms) |idle| {
            if (now - @max(self.last_change_ms, w.started) >= idle) {
                out.reason = "idle";
                return out;
            }
        }
        if (w.settle_ms) |ms| {
            if (self.settledAt(ms)) |at| {
                if (now >= at) {
                    out.reason = "settle";
                    return out;
                }
            }
        }
        out.satisfied = false;
        if (self.awaitingInputAt(w)) |at| {
            if (now >= at) {
                if (self.inputMode() != null) {
                    self.awaiting_reported_send_ms = self.last_send_ms;
                    out.reason = "awaiting-input";
                    return out;
                }
                self.awaiting_recheck_ms = now + 250;
            }
        }
        // The screen can no longer change once the program is gone and its
        // output has been drained.
        if (w.screenOnly() and self.child_exited) {
            out.reason = "exited";
            return out;
        }
        if (now >= w.deadline) {
            out.reason = "timeout";
            return out;
        }
        return null;
    }

    /// The screen as logical lines: rows joined where the text wrapped at
    /// the right edge, with trailing blanks kept.
    fn logicalLines(self: *Session, arena: Allocator) ![]const []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        var cur: std.ArrayList(u8) = .empty;
        for (0..self.term.rows) |r| {
            try self.term.appendRowTextPadded(r, &cur, arena);
            if (!self.term.rowWrapped(r) or r + 1 == self.term.rows) {
                try lines.append(arena, cur.items);
                cur = .empty;
            }
        }
        return lines.items;
    }

    // ------------------------------------------------------------------
    // Rendering

    const RenderOptions = struct {
        json: bool = false,
        diff: bool = false,
        scrollback: usize = 0,
        /// Report styled runs per row.
        styles: bool = false,
        /// Text output only: leave out empty rows at the bottom.
        trim: bool = false,
        /// Whose diff marker to compare against and update.
        client: []const u8 = "",
        wait: ?WaitOutcome = null,
    };

    const Run = struct {
        start: usize,
        end: usize,
        text: []const u8,
        style: vt.Style,
    };

    fn respondScreen(self: *Session, fd: posix.fd_t, status: Status, opts: RenderOptions) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try self.renderScreen(&out.writer, opts);
        respond(fd, status, out.written());
    }

    fn renderScreen(self: *Session, w: *std.Io.Writer, opts: RenderOptions) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const t = &self.term;
        const lines = try arena.alloc([]u8, t.rows);
        const runs = try arena.alloc([]Run, t.rows);
        // Text plus styles: a row whose styles change (a menu selection
        // moving) counts as changed for --diff.
        const signatures = try arena.alloc([]u8, t.rows);
        for (0..t.rows) |r| {
            var buf: std.ArrayList(u8) = .empty;
            try t.appendRowText(r, &buf, arena);
            lines[r] = buf.items;

            var raw: std.ArrayList(vt.StyleRun) = .empty;
            try t.appendStyleRuns(r, &raw, arena);
            runs[r] = try arena.alloc(Run, raw.items.len);
            for (raw.items, runs[r]) |sr, *dst| {
                var text: std.ArrayList(u8) = .empty;
                try t.appendRangeText(r, sr.start, sr.end, &text, arena);
                dst.* = .{ .start = sr.start, .end = sr.end, .text = text.items, .style = sr.style };
            }

            var sig: std.Io.Writer.Allocating = .init(arena);
            try sig.writer.writeAll(lines[r]);
            try sig.writer.writeByte(0);
            try writeRunsText(&sig.writer, runs[r]);
            signatures[r] = sig.written();
        }

        var changed: std.ArrayList(usize) = .empty;
        const marker = try self.markerFor(opts.client);
        const same_shape = marker.rows.items.len == lines.len;
        for (signatures, 0..) |sig, r| {
            if (!same_shape or !std.mem.eql(u8, marker.rows.items[r], sig)) try changed.append(arena, r);
        }
        for (marker.rows.items) |l| self.gpa.free(l);
        marker.rows.clearRetainingCapacity();
        for (signatures) |sig| try marker.rows.append(self.gpa, try self.gpa.dupe(u8, sig));

        const sb = &t.scrollback;
        const sb_count = @min(opts.scrollback, sb.len);
        const sb_first = sb.len - sb_count;

        if (opts.json) {
            var jw: std.json.Stringify = .{ .writer = w };
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(self.cfg.name);
            try jw.objectField("cols");
            try jw.write(t.cols);
            try jw.objectField("rows");
            try jw.write(t.rows);
            try jw.objectField("cursor");
            try jw.beginObject();
            try jw.objectField("row");
            try jw.write(t.cursor.row);
            try jw.objectField("col");
            try jw.write(t.cursor.col);
            try jw.objectField("visible");
            try jw.write(t.modes.cursor_visible);
            try jw.endObject();
            try jw.objectField("alt_screen");
            try jw.write(t.alt_active);
            try jw.objectField("title");
            try jw.write(t.title.items);
            try jw.objectField("app_cursor_keys");
            try jw.write(t.modes.app_cursor);
            try jw.objectField("bracketed_paste");
            try jw.write(t.modes.bracketed_paste);
            try self.writeExit(&jw);
            if (opts.diff) {
                try jw.objectField("changed");
                try jw.beginArray();
                for (changed.items) |r| {
                    try jw.beginObject();
                    try jw.objectField("row");
                    try jw.write(r);
                    try jw.objectField("text");
                    try jw.write(lines[r]);
                    if (opts.styles) {
                        try jw.objectField("styles");
                        try writeRunsJson(&jw, runs[r]);
                    }
                    try jw.endObject();
                }
                try jw.endArray();
            } else {
                try jw.objectField("lines");
                try jw.write(lines);
                if (opts.styles) {
                    try jw.objectField("styles");
                    try jw.beginArray();
                    for (runs) |row_runs| try writeRunsJson(&jw, row_runs);
                    try jw.endArray();
                }
            }
            if (opts.scrollback > 0) {
                try jw.objectField("scrollback");
                try jw.beginArray();
                for (sb_first..sb.len) |i| try jw.write(sb.get(i));
                try jw.endArray();
            }
            if (opts.wait) |o| {
                try jw.objectField("wait");
                try jw.write(o);
            }
            try jw.endObject();
            try w.writeByte('\n');
            return;
        }

        if (opts.scrollback > 0) {
            for (sb_first..sb.len) |i| try w.print("{s}\n", .{sb.get(i)});
            try w.print("[headterm] end of scrollback ({d} lines)\n", .{sb_count});
        }
        var shown_rows = lines.len;
        if (opts.trim) {
            while (shown_rows > 0 and lines[shown_rows - 1].len == 0 and
                (!opts.styles or runs[shown_rows - 1].len == 0)) shown_rows -= 1;
        }
        if (opts.diff) {
            for (changed.items) |r| try w.print("{d}|{s}\n", .{ r, lines[r] });
        } else {
            for (lines[0..shown_rows]) |l| try w.print("{s}\n", .{l});
        }
        if (opts.styles) {
            try w.writeAll("[headterm] styles (row: [start-end attributes \"text\"], 0-based columns, end exclusive)\n");
            const style_rows: []const usize = if (opts.diff) changed.items else blk: {
                const all = try arena.alloc(usize, shown_rows);
                for (all, 0..) |*x, i| x.* = i;
                break :blk all;
            };
            for (style_rows) |r| {
                if (runs[r].len == 0) continue;
                try w.print("row {d}: ", .{r});
                try writeRunsText(w, runs[r]);
                try w.writeByte('\n');
            }
        }
        if (!opts.styles) {
            try writeHighlights(w, runs[0..shown_rows], dominantBackground(t));
            const cell_rows = try arena.alloc([]const vt.Cell, shown_rows);
            for (cell_rows, 0..) |*cells, r| cells.* = t.rowCells(r);
            try stylenote.write(w, arena, cell_rows, !t.modes.cursor_visible);
        }
        if (opts.wait) |o| {
            if (std.mem.eql(u8, o.reason, "awaiting-input")) {
                try w.print("[headterm] still running: the screen has not changed for {d} s and {s}, so it is probably waiting for input (wait again if it is working)\n", .{ awaiting_input_ms / 1000, self.inputMode() orelse "the terminal is in raw mode" });
            }
        }
        try w.print("[headterm] {s} {d}x{d} cursor={d},{d}", .{ self.cfg.name, t.cols, t.rows, t.cursor.row, t.cursor.col });
        if (t.alt_active) try w.writeAll(" alt");
        if (t.title.items.len > 0) try w.print(" title=\"{s}\"", .{t.title.items});
        if (opts.diff) try w.print(" changed={d}", .{changed.items.len});
        if (self.exit_code) |c| {
            try w.print(" exited={d}", .{c});
        } else if (self.exit_signal) |sig| {
            try w.print(" killed-by-signal={d}", .{sig});
        } else if (self.child_exited) {
            try w.writeAll(" exited");
        } else {
            try w.writeAll(" running");
        }
        if (opts.wait) |o| {
            if (o.satisfied) {
                try w.print(" wait=ok({s})", .{o.reason});
            } else {
                try w.print(" wait=failed({s})", .{o.reason});
            }
            try w.print(" waited={d}ms", .{o.elapsed_ms});
        }
        try w.writeByte('\n');
    }

    fn writeExit(self: *Session, jw: *std.json.Stringify) !void {
        try jw.objectField("pid");
        try jw.write(self.pty.pid);
        try jw.objectField("exited");
        try jw.write(self.child_exited);
        try jw.objectField("exit_code");
        try jw.write(self.exit_code);
        try jw.objectField("exit_signal");
        try jw.write(self.exit_signal);
    }

    /// The diff marker of client `id`, created on first use.
    fn markerFor(self: *Session, id: []const u8) !*Marker {
        const now = nowMs();
        if (self.markers.getPtr(id)) |m| {
            m.used_ms = now;
            return m;
        }
        if (self.markers.count() >= max_markers) {
            var oldest: ?[]const u8 = null;
            var oldest_ms: i64 = std.math.maxInt(i64);
            var it = self.markers.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.used_ms < oldest_ms) {
                    oldest_ms = e.value_ptr.used_ms;
                    oldest = e.key_ptr.*;
                }
            }
            if (self.markers.fetchRemove(oldest.?)) |kv| {
                var m = kv.value;
                m.deinit(self.gpa);
                self.gpa.free(kv.key);
            }
        }
        const key = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(key);
        try self.markers.put(self.gpa, key, .{ .used_ms = now });
        return self.markers.getPtr(key).?;
    }

    fn writeInfo(self: *Session, w: *std.Io.Writer) !void {
        const t = &self.term;
        var jw: std.json.Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.cfg.name);
        try jw.objectField("command");
        try jw.write(self.cfg.argv);
        try jw.objectField("cols");
        try jw.write(t.cols);
        try jw.objectField("rows");
        try jw.write(t.rows);
        try jw.objectField("title");
        try jw.write(t.title.items);
        try jw.objectField("alt_screen");
        try jw.write(t.alt_active);
        try self.writeExit(&jw);
        try jw.objectField("server_pid");
        try jw.write(std.c.getpid());
        try jw.objectField("started_at_ms");
        try jw.write(self.started_ms);
        try jw.objectField("ttl_s");
        try jw.write(self.cfg.ttl_s);
        try jw.endObject();
    }
};

const color_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

/// "red", "bright-red", "208" or "#rrggbb"; null for the default color.
pub fn colorName(buf: []u8, c: vt.Color) ?[]const u8 {
    return switch (c) {
        .default => null,
        .palette => |p| if (p < 8)
            color_names[p]
        else if (p < 16)
            std.fmt.bufPrint(buf, "bright-{s}", .{color_names[p - 8]}) catch unreachable
        else
            std.fmt.bufPrint(buf, "{d}", .{p}) catch unreachable,
        .rgb => |rgb| std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable,
    };
}

/// Attribute names in a fixed order; colors are separate.
pub fn styleAttrs(st: vt.Style, out: *[9][]const u8) [][]const u8 {
    var n: usize = 0;
    const flags = [_]struct { bool, []const u8 }{
        .{ st.bold, "bold" },
        .{ st.faint, "dim" },
        .{ st.italic, "italic" },
        .{ st.underline != 0, "underline" },
        .{ st.blink, "blink" },
        .{ st.inverse, "inverse" },
        .{ st.invisible, "hidden" },
        .{ st.strikethrough, "strike" },
        .{ st.overline, "overline" },
    };
    for (flags) |f| {
        if (f[0]) {
            out[n] = f[1];
            n += 1;
        }
    }
    return out[0..n];
}

/// `[2-10 inverse "Save"] [12-17 bold fg=red "Error"]`
fn writeRunsText(w: *std.Io.Writer, runs: []const Session.Run) !void {
    for (runs, 0..) |r, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("[{d}-{d}", .{ r.start, r.end });
        var attr_buf: [9][]const u8 = undefined;
        for (styleAttrs(r.style, &attr_buf)) |a| try w.print(" {s}", .{a});
        var buf: [16]u8 = undefined;
        if (colorName(&buf, r.style.fg)) |c| try w.print(" fg={s}", .{c});
        if (colorName(&buf, r.style.bg)) |c| try w.print(" bg={s}", .{c});
        if (r.text.len > 0) {
            try w.writeByte(' ');
            try std.json.Stringify.encodeJsonString(r.text, .{}, w);
        }
        try w.writeByte(']');
    }
}

/// The background a cell visibly has: its background color, or with
/// inverse its foreground color.
const Background = struct {
    inverse: bool,
    color: vt.Color,

    fn of(st: vt.Style) Background {
        return if (st.inverse) .{ .inverse = true, .color = st.fg } else .{ .inverse = false, .color = st.bg };
    }

    fn eql(a: Background, b: Background) bool {
        return a.inverse == b.inverse and std.meta.eql(a.color, b.color);
    }
};

/// The most common visible background on screen. Programs that paint the
/// whole screen in a color (curses with start_color) make that the normal
/// background, not a highlight.
fn dominantBackground(t: *const vt.Terminal) Background {
    var seen: [16]Background = undefined;
    var counts: [16]usize = undefined;
    var n: usize = 0;
    for (0..t.rows) |r| {
        for (t.rowCells(r)) |cell| {
            const k = Background.of(cell.style);
            for (seen[0..n], 0..) |existing, i| {
                if (existing.eql(k)) {
                    counts[i] += 1;
                    break;
                }
            } else if (n < seen.len) {
                seen[n] = k;
                counts[n] = 1;
                n += 1;
            }
        }
    }
    var best: usize = 0;
    for (counts[0..n], 0..) |c, i| {
        if (c > counts[best]) best = i;
    }
    return if (n == 0) .{ .inverse = false, .color = .default } else seen[best];
}

/// One line naming the rows with highlighted text (a background that differs
/// from the screen's usual one, e.g. inverse), such as the selected menu
/// item, for callers that did not ask for --styles.
fn writeHighlights(w: *std.Io.Writer, rows: []const []const Session.Run, normal: Background) !void {
    const max_shown = 3;
    var shown: usize = 0;
    var more: usize = 0;
    for (rows, 0..) |runs, r| {
        for (runs) |run| {
            const text = std.mem.trim(u8, run.text, " ");
            if (text.len == 0) continue;
            if (Background.of(run.style).eql(normal)) continue;
            if (shown == max_shown) {
                more += 1;
                break;
            }
            try w.writeAll(if (shown == 0) "[headterm] highlighted: " else "; ");
            try w.print("row {d} ", .{r});
            try std.json.Stringify.encodeJsonString(text[0..@min(text.len, 60)], .{}, w);
            shown += 1;
            break; // one run per row
        }
    }
    if (shown == 0) return;
    if (more > 0) try w.print(" (+{d} more rows)", .{more});
    try w.writeByte('\n');
}

fn writeRunsJson(jw: *std.json.Stringify, runs: []const Session.Run) !void {
    try jw.beginArray();
    for (runs) |r| {
        try jw.beginObject();
        try jw.objectField("start");
        try jw.write(r.start);
        try jw.objectField("end");
        try jw.write(r.end);
        try jw.objectField("text");
        try jw.write(r.text);
        try jw.objectField("attrs");
        var attr_buf: [9][]const u8 = undefined;
        try jw.write(styleAttrs(r.style, &attr_buf));
        var buf: [16]u8 = undefined;
        try jw.objectField("fg");
        try jw.write(colorName(&buf, r.style.fg));
        try jw.objectField("bg");
        try jw.write(colorName(&buf, r.style.bg));
        try jw.endObject();
    }
    try jw.endArray();
}

fn containsText(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) return true;
    }
    return false;
}

fn validClientId(id: []const u8) bool {
    return id.len > 0 and id.len <= max_client_id;
}

fn respond(fd: posix.fd_t, status: Status, body: []const u8) void {
    writeAll(fd, @tagName(status)) catch return;
    writeAll(fd, "\n") catch return;
    writeAll(fd, body) catch return;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
