//! Command line to a Request. Pure: no I/O.
const std = @import("std");
const frame = @import("frame.zig");
const watch = @import("watch.zig");
const Rect = frame.Rect;

pub const Source = union(enum) { screen, window: []const u8, camera: ?[]const u8 };
pub const Command = enum { snap, wait, diff, drop, text, windows, help, version };

pub const Request = struct {
    cmd: Command,
    source: Source = .screen,
    region: ?Rect = null,
    ignore: []Rect = &.{},
    mode: ?watch.Mode = null,
    timeout_ms: u32 = 120_000,
    fps: u32 = 30,
    name: ?[]const u8 = null,
    since: ?[]const u8 = null,
    accurate: bool = false,
    json: bool = false,
    help_topic: ?[]const u8 = null,

    pub fn deinit(r: *Request, alloc: std.mem.Allocator) void {
        alloc.free(r.ignore);
    }
};

pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(d: *Diag, comptime fmt: []const u8, a: anytype) void {
        const s = std.fmt.bufPrint(&d.buf, fmt, a) catch d.buf[0..];
        d.len = s.len;
    }
    pub fn msg(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }
};

pub const Error = error{ Usage, OutOfMemory };

const Flag = enum { source, window, camera, region, ignore, change, still, text, since, name, timeout, fps, accurate, json };

fn allowed(cmd: Command, f: Flag) bool {
    return switch (cmd) {
        .snap => switch (f) {
            .source, .window, .camera, .region, .name, .json => true,
            else => false,
        },
        .wait => switch (f) {
            .source, .window, .camera, .region, .ignore, .change, .still, .text, .since, .timeout, .fps, .json => true,
            else => false,
        },
        .diff => f == .since or f == .json,
        .text => switch (f) {
            .source, .window, .camera, .region, .accurate, .json => true,
            else => false,
        },
        .windows => f == .json,
        .drop, .help, .version => false,
    };
}

