//! paymcp-sim: a stand-in for the billing provider's API, for trying paymcp.
const std = @import("std");
const sim = @import("sim.zig");
const model = @import("model.zig");

const usage =
    \\usage: paymcp-sim PORT KEY [--day YYYY-MM-DD] [--no-meters] [--disputes | --no-disputes] [--write-key KEY2] [--with-stdin]
    \\
    \\A made-up software business (twelve customers, their subscriptions,
    \\prices and invoices) behind a stand-in for the billing provider's API on
    \\127.0.0.1:PORT (0: any free port). It answers GETs sent with KEY as the
    \\bearer key and refuses everything else. The records are placed around
    \\--day (default: today, UTC). With --no-meters, KEY may not read the
    \\meters, as a key without that permission. With --disputes the business
    \\has four card disputes (one to answer, one inquiry, one lost with no
    \\answer sent, one won); with --no-disputes KEY may not read disputes.
    \\With --write-key, requests sent with KEY2 may also change things (end a
    \\discount, set a quantity or a price, resume collection, finalise or send
    \\an invoice, keep evidence for a dispute); KEY still only reads.
    \\With --with-stdin it ends when its standard input ends (for a program
    \\that starts it and should take it along when it goes).
    \\examples/who.csv is the business's own file that goes with it.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return bad(io);
    const port = std.fmt.parseInt(u16, args[1], 10) catch return bad(io);
    var now: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    var meters = true;
    var with_stdin = false;
    var opts: sim.Options = .{ .key = args[2], .now = 0 };
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--day") and i + 1 < args.len) {
            i += 1;
            now = model.dayStart(args[i]) orelse return bad(io);
        } else if (std.mem.eql(u8, args[i], "--no-meters")) {
            meters = false;
        } else if (std.mem.eql(u8, args[i], "--write-key") and i + 1 < args.len) {
            i += 1;
            opts.write_key = args[i];
        } else if (std.mem.eql(u8, args[i], "--disputes")) {
            opts.disputes = .some;
        } else if (std.mem.eql(u8, args[i], "--no-disputes")) {
            opts.disputes = .denied;
        } else if (std.mem.eql(u8, args[i], "--with-stdin")) {
            with_stdin = true;
        } else return bad(io);
    }
    opts.port = port;
    opts.now = now;
    opts.meters = meters;
    if (with_stdin) {
        const th = try std.Thread.spawn(.{}, untilStdinEnds, .{io});
        th.detach();
    }
    try sim.run(init.gpa, io, opts);
    return 0;
}

/// Ends the stand-in when its input ends: a program that started it and
/// holds the other end takes it along when it goes, however it goes.
fn untilStdinEnds(io: std.Io) void {
    var buf: [256]u8 = undefined;
    var r = std.Io.File.stdin().reader(io, &buf);
    while (true) {
        _ = r.interface.takeByte() catch break;
    }
    std.process.exit(0);
}

fn bad(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 2;
}

test {
    _ = @import("sim.zig");
}
