//! Tesla's Fleet API, the parts carcloud uses, through the owner's own
//! developer application: the sign-in (an authorization code once, then a
//! refresh token Tesla replaces at each use, kept in the token file), the
//! car's state and `vehicle_data` (live: a sleeping car answers nothing
//! until woken), waking it, and commands. Commands must be signed with the
//! application's key, which the owner paired with the car once (the
//! virtual key): they go to `command_api`, Tesla's tesla-http-proxy, which
//! signs them (Tesla documents the signing protocol only in its Go code).
//! Written from Tesla's documentation (as of November 2026); tried against
//! carcloud-sim only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const http = @import("http.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");

/// The scopes carcloud asks for: reading, commands, charging commands;
/// location only when the car file shows it.
pub fn scopes(cfg: *const config.Config) []const u8 {
    return if (cfg.location)
        "openid offline_access vehicle_device_data vehicle_location vehicle_cmds vehicle_charging_cmds"
    else
        "openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds";
}

/// The link the owner opens to sign in and allow the application.
pub fn authorizeLink(a: Allocator, cfg: *const config.Config, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}?response_type=code&client_id={f}&redirect_uri={f}&scope={f}&state={f}&prompt_missing_scopes=true", .{ cfg.auth_url, formEscape(cfg.client_id), formEscape(cfg.redirect_uri), formEscape(scopes(cfg)), formEscape(state) });
}

/// The code from what the owner pasted: the address the browser ended on
/// (its `state` must be `want`), or the code alone.
pub fn codeFrom(a: Allocator, pasted_in: []const u8, want: []const u8) error{ NoCode, StateMismatch, OutOfMemory }![]const u8 {
    const pasted = std.mem.trim(u8, pasted_in, " \t\r\n<>\"'");
    const q = std.mem.indexOfScalar(u8, pasted, '?') orelse {
        if (pasted.len == 0 or std.mem.indexOfAny(u8, pasted, " =&/") != null) return error.NoCode;
        return pasted;
    };
    var code: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, pasted[q + 1 ..], '&');
    while (it.next()) |kv| {
        const end = std.mem.indexOfScalar(u8, kv, '#') orelse kv.len;
        const pair = kv[0..end];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], "code")) code = try unescape(a, pair[eq + 1 ..]);
        if (std.mem.eql(u8, pair[0..eq], "state")) state = try unescape(a, pair[eq + 1 ..]);
    }
    const c = code orelse return error.NoCode;
    if (c.len == 0) return error.NoCode;
    if (state == null or !std.mem.eql(u8, state.?, want)) return error.StateMismatch;
    return c;
}

/// A car of the account (carcloud login lists them).
pub const Vehicle = struct { vin: []const u8, name: []const u8, state: []const u8 };

