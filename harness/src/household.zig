//! Household members: people the owner lets use harness, in a group the
//! owner registered or in their own chat with the bot, within the rules'
//! `[member]` sections. The owner adds one with `/member add NAME` and
//! gives them the one-time code harness answers with; `/join CODE` from
//! their Telegram account makes it theirs. Kept in `state/members`, one
//! JSON object a line, written whole (a temporary file, then a rename)
//! before harness acts on a change; a code only as its SHA-256.
//!
//! A member's call that needs the owner waits in `state/member-asks` the
//! same way until the owner answers its item. Here too: a call in plain
//! words, and what members are told.
const std = @import("std");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const max_name = 32;
pub const max_members = 32;
/// How long a code joins, once.
pub const code_seconds: i64 = 600;
/// A code's length; its letters as `harness pair`'s.
pub const code_len = 8;
const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
/// Calls of one member waiting for the owner at once.
pub const max_asks = 5;

/// The words `/member` takes: never a member's name.
const command_words = [_][]const u8{ "add", "rm" };

/// a-z, 0-9, `-` and `_`, up to 32, and not `add` or `rm`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    for (command_words) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

/// "anna" as members and the owner read it: "Anna".
pub fn display(buf: *[max_name]u8, name: []const u8) []const u8 {
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

/// A new code: `code_len` letters from the system's secure random source.
pub fn newCode(io: Io, out: *[code_len]u8) ![]const u8 {
    var raw: [code_len]u8 = undefined;
    try io.randomSecure(&raw);
    for (out, raw) |*ch, r| ch.* = alphabet[r % alphabet.len];
    return out;
}

/// The SHA-256 of a code as typed (any case, spaces around it), in hex;
/// null when it can't be a code.
fn codeHash(code_in: []const u8) ?[64]u8 {
    const code = std.mem.trim(u8, code_in, " \t\r\n");
    if (code.len != code_len) return null;
    var up: [code_len]u8 = undefined;
    for (code, &up) |ch, *u| u.* = std.ascii.toUpper(ch);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&up, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub const Member = struct {
    name: []u8,
    /// Their Telegram account; 0: not joined yet.
    user: i64 = 0,
    added: i64,
    joined: i64 = 0,
    /// The waiting code's SHA-256 (hex), and until when it joins.
    code: ?[64]u8 = null,
    expires: i64 = 0,
};

/// What came of a `/join`.
pub const Joined = union(enum) {
    /// The account is this member's now (the name, in the caller's arena).
    joined: []const u8,
    /// The account is a member already, by this name.
    already: []const u8,
    /// No waiting code is this one.
    wrong,
};

pub const Members = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    /// Held while the list is read or changed.
    mutex: Io.Mutex = .init,
    items: std.ArrayList(*Member) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, path: []const u8) Members {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(l: *Members) void {
        for (l.items.items) |m| l.free(m);
        l.items.deinit(l.gpa);
    }

    fn free(l: *Members, m: *Member) void {
        l.gpa.free(m.name);
        l.gpa.destroy(m);
    }

    /// Reads the file; a line that does not read, or names a member or an
    /// account twice, is left out.
    pub fn load(l: *Members) !void {
        const text = Io.Dir.cwd().readFileAlloc(l.io, l.path, l.gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer l.gpa.free(text);
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const v = jv.parse(arena.allocator(), line) orelse continue;
            const name = jv.str(jv.get(v, "name")) orelse continue;
            if (!validName(name) or l.find(name) != null or l.items.items.len >= max_members) continue;
            const user = jv.int(jv.get(v, "user")) orelse 0;
            if (user != 0 and l.byUser(user) != null) continue;
            var code: ?[64]u8 = null;
            if (jv.str(jv.get(v, "code"))) |h| if (h.len == 64) {
                code = h[0..64].*;
            };
            try l.append(.{
                .name = @constCast(name),
                .user = user,
                .added = util.parseIso(jv.str(jv.get(v, "added")) orelse "") orelse 0,
                .joined = util.parseIso(jv.str(jv.get(v, "joined")) orelse "") orelse 0,
                .code = code,
                .expires = jv.int(jv.get(v, "expires")) orelse 0,
            });
        }
    }

    fn append(l: *Members, m: Member) !void {
        const e = try l.gpa.create(Member);
        errdefer l.gpa.destroy(e);
        e.* = m;
        e.name = try l.gpa.dupe(u8, m.name);
        errdefer l.gpa.free(e.name);
        try l.items.append(l.gpa, e);
    }

    /// Writes the whole list to a new file that replaces the old one.
    pub fn save(l: *Members) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(l.gpa);
        for (l.items.items) |m| {
            var tb: [20]u8 = undefined;
            try out.appendSlice(l.gpa, "{\"name\":");
            try util.jsonString(&out, l.gpa, m.name);
            try out.print(l.gpa, ",\"user\":{d},\"added\":\"{s}\"", .{ m.user, util.isoTime(&tb, m.added) });
            if (m.joined != 0) try out.print(l.gpa, ",\"joined\":\"{s}\"", .{util.isoTime(&tb, m.joined)});
            if (m.code) |h| try out.print(l.gpa, ",\"code\":\"{s}\",\"expires\":{d}", .{ &h, m.expires });
            try out.appendSlice(l.gpa, "}\n");
        }
        try util.writeReplace(l.io, l.path, out.items);
    }

    pub fn find(l: *const Members, name: []const u8) ?*Member {
        for (l.items.items) |m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    /// The member whose Telegram account `user` is.
    pub fn byUser(l: *const Members, user: i64) ?*Member {
        if (user == 0) return null;
        for (l.items.items) |m| if (m.user == user) return m;
        return null;
    }

    /// A new member called `name` with `code` waiting, or a new code for
    /// one (it replaces a waiting one; their account stays theirs until
    /// the code is used); written before it is said. error.Full past
    /// `max_members`.
    pub fn offer(l: *Members, name: []const u8, code: []const u8, now_s: i64) !void {
        const h = codeHash(code) orelse return error.BadCode;
        if (l.find(name)) |m| {
            const before = .{ m.code, m.expires };
            m.code = h;
            m.expires = now_s + code_seconds;
            l.save() catch |e| {
                m.code = before[0];
                m.expires = before[1];
                return e;
            };
            return;
        }
        if (l.items.items.len >= max_members) return error.Full;
        try l.append(.{ .name = @constCast(name), .added = now_s, .code = h, .expires = now_s + code_seconds });
        l.save() catch |e| {
            l.free(l.items.pop().?);
            return e;
        };
    }

    /// `/join CODE` from account `user`: the member whose code it is,
    /// waiting and not expired, gets the account; the code is used up.
    /// Written before it is said.
    pub fn join(l: *Members, a: std.mem.Allocator, code: []const u8, user: i64, now_s: i64) !Joined {
        if (l.byUser(user)) |m| return .{ .already = try a.dupe(u8, m.name) };
        const h = codeHash(code) orelse return .wrong;
        for (l.items.items) |m| {
            const want = m.code orelse continue;
            if (now_s > m.expires or !std.mem.eql(u8, &want, &h)) continue;
            const before = m.*;
            m.user = user;
            m.joined = now_s;
            m.code = null;
            m.expires = 0;
            l.save() catch |e| {
                m.* = before;
                return e;
            };
            return .{ .joined = try a.dupe(u8, m.name) };
        }
        return .wrong;
    }

    /// Removes member `name`; false when there is none. Written first.
    pub fn remove(l: *Members, name: []const u8) !bool {
        for (l.items.items, 0..) |m, i| if (std.mem.eql(u8, m.name, name)) {
            _ = l.items.orderedRemove(i);
            l.save() catch |e| {
                l.items.insert(l.gpa, i, m) catch l.free(m);
                return e;
            };
            l.free(m);
            return true;
        };
        return false;
    }
};

/// A member's call waiting for the owner's answer to its item.
pub const Ask = struct {
    item: u64,
    member: []const u8,
    /// The definition whose run asked.
    agent: []const u8,
    /// Where the member asked.
    conversation: []const u8,
    /// The gate's kind (`mcp` or `money`) and argument ("SERVER/TOOL INPUT").
    tool: []const u8,
    arg: []const u8,
    /// The call in plain words ("unlock the front door").
    what: []const u8,
};

/// The calls waiting for the owner, `state/member-asks`. Each call's texts
/// are its own allocations, freed when it is taken.
pub const Asks = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Ask) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, path: []const u8) Asks {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(s: *Asks) void {
        for (s.items.items) |k| freeAsk(s.gpa, k);
        s.items.deinit(s.gpa);
    }

    pub fn load(s: *Asks) !void {
        const text = Io.Dir.cwd().readFileAlloc(s.io, s.path, s.gpa, .limited(4 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer s.gpa.free(text);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const v = jv.parse(a, line) orelse continue;
            const item = jv.int(jv.get(v, "item")) orelse continue;
            if (item <= 0) continue;
            const k = try copyAsk(s.gpa, .{
                .item = @intCast(item),
                .member = jv.str(jv.get(v, "member")) orelse continue,
                .agent = jv.str(jv.get(v, "agent")) orelse "main",
                .conversation = jv.str(jv.get(v, "conversation")) orelse continue,
                .tool = jv.str(jv.get(v, "tool")) orelse continue,
                .arg = jv.str(jv.get(v, "arg")) orelse continue,
                .what = jv.str(jv.get(v, "what")) orelse "",
            });
            s.items.append(s.gpa, k) catch |e| {
                freeAsk(s.gpa, k);
                return e;
            };
        }
    }

    /// Writes the whole list to a new file that replaces the old one.
    fn save(s: *Asks) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        for (s.items.items) |k| {
            try out.print(s.gpa, "{{\"item\":{d},\"member\":", .{k.item});
            try util.jsonString(&out, s.gpa, k.member);
            try out.appendSlice(s.gpa, ",\"agent\":");
            try util.jsonString(&out, s.gpa, k.agent);
            try out.appendSlice(s.gpa, ",\"conversation\":");
            try util.jsonString(&out, s.gpa, k.conversation);
            try out.appendSlice(s.gpa, ",\"tool\":");
            try util.jsonString(&out, s.gpa, k.tool);
            try out.appendSlice(s.gpa, ",\"arg\":");
            try util.jsonString(&out, s.gpa, k.arg);
            try out.appendSlice(s.gpa, ",\"what\":");
            try util.jsonString(&out, s.gpa, k.what);
            try out.appendSlice(s.gpa, "}\n");
        }
        try util.writeReplace(s.io, s.path, out.items);
    }

    /// Keeps a call (its texts copied); written before its item is shown.
    pub fn add(s: *Asks, k: Ask) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const owned = try copyAsk(s.gpa, k);
        s.items.append(s.gpa, owned) catch |e| {
            freeAsk(s.gpa, owned);
            return e;
        };
        s.save() catch |e| {
            freeAsk(s.gpa, s.items.pop().?);
            return e;
        };
    }

    /// The call item `item` waits on, taken off the list (copied into
    /// `a`); written before it is acted on, so a crash never makes it twice.
    pub fn take(s: *Asks, a: std.mem.Allocator, item: u64) ?Ask {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.items.items, 0..) |k, i| if (k.item == item) {
            const copy = copyAsk(a, k) catch return null;
            _ = s.items.orderedRemove(i);
            freeAsk(s.gpa, k);
            s.save() catch {};
            return copy;
        };
        return null;
    }

    /// The item of `member`'s call with argument `arg` that waits already.
    pub fn waiting(s: *Asks, member: []const u8, arg: []const u8) ?u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.items.items) |k| if (std.mem.eql(u8, k.member, member) and std.mem.eql(u8, k.arg, arg)) return k.item;
        return null;
    }

    /// How many of `member`'s calls wait.
    pub fn countOf(s: *Asks, member: []const u8) usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var n: usize = 0;
        for (s.items.items) |k| if (std.mem.eql(u8, k.member, member)) {
            n += 1;
        };
        return n;
    }

    /// The items `member`'s calls wait on, or every call's for "" (in `a`).
    pub fn itemsOf(s: *Asks, a: std.mem.Allocator, member: []const u8) ![]const u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.ArrayList(u64) = .empty;
        for (s.items.items) |k| if (member.len == 0 or std.mem.eql(u8, k.member, member)) try out.append(a, k.item);
        return out.items;
    }
};

