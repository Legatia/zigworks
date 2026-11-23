//! Memory: one plain file per item, ranked by how often and how recently
//! the owner brought it up. Pinned items are always in front of the model;
//! the strongest few are too (when automatic recall is on); the rest come
//! in when a message matches them, and the further an item has sunk, the
//! closer the match must be.
const std = @import("std");
const util = @import("util.zig");
const scrub = @import("scrub.zig");
const Io = std.Io;

pub const Level = enum { pinned, top, middle, bottom };

/// Strength below which an item counts as sunk to the bottom.
pub const bottom_line: f64 = -1.0;
pub const middle_match: f64 = 0.3;
pub const bottom_match: f64 = 0.7;
pub const mention_match: f64 = 0.5;
pub const same_item: f64 = 0.8;
pub const max_recalled = 8;
/// Mentions kept per item; older ones add almost nothing to the strength.
pub const max_mentions = 64;
const max_terms = 12;
const max_body = 2000;

pub const Item = struct {
    id: []u8,
    created_s: i64,
    mentions: std.ArrayList(i64) = .empty,
    pinned: bool = false,
    terms: [][]u8,
    body: []u8,

    fn deinit(it: *Item, gpa: std.mem.Allocator) void {
        gpa.free(it.id);
        gpa.free(it.body);
        for (it.terms) |w| gpa.free(w);
        gpa.free(it.terms);
        it.mentions.deinit(gpa);
    }

    fn lastMention(it: *const Item) i64 {
        return if (it.mentions.items.len > 0) it.mentions.items[it.mentions.items.len - 1] else it.created_s;
    }
};

/// ln(Σ (age_in_days + 1)^-0.5) over the mentions (ACT-R base level).
pub fn strength(mentions: []const i64, now_s: i64) f64 {
    var sum: f64 = 0;
    for (mentions) |m| {
        const age = @max(0, @as(f64, @floatFromInt(now_s - m)) / 86400.0);
        sum += 1.0 / @sqrt(age + 1.0);
    }
    if (sum == 0) return -std.math.inf(f64);
    return @log(sum);
}

const stop_words = [_][]const u8{
    "the",  "and",   "for",   "are",  "but",   "not",  "you",   "your", "all",  "any",   "can",  "had",
    "has",  "have",  "her",   "his",  "him",   "she",  "they",  "them", "their", "this", "that", "these",
    "those", "with", "from",  "into", "about", "what", "when",  "where", "which", "who", "whom", "why",
    "how",  "was",   "were",  "will", "would", "should", "could", "there", "here", "then", "than", "also",
    "just", "very",  "some",  "such", "only",  "own",  "same",  "too",  "out",  "off",   "over", "under",
    "again", "once", "more",  "most", "other", "each", "few",   "both", "does", "did",   "doing", "being",
    "been", "our",   "ours",  "its",  "it's",  "i'm",  "don't", "please", "thanks", "want", "wants", "like",
    "user", "tell",  "me",
};

fn isStop(w: []const u8) bool {
    for (stop_words) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// Lowercased words of 3+ letters or digits, stop words left out, each once.
pub fn words(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !isWordByte(text[i])) i += 1;
        const start = i;
        while (i < text.len and isWordByte(text[i])) i += 1;
        if (i - start < 3) continue;
        const w = try std.ascii.allocLowerString(arena, text[start..i]);
        if (isStop(w)) continue;
        var seen = false;
        for (out.items) |o| if (std.mem.eql(u8, o, w)) {
            seen = true;
            break;
        };
        if (!seen) try out.append(arena, w);
    }
    return out.items;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Whether two texts that share their key words can be the same fact: a
