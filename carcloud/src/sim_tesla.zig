//! carcloud-sim tesla: a stand-in for Tesla's sign-in, its Fleet API and
//! tesla-http-proxy, with one made-up car that starts asleep, for trying
//! carcloud's Tesla backend without an account. Built from Tesla's
//! documentation (November 2026), not from Tesla.
//!
//! On 127.0.0.1, HTTP (the API port):
//!   GET  /oauth2/v3/authorize?...            signs in at once: 302 to redirect_uri?code=…&state=…
//!   POST /oauth2/v3/token                    authorization_code, refresh_token (rotated at each use)
//!   GET  /api/1/vehicles, /api/1/vehicles/{vin}          never wakes the car
//!   GET  /api/1/vehicles/{vin}/vehicle_data             408 while asleep
//!   POST /api/1/vehicles/{vin}/wake_up                  online 2 s later
//!   POST /api/1/vehicles/fleet_status                   the virtual key: paired or not
//!   POST /api/1/vehicles/{vin}/command/...              403: commands must be signed
//!   GET|POST /sim/state                                 (tests)
//! On 127.0.0.1, TLS with a CA made at start (the proxy port):
//!   POST /api/1/vehicles/{vin}/command/{name}           as tesla-http-proxy: signed, so the car takes it
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sock = @import("sock.zig");
const jv = @import("jv.zig");
const testca = @import("testca.zig");
const tlsserver = @import("tlsserver.zig");

pub const vin = "5YJ3SIM0000000001";
pub const client_id = "sim-tesla-client";
pub const redirect_uri = "https://example.com/carcloud-callback";

const Car = struct {
    soc: f64 = 64,
    plugged: bool = true,
    charging: bool = false,
    limit: u8 = 80,
    locked: bool = true,
    odometer_mi: f64 = 11330.48,
    inside: f64 = 4.5,
    outside: f64 = -3,
    climate_on: bool = false,
    set_temp: f64 = 21,
    /// Tesla's heater numbers 0 to 5 (3 unused).
    seats: [6]u8 = @splat(0),
    asleep: bool = true,
    /// When wake_up was asked (ns); 0: not waking.
    waking_since: i128 = 0,
    key_paired: bool = true,
};

const Token = struct { value: []u8, until_s: i64 };

const Sim = struct {
    gpa: Allocator,
    io: Io,
    secret: []const u8,
    api_port: u16 = 0,
    lock: Io.Mutex = .init,
    car: Car = .{},
    codes: std.ArrayList([]u8) = .empty,
    /// The one refresh token that works now; "": none given out yet.
    refresh: []u8 = &.{},
    access: std.ArrayList(Token) = .empty,
    token_life_s: i64 = 28800,
    /// Counters the tests read: wakes asked, commands the proxy passed,
    /// commands sent to the Fleet API unsigned.
    wakes: u32 = 0,
    commands: u32 = 0,
    unsigned: u32 = 0,
    id: tlsserver.Identity = undefined,
};

pub const Made = struct { api: u16, proxy: u16, ca_pem: []const u8 };

/// Starts the stand-in on free ports (or those given), its threads
/// detached; the ports and the CA's PEM.
pub fn start(gpa: Allocator, io: Io, secret: []const u8, want: [2]u16) !Made {
    const s = try gpa.create(Sim);
    s.* = .{ .gpa = gpa, .io = io, .secret = secret };
    var seed: [64]u8 = undefined;
    try io.randomSecure(&seed);
    const made = try testca.make(gpa, &seed, nowS(io));
    s.id = .{ .cert_der = made.cert_der, .key = made.key };
    const api = try sock.Listener.open(want[0]);
    const proxy = try sock.Listener.open(want[1]);
    s.api_port = api.port;
    (try std.Thread.spawn(.{}, acceptLoop, .{ s, api, false })).detach();
    (try std.Thread.spawn(.{}, acceptLoop, .{ s, proxy, true })).detach();
    return .{ .api = api.port, .proxy = proxy.port, .ca_pem = made.ca_pem };
}