/// `k` with its texts copied into `a`.
pub fn copyAsk(a: std.mem.Allocator, k: Ask) !Ask {
    var out: Ask = .{ .item = k.item, .member = "", .agent = "", .conversation = "", .tool = "", .arg = "", .what = "" };
    errdefer freeAsk(a, out);
    out.member = try a.dupe(u8, k.member);
    out.agent = try a.dupe(u8, k.agent);
    out.conversation = try a.dupe(u8, k.conversation);
    out.tool = try a.dupe(u8, k.tool);
    out.arg = try a.dupe(u8, k.arg);
    out.what = try a.dupe(u8, k.what);
    return out;
}

fn freeAsk(a: std.mem.Allocator, k: Ask) void {
    for ([_][]const u8{ k.member, k.agent, k.conversation, k.tool, k.arg, k.what }) |x| a.free(x);
}

// ---- a call in plain words ----

/// The parts of an MCP call's gate argument, "SERVER/TOOL INPUT".
pub const Call = struct { server: []const u8, tool: []const u8, input: []const u8 };

pub fn splitCall(arg: []const u8) ?Call {
    const sp = std.mem.indexOfScalar(u8, arg, ' ') orelse arg.len;
    const head = arg[0..sp];
    const slash = std.mem.indexOfScalar(u8, head, '/') orelse return null;
    return .{ .server = head[0..slash], .tool = head[slash + 1 ..], .input = if (sp < arg.len) arg[sp + 1 ..] else "" };
}

