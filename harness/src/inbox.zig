//! The inbox: what waits for the owner — approvals, the agent's questions
//! and drafts, calls an unattended run skipped, posts that did not get
//! through, and the kinds other parts add. Kept in `state/inbox`: a first
//! line with the next id and the day of the last reminder, then one item a
//! line (format v1, then the fields kept in the file only), written whole
//! (a temporary file, then a rename) on every change, before anyone acts on
//! it; open items and those closed in the last 7 days, at most 500.
//! Transport-free: the core shows items and takes their answers; this
//! file says what an item is and how it reads.
const std = @import("std");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const max_title = 200;
/// Today's question limit: a longer call is refused before it is asked.
pub const max_body = 12 * 1024;
/// Messages an item's buttons are in at once (the first and Show's).
pub const max_shown = 4;
/// Closed items are kept this long.
pub const keep_s: i64 = 7 * 86400;
pub const max_kept = 500;
/// Open items other than runs' at once; past it the oldest skipped expire.
pub const max_open_other = 200;
/// Telegram's limit for one message, in bytes.
pub const message_max = 4096;
/// What a message keeps free for the outcome added when its item closes.
const outcome_room = 160;

pub const Status = enum { open, answered, expired, void, withdrawn, done };
/// What a text answer is (`text` in v1).
pub const TextKind = enum { none, answer, draft, reason };
/// `fallback`: an urgent routine's question nobody was on, answered by
/// harness with its yes (its safe call).
pub const Via = enum { telegram, terminal, bar, harness, fallback };

pub const Choice = struct { key: []const u8, label: []const u8 };

/// How an item closed: the key chosen (null when harness closed it), the
/// owner's words or harness's reason, when, and from where.
pub const Answer = struct { key: ?[]const u8 = null, text: ?[]const u8 = null, at: i64, via: Via };

/// A message with the item's buttons.
pub const Shown = struct {
    chat: i64,
    thread: i64,
    message: i64,
    /// main's one-line pointer to an item shown in its topic: edited with
    /// that line and the outcome when it closes.
    short: bool = false,
};

/// A delivery's post, to be sent again as it was.
pub const Post = struct {
    conversation: []const u8,
    text: []const u8,
    /// A brief's links: seen once it is delivered.
    links: []const []const u8 = &.{},
    /// The brief or task whose message it is ("task:NAME"); "": none.
    of: []const u8 = "",
    /// What the scheduler's `ran` gets for `of` once it is delivered.
    ran: i64 = 0,
    tries: u32 = 0,
    /// When harness sends it again; 0: it does not (the owner decides).
    next: i64 = 0,
};

/// The grant "Allow for this task" writes: the tool (`shell@host` for a
/// command), the key the gate matches, who it covers.
pub const Grant = struct { tool: []const u8, key: []const u8, who: []const u8 };

/// A text kept only as its size and keyed hash (a private run's, once its
/// item closed), as the log keeps private fields.
pub const Mark = struct { bytes: usize, hmac: ?[64]u8 = null };

pub const Hidden = struct { title: Mark, body: Mark, draft: ?Mark = null, answer: ?Mark = null, post: ?Mark = null };

/// A press of an item's buttons that came before the channel said which
/// message they are in.
pub const Early = struct {
    message: i64,
    buf: [16]u8 = undefined,
    len: u8 = 0,

    pub fn key(e: *const Early) []const u8 {
        return e.buf[0..e.len];
    }
};

pub const Item = struct {
    /// Holds its texts; an item is freed whole.
    arena: std.heap.ArenaAllocator,
    id: u64,
    kind: []const u8,
    status: Status = .open,
    created: i64,
    /// When it closes unanswered; 0: never.
    expires: i64 = 0,
    by: []const u8 = "owner",
    agent: ?[]const u8 = null,
    rid: ?u64 = null,
    run: ?[]const u8 = null,
    conversation: []const u8 = "main",
    /// `run` (void at a restart), `harness`, or a workflow step's label.
    waiter: []const u8 = "harness",
    app: ?[]const u8 = null,
    title: []const u8 = "",
    body: []const u8 = "",
    choices: []const Choice = &.{},
    text: TextKind = .none,
    draft: ?[]const u8 = null,
    /// How often the same thing came up.
    count: u32 = 1,
    answer: ?Answer = null,

    // kept in the file only

    /// Random per item: a button answers only its own item.
    token: [16]u8,
    shown: std.ArrayList(Shown) = .empty,
    post: ?Post = null,
    grant: ?Grant = null,
    /// A skipped call's key: one item per task (trigger, workflow) and call.
    skip: ?[]const u8 = null,
    /// Its run or conversation was private.
    private: bool = false,
    /// Its texts as marks, once a private item closed.
    hidden: ?Hidden = null,

    // in memory only

    /// Its buttons are being sent: a press now is checked once they are.
    showing: bool = false,
    early: ?Early = null,
    /// An answer is being acted on (a grant written, a post sent).
    settling: bool = false,

    pub fn offers(it: *const Item, key: []const u8) bool {
        for (it.choices) |ch| if (std.mem.eql(u8, ch.key, key)) return true;
        return false;
    }

    /// The key a text answer takes: an approval's reason denies it, a
    /// question's words answer it, a draft's replace it.
    pub fn textKey(it: *const Item) ?[]const u8 {
        return switch (it.text) {
            .none => null,
            .reason => "deny",
            .answer => "text",
            .draft => "use",
        };
    }

    /// A run waits on it (it is void at a restart).
    pub fn isRun(it: *const Item) bool {
        return std.mem.eql(u8, it.waiter, "run");
    }

    pub fn choiceLabel(it: *const Item, key: []const u8) ?[]const u8 {
        for (it.choices) |ch| if (std.mem.eql(u8, ch.key, key)) return ch.label;
        return null;
    }

    fn destroy(it: *Item, gpa: std.mem.Allocator) void {
        it.arena.deinit();
        gpa.destroy(it);
    }
};

/// An item to make (`Box.add` copies what it holds).
pub const New = struct {
    kind: []const u8,
    by: []const u8 = "owner",
    agent: ?[]const u8 = null,
    rid: ?u64 = null,
    run: ?[]const u8 = null,
    conversation: []const u8 = "main",
    waiter: []const u8 = "harness",
    /// The app that shows it (gap 8); null: none.
    app: ?[]const u8 = null,
    title: []const u8,
    body: []const u8,
    choices: []const Choice = &.{},
    text: TextKind = .none,
    draft: ?[]const u8 = null,
    expires: i64 = 0,
    post: ?Post = null,
    grant: ?Grant = null,
    skip: ?[]const u8 = null,
    private: bool = false,
};

