//! Topics: one chat with the bot, filed by subject. The butler's subjects
//! and their titles, a topic's link (`https://t.me/<bot>/<thread>`, which
//! opens only for the owner), and message entities (offsets in bytes here,
//! UTF-16 units in telegram.zig). Core builds the lines that carry links
//! itself (`Core.Linked`): only harness's own words become links, never a
//! run's text or outside text. `expand` reads `{topic:NAME}` tokens; core
//! no longer uses it on anything it sends.
const std = @import("std");
const telegram = @import("telegram.zig");

pub const Entity = telegram.Entity;

/// The butler's subjects: each a topic when topics are in use.
pub const Subject = enum { house, travel, errands, mail, work };

pub fn title(s: Subject) []const u8 {
    return switch (s) {
        .house => "House",
        .travel => "Travel",
        .errands => "Errands",
        .mail => "Mail and diary",
        .work => "Work",
    };
}

/// What the topic is about, as setup writes it (the turn's context).
pub fn focus(s: Subject) []const u8 {
    return switch (s) {
        .house => "the house: its events, away mode, the doorbell, upkeep, the car's warm-up and readings.",
        .travel => "trips, flights, check-in, leaving for the airport, packing.",
        .errands => "the shared list, reorders, deliveries.",
        .mail => "others' mail, drafts, prep notes before meetings, people from the calendar.",
        .work => "the exchange between main and its helpers.",
    };
}

/// The topic's link: it opens only for the owner.
pub fn link(a: std.mem.Allocator, bot: []const u8, thread: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "https://t.me/{s}/{d}", .{ bot, thread });
}

/// `{topic:NAME}`: the topic's title, linked, once sent.
pub fn token(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{topic:{s}}}", .{name});
}

/// Where a token's topic is: its title, and its link ("": none, the title
/// goes plain).
pub const Target = struct { title: []const u8, url: []const u8 = "" };

pub const Resolver = struct {
    ctx: *anyopaque,
    find: *const fn (ctx: *anyopaque, a: std.mem.Allocator, name: []const u8) ?Target,
};

pub const Rich = struct { text: []const u8, entities: []const Entity };

/// `text` with each `{topic:NAME}` its title (a text_link where the
/// resolver gives a link); `in` (entities of `text`) moved with it.
pub fn expand(a: std.mem.Allocator, text: []const u8, in: []const Entity, r: Resolver) !Rich {
    var out: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(Entity) = .empty;
    // where each replaced token was (in `text`) and how much it moved what follows
    const Moved = struct { at: usize, end: usize, delta: isize };
    var moved: std.ArrayList(Moved) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "{topic:")) |at| {
        const end = std.mem.indexOfScalarPos(u8, text, at, '}') orelse break;
        const name = text[at + "{topic:".len .. end];
        const target = if (name.len > 0 and name.len <= 32) r.find(r.ctx, a, name) else null;
        try out.appendSlice(a, text[i..at]);
        if (target) |tg| {
            if (tg.url.len > 0) try links.append(a, .{ .kind = .text_link, .offset = out.items.len, .len = tg.title.len, .url = tg.url });
            try out.appendSlice(a, tg.title);
            try moved.append(a, .{ .at = at, .end = end + 1, .delta = @as(isize, @intCast(tg.title.len)) - @as(isize, @intCast(end + 1 - at)) });
        } else try out.appendSlice(a, text[at .. end + 1]);
        i = end + 1;
    }
    try out.appendSlice(a, text[i..]);
    // `in`'s entities, where their text went
    const map = struct {
        fn f(ms: []const Moved, pos: usize) usize {
            var p: isize = @intCast(pos);
            for (ms) |m| if (m.end <= pos) {
                p += m.delta;
            };
            return @intCast(@max(p, 0));
        }
    }.f;
    var all: std.ArrayList(Entity) = .empty;
    try all.appendSlice(a, links.items);
    for (in) |e| {
        const start = map(moved.items, e.offset);
        const stop = map(moved.items, e.offset + e.len);
        var x = e;
        x.offset = start;
        x.len = stop - start;
        try all.append(a, x);
    }
    std.mem.sort(Entity, all.items, {}, struct {
        fn lt(_: void, x: Entity, y: Entity) bool {
            return x.offset < y.offset;
        }
    }.lt);
    return .{ .text = out.items, .entities = all.items };
}

const t = std.testing;

const TestTopics = struct {
    fn find(ctx: *anyopaque, a: std.mem.Allocator, name: []const u8) ?Target {
        _ = ctx;
        _ = a;
        if (std.mem.eql(u8, name, "errands")) return .{ .title = "Errands", .url = "https://t.me/b/5003" };
        if (std.mem.eql(u8, name, "mail")) return .{ .title = "Mail and diary" };
        return null;
    }
};

test "tokens_become_titles_with_links" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    const r: Resolver = .{ .ctx = &dummy, .find = TestTopics.find };
    // a quote before the token moves with it
    const text = "Kraków: two deliveries. ({topic:errands}) More in {topic:mail}; {topic:nope} stays.";
    const q = std.mem.indexOf(u8, text, "More").?;
    const got = try expand(a, text, &.{.{ .kind = .expandable_blockquote, .offset = q, .len = 4 }}, r);
    try t.expectEqualStrings("Kraków: two deliveries. (Errands) More in Mail and diary; {topic:nope} stays.", got.text);
    try t.expectEqual(2, got.entities.len);
    const link_e = got.entities[0];
    try t.expectEqual(.text_link, link_e.kind);
    try t.expectEqualStrings("Errands", got.text[link_e.offset .. link_e.offset + link_e.len]);
    try t.expectEqualStrings("https://t.me/b/5003", link_e.url);
    const quote = got.entities[1];
    try t.expectEqualStrings("More", got.text[quote.offset .. quote.offset + quote.len]);
    try t.expectEqualStrings("https://t.me/harness_test_bot/5012", try link(a, "harness_test_bot", 5012));
    try t.expectEqualStrings("{topic:house}", try token(a, "house"));
}
