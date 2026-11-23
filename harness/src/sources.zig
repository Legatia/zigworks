//! A trigger's polls: what each kind reads, through the gate (a
//! `Decider`: listed reads for a poll, the run's own gate for the tool's
//! test), and what is new against the trigger's state. A first poll only
//! marks what is there. No model call, no lock, nothing written: the
//! engine queues the events and only then keeps `Outcome.next`.
const std = @import("std");
const triggers = @import("triggers.zig");
const tstate = @import("tstate.zig");
const brief = @import("brief.zig");
const feeds = @import("feeds.zig");
const tools = @import("tools.zig");
const gate = @import("gate.zig");
const page = @import("page.zig");
const rules = @import("rules.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Why a read was refused; `final` when it can't mend itself (a role in
/// folders.ini): the trigger pauses; `skipped` when it waits for the
/// owner's grant (a skipped item says so): no failure.
pub const Refused = struct { why: []const u8, final: bool = false, skipped: bool = false };

/// How a poll's reads are decided and logged.
pub const Decider = struct {
    ctx: *anyopaque,
    /// Null when the read may go.
    decide: *const fn (ctx: *anyopaque, a: Allocator, tool: gate.Tool, arg: []const u8) ?Refused,
    /// A redirect to `url`; `known_host`: the request reached that host.
    hop: *const fn (ctx: *anyopaque, a: Allocator, url: []const u8, known_host: bool) ?[]const u8,
    /// A call no listing allows (a polled MCP tool): a rule or a grant for
    /// the trigger; null: `decide`.
    unlisted: ?*const fn (ctx: *anyopaque, a: Allocator, tool: gate.Tool, arg: []const u8) ?Refused = null,
};

/// How a poll reaches an MCP server.
pub const Mcp = struct {
    ctx: *anyopaque,
    /// tools/call; error.MoneyTool for a tool that moves money.
    call: *const fn (ctx: *anyopaque, a: Allocator, server: []const u8, tool: []const u8, input: []const u8) anyerror!Called,
    read: *const fn (ctx: *anyopaque, a: Allocator, server: []const u8, uri: []const u8) anyerror!Called,
};

pub const Called = struct { text: []const u8, is_error: bool = false };

pub const Env = struct {
    gpa: Allocator,
    io: Io,
    decider: Decider,
    /// The workspace's real path.
    workspace: []const u8,
    search_url: []const u8 = "",
    search_key: ?[]const u8 = null,
    stop: *const std.atomic.Value(bool),
    /// Every request is over by then (Unix seconds; 0: its own limits).
    deadline_s: i64 = 0,
    mcp: ?Mcp = null,
};

/// An event the poll found, and the key it marks seen once it is queued.
pub const Found = struct { event: tstate.Event, seen: ?[]const u8 = null };

pub const Outcome = struct {
    found: []const Found = &.{},
    /// Every key the sources gave, new or not: seen once the poll is kept.
    seen_all: []const []const u8 = &.{},
    /// The state once the events are queued (cursors, files, the value).
    next: tstate.State,
    /// A page's readable text to keep as `last`; null: unchanged.
    last: ?[]const u8 = null,
    status: u16 = 0,
    bytes: usize = 0,
    /// It failed: why (it backs off).
    failed: ?[]const u8 = null,
    retry_after_s: ?u32 = null,
    /// It can't go on: why (the trigger pauses).
    pause: ?[]const u8 = null,
    /// It waits for the owner's grant (a skipped item): why; no failure.
    skipped: ?[]const u8 = null,
};

/// Polls `tr` once against `prev` (its state), `seen` (what it found
/// before) and `last` (a page's last text). A source that fails says so in
/// `failed` (or `pause`); what the others found still counts.
pub fn poll(env: Env, a: Allocator, tr: triggers.Trigger, prev: tstate.State, seen: *const brief.Seen, last: []const u8, now_s: i64) !Outcome {
    var out: Outcome = .{ .next = prev };
    switch (tr.kind) {
        .feed, .search => try pollLinks(env, a, tr, prev, seen, now_s, &out),
        .page => try pollPage(env, a, tr, prev, last, now_s, &out),
        .file => try pollFile(env, a, tr, prev, now_s, &out),
        .mcp => try pollMcp(env, a, tr, prev, seen, now_s, &out),
        .schedule, .brief => out.failed = "a schedule is not polled",
    }
    return out;
}

/// A feed is read up to 4 MiB, as briefs read them.
const feed_max = 4 << 20;
/// A field of an event holds up to 4 KB.
pub const field_max = 4096;
/// A file trigger looks at up to 1000 files.
pub const max_files = 1000;

fn until(env: Env) tools.Until {
    return .{ .deadline_s = env.deadline_s, .stop = env.stop };
}

fn redirect(env: Env) tools.Redirect {
    return .{ .ctx = env.decider.ctx, .allow = env.decider.hop };
}

/// The first 16 bytes of `s`'s SHA-256, in hex.
pub fn hashHex(a: Allocator, s: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d[0..16].*, .lower));
}

fn refusedRead(out: *Outcome, a: Allocator, what: []const u8, r: Refused) !void {
    const why = try std.fmt.allocPrint(a, "{s} was refused: {s}", .{ what, r.why });
    if (r.final) out.pause = why else out.failed = why;
}

/// An answer that is not 200: 401, 403 and 410 pause the trigger, the
/// others fail the poll (with the wait it asked for).
fn badStatus(out: *Outcome, a: Allocator, what: []const u8, g: tools.Got) !void {
    out.status = g.status;
    const why = try std.fmt.allocPrint(a, "{s} answered {d}", .{ what, g.status });
    switch (g.status) {
        401, 403, 410 => out.pause = why,
        else => {
            out.failed = why;
            out.retry_after_s = g.retry_after_s;
        },
    }
}

