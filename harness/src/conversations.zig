//! The conversations: where the owner and the agent exchange messages. The
//! private Telegram chat (`main`), its topics (one per subject), groups the
//! owner registered (others read them: post-only), and the terminal. Kept
//! in `state/conversations`, one JSON object a line, written whole (a
//! temporary file, then a rename) before harness acts on a change.
const std = @import("std");
const jv = @import("jv.zig");
const util = @import("util.zig");
const agents = @import("agents.zig");
const Io = std.Io;

pub const max_name = 32;

/// The words the conversation commands take: never a conversation's name.
const command_words = [_][]const u8{ "new", "rename", "rm", "add" };

/// a-z, 0-9, `-` and `_`, up to 32, and none of the commands' words.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    for (command_words) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

/// Who reads a conversation: only the owner (the private chat, its topics,
/// the terminal) or others too (a group).
pub const Audience = enum { own, shared };

/// Where it is (`channel` in the file).
pub const Kind = enum { telegram, terminal };

pub const Entry = struct {
    name: []u8,
    channel: Kind,
    chat: i64,
    /// The topic's thread; 0: the chat itself.
    thread: i64,
    audience: Audience,
    /// /private on: nothing from it goes to memory, its runs' log lines
    /// keep only sizes and keyed hashes. Read by runs while they go.
    private: std.atomic.Value(bool),
    created: i64,
    /// The definition that answers here (`/agent NAME`): `main` unless the
    /// owner picked another; in the file only then.
    agent: []u8,
    /// A topic's title as Telegram shows it ("Mail and diary"); "": its name.
    title: []u8 = &.{},
    /// What the topic is about (the owner's or setup's words, put in its
    /// turns' context); "": nothing said.
    focus: []u8 = &.{},
    /// The butler's subject it files (topics.zig); "": none.
    subject: []u8 = &.{},
    /// Its pinned card's message; 0: none.
    card: i64 = 0,

    // in memory only

    /// When its card was last edited (at most once a minute).
    card_s: i64 = 0,
    /// The card's text as last posted or edited (its SHA-256).
    card_hash: [32]u8 = @splat(0),
    /// The last three lines posted here (a topic that files a subject),
    /// for its card's Lately; oldest first.
    lately: [3]Late = @splat(.{}),
    lately_n: u8 = 0,


    /// Telegram refused its topic: its posts go to main with its name in
    /// front; `told` once the owner heard why.
    refused: bool = false,
    told: bool = false,
    /// Turns of a definition's context here dropped to make room for
    /// others' (its model is told when it comes back).
    dropped: std.ArrayList(Dropped) = .empty,
    /// When a message last came from it or a post went to it; 0: not since
    /// harness started.
    used_s: i64 = 0,
    /// When the posts of the last hour were sent (`sends_per_hour`).
    posts: std.ArrayList(i64) = .empty,
    /// Posts not sent for the hourly limit since the owner was last told,
    /// and when that was.
    held: u32 = 0,
    told_held_s: i64 = 0,

    pub const Dropped = struct { agent: []u8, turns: usize };

    pub const Late = struct { buf: [160]u8 = undefined, len: u8 = 0, at: i64 = 0 };

    /// Notes `text`'s first line as posted here at `at`.
    pub fn noteLately(e: *Entry, text: []const u8, at: i64) void {
        const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
        if (line.len == 0) return;
        if (e.lately_n == e.lately.len) {
            e.lately[0] = e.lately[1];
            e.lately[1] = e.lately[2];
            e.lately_n -= 1;
        }
        const cut = util.cut(line, 160);
        var l: Late = .{ .len = @intCast(cut.len), .at = at };
        @memcpy(l.buf[0..cut.len], cut);
        e.lately[e.lately_n] = l;
        e.lately_n += 1;
    }

    pub fn isPrivate(e: *const Entry) bool {
        return e.private.load(.acquire);
    }

    /// Turns of definition `agent`'s context here that were dropped.
    pub fn droppedOf(e: *const Entry, agent: []const u8) usize {
        for (e.dropped.items) |d| if (std.mem.eql(u8, d.agent, agent)) return d.turns;
        return 0;
    }

    /// What kind of place it is, for the model and /conversations.
    pub fn where(e: *const Entry) []const u8 {
        if (e.channel == .terminal) return "terminal";
        if (e.audience == .shared) return if (e.thread != 0) "Telegram group topic, others read it" else "Telegram group, others read it";
        return if (e.thread != 0) "Telegram topic" else "Telegram chat";
    }
};

