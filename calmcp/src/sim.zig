//! calmcp-sim: a stand-in CalDAV server with a made-up owner's calendars,
//! for trying calmcp without an account and for its tests. Written from
//! RFC 4791 (CalDAV), 4918 (WebDAV) and 6638 (scheduling), not from any
//! one server:
//!   /.well-known/caldav                      301 to /dav/
//!   PROPFIND /dav/                           current-user-principal
//!   PROPFIND /dav/principals/USER/           calendar-home-set, the owner's address, the default calendar
//!   PROPFIND /dav/calendars/USER/ (Depth 1)  the calendars: personal, work, birthdays (read only), tasks (VTODO)
//!   REPORT   /dav/calendars/USER/CAL/        calendar-query: a time range or a UID
//!   GET, PUT, DELETE …/CAL/NAME.ics          with ETags: If-Match, If-None-Match: * (412 when they don't hold)
//!   POST /oauth2/token                       a refresh token for an access token (bearer)
//!   POST /sim/touch?path=P                   someone else changes P (a new ETag)
//!   GET  /sim/replies                        the invitation answers the server sent, a line each
//!   GET  /sim/object?path=P                  P as stored
//! The events are placed around one day (`--day`, else today): a dentist
//! at 10:30 Warsaw time, a weekly team call with people, a call in New
//! York's time, a monthly review, focus time shown as free, lunch the day
//! after, a birthday three days on.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sock = @import("sock.zig");
const tz = @import("tz.zig");
const xml = @import("xml.zig");

pub const owner_email = "owner@example.com";
pub const client_id = "sim-client";

pub const Options = struct {
    port: u16 = 0,
    user: []const u8,
    password: []const u8,
    /// The day the events are placed around (days since 1970-01-01).
    day: i64,
    /// A refresh token the token endpoint takes (bearer sign-in); "": none.
    refresh: []const u8 = "",
};

const Obj = struct { name: []u8, etag: []u8, data: []u8 };

const Cal = struct {
    key: []const u8,
    name: []const u8,
    writable: bool,
    comp: []const u8 = "VEVENT",
    objs: std.ArrayList(Obj) = .empty,
};

pub const Sim = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    port: u16 = 0,
    lock: Io.Mutex = .init,
    cals: [4]Cal,
    next_etag: u64 = 1,
    tokens: std.ArrayList([]u8) = .empty,
    replies: std.ArrayList(u8) = .empty,
    listener: sock.Listener = undefined,
};

/// Starts the sim on a thread of its own; it serves until the process ends.
pub fn start(gpa: Allocator, io: Io, opts: Options) !*Sim {
    const s = try gpa.create(Sim);
    s.* = .{ .gpa = gpa, .io = io, .opts = opts, .cals = .{
        .{ .key = "personal", .name = "Personal", .writable = true },
        .{ .key = "work", .name = "Work", .writable = true },
        .{ .key = "birthdays", .name = "Birthdays", .writable = false },
        .{ .key = "tasks", .name = "Tasks", .writable = true, .comp = "VTODO" },
    } };
    try seed(s);
    s.listener = try sock.Listener.open(opts.port);
    s.port = s.listener.port;
    const th = try std.Thread.spawn(.{}, acceptLoop, .{s});
    th.detach();
    return s;
}

/// Serves on this thread (calmcp-sim).
pub fn run(gpa: Allocator, io: Io, opts: Options) !void {
    const s = try start(gpa, io, opts);
    std.log.info("CalDAV stand-in on 127.0.0.1:{d} (user {s})", .{ s.port, opts.user });
    while (true) io.sleep(.fromSeconds(3600), .awake) catch {};
}

fn acceptLoop(s: *Sim) void {
    while (true) {
        const conn = s.listener.accept() catch continue;
        const t = std.Thread.spawn(.{}, serve, .{ s, conn }) catch {
            sock.closeHandle(conn);
            continue;
        };
        t.detach();
    }
}

// ---- the made-up calendars ----

