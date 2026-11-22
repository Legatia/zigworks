//! The MCP server: JSON-RPC over stdin and stdout, and the tools. Seeing is
//! one tool; doing is two: home_set for ordinary devices, and home_guarded
//! for locks, alarms, valves and anything marked guarded, so that an agent
//! harness can ask its owner before every guarded call. Nothing outside
//! the home file's `allow` lists can be done at all.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const model = @import("model.zig");
const hub_mod = @import("hub.zig");
const jv = @import("jv.zig");

pub const max_wait_s = 300;
const confirm_ms = 5000;
const versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    hub: hub_mod.Hub,
    tools_json: []u8,
    log: ?Io.File = null,
    log_offset: u64 = 0,
    /// tests: replies go here instead of stdout
    captured: ?*std.ArrayList(u8) = null,

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, hub: hub_mod.Hub) !Server {
        var s: Server = .{ .gpa = gpa, .io = io, .cfg = cfg, .hub = hub, .tools_json = try toolsJson(gpa, cfg) };
        if (cfg.log_path.len > 0) {
            const f = Io.Dir.cwd().createFile(io, cfg.log_path, .{ .truncate = false, .read = true }) catch |e| {
                var buf: [1024]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "homemcp: can't open the log {s}: {s}\n", .{ cfg.log_path, @errorName(e) }) catch "homemcp: can't open the log\n";
                Io.File.stderr().writeStreamingAll(io, msg) catch {};
                gpa.free(s.tools_json);
                return error.LogUnopenable;
            };
            s.log = f;
            s.log_offset = try f.length(io);
        }
        return s;
    }

    pub fn deinit(s: *Server) void {
        s.gpa.free(s.tools_json);
        if (s.log) |f| f.close(s.io);
    }

    pub fn handleLine(s: *Server, raw: []const u8) !void {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = jv.parse(a, line) orelse return s.send("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error\"}}");
        const method = jv.str(jv.get(v, "method")) orelse return;
        const idv = jv.get(v, "id") orelse return; // a notification
        const id = try std.json.Stringify.valueAlloc(a, idv, .{});
        if (eql(method, "initialize")) {
            const asked = jv.str(jv.at(v, &.{ "params", "protocolVersion" }));
            const version = for (versions) |x| {
                if (asked != null and eql(asked.?, x)) break x;
            } else versions[0];
            const instructions = try std.fmt.allocPrint(a, "homemcp shows and controls {s}. home_state shows every device and what may be done with it; home_set acts on ordinary devices; home_guarded acts on locks, alarms, valves and anything else marked guarded. Nothing else can be done.", .{s.cfg.name});
            return s.reply(a, id, try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"homemcp\",\"version\":\"{s}\"}},\"instructions\":{f}}}", .{ version, build_options.version, std.json.fmt(instructions, .{}) }));
        }
        if (eql(method, "ping")) return s.reply(a, id, "{}");
        if (eql(method, "tools/list")) return s.reply(a, id, s.tools_json);
        if (eql(method, "tools/call")) {
            const name = jv.str(jv.at(v, &.{ "params", "name" })) orelse return s.text(a, id, "no tool name", true);
            const args = jv.at(v, &.{ "params", "arguments" });
            if (eql(name, "home_state")) return s.stateTool(a, id, args);
            if (eql(name, "home_set")) return s.actTool(a, id, args, false);
            if (eql(name, "home_guarded")) return s.actTool(a, id, args, true);
            if (eql(name, "home_wait")) return s.waitTool(a, id, args);
            return s.text(a, id, try std.fmt.allocPrint(a, "no tool called {s}", .{name}), true);
        }
        return s.send(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id}));
    }

    // ---- tools ----

    fn stateTool(s: *Server, a: Allocator, id: []const u8, args: ?jv.Value) !void {
        const only = jv.str(jv.get(args, "device"));
        if (only) |n| if (s.cfg.device(n) == null) return s.text(a, id, try std.fmt.allocPrint(a, "no device called {s}; there are: {s}", .{ n, try s.deviceNames(a, null) }), true);
        const states = s.hub.states(a) catch |e| return s.text(a, id, try std.fmt.allocPrint(a, "{s}: {s}", .{ try s.hub.status(a), @errorName(e) }), true);
        var o: std.ArrayList(u8) = .empty;
        try o.print(a, "{s}. {s}.\n", .{ s.cfg.name, try s.hub.status(a) });
        for (s.cfg.devices, states) |d, st| {
            if (only) |n| if (!eql(n, d.name)) continue;
            try o.print(a, "{s} ({s}, {s}): {s}", .{ d.name, d.id, @tagName(d.kind), try model.describe(a, d.kind, st.props) });
            if (st.age_s) |age| if (age >= 600) try o.print(a, " (changed {s} ago)", .{try ago(a, age)});
            if (d.allow.len > 0) {
                try o.print(a, ". May: {s}", .{try actionList(a, &d, s.cfg)});
                if (d.guarded) try o.appendSlice(a, " (guarded: home_guarded)");
            } else try o.appendSlice(a, ". Only seen, never acted on");
            if (d.note.len > 0) try o.print(a, ". {s}", .{d.note});
            try o.appendSlice(a, ".\n");
        }
        return s.text(a, id, o.items, false);
    }

    fn actTool(s: *Server, a: Allocator, id: []const u8, args: ?jv.Value, guarded: bool) !void {
        const tool = if (guarded) "home_guarded" else "home_set";
        const name = jv.str(jv.get(args, "device")) orelse return s.text(a, id, "say which device", true);
        const di = s.cfg.device(name) orelse return s.text(a, id, try std.fmt.allocPrint(a, "no device called {s}; {s} can act on: {s}", .{ name, tool, try s.deviceNames(a, guarded) }), true);
        const d = &s.cfg.devices[di];
        // From here on every answer goes into the log, refusals too: what
        // the agent tried matters as much as what was done.
        const act_s = jv.str(jv.get(args, "action")) orelse "";
        if (d.allow.len == 0) return s.finish(a, id, tool, d, act_s, null, null, "refused", try std.fmt.allocPrint(a, "{s} may only be seen, never acted on", .{name}), true);
        if (d.guarded != guarded) return s.finish(a, id, tool, d, act_s, null, null, "refused", try std.fmt.allocPrint(a, "{s} is {s}: use {s}", .{ name, if (d.guarded) "guarded" else "not guarded", if (d.guarded) "home_guarded" else "home_set" }), true);
        if (act_s.len == 0) return s.finish(a, id, tool, d, act_s, null, null, "refused", "say which action", true);
        const action = model.Action.parse(act_s) orelse return s.finish(a, id, tool, d, act_s, null, null, "refused", try std.fmt.allocPrint(a, "no action called {s}", .{act_s}), true);
        if (!d.allows(action)) return s.finish(a, id, tool, d, act_s, null, null, "refused", try std.fmt.allocPrint(a, "{s} may not {s}; it may: {s}", .{ name, act_s, try actionList(a, d, s.cfg) }), true);
        var number: ?f64 = null;
        var txt: ?[]const u8 = null;
        switch (action.needs()) {
            .nothing => {},
            .number => {
                number = numberArg(jv.get(args, "value")) orelse return s.finish(a, id, tool, d, act_s, null, null, "refused", try std.fmt.allocPrint(a, "{s} needs a number as value", .{act_s}), true);
                const r = switch (action) {
                    .brightness => s.cfg.brightness,
                    .temperature => s.cfg.temperature,
                    else => s.cfg.position,
                };
                if (number.? < r.min or number.? > r.max) return s.finish(a, id, tool, d, act_s, number, null, "refused", try std.fmt.allocPrint(a, "{s} must be from {s} to {s}", .{ act_s, model.num(r.min), model.num(r.max) }), true);
            },
            .text => {
                txt = jv.str(jv.get(args, "value")) orelse return s.finish(a, id, tool, d, act_s, null, null, "refused", "mode needs a value", true);
                const known = for (d.modes) |m| {
                    if (std.ascii.eqlIgnoreCase(m, txt.?)) break true;
                } else false;
                if (!known) return s.finish(a, id, tool, d, act_s, null, txt, "refused", try std.fmt.allocPrint(a, "{s} may only be set to: {s}", .{ name, try join(a, d.modes) }), true);
            },
        }
        const before = s.hub.states(a) catch |e| return s.finish(a, id, tool, d, act_s, number, txt, "failed", try std.fmt.allocPrint(a, "can't reach the hub: {s}", .{@errorName(e)}), true);
        if (before[di].props.available == false) return s.finish(a, id, tool, d, act_s, number, txt, "refused", try std.fmt.allocPrint(a, "{s} is offline: nothing was sent", .{name}), true);
        s.hub.command(a, d, action, number, txt) catch |e| return s.finish(a, id, tool, d, act_s, number, txt, "failed", try std.fmt.allocPrint(a, "not sent: {s}", .{@errorName(e)}), true);
        // read it back: did it take?
        var waited: u32 = 0;
        var last = before[di].props;
        while (waited <= confirm_ms) : (waited += 250) {
            const now = s.hub.states(a) catch null;
            if (now) |st| {
                last = st[di].props;
                if (model.took(action, number, txt, last) == true) {
                    return s.finish(a, id, tool, d, act_s, number, txt, "done", try std.fmt.allocPrint(a, "done: {s} is {s}", .{ name, try model.describe(a, d.kind, last) }), false);
                }
            }
            s.io.sleep(.fromMilliseconds(250), .awake) catch {};
        }
        return s.finish(a, id, tool, d, act_s, number, txt, "unconfirmed", try std.fmt.allocPrint(a, "sent, but {s} has not confirmed within {d} s: it says {s}", .{ name, confirm_ms / 1000, try model.describe(a, d.kind, last) }), false);
    }

    /// Answers, and logs the call. `action` is what the agent asked for, as it
    /// asked (it may be no action at all).
    fn finish(s: *Server, a: Allocator, id: []const u8, tool: []const u8, d: *const config.Device, action: []const u8, number: ?f64, txt: ?[]const u8, result: []const u8, message: []const u8, is_error: bool) !void {
        s.writeLog(a, tool, d, action, number, txt, result, message) catch {};
        return s.text(a, id, message, is_error);
    }

    fn waitTool(s: *Server, a: Allocator, id: []const u8, args: ?jv.Value) !void {
        const name = jv.str(jv.get(args, "device")) orelse return s.text(a, id, "say which device", true);
        const di = s.cfg.device(name) orelse return s.text(a, id, try std.fmt.allocPrint(a, "no device called {s}; there are: {s}", .{ name, try s.deviceNames(a, null) }), true);
        const prop = jv.str(jv.get(args, "property")) orelse return s.text(a, id, "say which property", true);
        const known = for (model.Props.fields) |f| {
            if (eql(f, prop)) break true;
        } else false;
        if (!known) return s.text(a, id, try std.fmt.allocPrint(a, "no property called {s}; there are: {s}", .{ prop, try join(a, &model.Props.fields) }), true);
        const cond = jv.str(jv.get(args, "condition")) orelse "changes";
        const ops = [_][]const u8{ "changes", "==", "!=", ">", "<", ">=", "<=" };
        const op = for (ops, 0..) |o, i| {
            if (eql(o, cond)) break i;
        } else return s.text(a, id, "condition: changes, ==, !=, >, <, >= or <=", true);
        const want: ?[]const u8 = if (jv.get(args, "value")) |vv| switch (vv) {
            .string => |x| normalize(x),
            .integer, .float, .number_string => try a.dupe(u8, model.num(numberArg(vv).?)),
            .bool => |b| if (b) "yes" else "no",
            else => null,
        } else null;
        if (op != 0 and want == null) return s.text(a, id, "this condition needs a value", true);
        if (op >= 3 and std.fmt.parseFloat(f64, want.?) == error.InvalidCharacter) return s.text(a, id, "this condition needs a number", true);
        var secs: f64 = numberArg(jv.get(args, "timeout_s")) orelse 60;
        secs = std.math.clamp(secs, 0, max_wait_s);
        const d = &s.cfg.devices[di];
        const first = s.hub.states(a) catch |e| return s.text(a, id, try std.fmt.allocPrint(a, "can't reach the hub: {s}", .{@errorName(e)}), true);
        const start = try model.field(a, first[di].props, prop);
        var waited: f64 = 0;
        var cur = start;
        while (true) {
            const met = if (cur) |c| switch (op) {
                0 => start == null or !std.ascii.eqlIgnoreCase(c, start.?),
                1 => std.ascii.eqlIgnoreCase(c, want.?),
                2 => !std.ascii.eqlIgnoreCase(c, want.?),
                else => cmp(c, want.?, op),
            } else false;
            if (met) {
                const what = if (op == 0) try std.fmt.allocPrint(a, "{s} {s} changed after {d:.1} s: {s} -> {s}", .{ name, prop, waited, start orelse "unknown", cur.? }) else try std.fmt.allocPrint(a, "{s} {s} {s} {s}: yes, after {d:.1} s", .{ name, prop, cond, want.?, waited });
                return s.text(a, id, what, false);
            }
            if (waited >= secs) break;
            s.io.sleep(.fromMilliseconds(500), .awake) catch {};
            waited += 0.5;
            const st = s.hub.states(a) catch continue;
            cur = try model.field(a, st[di].props, prop);
        }
        _ = d;
        return s.text(a, id, try std.fmt.allocPrint(a, "{s} {s} {s}{s}{s}: not within {d:.0} s (it is {s})", .{ name, prop, cond, if (want != null) " " else "", want orelse "", secs, cur orelse "unknown" }), false);
    }

    // ---- helpers ----

    fn deviceNames(s: *const Server, a: Allocator, guarded: ?bool) ![]u8 {
        var o: std.ArrayList(u8) = .empty;
        for (s.cfg.devices) |d| {
            if (guarded) |g| if (d.guarded != g or d.allow.len == 0) continue;
            if (o.items.len > 0) try o.appendSlice(a, ", ");
            try o.appendSlice(a, d.name);
        }
        if (o.items.len == 0) try o.appendSlice(a, "none");
        return o.items;
    }

    fn writeLog(s: *Server, a: Allocator, tool: []const u8, d: *const config.Device, action: []const u8, number: ?f64, txt: ?[]const u8, result: []const u8, message: []const u8) !void {
        const f = s.log orelse return;
        var tbuf: [20]u8 = undefined;
        const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_s));
        const value: []const u8 = if (number) |n| try a.dupe(u8, model.num(n)) else if (txt) |x| try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(x, .{})}) else "null";
        const line = try std.fmt.allocPrint(a, "{{\"time\":\"{s}\",\"tool\":\"{s}\",\"device\":{f},\"id\":{f},\"action\":{f},\"value\":{s},\"result\":\"{s}\",\"message\":{f}}}\n", .{ isoTime(&tbuf, now_s), tool, std.json.fmt(d.name, .{}), std.json.fmt(d.id, .{}), std.json.fmt(action, .{}), value, result, std.json.fmt(message, .{}) });
        try f.writePositionalAll(s.io, line, s.log_offset);
        s.log_offset += line.len;
    }

    fn text(s: *Server, a: Allocator, id: []const u8, msg: []const u8, is_error: bool) !void {
        return s.reply(a, id, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{}}}", .{ std.json.fmt(msg, .{}), is_error }));
    }

    fn reply(s: *Server, a: Allocator, id: []const u8, result: []const u8) !void {
        return s.send(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result }));
    }

    fn send(s: *Server, line: []const u8) !void {
        if (s.captured) |c| {
            try c.appendSlice(s.gpa, line);
            try c.append(s.gpa, '\n');
            return;
        }
        const out = Io.File.stdout();
        try out.writeStreamingAll(s.io, line);
        try out.writeStreamingAll(s.io, "\n");
    }
};

