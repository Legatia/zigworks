//! The car file: which car, through which carmaker's cloud, and which
//! commands the agent may send. An INI file, Smartcar's:
//!
//!   [car]
//!   name = The Model 3
//!   vehicle_id = 0d3a...          ; from Smartcar's Dashboard, after Connect
//!   user_id = 5a2b...             ; the Smartcar user the car was connected by
//!   client_id = ...               ; the application's id (its secret: SMARTCAR_CLIENT_SECRET)
//!   allow = charge_start, charge_stop, charge_limit, lock   ; unlock only if listed
//!   charge_limit = 60 90          ; the limits the agent may set, %
//!   commands_per_day = 10         ; at most this many commands in any 24 hours
//!   min_seconds_between = 60      ; and this long between two
//!   location = no                 ; yes: car_status shows where the car is
//!   log = carcloud.jsonl          ; optional: one line per command (relative: to this file)
//!   api = https://vehicle.api.smartcar.com/v3      ; (the default)
//!   token_url = https://iam.smartcar.com/oauth2/token
//!
//! or Tesla's Fleet API (`backend = tesla`), through the owner's own
//! developer application:
//!
//!   [car]
//!   backend = tesla
//!   vin = 5YJ3...                 ; the car's VIN (carcloud login lists them)
//!   client_id = ...               ; the application's (its secret: TESLA_CLIENT_SECRET, for login)
//!   redirect_uri = https://...    ; one the application lists, for carcloud login
//!   region = eu                   ; eu, na (North America, Asia-Pacific) or cn
//!   command_api = https://localhost:4443   ; tesla-http-proxy, which signs commands
//!   command_ca = proxy-cert.pem   ; its certificate
//!   token = car.ini.token         ; the sign-in (the default: this file's name + .token)
//!   allow = climate, seat_heat, charge_start, charge_stop, charge_limit
//!   climate_temp = 18 24          ; the temperatures the agent may set, °C
//!   wakes_per_day = 3             ; car_status may wake the car this often
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");

pub const Backend = enum { smartcar, tesla };

pub const Command = enum {
    charge_start,
    charge_stop,
    charge_limit,
    lock,
    unlock,

    /// The path under /vehicles/{id}/commands/ (Smartcar).
    pub fn path(c: Command) []const u8 {
        return switch (c) {
            .charge_start => "charge/start",
            .charge_stop => "charge/stop",
            .charge_limit => "charge/set-limit",
            .lock => "security/lock",
            .unlock => "security/unlock",
        };
    }

    /// The Fleet API command's name (Tesla).
    pub fn teslaName(c: Command) []const u8 {
        return switch (c) {
            .charge_start => "charge_start",
            .charge_stop => "charge_stop",
            .charge_limit => "set_charge_limit",
            .lock => "door_lock",
            .unlock => "door_unlock",
        };
    }
};

/// Tesla's own range for set_temps, °C.
pub const tesla_temp_min: f64 = 15;
pub const tesla_temp_max: f64 = 28;

pub const Config = struct {
    backend: Backend = .smartcar,
    name: []const u8 = "the car",
    vehicle_id: []const u8 = "",
    user_id: []const u8 = "",
    client_id: []const u8 = "",
    /// Smartcar's v3, or the Fleet API's address (Tesla).
    api: []const u8 = "",
    token_url: []const u8 = "",
    allow: []const Command = &.{},
    limit_min: u8 = 60,
    limit_max: u8 = 90,
    per_day: u32 = 10,
    min_between_s: u32 = 60,
    location: bool = false,
    log_path: []const u8 = "",
    // ---- Tesla ----
    vin: []const u8 = "",
    /// Where the owner signs in (carcloud login).
    auth_url: []const u8 = "",
    /// The token's audience: the region's Fleet API.
    audience: []const u8 = "",
    redirect_uri: []const u8 = "",
    /// tesla-http-proxy: commands are signed there.
    command_api: []const u8 = "",
    /// The proxy's certificate (PEM); "": the system's roots.
    command_ca: []const u8 = "",
    /// The sign-in: the refresh token, kept and replaced here.
    token_path: []const u8 = "",
    /// `allow = climate`: car_climate; `seat_heat`: car_seat_heat.
    climate: bool = false,
    seat_heat: bool = false,
    temp_min: f64 = 18,
    temp_max: f64 = 24,
    wakes_per_day: u32 = 3,

    pub fn allows(c: *const Config, x: Command) bool {
        for (c.allow) |a| if (a == x) return true;
        return false;
    }

    /// Whether any command at all may be sent.
    pub fn anyCommand(c: *const Config) bool {
        return c.allow.len > 0 or c.climate or c.seat_heat;
    }
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| {
        diag.* = .{ .what = try std.fmt.allocPrint(a, "can't read {s}: {s}", .{ path, @errorName(e) }) };
        return error.BadConfig;
    };
    var c = try parse(a, text, diag);
    try placeFiles(a, &c, path);
    return c;
}

