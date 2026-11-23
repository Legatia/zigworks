//! CalDAV (RFC 4791) as calmcp needs it: a calendar-query REPORT for a
//! time range or a UID, an object read with its ETag, written back only if
//! it is still that one (If-Match; If-None-Match: * for a new one),
//! deleted the same way; a calendar's own properties; and discovery from
//! the server's address (current-user-principal, calendar-home-set, the
//! calendars). Basic auth with an app password, or a bearer token renewed
//! with a refresh token.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");
const xml = @import("xml.zig");
const config = @import("config.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");

/// What calmcp is given from the environment.
pub const Secret = struct {
    /// CALDAV_PASSWORD
    password: []const u8 = "",
    /// CALDAV_TOKEN
    token: []const u8 = "",
    /// CALDAV_REFRESH_TOKEN, CALDAV_CLIENT_SECRET
    refresh: []const u8 = "",
    client_secret: []const u8 = "",
};

pub const Object = struct { href: []const u8, etag: []const u8, data: []const u8 };

/// A calendar's properties.
pub const Info = struct {
    url: []const u8,
    name: []const u8 = "",
    writable: bool = true,
    /// It holds events (VEVENT), not only tasks.
    events: bool = true,
    /// Its time zone's TZID, when the server says (calendar-timezone).
    zone: []const u8 = "",
};

pub const Found = struct {
    principal: []const u8 = "",
    home: []const u8 = "",
    /// The owner's address (calendar-user-address-set's mailto:).
    email: []const u8 = "",
    /// The server's calendar for new events, when it says.
    default: []const u8 = "",
    calendars: []const Info = &.{},
};

pub const Error = error{
    /// 401 (the password or the token) or 403 on a read.
    Refused,
    /// 403 on a write: the calendar is read only.
    ReadOnly,
    NotFound,
    /// 412: it changed meanwhile (or exists, for a new one).
    Changed,
    /// No connection, a time-out, a broken answer.
    Unreachable,
    BadAnswer,
    OutOfMemory,
};

