//! The mail file: which mailboxes, how to reach them, and what each may do.
//! An INI file, a section per mailbox:
//!
//!   utc_offset = +01:00          ; the owner's time, for dates ("due in 3 days")
//!   log = mail.jsonl             ; optional: one line per draft and send (relative: to this file)
//!
//!   [butler]                     ; the butler's own mailbox
//!   address = butler@example.com
//!   from_name = Butler           ; optional: the name on what it sends
//!   imap = imap.fastmail.com:993
//!   smtp = smtp.fastmail.com:465 ; 465: TLS from the start; 587: STARTTLS
//!   login = butler@example.com
//!   secret = MAIL_BUTLER         ; the environment variable that holds the password (or token)
//!   auth = password              ; or xoauth2: the variable holds an OAuth 2 access token
//!   role = own                   ; it sends, from its own address
//!
//!   [mine]                       ; the owner's: read, and drafts written; never sent from
//!   address = me@gmail.com
//!   imap = imap.gmail.com:993
//!   login = me@gmail.com
//!   secret = MAIL_MINE
//!   role = mine
//!   folders = INBOX              ; what is read (the first: what "new" watches)
//!   drafts = [Gmail]/Drafts      ; optional: else the folder the server marks \Drafts, else Drafts
//!   ca = my-ca.pem               ; optional: one more certificate authority to trust (a server with its own)
//!   poll = 120                   ; seconds between looks where the server has no IDLE
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");

pub const Role = enum {
    /// The butler's own: reads, drafts and sends from its address.
    own,
    /// The owner's: reads (nothing marked) and drafts; never sends,
    /// deletes, moves, flags or marks.
    mine,
};

pub const Auth = enum { password, xoauth2 };

pub const SmtpTls = enum { implicit, starttls };

pub const Mailbox = struct {
    name: []const u8,
    address: []const u8 = "",
    from_name: []const u8 = "",
    imap_host: []const u8 = "",
    imap_port: u16 = 993,
    smtp_host: []const u8 = "",
    smtp_port: u16 = 0,
    smtp_tls: SmtpTls = .implicit,
    login: []const u8 = "",
    secret: []const u8 = "",
    auth: Auth = .password,
    role: Role = .mine,
    folders: []const []const u8 = &.{"INBOX"},
    drafts: []const u8 = "",
    ca: []const u8 = "",
    poll_s: u32 = 120,

    pub fn sends(m: *const Mailbox) bool {
        return m.role == .own and m.smtp_host.len > 0;
    }
};