pub const vtz_warsaw = "BEGIN:VTIMEZONE\r\nTZID:Europe/Warsaw\r\nBEGIN:STANDARD\r\nDTSTART:19701025T030000\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nBEGIN:DAYLIGHT\r\nDTSTART:19700329T020000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\n";
pub const vtz_new_york = "BEGIN:VTIMEZONE\r\nTZID:America/New_York\r\nBEGIN:DAYLIGHT\r\nDTSTART:20070311T020000\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\r\nEND:DAYLIGHT\r\nBEGIN:STANDARD\r\nDTSTART:20071104T020000\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n";

fn ymd(buf: *[8]u8, d: i64) []const u8 {
    const c = tz.civil(d);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{ @as(u64, @intCast(c.y)), c.m, c.d }) catch unreachable;
}

fn add(s: *Sim, cal: usize, name: []const u8, data: []const u8) !void {
    const etag = try std.fmt.allocPrint(s.gpa, "\"sim-{d}\"", .{s.next_etag});
    s.next_etag += 1;
    try s.cals[cal].objs.append(s.gpa, .{ .name = try s.gpa.dupe(u8, name), .etag = etag, .data = try s.gpa.dupe(u8, data) });
}

fn seed(s: *Sim) !void {
    const a = s.gpa;
    const d = s.opts.day;
    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    var b3: [8]u8 = undefined;
    const today = ymd(&b0, d);
    const tomorrow = ymd(&b1, d + 1);
    const wd = tz.weekday(d);
    const names = [_][]const u8{ "SU", "MO", "TU", "WE", "TH", "FR", "SA" };
    const head = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//calmcp-sim//EN\r\n";
    const tail = "END:VCALENDAR\r\n";
    try add(s, 0, "dentist-1.ics", try std.fmt.allocPrint(a, "{s}{s}BEGIN:VEVENT\r\nUID:dentist-1@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=Europe/Warsaw:{s}T103000\r\nDTEND;TZID=Europe/Warsaw:{s}T113000\r\nSUMMARY:Dentist\r\nLOCATION:Dental clinic\\, ul. Długa 5\\, Kraków\r\nSEQUENCE:0\r\nEND:VEVENT\r\n{s}", .{ head, vtz_warsaw, today, today, tail }));
    try add(s, 0, "lunch-anna.ics", try std.fmt.allocPrint(a, "{s}{s}BEGIN:VEVENT\r\nUID:lunch-anna@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=Europe/Warsaw:{s}T130000\r\nDTEND;TZID=Europe/Warsaw:{s}T140000\r\nSUMMARY:Lunch with Anna\r\nLOCATION:Café Nowa\\, Rynek 12\r\nDESCRIPTION:Table booked: https://booking.example.com/r/123\r\nORGANIZER;CN=Owner:mailto:{s}\r\nATTENDEE;CN=Owner;PARTSTAT=ACCEPTED:mailto:{s}\r\nATTENDEE;CN=Anna Kowalska;PARTSTAT=ACCEPTED:mailto:anna@example.com\r\nEND:VEVENT\r\n{s}", .{ head, vtz_warsaw, tomorrow, tomorrow, owner_email, owner_email, tail }));
    try add(s, 0, "focus.ics", try std.fmt.allocPrint(a, "{s}{s}BEGIN:VEVENT\r\nUID:focus@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=Europe/Warsaw:{s}T130000\r\nDTEND;TZID=Europe/Warsaw:{s}T140000\r\nSUMMARY:Focus time\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT\r\n{s}", .{ head, vtz_warsaw, today, today, tail }));
    // the team call: weekly on the day's weekday, from eight weeks before; the
    // one two weeks before taken out, last week's at 10:00
    const first = ymd(&b2, d - 56);
    const moved = ymd(&b3, d - 7);
    var b4: [8]u8 = undefined;
    const out = ymd(&b4, d - 14);
    try add(s, 1, "team-call.ics", try std.fmt.allocPrint(a, "{s}{s}BEGIN:VEVENT\r\nUID:team-call@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=Europe/Warsaw:{s}T090000\r\nDTEND;TZID=Europe/Warsaw:{s}T093000\r\nRRULE:FREQ=WEEKLY;BYDAY={s}\r\nEXDATE;TZID=Europe/Warsaw:{s}T090000\r\nSUMMARY:Team call\r\nLOCATION:Video call\r\nURL:https://meet.example.com/team\r\nORGANIZER;CN=Piotr Nowak:mailto:piotr@example.com\r\nATTENDEE;CN=Piotr Nowak;PARTSTAT=ACCEPTED:mailto:piotr@example.com\r\nATTENDEE;CN=Ewa Lis;PARTSTAT=ACCEPTED:mailto:ewa@example.com\r\nATTENDEE;CN=Owner;PARTSTAT=ACCEPTED:mailto:{s}\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:team-call@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nRECURRENCE-ID;TZID=Europe/Warsaw:{s}T090000\r\nDTSTART;TZID=Europe/Warsaw:{s}T100000\r\nDTEND;TZID=Europe/Warsaw:{s}T103000\r\nSUMMARY:Team call\r\nLOCATION:Video call\r\nURL:https://meet.example.com/team\r\nORGANIZER;CN=Piotr Nowak:mailto:piotr@example.com\r\nATTENDEE;CN=Piotr Nowak;PARTSTAT=ACCEPTED:mailto:piotr@example.com\r\nATTENDEE;CN=Ewa Lis;PARTSTAT=ACCEPTED:mailto:ewa@example.com\r\nATTENDEE;CN=Owner;PARTSTAT=ACCEPTED:mailto:{s}\r\nEND:VEVENT\r\n{s}", .{ head, vtz_warsaw, first, first, names[wd], out, owner_email, moved, moved, moved, owner_email, tail }));
    // a call in New York's time, an invitation not answered yet
    try add(s, 1, "ny-call.ics", try std.fmt.allocPrint(a, "{s}{s}BEGIN:VEVENT\r\nUID:ny-call@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=America/New_York:{s}T090000\r\nDTEND;TZID=America/New_York:{s}T100000\r\nSUMMARY:Call with the New York office\r\nDESCRIPTION:Agenda: https://docs.example.com/ny-agenda\r\nORGANIZER;CN=Sam Lee:mailto:sam@example.com\r\nATTENDEE;CN=Sam Lee;PARTSTAT=ACCEPTED:mailto:sam@example.com\r\nATTENDEE;CN=Owner;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:{s}\r\nSEQUENCE:1\r\nEND:VEVENT\r\n{s}", .{ head, vtz_new_york, today, today, owner_email, tail }));
    var b5: [8]u8 = undefined;
    try add(s, 1, "review.ics", try std.fmt.allocPrint(a, "{s}{s}BEGIN:VEVENT\r\nUID:review@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=Europe/Warsaw:{s}T160000\r\nDTEND;TZID=Europe/Warsaw:{s}T170000\r\nRRULE:FREQ=MONTHLY;BYDAY=2TU\r\nSUMMARY:Monthly review\r\nEND:VEVENT\r\n{s}", .{ head, vtz_warsaw, ymd(&b5, d - 60), ymd(&b5, d - 60), tail }));
    // a birthday three days on, every year since 1990
    const bc = tz.civil(d + 3);
    try add(s, 2, "anna-bday.ics", try std.fmt.allocPrint(a, "{s}BEGIN:VEVENT\r\nUID:anna-bday@calmcp-sim\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;VALUE=DATE:1990{d:0>2}{d:0>2}\r\nRRULE:FREQ=YEARLY\r\nSUMMARY:Anna's birthday\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT\r\n{s}", .{ head, bc.m, bc.d, tail }));
    try add(s, 3, "milk.ics", head ++ "BEGIN:VTODO\r\nUID:milk@calmcp-sim\r\nSUMMARY:Buy milk\r\nEND:VTODO\r\n" ++ tail);
}

