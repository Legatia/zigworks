//! An IMAP4rev1 client over TLS, with only what mailmcp needs: logging in
//! (LOGIN, AUTHENTICATE PLAIN or XOAUTH2), EXAMINE (read-only: nothing can
//! be marked), UID SEARCH, UID FETCH with BODY.PEEK, LIST, APPEND (drafts)
//! and IDLE. It has no STORE, COPY, MOVE, EXPUNGE or DELETE, and never
//! SELECTs a folder.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tlsconn = @import("tlsconn.zig");

pub const Value = union(enum) {
    atom: []const u8,
    string: []const u8,
    list: []const Value,
    nil,

    pub fn text(v: Value) ?[]const u8 {
        return switch (v) {
            .atom, .string => |s| s,
            else => null,
        };
    }
};

/// One response: its tag ("*", "+" or the command's), and for status
/// responses (OK, NO, BAD, BYE, PREAUTH) the word, the code in brackets
/// and the text; for others the values.
pub const Response = struct {
    tag: []const u8,
    status: []const u8 = "",
    code: []const u8 = "",
    text: []const u8 = "",
    /// `* 12 EXISTS`: 12; null when the second word is no number.
    number: ?u32 = null,
    /// The word after the tag (or after the number): EXISTS, FETCH,
    /// SEARCH, LIST, CAPABILITY …
    kind: []const u8 = "",
    values: []const Value = &.{},
};

pub const Error = error{
    /// The server said NO or BAD; `last` says what.
    Refused,
    /// The login was refused.
    LoginRefused,
    /// The server ended the connection (BYE) or sent what isn't IMAP.
    BadResponse,
    /// A folder name or login with a line break.
    BadArgument,
    ConnectionClosed,
    Timeout,
} || tlsconn.Error;

pub const Selected = struct { exists: u32 = 0, uidvalidity: u32 = 0, uidnext: u32 = 0 };

pub const Fetched = struct {
    uid: u32 = 0,
    flags: []const []const u8 = &.{},
    size: u64 = 0,
    /// The message (or its first bytes, for a partial fetch).
    body: []const u8 = "",

    pub fn seen(f: Fetched) bool {
        for (f.flags) |x| if (std.ascii.eqlIgnoreCase(x, "\\Seen")) return true;
        return false;
    }
};

pub const Folder = struct { name: []const u8, attrs: []const []const u8 };

pub const Login = struct {
    user: []const u8,
    secret: []const u8,
    xoauth2: bool = false,
};

