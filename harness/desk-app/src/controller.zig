//! The app's state, decided apart from the window: events come in (a
//! timer, a check's result, a code, a message from the page, a menu item),
//! effects go out (show a page, load a URL, check, enter, run a command, set
//! the badge). Effects' strings are valid until the next `handle`.
const std = @import("std");
const bridge = @import("bridge.zig");
const deskjson = @import("deskjson.zig");
const Command = @import("commands.zig").Command;
const Screen = @import("pages.zig").Screen;
const Desk = deskjson.Desk;
const entry = @import("entry.zig");

/// Between checks while nothing changes, and while harness starts or stops.
pub const check_every_ms = 5000;
pub const fast_check_every_ms = 1000;
pub const fast_for_ms = 15_000;
/// A 401 or 403 while in enters again, at most this often.
pub const reenter_every_ms = 5000;
/// `harness run` ending with a failure within this long is said.
pub const early_exit_ms = 10_000;

pub const State = enum { setup, down, connecting, in };

pub const CheckResult = union(enum) { no_desk, bad_desk, dead: Desk, alive: Desk };

pub const MenuItem = enum { start, stop, autostart, reload };

pub const Event = union(enum) {
    start,
    /// Every second.
    tick,
    checked: struct { gen: u32, result: CheckResult },
    entered: struct { gen: u32, code: ?[]const u8 },
    message: struct { msg: bridge.Message, source: bridge.Source },
    menu: MenuItem,
    /// The main frame's response.
    loaded: struct { status: u16, url: []const u8 },
    /// The main frame couldn't load.
    failed,
    /// The web content process is gone.
    crashed,
    /// A command ended (`run`: it couldn't be started). `autostart` is the
    /// query's answer.
    ran: struct { cmd: Command, ok: bool, text: []const u8 = "", autostart: ?bool = null },
    /// The `harness run` the app started has ended.
    exited: struct { code: u8 },
};

pub const Menu = struct {
    start: bool = false,
    stop: bool = false,
    autostart_enabled: bool = false,
    autostart: ?bool = null,
};

pub const Effect = union(enum) {
    show: struct { screen: Screen, note: []const u8 = "" },
    load: []const u8,
    reload,
    /// Read desk.json, then `GET /alive` on its port; answer `checked`.
    check: u32,
    /// `entry.request`, then `entry.wait`; answer `entered`.
    enter: u32,
    run: struct { cmd: Command, binary: []const u8, home: []const u8, path: []const u8 },
    badge: u32,
    attention,
    menu: Menu,
    alert: struct { title: []const u8, text: []const u8 },
};

