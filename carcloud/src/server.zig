//! The MCP server: car_status reads, car_command sends one of the commands
//! the car file allows (within its limits: how many a day, how often, which
//! charge limits), and car_unlock exists only when the file allows
//! unlocking, as a tool of its own that asks for a person every time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const smartcar = @import("smartcar.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");

const versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    sc: *smartcar.Client,
    tools_json: []u8,
    /// when commands were sent, for the limits
    sent: std.ArrayList(i128) = .empty,
    log: ?Io.File = null,
    log_offset: u64 = 0,
    captured: ?*std.ArrayList(u8) = null,

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, sc: *smartcar.Client) !Server {
        var s: Server = .{ .gpa = gpa, .io = io, .cfg = cfg, .sc = sc, .tools_json = try toolsJson(gpa, cfg) };
        if (cfg.log_path.len > 0) {
            const f = Io.Dir.cwd().createFile(io, cfg.log_path, .{ .truncate = false, .read = true }) catch |e| {
                var buf: [1024]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "carcloud: can't open the log {s}: {s}\n", .{ cfg.log_path, @errorName(e) }) catch "carcloud: can't open the log\n";
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
        s.sent.deinit(s.gpa);
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
        const idv = jv.get(v, "id") orelse return;
        const id = try std.json.Stringify.valueAlloc(a, idv, .{});
        if (eql(method, "initialize")) {
            const asked = jv.str(jv.at(v, &.{ "params", "protocolVersion" }));
            const version = for (versions) |x| {
                if (asked != null and eql(asked.?, x)) break x;
            } else versions[0];
            const instructions = try std.fmt.allocPrint(a, "carcloud reads {s} through Smartcar and sends it the few commands its owner allowed. Data can be hours old: Smartcar collects it from the carmaker, often about once a day.", .{s.cfg.name});
            return s.reply(a, id, try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"carcloud\",\"version\":\"{s}\"}},\"instructions\":{f}}}", .{ version, build_options.version, std.json.fmt(instructions, .{}) }));
        }
        if (eql(method, "ping")) return s.reply(a, id, "{}");
        if (eql(method, "tools/list")) return s.reply(a, id, s.tools_json);
        if (eql(method, "tools/call")) {
            const name = jv.str(jv.at(v, &.{ "params", "name" })) orelse return s.text(a, id, "no tool name", true);
            const args = jv.at(v, &.{ "params", "arguments" });
            if (eql(name, "car_status")) return s.statusTool(a, id);
            if (eql(name, "car_command")) return s.commandTool(a, id, args, false);
            if (eql(name, "car_unlock") and s.cfg.allows(.unlock)) return s.commandTool(a, id, args, true);
            return s.text(a, id, try std.fmt.allocPrint(a, "no tool called {s}", .{name}), true);
        }
        return s.send(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id}));
    }

    fn statusTool(s: *Server, a: Allocator, id: []const u8) !void {
        const list = s.sc.signals(a) catch |e| return s.text(a, id, try s.why(a, e), true);
        var o: std.ArrayList(u8) = .empty;
        try o.print(a, "{s}:\n", .{s.cfg.name});
        var oldest: ?f64 = null;
        var unavailable: std.ArrayList(u8) = .empty;
        const wanted = [_][]const u8{
            "tractionbattery-stateofcharge", "tractionbattery-range",           "charge-ischarging",
            "charge-ischargingcableconnected", "charge-chargelimits",           "closure-islocked",
            "odometer-traveleddistance",     "climate-internaltemperature",     "location-preciselocation",
        };
        for (wanted) |code| {
            if (eql(code, "location-preciselocation") and !s.cfg.location) continue;
            const sig = for (list) |x| {
                if (eql(x.code, code)) break x;
            } else continue;
            if (!sig.ok) {
                if (unavailable.items.len > 0) try unavailable.appendSlice(a, ", ");
                try unavailable.appendSlice(a, code);
                continue;
            }
            if (sig.age_s) |age| oldest = @max(oldest orelse 0, age);
            const b = sig.body;
            const val = jv.get(b, "value");
            const unit = jv.str(jv.get(b, "unit")) orelse "";
            const line: []const u8 = if (eql(code, "tractionbattery-stateofcharge"))
                try std.fmt.allocPrint(a, "battery: {s}%", .{num(a, val)})
            else if (eql(code, "tractionbattery-range"))
                try std.fmt.allocPrint(a, "range: {s} {s}", .{ num(a, val), unit })
            else if (eql(code, "charge-ischarging"))
                try std.fmt.allocPrint(a, "charging: {s}", .{yesNo(val)})
            else if (eql(code, "charge-ischargingcableconnected"))
                try std.fmt.allocPrint(a, "plugged in: {s}", .{yesNo(val)})
            else if (eql(code, "charge-chargelimits"))
                try std.fmt.allocPrint(a, "charge limit: {s}%", .{num(a, jv.get(b, "activeLimit"))})
            else if (eql(code, "closure-islocked"))
                try std.fmt.allocPrint(a, "locked: {s}", .{yesNo(val)})
            else if (eql(code, "odometer-traveleddistance"))
                try std.fmt.allocPrint(a, "odometer: {s} {s}", .{ num(a, val), unit })
            else if (eql(code, "climate-internaltemperature"))
                try std.fmt.allocPrint(a, "inside: {s} °C", .{num(a, val)})
            else
                try std.fmt.allocPrint(a, "location: {s}, {s} ({s})", .{ num(a, jv.get(b, "latitude")), num(a, jv.get(b, "longitude")), jv.str(jv.get(b, "locationType")) orelse "?" });
            try o.print(a, "{s}\n", .{line});
        }
        if (unavailable.items.len > 0) try o.print(a, "not available now: {s}\n", .{unavailable.items});
        if (oldest) |age| try o.print(a, "{s}\n", .{try ageText(a, age)});
        try o.print(a, "commands the owner allowed: {s}", .{try allowList(a, s.cfg)});
        return s.text(a, id, o.items, false);
    }

    fn commandTool(s: *Server, a: Allocator, id: []const u8, args: ?jv.Value, unlock: bool) !void {
        var cmd: config.Command = .unlock;
        var percent: ?u8 = null;
        // Every call goes into the log, refusals too: what the agent tried
        // matters as much as what was done.
        if (!unlock) {
            const name = jv.str(jv.get(args, "command")) orelse "";
            if (name.len == 0) return s.finish(a, id, name, null, "refused", "say which command", true);
            cmd = std.meta.stringToEnum(config.Command, name) orelse return s.finish(a, id, name, null, "refused", try std.fmt.allocPrint(a, "no command called {s}", .{name}), true);
            if (cmd == .unlock) return s.finish(a, id, name, null, "refused", "unlocking is not done through car_command", true);
            if (!s.cfg.allows(cmd)) return s.finish(a, id, name, null, "refused", try std.fmt.allocPrint(a, "{s} is not allowed; allowed: {s}", .{ name, try allowList(a, s.cfg) }), true);
            if (cmd == .charge_limit) {
                const p = numberArg(jv.get(args, "percent")) orelse return s.finish(a, id, name, null, "refused", "charge_limit needs percent", true);
                if (p < @as(f64, @floatFromInt(s.cfg.limit_min)) or p > @as(f64, @floatFromInt(s.cfg.limit_max)))
                    return s.finish(a, id, name, p, "refused", try std.fmt.allocPrint(a, "the charge limit must be from {d} to {d} %", .{ s.cfg.limit_min, s.cfg.limit_max }), true);
                percent = @intFromFloat(@round(p));
            }
        }
        const cmd_s = @tagName(cmd);
        const pct: ?f64 = if (percent) |p| @floatFromInt(p) else null;
        // the owner's limits on how many and how often
        const now = sock.nowNs(s.io);
        var i: usize = s.sent.items.len;
        while (i > 0) {
            i -= 1;
            if (now - s.sent.items[i] > 24 * std.time.ns_per_hour) _ = s.sent.orderedRemove(i);
        }
        if (s.sent.items.len >= s.cfg.per_day) return s.finish(a, id, cmd_s, pct, "refused", try std.fmt.allocPrint(a, "not sent: {d} commands in the last 24 hours is the limit", .{s.cfg.per_day}), true);
        if (s.sent.items.len > 0) {
            const since = @divTrunc(now - s.sent.items[s.sent.items.len - 1], std.time.ns_per_s);
            if (since < s.cfg.min_between_s) return s.finish(a, id, cmd_s, pct, "refused", try std.fmt.allocPrint(a, "not sent: wait {d} s more (at least {d} s between commands)", .{ @as(i128, s.cfg.min_between_s) - since, s.cfg.min_between_s }), true);
        }
        try s.sent.append(s.gpa, now);
        const out = s.sc.command(a, cmd, percent) catch |e| return s.finish(a, id, cmd_s, pct, "failed", try s.why(a, e), true);
        const what = if (cmd == .charge_limit) try std.fmt.allocPrint(a, "charge limit {d}%", .{percent.?}) else cmd_s;
        if (eql(out.status, "SUCCESS")) return s.finish(a, id, cmd_s, pct, "done", try std.fmt.allocPrint(a, "done: {s}, confirmed by the car", .{what}), false);
        if (eql(out.status, "PENDING")) return s.finish(a, id, cmd_s, pct, "pending", try std.fmt.allocPrint(a, "{s} was sent and has not finished after 90 s; check later with car_status", .{what}), false);
        if (eql(out.status, "EXPIRED")) return s.finish(a, id, cmd_s, pct, "unknown", try std.fmt.allocPrint(a, "{s}: Smartcar gave up waiting for the car; whether it happened is unknown (check car_status)", .{what}), true);
        return s.finish(a, id, cmd_s, pct, "failed", try std.fmt.allocPrint(a, "{s} failed{s}{s}", .{ what, if (out.detail.len > 0) ": " else "", out.detail }), true);
    }

    /// Answers, and logs the call. `command` is what the agent asked for, as
    /// it asked (it may be no command at all).
    fn finish(s: *Server, a: Allocator, id: []const u8, command: []const u8, percent: ?f64, result: []const u8, message: []const u8, is_error: bool) !void {
        s.writeLog(a, command, percent, result, message) catch {};
        return s.text(a, id, message, is_error);
    }

    fn why(s: *Server, a: Allocator, e: anyerror) ![]const u8 {
        if (s.sc.problem) |p| return p.text(a);
        return std.fmt.allocPrint(a, "can't reach Smartcar: {s}", .{@errorName(e)});
    }

    fn writeLog(s: *Server, a: Allocator, command: []const u8, percent: ?f64, result: []const u8, message: []const u8) !void {
        const f = s.log orelse return;
        var tbuf: [20]u8 = undefined;
        const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_s));
        const line = try std.fmt.allocPrint(a, "{{\"time\":\"{s}\",\"vehicle\":{f},\"command\":{f},\"percent\":{?d},\"result\":\"{s}\",\"message\":{f}}}\n", .{ isoTime(&tbuf, now_s), std.json.fmt(s.cfg.vehicle_id, .{}), std.json.fmt(command, .{}), percent, result, std.json.fmt(message, .{}) });
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