// ---- HTTP ----

const Req = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    depth: []const u8 = "0",
    auth: []const u8 = "",
    if_match: []const u8 = "",
    if_none_match: []const u8 = "",
    body: []const u8 = "",
};

const Res = struct { status: u16, body: []const u8 = "", ctype: []const u8 = "text/plain", etag: []const u8 = "", location: []const u8 = "", www: bool = false };

fn serve(s: *Sim, conn: sock.Handle) void {
    defer sock.closeHandle(conn);
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(s.io, conn, &rbuf, &wbuf, 60_000);
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const req = readRequest(a, &sk.reader) catch return orelse return;
        const res = blk: {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            break :blk handle(s, a, req) catch Res{ .status = 500, .body = "sim error" };
        };
        writeResponse(&sk.writer, res) catch return;
        sk.writer.flush() catch return;
    }
}

fn readRequest(a: Allocator, r: *Io.Reader) !?Req {
    const line = (try r.takeDelimiter('\n')) orelse return null;
    const first = std.mem.trimEnd(u8, line, "\r");
    if (first.len == 0) return null;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = try a.dupe(u8, parts.next() orelse return error.BadRequest);
    const target = try a.dupe(u8, parts.next() orelse return error.BadRequest);
    const q = std.mem.indexOfScalar(u8, target, '?');
    var req: Req = .{ .method = method, .path = target[0 .. q orelse target.len], .query = if (q) |i| target[i + 1 ..] else "" };
    var length: usize = 0;
    while (true) {
        const h = std.mem.trimEnd(u8, (try r.takeDelimiter('\n')) orelse return error.BadRequest, "\r");
        if (h.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        const name = std.mem.trim(u8, h[0..colon], " ");
        const value = try a.dupe(u8, std.mem.trim(u8, h[colon + 1 ..], " \t"));
        if (std.ascii.eqlIgnoreCase(name, "content-length")) length = std.fmt.parseInt(usize, value, 10) catch 0;
        if (std.ascii.eqlIgnoreCase(name, "depth")) req.depth = value;
        if (std.ascii.eqlIgnoreCase(name, "authorization")) req.auth = value;
        if (std.ascii.eqlIgnoreCase(name, "if-match")) req.if_match = value;
        if (std.ascii.eqlIgnoreCase(name, "if-none-match")) req.if_none_match = value;
    }
    if (length > 4 << 20) return error.BadRequest;
    if (length > 0) {
        const body = try a.alloc(u8, length);
        try r.readSliceAll(body);
        req.body = body;
    }
    return req;
}

fn writeResponse(w: *Io.Writer, res: Res) !void {
    const reason: []const u8 = switch (res.status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        207 => "Multi-Status",
        301 => "Moved Permanently",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        412 => "Precondition Failed",
        415 => "Unsupported Media Type",
        else => "Status",
    };
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n", .{ res.status, reason, res.body.len });
    if (res.body.len > 0) try w.print("Content-Type: {s}\r\n", .{res.ctype});
    if (res.etag.len > 0) try w.print("ETag: {s}\r\n", .{res.etag});
    if (res.location.len > 0) try w.print("Location: {s}\r\n", .{res.location});
    if (res.www) try w.writeAll("WWW-Authenticate: Basic realm=\"calmcp-sim\"\r\n");
    try w.writeAll("\r\n");
    try w.writeAll(res.body);
}

// ---- the routes ----

fn authorized(s: *Sim, a: Allocator, auth: []const u8) bool {
    if (std.mem.startsWith(u8, auth, "Basic ")) {
        const enc = std.mem.trim(u8, auth[6..], " ");
        const n = std.base64.standard.Decoder.calcSizeForSlice(enc) catch return false;
        const buf = a.alloc(u8, n) catch return false;
        std.base64.standard.Decoder.decode(buf, enc) catch return false;
        const want = std.fmt.allocPrint(a, "{s}:{s}", .{ s.opts.user, s.opts.password }) catch return false;
        return std.mem.eql(u8, buf, want);
    }
    if (std.mem.startsWith(u8, auth, "Bearer ")) {
        for (s.tokens.items) |x| if (std.mem.eql(u8, x, auth[7..])) return true;
    }
    return false;
}

fn formValue(body: []const u8, key: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return kv[eq + 1 ..];
    }
    return "";
}