pub const Controller = struct {
    gpa: std.mem.Allocator,
    /// The data folder: where desk.json was looked for, and `--home` for
    /// every command.
    home: []const u8,
    state: State = .setup,
    desk: ?Desk = null,
    desk_arena: std.heap.ArenaAllocator,
    /// The port of the desk page loaded (null when none is).
    entered_port: ?u16 = null,
    /// The built-in page shown, and its note.
    screen: ?Screen = null,
    note: []const u8 = "",

    check_gen: u32 = 0,
    checking: bool = false,
    last_check_ms: i64 = std.math.minInt(i32),
    fast_until_ms: i64 = 0,
    misses: u8 = 0,

    enter_gen: u32 = 0,
    entering: bool = false,
    /// Enter once the next check finds harness, keeping the page shown.
    reentering: bool = false,
    last_enter_ms: i64 = std.math.minInt(i32),

    started_ms: ?i64 = null,
    autostart: ?bool = null,
    menu_sent: ?Menu = null,

    pub fn init(gpa: std.mem.Allocator, home: []const u8) Controller {
        return .{ .gpa = gpa, .home = home, .desk_arena = .init(gpa) };
    }

    pub fn deinit(c: *Controller) void {
        c.desk_arena.deinit();
    }

    /// The port navigation and messages are judged by: the loaded desk
    /// page's, else desk.json's.
    pub fn port(c: *const Controller) ?u16 {
        if (c.state == .in) if (c.entered_port) |p| return p;
        return if (c.desk) |d| d.port else null;
    }

    pub fn showingBuiltin(c: *const Controller) bool {
        return c.screen != null;
    }

    pub fn handle(c: *Controller, now: i64, ev: Event, out: *std.ArrayList(Effect), a: std.mem.Allocator) !void {
        var fx: Fx = .{ .out = out, .gpa = c.gpa };
        switch (ev) {
            .start => try c.checkNow(now, &fx),
            .tick => {
                const every: i64 = if (now < c.fast_until_ms) fast_check_every_ms else check_every_ms;
                if (!c.checking and now - c.last_check_ms >= every) try c.checkNow(now, &fx);
            },
            .checked => |r| if (r.gen == c.check_gen and c.checking) {
                c.checking = false;
                try c.onChecked(now, r.result, &fx);
            },
            .entered => |r| if (r.gen == c.enter_gen and c.entering) {
                c.entering = false;
                if (r.code) |code| {
                    const p = c.desk.?.port;
                    try fx.add(.{ .load = try entry.enterUrl(a, p, code) });
                    c.state = .in;
                    c.screen = null;
                    c.entered_port = p;
                    c.reentering = false;
                    c.misses = 0;
                    c.last_enter_ms = now;
                } else if (c.state == .in) {
                    // the page stays; the next check tries again
                    c.reentering = true;
                } else {
                    try c.show(.connecting, "No answer from harness yet. Trying again.", &fx);
                }
            },
            .message => |m| switch (m.source) {
                .desk => {
                    if (m.msg.badge) |n| try fx.add(.{ .badge = n });
                    if (m.msg.attention) try fx.add(.attention);
                    if (m.msg.reenter) try c.reenter(now, &fx);
                },
                .builtin => if (m.msg.start) try c.startHarness(now, &fx),
                .other => {},
            },
            .menu => |item| switch (item) {
                .start => try c.startHarness(now, &fx),
                .stop => if (c.binary()) |bin| {
                    try fx.add(.{ .run = c.runOf(.stop, bin) });
                    c.fast_until_ms = now + fast_for_ms;
                },
                .autostart => if (c.binary()) |bin| {
                    try fx.add(.{ .run = c.runOf(if (c.autostart == true) .autostart_off else .autostart_on, bin) });
                },
                .reload => if (c.state == .in) {
                    try fx.add(.reload);
                } else if (!c.checking) try c.checkNow(now, &fx),
            },
            .loaded => |l| if (c.state == .in and (l.status == 401 or l.status == 403) and
                now - c.last_enter_ms >= reenter_every_ms) try c.reenter(now, &fx),
            .failed => if (c.state == .in) {
                c.misses = @max(c.misses, 1);
                if (!c.checking) try c.checkNow(now, &fx);
            },
            .crashed => if (c.state == .in) {
                try c.reenter(now, &fx);
            } else if (c.screen) |s| {
                c.screen = null;
                try c.show(s, c.note, &fx);
            },
            .ran => |r| switch (r.cmd) {
                .autostart_query => c.autostart = r.autostart,
                .autostart_on, .autostart_off => if (r.ok) {
                    c.autostart = r.cmd == .autostart_on;
                } else try fx.add(.{ .alert = .{ .title = "Couldn't change Open at login", .text = r.text } }),
                .stop => if (!r.ok) try fx.add(.{ .alert = .{ .title = "Couldn't stop harness", .text = r.text } }),
                .run => if (!r.ok) try fx.add(.{ .alert = .{ .title = "Couldn't start harness", .text = r.text } }),
            },
            .exited => |x| if (c.started_ms) |at| {
                c.started_ms = null;
                if (x.code != 0 and now - at < early_exit_ms) try fx.add(.{ .alert = .{
                    .title = "harness stopped",
                    .text = try std.fmt.allocPrint(a, "It exited right after starting, with code {d}. Run harness run in Terminal to see why.", .{x.code}),
                } });
            },
        }
        const m = c.menu();
        if (c.menu_sent == null or !std.meta.eql(c.menu_sent.?, m)) {
            c.menu_sent = m;
            try fx.add(.{ .menu = m });
        }
    }

    fn onChecked(c: *Controller, now: i64, result: CheckResult, fx: *Fx) !void {
        switch (result) {
            .no_desk, .bad_desk => {
                try c.setDesk(null, fx);
                // a code that still comes has no port to go to
                c.entering = false;
                c.state = .setup;
                c.misses = 0;
                c.reentering = false;
                try c.show(.setup, if (result == .bad_desk) "Its state/desk.json can't be read." else "", fx);
            },
            .dead => |d| {
                try c.setDesk(d, fx);
                if (c.state == .in) {
                    c.misses +|= 1;
                    if (c.misses < 2 and !c.reentering) return;
                }
                c.state = .down;
                c.reentering = false;
                try c.show(.down, "", fx);
            },
            .alive => |d| {
                try c.setDesk(d, fx);
                c.misses = 0;
                if (c.entering) return;
                if (c.state == .in) {
                    if (c.reentering) try c.beginEntry(now, fx);
                    return;
                }
                c.state = .connecting;
                if (c.screen != .connecting) try c.show(.connecting, "", fx);
                try c.beginEntry(now, fx);
            },
        }
    }

    fn checkNow(c: *Controller, now: i64, fx: *Fx) !void {
        c.check_gen +%= 1;
        c.checking = true;
        c.last_check_ms = now;
        try fx.add(.{ .check = c.check_gen });
    }

    fn beginEntry(c: *Controller, now: i64, fx: *Fx) !void {
        _ = now;
        c.enter_gen +%= 1;
        c.entering = true;
        try fx.add(.{ .enter = c.enter_gen });
    }

    fn reenter(c: *Controller, now: i64, fx: *Fx) !void {
        if (c.entering or c.reentering) return;
        c.reentering = true;
        if (!c.checking) try c.checkNow(now, fx);
    }

    fn startHarness(c: *Controller, now: i64, fx: *Fx) !void {
        const bin = c.binary() orelse return fx.add(.{ .alert = .{
            .title = "Couldn't start harness",
            .text = "Its state/desk.json doesn't say where harness is. Run harness run in Terminal.",
        } });
        try fx.add(.{ .run = c.runOf(.run, bin) });
        c.started_ms = now;
        c.fast_until_ms = now + fast_for_ms;
        // the first check a second from now
        c.last_check_ms = @min(c.last_check_ms, now - check_every_ms + fast_check_every_ms);
    }

    fn show(c: *Controller, s: Screen, note: []const u8, fx: *Fx) !void {
        if (c.screen == s and std.mem.eql(u8, c.note, note)) return;
        c.screen = s;
        c.note = note;
        c.entered_port = null;
        try fx.add(.{ .show = .{ .screen = s, .note = note } });
    }

    fn binary(c: *const Controller) ?[]const u8 {
        const d = c.desk orelse return null;
        return if (d.binary.len > 0) d.binary else null;
    }

    fn runOf(c: *const Controller, cmd: Command, bin: []const u8) @FieldType(Effect, "run") {
        return .{ .cmd = cmd, .binary = bin, .home = c.home, .path = c.desk.?.path };
    }

    /// Keeps its own copy of `d`; asks Open at login's state when the binary
    /// is new.
    fn setDesk(c: *Controller, d: ?Desk, fx: *Fx) !void {
        if (d == null) {
            if (c.desk != null) {
                c.desk = null;
                _ = c.desk_arena.reset(.retain_capacity);
            }
            return;
        }
        const n = d.?;
        if (c.desk) |old| if (old.port == n.port and std.mem.eql(u8, old.binary, n.binary) and
            std.mem.eql(u8, old.home, n.home) and std.mem.eql(u8, old.version, n.version) and
            std.mem.eql(u8, old.path, n.path)) return;
        const new_binary = if (c.desk) |old| !std.mem.eql(u8, old.binary, n.binary) else true;
        // the effects already handed out this turn don't point into the arena
        _ = c.desk_arena.reset(.retain_capacity);
        const da = c.desk_arena.allocator();
        c.desk = .{
            .port = n.port,
            .binary = try da.dupe(u8, n.binary),
            .home = try da.dupe(u8, n.home),
            .version = try da.dupe(u8, n.version),
            .path = try da.dupe(u8, n.path),
        };
        if (new_binary) {
            c.autostart = null;
            if (c.binary()) |bin| try fx.add(.{ .run = c.runOf(.autostart_query, bin) });
        }
    }

    fn menu(c: *const Controller) Menu {
        const known = c.binary() != null;
        const up = c.state == .in or c.state == .connecting;
        return .{ .start = known and !up, .stop = known and up, .autostart_enabled = known, .autostart = c.autostart };
    }
};