pub const Client = struct {
    gpa: Allocator,
    conn: *tlsconn.Conn,
    n: u32 = 0,
    /// The server's capabilities, uppercased.
    caps: std.ArrayList([]u8) = .empty,
    /// The text of the last NO or BAD (gpa).
    last: std.ArrayList(u8) = .empty,
    idling: ?[8]u8 = null,

    /// Connects, reads the greeting and the capabilities, logs in.
    pub fn connect(gpa: Allocator, io: Io, host: []const u8, port: u16, trust: *tlsconn.Trust, login: Login, idle_ms: u32) !*Client {
        const conn = try tlsconn.open(gpa, io, host, port, true, trust, idle_ms);
        const c = gpa.create(Client) catch {
            conn.close();
            return error.OutOfMemory;
        };
        c.* = .{ .gpa = gpa, .conn = conn };
        errdefer c.destroy();
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const hello = try c.read(a);
        if (!std.mem.eql(u8, hello.tag, "*") or !(eqlI(hello.status, "OK") or eqlI(hello.status, "PREAUTH"))) return error.BadResponse;
        try c.capabilities(a);
        if (!eqlI(hello.status, "PREAUTH")) try c.logIn(a, login);
        // capabilities may change once logged in
        try c.capabilities(a);
        return c;
    }

    fn destroy(c: *Client) void {
        c.conn.close();
        for (c.caps.items) |x| c.gpa.free(x);
        c.caps.deinit(c.gpa);
        c.last.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    /// LOGOUT, then the connection closes.
    pub fn close(c: *Client) void {
        var arena = std.heap.ArenaAllocator.init(c.gpa);
        defer arena.deinit();
        if (c.idling == null) {
            c.conn.setIdle(3000);
            _ = c.command(arena.allocator(), "LOGOUT", null) catch {};
        }
        c.destroy();
    }

    pub fn has(c: *const Client, cap: []const u8) bool {
        for (c.caps.items) |x| if (eqlI(x, cap)) return true;
        return false;
    }

    pub fn lastText(c: *const Client) []const u8 {
        return c.last.items;
    }

    fn capabilities(c: *Client, a: Allocator) !void {
        const rs = try c.command(a, "CAPABILITY", null);
        for (c.caps.items) |x| c.gpa.free(x);
        c.caps.clearRetainingCapacity();
        for (rs) |r| if (eqlI(r.kind, "CAPABILITY")) for (r.values) |v| if (v.text()) |s| {
            const up = try c.gpa.dupe(u8, s);
            for (up) |*ch| ch.* = std.ascii.toUpper(ch.*);
            try c.caps.append(c.gpa, up);
        };
    }

    fn logIn(c: *Client, a: Allocator, login: Login) !void {
        const b64 = std.base64.standard.Encoder;
        if (login.xoauth2) {
            const raw = try std.fmt.allocPrint(a, "user={s}\x01auth=Bearer {s}\x01\x01", .{ login.user, login.secret });
            const enc = try a.alloc(u8, b64.calcSize(raw.len));
            _ = b64.encode(enc, raw);
            return c.authenticate(a, "XOAUTH2", enc);
        }
        if (c.has("AUTH=PLAIN")) {
            const raw = try std.fmt.allocPrint(a, "\x00{s}\x00{s}", .{ login.user, login.secret });
            const enc = try a.alloc(u8, b64.calcSize(raw.len));
            _ = b64.encode(enc, raw);
            return c.authenticate(a, "PLAIN", enc);
        }
        if (c.has("LOGINDISABLED")) return error.LoginRefused;
        const line = try std.fmt.allocPrint(a, "LOGIN {s} {s}", .{ try quote(a, login.user), try quote(a, login.secret) });
        _ = c.command(a, line, null) catch |e| return if (e == error.Refused) error.LoginRefused else e;
    }

    /// AUTHENTICATE MECH with its initial response; a challenge after it
    /// (the server's reason for refusing XOAUTH2) is answered empty.
    fn authenticate(c: *Client, a: Allocator, mech: []const u8, initial: []const u8) !void {
        const tag = c.nextTag();
        const w = c.conn.out();
        const ir = c.has("SASL-IR");
        if (ir) {
            try w.print("{s} AUTHENTICATE {s} {s}\r\n", .{ &tag, mech, initial });
        } else try w.print("{s} AUTHENTICATE {s}\r\n", .{ &tag, mech });
        try c.conn.flush();
        var sent = ir;
        while (true) {
            const r = try c.read(a);
            if (std.mem.eql(u8, r.tag, "+")) {
                if (!sent) {
                    try w.print("{s}\r\n", .{initial});
                    sent = true;
                } else try w.writeAll("\r\n");
                try c.conn.flush();
                continue;
            }
            if (std.mem.eql(u8, r.tag, &tag)) {
                if (eqlI(r.status, "OK")) return;
                c.keepLast(r.text);
                return error.LoginRefused;
            }
            if (eqlI(r.status, "BYE")) return error.ConnectionClosed;
        }
    }

    fn nextTag(c: *Client) [8]u8 {
        c.n += 1;
        var tag: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&tag, "m{d:0>7}", .{c.n % 10_000_000}) catch unreachable;
        return tag;
    }

    fn keepLast(c: *Client, text: []const u8) void {
        c.last.clearRetainingCapacity();
        c.last.appendSlice(c.gpa, text[0..@min(text.len, 300)]) catch {};
    }

    /// Sends `line` (and `literal` after the server's go-ahead, for
    /// APPEND) and reads up to the tagged answer: the untagged responses
    /// before it, then it. error.Refused for NO or BAD (`lastText`).
    pub fn command(c: *Client, a: Allocator, line: []const u8, literal: ?[]const u8) Error![]Response {
        const tag = c.nextTag();
        const w = c.conn.out();
        w.print("{s} {s}", .{ &tag, line }) catch return c.fault();
        if (literal) |lit| {
            w.print(" {{{d}}}\r\n", .{lit.len}) catch return c.fault();
            c.conn.flush() catch return c.fault();
            while (true) {
                const r = try c.read(a);
                if (std.mem.eql(u8, r.tag, "+")) break;
                if (std.mem.eql(u8, r.tag, &tag)) {
                    c.keepLast(r.text);
                    return error.Refused;
                }
            }
            w.writeAll(lit) catch return c.fault();
        }
        w.writeAll("\r\n") catch return c.fault();
        c.conn.flush() catch return c.fault();
        var out: std.ArrayList(Response) = .empty;
        while (true) {
            const r = try c.read(a);
            if (std.mem.eql(u8, r.tag, &tag)) {
                if (eqlI(r.status, "OK")) {
                    out.append(a, r) catch return error.OutOfMemory;
                    return out.items;
                }
                c.keepLast(r.text);
                return error.Refused;
            }
            if (std.mem.eql(u8, r.tag, "*") and eqlI(r.status, "BYE") and !std.mem.startsWith(u8, line, "LOGOUT")) {
                c.keepLast(r.text);
                return error.ConnectionClosed;
            }
            out.append(a, r) catch return error.OutOfMemory;
        }
    }

    fn fault(c: *Client) Error {
        if (c.conn.s.timed_out) return error.Timeout;
        return error.ConnectionClosed;
    }

    /// EXAMINE `folder`: opened read-only.
    pub fn examine(c: *Client, a: Allocator, folder: []const u8) Error!Selected {
        const rs = try c.command(a, try std.fmt.allocPrint(a, "EXAMINE {s}", .{try quote(a, folder)}), null);
        var s: Selected = .{};
        for (rs) |r| {
            if (r.number) |n| if (eqlI(r.kind, "EXISTS")) {
                s.exists = n;
            };
            if (codeNumber(r.code, "UIDVALIDITY")) |v| s.uidvalidity = v;
            if (codeNumber(r.code, "UIDNEXT")) |v| s.uidnext = v;
        }
        return s;
    }

    /// UID SEARCH `criteria`: the UIDs, ascending.
    pub fn search(c: *Client, a: Allocator, criteria: []const u8) Error![]u32 {
        const rs = try c.command(a, try std.fmt.allocPrint(a, "UID SEARCH {s}", .{criteria}), null);
        var out: std.ArrayList(u32) = .empty;
        for (rs) |r| if (eqlI(r.kind, "SEARCH")) for (r.values) |v| if (v.text()) |s| {
            const n = std.fmt.parseInt(u32, s, 10) catch continue;
            out.append(a, n) catch return error.OutOfMemory;
        };
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        return out.items;
    }

    /// UID FETCH of `uids` with BODY.PEEK (nothing is marked seen): the
    /// whole message, or its first `max` bytes when `max` is set.
    pub fn fetch(c: *Client, a: Allocator, uids: []const u32, max: ?usize) Error![]Fetched {
        if (uids.len == 0) return &.{};
        var set: std.ArrayList(u8) = .empty;
        for (uids, 0..) |u, i| set.print(a, "{s}{d}", .{ if (i > 0) "," else "", u }) catch return error.OutOfMemory;
        const part = if (max) |m| std.fmt.allocPrint(a, "BODY.PEEK[]<0.{d}>", .{m}) catch return error.OutOfMemory else "BODY.PEEK[]";
        const rs = try c.command(a, std.fmt.allocPrint(a, "UID FETCH {s} (UID FLAGS RFC822.SIZE {s})", .{ set.items, part }) catch return error.OutOfMemory, null);
        var out: std.ArrayList(Fetched) = .empty;
        for (rs) |r| {
            if (!eqlI(r.kind, "FETCH") or r.values.len == 0 or r.values[0] != .list) continue;
            const items = r.values[0].list;
            var f: Fetched = .{};
            var i: usize = 0;
            while (i + 1 < items.len) : (i += 2) {
                const key = items[i].text() orelse continue;
                const v = items[i + 1];
                if (eqlI(key, "UID")) {
                    f.uid = std.fmt.parseInt(u32, v.text() orelse "", 10) catch 0;
                } else if (eqlI(key, "RFC822.SIZE")) {
                    f.size = std.fmt.parseInt(u64, v.text() orelse "", 10) catch 0;
                } else if (eqlI(key, "FLAGS")) {
                    if (v == .list) {
                        var fl: std.ArrayList([]const u8) = .empty;
                        for (v.list) |x| if (x.text()) |s| fl.append(a, s) catch return error.OutOfMemory;
                        f.flags = fl.items;
                    }
                } else if (std.ascii.startsWithIgnoreCase(key, "BODY[")) {
                    f.body = v.text() orelse "";
                }
            }
            if (f.uid != 0) out.append(a, f) catch return error.OutOfMemory;
        }
        // in the order asked
        var ordered: std.ArrayList(Fetched) = .empty;
        for (uids) |u| for (out.items) |f| if (f.uid == u) {
            ordered.append(a, f) catch return error.OutOfMemory;
            break;
        };
        return ordered.items;
    }

    /// LIST "" "*": every folder with its attributes (\Drafts …).
    pub fn list(c: *Client, a: Allocator) Error![]Folder {
        const rs = try c.command(a, "LIST \"\" \"*\"", null);
        var out: std.ArrayList(Folder) = .empty;
        for (rs) |r| {
            if (!eqlI(r.kind, "LIST") or r.values.len < 3) continue;
            var attrs: std.ArrayList([]const u8) = .empty;
            if (r.values[0] == .list) for (r.values[0].list) |x| if (x.text()) |s| attrs.append(a, s) catch return error.OutOfMemory;
            const name = r.values[2].text() orelse continue;
            out.append(a, .{ .name = name, .attrs = attrs.items }) catch return error.OutOfMemory;
        }
        return out.items;
    }

    /// The folder drafts go in: the one marked \Drafts, else one called
    /// Drafts (any case), else "Drafts".
    pub fn draftsFolder(c: *Client, a: Allocator) Error![]const u8 {
        const folders = try c.list(a);
        for (folders) |f| for (f.attrs) |x| if (eqlI(x, "\\Drafts")) return f.name;
        for (folders) |f| if (eqlI(f.name, "Drafts")) return f.name;
        return "Drafts";
    }

    /// APPEND `message` to `folder` as a draft (\Draft \Seen: a new draft,
    /// not unread mail). The UID when the server says it (UIDPLUS).
    pub fn appendDraft(c: *Client, a: Allocator, folder: []const u8, message: []const u8) Error!?u32 {
        const rs = try c.command(a, std.fmt.allocPrint(a, "APPEND {s} (\\Draft \\Seen)", .{try quote(a, folder)}) catch return error.OutOfMemory, message);
        const done = rs[rs.len - 1];
        if (std.ascii.startsWithIgnoreCase(done.code, "APPENDUID ")) {
            var it = std.mem.tokenizeScalar(u8, done.code, ' ');
            _ = it.next();
            _ = it.next();
            return std.fmt.parseInt(u32, it.next() orelse "", 10) catch null;
        }
        return null;
    }

    /// Starts IDLE: the server says what changes until `idleDone`.
    pub fn idleStart(c: *Client, a: Allocator) Error!void {
        const tag = c.nextTag();
        const w = c.conn.out();
        w.print("{s} IDLE\r\n", .{&tag}) catch return c.fault();
        c.conn.flush() catch return c.fault();
        while (true) {
            const r = try c.read(a);
            if (std.mem.eql(u8, r.tag, "+")) {
                c.idling = tag;
                return;
            }
            if (std.mem.eql(u8, r.tag, &tag)) {
                c.keepLast(r.text);
                return error.Refused;
            }
        }
    }

    pub const Change = enum { exists, other, nothing };

    /// Waits up to `ms` for what the server says while idling: a new
    /// message count (`exists`), something else, or nothing.
    pub fn idleWait(c: *Client, a: Allocator, ms: u32) Error!Change {
        if (!(c.conn.readable(ms) catch return c.fault())) return .nothing;
        const r = try c.read(a);
        if (r.number != null and eqlI(r.kind, "EXISTS")) return .exists;
        if (eqlI(r.status, "BYE")) return error.ConnectionClosed;
        return .other;
    }

    /// Ends IDLE: DONE, then the tagged answer.
    pub fn idleDone(c: *Client, a: Allocator) Error!void {
        const tag = c.idling orelse return;
        c.idling = null;
        const w = c.conn.out();
        w.writeAll("DONE\r\n") catch return c.fault();
        c.conn.flush() catch return c.fault();
        while (true) {
            const r = try c.read(a);
            if (std.mem.eql(u8, r.tag, &tag)) return;
        }
    }

    /// Reads one response.
    pub fn read(c: *Client, a: Allocator) Error!Response {
        var p: Parser = .{ .r = c.conn.in(), .a = a };
        return p.response() catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.EndOfStream, error.ReadFailed => c.fault(),
            else => error.BadResponse,
        };
    }
};