/// How a write is made: only if the object is new, or still `etag`.
pub const Cond = union(enum) { create, match: []const u8 };

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    secret: Secret,
    /// One HTTP client per origin (scheme, host, port).
    conns: std.ArrayList(Conn) = .empty,
    token: []u8 = &.{},
    token_until_ns: i128 = 0,
    /// What went wrong last, in words ("the server refused the password (HTTP 401)").
    why: []u8 = &.{},

    const Conn = struct { origin: []u8, client: http.Client };

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, secret: Secret) Client {
        return .{ .gpa = gpa, .io = io, .cfg = cfg, .secret = secret };
    }

    pub fn deinit(c: *Client) void {
        for (c.conns.items) |*x| {
            x.client.deinit();
            c.gpa.free(x.origin);
        }
        c.conns.deinit(c.gpa);
        c.gpa.free(c.token);
        c.gpa.free(c.why);
    }

    fn conn(c: *Client, origin: []const u8) Error!*http.Client {
        for (c.conns.items) |*x| if (std.mem.eql(u8, x.origin, origin)) return &x.client;
        const target = http.Target.parse(origin) catch return error.Unreachable;
        const owned = try c.gpa.dupe(u8, origin);
        errdefer c.gpa.free(owned);
        // the target's host points into the origin: keep it owned
        var t = target;
        t.host = owned[(@intFromPtr(target.host.ptr) - @intFromPtr(origin.ptr))..][0..target.host.len];
        try c.conns.append(c.gpa, .{ .origin = owned, .client = .init(c.gpa, c.io, t) });
        const x = &c.conns.items[c.conns.items.len - 1].client;
        x.user_agent = "calmcp";
        return x;
    }

    fn say(c: *Client, comptime fmt: []const u8, args: anytype) void {
        c.gpa.free(c.why);
        c.why = std.fmt.allocPrint(c.gpa, fmt, args) catch &.{};
    }

    /// The bearer token: CALDAV_TOKEN, or one renewed with the refresh
    /// token a minute before it runs out.
    fn bearer(c: *Client, a: Allocator, renew: bool) Error![]const u8 {
        if (c.cfg.token_url.len == 0 or c.secret.refresh.len == 0) return c.secret.token;
        if (!renew and c.token.len > 0 and sock.nowNs(c.io) < c.token_until_ns) return c.token;
        const origin = config.originOf(c.cfg.token_url) orelse return error.Unreachable;
        const hc = try c.conn(origin);
        const body = try std.fmt.allocPrint(a, "grant_type=refresh_token&refresh_token={f}&client_id={f}&client_secret={f}", .{ form(c.secret.refresh), form(c.cfg.client_id), form(c.secret.client_secret) });
        const ans = http.fetch(hc, a, .{ .path = c.cfg.token_url[origin.len..], .body = body, .content_type = "application/x-www-form-urlencoded", .limits = .{ .idle_ms = 15_000, .total_ms = 30_000 } }) catch {
            c.say("can't reach {s} to renew the token", .{c.cfg.token_url});
            return error.Unreachable;
        };
        if (ans.status != 200) {
            c.say("{s} refused the refresh token (HTTP {d})", .{ c.cfg.token_url, ans.status });
            return error.Refused;
        }
        const v = jv.parse(a, ans.body);
        const tok = jv.str(jv.get(v, "access_token")) orelse return error.BadAnswer;
        const secs = jv.int(jv.get(v, "expires_in")) orelse 3600;
        c.gpa.free(c.token);
        c.token = try c.gpa.dupe(u8, tok);
        c.token_until_ns = sock.nowNs(c.io) + @as(i128, @max(secs - 60, 30)) * std.time.ns_per_s;
        return c.token;
    }

    const Extra = struct { depth: ?[]const u8 = null, if_match: ?[]const u8 = null, create: bool = false, ctype: []const u8 = "application/xml; charset=utf-8" };

    /// One request with the account's credentials; a 401 on a renewable
    /// token is tried once more with a new one.
    fn send(c: *Client, a: Allocator, method: @FieldType(http.Request, "method"), url: []const u8, body: ?[]const u8, extra: Extra) Error!http.Answer {
        const origin = config.originOf(url) orelse return error.Unreachable;
        const path = if (url.len > origin.len) url[origin.len..] else "/";
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            var hs: std.ArrayList(std.http.Header) = .empty;
            var key: ?[]const u8 = null;
            switch (c.cfg.auth) {
                .password => {
                    const raw = try std.fmt.allocPrint(a, "{s}:{s}", .{ c.cfg.user, c.secret.password });
                    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
                    try hs.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Basic {s}", .{std.base64.standard.Encoder.encode(enc, raw)}) });
                },
                .token => key = try c.bearer(a, attempt > 0),
            }
            if (extra.depth) |d| try hs.append(a, .{ .name = "Depth", .value = d });
            if (extra.if_match) |m| try hs.append(a, .{ .name = "If-Match", .value = m });
            if (extra.create) try hs.append(a, .{ .name = "If-None-Match", .value = "*" });
            const hc = try c.conn(origin);
            const ans = http.fetch(hc, a, .{ .method = method, .path = path, .body = body, .content_type = extra.ctype, .key = key, .headers = hs.items, .limits = .{ .idle_ms = 20_000, .total_ms = 45_000 } }) catch |e| {
                c.say("can't reach {s}: {s}", .{ origin, switch (e) {
                    error.Timeout => "it did not answer in time",
                    error.ConnectFailed => "no connection",
                    error.CertificateRejected => "its https certificate was not accepted",
                    error.TlsFailed => "the https handshake failed",
                    else => @errorName(e),
                } });
                return error.Unreachable;
            };
            if (ans.status == 401 and attempt == 0 and c.cfg.auth == .token and c.cfg.token_url.len > 0 and c.secret.refresh.len > 0) continue;
            if (ans.status == 401) {
                c.say("the server refused the {s} (HTTP 401)", .{if (c.cfg.auth == .password) "password" else "token"});
                return error.Refused;
            }
            return ans;
        }
    }

    fn status(c: *Client, ans: http.Answer, url: []const u8, comptime what: []const u8) Error!void {
        switch (ans.status) {
            200...299 => return,
            403 => {
                c.say("the server refused to " ++ what ++ " (HTTP 403)", .{});
                return error.Refused;
            },
            404 => {
                c.say("{s} is not there (HTTP 404)", .{url});
                return error.NotFound;
            },
            412 => return error.Changed,
            else => {
                c.say("the server answered HTTP {d} to " ++ what, .{ans.status});
                return error.BadAnswer;
            },
        }
    }

    fn objects(c: *Client, a: Allocator, url: []const u8, body: []const u8) Error![]Object {
        const ans = try c.send(a, .REPORT, url, body, .{ .depth = "1" });
        try c.status(ans, url, "read the calendar");
        const root = xml.parse(a, ans.body) catch return error.BadAnswer;
        var out: std.ArrayList(Object) = .empty;
        for (root.kids) |*r| {
            if (!std.mem.eql(u8, r.name, "response")) continue;
            const href = (r.child("href") orelse continue).value();
            const ok = okProps(r) orelse continue;
            const data = (ok.child("calendar-data") orelse continue).text;
            const etag = if (ok.child("getetag")) |e| e.value() else "";
            try out.append(a, .{ .href = try resolve(a, url, href), .etag = etag, .data = data });
        }
        return out.items;
    }

    /// The events of calendar `url` that overlap [`from`, `to`) (Unix seconds).
    pub fn query(c: *Client, a: Allocator, url: []const u8, from: i64, to: i64) Error![]Object {
        var fb: [16]u8 = undefined;
        var tb: [16]u8 = undefined;
        const body = try std.fmt.allocPrint(a,
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="{s}" end="{s}"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>
        , .{ stamp(&fb, from), stamp(&tb, to) });
        return c.objects(a, url, body);
    }

    /// The object of calendar `url` whose UID is `uid`; null: none.
    pub fn byUid(c: *Client, a: Allocator, url: []const u8, uid: []const u8) Error!?Object {
        const body = try std.fmt.allocPrint(a,
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="UID"><C:text-match collation="i;octet">{s}</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>
        , .{try xml.escape(a, uid)});
        const list = try c.objects(a, url, body);
        // a server that ignores the filter sends more: the one with this UID
        for (list) |o| {
            const want = try std.fmt.allocPrint(a, "\nUID:{s}", .{uid});
            if (std.mem.indexOf(u8, o.data, want) != null) return o;
        }
        return null;
    }

    /// One object, with its ETag; null when it is gone.
    pub fn get(c: *Client, a: Allocator, url: []const u8) Error!?Object {
        const ans = try c.send(a, .GET, url, null, .{});
        if (ans.status == 404 or ans.status == 410) return null;
        try c.status(ans, url, "read the event");
        return .{ .href = url, .etag = ans.etag, .data = ans.body };
    }

    /// Writes `data` to `url` if `cond` holds; the new ETag ("" when the
    /// server gives none).
    pub fn put(c: *Client, a: Allocator, url: []const u8, data: []const u8, cond: Cond) Error![]const u8 {
        const ans = try c.send(a, .PUT, url, data, .{ .ctype = "text/calendar; charset=utf-8", .if_match = if (cond == .match) cond.match else null, .create = cond == .create });
        if (ans.status == 403) {
            c.say("the server refused the change: the calendar is read only (HTTP 403)", .{});
            return error.ReadOnly;
        }
        try c.status(ans, url, "write the event");
        return ans.etag;
    }

    pub fn delete(c: *Client, a: Allocator, url: []const u8, etag: []const u8) Error!void {
        const ans = try c.send(a, .DELETE, url, null, .{ .if_match = if (etag.len > 0) etag else null });
        if (ans.status == 403) {
            c.say("the server refused to delete it: the calendar is read only (HTTP 403)", .{});
            return error.ReadOnly;
        }
        try c.status(ans, url, "delete the event");
    }

    const props_body =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/"><D:prop><D:displayname/><D:resourcetype/><D:current-user-privilege-set/><C:supported-calendar-component-set/><C:calendar-timezone/><CS:getctag/></D:prop></D:propfind>
    ;

    /// Calendar `url`'s name, whether it may be written, what it holds.
    pub fn info(c: *Client, a: Allocator, url: []const u8) Error!Info {
        const ans = try c.send(a, .PROPFIND, url, props_body, .{ .depth = "0" });
        try c.status(ans, url, "read the calendar's properties");
        const root = xml.parse(a, ans.body) catch return error.BadAnswer;
        for (root.kids) |*r| {
            if (!std.mem.eql(u8, r.name, "response")) continue;
            const ok = okProps(r) orelse continue;
            const i = try infoOf(a, url, ok);
            if (!isCalendar(ok)) {
                c.say("{s} is not a calendar", .{url});
                return error.NotFound;
            }
            return i;
        }
        return error.BadAnswer;
    }

    /// A PROPFIND whose answer names one href under `prop` (`start` again
    /// after redirects, at most five).
    fn hrefProp(c: *Client, a: Allocator, start: []const u8, body: []const u8, prop: []const u8) Error!struct { url: []const u8, href: []const u8, root: xml.Node } {
        var url = start;
        var hops: u32 = 0;
        while (true) : (hops += 1) {
            const ans = try c.send(a, .PROPFIND, url, body, .{ .depth = "0" });
            if (ans.status >= 300 and ans.status < 400 and ans.location.len > 0 and hops < 5) {
                url = try resolve(a, url, ans.location);
                continue;
            }
            try c.status(ans, url, "say where the calendars are");
            const root = xml.parse(a, ans.body) catch return error.BadAnswer;
            const p = root.find(prop) orelse return .{ .url = url, .href = "", .root = root };
            const h = p.find("href") orelse return .{ .url = url, .href = "", .root = root };
            return .{ .url = url, .href = h.value(), .root = root };
        }
    }

    /// The owner's calendars, found from the server's address.
    pub fn discover(c: *Client, a: Allocator, start: []const u8) Error!Found {
        const principal_body =
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<D:propfind xmlns:D="DAV:"><D:prop><D:current-user-principal/></D:prop></D:propfind>
        ;
        var got = c.hrefProp(a, start, principal_body, "current-user-principal") catch |e| switch (e) {
            error.NotFound, error.BadAnswer => null,
            else => return e,
        };
        if (got == null or got.?.href.len == 0) {
            // the well-known address (RFC 6764)
            const origin = config.originOf(start) orelse return error.Unreachable;
            got = try c.hrefProp(a, try std.fmt.allocPrint(a, "{s}/.well-known/caldav", .{origin}), principal_body, "current-user-principal");
        }
        const p = got.?;
        if (p.href.len == 0) {
            c.say("{s} doesn't say whose calendars these are (no current-user-principal)", .{start});
            return error.BadAnswer;
        }
        var found: Found = .{ .principal = try resolve(a, p.url, p.href) };
        const home_body =
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><C:calendar-home-set/><C:calendar-user-address-set/><C:schedule-default-calendar-URL/></D:prop></D:propfind>
        ;
        const h = try c.hrefProp(a, found.principal, home_body, "calendar-home-set");
        if (h.href.len == 0) {
            c.say("{s} doesn't say where the calendars are (no calendar-home-set)", .{found.principal});
            return error.BadAnswer;
        }
        found.home = try resolve(a, h.url, h.href);
        if (h.root.find("calendar-user-address-set")) |set| for (set.kids) |*k| {
            const v = k.value();
            if (std.mem.eql(u8, k.name, "href") and v.len > 7 and std.ascii.eqlIgnoreCase(v[0..7], "mailto:")) {
                found.email = v[7..];
                break;
            }
        };
        if (h.root.find("schedule-default-calendar-URL")) |d| if (d.find("href")) |x| {
            found.default = try resolve(a, h.url, x.value());
        };
        const ans = try c.send(a, .PROPFIND, found.home, props_body, .{ .depth = "1" });
        try c.status(ans, found.home, "list the calendars");
        const root = xml.parse(a, ans.body) catch return error.BadAnswer;
        var cals: std.ArrayList(Info) = .empty;
        for (root.kids) |*r| {
            if (!std.mem.eql(u8, r.name, "response")) continue;
            const href = (r.child("href") orelse continue).value();
            const ok = okProps(r) orelse continue;
            if (!isCalendar(ok)) continue;
            try cals.append(a, try infoOf(a, try resolve(a, found.home, href), ok));
        }
        found.calendars = cals.items;
        return found;
    }
};