fn handle(s: *Sim, a: Allocator, req: Req) !Res {
    const eql = std.mem.eql;
    if (eql(u8, req.path, "/.well-known/caldav")) return .{ .status = 301, .location = "/dav/" };
    if (eql(u8, req.method, "POST") and eql(u8, req.path, "/oauth2/token")) {
        if (s.opts.refresh.len == 0 or !eql(u8, formValue(req.body, "grant_type"), "refresh_token") or !eql(u8, formValue(req.body, "refresh_token"), s.opts.refresh) or !eql(u8, formValue(req.body, "client_id"), client_id))
            return .{ .status = 400, .ctype = "application/json", .body = "{\"error\":\"invalid_grant\"}" };
        const tok = try std.fmt.allocPrint(s.gpa, "sim-access-{d}", .{s.tokens.items.len + 1});
        try s.tokens.append(s.gpa, tok);
        return .{ .status = 200, .ctype = "application/json", .body = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":3600}}", .{tok}) };
    }
    if (eql(u8, req.path, "/sim/replies")) return .{ .status = 200, .body = s.replies.items };
    if (eql(u8, req.path, "/sim/object") or eql(u8, req.path, "/sim/touch")) {
        const path = formValue(req.query, "path");
        const o = find(s, path) orelse return .{ .status = 404 };
        if (eql(u8, req.path, "/sim/object")) return .{ .status = 200, .ctype = "text/calendar", .body = o.obj.data, .etag = o.obj.etag };
        // someone else changed it: a new ETag (and a line it didn't have)
        const marked = try std.mem.replaceOwned(u8, s.gpa, o.obj.data, "END:VEVENT\r\n", "X-SIM-TOUCHED:1\r\nEND:VEVENT\r\n");
        o.obj.data = marked;
        o.obj.etag = try std.fmt.allocPrint(s.gpa, "\"sim-{d}\"", .{s.next_etag});
        s.next_etag += 1;
        return .{ .status = 204 };
    }
    if (!authorized(s, a, req.auth)) return .{ .status = 401, .www = true, .body = "Unauthorized" };
    const home = try std.fmt.allocPrint(a, "/dav/calendars/{s}/", .{s.opts.user});
    const principal = try std.fmt.allocPrint(a, "/dav/principals/{s}/", .{s.opts.user});
    if (eql(u8, req.method, "PROPFIND")) {
        if (eql(u8, req.path, "/dav/") or eql(u8, req.path, "/")) return multistatus(a, &.{try response(a, req.path, try std.fmt.allocPrint(a, "<d:current-user-principal><d:href>{s}</d:href></d:current-user-principal><d:resourcetype><d:collection/></d:resourcetype>", .{principal}))});
        if (eql(u8, req.path, principal)) return multistatus(a, &.{try response(a, principal, try std.fmt.allocPrint(a, "<c:calendar-home-set><d:href>{s}</d:href></c:calendar-home-set><c:calendar-user-address-set><d:href>mailto:{s}</d:href><d:href>{s}</d:href></c:calendar-user-address-set><c:schedule-default-calendar-URL><d:href>{s}personal/</d:href></c:schedule-default-calendar-URL><d:displayname>Owner</d:displayname>", .{ home, owner_email, principal, home }))});
        if (eql(u8, req.path, home)) {
            var list: std.ArrayList([]const u8) = .empty;
            try list.append(a, try response(a, home, "<d:resourcetype><d:collection/></d:resourcetype>"));
            if (!eql(u8, req.depth, "0")) for (&s.cals) |*cal| try list.append(a, try response(a, try std.fmt.allocPrint(a, "{s}{s}/", .{ home, cal.key }), try calProps(a, cal)));
            return multistatus(a, list.items);
        }
        for (&s.cals) |*cal| if (eql(u8, req.path, try std.fmt.allocPrint(a, "{s}{s}/", .{ home, cal.key }))) {
            var list: std.ArrayList([]const u8) = .empty;
            try list.append(a, try response(a, req.path, try calProps(a, cal)));
            if (!eql(u8, req.depth, "0")) for (cal.objs.items) |o| try list.append(a, try response(a, try std.fmt.allocPrint(a, "{s}{s}", .{ req.path, o.name }), try std.fmt.allocPrint(a, "<d:getetag>{s}</d:getetag>", .{try xml.escape(a, o.etag)})));
            return multistatus(a, list.items);
        };
        return .{ .status = 404 };
    }
    if (eql(u8, req.method, "REPORT")) {
        const cal = for (&s.cals) |*c| {
            if (eql(u8, req.path, try std.fmt.allocPrint(a, "{s}{s}/", .{ home, c.key }))) break c;
        } else return .{ .status = 404 };
        return report(a, req, cal);
    }
    // an object: GET, PUT, DELETE
    const slash = std.mem.lastIndexOfScalar(u8, req.path, '/') orelse return .{ .status = 404 };
    const dir = req.path[0 .. slash + 1];
    const name = req.path[slash + 1 ..];
    const cal = for (&s.cals) |*c| {
        if (eql(u8, dir, try std.fmt.allocPrint(a, "{s}{s}/", .{ home, c.key }))) break c;
    } else return .{ .status = 404 };
    const at: ?usize = for (cal.objs.items, 0..) |o, i| {
        if (eql(u8, o.name, name)) break i;
    } else null;
    if (eql(u8, req.method, "GET")) {
        const i = at orelse return .{ .status = 404 };
        return .{ .status = 200, .ctype = "text/calendar; charset=utf-8", .body = cal.objs.items[i].data, .etag = cal.objs.items[i].etag };
    }
    if (eql(u8, req.method, "PUT")) {
        if (!cal.writable) return .{ .status = 403, .body = "This calendar is read only." };
        if (!std.mem.startsWith(u8, req.body, "BEGIN:VCALENDAR")) return .{ .status = 415 };
        if (req.if_none_match.len > 0 and at != null) return .{ .status = 412 };
        if (req.if_match.len > 0 and (at == null or !eql(u8, req.if_match, cal.objs.items[at.?].etag))) return .{ .status = 412 };
        const etag = try std.fmt.allocPrint(s.gpa, "\"sim-{d}\"", .{s.next_etag});
        s.next_etag += 1;
        if (at) |i| {
            try noteReplies(s, a, cal.objs.items[i].data, req.body);
            cal.objs.items[i].data = try s.gpa.dupe(u8, req.body);
            cal.objs.items[i].etag = etag;
            return .{ .status = 204, .etag = etag };
        }
        try cal.objs.append(s.gpa, .{ .name = try s.gpa.dupe(u8, name), .etag = etag, .data = try s.gpa.dupe(u8, req.body) });
        return .{ .status = 201, .etag = etag };
    }
    if (eql(u8, req.method, "DELETE")) {
        if (!cal.writable) return .{ .status = 403 };
        const i = at orelse return .{ .status = 404 };
        if (req.if_match.len > 0 and !eql(u8, req.if_match, cal.objs.items[i].etag)) return .{ .status = 412 };
        _ = cal.objs.orderedRemove(i);
        return .{ .status = 204 };
    }
    return .{ .status = 405 };
}