pub fn run(gpa: Allocator, io: Io, cfg: *const config.Config, sc: *smartcar.Client) !void {
    var s = try Server.init(gpa, io, cfg, sc);
    defer s.deinit();
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var r = Io.File.stdin().reader(io, buf);
    while (r.interface.takeDelimiter('\n') catch return) |line| try s.handleLine(line);
}

fn toolsJson(gpa: Allocator, cfg: *const config.Config) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cmds: std.ArrayList(u8) = .empty;
    for (cfg.allow) |c| if (c != .unlock) {
        if (cmds.items.len > 0) try cmds.append(a, ',');
        try cmds.print(a, "\"{s}\"", .{@tagName(c)});
    };
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"tools\":[{\"name\":\"car_status\",\"description\":\"The car's battery, range, charging, charge limit, locks, odometer and (if allowed) location, with how old the data is: Smartcar collects it from the carmaker, often about once a day. Only reads.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"annotations\":{\"readOnlyHint\":true}}");
    if (cmds.items.len > 0) {
        const desc = try std.fmt.allocPrint(a, "Send the car one command its owner allowed, and wait (up to 90 s) for the car to confirm it. At most {d} commands in 24 hours, {d} s apart; charge_limit takes percent from {d} to {d}.", .{ cfg.per_day, cfg.min_between_s, cfg.limit_min, cfg.limit_max });
        try o.print(a, ",{{\"name\":\"car_command\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"command\":{{\"type\":\"string\",\"enum\":[{s}]}},\"percent\":{{\"type\":\"integer\"}}}},\"required\":[\"command\"]}}}}", .{ std.json.fmt(desc, .{}), cmds.items });
    }
    if (cfg.allows(.unlock)) {
        try o.appendSlice(a, ",{\"name\":\"car_unlock\",\"description\":\"Unlock the car. The owner should be asked every time, and told where the car is first.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"annotations\":{\"destructiveHint\":true},\"_meta\":{\"anthropic/requiresUserInteraction\":true}}");
    }
    try o.appendSlice(a, "]}");
    return gpa.dupe(u8, o.items);
}