/// The car file for the stand-in (`ca.pem` beside it).
pub fn carFile(a: Allocator, m: Made) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\; carcloud-sim's made-up Tesla. carcloud login with
        \\; TESLA_CLIENT_SECRET set to the sim's secret signs in; the sim's
        \\; stand-in for tesla-http-proxy is checked against ca.pem.
        \\
        \\[car]
        \\backend = tesla
        \\name = The made-up Tesla
        \\vin = {s}
        \\client_id = {s}
        \\redirect_uri = {s}
        \\api = http://127.0.0.1:{d}
        \\auth_url = http://127.0.0.1:{d}/oauth2/v3/authorize
        \\token_url = http://127.0.0.1:{d}/oauth2/v3/token
        \\command_api = https://localhost:{d}
        \\command_ca = ca.pem
        \\allow = charge_start, charge_stop, charge_limit, climate, seat_heat
        \\climate_temp = 18 24
        \\commands_per_day = 10
        \\min_seconds_between = 60
        \\wakes_per_day = 3
        \\location = no
        \\
    , .{ vin, client_id, redirect_uri, m.api, m.api, m.api, m.proxy });
}

fn nowS(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn acceptLoop(s: *Sim, l: sock.Listener, tls: bool) void {
    while (true) {
        const conn = l.accept() catch continue;
        const t = std.Thread.spawn(.{}, serve, .{ s, conn, tls }) catch {
            sock.closeHandle(conn);
            continue;
        };
        t.detach();
    }
}

fn serve(s: *Sim, conn: sock.Handle, tls: bool) void {
    var rbuf: [32 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(s.io, conn, &rbuf, &wbuf, 60_000);
    defer sk.close();
    var t: tlsserver.Server = undefined;
    var prb: [32 * 1024]u8 = undefined;
    var pwb: [32 * 1024]u8 = undefined;
    var hs = if (tls) blk: {
        var entropy: [64]u8 = undefined;
        s.io.randomSecure(&entropy) catch return;
        t.accept(&sk, &s.id, &entropy, &prb, &pwb) catch return;
        break :blk std.http.Server.init(&t.reader, &t.writer);
    } else std.http.Server.init(&sk.reader, &sk.writer);
    while (true) {
        var req = hs.receiveHead() catch return;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        (if (tls) proxyHandle(s, a, &req) else apiHandle(s, a, &req)) catch return;
    }
}

const In = struct { target: []const u8, route: []const u8, auth: []const u8, body: []const u8 };

fn readIn(a: Allocator, req: *std.http.Server.Request) !In {
    const target = try a.dupe(u8, req.head.target);
    var auth: []const u8 = "";
    var it = req.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
        auth = try a.dupe(u8, h.value);
    };
    var body_buf: [8192]u8 = undefined;
    const body = try (try req.readerExpectContinue(&body_buf)).allocRemaining(a, .limited(1 << 20));
    return .{ .target = target, .route = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len], .auth = auth, .body = body };
}

/// The car's state: waking ends 2 s after wake_up was asked.
fn awake(s: *Sim) bool {
    const c = &s.car;
    if (c.asleep and c.waking_since > 0 and sock.nowNs(s.io) - c.waking_since >= 2 * std.time.ns_per_s) {
        c.asleep = false;
        c.waking_since = 0;
    }
    return !c.asleep;
}

fn tokenOk(s: *Sim, auth: []const u8) bool {
    const tok = if (std.mem.startsWith(u8, auth, "Bearer ")) auth[7..] else return false;
    const now = nowS(s.io);
    for (s.access.items) |x| if (std.mem.eql(u8, x.value, tok)) return now < x.until_s;
    return false;
}

fn randomToken(s: *Sim, prefix: []const u8) ![]u8 {
    var rnd: [12]u8 = undefined;
    s.io.randomSecure(&rnd) catch {};
    return std.fmt.allocPrint(s.gpa, "{s}{s}", .{ prefix, &std.fmt.bytesToHex(rnd, .lower) });
}