/// feed and search: an event per link not seen before.
fn pollLinks(env: Env, a: Allocator, tr: triggers.Trigger, prev: tstate.State, seen: *const brief.Seen, now_s: i64, out: *Outcome) !void {
    var found: std.ArrayList(Found) = .empty;
    var all: std.ArrayList([]const u8) = .empty;
    var here: std.StringHashMapUnmanaged(void) = .empty;
    var read_one = false;
    for (tr.sources) |src| {
        if (env.stop.load(.acquire)) {
            out.failed = "stopped by the owner";
            break;
        }
        const got = if (tr.kind == .feed) try fetchFeed(env, a, src, out) else try searchFor(env, a, src, out);
        const entries = got orelse continue;
        read_one = true;
        for (entries) |en| {
            if (here.contains(en.link)) continue;
            try here.put(a, en.link, {});
            try all.append(a, en.link);
            // a first poll only marks
            if (!prev.polled or seen.has(en.link)) continue;
            var fields: std.ArrayList(triggers.Field) = .empty;
            try fields.append(a, .{ .name = "title", .value = util.cut(en.title, field_max) });
            try fields.append(a, .{ .name = "link", .value = en.link });
            if (tr.kind == .feed) try fields.append(a, .{ .name = "text", .value = util.cut(en.text, field_max) });
            try fields.append(a, .{ .name = "date", .value = en.date });
            if (tr.kind == .feed) try fields.append(a, .{ .name = "source", .value = src });
            try found.append(a, .{ .event = .{ .id = try hashHex(a, en.link), .at = now_s, .fields = fields.items }, .seen = en.link });
        }
    }
    out.found = found.items;
    out.seen_all = all.items;
    if (read_one) out.next.polled = true;
}

/// A feed's entries; null when it failed (said in `out`).
fn fetchFeed(env: Env, a: Allocator, url: []const u8, out: *Outcome) !?[]const feeds.Entry {
    if (env.decider.decide(env.decider.ctx, a, .fetch, url)) |r| {
        try refusedRead(out, a, url, r);
        return null;
    }
    const g = tools.getUntil(env.gpa, env.io, a, url, &.{}, feed_max, redirect(env), until(env)) catch |e| {
        out.failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ url, @errorName(e) });
        return null;
    };
    out.bytes += g.body.len;
    out.status = g.status;
    if (g.stopped) |st| {
        out.failed = try std.fmt.allocPrint(a, "{s}: the redirect to {s} was not followed: {s}", .{ url, st.to, st.why });
        return null;
    }
    if (g.status != 200) {
        try badStatus(out, a, url, g);
        return null;
    }
    if (g.truncated) {
        out.failed = try std.fmt.allocPrint(a, "{s} is over 4 MiB", .{url});
        return null;
    }
    return try feeds.parse(a, g.body);
}

/// A search's results; null when it failed (said in `out`).
fn searchFor(env: Env, a: Allocator, words: []const u8, out: *Outcome) !?[]const feeds.Entry {
    const what = try std.fmt.allocPrint(a, "search \"{s}\"", .{words});
    if (env.decider.decide(env.decider.ctx, a, .search, words)) |r| {
        try refusedRead(out, a, what, r);
        return null;
    }
    const key = env.search_key orelse {
        out.failed = "web search is not set up: no search API key stored";
        return null;
    };
    var url: std.ArrayList(u8) = .empty;
    try url.print(a, "{s}/res/v1/web/search?count=8&freshness=pd&q=", .{std.mem.trimEnd(u8, env.search_url, "/")});
    for (words) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try url.append(a, ch) else try url.print(a, "%{X:0>2}", .{ch});
    }
    const g = tools.getUntil(env.gpa, env.io, a, url.items, &.{
        .{ .name = "X-Subscription-Token", .value = key },
        .{ .name = "Accept", .value = "application/json" },
    }, feed_max, redirect(env), until(env)) catch |e| {
        out.failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ what, @errorName(e) });
        return null;
    };
    out.bytes += g.body.len;
    out.status = g.status;
    if (g.stopped) |st| {
        out.failed = try std.fmt.allocPrint(a, "{s}: the redirect to {s} was not followed: {s}", .{ what, st.to, st.why });
        return null;
    }
    if (g.status != 200) {
        try badStatus(out, a, what, g);
        return null;
    }
    const v = jv.parse(a, g.body) orelse {
        out.failed = try std.fmt.allocPrint(a, "{s} answered something that is not JSON", .{what});
        return null;
    };
    var list: std.ArrayList(feeds.Entry) = .empty;
    for (jv.arr(jv.at(v, &.{ "web", "results" })) orelse &.{}) |res| {
        const link = jv.str(jv.get(res, "url")) orelse continue;
        try list.append(a, .{ .title = jv.str(jv.get(res, "title")) orelse link, .link = link, .date = jv.str(jv.get(res, "age")) orelse "" });
    }
    return list.items;
}

