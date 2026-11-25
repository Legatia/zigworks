//! The desk (harness's own window, `harness-desk`): the pieces that hold
//! no core state. Entry by a one-time code (`state/open-request` →
//! `state/desk-code`, 60 s, used once) and a session cookie held in memory
//! only; the feed of events the page long-polls; the last 50 messages of
//! each conversation (in memory, never written); what is spoken of a reply;
//! the state the avatar shows, from harness's facts; the run view's labels;
//! `state/desk.json`; an avatar pack's files.
const std = @import("std");
const util = @import("util.zig");
const config = @import("config.zig");
const Io = std.Io;

// ---- entry: the one-time code ----

/// How long a code is good for.
pub const code_ms: i64 = 60_000;

/// The one code waiting (a new request replaces it).
pub const Codes = struct {
    mutex: Io.Mutex = .init,
    code: [22]u8 = undefined,
    issued_ms: i64 = 0,
    live: bool = false,

    /// A new code, written to `path` (only its owner can read it): any
    /// code before it is void.
    pub fn issue(c: *Codes, io: Io, path: []const u8, now_ms: i64) ![22]u8 {
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        var code: [22]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&code, &raw);
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.live = false;
        // made new, so its mode is ours from the start
        Io.Dir.cwd().deleteFile(io, path) catch {};
        var f = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = util.private_file });
        defer f.close(io);
        var line: [23]u8 = undefined;
        @memcpy(line[0..22], &code);
        line[22] = '\n';
        try f.writeStreamingAll(io, &line);
        c.code = code;
        c.issued_ms = now_ms;
        c.live = true;
        return code;
    }

    /// Whether `given` is the code waiting, within its 60 s and unused;
    /// either way a used or late code is gone, and its file too.
    pub fn take(c: *Codes, io: Io, path: []const u8, given: []const u8, now_ms: i64) bool {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (!c.live) return false;
        if (now_ms - c.issued_ms > code_ms) {
            c.live = false;
            Io.Dir.cwd().deleteFile(io, path) catch {};
            return false;
        }
        if (given.len != 22) return false;
        if (!std.crypto.timing_safe.eql([22]u8, given[0..22].*, c.code)) return false;
        c.live = false;
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return true;
    }

    /// Past its 60 s the code is forgotten and its file deleted.
    pub fn expire(c: *Codes, io: Io, path: []const u8, now_ms: i64) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (!c.live or now_ms - c.issued_ms <= code_ms) return;
        c.live = false;
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
};

// ---- entry: the session ----

/// The session cookie's name.
pub const cookie_name = "harness_desk";

/// The desk's sessions, in memory only (a restart ends them all).
pub const Sessions = struct {
    mutex: Io.Mutex = .init,
    list: [max][43]u8 = undefined,
    n: usize = 0,

    /// Kept at once; past it the oldest goes.
    pub const max = 16;

    /// A new session: 32 random bytes, base64url.
    pub fn create(s: *Sessions, io: Io) ![43]u8 {
        var raw: [32]u8 = undefined;
        try io.randomSecure(&raw);
        var tok: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&tok, &raw);
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.n == max) {
            std.mem.copyForwards([43]u8, s.list[0 .. max - 1], s.list[1..max]);
            s.n -= 1;
        }
        s.list[s.n] = tok;
        s.n += 1;
        return tok;
    }

    /// Whether `token` is one of the sessions (each compared in full, in
    /// time that doesn't depend on where they differ).
    pub fn valid(s: *Sessions, io: Io, token: []const u8) bool {
        if (token.len != 43) return false;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        var hit = false;
        for (s.list[0..s.n]) |x| {
            if (std.crypto.timing_safe.eql([43]u8, x, token[0..43].*)) hit = true;
        }
        return hit;
    }
};

/// Cookie `name`'s value in a Cookie header; null: none.
pub fn cookieOf(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, part[0..eq], " \t"), name)) continue;
        return std.mem.trim(u8, part[eq + 1 ..], " \t");
    }
    return null;
}