const Fx = struct {
    out: *std.ArrayList(Effect),
    gpa: std.mem.Allocator,
    fn add(f: *Fx, e: Effect) !void {
        try f.out.append(f.gpa, e);
    }
};

const t = std.testing;

const Rig = struct {
    c: Controller,
    arena: std.heap.ArenaAllocator,
    out: std.ArrayList(Effect) = .empty,
    now: i64 = 1_000_000,

    fn init() Rig {
        return .{ .c = .init(t.allocator, "/data/harness"), .arena = .init(t.allocator) };
    }
    fn deinit(r: *Rig) void {
        r.out.deinit(t.allocator);
        r.c.deinit();
        r.arena.deinit();
    }
    fn ev(r: *Rig, e: Event) ![]const Effect {
        r.out.clearRetainingCapacity();
        try r.c.handle(r.now, e, &r.out, r.arena.allocator());
        return r.out.items;
    }
    fn wait(r: *Rig, ms: i64) void {
        r.now += ms;
    }
    /// The gen of the check asked for, or a test failure.
    fn checkGen(fx: []const Effect) !u32 {
        for (fx) |f| if (f == .check) return f.check;
        return error.NoCheck;
    }
    fn enterGen(fx: []const Effect) !u32 {
        for (fx) |f| if (f == .enter) return f.enter;
        return error.NoEnter;
    }
    /// Starts, finds harness alive and enters with `code`.
    fn getIn(r: *Rig, d: Desk, code: []const u8) !void {
        const g = try checkGen(try r.ev(.start));
        const e = try enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d } } }));
        _ = try r.ev(.{ .entered = .{ .gen = e, .code = code } });
    }
};