/// correction usually changes a number ("at 9" → "at 10") or denies what
/// the other says, and is then a new item, not a repeat.
pub fn sameFacts(a: []const u8, b: []const u8) bool {
    if (negations(a) != negations(b)) return false;
    var na: [16][]const u8 = undefined;
    var nb: [16][]const u8 = undefined;
    const xa = numbers(a, &na);
    const xb = numbers(b, &nb);
    if (xa.len != xb.len) return false;
    const lt = struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f;
    std.mem.sort([]const u8, xa, {}, lt);
    std.mem.sort([]const u8, xb, {}, lt);
    for (xa, xb) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// How many words of `text` deny something: not, no, never, … and any
/// word ending in n't.
fn negations(text: []const u8) usize {
    const words_that_deny = [_][]const u8{ "not", "no", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor", "cannot", "without" };
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !isWordByte(text[i]) and text[i] != '\'') i += 1;
        const start = i;
        while (i < text.len and (isWordByte(text[i]) or text[i] == '\'')) i += 1;
        const w = text[start..i];
        if (w.len == 0) continue;
        if (std.ascii.endsWithIgnoreCase(w, "n't") or std.ascii.endsWithIgnoreCase(w, "n\u{2019}t")) {
            n += 1;
            continue;
        }
        for (words_that_deny) |d| if (std.ascii.eqlIgnoreCase(w, d)) {
            n += 1;
            break;
        };
    }
    return n;
}

/// The numbers in `text` ("9", "10:30", "3.5"), the first `out.len` of them.
fn numbers(text: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and (std.ascii.isDigit(text[i]) or ((text[i] == '.' or text[i] == ',' or text[i] == ':') and i + 1 < text.len and std.ascii.isDigit(text[i + 1])))) i += 1;
        out[n] = text[start..i];
        n += 1;
    }
    return out[0..n];
}

/// Fraction of the item's terms that appear among `ws`.
pub fn match(terms: []const []const u8, ws: []const []const u8) f64 {
    if (terms.len == 0) return 0;
    var hit: usize = 0;
    for (terms) |term| {
        for (ws) |w| if (std.mem.eql(u8, term, w)) {
            hit += 1;
            break;
        };
    }
    return @as(f64, @floatFromInt(hit)) / @as(f64, @floatFromInt(terms.len));
}

pub const Ranked = struct { item: *Item, level: Level, strength: f64 };

pub const Recall = struct {
    /// Pinned items, and the top level when automatic recall is on.
    always: []*Item,
    /// Middle and bottom items the text matched closely enough.
    found: []*Item,
};