/// A conversation to add.
pub const New = struct {
    name: []const u8,
    channel: Kind = .telegram,
    chat: i64 = 0,
    thread: i64 = 0,
    audience: Audience = .own,
    private: bool = false,
    created: i64 = 0,
    agent: []const u8 = "main",
    title: []const u8 = "",
    focus: []const u8 = "",
    subject: []const u8 = "",
    card: i64 = 0,
};

pub const Error = error{
    /// Not a conversation's name (see `validName`).
    BadName,
    /// Another conversation has it.
    Taken,
    /// No conversation has it.
    NotFound,
    /// main and terminal are harness's own: never renamed or removed.
    Fixed,
};

pub const List = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    /// Held while the list or an entry in it is read or changed.
    mutex: Io.Mutex = .init,
    items: std.ArrayList(*Entry) = .empty,
    /// Removed entries: a run that reports to one may still read its
    /// private flag; freed at deinit.
    gone: std.ArrayList(*Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, path: []const u8) List {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(l: *List) void {
        for (l.items.items) |e| l.free(e);
        for (l.gone.items) |e| l.free(e);
        l.items.deinit(l.gpa);
        l.gone.deinit(l.gpa);
    }

    fn free(l: *List, e: *Entry) void {
        l.gpa.free(e.name);
        l.gpa.free(e.agent);
        l.gpa.free(e.title);
        l.gpa.free(e.focus);
        l.gpa.free(e.subject);
        for (e.dropped.items) |d| l.gpa.free(d.agent);
        e.dropped.deinit(l.gpa);
        e.posts.deinit(l.gpa);
        l.gpa.destroy(e);
    }

    fn append(l: *List, n: New) !*Entry {
        const e = try l.gpa.create(Entry);
        errdefer l.gpa.destroy(e);
        const name = try l.gpa.dupe(u8, n.name);
        errdefer l.gpa.free(name);
        const agent = try l.gpa.dupe(u8, n.agent);
        errdefer l.gpa.free(agent);
        const title = try l.gpa.dupe(u8, n.title);
        errdefer l.gpa.free(title);
        const focus = try l.gpa.dupe(u8, n.focus);
        errdefer l.gpa.free(focus);
        const subject = try l.gpa.dupe(u8, n.subject);
        errdefer l.gpa.free(subject);
        e.* = .{ .name = name, .channel = n.channel, .chat = n.chat, .thread = n.thread, .audience = n.audience, .private = .init(n.private), .created = n.created, .agent = agent, .title = title, .focus = focus, .subject = subject, .card = n.card };
        try l.items.append(l.gpa, e);
        return e;
    }

    /// Reads the file; a line that does not read, or names a conversation
    /// twice, is left out.
    pub fn load(l: *List) !void {
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
            if (!validName(name) or l.find(name) != null) continue;
            const channel = std.meta.stringToEnum(Kind, jv.str(jv.get(v, "channel")) orelse "") orelse continue;
            const audience = std.meta.stringToEnum(Audience, jv.str(jv.get(v, "audience")) orelse "") orelse continue;
            const chat = jv.int(jv.get(v, "chat")) orelse continue;
            _ = try l.append(.{
                .name = name,
                .channel = channel,
                .chat = chat,
                .thread = jv.int(jv.get(v, "thread")) orelse 0,
                .audience = audience,
                .private = jv.boolean(jv.get(v, "private")) orelse false,
                .created = util.parseIso(jv.str(jv.get(v, "created")) orelse "") orelse 0,
                // a name that is no definition's: main answers
                .agent = if (jv.str(jv.get(v, "agent"))) |ag| (if (agents.validName(ag)) ag else "main") else "main",
                .title = jv.str(jv.get(v, "title")) orelse "",
                .focus = jv.str(jv.get(v, "focus")) orelse "",
                .subject = jv.str(jv.get(v, "subject")) orelse "",
                .card = jv.int(jv.get(v, "card")) orelse 0,
            });
        }
    }

    /// Writes the whole list to a new file that then replaces the old one
    /// (on Windows too), so a crash leaves the old list or the new one,
    /// never a cut one.
    pub fn save(l: *List) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(l.gpa);
        for (l.items.items) |e| {
            var tb: [20]u8 = undefined;
            try out.appendSlice(l.gpa, "{\"name\":");
            try util.jsonString(&out, l.gpa, e.name);
            try out.print(l.gpa, ",\"channel\":\"{s}\",\"chat\":{d},\"thread\":{d},\"audience\":\"{s}\",\"private\":{s},\"created\":\"{s}\"", .{
                @tagName(e.channel), e.chat,                                     e.thread,
                @tagName(e.audience), if (e.isPrivate()) "true" else "false", util.isoTime(&tb, e.created),
            });
            // only when the owner picked another: main's lines stay as they were
            if (!std.mem.eql(u8, e.agent, "main")) {
                try out.appendSlice(l.gpa, ",\"agent\":");
                try util.jsonString(&out, l.gpa, e.agent);
            }
            // a topic's: only where set, so older lines stay as they were
            inline for (.{ "title", "focus", "subject" }) |field| if (@field(e, field).len > 0) {
                try out.appendSlice(l.gpa, ",\"" ++ field ++ "\":");
                try util.jsonString(&out, l.gpa, @field(e, field));
            };
            if (e.card != 0) try out.print(l.gpa, ",\"card\":{d}", .{e.card});
            try out.appendSlice(l.gpa, "}\n");
        }
        try util.writeReplace(l.io, l.path, out.items);
    }

    pub fn find(l: *const List, name: []const u8) ?*Entry {
        for (l.items.items) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// The Telegram conversation in `chat`, topic `thread` (0: the chat).
    pub fn at(l: *const List, chat: i64, thread: i64) ?*Entry {
        for (l.items.items) |e| if (e.channel == .telegram and e.chat == chat and e.thread == thread) return e;
        return null;
    }

    /// Adds a conversation and writes the list; nothing is added when it
    /// can't be written.
    pub fn add(l: *List, n: New) !*Entry {
        if (!validName(n.name)) return error.BadName;
        if (l.find(n.name) != null) return error.Taken;
        const e = try l.append(n);
        l.save() catch |err| {
            _ = l.items.pop();
            l.free(e);
            return err;
        };
        return e;
    }

    pub fn rename(l: *List, old: []const u8, new: []const u8) !void {
        if (isFixed(old)) return error.Fixed;
        if (!validName(new)) return error.BadName;
        const e = l.find(old) orelse return error.NotFound;
        if (l.find(new) != null) return error.Taken;
        const name = try l.gpa.dupe(u8, new);
        const before = e.name;
        e.name = name;
        l.save() catch |err| {
            e.name = before;
            l.gpa.free(name);
            return err;
        };
        l.gpa.free(before);
    }

    /// Definition `agent` answers in conversation `name` from now on;
    /// written before it applies (nothing changes when it can't be).
    pub fn setAgent(l: *List, name: []const u8, agent: []const u8) !void {
        const e = l.find(name) orelse return error.NotFound;
        const owned = try l.gpa.dupe(u8, agent);
        const before = e.agent;
        e.agent = owned;
        l.save() catch |err| {
            e.agent = before;
            l.gpa.free(owned);
            return err;
        };
        l.gpa.free(before);
    }

    /// Every conversation definition `agent` answered in goes back to
    /// main (it was removed); returns their names (in `a`).
    pub fn resetAgent(l: *List, a: std.mem.Allocator, agent: []const u8) ![]const []const u8 {
        var names_out: std.ArrayList([]const u8) = .empty;
        for (l.items.items) |e| if (std.mem.eql(u8, e.agent, agent)) {
            const main = try l.gpa.dupe(u8, "main");
            l.gpa.free(e.agent);
            e.agent = main;
            try names_out.append(a, try a.dupe(u8, e.name));
        };
        if (names_out.items.len > 0) try l.save();
        return names_out.items;
    }

    /// Notes that `turns` turns of definition `agent`'s context in `e`
    /// were dropped.
    pub fn setDropped(l: *List, e: *Entry, agent: []const u8, turns: usize) !void {
        for (e.dropped.items) |*d| if (std.mem.eql(u8, d.agent, agent)) {
            d.turns = turns;
            return;
        };
        const owned = try l.gpa.dupe(u8, agent);
        errdefer l.gpa.free(owned);
        try e.dropped.append(l.gpa, .{ .agent = owned, .turns = turns });
    }

    /// Forgets a conversation (a topic stays in Telegram).
    pub fn remove(l: *List, name: []const u8) !void {
        if (isFixed(name)) return error.Fixed;
        for (l.items.items, 0..) |e, i| if (std.mem.eql(u8, e.name, name)) {
            try l.gone.ensureUnusedCapacity(l.gpa, 1);
            _ = l.items.orderedRemove(i);
            l.save() catch |err| {
                l.items.insert(l.gpa, i, e) catch l.gone.appendAssumeCapacity(e);
                return err;
            };
            l.gone.appendAssumeCapacity(e);
            return;
        };
        return error.NotFound;
    }

    /// The upgrade from a folder without conversations: `terminal`, and
    /// `main` once an owner is paired (with 0.3's `private on`). True when
    /// it added any (and wrote the list).
    pub fn ensure(l: *List, owner: ?i64, private_main: bool, now_s: i64) !bool {
        var changed = false;
        if (l.find("terminal") == null) {
            _ = try l.append(.{ .name = "terminal", .channel = .terminal, .created = now_s });
            changed = true;
        }
        if (owner) |o| if (l.find("main") == null) {
            _ = try l.append(.{ .name = "main", .chat = o, .private = private_main, .created = now_s });
            changed = true;
        };
        if (changed) try l.save();
        return changed;
    }

    /// Another account paired: `main` moves to its chat and the old
    /// account's topics are forgotten. Returns their names (in `a`).
    pub fn pair(l: *List, a: std.mem.Allocator, old: i64, new: i64, now_s: i64) ![]const []const u8 {
        var dropped: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < l.items.items.len) {
            const e = l.items.items[i];
            if (e.channel == .telegram and e.chat == old and e.thread != 0) {
                try dropped.append(a, try a.dupe(u8, e.name));
                try l.gone.append(l.gpa, l.items.orderedRemove(i));
                continue;
            }
            i += 1;
        }
        if (l.find("main")) |m| m.chat = new else _ = try l.append(.{ .name = "main", .chat = new, .created = now_s });
        try l.save();
        return dropped.items;
    }

    /// The name of a topic not known yet: its name in lower case, spaces
    /// to `-`, other characters dropped, cut to 32; `-2`, `-3` … when
    /// another conversation has it (or it is a command's word);
    /// `topic-THREAD` when nothing is left.
    pub fn fromTopic(l: *const List, a: std.mem.Allocator, topic: ?[]const u8, thread: i64) ![]const u8 {
        var base: std.ArrayList(u8) = .empty;
        if (topic) |tn| for (tn) |ch| {
            if (base.items.len == max_name) break;
            const lc = std.ascii.toLower(ch);
            if (lc == ' ') {
                try base.append(a, '-');
            } else if (std.ascii.isLower(lc) or std.ascii.isDigit(lc) or lc == '-' or lc == '_') try base.append(a, lc);
        };
        if (base.items.len == 0) try base.print(a, "topic-{d}", .{thread});
        var name: []const u8 = base.items;
        var n: usize = 2;
        while (!validName(name) or l.find(name) != null) : (n += 1) {
            var sb: [24]u8 = undefined;
            const suffix = try std.fmt.bufPrint(&sb, "-{d}", .{n});
            const keep = @min(base.items.len, max_name - suffix.len);
            name = try std.fmt.allocPrint(a, "{s}{s}", .{ base.items[0..keep], suffix });
        }
        return name;
    }

    /// The topic that files `subject`.
    pub fn bySubject(l: *const List, subject: []const u8) ?*Entry {
        if (subject.len == 0) return null;
        for (l.items.items) |e| if (std.mem.eql(u8, e.subject, subject)) return e;
        return null;
    }

    /// A topic's title, focus and subject, written before they apply.
    pub fn setTopic(l: *List, name: []const u8, title: []const u8, focus: []const u8, subject: []const u8) !void {
        const e = l.find(name) orelse return error.NotFound;
        const nt = try l.gpa.dupe(u8, title);
        errdefer l.gpa.free(nt);
        const nf = try l.gpa.dupe(u8, focus);
        errdefer l.gpa.free(nf);
        const ns = try l.gpa.dupe(u8, subject);
        errdefer l.gpa.free(ns);
        const before = .{ e.title, e.focus, e.subject };
        e.title, e.focus, e.subject = .{ nt, nf, ns };
        l.save() catch |err| {
            e.title, e.focus, e.subject = before;
            return err;
        };
        l.gpa.free(before[0]);
        l.gpa.free(before[1]);
        l.gpa.free(before[2]);
    }

    pub fn setFocus(l: *List, name: []const u8, focus: []const u8) !void {
        const e = l.find(name) orelse return error.NotFound;
        return l.setTopic(name, e.title, focus, e.subject);
    }

    /// Its card's message (0: none).
    pub fn setCard(l: *List, name: []const u8, id: i64) !void {
        const e = l.find(name) orelse return error.NotFound;
        const before = e.card;
        e.card = id;
        l.save() catch |err| {
            e.card = before;
            return err;
        };
    }

    /// Every conversation's name, in the list's order (in `a`).
    pub fn names(l: *const List, a: std.mem.Allocator) ![]const []const u8 {
        const out = try a.alloc([]const u8, l.items.items.len);
        for (l.items.items, out) |e, *o| o.* = try a.dupe(u8, e.name);
        return out;
    }
};