/// Serves MCP on stdin and stdout until stdin closes.
pub fn run(gpa: Allocator, io: Io, cfg: *const config.Config, hub: hub_mod.Hub) !void {
    var s = try Server.init(gpa, io, cfg, hub);
    defer s.deinit();
    const buf = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(buf);
    var r = Io.File.stdin().reader(io, buf);
    while (r.interface.takeDelimiter('\n') catch return) |line| {
        try s.handleLine(line);
    }
}

fn toolsJson(gpa: Allocator, cfg: *const config.Config) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var all: std.ArrayList(u8) = .empty;
    var plain: std.ArrayList(u8) = .empty;
    var guarded: std.ArrayList(u8) = .empty;
    var plain_about: std.ArrayList(u8) = .empty;
    var guarded_about: std.ArrayList(u8) = .empty;
    for (cfg.devices) |d| {
        if (all.items.len > 0) try all.append(a, ',');
        try all.print(a, "{f}", .{std.json.fmt(d.name, .{})});
        if (d.allow.len == 0) continue;
        const list = if (d.guarded) &guarded else &plain;
        const about = if (d.guarded) &guarded_about else &plain_about;
        if (list.items.len > 0) {
            try list.append(a, ',');
            try about.appendSlice(a, "; ");
        }
        try list.print(a, "{f}", .{std.json.fmt(d.name, .{})});
        try about.print(a, "{s}: {s}", .{ d.name, try actionList(a, &d, cfg) });
    }
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"tools\":[");
    try o.print(a, "{{\"name\":\"home_state\",\"description\":\"Every device in the home (or one): its state now, and what may be done with it. Only reads.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"device\":{{\"type\":\"string\",\"enum\":[{s}]}}}}}},\"annotations\":{{\"readOnlyHint\":true}}}}", .{all.items});
    if (plain.items.len > 0) {
        const desc = try std.fmt.allocPrint(a, "Act on an ordinary device and read back whether it took. Allowed: {s}. brightness and position are %, temperature is °C; they need value.", .{plain_about.items});
        try o.print(a, ",{{\"name\":\"home_set\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"device\":{{\"type\":\"string\",\"enum\":[{s}]}},\"action\":{{\"type\":\"string\"}},\"value\":{{\"type\":\"string\",\"description\":\"for brightness, position, temperature, mode\"}}}},\"required\":[\"device\",\"action\"]}}}}", .{ std.json.fmt(desc, .{}), plain.items });
    }
    if (guarded.items.len > 0) {
        const desc = try std.fmt.allocPrint(a, "Act on a guarded device (locks, alarms, valves, doors and gates, anything that matters if it goes wrong) and read back whether it took. The owner should be asked before every call. Allowed: {s}.", .{guarded_about.items});
        try o.print(a, ",{{\"name\":\"home_guarded\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"device\":{{\"type\":\"string\",\"enum\":[{s}]}},\"action\":{{\"type\":\"string\"}},\"value\":{{\"type\":\"string\"}}}},\"required\":[\"device\",\"action\"]}},\"annotations\":{{\"destructiveHint\":true}},\"_meta\":{{\"anthropic/requiresUserInteraction\":true}}}}", .{ std.json.fmt(desc, .{}), guarded.items });
    }
    try o.print(a, ",{{\"name\":\"home_wait\",\"description\":\"Wait until a device's property changes or meets a condition (such as open == yes, temperature > 21, lock == unlocked), for at most timeout_s seconds (default 60, at most {d}). Only reads.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"device\":{{\"type\":\"string\",\"enum\":[{s}]}},\"property\":{{\"type\":\"string\",\"enum\":[{s}]}},\"condition\":{{\"type\":\"string\",\"enum\":[\"changes\",\"==\",\"!=\",\">\",\"<\",\">=\",\"<=\"]}},\"value\":{{\"type\":\"string\"}},\"timeout_s\":{{\"type\":\"number\"}}}},\"required\":[\"device\",\"property\"]}},\"annotations\":{{\"readOnlyHint\":true}}}}", .{ max_wait_s, all.items, try quotedList(a, &model.Props.fields) });
    try o.appendSlice(a, "]}");
    return gpa.dupe(u8, o.items);
}

