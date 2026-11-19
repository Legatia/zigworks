//! Briefs: collect the topics' feeds and searches without the model, drop
//! what was sent before, and only then, if anything is new, ask the model
//! once to write it up with a link on every line.
const std = @import("std");
const config = @import("config.zig");
const feeds = @import("feeds.zig");
const tools = @import("tools.zig");
const agent = @import("agent.zig");
const model = @import("model.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Links sent before are forgotten after this long.
pub const keep_seen_s: i64 = 60 * 86400;
/// New items per topic passed to the model.
pub const max_new_per_topic = 15;
const feed_max = 4 << 20;

pub const Seen = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged([16]u8, i64) = .empty,

    pub fn init(gpa: std.mem.Allocator) Seen {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Seen) void {
        s.map.deinit(s.gpa);
    }

    fn key(link: []const u8) [16]u8 {
        var d: [32]u8 = undefined;
        Sha256.hash(link, &d, .{});
        return d[0..16].*;
    }

    pub fn clone(s: *const Seen) !Seen {
        return .{ .gpa = s.gpa, .map = try s.map.clone(s.gpa) };
    }

    pub fn has(s: *const Seen, link: []const u8) bool {
        return s.map.contains(key(link));
    }

    pub fn add(s: *Seen, link: []const u8, now_s: i64) !void {
        try s.map.put(s.gpa, key(link), now_s);
    }

    pub fn prune(s: *Seen, now_s: i64) void {
        var it = s.map.iterator();
        var drop: std.ArrayList([16]u8) = .empty;
        defer drop.deinit(s.gpa);
        while (it.next()) |e| if (now_s - e.value_ptr.* > keep_seen_s) drop.append(s.gpa, e.key_ptr.*) catch {};
        for (drop.items) |k| _ = s.map.remove(k);
    }

    pub fn load(s: *Seen, io: Io, path: []const u8) !void {
        const text = Io.Dir.cwd().readFileAlloc(io, path, s.gpa, .limited(64 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer s.gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len < 34 or line[32] != '\t') continue;
            var k: [16]u8 = undefined;
            _ = std.fmt.hexToBytes(&k, line[0..32]) catch continue;
            const when = std.fmt.parseInt(i64, line[33..], 10) catch continue;
            try s.map.put(s.gpa, k, when);
        }
    }

    pub fn save(s: *const Seen, io: Io, path: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        var it = s.map.iterator();
        while (it.next()) |e| try out.print(s.gpa, "{x}\t{d}\n", .{ e.key_ptr, e.value_ptr.* });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    }
};

pub const TopicItems = struct {
    name: []const u8,
    new: []const feeds.Entry,
    notes: []const []const u8,
};

pub const Collected = struct { topics: []const TopicItems };

/// Fetches every source of the brief; nothing here calls the model.
pub fn collect(r: *agent.Run, arena: std.mem.Allocator, b: config.Brief, seen: *const Seen) !Collected {
    var out: std.ArrayList(TopicItems) = .empty;
    for (b.topics) |topic| {
        var new: std.ArrayList(feeds.Entry) = .empty;
        var notes: std.ArrayList([]const u8) = .empty;
        var links_here: std.StringHashMapUnmanaged(void) = .empty;
        for (topic.feeds) |url| {
            if (r.env.stop.load(.acquire)) break;
            const entries = fetchFeed(r, arena, url) catch |e| {
                try notes.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ url, @errorName(e) }));
                continue;
            };
            for (entries) |en| try addNew(arena, &new, &links_here, seen, en);
        }
        for (topic.searches) |q| {
            if (r.env.stop.load(.acquire)) break;
            const entries = searchEntries(r, arena, q) catch |e| {
                try notes.append(arena, try std.fmt.allocPrint(arena, "search \"{s}\": {s}", .{ q, @errorName(e) }));
                continue;
            };
            for (entries) |en| try addNew(arena, &new, &links_here, seen, en);
        }
        const kept = new.items[0..@min(new.items.len, max_new_per_topic)];
        try out.append(arena, .{ .name = topic.name, .new = kept, .notes = notes.items });
    }
    return .{ .topics = out.items };
}