fn apiHandle(s: *Sim, a: Allocator, req: *std.http.Server.Request) !void {
    const in = try readIn(a, req);
    const method = req.head.method;
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);
    const route = in.route;
    if (method == .GET and std.mem.eql(u8, route, "/oauth2/v3/authorize")) {
        const q = in.target[route.len..];
        const cid = try queryValue(a, q, "client_id");
        const ru = try queryValue(a, q, "redirect_uri");
        const st = try queryValue(a, q, "state");
        if (!std.mem.eql(u8, cid, client_id) or !std.mem.eql(u8, ru, redirect_uri) or !std.mem.eql(u8, try queryValue(a, q, "response_type"), "code"))
            return req.respond("unknown client or redirect_uri", .{ .status = .bad_request });
        const code = try randomToken(s, "NA_code-");
        try s.codes.append(s.gpa, code);
        const loc = try std.fmt.allocPrint(a, "{s}?locale=en-US&code={s}&state={s}&issuer=https%3A%2F%2Fauth.tesla.com%2Foauth2%2Fv3", .{ redirect_uri, code, st });
        return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = loc }} });
    }
    if (method == .POST and std.mem.eql(u8, route, "/oauth2/v3/token")) {
        const b = in.body;
        if (!std.mem.eql(u8, try formValue(a, b, "client_id"), client_id)) return json(req, .unauthorized, "{\"error\":\"invalid_client\"}");
        const sec = try formValue(a, b, "client_secret");
        const grant = try formValue(a, b, "grant_type");
        if (std.mem.eql(u8, grant, "authorization_code")) {
            if (!std.mem.eql(u8, sec, s.secret)) return json(req, .unauthorized, "{\"error\":\"invalid_client\"}");
            const code = try formValue(a, b, "code");
            const i = for (s.codes.items, 0..) |x, i| {
                if (std.mem.eql(u8, x, code)) break i;
            } else return json(req, .bad_request, "{\"error\":\"invalid_grant\"}");
            s.gpa.free(s.codes.orderedRemove(i));
            if (!std.mem.eql(u8, try formValue(a, b, "redirect_uri"), redirect_uri)) return json(req, .bad_request, "{\"error\":\"invalid_grant\"}");
            const want_aud = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{s.api_port});
            if (!std.mem.eql(u8, try formValue(a, b, "audience"), want_aud)) return json(req, .bad_request, "{\"error\":\"invalid_audience\"}");
        } else if (std.mem.eql(u8, grant, "refresh_token")) {
            // the secret is optional; when sent, it must be right
            if (sec.len > 0 and !std.mem.eql(u8, sec, s.secret)) return json(req, .unauthorized, "{\"error\":\"invalid_client\"}");
            if (s.refresh.len == 0 or !std.mem.eql(u8, try formValue(a, b, "refresh_token"), s.refresh)) return json(req, .bad_request, "{\"error\":\"invalid_grant\"}");
        } else return json(req, .bad_request, "{\"error\":\"unsupported_grant_type\"}");
        // Tesla's refresh tokens are used once: the old one stops working
        s.gpa.free(s.refresh);
        s.refresh = try randomToken(s, "NA_refresh-");
        const access = try randomToken(s, "sim-access-");
        try s.access.append(s.gpa, .{ .value = access, .until_s = nowS(s.io) + s.token_life_s });
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"id_token\":\"sim-id\",\"expires_in\":{d},\"token_type\":\"Bearer\"}}", .{ access, s.refresh, s.token_life_s }));
    }
    if (std.mem.eql(u8, route, "/sim/state")) {
        if (method == .POST) {
            const v = jv.parse(a, in.body) orelse return json(req, .bad_request, "{}");
            const c = &s.car;
            if (jv.boolean(jv.get(v, "asleep"))) |x| {
                c.asleep = x;
                c.waking_since = 0;
            }
            if (jv.boolean(jv.get(v, "plugged"))) |x| c.plugged = x;
            if (jv.boolean(jv.get(v, "key_paired"))) |x| c.key_paired = x;
            if (jv.num(jv.get(v, "outside"))) |x| c.outside = x;
            if (jv.num(jv.get(v, "inside"))) |x| c.inside = x;
            if (jv.int(jv.get(v, "token_life"))) |x| s.token_life_s = x;
            if (jv.boolean(jv.get(v, "expire_tokens")) orelse false) for (s.access.items) |*x| {
                x.until_s = 0;
            };
            return json(req, .ok, "{}");
        }
        const c = s.car;
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"wakes\":{d},\"commands\":{d},\"unsigned\":{d},\"asleep\":{},\"climate_on\":{},\"set_temp\":{d},\"seat_left\":{d}}}", .{ s.wakes, s.commands, s.unsigned, c.asleep, c.climate_on, c.set_temp, c.seats[0] }));
    }
    // the Fleet API needs a token given out and not expired
    if (!tokenOk(s, in.auth)) return json(req, .unauthorized, "{\"error\":\"token expired (401)\"}");
    const one = "/api/1/vehicles/" ++ vin;
    if (method == .GET and std.mem.eql(u8, route, "/api/1/vehicles"))
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"response\":[{s}],\"count\":1}}", .{try vehicleJson(s, a)}));
    if (method == .POST and std.mem.eql(u8, route, "/api/1/vehicles/fleet_status")) {
        const paired = s.car.key_paired;
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"response\":{{\"key_paired_vins\":[{s}],\"unpaired_vins\":[{s}],\"vehicle_info\":{{}}}}}}", .{ if (paired) "\"" ++ vin ++ "\"" else "", if (paired) "" else "\"" ++ vin ++ "\"" }));
    }
    if (!std.mem.startsWith(u8, route, "/api/1/vehicles/")) return json(req, .not_found, "{\"response\":null,\"error\":\"not_found\",\"error_description\":\"\"}");
    if (!std.mem.startsWith(u8, route, one)) return json(req, .not_found, "{\"response\":null,\"error\":\"not_found\",\"error_description\":\"no vehicle with this id\"}");
    const rest = route[one.len..];
    if (method == .GET and rest.len == 0) return json(req, .ok, try std.fmt.allocPrint(a, "{{\"response\":{s}}}", .{try vehicleJson(s, a)}));
    if (method == .POST and std.mem.eql(u8, rest, "/wake_up")) {
        s.wakes += 1;
        if (s.car.asleep and s.car.waking_since == 0) s.car.waking_since = sock.nowNs(s.io);
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"response\":{s}}}", .{try vehicleJson(s, a)}));
    }
    if (method == .GET and std.mem.eql(u8, rest, "/vehicle_data")) {
        if (!awake(s)) return json(req, .request_timeout, "{\"response\":null,\"error\":\"vehicle unavailable: vehicle is offline or asleep\",\"error_description\":\"\"}");
        const with_location = std.mem.indexOf(u8, in.target, "location_data") != null;
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"response\":{s}}}", .{try dataJson(s, a, with_location)}));
    }
    if (method == .POST and std.mem.startsWith(u8, rest, "/command/")) {
        s.unsigned += 1;
        return json(req, .forbidden, "{\"response\":null,\"error\":\"Tesla Vehicle Command Protocol required, please refer to the documentation here: https://developer.tesla.com/docs/fleet-api#2023-10-09-rest-api-vehicle-commands-endpoint-deprecation-warning\",\"error_description\":\"\"}");
    }
    return json(req, .not_found, "{\"response\":null,\"error\":\"not_found\",\"error_description\":\"\"}");
}

