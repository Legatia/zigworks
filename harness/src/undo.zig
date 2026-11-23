//! Undo: a run's changes taken back, file by file, from its snapshots
//! (`snapshots.Store.undo` does the work). Here: the Undo button's data,
//! `u<run>-<token>`, whose token is an HMAC of the run's number with the
//! log's key, so a press is checked with no state kept for it; the line a
//! run's message ends with; and what an undo says.
const std = @import("std");
const snapshots = @import("snapshots.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// The button's label.
pub const label = "Undo";

/// The first 16 hex digits of the HMAC-SHA256 of the run's number (in
/// decimal) with `key`.
pub fn token(key: *const [32]u8, rid: u64) [16]u8 {
    var num: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&num, "{d}", .{rid}) catch unreachable;
    var d: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&d, text, key);
    return std.fmt.bytesToHex(d[0..8].*, .lower);
}

/// Run `rid`'s Undo button data: `u<run>-<token>`.
pub fn data(buf: *[48]u8, key: *const [32]u8, rid: u64) []const u8 {
    const tk = token(key, rid);
    return std.fmt.bufPrint(buf, "u{d}-{s}", .{ rid, &tk }) catch unreachable;
}

/// The run an Undo button's data names when its token is right; null
/// when it is not (another key, another run, a changed digit) or the data
/// is no Undo's.
pub fn check(key: *const [32]u8, d: []const u8) ?u64 {
    const rid = runOf(d) orelse return null;
    const got = d[std.mem.indexOfScalar(u8, d, '-').? + 1 ..];
    if (got.len != 16) return null;
    const want = token(key, rid);
    var diff: u8 = 0;
    for (want, got) |x, y| diff |= x ^ y;
    return if (diff == 0) rid else null;
}

/// The run an Undo button's data names, its token unchecked (the
/// terminal prints `/undo RUN` for it); null for other data.
pub fn runOf(d: []const u8) ?u64 {
    if (d.len < 3 or d[0] != 'u') return null;
    const dash = std.mem.indexOfScalar(u8, d, '-') orelse return null;
    if (dash < 2) return null;
    for (d[1..dash]) |ch| if (!std.ascii.isDigit(ch)) return null;
    const rid = std.fmt.parseInt(u64, d[1..dash], 10) catch return null;
    return if (rid == 0) null else rid;
}

/// "Changed 3 files in notes/ and site/.": what a run changed, in the
/// folders as the store names them (`/` is the workspace), written in
/// `buf`; when that is too short, the number of folders instead.
pub fn line(buf: []u8, files: usize, folders: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    whole(&w, files, folders) catch
        return std.fmt.bufPrint(buf, "Changed {d} file{s} in {d} folders.", .{ files, plural(files), folders.len }) catch "";
    return w.buffered();
}

