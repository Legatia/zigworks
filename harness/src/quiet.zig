//! Quiet hours and the digest: while they last, the posts and questions
//! of runs nobody waits on (schedules, briefs, triggers, workflows) are
//! held, unless the trigger or workflow is urgent; when they end, a digest
//! per conversation says them a line each, oldest first, and what does
//! not fit its line follows it whole. The held list, the `/quiet` switch
//! and hours are `state/quiet`, written whole.
const std = @import("std");
const config = @import("config.zig");
const util = @import("util.zig");
const Io = std.Io;

/// The hours `/quiet on` takes when none are set.
pub const default_hours: config.Quiet = .{ .start = 22 * 60, .end = 7 * 60 };

/// The longest digest line (bytes) before it is cut.
pub const line_max = 160;

/// A post or a question held for the digest.
pub const Held = struct {
    id: u64 = 0,
    /// When it was held (Unix seconds).
    at: i64 = 0,
    /// The conversation it was for.
    conv: []const u8 = "main",
    /// What started its run.
    by: []const u8 = "",
    /// Its run's definition (a quick reply's press goes back to it).
    agent: []const u8 = "main",
    rid: u64 = 0,
    /// The post as it would have gone (masked); for an item, its first line.
    text: []const u8 = "",
    /// Its quick replies' labels.
    buttons: []const []const u8 = &.{},
    /// Its Undo button's data; "": none.
    undo: []const u8 = "",
    /// An inbox item held instead of shown; 0: a post.
    item: u64 = 0,
    /// Said in a digest already: only still to be sent after it.
    listed: bool = false,
    private: bool = false,

    /// Whether it follows the digest whole: a question, or a post that
    /// does not fit its line or has buttons.
    pub fn follows(h: Held) bool {
        if (h.item != 0) return true;
        if (h.buttons.len > 0 or h.undo.len > 0) return true;
        return !fits(h.text);
    }
};

/// One line, short enough to be said whole in a digest.
fn fits(text: []const u8) bool {
    const tx = std.mem.trim(u8, text, " \t\r\n");
    return tx.len <= line_max and std.mem.indexOfScalar(u8, tx, '\n') == null;
}

/// Its line in a digest: the first line, cut at `line_max` bytes, with
/// `…` when there is more.
pub fn lineOf(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const tx = std.mem.trim(u8, text, " \t\r\n");
    const first = std.mem.trimEnd(u8, tx[0 .. std.mem.indexOfScalar(u8, tx, '\n') orelse tx.len], " \t\r");
    const cut = util.cut(first, line_max);
    if (cut.len == tx.len) return cut;
    return std.fmt.allocPrint(a, "{s}…", .{cut});
}

/// "22:00–07:00".
pub fn hoursText(buf: *[24]u8, q: config.Quiet) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}–{d:0>2}:{d:0>2}", .{ q.start / 60, q.start % 60, q.end / 60, q.end % 60 }) catch "";
}

/// The owner's minute of the day at `now_s`.
pub fn minuteOf(now_s: i64, utc_offset: i32) u16 {
    return @intCast(@divFloor(@mod(now_s + @as(i64, utc_offset) * 60, 86400), 60));
}

/// When quiet hours `q` next end after `now_s` (Unix seconds).
pub fn endAfter(q: config.Quiet, now_s: i64, utc_offset: i32) i64 {
    const off = @as(i64, utc_offset) * 60;
    const local = now_s + off;
    var end = @divFloor(local, 86400) * 86400 + @as(i64, q.end) * 60;
    if (end <= local) end += 86400;
    return end - off;
}

/// "HH:MM", the owner's time.
pub fn clock(buf: *[8]u8, secs: i64, utc_offset: i32) []const u8 {
    const m = minuteOf(secs, utc_offset);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ m / 60, m % 60 }) catch "";
}

