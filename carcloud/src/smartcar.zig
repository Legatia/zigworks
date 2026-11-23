//! Smartcar's v3 API, the parts carcloud uses: an application token
//! (client credentials), all of a car's signals in one request, and
//! commands, waited out to their end. Written from Smartcar's docs (as of
//! November 2026); tried against carcloud-sim only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const http = @import("http.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");

/// What Smartcar said when it said no.
pub const Problem = struct {
    status: u16,
    kind: []const u8 = "",
    code: []const u8 = "",
    title: []const u8 = "",
    detail: []const u8 = "",

    pub fn text(p: Problem, a: Allocator) ![]u8 {
        const why = if (std.mem.eql(u8, p.kind, "VEHICLE_STATE"))
            "the car can't do it now"
        else if (std.mem.eql(u8, p.kind, "BILLING"))
            "the Smartcar plan does not allow it"
        else if (std.mem.eql(u8, p.kind, "RATE_LIMIT"))
            "too many requests; try later"
        else if (std.mem.eql(u8, p.kind, "COMPATIBILITY"))
            "this car or its maker does not offer it"
        else if (std.mem.eql(u8, p.kind, "AUTHENTICATION"))
            "Smartcar refused the credentials"
        else if (std.mem.eql(u8, p.kind, "CONNECTED_SERVICES_ACCOUNT"))
            "the car's own account needs attention (for a Tesla: Smartcar's virtual key)"
        else
            "Smartcar said no";
        return std.fmt.allocPrint(a, "{s} (HTTP {d}{s}{s}{s}{s}){s}{s}", .{ why, p.status, if (p.kind.len > 0) ", " else "", p.kind, if (p.code.len > 0) " " else "", p.code, if (p.detail.len > 0 or p.title.len > 0) ": " else "", if (p.detail.len > 0) p.detail else p.title });
    }
};

pub const Signal = struct {
    code: []const u8,
    ok: bool,
    body: ?jv.Value,
    /// seconds since the car reported it
    age_s: ?f64,
};