/// page: a changed value (`json`), or the lines its readable text gained
/// and lost; a 304 changes nothing.
fn pollPage(env: Env, a: Allocator, tr: triggers.Trigger, prev: tstate.State, last: []const u8, now_s: i64, out: *Outcome) !void {
    const url = tr.sources[0];
    if (env.decider.decide(env.decider.ctx, a, .fetch, url)) |r| return refusedRead(out, a, url, r);
    var hb: [2]std.http.Header = undefined;
    var n: usize = 0;
    if (prev.etag.len > 0) {
        hb[n] = .{ .name = "If-None-Match", .value = prev.etag };
        n += 1;
    }
    if (prev.modified.len > 0) {
        hb[n] = .{ .name = "If-Modified-Since", .value = prev.modified };
        n += 1;
    }
    const g = tools.getUntil(env.gpa, env.io, a, url, hb[0..n], tools.fetch_max, redirect(env), until(env)) catch |e| {
        out.failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ url, @errorName(e) });
        return;
    };
    out.bytes = g.body.len;
    out.status = g.status;
    if (g.stopped) |st| {
        out.failed = try std.fmt.allocPrint(a, "{s}: the redirect to {s} was not followed: {s}", .{ url, st.to, st.why });
        return;
    }
    if (g.status == 304) return;
    if (g.status != 200) return badStatus(out, a, url, g);
    out.next.etag = g.etag;
    out.next.modified = g.last_modified;
    if (tr.json.len > 0) {
        const value = jsonAt(a, g.body, tr.json) orelse {
            out.failed = try std.fmt.allocPrint(a, "{s} has no value at {s}", .{ url, tr.json });
            return;
        };
        out.next.polled = true;
        if (!prev.polled) {
            out.next.value = value;
            out.next.base = value;
            return;
        }
        if (std.mem.eql(u8, value, prev.value)) return;
        out.next.value = value;
        // change and move count from the last event acted on (R10)
        const base = if (prev.base.len > 0) prev.base else prev.value;
        var fields: std.ArrayList(triggers.Field) = .empty;
        try fields.append(a, .{ .name = "value", .value = util.cut(value, field_max) });
        if (changeOf(base, value)) |ch| {
            try fields.append(a, .{ .name = "change", .value = try numText(a, ch) });
            try fields.append(a, .{ .name = "move", .value = try numText(a, @abs(ch)) });
        }
        // the same change found again after a stop has the same id
        const id = try hashHex(a, try std.mem.concat(a, u8, &.{ prev.value, "\x00", value, "\x00", base }));
        out.found = try a.dupe(Found, &.{.{ .event = .{ .id = id, .at = now_s, .fields = fields.items } }});
        return;
    }
    const text = if (std.ascii.findIgnoreCase(g.content_type, "html") != null) (try page.extract(a, g.body, url)).text else g.body;
    const h = try hashHex(a, text);
    out.next.polled = true;
    if (!prev.polled) {
        out.next.hash = h;
        out.last = text;
        return;
    }
    if (std.mem.eql(u8, h, prev.hash)) return;
    out.next.hash = h;
    out.last = text;
    const d = try diffLines(a, last, text);
    const id = try hashHex(a, try std.mem.concat(a, u8, &.{ prev.hash, "\x00", h }));
    const fields = try a.dupe(triggers.Field, &.{ .{ .name = "text", .value = util.cut(d.added, field_max) }, .{ .name = "removed", .value = util.cut(d.removed, field_max) } });
    out.found = try a.dupe(Found, &.{.{ .event = .{ .id = id, .at = now_s, .fields = fields } }});
}

/// A number as an event's field: up to 4 decimals, no trailing zeros.
fn numText(a: Allocator, x: f64) ![]const u8 {
    const r = @round(x * 10000) / 10000;
    return std.fmt.allocPrint(a, "{d}", .{if (r == 0) 0 else r});
}

/// The signed percent from `base` to `value`, when both are numbers
/// ("97012.5" counts) and `base` is not 0.
pub fn changeOf(base: []const u8, value: []const u8) ?f64 {
    const b = std.fmt.parseFloat(f64, std.mem.trim(u8, base, " \t")) catch return null;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return null;
    if (b == 0 or std.math.isNan(b) or std.math.isNan(v) or std.math.isInf(b) or std.math.isInf(v)) return null;
    return (v - b) / @abs(b) * 100;
}

/// The lines `new` has that `old` has not (in `new`'s order), and those
/// `old` had that `new` has not; blank lines left out, each list joined by
/// line breaks.
pub fn diffLines(a: Allocator, old: []const u8, new: []const u8) !struct { added: []const u8, removed: []const u8 } {
    var old_count: std.StringHashMapUnmanaged(u32) = .empty;
    var new_count: std.StringHashMapUnmanaged(u32) = .empty;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        const e = try old_count.getOrPut(a, l);
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }
    it = std.mem.splitScalar(u8, new, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        const e = try new_count.getOrPut(a, l);
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }
    var added: std.ArrayList(u8) = .empty;
    var removed: std.ArrayList(u8) = .empty;
    it = std.mem.splitScalar(u8, new, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        if (old_count.getPtr(l)) |c| if (c.* > 0) {
            c.* -= 1;
            continue;
        };
        if (added.items.len > 0) try added.append(a, '\n');
        try added.appendSlice(a, l);
    }
    it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        if (new_count.getPtr(l)) |c| if (c.* > 0) {
            c.* -= 1;
            continue;
        };
        if (removed.items.len > 0) try removed.append(a, '\n');
        try removed.appendSlice(a, l);
    }
    return .{ .added = added.items, .removed = removed.items };
}

