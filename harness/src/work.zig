//! The Work topic: one post per `delegate` call, built from the log
//! (never by the model): a header with the request's first line and where
//! the answer went, a folded quote per helper (its definition, task,
//! steps, the tools it used, its answer, its tokens), and the totals. It
//! is sent with message entities (no parse_mode): outside text in an
//! answer is shown as it is and never makes markup. It is never put in a
//! prompt.
const std = @import("std");
const jv = @import("jv.zig");
const topics = @import("topics.zig");

pub const Entity = topics.Entity;

/// A post that fits one message.
pub const max_post = 4096;
/// An answer gets at least this much of what the header leaves.
pub const min_answer = 200;
/// Helpers shown at most.
pub const max_helpers = 8;

pub const Post = struct { text: []const u8, entities: []const Entity };

/// Where the answer went: the conversation's title, and its link ("":
/// none, the title goes plain); whether the run was private (then only
/// who, the step counts and the tokens).
pub const Header = struct { conversation: []const u8, title: []const u8 = "", url: []const u8 = "", private: bool = false };

/// The post for helpers `rids` of run `parent`, from the log `text`; null
/// when the log has none of them.
pub fn build(a: std.mem.Allocator, text: []const u8, parent: u64, rids: []const u64, h: Header) !?Post {
    const Help = struct {
        rid: u64,
        agent: []const u8 = "",
        task: []const u8 = "",
        steps: i64 = 0,
        tools: std.ArrayList([]const u8) = .empty,
        answer: []const u8 = "",
        ended: []const u8 = "",
        in: i64 = 0,
        out: i64 = 0,
        calls: i64 = 0,
        found: bool = false,
    };
    const shown = rids[0..@min(rids.len, max_helpers)];
    const helps = try a.alloc(Help, shown.len);
    for (shown, helps) |rid, *x| x.* = .{ .rid = rid };
    var request: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = jv.parse(a, line) orelse continue;
        const rid: u64 = @intCast(@max(0, jv.int(jv.get(v, "rid")) orelse continue));
        const seq: u64 = @intCast(@max(0, jv.int(jv.get(v, "seq")) orelse continue));
        const kind = jv.str(jv.get(v, "kind")) orelse "";
        if (rid == parent and seq == rid) request = jv.str(jv.get(v, "text")) orelse "";
        const x = for (helps) |*y| {
            if (y.rid == rid) break y;
        } else continue;
        x.found = true;
        if (seq == rid) {
            x.agent = jv.str(jv.get(v, "agent")) orelse "";
            x.task = jv.str(jv.get(v, "text")) orelse "";
        } else if (std.mem.eql(u8, kind, "model")) {
            if (!std.mem.eql(u8, jv.str(jv.get(v, "result")) orelse "", "ok")) continue;
            x.in += jv.int(jv.get(v, "input_tokens")) orelse 0;
            x.out += jv.int(jv.get(v, "output_tokens")) orelse 0;
            x.calls += 1;
        } else if (std.mem.eql(u8, kind, "tool")) {
            if (jv.get(v, "event") != null) continue;
            const tool = jv.str(jv.get(v, "tool")) orelse continue;
            for (x.tools.items) |y| {
                if (std.mem.eql(u8, y, tool)) break;
            } else try x.tools.append(a, tool);
        } else if (std.mem.eql(u8, kind, "turn") and jv.get(v, "steps") != null) {
            x.steps = jv.int(jv.get(v, "steps")) orelse 0;
            x.answer = jv.str(jv.get(v, "answer")) orelse "";
            x.ended = jv.str(jv.get(v, "ended_by")) orelse "";
        }
    }
    var kept: std.ArrayList(Help) = .empty;
    for (helps) |x| if (x.found) try kept.append(a, x);
    if (kept.items.len == 0) return null;
    // the header and each helper's head, then the answers share the rest
    const title = if (h.title.len > 0) h.title else h.conversation;
    const first = if (h.private) "A private run's helpers.\nAnswer in " else try std.fmt.allocPrint(a, "For: {s}\nAnswer in ", .{try cut(a, firstLine(request), 200)});
    const head = try std.fmt.allocPrint(a, "{s}{s}.\n", .{ first, title });
    var tin: i64 = 0;
    var tout: i64 = 0;
    var tcalls: i64 = 0;
    for (kept.items) |x| {
        tin += x.in;
        tout += x.out;
        tcalls += x.calls;
    }
    const total = try std.fmt.allocPrint(a, "Altogether: {d} helper{s}, {s} tokens in, {s} out, {d} model call{s}.", .{ kept.items.len, if (kept.items.len == 1) "" else "s", try thousands(a, tin), try thousands(a, tout), tcalls, if (tcalls == 1) "" else "s" });
    // the heads with tasks cut shorter until the answers get their floor;
    // past that, the answers share what is left
    const budget = max_post - 64;
    var task_cap: usize = 200;
    var heads: std.ArrayList([]const u8) = .empty;
    var fixed: usize = 0;
    while (true) {
        heads = .empty;
        fixed = head.len + total.len;
        for (kept.items) |x| {
            const hd = try headOf(a, x.agent, x.task, x.steps, x.tools.items, x.in, x.out, x.calls, x.ended, task_cap, h.private);
            fixed += hd.len + 1;
            try heads.append(a, hd);
        }
        if (h.private or fixed + kept.items.len * min_answer <= budget or task_cap <= 24) break;
        task_cap = task_cap * 2 / 3;
    }
    const share = (budget -| fixed) / kept.items.len;
    var out: std.ArrayList(u8) = .empty;
    var ents: std.ArrayList(Entity) = .empty;
    try out.appendSlice(a, first);
    if (h.url.len > 0) try ents.append(a, .{ .kind = .text_link, .offset = out.items.len, .len = title.len, .url = h.url });
    try out.print(a, "{s}.\n", .{title});
    for (kept.items, heads.items) |x, hd| {
        const at = out.items.len;
        try out.appendSlice(a, hd);
        if (!h.private) try out.appendSlice(a, try cut(a, std.mem.trim(u8, x.answer, " \t\r\n"), share));
        try ents.append(a, .{ .kind = .expandable_blockquote, .offset = at, .len = out.items.len - at });
        try out.append(a, '\n');
    }
    try out.appendSlice(a, total);
    return .{ .text = out.items, .entities = ents.items };
}