/// The Set-Cookie value of session `token`: for this server's every
/// path, never read by scripts, never sent from another site, gone when
/// the web view closes (no Expires).
pub fn setCookie(buf: []u8, token: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}={s}; Path=/; HttpOnly; SameSite=Strict", .{ cookie_name, token }) catch "";
}

// ---- the feed ----

/// What a long-poll gets: the newest seq, the events after the cursor,
/// or `reset` (the cursor is from an earlier start or older than the feed
/// keeps: the page reads the state again).
pub const Since = struct { seq: u64, events: []const []const u8 = &.{}, reset: bool = false };

/// The events of this start, numbered; the last 512 kept.
pub const Feed = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    ring: [cap]?[]u8 = @splat(null),
    seq: u64 = 0,

    pub const cap = 512;

    pub fn init(gpa: std.mem.Allocator, io: Io) Feed {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(f: *Feed) void {
        for (&f.ring) |*e| if (e.*) |x| {
            f.gpa.free(x);
            e.* = null;
        };
    }

    /// `{"seq":N,"type":"KIND",FIELDS}`; `fields` is JSON members without
    /// braces ("" for none). A push that can't be kept is dropped.
    pub fn push(f: *Feed, kind: []const u8, fields: []const u8) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const seq = f.seq + 1;
        const line = std.fmt.allocPrint(f.gpa, "{{\"seq\":{d},\"type\":\"{s}\"{s}{s}}}", .{ seq, kind, if (fields.len > 0) "," else "", fields }) catch return;
        const slot = &f.ring[@intCast(seq % cap)];
        if (slot.*) |old| f.gpa.free(old);
        slot.* = line;
        f.seq = seq;
    }

    pub fn last(f: *Feed) u64 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.seq;
    }

    /// The events after `after`, at once; none yet: waits up to `wait_ms`
    /// for one (ended early by `stop`).
    pub fn since(f: *Feed, a: std.mem.Allocator, after: u64, wait_ms: u32, stop: ?*const std.atomic.Value(bool)) !Since {
        var waited: u32 = 0;
        while (true) {
            {
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                const oldest = if (f.seq > cap) f.seq - cap + 1 else 1;
                if (after > f.seq or after + 1 < oldest) return .{ .seq = f.seq, .reset = true };
                if (after < f.seq) {
                    var out: std.ArrayList([]const u8) = .empty;
                    var i = after + 1;
                    while (i <= f.seq) : (i += 1) try out.append(a, try a.dupe(u8, f.ring[@intCast(i % cap)].?));
                    return .{ .seq = f.seq, .events = out.items };
                }
                if (waited >= wait_ms) return .{ .seq = f.seq };
            }
            if (stop) |x| if (x.load(.acquire)) return .{ .seq = f.last() };
            f.io.sleep(.fromMilliseconds(50), .awake) catch {};
            waited += 50;
        }
    }
};

/// A long-poll's answer: `{"seq":N,"events":[…]}`, with `"reset":true`.
pub fn sinceJson(a: std.mem.Allocator, got: Since) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{\"seq\":{d}{s},\"events\":[", .{ got.seq, if (got.reset) ",\"reset\":true" else "" });
    for (got.events, 0..) |e, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, e);
    }
    try out.appendSlice(a, "]}");
    return out.items;
}

// ---- history ----

pub const From = enum { you, harness };

/// One message of a conversation as the desk shows it.
pub const Msg = struct {
    id: u64 = 0,
    from: From,
    text: []const u8,
    at: i64,
    /// The inbox item its buttons answer; 0: none.
    item: u64 = 0,
    /// An urgent alert's post.
    urgent: bool = false,
    /// Where the owner wrote it ("desk", "telegram", "terminal"); "": harness's.
    via: []const u8 = "",
};

