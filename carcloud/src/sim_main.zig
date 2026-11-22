//! carcloud-sim: a stand-in for Smartcar's v3 API, for trying carcloud.
const std = @import("std");
const sim = @import("sim.zig");

const usage =
    \\usage: carcloud-sim PORT SECRET    a made-up electric car behind a stand-in for
    \\                                   Smartcar's v3 API on 127.0.0.1:PORT
    \\
    \\Its ids, for the car file: client_id = sim-client,
    \\vehicle_id = 0c5f52b4-6a39-4a66-b2bd-6fdc1a5c8b11, user_id = 5a2b7c1e-sim-user;
    \\SMARTCAR_CLIENT_SECRET=SECRET.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    }
    const port = std.fmt.parseInt(u16, args[1], 10) catch {
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    };
    try sim.run(init.gpa, io, port, args[2]);
    return 0;
}