pub const AddResult = struct { id: []const u8, merged: bool };

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    dir: []u8,
    items: std.ArrayList(*Item) = .empty,
    /// Stored secrets: masked as `[secret:NAME]` in every item written.
    secrets: []const scrub.Secret = &.{},

    pub fn load(gpa: std.mem.Allocator, io: Io, dir: []const u8) !Store {
        try Io.Dir.cwd().createDirPath(io, dir);
        var s: Store = .{ .gpa = gpa, .io = io, .dir = try gpa.dupe(u8, dir) };
        errdefer s.deinit();
        var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".md")) continue;
            // the file's name is the item's id, whatever its text says
            const id = e.name[0 .. e.name.len - 3];
            if (!validId(id)) continue;
            const text = d.readFileAlloc(io, e.name, gpa, .limited(64 * 1024)) catch continue;
            defer gpa.free(text);
            const item = parseItem(gpa, id, text) catch continue;
            try s.items.append(gpa, item);
        }
        // a stable order for ties
        std.mem.sort(*Item, s.items.items, {}, struct {
            fn lt(_: void, a: *Item, b: *Item) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lt);
        return s;
    }

    pub fn deinit(s: *Store) void {
        for (s.items.items) |it| {
            it.deinit(s.gpa);
            s.gpa.destroy(it);
        }
        s.items.deinit(s.gpa);
        s.gpa.free(s.dir);
    }

    pub fn find(s: *Store, id: []const u8) ?*Item {
        for (s.items.items) |it| if (std.mem.eql(u8, it.id, id)) return it;
        return null;
    }

    /// Who is writing an item.
    pub const From = enum { owner, other };

    /// The owner's own words (`/remember`): writes a new item, or adds a
    /// mention to one it nearly repeats.
    pub fn add(s: *Store, body_in: []const u8, given_terms: ?[]const []const u8, now_s: i64) !AddResult {
        return s.addFrom(body_in, given_terms, now_s, .owner);
    }

    /// Like `add`; an item nearly repeated by `.other` (the agent, the
    /// memory writer) gets no mention, as only the owner's words count.
    pub fn addFrom(s: *Store, body_in: []const u8, given_terms: ?[]const []const u8, now_s: i64, from: From) !AddResult {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var sc = try scrub.Scrubber.init(a, s.secrets);
        const masked = try sc.scrubAlloc(a, body_in);
        const body = std.mem.trim(u8, util.cut(masked, max_body), " \t\r\n");
        if (body.len == 0) return error.EmptyMemory;
        var ts = if (given_terms) |g| blk: {
            var lowered: std.ArrayList([]const u8) = .empty;
            for (g) |w| {
                const ws = try words(a, w);
                for (ws) |x| try lowered.append(a, x);
            }
            break :blk lowered.items;
        } else try words(a, body);
        if (ts.len > max_terms) ts = ts[0..max_terms];
        if (ts.len == 0) ts = try words(a, body);
        for (s.items.items) |it| {
            const overlap = match(ts, @ptrCast(it.terms));
            if (ts.len > 0 and overlap >= same_item and sameFacts(body, it.body)) {
                if (from == .owner) try s.mention(it, now_s);
                return .{ .id = it.id, .merged = true };
            }
        }
        const item = try s.gpa.create(Item);
        errdefer s.gpa.destroy(item);
        const terms = try s.gpa.alloc([]u8, ts.len);
        var made: usize = 0;
        errdefer {
            for (terms[0..made]) |w| s.gpa.free(w);
            s.gpa.free(terms);
        }
        for (ts, 0..) |w, i| {
            terms[i] = try s.gpa.dupe(u8, w);
            made += 1;
        }
        item.* = .{ .id = try s.newId(now_s), .created_s = now_s, .terms = terms, .body = try s.gpa.dupe(u8, body) };
        try item.mentions.append(s.gpa, now_s);
        try s.items.append(s.gpa, item);
        try s.save(item);
        return .{ .id = item.id, .merged = false };
    }

    fn newId(s: *Store, now_s: i64) ![]u8 {
        const c = util.civil(@divFloor(now_s, 86400));
        var prefix_buf: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "{d:0>4}{d:0>2}{d:0>2}-", .{ @as(u64, @intCast(c.y)), c.m, c.d });
        var n: u32 = 0;
        for (s.items.items) |it| {
            if (std.mem.startsWith(u8, it.id, prefix)) {
                const k = std.fmt.parseInt(u32, it.id[prefix.len..], 10) catch continue;
                n = @max(n, k);
            }
        }
        return std.fmt.allocPrint(s.gpa, "{s}{d:0>4}", .{ prefix, n + 1 });
    }

    pub fn mention(s: *Store, it: *Item, now_s: i64) !void {
        if (it.mentions.items.len >= max_mentions) _ = it.mentions.orderedRemove(0);
        try it.mentions.append(s.gpa, now_s);
        try s.save(it);
    }

    pub fn setPinned(s: *Store, id: []const u8, pinned: bool) !bool {
        const it = s.find(id) orelse return false;
        it.pinned = pinned;
        try s.save(it);
        return true;
    }

    pub fn forget(s: *Store, id: []const u8) !bool {
        for (s.items.items, 0..) |it, i| {
            if (!std.mem.eql(u8, it.id, id)) continue;
            var d = try Io.Dir.cwd().openDir(s.io, s.dir, .{});
            defer d.close(s.io);
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}.md", .{it.id});
            d.deleteFile(s.io, name) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
            _ = s.items.orderedRemove(i);
            it.deinit(s.gpa);
            s.gpa.destroy(it);
            return true;
        }
        return false;
    }

    pub fn save(s: *Store, it: *const Item) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        var tb: [20]u8 = undefined;
        try out.print(s.gpa, "id: {s}\ncreated: {s}\nmentions:", .{ it.id, util.isoTime(&tb, it.created_s) });
        for (it.mentions.items) |m| try out.print(s.gpa, " {s}", .{util.isoTime(&tb, m)});
        try out.print(s.gpa, "\npinned: {s}\nterms:", .{if (it.pinned) "yes" else "no"});
        for (it.terms) |w| try out.print(s.gpa, " {s}", .{w});
        try out.print(s.gpa, "\n---\n{s}\n", .{it.body});
        var d = try Io.Dir.cwd().openDir(s.io, s.dir, .{});
        defer d.close(s.io);
        var name_buf: [64]u8 = undefined;
        try d.writeFile(s.io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{s}.md", .{it.id}), .data = out.items });
    }

    /// Every item with its level, strongest first within each level.
    pub fn levels(s: *Store, arena: std.mem.Allocator, now_s: i64, top_size: u32) ![]Ranked {
        var out = try arena.alloc(Ranked, s.items.items.len);
        for (s.items.items, 0..) |it, i| out[i] = .{ .item = it, .level = .pinned, .strength = strength(it.mentions.items, now_s) };
        std.mem.sort(Ranked, out, {}, struct {
            fn lt(_: void, a: Ranked, b: Ranked) bool {
                if (a.item.pinned != b.item.pinned) return a.item.pinned;
                return a.strength > b.strength;
            }
        }.lt);
        var top_left = top_size;
        for (out) |*r| {
            if (r.item.pinned) {
                r.level = .pinned;
            } else if (top_left > 0) {
                r.level = .top;
                top_left -= 1;
            } else {
                r.level = if (r.strength >= bottom_line) .middle else .bottom;
            }
        }
        return out;
    }

    /// What goes in front of the model for a message.
    pub fn recall(s: *Store, arena: std.mem.Allocator, text: []const u8, now_s: i64, top_size: u32, auto: bool) !Recall {
        const ranked = try s.levels(arena, now_s, top_size);
        var always: std.ArrayList(*Item) = .empty;
        var found: std.ArrayList(*Item) = .empty;
        const ws = try words(arena, text);
        for (ranked) |r| switch (r.level) {
            .pinned => try always.append(arena, r.item),
            .top => if (auto) try always.append(arena, r.item),
            .middle, .bottom => if (auto and found.items.len < max_recalled) {
                const need = if (r.level == .middle) middle_match else bottom_match;
                if (match(@ptrCast(r.item.terms), ws) >= need) try found.append(arena, r.item);
            },
        };
        return .{ .always = always.items, .found = found.items };
    }

    /// The `recall` tool: any level, closest matches first.
    pub fn search(s: *Store, arena: std.mem.Allocator, text: []const u8) ![]*Item {
        const ws = try words(arena, text);
        const Hit = struct { item: *Item, score: f64 };
        var hits: std.ArrayList(Hit) = .empty;
        for (s.items.items) |it| {
            const m = match(@ptrCast(it.terms), ws);
            if (m >= middle_match) try hits.append(arena, .{ .item = it, .score = m });
        }
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lt(_: void, a: Hit, b: Hit) bool {
                return a.score > b.score;
            }
        }.lt);
        const n = @min(hits.items.len, max_recalled);
        const out = try arena.alloc(*Item, n);
        for (hits.items[0..n], 0..) |h, i| out[i] = h.item;
        return out;
    }

    /// Adds a mention to every item the owner's message matches at half
    /// its terms or more; returns their ids.
    pub fn noteMentions(s: *Store, arena: std.mem.Allocator, text: []const u8, now_s: i64) ![][]const u8 {
        const ws = try words(arena, text);
        var ids: std.ArrayList([]const u8) = .empty;
        for (s.items.items) |it| {
            if (match(@ptrCast(it.terms), ws) >= mention_match) {
                try s.mention(it, now_s);
                try ids.append(arena, it.id);
            }
        }
        return ids.items;
    }

    /// The `/memory` listing.
    pub fn render(s: *Store, arena: std.mem.Allocator, now_s: i64, top_size: u32) ![]u8 {
        const ranked = try s.levels(arena, now_s, top_size);
        var out: std.ArrayList(u8) = .empty;
        if (ranked.len == 0) return arena.dupe(u8, "No memories yet.");
        var current: ?Level = null;
        for (ranked) |r| {
            if (current != r.level) {
                current = r.level;
                try out.print(arena, "{s}{s}\n", .{ if (out.items.len > 0) "\n" else "", switch (r.level) {
                    .pinned => "Pinned",
                    .top => "Top",
                    .middle => "Middle",
                    .bottom => "Bottom",
                } });
            }
            var tb: [20]u8 = undefined;
            const last = util.isoTime(&tb, r.item.lastMention())[0..10];
            try out.print(arena, "{s}  {d:.2}  last {s}, {d}×  {s}\n", .{ r.item.id, r.strength, last, r.item.mentions.items.len, util.cut(firstLine(r.item.body), 80) });
        }
        return out.items;
    }
};