/// main and terminal: never renamed or removed.
pub fn isFixed(name: []const u8) bool {
    return std.mem.eql(u8, name, "main") or std.mem.eql(u8, name, "terminal");
}

const t = std.testing;

fn tmpList(tmp: *t.TmpDir, a: std.mem.Allocator) !List {
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    return .init(t.allocator, t.io, try std.fs.path.join(a, &.{ dir, "conversations" }));
}

test "the_list_is_written_whole_and_read_back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try tmpList(&tmp, a);
    defer l.deinit();
    const t0 = util.parseIso("2026-11-22T09:00:00Z").?;
    _ = try l.add(.{ .name = "main", .chat = 123456789, .created = t0 });
    _ = try l.add(.{ .name = "house-search", .chat = 123456789, .thread = 5012, .private = true, .created = t0 + 1800 });
    _ = try l.add(.{ .name = "family", .chat = -1001234567890, .audience = .shared, .created = t0 + 3600 });
    try t.expectError(error.Taken, l.add(.{ .name = "family", .chat = 1 }));
    try t.expectError(error.BadName, l.add(.{ .name = "Family", .chat = 1 }));
    const text = try tmp.dir.readFileAlloc(t.io, "conversations", a, .unlimited);
    try t.expectEqualStrings(
        \\{"name":"main","channel":"telegram","chat":123456789,"thread":0,"audience":"own","private":false,"created":"2026-11-22T09:00:00Z"}
        \\{"name":"house-search","channel":"telegram","chat":123456789,"thread":5012,"audience":"own","private":true,"created":"2026-11-22T09:30:00Z"}
        \\{"name":"family","channel":"telegram","chat":-1001234567890,"thread":0,"audience":"shared","private":false,"created":"2026-11-22T10:00:00Z"}
        \\
    , text);
    // written whole, then put in place: nothing is left beside it
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "conversations.tmp", .{}));
    // read back, with a line that does not read left out
    try tmp.dir.writeFile(t.io, .{ .sub_path = "conversations", .data = try std.mem.concat(a, u8, &.{ text, "{\"name\":\"broken\"\nnot json\n" }) });
    var again: List = .init(t.allocator, t.io, l.path);
    defer again.deinit();
    try again.load();
    try t.expectEqual(3, again.items.items.len);
    const hs = again.find("house-search").?;
    try t.expectEqual(5012, hs.thread);
    try t.expect(hs.isPrivate());
    try t.expectEqualStrings("Telegram topic", hs.where());
    try t.expectEqual(.shared, again.at(-1001234567890, 0).?.audience);
    try t.expectEqual(null, again.at(123456789, 7));
    // renamed and removed, the file follows; main and terminal stay
    try again.rename("house-search", "flats");
    try t.expectError(error.Fixed, again.rename("main", "home"));
    try again.remove("family");
    try t.expectError(error.Fixed, again.remove("main"));
    try t.expectError(error.NotFound, again.remove("family"));
    const after = try tmp.dir.readFileAlloc(t.io, "conversations", a, .unlimited);
    try t.expect(std.mem.indexOf(u8, after, "\"name\":\"flats\"") != null);
    try t.expect(std.mem.indexOf(u8, after, "family") == null);
}