/// A helper's head in the post: its definition and task, then its numbers.
fn headOf(a: std.mem.Allocator, agent: []const u8, task: []const u8, steps: i64, used: []const []const u8, in: i64, out: i64, calls: i64, ended: []const u8, task_cap: usize, private: bool) ![]const u8 {
    const stats = try std.fmt.allocPrint(a, "{d} step{s}; {s}{s} tokens in, {s} out, {d} model call{s}{s}{s}", .{
        steps,                                                             if (steps == 1) "" else "s",
        if (private) "" else try std.fmt.allocPrint(a, "used {s}; ", .{if (used.len > 0) try std.mem.join(a, ", ", used) else "no tools"}),
        try thousands(a, in),                                              try thousands(a, out),
        calls,                                                             if (calls == 1) "" else "s",
        if (ended.len > 0) "; ended early: " else "",                      try cut(a, ended, 80),
    });
    if (private) return std.fmt.allocPrint(a, "{s}: {s}", .{ agent, stats });
    return std.fmt.allocPrint(a, "{s}: {s}\n{s}\n", .{ agent, try cut(a, firstLine(task), task_cap), stats });
}

fn firstLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len], " \t\r");
}

/// `s` cut to `max` bytes with "…" (at a UTF-8 boundary).
fn cut(a: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    var n = max -| 3;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return std.fmt.allocPrint(a, "{s}…", .{s[0..n]});
}

/// 1,234 for 1234.
fn thousands(a: std.mem.Allocator, n: i64) ![]const u8 {
    const digits = try std.fmt.allocPrint(a, "{d}", .{@abs(n)});
    var out: std.ArrayList(u8) = .empty;
    if (n < 0) try out.append(a, '-');
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(a, ',');
        try out.append(a, d);
    }
    return out.items;
}

/// The post as plain text (`/work`).
pub fn plain(p: Post) []const u8 {
    return p.text;
}

const t = std.testing;