/// The last 50 messages of each conversation, in memory only: a private
/// conversation's never reach a file.
pub const History = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    convs: std.ArrayList(Conv) = .empty,
    next_id: u64 = 1,
    clock: u64 = 0,

    pub const per_conv = 50;
    pub const max_convs = 64;
    /// The most of one message kept.
    pub const max_text = 16 * 1024;

    const Conv = struct { name: []u8, msgs: std.ArrayList(Msg) = .empty, touched: u64 = 0 };

    pub fn init(gpa: std.mem.Allocator, io: Io) History {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(h: *History) void {
        for (h.convs.items) |*c| h.freeConv(c);
        h.convs.deinit(h.gpa);
    }

    fn freeConv(h: *History, c: *Conv) void {
        for (c.msgs.items) |m| h.freeMsg(m);
        c.msgs.deinit(h.gpa);
        h.gpa.free(c.name);
    }

    fn freeMsg(h: *History, m: Msg) void {
        h.gpa.free(m.text);
        h.gpa.free(m.via);
    }

    /// Adds `m` to `conv` (its texts copied); returns its id.
    pub fn add(h: *History, conv: []const u8, m: Msg) !u64 {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const c = try h.convOf(conv);
        var own = m;
        own.text = try h.gpa.dupe(u8, util.cut(m.text, max_text));
        errdefer h.gpa.free(own.text);
        own.via = try h.gpa.dupe(u8, m.via);
        errdefer h.gpa.free(own.via);
        own.id = h.next_id;
        if (c.msgs.items.len == per_conv) h.freeMsg(c.msgs.orderedRemove(0));
        try c.msgs.append(h.gpa, own);
        h.next_id += 1;
        h.clock += 1;
        c.touched = h.clock;
        return own.id;
    }

    fn convOf(h: *History, name: []const u8) !*Conv {
        for (h.convs.items) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        if (h.convs.items.len == max_convs) {
            var oldest: usize = 0;
            for (h.convs.items, 0..) |c, i| if (c.touched < h.convs.items[oldest].touched) {
                oldest = i;
            };
            var gone = h.convs.orderedRemove(oldest);
            h.freeConv(&gone);
        }
        const owned = try h.gpa.dupe(u8, name);
        errdefer h.gpa.free(owned);
        try h.convs.append(h.gpa, .{ .name = owned });
        return &h.convs.items[h.convs.items.len - 1];
    }

    /// `conv`'s messages, oldest first, copied into `a`.
    pub fn list(h: *History, a: std.mem.Allocator, conv: []const u8) ![]Msg {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.convs.items) |c| if (std.mem.eql(u8, c.name, conv)) {
            const out = try a.alloc(Msg, c.msgs.items.len);
            for (c.msgs.items, out) |m, *o| o.* = try copyMsg(a, m);
            return out;
        };
        return &.{};
    }

    pub const Found = struct { conv: []const u8, msg: Msg };

    /// Message `id`, with its conversation, copied into `a`.
    pub fn find(h: *History, a: std.mem.Allocator, id: u64) !?Found {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.convs.items) |c| for (c.msgs.items) |m| if (m.id == id) return .{ .conv = try a.dupe(u8, c.name), .msg = try copyMsg(a, m) };
        return null;
    }

    fn copyMsg(a: std.mem.Allocator, m: Msg) !Msg {
        var o = m;
        o.text = try a.dupe(u8, m.text);
        o.via = try a.dupe(u8, m.via);
        return o;
    }
};

/// A message as the page reads it; harness's carry `say`, what would be
/// spoken of them.
pub fn msgJson(out: *std.ArrayList(u8), a: std.mem.Allocator, m: Msg) !void {
    try out.print(a, "{{\"id\":{d},\"from\":\"{s}\",\"text\":", .{ m.id, @tagName(m.from) });
    try util.jsonString(out, a, m.text);
    try out.print(a, ",\"at\":{d}", .{m.at});
    if (m.item != 0) try out.print(a, ",\"item\":{d}", .{m.item});
    if (m.urgent) try out.appendSlice(a, ",\"urgent\":true");
    if (m.via.len > 0) {
        try out.appendSlice(a, ",\"via\":");
        try util.jsonString(out, a, m.via);
    }
    if (m.from == .harness) {
        try out.appendSlice(a, ",\"say\":");
        try util.jsonString(out, a, try spoken(a, m.text));
    }
    try out.append(a, '}');
}

