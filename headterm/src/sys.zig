//! What headterm asks of the operating system: descriptors, files, sockets,
//! waiting, time and the environment. sys_posix.zig holds the macOS and
//! Linux side, sys_windows.zig the Windows side; everything else uses only
//! the names listed here.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("sys_windows.zig"),
    else => @import("sys_posix.zig"),
};

pub const fd_t = impl.fd_t;
pub const pid_t = impl.pid_t;

pub const initProcess = impl.initProcess;
pub const exit = impl.exit;
pub const getpid = impl.getpid;
pub const getenvBuf = impl.getenvBuf;
pub const setEnv = impl.setEnv;
pub const nanoTimestamp = impl.nanoTimestamp;
pub const milliTimestamp = impl.milliTimestamp;

pub const stdin = impl.stdin;
pub const stdout = impl.stdout;
pub const stderr = impl.stderr;
pub const ReadError = impl.ReadError;
pub const WriteError = impl.WriteError;
pub const read = impl.read;
pub const write = impl.write;
pub const writeAll = impl.writeAll;
pub const close = impl.close;

pub const OpenError = impl.OpenError;
pub const WriteMode = impl.WriteMode;
pub const openForWrite = impl.openForWrite;
pub const unlink = impl.unlink;

pub const session_dir_hint = impl.session_dir_hint;
pub const sessionDir = impl.sessionDir;
pub const ensureSessionDir = impl.ensureSessionDir;

pub const unixAddress = impl.unixAddress;
pub const connectUnix = impl.connectUnix;
pub const listenUnix = impl.listenUnix;
pub const accept = impl.accept;
pub const setReceiveTimeout = impl.setReceiveTimeout;

pub const PollError = impl.PollError;
pub const PollItem = impl.PollItem;
pub const pollItem = impl.pollItem;
pub const poll = impl.poll;
pub const readable = impl.readable;
pub const writable = impl.writable;
/// How many descriptors one `poll` takes; null if there is no limit.
pub const max_poll_items: ?usize = impl.max_poll_items;

test {
    _ = impl;
}