/// What a command's call came to: the car's own yes (`ok`), or why not.
pub const Sent = struct { ok: bool, reason: []const u8 = "" };

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    /// TESLA_CLIENT_SECRET; "": not set (a refresh needs only the id).
    secret: []const u8,
    api: http.Client,
    auth: http.Client,
    cmd: ?http.Client,
    token: []u8 = &.{},
    token_until_ns: i128 = 0,
    /// Why the last call failed, in plain words (in the caller's arena).
    problem: ?[]const u8 = null,
    /// How long a wake is waited for (s); between two looks (ms).
    wake_wait_s: u32 = 60,
    poll_ms: u32 = 3000,

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, secret: []const u8) !Client {
        var c: Client = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .secret = secret,
            .api = .init(gpa, io, try http.Target.parse(cfg.api)),
            .auth = .init(gpa, io, try http.Target.parse(cfg.token_url)),
            .cmd = if (cfg.command_api.len > 0) http.Client.init(gpa, io, try http.Target.parse(cfg.command_api)) else null,
        };
        c.api.user_agent = "carcloud";
        c.auth.user_agent = "carcloud";
        if (c.cmd) |*x| {
            x.user_agent = "carcloud";
            x.ca_file = cfg.command_ca;
        }
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.api.deinit();
        c.auth.deinit();
        if (c.cmd) |*x| x.deinit();
        std.crypto.secureZero(u8, c.token);
        c.gpa.free(c.token);
    }

    fn say(c: *Client, a: Allocator, comptime fmt: []const u8, args: anytype) error{ Refused, OutOfMemory } {
        c.problem = try std.fmt.allocPrint(a, fmt, args);
        return error.Refused;
    }

    // ---- the sign-in ----

    /// carcloud login: the code exchanged for tokens; the refresh token
    /// written to the token file.
    pub fn exchangeCode(c: *Client, a: Allocator, code: []const u8) !void {
        c.problem = null;
        if (c.secret.len == 0) return c.say(a, "TESLA_CLIENT_SECRET is not set: your application's secret (developer.tesla.com)", .{});
        const body = try std.fmt.allocPrint(a, "grant_type=authorization_code&client_id={f}&client_secret={f}&code={f}&audience={f}&redirect_uri={f}", .{ formEscape(c.cfg.client_id), formEscape(c.secret), formEscape(code), formEscape(c.cfg.audience), formEscape(c.cfg.redirect_uri) });
        try c.takeTokens(a, body, "the sign-in");
    }

    /// An access token, fetched with the kept refresh token a minute
    /// before the last one runs out (the file read each time: another
    /// carcloud may have replaced it).
    fn accessToken(c: *Client, a: Allocator) ![]const u8 {
        if (c.token.len > 0 and sock.nowNs(c.io) < c.token_until_ns) return c.token;
        const refresh = readToken(a, c.io, c.cfg.token_path) catch |e| switch (e) {
            error.FileNotFound => return c.say(a, "not signed in to Tesla yet: run carcloud login with this car file", .{}),
            error.NotAToken => return c.say(a, "the token file {s} doesn't hold a sign-in: run carcloud login again", .{c.cfg.token_path}),
            else => return c.say(a, "can't read the token file {s}: {s}", .{ c.cfg.token_path, @errorName(e) }),
        };
        const body = if (c.secret.len > 0)
            try std.fmt.allocPrint(a, "grant_type=refresh_token&client_id={f}&client_secret={f}&refresh_token={f}", .{ formEscape(c.cfg.client_id), formEscape(c.secret), formEscape(refresh) })
        else
            try std.fmt.allocPrint(a, "grant_type=refresh_token&client_id={f}&refresh_token={f}", .{ formEscape(c.cfg.client_id), formEscape(refresh) });
        try c.takeTokens(a, body, "the kept sign-in");
        return c.token;
    }

    /// Posts `body` to the token endpoint; keeps the access token, writes
    /// the refresh token Tesla gives back before anything uses the new one.
    fn takeTokens(c: *Client, a: Allocator, body: []const u8, what: []const u8) !void {
        const ans = http.fetch(&c.auth, a, .{ .path = "", .body = body, .content_type = "application/x-www-form-urlencoded", .limits = .{ .idle_ms = 15_000, .total_ms = 30_000 } }) catch |e| return c.say(a, "can't reach Tesla's sign-in: {s}", .{@errorName(e)});
        const v = jv.parse(a, ans.body);
        if (ans.status != 200) {
            const err = plainCode(jv.str(jv.get(v, "error")) orelse "");
            return c.say(a, "Tesla refused {s} (HTTP {d}{s}{s}): run carcloud login with this car file again", .{ what, ans.status, if (err.len > 0) ", " else "", err });
        }
        const tok = jv.str(jv.get(v, "access_token")) orelse return c.say(a, "Tesla's sign-in answered without a token", .{});
        if (jv.str(jv.get(v, "refresh_token"))) |r| writeToken(c.io, c.cfg.token_path, r) catch |e| return c.say(a, "can't write the token file {s}: {s}", .{ c.cfg.token_path, @errorName(e) });
        const secs = jv.int(jv.get(v, "expires_in")) orelse 3600;
        std.crypto.secureZero(u8, c.token);
        c.gpa.free(c.token);
        c.token = try c.gpa.dupe(u8, tok);
        c.token_until_ns = sock.nowNs(c.io) + @as(i128, @max(secs - 60, 30)) * std.time.ns_per_s;
    }

    // ---- reading ----

    /// A Fleet API call with the access token, once more with a fresh one
    /// after a 401.
    fn call(c: *Client, a: Allocator, client: *http.Client, method: @FieldType(http.Request, "method"), path: []const u8, body: ?[]const u8, limits: http.Limits) !http.Answer {
        var tries: usize = 0;
        while (true) : (tries += 1) {
            const tok = try c.accessToken(a);
            const ans = http.fetch(client, a, .{ .method = method, .path = path, .body = body, .key = tok, .limits = limits }) catch |e| {
                if (client == &c.api) return c.say(a, "can't reach Tesla's Fleet API: {s}", .{@errorName(e)});
                return c.say(a, "{s}", .{try proxyTrouble(a, c.cfg, e, client.detail)});
            };
            if (ans.status == 401 and tries == 0) {
                c.token_until_ns = 0;
                continue;
            }
            return ans;
        }
    }

    /// The car's state without waking it: online, asleep or offline.
    pub fn state(c: *Client, a: Allocator) ![]const u8 {
        c.problem = null;
        const ans = try c.call(a, &c.api, .GET, try std.fmt.allocPrint(a, "/api/1/vehicles/{s}", .{c.cfg.vin}), null, .{ .idle_ms = 20_000, .total_ms = 30_000 });
        if (ans.status != 200) return c.refusal(a, ans);
        return jv.str(jv.at(jv.parse(a, ans.body), &.{ "response", "state" })) orelse c.say(a, "Tesla's answer had no state for the car", .{});
    }

    /// The account's cars (for carcloud login).
    pub fn vehicles(c: *Client, a: Allocator) ![]Vehicle {
        c.problem = null;
        const ans = try c.call(a, &c.api, .GET, "/api/1/vehicles", null, .{ .idle_ms = 20_000, .total_ms = 30_000 });
        if (ans.status != 200) return c.refusal(a, ans);
        var out: std.ArrayList(Vehicle) = .empty;
        for (jv.arr(jv.get(jv.parse(a, ans.body), "response")) orelse &.{}) |x| try out.append(a, .{
            .vin = jv.str(jv.get(x, "vin")) orelse "?",
            .name = jv.str(jv.get(x, "display_name")) orelse "",
            .state = jv.str(jv.get(x, "state")) orelse "?",
        });
        return out.items;
    }

    /// `vehicle_data` (the parts carcloud shows); error.Asleep when the
    /// car is asleep or offline (it isn't woken).
    pub fn vehicleData(c: *Client, a: Allocator) !jv.Value {
        c.problem = null;
        const ends = if (c.cfg.location) "charge_state%3Bclimate_state%3Bvehicle_state%3Blocation_data" else "charge_state%3Bclimate_state%3Bvehicle_state";
        const ans = try c.call(a, &c.api, .GET, try std.fmt.allocPrint(a, "/api/1/vehicles/{s}/vehicle_data?endpoints={s}", .{ c.cfg.vin, ends }), null, .{ .idle_ms = 20_000, .total_ms = 40_000 });
        if (ans.status == 408) return error.Asleep;
        if (ans.status != 200) return c.refusal(a, ans);
        return jv.get(jv.parse(a, ans.body), "response") orelse c.say(a, "Tesla's answer had no data for the car", .{});
    }

    /// Wakes the car and waits until it is online (up to `wake_wait_s`);
    /// false when it isn't by then.
    pub fn wake(c: *Client, a: Allocator) !bool {
        c.problem = null;
        const ans = try c.call(a, &c.api, .POST, try std.fmt.allocPrint(a, "/api/1/vehicles/{s}/wake_up", .{c.cfg.vin}), "{}", .{ .idle_ms = 20_000, .total_ms = 30_000 });
        if (ans.status != 200) return c.refusal(a, ans);
        if (std.mem.eql(u8, jv.str(jv.at(jv.parse(a, ans.body), &.{ "response", "state" })) orelse "", "online")) return true;
        var waited_ms: u64 = 0;
        while (waited_ms < @as(u64, c.wake_wait_s) * 1000) {
            c.io.sleep(.fromMilliseconds(c.poll_ms), .awake) catch {};
            waited_ms += c.poll_ms;
            if (std.mem.eql(u8, try c.state(a), "online")) return true;
        }
        return false;
    }

    /// Whether the car knows the application's key (Fleet API
    /// fleet_status); null when Tesla doesn't say.
    pub fn keyPaired(c: *Client, a: Allocator) !?bool {
        c.problem = null;
        const ans = try c.call(a, &c.api, .POST, "/api/1/vehicles/fleet_status", try std.fmt.allocPrint(a, "{{\"vins\":[{f}]}}", .{std.json.fmt(c.cfg.vin, .{})}), .{ .idle_ms = 20_000, .total_ms = 30_000 });
        if (ans.status != 200) return null;
        const v = jv.parse(a, ans.body);
        for (jv.arr(jv.at(v, &.{ "response", "key_paired_vins" })) orelse &.{}) |x| if (std.mem.eql(u8, jv.str(x) orelse "", c.cfg.vin)) return true;
        for (jv.arr(jv.at(v, &.{ "response", "unpaired_vins" })) orelse &.{}) |x| if (std.mem.eql(u8, jv.str(x) orelse "", c.cfg.vin)) return false;
        return null;
    }

    /// Whether tesla-http-proxy answers, its certificate accepted.
    pub fn proxyAnswers(c: *Client, a: Allocator) !void {
        c.problem = null;
        const x = if (c.cmd) |*p| p else return c.say(a, "no command_api in the car file", .{});
        _ = http.fetch(x, a, .{ .method = .GET, .path = "/", .limits = .{ .idle_ms = 10_000, .total_ms = 15_000 } }) catch |e| return c.say(a, "{s}", .{try proxyTrouble(a, c.cfg, e, x.detail)});
    }

    // ---- commands ----

    /// Sends command `name` (its JSON `body`) through tesla-http-proxy,
    /// which signs it; the car's own answer.
    pub fn send(c: *Client, a: Allocator, name: []const u8, body: []const u8) !Sent {
        c.problem = null;
        const x = if (c.cmd) |*p| p else return c.say(a, "no command_api in the car file", .{});
        const ans = try c.call(a, x, .POST, try std.fmt.allocPrint(a, "/api/1/vehicles/{s}/command/{s}", .{ c.cfg.vin, name }), body, .{ .idle_ms = 45_000, .total_ms = 60_000 });
        if (ans.status != 200) return c.refusal(a, ans);
        const v = jv.parse(a, ans.body);
        if (jv.boolean(jv.at(v, &.{ "response", "result" })) orelse false) return .{ .ok = true };
        return .{ .ok = false, .reason = jv.str(jv.at(v, &.{ "response", "reason" })) orelse jv.str(jv.get(v, "error")) orelse "" };
    }

    /// Tesla's no, in plain words.
    fn refusal(c: *Client, a: Allocator, ans: http.Answer) error{ Refused, OutOfMemory } {
        c.problem = try refusalText(a, ans.status, ans.body);
        return error.Refused;
    }
};