/// The value at `path` (names and `[N]`, dots between) in JSON `body`, as
/// text: a string as it is, a number as written, anything else as JSON;
/// null when there is none.
pub fn jsonAt(a: Allocator, body: []const u8, path: []const u8) ?[]const u8 {
    var v = jv.parse(a, body) orelse return null;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        const br = std.mem.indexOfScalar(u8, part, '[') orelse part.len;
        if (br > 0) {
            if (v != .object) return null;
            v = v.object.get(part[0..br]) orelse return null;
        }
        var rest = part[br..];
        while (rest.len > 0) {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
            const i = std.fmt.parseInt(usize, rest[1..close], 10) catch return null;
            if (v != .array or i >= v.array.items.len) return null;
            v = v.array.items[i];
            rest = rest[close + 1 ..];
        }
    }
    return switch (v) {
        .string => |x| x,
        .number_string => |x| x,
        .integer => |x| std.fmt.allocPrint(a, "{d}", .{x}) catch null,
        .float => |x| std.fmt.allocPrint(a, "{d}", .{x}) catch null,
        .bool => |x| if (x) "true" else "false",
        .null => "null",
        else => std.json.Stringify.valueAlloc(a, v, .{}) catch null,
    };
}

/// file: the files of one workspace folder matching its pattern (dot
/// names and links left out, up to 1000); a change counts once a file is
/// the same on two polls, a file gone on two polls is removed.
fn pollFile(env: Env, a: Allocator, tr: triggers.Trigger, prev: tstate.State, now_s: i64, out: *Outcome) !void {
    const pat = tr.sources[0];
    const slash = std.mem.lastIndexOfScalar(u8, pat, '/');
    const folder = if (slash) |s| pat[0..s] else "";
    const pattern = if (slash) |s| pat[s + 1 ..] else pat;
    const arg = if (folder.len == 0) "." else folder;
    if (env.decider.decide(env.decider.ctx, a, .read_file, arg)) |r| return refusedRead(out, a, arg, r);
    const abs = gate.confine(a, env.io, env.workspace, arg) catch {
        out.pause = try std.fmt.allocPrint(a, "{s} is not a folder inside the workspace", .{arg});
        return;
    };
    var cur: std.ArrayList(tstate.FileState) = .empty;
    if (Io.Dir.cwd().openDir(env.io, abs, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(env.io);
        var it = dir.iterate();
        while (it.next(env.io) catch null) |e| {
            if (e.kind != .file or e.name.len == 0 or e.name[0] == '.') continue;
            if (!rules.globCase(pattern, e.name, gate.fold_paths)) continue;
            if (cur.items.len >= max_files) break;
            const st = dir.statFile(env.io, e.name, .{ .follow_symlinks = false }) catch continue;
            if (st.kind != .file) continue;
            const rel = if (folder.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, e.name });
            try cur.append(a, .{ .path = rel, .size = st.size, .mtime = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms)) });
        }
    } else |e| switch (e) {
        // not there yet: no files
        error.FileNotFound => {},
        else => {
            out.failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ arg, @errorName(e) });
            return;
        },
    }
    std.mem.sort(tstate.FileState, cur.items, {}, struct {
        fn lt(_: void, x: tstate.FileState, y: tstate.FileState) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    var next: std.ArrayList(tstate.FileState) = .empty;
    var found: std.ArrayList(Found) = .empty;
    for (cur.items) |cf| {
        var nf = cf;
        if (!prev.polled) {
            // a first poll only marks
            nf.settled = true;
            nf.settled_size = cf.size;
            nf.settled_mtime = cf.mtime;
        } else if (fileIn(prev.files, cf.path)) |pf| {
            nf.settled = pf.settled;
            nf.settled_size = pf.settled_size;
            nf.settled_mtime = pf.settled_mtime;
            const still = !pf.gone and pf.size == cf.size and pf.mtime == cf.mtime;
            const counted = pf.settled and pf.settled_size == cf.size and pf.settled_mtime == cf.mtime;
            if (still and !counted) {
                try found.append(a, .{ .event = try fileEvent(a, cf.path, if (pf.settled) "changed" else "new", cf.size, try std.fmt.allocPrint(a, "{s}@{d}:{d}", .{ cf.path, cf.mtime, cf.size }), now_s) });
                nf.settled = true;
                nf.settled_size = cf.size;
                nf.settled_mtime = cf.mtime;
            }
        }
        try next.append(a, nf);
    }
    for (prev.files) |pf| {
        if (fileIn(cur.items, pf.path) != null) continue;
        if (!pf.gone) {
            var g = pf;
            g.gone = true;
            try next.append(a, g);
            continue;
        }
        if (pf.settled) try found.append(a, .{ .event = try fileEvent(a, pf.path, "removed", pf.settled_size, try std.fmt.allocPrint(a, "{s}@gone:{d}", .{ pf.path, pf.settled_mtime }), now_s) });
    }
    out.next.files = next.items;
    out.next.polled = true;
    out.found = found.items;
}

fn fileIn(files: []const tstate.FileState, path: []const u8) ?tstate.FileState {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

fn fileEvent(a: Allocator, path: []const u8, change: []const u8, size: u64, id: []const u8, now_s: i64) !tstate.Event {
    return .{ .id = id, .at = now_s, .fields = try a.dupe(triggers.Field, &.{
        .{ .name = "path", .value = path },
        .{ .name = "change", .value = change },
        .{ .name = "size", .value = try std.fmt.allocPrint(a, "{d}", .{size}) },
    }) };
}

/// mcp: a resource (a listed read; one event when it changed) or a tool
/// (no listed read: a rule or a grant for its trigger; a list gives an
/// event per item whose `key` is new, anything else one when it changed).
/// A money tool is never polled.
fn pollMcp(env: Env, a: Allocator, tr: triggers.Trigger, prev: tstate.State, seen: *const brief.Seen, now_s: i64, out: *Outcome) !void {
    const m = tr.mcp.?;
    const mc = env.mcp orelse {
        out.failed = "no MCP server runs here";
        return;
    };
    if (m.tool.len == 0) {
        var arg: std.ArrayList(u8) = .empty;
        try arg.print(a, "{s}/resources/read {{\"uri\":", .{m.server});
        try util.jsonString(&arg, a, m.uri);
        try arg.append(a, '}');
        if (env.decider.decide(env.decider.ctx, a, .mcp, arg.items)) |r| return refusedRead(out, a, arg.items, r);
        const got = mc.read(mc.ctx, a, m.server, m.uri) catch |e| {
            out.failed = try std.fmt.allocPrint(a, "{s} resource {s}: {s}", .{ m.server, m.uri, @errorName(e) });
            return;
        };
        out.bytes = got.text.len;
        if (got.is_error) {
            out.failed = try std.fmt.allocPrint(a, "{s} resource {s}: {s}", .{ m.server, m.uri, util.cut(got.text, 200) });
            return;
        }
        return changedText(a, prev, got.text, now_s, out);
    }
    const arg = try std.fmt.allocPrint(a, "{s}/{s} {s}", .{ m.server, m.tool, m.input });
    const decide = env.decider.unlisted orelse env.decider.decide;
    if (decide(env.decider.ctx, a, .mcp, arg)) |r| {
        if (r.skipped) {
            out.skipped = r.why;
            return;
        }
        return refusedRead(out, a, arg, r);
    }
    const got = mc.call(mc.ctx, a, m.server, m.tool, m.input) catch |e| {
        if (e == error.MoneyTool) {
            out.pause = try std.fmt.allocPrint(a, "{s}/{s} moves money: it is never polled", .{ m.server, m.tool });
        } else out.failed = try std.fmt.allocPrint(a, "{s}/{s}: {s}", .{ m.server, m.tool, @errorName(e) });
        return;
    };
    out.bytes = got.text.len;
    if (got.is_error) {
        out.failed = try std.fmt.allocPrint(a, "{s}/{s} said: {s}", .{ m.server, m.tool, util.cut(got.text, 200) });
        return;
    }
    if (jv.parse(a, got.text)) |v| if (v == .array) {
        var found: std.ArrayList(Found) = .empty;
        var all: std.ArrayList([]const u8) = .empty;
        for (v.array.items) |item| {
            const key = try itemKey(a, item, tr.key);
            const known = for (all.items) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (known) continue;
            try all.append(a, key);
            // a first poll only marks
            if (!prev.polled or seen.has(key)) continue;
            var fields: std.ArrayList(triggers.Field) = .empty;
            if (item == .object) {
                var it = item.object.iterator();
                while (it.next()) |e| try fields.append(a, .{ .name = e.key_ptr.*, .value = util.cut(try valueText(a, e.value_ptr.*), field_max) });
            } else try fields.append(a, .{ .name = "text", .value = util.cut(try valueText(a, item), field_max) });
            try found.append(a, .{ .event = .{ .id = try hashHex(a, key), .at = now_s, .fields = fields.items }, .seen = key });
        }
        out.found = found.items;
        out.seen_all = all.items;
        out.next.polled = true;
        return;
    };
    return changedText(a, prev, got.text, now_s, out);
}

/// What tells an MCP tool's list item apart: its `key` field as text, else
/// the hash of the whole item.
fn itemKey(a: Allocator, item: jv.Value, key: []const u8) ![]const u8 {
    if (item == .object) if (item.object.get(key)) |k| return std.fmt.allocPrint(a, "{s}={s}", .{ key, try valueText(a, k) });
    return hashHex(a, try std.json.Stringify.valueAlloc(a, item, .{}));
}

/// A JSON value as text: a string as it is, a number as written, anything
/// else as JSON.
fn valueText(a: Allocator, v: jv.Value) ![]const u8 {
    return switch (v) {
        .string => |x| x,
        .number_string => |x| x,
        .integer => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .float => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .bool => |x| if (x) "true" else "false",
        .null => "null",
        else => std.json.Stringify.valueAlloc(a, v, .{}),
    };
}

/// One event `{text}` when `text` is not what the last poll saw (by its
/// hash); a first poll only marks.
fn changedText(a: Allocator, prev: tstate.State, text: []const u8, now_s: i64, out: *Outcome) !void {
    const h = try hashHex(a, text);
    out.next.polled = true;
    if (!prev.polled) {
        out.next.hash = h;
        return;
    }
    if (std.mem.eql(u8, h, prev.hash)) return;
    out.next.hash = h;
    const id = try hashHex(a, try std.mem.concat(a, u8, &.{ prev.hash, "\x00", h }));
    var fields: std.ArrayList(triggers.Field) = .empty;
    try fields.append(a, .{ .name = "text", .value = util.cut(text, field_max) });
    // a JSON object (homemcp's events): its fields too, so `match = to is
    // open` and `{device}` read plainly; `text` stays the whole text
    if (jv.parse(a, text)) |v| if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "text")) continue;
            try fields.append(a, .{ .name = e.key_ptr.*, .value = util.cut(try valueText(a, e.value_ptr.*), field_max) });
        }
    };
    out.found = try a.dupe(Found, &.{.{ .event = .{ .id = id, .at = now_s, .fields = fields.items } }});
}

