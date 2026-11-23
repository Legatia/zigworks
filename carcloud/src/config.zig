//! The car file: which car, through which Smartcar application, and which
//! commands the agent may send. An INI file:
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
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");

pub const Command = enum {
    charge_start,
    charge_stop,
    charge_limit,
    lock,
    unlock,

    /// The path under /vehicles/{id}/commands/.
    pub fn path(c: Command) []const u8 {
        return switch (c) {
            .charge_start => "charge/start",
            .charge_stop => "charge/stop",
            .charge_limit => "charge/set-limit",
            .lock => "security/lock",
            .unlock => "security/unlock",
        };
    }
};

pub const Config = struct {
    name: []const u8 = "the car",
    vehicle_id: []const u8 = "",
    user_id: []const u8 = "",
    client_id: []const u8 = "",
    api: []const u8 = "https://vehicle.api.smartcar.com/v3",
    token_url: []const u8 = "https://iam.smartcar.com/oauth2/token",
    allow: []const Command = &.{},
    limit_min: u8 = 60,
    limit_max: u8 = 90,
    per_day: u32 = 10,
    min_between_s: u32 = 60,
    location: bool = false,
    log_path: []const u8 = "",

    pub fn allows(c: *const Config, x: Command) bool {
        for (c.allow) |a| if (a == x) return true;
        return false;
    }
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| {
        diag.* = .{ .what = try std.fmt.allocPrint(a, "can't read {s}: {s}", .{ path, @errorName(e) }) };
        return error.BadConfig;
    };
    var c = try parse(a, text, diag);
    if (c.log_path.len > 0 and !std.fs.path.isAbsolute(c.log_path))
        c.log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(path) orelse ".", c.log_path });
    return c;
}

pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Config {
    var bad: usize = 0;
    const entries = ini.parse(a, text, &bad) catch return fail(diag, bad, "not a key = value line or [section]");
    var c: Config = .{};
    for (entries) |e| {
        if (!std.mem.eql(u8, e.section, "car")) return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown section [{s}]", .{e.section}));
        const k = e.key;
        const v = e.value;
        if (eql(k, "name")) {
            c.name = v;
        } else if (eql(k, "vehicle_id")) {
            c.vehicle_id = v;
        } else if (eql(k, "user_id")) {
            c.user_id = v;
        } else if (eql(k, "client_id")) {
            c.client_id = v;
        } else if (eql(k, "api")) {
            c.api = std.mem.trimEnd(u8, v, "/");
        } else if (eql(k, "token_url")) {
            c.token_url = v;
        } else if (eql(k, "allow")) {
            var list: std.ArrayList(Command) = .empty;
            var it = std.mem.tokenizeAny(u8, v, ", \t");
            while (it.next()) |w| try list.append(a, std.meta.stringToEnum(Command, w) orelse return fail(diag, e.line, try std.fmt.allocPrint(a, "no command called {s}: charge_start, charge_stop, charge_limit, lock, unlock", .{w})));
            c.allow = list.items;
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
        } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s}", .{k}));
    }
    if (c.vehicle_id.len == 0) return fail(diag, 0, "no vehicle_id in [car]");
    if (c.user_id.len == 0) return fail(diag, 0, "no user_id in [car]");
    if (c.client_id.len == 0) return fail(diag, 0, "no client_id in [car]");
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