/// Why Tesla (or its proxy) said no: the status and its `error`.
pub fn refusalText(a: Allocator, status: u16, body: []const u8) ![]const u8 {
    const err = std.mem.trim(u8, jv.str(jv.get(jv.parse(a, body), "error")) orelse "", " ");
    const said = if (err.len > 0) try std.fmt.allocPrint(a, " (HTTP {d}: {s})", .{ status, oneLine(err) }) else try std.fmt.allocPrint(a, " (HTTP {d})", .{status});
    if (std.ascii.findIgnoreCase(err, "not been paired") != null or std.ascii.findIgnoreCase(err, "public key") != null or std.ascii.findIgnoreCase(err, "unknown key") != null)
        return std.fmt.allocPrint(a, "the car doesn't know the application's key yet: pair the virtual key once in the Tesla app (README: With a Tesla){s}", .{said});
    if (std.ascii.findIgnoreCase(err, "command protocol required") != null)
        return std.fmt.allocPrint(a, "the command reached the Fleet API unsigned: command_api must be tesla-http-proxy{s}", .{said});
    return switch (status) {
        408 => std.fmt.allocPrint(a, "the car is asleep or offline{s}", .{said}),
        404 => std.fmt.allocPrint(a, "Tesla knows no such car on this account: check vin{s}", .{said}),
        401, 403 => std.fmt.allocPrint(a, "Tesla refused the sign-in for this: run carcloud login again, with the scopes allowed{s}", .{said}),
        421 => std.fmt.allocPrint(a, "the account is in another region: check region{s}", .{said}),
        429 => std.fmt.allocPrint(a, "Tesla's rate limit: try later{s}", .{said}),
        else => std.fmt.allocPrint(a, "Tesla said no{s}", .{said}),
    };
}