const Found = struct { cal: *Cal, obj: *Obj };

fn find(s: *Sim, path: []const u8) ?Found {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const dir = path[0..slash];
    const name = path[slash + 1 ..];
    for (&s.cals) |*cal| {
        if (!std.mem.endsWith(u8, dir, cal.key)) continue;
        for (cal.objs.items) |*o| if (std.mem.eql(u8, o.name, name)) return .{ .cal = cal, .obj = o };
    }
    return null;
}

/// RFC 6638: when the owner's answer in their copy changes, the server
/// sends it to the organizer. Kept as "ORGANIZER PARTSTAT UID" lines.
fn noteReplies(s: *Sim, a: Allocator, old: []const u8, new: []const u8) !void {
    const before = partstatOf(a, old) orelse return;
    const after = partstatOf(a, new) orelse return;
    if (std.mem.eql(u8, before.partstat, after.partstat)) return;
    try s.replies.print(s.gpa, "{s} {s} {s}\n", .{ after.organizer, after.partstat, after.uid });
}

const Answer = struct { organizer: []const u8, partstat: []const u8, uid: []const u8 };

fn partstatOf(a: Allocator, data: []const u8) ?Answer {
    _ = a;
    var org: []const u8 = "";
    var uid: []const u8 = "";
    var ps: ?[]const u8 = null;
    var it = std.mem.splitSequence(u8, data, "\r\n");
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "UID:") and uid.len == 0) uid = l[4..];
        if (std.mem.startsWith(u8, l, "ORGANIZER") and org.len == 0) {
            if (std.ascii.findIgnoreCase(l, "mailto:")) |i| org = l[i + 7 ..];
        }
        if (std.mem.startsWith(u8, l, "ATTENDEE") and std.ascii.findIgnoreCase(l, "mailto:" ++ owner_email) != null and ps == null) {
            const at = std.mem.indexOf(u8, l, "PARTSTAT=") orelse continue;
            const rest = l[at + 9 ..];
            ps = rest[0 .. std.mem.indexOfAny(u8, rest, ";:") orelse rest.len];
        }
    }
    return .{ .organizer = org, .partstat = ps orelse return null, .uid = uid };
}