// ---- tests ----

const t = std.testing;
const model = @import("model.zig");

const Allow = struct {
    calls: std.ArrayList(u8) = .empty,
    refuse: ?Refused = null,

    fn decide(ctx: *anyopaque, a: Allocator, tool: gate.Tool, arg: []const u8) ?Refused {
        _ = a;
        const al: *Allow = @ptrCast(@alignCast(ctx));
        al.calls.print(t.allocator, "{s} {s}\n", .{ @tagName(tool), arg }) catch {};
        return al.refuse;
    }

    fn hop(ctx: *anyopaque, a: Allocator, url: []const u8, known_host: bool) ?[]const u8 {
        _ = ctx;
        _ = a;
        _ = url;
        return if (known_host) null else "another host";
    }

    fn decider(al: *Allow) Decider {
        return .{ .ctx = al, .decide = decide, .hop = hop };
    }
};

const Fix = struct {
    e: model.TestEnv,
    al: Allow = .{},
    stop: std.atomic.Value(bool) = .init(false),
    seen: brief.Seen,
    ws: []const u8,

    fn init(f: *Fix) !void {
        try f.e.init();
        f.al = .{};
        f.stop = .init(false);
        f.seen = .init(t.allocator);
        try f.e.tmp.dir.createDirPath(t.io, "ws");
        f.ws = try f.e.tmp.dir.realPathFileAlloc(t.io, "ws", f.e.arena.allocator());
    }

    fn deinit(f: *Fix) void {
        f.al.calls.deinit(t.allocator);
        f.seen.deinit();
        f.e.deinit();
    }

    fn env(f: *Fix) !Env {
        return .{ .gpa = t.allocator, .io = t.io, .decider = f.al.decider(), .workspace = f.ws, .search_url = try f.e.url(), .search_key = "k", .stop = &f.stop };
    }

    fn page(f: *Fix, name: []const u8, data: []const u8) !void {
        try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(f.e.arena.allocator(), "pages/{s}", .{name}), .data = data });
    }

    fn trigger(f: *Fix, text: []const u8) !triggers.Trigger {
        const a = f.e.arena.allocator();
        const filled = try std.mem.replaceOwned(u8, a, text, "URL", try f.e.url());
        var d: triggers.Diag = .{};
        return (try triggers.parse(a, filled, .triggers, &d))[0];
    }

    fn poll(f: *Fix, tr: triggers.Trigger, prev: tstate.State, last: []const u8) !Outcome {
        return poll_(try f.env(), f.e.arena.allocator(), tr, prev, &f.seen, last, 1796083200);
    }
};