pub const Config = struct {
    mailboxes: []const Mailbox = &.{},
    /// Minutes east of UTC: the owner's day.
    utc_offset_min: i32 = 0,
    log_path: []const u8 = "",

    pub fn find(c: *const Config, name: []const u8) ?*const Mailbox {
        for (c.mailboxes) |*m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    pub fn anySends(c: *const Config) bool {
        for (c.mailboxes) |*m| if (m.sends()) return true;
        return false;
    }
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

/// Keys that would let a mailbox do more than read and write drafts:
/// refused for `role = mine` (and unknown for `own`: nothing deletes,
/// moves, flags or marks).
const more_keys = [_][]const u8{ "send", "delete", "move", "flag", "mark", "expunge", "allow", "smtp", "smtp_tls" };

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| {
        diag.* = .{ .what = try std.fmt.allocPrint(a, "can't read {s}: {s}", .{ path, @errorName(e) }) };
        return error.BadConfig;
    };
    var c = try parse(a, text, diag);
    const dir = std.fs.path.dirname(path) orelse ".";
    if (c.log_path.len > 0 and !std.fs.path.isAbsolute(c.log_path)) c.log_path = try std.fs.path.join(a, &.{ dir, c.log_path });
    const boxes = try a.dupe(Mailbox, c.mailboxes);
    for (boxes) |*m| if (m.ca.len > 0 and !std.fs.path.isAbsolute(m.ca)) {
        m.ca = try std.fs.path.join(a, &.{ dir, m.ca });
    };
    c.mailboxes = boxes;
    return c;
}

pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Config {
    var bad: usize = 0;
    const entries = ini.parse(a, text, &bad) catch return fail(diag, bad, "not a key = value line or [section]");
    var c: Config = .{};
    var boxes: std.ArrayList(Mailbox) = .empty;
    var lines: std.ArrayList(usize) = .empty;
    var current: ?usize = null;
    var section: []const u8 = "";
    for (entries) |e| {
        const k = e.key;
        const v = e.value;
        if (e.section.len == 0) {
            if (eql(k, "utc_offset")) {
                c.utc_offset_min = parseOffset(v) orelse return fail(diag, e.line, "utc_offset: like +01:00 or -05:30");
            } else if (eql(k, "log")) {
                c.log_path = v;
            } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s} (before any [mailbox])", .{k}));
            continue;
        }
        if (current == null or !eql(section, e.section)) {
            if (e.name.len > 0 or !validName(e.section)) return fail(diag, e.line, try std.fmt.allocPrint(a, "[{s}]: a mailbox's name is a-z, 0-9, - and _, up to 32", .{e.section}));
            for (boxes.items) |b| if (eql(b.name, e.section)) return fail(diag, e.line, try std.fmt.allocPrint(a, "[{s}] twice", .{e.section}));
            try boxes.append(a, .{ .name = e.section });
            try lines.append(a, e.line);
            current = boxes.items.len - 1;
            section = e.section;
        }
        const m = &boxes.items[current.?];
        if (eql(k, "address")) {
            if (!plainAddress(v)) return fail(diag, e.line, "address: one address, like me@example.com");
            m.address = v;
        } else if (eql(k, "from_name")) {
            if (std.mem.indexOfAny(u8, v, "\r\n\"<>") != null) return fail(diag, e.line, "from_name: a plain name");
            m.from_name = v;
        } else if (eql(k, "imap")) {
            const hp = hostPort(v, 993) orelse return fail(diag, e.line, "imap: HOST or HOST:PORT");
            m.imap_host = hp.host;
            m.imap_port = hp.port;
        } else if (eql(k, "smtp")) {
            const hp = hostPort(v, 465) orelse return fail(diag, e.line, "smtp: HOST or HOST:PORT");
            m.smtp_host = hp.host;
            m.smtp_port = hp.port;
        } else if (eql(k, "smtp_tls")) {
            m.smtp_tls = std.meta.stringToEnum(SmtpTls, v) orelse return fail(diag, e.line, "smtp_tls: implicit (TLS from the start) or starttls");
        } else if (eql(k, "login")) {
            m.login = v;
        } else if (eql(k, "secret")) {
            if (!envName(v)) return fail(diag, e.line, "secret: the name of an environment variable (A-Z, 0-9, _), never the password itself");
            m.secret = v;
        } else if (eql(k, "auth")) {
            m.auth = std.meta.stringToEnum(Auth, v) orelse return fail(diag, e.line, "auth: password (an app password) or xoauth2 (an OAuth 2 access token)");
        } else if (eql(k, "role")) {
            m.role = std.meta.stringToEnum(Role, v) orelse return fail(diag, e.line, "role: own (the butler's mailbox) or mine (yours: read and drafts only)");
        } else if (eql(k, "folders")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, v, ",");
            while (it.next()) |w| {
                const f = std.mem.trim(u8, w, " \t");
                if (f.len == 0) continue;
                if (!plainFolder(f)) return fail(diag, e.line, try std.fmt.allocPrint(a, "folders: {s} isn't a plain folder name", .{f}));
                try list.append(a, f);
            }
            if (list.items.len == 0) return fail(diag, e.line, "folders: at least one, like INBOX");
            m.folders = list.items;
        } else if (eql(k, "drafts")) {
            if (!plainFolder(v)) return fail(diag, e.line, "drafts: a plain folder name");
            m.drafts = v;
        } else if (eql(k, "ca")) {
            m.ca = v;
        } else if (eql(k, "poll")) {
            const s = std.fmt.parseInt(u32, v, 10) catch return fail(diag, e.line, "poll: seconds, 30 or more");
            if (s < 30) return fail(diag, e.line, "poll: seconds, 30 or more");
            m.poll_s = s;
        } else if (isMore(k)) {
            // judged once the section's role is known
        } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s}", .{k}));
    }
    // what a section asks for, now that its role is known
    for (entries) |e| {
        if (e.section.len == 0 or !isMore(e.key)) continue;
        const m = for (boxes.items) |*b| {
            if (eql(b.name, e.section)) break b;
        } else unreachable;
        if (m.role == .mine) return fail(diag, e.line, try std.fmt.allocPrint(a, "[{s}] is role = mine: it is read and gets drafts, nothing more ({s} is refused: mail is never sent as you, deleted, moved, flagged or marked)", .{ m.name, e.key }));
        if (!eql(e.key, "smtp") and !eql(e.key, "smtp_tls")) return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s}: mailmcp never deletes, moves, flags or marks mail", .{e.key}));
    }
    for (boxes.items, lines.items) |*m, line| {
        if (m.address.len == 0) return fail(diag, line, try std.fmt.allocPrint(a, "[{s}] has no address", .{m.name}));
        if (m.imap_host.len == 0) return fail(diag, line, try std.fmt.allocPrint(a, "[{s}] has no imap", .{m.name}));
        if (m.login.len == 0) return fail(diag, line, try std.fmt.allocPrint(a, "[{s}] has no login", .{m.name}));
        if (m.secret.len == 0) return fail(diag, line, try std.fmt.allocPrint(a, "[{s}] has no secret (the environment variable with its password)", .{m.name}));
        if (m.role == .own) {
            if (m.smtp_host.len == 0) return fail(diag, line, try std.fmt.allocPrint(a, "[{s}] is role = own and has no smtp", .{m.name}));
            const said_tls = for (entries) |e| {
                if (eql(e.section, m.name) and eql(e.key, "smtp_tls")) break true;
            } else false;
            if (!said_tls) m.smtp_tls = switch (m.smtp_port) {
                465 => .implicit,
                587 => .starttls,
                else => return fail(diag, line, try std.fmt.allocPrint(a, "[{s}] smtp port {d}: say smtp_tls = implicit or starttls", .{ m.name, m.smtp_port })),
            };
        }
    }
    if (boxes.items.len == 0) return fail(diag, 0, "no mailbox: add a [NAME] section");
    c.mailboxes = boxes.items;
    return c;
}

