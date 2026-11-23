//! carcloud-sim: a stand-in for Smartcar's v3 API with one made-up
//! electric car, for trying carcloud without a Smartcar account. Built from
//! Smartcar's documentation, not from Smartcar itself.
//!   POST /oauth2/token                     client credentials, as a form
//!   GET  /v3/vehicles/{id}/signals         needs sc-user-id
//!   POST /v3/vehicles/{id}/commands/...    charge/start, charge/stop,
//!                                          charge/set-limit, security/lock, security/unlock
//!   GET  /v3/command-executions/{id}
//!   POST /sim/state  {"plugged","soc","asleep","commands_left","locked"}   (tests)
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sock = @import("sock.zig");
const jv = @import("jv.zig");
const server = @import("server.zig");

pub const vehicle_id = "0c5f52b4-6a39-4a66-b2bd-6fdc1a5c8b11";
pub const user_id = "5a2b7c1e-sim-user";
pub const client_id = "sim-client";

const Exec = struct { id: [27]u8, kind: []const u8, done_ns: i128, apply: enum { lock, unlock } };

const Car = struct {
    soc: f64 = 64,
    plugged: bool = true,
    charging: bool = false,
    limit: u8 = 80,
    locked: bool = true,
    odometer: f64 = 18234.6,
    cabin: f64 = 14.5,
    asleep: bool = false,
    commands_left: i64 = 100,
    /// when the carmaker last reported, seconds since the epoch
    reported_s: i64 = 0,
};

const Sim = struct {
    gpa: Allocator,
    io: Io,
    secret: []const u8,
    lock: Io.Mutex = .init,
    car: Car = .{},
    tokens: std.ArrayList([]u8) = .empty,
    execs: std.ArrayList(Exec) = .empty,
    next_exec: u32 = 1,
};

pub fn run(gpa: Allocator, io: Io, port: u16, secret: []const u8) !void {
    const l = try sock.Listener.open(port);
    defer l.close();
    const s = try gpa.create(Sim);
    s.* = .{ .gpa = gpa, .io = io, .secret = secret };
    s.car.reported_s = nowS(io) - 30 * 60; // the carmaker's last report: half an hour ago
    const th = try std.Thread.spawn(.{}, charger, .{s});
    th.detach();
    std.log.info("Smartcar stand-in on 127.0.0.1:{d}", .{l.port});
    while (true) {
        const conn = l.accept() catch continue;
        const t = std.Thread.spawn(.{}, serve, .{ s, conn }) catch {
            sock.closeHandle(conn);
            continue;
        };
        t.detach();
    }
}

