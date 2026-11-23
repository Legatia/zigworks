//! The MCP server: car_status reads, car_command sends one of the commands
//! the car file allows (within its limits: how many a day, how often, which
//! charge limits), and car_unlock exists only when the file allows
//! unlocking, as a tool of its own that asks for a person every time. With
//! a Tesla, car_climate and car_seat_heat too, each only when the file
//! allows it, within its limits, read back from the car.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const smartcar = @import("smartcar.zig");
const tesla = @import("tesla.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");

/// The carmaker's cloud the car is reached through.
pub const Car = union(config.Backend) {
    smartcar: *smartcar.Client,
    tesla: *tesla.Client,
};

const versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    car: Car,
    tools_json: []u8,
    /// when commands were sent, for the limits
    sent: std.ArrayList(i128) = .empty,
    /// when car_status woke the car, for wakes_per_day
    wakes: std.ArrayList(i128) = .empty,
    log: ?Io.File = null,
    log_offset: u64 = 0,
    captured: ?*std.ArrayList(u8) = null,

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, car: Car) !Server {
        var s: Server = .{ .gpa = gpa, .io = io, .cfg = cfg, .car = car, .tools_json = try toolsJson(gpa, cfg) };
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
        s.wakes.deinit(s.gpa);
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
            const instructions = switch (s.car) {
                .smartcar => try std.fmt.allocPrint(a, "carcloud reads {s} through Smartcar and sends it the few commands its owner allowed. Data can be hours old: Smartcar collects it from the carmaker, often about once a day.", .{s.cfg.name}),
                .tesla => try std.fmt.allocPrint(a, "carcloud reads {s} through Tesla's Fleet API and sends it the few commands its owner allowed, signed, read back from the car. A sleeping car answers nothing until woken: car_status wakes it only when asked (wake), a few times a day, as each wake costs.", .{s.cfg.name}),
            };
            return s.reply(a, id, try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"carcloud\",\"version\":\"{s}\"}},\"instructions\":{f}}}", .{ version, build_options.version, std.json.fmt(instructions, .{}) }));
        }
        if (eql(method, "ping")) return s.reply(a, id, "{}");
        if (eql(method, "tools/list")) return s.reply(a, id, s.tools_json);
        if (eql(method, "tools/call")) {
            const name = jv.str(jv.at(v, &.{ "params", "name" })) orelse return s.text(a, id, "no tool name", true);
            const args = jv.at(v, &.{ "params", "arguments" });
            if (eql(name, "car_status")) return switch (s.car) {
                .smartcar => s.statusTool(a, id),
                .tesla => |tc| s.teslaStatus(a, id, tc, args),
            };
            if (eql(name, "car_command")) return s.commandTool(a, id, args, false);
            if (eql(name, "car_unlock") and s.cfg.allows(.unlock)) return s.commandTool(a, id, args, true);
            if (s.car == .tesla and eql(name, "car_climate") and s.cfg.climate) return s.climateTool(a, id, s.car.tesla, args);
            if (s.car == .tesla and eql(name, "car_seat_heat") and s.cfg.seat_heat) return s.seatTool(a, id, s.car.tesla, args);
            return s.text(a, id, try std.fmt.allocPrint(a, "no tool called {s}", .{name}), true);
        }
        return s.send(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id}));
    }

    fn statusTool(s: *Server, a: Allocator, id: []const u8) !void {
        const list = s.car.smartcar.signals(a) catch |e| return s.text(a, id, try s.why(a, e), true);
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
        if (try s.admit(a)) |no| return s.finish(a, id, cmd_s, pct, "refused", no, true);
        const sc = switch (s.car) {
            .smartcar => |x| x,
            .tesla => |tc| return s.teslaCommand(a, id, tc, cmd, percent),
        };
        const out = sc.command(a, cmd, percent) catch |e| return s.finish(a, id, cmd_s, pct, "failed", try s.why(a, e), true);
        const what = if (cmd == .charge_limit) try std.fmt.allocPrint(a, "charge limit {d}%", .{percent.?}) else cmd_s;
        if (eql(out.status, "SUCCESS")) return s.finish(a, id, cmd_s, pct, "done", try std.fmt.allocPrint(a, "done: {s}, confirmed by the car", .{what}), false);
        if (eql(out.status, "PENDING")) return s.finish(a, id, cmd_s, pct, "pending", try std.fmt.allocPrint(a, "{s} was sent and has not finished after 90 s; check later with car_status", .{what}), false);
        if (eql(out.status, "EXPIRED")) return s.finish(a, id, cmd_s, pct, "unknown", try std.fmt.allocPrint(a, "{s}: Smartcar gave up waiting for the car; whether it happened is unknown (check car_status)", .{what}), true);
        return s.finish(a, id, cmd_s, pct, "failed", try std.fmt.allocPrint(a, "{s} failed{s}{s}", .{ what, if (out.detail.len > 0) ": " else "", out.detail }), true);
    }

    /// The owner's limits on how many commands and how often: why not, or
    /// null (then the command counts from now).
    fn admit(s: *Server, a: Allocator) !?[]const u8 {
        const now = sock.nowNs(s.io);
        prune(&s.sent, now);
        if (s.sent.items.len >= s.cfg.per_day) return try std.fmt.allocPrint(a, "not sent: {d} commands in the last 24 hours is the limit", .{s.cfg.per_day});
        if (s.sent.items.len > 0) {
            const since = @divTrunc(now - s.sent.items[s.sent.items.len - 1], std.time.ns_per_s);
            if (since < s.cfg.min_between_s) return try std.fmt.allocPrint(a, "not sent: wait {d} s more (at least {d} s between commands)", .{ @as(i128, s.cfg.min_between_s) - since, s.cfg.min_between_s });
        }
        try s.sent.append(s.gpa, now);
        return null;
    }

    /// Answers, and logs the call. `command` is what the agent asked for, as
    /// it asked (it may be no command at all).
    fn finish(s: *Server, a: Allocator, id: []const u8, command: []const u8, percent: ?f64, result: []const u8, message: []const u8, is_error: bool) !void {
        return s.finishWith(a, id, command, percent, "", result, message, is_error);
    }

    /// `finish`, the log line carrying `extra` (`,"key":value` JSON) too.
    fn finishWith(s: *Server, a: Allocator, id: []const u8, command: []const u8, percent: ?f64, extra: []const u8, result: []const u8, message: []const u8, is_error: bool) !void {
        s.writeLog(a, command, percent, extra, result, message) catch {};
        return s.text(a, id, message, is_error);
    }

    fn why(s: *Server, a: Allocator, e: anyerror) ![]const u8 {
        switch (s.car) {
            .smartcar => |sc| {
                if (sc.problem) |p| return p.text(a);
                return std.fmt.allocPrint(a, "can't reach Smartcar: {s}", .{@errorName(e)});
            },
            .tesla => |tc| {
                if (tc.problem) |p| return p;
                return std.fmt.allocPrint(a, "can't reach Tesla: {s}", .{@errorName(e)});
            },
        }
    }

    fn writeLog(s: *Server, a: Allocator, command: []const u8, percent: ?f64, extra: []const u8, result: []const u8, message: []const u8) !void {
        const f = s.log orelse return;
        var tbuf: [20]u8 = undefined;
        const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_s));
        const vehicle = if (s.car == .tesla) s.cfg.vin else s.cfg.vehicle_id;
        const line = try std.fmt.allocPrint(a, "{{\"time\":\"{s}\",\"vehicle\":{f},\"command\":{f},\"percent\":{?d},\"result\":\"{s}\",\"message\":{f}{s}}}\n", .{ isoTime(&tbuf, now_s), std.json.fmt(vehicle, .{}), std.json.fmt(command, .{}), percent, result, std.json.fmt(message, .{}), extra });
        try f.writePositionalAll(s.io, line, s.log_offset);
        s.log_offset += line.len;
    }

    // ---- Tesla ----

    /// What car_status says of a car that sleeps (or can't be reached).
    fn asleepText(s: *Server, a: Allocator, state: []const u8) ![]const u8 {
        prune(&s.wakes, sock.nowNs(s.io));
        const left = s.cfg.wakes_per_day -| @as(u32, @intCast(s.wakes.items.len));
        const what = if (eql(state, "offline")) "offline: yes; the car can't be reached now" else "asleep: yes; reading it would wake it";
        return std.fmt.allocPrint(a, "{s}:\n{s} (car_status with wake true wakes it; {d} of {d} wakes left in 24 hours)\ncommands the owner allowed: {s}", .{ s.cfg.name, what, left, s.cfg.wakes_per_day, try allowList(a, s.cfg) });
    }

    fn teslaStatus(s: *Server, a: Allocator, id: []const u8, tc: *tesla.Client, args: ?jv.Value) !void {
        if (unknownField(args, &.{"wake"})) |f| return s.text(a, id, try std.fmt.allocPrint(a, "car_status has no field {s}: it takes wake (true or false)", .{f}), true);
        const want_wake = jv.boolean(jv.get(args, "wake")) orelse false;
        const state = tc.state(a) catch |e| return s.text(a, id, try s.why(a, e), true);
        var woke = false;
        if (!eql(state, "online")) {
            if (!want_wake) return s.text(a, id, try s.asleepText(a, state), false);
            const now = sock.nowNs(s.io);
            prune(&s.wakes, now);
            if (s.wakes.items.len >= s.cfg.wakes_per_day) {
                const no = try std.fmt.allocPrint(a, "not woken: {d} wakes in the last 24 hours is the limit (wakes_per_day)", .{s.cfg.wakes_per_day});
                s.writeLog(a, "wake", null, "", "refused", no) catch {};
                return s.text(a, id, try std.fmt.allocPrint(a, "{s}\n{s}", .{ no, try s.asleepText(a, state) }), true);
            }
            try s.wakes.append(s.gpa, now);
            const ok = tc.wake(a) catch |e| {
                const why_s = try s.why(a, e);
                s.writeLog(a, "wake", null, "", "failed", why_s) catch {};
                return s.text(a, id, why_s, true);
            };
            if (!ok) {
                const no = try std.fmt.allocPrint(a, "the car didn't wake within {d} s", .{tc.wake_wait_s});
                s.writeLog(a, "wake", null, "", "failed", no) catch {};
                return s.text(a, id, no, true);
            }
            s.writeLog(a, "wake", null, "", "done", "woken to be read") catch {};
            woke = true;
        }
        const d = tc.vehicleData(a) catch |e| switch (e) {
            error.Asleep => return s.text(a, id, try s.asleepText(a, "asleep"), false),
            else => return s.text(a, id, try s.why(a, e), true),
        };
        var o: std.ArrayList(u8) = .empty;
        try o.appendSlice(a, try tesla.statusLines(a, s.cfg, d, nowMs(s.io)));
        if (woke) try o.print(a, "woken for this read ({d} of {d} wakes left in 24 hours)\n", .{ s.cfg.wakes_per_day -| @as(u32, @intCast(s.wakes.items.len)), s.cfg.wakes_per_day });
        try o.print(a, "commands the owner allowed: {s}", .{try allowList(a, s.cfg)});
        return s.text(a, id, o.items, false);
    }

    /// One Fleet API command and its JSON body.
    const Step = struct { name: []const u8, body: []const u8 = "{}" };

    /// Wakes the car when it sleeps, then sends `steps` in order through
    /// the signing proxy; why not, or null when the car said yes to each.
    fn teslaSend(s: *Server, a: Allocator, tc: *tesla.Client, steps: []const Step) !?[]const u8 {
        const state = tc.state(a) catch |e| return try s.why(a, e);
        if (!eql(state, "online")) {
            const ok = tc.wake(a) catch |e| return try s.why(a, e);
            if (!ok) return try std.fmt.allocPrint(a, "the car didn't wake within {d} s; nothing was sent", .{tc.wake_wait_s});
        }
        for (steps) |st| {
            const sent = tc.send(a, st.name, st.body) catch |e| return try s.why(a, e);
            if (!sent.ok) return try std.fmt.allocPrint(a, "the car said no{s}{s}", .{ if (sent.reason.len > 0) ": " else "", sent.reason });
        }
        return null;
    }

    fn teslaCommand(s: *Server, a: Allocator, id: []const u8, tc: *tesla.Client, cmd: config.Command, percent: ?u8) !void {
        const cmd_s = @tagName(cmd);
        const pct: ?f64 = if (percent) |p| @floatFromInt(p) else null;
        const body: []const u8 = if (cmd == .charge_limit) try std.fmt.allocPrint(a, "{{\"percent\":{d}}}", .{percent.?}) else "{}";
        if (try s.teslaSend(a, tc, &.{.{ .name = cmd.teslaName(), .body = body }})) |no| return s.finish(a, id, cmd_s, pct, "failed", no, true);
        const what = if (cmd == .charge_limit) try std.fmt.allocPrint(a, "charge limit {d}%", .{percent.?}) else cmd_s;
        // read back: what the car reports now
        const reads: []const u8 = if (tc.vehicleData(a)) |d| blk: {
            const ch = jv.get(d, "charge_state");
            const cs = jv.str(jv.get(ch, "charging_state")) orelse "";
            const charging = eql(cs, "Charging") or eql(cs, "Starting");
            break :blk switch (cmd) {
                .charge_start => if (charging) "it reads charging" else "it doesn't read charging yet",
                .charge_stop => if (charging) "it still reads charging" else "it reads not charging",
                .charge_limit => try std.fmt.allocPrint(a, "it reads {s}%", .{tesla.num(a, jv.get(ch, "charge_limit_soc"))}),
                .lock, .unlock => if (jv.boolean(jv.get(jv.get(d, "vehicle_state"), "locked"))) |l| (if (l) "it reads locked" else "it reads unlocked") else "",
            };
        } else |_| "";
        return s.finish(a, id, cmd_s, pct, "done", try std.fmt.allocPrint(a, "done: {s}, confirmed by the car{s}{s}{s}", .{ what, if (reads.len > 0) " (" else "", reads, if (reads.len > 0) ")" else "" }), false);
    }

    fn climateTool(s: *Server, a: Allocator, id: []const u8, tc: *tesla.Client, args: ?jv.Value) !void {
        const cmd = "climate";
        if (unknownField(args, &.{ "state", "temperature" })) |f| return s.finish(a, id, cmd, null, "refused", try std.fmt.allocPrint(a, "car_climate has no field {s}: it takes state (on or off) and temperature (°C)", .{f}), true);
        const state_s = jv.str(jv.get(args, "state"));
        const temp_v = jv.get(args, "temperature");
        var extra: std.ArrayList(u8) = .empty;
        if (state_s) |x| try extra.print(a, ",\"state\":{f}", .{std.json.fmt(x, .{})});
        if (temp_v) |x| try extra.print(a, ",\"temperature\":{s}", .{try std.json.Stringify.valueAlloc(a, x, .{})});
        if (state_s == null and temp_v == null) return s.finishWith(a, id, cmd, null, extra.items, "refused", "say state (on or off), temperature (°C), or both", true);
        var on: ?bool = null;
        if (state_s) |x| {
            if (eql(x, "on")) on = true else if (eql(x, "off")) on = false else return s.finishWith(a, id, cmd, null, extra.items, "refused", "state is on or off", true);
        }
        var temp: ?f64 = null;
        if (temp_v != null) {
            const t = numberArg(temp_v) orelse return s.finishWith(a, id, cmd, null, extra.items, "refused", "temperature is a number, °C", true);
            if (on != null and !on.?) return s.finishWith(a, id, cmd, null, extra.items, "refused", "climate off takes no temperature", true);
            if (t < s.cfg.temp_min or t > s.cfg.temp_max) return s.finishWith(a, id, cmd, null, extra.items, "refused", try std.fmt.allocPrint(a, "the temperature must be from {s} to {s} °C", .{ tesla.num(a, .{ .float = s.cfg.temp_min }), tesla.num(a, .{ .float = s.cfg.temp_max }) }), true);
            // Tesla takes half degrees
            temp = @round(t * 2) / 2;
        }
        if (try s.admit(a)) |no| return s.finishWith(a, id, cmd, null, extra.items, "refused", no, true);
        var steps: std.ArrayList(Step) = .empty;
        if (temp) |t| try steps.append(a, .{ .name = "set_temps", .body = try std.fmt.allocPrint(a, "{{\"driver_temp\":{d},\"passenger_temp\":{d}}}", .{ t, t }) });
        if (on) |o| try steps.append(a, .{ .name = if (o) "auto_conditioning_start" else "auto_conditioning_stop" });
        if (try s.teslaSend(a, tc, steps.items)) |no| return s.finishWith(a, id, cmd, null, extra.items, "failed", no, true);
        const d = tc.vehicleData(a) catch return s.finishWith(a, id, cmd, null, extra.items, "done", "The car accepted it; reading it back failed (check with car_status).", false);
        return s.finishWith(a, id, cmd, null, extra.items, "done", try tesla.climateReadBack(a, d, on, temp), false);
    }

    fn seatTool(s: *Server, a: Allocator, id: []const u8, tc: *tesla.Client, args: ?jv.Value) !void {
        const cmd = "seat_heat";
        if (unknownField(args, &.{ "seat", "level" })) |f| return s.finish(a, id, cmd, null, "refused", try std.fmt.allocPrint(a, "car_seat_heat has no field {s}: it takes seat and level", .{f}), true);
        const seat_s = jv.str(jv.get(args, "seat")) orelse "";
        var extra: std.ArrayList(u8) = .empty;
        try extra.print(a, ",\"seat\":{f}", .{std.json.fmt(seat_s, .{})});
        const seat = std.meta.stringToEnum(tesla.Seat, seat_s) orelse return s.finishWith(a, id, cmd, null, extra.items, "refused", "seat is front_left, front_right, rear_left, rear_center or rear_right", true);
        const lv = numberArg(jv.get(args, "level")) orelse return s.finishWith(a, id, cmd, null, extra.items, "refused", "level is 0 (off) to 3", true);
        if (lv < 0 or lv > 3 or lv != @round(lv)) return s.finishWith(a, id, cmd, null, extra.items, "refused", "level is 0 (off) to 3", true);
        const level: u8 = @intFromFloat(lv);
        try extra.print(a, ",\"level\":{d}", .{level});
        if (try s.admit(a)) |no| return s.finishWith(a, id, cmd, null, extra.items, "refused", no, true);
        const body = try std.fmt.allocPrint(a, "{{\"heater\":{d},\"level\":{d}}}", .{ seat.heater(), level });
        if (try s.teslaSend(a, tc, &.{.{ .name = "remote_seat_heater_request", .body = body }})) |no| return s.finishWith(a, id, cmd, null, extra.items, "failed", no, true);
        const d = tc.vehicleData(a) catch return s.finishWith(a, id, cmd, null, extra.items, "done", "The car accepted it; reading it back failed (check with car_status).", false);
        return s.finishWith(a, id, cmd, null, extra.items, "done", try tesla.seatReadBack(a, d, seat, level), false);
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

pub fn run(gpa: Allocator, io: Io, cfg: *const config.Config, car: Car) !void {
    var s = try Server.init(gpa, io, cfg, car);
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
    const tesla_car = cfg.backend == .tesla;
    if (tesla_car) {
        try o.print(a, "{{\"tools\":[{{\"name\":\"car_status\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"wake\":{{\"type\":\"boolean\"}}}}}},\"annotations\":{{\"readOnlyHint\":true}}}}", .{std.json.fmt(try std.fmt.allocPrint(a, "The car's battery, range, charging, charge limit, locks, odometer, inside and outside temperature, climate and (if allowed) location, read live from Tesla. A sleeping car answers only that it sleeps: wake true wakes it first (at most {d} times in 24 hours: each wake costs). Only reads.", .{cfg.wakes_per_day}), .{})});
    } else try o.appendSlice(a, "{\"tools\":[{\"name\":\"car_status\",\"description\":\"The car's battery, range, charging, charge limit, locks, odometer and (if allowed) location, with how old the data is: Smartcar collects it from the carmaker, often about once a day. Only reads.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"annotations\":{\"readOnlyHint\":true}}");
    if (cmds.items.len > 0) {
        const desc = if (tesla_car)
            try std.fmt.allocPrint(a, "Send the car one command its owner allowed (waking it first if it sleeps), signed, and wait for the car's own answer. At most {d} commands in 24 hours, {d} s apart; charge_limit takes percent from {d} to {d}.", .{ cfg.per_day, cfg.min_between_s, cfg.limit_min, cfg.limit_max })
        else
            try std.fmt.allocPrint(a, "Send the car one command its owner allowed, and wait (up to 90 s) for the car to confirm it. At most {d} commands in 24 hours, {d} s apart; charge_limit takes percent from {d} to {d}.", .{ cfg.per_day, cfg.min_between_s, cfg.limit_min, cfg.limit_max });
        try o.print(a, ",{{\"name\":\"car_command\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"command\":{{\"type\":\"string\",\"enum\":[{s}]}},\"percent\":{{\"type\":\"integer\"}}}},\"required\":[\"command\"]}}}}", .{ std.json.fmt(desc, .{}), cmds.items });
    }
    if (tesla_car and cfg.climate) {
        const lo = tesla.num(a, .{ .float = cfg.temp_min });
        const hi = tesla.num(a, .{ .float = cfg.temp_max });
        const desc = try std.fmt.allocPrint(a, "Turn the car's climate on or off, or set its temperature (°C, from {s} to {s}), or both; the car is woken first if it sleeps. One of the {d} commands in 24 hours, {d} s apart. Answers with what the car reads back.", .{ lo, hi, cfg.per_day, cfg.min_between_s });
        try o.print(a, ",{{\"name\":\"car_climate\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"state\":{{\"type\":\"string\",\"enum\":[\"on\",\"off\"]}},\"temperature\":{{\"type\":\"number\",\"minimum\":{s},\"maximum\":{s}}}}}}}}}", .{ std.json.fmt(desc, .{}), lo, hi });
    }
    if (tesla_car and cfg.seat_heat) {
        const desc = try std.fmt.allocPrint(a, "Set one seat's heating, level 0 (off) to 3; front_left is the driver's in a left-hand-drive car. The car is woken first if it sleeps. One of the {d} commands in 24 hours, {d} s apart. Answers with what the car reads back.", .{ cfg.per_day, cfg.min_between_s });
        try o.print(a, ",{{\"name\":\"car_seat_heat\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"seat\":{{\"type\":\"string\",\"enum\":[\"front_left\",\"front_right\",\"rear_left\",\"rear_center\",\"rear_right\"]}},\"level\":{{\"type\":\"integer\",\"minimum\":0,\"maximum\":3}}}},\"required\":[\"seat\",\"level\"]}}}}", .{std.json.fmt(desc, .{})});
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
    if (cfg.climate) try o.print(a, "{s}climate", .{if (o.items.len > 0) ", " else ""});
    if (cfg.seat_heat) try o.print(a, "{s}seat_heat", .{if (o.items.len > 0) ", " else ""});
    if (o.items.len == 0) try o.appendSlice(a, "none");
    return o.items;
}

/// Drops the times older than 24 hours.
fn prune(list: *std.ArrayList(i128), now: i128) void {
    var i: usize = list.items.len;
    while (i > 0) {
        i -= 1;
        if (now - list.items[i] > 24 * std.time.ns_per_hour) _ = list.orderedRemove(i);
    }
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// The first key of `args` that isn't one of `known`; null when all are
/// (or there are none). A misspelt field is refused, never ignored.
fn unknownField(args: ?jv.Value, known: []const []const u8) ?[]const u8 {
    const v = args orelse return null;
    if (v == .null) return null;
    if (v != .object) return "(not an object)";
    var it = v.object.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        for (known) |x| {
            if (eql(k, x)) break;
        } else return k;
    }
    return null;
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

test "tesla_tools_follow_the_allow_list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: config.Diag = .{};
    const head = "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\ncommand_api = https://localhost:4443\n";
    const Names = struct {
        fn of(al: Allocator, j: []const u8) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (jv.arr(jv.get(jv.parse(al, j), "tools")).?) |x| try out.print(al, "{s} ", .{jv.str(jv.get(x, "name")).?});
            return out.items;
        }
    };
    const none = try config.parse(a, head, &d);
    const j0 = try toolsJson(a, &none);
    try std.testing.expectEqualStrings("car_status ", try Names.of(a, j0));
    // car_status may be asked to wake the car
    try std.testing.expect(std.mem.indexOf(u8, j0, "\"wake\":{\"type\":\"boolean\"}") != null);
    const climate = try config.parse(a, head ++ "allow = climate\nclimate_temp = 19 23\n", &d);
    const j1 = try toolsJson(a, &climate);
    try std.testing.expectEqualStrings("car_status car_climate ", try Names.of(a, j1));
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"state\":{\"type\":\"string\",\"enum\":[\"on\",\"off\"]},\"temperature\":{\"type\":\"number\",\"minimum\":19,\"maximum\":23}") != null);
    const all = try config.parse(a, head ++ "allow = charge_start, climate, seat_heat, unlock\n", &d);
    const j2 = try toolsJson(a, &all);
    try std.testing.expectEqualStrings("car_status car_command car_climate car_seat_heat car_unlock ", try Names.of(a, j2));
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"enum\":[\"charge_start\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"seat\":{\"type\":\"string\",\"enum\":[\"front_left\",\"front_right\",\"rear_left\",\"rear_center\",\"rear_right\"]}") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, j2, '\n') == null);
}

test "unknown_fields_are_named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(unknownField(jv.parse(a, "{\"state\":\"on\",\"temperature\":21}"), &.{ "state", "temperature" }) == null);
    try std.testing.expect(unknownField(null, &.{"state"}) == null);
    try std.testing.expectEqualStrings("temp", unknownField(jv.parse(a, "{\"state\":\"on\",\"temp\":21}"), &.{ "state", "temperature" }).?);
    try std.testing.expectEqualStrings("(not an object)", unknownField(jv.parse(a, "[1]"), &.{"state"}).?);
}
