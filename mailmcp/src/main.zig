//! mailmcp: mailboxes as a few named tools for an AI agent, over MCP on
//! stdio, through IMAP and SMTP over TLS. The butler's own mailbox reads,
//! drafts and sends; the owner's is read (nothing marked) and gets drafts.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const server = @import("server.zig");
const imap = @import("imap.zig");
const smtp = @import("smtp.zig");

const usage =
    \\usage: mailmcp MAIL.ini          serve MCP on stdin and stdout (what an agent starts)
    \\       mailmcp check MAIL.ini    read the mail file, then log in to each mailbox (and its
    \\                                 SMTP server, sending nothing) and say what is there
    \\       mailmcp version
    \\
    \\Each mailbox's password (or OAuth 2 access token, with auth = xoauth2) comes from the
    \\environment variable its `secret =` names (in harness: secret = MAIL_BUTLER:mail-butler).
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(io, usage, 2);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try Io.File.stdout().writeStreamingAll(io, "mailmcp " ++ build_options.version ++ "\n");
        return 0;
    }
    const check = std.mem.eql(u8, cmd, "check") and args.len == 3;
    if (!check and !(args.len == 2 and cmd.len > 0 and cmd[0] != '-')) return fail(io, usage, 2);
    const path = if (check) args[2] else cmd;
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "mailmcp: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    const secrets = try a.alloc(?[]const u8, cfg.mailboxes.len);
    for (cfg.mailboxes, secrets) |mb, *sv| sv.* = init.environ_map.get(mb.secret);
    if (check) return checkAll(init.gpa, a, io, &cfg, secrets);
    server.run(init.gpa, io, &cfg, secrets) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    return 0;
}

/// `mailmcp check`: each mailbox, in plain lines; 1 when one can't be reached.
fn checkAll(gpa: std.mem.Allocator, a: std.mem.Allocator, io: Io, cfg: *const config.Config, secrets: []const ?[]const u8) !u8 {
    var s = server.Server.init(gpa, io, cfg, secrets) catch |e| {
        if (e == error.LogUnopenable) return 1;
        return e;
    };
    defer s.deinit();
    var o: std.ArrayList(u8) = .empty;
    var bad = false;
    for (cfg.mailboxes, 0..) |mb, i| {
        try o.print(a, "{s} ({s}, {s}): ", .{ mb.name, mb.address, if (mb.role == .own) "the butler's own: reads, drafts, sends" else "yours: read without marking, drafts only" });
        const c = s.connect(i) catch |e| {
            try o.print(a, "{s}.\n", .{s.why(a, i, e)});
            bad = true;
            continue;
        };
        defer c.close();
        try o.appendSlice(a, "IMAP ok");
        for (mb.folders) |f| {
            const sel = c.examine(a, f) catch {
                try o.print(a, "; {s} can't be opened ({s})", .{ f, c.lastText() });
                bad = true;
                continue;
            };
            const unseen = c.search(a, "UNSEEN") catch &.{};
            try o.print(a, "; {s}: {d} mails, {d} unread", .{ f, sel.exists, unseen.len });
        }
        const drafts = if (mb.drafts.len > 0) mb.drafts else c.draftsFolder(a) catch "Drafts";
        try o.print(a, "; drafts go in {s}; new mail {s}", .{ drafts, if (c.has("IDLE")) "pushed (IDLE)" else try std.fmt.allocPrint(a, "looked at every {d} s (no IDLE)", .{mb.poll_s}) });
        if (mb.sends()) {
            var why: std.ArrayList(u8) = .empty;
            defer why.deinit(gpa);
            // loaded by connect above
            const trust = &s.trusts[i];
            smtp.check(gpa, io, .{ .host = mb.smtp_host, .port = mb.smtp_port, .implicit = mb.smtp_tls == .implicit, .login = mb.login, .secret = secrets[i].?, .xoauth2 = mb.auth == .xoauth2 }, trust, 30_000, &why) catch |e| {
                try o.print(a, "; SMTP {s}:{d}: {s}", .{ mb.smtp_host, mb.smtp_port, switch (e) {
                    error.LoginRefused => "the login was refused",
                    error.NoStartTls => "no STARTTLS offered (mail is never sent without TLS)",
                    error.CertificateRejected => "its certificate was not accepted",
                    error.Refused => why.items,
                    else => @errorName(e),
                } });
                bad = true;
                try o.appendSlice(a, ".\n");
                continue;
            };
            try o.print(a, "; SMTP ok ({s}:{d}, {s}; nothing sent)", .{ mb.smtp_host, mb.smtp_port, if (mb.smtp_tls == .implicit) "TLS" else "STARTTLS" });
        }
        try o.appendSlice(a, ".\n");
    }
    try Io.File.stdout().writeStreamingAll(io, o.items);
    return if (bad) 1 else 0;
}

fn fail(io: Io, msg: []const u8, code: u8) u8 {
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return code;
}

test {
    _ = @import("config.zig");
    _ = @import("ini.zig");
    _ = @import("jv.zig");
    _ = @import("sock.zig");
    _ = @import("tlsconn.zig");
    _ = @import("imap.zig");
    _ = @import("smtp.zig");
    _ = @import("mime.zig");
    _ = @import("classify.zig");
    _ = @import("server.zig");
    _ = @import("sim.zig");
    _ = @import("server_test.zig");
}