/// The log, the token file and the proxy's certificate, relative to the
/// car file at `path`; the token file by default beside it.
pub fn placeFiles(a: Allocator, c: *Config, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    if (c.log_path.len > 0 and !std.fs.path.isAbsolute(c.log_path))
        c.log_path = try std.fs.path.join(a, &.{ dir, c.log_path });
    if (c.backend != .tesla) return;
    if (c.token_path.len == 0) c.token_path = try std.fmt.allocPrint(a, "{s}.token", .{path}) else if (!std.fs.path.isAbsolute(c.token_path))
        c.token_path = try std.fs.path.join(a, &.{ dir, c.token_path });
    if (c.command_ca.len > 0 and !std.fs.path.isAbsolute(c.command_ca))
        c.command_ca = try std.fs.path.join(a, &.{ dir, c.command_ca });
}

const regions = [_]struct { name: []const u8, api: []const u8 }{
    .{ .name = "eu", .api = "https://fleet-api.prd.eu.vn.cloud.tesla.com" },
    .{ .name = "na", .api = "https://fleet-api.prd.na.vn.cloud.tesla.com" },
    .{ .name = "cn", .api = "https://fleet-api.prd.cn.vn.cloud.tesla.cn" },
};
const region_help = "region: eu (Europe), na (North America, Asia-Pacific) or cn (China)";

pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Config {
    var bad: usize = 0;
    const entries = ini.parse(a, text, &bad) catch return fail(diag, bad, "not a key = value line or [section]");
    var c: Config = .{};
    var allow_line: usize = 0;
    var allow_words: []const u8 = "";
    var region: []const u8 = "";
    var region_line: usize = 0;
    // keys only one backend takes, and where they were
    var smartcar_key: ?ini.Entry = null;
    var tesla_key: ?ini.Entry = null;
    for (entries) |e| {
        if (!std.mem.eql(u8, e.section, "car")) return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown section [{s}]", .{e.section}));
        const k = e.key;
        const v = e.value;
        if (eql(k, "backend")) {
            c.backend = std.meta.stringToEnum(Backend, v) orelse return fail(diag, e.line, "backend: smartcar or tesla");
        } else if (eql(k, "name")) {
            c.name = v;
        } else if (eql(k, "vehicle_id")) {
            c.vehicle_id = v;
            smartcar_key = e;
        } else if (eql(k, "user_id")) {
            c.user_id = v;
            smartcar_key = e;
        } else if (eql(k, "client_id")) {
            c.client_id = v;
        } else if (eql(k, "api")) {
            c.api = std.mem.trimEnd(u8, v, "/");
        } else if (eql(k, "token_url")) {
            c.token_url = v;
        } else if (eql(k, "allow")) {
            allow_words = v;
            allow_line = e.line;
        } else if (eql(k, "charge_limit")) {
            var it = std.mem.tokenizeAny(u8, v, " \t,");
            const lo = std.fmt.parseInt(u8, it.next() orelse "", 10) catch return fail(diag, e.line, "charge_limit: two numbers, such as 60 90");
            const hi = std.fmt.parseInt(u8, it.next() orelse "", 10) catch return fail(diag, e.line, "charge_limit: two numbers, such as 60 90");
            // Smartcar takes 50 to 100
            if (lo < 50 or hi > 100 or lo > hi) return fail(diag, e.line, "charge_limit: within 50 and 100");
            c.limit_min = lo;
            c.limit_max = hi;
        } else if (eql(k, "commands_per_day")) {
            c.per_day = std.fmt.parseInt(u32, v, 10) catch return fail(diag, e.line, "commands_per_day: a number");
        } else if (eql(k, "min_seconds_between")) {
            c.min_between_s = std.fmt.parseInt(u32, v, 10) catch return fail(diag, e.line, "min_seconds_between: a number");
        } else if (eql(k, "location")) {
            c.location = eql(v, "yes") or eql(v, "on");
        } else if (eql(k, "log")) {
            c.log_path = v;
        } else if (eql(k, "vin")) {
            c.vin = v;
            tesla_key = e;
        } else if (eql(k, "region")) {
            region = v;
            region_line = e.line;
            tesla_key = e;
        } else if (eql(k, "auth_url")) {
            c.auth_url = v;
            tesla_key = e;
        } else if (eql(k, "redirect_uri")) {
            c.redirect_uri = v;
            tesla_key = e;
        } else if (eql(k, "command_api")) {
            c.command_api = std.mem.trimEnd(u8, v, "/");
            tesla_key = e;
        } else if (eql(k, "command_ca")) {
            c.command_ca = v;
            tesla_key = e;
        } else if (eql(k, "token")) {
            c.token_path = v;
            tesla_key = e;
        } else if (eql(k, "climate_temp")) {
            var it = std.mem.tokenizeAny(u8, v, " \t,");
            const lo = std.fmt.parseFloat(f64, it.next() orelse "") catch return fail(diag, e.line, "climate_temp: two numbers, such as 18 24");
            const hi = std.fmt.parseFloat(f64, it.next() orelse "") catch return fail(diag, e.line, "climate_temp: two numbers, such as 18 24");
            if (lo < tesla_temp_min or hi > tesla_temp_max or lo > hi) return fail(diag, e.line, "climate_temp: within 15 and 28 (Tesla's range), °C");
            c.temp_min = lo;
            c.temp_max = hi;
            tesla_key = e;
        } else if (eql(k, "wakes_per_day")) {
            c.wakes_per_day = std.fmt.parseInt(u32, v, 10) catch return fail(diag, e.line, "wakes_per_day: a number");
            tesla_key = e;
        } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s}", .{k}));
    }
    // allow, read once the backend is known
    if (allow_words.len > 0) {
        var list: std.ArrayList(Command) = .empty;
        var it = std.mem.tokenizeAny(u8, allow_words, ", \t");
        while (it.next()) |w| {
            if (eql(w, "climate") or eql(w, "seat_heat")) {
                if (c.backend != .tesla) return fail(diag, allow_line, try std.fmt.allocPrint(a, "{s}: Smartcar's v3 has no climate or seat heating (backend = tesla has)", .{w}));
                if (eql(w, "climate")) c.climate = true else c.seat_heat = true;
                continue;
            }
            const cmd = std.meta.stringToEnum(Command, w) orelse return fail(diag, allow_line, try std.fmt.allocPrint(a, "no command called {s}: charge_start, charge_stop, charge_limit, lock, unlock{s}", .{ w, if (c.backend == .tesla) ", climate, seat_heat" else "" }));
            try list.append(a, cmd);
        }
        c.allow = list.items;
    }
    switch (c.backend) {
        .smartcar => {
            if (tesla_key) |e| return fail(diag, e.line, try std.fmt.allocPrint(a, "{s} is for backend = tesla", .{e.key}));
            if (c.api.len == 0) c.api = "https://vehicle.api.smartcar.com/v3";
            if (c.token_url.len == 0) c.token_url = "https://iam.smartcar.com/oauth2/token";
            if (c.vehicle_id.len == 0) return fail(diag, 0, "no vehicle_id in [car]");
            if (c.user_id.len == 0) return fail(diag, 0, "no user_id in [car]");
            if (c.client_id.len == 0) return fail(diag, 0, "no client_id in [car]");
        },
        .tesla => {
            if (smartcar_key) |e| return fail(diag, e.line, try std.fmt.allocPrint(a, "{s} is Smartcar's: backend = tesla takes vin", .{e.key}));
            if (c.vin.len == 0) return fail(diag, 0, "no vin in [car] (carcloud login lists your cars)");
            if (c.client_id.len == 0) return fail(diag, 0, "no client_id in [car]: your Tesla developer application's");
            var region_api: []const u8 = "";
            if (region.len > 0) {
                for (regions) |r| if (eql(r.name, region)) {
                    region_api = r.api;
                };
                if (region_api.len == 0) return fail(diag, region_line, region_help);
            }
            if (c.api.len == 0) c.api = region_api;
            if (c.api.len == 0) return fail(diag, 0, region_help);
            c.audience = if (region_api.len > 0) region_api else c.api;
            if (c.token_url.len == 0) c.token_url = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token";
            if (c.auth_url.len == 0) c.auth_url = "https://auth.tesla.com/oauth2/v3/authorize";
            if (c.anyCommand() and c.command_api.len == 0) return fail(diag, allow_line, "allow lists commands, and Tesla takes them only signed: run tesla-http-proxy and set command_api = https://localhost:4443 (and command_ca, its certificate); see the README, With a Tesla");
        },
    }
    return c;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(diag: *Diag, line: usize, what: []const u8) error{BadConfig} {
    diag.* = .{ .line = line, .what = what };
    return error.BadConfig;
}

