//! Windows: the stand-in harness as a program, for the smoke to put beside
//! the app as `harness.exe`, where the release carries harness (macOS and
//! Linux copy test/fake_harness.py there itself; Windows can't start a
//! script). It runs the script FAKE_HARNESS_PY names (the smoke sets it to
//! test/fake_harness.py) with python and passes on its arguments, input,
//! output and exit code.
const std = @import("std");

pub fn main(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    const argv = init.minimal.args.toSlice(a) catch return 70;
    var line: std.ArrayList([]const u8) = .empty;
    const script = init.environ_map.get("FAKE_HARNESS_PY") orelse {
        std.debug.print("fake-harness: FAKE_HARNESS_PY doesn't name the stand-in's script\n", .{});
        return 64;
    };
    line.appendSlice(a, &.{ "python", script }) catch return 70;
    for (argv[1..]) |arg| line.append(a, arg) catch return 70;
    var env = init.environ_map.clone(a) catch return 70;
    // desk.json names this program, as harness names itself
    const self = std.process.executablePathAlloc(init.io, a) catch return 70;
    env.put("FAKE_BINARY", self) catch return 70;
    var child = std.process.spawn(init.io, .{
        .argv = line.items,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        // started by the app it has no console, and python would open one
        .create_no_window = true,
    }) catch return 71;
    const term = child.wait(init.io) catch return 72;
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
