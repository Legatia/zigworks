//! calmcp: the owner's CalDAV calendars (iCloud, Fastmail, Nextcloud,
//! Google) as a few named tools for an AI agent, over MCP on stdio:
//! reads, and changes only where the calendar file allows, each checked
//! and read back.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const caldav = @import("caldav.zig");
const server = @import("server.zig");
const tz = @import("tz.zig");
const jv = @import("jv.zig");

const usage =
    \\usage: calmcp CAL.ini               serve MCP on stdin and stdout (what an agent starts)
    \\       calmcp check CAL.ini         read the calendar file, then each calendar, and say the next event
    \\       calmcp discover URL USER     print a calendar file for the account's calendars: the server's
    \\                                    calendar for new events may change, the others are read only
    \\       calmcp version
    \\
    \\Secrets come from the environment, never from the file: CALDAV_PASSWORD (an app
    \\password: iCloud, Fastmail, Nextcloud) for auth = password; CALDAV_TOKEN, or
    \\CALDAV_REFRESH_TOKEN and CALDAV_CLIENT_SECRET, for auth = token (Google).
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(io, usage, 2);
    const cmd = args[1];
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try out(io, "calmcp " ++ build_options.version ++ "\n");
        return 0;
    }
    const env = init.environ_map;
    const secret: caldav.Secret = .{
        .password = env.get("CALDAV_PASSWORD") orelse "",
        .token = env.get("CALDAV_TOKEN") orelse "",
        .refresh = env.get("CALDAV_REFRESH_TOKEN") orelse "",
        .client_secret = env.get("CALDAV_CLIENT_SECRET") orelse "",
    };
    if (eql(cmd, "discover")) {
        if (args.len != 4) return fail(io, usage, 2);
        return discover(init.gpa, a, io, args[2], args[3], secret);
    }
    const check = eql(cmd, "check") and args.len == 3;
    if (!check and !(args.len == 2 and cmd.len > 0 and cmd[0] != '-')) return fail(io, usage, 2);
    const path = if (check) args[2] else cmd;
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "calmcp: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    switch (cfg.auth) {
        .password => if (secret.password.len == 0) return fail(io, "calmcp: auth = password needs CALDAV_PASSWORD in the environment (an app password)\n", 1),
        .token => if (secret.token.len == 0 and secret.refresh.len == 0) return fail(io, "calmcp: auth = token needs CALDAV_TOKEN (or CALDAV_REFRESH_TOKEN) in the environment\n", 1),
    }
    var dav: caldav.Client = .init(init.gpa, io, &cfg, secret);
    defer dav.deinit();
    if (check) return checkCalendars(init.gpa, a, io, &cfg, &dav);
    server.run(init.gpa, io, &cfg, &dav) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    return 0;
}