fn addNew(arena: std.mem.Allocator, new: *std.ArrayList(feeds.Entry), here: *std.StringHashMapUnmanaged(void), seen: *const Seen, en: feeds.Entry) !void {
    if (seen.has(en.link) or here.contains(en.link)) return;
    try here.put(arena, en.link, {});
    try new.append(arena, en);
}

fn fetchFeed(r: *agent.Run, arena: std.mem.Allocator, url: []const u8) ![]const feeds.Entry {
    const d = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        break :blk r.gate.decide(arena, .fetch, url, util.nowSeconds(r.io), .{ .scheduled = true, .brief_source = true });
    };
    try r.log.write(.gate, false, .{ .run = r.label, .tool = "fetch", .decision = @tagName(d.action), .why = d.why, .arg = url });
    if (d.action != .allow) return error.Refused;
    const g = try tools.get(r.gpa, r.io, arena, url, &.{}, feed_max);
    if (g.status != 200) return error.NotFound;
    if (g.truncated) return error.FeedTooLarge;
    return feeds.parse(arena, g.body);
}

fn searchEntries(r: *agent.Run, arena: std.mem.Allocator, q: []const u8) ![]const feeds.Entry {
    const d = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        break :blk r.gate.decide(arena, .search, q, util.nowSeconds(r.io), .{ .scheduled = true, .brief_source = true });
    };
    try r.log.write(.gate, false, .{ .run = r.label, .tool = "search", .decision = @tagName(d.action), .why = d.why, .arg = q });
    if (d.action != .allow) return error.Refused;
    const key = r.env.search_key orelse return error.NoSearchKey;
    var url: std.ArrayList(u8) = .empty;
    try url.print(arena, "{s}/res/v1/web/search?count=8&freshness=pd&q=", .{std.mem.trimEnd(u8, r.env.search_url, "/")});
    for (q) |c| {
        if (std.ascii.isAlphanumeric(c)) try url.append(arena, c) else try url.print(arena, "%{X:0>2}", .{c});
    }
    const g = try tools.get(r.gpa, r.io, arena, url.items, &.{
        .{ .name = "X-Subscription-Token", .value = key },
        .{ .name = "Accept", .value = "application/json" },
    }, feed_max);
    if (g.status != 200) return error.SearchFailed;
    const v = jv.parse(arena, g.body) orelse return error.SearchFailed;
    var out: std.ArrayList(feeds.Entry) = .empty;
    for (jv.arr(jv.at(v, &.{ "web", "results" })) orelse &.{}) |res| {
        const link = jv.str(jv.get(res, "url")) orelse continue;
        try out.append(arena, .{ .title = jv.str(jv.get(res, "title")) orelse link, .link = link, .date = jv.str(jv.get(res, "age")) orelse "" });
    }
    return out.items;
}

pub const Written = struct {
    text: []const u8,
    /// Links to mark as seen once the brief has been delivered.
    links: []const []const u8,
    model_calls: u32,
};

const brief_instructions =
    \\Write the owner's brief from the new items below. Group by topic. One short line per item worth reading, in plain words, ending with its link in parentheses. Leave out items that repeat another. No introduction and no closing remarks.
;