const poll_ = poll;

fn fieldOf(ev: tstate.Event, name: []const u8) ?[]const u8 {
    for (ev.fields) |fl| if (std.mem.eql(u8, fl.name, name)) return fl.value;
    return null;
}

test "a_first_poll_starts_nothing" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.page("z.xml", "<rss><channel><item><title>One</title><link>https://z.org/1</link></item><item><title>Two</title><link>https://z.org/2</link></item></channel></rss>");
    const feed = try f.trigger("[news]\nfeed = URL/page/z.xml\n");
    const out = try f.poll(feed, .{}, "");
    try t.expectEqual(null, out.failed);
    try t.expectEqual(0, out.found.len);
    try t.expect(out.next.polled);
    try t.expectEqual(2, out.seen_all.len);
    try t.expectEqualStrings("https://z.org/1", out.seen_all[0]);
    try t.expect(std.mem.indexOf(u8, f.al.calls.items, "fetch http://127.0.0.1:") != null);
    try f.page("p.txt", "a line\n");
    const pg = try f.poll(try f.trigger("[p]\npage = URL/page/p.txt\n"), .{}, "");
    try t.expectEqual(0, pg.found.len);
    try t.expect(pg.next.polled);
    try t.expectEqualStrings("a line\n", pg.last.?);
    try f.page("btc.json", "{\"data\":{\"amount\":\"100\"}}");
    const js = try f.poll(try f.trigger("[btc]\npage = URL/page/btc.json\njson = data.amount\n"), .{}, "");
    try t.expectEqual(0, js.found.len);
    try t.expectEqualStrings("100", js.next.value);
    try t.expectEqualStrings("100", js.next.base);
    try f.e.tmp.dir.createDirPath(t.io, "ws/inbox");
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/inbox/a.pdf", .data = "pdf" });
    const fl = try f.poll(try f.trigger("[scans]\nfile = inbox/*.pdf\n"), .{}, "");
    try t.expectEqual(0, fl.found.len);
    try t.expectEqual(1, fl.next.files.len);
    try t.expect(fl.next.files[0].settled);
}

test "a_feed_gives_an_event_per_new_link_with_its_summary" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.page("z.xml", "<rss><channel><item><title>One</title><link>https://z.org/1</link></item><item><title>Two</title><link>https://z.org/2</link><description>The &lt;b&gt;second&lt;/b&gt;</description><pubDate>Tue, 01 Dec 2026</pubDate></item></channel></rss>");
    try f.seen.add("https://z.org/1", 0);
    const tr = try f.trigger("[news]\nfeed = URL/page/z.xml\n");
    const out = try f.poll(tr, .{ .polled = true }, "");
    try t.expectEqual(1, out.found.len);
    const ev = out.found[0].event;
    try t.expectEqualStrings("Two", fieldOf(ev, "title").?);
    try t.expectEqualStrings("https://z.org/2", fieldOf(ev, "link").?);
    try t.expectEqualStrings("The second", fieldOf(ev, "text").?);
    try t.expectEqualStrings("Tue, 01 Dec 2026", fieldOf(ev, "date").?);
    try t.expectEqualStrings(tr.sources[0], fieldOf(ev, "source").?);
    try t.expectEqualStrings("https://z.org/2", out.found[0].seen.?);
    try t.expectEqual(32, ev.id.len);
    try t.expectEqual(2, out.seen_all.len);
}

