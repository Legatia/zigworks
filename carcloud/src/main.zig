//! carcloud: an electric car's battery, charging and locks as a few named
//! tools for an AI agent, over MCP on stdio, through Smartcar's v3 API.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const smartcar = @import("smartcar.zig");
const server = @import("server.zig");

const usage =
    \\usage: carcloud CAR.ini          serve MCP on stdin and stdout (what an agent starts)
    \\       carcloud check CAR.ini    read the car file, then ask Smartcar for the car's state
    \\       carcloud version
    \\
    \\The Smartcar application's secret comes from the environment:
    \\SMARTCAR_CLIENT_SECRET (in harness: secret = SMARTCAR_CLIENT_SECRET:smartcar).
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(io, usage, 2);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try Io.File.stdout().writeStreamingAll(io, "carcloud " ++ build_options.version ++ "\n");
        return 0;
    }
    const check = std.mem.eql(u8, cmd, "check") and args.len == 3;
    if (!check and !(args.len == 2 and cmd.len > 0 and cmd[0] != '-')) return fail(io, usage, 2);
    const path = if (check) args[2] else cmd;
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "carcloud: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    const secret = init.environ_map.get("SMARTCAR_CLIENT_SECRET") orelse return fail(io, "carcloud: SMARTCAR_CLIENT_SECRET is not set\n", 1);
    var sc = try smartcar.Client.init(init.gpa, io, &cfg, secret);
    defer sc.deinit();
    if (check) {
        // the same text an agent sees
        var s = server.Server.init(init.gpa, io, &cfg, &sc) catch |e| {
            if (e == error.LogUnopenable) return 1;
            return e;
        };
        defer s.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(init.gpa);
        s.captured = &out;
        try s.handleLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"car_status\"}}");
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, out.items, .{}) catch return fail(io, "carcloud: no answer\n", 1);
        const res = v.object.get("result").?.object;
        const text = res.get("content").?.array.items[0].object.get("text").?.string;
        if (res.get("isError").?.bool) return fail(io, try std.fmt.allocPrint(a, "carcloud: {s}\n", .{text}), 1);
        try Io.File.stdout().writeStreamingAll(io, text);
        try Io.File.stdout().writeStreamingAll(io, "\n");
        return 0;
    }
    server.run(init.gpa, io, &cfg, &sc) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    return 0;
}

fn fail(io: Io, msg: []const u8, code: u8) u8 {
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return code;
}

test {
    _ = @import("config.zig");
    _ = @import("smartcar.zig");
    _ = @import("server.zig");
    _ = @import("ini.zig");
    _ = @import("jv.zig");
    _ = @import("http.zig");
}