/// What the owner is told when the agent or the memory writer saves an
/// item: one line, with how to take it back.
pub fn savedNote(arena: std.mem.Allocator, id: []const u8, body: []const u8) ![]u8 {
    const short = util.cut(body, 200);
    const line = try std.mem.replaceOwned(u8, arena, short, "\n", " ");
    return std.fmt.allocPrint(arena, "Saved to memory: {s}{s} (/forget {s})", .{ line, if (short.len < body.len) "…" else "", id });
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

/// An id that names a file in the memory folder and nothing else.
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 40 or std.mem.indexOf(u8, id, "..") != null) return false;
    for (id) |c| if (c == '/' or c == '\\' or c < ' ' or c == 0x7f) return false;
    return true;
}

/// A time read from an item's file; none before 1970.
fn parseTime(v: []const u8) ?i64 {
    const x = util.parseIso(v) orelse return null;
    return if (x >= 0) x else null;
}

fn parseItem(gpa: std.mem.Allocator, id_s: []const u8, text: []const u8) !*Item {
    const sep = std.mem.indexOf(u8, text, "\n---\n") orelse return error.BadItem;
    var created: ?i64 = null;
    var pinned = false;
    var mentions_line: []const u8 = "";
    var terms_line: []const u8 = "";
    var it = std.mem.splitScalar(u8, text[0..sep], '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "created")) {
            created = parseTime(val);
        } else if (std.mem.eql(u8, key, "pinned")) {
            pinned = std.mem.eql(u8, val, "yes");
        } else if (std.mem.eql(u8, key, "mentions")) {
            mentions_line = val;
        } else if (std.mem.eql(u8, key, "terms")) terms_line = val;
    }
    if (!validId(id_s)) return error.BadItem;
    const item = try gpa.create(Item);
    errdefer gpa.destroy(item);
    var tl: std.ArrayList([]u8) = .empty;
    errdefer {
        for (tl.items) |w| gpa.free(w);
        tl.deinit(gpa);
    }
    var tw = std.mem.tokenizeAny(u8, terms_line, " \t");
    while (tw.next()) |w| {
        if (tl.items.len >= max_terms) break;
        try tl.append(gpa, try gpa.dupe(u8, w));
    }
    const body = try gpa.dupe(u8, std.mem.trim(u8, text[sep + 5 ..], " \t\r\n"));
    errdefer gpa.free(body);
    const id_owned = try gpa.dupe(u8, id_s);
    errdefer gpa.free(id_owned);
    item.* = .{ .id = id_owned, .created_s = created orelse 0, .pinned = pinned, .terms = try tl.toOwnedSlice(gpa), .body = body };
    var mw = std.mem.tokenizeAny(u8, mentions_line, " \t");
    while (mw.next()) |m| {
        if (parseTime(m)) |v| try item.mentions.append(gpa, v);
    }
    if (item.mentions.items.len == 0) try item.mentions.append(gpa, item.created_s);
    return item;
}

