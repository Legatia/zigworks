//! SMTP submission over TLS: TLS from the start (465) or after STARTTLS
//! (587; a server that doesn't offer STARTTLS gets nothing), AUTH PLAIN,
//! LOGIN or XOAUTH2, one message to its recipients.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tlsconn = @import("tlsconn.zig");

pub const Error = error{
    /// The server refused something; `Result.why` says what.
    Refused,
    LoginRefused,
    NoStartTls,
    BadResponse,
    ConnectionClosed,
    Timeout,
} || tlsconn.Error;

pub const Message = struct {
    from: []const u8,
    to: []const []const u8,
    /// The whole message, "\r\n" line ends.
    data: []const u8,
};

pub const Server = struct {
    host: []const u8,
    port: u16,
    implicit: bool,
    login: []const u8,
    secret: []const u8,
    xoauth2: bool = false,
};

const Reply = struct { code: u16, lines: []const []const u8 };

const Session = struct {
    conn: *tlsconn.Conn,
    a: Allocator,
    /// `why`'s own allocator.
    gpa: Allocator,
    why: *std.ArrayList(u8),

    fn reply(s: *Session) Error!Reply {
        var lines: std.ArrayList([]const u8) = .empty;
        while (true) {
            const raw = s.conn.in().takeDelimiter('\n') catch return s.fault();
            const line = std.mem.trimEnd(u8, raw orelse return error.ConnectionClosed, "\r");
            if (line.len < 3) return error.BadResponse;
            const code = std.fmt.parseInt(u16, line[0..3], 10) catch return error.BadResponse;
            lines.append(s.a, s.a.dupe(u8, if (line.len > 4) line[4..] else "") catch return error.OutOfMemory) catch return error.OutOfMemory;
            if (line.len == 3 or line[3] == ' ') return .{ .code = code, .lines = lines.items };
            if (lines.items.len > 200) return error.BadResponse;
        }
    }

    fn fault(s: *Session) Error {
        return if (s.conn.s.timed_out) error.Timeout else error.ConnectionClosed;
    }

    fn send(s: *Session, line: []const u8) Error!void {
        s.conn.out().writeAll(line) catch return s.fault();
        s.conn.out().writeAll("\r\n") catch return s.fault();
        s.conn.flush() catch return s.fault();
    }

    /// Sends `line`; the reply must be `want` (its first digit when `want`
    /// < 10).
    fn expect(s: *Session, line: []const u8, want: u16) Error!Reply {
        try s.send(line);
        return s.check(want);
    }

    fn check(s: *Session, want: u16) Error!Reply {
        const r = try s.reply();
        const ok = if (want < 10) r.code / 100 == want else r.code == want;
        if (!ok) {
            s.why.clearRetainingCapacity();
            s.why.print(s.gpa, "{d} {s}", .{ r.code, if (r.lines.len > 0) r.lines[r.lines.len - 1] else "" }) catch {};
            return error.Refused;
        }
        return r;
    }
};

fn offers(r: Reply, word: []const u8) bool {
    for (r.lines) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const first = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(first, word)) return true;
    }
    return false;
}

fn authOffers(r: Reply, mech: []const u8) bool {
    for (r.lines) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const first = it.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(first, "AUTH")) continue;
        while (it.next()) |m| if (std.ascii.eqlIgnoreCase(m, mech)) return true;
    }
    return false;
}

fn b64(a: Allocator, raw: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return out;
}

/// Sends `m` through `srv`. `why` gets the server's words when it refuses.
pub fn send(gpa: Allocator, io: Io, srv: Server, trust: *tlsconn.Trust, m: Message, idle_ms: u32, why: *std.ArrayList(u8)) Error!void {
    return run(gpa, io, srv, trust, m, idle_ms, why);
}

/// Connects and logs in, and sends nothing (`mailmcp check`).
pub fn check(gpa: Allocator, io: Io, srv: Server, trust: *tlsconn.Trust, idle_ms: u32, why: *std.ArrayList(u8)) Error!void {
    return run(gpa, io, srv, trust, null, idle_ms, why);
}

fn run(gpa: Allocator, io: Io, srv: Server, trust: *tlsconn.Trust, msg: ?Message, idle_ms: u32, why: *std.ArrayList(u8)) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (msg) |m| {
        for (m.to) |r| if (std.mem.indexOfAny(u8, r, "\r\n<> ") != null) return error.Refused;
        if (std.mem.indexOfAny(u8, m.from, "\r\n<> ") != null) return error.Refused;
    }
    const conn = try tlsconn.open(gpa, io, srv.host, srv.port, srv.implicit, trust, idle_ms);
    defer conn.close();
    var s: Session = .{ .conn = conn, .a = a, .gpa = gpa, .why = why };
    _ = try s.check(220);
    var ehlo = try s.expect("EHLO mailmcp.localdomain", 250);
    if (!srv.implicit) {
        if (!offers(ehlo, "STARTTLS")) return error.NoStartTls;
        _ = try s.expect("STARTTLS", 220);
        try conn.startTls(trust);
        ehlo = try s.expect("EHLO mailmcp.localdomain", 250);
    }
    // logging in
    if (srv.xoauth2) {
        const raw = try std.fmt.allocPrint(a, "user={s}\x01auth=Bearer {s}\x01\x01", .{ srv.login, srv.secret });
        try s.send(try std.fmt.allocPrint(a, "AUTH XOAUTH2 {s}", .{try b64(a, raw)}));
        var r = try s.reply();
        if (r.code == 334) {
            // the server's reason, base64 JSON: answered empty, then 535
            try s.send("");
            r = try s.reply();
        }
        if (r.code != 235) return error.LoginRefused;
    } else if (authOffers(ehlo, "PLAIN") or !authOffers(ehlo, "LOGIN")) {
        const raw = try std.fmt.allocPrint(a, "\x00{s}\x00{s}", .{ srv.login, srv.secret });
        _ = s.expect(try std.fmt.allocPrint(a, "AUTH PLAIN {s}", .{try b64(a, raw)}), 235) catch |e| return if (e == error.Refused) error.LoginRefused else e;
    } else {
        _ = try s.expect("AUTH LOGIN", 334);
        _ = try s.expect(try b64(a, srv.login), 334);
        _ = s.expect(try b64(a, srv.secret), 235) catch |e| return if (e == error.Refused) error.LoginRefused else e;
    }
    const m = msg orelse {
        _ = s.expect("QUIT", 221) catch {};
        return;
    };
    _ = try s.expect(try std.fmt.allocPrint(a, "MAIL FROM:<{s}>", .{m.from}), 2);
    for (m.to) |r| _ = try s.expect(try std.fmt.allocPrint(a, "RCPT TO:<{s}>", .{r}), 2);
    _ = try s.expect("DATA", 354);
    // the message, dot-stuffed, "\r\n" line ends
    const w = conn.out();
    var it = std.mem.splitScalar(u8, m.data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // the message's own last line end
        if (it.peek() == null and line.len == 0) break;
        if (line.len > 0 and line[0] == '.') w.writeAll(".") catch return s.fault();
        w.writeAll(line) catch return s.fault();
        w.writeAll("\r\n") catch return s.fault();
    }
    _ = try s.expect(".", 250);
    _ = s.expect("QUIT", 221) catch {};
}
