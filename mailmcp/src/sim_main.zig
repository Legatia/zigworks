//! mailmcp-sim: a stand-in mail server for trying mailmcp without an
//! account. IMAP and SMTP over TLS on 127.0.0.1, with a certificate from a
//! CA it makes at start.
const std = @import("std");
const Io = std.Io;
const sim_mod = @import("sim.zig");

const usage =
    \\usage: mailmcp-sim DIR [IMAP SMTPS SUBMISSION]
    \\
    \\Serves IMAP (TLS) and SMTP (TLS, and STARTTLS on the submission port) on
    \\127.0.0.1 (free ports unless given), and writes into DIR:
    \\  ca.pem      its CA, for the mail file's `ca =`
    \\  ports       "IMAP SMTPS SUBMISSION"
    \\  mail.ini    a mail file for its two mailboxes (butler: own, mine: the owner's)
    \\  flags       every mail's flags, rewritten after each change
    \\Mail dropped into DIR/drop/ as ADDRESS.eml (or ADDRESS--anything.eml) is
    \\delivered to that account's INBOX. Accounts: butler@sim.test (password
    \\butler-pass), me@sim.test (me-pass), anna@else.test (anna-pass);
    \\XOAUTH2 tokens butler-token, me-token, anna-token.
    \\
;

var dir_path: []const u8 = "";
var flags_io: Io = undefined;

fn writeFlags(s: *sim_mod.Sim) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = s.flagsText(a) catch return;
    const path = std.fs.path.join(a, &.{ dir_path, "flags" }) catch return;
    const tmp = std.fs.path.join(a, &.{ dir_path, "flags.tmp" }) catch return;
    Io.Dir.cwd().writeFile(flags_io, .{ .sub_path = tmp, .data = text }) catch return;
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, flags_io) catch {};
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2 and args.len != 5) {
        Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    }
    var want: [3]u16 = .{ 0, 0, 0 };
    if (args.len == 5) for (0..3) |i| {
        want[i] = std.fmt.parseInt(u16, args[2 + i], 10) catch {
            Io.File.stderr().writeStreamingAll(io, usage) catch {};
            return 2;
        };
    };
    dir_path = args[1];
    flags_io = io;
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ dir_path, "drop" }));
    const s = try sim_mod.Sim.start(std.heap.page_allocator, io, want);
    s.on_change = writeFlags;
    const p = s.ports();
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir_path, "ca.pem" }), .data = s.ca_pem });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir_path, "mail.ini" }), .data = try std.fmt.allocPrint(a,
        \\; mailmcp-sim's two mailboxes (secrets: MAIL_BUTLER=butler-pass, MAIL_MINE=me-pass)
        \\utc_offset = +00:00
        \\
        \\[butler]
        \\address = butler@sim.test
        \\from_name = Butler
        \\imap = localhost:{d}
        \\smtp = localhost:{d}
        \\smtp_tls = implicit
        \\login = butler@sim.test
        \\secret = MAIL_BUTLER
        \\role = own
        \\ca = ca.pem
        \\
        \\[mine]
        \\address = me@sim.test
        \\imap = localhost:{d}
        \\login = me@sim.test
        \\secret = MAIL_MINE
        \\role = mine
        \\ca = ca.pem
        \\
    , .{ p[0], p[1], p[0] }) });
    writeFlags(s);
    // written last: whoever waits for it finds the rest in place
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir_path, "ports" }), .data = try std.fmt.allocPrint(a, "{d} {d} {d}\n", .{ p[0], p[1], p[2] }) });
    const drop = try std.fs.path.join(a, &.{ dir_path, "drop" });
    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        var d = cwd.openDir(io, drop, .{ .iterate = true }) catch continue;
        defer d.close(io);
        // the names first: nothing is removed while the folder is read
        var fa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer fa.deinit();
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".eml")) continue;
            names.append(fa.allocator(), fa.allocator().dupe(u8, e.name) catch continue) catch continue;
        }
        for (names.items) |name| {
            const raw = d.readFileAlloc(io, name, fa.allocator(), .limited(16 << 20)) catch continue;
            const stem = name[0 .. name.len - 4];
            const addr = stem[0 .. std.mem.indexOf(u8, stem, "--") orelse stem.len];
            _ = s.deliver(addr, raw) catch false;
            d.deleteFile(io, name) catch {};
        }
    }
}
