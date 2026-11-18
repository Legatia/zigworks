//! The macOS and Linux side of daemon.zig: the session server is forked
//! out of the calling process.
//!
//! After `fork` only the calling thread exists and only plain system calls
//! are safe, which is why the server and everything under it use sys.zig
//! and not `std.Io`.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const sys = @import("sys_posix.zig");
const server = @import("server.zig");

pub const LaunchError = sys.ForkError || sys.PipeError;

/// Forks the session server and returns the reading end of the pipe on
/// which it reports that it is ready.
pub fn launch(gpa: Allocator, cfg: server.Config) LaunchError!sys.fd_t {
    const ready = try sys.pipe2(.{ .cloexec = true });
    const pid = try sys.fork();
    if (pid == 0) {
        sys.close(ready[0]);
        // Double fork: the server must not be a session leader or a child
        // of the CLI process.
        sys.setsid();
        const pid2 = sys.fork() catch sys.exit(1);
        if (pid2 != 0) sys.exit(0);
        detach(ready[1]);
        server.serve(gpa, cfg, ready[1]);
    }
    sys.close(ready[1]);
    _ = sys.waitpid(pid, 0);
    return ready[0];
}

/// Detaches from the caller's stdio so `$(headterm start ...)` returns,
/// and drops any other inherited descriptors but `keep`.
fn detach(keep: sys.fd_t) void {
    if (sys.open("/dev/null", .{ .ACCMODE = .RDWR }, 0)) |null_fd| {
        for (0..3) |fd| sys.dup2(null_fd, @intCast(fd)) catch {};
        if (null_fd > 2) sys.close(null_fd);
    } else |_| {}
    var fd: sys.fd_t = 3;
    while (fd < 1024) : (fd += 1) {
        if (fd != keep) sys.close(fd);
    }

    // Clients that hang up and a caller's terminal that closes must not
    // end the server.
    const ignore: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.PIPE, &ignore, null);
    posix.sigaction(.HUP, &ignore, null);
}