/// The items, and `state/inbox`. Callers hold `mutex` for every call but
/// `init`, `load` (before others can reach it) and `deinit`.
pub const Box = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(*Item) = .empty,
    next: u64 = 1,
    /// The local day the reminder last went out.
    reminded: i64 = 0,
    /// The instance's key for private texts' hashes (the log's).
    key: ?[32]u8 = null,
    /// `state/approvals`, deleted once `state/inbox` holds the numbers.
    retire: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, io: Io, path: []const u8) Box {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(b: *Box) void {
        for (b.items.items) |it| it.destroy(b.gpa);
        b.items.deinit(b.gpa);
    }

    /// Reads `state/inbox`; a line that does not read is left out. With no
    /// such file, the first id follows the number in `approvals` ("" for
    /// none), which goes once `state/inbox` is written.
    pub fn load(b: *Box, approvals: []const u8) !void {
        const text = Io.Dir.cwd().readFileAlloc(b.io, b.path, b.gpa, .limited(64 << 20)) catch |e| switch (e) {
            error.FileNotFound => {
                if (approvals.len == 0) return;
                var buf: [32]u8 = undefined;
                const got = Io.Dir.cwd().readFile(b.io, approvals, &buf) catch return;
                const n = std.fmt.parseInt(u64, std.mem.trim(u8, got, " \r\n"), 10) catch return;
                b.next = @max(b.next, n + 1);
                b.retire = approvals;
                return;
            },
            else => return e,
        };
        defer b.gpa.free(text);
        var scratch: std.heap.ArenaAllocator = .init(b.gpa);
        defer scratch.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            _ = scratch.reset(.retain_capacity);
            const v = jv.parse(scratch.allocator(), line) orelse continue;
            if (jv.get(v, "v") == null) {
                // the first line: the numbers
                if (jv.int(jv.get(v, "next"))) |n| if (n > 0) {
                    b.next = @max(b.next, @as(u64, @intCast(n)));
                };
                if (jv.int(jv.get(v, "reminded"))) |d| b.reminded = d;
                continue;
            }
            const it = parseItem(b.gpa, v) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => continue,
            };
            if (b.find(it.id) != null) {
                it.destroy(b.gpa);
                continue;
            }
            b.items.append(b.gpa, it) catch |e| {
                it.destroy(b.gpa);
                return e;
            };
            b.next = @max(b.next, it.id + 1);
            // closed before its texts could go (a crash): they go now
            b.hide(it);
        }
    }

    /// Writes every kept item to a new file that then replaces the old one,
    /// after dropping closed items past 7 days and, past 500, the oldest
    /// closed.
    pub fn save(b: *Box, now_s: i64) !void {
        b.prune(now_s);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        try out.print(b.gpa, "{{\"next\":{d},\"reminded\":{d}}}\n", .{ b.next, b.reminded });
        for (b.items.items) |it| {
            try render(&out, b.gpa, it, true);
            try out.append(b.gpa, '\n');
        }
        // whole or not at all, even while another program holds it open
        try util.writeReplace(b.io, b.path, out.items);
        const cwd = Io.Dir.cwd();
        if (b.retire.len > 0) {
            cwd.deleteFile(b.io, b.retire) catch {};
            b.retire = "";
        }
    }

    fn prune(b: *Box, now_s: i64) void {
        var i: usize = 0;
        while (i < b.items.items.len) {
            const it = b.items.items[i];
            if (it.status != .open and closedAt(it) + keep_s <= now_s) {
                _ = b.items.orderedRemove(i);
                it.destroy(b.gpa);
            } else i += 1;
        }
        while (b.items.items.len > max_kept) {
            var oldest: ?usize = null;
            for (b.items.items, 0..) |it, j| {
                if (it.status == .open) continue;
                if (oldest == null or closedAt(it) < closedAt(b.items.items[oldest.?])) oldest = j;
            }
            const j = oldest orelse break;
            b.items.orderedRemove(j).destroy(b.gpa);
        }
    }

    /// A new item with the next id, its texts copied (title and body cut
    /// to their limits).
    pub fn add(b: *Box, n: New, now_s: i64, token: [16]u8) !*Item {
        const it = try b.gpa.create(Item);
        it.* = .{ .arena = .init(b.gpa), .id = b.next, .kind = "", .created = now_s, .token = token };
        errdefer it.destroy(b.gpa);
        const a = it.arena.allocator();
        it.kind = try a.dupe(u8, n.kind);
        it.expires = n.expires;
        it.by = try a.dupe(u8, n.by);
        it.agent = try dupeOpt(a, n.agent);
        it.rid = n.rid;
        it.run = try dupeOpt(a, n.run);
        it.conversation = try a.dupe(u8, n.conversation);
        it.waiter = try a.dupe(u8, n.waiter);
        it.app = try dupeOpt(a, n.app);
        it.title = try a.dupe(u8, util.cut(n.title, max_title));
        it.body = try a.dupe(u8, util.cut(n.body, max_body));
        const choices = try a.alloc(Choice, n.choices.len);
        for (n.choices, choices) |c, *d| d.* = .{ .key = try a.dupe(u8, c.key), .label = try a.dupe(u8, c.label) };
        it.choices = choices;
        it.text = n.text;
        it.draft = try dupeOpt(a, n.draft);
        if (n.post) |p| it.post = try copyPost(a, p);
        if (n.grant) |g| it.grant = .{ .tool = try a.dupe(u8, g.tool), .key = try a.dupe(u8, g.key), .who = try a.dupe(u8, g.who) };
        it.skip = try dupeOpt(a, n.skip);
        it.private = n.private;
        try b.items.append(b.gpa, it);
        b.next += 1;
        return it;
    }

    pub fn find(b: *const Box, id: u64) ?*Item {
        for (b.items.items) |it| if (it.id == id) return it;
        return null;
    }

    /// Open items a run waits on.
    pub fn runOpen(b: *const Box) usize {
        var n: usize = 0;
        for (b.items.items) |it| if (it.status == .open and it.isRun()) {
            n += 1;
        };
        return n;
    }

    /// Open items of other waiters.
    pub fn otherOpen(b: *const Box) usize {
        var n: usize = 0;
        for (b.items.items) |it| if (it.status == .open and !it.isRun()) {
            n += 1;
        };
        return n;
    }

    /// Closes `it`. A private item's texts go at once when harness waits on
    /// it; a run or workflow reads its answer first, then calls `hide`.
    pub fn close(b: *Box, it: *Item, status: Status, ans: Answer) void {
        const a = it.arena.allocator();
        it.status = status;
        it.answer = .{
            .key = dupeOpt(a, ans.key) catch null,
            .text = dupeOpt(a, ans.text) catch null,
            .at = ans.at,
            .via = ans.via,
        };
        it.settling = false;
        it.showing = false;
        it.early = null;
        if (std.mem.eql(u8, it.waiter, "harness")) b.hide(it);
    }

    /// A closed private item keeps only the size and keyed hash of its
    /// texts.
    pub fn hide(b: *Box, it: *Item) void {
        if (!it.private or it.status == .open or it.hidden != null) return;
        var h: Hidden = .{ .title = mark(b.key, it.title), .body = mark(b.key, it.body) };
        if (it.draft) |d| h.draft = mark(b.key, d);
        if (it.answer) |*an| if (an.text) |x| {
            h.answer = mark(b.key, x);
            an.text = null;
        };
        if (it.post) |*p| {
            h.post = mark(b.key, p.text);
            p.text = "";
        }
        it.title = "";
        it.body = "";
        it.draft = null;
        it.hidden = h;
    }

    /// The skipped item for this task and call: open, or kept after a
    /// dismiss (a repeat adds to its count, unposted).
    pub fn findSkip(b: *const Box, skip: []const u8) ?*Item {
        for (b.items.items) |it| {
            const key = it.skip orelse continue;
            if (!std.mem.eql(u8, key, skip)) continue;
            if (it.status == .open) return it;
            if (it.status == .answered) if (it.answer) |an| if (an.key) |k| if (std.mem.eql(u8, k, "dismiss")) return it;
        }
        return null;
    }
};