/// Each calendar read (its name, whether calmcp may change it), then the
/// next event, as an agent would read it.
fn checkCalendars(gpa: std.mem.Allocator, a: std.mem.Allocator, io: Io, cfg: *const config.Config, dav: *caldav.Client) !u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "The calendars of {s} at {s}, times in {s}:\n", .{ if (cfg.user.len > 0) cfg.user else "the account", cfg.url, cfg.zone_name });
    var failed = false;
    for (cfg.calendars) |cal| {
        const info = dav.info(a, cal.url) catch {
            try o.print(a, "{s}: {s}\n", .{ cal.name, dav.why });
            failed = true;
            continue;
        };
        if (!info.events) {
            try o.print(a, "{s}: it holds no events (tasks?): leave it out\n", .{cal.name});
            failed = true;
            continue;
        }
        if (cal.change and !info.writable) {
            try o.print(a, "{s}: change = yes, but the server doesn't let this account write it\n", .{cal.name});
        } else try o.print(a, "{s}: {s}\n", .{ cal.name, if (cal.change) "calmcp may change it" else "read only" });
    }
    if (failed) {
        Io.File.stderr().writeStreamingAll(io, o.items) catch {};
        return 1;
    }
    // the next event, through the same reading the tools use
    var s = server.Server.init(gpa, io, cfg, dav) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    defer s.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    s.captured = &got;
    const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    var next: []const u8 = "";
    var day: i64 = 0;
    // a week at a time, up to eight weeks on
    while (day < 56 and next.len == 0) : (day += 7) {
        got.clearRetainingCapacity();
        try s.handleLine(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"cal_agenda\",\"arguments\":{{\"from\":\"{s}\",\"to\":\"{s}\"}}}}}}", .{ try isoUtc(a, now_s + day * 86400), try isoUtc(a, now_s + (day + 7) * 86400) }));
        const v = jv.parse(a, try a.dupe(u8, got.items)) orelse break;
        const text = jv.str(jv.at(v, &.{ "result", "content", "0", "text" })) orelse break;
        // the first event line (a time) under a day's heading
        var day_head: []const u8 = "";
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (l.len > 4 and std.ascii.isAlphabetic(l[0]) and !std.mem.startsWith(u8, l, "All day")) {
                day_head = l[0 .. std.mem.indexOfAny(u8, l, ":(") orelse l.len];
                continue;
            }
            if (l.len > 0 and (std.ascii.isDigit(l[0]) or std.mem.startsWith(u8, l, "All day"))) {
                const bracket = std.mem.lastIndexOf(u8, l, " [") orelse l.len;
                next = try std.fmt.allocPrint(a, "{s} {s}", .{ std.mem.trim(u8, day_head, " "), l[0..bracket] });
                break;
            }
        }
    }
    try o.print(a, "Next: {s}\n", .{if (next.len > 0) next else "nothing in the next eight weeks"});
    if (cfg.anyChange()) try o.appendSlice(a, "Changes calmcp may make, each asked about first: cal_create, cal_move, cal_cancel, cal_reply.\n") else try o.appendSlice(a, "It only reads: no calendar has change = yes.\n");
    try out(io, o.items);
    return 0;
}

/// "2026-11-23T09:30:00Z".
fn isoUtc(a: std.mem.Allocator, t: i64) ![]const u8 {
    const c = tz.civil(@divFloor(t, 86400));
    const sod: u64 = @intCast(@mod(t, 86400));
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u64, @intCast(c.y)), c.m, c.d, sod / 3600, sod / 60 % 60, sod % 60 });
}

/// A short name for a calendar: its name in lower case, a-z, 0-9 and -.
fn keyOf(a: std.mem.Allocator, name: []const u8, taken: []const []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var dash = false;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (dash and o.items.len > 0) try o.append(a, '-');
            dash = false;
            if (o.items.len < 28) try o.append(a, std.ascii.toLower(ch));
        } else dash = true;
    }
    const base = if (o.items.len == 0) "calendar" else o.items;
    var key = base;
    var n: usize = 2;
    while (for (taken) |t| {
        if (std.mem.eql(u8, t, key)) break true;
    } else false) : (n += 1) key = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
    return key;
}

