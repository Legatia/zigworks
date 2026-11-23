//! homemcp-sim: a made-up home for trying homemcp without hardware.
const std = @import("std");
const sim = @import("sim.zig");

const usage =
    \\usage: homemcp-sim z2m HOST:PORT [BASE]   play Zigbee2MQTT through the MQTT broker at HOST:PORT
    \\       homemcp-sim ha PORT TOKEN          play Home Assistant's REST API on 127.0.0.1:PORT
    \\
    \\Eight devices: Living room light, Kettle plug, Hall thermostat, Front door (lock),
    \\Garage door, Hall motion, Back door (contact), Water main (valve).
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "z2m")) {
        const hp = args[2];
        const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return bad(io);
        const port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return bad(io);
        try sim.runZ2m(init.gpa, io, hp[0..colon], port, if (args.len >= 4) args[3] else "zigbee2mqtt");
        return 0;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "ha")) {
        const port = std.fmt.parseInt(u16, args[2], 10) catch return bad(io);
        try sim.runHa(init.gpa, io, port, args[3]);
        return 0;
    }
    return bad(io);
}

fn bad(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 2;
}
