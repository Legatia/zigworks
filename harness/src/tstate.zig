//! A trigger's state on disk, in `state/triggers/NAME/`: `state` (where
//! its polls are and what it counted: JSON, written whole, a temporary
//! file then a rename), `seen` (what it found before: hashes and when,
//! 60 days, as briefs keep theirs), `queue` (JSON lines appended: each
//! event, then `checked`, `started` and `done` lines; compacted when all
//! are done or past 1 MB) and `last` (a page's last readable text).
const std = @import("std");
const triggers = @import("triggers.zig");
const brief = @import("brief.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One event a poll found, as the queue keeps it.
pub const Event = struct {
    /// What tells it apart: a link's hash, `path@time:size`, a value's hash.
    id: []const u8,
    /// When it was found.
    at: i64,
    fields: []const triggers.Field,
    /// The model's check: null not asked yet.
    checked: ?bool = null,
    /// A run with it was started (a restart repeats it, saying so).
    started: bool = false,
};

/// A file a file trigger watches: as the last poll saw it, and as it was
/// last counted.
pub const FileState = struct {
    path: []const u8,
    size: u64,
    /// Milliseconds.
    mtime: i64,
    /// It was counted (or marked by a first poll) at `settled_*`.
    settled: bool = false,
    settled_size: u64 = 0,
    settled_mtime: i64 = 0,
    /// It was missing at the last poll (a second time counts it removed).
    gone: bool = false,
};

pub const State = struct {
    /// When it polls next (Unix seconds).
    next: i64 = 0,
    /// Its first poll is done (a first poll only marks what is there).
    polled: bool = false,
    /// Failed polls in a row.
    failures: u32 = 0,
    /// The owner heard of them (5 in a row): told again when it recovers.
    told: bool = false,
    /// Why it is paused; "" when it is not.
    paused: []const u8 = "",
    /// A page's ETag and Last-Modified.
    etag: []const u8 = "",
    modified: []const u8 = "",
    /// A page's value (`json`), and the value of the last event acted on.
    value: []const u8 = "",
    base: []const u8 = "",
    /// The hash of a page's text or an MCP result.
    hash: []const u8 = "",
    files: []const FileState = &.{},
    /// When its runs started, the last day's.
    runs: []const i64 = &.{},
    /// The local day its checks were counted on, and how many.
    check_day: i64 = 0,
    checks: u32 = 0,
    /// The owner heard that its workflow can't start yet.
    told_workflow: bool = false,

    /// A copy whose every slice is in `a`.
    pub fn clone(s: State, a: Allocator) !State {
        var o = s;
        inline for (.{ "paused", "etag", "modified", "value", "base", "hash" }) |f| @field(o, f) = try a.dupe(u8, @field(s, f));
        const files = try a.alloc(FileState, s.files.len);
        for (s.files, files) |f, *d| {
            d.* = f;
            d.path = try a.dupe(u8, f.path);
        }
        o.files = files;
        o.runs = try a.dupe(i64, s.runs);
        return o;
    }
};

/// A queue as read back: the events not done, in the order found, and the
/// ids done since it was last compacted.
pub const Queue = struct {
    pending: []Event = &.{},
    done: []const []const u8 = &.{},
    /// The file's size.
    bytes: usize = 0,

    /// Whether an event with `id` is in it, done or not.
    pub fn has(q: Queue, id: []const u8) bool {
        for (q.pending) |e| if (std.mem.eql(u8, e.id, id)) return true;
        for (q.done) |d| if (std.mem.eql(u8, d, id)) return true;
        return false;
    }
};

/// Past this the queue is compacted when an event is done.
pub const compact_bytes = 1 << 20;

pub const Dir = struct {
    io: Io,
    /// `state/triggers/NAME`.
    path: []const u8,

    fn file(d: Dir, a: Allocator, name: []const u8) ![]const u8 {
        return std.fs.path.join(a, &.{ d.path, name });
    }

    /// Its state; the defaults when there is none or it does not read.
    pub fn loadState(d: Dir, a: Allocator) State {
        const text = Io.Dir.cwd().readFileAlloc(d.io, d.file(a, "state") catch return .{}, a, .limited(16 << 20)) catch return .{};
        const v = jv.parse(a, text) orelse return .{};
        if (v != .object) return .{};
        var s: State = .{};
        s.next = jv.int(jv.get(v, "next")) orelse 0;
        s.polled = jv.boolean(jv.get(v, "polled")) orelse false;
        s.failures = @intCast(std.math.clamp(jv.int(jv.get(v, "failures")) orelse 0, 0, std.math.maxInt(u32)));
        s.told = jv.boolean(jv.get(v, "told")) orelse false;
        inline for (.{ "paused", "etag", "modified", "value", "base", "hash" }) |f| @field(s, f) = jv.str(jv.get(v, f)) orelse "";
        var files: std.ArrayList(FileState) = .empty;
        for (jv.arr(jv.get(v, "files")) orelse &.{}) |fv| {
            const path = jv.str(jv.get(fv, "path")) orelse continue;
            files.append(a, .{
                .path = path,
                .size = @intCast(@max(0, jv.int(jv.get(fv, "size")) orelse 0)),
                .mtime = jv.int(jv.get(fv, "mtime")) orelse 0,
                .settled = jv.boolean(jv.get(fv, "settled")) orelse false,
                .settled_size = @intCast(@max(0, jv.int(jv.get(fv, "settled_size")) orelse 0)),
                .settled_mtime = jv.int(jv.get(fv, "settled_mtime")) orelse 0,
                .gone = jv.boolean(jv.get(fv, "gone")) orelse false,
            }) catch return .{};
        }
        s.files = files.items;
        var runs: std.ArrayList(i64) = .empty;
        for (jv.arr(jv.get(v, "runs")) orelse &.{}) |rv| if (jv.int(rv)) |x| runs.append(a, x) catch return .{};
        s.runs = runs.items;
        s.check_day = jv.int(jv.get(v, "check_day")) orelse 0;
        s.checks = @intCast(std.math.clamp(jv.int(jv.get(v, "checks")) orelse 0, 0, std.math.maxInt(u32)));
        s.told_workflow = jv.boolean(jv.get(v, "told_workflow")) orelse false;
        return s;
    }

    /// Writes its state whole: a temporary file, then a rename.
    pub fn saveState(d: Dir, a: Allocator, s: State) !void {
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{{\"v\":1,\"next\":{d},\"polled\":{},\"failures\":{d},\"told\":{}", .{ s.next, s.polled, s.failures, s.told });
        inline for (.{ "paused", "etag", "modified", "value", "base", "hash" }) |f| {
            try out.print(a, ",\"{s}\":", .{f});
            try util.jsonString(&out, a, @field(s, f));
        }
        try out.appendSlice(a, ",\"files\":[");
        for (s.files, 0..) |f, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, "{\"path\":");
            try util.jsonString(&out, a, f.path);
            try out.print(a, ",\"size\":{d},\"mtime\":{d},\"settled\":{},\"settled_size\":{d},\"settled_mtime\":{d},\"gone\":{}}}", .{ f.size, f.mtime, f.settled, f.settled_size, f.settled_mtime, f.gone });
        }
        try out.appendSlice(a, "],\"runs\":[");
        for (s.runs, 0..) |r, i| try out.print(a, "{s}{d}", .{ if (i > 0) "," else "", r });
        try out.print(a, "],\"check_day\":{d},\"checks\":{d},\"told_workflow\":{}}}\n", .{ s.check_day, s.checks, s.told_workflow });
        try d.writeWhole(a, "state", out.items);
    }

    /// What it found before (`seen`); nothing when there is no file.
    pub fn loadSeen(d: Dir, seen: *brief.Seen) void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}{c}seen", .{ d.path, std.fs.path.sep }) catch return;
        seen.load(d.io, p) catch {};
    }

    /// Writes `seen` whole (pruned past 60 days by the caller).
    pub fn saveSeen(d: Dir, a: Allocator, seen: *const brief.Seen) !void {
        var out: std.ArrayList(u8) = .empty;
        var it = seen.map.iterator();
        while (it.next()) |e| try out.print(a, "{x}\t{d}\n", .{ e.key_ptr, e.value_ptr.* });
        try d.writeWhole(a, "seen", out.items);
    }

    /// The queue as it is now.
    pub fn loadQueue(d: Dir, a: Allocator) !Queue {
        const text = Io.Dir.cwd().readFileAlloc(d.io, try d.file(a, "queue"), a, .limited(256 << 20)) catch |e| switch (e) {
            error.FileNotFound => return .{},
            else => return e,
        };
        var events: std.ArrayList(Event) = .empty;
        var done: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = jv.parse(a, line) orelse continue;
            if (v != .object) continue;
            if (jv.str(jv.get(v, "id"))) |id| {
                var fields: std.ArrayList(triggers.Field) = .empty;
                if (jv.get(v, "fields")) |fv| if (fv == .object) {
                    var fit = fv.object.iterator();
                    while (fit.next()) |e| try fields.append(a, .{ .name = e.key_ptr.*, .value = jv.str(e.value_ptr.*) orelse continue });
                };
                try events.append(a, .{ .id = id, .at = jv.int(jv.get(v, "at")) orelse 0, .fields = fields.items, .checked = jv.boolean(jv.get(v, "checked")), .started = jv.boolean(jv.get(v, "started")) orelse false });
                continue;
            }
            inline for (.{ "checked", "no", "started", "done" }) |mark| if (jv.str(jv.get(v, mark))) |id| {
                for (events.items) |*e| if (std.mem.eql(u8, e.id, id)) {
                    if (comptime std.mem.eql(u8, mark, "checked")) e.checked = true;
                    if (comptime std.mem.eql(u8, mark, "no")) e.checked = false;
                    if (comptime std.mem.eql(u8, mark, "started")) e.started = true;
                };
                if (comptime std.mem.eql(u8, mark, "done")) try done.append(a, id);
            };
        }
        var pending: std.ArrayList(Event) = .empty;
        for (events.items) |e| {
            const gone = for (done.items) |x| {
                if (std.mem.eql(u8, x, e.id)) break true;
            } else false;
            if (!gone) try pending.append(a, e);
        }
        return .{ .pending = pending.items, .done = done.items, .bytes = text.len };
    }

    /// Adds lines to the end of the queue (the file is made if missing).
    pub fn append(d: Dir, text: []const u8) !void {
        try Io.Dir.cwd().createDirPath(d.io, d.path);
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}{c}queue", .{ d.path, std.fs.path.sep });
        var f = try Io.Dir.cwd().createFile(d.io, p, .{ .truncate = false, .permissions = util.private_file });
        defer f.close(d.io);
        try f.writePositionalAll(d.io, text, try f.length(d.io));
    }

    /// Writes the queue again with only its pending events (and their
    /// marks): empty when none is.
    pub fn compact(d: Dir, a: Allocator, q: Queue) !void {
        var out: std.ArrayList(u8) = .empty;
        for (q.pending) |e| try out.appendSlice(a, try eventLine(a, e));
        try d.writeWhole(a, "queue", out.items);
    }

    /// A page's last readable text ("" for none).
    pub fn readLast(d: Dir, a: Allocator) []const u8 {
        return Io.Dir.cwd().readFileAlloc(d.io, d.file(a, "last") catch return "", a, .limited(8 << 20)) catch "";
    }

    pub fn writeLast(d: Dir, a: Allocator, text: []const u8) !void {
        try d.writeWhole(a, "last", text);
    }

    /// Deletes the folder and what is in it.
    pub fn remove(d: Dir) void {
        Io.Dir.cwd().deleteTree(d.io, d.path) catch {};
    }

    /// Writes `name` in the folder whole: a temporary file, then a rename.
    fn writeWhole(d: Dir, a: Allocator, name: []const u8, data: []const u8) !void {
        try Io.Dir.cwd().createDirPath(d.io, d.path);
        const p = try d.file(a, name);
        const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{p});
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(d.io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = util.private_file } });
        errdefer cwd.deleteFile(d.io, tmp) catch {};
        try cwd.rename(tmp, cwd, p, d.io);
    }
};

