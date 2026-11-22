//! cantap: a listen-only CAN tap. Prints frames like candump, tells systemd
//! it is alive, and exits once the bus has been silent for `silent_ms` (the
//! car is asleep), so a power board can cut the supply.
//! Usage: cantap [--fd] IFACE [ID ...]
//!   --fd: CAN FD frames too; IDs: 11-bit ids in hex, only those frames.
const std = @import("std");
const Io = std.Io;
const can = @import("can.zig");
const notify = @import("notify.zig").notify;

const silent_ms = 10_000;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const fd_frames = args.len > 1 and std.mem.eql(u8, args[1], "--fd");
    const skip: usize = if (fd_frames) 2 else 1;
    const rest = args[skip..];
    if (rest.len < 1 or rest.len > 1 + 16) {
        try Io.File.stderr().writeStreamingAll(io, "usage: cantap [--fd] IFACE [ID ...]\n");
        return 2;
    }
    var filters: [16]can.Filter = undefined;
    const wanted = filters[0 .. rest.len - 1];
    for (rest[1..], wanted) |a, *f| f.* = .exact(try std.fmt.parseInt(u11, a, 16));
    const tap = try can.Tap.open(rest[0], .{ .filters = wanted, .fd_frames = fd_frames });
    defer tap.close();

    const sock = init.environ_map.get("NOTIFY_SOCKET");
    try notify(sock, "READY=1");
    var last = Io.Clock.awake.now(io);
    var line: [256]u8 = undefined;
    var frame: can.Frame = undefined;
    while (try tap.read(&frame, silent_ms)) |kind| {
        const now = Io.Clock.awake.now(io);
        if (last.durationTo(now).toMilliseconds() >= 1000) {
            try notify(sock, "WATCHDOG=1");
            last = now;
        }
        const text = switch (kind) {
            .err => try std.fmt.bufPrint(&line, "error {t}\n", .{can.trouble(&frame).?}),
            .classic, .fd => try std.fmt.bufPrint(&line, "{X:0>3} [{d}] {X}\n", .{ frame.ident(), frame.len, frame.payload() }),
        };
        try Io.File.stdout().writeStreamingAll(io, text);
    }
    try notify(sock, "STOPPING=1");
    return 0;
}
