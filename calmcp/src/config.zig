//! The calendar file: one CalDAV account, the owner's zone and address,
//! and the calendars calmcp reads, each saying whether calmcp may change
//! it. An INI file:
//!
//!   [account]
//!   url = https://caldav.fastmail.com   ; the server
//!   user = anna@fastmail.com
//!   auth = password                     ; CALDAV_PASSWORD (an app password); token: CALDAV_TOKEN (Google)
//!   zone = Europe/Warsaw                ; the owner's time zone
//!   email = anna@fastmail.com           ; the owner's address in invitations (cal_reply)
//!   writes_per_day = 20
//!   log = calmcp.jsonl                  ; one line per write (relative: to this file)
//!
//!   [calendar personal]
//!   url = /dav/calendars/user/anna@fastmail.com/Default/
//!   name = Personal
//!   change = yes                        ; calmcp may create, move, cancel and answer here (default: no)
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");
const tz = @import("tz.zig");

pub const Auth = enum { password, token };

pub const Calendar = struct {
    /// Its short name in the file (`[calendar NAME]`), in event ids.
    key: []const u8,
    /// The collection's address, whole (https://host/path/).
    url: []const u8,
    name: []const u8,
    change: bool = false,
};

pub const Config = struct {
    /// The server: scheme, host and port (and a path discover starts at).
    url: []const u8 = "",
    user: []const u8 = "",
    auth: Auth = .password,
    /// With `auth = token`: where an expired token is renewed.
    token_url: []const u8 = "",
    client_id: []const u8 = "",
    zone_name: []const u8 = "UTC",
    zone: tz.Zone = .utc,
    email: []const u8 = "",
    writes_per_day: u32 = 20,
    log_path: []const u8 = "",
    calendars: []const Calendar = &.{},

    pub fn find(c: *const Config, key: []const u8) ?*const Calendar {
        for (c.calendars) |*x| if (std.mem.eql(u8, x.key, key)) return x;
        return null;
    }

    /// Whether some calendar may change: the write tools are offered.
    pub fn anyChange(c: *const Config) bool {
        for (c.calendars) |x| if (x.change) return true;
        return false;
    }
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| {
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
    var cals: std.ArrayList(Calendar) = .empty;
    var raw_urls: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList(usize) = .empty;
    var seen_url = false;
    // the calendars in the order their headers come, keys or not
    var hl = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (hl.next()) |raw| {
        n += 1;
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, l, "[calendar") or !std.mem.endsWith(u8, l, "]")) continue;
        const name = std.mem.trim(u8, l["[calendar".len .. l.len - 1], " \t");
        if (!validKey(name)) return fail(diag, n, "[calendar NAME]: a-z, 0-9, - and _, up to 32");
        for (cals.items) |x| if (eql(x.key, name)) return fail(diag, n, try std.fmt.allocPrint(a, "[calendar {s}] twice", .{name}));
        try cals.append(a, .{ .key = name, .url = "", .name = name });
        try raw_urls.append(a, "");
        try lines.append(a, n);
    }
    for (entries) |e| {
        const k = e.key;
        const v = e.value;
        if (eql(e.section, "account")) {
            if (e.name.len > 0) return fail(diag, e.line, "[account] takes no name");
            if (eql(k, "url")) {
                c.url = originOf(v) orelse return fail(diag, e.line, "url: the server's address, like https://caldav.example.com");
                seen_url = true;
            } else if (eql(k, "user")) {
                c.user = v;
            } else if (eql(k, "auth")) {
                c.auth = std.meta.stringToEnum(Auth, v) orelse return fail(diag, e.line, "auth: password or token");
            } else if (eql(k, "token_url")) {
                if (originOf(v) == null) return fail(diag, e.line, "token_url: an https address");
                c.token_url = v;
            } else if (eql(k, "client_id")) {
                c.client_id = v;
            } else if (eql(k, "zone")) {
                c.zone = tz.lookup(v) orelse return fail(diag, e.line, try std.fmt.allocPrint(a, "zone: {s} is not a time zone calmcp knows (an IANA name such as Europe/Warsaw)", .{v}));
                c.zone_name = tz.canonical(v).?;
            } else if (eql(k, "email")) {
                c.email = v;
            } else if (eql(k, "writes_per_day")) {
                c.writes_per_day = std.fmt.parseInt(u32, v, 10) catch return fail(diag, e.line, "writes_per_day: a number");
            } else if (eql(k, "log")) {
                c.log_path = v;
            } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s}", .{k}));
        } else if (eql(e.section, "calendar")) {
            if (!validKey(e.name)) return fail(diag, e.line, "[calendar NAME]: a-z, 0-9, - and _, up to 32");
            const at = for (cals.items, 0..) |x, j| {
                if (eql(x.key, e.name)) break j;
            } else return fail(diag, e.line, "[calendar NAME]: a-z, 0-9, - and _, up to 32");
            const cal = &cals.items[at];
            if (eql(k, "url")) {
                raw_urls.items[at] = v;
            } else if (eql(k, "name")) {
                cal.name = v;
            } else if (eql(k, "change")) {
                cal.change = if (eql(v, "yes") or eql(v, "on")) true else if (eql(v, "no") or eql(v, "off")) false else return fail(diag, e.line, "change: yes or no");
            } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s} in [calendar {s}]", .{ k, e.name }));
        } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown section [{s}]", .{e.section}));
    }
    if (!seen_url) return fail(diag, 0, "no url in [account]: the server's address, like https://caldav.example.com");
    if (c.auth == .password and c.user.len == 0) return fail(diag, 0, "user: the account's user name (auth = password needs one)");
    if (cals.items.len == 0) return fail(diag, 0, "no [calendar NAME] section: calmcp check lists what discover finds");
    for (cals.items, raw_urls.items, lines.items) |*cal, raw, line| {
        if (raw.len == 0) return fail(diag, line, try std.fmt.allocPrint(a, "no url in [calendar {s}]", .{cal.key}));
        if (originOf(raw) != null) {
            cal.url = raw;
        } else if (raw[0] == '/') {
            cal.url = try std.fmt.allocPrint(a, "{s}{s}", .{ c.url, raw });
        } else return fail(diag, line, try std.fmt.allocPrint(a, "[calendar {s}] url: a path (/…/) or a whole address", .{cal.key}));
    }
    c.calendars = cals.items;
    return c;
}