test "names_from_topics_follow_the_name_rule" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try tmpList(&tmp, a);
    defer l.deinit();
    try t.expectEqualStrings("house-search", try l.fromTopic(a, "House search", 5012));
    _ = try l.add(.{ .name = "house-search", .chat = 1, .thread = 5012 });
    try t.expectEqualStrings("house-search-2", try l.fromTopic(a, "House search", 5013));
    try t.expectEqualStrings("ncode", try l.fromTopic(a, "Ünïcode!!", 5014));
    try t.expectEqualStrings("topic-5015", try l.fromTopic(a, "!!!", 5015));
    try t.expectEqualStrings("topic-5016", try l.fromTopic(a, null, 5016));
    // a word the commands take is taken
    try t.expectEqualStrings("add-2", try l.fromTopic(a, "Add", 5017));
    const long = try l.fromTopic(a, "abcdefghijklmnopqrstuvwxyzabcdefghijklmn", 5018);
    try t.expectEqual(32, long.len);
    for ([_][]const u8{ "main", "a_b-1", "topic-5012" }) |n| try t.expect(validName(n));
    const too_long: [33]u8 = @splat('a');
    for ([_][]const u8{ "Main", "a b", "a/b", "", &too_long, "rm", "new", "a:b", "a*" }) |n| try t.expect(!validName(n));
}