/// A homemcp call harness can say exactly: its device, action and value,
/// each a plain word.
const HomeCall = struct { device: []const u8, action: []const u8, value: ?[]const u8 };

fn homeCall(a: std.mem.Allocator, arg: []const u8) ?HomeCall {
    const c = splitCall(arg) orelse return null;
    if (!std.mem.startsWith(u8, c.tool, "home_")) return null;
    const v = jv.parse(a, c.input) orelse return null;
    if (v != .object) return null;
    const device = jv.str(jv.get(v, "device")) orelse return null;
    const action = jv.str(jv.get(v, "action")) orelse return null;
    // anything else in it: said as given
    var it = v.object.iterator();
    while (it.next()) |e| if (!oneOf(e.key_ptr.*, &.{ "device", "action", "value" })) return null;
    const value: ?[]const u8 = if (jv.get(v, "value")) |x| switch (x) {
        .string => |s| s,
        .integer, .float, .number_string => std.json.Stringify.valueAlloc(a, x, .{}) catch return null,
        else => return null,
    } else null;
    if (!plainWord(device, "_.-") or !plainWord(action, "_")) return null;
    if (value) |x| if (!plainWord(x, "_.-,% ")) return null;
    return .{ .device = device, .action = action, .value = value };
}

/// 1 to 64 letters and digits, and `extra`.
fn plainWord(s: []const u8, extra: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, extra, ch) == null) return false;
    return true;
}