// ---- what is spoken ----

/// The most of a reply read aloud whole (speech.zig's `max_spoken`).
pub const max_spoken = 400;
const rest_on_screen = " The rest is on screen.";

/// What the desk reads aloud of `text`: all of it up to 400 bytes, else
/// its first two sentences (a line break ends one too) and "The rest is on
/// screen."
pub fn spoken(a: std.mem.Allocator, text_in: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len <= max_spoken) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var sentences: u32 = 0;
    var start: usize = 0;
    while (i < text.len and sentences < 2) : (i += 1) {
        const ch = text[i];
        const ends = ch == '\n' or ((ch == '.' or ch == '!' or ch == '?') and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\n'));
        if (!ends) continue;
        const upto = if (ch == '\n') i else i + 1;
        const part = std.mem.trim(u8, text[start..upto], " \t\r\n");
        start = i + 1;
        if (part.len == 0) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, part);
        sentences += 1;
    }
    if (out.items.len == 0 or out.items.len > max_spoken) {
        // one long sentence: cut at the last word that fits
        const from = if (out.items.len > 0) out.items else text;
        const cut = util.cut(from, max_spoken);
        const sp = std.mem.lastIndexOfScalar(u8, cut, ' ') orelse cut.len;
        const kept = std.mem.trimEnd(u8, cut[0..sp], " ,;:");
        out = .empty;
        try out.appendSlice(a, kept);
    }
    try out.appendSlice(a, rest_on_screen);
    return out.items;
}

// ---- the state ----

/// What the avatar shows, from harness's facts (the spec's table; the
/// page puts `speaking` between urgent and needs while its voice plays).
pub const State = enum { urgent, needs, working, quiet, resting };

pub const Facts = struct { urgent_items: usize = 0, alerts: usize = 0, open_items: usize = 0, runs: usize = 0, quiet: bool = false };

pub fn stateOf(f: Facts) State {
    if (f.urgent_items > 0 or f.alerts > 0) return .urgent;
    if (f.open_items > 0) return .needs;
    if (f.runs > 0) return .working;
    if (f.quiet) return .quiet;
    return .resting;
}

/// The status card's label of a run: the owner's own message's first
/// line, else what started it.
pub fn runLabel(a: std.mem.Allocator, by: []const u8, text: []const u8) ![]const u8 {
    if (std.mem.eql(u8, by, "owner")) {
        const first = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
        if (first.len <= 80) return a.dupe(u8, first);
        return std.fmt.allocPrint(a, "{s}…", .{std.mem.trimEnd(u8, util.cut(first, 80), " ")});
    }
    const colon = std.mem.indexOfScalar(u8, by, ':') orelse return std.fmt.allocPrint(a, "Run: {s}", .{by});
    const kind = by[0..colon];
    var name = by[colon + 1 ..];
    name = name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len];
    const word: ?[]const u8 = if (std.mem.eql(u8, kind, "schedule")) "Routine" else if (std.mem.eql(u8, kind, "trigger")) "Trigger" else if (std.mem.eql(u8, kind, "workflow")) "Workflow" else if (std.mem.eql(u8, kind, "app")) "App" else null;
    if (word) |w| return std.fmt.allocPrint(a, "{s}: {s}", .{ w, name });
    return std.fmt.allocPrint(a, "Run: {s}", .{by});
}

// ---- files ----