pub const Outcome = struct {
    /// SUCCESS, FAILURE, EXPIRED, or PENDING when it did not end in time
    status: []const u8,
    detail: []const u8 = "",
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    secret: []const u8,
    api: http.Client,
    auth: http.Client,
    token: []u8 = &.{},
    token_until_ns: i128 = 0,
    problem: ?Problem = null,

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, secret: []const u8) !Client {
        var c: Client = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .secret = secret,
            .api = .init(gpa, io, try http.Target.parse(cfg.api)),
            .auth = .init(gpa, io, try http.Target.parse(cfg.token_url)),
        };
        c.api.user_agent = "carcloud";
        c.auth.user_agent = "carcloud";
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.api.deinit();
        c.auth.deinit();
        c.gpa.free(c.token);
    }

    /// An application token, fetched again a minute before it runs out.
    fn appToken(c: *Client, a: Allocator) ![]const u8 {
        if (c.token.len > 0 and sock.nowNs(c.io) < c.token_until_ns) return c.token;
        const body = try std.fmt.allocPrint(a, "grant_type=client_credentials&client_id={f}&client_secret={f}", .{ formEscape(c.cfg.client_id), formEscape(c.secret) });
        const ans = try http.fetch(&c.auth, a, .{ .path = "", .body = body, .content_type = "application/x-www-form-urlencoded", .limits = .{ .idle_ms = 15_000, .total_ms = 30_000 } });
        if (ans.status != 200) {
            c.problem = .{ .status = ans.status, .kind = "AUTHENTICATION", .code = jv.str(jv.get(jv.parse(a, ans.body), "error")) orelse "" };
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

    fn headers(c: *Client, a: Allocator, extra: ?std.http.Header) ![]const std.http.Header {
        const list = try a.alloc(std.http.Header, if (extra != null) 2 else 1);
        list[0] = .{ .name = "sc-user-id", .value = c.cfg.user_id };
        if (extra) |e| list[1] = e;
        return list;
    }

    /// Every signal of the car, from one request.
    pub fn signals(c: *Client, a: Allocator) ![]Signal {
        c.problem = null;
        const tok = try c.appToken(a);
        const ans = try http.fetch(&c.api, a, .{
            .method = .GET,
            .path = try std.fmt.allocPrint(a, "/vehicles/{s}/signals", .{c.cfg.vehicle_id}),
            .key = tok,
            .headers = try c.headers(a, null),
            .limits = .{ .idle_ms = 20_000, .total_ms = 40_000 },
        });
        if (ans.status != 200) {
            c.problem = problemOf(a, ans);
            return error.Refused;
        }
        const list = jv.arr(jv.get(jv.parse(a, ans.body), "data")) orelse return error.BadAnswer;
        var out: std.ArrayList(Signal) = .empty;
        for (list) |s| {
            const at = jv.get(s, "attributes");
            try out.append(a, .{
                .code = jv.str(jv.get(at, "code")) orelse continue,
                .ok = std.mem.eql(u8, jv.str(jv.at(at, &.{ "status", "value" })) orelse "", "SUCCESS"),
                .body = jv.get(at, "body"),
                .age_s = ageOf(c.io, jv.str(jv.at(s, &.{ "meta", "oemUpdatedAt" })) orelse jv.str(jv.at(s, &.{ "meta", "retrievedAt" }))),
            });
        }
        return out.items;
    }

    /// Sends a command and waits for its end, at most about 90 seconds.
    pub fn command(c: *Client, a: Allocator, cmd: config.Command, percent: ?u8) !Outcome {
        c.problem = null;
        const tok = try c.appToken(a);
        const body: ?[]const u8 = if (cmd == .charge_limit) try std.fmt.allocPrint(a, "{{\"data\":{{\"attributes\":{{\"percent\":{d}}}}}}}", .{percent.?}) else "{}";
        const ans = try http.fetch(&c.api, a, .{
            .path = try std.fmt.allocPrint(a, "/vehicles/{s}/commands/{s}", .{ c.cfg.vehicle_id, cmd.path() }),
            .body = body,
            .key = tok,
            .headers = try c.headers(a, .{ .name = "Prefer", .value = "wait=60" }),
            .limits = .{ .idle_ms = 75_000, .total_ms = 90_000 },
        });
        if (ans.status != 200 and ans.status != 202) {
            c.problem = problemOf(a, ans);
            return error.Refused;
        }
        var exec = jv.get(jv.parse(a, ans.body), "data");
        var waited: u32 = 0;
        while (true) {
            const status = jv.str(jv.at(exec, &.{ "attributes", "status", "value" })) orelse "PENDING";
            if (!std.mem.eql(u8, status, "PENDING")) return .{ .status = status, .detail = errText(a, jv.at(exec, &.{ "attributes", "status", "error" })) };
            if (waited >= 90) return .{ .status = "PENDING" };
            const id = jv.str(jv.get(exec, "id")) orelse return .{ .status = "PENDING" };
            c.io.sleep(.fromMilliseconds(3000), .awake) catch {};
            waited += 3;
            const again = try http.fetch(&c.api, a, .{
                .method = .GET,
                .path = try std.fmt.allocPrint(a, "/command-executions/{s}", .{id}),
                .key = try c.appToken(a),
                .limits = .{ .idle_ms = 20_000, .total_ms = 30_000 },
            });
            if (again.status != 200) {
                c.problem = problemOf(a, again);
                return error.Refused;
            }
            exec = jv.get(jv.parse(a, again.body), "data");
        }
    }
};

fn problemOf(a: Allocator, ans: http.Answer) Problem {
    const e = if (jv.arr(jv.get(jv.parse(a, ans.body), "errors"))) |list| (if (list.len > 0) list[0] else null) else null;
    return .{
        .status = ans.status,
        .kind = jv.str(jv.get(e, "type")) orelse "",
        .code = jv.str(jv.get(e, "code")) orelse "",
        .title = jv.str(jv.get(e, "title")) orelse "",
        .detail = jv.str(jv.get(e, "detail")) orelse "",
    };
}

fn errText(a: Allocator, e: ?jv.Value) []const u8 {
    const v = e orelse return "";
    const s = std.fmt.allocPrint(a, "{s} {s}", .{ jv.str(jv.get(v, "type")) orelse jv.str(jv.get(v, "code")) orelse "", jv.str(jv.get(v, "detail")) orelse jv.str(jv.get(v, "title")) orelse "" }) catch return "";
    return std.mem.trim(u8, s, " ");
}

/// application/x-www-form-urlencoded
fn formEscape(s: []const u8) Form {
    return .{ .s = s };
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

/// Seconds since an ISO 8601 time (UTC), such as 2026-11-22T10:01:02.123Z.
pub fn ageOf(io: Io, iso: ?[]const u8) ?f64 {
    const s = iso orelse return null;
    if (s.len < 19) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = if (mo > 2) mo - 3 else mo + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const then = (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss;
    const now = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    return @floatFromInt(@max(0, now - then));
}

test "form escaping" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a%2Bb%26c%3D%20d", try std.fmt.bufPrint(&buf, "{f}", .{formEscape("a+b&c= d")}));
}

test "a refusal, said plainly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = problemOf(arena.allocator(), .{ .status = 409, .body = @constCast("{\"errors\":[{\"status\":\"409\",\"type\":\"VEHICLE_STATE\",\"code\":\"CHARGING_PLUG_NOT_CONNECTED\",\"title\":\"Plug not connected\",\"detail\":\"Plug the car in first.\"}]}") });
    try std.testing.expectEqualStrings("the car can't do it now (HTTP 409, VEHICLE_STATE CHARGING_PLUG_NOT_CONNECTED): Plug the car in first.", try p.text(arena.allocator()));
}