/// An event as a queue line, with its marks.
pub fn eventLine(a: Allocator, ev: Event) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"id\":");
    try util.jsonString(&out, a, ev.id);
    try out.print(a, ",\"at\":{d},\"fields\":{{", .{ev.at});
    for (ev.fields, 0..) |f, i| {
        if (i > 0) try out.append(a, ',');
        try util.jsonString(&out, a, f.name);
        try out.append(a, ':');
        try util.jsonString(&out, a, f.value);
    }
    try out.append(a, '}');
    if (ev.checked) |c| try out.print(a, ",\"checked\":{}", .{c});
    if (ev.started) try out.appendSlice(a, ",\"started\":true");
    try out.appendSlice(a, "}\n");
    return out.items;
}

/// A queue line marking event `id`: `checked` (the check said yes), `no`
/// (it said no), `started` (a run with it began), `done`.
pub fn markLine(a: Allocator, mark: []const u8, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{\"{s}\":", .{mark});
    try util.jsonString(&out, a, id);
    try out.appendSlice(a, "}\n");
    return out.items;
}

// ---- tests ----

const t = std.testing;

fn tmpDir(tmp: *std.testing.TmpDir, a: Allocator) !Dir {
    return .{ .io = t.io, .path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "btc" }) };
}

test "state_is_written_whole_and_read_back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try tmpDir(&tmp, a);
    // nothing yet: the defaults
    try t.expectEqualDeep(State{}, d.loadState(a));
    const s: State = .{
        .next = 1796083500,
        .polled = true,
        .failures = 2,
        .told = true,
        .paused = "the source said 403",
        .etag = "\"abc\"",
        .modified = "Tue, 01 Dec 2026 00:00:00 GMT",
        .value = "97012.5",
        .base = "96000",
        .hash = "0011aabb",
        .files = &.{.{ .path = "inbox/a \"b\".pdf", .size = 12, .mtime = 1796083200123, .settled = true, .settled_size = 12, .settled_mtime = 1796083200123, .gone = true }},
        .runs = &.{ 1796083200, 1796083300 },
        .check_day = 20788,
        .checks = 7,
        .told_workflow = true,
    };
    try d.saveState(a, s);
    try t.expectEqualDeep(s, d.loadState(a));
    // no temporary file left
    var dir = try Io.Dir.cwd().openDir(t.io, d.path, .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    while (try it.next(t.io)) |e| try t.expect(!std.mem.endsWith(u8, e.name, ".tmp"));
    // a damaged file reads as the defaults, never half
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ d.path, "state" }), .data = "{\"next\":1,\"polled\":tr" });
    try t.expectEqualDeep(State{}, d.loadState(a));
}