/// The lines of `held` (oldest first): `HH:MM` and its line, "(below)"
/// after what follows the digest whole when `below`.
pub fn lines(a: std.mem.Allocator, held: []const Held, utc_offset: i32, below: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (held, 0..) |h, i| {
        var cb: [8]u8 = undefined;
        try out.print(a, "{s}{s} {s}{s}", .{ if (i > 0) "\n" else "", clock(&cb, h.at, utc_offset), try lineOf(a, h.text), if (below and h.follows()) " (below)" else "" });
    }
    return out.items;
}

/// The digest of one conversation's `held`: what it is, and a line each.
pub fn digestText(a: std.mem.Allocator, held: []const Held, hours: config.Quiet, utc_offset: i32) ![]const u8 {
    var hb: [24]u8 = undefined;
    return std.fmt.allocPrint(a, "During quiet hours ({s}):\n{s}", .{ hoursText(&hb, hours), try lines(a, held, utc_offset, true) });
}

/// The state file as written.
const File = struct {
    v: u32 = 1,
    /// "on", "off", or null: as config.ini says.
    @"switch": ?[]const u8 = null,
    /// "HH:MM-HH:MM" set with /quiet; null: config.ini's.
    hours: ?[]const u8 = null,
    next: u64 = 1,
    held: []const Held = &.{},
};