/// The brief's text: no model call when nothing is new.
pub fn compose(r: *agent.Run, arena: std.mem.Allocator, b: config.Brief, c: Collected) !Written {
    var links: std.ArrayList([]const u8) = .empty;
    var quiet: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList(u8) = .empty;
    var items: std.ArrayList(u8) = .empty;
    for (c.topics) |tp| {
        for (tp.notes) |n| try notes.print(arena, "Could not read {s}\n", .{n});
        if (tp.new.len == 0) {
            try quiet.append(arena, tp.name);
            continue;
        }
        try items.print(arena, "\nTopic: {s}\n", .{tp.name});
        {
            // items may be changed or forgotten by the chat meanwhile
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            const known = try r.mem.search(arena, tp.name);
            for (known) |it| try items.print(arena, "(the owner: {s})\n", .{it.body});
        }
        for (tp.new) |en| {
            try items.print(arena, "- {s} | {s}{s}{s}\n", .{ en.title, en.link, if (en.date.len > 0) " | " else "", en.date });
            try links.append(arena, en.link);
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var calls: u32 = 0;
    if (links.items.len > 0) {
        calls = 1;
        const msg = try std.fmt.allocPrint(arena, "Brief \"{s}\".\n{s}", .{ b.name, items.items });
        const system = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ brief_instructions, r.extra_instructions });
        if (r.client.send(arena, system, &.{.{ .role = .user, .blocks = &.{.{ .text = msg }} }}, &.{})) |reply| {
            try r.log.write(.model, false, .{ .run = r.label, .result = "ok", .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens });
            try out.appendSlice(arena, try reply.text(arena));
        } else |e| {
            try r.log.write(.model, false, .{ .run = r.label, .result = @errorName(e), .detail = r.client.lastError() });
            // the items themselves still reach the owner
            try out.print(arena, "{s} The new items:\n", .{if (e == error.BudgetSpent) "Model budget used up." else "The model could not write the brief."});
            for (c.topics) |tp| for (tp.new) |en| try out.print(arena, "- {s} ({s})\n", .{ en.title, en.link });
        }
    }
    if (quiet.items.len > 0) {
        if (out.items.len > 0) try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, "Nothing new on: ");
        for (quiet.items, 0..) |q, i| try out.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", q });
        try out.append(arena, '.');
    }
    if (notes.items.len > 0) try out.print(arena, "\n\n{s}", .{std.mem.trimEnd(u8, notes.items, "\n")});
    try r.log.write(.brief, false, .{ .name = b.name, .new_items = links.items.len, .model_calls = calls });
    return .{ .text = out.items, .links = links.items, .model_calls = calls };
}

// ---- tests ----

const t = std.testing;
const gate = @import("gate.zig");
const log_mod = @import("log.zig");
const memory = @import("memory.zig");
const rules = @import("rules.zig");

const Fix = struct {
    e: model.TestEnv,
    client: model.Client,
    grants: gate.Grants,
    g: gate.Gate,
    log: log_mod.Log,
    mem: memory.Store,
    lock: Io.Mutex = .init,
    stop: std.atomic.Value(bool) = .init(false),
    run: agent.Run,
    seen: Seen,

    fn init(f: *Fix) !void {
        try f.e.init();
        const a = f.e.arena.allocator();
        try f.e.tmp.dir.createDirPath(t.io, "ws");
        const ws = try f.e.tmp.dir.realPathFileAlloc(t.io, "ws", a);
        f.client = try f.e.client();
        f.grants = .init(t.allocator);
        f.g = .{ .io = t.io, .rules = &.{}, .grants = &f.grants, .workspace = ws };
        f.log = try log_mod.Log.open(t.allocator, t.io, try std.fs.path.join(a, &.{ f.e.dir, "actions.jsonl" }));
        f.mem = try memory.Store.load(t.allocator, t.io, try std.fs.path.join(a, &.{ f.e.dir, "memory" }));
        f.lock = .init;
        f.stop = .init(false);
        f.seen = .init(t.allocator);
        f.run = .{
            .gpa = t.allocator,
            .io = t.io,
            .client = &f.client,
            .gate = &f.g,
            .log = &f.log,
            .mem = &f.mem,
            .lock = &f.lock,
            .env = .{ .gpa = t.allocator, .io = t.io, .workspace = ws, .stop = &f.stop, .search_url = try f.e.url(), .search_key = "k" },
            .limits = .{},
            .scheduled = true,
            .label = "brief morning",
        };
    }

    fn deinit(f: *Fix) void {
        f.seen.deinit();
        f.mem.deinit();
        f.log.close();
        f.grants.deinit();
        f.client.deinit();
        f.e.deinit();
    }

    fn brief(f: *Fix, feed_names: []const []const u8) !config.Brief {
        const a = f.e.arena.allocator();
        var urls: std.ArrayList([]const u8) = .empty;
        for (feed_names) |n| try urls.append(a, try std.fmt.allocPrint(a, "{s}/page/{s}", .{ try f.e.url(), n }));
        const topics = try a.alloc(config.Topic, 1);
        topics[0] = .{ .name = "Zig", .feeds = urls.items, .searches = &.{} };
        return .{ .name = "morning", .at_minutes = 420, .topics = topics };
    }

    fn feed(f: *Fix, name: []const u8, links: []const []const u8) !void {
        const a = f.e.arena.allocator();
        var x: std.ArrayList(u8) = .empty;
        try x.appendSlice(a, "<rss><channel>");
        for (links, 0..) |l, i| try x.print(a, "<item><title>Item {d}</title><link>{s}</link></item>", .{ i, l });
        try x.appendSlice(a, "</channel></rss>");
        try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(a, "pages/{s}", .{name}), .data = x.items });
    }
};