fn calProps(a: Allocator, cal: *const Cal) ![]const u8 {
    const priv: []const u8 = if (cal.writable) "<d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege>" else "<d:privilege><d:read/></d:privilege>";
    const zone: []const u8 = if (std.mem.eql(u8, cal.comp, "VEVENT")) try std.fmt.allocPrint(a, "<c:calendar-timezone>{s}</c:calendar-timezone>", .{try xml.escape(a, "BEGIN:VCALENDAR\r\n" ++ vtz_warsaw ++ "END:VCALENDAR\r\n")}) else "";
    return std.fmt.allocPrint(a, "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>{s}</d:displayname><c:supported-calendar-component-set><c:comp name=\"{s}\"/></c:supported-calendar-component-set><d:current-user-privilege-set>{s}</d:current-user-privilege-set><cs:getctag>ctag-{d}</cs:getctag>{s}", .{ cal.name, cal.comp, priv, cal.objs.items.len, zone });
}

fn response(a: Allocator, href: []const u8, props: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "<d:response><d:href>{s}</d:href><d:propstat><d:prop>{s}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>", .{ href, props });
}

fn multistatus(a: Allocator, responses: []const []const u8) !Res {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\" xmlns:cs=\"http://calendarserver.org/ns/\">");
    for (responses) |r| try o.appendSlice(a, r);
    try o.appendSlice(a, "</d:multistatus>\n");
    return .{ .status = 207, .ctype = "application/xml; charset=utf-8", .body = o.items };
}