fn actionList(a: Allocator, d: *const config.Device, cfg: *const config.Config) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (d.allow, 0..) |x, i| {
        if (i > 0) try o.appendSlice(a, ", ");
        try o.appendSlice(a, @tagName(x));
        switch (x) {
            .brightness => try o.print(a, " {s}-{s}%", .{ model.num(cfg.brightness.min), model.num(cfg.brightness.max) }),
            .temperature => try o.print(a, " {s}-{s} °C", .{ model.num(cfg.temperature.min), model.num(cfg.temperature.max) }),
            .position => try o.print(a, " {s}-{s}%", .{ model.num(cfg.position.min), model.num(cfg.position.max) }),
            .mode => try o.print(a, " ({s})", .{try join(a, d.modes)}),
            else => {},
        }
    }
    return o.items;
}

fn join(a: Allocator, items: []const []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (items, 0..) |x, i| {
        if (i > 0) try o.appendSlice(a, ", ");
        try o.appendSlice(a, x);
    }
    return o.items;
}

fn quotedList(a: Allocator, items: []const []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (items, 0..) |x, i| {
        if (i > 0) try o.append(a, ',');
        try o.print(a, "{f}", .{std.json.fmt(x, .{})});
    }
    return o.items;
}

fn numberArg(v: ?jv.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " %°C")) catch null,
        else => null,
    };
}