/// The `prop` of a response's propstat whose status is 200.
fn okProps(r: *const xml.Node) ?*const xml.Node {
    for (r.kids) |*ps| {
        if (!std.mem.eql(u8, ps.name, "propstat")) continue;
        const st = if (ps.child("status")) |x| x.value() else "HTTP/1.1 200 OK";
        if (std.mem.indexOf(u8, st, " 200") == null) continue;
        return ps.child("prop");
    }
    return null;
}

fn isCalendar(prop: *const xml.Node) bool {
    const rt = prop.child("resourcetype") orelse return false;
    return rt.child("calendar") != null;
}

fn infoOf(a: Allocator, url: []const u8, prop: *const xml.Node) !Info {
    var i: Info = .{ .url = url };
    if (prop.child("displayname")) |d| i.name = d.value();
    if (prop.child("supported-calendar-component-set")) |set| {
        i.events = false;
        for (set.kids) |*k| if (k.attr("name")) |n| if (std.ascii.eqlIgnoreCase(n, "VEVENT")) {
            i.events = true;
        };
        if (set.kids.len == 0) i.events = true;
    }
    if (prop.child("current-user-privilege-set")) |set| {
        i.writable = set.find("write") != null or set.find("write-content") != null or set.find("all") != null;
    }
    if (prop.child("calendar-timezone")) |z| {
        // a VCALENDAR with one VTIMEZONE: its TZID
        var it = std.mem.splitScalar(u8, z.text, '\n');
        while (it.next()) |l| {
            const line = std.mem.trimEnd(u8, l, "\r");
            if (std.mem.startsWith(u8, line, "TZID:")) {
                i.zone = try a.dupe(u8, line[5..]);
                break;
            }
        }
    }
    return i;
}