fn nowS(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

/// Charging adds a percent every two seconds, up to the limit.
fn charger(s: *Sim) void {
    while (true) {
        s.io.sleep(.fromMilliseconds(2000), .awake) catch {};
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const c = &s.car;
        if (!c.charging) continue;
        if (!c.plugged or c.soc >= @as(f64, @floatFromInt(c.limit))) {
            c.charging = false;
            continue;
        }
        c.soc += 1;
        c.reported_s = nowS(s.io);
    }
}

fn serve(s: *Sim, conn: sock.Handle) void {
    defer sock.closeHandle(conn);
    var rbuf: [32 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(s.io, conn, &rbuf, &wbuf, 60_000);
    var hs = std.http.Server.init(&sk.reader, &sk.writer);
    while (true) {
        var req = hs.receiveHead() catch return;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        handle(s, arena_state.allocator(), &req) catch return;
    }
}

fn handle(s: *Sim, a: Allocator, req: *std.http.Server.Request) !void {
    const target = try a.dupe(u8, req.head.target);
    const method = req.head.method;
    var auth: []const u8 = "";
    var user: []const u8 = "";
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = try a.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "sc-user-id")) user = try a.dupe(u8, h.value);
    }
    var body_buf: [8192]u8 = undefined;
    const body = try (try req.readerExpectContinue(&body_buf)).allocRemaining(a, .limited(1 << 20));
    const route = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);

    if (method == .POST and std.mem.eql(u8, route, "/oauth2/token")) {
        if (!std.mem.eql(u8, formValue(body, "grant_type") orelse "", "client_credentials")) return json(req, .bad_request, "{\"error\":\"invalid_request\"}");
        if (!std.mem.eql(u8, formValue(body, "client_id") orelse "", client_id) or !std.mem.eql(u8, try unescape(a, formValue(body, "client_secret") orelse ""), s.secret))
            return json(req, .unauthorized, "{\"error\":\"invalid_client\"}");
        var rnd: [8]u8 = undefined;
        s.io.randomSecure(&rnd) catch {};
        const tok = try std.fmt.allocPrint(s.gpa, "sim-{x}", .{std.mem.readInt(u64, &rnd, .little)});
        try s.tokens.append(s.gpa, tok);
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":3600}}", .{tok}));
    }
    if (method == .POST and std.mem.eql(u8, route, "/sim/state")) {
        const v = jv.parse(a, body) orelse return json(req, .bad_request, "{}");
        if (jv.boolean(jv.get(v, "plugged"))) |x| s.car.plugged = x;
        if (jv.boolean(jv.get(v, "asleep"))) |x| s.car.asleep = x;
        if (jv.boolean(jv.get(v, "locked"))) |x| s.car.locked = x;
        if (jv.num(jv.get(v, "soc"))) |x| s.car.soc = x;
        if (jv.int(jv.get(v, "commands_left"))) |x| s.car.commands_left = x;
        return json(req, .ok, "{}");
    }

    // everything else needs a token we gave out
    const tok = if (std.mem.startsWith(u8, auth, "Bearer ")) auth[7..] else "";
    const known = for (s.tokens.items) |x| {
        if (std.mem.eql(u8, x, tok)) break true;
    } else false;
    if (!known) return problem(req, a, .unauthorized, "AUTHENTICATION", "UNAUTHORIZED", "Unauthorized", "The access token is missing or not valid.");

    if (method == .GET and std.mem.startsWith(u8, route, "/v3/command-executions/")) {
        const id = route["/v3/command-executions/".len..];
        for (s.execs.items) |*e| if (std.mem.eql(u8, &e.id, id)) {
            return json(req, .ok, try execJson(s, a, e));
        };
        return problem(req, a, .not_found, "RESOURCE_NOT_FOUND", "", "Not found", "No such command execution.");
    }
    const vprefix = "/v3/vehicles/" ++ vehicle_id;
    if (!std.mem.startsWith(u8, route, "/v3/vehicles/")) return problem(req, a, .not_found, "RESOURCE_NOT_FOUND", "", "Not found", "");
    if (!std.mem.startsWith(u8, route, vprefix)) return problem(req, a, .not_found, "RESOURCE_NOT_FOUND", "", "Vehicle not found", "No vehicle with this id.");
    if (!std.mem.eql(u8, user, user_id)) return problem(req, a, .forbidden, "AUTHENTICATION", "ACCESS_DENIED", "Access denied", "sc-user-id does not own this vehicle.");
    const rest = route[vprefix.len..];
    if (method == .GET and std.mem.eql(u8, rest, "/signals")) return json(req, .ok, try signalsJson(s, a));
    if (method == .POST and std.mem.startsWith(u8, rest, "/commands/")) {
        const cmd = rest["/commands/".len..];
        if (s.car.commands_left <= 0) return problem(req, a, @enumFromInt(430), "BILLING", "VEHICLE_REQUEST_LIMIT", "Request limit reached", "This vehicle has used its requests for the month.");
        if (s.car.asleep) return problem(req, a, .conflict, "VEHICLE_STATE", "ASLEEP", "Vehicle Asleep", "The vehicle is asleep and did not wake up.");
        s.car.commands_left -= 1;
        const c = &s.car;
        if (std.mem.eql(u8, cmd, "charge/start")) {
            if (!c.plugged) return problem(req, a, .conflict, "VEHICLE_STATE", "CHARGING_PLUG_NOT_CONNECTED", "Charging plug not connected", "Plug the car in first.");
            c.charging = true;
            return json(req, .ok, try doneJson(s, a, "charge-start"));
        }
        if (std.mem.eql(u8, cmd, "charge/stop")) {
            c.charging = false;
            return json(req, .ok, try doneJson(s, a, "charge-stop"));
        }
        if (std.mem.eql(u8, cmd, "charge/set-limit")) {
            const pct = jv.int(jv.at(jv.parse(a, body), &.{ "data", "attributes", "percent" })) orelse return problem(req, a, .bad_request, "VALIDATION", "", "Invalid body", "data.attributes.percent is required.");
            if (pct < 50 or pct > 100) return problem(req, a, .bad_request, "VALIDATION", "", "Invalid percent", "percent must be from 50 to 100.");
            c.limit = @intCast(pct);
            c.reported_s = nowS(s.io);
            return json(req, .ok, try doneJson(s, a, "charge-set-limit"));
        }
        if (std.mem.eql(u8, cmd, "security/lock") or std.mem.eql(u8, cmd, "security/unlock")) {
            // locks take a moment: answered at once with PENDING, done 2 s later
            const lock = std.mem.eql(u8, cmd, "security/lock");
            var e: Exec = .{ .id = undefined, .kind = if (lock) "security-lock" else "security-unlock", .done_ns = sock.nowNs(s.io) + 2 * std.time.ns_per_s, .apply = if (lock) .lock else .unlock };
            _ = try std.fmt.bufPrint(&e.id, "exec_{d:0>22}", .{s.next_exec});
            s.next_exec += 1;
            try s.execs.append(s.gpa, e);
            return req.respond(try execJson(s, a, &s.execs.items[s.execs.items.len - 1]), .{ .status = .accepted, .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "location", .value = try std.fmt.allocPrint(a, "/v3/command-executions/{s}", .{e.id}) },
                .{ .name = "retry-after", .value = "2" },
            } });
        }
        return problem(req, a, .not_implemented, "COMPATIBILITY", "SMARTCAR_NOT_CAPABLE", "Not capable", "This command is not offered for this vehicle.");
    }
    return problem(req, a, .not_found, "RESOURCE_NOT_FOUND", "", "Not found", "");
}