/// true/on/open -> yes, false/off/closed -> no; anything else as it is.
fn normalize(s: []const u8) []const u8 {
    const yes = [_][]const u8{ "true", "yes", "on" };
    const no = [_][]const u8{ "false", "no", "off" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(s, y)) return "yes";
    for (no) |n| if (std.ascii.eqlIgnoreCase(s, n)) return "no";
    return s;
}

fn cmp(cur: []const u8, want: []const u8, op: usize) bool {
    const x = std.fmt.parseFloat(f64, cur) catch return false;
    const y = std.fmt.parseFloat(f64, want) catch return false;
    return switch (op) {
        3 => x > y,
        4 => x < y,
        5 => x >= y,
        else => x <= y,
    };
}

fn ago(a: Allocator, s: f64) ![]u8 {
    if (s < 3600) return std.fmt.allocPrint(a, "{d:.0} min", .{s / 60});
    if (s < 86400 * 2) return std.fmt.allocPrint(a, "{d:.1} h", .{s / 3600});
    return std.fmt.allocPrint(a, "{d:.0} days", .{s / 86400});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isoTime(buf: *[20]u8, secs: i64) []const u8 {
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)), sod / 3600, sod / 60 % 60, sod % 60,
    }) catch unreachable;
}

test "the tool list is one line and offers each tool only when it has devices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: config.Diag = .{};
    const cfg = try config.parse(arena.allocator(),
        \\[device light]
        \\id = Hall light
        \\kind = light
        \\allow = on, off
        \\[device motion]
        \\id = Hall motion
        \\kind = sensor
    , &d);
    const j = try toolsJson(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(j);
    try std.testing.expect(std.mem.indexOfScalar(u8, j, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"home_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"home_guarded\"") == null);
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, j, .{});
    v.deinit();
}

test "values for waits" {
    try std.testing.expectEqualStrings("yes", normalize("TRUE"));
    try std.testing.expectEqualStrings("no", normalize("off"));
    try std.testing.expectEqualStrings("locked", normalize("locked"));
    try std.testing.expect(cmp("21.5", "21", 3));
    try std.testing.expect(!cmp("x", "21", 3));
    var b: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-22T00:00:00Z", isoTime(&b, 1795305600));
}