/// A file's ETag: its SHA-256's first 16 bytes, quoted.
pub fn etag(data: []const u8) [34]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    var out: [34]u8 = undefined;
    out[0] = '"';
    out[33] = '"';
    _ = std.fmt.bufPrint(out[1..33], "{s}", .{std.fmt.bytesToHex(h[0..16].*, .lower)}) catch {};
    return out;
}

/// `state/desk.json`: where the desk app finds harness.
pub fn deskJson(a: std.mem.Allocator, binary: []const u8, port: u16, home: []const u8, version: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"binary\":");
    try util.jsonString(&out, a, binary);
    try out.print(a, ",\"port\":{d},\"home\":", .{port});
    try util.jsonString(&out, a, home);
    try out.appendSlice(a, ",\"version\":");
    try util.jsonString(&out, a, version);
    try out.appendSlice(a, "}\n");
    return out.items;
}

/// The files of an avatar pack.
pub const Part = enum { still, closed, head, eyes, eyemask };

/// "jpg" or "png" by the image's first bytes; null: neither.
pub fn imageKind(data: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) return "jpg";
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "png";
    return null;
}

/// The name part `part` is kept under in `avatars/NAME/`; null: `data`
/// isn't that part (the portraits JPEG or PNG, the eyes and mask PNG).
pub fn packFile(part: Part, data: []const u8) ?[]const u8 {
    return switch (part) {
        .still => if (imageKind(data)) |k| (if (std.mem.eql(u8, k, "jpg")) "still.jpg" else "still.png") else null,
        .closed => if (imageKind(data)) |k| (if (std.mem.eql(u8, k, "jpg")) "closed.jpg" else "closed.png") else null,
        .head => if (data.len > 0) "head.bin" else null,
        .eyes => if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) "eyes.png" else null,
        .eyemask => if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) "eyemask.png" else null,
    };
}

/// What an avatar's folder holds.
pub const Pack = struct { still: ?[]const u8 = null, closed: ?[]const u8 = null, head: ?[]const u8 = null, eyes: ?[]const u8 = null, eyemask: ?[]const u8 = null };

/// `avatar.ini`, naming the files there are.
pub fn avatarIni(a: std.mem.Allocator, p: Pack) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "[avatar]\n");
    inline for (.{ "still", "closed", "head", "eyes", "eyemask" }) |k| if (@field(p, k)) |v| try out.print(a, k ++ " = {s}\n", .{v});
    return out.items;
}

// ---- tests ----

const t = std.testing;

fn tmpPath(tmp: *t.TmpDir, a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), name });
}

test "a_code_works_once_and_expires" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(&tmp, a, "desk-code");
    var c: Codes = .{};
    const code = try c.issue(t.io, path, 1000);
    // the file holds the code, readable only by its owner
    const text = try tmp.dir.readFileAlloc(t.io, "desk-code", a, .unlimited);
    try t.expectEqualStrings(&code, std.mem.trimEnd(u8, text, "\n"));
    if (@import("builtin").os.tag != .windows) {
        const st = try tmp.dir.statFile(t.io, "desk-code", .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    // a wrong code of the right length, and one of another length: no
    var wrong = code;
    wrong[0] = if (code[0] == 'A') 'B' else 'A';
    try t.expect(!c.take(t.io, path, &wrong, 2000));
    try t.expect(!c.take(t.io, path, code[0..10], 2000));
    // once, and the file goes
    try t.expect(c.take(t.io, path, &code, 2000));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "desk-code", .{}));
    try t.expect(!c.take(t.io, path, &code, 2001));
    // a new one expires after 60 s: refused, and its file deleted
    const two = try c.issue(t.io, path, 10_000);
    try t.expect(!std.mem.eql(u8, &two, &code));
    c.expire(t.io, path, 10_000 + code_ms - 1);
    _ = try tmp.dir.statFile(t.io, "desk-code", .{});
    c.expire(t.io, path, 10_000 + code_ms + 1);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "desk-code", .{}));
    try t.expect(!c.take(t.io, path, &two, 10_000 + code_ms + 2));
    // taken late without a tick between: refused too
    const three = try c.issue(t.io, path, 100_000);
    try t.expect(!c.take(t.io, path, &three, 100_000 + code_ms + 1));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "desk-code", .{}));
}

