//! carcloud: an electric car's battery, charging, locks and (Tesla) climate
//! as a few named tools for an AI agent, over MCP on stdio, through
//! Smartcar's v3 API or Tesla's Fleet API.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const smartcar = @import("smartcar.zig");
const tesla = @import("tesla.zig");
const server = @import("server.zig");
const jv = @import("jv.zig");

const usage =
    \\usage: carcloud CAR.ini          serve MCP on stdin and stdout (what an agent starts)
    \\       carcloud check CAR.ini    read the car file, then ask the carmaker's cloud for the car's state
    \\       carcloud login CAR.ini    a Tesla: sign in once with your developer application
    \\       carcloud version
    \\
    \\Secrets come from the environment: SMARTCAR_CLIENT_SECRET for Smartcar
    \\(in harness: secret = SMARTCAR_CLIENT_SECRET:smartcar); TESLA_CLIENT_SECRET
    \\for carcloud login with a Tesla, which keeps the sign-in beside the car file.
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
    const login = std.mem.eql(u8, cmd, "login") and args.len == 3;
    if (!check and !login and !(args.len == 2 and cmd.len > 0 and cmd[0] != '-')) return fail(io, usage, 2);
    const path = if (check or login) args[2] else cmd;
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "carcloud: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    if (cfg.backend == .tesla) return teslaMain(init, &cfg, path, check, login);
    if (login) return fail(io, "carcloud: login is for backend = tesla; a car reached through Smartcar is connected in Smartcar's Dashboard\n", 2);
    const secret = init.environ_map.get("SMARTCAR_CLIENT_SECRET") orelse return fail(io, "carcloud: SMARTCAR_CLIENT_SECRET is not set\n", 1);
    var sc = try smartcar.Client.init(init.gpa, io, &cfg, secret);
    defer sc.deinit();
    const car: server.Car = .{ .smartcar = &sc };
    if (check) {
        const text = statusText(init, &cfg, car) catch |e| return if (e == error.Said) 1 else e;
        try Io.File.stdout().writeStreamingAll(io, text);
        try Io.File.stdout().writeStreamingAll(io, "\n");
        return 0;
    }
    server.run(init.gpa, io, &cfg, car) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    return 0;
}

/// The text an agent sees from car_status; error.Said when it was an
/// error (said on stderr).
fn statusText(init: std.process.Init, cfg: *const config.Config, car: server.Car) ![]const u8 {
    const io = init.io;
    const a = init.arena.allocator();
    var s = server.Server.init(init.gpa, io, cfg, car) catch |e| {
        if (e == error.LogUnopenable) return error.Said;
        return e;
    };
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(init.gpa);
    s.captured = &out;
    try s.handleLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"car_status\"}}");
    const v = jv.parse(a, out.items) orelse {
        _ = fail(io, "carcloud: no answer\n", 1);
        return error.Said;
    };
    const res = jv.get(v, "result");
    const text = jv.str(jv.at(res, &.{ "content", "0", "text" })) orelse "";
    if (jv.boolean(jv.get(res, "isError")) orelse true) {
        _ = fail(io, try std.fmt.allocPrint(a, "carcloud: {s}\n", .{text}), 1);
        return error.Said;
    }
    return a.dupe(u8, text);
}