fn oneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// "front_door" as said: "front door".
fn spoken(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    const out = try a.dupe(u8, id);
    for (out) |*ch| if (ch.* == '_') {
        ch.* = ' ';
    };
    return out;
}

const verbs = [_][]const u8{ "lock", "unlock", "open", "close", "stop", "disarm" };

/// A member's call as the owner's question and the member's lines say
/// it: "unlock the front door", "turn on the hall light", "set the
/// thermostat temperature to 21"; a call harness can't say exactly is
/// given whole ("use cloud/car_command with {...}").
pub fn plainCall(a: std.mem.Allocator, arg: []const u8) ![]const u8 {
    const h = homeCall(a, arg) orelse {
        const c = splitCall(arg) orelse return a.dupe(u8, arg);
        const empty = std.mem.eql(u8, std.mem.trim(u8, c.input, " "), "{}") or c.input.len == 0;
        if (empty) return std.fmt.allocPrint(a, "use {s}/{s}", .{ c.server, c.tool });
        return std.fmt.allocPrint(a, "use {s}/{s} with {s}", .{ c.server, c.tool, c.input });
    };
    const device = try spoken(a, h.device);
    const eql = std.mem.eql;
    if (eql(u8, h.action, "on") or eql(u8, h.action, "off")) return std.fmt.allocPrint(a, "turn {s} the {s}", .{ h.action, device });
    if (oneOf(h.action, &verbs)) return std.fmt.allocPrint(a, "{s} the {s}", .{ h.action, device });
    if (eql(u8, h.action, "arm_home")) return std.fmt.allocPrint(a, "arm the {s} (home)", .{device});
    if (eql(u8, h.action, "arm_away")) return std.fmt.allocPrint(a, "arm the {s} (away)", .{device});
    const action = try spoken(a, h.action);
    if (h.value) |x| return std.fmt.allocPrint(a, "set the {s} {s} to {s}", .{ device, action, x });
    return std.fmt.allocPrint(a, "{s} the {s}", .{ action, device });
}