pub fn parse(alloc: std.mem.Allocator, argv: []const []const u8, diag: *Diag) Error!Request {
    if (argv.len == 0) {
        diag.set("missing command; run 'headsight help'", .{});
        return error.Usage;
    }
    const first = argv[0];
    const cmd: Command = if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h"))
        .help
    else if (std.mem.eql(u8, first, "--version"))
        .version
    else
        std.meta.stringToEnum(Command, first) orelse {
            diag.set("unknown command '{s}'; run 'headsight help'", .{first});
            return error.Usage;
        };

    var req = Request{ .cmd = cmd };
    var ignore: std.ArrayList(Rect) = .empty;
    errdefer ignore.deinit(alloc);
    var positional: ?[]const u8 = null;
    var modes: u32 = 0;
    var source_set = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (positional != null or !(cmd == .drop or cmd == .help)) {
                diag.set("unexpected argument '{s}' for '{s}'", .{ arg, @tagName(cmd) });
                return error.Usage;
            }
            positional = arg;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const key = arg[2 .. eq orelse arg.len];
        const inline_val: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
        const flag = std.meta.stringToEnum(Flag, key) orelse {
            diag.set("unknown option --{s} for '{s}'", .{ key, @tagName(cmd) });
            return error.Usage;
        };
        if (!allowed(cmd, flag)) {
            diag.set("--{s} does not apply to '{s}'", .{ key, @tagName(cmd) });
            return error.Usage;
        }
        switch (flag) {
            .change, .accurate, .json => {
                if (inline_val != null) {
                    diag.set("--{s} takes no value", .{key});
                    return error.Usage;
                }
                switch (flag) {
                    .change => {
                        req.mode = .change;
                        modes += 1;
                    },
                    .accurate => req.accurate = true,
                    .json => req.json = true,
                    else => unreachable,
                }
                continue;
            },
            .still => {
                const ms = if (inline_val) |v| std.fmt.parseInt(u32, v, 10) catch {
                    diag.set("--still=MS needs milliseconds, e.g. --still=1500", .{});
                    return error.Usage;
                } else 800;
                req.mode = .{ .still = ms };
                modes += 1;
                continue;
            },
            else => {},
        }
        const val = inline_val orelse blk: {
            i += 1;
            if (i >= argv.len) {
                diag.set("--{s} needs a value", .{key});
                return error.Usage;
            }
            break :blk argv[i];
        };
        switch (flag) {
            .source => {
                if (std.mem.eql(u8, val, "screen")) {
                    req.source = .screen;
                } else if (std.mem.eql(u8, val, "camera")) {
                    if (req.source != .camera) req.source = .{ .camera = null };
                } else {
                    diag.set("--source is screen or camera, not '{s}'", .{val});
                    return error.Usage;
                }
                if (source_set and req.source == .window) {
                    diag.set("--source and --window can't be combined", .{});
                    return error.Usage;
                }
                source_set = true;
            },
            .window => {
                if (req.source == .camera) {
                    diag.set("--window can't be combined with the camera", .{});
                    return error.Usage;
                }
                req.source = .{ .window = val };
                source_set = true;
            },
            .camera => {
                if (req.source == .window) {
                    diag.set("--camera can't be combined with --window", .{});
                    return error.Usage;
                }
                req.source = .{ .camera = val };
                source_set = true;
            },
            .region => req.region = try parseRect("--region", val, diag),
            .ignore => try ignore.append(alloc, try parseRect("--ignore", val, diag)),
            .text => {
                if (val.len == 0) {
                    diag.set("--text needs some text to look for", .{});
                    return error.Usage;
                }
                req.mode = .{ .text = val };
                modes += 1;
            },
            .since, .name => {
                if (!validName(val)) {
                    diag.set("bad name '{s}': use letters, digits, '.', '_', '-' (up to 64)", .{val});
                    return error.Usage;
                }
                if (flag == .since) req.since = val else req.name = val;
            },
            .timeout => {
                const secs = std.fmt.parseFloat(f64, val) catch -1;
                if (!(secs > 0 and secs <= 86_400)) {
                    diag.set("--timeout needs seconds, e.g. --timeout 30", .{});
                    return error.Usage;
                }
                req.timeout_ms = @intFromFloat(@round(secs * 1000));
            },
            .fps => {
                const n = std.fmt.parseInt(u32, val, 10) catch 0;
                if (n < 1 or n > 60) {
                    diag.set("--fps is 1 to 60", .{});
                    return error.Usage;
                }
                req.fps = n;
            },
            .change, .still, .accurate, .json => unreachable,
        }
    }

    switch (cmd) {
        .wait => {
            if (modes != 1) {
                diag.set("wait needs exactly one of --change, --still[=MS], --text TEXT", .{});
                return error.Usage;
            }
            if (req.since != null and source_set) {
                diag.set("--since watches the reference's own window, screen or camera; leave out --window, --source and --camera", .{});
                return error.Usage;
            }
        },
        .diff => if (req.since == null) {
            diag.set("diff needs --since NAME (a reference made with 'snap --name NAME')", .{});
            return error.Usage;
        },
        .drop => {
            const n = positional orelse {
                diag.set("drop needs a reference name", .{});
                return error.Usage;
            };
            if (!validName(n)) {
                diag.set("bad name '{s}': use letters, digits, '.', '_', '-' (up to 64)", .{n});
                return error.Usage;
            }
            req.name = n;
        },
        .help => req.help_topic = positional,
        else => {},
    }
    req.ignore = try ignore.toOwnedSlice(alloc);
    return req;
}

fn parseRect(flag: []const u8, s: []const u8, diag: *Diag) error{Usage}!Rect {
    var it = std.mem.splitScalar(u8, s, ',');
    var v: [4]u32 = undefined;
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 4) break;
        v[n] = std.fmt.parseInt(u32, std.mem.trim(u8, part, " "), 10) catch {
            n = 5;
            break;
        };
    }
    if (n == 4) {
        _ = std.math.add(u32, v[0], v[2]) catch {
            n = 5;
        };
        _ = std.math.add(u32, v[1], v[3]) catch {
            n = 5;
        };
    }
    if (n != 4 or v[2] == 0 or v[3] == 0) {
        diag.set("{s} needs X,Y,W,H in pixels with W and H above 0, e.g. 0,0,800,600", .{flag});
        return error.Usage;
    }
    return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

pub fn checkRegion(r: Rect, src_w: u32, src_h: u32, diag: *Diag) error{Usage}!void {
    if (!(Rect{ .x = 0, .y = 0, .w = src_w, .h = src_h }).contains(r)) {
        diag.set("region {d},{d},{d},{d} is outside the source ({d}x{d})", .{ r.x, r.y, r.w, r.h, src_w, src_h });
        return error.Usage;
    }
}

/// Reference names: letters, digits, '.', '_', '-', 1 to 64 characters, not starting with '.'.
pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64 or s[0] == '.') return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

// ---- tests ----

const testing = std.testing;