fn execJson(s: *Sim, a: Allocator, e: *Exec) ![]u8 {
    const done = sock.nowNs(s.io) >= e.done_ns;
    if (done) {
        s.car.locked = e.apply == .lock;
        s.car.reported_s = nowS(s.io);
    }
    return std.fmt.allocPrint(a, "{{\"data\":{{\"id\":\"{s}\",\"type\":\"command-execution\",\"attributes\":{{\"commandType\":\"{s}\",\"status\":{{\"value\":\"{s}\"}},\"executionMode\":\"async\",\"userId\":\"{s}\",\"vehicleId\":\"{s}\"}}}}}}", .{ e.id, e.kind, if (done) "SUCCESS" else "PENDING", user_id, vehicle_id });
}

fn doneJson(s: *Sim, a: Allocator, kind: []const u8) ![]u8 {
    const n = s.next_exec;
    s.next_exec += 1;
    return std.fmt.allocPrint(a, "{{\"data\":{{\"id\":\"exec_{d:0>22}\",\"type\":\"command-execution\",\"attributes\":{{\"commandType\":\"{s}\",\"status\":{{\"value\":\"SUCCESS\"}},\"executionMode\":\"sync\",\"userId\":\"{s}\",\"vehicleId\":\"{s}\"}}}}}}", .{ n, kind, user_id, vehicle_id });
}