test "a_page_sends_its_etag_and_a_304_changes_nothing" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.page("p.txt", "one\n");
    try f.page("p.txt.etag", "\"v1\"");
    const tr = try f.trigger("[p]\npage = URL/page/p.txt\n");
    const first = try f.poll(tr, .{}, "");
    try t.expectEqualStrings("\"v1\"", first.next.etag);
    const again = try f.poll(tr, first.next, first.last.?);
    try t.expectEqual(304, again.status);
    try t.expectEqual(0, again.found.len);
    try t.expectEqual(null, again.last);
    try t.expectEqualDeep(first.next, again.next);
    const reqs = try f.e.tmp.dir.readFileAlloc(t.io, "page-requests.jsonl", f.e.arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, reqs, "\"If-None-Match\":\"\\\"v1\\\"\"") != null);
}

test "a_page_change_gives_the_lines_added_and_removed" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.page("p.txt", "a\nc\nd\n");
    const tr = try f.trigger("[p]\npage = URL/page/p.txt\n");
    const out = try f.poll(tr, .{ .polled = true, .hash = "old" }, "a\nb\nc\n");
    try t.expectEqual(1, out.found.len);
    try t.expectEqualStrings("d", fieldOf(out.found[0].event, "text").?);
    try t.expectEqualStrings("b", fieldOf(out.found[0].event, "removed").?);
    try t.expectEqualStrings("a\nc\nd\n", out.last.?);
    try t.expect(!std.mem.eql(u8, out.next.hash, "old"));
    // the same text again: nothing
    const same = try f.poll(tr, out.next, out.last.?);
    try t.expectEqual(0, same.found.len);
    const d = try diffLines(f.e.arena.allocator(), "x\ny\nx\n", "x\nz\n");
    try t.expectEqualStrings("z", d.added);
    try t.expectEqualStrings("y\nx", d.removed);
}

test "move_counts_from_the_base" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const tr = try f.trigger("[btc]\npage = URL/page/btc.json\njson = data.amount\n");
    try f.page("btc.json", "{\"data\":{\"amount\":\"102\"}}");
    const up2 = try f.poll(tr, .{ .polled = true, .value = "100", .base = "100" }, "");
    try t.expectEqual(1, up2.found.len);
    try t.expectEqualStrings("102", fieldOf(up2.found[0].event, "value").?);
    try t.expectEqualStrings("2", fieldOf(up2.found[0].event, "change").?);
    try t.expectEqualStrings("2", fieldOf(up2.found[0].event, "move").?);
    // the base stays until an event is acted on: 104 is 4% from 100
    try f.page("btc.json", "{\"data\":{\"amount\":104}}");
    const up4 = try f.poll(tr, up2.next, "");
    try t.expectEqualStrings("4", fieldOf(up4.found[0].event, "change").?);
    try t.expectEqualStrings("100", up4.next.base);
    try f.page("btc.json", "{\"data\":{\"amount\":\"96\"}}");
    const down = try f.poll(tr, .{ .polled = true, .value = "104", .base = "100" }, "");
    try t.expectEqualStrings("-4", fieldOf(down.found[0].event, "change").?);
    try t.expectEqualStrings("4", fieldOf(down.found[0].event, "move").?);
    const a = f.e.arena.allocator();
    try t.expectEqualStrings("97012.5", jsonAt(a, "{\"data\":{\"amount\":\"97012.5\"}}", "data.amount").?);
    try t.expectEqualStrings("3", jsonAt(a, "{\"items\":[{\"p\":1},{\"p\":3}]}", "items[1].p").?);
    try t.expectEqualStrings("{\"x\":true}", jsonAt(a, "{\"o\":{\"x\":true}}", "o").?);
    try t.expectEqual(null, jsonAt(a, "{\"items\":[]}", "items[0]"));
}

test "a_file_counts_when_unchanged_for_two_polls" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const dir = f.e.tmp.dir;
    try dir.createDirPath(t.io, "ws/inbox");
    try dir.writeFile(t.io, .{ .sub_path = "ws/inbox/a.pdf", .data = "a" });
    const tr = try f.trigger("[scans]\nfile = inbox/*.pdf\n");
    var s = (try f.poll(tr, .{}, "")).next;
    // new: seen once, then counted when the same on the next poll
    try dir.writeFile(t.io, .{ .sub_path = "ws/inbox/b.pdf", .data = "bb" });
    try dir.writeFile(t.io, .{ .sub_path = "ws/inbox/.c.pdf", .data = "c" });
    try dir.writeFile(t.io, .{ .sub_path = "ws/inbox/d.txt", .data = "d" });
    var out = try f.poll(tr, s, "");
    try t.expectEqual(0, out.found.len);
    s = out.next;
    out = try f.poll(tr, s, "");
    try t.expectEqual(1, out.found.len);
    try t.expectEqualStrings("inbox/b.pdf", fieldOf(out.found[0].event, "path").?);
    try t.expectEqualStrings("new", fieldOf(out.found[0].event, "change").?);
    try t.expectEqualStrings("2", fieldOf(out.found[0].event, "size").?);
    try t.expect(std.mem.startsWith(u8, out.found[0].event.id, "inbox/b.pdf@"));
    s = out.next;
    // changed: once it holds still
    try dir.writeFile(t.io, .{ .sub_path = "ws/inbox/b.pdf", .data = "bbbb" });
    out = try f.poll(tr, s, "");
    try t.expectEqual(0, out.found.len);
    s = out.next;
    out = try f.poll(tr, s, "");
    try t.expectEqual(1, out.found.len);
    try t.expectEqualStrings("changed", fieldOf(out.found[0].event, "change").?);
    s = out.next;
    out = try f.poll(tr, s, "");
    try t.expectEqual(0, out.found.len);
    s = out.next;
    // removed: gone on two polls
    try dir.deleteFile(t.io, "ws/inbox/a.pdf");
    out = try f.poll(tr, s, "");
    try t.expectEqual(0, out.found.len);
    s = out.next;
    out = try f.poll(tr, s, "");
    try t.expectEqual(1, out.found.len);
    try t.expectEqualStrings("inbox/a.pdf", fieldOf(out.found[0].event, "path").?);
    try t.expectEqualStrings("removed", fieldOf(out.found[0].event, "change").?);
    try t.expectEqual(1, out.next.files.len);
    try t.expect(std.mem.indexOf(u8, f.al.calls.items, "read_file inbox") != null);
}