const Form = struct {
    s: []const u8,
    pub fn format(f: Form, w: *Io.Writer) Io.Writer.Error!void {
        for (f.s) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
                try w.writeByte(ch);
            } else try w.print("%{X:0>2}", .{ch});
        }
    }
};

fn form(s: []const u8) Form {
    return .{ .s = s };
}

/// `href` (a path or a whole address) against `base`'s origin.
pub fn resolve(a: Allocator, base: []const u8, href: []const u8) ![]const u8 {
    if (config.originOf(href) != null) return href;
    const origin = config.originOf(base) orelse return href;
    if (href.len > 0 and href[0] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ origin, href });
    // relative to the base's folder
    const slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse return std.fmt.allocPrint(a, "{s}/{s}", .{ origin, href });
    if (slash < origin.len) return std.fmt.allocPrint(a, "{s}/{s}", .{ origin, href });
    return std.fmt.allocPrint(a, "{s}{s}", .{ base[0 .. slash + 1], href });
}

/// "20261123T000000Z".
pub fn stamp(buf: *[16]u8, t: i64) []const u8 {
    const tz_ = @import("tz.zig");
    const d = tz_.civil(@divFloor(t, 86400));
    const sod: u64 = @intCast(@mod(t, 86400));
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ @as(u64, @intCast(d.y)), d.m, d.d, sod / 3600, sod / 60 % 60, sod % 60 }) catch unreachable;
}