fn ok(argv: []const []const u8) !Request {
    var d = Diag{};
    return parse(testing.allocator, argv, &d) catch |e| {
        std.debug.print("unexpected usage error: {s}\n", .{d.msg()});
        return e;
    };
}

fn bad(argv: []const []const u8) ![]const u8 {
    const S = struct {
        var d = Diag{};
    };
    if (parse(testing.allocator, argv, &S.d)) |r| {
        var req = r;
        req.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |e| {
        try testing.expectEqual(error.Usage, e);
        return S.d.msg();
    }
}

test "wait_change_window" {
    var r = try ok(&.{ "wait", "--change", "--window", "Safari", "--timeout", "60" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Command.wait, r.cmd);
    try testing.expectEqualStrings("Safari", r.source.window);
    try testing.expect(r.mode.? == .change);
    try testing.expectEqual(@as(u32, 60_000), r.timeout_ms);
}

test "still_default_and_value" {
    var a = try ok(&.{ "wait", "--still" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 800), a.mode.?.still);
    var b = try ok(&.{ "wait", "--still=1500" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1500), b.mode.?.still);
}

test "wait_needs_one_mode" {
    const m = try bad(&.{"wait"});
    try testing.expect(std.mem.indexOf(u8, m, "--change") != null);
    try testing.expect(std.mem.indexOf(u8, m, "--still") != null);
    try testing.expect(std.mem.indexOf(u8, m, "--text") != null);
    _ = try bad(&.{ "wait", "--change", "--still" });
}

test "region_parse_errors" {
    _ = try bad(&.{ "snap", "--region", "1,2,3" });
    _ = try bad(&.{ "snap", "--region", "a,b,c,d" });
    _ = try bad(&.{ "snap", "--region", "0,0,0,10" });
    var r = try ok(&.{ "snap", "--region=10,20,300,400" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 300, .h = 400 }, r.region.?);
}

test "region_outside_source" {
    var d = Diag{};
    try testing.expectError(error.Usage, checkRegion(.{ .x = 3000, .y = 0, .w = 100, .h = 100 }, 3024, 1964, &d));
    try testing.expect(std.mem.indexOf(u8, d.msg(), "3024x1964") != null);
    try checkRegion(.{ .x = 0, .y = 0, .w = 3024, .h = 1964 }, 3024, 1964, &d);
}

test "camera_name_implies_camera" {
    var r = try ok(&.{ "snap", "--camera", "FaceTime HD" });
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("FaceTime HD", r.source.camera.?);
    var s = try ok(&.{ "snap", "--source", "camera" });
    defer s.deinit(testing.allocator);
    try testing.expect(s.source == .camera and s.source.camera == null);
}

test "diff_requires_since" {
    _ = try bad(&.{"diff"});
    var r = try ok(&.{ "diff", "--since", "before" });
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("before", r.since.?);
}

test "bad_names_rejected" {
    try testing.expect(!validName("../x"));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("a" ** 65));
    try testing.expect(validName("before-1.v_2"));
    _ = try bad(&.{ "snap", "--name", "../x" });
    _ = try bad(&.{ "drop", "a/b" });
}

test "unknown_flag" {
    const m = try bad(&.{ "wait", "--change", "--frobnicate" });
    try testing.expect(std.mem.indexOf(u8, m, "--frobnicate") != null);
}

test "timeout_decimal" {
    var r = try ok(&.{ "wait", "--text", "Done", "--timeout", "1.5" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1500), r.timeout_ms);
    try testing.expectEqualStrings("Done", r.mode.?.text);
}

test "since_refuses_an_explicit_source" {
    const m = try bad(&.{ "wait", "--change", "--since", "before", "--window", "Safari" });
    try testing.expect(std.mem.indexOf(u8, m, "--since") != null);
    _ = try bad(&.{ "wait", "--change", "--source", "camera", "--since", "before" });
    var r = try ok(&.{ "wait", "--change", "--since", "before" });
    defer r.deinit(testing.allocator);
}

test "region_overflow_rejected" {
    _ = try bad(&.{ "snap", "--region", "4294967295,0,10,10" });
    _ = try bad(&.{ "wait", "--change", "--ignore", "0,4294967290,10,10" });
}

test "ignore_repeatable_and_help" {
    var r = try ok(&.{ "wait", "--change", "--ignore", "0,0,10,10", "--ignore=20,20,5,5" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.ignore.len);
    var h = try ok(&.{ "help", "wait" });
    defer h.deinit(testing.allocator);
    try testing.expectEqualStrings("wait", h.help_topic.?);
    _ = try bad(&.{ "snap", "--change" });
}
