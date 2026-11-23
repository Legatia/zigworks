//! The MCP server against mailmcp-sim: the tools, the refusals, the
//! resource and its pushes.
const std = @import("std");
const t = std.testing;
const config = @import("config.zig");
const server = @import("server.zig");
const sim_mod = @import("sim.zig");
const jv = @import("jv.zig");

const Fixture = struct {
    sim: *sim_mod.Sim,
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    secrets: [2]?[]const u8 = .{ "butler-pass", "me-pass" },
    s: server.Server = undefined,
    out: std.ArrayList(u8) = .empty,
    n: u32 = 0,

    fn init(f: *Fixture, extra: []const u8) !void {
        f.sim = try sim_mod.Sim.start(std.heap.page_allocator, t.io, .{ 0, 0, 0 });
        f.arena = .init(t.allocator);
        f.out = .empty;
        f.n = 0;
        f.secrets = .{ "butler-pass", "me-pass" };
        const a = f.arena.allocator();
        const p = f.sim.ports();
        var d: config.Diag = .{};
        f.cfg = try config.parse(a, try std.fmt.allocPrint(a,
            \\utc_offset = +00:00
            \\[butler]
            \\address = butler@sim.test
            \\from_name = Butler
            \\imap = localhost:{d}
            \\smtp = localhost:{d}
            \\smtp_tls = implicit
            \\login = butler@sim.test
            \\secret = MAIL_BUTLER
            \\role = own
            \\[mine]
            \\address = me@sim.test
            \\imap = localhost:{d}
            \\login = me@sim.test
            \\secret = MAIL_MINE
            \\role = mine
            \\{s}
        , .{ p[0], p[1], p[0], extra }), &d);
        f.s = try server.Server.init(t.allocator, t.io, &f.cfg, &f.secrets);
        f.s.test_pem = f.sim.ca_pem;
        f.s.captured = &f.out;
        f.s.idle_ms = 10_000;
    }

    fn deinit(f: *Fixture) void {
        f.s.deinit();
        f.out.deinit(t.allocator);
        f.sim.stop();
        f.arena.deinit();
    }

    /// Calls `tool` with `args` (JSON); the result's text and whether it
    /// is an error.
    fn call(f: *Fixture, tool: []const u8, args: []const u8) !struct { text: []const u8, err: bool } {
        const a = f.arena.allocator();
        f.n += 1;
        const before = f.out.items.len;
        try f.s.handleLine(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ f.n, tool, args }));
        const line = std.mem.trim(u8, f.out.items[before..], "\n");
        const v = jv.parse(a, line) orelse return error.NotJson;
        return .{ .text = jv.str(jv.at(v, &.{ "result", "content", "0", "text" })) orelse "", .err = jv.boolean(jv.at(v, &.{ "result", "isError" })) orelse true };
    }

    fn rpc(f: *Fixture, method: []const u8, params: []const u8) !jv.Value {
        const a = f.arena.allocator();
        f.n += 1;
        f.s.out_lock.lockUncancelable(t.io);
        const before = f.out.items.len;
        f.s.out_lock.unlock(t.io);
        try f.s.handleLine(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ f.n, method, params }));
        f.s.out_lock.lockUncancelable(t.io);
        defer f.s.out_lock.unlock(t.io);
        var it = std.mem.splitScalar(u8, f.out.items[before..], '\n');
        const want = try std.fmt.allocPrint(a, "\"id\":{d},", .{f.n});
        while (it.next()) |l| if (std.mem.indexOf(u8, l, want) != null) return jv.parse(a, try a.dupe(u8, l)) orelse error.NotJson;
        return error.NoAnswer;
    }
};