// ---- tests ----

const tt = std.testing;
const sim = @import("sim.zig");
const tz = @import("tz.zig");

const day = tz.daysFromCivil(2026, 11, 23);

fn simConfig(a: Allocator, port: u16, auth: config.Auth, token_url: bool) !config.Config {
    var d: config.Diag = .{};
    const text = try std.fmt.allocPrint(a, "[account]\nurl = http://127.0.0.1:{d}\nuser = owner\nauth = {s}\nzone = Europe/Warsaw\n{s}[calendar personal]\nurl = /dav/calendars/owner/personal/\nchange = yes\n[calendar birthdays]\nurl = /dav/calendars/owner/birthdays/\n", .{ port, @tagName(auth), if (token_url) try std.fmt.allocPrint(a, "token_url = http://127.0.0.1:{d}/oauth2/token\nclient_id = sim-client\n", .{port}) else "" });
    return config.parse(a, text, &d);
}

test "resolve_and_stamp" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tt.expectEqualStrings("https://h.example.com/dav/x.ics", try resolve(a, "https://h.example.com/dav/cal/", "/dav/x.ics"));
    try tt.expectEqualStrings("https://o.example.com/y", try resolve(a, "https://h.example.com/dav/cal/", "https://o.example.com/y"));
    try tt.expectEqualStrings("https://h.example.com/dav/cal/z.ics", try resolve(a, "https://h.example.com/dav/cal/", "z.ics"));
    var b: [16]u8 = undefined;
    try tt.expectEqualStrings("20261123T093000Z", stamp(&b, day * 86400 + 9 * 3600 + 30 * 60));
}

