//! Session directory layout and the client side of the socket protocol.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const server = @import("server.zig");

pub const max_name_len = 64;

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len or name[0] == '.') return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

/// `$XDG_RUNTIME_DIR/headterm`, else `$TMPDIR/headterm-$UID` (TMPDIR
/// defaulting to /tmp).
pub fn sessionDir(buf: []u8) ![]const u8 {
    if (posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        if (xdg.len > 0) return std.fmt.bufPrint(buf, "{s}/headterm", .{std.mem.trimRight(u8, xdg, "/")});
    }
    const tmp = posix.getenv("TMPDIR") orelse "/tmp";
    const base = if (tmp.len == 0) "/tmp" else std.mem.trimRight(u8, tmp, "/");
    return std.fmt.bufPrint(buf, "{s}/headterm-{d}", .{ base, posix.getuid() });
}

pub const DirError = error{ NotOwned, NotADirectory } || posix.MakeDirError || posix.OpenError || posix.FStatError || posix.FChmodError;

/// Creates the session directory with mode 0700, refusing one owned by
/// another user.
pub fn ensureSessionDir(dir: []const u8) DirError!void {
    posix.mkdir(dir, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    const fd = try posix.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer posix.close(fd);
    const st = try posix.fstat(fd);
    if (st.uid != posix.getuid()) return error.NotOwned;
    if (st.mode & 0o777 != 0o700) try posix.fchmod(fd, 0o700);
}

pub fn socketPath(buf: []u8, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.sock", .{ dir, name });
}

pub const Status = enum { ok, timeout, @"error" };

pub const Response = struct {
    status: Status,
    body: []u8,
};

pub const RequestError = error{ NoSuchSession, StaleSession, BadResponse } || Allocator.Error || posix.WriteError || posix.ReadError;

/// Sends one request and reads the whole response. The caller owns `body`.
pub fn request(gpa: Allocator, socket_path: []const u8, args: []const []const u8) RequestError!Response {
    const stream = try connect(socket_path);
    defer stream.close();
    try sendRequest(gpa, stream.handle, args);
    return readResponse(gpa, stream.handle);
}

pub fn connect(socket_path: []const u8) RequestError!std.net.Stream {
    return std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => error.StaleSession,
        else => error.NoSuchSession,
    };
}

pub fn sendRequest(gpa: Allocator, fd: posix.fd_t, args: []const []const u8) RequestError!void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    for (args) |a| {
        try payload.appendSlice(gpa, a);
        try payload.append(gpa, 0);
    }
    var header: [32]u8 = undefined;
    try writeAll(fd, std.fmt.bufPrint(&header, "{d}\n", .{payload.items.len}) catch unreachable);
    try writeAll(fd, payload.items);
}

/// Reads until the server closes the connection.
pub fn readResponse(gpa: Allocator, fd: posix.fd_t) RequestError!Response {
    var resp: std.ArrayList(u8) = .empty;
    errdefer resp.deinit(gpa);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => |e| return e,
        };
        if (n == 0) break;
        try resp.appendSlice(gpa, buf[0..n]);
    }

    const nl = std.mem.indexOfScalar(u8, resp.items, '\n') orelse return error.BadResponse;
    const status = std.meta.stringToEnum(Status, resp.items[0..nl]) orelse return error.BadResponse;
    const body_len = resp.items.len - nl - 1;
    std.mem.copyForwards(u8, resp.items[0..body_len], resp.items[nl + 1 ..]);
    resp.shrinkRetainingCapacity(body_len);
    return .{ .status = status, .body = try resp.toOwnedSlice(gpa) };
}

pub const StartOptions = struct {
    cols: u16 = 120,
    rows: u16 = 40,
    cwd: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    ttl_s: ?u32 = null,
};

/// Starts session `name` running `argv`. Returns the program's pid; on
/// failure `msg` holds a human-readable reason.
pub fn startSession(gpa: Allocator, name: []const u8, argv: []const []const u8, opts: StartOptions, msg: *[256]u8) error{StartFailed}!posix.pid_t {
    @memset(msg, 0);
    if (!validName(name)) return failMsg(msg, "invalid session name '{s}' (use letters, digits, '.', '_', '-')", .{name});
    if (argv.len == 0) return failMsg(msg, "missing command", .{});
    if (opts.cols < 2 or opts.rows < 1 or opts.cols > 1000 or opts.rows > 1000) return failMsg(msg, "cols must be 2..1000 and rows 1..1000", .{});

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = sessionDir(&dir_buf) catch return failMsg(msg, "session directory path too long", .{});
    ensureSessionDir(dir) catch |err| return failMsg(msg, "cannot use session directory {s}: {s}", .{ dir, @errorName(err) });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = socketPath(&path_buf, dir, name) catch return failMsg(msg, "socket path too long", .{});

    // A socket nobody listens on is left over from a crashed server.
    if (request(gpa, sock, &.{"info"})) |resp| {
        gpa.free(resp.body);
        return failMsg(msg, "session '{s}' already exists", .{name});
    } else |err| switch (err) {
        error.StaleSession => posix.unlink(sock) catch {},
        else => {},
    }
    _ = std.net.Address.initUnix(sock) catch return failMsg(msg, "socket path too long: {s} (set XDG_RUNTIME_DIR or TMPDIR to a shorter directory)", .{sock});

    var server_msg: [256]u8 = .{0} ** 256;
    return server.start(gpa, .{
        .name = name,
        .socket_path = sock,
        .argv = argv,
        .cwd = opts.cwd,
        .cols = opts.cols,
        .rows = opts.rows,
        .log_path = opts.log_path,
        .ttl_s = opts.ttl_s,
    }, &server_msg) catch |err| switch (err) {
        error.StartFailed => failMsg(msg, "{s}", .{std.mem.sliceTo(&server_msg, 0)}),
        else => failMsg(msg, "{s}", .{@errorName(err)}),
    };
}