test "mail_list_and_read_across_mime_shapes_and_polish_charsets" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const list = try f.call("mail_list", "{\"mailbox\":\"mine\"}");
    try t.expect(!list.err);
    const v = jv.parse(a, list.text).?;
    const items = jv.arr(v).?;
    try t.expectEqual(7, items.len);
    // the bill: ISO-8859-2 subject and body, its amount and due date
    try t.expectEqualStrings("Faktura VAT nr FV/11/2026 - do zapłaty", jv.str(jv.get(items[0], "subject")).?);
    try t.expectEqualStrings("Energa Obrót <faktury@energa.example>", jv.str(jv.get(items[0], "from")).?);
    try t.expectEqualStrings("bill", jv.str(jv.get(items[0], "kind")).?);
    try t.expectEqualStrings("249.99 PLN", jv.str(jv.get(items[0], "amount")).?);
    try t.expect(jv.str(jv.get(items[0], "due")).?.len == 10);
    // the parcel: a Windows-1250 subject; a delivery today
    try t.expectEqualStrings("Twoja paczka jest w drodze – doręczymy dziś", jv.str(jv.get(items[1], "subject")).?);
    try t.expectEqualStrings("delivery", jv.str(jv.get(items[1], "kind")).?);
    try t.expectEqualStrings("travel", jv.str(jv.get(items[2], "kind")).?);
    try t.expectEqualStrings("Potwierdzenie rezerwacji lotu LO 3921 Kraków – Warszawa", jv.str(jv.get(items[2], "subject")).?);
    try t.expectEqualStrings("invitation", jv.str(jv.get(items[3], "kind")).?);
    try t.expectEqual(1, jv.int(jv.get(items[5], "attachments")).?);
    try t.expect(!(jv.boolean(jv.get(items[6], "unread")).?));
    try t.expect(jv.boolean(jv.get(items[0], "unread")).?);
    const uid0 = jv.int(jv.get(items[0], "uid")).?;
    // reading: the data note first, Polish letters right
    const bill = try f.call("mail_read", try std.fmt.allocPrint(a, "{{\"mailbox\":\"mine\",\"uid\":{d}}}", .{uid0}));
    try t.expect(!bill.err);
    try t.expect(std.mem.startsWith(u8, bill.text, server.data_note));
    try t.expect(std.mem.indexOf(u8, bill.text, "Kwota do zapłaty: 249,99 zł") != null);
    try t.expect(std.mem.indexOf(u8, bill.text, "energię elektryczną") != null);
    try t.expect(std.mem.indexOf(u8, bill.text, "Looks like: bill, 249.99 PLN, due ") != null);
    const parcel = try f.call("mail_read", try std.fmt.allocPrint(a, "{{\"mailbox\":\"mine\",\"uid\":{d}}}", .{jv.int(jv.get(items[1], "uid")).?}));
    try t.expect(std.mem.indexOf(u8, parcel.text, "zostanie doręczona dziś do Paczkomatu KRA01M") != null);
    try t.expect(std.mem.indexOf(u8, parcel.text, "color:red") == null);
    const contract = try f.call("mail_read", try std.fmt.allocPrint(a, "{{\"mailbox\":\"mine\",\"uid\":{d}}}", .{jv.int(jv.get(items[5], "uid")).?}));
    try t.expect(std.mem.indexOf(u8, contract.text, "Attachments (not read): umowa łódź.pdf (application/pdf") != null);
    try t.expect(std.mem.indexOf(u8, contract.text, "PDF-1.4") == null);
    const invite = try f.call("mail_read", try std.fmt.allocPrint(a, "{{\"mailbox\":\"mine\",\"uid\":{d},\"format\":\"json\"}}", .{jv.int(jv.get(items[3], "uid")).?}));
    const iv = jv.parse(a, invite.text).?;
    try t.expectEqualStrings("Dinner at Ania's", jv.str(jv.at(iv, &.{ "invite", "summary" })).?);
    try t.expectEqualStrings(server.data_note, jv.str(jv.get(iv, "note")).?);
    // filters: the bill due in three days, the parcel today
    const due = jv.arr(jv.parse(a, (try f.call("mail_list", "{\"mailbox\":\"mine\",\"due_in_days\":3}")).text).?).?;
    try t.expectEqual(1, due.len);
    try t.expectEqual(uid0, jv.int(jv.get(due[0], "uid")).?);
    try t.expectEqual(0, jv.arr(jv.parse(a, (try f.call("mail_list", "{\"mailbox\":\"mine\",\"due_in_days\":2}")).text).?).?.len);
    const today = jv.arr(jv.parse(a, (try f.call("mail_list", "{\"mailbox\":\"mine\",\"day\":\"today\"}")).text).?).?;
    try t.expectEqual(1, today.len);
    try t.expectEqualStrings("delivery", jv.str(jv.get(today[0], "kind")).?);
    try t.expectEqual(6, jv.arr(jv.parse(a, (try f.call("mail_list", "{\"mailbox\":\"mine\",\"unread\":true}")).text).?).?.len);
}