fn teslaMain(init: std.process.Init, cfg: *const config.Config, path: []const u8, check: bool, login: bool) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    // only a sign-in needs it; a refresh takes it when it is there
    const secret = init.environ_map.get("TESLA_CLIENT_SECRET") orelse "";
    var tc = try tesla.Client.init(init.gpa, io, cfg, secret);
    defer tc.deinit();
    if (login) return teslaLogin(init, cfg, &tc, path);
    const car: server.Car = .{ .tesla = &tc };
    if (!check) {
        server.run(init.gpa, io, cfg, car) catch |e| {
            if (e == error.LogUnopenable) return 1;
            return e;
        };
        return 0;
    }
    const text = statusText(init, cfg, car) catch |e| return if (e == error.Said) 1 else e;
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "{s}\nsign-in: kept in {s}\n", .{ text, cfg.token_path });
    const paired = tc.keyPaired(a) catch null;
    try o.appendSlice(a, if (paired) |p| (if (p) "virtual key: paired with the car\n" else "virtual key: not paired yet: open tesla.com/_ak/YOUR-DOMAIN on the phone with the Tesla app, once (README: With a Tesla)\n") else "virtual key: Tesla didn't say whether it is paired\n");
    var code: u8 = 0;
    if (cfg.command_api.len > 0) {
        if (tc.proxyAnswers(a)) |_| {
            try o.print(a, "commands: signed through tesla-http-proxy at {s} (its certificate accepted)\n", .{cfg.command_api});
        } else |_| {
            try o.print(a, "commands: {s}\n", .{tc.problem orelse "tesla-http-proxy doesn't answer"});
            code = 1;
        }
    } else try o.appendSlice(a, "commands: none (no command_api)\n");
    try Io.File.stdout().writeStreamingAll(io, o.items);
    return code;
}

fn teslaLogin(init: std.process.Init, cfg: *const config.Config, tc: *tesla.Client, path: []const u8) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    if (cfg.redirect_uri.len == 0) return fail(io, try std.fmt.allocPrint(a, "carcloud: {s}: no redirect_uri in [car]: one of those your application lists (developer.tesla.com)\n", .{path}), 1);
    if (tc.secret.len == 0) return fail(io, "carcloud: TESLA_CLIENT_SECRET is not set: your application's secret (developer.tesla.com)\n", 1);
    var rnd: [16]u8 = undefined;
    try io.randomSecure(&rnd);
    const state = std.fmt.bytesToHex(rnd, .lower);
    const out = Io.File.stdout();
    try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "Open this link, sign in to Tesla and allow the application:\n\n{s}\n\nThen paste here the address your browser ended on (it starts with {s}):\n", .{ try tesla.authorizeLink(a, cfg, &state), cfg.redirect_uri }));
    var buf: [16 * 1024]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    const line = (r.interface.takeDelimiter('\n') catch return fail(io, "carcloud: that is too long to be the address\n", 1)) orelse return fail(io, "carcloud: nothing pasted\n", 1);
    const code = tesla.codeFrom(a, line, &state) catch |e| return fail(io, switch (e) {
        error.NoCode => "carcloud: that address has no code (was the access allowed?); run carcloud login again\n",
        error.StateMismatch => "carcloud: that address is from another sign-in (its state differs); run carcloud login again\n",
        error.OutOfMemory => "carcloud: out of memory\n",
    }, 1);
    tc.exchangeCode(a, code) catch |e| return fail(io, try std.fmt.allocPrint(a, "carcloud: {s}\n", .{tc.problem orelse @errorName(e)}), 1);
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "Signed in. The sign-in is kept in {s} (readable by you only; carcloud renews it).\n", .{cfg.token_path});
    if (tc.vehicles(a)) |list| {
        var listed = false;
        try o.appendSlice(a, "The account's cars:\n");
        for (list) |v| {
            try o.print(a, "  {s}  {s}  ({s})\n", .{ v.vin, if (v.name.len > 0) v.name else "(no name)", v.state });
            if (std.mem.eql(u8, v.vin, cfg.vin)) listed = true;
        }
        if (list.len == 0) try o.appendSlice(a, "  none\n");
        try o.appendSlice(a, if (listed) "The car file's vin is among them.\n" else "The car file's vin isn't among them: put the right one in as vin = ...\n");
    } else |_| try o.print(a, "The cars couldn't be listed: {s}\n", .{tc.problem orelse "?"});
    try out.writeStreamingAll(io, o.items);
    return 0;
}

fn fail(io: Io, msg: []const u8, code: u8) u8 {
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return code;
}

test {
    _ = @import("config.zig");
    _ = @import("smartcar.zig");
    _ = @import("tesla.zig");
    _ = @import("server.zig");
    _ = @import("ini.zig");
    _ = @import("jv.zig");
    _ = @import("http.zig");
}