fn count(fx: []const Effect, tag: std.meta.Tag(Effect)) usize {
    var n: usize = 0;
    for (fx) |f| if (f == tag) {
        n += 1;
    };
    return n;
}
fn shown(fx: []const Effect) ?Screen {
    for (fx) |f| if (f == .show) return f.show.screen;
    return null;
}
fn loaded(fx: []const Effect) ?[]const u8 {
    for (fx) |f| if (f == .load) return f.load;
    return null;
}
fn ran(fx: []const Effect) ?Command {
    for (fx) |f| if (f == .run) return f.run.cmd;
    return null;
}
fn menuOf(fx: []const Effect) ?Menu {
    for (fx) |f| if (f == .menu) return f.menu;
    return null;
}

const d1: Desk = .{ .port = 41234, .binary = "/usr/local/bin/harness", .home = "/data/harness", .path = "/opt/homebrew/bin:/usr/bin" };
const nobin: Desk = .{ .port = 41234 };

test "no_desk_json_shows_setup" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    const fx = try r.ev(.{ .checked = .{ .gen = g, .result = .no_desk } });
    try t.expectEqual(Screen.setup, shown(fx).?);
    try t.expectEqual(State.setup, r.c.state);
    try t.expect(r.c.showingBuiltin());
    try t.expect(r.c.port() == null);

    // a desk.json that can't be read: the same page, saying so
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    const bad = try r.ev(.{ .checked = .{ .gen = g2, .result = .bad_desk } });
    for (bad) |f| if (f == .show) try t.expect(f.show.note.len > 0);
    try t.expectEqual(Screen.setup, shown(bad).?);
}