fn whole(w: *std.Io.Writer, files: usize, folders: []const []const u8) !void {
    try w.print("Changed {d} file{s} in ", .{ files, plural(files) });
    for (folders, 0..) |f, i| {
        if (i > 0) try w.writeAll(if (i + 1 == folders.len) " and " else ", ");
        if (std.mem.eql(u8, f, "/")) try w.writeAll("the workspace") else try w.print("{s}/", .{f});
    }
    try w.writeAll(".");
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// What an undo of run `rid` says. `pressed`: from its Undo button, so
/// the run certainly changed files, and a run with no snapshot kept is
/// too old.
pub fn outcome(a: std.mem.Allocator, rid: u64, res: snapshots.Undone, pressed: bool) ![]const u8 {
    if (!res.found) {
        if (pressed) return "Too old to undo: its snapshots were pruned.";
        return std.fmt.allocPrint(a, "Nothing kept for run {d}: too old to undo, or it changed no folder that keeps snapshots.", .{rid});
    }
    if (res.folders.len == 0 and res.pruned.len > 0) return "Too old to undo: its snapshots were pruned.";
    var put_back: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var left: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(u8) = .empty;
    var restores: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    for (res.folders) |uf| {
        for (uf.undone) |p| {
            const gone = for (uf.removed) |r| {
                if (std.mem.eql(u8, r, p)) break true;
            } else false;
            try (if (gone) &removed else &put_back).append(a, p);
        }
        try left.appendSlice(a, uf.left);
        for (uf.failed) |fl| try failed.print(a, "{s}{s} ({s})", .{ if (failed.items.len > 0) ", " else "", fl.path, fl.why });
        if (uf.snapshot > 0) try restores.append(a, try std.fmt.allocPrint(a, "/restore {s} {d}", .{ uf.name, uf.snapshot }));
    }
    if (put_back.items.len + removed.items.len > 0) {
        try out.print(a, "Undid run {d}: ", .{rid});
        if (put_back.items.len > 0) {
            try out.appendSlice(a, "put back ");
            try names(&out, a, put_back.items);
        }
        if (removed.items.len > 0) {
            try out.appendSlice(a, if (put_back.items.len > 0) "; removed " else "removed ");
            try names(&out, a, removed.items);
        }
        try out.append(a, '.');
    } else if (left.items.len + failed.items.len == 0 and res.pruned.len == 0 and !refusedAny(res)) {
        if (res.already > 0) return std.fmt.allocPrint(a, "Run {d}'s changes are undone already.", .{rid});
        return std.fmt.allocPrint(a, "Run {d} changed no files in folders that keep snapshots.", .{rid});
    } else try out.print(a, "Nothing of run {d} was undone.", .{rid});
    if (left.items.len > 0) {
        try out.append(a, '\n');
        try names(&out, a, left.items);
        try out.appendSlice(a, if (left.items.len == 1) " changed since; left as it is." else " changed since; left as they are.");
    }
    if (failed.items.len > 0) try out.print(a, "\nNot put back: {s}.", .{failed.items});
    for (res.folders) |uf| if (uf.refused) |why| try out.print(a, "\n{s}: not undone, {s}.", .{ shown(uf.name), why });
    for (res.pruned) |p| try out.print(a, "\n{s}: too old to undo, its snapshots were pruned.", .{shown(p)});
    if (restores.items.len > 0) {
        try out.append(a, '\n');
        try names(&out, a, restores.items);
        try out.appendSlice(a, if (restores.items.len == 1) " takes the undo back." else " take the undo back.");
    }
    return out.items;
}

fn refusedAny(res: snapshots.Undone) bool {
    for (res.folders) |uf| if (uf.refused != null) return true;
    return false;
}

/// A folder as the owner reads it: `notes/`, or the workspace.
fn shown(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "/")) return "The workspace";
    return name;
}

/// "a", "a and b", "a, b and c" (the first 20, then how many more).
fn names(out: *std.ArrayList(u8), a: std.mem.Allocator, list: []const []const u8) !void {
    const n = @min(list.len, 20);
    for (list[0..n], 0..) |x, i| {
        if (i > 0) try out.appendSlice(a, if (i + 1 == n and list.len <= 20) " and " else ", ");
        try out.appendSlice(a, x);
    }
    if (list.len > 20) try out.print(a, " and {d} more", .{list.len - 20});
}

/// A message's text with an undo's outcome after it, within `max` bytes:
/// the outcome whole, the text cut (and marked) when both don't fit.
pub fn edited(a: std.mem.Allocator, text: []const u8, said: []const u8, max: usize) ![]const u8 {
    const what = cutUtf8(said, max / 2);
    if (text.len + 2 + what.len <= max) return std.fmt.allocPrint(a, "{s}\n\n{s}", .{ text, what });
    const room = max - what.len - 2 - "…".len;
    return std.fmt.allocPrint(a, "{s}…\n\n{s}", .{ cutUtf8(text, room), what });
}

/// `s` cut to at most `max` bytes, never inside a UTF-8 sequence.
fn cutUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return s[0..n];
}

// ---- tests ----

const t = std.testing;

test "the_undo_data_carries_the_run_and_its_hmac" {
    const key: [32]u8 = @splat(7);
    const other: [32]u8 = @splat(8);
    var buf: [48]u8 = undefined;
    const d = data(&buf, &key, 41);
    try t.expect(std.mem.startsWith(u8, d, "u41-"));
    try t.expectEqual(4 + 16, d.len);
    for (d[4..]) |ch| try t.expect(std.ascii.isHex(ch) and !std.ascii.isUpper(ch));
    try t.expectEqual(41, check(&key, d).?);
    try t.expectEqual(41, runOf(d).?);
    // another key
    try t.expectEqual(null, check(&other, d));
    // this token on another run
    var moved: [48]u8 = undefined;
    try t.expectEqual(null, check(&key, try std.fmt.bufPrint(&moved, "u42{s}", .{d[3..]})));
    // a changed digit
    var changed: [48]u8 = undefined;
    @memcpy(changed[0..d.len], d);
    changed[d.len - 1] = if (d[d.len - 1] == '0') '1' else '0';
    try t.expectEqual(null, check(&key, changed[0..d.len]));
    // not an Undo's data
    for ([_][]const u8{ "u41", "u-x", "ux-0123456789abcdef", "u41-", "u0-0123456789abcdef", "r1-x:1", "i3-0123456789abcdef:once", "" }) |bad| {
        try t.expectEqual(null, check(&key, bad));
    }
    try t.expectEqual(null, check(&key, d[0 .. d.len - 1]));
    try t.expectEqual(null, runOf("r1-abc:1"));
}

