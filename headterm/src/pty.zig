//! A pseudo-terminal with a program running on it. pty_posix.zig holds the
//! macOS and Linux side (a POSIX pty), pty_windows.zig the Windows side (a
//! pseudoconsole); both give a `Pty` with the same methods.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig"),
    else => @import("pty_posix.zig"),
};

pub const Pty = impl.Pty;
pub const SpawnError = impl.SpawnError;

/// Opens a terminal of the given size and starts `argv` on it. If the
/// program cannot be started, `err_msg` receives a human-readable reason.
pub const spawn = impl.spawn;

/// Whether the terminal itself prints something (that shows nothing) when
/// it is opened, before the program has printed anything.
pub const prints_setup: bool = impl.prints_setup;

/// What `resize` and `kill` do to the program, for the help texts.
pub const help = impl.help;

/// How the program ended.
pub const Exit = struct {
    code: ?u32 = null,
    /// The signal that killed it (macOS and Linux only).
    signal: ?u8 = null,
};

test {
    _ = impl;
}