/// calendar-query: a UID's object, or the objects a time range may hold
/// (more than it does: the client reads each one's times itself).
fn report(a: Allocator, req: Req, cal: *Cal) !Res {
    const root = xml.parse(a, req.body) catch return .{ .status = 400 };
    var list: std.ArrayList([]const u8) = .empty;
    const uid: ?[]const u8 = if (root.find("text-match")) |m| m.value() else null;
    var from: ?i64 = null;
    var to: ?i64 = null;
    if (root.find("time-range")) |r| {
        from = dayOf(r.attr("start") orelse "");
        to = dayOf(r.attr("end") orelse "");
    }
    for (cal.objs.items) |o| {
        if (!std.mem.eql(u8, cal.comp, "VEVENT")) break;
        if (uid) |u| {
            const want = try std.fmt.allocPrint(a, "\r\nUID:{s}\r\n", .{u});
            if (std.mem.indexOf(u8, o.data, want) == null) continue;
        } else if (std.mem.indexOf(u8, o.data, "\r\nRRULE:") == null) {
            // a single event: its start's date near the range
            const at = std.mem.indexOf(u8, o.data, "\r\nDTSTART") orelse continue;
            const colon = std.mem.indexOfScalarPos(u8, o.data, at + 2, ':') orelse continue;
            const d = dayOf(o.data[colon + 1 ..]) orelse continue;
            if (from) |f| if (d < f - 2) continue;
            if (to) |t| if (d > t + 2) continue;
        }
        try list.append(a, try std.fmt.allocPrint(a, "<d:response><d:href>{s}{s}</d:href><d:propstat><d:prop><d:getetag>{s}</d:getetag><c:calendar-data>{s}</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>", .{ req.path, o.name, try xml.escape(a, o.etag), try xml.escape(a, o.data) }));
    }
    return multistatus(a, list.items);
}

/// The day of "20261123…".
fn dayOf(v: []const u8) ?i64 {
    if (v.len < 8) return null;
    const y = std.fmt.parseInt(i64, v[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, v[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, v[6..8], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return tz.daysFromCivil(y, m, d);
}