/// A run's log lines: its first, a model call, the tools, its end.
fn runLines(a: std.mem.Allocator, out: *std.ArrayList(u8), seq: *u64, rid: u64, parent: ?u64, agent: []const u8, task: []const u8, tools_used: []const []const u8, answer: []const u8, private: bool) !void {
    const q = struct {
        fn s(al: std.mem.Allocator, x: []const u8, p: bool) ![]const u8 {
            if (p) return std.fmt.allocPrint(al, "{{\"bytes\":{d},\"hmac\":\"00\"}}", .{x.len});
            return std.fmt.allocPrint(al, "{f}", .{std.json.fmt(x, .{})});
        }
    }.s;
    try out.print(a, "{{\"seq\":{d},\"kind\":\"turn\",\"rid\":{d},\"conversation\":\"travel\",\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"{s}\"{s},\"text\":{s}}}\n", .{ rid, rid, agent, if (parent) |p| try std.fmt.allocPrint(a, ",\"parent\":{d}", .{p}) else "", try q(a, task, private) });
    seq.* = rid + 1;
    try out.print(a, "{{\"seq\":{d},\"kind\":\"model\",\"rid\":{d},\"result\":\"ok\",\"input_tokens\":1200,\"output_tokens\":80}}\n", .{ seq.*, rid });
    seq.* += 1;
    for (tools_used) |tl| {
        try out.print(a, "{{\"seq\":{d},\"kind\":\"tool\",\"rid\":{d},\"agent\":\"{s}\",\"tool\":\"{s}\",\"arg\":\"x\",\"is_error\":false}}\n", .{ seq.*, rid, agent, tl });
        seq.* += 1;
    }
    try out.print(a, "{{\"seq\":{d},\"kind\":\"model\",\"rid\":{d},\"result\":\"ok\",\"input_tokens\":300,\"output_tokens\":40}}\n", .{ seq.*, rid });
    seq.* += 1;
    try out.print(a, "{{\"seq\":{d},\"kind\":\"turn\",\"rid\":{d},\"answer\":{s},\"steps\":{d}}}\n", .{ seq.*, rid, try q(a, answer, private), 1 + tools_used.len });
    seq.* += 1;
}

/// A delegated run's log: the owner's request (rid 10) and `n` helpers.
fn logOf(a: std.mem.Allocator, n: usize, answer: []const u8, private: bool) !struct { text: []const u8, rids: []const u64 } {
    var out: std.ArrayList(u8) = .empty;
    var seq: u64 = 10;
    try out.print(a, "{{\"seq\":10,\"kind\":\"turn\",\"rid\":10,\"conversation\":\"travel\",\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"main\",\"text\":{s}}}\n", .{if (private) "{\"bytes\":30,\"hmac\":\"00\"}" else "\"Find a flat in Kraków\\nwith a balcony\""});
    var rids: std.ArrayList(u64) = .empty;
    var rid: u64 = 100;
    for (0..n) |i| {
        try runLines(a, &out, &seq, rid, 10, if (i % 2 == 0) "researcher" else "helper", try std.fmt.allocPrint(a, "Look at listing {d}", .{i + 1}), &.{ "search", "fetch", "fetch" }, answer, private);
        try rids.append(a, rid);
        rid += 100;
    }
    return .{ .text = out.items, .rids = rids.items };
}