test "sessions_are_random_and_bounded" {
    var s: Sessions = .{};
    const one = try s.create(t.io);
    const two = try s.create(t.io);
    try t.expect(!std.mem.eql(u8, &one, &two));
    try t.expect(s.valid(t.io, &one));
    try t.expect(s.valid(t.io, &two));
    try t.expect(!s.valid(t.io, ""));
    try t.expect(!s.valid(t.io, one[0..42]));
    var other = one;
    other[5] = if (one[5] == 'A') 'B' else 'A';
    try t.expect(!s.valid(t.io, &other));
    // past 16 the oldest goes
    for (0..Sessions.max - 1) |_| _ = try s.create(t.io);
    try t.expect(!s.valid(t.io, &one));
    try t.expect(s.valid(t.io, &two));
}

test "cookies_are_read_from_the_header" {
    try t.expectEqualStrings("XYZ", cookieOf("a=1; harness_desk=XYZ; b=2", cookie_name).?);
    try t.expectEqualStrings("XYZ", cookieOf("harness_desk=XYZ", cookie_name).?);
    try t.expectEqualStrings("XYZ", cookieOf("  harness_desk = XYZ ;x=y", cookie_name).?);
    try t.expectEqual(null, cookieOf("other_harness_desk=XYZ", cookie_name));
    try t.expectEqual(null, cookieOf("a=1", cookie_name));
    try t.expectEqual(null, cookieOf("", cookie_name));
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("harness_desk=TOKEN; Path=/; HttpOnly; SameSite=Strict", setCookie(&buf, "TOKEN"));
}

fn pushLater(f: *Feed) void {
    f.io.sleep(.fromMilliseconds(150), .awake) catch {};
    f.push("items", "");
}

test "the_feed_answers_at_once_or_waits" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Feed = .init(t.allocator, t.io);
    defer f.deinit();
    f.push("message", "\"conv\":\"main\"");
    f.push("moment", "\"moment\":\"smile\"");
    try t.expectEqual(2, f.last());
    const got = try f.since(a, 0, 25_000, null);
    try t.expectEqual(2, got.seq);
    try t.expectEqual(2, got.events.len);
    try t.expectEqualStrings("{\"seq\":1,\"type\":\"message\",\"conv\":\"main\"}", got.events[0]);
    try t.expectEqualStrings("{\"seq\":2,\"type\":\"moment\",\"moment\":\"smile\"}", got.events[1]);
    try t.expectEqualStrings("{\"seq\":2,\"events\":[{\"seq\":2,\"type\":\"moment\",\"moment\":\"smile\"}]}", try sinceJson(a, try f.since(a, 1, 0, null)));
    // nothing new: empty after the wait
    const empty = try f.since(a, 2, 50, null);
    try t.expectEqual(0, empty.events.len);
    try t.expectEqualStrings("{\"seq\":2,\"events\":[]}", try sinceJson(a, empty));
    // a push from another thread ends the wait
    const th = try std.Thread.spawn(.{}, pushLater, .{&f});
    const started = Io.Clock.awake.now(t.io);
    const later = try f.since(a, 2, 10_000, null);
    th.join();
    try t.expect(started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 5000);
    try t.expectEqual(1, later.events.len);
    try t.expectEqualStrings("{\"seq\":3,\"type\":\"items\"}", later.events[0]);
    // a stop ends it too
    var stop: std.atomic.Value(bool) = .init(true);
    try t.expectEqual(0, (try f.since(a, 3, 10_000, &stop)).events.len);
}