test "events_are_queued_once_and_compacted" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try tmpDir(&tmp, a);
    try t.expectEqual(0, (try d.loadQueue(a)).pending.len);
    for ([_][]const u8{ "e1", "e2", "e3" }) |id| try d.append(try eventLine(a, .{ .id = id, .at = 5, .fields = &.{ .{ .name = "title", .value = "a \"quoted\"\nline" }, .{ .name = "link", .value = id } } }));
    try d.append(try markLine(a, "checked", "e1"));
    try d.append(try markLine(a, "started", "e3"));
    try d.append(try markLine(a, "done", "e1"));
    try d.append(try markLine(a, "done", "e2"));
    var q = try d.loadQueue(a);
    try t.expectEqual(1, q.pending.len);
    try t.expectEqualStrings("e3", q.pending[0].id);
    try t.expect(q.pending[0].started);
    try t.expectEqualStrings("a \"quoted\"\nline", q.pending[0].fields[0].value);
    try t.expectEqualStrings("link", q.pending[0].fields[1].name);
    try t.expect(q.has("e1") and q.has("e3") and !q.has("e4"));
    // compacted: the pending one with its marks, the done ones gone
    try d.compact(a, q);
    q = try d.loadQueue(a);
    try t.expectEqual(1, q.pending.len);
    try t.expect(q.pending[0].started);
    try t.expect(!q.has("e1"));
    // a "no" from the check is kept as such
    try d.append(try markLine(a, "no", "e3"));
    q = try d.loadQueue(a);
    try t.expectEqual(false, q.pending[0].checked.?);
    // all done: an empty file
    try d.append(try markLine(a, "done", "e3"));
    q = try d.loadQueue(a);
    try t.expectEqual(0, q.pending.len);
    try d.compact(a, q);
    try t.expectEqual(0, (try d.loadQueue(a)).bytes);
    // a line that does not read is left out
    try d.append("not json\n");
    try d.append(try eventLine(a, .{ .id = "e5", .at = 6, .fields = &.{} }));
    try t.expectEqual(1, (try d.loadQueue(a)).pending.len);
}

test "seen_and_last_survive_a_reload" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try tmpDir(&tmp, a);
    var seen: brief.Seen = .init(t.allocator);
    defer seen.deinit();
    try seen.add("https://z.org/1", 1796083200);
    try d.saveSeen(a, &seen);
    var back: brief.Seen = .init(t.allocator);
    defer back.deinit();
    d.loadSeen(&back);
    try t.expect(back.has("https://z.org/1"));
    try t.expect(!back.has("https://z.org/2"));
    try t.expectEqualStrings("", d.readLast(a));
    try d.writeLast(a, "line one\nline two\n");
    try t.expectEqualStrings("line one\nline two\n", d.readLast(a));
    d.remove();
    try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, d.path, .{}));
}