test "desk_json_appearing_is_noticed" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    _ = try r.ev(.{ .checked = .{ .gen = g, .result = .no_desk } });
    r.wait(1000);
    try t.expectEqual(@as(usize, 0), count(try r.ev(.tick), .check));
    r.wait(4000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    const fx = try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .alive = d1 } } });
    try t.expectEqual(Screen.connecting, shown(fx).?);
    try t.expectEqual(@as(usize, 1), count(fx, .enter));
    try t.expectEqual(State.connecting, r.c.state);
}

test "alive_enters_and_loads_the_enter_url" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    const fx = try r.ev(.{ .entered = .{ .gen = e, .code = "abc123" } });
    try t.expectEqualStrings("http://127.0.0.1:41234/enter?code=abc123", loaded(fx).?);
    try t.expectEqual(State.in, r.c.state);
    try t.expectEqual(@as(?u16, 41234), r.c.port());
    try t.expect(!r.c.showingBuiltin());
}

test "no_code_stays_connecting_and_tries_again" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    r.wait(30_000);
    const fx = try r.ev(.{ .entered = .{ .gen = e, .code = null } });
    try t.expect(loaded(fx) == null);
    try t.expectEqual(State.connecting, r.c.state);
    var noted = false;
    for (fx) |f| if (f == .show and f.show.screen == .connecting and f.show.note.len > 0) {
        noted = true;
    };
    try t.expect(noted);
    // the next check enters again, with a new entry
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    const e2 = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .alive = d1 } } }));
    try t.expect(e2 != e);
}

test "two_missed_checks_while_in_show_down" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    r.wait(5000);
    const g = try Rig.checkGen(try r.ev(.tick));
    const one = try r.ev(.{ .checked = .{ .gen = g, .result = .{ .dead = d1 } } });
    try t.expect(shown(one) == null);
    try t.expectEqual(State.in, r.c.state);
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    const two = try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .dead = d1 } } });
    try t.expectEqual(Screen.down, shown(two).?);
    try t.expectEqual(State.down, r.c.state);
}

test "one_miss_then_alive_stays_in" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    for ([_]bool{ false, true, false, true }) |alive| {
        r.wait(5000);
        const g = try Rig.checkGen(try r.ev(.tick));
        const fx = try r.ev(.{ .checked = .{ .gen = g, .result = if (alive) .{ .alive = d1 } else .{ .dead = d1 } } });
        try t.expect(shown(fx) == null);
        try t.expectEqual(@as(usize, 0), count(fx, .enter));
        try t.expectEqual(State.in, r.c.state);
    }
}

test "reenter_checks_then_enters_without_a_screen" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    r.wait(1000);
    const g = try Rig.checkGen(try r.ev(.{ .message = .{ .msg = .{ .reenter = true }, .source = .desk } }));
    const fx = try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } });
    try t.expect(shown(fx) == null);
    const e = try Rig.enterGen(fx);
    const in = try r.ev(.{ .entered = .{ .gen = e, .code = "c2" } });
    try t.expectEqualStrings("http://127.0.0.1:41234/enter?code=c2", loaded(in).?);
    // harness gone instead: the page says so
    const g2 = try Rig.checkGen(try r.ev(.{ .message = .{ .msg = .{ .reenter = true }, .source = .desk } }));
    try t.expectEqual(Screen.down, shown(try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .dead = d1 } } })).?);
}