/// Why the proxy couldn't be used, in plain words.
fn proxyTrouble(a: Allocator, cfg: *const config.Config, e: anyerror, detail: ?anyerror) ![]const u8 {
    return switch (e) {
        error.CertificateRejected => std.fmt.allocPrint(a, "tesla-http-proxy at {s}: its certificate was not accepted ({s}; command_ca must be its own certificate, for this host name)", .{ cfg.command_api, if (cfg.command_ca.len > 0) cfg.command_ca else "the system's roots" }),
        error.ConnectFailed, error.Timeout => std.fmt.allocPrint(a, "tesla-http-proxy at {s} doesn't answer ({s}): is it running?", .{ cfg.command_api, @errorName(e) }),
        else => std.fmt.allocPrint(a, "tesla-http-proxy at {s}: {s}{s}{s}", .{ cfg.command_api, @errorName(e), if (detail != null) ", " else "", if (detail) |d| @errorName(d) else "" }),
    };
}

/// An OAuth error code as it is, or "" when it isn't one (nothing else of
/// the answer is repeated).
fn plainCode(s: []const u8) []const u8 {
    if (s.len > 40) return "";
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return "";
    return s;
}

fn oneLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, "\r\n") orelse s.len;
    return s[0..@min(end, 200)];
}

// ---- the token file ----