/// A folder name or a login as IMAP takes it: quoted, or a literal when
/// it holds a line break or a non-ASCII byte (not taken here: refused).
pub fn quote(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '"');
    for (s) |ch| {
        if (ch == '\r' or ch == '\n' or ch == 0) return error.BadArgument;
        if (ch == '"' or ch == '\\') try o.append(a, '\\');
        try o.append(a, ch);
    }
    try o.append(a, '"');
    return o.items;
}

fn codeNumber(code: []const u8, name: []const u8) ?u32 {
    if (!std.ascii.startsWithIgnoreCase(code, name)) return null;
    const rest = std.mem.trim(u8, code[name.len..], " ");
    return std.fmt.parseInt(u32, rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len], 10) catch null;
}

fn eqlI(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

/// Reads responses from the server: atoms, quoted strings, literals
/// ({N} then N bytes), NIL and lists, over as many lines as literals
/// take. Status texts are kept as written.
pub const Parser = struct {
    r: *Io.Reader,
    a: Allocator,
    depth: u32 = 0,

    const Err = error{ EndOfStream, ReadFailed, OutOfMemory, BadSyntax, TooLong };

    fn peek(p: *Parser) Err!u8 {
        return p.r.peekByte() catch |e| switch (e) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => error.ReadFailed,
        };
    }

    fn take(p: *Parser) Err!u8 {
        return p.r.takeByte() catch |e| switch (e) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => error.ReadFailed,
        };
    }

    fn skipSpaces(p: *Parser) Err!void {
        while ((try p.peek()) == ' ') _ = try p.take();
    }

    /// At a line's end ("\r\n" or "\n"): takes it.
    fn atEnd(p: *Parser) Err!bool {
        const ch = try p.peek();
        if (ch == '\n') {
            _ = try p.take();
            return true;
        }
        if (ch == '\r') {
            _ = try p.take();
            if ((try p.peek()) == '\n') _ = try p.take();
            return true;
        }
        return false;
    }

    /// The rest of the line, as written, without its end.
    fn restOfLine(p: *Parser) Err![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        while (true) {
            const ch = try p.take();
            if (ch == '\n') break;
            if (o.items.len > 64 * 1024) return error.TooLong;
            try o.append(p.a, ch);
        }
        return std.mem.trimEnd(u8, o.items, "\r");
    }

    fn word(p: *Parser) Err![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        var bracket: u32 = 0;
        while (true) {
            const ch = try p.peek();
            if (bracket == 0 and (ch == ' ' or ch == '(' or ch == ')' or ch == '\r' or ch == '\n')) break;
            if (ch == '\r' or ch == '\n') break;
            if (ch == '[') bracket += 1;
            if (ch == ']' and bracket > 0) bracket -= 1;
            if (o.items.len > 8 * 1024) return error.TooLong;
            try o.append(p.a, try p.take());
        }
        return o.items;
    }

    pub fn response(p: *Parser) Err!Response {
        const tag = try p.word();
        if (tag.len == 0) {
            // a stray blank line
            _ = try p.restOfLine();
            return .{ .tag = "" };
        }
        if ((try p.peek()) == ' ') _ = try p.take();
        if (std.mem.eql(u8, tag, "+")) return .{ .tag = tag, .text = try p.restOfLine() };
        var second = try p.word();
        var resp: Response = .{ .tag = tag };
        if (std.fmt.parseInt(u32, second, 10)) |n| {
            resp.number = n;
            try p.skipSpaces();
            second = try p.word();
        } else |_| {}
        const statuses = [_][]const u8{ "OK", "NO", "BAD", "BYE", "PREAUTH" };
        for (statuses) |s| if (resp.number == null and eqlI(second, s)) {
            resp.status = second;
            try p.skipSpaces();
            var rest = try p.restOfLine();
            if (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.lastIndexOfScalar(u8, rest, ']') orelse rest.len - 1;
                resp.code = rest[1..close];
                rest = std.mem.trimStart(u8, rest[@min(close + 1, rest.len)..], " ");
            }
            resp.text = rest;
            return resp;
        };
        resp.kind = second;
        var values: std.ArrayList(Value) = .empty;
        while (true) {
            try p.skipSpaces();
            if (try p.atEnd()) break;
            try values.append(p.a, try p.value());
        }
        resp.values = values.items;
        return resp;
    }

    fn value(p: *Parser) Err!Value {
        const ch = try p.peek();
        if (ch == '(') {
            _ = try p.take();
            p.depth += 1;
            if (p.depth > 50) return error.BadSyntax;
            defer p.depth -= 1;
            var items: std.ArrayList(Value) = .empty;
            while (true) {
                try p.skipSpaces();
                const c2 = try p.peek();
                if (c2 == ')') {
                    _ = try p.take();
                    break;
                }
                if (c2 == '\r' or c2 == '\n') return error.BadSyntax;
                try items.append(p.a, try p.value());
            }
            return .{ .list = items.items };
        }
        if (ch == '"') {
            _ = try p.take();
            var o: std.ArrayList(u8) = .empty;
            while (true) {
                var c2 = try p.take();
                if (c2 == '"') break;
                if (c2 == '\\') c2 = try p.take();
                if (c2 == '\n') return error.BadSyntax;
                if (o.items.len > 1 << 20) return error.TooLong;
                try o.append(p.a, c2);
            }
            return .{ .string = o.items };
        }
        if (ch == '{') {
            _ = try p.take();
            var n: usize = 0;
            while (true) {
                const c2 = try p.take();
                if (c2 == '}') break;
                if (c2 == '+') continue;
                if (!std.ascii.isDigit(c2)) return error.BadSyntax;
                n = n * 10 + (c2 - '0');
                if (n > 64 << 20) return error.TooLong;
            }
            if (!(try p.atEnd())) return error.BadSyntax;
            const bytes = p.r.readAlloc(p.a, n) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.ReadFailed,
            };
            return .{ .string = bytes };
        }
        const w = try p.word();
        if (w.len == 0) {
            // a lone ")" or something unexpected
            _ = try p.take();
            return error.BadSyntax;
        }
        if (eqlI(w, "NIL")) return .nil;
        return .{ .atom = w };
    }
};