const t = std.testing;
const day: i64 = 86400;
const now: i64 = 1796083200; // 2026-12-01

// long memory's own files: the search of the log, the summaries
test {
    _ = @import("history.zig");
    _ = @import("summaries.zig");
}

const Fix = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    store: Store,

    fn init(f: *Fix) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        const dir = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.arena.allocator());
        f.store = try Store.load(t.allocator, t.io, try std.fs.path.join(f.arena.allocator(), &.{ dir, "memory" }));
    }

    fn deinit(f: *Fix) void {
        f.store.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn addAt(f: *Fix, body: []const u8, when: i64) !*Item {
        const r = try f.store.add(body, null, when);
        return f.store.find(r.id).?;
    }
};

test "strength_favours_recent_mentions" {
    var recent: [5]i64 = undefined;
    for (&recent, 0..) |*m, i| m.* = now - @as(i64, @intCast(i + 1)) * day;
    var old: [20]i64 = undefined;
    for (&old) |*m| m.* = now - 365 * day;
    try t.expect(strength(&recent, now) > strength(&old, now));
    // one mention today: ln(1) = 0
    try t.expectApproxEqAbs(0.0, strength(&.{now}, now), 1e-9);
}

test "levels_split_pinned_top_middle_bottom" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = try f.addAt("Zig compiler releases with breaking changes", now - day);
    const b = try f.addAt("Bitcoin price alerts above three percent", now - 2 * day);
    const c = try f.addAt("Grandmother birthday gift ideas", now - 400 * day);
    const d = try f.addAt("Standing order: ask before deleting anything", now - 900 * day);
    _ = try f.store.setPinned(d.id, true);
    const r = try f.store.levels(f.arena.allocator(), now, 1);
    try t.expectEqual(4, r.len);
    try t.expectEqual(d, r[0].item);
    try t.expectEqual(Level.pinned, r[0].level);
    try t.expectEqual(a, r[1].item);
    try t.expectEqual(Level.top, r[1].level);
    try t.expectEqual(b, r[2].item);
    try t.expectEqual(Level.middle, r[2].level);
    try t.expectEqual(c, r[3].item);
    try t.expectEqual(Level.bottom, r[3].level); // ln(401^-0.5) ≈ -3.0
}