/// The owner's Yes button for a member's call: its verb ("Unlock",
/// "Turn on", "Set"), or "Allow".
pub fn yesLabel(a: std.mem.Allocator, arg: []const u8) ![]const u8 {
    const h = homeCall(a, arg) orelse return "Allow";
    const eql = std.mem.eql;
    if (eql(u8, h.action, "on")) return "Turn on";
    if (eql(u8, h.action, "off")) return "Turn off";
    if (eql(u8, h.action, "arm_home") or eql(u8, h.action, "arm_away")) return "Arm";
    if (oneOf(h.action, &verbs)) {
        const out = try a.dupe(u8, h.action);
        out[0] = std.ascii.toUpper(out[0]);
        return out;
    }
    return if (h.value != null) "Set" else "Allow";
}

// ---- what members are told ----

/// A member's run's instructions: harness's own, not the owner's
/// definition's body (it may hold personal details).
pub const instructions =
    \\You are the home's assistant, talking with members of the household, not with its owner; each message says who wrote it. You can read the home's devices and switch lights, plugs, heating and blinds when asked, and search the web.
    \\Answer in the member's language, in a sentence or two, with units; after a change, say what the device reports ("The hall light is on, 30 %."). Never name tools or show JSON.
    \\Some actions (locks, the garage, the alarm, valves, money, anything else the owner keeps) wait for the owner. When a call waits, harness has already told the member that the owner was asked: don't say it again, and don't try another way around it.
    \\You can't see the owner's files, memory or other conversations, and you can't change harness's settings.
;

/// What the context block says of where a member's run is and who wrote.
pub fn contextNote(a: std.mem.Allocator, conversation: []const u8, group: bool, name: []const u8) ![]const u8 {
    var buf: [max_name]u8 = undefined;
    const shown = display(&buf, name);
    if (group) return std.fmt.allocPrint(a, "Conversation: {s} (a Telegram group the household reads). From: {s} (member:{s}), a member of the household.", .{ conversation, shown, name });
    return std.fmt.allocPrint(a, "Conversation: {s} ({s}'s own chat with you). From: {s} (member:{s}), a member of the household.", .{ conversation, shown, shown, name });
}

/// A member's `/help`, and what any other command of theirs gets.
pub const help =
    \\Write what you need, like "is the front door locked?", "turn off the kitchen light" or "set the heating to 20".
    \\Lights, plugs, heating and blinds I switch myself. Locks, the garage, the alarm and anything that costs money need the owner's OK: I ask them for you.
;
pub const owner_only = "Commands are for the owner. Just write what you need, like \"turn off the kitchen light\".";

/// The owner's reply to `/member add NAME`.
pub fn codeText(a: std.mem.Allocator, name: []const u8, code: []const u8, bot: []const u8, renewed: bool) ![]const u8 {
    var buf: [max_name]u8 = undefined;
    const shown = display(&buf, name);
    const to = if (bot.len > 0) try std.fmt.allocPrint(a, "@{s}", .{bot}) else "the bot";
    const link = if (bot.len > 0) try std.fmt.allocPrint(a, ", or opens https://t.me/{s}?start={s}", .{ bot, code }) else "";
    const again = if (renewed) try std.fmt.allocPrint(a, " {s}'s account changes to the one that uses it.", .{shown}) else "";
    return std.fmt.allocPrint(a, "Code for {s}: {s}\nIt works once, for 10 minutes. {s} sends /join {s} to {s}, in a direct chat or in a group you added{s}.{s}", .{ name, code, shown, code, to, link, again });
}