test "discover_finds_the_calendars_through_the_principal" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sim.start(std.heap.page_allocator, tt.io, .{ .user = "owner", .password = "app-pass-1", .day = day });
    const cfg = try simConfig(a, s.port, .password, false);
    var c: Client = .init(tt.allocator, tt.io, &cfg, .{ .password = "app-pass-1" });
    defer c.deinit();
    const found = try c.discover(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{s.port}));
    try tt.expectEqualStrings(sim.owner_email, found.email);
    try tt.expect(std.mem.endsWith(u8, found.default, "/dav/calendars/owner/personal/"));
    var names: std.ArrayList(u8) = .empty;
    for (found.calendars) |x| if (x.events) try names.print(a, "{s}{s};", .{ x.name, if (x.writable) "" else " (read only)" });
    try tt.expectEqualStrings("Personal;Work;Birthdays (read only);", names.items);
    try tt.expectEqualStrings("Europe/Warsaw", found.calendars[0].zone);
    // tasks only: not a calendar of events
    try tt.expect(!found.calendars[3].events);
    // a wrong password, said plainly
    var w: Client = .init(tt.allocator, tt.io, &cfg, .{ .password = "wrong" });
    defer w.deinit();
    try tt.expectError(error.Refused, w.discover(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{s.port})));
    try tt.expect(std.mem.indexOf(u8, w.why, "refused the password (HTTP 401)") != null);
}

test "a_query_finds_a_days_events_and_a_write_needs_its_etag" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sim.start(std.heap.page_allocator, tt.io, .{ .user = "owner", .password = "app-pass-1", .day = day });
    const cfg = try simConfig(a, s.port, .password, false);
    var c: Client = .init(tt.allocator, tt.io, &cfg, .{ .password = "app-pass-1" });
    defer c.deinit();
    const personal = cfg.find("personal").?.url;
    const objs = try c.query(a, personal, day * 86400 - 3600, day * 86400 + 23 * 3600);
    var dentist: ?Object = null;
    for (objs) |o| if (std.mem.indexOf(u8, o.data, "SUMMARY:Dentist") != null) {
        dentist = o;
    };
    const d = dentist orelse return error.NoDentist;
    try tt.expect(d.etag.len > 0);
    try tt.expect(std.mem.endsWith(u8, d.href, "/dentist-1.ics"));
    // by UID, then read alone: the same ETag
    const by = (try c.byUid(a, personal, "dentist-1@calmcp-sim")).?;
    try tt.expectEqualStrings(d.etag, by.etag);
    const got = (try c.get(a, d.href)).?;
    try tt.expectEqualStrings(d.etag, got.etag);
    // a write with an ETag that isn't the object's: refused, nothing written
    try tt.expectError(error.Changed, c.put(a, d.href, d.data, .{ .match = "\"not-it\"" }));
    const etag2 = try c.put(a, d.href, d.data, .{ .match = d.etag });
    try tt.expect(etag2.len > 0 and !std.mem.eql(u8, etag2, d.etag));
    // a new one only if it is new
    try tt.expectError(error.Changed, c.put(a, d.href, d.data, .create));
    // the old ETag no longer deletes it; the new one does
    try tt.expectError(error.Changed, c.delete(a, d.href, d.etag));
    try c.delete(a, d.href, etag2);
    try tt.expect((try c.get(a, d.href)) == null);
    // a read-only calendar takes no writes
    const bday = cfg.find("birthdays").?.url;
    try tt.expectError(error.ReadOnly, c.put(a, try std.fmt.allocPrint(a, "{s}new.ics", .{bday}), d.data, .create));
    const info = try c.info(a, bday);
    try tt.expectEqualStrings("Birthdays", info.name);
    try tt.expect(!info.writable);
}

test "a_token_is_renewed_with_the_refresh_token" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sim.start(std.heap.page_allocator, tt.io, .{ .user = "owner", .password = "app-pass-1", .day = day, .refresh = "refresh-1" });
    const cfg = try simConfig(a, s.port, .token, true);
    var c: Client = .init(tt.allocator, tt.io, &cfg, .{ .refresh = "refresh-1", .client_secret = "sim-secret" });
    defer c.deinit();
    const objs = try c.query(a, cfg.find("personal").?.url, day * 86400, day * 86400 + 86400);
    try tt.expect(objs.len > 0);
    try tt.expect(std.mem.startsWith(u8, c.token, "sim-access-"));
    // a token the server didn't give is refused
    var bad: Client = .init(tt.allocator, tt.io, &(try simConfig(a, s.port, .token, false)), .{ .token = "made-up" });
    defer bad.deinit();
    try tt.expectError(error.Refused, bad.query(a, cfg.find("personal").?.url, day * 86400, day * 86400 + 86400));
    try tt.expect(std.mem.indexOf(u8, bad.why, "refused the token (HTTP 401)") != null);
}