test "middle_needs_30_percent_bottom_needs_70" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.addAt("filler item keeps the top slot busy", now);
    const mid = try f.addAt("kayak trip planning norway fjords summer", now - 3 * day);
    const low = try f.addAt("old apartment lease landlord deposit dispute", now - 600 * day);
    const a = f.arena.allocator();
    // 2 of 6 terms → 33%: enough for middle
    var r = try f.store.recall(a, "thinking about a kayak in norway", now, 1, true);
    try t.expectEqual(1, r.found.len);
    try t.expectEqual(mid, r.found[0]);
    // 3 of 5 terms → 60%: not enough for bottom
    r = try f.store.recall(a, "the landlord kept my deposit for the apartment", now, 1, true);
    try t.expectEqual(0, r.found.len);
    // 4 of 5 → 80%
    r = try f.store.recall(a, "landlord deposit dispute about the old apartment", now, 1, true);
    try t.expectEqual(1, r.found.len);
    try t.expectEqual(low, r.found[0]);
}

test "recall_caps_at_8_strongest_first" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.addAt("top slot filler", now);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const body = try std.fmt.allocPrint(f.arena.allocator(), "garden tomato plan number{d}", .{i});
        _ = try f.addAt(body, now - @as(i64, @intCast(i + 1)) * 3600); // all still in the middle level
    }
    const r = try f.store.recall(f.arena.allocator(), "garden tomato", now, 1, true);
    try t.expectEqual(8, r.found.len);
    try t.expect(std.mem.endsWith(u8, r.found[0].body, "number0"));
}