test "a_refused_status_pauses_and_others_back_off" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.page("p.txt", "x");
    const tr = try f.trigger("[p]\npage = URL/page/p.txt\n");
    try f.page("p.txt.status", "403");
    const refused = try f.poll(tr, .{ .polled = true }, "");
    try t.expect(refused.pause != null);
    try t.expectEqual(403, refused.status);
    try f.page("p.txt.status", "500 120");
    const failed = try f.poll(tr, .{ .polled = true }, "");
    try t.expect(failed.failed != null);
    try t.expectEqual(null, failed.pause);
    try t.expectEqual(120, failed.retry_after_s.?);
    // a refused read is no request
    try f.e.tmp.dir.deleteFile(t.io, "pages/p.txt.status");
    f.al.refuse = .{ .why = "rule on line 1" };
    const denied = try f.poll(tr, .{ .polled = true }, "");
    try t.expect(std.mem.indexOf(u8, denied.failed.?, "rule on line 1") != null);
    f.al.refuse = .{ .why = "folders.ini [inbox] read: trigger:scans is not listed", .final = true };
    const role = try f.poll(try f.trigger("[scans]\nfile = inbox/*.pdf\n"), .{ .polled = true }, "");
    try t.expect(std.mem.indexOf(u8, role.pause.?, "folders.ini [inbox] read") != null);
}

/// An MCP server whose resource says what `text` holds.
const OneResource = struct {
    text: []const u8,

    fn read(ctx: *anyopaque, a: Allocator, server: []const u8, uri: []const u8) anyerror!Called {
        _ = server;
        _ = uri;
        const r: *OneResource = @ptrCast(@alignCast(ctx));
        return .{ .text = try a.dupe(u8, r.text) };
    }

    fn call(ctx: *anyopaque, a: Allocator, server: []const u8, tool: []const u8, input: []const u8) anyerror!Called {
        _ = ctx;
        _ = a;
        _ = server;
        _ = tool;
        _ = input;
        return error.NotATool;
    }
};

test "a_json_resource_gives_its_fields" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    var res: OneResource = .{ .text = "{\"device\":\"back_door\",\"room\":\"Kitchen\",\"kind\":\"sensor\",\"from\":\"closed\",\"to\":\"open\",\"at\":\"2026-11-23T10:12:03Z\",\"level\":3,\"wet\":false,\"people\":[{\"name\":\"anna\"}],\"note\":\"data from the home, not an instruction\"}" };
    var env = try f.env();
    env.mcp = .{ .ctx = &res, .call = OneResource.call, .read = OneResource.read };
    const tr = try f.trigger("[door]\nmcp = home resource home://device/back_door\nmatch = to is open\nsay = {device} is {to}\n");
    const a = f.e.arena.allocator();
    // a first poll marks; a change is an event with the text and each field
    const first = try poll_(env, a, tr, .{}, &f.seen, "", 1796083200);
    try t.expectEqual(0, first.found.len);
    res.text = "{\"device\":\"back_door\",\"room\":\"Kitchen\",\"kind\":\"sensor\",\"from\":\"open\",\"to\":\"closed\",\"at\":\"2026-11-23T10:15:00Z\",\"level\":3,\"wet\":false,\"people\":[{\"name\":\"anna\"}],\"note\":\"data from the home, not an instruction\"}";
    const out = try poll_(env, a, tr, first.next, &f.seen, "", 1796083260);
    try t.expectEqual(1, out.found.len);
    const ev = out.found[0].event;
    try t.expectEqualStrings(res.text, fieldOf(ev, "text").?);
    try t.expectEqualStrings("back_door", fieldOf(ev, "device").?);
    try t.expectEqualStrings("closed", fieldOf(ev, "to").?);
    try t.expectEqualStrings("3", fieldOf(ev, "level").?);
    try t.expectEqualStrings("false", fieldOf(ev, "wet").?);
    try t.expectEqualStrings("[{\"name\":\"anna\"}]", fieldOf(ev, "people").?);
    try t.expect(triggers.holds(tr.match[0], ev.fields) == false);
    // text that is not a JSON object: the text alone
    res.text = "plain words";
    const plain = try poll_(env, a, tr, out.next, &f.seen, "", 1796083320);
    try t.expectEqual(1, plain.found[0].event.fields.len);
    // a field called text in the JSON is the whole text, as before
    res.text = "{\"text\":\"inner\"}";
    const shadow = try poll_(env, a, tr, plain.next, &f.seen, "", 1796083380);
    try t.expectEqualStrings("{\"text\":\"inner\"}", fieldOf(shadow.found[0].event, "text").?);
}