/// The scheme, host and port of a URL ("https://host:8443"), or null.
pub fn originOf(url: []const u8) ?[]const u8 {
    const rest_at: usize = if (std.mem.startsWith(u8, url, "https://")) 8 else if (std.mem.startsWith(u8, url, "http://")) 7 else return null;
    const end = std.mem.indexOfScalarPos(u8, url, rest_at, '/') orelse url.len;
    if (end == rest_at) return null;
    for (url[rest_at..end]) |ch| if (ch <= ' ' or ch == '@' or ch >= 0x7f) return null;
    return url[0..end];
}

/// A short name: a-z, 0-9, - and _, up to 32.
pub fn validKey(k: []const u8) bool {
    if (k.len == 0 or k.len > 32) return false;
    for (k) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn fail(diag: *Diag, line: usize, what: []const u8) error{BadConfig} {
    diag.* = .{ .line = line, .what = what };
    return error.BadConfig;
}

const tt = std.testing;

test "a_calendar_file_reads_and_its_mistakes_are_named" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const c = try parse(a,
        \\[account]
        \\url = https://caldav.example.com/
        \\user = anna@example.com
        \\zone = Europe/Warsaw
        \\email = anna@example.com
        \\writes_per_day = 5
        \\[calendar personal]
        \\url = /dav/calendars/anna/personal/
        \\name = Personal
        \\change = yes
        \\[calendar holidays]
        \\url = https://other.example.com/holidays/
    , &d);
    try tt.expectEqualStrings("https://caldav.example.com", c.url);
    try tt.expectEqual(Auth.password, c.auth);
    try tt.expectEqual(@as(i32, 60), c.zone.std_off);
    try tt.expectEqual(@as(u32, 5), c.writes_per_day);
    try tt.expectEqual(@as(usize, 2), c.calendars.len);
    // a path is the server's; a whole address stays as it is
    try tt.expectEqualStrings("https://caldav.example.com/dav/calendars/anna/personal/", c.find("personal").?.url);
    try tt.expectEqualStrings("https://other.example.com/holidays/", c.find("holidays").?.url);
    try tt.expect(c.find("personal").?.change and !c.find("holidays").?.change);
    // a calendar without a name is called by its key
    try tt.expectEqualStrings("holidays", c.find("holidays").?.name);
    try tt.expect(c.anyChange());
    try tt.expectEqualStrings("https://caldav.example.com:8443", originOf("https://caldav.example.com:8443/dav/x").?);
    try tt.expect(originOf("caldav.example.com/dav") == null);
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "[account]\nurl = https://x\nuser = u\nzone = Mars/Olympus\n[calendar a]\nurl = /a/\n", "zone: Mars/Olympus is not a time zone calmcp knows" },
        .{ "[account]\nurl = https://x\nuser = u\n", "no [calendar NAME] section" },
        .{ "[account]\nurl = ftp://x\nuser = u\n[calendar a]\nurl = /a/\n", "url: the server's address, like https://caldav.example.com" },
        .{ "[account]\nurl = https://x\n[calendar a]\nurl = /a/\n", "user: the account's user name (auth = password needs one)" },
        .{ "[account]\nurl = https://x\nuser = u\n[calendar Bad Name]\nurl = /a/\n", "[calendar NAME]: a-z, 0-9, - and _, up to 32" },
        .{ "[account]\nurl = https://x\nuser = u\nauth = magic\n[calendar a]\nurl = /a/\n", "auth: password or token" },
        .{ "[account]\nurl = https://x\nuser = u\n[calendar a]\nurl = /a/\nchange = maybe\n", "change: yes or no" },
        .{ "[account]\nurl = https://x\nuser = u\n[calendar a]\n", "no url in [calendar a]" },
        .{ "[account]\nurl = https://x\nuser = u\nsecret = x\n[calendar a]\nurl = /a/\n", "unknown key secret" },
    };
    for (bad) |b| {
        try tt.expectError(error.BadConfig, parse(a, b[0], &d));
        if (std.mem.indexOf(u8, d.what, b[1]) == null) {
            std.debug.print("want {s}, got {s}\n", .{ b[1], d.what });
            return error.TestUnexpectedResult;
        }
    }
    // a token account needs no user
    const tok = try parse(a, "[account]\nurl = https://apidata.googleusercontent.com\nauth = token\n[calendar main]\nurl = /caldav/v2/anna%40gmail.com/events/\n", &d);
    try tt.expectEqual(Auth.token, tok.auth);
}