/// The refresh token kept in `path`.
pub fn readToken(a: Allocator, io: Io, path: []const u8) ![]const u8 {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024));
    const tok = jv.str(jv.get(jv.parse(a, text), "refresh_token")) orelse return error.NotAToken;
    if (tok.len == 0) return error.NotAToken;
    return tok;
}

const private_file: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);

/// Writes the refresh token to `path`, readable by the owner only, whole
/// or not at all (a new file beside it, then renamed over it).
pub fn writeToken(io: Io, path: []const u8, refresh: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const data = try std.fmt.allocPrint(fba.allocator(), "{{\"refresh_token\":{f},\"note\":\"carcloud's Tesla sign-in: keep it private\"}}\n", .{std.json.fmt(refresh, .{})});
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&pbuf, "{s}.tmp-{s}", .{ path, &std.fmt.bytesToHex(rnd, .lower) });
    const cwd = Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp, .{ .exclusive = true, .permissions = private_file });
        defer f.close(io);
        errdefer cwd.deleteFile(io, tmp) catch {};
        try f.writeStreamingAll(io, data);
        try f.sync(io);
    }
    errdefer cwd.deleteFile(io, tmp) catch {};
    try cwd.rename(tmp, cwd, path, io);
    std.crypto.secureZero(u8, data);
}

// ---- what the car says ----

const km_per_mile = 1.609344;

/// The seats `car_seat_heat` names, and Tesla's `heater` number for each.
pub const Seat = enum {
    front_left,
    front_right,
    rear_left,
    rear_center,
    rear_right,

    pub fn heater(s: Seat) u8 {
        return switch (s) {
            .front_left => 0,
            .front_right => 1,
            .rear_left => 2,
            .rear_center => 4,
            .rear_right => 5,
        };
    }

    /// Its field in climate_state.
    pub fn field(s: Seat) []const u8 {
        return switch (s) {
            .front_left => "seat_heater_left",
            .front_right => "seat_heater_right",
            .rear_left => "seat_heater_rear_left",
            .rear_center => "seat_heater_rear_center",
            .rear_right => "seat_heater_rear_right",
        };
    }

    pub fn words(s: Seat) []const u8 {
        return switch (s) {
            .front_left => "front left",
            .front_right => "front right",
            .rear_left => "rear left",
            .rear_center => "rear centre",
            .rear_right => "rear right",
        };
    }
};

/// A number as carcloud shows it: whole, else with one decimal.
pub fn num(a: Allocator, v: ?jv.Value) []const u8 {
    const x = jv.num(v) orelse return "?";
    return numF(a, x);
}

fn numF(a: Allocator, x: f64) []const u8 {
    if (@abs(x - @round(x)) < 1e-9) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@round(x)))}) catch "?";
    return std.fmt.allocPrint(a, "{d:.1}", .{x}) catch "?";
}

fn yesNo(v: ?jv.Value) []const u8 {
    return if (jv.boolean(v)) |b| (if (b) "yes" else "no") else "?";
}

