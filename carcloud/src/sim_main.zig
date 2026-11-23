//! carcloud-sim: a stand-in for Smartcar's v3 API, or for Tesla's sign-in,
//! Fleet API and tesla-http-proxy, for trying carcloud.
const std = @import("std");
const Io = std.Io;
const sim = @import("sim.zig");
const sim_tesla = @import("sim_tesla.zig");

const usage =
    \\usage: carcloud-sim PORT SECRET    a made-up electric car behind a stand-in for
    \\                                   Smartcar's v3 API on 127.0.0.1:PORT
    \\       carcloud-sim tesla DIR SECRET [API PROXY]
    \\                                   a made-up Tesla (asleep at first) behind stand-ins
    \\                                   for Tesla's sign-in and Fleet API (HTTP) and
    \\                                   tesla-http-proxy (TLS) on 127.0.0.1, free ports
    \\                                   unless given; writes into DIR ca.pem (the proxy's
    \\                                   CA), car.ini (a car file for it) and ports
    \\
    \\Smartcar's ids, for the car file: client_id = sim-client,
    \\vehicle_id = 0c5f52b4-6a39-4a66-b2bd-6fdc1a5c8b11, user_id = 5a2b7c1e-sim-user;
    \\SMARTCAR_CLIENT_SECRET=SECRET. Tesla's: in DIR/car.ini; TESLA_CLIENT_SECRET=SECRET
    \\for carcloud login, which signs in at once.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "tesla")) {
        if (args.len != 4 and args.len != 6) return bad(io);
        var want: [2]u16 = .{ 0, 0 };
        if (args.len == 6) for (0..2) |i| {
            want[i] = std.fmt.parseInt(u16, args[4 + i], 10) catch return bad(io);
        };
        const dir = args[2];
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, dir);
        const m = try sim_tesla.start(std.heap.page_allocator, io, args[3], want);
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "ca.pem" }), .data = m.ca_pem });
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "car.ini" }), .data = try sim_tesla.carFile(a, m) });
        // written last: whoever waits for it finds the rest in place
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "ports" }), .data = try std.fmt.allocPrint(a, "{d} {d}\n", .{ m.api, m.proxy }) });
        std.log.info("Tesla stand-in: API on 127.0.0.1:{d}, proxy on 127.0.0.1:{d}", .{ m.api, m.proxy });
        while (true) io.sleep(.fromSeconds(3600), .awake) catch {};
    }
    if (args.len != 3) return bad(io);
    const port = std.fmt.parseInt(u16, args[1], 10) catch return bad(io);
    try sim.run(init.gpa, io, port, args[2]);
    return 0;
}

fn bad(io: Io) u8 {
    Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 2;
}

test {
    _ = @import("sim_tesla.zig");
}