test "a_post_has_a_folded_quote_per_helper" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try logOf(a, 2, "Two flats: Długa 5 (2,900 PLN) and Rynek 1.", false);
    const p = (try build(a, lg.text, 10, lg.rids, .{ .conversation = "travel" })).?;
    try t.expect(std.mem.startsWith(u8, p.text, "For: Find a flat in Kraków\nAnswer in travel.\n"));
    // with the topic's title and link: the title is the link
    const linked = (try build(a, lg.text, 10, lg.rids, .{ .conversation = "travel", .title = "Travel", .url = "https://t.me/b/5002" })).?;
    try t.expect(std.mem.startsWith(u8, linked.text, "For: Find a flat in Kraków\nAnswer in Travel.\n"));
    try t.expectEqual(Entity.Kind.text_link, linked.entities[0].kind);
    try t.expectEqualStrings("Travel", linked.text[linked.entities[0].offset .. linked.entities[0].offset + linked.entities[0].len]);
    var quotes: usize = 0;
    for (p.entities) |e| if (e.kind == .expandable_blockquote) {
        quotes += 1;
        const q = p.text[e.offset .. e.offset + e.len];
        try t.expect(std.mem.startsWith(u8, q, if (quotes == 1) "researcher: Look at listing 1" else "helper: Look at listing 2"));
        try t.expect(std.mem.indexOf(u8, q, "4 steps; used search, fetch; 1,500 tokens in, 120 out, 2 model calls") != null);
        try t.expect(std.mem.endsWith(u8, q, "Two flats: Długa 5 (2,900 PLN) and Rynek 1."));
    };
    try t.expectEqual(2, quotes);
    try t.expect(std.mem.endsWith(u8, p.text, "\nAltogether: 2 helpers, 3,000 tokens in, 240 out, 4 model calls."));
    // a helper of another call is not in it; nothing at all: null
    try t.expectEqual(null, try build(a, lg.text, 10, &.{999}, .{ .conversation = "travel" }));
}

test "eight_long_answers_fit_4096" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long: [3000]u8 = @splat('w');
    const lg = try logOf(a, 8, &long, false);
    const p = (try build(a, lg.text, 10, lg.rids, .{ .conversation = "travel" })).?;
    try t.expect(p.text.len <= max_post - 64);
    var quotes: usize = 0;
    for (p.entities) |e| if (e.kind == .expandable_blockquote) {
        quotes += 1;
        const q = p.text[e.offset .. e.offset + e.len];
        try t.expect(std.mem.endsWith(u8, q, "…"));
        try t.expect(std.mem.count(u8, q, "w") >= min_answer);
    };
    try t.expectEqual(8, quotes);
}

test "outside_text_in_a_work_post_is_shown_as_it_is" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try logOf(a, 1, "<b>Cheap</b> *now* _only_ [here](https://evil.example) {topic:main}", false);
    const p = (try build(a, lg.text, 10, lg.rids, .{ .conversation = "travel" })).?;
    try t.expect(std.mem.indexOf(u8, p.text, "<b>Cheap</b> *now* _only_ [here](https://evil.example)") != null);
    // no entity but the folded quote (the header's link comes at send time)
    for (p.entities) |e| try t.expectEqual(Entity.Kind.expandable_blockquote, e.kind);
}

test "a_private_run_posts_metadata_only" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try logOf(a, 2, "Secret flat at Długa 5.", true);
    const p = (try build(a, lg.text, 10, lg.rids, .{ .conversation = "travel", .private = true })).?;
    try t.expect(std.mem.startsWith(u8, p.text, "A private run's helpers.\n"));
    for ([_][]const u8{ "Długa", "Find a flat", "listing", "search, fetch" }) |w| try t.expect(std.mem.indexOf(u8, p.text, w) == null);
    try t.expect(std.mem.indexOf(u8, p.text, "researcher: 4 steps; 1,500 tokens in, 120 out") != null);
}

test "long_tasks_and_a_long_request_fit_one_message" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    const request: [1500]u8 = @splat('r');
    try out.print(a, "{{\"seq\":10,\"kind\":\"turn\",\"rid\":10,\"conversation\":\"travel\",\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"main\",\"text\":\"{s}\"}}\n", .{&request});
    var seq: u64 = 10;
    var rids: std.ArrayList(u64) = .empty;
    const task: [400]u8 = @splat('k');
    const answer: [1500]u8 = @splat('w');
    for (0..max_helpers) |i| {
        const rid: u64 = 100 * (i + 1);
        try runLines(a, &out, &seq, rid, 10, "researcher", &task, &.{ "search", "fetch" }, &answer, false);
        try rids.append(a, rid);
    }
    const p = (try build(a, out.items, 10, rids.items, .{ .conversation = "travel" })).?;
    try t.expect(p.text.len <= max_post - 64);
    var quotes: usize = 0;
    for (p.entities) |e| if (e.kind == .expandable_blockquote) {
        quotes += 1;
        try t.expect(e.offset + e.len <= p.text.len);
    };
    try t.expectEqual(max_helpers, quotes);
}
