//! A topic's card: the message pinned at its top saying what its subject
//! holds now, built from harness's state (never by the model, and never
//! put in a prompt: it holds outside text, such as calendar titles and a
//! parcel's sender). `/overview` and the summaries' topic lines are built
//! from the same facts.
const std = @import("std");

/// What a card says: its title, what waits on the owner, what comes next
/// (with times), and the last three things (oldest first).
pub const Facts = struct {
    title: []const u8,
    pending: []const []const u8 = &.{},
    next: []const []const u8 = &.{},
    lately: []const []const u8 = &.{},
};

/// At most this many of each list on a card.
pub const max_each = 5;
/// A line of a card at most (bytes; "…" after a cut).
pub const max_line = 120;

/// "Title\nPending: …\nNext: …\nLately: …" ("none." for an empty part).
pub fn text(a: std.mem.Allocator, f: Facts) ![]const u8 {
    const lately = f.lately[f.lately.len -| 3..];
    return std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}", .{ f.title, try part(a, "Pending", f.pending), try part(a, "Next", f.next), try part(a, "Lately", lately) });
}

/// One item on one line: breaks as spaces, its full stop dropped, cut
/// with "…".
pub fn item(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const one = std.mem.trim(u8, try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, s, "\r", ""), "\n", " "), " \t");
    const bare = std.mem.trimEnd(u8, one, ". ");
    if (bare.len <= max_line) return bare;
    var n: usize = max_line - 3;
    while (n > 0 and (bare[n] & 0xC0) == 0x80) n -= 1;
    return std.fmt.allocPrint(a, "{s}…", .{bare[0..n]});
}

/// "Label: a; b." ("none." when empty; no full stop after a question).
fn part(a: std.mem.Allocator, label: []const u8, list: []const []const u8) ![]const u8 {
    if (list.len == 0) return std.fmt.allocPrint(a, "{s}: none.", .{label});
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}: ", .{label});
    for (list[0..@min(list.len, max_each)], 0..) |x, i| try out.print(a, "{s}{s}", .{ if (i > 0) "; " else "", try item(a, x) });
    if (!endsAsked(out.items)) try out.append(a, '.');
    return out.items;
}

fn endsAsked(s: []const u8) bool {
    return s.len > 0 and (s[s.len - 1] == '?' or s[s.len - 1] == '!');
}

/// `/overview`'s line for topic `name`: its title as a link, then what
/// waits on the owner, else what comes next, else "nothing new".
pub fn overviewLine(a: std.mem.Allocator, name: []const u8, f: Facts) ![]const u8 {
    if (f.pending.len > 0) {
        const first = try item(a, f.pending[0]);
        const more = if (f.pending.len > 1) try std.fmt.allocPrint(a, " (and {d} more)", .{f.pending.len - 1}) else "";
        return std.fmt.allocPrint(a, "{{topic:{s}}}: waiting on you: {s}{s}{s}", .{ name, first, if (more.len == 0 and !endsAsked(first)) "." else "", more });
    }
    if (f.next.len > 0) {
        const first = try item(a, f.next[0]);
        return std.fmt.allocPrint(a, "{{topic:{s}}}: next: {s}{s}", .{ name, first, if (endsAsked(first)) "" else "." });
    }
    return std.fmt.allocPrint(a, "{{topic:{s}}}: nothing new.", .{name});
}

/// A summary's line for topic `name`: its news, then its title as a link.
pub fn summaryLine(a: std.mem.Allocator, name: []const u8, title: []const u8, news: []const u8) ![]const u8 {
    const n = try item(a, news);
    return std.fmt.allocPrint(a, "{s}: {s}{s} ({{topic:{s}}})", .{ title, n, if (endsAsked(n)) "" else ".", name });
}

/// A topic's news for a summary: what waits on the owner, else the last
/// thing posted there, else what comes next; null: nothing.
pub fn newsOf(a: std.mem.Allocator, f: Facts) !?[]const u8 {
    if (f.pending.len > 0) {
        const first = try item(a, f.pending[0]);
        if (f.pending.len == 1) return try std.fmt.allocPrint(a, "waiting on you: {s}", .{first});
        return try std.fmt.allocPrint(a, "{d} waiting on you, first: {s}", .{ f.pending.len, first });
    }
    if (f.lately.len > 0) return f.lately[f.lately.len - 1];
    if (f.next.len > 0) return f.next[0];
    return null;
}

const t = std.testing;

test "a_card_has_its_parts_and_none" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("House\nPending: none.\nNext: boiler service due 2 December; smoke alarm test on Sunday.\nLately: front door closed 18:40; heating back to 21° at 17:00; parcel left at 14:10.", try text(a, .{
        .title = "House",
        .next = &.{ "boiler service due 2 December.", "smoke alarm test on Sunday" },
        .lately = &.{ "an older line", "front door closed 18:40", "heating back to 21° at 17:00", "parcel left at 14:10." },
    }));
    try t.expectEqualStrings("Errands\nPending: Order milk from Frisco?\nNext: none.\nLately: none.", try text(a, .{ .title = "Errands", .pending = &.{"Order milk from Frisco?"} }));
    // a long line is cut, a line break is a space
    const long: [200]u8 = @splat('x');
    const got = try text(a, .{ .title = "Mail and diary", .next = &.{ &long, "Dentist\nat 10:30" } });
    try t.expect(std.mem.indexOf(u8, got, "x…; Dentist at 10:30.") != null);
    // the overview: pending first, else next, else nothing new
    try t.expectEqualStrings("{topic:errands}: waiting on you: Order milk from Frisco? (and 1 more)", try overviewLine(a, "errands", .{ .title = "Errands", .pending = &.{ "Order milk from Frisco?", "Renew the passport" } }));
    try t.expectEqualStrings("{topic:house}: next: boiler service due 2 December.", try overviewLine(a, "house", .{ .title = "House", .next = &.{"boiler service due 2 December."} }));
    try t.expectEqualStrings("{topic:travel}: nothing new.", try overviewLine(a, "travel", .{ .title = "Travel", .lately = &.{"Gate B12"} }));
}

test "a_summary_line_ends_with_its_topic" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Errands: two deliveries today. ({topic:errands})", try summaryLine(a, "errands", "Errands", "two deliveries today"));
    try t.expectEqualStrings("Travel: waiting on you: Check in now? ({topic:travel})", try summaryLine(a, "travel", "Travel", "waiting on you: Check in now?"));
}
