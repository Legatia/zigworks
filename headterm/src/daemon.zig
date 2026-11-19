//! Starting the session server as a background process of its own.
//! daemon_posix.zig forks it out of the calling process; daemon_windows.zig
//! starts this program a second time, as Windows has no fork.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("daemon_windows.zig"),
    else => @import("daemon_posix.zig"),
};

pub const LaunchError = impl.LaunchError;

/// Starts a session server for a `server.Config`, detached from the
/// caller. Returns the descriptor on which it reports "ok <pid>" or
/// "err <reason>" once the program runs or could not be started.
pub const launch = impl.launch;

/// The command-line word that makes this program a session server, where
/// it is started that way; null where it is forked.
pub const server_command: ?[]const u8 = if (@hasDecl(impl, "server_command")) impl.server_command else null;

/// What `main` runs for `server_command`.
pub const serverMain = impl.serverMain;

test {
    _ = impl;
}