test "a car file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    const c = try parse(arena.allocator(), "[car]\nvehicle_id = v1\nuser_id = u1\nclient_id = c1\nallow = charge_start, lock\ncharge_limit = 55 95\n", &d);
    try std.testing.expect(c.allows(.lock) and !c.allows(.unlock));
    try std.testing.expectEqual(55, c.limit_min);
    try std.testing.expectError(error.BadConfig, parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = open_trunk\n", &d));
    try std.testing.expectError(error.BadConfig, parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\ncharge_limit = 20 90\n", &d));
}

test "a_tesla_car_file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const c = try parse(a, "[car]\nbackend = tesla\nvin = 5YJ3E7EB0KF000001\nclient_id = c1\nregion = eu\ncommand_api = https://localhost:4443\ncommand_ca = proxy.pem\nallow = charge_start, climate, seat_heat\nclimate_temp = 19 23.5\nwakes_per_day = 2\n", &d);
    try std.testing.expectEqual(Backend.tesla, c.backend);
    try std.testing.expectEqualStrings("https://fleet-api.prd.eu.vn.cloud.tesla.com", c.api);
    try std.testing.expectEqualStrings("https://fleet-api.prd.eu.vn.cloud.tesla.com", c.audience);
    try std.testing.expectEqualStrings("https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token", c.token_url);
    try std.testing.expectEqualStrings("https://auth.tesla.com/oauth2/v3/authorize", c.auth_url);
    try std.testing.expect(c.climate and c.seat_heat and c.allows(.charge_start) and !c.allows(.lock));
    try std.testing.expectEqual(@as(f64, 19), c.temp_min);
    try std.testing.expectEqual(@as(f64, 23.5), c.temp_max);
    try std.testing.expectEqual(@as(u32, 2), c.wakes_per_day);
    // na and cn, and the sim's own addresses
    try std.testing.expectEqualStrings("https://fleet-api.prd.na.vn.cloud.tesla.com", (try parse(a, "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = na\n", &d)).api);
    const sim = try parse(a, "[car]\nbackend = tesla\nvin = V\nclient_id = c\napi = http://127.0.0.1:9/\nauth_url = http://127.0.0.1:9/oauth2/v3/authorize\ntoken_url = http://127.0.0.1:9/oauth2/v3/token\n", &d);
    try std.testing.expectEqualStrings("http://127.0.0.1:9", sim.api);
    try std.testing.expectEqualStrings("http://127.0.0.1:9", sim.audience);
    // defaults: climate 18 to 24, 3 wakes a day, no commands
    const plain = try parse(a, "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\n", &d);
    try std.testing.expectEqual(@as(f64, 18), plain.temp_min);
    try std.testing.expectEqual(@as(f64, 24), plain.temp_max);
    try std.testing.expectEqual(@as(u32, 3), plain.wakes_per_day);
    try std.testing.expect(!plain.climate and !plain.anyCommand());
}

