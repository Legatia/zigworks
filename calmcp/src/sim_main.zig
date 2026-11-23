//! calmcp-sim: a stand-in CalDAV server, for trying calmcp.
const std = @import("std");
const sim = @import("sim.zig");
const tz = @import("tz.zig");

const usage =
    \\usage: calmcp-sim PORT USER PASSWORD [--day YYYY-MM-DD] [--refresh TOKEN]
    \\
    \\A made-up owner's calendars (Personal, Work, Birthdays read only, Tasks)
    \\behind a stand-in CalDAV server on 127.0.0.1:PORT (0: any free port).
    \\Basic auth with USER and PASSWORD; with --refresh, also bearer tokens from
    \\POST /oauth2/token (grant_type=refresh_token, client_id=sim-client).
    \\The events are placed around --day (default: today, UTC); the owner is
    \\owner@example.com, in Europe/Warsaw.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return bad(io);
    const port = std.fmt.parseInt(u16, args[1], 10) catch return bad(io);
    var day: i64 = @divFloor(@as(i64, @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s))), 86400);
    var refresh: []const u8 = "";
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--day") and i + 1 < args.len) {
            i += 1;
            const v = args[i];
            if (v.len != 10 or v[4] != '-' or v[7] != '-') return bad(io);
            const y = std.fmt.parseInt(i64, v[0..4], 10) catch return bad(io);
            const m = std.fmt.parseInt(u8, v[5..7], 10) catch return bad(io);
            const d = std.fmt.parseInt(u8, v[8..10], 10) catch return bad(io);
            if (m < 1 or m > 12 or d < 1 or d > 31) return bad(io);
            day = tz.daysFromCivil(y, m, d);
        } else if (std.mem.eql(u8, args[i], "--refresh") and i + 1 < args.len) {
            i += 1;
            refresh = args[i];
        } else return bad(io);
    }
    try sim.run(init.gpa, io, .{ .port = port, .user = args[2], .password = args[3], .day = day, .refresh = refresh });
    return 0;
}

fn bad(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 2;
}