const t = std.testing;

test "imap_responses_parse_with_literals_and_both_line_ends" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n" ++
        "* 2 FETCH (UID 12 FLAGS (\\Seen \\Draft) RFC822.SIZE 11 BODY[]<0> {11}\r\nHi\r\nthere\r\n)\r\n" ++
        "* SEARCH 3 12 7\n" ++
        "* LIST (\\HasNoChildren \\Drafts) \"/\" \"[Gmail]/Drafts\"\r\n" ++
        "* 4 EXISTS\r\n" ++
        "m0000001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n" ++
        "+ idling\r\n";
    var r: Io.Reader = .fixed(text);
    var p: Parser = .{ .r = &r, .a = a };
    const ok = try p.response();
    try t.expectEqualStrings("OK", ok.status);
    try t.expectEqual(3857529045, codeNumber(ok.code, "UIDVALIDITY").?);
    const f = try p.response();
    try t.expectEqual(2, f.number.?);
    try t.expectEqualStrings("FETCH", f.kind);
    const items = f.values[0].list;
    try t.expectEqualStrings("UID", items[0].atom);
    try t.expectEqual(2, items[3].list.len);
    try t.expectEqualStrings("BODY[]<0>", items[6].atom);
    try t.expectEqualStrings("Hi\r\nthere\r\n"[0..11], items[7].string);
    const s = try p.response();
    try t.expectEqualStrings("SEARCH", s.kind);
    try t.expectEqual(3, s.values.len);
    const l = try p.response();
    try t.expectEqualStrings("[Gmail]/Drafts", l.values[2].string);
    try t.expectEqualStrings("\\Drafts", l.values[0].list[1].atom);
    const e = try p.response();
    try t.expectEqual(4, e.number.?);
    try t.expectEqualStrings("EXISTS", e.kind);
    const no = try p.response();
    try t.expectEqualStrings("NO", no.status);
    try t.expectEqualStrings("AUTHENTICATIONFAILED", no.code);
    try t.expectEqualStrings("Invalid credentials (Failure)", no.text);
    const plus = try p.response();
    try t.expectEqualStrings("+", plus.tag);
    try t.expectEqualStrings("idling", plus.text);
}

test "a_header_section_with_spaces_stays_one_atom" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var r: Io.Reader = .fixed("* 1 FETCH (UID 5 BODY[HEADER.FIELDS (FROM SUBJECT)] {4}\r\nab\r\n)\r\n");
    var p: Parser = .{ .r = &r, .a = arena.allocator() };
    const f = try p.response();
    try t.expectEqualStrings("BODY[HEADER.FIELDS (FROM SUBJECT)]", f.values[0].list[2].atom);
    try t.expectEqualStrings("ab\r\n", f.values[0].list[3].string);
}

test "quoting_refuses_line_breaks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("\"a\\\"b\\\\c\"", try quote(arena.allocator(), "a\"b\\c"));
    try t.expectError(error.BadArgument, quote(arena.allocator(), "x\r\nm2 DELETE INBOX"));
}