test "auto_off_keeps_only_pinned" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const p = try f.addAt("ask before deleting files", now);
    _ = try f.store.setPinned(p.id, true);
    _ = try f.addAt("zig release notes", now);
    _ = try f.addAt("kayak norway fjords", now - 50 * day);
    const r = try f.store.recall(f.arena.allocator(), "kayak norway fjords", now, 1, false);
    try t.expectEqual(1, r.always.len);
    try t.expectEqual(p, r.always[0]);
    try t.expectEqual(0, r.found.len);
    // explicit search still finds it
    try t.expectEqual(1, (try f.store.search(f.arena.allocator(), "kayak fjords")).len);
}

test "mention_counts_at_half_match" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const it = try f.addAt("kayak trip norway fjords", now - 10 * day);
    const a = f.arena.allocator();
    try t.expectEqual(0, (try f.store.noteMentions(a, "a kayak", now)).len);
    try t.expectEqual(1, (try f.store.noteMentions(a, "kayak in norway?", now)).len);
    try t.expectEqual(2, it.mentions.items.len);
}

test "near_duplicate_becomes_a_mention" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.store.add("User follows Zig compiler releases", null, now - day);
    const again = try f.store.add("The user follows zig compiler releases closely", null, now);
    try t.expect(again.merged);
    try t.expectEqualStrings(first.id, again.id);
    try t.expectEqual(1, f.store.items.items.len);
    try t.expectEqual(2, f.store.items.items[0].mentions.items.len);
}

test "a_correction_is_not_merged_into_the_fact_it_corrects" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const nine = try f.store.add("Owner's flight to Oslo leaves at 9 am", null, now - day);
    const ten = try f.store.add("Owner's flight to Oslo leaves at 10 am", null, now);
    try t.expect(!ten.merged);
    try t.expect(!std.mem.eql(u8, nine.id, ten.id));
    _ = try f.store.add("The owner likes coffee", null, now - day);
    try t.expect(!(try f.store.add("The owner does not like coffee", null, now)).merged);
    _ = try f.store.add("The owner can't stand loud music at dinner", null, now - day);
    try t.expect(!(try f.store.add("The owner can stand loud music at dinner", null, now)).merged);
    // a plain repeat still merges, into the item it agrees with
    const again = try f.store.add("Owner's flight to Oslo leaves at 10 am sharp", null, now);
    try t.expect(again.merged);
    try t.expectEqualStrings(ten.id, again.id);
    try t.expectEqual(6, f.store.items.items.len);
}

test "a_repeat_by_the_agent_or_the_writer_is_not_a_mention" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.store.add("User follows Zig compiler releases", null, now - day);
    const again = try f.store.addFrom("The user follows zig compiler releases closely", null, now, .other);
    try t.expect(again.merged);
    try t.expectEqualStrings(first.id, again.id);
    try t.expectEqual(1, f.store.items.items[0].mentions.items.len);
}

test "a_secret_in_an_item_is_masked" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.store.secrets = &.{.{ .name = "omnigate", .value = "og-secret-value-123" }};
    const r = try f.store.add("my omnigate key is og-secret-value-123", null, now);
    try t.expectEqualStrings("my omnigate key is [secret:omnigate]", f.store.find(r.id).?.body);
    var d = try Io.Dir.cwd().openDir(t.io, f.store.dir, .{});
    defer d.close(t.io);
    const file = try d.readFileAlloc(t.io, try std.fmt.allocPrint(f.arena.allocator(), "{s}.md", .{r.id}), f.arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, file, "og-secret-value-123") == null);
}