test "a_tesla_car_file_says_what_is_missing_or_wrong" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { text: []const u8, says: []const u8 };
    const cases = [_]Case{
        .{ .text = "[car]\nbackend = tesla\nclient_id = c\nregion = eu\n", .says = "no vin in [car]" },
        .{ .text = "[car]\nbackend = tesla\nvin = V\nregion = eu\n", .says = "no client_id in [car]" },
        .{ .text = "[car]\nbackend = tesla\nvin = V\nclient_id = c\n", .says = "region: eu (Europe), na (North America, Asia-Pacific) or cn (China)" },
        .{ .text = "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = mars\n", .says = "region: eu (Europe), na (North America, Asia-Pacific) or cn (China)" },
        // commands need the signing proxy
        .{ .text = "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\nallow = climate\n", .says = "command_api" },
        // Tesla's range is 15 to 28
        .{ .text = "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\nclimate_temp = 10 30\n", .says = "climate_temp: within 15 and 28" },
        .{ .text = "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\nallow = open_trunk\n", .says = "no command called open_trunk: charge_start, charge_stop, charge_limit, lock, unlock, climate, seat_heat" },
        // Smartcar's keys in a Tesla file, and Tesla's in Smartcar's
        .{ .text = "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\nuser_id = u\n", .says = "user_id is Smartcar's: backend = tesla takes vin" },
        .{ .text = "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nvin = V\n", .says = "vin is for backend = tesla" },
        .{ .text = "[car]\nbackend = bmw\n", .says = "backend: smartcar or tesla" },
    };
    for (cases) |cs| {
        var d: Diag = .{};
        try std.testing.expectError(error.BadConfig, parse(a, cs.text, &d));
        if (std.mem.indexOf(u8, d.what, cs.says) == null) {
            std.debug.print("said: {s}\nwanted: {s}\n", .{ d.what, cs.says });
            return error.TestUnexpectedResult;
        }
    }
}

test "a_smartcar_file_refuses_climate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    try std.testing.expectError(error.BadConfig, parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = charge_start, climate\n", &d));
    try std.testing.expectEqualStrings("climate: Smartcar's v3 has no climate or seat heating (backend = tesla has)", d.what);
    try std.testing.expectEqual(@as(usize, 5), d.line);
    // Smartcar's own file reads as before
    const c = try parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = charge_start, lock\n", &d);
    try std.testing.expectEqual(Backend.smartcar, c.backend);
    try std.testing.expectEqualStrings("https://vehicle.api.smartcar.com/v3", c.api);
    try std.testing.expectEqualStrings("https://iam.smartcar.com/oauth2/token", c.token_url);
    try std.testing.expectError(error.BadConfig, parse(arena.allocator(), "[car]\nvehicle_id = v\nuser_id = u\nclient_id = c\nallow = open_trunk\n", &d));
    try std.testing.expectEqualStrings("no command called open_trunk: charge_start, charge_stop, charge_limit, lock, unlock", d.what);
}

test "the_token_file_sits_beside_the_car_file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    var c = try parse(a, "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\ncommand_api = https://localhost:4443\ncommand_ca = proxy.pem\n", &d);
    try placeFiles(a, &c, "/etc/carcloud/car.ini");
    try std.testing.expectEqualStrings("/etc/carcloud/car.ini.token", c.token_path);
    try std.testing.expectEqualStrings("/etc/carcloud/proxy.pem", c.command_ca);
    var c2 = try parse(a, "[car]\nbackend = tesla\nvin = V\nclient_id = c\nregion = eu\ntoken = /var/lib/carcloud/tesla.token\n", &d);
    try placeFiles(a, &c2, "/etc/carcloud/car.ini");
    try std.testing.expectEqualStrings("/var/lib/carcloud/tesla.token", c2.token_path);
}
