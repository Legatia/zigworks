//! sd_notify without libsystemd: one datagram to the socket in $NOTIFY_SOCKET.
const std = @import("std");
const linux = std.os.linux;

/// Sends `message` ("READY=1", "WATCHDOG=1", "STOPPING=1") to systemd.
/// `socket_path` is the value of $NOTIFY_SOCKET: null when the program was
/// not started by systemd, and then nothing is sent.
pub fn notify(socket_path: ?[]const u8, message: []const u8) !void {
    const path = socket_path orelse return;
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len < 2 or path.len >= addr.path.len or (path[0] != '/' and path[0] != '@'))
        return error.BadNotifySocket;
    @memcpy(addr.path[0..path.len], path);
    if (path[0] == '@') addr.path[0] = 0; // an abstract socket
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NotifyFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len);
    if (linux.errno(linux.sendto(fd, message.ptr, message.len, 0, @ptrCast(&addr), len)) != .SUCCESS)
        return error.NotifyFailed;
}