/// tesla-http-proxy's part: a command, signed (here: taken as it is) when
/// the car knows the key.
fn proxyHandle(s: *Sim, a: Allocator, req: *std.http.Server.Request) !void {
    const in = try readIn(a, req);
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);
    const prefix = "/api/1/vehicles/" ++ vin ++ "/command/";
    if (req.head.method != .POST or !std.mem.startsWith(u8, in.route, prefix)) return json(req, .not_found, "{\"response\":null,\"error\":\"not found\",\"error_description\":\"\"}");
    if (!tokenOk(s, in.auth)) return json(req, .unauthorized, "{\"response\":null,\"error\":\"token expired (401)\",\"error_description\":\"\"}");
    if (!awake(s)) return json(req, .request_timeout, "{\"response\":null,\"error\":\"vehicle unavailable: vehicle is offline or asleep\",\"error_description\":\"\"}");
    if (!s.car.key_paired) return json(req, .forbidden, "{\"response\":null,\"error\":\"vehicle rejected request: your public key has not been paired with the vehicle\",\"error_description\":\"\"}");
    const name = in.route[prefix.len..];
    const v = jv.parse(a, if (in.body.len > 0) in.body else "{}") orelse return json(req, .bad_request, "{\"response\":null,\"error\":\"invalid JSON\",\"error_description\":\"\"}");
    const Params = struct {
        fn only(x: jv.Value, keys: []const []const u8) bool {
            if (x != .object) return false;
            var it = x.object.iterator();
            while (it.next()) |e| {
                for (keys) |k| {
                    if (std.mem.eql(u8, e.key_ptr.*, k)) break;
                } else return false;
            }
            return true;
        }
    };
    const c = &s.car;
    const eql = std.mem.eql;
    var reason: []const u8 = "";
    if (eql(u8, name, "auto_conditioning_start") or eql(u8, name, "auto_conditioning_stop")) {
        if (!Params.only(v, &.{})) return badParams(req);
        c.climate_on = eql(u8, name, "auto_conditioning_start");
    } else if (eql(u8, name, "set_temps")) {
        if (!Params.only(v, &.{ "driver_temp", "passenger_temp" })) return badParams(req);
        const d = jv.num(jv.get(v, "driver_temp")) orelse return badParams(req);
        if (d < 15 or d > 28) reason = "invalid temperature" else c.set_temp = d;
    } else if (eql(u8, name, "remote_seat_heater_request")) {
        if (!Params.only(v, &.{ "heater", "level" })) return badParams(req);
        const h = jv.int(jv.get(v, "heater")) orelse return badParams(req);
        const l = jv.int(jv.get(v, "level")) orelse return badParams(req);
        if (h < 0 or h > 5 or h == 3 or l < 0 or l > 3) reason = "invalid seat or level" else c.seats[@intCast(h)] = @intCast(l);
    } else if (eql(u8, name, "charge_start")) {
        if (!Params.only(v, &.{})) return badParams(req);
        if (!c.plugged) reason = "disconnected" else c.charging = true;
    } else if (eql(u8, name, "charge_stop")) {
        if (!Params.only(v, &.{})) return badParams(req);
        if (!c.charging) reason = "not_charging" else c.charging = false;
    } else if (eql(u8, name, "set_charge_limit")) {
        if (!Params.only(v, &.{"percent"})) return badParams(req);
        const p = jv.int(jv.get(v, "percent")) orelse return badParams(req);
        if (p < 50 or p > 100) reason = "invalid percent" else c.limit = @intCast(p);
    } else if (eql(u8, name, "door_lock") or eql(u8, name, "door_unlock")) {
        if (!Params.only(v, &.{})) return badParams(req);
        c.locked = eql(u8, name, "door_lock");
    } else return json(req, .not_found, "{\"response\":null,\"error\":\"unknown command\",\"error_description\":\"\"}");
    s.commands += 1;
    return json(req, .ok, try std.fmt.allocPrint(a, "{{\"response\":{{\"result\":{},\"reason\":\"{s}\"}}}}", .{ reason.len == 0, reason }));
}