fn closedAt(it: *const Item) i64 {
    return if (it.answer) |an| an.at else it.created;
}

fn dupeOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

fn copyPost(a: std.mem.Allocator, p: Post) !Post {
    const links = try a.alloc([]const u8, p.links.len);
    for (p.links, links) |l, *d| d.* = try a.dupe(u8, l);
    return .{ .conversation = try a.dupe(u8, p.conversation), .text = try a.dupe(u8, p.text), .links = links, .of = try a.dupe(u8, p.of), .ran = p.ran, .tries = p.tries, .next = p.next };
}

fn mark(key: ?[32]u8, s: []const u8) Mark {
    var m: Mark = .{ .bytes = s.len };
    if (key) |k| {
        var d: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&d, s, &k);
        m.hmac = std.fmt.bytesToHex(d, .lower);
    }
    return m;
}

// ---- the file and format v1 ----

/// Appends `it` as one JSON object: format v1, and with `kept` the fields
/// kept in the file only.
pub fn render(out: *std.ArrayList(u8), gpa: std.mem.Allocator, it: *const Item, kept: bool) !void {
    var tb: [20]u8 = undefined;
    const h = it.hidden;
    try out.print(gpa, "{{\"v\":1,\"id\":{d},\"kind\":", .{it.id});
    try util.jsonString(out, gpa, it.kind);
    try out.print(gpa, ",\"status\":\"{s}\",\"created\":\"{s}\",\"expires\":", .{ @tagName(it.status), util.isoTime(&tb, it.created) });
    if (it.expires > 0) try out.print(gpa, "\"{s}\"", .{util.isoTime(&tb, it.expires)}) else try out.appendSlice(gpa, "null");
    try field(out, gpa, "by", it.by);
    try fieldOpt(out, gpa, "agent", it.agent);
    try out.appendSlice(gpa, ",\"rid\":");
    if (it.rid) |r| try out.print(gpa, "{d}", .{r}) else try out.appendSlice(gpa, "null");
    try fieldOpt(out, gpa, "run", it.run);
    try field(out, gpa, "conversation", it.conversation);
    try field(out, gpa, "waiter", it.waiter);
    try fieldOpt(out, gpa, "app", it.app);
    try out.appendSlice(gpa, ",\"title\":");
    try textOrMark(out, gpa, it.title, if (h) |x| x.title else null);
    try out.appendSlice(gpa, ",\"body\":");
    try textOrMark(out, gpa, it.body, if (h) |x| x.body else null);
    try out.appendSlice(gpa, ",\"choices\":[");
    for (it.choices, 0..) |c, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"key\":");
        try util.jsonString(out, gpa, c.key);
        try out.appendSlice(gpa, ",\"label\":");
        try util.jsonString(out, gpa, c.label);
        try out.append(gpa, '}');
    }
    try out.print(gpa, "],\"text\":\"{s}\",\"draft\":", .{@tagName(it.text)});
    if (h != null and h.?.draft != null) try writeMark(out, gpa, h.?.draft.?) else if (it.draft) |d| try util.jsonString(out, gpa, d) else try out.appendSlice(gpa, "null");
    try out.print(gpa, ",\"count\":{d},\"answer\":", .{it.count});
    if (it.answer) |an| {
        try out.appendSlice(gpa, "{\"key\":");
        if (an.key) |k| try util.jsonString(out, gpa, k) else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, ",\"text\":");
        if (h != null and h.?.answer != null) try writeMark(out, gpa, h.?.answer.?) else if (an.text) |x| try util.jsonString(out, gpa, x) else try out.appendSlice(gpa, "null");
        try out.print(gpa, ",\"at\":\"{s}\",\"via\":\"{s}\"}}", .{ util.isoTime(&tb, an.at), @tagName(an.via) });
    } else try out.appendSlice(gpa, "null");
    if (kept) {
        try out.print(gpa, ",\"token\":\"{s}\",\"shown\":[", .{&it.token});
        for (it.shown.items, 0..) |s, i| try out.print(gpa, "{s}{{\"chat\":{d},\"thread\":{d},\"message\":{d}{s}}}", .{ if (i > 0) "," else "", s.chat, s.thread, s.message, if (s.short) ",\"short\":true" else "" });
        try out.appendSlice(gpa, "],\"post\":");
        if (it.post) |p| {
            try out.appendSlice(gpa, "{\"conversation\":");
            try util.jsonString(out, gpa, p.conversation);
            try out.appendSlice(gpa, ",\"text\":");
            try textOrMark(out, gpa, p.text, if (h) |x| x.post else null);
            try out.appendSlice(gpa, ",\"links\":[");
            for (p.links, 0..) |l, i| {
                if (i > 0) try out.append(gpa, ',');
                try util.jsonString(out, gpa, l);
            }
            try out.appendSlice(gpa, "],\"of\":");
            try util.jsonString(out, gpa, p.of);
            try out.print(gpa, ",\"ran\":{d},\"tries\":{d},\"next\":{d}}}", .{ p.ran, p.tries, p.next });
        } else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, ",\"grant\":");
        if (it.grant) |g| {
            try out.appendSlice(gpa, "{\"tool\":");
            try util.jsonString(out, gpa, g.tool);
            try out.appendSlice(gpa, ",\"key\":");
            try util.jsonString(out, gpa, g.key);
            try out.appendSlice(gpa, ",\"who\":");
            try util.jsonString(out, gpa, g.who);
            try out.append(gpa, '}');
        } else try out.appendSlice(gpa, "null");
        try fieldOpt(out, gpa, "skip", it.skip);
        try out.print(gpa, ",\"private\":{s}", .{if (it.private) "true" else "false"});
    }
    try out.append(gpa, '}');
}

fn field(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime name: []const u8, s: []const u8) !void {
    try out.appendSlice(gpa, ",\"" ++ name ++ "\":");
    try util.jsonString(out, gpa, s);
}

fn fieldOpt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime name: []const u8, s: ?[]const u8) !void {
    try out.appendSlice(gpa, ",\"" ++ name ++ "\":");
    if (s) |x| try util.jsonString(out, gpa, x) else try out.appendSlice(gpa, "null");
}

fn textOrMark(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8, m: ?Mark) !void {
    if (m) |x| return writeMark(out, gpa, x);
    try util.jsonString(out, gpa, s);
}