test "an_old_folder_gets_terminal_and_main_once_paired" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try tmpList(&tmp, a);
    defer l.deinit();
    try t.expect(try l.ensure(null, true, 1000));
    try t.expectEqual(1, l.items.items.len);
    try t.expectEqual(.terminal, l.find("terminal").?.channel);
    // paired: main, with 0.3's private switch
    try t.expect(try l.ensure(42, true, 1000));
    const m = l.find("main").?;
    try t.expectEqual(42, m.chat);
    try t.expect(m.isPrivate());
    try t.expect(!try l.ensure(42, false, 1000));
    // another account: main moves, the old account's topics go
    _ = try l.add(.{ .name = "house-search", .chat = 42, .thread = 5012 });
    _ = try l.add(.{ .name = "family", .chat = -100, .audience = .shared });
    const dropped = try l.pair(a, 42, 77, 1000);
    try t.expectEqual(1, dropped.len);
    try t.expectEqualStrings("house-search", dropped[0]);
    try t.expectEqual(77, l.find("main").?.chat);
    try t.expect(l.find("family") != null);
    const text = try tmp.dir.readFileAlloc(t.io, "conversations", a, .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "house-search") == null);
    try t.expect(std.mem.indexOf(u8, text, "\"chat\":77") != null);
}

test "each_conversation_keeps_its_agent" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try tmpList(&tmp, a);
    defer l.deinit();
    const t0 = util.parseIso("2026-11-22T09:00:00Z").?;
    _ = try l.add(.{ .name = "main", .chat = 42, .created = t0 });
    _ = try l.add(.{ .name = "house-search", .chat = 42, .thread = 5012, .agent = "researcher", .created = t0 });
    // main's line is as before; another definition is said at the end
    try t.expectEqualStrings(
        \\{"name":"main","channel":"telegram","chat":42,"thread":0,"audience":"own","private":false,"created":"2026-11-22T09:00:00Z"}
        \\{"name":"house-search","channel":"telegram","chat":42,"thread":5012,"audience":"own","private":false,"created":"2026-11-22T09:00:00Z","agent":"researcher"}
        \\
    , try tmp.dir.readFileAlloc(t.io, "conversations", a, .unlimited));
    try l.setAgent("main", "writer");
    try t.expectError(error.NotFound, l.setAgent("nope", "writer"));
    try t.expectEqualStrings("writer", l.find("main").?.agent);
    // read back; an agent that is no definition's name reads as main
    const text = try tmp.dir.readFileAlloc(t.io, "conversations", a, .unlimited);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "conversations", .data = try std.mem.concat(a, u8, &.{ text, "{\"name\":\"odd\",\"channel\":\"telegram\",\"chat\":1,\"thread\":0,\"audience\":\"own\",\"private\":false,\"created\":\"2026-11-22T09:00:00Z\",\"agent\":\"Not A Name\"}\n" }) });
    var again: List = .init(t.allocator, t.io, l.path);
    defer again.deinit();
    try again.load();
    try t.expectEqualStrings("writer", again.find("main").?.agent);
    try t.expectEqualStrings("researcher", again.find("house-search").?.agent);
    try t.expectEqualStrings("main", again.find("odd").?.agent);
    // a removed definition: its conversations go back to main
    const back = try again.resetAgent(a, "researcher");
    try t.expectEqual(1, back.len);
    try t.expectEqualStrings("house-search", back[0]);
    try t.expectEqualStrings("main", again.find("house-search").?.agent);
    // turns dropped are kept per definition
    const e = again.find("main").?;
    try again.setDropped(e, "researcher", 3);
    try again.setDropped(e, "researcher", 5);
    try t.expectEqual(5, e.droppedOf("researcher"));
    try t.expectEqual(0, e.droppedOf("main"));
}