fn allowList(a: Allocator, cfg: *const config.Config) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (cfg.allow, 0..) |c, i| {
        if (i > 0) try o.appendSlice(a, ", ");
        try o.appendSlice(a, @tagName(c));
    }
    if (o.items.len == 0) try o.appendSlice(a, "none");
    return o.items;
}

fn ageText(a: Allocator, s: f64) ![]u8 {
    if (s < 120) return a.dupe(u8, "data: from the last minutes");
    if (s < 7200) return std.fmt.allocPrint(a, "data: from {d:.0} minutes ago", .{s / 60});
    return std.fmt.allocPrint(a, "data: from {d:.1} hours ago (Smartcar collects it from the carmaker, often about once a day)", .{s / 3600});
}

fn yesNo(v: ?jv.Value) []const u8 {
    return if (jv.boolean(v)) |b| (if (b) "yes" else "no") else "?";
}

fn num(a: Allocator, v: ?jv.Value) []const u8 {
    const x = jv.num(v) orelse return "?";
    if (@abs(x - @round(x)) < 1e-9) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@round(x)))}) catch "?";
    return std.fmt.allocPrint(a, "{d:.1}", .{x}) catch "?";
}

fn numberArg(v: ?jv.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " %")) catch null,
        else => null,
    };
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

test "tools: unlock only when allowed, the list on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: config.Diag = .{};
    const plain = try config.parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = charge_start, lock\n", &d);
    const j = try toolsJson(std.testing.allocator, &plain);
    defer std.testing.allocator.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "car_unlock") == null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"enum\":[\"charge_start\",\"lock\"]") != null);
    const with = try config.parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = unlock\n", &d);
    const j2 = try toolsJson(std.testing.allocator, &with);
    defer std.testing.allocator.free(j2);
    try std.testing.expect(std.mem.indexOf(u8, j2, "car_unlock") != null);
    try std.testing.expect(std.mem.indexOf(u8, j2, "car_command") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, j2, '\n') == null);
}