/// The held list and the `/quiet` switch, as `state/quiet` keeps them.
/// Every change is written whole before the caller goes on.
pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    /// Holds the held list's strings; let go of once it is empty.
    arena: std.heap.ArenaAllocator,
    held: std.ArrayList(Held) = .empty,
    next: u64 = 1,
    /// /quiet on|off; null: as config.ini says.
    on: ?bool = null,
    /// Hours set with /quiet; null: config.ini's.
    hours: ?config.Quiet = null,
    /// The urgent triggers and workflows: `trigger:NAME`, `workflow:NAME`.
    urgent_arena: std.heap.ArenaAllocator,
    urgent: []const []const u8 = &.{},
    /// A digest that did not go is not tried again before this (ms).
    retry_ms: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, path: []const u8) Store {
        return .{ .gpa = gpa, .io = io, .path = path, .arena = .init(gpa), .urgent_arena = .init(gpa) };
    }

    pub fn deinit(s: *Store) void {
        s.held.deinit(s.gpa);
        s.arena.deinit();
        s.urgent_arena.deinit();
    }

    /// Reads the file (none: nothing held).
    pub fn load(s: *Store) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const a = s.arena.allocator();
        const text = Io.Dir.cwd().readFileAlloc(s.io, s.path, a, .limited(64 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        const f = try std.json.parseFromSliceLeaky(File, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        s.next = @max(f.next, 1);
        s.on = if (f.@"switch") |w| (if (std.mem.eql(u8, w, "on")) true else if (std.mem.eql(u8, w, "off")) false else null) else null;
        s.hours = if (f.hours) |h| config.parseQuiet(h) catch null else null;
        s.held.clearRetainingCapacity();
        try s.held.appendSlice(s.gpa, f.held);
        for (s.held.items) |h| s.next = @max(s.next, h.id + 1);
    }

    /// Writes the file whole (under the mutex).
    fn save(s: *Store) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var hb: [16]u8 = undefined;
        const f: File = .{
            .@"switch" = if (s.on) |on| (if (on) "on" else "off") else null,
            .hours = if (s.hours) |h| config.formatQuiet(&hb, h) else null,
            .next = s.next,
            .held = s.held.items,
        };
        const text = try std.json.Stringify.valueAlloc(a, f, .{});
        try util.writeReplace(s.io, s.path, try std.mem.concat(a, u8, &.{ text, "\n" }));
    }

    /// The quiet hours that apply: none after /quiet off; else /quiet's
    /// hours, else config.ini's, else 22:00–07:00 after /quiet on.
    pub fn effective(s: *Store, cfg: ?config.Quiet) ?config.Quiet {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.on) |on| if (!on) return null;
        if (s.hours) |h| return h;
        if (cfg) |h| return h;
        if (s.on) |on| if (on) return default_hours;
        return null;
    }

    /// The hours as set, on or off: /quiet's, config.ini's, or the default.
    pub fn hoursSet(s: *Store, cfg: ?config.Quiet) config.Quiet {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.hours orelse cfg orelse default_hours;
    }

    /// `/quiet on|off` (and hours, when given); written.
    pub fn setSwitch(s: *Store, on: bool, hours: ?config.Quiet) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.on = on;
        if (hours) |h| s.hours = h;
        try s.save();
    }

    /// Holds `h` (its strings copied) and writes the file; its id.
    pub fn hold(s: *Store, h: Held) !u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const a = s.arena.allocator();
        var x = h;
        x.id = s.next;
        x.conv = try a.dupe(u8, h.conv);
        x.by = try a.dupe(u8, h.by);
        x.agent = try a.dupe(u8, h.agent);
        x.text = try a.dupe(u8, h.text);
        x.undo = try a.dupe(u8, h.undo);
        const labels = try a.alloc([]const u8, h.buttons.len);
        for (h.buttons, labels) |b, *o| o.* = try a.dupe(u8, b);
        x.buttons = labels;
        try s.held.append(s.gpa, x);
        s.next += 1;
        s.save() catch |e| {
            _ = s.held.pop();
            return e;
        };
        return x.id;
    }

    pub fn count(s: *Store) usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.held.items.len;
    }

    /// What is held, oldest first, copied into `a`.
    pub fn list(s: *Store, a: std.mem.Allocator) ![]Held {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const out = try a.alloc(Held, s.held.items.len);
        for (s.held.items, out) |h, *o| {
            o.* = h;
            o.conv = try a.dupe(u8, h.conv);
            o.by = try a.dupe(u8, h.by);
            o.agent = try a.dupe(u8, h.agent);
            o.text = try a.dupe(u8, h.text);
            o.undo = try a.dupe(u8, h.undo);
            const labels = try a.alloc([]const u8, h.buttons.len);
            for (h.buttons, labels) |b, *l| l.* = try a.dupe(u8, b);
            o.buttons = labels;
        }
        return out;
    }

    /// `ids` were said in a digest: those that follow it stay (listed),
    /// the others go; written.
    pub fn listed(s: *Store, ids: []const u64) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var i: usize = 0;
        while (i < s.held.items.len) {
            const h = &s.held.items[i];
            if (std.mem.indexOfScalar(u64, ids, h.id) == null) {
                i += 1;
                continue;
            }
            if (h.follows()) {
                h.listed = true;
                i += 1;
            } else _ = s.held.orderedRemove(i);
        }
        try s.saveTidy();
    }

    /// `id` went (or is no longer to go); written.
    pub fn remove(s: *Store, id: u64) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.held.items, 0..) |h, i| if (h.id == id) {
            _ = s.held.orderedRemove(i);
            break;
        };
        try s.saveTidy();
    }

    /// Writes the file; an empty list lets go of its strings.
    fn saveTidy(s: *Store) !void {
        if (s.held.items.len == 0) _ = s.arena.reset(.retain_capacity);
        try s.save();
    }

    /// The urgent triggers and workflows from now on (`trigger:NAME`,
    /// `workflow:NAME`), when they differ from those kept.
    pub fn setUrgent(s: *Store, names: []const []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const same = names.len == s.urgent.len and for (names, s.urgent) |x, y| {
            if (!std.mem.eql(u8, x, y)) break false;
        } else true;
        if (same) return;
        _ = s.urgent_arena.reset(.retain_capacity);
        const a = s.urgent_arena.allocator();
        const list_ = try a.alloc([]const u8, names.len);
        for (names, list_) |n, *o| o.* = try a.dupe(u8, n);
        s.urgent = list_;
    }

    /// Whether what started a run (`by`) is urgent: its trigger (an event
    /// trigger's or a schedule's of triggers.ini) or its workflow says so.
    pub fn isUrgent(s: *Store, by: []const u8) bool {
        var buf: [160]u8 = undefined;
        const key = urgentKey(&buf, by) orelse return false;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.urgent) |u| if (std.mem.eql(u8, u, key)) return true;
        return false;
    }
};

