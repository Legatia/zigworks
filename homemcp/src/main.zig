//! homemcp: a smart home as named, allowlisted tools for an AI agent, over
//! MCP on stdio, through Zigbee2MQTT or Home Assistant.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const hub_mod = @import("hub.zig");
const server = @import("server.zig");
const model = @import("model.zig");

const usage =
    \\usage: homemcp HOME.ini          serve MCP on stdin and stdout (what an agent starts)
    \\       homemcp check HOME.ini    read the home file, then ask the hub for every device's state
    \\       homemcp version
    \\
    \\Secrets come from the environment, never from the file: HA_TOKEN for Home
    \\Assistant, MQTT_USER and MQTT_PASSWORD for the broker.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(io, usage, 2);
    const cmd = args[1];
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try out(io, "homemcp " ++ build_options.version ++ "\n");
        return 0;
    }
    const check = eql(cmd, "check") and args.len == 3;
    if (!check and !(args.len == 2 and cmd.len > 0 and cmd[0] != '-')) return fail(io, usage, 2);
    const path = if (check) args[2] else cmd;
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "homemcp: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    const env = init.environ_map;
    const secrets: hub_mod.Secrets = .{
        .ha_token = env.get("HA_TOKEN") orelse "",
        .mqtt_user = env.get("MQTT_USER"),
        .mqtt_password = env.get("MQTT_PASSWORD"),
    };
    if (cfg.hub == .homeassistant and secrets.ha_token.len == 0) return fail(io, "homemcp: hub = homeassistant needs HA_TOKEN in the environment\n", 1);
    const hub = try hub_mod.Hub.start(init.gpa, io, &cfg, secrets);
    defer hub.stop();
    if (check) return checkHome(a, io, &cfg, hub);
    server.run(init.gpa, io, &cfg, hub) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    return 0;
}

fn checkHome(a: std.mem.Allocator, io: Io, cfg: *const config.Config, hub: hub_mod.Hub) !u8 {
    // Zigbee2MQTT: give the connection and the first states a moment
    var states: []hub_mod.State = &.{};
    var tries: u32 = 0;
    while (tries < 30) : (tries += 1) {
        states = hub.states(a) catch |e| {
            if (cfg.hub == .homeassistant) return fail(io, try std.fmt.allocPrint(a, "homemcp: {s}: {s}\n", .{ try hub.status(a), @errorName(e) }), 1);
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            continue;
        };
        if (cfg.hub == .homeassistant) break;
        var known: usize = 0;
        for (states) |st| {
            if (st.props.available != null or st.age_s != null) known += 1;
        }
        if (known == states.len) break;
        io.sleep(.fromMilliseconds(200), .awake) catch {};
    }
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "{s}: {d} devices. {s}.\n", .{ cfg.name, cfg.devices.len, try hub.status(a) });
    for (cfg.devices, 0..) |dv, i| {
        const what = if (i < states.len) try model.describe(a, dv.kind, states[i].props) else "unknown";
        try o.print(a, "{s} ({s}, {s}{s}): {s}; may: ", .{ dv.name, dv.id, @tagName(dv.kind), if (dv.guarded) ", guarded" else "", what });
        if (dv.allow.len == 0) try o.appendSlice(a, "nothing (only seen)");
        for (dv.allow, 0..) |x, j| try o.print(a, "{s}{s}", .{ if (j > 0) ", " else "", @tagName(x) });
        try o.append(a, '\n');
    }
    try out(io, o.items);
    return 0;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn out(io: Io, s: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, s);
}

fn fail(io: Io, msg: []const u8, code: u8) u8 {
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return code;
}

test {
    _ = @import("mqtt.zig");
    _ = @import("model.zig");
    _ = @import("config.zig");
    _ = @import("hub.zig");
    _ = @import("server.zig");
    _ = @import("ini.zig");
    _ = @import("jv.zig");
    _ = @import("http.zig");
}