fn signalsJson(s: *Sim, a: Allocator) ![]u8 {
    const c = s.car;
    var tbuf: [20]u8 = undefined;
    var rbuf: [20]u8 = undefined;
    const when = server.isoTime(&tbuf, c.reported_s);
    const now = server.isoTime(&rbuf, nowS(s.io));
    const Sig = struct { code: []const u8, body: []const u8 };
    const sigs = [_]Sig{
        .{ .code = "tractionbattery-stateofcharge", .body = try std.fmt.allocPrint(a, "{{\"value\":{d},\"unit\":\"percent\"}}", .{c.soc}) },
        .{ .code = "tractionbattery-range", .body = try std.fmt.allocPrint(a, "{{\"value\":{d:.1},\"type\":\"DEFAULT\",\"unit\":\"km\"}}", .{c.soc * 4.6}) },
        .{ .code = "charge-ischarging", .body = try std.fmt.allocPrint(a, "{{\"value\":{}}}", .{c.charging}) },
        .{ .code = "charge-ischargingcableconnected", .body = try std.fmt.allocPrint(a, "{{\"value\":{}}}", .{c.plugged}) },
        .{ .code = "charge-chargelimits", .body = try std.fmt.allocPrint(a, "{{\"activeLimit\":{d},\"values\":[{{\"type\":\"GLOBAL\",\"limit\":{d}}}],\"unit\":\"percent\"}}", .{ c.limit, c.limit }) },
        .{ .code = "closure-islocked", .body = try std.fmt.allocPrint(a, "{{\"value\":{}}}", .{c.locked}) },
        .{ .code = "odometer-traveleddistance", .body = try std.fmt.allocPrint(a, "{{\"value\":{d:.1},\"unit\":\"km\"}}", .{c.odometer}) },
        .{ .code = "climate-internaltemperature", .body = try std.fmt.allocPrint(a, "{{\"value\":{d:.1},\"unit\":\"celsius\"}}", .{c.cabin}) },
        .{ .code = "location-preciselocation", .body = "{\"latitude\":52.2297,\"longitude\":21.0122,\"heading\":90,\"direction\":\"E\",\"locationType\":\"LAST_PARKED\"}" },
    };
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"data\":[");
    for (sigs, 0..) |sg, i| {
        if (i > 0) try o.append(a, ',');
        try o.print(a, "{{\"id\":\"sig_{d}\",\"type\":\"signal\",\"attributes\":{{\"code\":\"{s}\",\"status\":{{\"value\":\"SUCCESS\"}},\"body\":{s}}},\"meta\":{{\"retrievedAt\":\"{s}\",\"oemUpdatedAt\":\"{s}\"}}}}", .{ i, sg.code, sg.body, now, when });
    }
    // a signal this car does not have now
    try o.print(a, ",{{\"id\":\"sig_9\",\"type\":\"signal\",\"attributes\":{{\"code\":\"wheel-tires\",\"status\":{{\"value\":\"UNAVAILABLE\"}},\"body\":null}},\"meta\":{{\"retrievedAt\":\"{s}\"}}}}", .{now});
    try o.print(a, "],\"included\":{{\"vehicle\":{{\"id\":\"{s}\",\"type\":\"vehicle\"}}}}}}", .{vehicle_id});
    return o.items;
}

fn problem(req: *std.http.Server.Request, a: Allocator, status: std.http.Status, kind: []const u8, code: []const u8, title: []const u8, detail: []const u8) !void {
    const n: u16 = @backingInt(status);
    const body = try std.fmt.allocPrint(a, "{{\"errors\":[{{\"status\":\"{d}\",\"type\":\"{s}\",\"code\":\"{s}\",\"title\":\"{s}\",\"detail\":\"{s}\",\"resolution\":{{\"type\":null}}}}]}}", .{ n, kind, code, title, detail });
    return json(req, status, body);
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn formValue(body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return kv[eq + 1 ..];
    }
    return null;
}

fn unescape(a: Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            try o.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch '?');
            i += 2;
        } else if (s[i] == '+') {
            try o.append(a, ' ');
        } else try o.append(a, s[i]);
    }
    return o.items;
}