fn writeMark(out: *std.ArrayList(u8), gpa: std.mem.Allocator, m: Mark) !void {
    if (m.hmac) |hx| return out.print(gpa, "{{\"bytes\":{d},\"hmac\":\"{s}\"}}", .{ m.bytes, &hx });
    try out.print(gpa, "{{\"bytes\":{d}}}", .{m.bytes});
}

fn parseMark(v: ?jv.Value) ?Mark {
    const x = v orelse return null;
    if (x != .object) return null;
    const n = jv.int(jv.get(x, "bytes")) orelse return null;
    var m: Mark = .{ .bytes = @intCast(@max(0, n)) };
    if (jv.str(jv.get(x, "hmac"))) |hx| if (hx.len == 64) {
        m.hmac = hx[0..64].*;
    };
    return m;
}

/// One item from its line, or an error when it does not read.
fn parseItem(gpa: std.mem.Allocator, v: jv.Value) !*Item {
    const id = jv.int(jv.get(v, "id")) orelse return error.BadItem;
    if (id <= 0) return error.BadItem;
    const kind = jv.str(jv.get(v, "kind")) orelse return error.BadItem;
    const status = std.meta.stringToEnum(Status, jv.str(jv.get(v, "status")) orelse "") orelse return error.BadItem;
    const created = util.parseIso(jv.str(jv.get(v, "created")) orelse "") orelse return error.BadItem;
    const token = jv.str(jv.get(v, "token")) orelse return error.BadItem;
    if (token.len != 16) return error.BadItem;
    const it = try gpa.create(Item);
    it.* = .{ .arena = .init(gpa), .id = @intCast(id), .kind = "", .status = status, .created = created, .token = token[0..16].* };
    errdefer it.destroy(gpa);
    const a = it.arena.allocator();
    it.kind = try a.dupe(u8, kind);
    it.expires = util.parseIso(jv.str(jv.get(v, "expires")) orelse "") orelse 0;
    it.by = try a.dupe(u8, jv.str(jv.get(v, "by")) orelse "owner");
    it.agent = try dupeOpt(a, jv.str(jv.get(v, "agent")));
    if (jv.int(jv.get(v, "rid"))) |r| if (r > 0) {
        it.rid = @intCast(r);
    };
    it.run = try dupeOpt(a, jv.str(jv.get(v, "run")));
    it.conversation = try a.dupe(u8, jv.str(jv.get(v, "conversation")) orelse "main");
    it.waiter = try a.dupe(u8, jv.str(jv.get(v, "waiter")) orelse "harness");
    it.app = try dupeOpt(a, jv.str(jv.get(v, "app")));
    var hidden: Hidden = .{ .title = .{ .bytes = 0 }, .body = .{ .bytes = 0 } };
    var any_mark = false;
    if (parseMark(jv.get(v, "title"))) |m| {
        hidden.title = m;
        any_mark = true;
    } else it.title = try a.dupe(u8, jv.str(jv.get(v, "title")) orelse "");
    if (parseMark(jv.get(v, "body"))) |m| {
        hidden.body = m;
        any_mark = true;
    } else it.body = try a.dupe(u8, jv.str(jv.get(v, "body")) orelse "");
    var choices: std.ArrayList(Choice) = .empty;
    for (jv.arr(jv.get(v, "choices")) orelse &.{}) |c| {
        const key = jv.str(jv.get(c, "key")) orelse continue;
        try choices.append(a, .{ .key = try a.dupe(u8, key), .label = try a.dupe(u8, jv.str(jv.get(c, "label")) orelse key) });
    }
    it.choices = choices.items;
    it.text = std.meta.stringToEnum(TextKind, jv.str(jv.get(v, "text")) orelse "none") orelse .none;
    if (parseMark(jv.get(v, "draft"))) |m| {
        hidden.draft = m;
        any_mark = true;
    } else it.draft = try dupeOpt(a, jv.str(jv.get(v, "draft")));
    it.count = @intCast(std.math.clamp(jv.int(jv.get(v, "count")) orelse 1, 1, std.math.maxInt(u32)));
    if (jv.get(v, "answer")) |an| {
        const via = std.meta.stringToEnum(Via, jv.str(jv.get(an, "via")) orelse "") orelse .harness;
        var ans: Answer = .{ .key = try dupeOpt(a, jv.str(jv.get(an, "key"))), .at = util.parseIso(jv.str(jv.get(an, "at")) orelse "") orelse created, .via = via };
        if (parseMark(jv.get(an, "text"))) |m| {
            hidden.answer = m;
            any_mark = true;
        } else ans.text = try dupeOpt(a, jv.str(jv.get(an, "text")));
        it.answer = ans;
    }
    for (jv.arr(jv.get(v, "shown")) orelse &.{}) |s| {
        if (it.shown.items.len == max_shown) break;
        try it.shown.append(a, .{ .chat = jv.int(jv.get(s, "chat")) orelse 0, .thread = jv.int(jv.get(s, "thread")) orelse 0, .message = jv.int(jv.get(s, "message")) orelse continue, .short = jv.boolean(jv.get(s, "short")) orelse false });
    }
    if (jv.get(v, "post")) |p| {
        var links: std.ArrayList([]const u8) = .empty;
        for (jv.arr(jv.get(p, "links")) orelse &.{}) |l| if (jv.str(l)) |x| try links.append(a, try a.dupe(u8, x));
        var post: Post = .{
            .conversation = try a.dupe(u8, jv.str(jv.get(p, "conversation")) orelse "main"),
            .text = "",
            .links = links.items,
            .of = try a.dupe(u8, jv.str(jv.get(p, "of")) orelse ""),
            .ran = jv.int(jv.get(p, "ran")) orelse 0,
            .tries = @intCast(std.math.clamp(jv.int(jv.get(p, "tries")) orelse 0, 0, std.math.maxInt(u32))),
            .next = jv.int(jv.get(p, "next")) orelse 0,
        };
        if (parseMark(jv.get(p, "text"))) |m| {
            hidden.post = m;
            any_mark = true;
        } else post.text = try a.dupe(u8, jv.str(jv.get(p, "text")) orelse "");
        it.post = post;
    }
    if (jv.get(v, "grant")) |g| {
        const tool = jv.str(jv.get(g, "tool"));
        const key = jv.str(jv.get(g, "key"));
        if (tool != null and key != null)
            it.grant = .{ .tool = try a.dupe(u8, tool.?), .key = try a.dupe(u8, key.?), .who = try a.dupe(u8, jv.str(jv.get(g, "who")) orelse "") };
    }
    it.skip = try dupeOpt(a, jv.str(jv.get(v, "skip")));
    it.private = jv.boolean(jv.get(v, "private")) orelse false;
    if (any_mark) it.hidden = hidden;
    return it;
}

// ---- what the owner reads ----