test "the_feed_answers_late_and_old_cursors_with_reset" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Feed = .init(t.allocator, t.io);
    defer f.deinit();
    for (0..Feed.cap + 10) |_| f.push("items", "");
    // from an earlier start (ahead of this one), or older than it keeps
    const ahead = try f.since(a, 9999, 10_000, null);
    try t.expect(ahead.reset);
    try t.expectEqual(Feed.cap + 10, ahead.seq);
    try t.expectEqualStrings("{\"seq\":522,\"reset\":true,\"events\":[]}", try sinceJson(a, ahead));
    try t.expect((try f.since(a, 5, 10_000, null)).reset);
    // the oldest kept is answered whole
    const kept = try f.since(a, 10, 0, null);
    try t.expect(!kept.reset);
    try t.expectEqual(Feed.cap, kept.events.len);
}

test "history_keeps_the_last_50_per_conversation" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: History = .init(t.allocator, t.io);
    defer h.deinit();
    var ids: [60]u64 = undefined;
    for (0..60) |i| ids[i] = try h.add("main", .{ .from = if (i % 2 == 0) .you else .harness, .text = try std.fmt.allocPrint(a, "m{d}", .{i}), .at = @intCast(1000 + i), .via = if (i % 2 == 0) "desk" else "" });
    _ = try h.add("house", .{ .from = .harness, .text = "Front door closed.", .at = 5000, .item = 7, .urgent = true });
    const main = try h.list(a, "main");
    try t.expectEqual(History.per_conv, main.len);
    try t.expectEqualStrings("m10", main[0].text);
    try t.expectEqualStrings("m59", main[49].text);
    try t.expectEqual(ids[59], main[49].id);
    try t.expect(ids[59] > ids[58]);
    try t.expectEqual(0, (try h.list(a, "nowhere")).len);
    const found = (try h.find(a, ids[59])).?;
    try t.expectEqualStrings("main", found.conv);
    try t.expectEqualStrings("m59", found.msg.text);
    try t.expectEqual(null, try h.find(a, ids[0]));
    // as the page reads it, with what harness's own message would say aloud
    var out: std.ArrayList(u8) = .empty;
    try msgJson(&out, a, (try h.list(a, "house"))[0]);
    try t.expectEqualStrings("{\"id\":61,\"from\":\"harness\",\"text\":\"Front door closed.\",\"at\":5000,\"item\":7,\"urgent\":true,\"say\":\"Front door closed.\"}", out.items);
    out.clearRetainingCapacity();
    try msgJson(&out, a, main[48]);
    try t.expectEqualStrings("{\"id\":59,\"from\":\"you\",\"text\":\"m58\",\"at\":1058,\"via\":\"desk\"}", out.items);
    // past 64 conversations the one least lately written goes
    for (0..History.max_convs) |i| _ = try h.add(try std.fmt.allocPrint(a, "t{d}", .{i}), .{ .from = .harness, .text = "x", .at = 1 });
    try t.expectEqual(0, (try h.list(a, "main")).len);
    try t.expectEqual(1, (try h.list(a, "t63")).len);
}

test "long_replies_speak_two_sentences" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Done. The heating is at 21.", try spoken(a, "  Done. The heating is at 21.\n"));
    const filler: [380]u8 = @splat('x');
    const long = try std.fmt.allocPrint(a, "Three flats match. The cheapest is on Miodowa! Then: {s}. And more.", .{&filler});
    try t.expectEqualStrings("Three flats match. The cheapest is on Miodowa! The rest is on screen.", try spoken(a, long));
    // a line break ends a sentence too
    const lines = try std.fmt.allocPrint(a, "Shortlist\nMiodowa 5, 3900\n{s}", .{&filler});
    try t.expectEqualStrings("Shortlist Miodowa 5, 3900 The rest is on screen.", try spoken(a, lines));
    // one sentence over 400 bytes: cut at a word
    var wl: std.ArrayList(u8) = .empty;
    for (0..100) |_| try wl.appendSlice(a, "word ");
    const words = wl.items;
    const got = try spoken(a, words);
    try t.expect(got.len <= max_spoken + " The rest is on screen.".len);
    try t.expect(std.mem.endsWith(u8, got, "word The rest is on screen."));
}