test "role_mine_reads_without_marking_anything_seen" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const before = try f.sim.flagsText(a);
    const items = jv.arr(jv.parse(a, (try f.call("mail_list", "{\"mailbox\":\"mine\"}")).text).?).?;
    for (items) |it| _ = try f.call("mail_read", try std.fmt.allocPrint(a, "{{\"mailbox\":\"mine\",\"uid\":{d}}}", .{jv.int(jv.get(it, "uid")).?}));
    _ = try f.rpc("resources/read", "{\"uri\":\"mail://mine/new\"}");
    try t.expectEqualStrings(before, try f.sim.flagsText(a));
    for ([_][]const u8{ "SELECT", "UID STORE", "STORE", "COPY", "UID COPY", "MOVE", "UID MOVE", "EXPUNGE", "DELETE" }) |w| try t.expect(!f.sim.saw(w));
}

test "mail_send_refuses_a_mine_mailbox" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const r = try f.call("mail_send", "{\"mailbox\":\"mine\",\"to\":\"tomek@else.test\",\"subject\":\"x\",\"text\":\"y\"}");
    try t.expect(r.err);
    try t.expect(std.mem.indexOf(u8, r.text, "never sends from it") != null);
    try t.expectEqual(0, f.sim.sentCount());
    // the tool list offers mail_send for the butler's mailbox alone
    const tl = try f.rpc("tools/list", "{}");
    const tools = jv.arr(jv.at(tl, &.{ "result", "tools" })).?;
    try t.expectEqual(4, tools.len);
    const enums = jv.arr(jv.at(tools[3], &.{ "inputSchema", "properties", "mailbox", "enum" })).?;
    try t.expectEqual(1, enums.len);
    try t.expectEqualStrings("butler", jv.str(enums[0]).?);
}

test "mail_send_is_not_offered_without_an_own_mailbox" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: config.Diag = .{};
    const cfg = try config.parse(arena.allocator(), "[mine]\naddress = me@example.com\nimap = imap.example.com\nlogin = me\nsecret = MAIL_MINE\nrole = mine\n", &d);
    var secrets = [_]?[]const u8{null};
    var s = try server.Server.init(t.allocator, t.io, &cfg, &secrets);
    defer s.deinit();
    try t.expect(std.mem.indexOf(u8, s.tools_json, "mail_send") == null);
    try t.expect(std.mem.indexOf(u8, s.tools_json, "mail_draft") != null);
}

test "a_draft_is_appended_never_sent" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const r = try f.call("mail_draft", "{\"mailbox\":\"mine\",\"to\":\"Tomek <tomek@else.test>\",\"subject\":\"Re: weekend\",\"text\":\"Sobota o 10, przy rynku. Będę!\",\"in_reply_to\":\"<weekend-2@else.test>\"}");
    try t.expect(!r.err);
    try t.expect(std.mem.indexOf(u8, r.text, "Nothing was sent") != null);
    try t.expect(std.mem.indexOf(u8, try f.sim.flagsText(a), "me@sim.test [Sim]/Drafts 1 \\Seen \\Draft") != null);
    try t.expectEqual(0, f.sim.sentCount());
    // the draft as stored: from the owner's address, a reply, UTF-8
    f.sim.mutex.lockUncancelable(t.io);
    const raw = try a.dupe(u8, f.sim.account("me@sim.test").?.folder("[Sim]/Drafts").?.msgs.items[0].raw);
    f.sim.mutex.unlock(t.io);
    try t.expect(std.mem.indexOf(u8, raw, "From: me@sim.test") != null);
    try t.expect(std.mem.indexOf(u8, raw, "In-Reply-To: <weekend-2@else.test>") != null);
    try t.expect(std.mem.indexOf(u8, raw, "To: tomek@else.test") != null);
    // header injection is refused
    const bad = try f.call("mail_draft", "{\"mailbox\":\"mine\",\"to\":\"tomek@else.test\",\"subject\":\"hi\\r\\nBcc: x@evil.test\",\"text\":\"y\"}");
    try t.expect(bad.err);
}