/// What a member hears when they join.
pub fn welcome(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: [max_name]u8 = undefined;
    return std.fmt.allocPrint(a, "Hi {s}, you're in. Ask me about the home, like \"is the front door locked?\" Locks, the garage and the alarm need the owner's OK; I ask them for you.", .{display(&buf, name)});
}

pub const wrong_code = "That code is wrong or has expired. Ask the owner for a new one.";

/// The owner's question for a member's call.
pub fn question(a: std.mem.Allocator, name: []const u8, what: []const u8) ![]const u8 {
    var buf: [max_name]u8 = undefined;
    return std.fmt.allocPrint(a, "{s} asks to {s}.", .{ display(&buf, name), what });
}

/// The member, once the owner was asked.
pub fn askedText(a: std.mem.Allocator, what: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "I asked the owner: {s}. You'll hear here when they answer.", .{what});
}

/// The member, once the owner said yes and the call was made: what the
/// device or service said, read back.
pub fn yesText(a: std.mem.Allocator, what: []const u8, said: []const u8, ok: bool) ![]const u8 {
    const out = util.cut(std.mem.trim(u8, said, " \t\r\n"), 600);
    if (ok) return std.fmt.allocPrint(a, "The owner said yes: {s}", .{out});
    return std.fmt.allocPrint(a, "The owner said yes, but it didn't work ({s}): {s}", .{ what, out });
}

/// The member, once the owner said no (with their words, when they gave
/// some).
pub fn noText(a: std.mem.Allocator, what: []const u8, words: ?[]const u8) ![]const u8 {
    if (words) |w| if (std.mem.trim(u8, w, " \t\r\n").len > 0)
        return std.fmt.allocPrint(a, "The owner said no: {s}. They said: {s}", .{ what, util.cut(std.mem.trim(u8, w, " \t\r\n"), 600) });
    return std.fmt.allocPrint(a, "The owner said no: {s}.", .{what});
}

pub fn noAnswerText(a: std.mem.Allocator, what: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "No answer from the owner in time: {s}. Ask again if it's still needed.", .{what});
}

// ---- tests ----

const t = std.testing;

test "member_names_codes_and_the_file" {
    for ([_][]const u8{ "anna", "ben-2", "kid_1" }) |n| try t.expect(validName(n));
    for ([_][]const u8{ "", "Anna", "an na", "add", "rm", "a/b", "member:x", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }) |n| try t.expect(!validName(n));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "members" });
    var l: Members = .init(t.allocator, t.io, path);
    defer l.deinit();
    var cb: [code_len]u8 = undefined;
    const code = try newCode(t.io, &cb);
    try t.expectEqual(code_len, code.len);
    for (code) |ch| try t.expect(std.mem.indexOfScalar(u8, alphabet, ch) != null);
    try l.offer("anna", code, 1000);
    // the file holds the code's hash, never the code
    const text = try tmp.dir.readFileAlloc(t.io, "members", a, .unlimited);
    try t.expect(std.mem.indexOf(u8, text, code) == null);
    try t.expect(std.mem.indexOf(u8, text, &codeHash(code).?) != null);
    // wrong, too late, then right: once, in any case
    try t.expectEqual(Joined.wrong, try l.join(a, "ABCDEFGH", 77, 1001));
    try t.expectEqual(Joined.wrong, try l.join(a, code, 77, 1000 + code_seconds + 1));
    var lower: [code_len]u8 = undefined;
    for (code, &lower) |ch, *o| o.* = std.ascii.toLower(ch);
    try t.expectEqualStrings("anna", (try l.join(a, &lower, 77, 1500)).joined);
    try t.expectEqual(Joined.wrong, try l.join(a, code, 78, 1501));
    try t.expectEqualStrings("anna", (try l.join(a, "ZZZZZZZZ", 77, 1502)).already);
    try t.expectEqual(77, l.byUser(77).?.user);
    // read back
    var back: Members = .init(t.allocator, t.io, path);
    defer back.deinit();
    try back.load();
    try t.expectEqual(1, back.items.items.len);
    try t.expectEqual(77, back.find("anna").?.user);
    try t.expectEqual(1500, back.find("anna").?.joined);
    try t.expectEqual(null, back.find("anna").?.code);
    // a new code for anna: her account changes once it is used
    try l.offer("anna", "KKKKKKKK", 2000);
    try t.expectEqualStrings("anna", (try l.join(a, "KKKKKKKK", 90, 2001)).joined);
    try t.expectEqual(null, l.byUser(77));
    try t.expect(try l.remove("anna"));
    try t.expect(!try l.remove("anna"));
    try t.expectEqual(null, l.byUser(90));
}