test "the_state_table" {
    // in the spec's order: urgent, (speaking: the page's), needs you, working, quiet, resting
    try t.expectEqual(State.urgent, stateOf(.{ .urgent_items = 1, .open_items = 3, .runs = 2, .quiet = true }));
    try t.expectEqual(State.urgent, stateOf(.{ .alerts = 1, .quiet = true }));
    try t.expectEqual(State.needs, stateOf(.{ .open_items = 1, .runs = 1, .quiet = true }));
    try t.expectEqual(State.working, stateOf(.{ .runs = 1, .quiet = true }));
    try t.expectEqual(State.quiet, stateOf(.{ .quiet = true }));
    try t.expectEqual(State.resting, stateOf(.{}));
}

test "run_labels_name_who_started_it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Find me a two-bedroom near Kazimierz", try runLabel(a, "owner", "Find me a two-bedroom near Kazimierz\nunder 4000"));
    const long: [120]u8 = @splat('y');
    const cut = try runLabel(a, "owner", &long);
    try t.expect(std.mem.endsWith(u8, cut, "…"));
    try t.expect(cut.len <= 80 + "…".len);
    try t.expectEqualStrings("Routine: morning", try runLabel(a, "schedule:morning", "Check the price."));
    try t.expectEqualStrings("Trigger: leak", try runLabel(a, "trigger:leak", "x"));
    try t.expectEqualStrings("Workflow: water", try runLabel(a, "workflow:water/ask", "x"));
    try t.expectEqualStrings("App: notes", try runLabel(a, "app:notes", "x"));
    try t.expectEqualStrings("Run: member:anna", try runLabel(a, "member:anna", "x"));
}

test "desk_json_names_binary_port_home_version" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("{\"binary\":\"C:\\\\h\\\\harness.exe\",\"port\":47811,\"home\":\"/home/x/.harness\",\"version\":\"0.4.0\"}\n", try deskJson(a, "C:\\h\\harness.exe", 47811, "/home/x/.harness", "0.4.0"));
}

test "pack_files_are_checked_by_magic" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jpg = "\xff\xd8\xff\xe0rest";
    const png = "\x89PNG\r\n\x1a\nrest";
    try t.expectEqualStrings("still.jpg", packFile(.still, jpg).?);
    try t.expectEqualStrings("still.png", packFile(.still, png).?);
    try t.expectEqualStrings("closed.jpg", packFile(.closed, jpg).?);
    try t.expectEqual(null, packFile(.still, "GIF89a"));
    try t.expectEqualStrings("eyes.png", packFile(.eyes, png).?);
    try t.expectEqual(null, packFile(.eyes, jpg));
    try t.expectEqualStrings("eyemask.png", packFile(.eyemask, png).?);
    try t.expectEqualStrings("head.bin", packFile(.head, "{\"v\":1}").?);
    try t.expectEqual(null, packFile(.head, ""));
    try t.expectEqualStrings("[avatar]\nstill = still.jpg\nhead = head.bin\neyes = eyes.png\n", try avatarIni(a, .{ .still = "still.jpg", .head = "head.bin", .eyes = "eyes.png" }));
    try t.expectEqualStrings("[avatar]\nstill = still.png\nclosed = closed.jpg\nhead = head.bin\neyes = eyes.png\neyemask = eyemask.png\n", try avatarIni(a, .{ .still = "still.png", .closed = "closed.jpg", .head = "head.bin", .eyes = "eyes.png", .eyemask = "eyemask.png" }));
    // an etag is the same for the same bytes, quoted
    const e1 = etag("abc");
    try t.expectEqual('"', e1[0]);
    try t.expectEqual('"', e1[33]);
    try t.expectEqualStrings(&e1, &etag("abc"));
    try t.expect(!std.mem.eql(u8, &e1, &etag("abd")));
}