test "seen_items_dropped_and_pruned_after_60_days" {
    var s: Seen = .init(t.allocator);
    defer s.deinit();
    const now: i64 = 1796083200;
    try s.add("https://a.com/1", now - 61 * 86400);
    try s.add("https://a.com/2", now - 59 * 86400);
    s.prune(now);
    try t.expect(!s.has("https://a.com/1"));
    try t.expect(s.has("https://a.com/2"));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const p = try std.fs.path.join(arena.allocator(), &.{ try tmp.dir.realPathFileAlloc(t.io, ".", arena.allocator()), "seen" });
    try s.save(t.io, p);
    var s2: Seen = .init(t.allocator);
    defer s2.deinit();
    try s2.load(t.io, p);
    try t.expect(s2.has("https://a.com/2"));
    try t.expect(!s2.has("https://a.com/3"));
}

test "nothing_new_needs_no_model_call" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("zig.xml", &.{ "https://z.org/1", "https://z.org/2" });
    try f.seen.add("https://z.org/1", 0);
    try f.seen.add("https://z.org/2", 0);
    const a = f.e.arena.allocator();
    const b = try f.brief(&.{"zig.xml"});
    const c = try collect(&f.run, a, b, &f.seen);
    const w = try compose(&f.run, a, b, c);
    try t.expectEqualStrings("Nothing new on: Zig.", w.text);
    try t.expectEqual(0, f.e.server.modelRequests());
    try t.expectEqual(0, w.links.len);
}

test "new_items_one_model_call_with_links" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("zig.xml", &.{ "https://z.org/old", "https://z.org/new" });
    try f.seen.add("https://z.org/old", 0);
    try f.e.script(1, model.textReply("Zig: something new (https://z.org/new)"));
    const a = f.e.arena.allocator();
    const b = try f.brief(&.{"zig.xml"});
    const w = try compose(&f.run, a, b, try collect(&f.run, a, b, &f.seen));
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqualStrings("Zig: something new (https://z.org/new)", w.text);
    try t.expectEqual(1, w.links.len);
    try t.expectEqualStrings("https://z.org/new", w.links[0]);
    const req = try f.e.request(1);
    try t.expect(std.mem.indexOf(u8, req, "https://z.org/new") != null);
    try t.expect(std.mem.indexOf(u8, req, "https://z.org/old") == null);
}

test "failed_feed_becomes_note" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const b = try f.brief(&.{"missing.xml"});
    const w = try compose(&f.run, a, b, try collect(&f.run, a, b, &f.seen));
    try t.expect(std.mem.startsWith(u8, w.text, "Nothing new on: Zig."));
    try t.expect(std.mem.indexOf(u8, w.text, "Could not read") != null);
    try t.expect(std.mem.indexOf(u8, w.text, "NotFound") != null);
}

test "budget_spent_still_sends_the_items" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.feed("zig.xml", &.{"https://z.org/a"});
    try f.e.script(1, "{\"status\":402}");
    const a = f.e.arena.allocator();
    const b = try f.brief(&.{"zig.xml"});
    const w = try compose(&f.run, a, b, try collect(&f.run, a, b, &f.seen));
    try t.expect(std.mem.startsWith(u8, w.text, "Model budget used up."));
    try t.expect(std.mem.indexOf(u8, w.text, "https://z.org/a") != null);
}