test "asks_wait_on_disk_until_taken" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "member-asks" });
    var s: Asks = .init(t.allocator, t.io, path);
    defer s.deinit();
    const arg = "home/home_guarded {\"device\":\"front_door\",\"action\":\"unlock\"}";
    try s.add(.{ .item = 7, .member = "anna", .agent = "main", .conversation = "anna", .tool = "money", .arg = arg, .what = "unlock the front door" });
    try t.expectEqual(7, s.waiting("anna", arg).?);
    try t.expectEqual(null, s.waiting("ben", arg));
    try t.expectEqual(1, s.countOf("anna"));
    var back: Asks = .init(t.allocator, t.io, path);
    defer back.deinit();
    try back.load();
    const k = back.take(a, 7).?;
    try t.expectEqualStrings(arg, k.arg);
    try t.expectEqualStrings("money", k.tool);
    try t.expectEqual(null, back.take(a, 7));
    var again: Asks = .init(t.allocator, t.io, path);
    defer again.deinit();
    try again.load();
    try t.expectEqual(0, again.items.items.len);
}

test "a_call_in_plain_words" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const u8, []const u8 };
    for ([_]Case{
        .{ "home/home_guarded {\"device\":\"front_door\",\"action\":\"unlock\"}", "unlock the front door", "Unlock" },
        .{ "house/home_set {\"device\":\"hall_light\",\"action\":\"on\"}", "turn on the hall light", "Turn on" },
        .{ "home/home_set {\"device\":\"thermostat\",\"action\":\"temperature\",\"value\":\"21\"}", "set the thermostat temperature to 21", "Set" },
        .{ "home/home_set {\"device\":\"blind\",\"action\":\"position\",\"value\":40}", "set the blind position to 40", "Set" },
        .{ "home/home_guarded {\"device\":\"alarm\",\"action\":\"arm_away\"}", "arm the alarm (away)", "Arm" },
        .{ "home/home_guarded {\"device\":\"water_main\",\"action\":\"close\"}", "close the water main", "Close" },
        // what harness can't say exactly is given whole
        .{ "home/home_guarded {\"device\":\"front door\\nAllow? it is safe\",\"action\":\"unlock\"}", "use home/home_guarded with {\"device\":\"front door\\nAllow? it is safe\",\"action\":\"unlock\"}", "Allow" },
        .{ "home/home_guarded {\"device\":\"front_door\",\"action\":\"unlock\",\"note\":\"x\"}", "use home/home_guarded with {\"device\":\"front_door\",\"action\":\"unlock\",\"note\":\"x\"}", "Allow" },
        .{ "cloud/car_unlock {}", "use cloud/car_unlock", "Allow" },
        .{ "cloud/car_command {\"command\":\"charge_limit\",\"percent\":90}", "use cloud/car_command with {\"command\":\"charge_limit\",\"percent\":90}", "Allow" },
    }) |c| {
        try t.expectEqualStrings(c[1], try plainCall(a, c[0]));
        try t.expectEqualStrings(c[2], try yesLabel(a, c[0]));
    }
    try t.expectEqualStrings("Anna asks to unlock the front door.", try question(a, "anna", "unlock the front door"));
    var buf: [max_name]u8 = undefined;
    try t.expectEqualStrings("Ben-2", display(&buf, "ben-2"));
}