fn badParams(req: *std.http.Server.Request) !void {
    return json(req, .bad_request, "{\"response\":null,\"error\":\"invalid parameters\",\"error_description\":\"\"}");
}

fn vehicleJson(s: *Sim, a: Allocator) ![]const u8 {
    const state: []const u8 = if (awake(s)) "online" else "asleep";
    return std.fmt.allocPrint(a, "{{\"id\":100021,\"vehicle_id\":99999,\"vin\":\"{s}\",\"display_name\":\"The made-up Tesla\",\"state\":\"{s}\",\"in_service\":false}}", .{ vin, state });
}

fn dataJson(s: *Sim, a: Allocator, with_location: bool) ![]const u8 {
    const c = s.car;
    const ms = @divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_ms);
    const charging_state: []const u8 = if (!c.plugged) "Disconnected" else if (c.charging) "Charging" else "Stopped";
    const loc: []const u8 = if (with_location) ",\"drive_state\":{\"latitude\":52.2297,\"longitude\":21.0122,\"heading\":90}" else "";
    return std.fmt.allocPrint(a, "{{\"vin\":\"{s}\",\"state\":\"online\",\"charge_state\":{{\"battery_level\":{d},\"battery_range\":{d:.2},\"charging_state\":\"{s}\",\"charge_limit_soc\":{d},\"timestamp\":{d}}},\"climate_state\":{{\"inside_temp\":{d},\"outside_temp\":{d},\"is_climate_on\":{},\"driver_temp_setting\":{d},\"passenger_temp_setting\":{d},\"seat_heater_left\":{d},\"seat_heater_right\":{d},\"seat_heater_rear_left\":{d},\"seat_heater_rear_center\":{d},\"seat_heater_rear_right\":{d},\"timestamp\":{d}}},\"vehicle_state\":{{\"locked\":{},\"odometer\":{d:.2},\"timestamp\":{d}}}{s}}}", .{
        vin,                 c.soc,         c.soc * 2.858, charging_state, c.limit,    ms,
        c.inside,            c.outside,     c.climate_on,  c.set_temp,     c.set_temp, c.seats[0],
        c.seats[1],          c.seats[2],    c.seats[4],    c.seats[5],     ms,         c.locked,
        c.odometer_mi,       ms,            loc,
    });
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn formValue(a: Allocator, body: []const u8, key: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return unescape(a, kv[eq + 1 ..]);
    }
    return "";
}