test "the_changed_line_names_the_folders" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("Changed 1 file in notes/.", line(&buf, 1, &.{"notes"}));
    try t.expectEqualStrings("Changed 3 files in notes/ and site/.", line(&buf, 3, &.{ "notes", "site" }));
    try t.expectEqualStrings("Changed 5 files in a/, b/ and work/shop/.", line(&buf, 5, &.{ "a", "b", "work/shop" }));
    try t.expectEqualStrings("Changed 2 files in the workspace.", line(&buf, 2, &.{"/"}));
    var small: [40]u8 = undefined;
    try t.expectEqualStrings("Changed 9 files in 4 folders.", line(&small, 9, &.{ "first-folder", "second-folder", "third", "fourth" }));
}

test "what_an_undo_says" {
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const all: snapshots.Undone = .{ .found = true, .folders = &.{.{ .name = "notes", .snapshot = 7, .undone = &.{ "notes/a.md", "notes/b.md", "notes/c.md" }, .removed = &.{"notes/c.md"} }} };
    try t.expectEqualStrings("Undid run 41: put back notes/a.md and notes/b.md; removed notes/c.md.\n/restore notes 7 takes the undo back.", try outcome(x, 41, all, true));
    const some: snapshots.Undone = .{ .found = true, .pruned = &.{"site"}, .folders = &.{
        .{ .name = "notes", .snapshot = 7, .undone = &.{"notes/c.md"}, .removed = &.{"notes/c.md"}, .left = &.{ "notes/a.md", "notes/b.md" }, .failed = &.{.{ .path = "notes/d.md", .why = "in use or not allowed" }} },
        .{ .name = "/", .snapshot = 3, .undone = &.{"x.txt"} },
    } };
    try t.expectEqualStrings(
        \\Undid run 41: put back x.txt; removed notes/c.md.
        \\notes/a.md and notes/b.md changed since; left as they are.
        \\Not put back: notes/d.md (in use or not allowed).
        \\site: too old to undo, its snapshots were pruned.
        \\/restore notes 7 and /restore / 3 take the undo back.
    , try outcome(x, 41, some, false));
    try t.expectEqualStrings("Nothing of run 41 was undone.\nnotes/a.md changed since; left as it is.", try outcome(x, 41, .{ .found = true, .folders = &.{.{ .name = "notes", .left = &.{"notes/a.md"} }} }, true));
    try t.expectEqualStrings("Run 41's changes are undone already.", try outcome(x, 41, .{ .found = true, .already = 2, .folders = &.{.{ .name = "notes" }} }, true));
    try t.expectEqualStrings("Run 41 changed no files in folders that keep snapshots.", try outcome(x, 41, .{ .found = true }, false));
    try t.expectEqualStrings("Too old to undo: its snapshots were pruned.", try outcome(x, 41, .{ .found = true, .pruned = &.{"notes"} }, false));
    try t.expectEqualStrings("Too old to undo: its snapshots were pruned.", try outcome(x, 41, .{}, true));
    try t.expectEqualStrings("Nothing kept for run 41: too old to undo, or it changed no folder that keeps snapshots.", try outcome(x, 41, .{}, false));
    try t.expectEqualStrings("Nothing of run 41 was undone.\nnotes: not undone, it is a symbolic link.", try outcome(x, 41, .{ .found = true, .folders = &.{.{ .name = "notes", .refused = "it is a symbolic link" }} }, true));
}

test "an_edited_message_keeps_the_outcome_whole" {
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const x = arena.allocator();
    try t.expectEqualStrings("Done.\n\nUndid run 4: removed a.", try edited(x, "Done.", "Undid run 4: removed a.", 4096));
    // thirty é, two bytes each
    var long: [60]u8 = undefined;
    for (0..30) |i| @memcpy(long[2 * i ..][0..2], "é");
    const e = try edited(x, &long, "Undid.", 40);
    try t.expect(e.len <= 40);
    try t.expect(std.mem.endsWith(u8, e, "…\n\nUndid."));
    try t.expect(std.unicode.utf8ValidateSlice(e));
}