test "topic_fields_are_kept_and_old_files_read" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try tmpList(&tmp, a);
    defer l.deinit();
    const t0 = util.parseIso("2026-11-24T09:00:00Z").?;
    _ = try l.add(.{ .name = "main", .chat = 42, .created = t0 });
    _ = try l.add(.{ .name = "travel", .chat = 42, .thread = 5003, .created = t0, .title = "Travel", .focus = "trips, flights, check-in, packing.", .subject = "travel" });
    try l.setCard("travel", 777);
    try l.setFocus("travel", "trips and flights.");
    const text = try tmp.dir.readFileAlloc(t.io, "conversations", a, .unlimited);
    // an old line stays as it was; the new fields only where set
    try t.expect(std.mem.startsWith(u8, text, "{\"name\":\"main\",\"channel\":\"telegram\",\"chat\":42,\"thread\":0,\"audience\":\"own\",\"private\":false,\"created\":\"2026-11-24T09:00:00Z\"}\n"));
    try t.expect(std.mem.indexOf(u8, text, ",\"title\":\"Travel\",\"focus\":\"trips and flights.\",\"subject\":\"travel\",\"card\":777}") != null);
    var again: List = .init(t.allocator, t.io, l.path);
    defer again.deinit();
    try again.load();
    const tr = again.bySubject("travel").?;
    try t.expectEqualStrings("travel", tr.name);
    try t.expectEqualStrings("Travel", tr.title);
    try t.expectEqualStrings("trips and flights.", tr.focus);
    try t.expectEqual(777, tr.card);
    try t.expectEqual(null, again.bySubject("house"));
    try t.expectEqualStrings("", again.find("main").?.title);
    try again.setTopic("main", "", "", "");
    try t.expectEqualStrings("", again.find("main").?.subject);
}