/// car_status's lines from `vehicle_data`'s response (`now_ms` the time).
pub fn statusLines(a: Allocator, cfg: *const config.Config, d: jv.Value, now_ms: i64) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "{s}:\n", .{cfg.name});
    const ch = jv.get(d, "charge_state");
    const cl = jv.get(d, "climate_state");
    const vs = jv.get(d, "vehicle_state");
    if (jv.get(ch, "battery_level")) |x| try o.print(a, "battery: {s}%\n", .{num(a, x)});
    if (jv.num(jv.get(ch, "battery_range"))) |mi| try o.print(a, "range: {s} km\n", .{numF(a, @round(mi * km_per_mile * 10) / 10)});
    if (jv.str(jv.get(ch, "charging_state"))) |cs| {
        try o.print(a, "charging: {s}\n", .{if (std.mem.eql(u8, cs, "Charging") or std.mem.eql(u8, cs, "Starting")) "yes" else "no"});
        try o.print(a, "plugged in: {s}\n", .{if (std.mem.eql(u8, cs, "Disconnected")) "no" else "yes"});
    }
    if (jv.get(ch, "charge_limit_soc")) |x| try o.print(a, "charge limit: {s}%\n", .{num(a, x)});
    if (jv.get(vs, "locked")) |x| try o.print(a, "locked: {s}\n", .{yesNo(x)});
    if (jv.num(jv.get(vs, "odometer"))) |mi| try o.print(a, "odometer: {s} km\n", .{numF(a, @round(mi * km_per_mile * 10) / 10)});
    if (jv.get(cl, "inside_temp")) |x| try o.print(a, "inside: {s} °C\n", .{num(a, x)});
    if (jv.get(cl, "outside_temp")) |x| try o.print(a, "outside: {s} °C\n", .{num(a, x)});
    if (jv.boolean(jv.get(cl, "is_climate_on"))) |on| try o.print(a, "climate: {s}, set to {s} °C\n", .{ if (on) "on" else "off", num(a, jv.get(cl, "driver_temp_setting")) });
    if (cfg.seat_heat) {
        var warm: std.ArrayList([]const u8) = .empty;
        for ([_]Seat{ .front_left, .front_right, .rear_left, .rear_center, .rear_right }) |s| {
            const lvl = jv.int(jv.get(cl, s.field())) orelse 0;
            if (lvl > 0) try warm.append(a, try std.fmt.allocPrint(a, "{s} {d}", .{ s.words(), lvl }));
        }
        try o.print(a, "seat heating: {s}\n", .{if (warm.items.len == 0) "off" else try std.mem.join(a, ", ", warm.items)});
    }
    if (cfg.location) if (jv.get(d, "drive_state")) |ds| if (jv.num(jv.get(ds, "latitude")) != null)
        try o.print(a, "location: {s}, {s}\n", .{ num(a, jv.get(ds, "latitude")), num(a, jv.get(ds, "longitude")) });
    // how old: the oldest part's own time
    var oldest: ?i64 = null;
    for ([_]?jv.Value{ ch, cl, vs }) |part| if (jv.int(jv.get(part, "timestamp"))) |ts| {
        oldest = if (oldest) |x| @min(x, ts) else ts;
    };
    if (oldest) |ts| try o.print(a, "{s}\n", .{try ageText(a, @as(f64, @floatFromInt(@max(0, now_ms - ts))) / 1000)});
    return o.items;
}

pub fn ageText(a: Allocator, s: f64) ![]u8 {
    if (s < 120) return a.dupe(u8, "data: from the last minutes");
    if (s < 7200) return std.fmt.allocPrint(a, "data: from {d:.0} minutes ago", .{s / 60});
    return std.fmt.allocPrint(a, "data: from {d:.1} hours ago", .{s / 3600});
}

/// What car_climate says once the car accepted it: what it reads now.
pub fn climateReadBack(a: Allocator, d: jv.Value, want_on: ?bool, want_temp: ?f64) ![]const u8 {
    const cl = jv.get(d, "climate_state");
    const on = jv.boolean(jv.get(cl, "is_climate_on"));
    const set = jv.num(jv.get(cl, "driver_temp_setting"));
    var temps: std.ArrayList(u8) = .empty;
    if (jv.get(cl, "inside_temp")) |x| try temps.print(a, "inside {s} °C", .{num(a, x)});
    if (jv.get(cl, "outside_temp")) |x| try temps.print(a, "{s}outside {s} °C", .{ if (temps.items.len > 0) ", " else "", num(a, x) });
    const t_said = if (set) |x| try std.fmt.allocPrint(a, "set to {s} °C", .{numF(a, x)}) else "";
    if (want_on) |w| {
        if (on == null or on.? != w) return std.fmt.allocPrint(a, "The car accepted it, but it still reads climate {s}; check with car_status in a minute.", .{if (on orelse !w) "on" else "off"});
    }
    if (want_temp) |w| if (set == null or @abs(set.? - w) > 0.26)
        return std.fmt.allocPrint(a, "The car accepted it, but it reads {s}; check with car_status in a minute.", .{if (t_said.len > 0) t_said else "no temperature"});
    const state_words: []const u8 = if (on orelse false) "Climate on" else "Climate off";
    if (want_on == null) {
        // the temperature alone
        return std.fmt.allocPrint(a, "Set to {s} °C; climate is {s}{s}{s}.", .{ numF(a, set orelse 0), if (on orelse false) "on" else "off", if (temps.items.len > 0) "; " else "", temps.items });
    }
    if (want_on.?) return std.fmt.allocPrint(a, "{s}, {s}{s}{s}.", .{ state_words, t_said, if (temps.items.len > 0) "; " else "", temps.items });
    return std.fmt.allocPrint(a, "{s}{s}{s}.", .{ state_words, if (temps.items.len > 0) "; " else "", temps.items });
}

