//! paymcp-sim: a stand-in for the billing provider's API, for trying paymcp.
const std = @import("std");
const sim = @import("sim.zig");
const model = @import("model.zig");

const usage =
    \\usage: paymcp-sim PORT KEY [--day YYYY-MM-DD] [--no-meters]
    \\
    \\A made-up software business (twelve customers, their subscriptions,
    \\prices and invoices) behind a stand-in for the billing provider's API on
    \\127.0.0.1:PORT (0: any free port). It answers GETs sent with KEY as the
    \\bearer key and refuses everything else. The records are placed around
    \\--day (default: today, UTC). With --no-meters, KEY may not read the
    \\meters, as a key without that permission. examples/who.csv is the
    \\business's own file that goes with it.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return bad(io);
    const port = std.fmt.parseInt(u16, args[1], 10) catch return bad(io);
    var now: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    var meters = true;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--day") and i + 1 < args.len) {
            i += 1;
            now = model.dayStart(args[i]) orelse return bad(io);
        } else if (std.mem.eql(u8, args[i], "--no-meters")) {
            meters = false;
        } else return bad(io);
    }
    try sim.run(init.gpa, io, .{ .port = port, .key = args[2], .now = now, .meters = meters });
    return 0;
}

fn bad(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 2;
}

test {
    _ = @import("sim.zig");
}
