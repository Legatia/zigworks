//! homemcp-sim: a made-up home for trying homemcp without hardware.
const std = @import("std");
const sim = @import("sim.zig");
const http = @import("http.zig");
const mqtt = @import("mqtt.zig");

const usage =
    \\usage: homemcp-sim z2m HOST:PORT [BASE]   play Zigbee2MQTT through the MQTT broker at HOST:PORT
    \\       homemcp-sim ha PORT TOKEN          play Home Assistant (REST and WebSocket) on 127.0.0.1:PORT
    \\                                         (0: a free port; it prints the one it took)
    \\       homemcp-sim poke ha PORT TOKEN ENTITY JSON
    \\       homemcp-sim poke z2m HOST:PORT NAME JSON
    \\                                         change a device or person, as a sensor or a hand would:
    \\                                         {"contact": false}, {"occupancy": true}, {"home": false} ...
    \\
    \\The flat: Living room light, Kettle plug, Hall thermostat, Front door (lock), Garage door,
    \\Hall motion, Back door (contact), Water main (valve), Bedroom lamp (colour), Ceiling fan,
    \\Living room temperature, Sink leak, Kitchen smoke alarm; as Home Assistant also the Kitchen
    \\speaker, the scenes Evening and Leaving, Anna and Ben (people), a camera and a few others.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "z2m")) {
        const hp = splitHostPort(args[2]) orelse return bad(io);
        try sim.runZ2m(init.gpa, io, hp.host, hp.port, if (args.len >= 4) args[3] else "zigbee2mqtt");
        return 0;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "ha")) {
        const port = std.fmt.parseInt(u16, args[2], 10) catch return bad(io);
        try sim.runHa(init.gpa, io, port, args[3], ready);
        return 0;
    }
    if (args.len == 7 and std.mem.eql(u8, args[1], "poke") and std.mem.eql(u8, args[2], "ha")) {
        const port = std.fmt.parseInt(u16, args[3], 10) catch return bad(io);
        var client: http.Client = .init(init.gpa, io, .{ .https = false, .host = "127.0.0.1", .port = port, .prefix = "" });
        defer client.deinit();
        const ans = http.fetch(&client, a, .{ .path = try std.fmt.allocPrint(a, "/homesim/{s}", .{args[5]}), .body = args[6], .key = args[4], .limits = .{ .idle_ms = 5000, .total_ms = 10_000 } }) catch |e| return say(io, try std.fmt.allocPrint(a, "homemcp-sim: can't reach the stand-in: {s}\n", .{@errorName(e)}));
        if (ans.status != 200) return say(io, try std.fmt.allocPrint(a, "homemcp-sim: the stand-in answered {d}: {s}\n", .{ ans.status, ans.body }));
        return 0;
    }
    if (args.len == 6 and std.mem.eql(u8, args[1], "poke") and std.mem.eql(u8, args[2], "z2m")) {
        const hp = splitHostPort(args[3]) orelse return bad(io);
        const c = try init.gpa.create(mqtt.Client);
        defer init.gpa.destroy(c);
        c.connect(init.gpa, io, hp.host, hp.port, "homemcp-sim-poke", null, null, 30) catch |e| return say(io, try std.fmt.allocPrint(a, "homemcp-sim: can't reach the broker: {s}\n", .{@errorName(e)}));
        defer c.close();
        try c.publish(try std.fmt.allocPrint(a, "homesim/{s}", .{args[4]}), args[5], false);
        c.bye();
        return 0;
    }
    return bad(io);
}

fn ready(io: std.Io, port: u16) void {
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "homemcp-sim: Home Assistant on 127.0.0.1:{d}\n", .{port}) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

const HostPort = struct { host: []const u8, port: u16 };

fn splitHostPort(hp: []const u8) ?HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return null;
    return .{ .host = hp[0..colon], .port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return null };
}

fn say(io: std.Io, msg: []const u8) u8 {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return 1;
}

fn bad(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 2;
}