fn discover(gpa: std.mem.Allocator, a: std.mem.Allocator, io: Io, url: []const u8, user: []const u8, secret: caldav.Secret) !u8 {
    const origin = config.originOf(url) orelse return fail(io, "calmcp: discover URL USER: URL like https://caldav.fastmail.com\n", 2);
    const auth: config.Auth = if (secret.password.len > 0) .password else if (secret.token.len > 0 or secret.refresh.len > 0) .token else return fail(io, "calmcp: discover needs CALDAV_PASSWORD (an app password) or CALDAV_TOKEN in the environment\n", 1);
    const cfg: config.Config = .{ .url = origin, .user = user, .auth = auth };
    var dav: caldav.Client = .init(gpa, io, &cfg, secret);
    defer dav.deinit();
    const found = dav.discover(a, url) catch return fail(io, try std.fmt.allocPrint(a, "calmcp: discover: {s}\n", .{if (dav.why.len > 0) dav.why else "the server didn't answer as CalDAV"}), 1);
    // which may change: the server's default for new events, else the first it lets write
    var pick: ?usize = null;
    for (found.calendars, 0..) |c, i| if (c.events and c.writable and std.mem.eql(u8, c.url, found.default)) {
        pick = i;
    };
    if (pick == null) for (found.calendars, 0..) |c, i| if (c.events and c.writable) {
        pick = i;
        break;
    };
    var zone: []const u8 = "";
    if (pick) |p| zone = tz.canonical(found.calendars[p].zone) orelse "";
    if (zone.len == 0) for (found.calendars) |c| if (tz.canonical(c.zone)) |z| {
        zone = z;
        break;
    };
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "; Written by calmcp discover from {s} as {s}.\n; Read it through, then: calmcp check FILE\n; change = yes lets calmcp create, move, cancel and answer invitations in\n; that calendar (an agent asks you before each); the others it only reads.\n\n[account]\nurl = {s}\nuser = {s}\nauth = {s}\n", .{ url, user, origin, user, @tagName(auth) });
    if (zone.len > 0) try o.print(a, "zone = {s}\n", .{zone}) else try o.appendSlice(a, "zone = UTC   ; your time zone, an IANA name like Europe/Warsaw (the server didn't say)\n");
    if (found.email.len > 0) try o.print(a, "email = {s}\n", .{found.email}) else try o.appendSlice(a, "; email = you@example.com   ; your address in invitations (cal_reply needs it)\n");
    try o.appendSlice(a, "log = calmcp.jsonl\n");
    var keys: std.ArrayList([]const u8) = .empty;
    var left: std.ArrayList([]const u8) = .empty;
    var summary: std.ArrayList([]const u8) = .empty;
    for (found.calendars, 0..) |c, i| {
        const name = if (c.name.len > 0) c.name else "Calendar";
        if (!c.events) {
            try left.append(a, try std.fmt.allocPrint(a, "{s} (tasks, not events)", .{name}));
            continue;
        }
        const key = try keyOf(a, name, keys.items);
        try keys.append(a, key);
        const here = if (std.mem.startsWith(u8, c.url, origin)) c.url[origin.len..] else c.url;
        const change = pick != null and pick.? == i;
        try o.appendSlice(a, "\n");
        if (change) try o.print(a, "; {s}: {s}\n", .{ name, if (std.mem.eql(u8, c.url, found.default)) "the server's calendar for new events" else "the first you may write" });
        if (!c.writable) try o.print(a, "; {s}: read only (the server doesn't let this account write it)\n", .{name});
        try o.print(a, "[calendar {s}]\nurl = {s}\nname = {s}\nchange = {s}\n", .{ key, here, name, if (change) "yes" else "no" });
        try summary.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ name, if (change) " (may change)" else if (!c.writable) " (read only)" else "" }));
    }
    if (left.items.len > 0) try o.print(a, "\n; Left out: {s}\n", .{try std.mem.join(a, ", ", left.items)});
    if (keys.items.len == 0) return fail(io, "calmcp: discover: the account has no calendars of events\n", 1);
    try out(io, o.items);
    Io.File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(a, "Found {d} calendar{s}: {s}.\n", .{ keys.items.len, if (keys.items.len == 1) "" else "s", try std.mem.join(a, ", ", summary.items) })) catch {};
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

test "a_calendar_key_from_its_name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("personal", try keyOf(a, "Personal", &.{}));
    try std.testing.expectEqualStrings("work-team", try keyOf(a, "Work & Team!", &.{}));
    try std.testing.expectEqualStrings("personal-2", try keyOf(a, "personal", &.{"personal"}));
    try std.testing.expectEqualStrings("calendar", try keyOf(a, "Ż", &.{}));
}

test {
    _ = @import("tz.zig");
    _ = @import("ics.zig");
    _ = @import("rrule.zig");
    _ = @import("agenda.zig");
    _ = @import("xml.zig");
    _ = @import("config.zig");
    _ = @import("caldav.zig");
    _ = @import("edit.zig");
    _ = @import("server.zig");
    _ = @import("http.zig");
    _ = @import("ini.zig");
    _ = @import("jv.zig");
}