fn failMsg(msg: *[256]u8, comptime fmt: []const u8, args: anytype) error{StartFailed} {
    _ = std.fmt.bufPrintZ(msg, fmt, args) catch {
        @memcpy(msg[msg.len - 4 ..], "...\x00");
    };
    return error.StartFailed;
}

pub const CallError = error{InvalidName} || RequestError;

/// Sends `args` to the server of session `name`.
pub fn call(gpa: Allocator, name: []const u8, args: []const []const u8) CallError!Response {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    return request(gpa, try sessionSocket(&path_buf, name), args);
}

/// Socket path of session `name`.
pub fn sessionSocket(buf: *[std.fs.max_path_bytes]u8, name: []const u8) CallError![]const u8 {
    if (!validName(name)) return error.InvalidName;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = sessionDir(&dir_buf) catch return error.NoSuchSession;
    return socketPath(buf, dir, name) catch error.NoSuchSession;
}

/// One-line explanation of a `call` failure.
pub fn describeError(buf: []u8, err: CallError, name: []const u8) []const u8 {
    return switch (err) {
        error.InvalidName => std.fmt.bufPrint(buf, "invalid session name '{s}' (use letters, digits, '.', '_', '-')", .{name}),
        error.NoSuchSession, error.StaleSession => std.fmt.bufPrint(buf, "no session named '{s}'", .{name}),
        error.BadResponse => std.fmt.bufPrint(buf, "bad response from session '{s}'", .{name}),
        else => std.fmt.bufPrint(buf, "session '{s}': {s}", .{ name, @errorName(err) }),
    } catch "error";
}

pub const SessionInfo = struct {
    name: []const u8,
    command: []const []const u8,
    cols: usize,
    rows: usize,
    pid: u32,
    exited: bool,
    exit_code: ?u8,
    exit_signal: ?u8,
};

pub const SessionList = struct {
    infos: []SessionInfo,
    /// The server's info JSON for each session, same order as `infos`.
    raw: []const []const u8,
};

/// Queries every live session, sorted by name, and removes sockets left by
/// crashed servers. Everything is allocated in `arena`.
pub fn listSessions(arena: Allocator) !SessionList {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try sessionDir(&dir_buf);

    var names: std.ArrayList([]const u8) = .empty;
    if (std.fs.openDirAbsolute(dir, .{ .iterate = true })) |d_const| {
        var d = d_const;
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - 5]));
        }
    } else |_| {}
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var raw: std.ArrayList([]const u8) = .empty;
    var infos: std.ArrayList(SessionInfo) = .empty;
    for (names.items) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sock = try socketPath(&path_buf, dir, name);
        const resp = request(arena, sock, &.{"info"}) catch |err| {
            if (err == error.StaleSession) posix.unlink(sock) catch {};
            continue;
        };
        if (resp.status != .ok) continue;
        const body = std.mem.trimRight(u8, resp.body, "\n");
        const parsed = std.json.parseFromSliceLeaky(SessionInfo, arena, body, .{ .ignore_unknown_fields = true }) catch continue;
        try raw.append(arena, body);
        try infos.append(arena, parsed);
    }
    return .{ .infos = infos.items, .raw = raw.items };
}

/// One line per session: name, pid, size, status, command.
pub fn writeSessionTable(w: *std.Io.Writer, infos: []const SessionInfo) !void {
    for (infos) |info| {
        var status_buf: [32]u8 = undefined;
        const status = if (!info.exited)
            "running"
        else if (info.exit_code) |c|
            try std.fmt.bufPrint(&status_buf, "exited={d}", .{c})
        else if (info.exit_signal) |s|
            try std.fmt.bufPrint(&status_buf, "signal={d}", .{s})
        else
            "exited";
        var size_buf: [16]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ info.cols, info.rows });
        try w.print("{s:<16} {d:<8} {s:<9} {s:<10}", .{ info.name, info.pid, size, status });
        for (info.command) |c| try w.print(" {s}", .{c});
        try w.writeByte('\n');
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) posix.WriteError!void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
}

test validName {
    try std.testing.expect(validName("vim-1"));
    try std.testing.expect(validName("a.b_c"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a b"));
}