/// What car_seat_heat says once the car accepted it.
pub fn seatReadBack(a: Allocator, d: jv.Value, seat: Seat, level: u8) ![]const u8 {
    const got = jv.int(jv.get(jv.get(d, "climate_state"), seat.field()));
    const Words = struct {
        fn of(al: Allocator, s: Seat, l: i64) ![]const u8 {
            if (l == 0) return std.fmt.allocPrint(al, "{s} seat heating off", .{s.words()});
            return std.fmt.allocPrint(al, "{s} seat heating at {d} of 3", .{ s.words(), l });
        }
    };
    if (got == null or got.? != level) return std.fmt.allocPrint(a, "The car accepted it, but it reads {s}; check with car_status in a minute.", .{if (got) |g| try Words.of(a, seat, g) else "no seat heating"});
    const w = try Words.of(a, seat, level);
    const out = try a.dupe(u8, w);
    out[0] = std.ascii.toUpper(out[0]);
    return std.fmt.allocPrint(a, "{s}.", .{out});
}

// ---- small things ----

/// application/x-www-form-urlencoded
pub fn formEscape(s: []const u8) Form {
    return .{ .s = s };
}

pub const Form = struct {
    s: []const u8,
    pub fn format(f: Form, w: *Io.Writer) Io.Writer.Error!void {
        for (f.s) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
                try w.writeByte(ch);
            } else try w.print("%{X:0>2}", .{ch});
        }
    }
};

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

const t = std.testing;

fn teslaCfg(a: Allocator, extra: []const u8) !config.Config {
    var d: config.Diag = .{};
    return config.parse(a, try std.fmt.allocPrint(a, "[car]\nbackend = tesla\nname = The Model 3\nvin = 5YJ3SIM\nclient_id = app-1\nredirect_uri = https://example.com/callback\nregion = eu\ncommand_api = https://localhost:4443\n{s}", .{extra}), &d);
}

const awake_data =
    \\{"vin":"5YJ3SIM","state":"online","charge_state":{"battery_level":64,"battery_range":182.93,"charging_state":"Stopped","charge_limit_soc":80,"timestamp":1795400000000},"climate_state":{"inside_temp":4.5,"outside_temp":-3,"is_climate_on":false,"driver_temp_setting":21,"seat_heater_left":0,"seat_heater_right":2,"timestamp":1795400000000},"vehicle_state":{"locked":true,"odometer":11330.48,"timestamp":1795400000000},"drive_state":{"latitude":50.06,"longitude":19.94}}
;

test "tesla_status_reads_as_smartcars_does" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try teslaCfg(a, "allow = climate, seat_heat\n");
    const d = jv.parse(a, awake_data).?;
    try t.expectEqualStrings(
        \\The Model 3:
        \\battery: 64%
        \\range: 294.4 km
        \\charging: no
        \\plugged in: yes
        \\charge limit: 80%
        \\locked: yes
        \\odometer: 18234.6 km
        \\inside: 4.5 °C
        \\outside: -3 °C
        \\climate: off, set to 21 °C
        \\seat heating: front right 2
        \\data: from the last minutes
        \\
    , try statusLines(a, &cfg, d, 1795400030000));
    // location only when the file says so; an hour old
    const loc = try teslaCfg(a, "location = yes\n");
    const s = try statusLines(a, &loc, d, 1795400000000 + 3600 * 1000);
    try t.expect(std.mem.indexOf(u8, s, "location: 50.1, 19.9\n") != null);
    try t.expect(std.mem.indexOf(u8, s, "data: from 60 minutes ago\n") != null);
    try t.expect(std.mem.indexOf(u8, s, "seat heating") == null);
}