/// Kinds whose message is their text alone, under no head: a routine's
/// one-tap question (`confirm`, an approve step with yes), setup's
/// questions (`setup`) and the routines offered (`routine`). Their buttons
/// name what they do.
pub fn plain(kind: []const u8) bool {
    for ([_][]const u8{ "confirm", "setup", "routine" }) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

/// The head of an item's message: "Allow this? [41]", "Question [44]" …;
/// "" for a plain kind.
fn headOf(a: std.mem.Allocator, it: *const Item) ![]const u8 {
    const eql = std.mem.eql;
    if (plain(it.kind)) return "";
    if (eql(u8, it.kind, "approval")) return std.fmt.allocPrint(a, "Allow this? [{d}]", .{it.id});
    if (eql(u8, it.kind, "question")) return std.fmt.allocPrint(a, "Question [{d}]", .{it.id});
    if (eql(u8, it.kind, "draft")) return std.fmt.allocPrint(a, "Draft to review [{d}]", .{it.id});
    if (eql(u8, it.kind, "skipped")) return std.fmt.allocPrint(a, "Skipped [{d}]: {s} could not make this call without you:", .{ it.id, it.run orelse "a run" });
    if (eql(u8, it.kind, "delivery")) return std.fmt.allocPrint(a, "Not delivered [{d}] to {s}:", .{ it.id, if (it.post) |p| p.conversation else it.conversation });
    const k = try a.dupe(u8, it.kind);
    if (k.len > 0) k[0] = std.ascii.toUpper(k[0]);
    return std.fmt.allocPrint(a, "{s} [{d}]", .{ k, it.id });
}

fn hintOf(it: *const Item) []const u8 {
    return switch (it.text) {
        .none => "",
        .reason => "(Reply with text to deny it and say why.)",
        .answer => "(Reply with text to answer.)",
        .draft => "(Reply with text to use your own version instead.)",
    };
}

/// The item as its messages: each with its head ("(2/3)" when there are
/// several), the hint for a text answer on the last, which gets the
/// buttons. Each leaves room for the outcome added when the item closes.
pub fn messageParts(a: std.mem.Allocator, it: *const Item) ![]const []const u8 {
    const head = try headOf(a, it);
    const hint = hintOf(it);
    const body = if (it.draft) |d| try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ it.body, d }) else it.body;
    const room = message_max -| (head.len + 16 + hint.len + 1 + outcome_room);
    var pieces: std.ArrayList([]const u8) = .empty;
    var rest = body;
    while (rest.len > room) {
        var n = util.cut(rest, room).len;
        // after a line break near the end, where there is one
        const from = room - room / 5;
        if (n > from) if (std.mem.lastIndexOfScalar(u8, rest[from..n], '\n')) |k| {
            n = from + k + 1;
        };
        try pieces.append(a, rest[0..n]);
        rest = rest[n..];
    }
    try pieces.append(a, rest);
    const out = try a.alloc([]const u8, pieces.items.len);
    for (pieces.items, out, 1..) |p, *o, i| {
        const last = i == pieces.items.len;
        const tail: []const u8 = if (last and hint.len > 0) try std.fmt.allocPrint(a, "\n{s}", .{hint}) else "";
        if (head.len == 0) {
            // a plain kind: its text, counted when it takes several
            const counted = if (pieces.items.len > 1) try std.fmt.allocPrint(a, "({d}/{d})\n", .{ i, pieces.items.len }) else "";
            o.* = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ counted, p, tail });
            continue;
        }
        const counted = if (pieces.items.len > 1) try std.fmt.allocPrint(a, " ({d}/{d})", .{ i, pieces.items.len }) else "";
        o.* = try std.fmt.allocPrint(a, "{s}{s}\n{s}{s}", .{ head, counted, p, tail });
    }
    return out;
}

/// "14:03", the owner's time.
fn clock(buf: *[5]u8, at: i64, utc_offset: i32) []const u8 {
    const m = @divFloor(@mod(at + @as(i64, utc_offset) * 60, 86400), 60);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(m, 60))), @as(u64, @intCast(@mod(m, 60))) }) catch "--:--";
}

/// What "this task" is for a skipped item's grant: task, trigger or workflow.
fn whatRan(it: *const Item) []const u8 {
    if (std.mem.startsWith(u8, it.by, "trigger:")) return "trigger";
    if (std.mem.startsWith(u8, it.by, "workflow:")) return "workflow";
    return "task";
}

/// How an item closed, in words starting small ("allowed once, 14:03");
/// a message's outcome line starts it with a capital.
pub fn outcome(a: std.mem.Allocator, it: *const Item, utc_offset: i32) ![]const u8 {
    const ans = it.answer orelse return "open";
    var cb: [5]u8 = undefined;
    const hm = clock(&cb, ans.at, utc_offset);
    const eql = std.mem.eql;
    const key = ans.key orelse "";
    const has_text = if (ans.text) |x| x.len > 0 else (it.hidden != null and it.hidden.?.answer != null);
    return switch (it.status) {
        .open => "open",
        .expired => if (eql(u8, it.kind, "approval")) "no answer in time; not allowed." else "no answer in time.",
        .void => std.fmt.allocPrint(a, "void: {s}.", .{ans.text orelse "it could not be shown"}),
        .withdrawn => std.fmt.allocPrint(a, "withdrawn: {s}.", .{ans.text orelse "its run stopped"}),
        .done => std.fmt.allocPrint(a, "delivered, {s}", .{hm}),
        .answered => blk: {
            if (eql(u8, it.kind, "approval")) {
                if (eql(u8, key, "once")) break :blk std.fmt.allocPrint(a, "allowed once, {s}", .{hm});
                if (eql(u8, key, "day")) break :blk std.fmt.allocPrint(a, "allowed for 24 h, {s}", .{hm});
                break :blk std.fmt.allocPrint(a, "denied{s}, {s}", .{ if (has_text) " with your reason" else "", hm });
            }
            if (eql(u8, key, "text")) break :blk std.fmt.allocPrint(a, "answered in words, {s}", .{hm});
            // nobody on it in time: harness tapped its yes itself
            if (ans.via == .fallback) if (it.choiceLabel(key)) |label| {
                const said = try a.dupe(u8, label);
                if (said.len > 0) said[0] = std.ascii.toLower(said[0]);
                break :blk std.fmt.allocPrint(a, "{s} (no one answered: harness did it), {s}", .{ said, hm });
            };
            // a plain kind's outcome is its button's own words
            if (plain(it.kind)) if (it.choiceLabel(key)) |label| {
                const said = try a.dupe(u8, label);
                if (said.len > 0) said[0] = std.ascii.toLower(said[0]);
                break :blk std.fmt.allocPrint(a, "{s}, {s}", .{ said, hm });
            };
            if (eql(u8, key, "use")) break :blk std.fmt.allocPrint(a, "{s}, {s}", .{ if (has_text) "replaced with your version" else "used as it is", hm });
            if (eql(u8, key, "drop")) break :blk std.fmt.allocPrint(a, "dropped, {s}", .{hm});
            if (eql(u8, key, "dismiss")) break :blk std.fmt.allocPrint(a, "dismissed, {s}", .{hm});
            if (eql(u8, key, "allow")) break :blk std.fmt.allocPrint(a, "allowed for this {s} for 30 days, {s}", .{ whatRan(it), hm });
            if (eql(u8, key, "again")) break :blk std.fmt.allocPrint(a, "sent again, {s}", .{hm});
            if (eql(u8, key, "resume")) break :blk std.fmt.allocPrint(a, "resumed, {s}", .{hm});
            if (eql(u8, key, "remove")) break :blk std.fmt.allocPrint(a, "removed, {s}", .{hm});
            break :blk std.fmt.allocPrint(a, "answered: {s}, {s}", .{ it.choiceLabel(key) orelse key, hm });
        },
    };
}