/// The urgent list's key of `by`: `trigger:NAME` for a trigger's and a
/// schedule's runs (a schedule of triggers.ini is a trigger section),
/// `workflow:NAME` for a workflow's steps.
fn urgentKey(buf: *[160]u8, by: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, by, ':') orelse return null;
    const kind = by[0..colon];
    var name = by[colon + 1 ..];
    if (std.mem.eql(u8, kind, "workflow")) {
        name = name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len];
        return std.fmt.bufPrint(buf, "workflow:{s}", .{name}) catch null;
    }
    if (std.mem.eql(u8, kind, "trigger") or std.mem.eql(u8, kind, "schedule")) return std.fmt.bufPrint(buf, "trigger:{s}", .{name}) catch null;
    return null;
}

// ---- tests ----

const t = std.testing;

test "hours_read_and_wrap_midnight" {
    const night = try config.parseQuiet("22:00-07:00");
    try t.expect(night.inside(22 * 60));
    try t.expect(night.inside(3 * 60));
    try t.expect(night.inside(6 * 60 + 59));
    try t.expect(!night.inside(7 * 60));
    try t.expect(!night.inside(12 * 60));
    try t.expect(!night.inside(21 * 60 + 59));
    const nap = try config.parseQuiet("13:30-15:00");
    try t.expect(nap.inside(14 * 60));
    try t.expect(!nap.inside(15 * 60));
    try t.expect(!nap.inside(3 * 60));
    // the end after a time inside, and after one outside: the next one
    const day0: i64 = 20_000 * 86400;
    try t.expectEqual(day0 + 86400 + 7 * 3600, endAfter(night, day0 + 23 * 3600, 0));
    try t.expectEqual(day0 + 7 * 3600, endAfter(night, day0 + 3 * 3600, 0));
    try t.expectEqual(day0 + 86400 + 7 * 3600, endAfter(night, day0 + 12 * 3600, 0));
    // the owner's time: 07:00 at +01:00 is 06:00 UTC
    try t.expectEqual(day0 + 6 * 3600, endAfter(night, day0 + 2 * 3600, 60));
    try t.expectEqual(2 * 60 + 30, minuteOf(day0 + 30 * 60, 120));
    var hb: [24]u8 = undefined;
    try t.expectEqualStrings("22:00–07:00", hoursText(&hb, night));
}

test "the_held_list_survives_a_restart" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "quiet" });
    {
        var s: Store = .init(t.allocator, t.io, path);
        defer s.deinit();
        try s.load();
        try t.expectEqual(0, s.count());
        try t.expect(s.effective(null) == null);
        try s.setSwitch(true, null);
        try t.expectEqualDeep(default_hours, s.effective(null).?);
        const one = try s.hold(.{ .at = 100, .conv = "main", .by = "trigger:btc", .text = "[btc] BTC 64,200 \"up\"" });
        const two = try s.hold(.{ .at = 200, .conv = "home", .by = "workflow:leak/ask", .item = 41, .text = "[leak#3] Close the water main?" });
        _ = try s.hold(.{ .at = 300, .conv = "main", .by = "schedule:report", .agent = "writer", .rid = 77, .text = "[report] Backups:\n- photos failed", .buttons = &.{ "Retry", "Leave it" }, .undo = "u77-0123456789abcdef" });
        try t.expectEqual(1, one);
        try t.expectEqual(2, two);
    }
    var s: Store = .init(t.allocator, t.io, path);
    defer s.deinit();
    try s.load();
    const held = try s.list(a);
    try t.expectEqual(3, held.len);
    try t.expectEqualStrings("[btc] BTC 64,200 \"up\"", held[0].text);
    try t.expectEqual(41, held[1].item);
    try t.expectEqualStrings("home", held[1].conv);
    try t.expectEqualStrings("writer", held[2].agent);
    try t.expectEqual(77, held[2].rid);
    try t.expectEqualStrings("Leave it", held[2].buttons[1]);
    try t.expectEqualStrings("u77-0123456789abcdef", held[2].undo);
    try t.expectEqual(true, s.on.?);
    // ids go on after a restart
    try t.expectEqual(4, try s.hold(.{ .at = 400, .text = "x" }));
    // said in a digest: what fits its line goes, what follows stays, listed
    try s.listed(&.{ 1, 2, 3 });
    const left = try s.list(a);
    try t.expectEqual(3, left.len);
    try t.expect(left[0].listed and left[1].listed);
    try t.expect(!left[2].listed);
    try s.remove(2);
    try s.remove(3);
    try s.remove(4);
    try t.expectEqual(0, s.count());
    // /quiet off: none apply, whatever config.ini says
    try s.setSwitch(false, null);
    try t.expect(s.effective(default_hours) == null);
    try s.setSwitch(true, try config.parseQuiet("23:00-06:30"));
    try t.expectEqual(23 * 60, s.effective(default_hours).?.start);
}