test "reenter_during_an_entry_is_ignored" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    const g = try Rig.checkGen(try r.ev(.{ .message = .{ .msg = .{ .reenter = true }, .source = .desk } }));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    const again = try r.ev(.{ .message = .{ .msg = .{ .reenter = true }, .source = .desk } });
    try t.expectEqual(@as(usize, 0), count(again, .check) + count(again, .enter));
    // nor does a check that comes back meanwhile start a second entry
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .alive = d1 } } }), .enter));
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .entered = .{ .gen = e, .code = "c2" } }), .load));
}

test "start_runs_harness_and_checks_fast" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    try t.expectEqual(Screen.down, shown(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .dead = d1 } } })).?);
    // from the desk page a start means nothing
    try t.expect(ran(try r.ev(.{ .message = .{ .msg = .{ .start = true }, .source = .desk } })) == null);
    const fx = try r.ev(.{ .message = .{ .msg = .{ .start = true }, .source = .builtin } });
    try t.expectEqual(Command.run, ran(fx).?);
    for (fx) |f| if (f == .run) {
        try t.expectEqualStrings("/usr/local/bin/harness", f.run.binary);
        try t.expectEqualStrings("/data/harness", f.run.home);
        try t.expectEqualStrings("/opt/homebrew/bin:/usr/bin", f.run.path);
    };
    // every second for 15 s
    var checks: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        r.wait(1000);
        const tick = try r.ev(.tick);
        if (count(tick, .check) > 0) {
            checks += 1;
            _ = try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(tick), .result = .{ .dead = d1 } } });
        }
    }
    try t.expect(checks >= 15 and checks <= 17);
    // the menu's Start does the same
    try t.expectEqual(Command.run, ran(try r.ev(.{ .menu = .start })).?);
}

test "start_without_a_binary_says_so" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    _ = try r.ev(.{ .checked = .{ .gen = g, .result = .{ .dead = nobin } } });
    const fx = try r.ev(.{ .message = .{ .msg = .{ .start = true }, .source = .builtin } });
    try t.expect(ran(fx) == null);
    try t.expectEqual(@as(usize, 1), count(fx, .alert));
}

test "harness_exiting_right_after_start_says_so" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    _ = try r.ev(.{ .checked = .{ .gen = g, .result = .{ .dead = d1 } } });
    _ = try r.ev(.{ .menu = .start });
    r.wait(2000);
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .exited = .{ .code = 1 } }), .alert));
    _ = try r.ev(.{ .menu = .start });
    r.wait(60_000);
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .exited = .{ .code = 1 } }), .alert));
    _ = try r.ev(.{ .menu = .start });
    r.wait(1000);
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .exited = .{ .code = 0 } }), .alert));
}

test "stale_results_are_dropped" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    try t.expectEqual(@as(usize, 0), (try r.ev(.{ .checked = .{ .gen = g +% 7, .result = .{ .alive = d1 } } })).len);
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    try t.expect(loaded(try r.ev(.{ .entered = .{ .gen = e +% 7, .code = "x" } })) == null);
    try t.expectEqual(State.connecting, r.c.state);
}

test "badge_and_attention_from_the_desk_page_only" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    const fx = try r.ev(.{ .message = .{ .msg = .{ .badge = 3, .attention = true }, .source = .desk } });
    try t.expectEqual(@as(usize, 1), count(fx, .badge));
    try t.expectEqual(@as(usize, 1), count(fx, .attention));
    for (fx) |f| if (f == .badge) try t.expectEqual(@as(u32, 3), f.badge);
    for ([_]bridge.Source{ .other, .builtin }) |src| {
        const no = try r.ev(.{ .message = .{ .msg = .{ .badge = 5, .attention = true, .reenter = true }, .source = src } });
        try t.expectEqual(@as(usize, 0), count(no, .badge) + count(no, .attention) + count(no, .check));
    }
}