/// What a press on a closed item is told.
pub fn already(a: std.mem.Allocator, it: *const Item, utc_offset: i32) ![]const u8 {
    const ans = it.answer orelse return "It is still open.";
    var cb: [5]u8 = undefined;
    return switch (it.status) {
        .open => "It is still open.",
        .answered => std.fmt.allocPrint(a, "Already answered: {s}.", .{try outcome(a, it, utc_offset)}),
        .expired => "Already closed: no answer in time.",
        .void => std.fmt.allocPrint(a, "Already closed: void, {s}.", .{ans.text orelse "it could not be shown"}),
        .withdrawn => std.fmt.allocPrint(a, "Already closed: withdrawn, {s}.", .{ans.text orelse "its run stopped"}),
        .done => std.fmt.allocPrint(a, "Already closed: delivered, {s}.", .{clock(&cb, ans.at, utc_offset)}),
    };
}

/// "[41] approval, research, 12 min: shell: git push origin main".
pub fn listLine(a: std.mem.Allocator, it: *const Item, now_s: i64) ![]const u8 {
    const age = @max(0, now_s - it.created);
    var ab: [24]u8 = undefined;
    const ago = if (age < 60)
        "just now"
    else if (age < 3600)
        std.fmt.bufPrint(&ab, "{d} min", .{@divFloor(age, 60)}) catch ""
    else if (age < 86400)
        std.fmt.bufPrint(&ab, "{d} h", .{@divFloor(age, 3600)}) catch ""
    else
        std.fmt.bufPrint(&ab, "{d} d", .{@divFloor(age, 86400)}) catch "";
    // one line: the title's breaks and control bytes shown as spaces
    const title = if (it.hidden != null) try a.dupe(u8, "(private)") else try a.dupe(u8, it.title);
    for (title) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
        ch.* = ' ';
    };
    return std.fmt.allocPrint(a, "[{d}] {s}, {s}, {s}: {s}", .{ it.id, it.kind, it.conversation, ago, title });
}

/// A press of an item's button: `i<id>-<token>:<key>`.
pub const Press = struct {
    id: u64,
    token: []const u8,
    key: []const u8,

    pub fn parse(data: []const u8) ?Press {
        if (data.len < 4 or data[0] != 'i') return null;
        const dash = std.mem.indexOfScalar(u8, data, '-') orelse return null;
        const colon = std.mem.indexOfScalarPos(u8, data, dash, ':') orelse return null;
        const id = std.fmt.parseInt(u64, data[1..dash], 10) catch return null;
        const token = data[dash + 1 .. colon];
        const key = data[colon + 1 ..];
        if (token.len != 16 or key.len == 0) return null;
        return .{ .id = id, .token = token, .key = key };
    }
};

/// A button's data for `key` of `it` (at most 64 bytes, Telegram's limit).
pub fn buttonData(buf: *[64]u8, it: *const Item, key: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "i{d}-{s}:{s}", .{ it.id, &it.token, key }) catch "";
}

// ---- tests ----

const t = std.testing;

/// A box on `path`, loaded (no state/approvals).
fn testBox(path: []const u8) !Box {
    var b: Box = .init(t.allocator, t.io, path);
    errdefer b.deinit();
    try b.load("");
    return b;
}

const test_token: [16]u8 = "0123456789abcdef".*;
/// 2026-11-22T14:03:00Z
const test_now: i64 = 1795356180;

fn approval(body: []const u8) New {
    return .{
        .kind = "approval",
        .agent = "main",
        .rid = 18234,
        .run = "chat",
        .conversation = "research",
        .waiter = "run",
        .title = body,
        .body = body,
        .choices = &.{ .{ .key = "once", .label = "Allow once" }, .{ .key = "day", .label = "Allow 24 h" }, .{ .key = "deny", .label = "Deny" } },
        .text = .reason,
        .expires = test_now + 600,
    };
}

test "items_are_written_whole_and_read_back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" });
    {
        var b = try testBox(path);
        defer b.deinit();
        var n = approval("shell: git push origin main");
        n.post = .{ .conversation = "main", .text = "hello", .links = &.{"https://z.org/1"}, .of = "task:check", .ran = 5, .tries = 2, .next = test_now + 300 };
        n.grant = .{ .tool = "shell@host", .key = "df -h", .who = "schedule:disk" };
        n.skip = "schedule:disk\tshell@host\tdf -h";
        const it = try b.add(n, test_now, test_token);
        try it.shown.append(it.arena.allocator(), .{ .chat = 42, .thread = 5012, .message = 7 });
        try b.save(test_now);
    }
    const text = try tmp.dir.readFileAlloc(t.io, "inbox", a, .unlimited);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try t.expectEqualStrings("{\"next\":2,\"reminded\":0}", lines.next().?);
    try t.expect(std.mem.startsWith(u8, lines.next().?, "{\"v\":1,\"id\":1,\"kind\":\"approval\",\"status\":\"open\",\"created\":\"2026-11-22T14:03:00Z\",\"expires\":\"2026-11-22T14:13:00Z\",\"by\":\"owner\",\"agent\":\"main\",\"rid\":18234,\"run\":\"chat\",\"conversation\":\"research\",\"waiter\":\"run\",\"app\":null,\"title\":\"shell: git push origin main\""));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "inbox.tmp", .{}));
    var b = try testBox(path);
    defer b.deinit();
    const it = b.find(1).?;
    try t.expectEqualStrings("approval", it.kind);
    try t.expectEqual(.open, it.status);
    try t.expectEqual(test_now, it.created);
    try t.expectEqual(test_now + 600, it.expires);
    try t.expectEqualStrings("owner", it.by);
    try t.expectEqualStrings("main", it.agent.?);
    try t.expectEqual(18234, it.rid.?);
    try t.expectEqualStrings("chat", it.run.?);
    try t.expectEqualStrings("research", it.conversation);
    try t.expectEqualStrings("run", it.waiter);
    try t.expectEqual(null, it.app);
    try t.expectEqualStrings("shell: git push origin main", it.body);
    try t.expectEqual(3, it.choices.len);
    try t.expectEqualStrings("day", it.choices[1].key);
    try t.expectEqualStrings("Allow 24 h", it.choices[1].label);
    try t.expectEqual(.reason, it.text);
    try t.expectEqual(1, it.count);
    try t.expectEqualStrings(&test_token, &it.token);
    try t.expectEqual(1, it.shown.items.len);
    try t.expectEqual(5012, it.shown.items[0].thread);
    try t.expectEqual(7, it.shown.items[0].message);
    const p = it.post.?;
    try t.expectEqualStrings("hello", p.text);
    try t.expectEqualStrings("https://z.org/1", p.links[0]);
    try t.expectEqualStrings("task:check", p.of);
    try t.expectEqual(5, p.ran);
    try t.expectEqual(2, p.tries);
    try t.expectEqual(test_now + 300, p.next);
    try t.expectEqualStrings("schedule:disk", it.grant.?.who);
    try t.expectEqualStrings("shell@host", it.grant.?.tool);
    try t.expectEqualStrings("schedule:disk\tshell@host\tdf -h", it.skip.?);
    try t.expectEqual(2, b.next);
    // format v1, as apps get it: without the fields kept in the file only
    var out: std.ArrayList(u8) = .empty;
    try render(&out, a, it, false);
    try t.expect(std.mem.startsWith(u8, out.items, "{\"v\":1,\"id\":1,"));
    for ([_][]const u8{ "\"token\"", "\"shown\"", "\"post\"", "\"grant\"", "\"skip\"", "\"private\"" }) |k| try t.expect(std.mem.indexOf(u8, out.items, k) == null);
    try t.expect(std.mem.endsWith(u8, out.items, "\"text\":\"reason\",\"draft\":null,\"count\":1,\"answer\":null}"));
}