fn isMore(k: []const u8) bool {
    for (more_keys) |x| if (eql(x, k)) return true;
    return false;
}

pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    for (s) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn envName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |ch| if (!(std.ascii.isUpper(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// One address, no name, no spaces or angle brackets.
pub fn plainAddress(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    for (s) |ch| if (ch <= ' ' or ch >= 0x7f or std.mem.indexOfScalar(u8, "<>,;\"()[]\\", ch) != null) return false;
    return true;
}

/// A folder name IMAP takes quoted: printable ASCII, no quotes or
/// backslashes, no wildcards.
pub fn plainFolder(s: []const u8) bool {
    if (s.len == 0 or s.len > 200) return false;
    for (s) |ch| if (ch < ' ' or ch >= 0x7f or ch == '"' or ch == '\\' or ch == '*' or ch == '%') return false;
    return true;
}

const HostPort = struct { host: []const u8, port: u16 };

fn hostPort(v: []const u8, default: u16) ?HostPort {
    if (v.len == 0) return null;
    var host = v;
    var port = default;
    if (std.mem.lastIndexOfScalar(u8, v, ':')) |i| {
        host = v[0..i];
        port = std.fmt.parseInt(u16, v[i + 1 ..], 10) catch return null;
        if (port == 0) return null;
    }
    if (host.len == 0) return null;
    for (host) |ch| if (ch <= ' ' or ch >= 0x7f or ch == '/' or ch == '@') return null;
    return .{ .host = host, .port = port };
}

/// "+01:00" → 60.
pub fn parseOffset(v: []const u8) ?i32 {
    if (v.len != 6 or (v[0] != '+' and v[0] != '-') or v[3] != ':') return null;
    const h = std.fmt.parseInt(i32, v[1..3], 10) catch return null;
    const m = std.fmt.parseInt(i32, v[4..6], 10) catch return null;
    if (h > 14 or m > 59) return null;
    const total = h * 60 + m;
    return if (v[0] == '-') -total else total;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn fail(diag: *Diag, line: usize, what: []const u8) error{BadConfig} {
    diag.* = .{ .line = line, .what = what };
    return error.BadConfig;
}

const t = std.testing;

const both =
    \\utc_offset = +01:00
    \\[butler]
    \\address = butler@example.com
    \\imap = imap.example.com:993
    \\smtp = smtp.example.com:587
    \\login = butler@example.com
    \\secret = MAIL_BUTLER
    \\role = own
    \\
    \\[mine]
    \\address = me@example.com
    \\imap = imap.example.com
    \\login = me@example.com
    \\secret = MAIL_MINE
    \\role = mine
    \\folders = INBOX, Bills
    \\
;

test "a_mail_file_with_both_roles" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    const c = try parse(arena.allocator(), both, &d);
    try t.expectEqual(60, c.utc_offset_min);
    try t.expectEqual(2, c.mailboxes.len);
    const b = c.find("butler").?;
    try t.expectEqual(Role.own, b.role);
    try t.expectEqual(SmtpTls.starttls, b.smtp_tls);
    try t.expectEqual(587, b.smtp_port);
    try t.expect(b.sends());
    const m = c.find("mine").?;
    try t.expectEqual(993, m.imap_port);
    try t.expect(!m.sends());
    try t.expectEqual(2, m.folders.len);
    try t.expectEqualStrings("Bills", m.folders[1]);
    // the same with \r\n line ends
    const crlf = try std.mem.replaceOwned(u8, arena.allocator(), both, "\n", "\r\n");
    const c2 = try parse(arena.allocator(), crlf, &d);
    try t.expectEqualStrings("Bills", c2.find("mine").?.folders[1]);
    try t.expectEqualStrings("MAIL_MINE", c2.find("mine").?.secret);
}

test "role_mine_refuses_send_and_more_in_the_file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const base = "[mine]\naddress = me@example.com\nimap = imap.example.com\nlogin = me\nsecret = MAIL_MINE\nrole = mine\n";
    for ([_][]const u8{ "smtp = smtp.example.com:465", "send = yes", "delete = yes", "move = Archive", "flag = yes", "mark = read", "expunge = yes", "allow = delete" }) |line| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "{s}{s}\n", .{ base, line }), &d));
        try t.expect(std.mem.indexOf(u8, d.what, "role = mine") != null);
        try t.expectEqual(7, d.line);
    }
    // the line before role = mine is refused too
    try t.expectError(error.BadConfig, parse(a, "[mine]\nsmtp = smtp.example.com\naddress = me@example.com\nimap = i\nlogin = me\nsecret = S\nrole = mine\n", &d));
    try t.expectEqual(2, d.line);
    // own: nothing deletes, moves, flags or marks either
    try t.expectError(error.BadConfig, parse(a, "[b]\naddress = b@example.com\nimap = i\nsmtp = s:465\nlogin = b\nsecret = S\nrole = own\ndelete = yes\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "never deletes") != null);
}

test "mail_file_mistakes_are_named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    try t.expectError(error.BadConfig, parse(a, "[b]\naddress = b@example.com\nimap = i\nlogin = b\nsecret = S\nrole = own\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "no smtp") != null);
    try t.expectError(error.BadConfig, parse(a, "[b]\naddress = b@example.com\nimap = i\nsmtp = s:2525\nlogin = b\nsecret = S\nrole = own\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "smtp_tls") != null);
    try t.expectError(error.BadConfig, parse(a, "[b]\naddress = b@example.com\nimap = i\nlogin = b\nsecret = hunter2\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "never the password") != null);
    try t.expectError(error.BadConfig, parse(a, "[My Box]\naddress = b@example.com\n", &d));
    try t.expectError(error.BadConfig, parse(a, "[b]\naddress = Me <b@example.com>\n", &d));
    try t.expectError(error.BadConfig, parse(a, "[b]\naddress = b@example.com\nimap = i\nlogin = b\nsecret = S\npoll = 5\n", &d));
    try t.expectError(error.BadConfig, parse(a, "; nothing\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "no mailbox") != null);
    const ok = try parse(a, "[b]\naddress = b@example.com\nimap = i\nsmtp = s:2525\nsmtp_tls = starttls\nlogin = b\nsecret = S\nrole = own\n", &d);
    try t.expectEqual(SmtpTls.starttls, ok.mailboxes[0].smtp_tls);
}