test "a_new_port_in_desk_json_is_used_from_the_next_check" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    var moved = d1;
    moved.port = 50000;
    const g = try Rig.checkGen(try r.ev(.{ .message = .{ .msg = .{ .reenter = true }, .source = .desk } }));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = moved } } }));
    // the page shown is still the old port's until the new entry loads
    try t.expectEqual(@as(?u16, 41234), r.c.port());
    const fx = try r.ev(.{ .entered = .{ .gen = e, .code = "c2" } });
    try t.expectEqualStrings("http://127.0.0.1:50000/enter?code=c2", loaded(fx).?);
    try t.expectEqual(@as(?u16, 50000), r.c.port());
}

test "refused_entry_enters_again_at_most_every_5_s" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    r.wait(1000);
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .loaded = .{ .status = 403, .url = "http://127.0.0.1:41234/desk" } }), .check));
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .loaded = .{ .status = 200, .url = "http://127.0.0.1:41234/desk" } }), .check));
    r.wait(5000);
    const g = try Rig.checkGen(try r.ev(.{ .loaded = .{ .status = 401, .url = "http://127.0.0.1:41234/desk" } }));
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }), .enter));
}

test "a_failed_load_or_a_crash_while_in_checks_now" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    // a failed load counts as one miss: one more and it's down
    const g = try Rig.checkGen(try r.ev(.failed));
    try t.expectEqual(Screen.down, shown(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .dead = d1 } } })).?);

    var r2: Rig = .init();
    defer r2.deinit();
    try r2.getIn(d1, "c1");
    const g2 = try Rig.checkGen(try r2.ev(.crashed));
    try t.expectEqual(@as(usize, 1), count(try r2.ev(.{ .checked = .{ .gen = g2, .result = .{ .alive = d1 } } }), .enter));
}

test "menu_state_follows" {
    var r: Rig = .init();
    defer r.deinit();
    // sent once at the start, then only when it changes
    const first = try r.ev(.start);
    const setup = menuOf(first).?;
    try t.expect(!setup.start and !setup.stop and !setup.autostart_enabled);
    try t.expect(menuOf(try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(first), .result = .no_desk } })) == null);

    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    const down = try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .dead = d1 } } });
    const m = menuOf(down).?;
    try t.expect(m.start and !m.stop and m.autostart_enabled and m.autostart == null);
    try t.expectEqual(Command.autostart_query, ran(down).?);

    const on = menuOf(try r.ev(.{ .ran = .{ .cmd = .autostart_query, .ok = true, .autostart = true } })).?;
    try t.expectEqual(@as(?bool, true), on.autostart);
    try t.expectEqual(Command.autostart_off, ran(try r.ev(.{ .menu = .autostart })).?);
    const off = menuOf(try r.ev(.{ .ran = .{ .cmd = .autostart_off, .ok = true } })).?;
    try t.expectEqual(@as(?bool, false), off.autostart);
    try t.expectEqual(Command.autostart_on, ran(try r.ev(.{ .menu = .autostart })).?);
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .ran = .{ .cmd = .autostart_on, .ok = false, .text = "no launchctl" } }), .alert));

    r.wait(5000);
    const g3 = try Rig.checkGen(try r.ev(.tick));
    const connecting = try r.ev(.{ .checked = .{ .gen = g3, .result = .{ .alive = d1 } } });
    const up = menuOf(connecting).?;
    try t.expect(!up.start and up.stop);
    try t.expect(menuOf(try r.ev(.{ .entered = .{ .gen = try Rig.enterGen(connecting), .code = "c" } })) == null);
    try t.expectEqual(Command.stop, ran(try r.ev(.{ .menu = .stop })).?);
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .menu = .reload }), .reload));
}

test "desk_json_vanishing_during_an_entry_drops_it" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    try t.expectEqual(Screen.setup, shown(try r.ev(.{ .checked = .{ .gen = g2, .result = .no_desk } })).?);
    try t.expect(loaded(try r.ev(.{ .entered = .{ .gen = e, .code = "late" } })) == null);
    try t.expectEqual(State.setup, r.c.state);
}