test "ids_start_after_state_approvals_and_are_never_reused" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "inbox" });
    const approvals = try std.fs.path.join(a, &.{ dir, "approvals" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "approvals", .data = "40\n" });
    {
        var b: Box = .init(t.allocator, t.io, path);
        defer b.deinit();
        try b.load(approvals);
        try t.expectEqual(41, (try b.add(approval("shell: ls"), test_now, test_token)).id);
        try b.save(test_now);
    }
    // retired once state/inbox holds the numbers
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "approvals", .{}));
    var b: Box = .init(t.allocator, t.io, path);
    defer b.deinit();
    try b.load(approvals);
    const second = try b.add(approval("shell: pwd"), test_now, test_token);
    try t.expectEqual(42, second.id);
    // the first closed 8 days ago: gone at the next save, its number not reused
    b.close(b.find(41).?, .answered, .{ .key = "once", .at = test_now - 8 * 86400, .via = .telegram });
    try b.save(test_now);
    try t.expectEqual(null, b.find(41));
    var c = try testBox(path);
    defer c.deinit();
    try t.expectEqual(43, (try c.add(approval("shell: id"), test_now, test_token)).id);
}

test "closed_items_are_kept_7_days_and_at_most_500" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" });
    var b = try testBox(path);
    defer b.deinit();
    const open = try b.add(approval("shell: still waiting"), test_now - 100_000, test_token);
    for (0..501) |i| {
        const it = try b.add(approval("shell: ls"), test_now - 1000, test_token);
        // the first made closed longest ago
        b.close(it, .answered, .{ .key = "deny", .at = test_now - 1000 + @as(i64, @intCast(i)), .via = .telegram });
    }
    try b.save(test_now);
    try t.expectEqual(500, b.items.items.len);
    try t.expect(b.find(open.id) != null);
    try t.expectEqual(null, b.find(open.id + 1));
    try t.expectEqual(null, b.find(open.id + 2));
    try t.expect(b.find(open.id + 3) != null);
    var c = try testBox(path);
    defer c.deinit();
    try t.expectEqual(500, c.items.items.len);
}

test "a_private_item_keeps_its_text_until_it_closes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    for ([_]bool{ true, false }) |keyed| {
        const path = try std.fs.path.join(a, &.{ dir, if (keyed) "keyed" else "plain" });
        var b = try testBox(path);
        defer b.deinit();
        if (keyed) b.key = @splat(7);
        var n: New = .{ .kind = "question", .title = "diary words", .body = "diary words", .waiter = "harness", .text = .answer, .private = true };
        n.choices = &.{};
        const it = try b.add(n, test_now, test_token);
        try b.save(test_now);
        try t.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(t.io, std.fs.path.basename(path), a, .unlimited), "diary words") != null);
        b.close(it, .answered, .{ .key = "text", .text = "my secret answer", .at = test_now, .via = .telegram });
        try b.save(test_now);
        const text = try tmp.dir.readFileAlloc(t.io, std.fs.path.basename(path), a, .unlimited);
        try t.expect(std.mem.indexOf(u8, text, "diary words") == null);
        try t.expect(std.mem.indexOf(u8, text, "my secret answer") == null);
        if (keyed) {
            try t.expect(std.mem.indexOf(u8, text, "\"title\":{\"bytes\":11,\"hmac\":\"") != null);
            try t.expect(std.mem.indexOf(u8, text, "\"text\":{\"bytes\":16,\"hmac\":\"") != null);
        } else try t.expect(std.mem.indexOf(u8, text, "\"title\":{\"bytes\":11}") != null);
        // read back, it stays so
        var c = try testBox(path);
        defer c.deinit();
        var out: std.ArrayList(u8) = .empty;
        try render(&out, a, c.find(1).?, false);
        try t.expect(std.mem.indexOf(u8, out.items, "diary words") == null);
        try t.expect(std.mem.indexOf(u8, out.items, "\"title\":{\"bytes\":11") != null);
    }
}

test "a_line_that_does_not_read_is_left_out" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" });
    {
        var b = try testBox(path);
        defer b.deinit();
        _ = try b.add(approval("shell: one"), test_now, test_token);
        _ = try b.add(approval("shell: two"), test_now, test_token);
        try b.save(test_now);
    }
    // a damaged middle and a first line that says less than the items do
    const text = try tmp.dir.readFileAlloc(t.io, "inbox", a, .unlimited);
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    const one = lines.next().?;
    const two = lines.next().?;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "inbox", .data = try std.fmt.allocPrint(a, "{{\"next\":1,\"reminded\":0}}\n{s}\nnot json at all\n{{\"v\":1,\"id\":9}}\n{s}\n", .{ one, two }) });
    var b = try testBox(path);
    defer b.deinit();
    try t.expectEqualStrings("shell: one", b.find(1).?.body);
    try t.expectEqualStrings("shell: two", b.find(2).?.body);
    try t.expectEqual(null, b.find(9));
    try t.expectEqual(2, b.items.items.len);
    try t.expect(b.next >= 3);
}

test "texts_with_quotes_breaks_and_control_bytes_round_trip" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" });
    const odd = "say \"hi\" \\ now\nnext\x01 end\ttab";
    {
        var b = try testBox(path);
        defer b.deinit();
        var n = approval(odd);
        n.choices = &.{ .{ .key = "1", .label = odd }, .{ .key = "2", .label = "plain" } };
        n.draft = odd;
        _ = try b.add(n, test_now, test_token);
        try b.save(test_now);
    }
    var b = try testBox(path);
    defer b.deinit();
    const it = b.find(1).?;
    try t.expectEqualStrings(odd, it.title);
    try t.expectEqualStrings(odd, it.body);
    try t.expectEqualStrings(odd, it.choices[0].label);
    try t.expectEqualStrings(odd, it.draft.?);
}