test "files_round_trip" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const it = try f.addAt("Prefers briefs before 7am", now - day);
    try f.store.mention(it, now);
    _ = try f.store.setPinned(it.id, true);
    var s2 = try Store.load(t.allocator, t.io, f.store.dir);
    defer s2.deinit();
    const back = s2.find(it.id).?;
    try t.expectEqualStrings("Prefers briefs before 7am", back.body);
    try t.expect(back.pinned);
    try t.expectEqualSlices(i64, it.mentions.items, back.mentions.items);
    try t.expectEqual(it.created_s, back.created_s);
    try t.expectEqual(it.terms.len, back.terms.len);
    try t.expect(std.mem.startsWith(u8, it.id, "20261130-"));
}

test "an_items_id_is_its_file_name" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const it = try f.addAt("Prefers tea in the morning", now - day);
    const id = try a.dupe(u8, it.id);
    var d = try Io.Dir.cwd().openDir(t.io, f.store.dir, .{});
    defer d.close(t.io);
    const text = try d.readFileAlloc(t.io, try std.fmt.allocPrint(a, "{s}.md", .{id}), a, .unlimited);
    // a copy under another name is an item of its own
    try d.writeFile(t.io, .{ .sub_path = "backup.md", .data = text });
    // an id line naming a place outside the folder counts for nothing
    try d.writeFile(t.io, .{ .sub_path = "planted.md", .data = "id: ../escaped\ncreated: 2026-11-01T00:00:00Z\nmentions: 2026-11-01T00:00:00Z\npinned: no\nterms: planted\n---\nplanted item\n" });
    try d.writeFile(t.io, .{ .sub_path = "...md", .data = text });
    var s2 = try Store.load(t.allocator, t.io, f.store.dir);
    defer s2.deinit();
    try t.expectEqual(3, s2.items.items.len);
    try t.expect(s2.find("backup") != null);
    try t.expect(s2.find("../escaped") == null);
    _ = try s2.setPinned("planted", true);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, try std.fs.path.join(a, &.{ f.store.dir, "..", "escaped.md" }), .{}));
    // forget removes the item asked for; the copy stays, as its own item
    try t.expect(try s2.forget(id));
    var s3 = try Store.load(t.allocator, t.io, f.store.dir);
    defer s3.deinit();
    try t.expect(s3.find(id) == null);
    try t.expect(s3.find("backup") != null);
}

test "an_item_with_a_date_no_clock_shows_is_read_without_a_crash" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    var d = try Io.Dir.cwd().openDir(t.io, f.store.dir, .{});
    defer d.close(t.io);
    try d.writeFile(t.io, .{ .sub_path = "old.md", .data = "id: old\ncreated: -001-01-01T00:00:00Z\nmentions: -001-01-01T00:00:00Z\npinned: no\nterms: ancient\n---\nvery old\n" });
    var s2 = try Store.load(t.allocator, t.io, f.store.dir);
    defer s2.deinit();
    const it = s2.find("old").?;
    try s2.save(it);
    _ = try s2.render(f.arena.allocator(), now, 20);
    try t.expect(it.created_s >= 0);
    // and a time before year 0 prints, if it ever comes to that
    var tb: [20]u8 = undefined;
    try t.expectEqualStrings("0000", util.isoTime(&tb, -2100 * 365 * day)[0..4]);
}

test "forget_removes_file" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const it = try f.addAt("temporary note to drop", now);
    const id = try f.arena.allocator().dupe(u8, it.id);
    try t.expect(try f.store.forget(id));
    try t.expect(!try f.store.forget(id));
    var s2 = try Store.load(t.allocator, t.io, f.store.dir);
    defer s2.deinit();
    try t.expectEqual(0, s2.items.items.len);
    const listing = try f.store.render(f.arena.allocator(), now, 20);
    try t.expectEqualStrings("No memories yet.", listing);
}