test "climate_and_seats_are_read_back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on = jv.parse(a, "{\"climate_state\":{\"inside_temp\":4,\"outside_temp\":-3,\"is_climate_on\":true,\"driver_temp_setting\":21,\"seat_heater_left\":3}}").?;
    try t.expectEqualStrings("Climate on, set to 21 °C; inside 4 °C, outside -3 °C.", try climateReadBack(a, on, true, null));
    try t.expectEqualStrings("Climate on, set to 21 °C; inside 4 °C, outside -3 °C.", try climateReadBack(a, on, true, 21));
    try t.expectEqualStrings("Set to 21 °C; climate is on; inside 4 °C, outside -3 °C.", try climateReadBack(a, on, null, 21));
    try t.expectEqualStrings("The car accepted it, but it still reads climate on; check with car_status in a minute.", try climateReadBack(a, on, false, null));
    try t.expectEqualStrings("The car accepted it, but it reads set to 21 °C; check with car_status in a minute.", try climateReadBack(a, on, true, 23));
    const off = jv.parse(a, "{\"climate_state\":{\"inside_temp\":19.5,\"is_climate_on\":false,\"driver_temp_setting\":21}}").?;
    try t.expectEqualStrings("Climate off; inside 19.5 °C.", try climateReadBack(a, off, false, null));
    try t.expectEqualStrings("Front left seat heating at 3 of 3.", try seatReadBack(a, on, .front_left, 3));
    try t.expectEqualStrings("The car accepted it, but it reads front left seat heating at 3 of 3; check with car_status in a minute.", try seatReadBack(a, on, .front_left, 1));
    try t.expectEqualStrings("Rear right seat heating off.", try seatReadBack(a, jv.parse(a, "{\"climate_state\":{\"seat_heater_rear_right\":0}}").?, .rear_right, 0));
    try t.expectEqual(@as(u8, 4), Seat.rear_center.heater());
}

test "the_sign_in_link_and_the_pasted_address" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try teslaCfg(a, "");
    try t.expectEqualStrings("https://auth.tesla.com/oauth2/v3/authorize?response_type=code&client_id=app-1&redirect_uri=https%3A%2F%2Fexample.com%2Fcallback&scope=openid%20offline_access%20vehicle_device_data%20vehicle_cmds%20vehicle_charging_cmds&state=s1&prompt_missing_scopes=true", try authorizeLink(a, &cfg, "s1"));
    try t.expectEqualStrings("NA_abc", try codeFrom(a, "https://example.com/callback?locale=en-US&code=NA_abc&state=s1&issuer=x\n", "s1"));
    try t.expectEqualStrings("NA_abc", try codeFrom(a, "  NA_abc \r\n", "s1"));
    try t.expectError(error.StateMismatch, codeFrom(a, "https://example.com/callback?code=NA_abc&state=other", "s1"));
    try t.expectError(error.StateMismatch, codeFrom(a, "https://example.com/callback?code=NA_abc", "s1"));
    try t.expectError(error.NoCode, codeFrom(a, "https://example.com/callback?error=access_denied&state=s1", "s1"));
    try t.expectError(error.NoCode, codeFrom(a, "", "s1"));
}

test "tesla_refusals_said_plainly" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("the car is asleep or offline (HTTP 408: vehicle unavailable: vehicle is offline or asleep)", try refusalText(a, 408, "{\"response\":null,\"error\":\"vehicle unavailable: vehicle is offline or asleep\",\"error_description\":\"\"}"));
    try t.expect(std.mem.startsWith(u8, try refusalText(a, 500, "{\"response\":null,\"error\":\"vehicle rejected request: your public key has not been paired with the vehicle\"}"), "the car doesn't know the application's key yet"));
    try t.expect(std.mem.startsWith(u8, try refusalText(a, 403, "{\"response\":null,\"error\":\"Tesla Vehicle Command Protocol required, please refer to the documentation here\"}"), "the command reached the Fleet API unsigned"));
    try t.expectEqualStrings("Tesla's rate limit: try later (HTTP 429)", try refusalText(a, 429, "not json"));
}

test "the_token_file_is_owner_only_and_replaced_whole" {
    // listed below: on Linux a directory opened without iterate can't be
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "car.ini.token" });
    try t.expectError(error.FileNotFound, readToken(a, t.io, path));
    try writeToken(t.io, path, "rt-1");
    try t.expectEqualStrings("rt-1", try readToken(a, t.io, path));
    try writeToken(t.io, path, "rt-2\"x");
    try t.expectEqualStrings("rt-2\"x", try readToken(a, t.io, path));
    if (@import("builtin").os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    // nothing left beside it
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(t.io)) |_| n += 1;
    try t.expectEqual(@as(usize, 1), n);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bad.token", .data = "{}" });
    try t.expectError(error.NotAToken, readToken(a, t.io, try std.fs.path.join(a, &.{ dir, "bad.token" })));
}