test "messages_outcomes_and_lines_read_as_the_spec_writes_them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" });
    var b = try testBox(path);
    defer b.deinit();
    b.next = 41;
    const it = try b.add(approval("shell: git push origin main"), test_now, test_token);
    const one = try messageParts(a, it);
    try t.expectEqual(1, one.len);
    try t.expectEqualStrings("Allow this? [41]\nshell: git push origin main\n(Reply with text to deny it and say why.)", one[0]);
    try t.expectEqualStrings("[41] approval, research, 12 min: shell: git push origin main", try listLine(a, it, test_now + 12 * 60));
    // a long one: in parts, each with its head, the hint on the last, room for the outcome
    var long: std.ArrayList(u8) = .empty;
    for (0..150) |i| try long.print(a, "line {d:0>3} {s}\n", .{ i, &@as([50]u8, @splat('y')) });
    const big = try b.add(approval(long.items), test_now, test_token);
    const parts = try messageParts(a, big);
    try t.expectEqual(3, parts.len);
    var whole: std.ArrayList(u8) = .empty;
    for (parts, 1..) |p, i| {
        const head = try std.fmt.allocPrint(a, "Allow this? [42] ({d}/3)\n", .{i});
        try t.expect(std.mem.startsWith(u8, p, head));
        try t.expect(p.len <= 4096);
        var rest = p[head.len..];
        if (i == 3) {
            const hint = "\n(Reply with text to deny it and say why.)";
            try t.expect(std.mem.endsWith(u8, rest, hint));
            rest = rest[0 .. rest.len - hint.len];
            try t.expect(p.len + 1 + 80 <= 4096);
        }
        try whole.appendSlice(a, rest);
    }
    try t.expectEqualStrings(long.items, whole.items);
    // the outcome, and what a later press is told
    b.close(it, .answered, .{ .key = "once", .at = test_now, .via = .telegram });
    try t.expectEqualStrings("allowed once, 14:03", try outcome(a, it, 0));
    try t.expectEqualStrings("allowed once, 15:03", try outcome(a, it, 60));
    try t.expectEqualStrings("Already answered: allowed once, 14:03.", try already(a, it, 0));
    b.close(big, .expired, .{ .at = test_now, .via = .harness });
    try t.expectEqualStrings("no answer in time; not allowed.", try outcome(a, big, 0));
    try t.expectEqualStrings("Already closed: no answer in time.", try already(a, big, 0));
    // the other kinds' heads
    var q: New = .{ .kind = "question", .title = "Which account?", .body = "Which account?", .text = .answer, .run = "task btc-watch" };
    q.choices = &.{ .{ .key = "1", .label = "Personal" }, .{ .key = "2", .label = "Work" } };
    try t.expect(std.mem.startsWith(u8, (try messageParts(a, try b.add(q, test_now, test_token)))[0], "Question [43]\nWhich account?\n(Reply with text to answer.)"));
    q.kind = "skipped";
    q.text = .none;
    try t.expect(std.mem.startsWith(u8, (try messageParts(a, try b.add(q, test_now, test_token)))[0], "Skipped [44]: task btc-watch could not make this call without you:\nWhich account?"));
    q.kind = "draft";
    q.text = .draft;
    q.draft = "Hi Anna, see you at 7.";
    try t.expectEqualStrings("Draft to review [45]\nWhich account?\n\nHi Anna, see you at 7.\n(Reply with text to use your own version instead.)", (try messageParts(a, try b.add(q, test_now, test_token)))[0]);
}

test "press_data_carries_id_token_and_key" {
    const p = Press.parse("i41-0123456789abcdef:once").?;
    try t.expectEqual(41, p.id);
    try t.expectEqualStrings("0123456789abcdef", p.token);
    try t.expectEqualStrings("once", p.key);
    for ([_][]const u8{ "a41-0123456789abcdef:once", "i41:once", "i41-short:once", "i-0123456789abcdef:once", "i41-0123456789abcdef:" }) |bad|
        try t.expectEqual(null, Press.parse(bad));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try testBox(try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" }));
    defer b.deinit();
    b.next = 1 << 63;
    const it = try b.add(approval("shell: ls"), test_now, test_token);
    var buf: [64]u8 = undefined;
    const data = buttonData(&buf, it, "dismiss");
    try t.expectEqualStrings("i9223372036854775808-0123456789abcdef:dismiss", data);
    try t.expect(data.len <= 64);
    try t.expectEqual(it.id, Press.parse(data).?.id);
}

test "plain_kinds_show_their_text_alone" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try testBox(try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" }));
    defer b.deinit();
    b.next = 50;
    // a routine's one-tap question: its text and its buttons, no head
    const c = try b.add(.{ .kind = "confirm", .title = "Water under the kitchen sink.", .body = "Water under the kitchen sink.", .choices = &.{ .{ .key = "approve", .label = "Close the water main" }, .{ .key = "deny", .label = "Ignore" } } }, test_now, test_token);
    try t.expectEqualStrings("Water under the kitchen sink.", (try messageParts(a, c))[0]);
    // its outcome is the button's own words
    b.close(c, .answered, .{ .key = "approve", .at = test_now, .via = .telegram });
    try t.expectEqualStrings("close the water main, 14:03", try outcome(a, c, 0));
    try t.expectEqualStrings("Already answered: close the water main, 14:03.", try already(a, c, 0));
    // setup's questions and the routines' offers too
    for ([_][]const u8{ "setup", "routine" }) |kind| {
        const s = try b.add(.{ .kind = kind, .title = "I found 15 devices in 5 rooms.", .body = "I found 15 devices in 5 rooms.\nI'll switch lights.", .choices = &.{ .{ .key = "yes", .label = "Looks right" }, .{ .key = "change", .label = "Change it" } } }, test_now, test_token);
        try t.expectEqualStrings("I found 15 devices in 5 rooms.\nI'll switch lights.", (try messageParts(a, s))[0]);
        // /inbox still lists it with its number
        try t.expect(std.mem.startsWith(u8, try listLine(a, s, test_now), try std.fmt.allocPrint(a, "[{d}] {s}, main, just now: I found 15 devices", .{ s.id, kind })));
    }
    // a long one: counted parts, still no head
    var long: std.ArrayList(u8) = .empty;
    for (0..150) |i| try long.print(a, "line {d:0>3} {s}\n", .{ i, &@as([50]u8, @splat('y')) });
    const big = try b.add(.{ .kind = "setup", .title = "long", .body = long.items }, test_now, test_token);
    const parts = try messageParts(a, big);
    try t.expectEqual(3, parts.len);
    try t.expect(std.mem.startsWith(u8, parts[0], "(1/3)\nline 000"));
    // a question keeps its head
    const q = try b.add(.{ .kind = "question", .title = "Which?", .body = "Which?" }, test_now, test_token);
    try t.expect(std.mem.startsWith(u8, (try messageParts(a, q))[0], "Question ["));
}