test "the_digest_has_a_line_each_oldest_first" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day0: i64 = 20_000 * 86400;
    var long: std.ArrayList(u8) = .empty;
    for (0..40) |_| try long.appendSlice(a, "word ");
    const held = [_]Held{
        .{ .at = day0 + 23 * 3600 + 40 * 60, .text = "[btc] BTC 64,200 (+3.1% since the last message)" },
        .{ .at = day0 + 86400 + 72 * 60, .text = "[garage] The garage door opened.", .buttons = &.{ "That was us", "Tell me more" } },
        .{ .at = day0 + 86400 + 2 * 3600, .text = "[report] Backups:\n- photos failed" },
        .{ .at = day0 + 86400 + 3 * 3600 + 5 * 60, .item = 41, .text = "[leak#3] Close the water main?" },
        .{ .at = day0 + 86400 + 4 * 3600, .text = long.items },
    };
    const text = try digestText(a, &held, default_hours, 0);
    const want =
        \\During quiet hours (22:00–07:00):
        \\23:40 [btc] BTC 64,200 (+3.1% since the last message)
        \\01:12 [garage] The garage door opened. (below)
        \\02:00 [report] Backups:… (below)
        \\03:05 [leak#3] Close the water main? (below)
    ;
    if (!std.mem.startsWith(u8, text, want)) {
        std.debug.print("got:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    // a long line is cut, and follows whole
    const last = text[std.mem.lastIndexOfScalar(u8, text, '\n').? + 1 ..];
    try t.expect(std.mem.startsWith(u8, last, "04:00 word word"));
    try t.expect(std.mem.endsWith(u8, last, "… (below)"));
    try t.expect(last.len < line_max + 20);
    try t.expect(!held[0].follows());
    try t.expect(held[4].follows());
    // /quiet lists them without "(below)"
    try t.expect(std.mem.indexOf(u8, try lines(a, &held, 0, false), "(below)") == null);
}

test "urgent_is_found_by_what_started_the_run" {
    var s: Store = .init(t.allocator, t.io, "unused");
    defer s.deinit();
    try s.setUrgent(&.{ "trigger:leak", "workflow:water" });
    try t.expect(s.isUrgent("trigger:leak"));
    // a schedule of triggers.ini is its section's
    try t.expect(s.isUrgent("schedule:leak"));
    try t.expect(s.isUrgent("workflow:water/close"));
    try t.expect(!s.isUrgent("workflow:watering/x"));
    try t.expect(!s.isUrgent("trigger:btc"));
    try t.expect(!s.isUrgent("owner"));
    try s.setUrgent(&.{});
    try t.expect(!s.isUrgent("trigger:leak"));
}