test "mail_send_sends_from_the_butlers_address" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const r = try f.call("mail_send", "{\"mailbox\":\"butler\",\"to\":\"me@sim.test\",\"subject\":\"Re: dentist\",\"text\":\"I'll remind you at 9.\",\"in_reply_to\":\"<q-1@sim.test>\"}");
    try t.expect(!r.err);
    try t.expect(std.mem.startsWith(u8, r.text, "Sent from butler@sim.test to me@sim.test"));
    try t.expectEqual(1, f.sim.sentCount());
    try t.expectEqualStrings("butler@sim.test", f.sim.sent.items[0].from);
    try t.expect(std.mem.indexOf(u8, f.sim.sent.items[0].data, "From: Butler <butler@sim.test>") != null);
    const bad = try f.call("mail_send", "{\"mailbox\":\"butler\",\"to\":\"not an address\",\"subject\":\"x\",\"text\":\"y\"}");
    try t.expect(bad.err);
}

test "a_missing_secret_is_said_plainly" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    f.secrets[1] = null;
    const r = try f.call("mail_list", "{\"mailbox\":\"mine\"}");
    try t.expect(r.err);
    try t.expectEqualStrings("MAIL_MINE is not set (the secret of [mine])", r.text);
}

fn waitFor(f: *Fixture, needle: []const u8, times: usize, ms: u32) !void {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 50) {
        if (f.s.wroteCount(needle) >= times) return;
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    std.debug.print("waited {d} ms for {d} x {s}\n", .{ ms, times, needle });
    return error.TestExpectedEqual;
}

const pushed_butler = "\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"mail://butler/new\"}";

test "idle_pushes_new_mail_to_a_subscriber" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.rpc("resources/subscribe", "{\"uri\":\"mail://butler/new\"}");
    f.s.listen();
    // the watcher's first look: the stranger's mail, not pushed
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 50) {
        f.s.watchers[0].lock.lockUncancelable(t.io);
        const known = f.s.watchers[0].known;
        f.s.watchers[0].lock.unlock(t.io);
        if (known) break;
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    try t.expectEqual(0, f.s.wroteCount(pushed_butler));
    // the owner writes to the butler: pushed, and in the resource
    try t.expect(try f.sim.deliver("butler@sim.test", "Authentication-Results: mailmcp-sim; dkim=pass header.d=sim.test\r\nFrom: me@sim.test\r\nTo: butler@sim.test\r\nSubject: Dentist\r\nMessage-ID: <q-1@sim.test>\r\n\r\nRemind me to call the dentist at 9.\r\n"));
    try waitFor(&f, pushed_butler, 1, 10_000);
    const res = try f.rpc("resources/read", "{\"uri\":\"mail://butler/new\"}");
    const items = jv.arr(jv.parse(a, jv.str(jv.at(res, &.{ "result", "contents", "0", "text" })).?).?).?;
    try t.expectEqual(2, items.len);
    try t.expectEqualStrings("Dentist", jv.str(jv.get(items[1], "subject")).?);
    try t.expectEqualStrings("pass", jv.str(jv.get(items[1], "auth")).?);
    try t.expectEqualStrings("fail", jv.str(jv.get(items[0], "auth")).?);
    // mail to the owner's mailbox is not the butler's: nothing more pushed there
    _ = try f.sim.deliver("me@sim.test", "From: x@else.test\r\nSubject: y\r\n\r\nz\r\n");
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try t.expectEqual(1, f.s.wroteCount(pushed_butler));
}

test "without_idle_new_mail_is_looked_for" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    f.sim.idle.store(false, .release);
    // a second's polls for the test (the file takes 30 or more)
    const boxes = @constCast(f.cfg.mailboxes);
    boxes[0].poll_s = 1;
    _ = try f.rpc("resources/subscribe", "{\"uri\":\"mail://butler/new\"}");
    f.s.listen();
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 50) {
        f.s.watchers[0].lock.lockUncancelable(t.io);
        const known = f.s.watchers[0].known;
        f.s.watchers[0].lock.unlock(t.io);
        if (known) break;
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    _ = try f.sim.deliver("butler@sim.test", "From: me@sim.test\r\nSubject: polled\r\n\r\nhi\r\n");
    try waitFor(&f, pushed_butler, 1, 15_000);
    try t.expect(!f.s.watchers[0].pushed);
}