fn queryValue(a: Allocator, q: []const u8, key: []const u8) ![]const u8 {
    return formValue(a, if (q.len > 0 and q[0] == '?') q[1..] else q, key);
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

// ---- tests ----

const http = @import("http.zig");
const tt = std.testing;

test "the_proxy_stand_in_is_trusted_only_through_its_ca" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = tt.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(tt.io, ".", a);
    const m = try start(std.heap.page_allocator, tt.io, "s3cret", .{ 0, 0 });
    const ca = try std.fs.path.join(a, &.{ dir, "ca.pem" });
    try Io.Dir.cwd().writeFile(tt.io, .{ .sub_path = ca, .data = m.ca_pem });
    const url = try std.fmt.allocPrint(a, "https://localhost:{d}", .{m.proxy});
    // its CA: the proxy answers (no token: 401, over TLS)
    {
        var c = http.Client.init(tt.allocator, tt.io, try http.Target.parse(url));
        defer c.deinit();
        c.ca_file = ca;
        const ans = try http.fetch(&c, a, .{ .path = "/api/1/vehicles/" ++ vin ++ "/command/auto_conditioning_start", .body = "{}" });
        try tt.expectEqual(@as(u16, 401), ans.status);
    }
    // the system's roots, or another CA: refused. On Windows std then asks
    // crypt32, which fails the stand-in's Ed25519 CA with a code std has no
    // name for; the test runner's Debug trace of it panics (carcloud's own
    // binary turns that trace off: main.zig's std_options), so there only
    // a release build checks these two.
    const os_trace = @import("builtin").os.tag == .windows and std.options.unexpected_error_tracing;
    if (!os_trace) {
        var c = http.Client.init(tt.allocator, tt.io, try http.Target.parse(url));
        defer c.deinit();
        try tt.expectError(error.CertificateRejected, http.fetch(&c, a, .{ .path = "/", .method = .GET }));
    }
    if (!os_trace) {
        var seed: [64]u8 = undefined;
        try tt.io.randomSecure(&seed);
        const other = try testca.make(a, &seed, nowS(tt.io));
        const other_ca = try std.fs.path.join(a, &.{ dir, "other.pem" });
        try Io.Dir.cwd().writeFile(tt.io, .{ .sub_path = other_ca, .data = other.ca_pem });
        var c = http.Client.init(tt.allocator, tt.io, try http.Target.parse(url));
        defer c.deinit();
        c.ca_file = other_ca;
        try tt.expectError(error.CertificateRejected, http.fetch(&c, a, .{ .path = "/", .method = .GET }));
    }
    // a CA file that isn't there: no connection at all
    {
        var c = http.Client.init(tt.allocator, tt.io, try http.Target.parse(url));
        defer c.deinit();
        c.ca_file = try std.fs.path.join(a, &.{ dir, "missing.pem" });
        try tt.expectError(error.TlsFailed, http.fetch(&c, a, .{ .path = "/", .method = .GET }));
    }
}
