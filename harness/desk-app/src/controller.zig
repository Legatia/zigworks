//! The app's state, decided apart from the window: events come in (a
//! timer, a check's result, a code, a message from the page, a menu item),
//! effects go out (show a page, load a URL, check, enter, run a command, set
//! the badge). Effects' strings are valid until the next `handle`.
const std = @import("std");
const bridge = @import("bridge.zig");
const deskjson = @import("deskjson.zig");
const Command = @import("commands.zig").Command;
const pages = @import("pages.zig");
const Screen = pages.Screen;
const setup = @import("setup.zig");
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

/// `no_config`: the data folder has no config.ini (harness was never set
/// up there); checked before desk.json.
pub const CheckResult = union(enum) { no_config, no_desk, bad_desk, dead: Desk, alive: Desk };

pub const MenuItem = enum { start, stop, autostart, reload, provider };

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
    /// A setup step (`step`) ended: its error line, and the first line it
    /// printed.
    stepped: struct { gen: u32, ok: bool, text: []const u8 = "", out: []const u8 = "" },
    /// The values in use were read (`read_config`).
    read: struct { gen: u32, ok: bool, text: []const u8 = "", in_use: setup.InUse = .{} },
    /// The secure field's answer: a key was typed (the app holds it, not
    /// the controller), nothing was, or it was cancelled.
    key: enum { given, empty, cancelled },
    /// `harness secret add` ended (`store_key`).
    stored: struct { gen: u32, ok: bool, text: []const u8 = "" },
};

pub const Menu = struct {
    start: bool = false,
    stop: bool = false,
    autostart_enabled: bool = false,
    autostart: ?bool = null,
    /// "Provider and key…"
    provider: bool = false,
};

pub const Effect = union(enum) {
    show: struct { screen: Screen, note: []const u8 = "", view: pages.View = .{} },
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
    /// Run a setup step to its end; answer `stepped`. `path`: PATH for it
    /// ("" leaves the app's).
    step: struct { gen: u32, argv: []const []const u8, path: []const u8 },
    /// Read the values in use with `harness config get`; answer `read`.
    read_config: struct { gen: u32, binary: []const u8, home: []const u8, path: []const u8 },
    /// Ask for the key in the secure field; answer `key`.
    ask_key: struct { title: []const u8, note: []const u8 },
    /// Pipe the key typed to `argv`, then clear it; answer `stored`. The
    /// app holds the key from `key = .given` while `holdsKey()`.
    store_key: struct { gen: u32, argv: []const []const u8, path: []const u8 },
    /// Write (true) or remove (false) `state/setup-unfinished`: harness
    /// init ran from the first setup, which isn't finished, so the next
    /// start shows "Set up" again.
    mark: bool,
};

/// The secure field's note: where harness keeps the key. macOS has the
/// Keychain and Windows the Credential Manager; elsewhere harness has no
/// key store and keeps a file per secret in the data folder.
pub const key_note = keyNote(@import("builtin").os.tag);

pub fn keyNote(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos, .windows => "harness keeps it in this computer's key store.",
        else => "harness keeps it in its data folder, in a file only you can read.",
    };
}

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

    /// harness beside the app's own program; "" when it isn't there.
    own: []const u8 = "",
    /// The "Set up" screen while it is open; its strings in `form_arena`.
    form: ?Form = null,
    form_arena: std.heap.ArenaAllocator,
    form_gen: u32 = 0,
    /// "Provider and key…" waits for the values in use.
    reading: ?u32 = null,
    /// The harness Open at login's state was asked of.
    autostart_bin: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, home: []const u8, own: []const u8) Controller {
        return .{ .gpa = gpa, .home = home, .own = own, .desk_arena = .init(gpa), .form_arena = .init(gpa) };
    }

    pub fn deinit(c: *Controller) void {
        c.desk_arena.deinit();
        c.form_arena.deinit();
        c.autostart_bin.deinit(c.gpa);
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
                if (c.form != null) {
                    // the form stays; the desk is entered once it closes
                    c.reentering = true;
                } else if (r.code) |code| {
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
                .builtin => {
                    if (m.msg.start) try c.startHarness(now, &fx);
                    if (m.msg.setup) |f| try c.submit(f, &fx, a);
                    if (m.msg.cancel) try c.cancelForm(now, &fx);
                },
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
                .reload => if (c.form != null) {
                    // what was typed stays
                    try c.showForm(&fx);
                } else if (c.state == .in) {
                    try fx.add(.reload);
                } else if (!c.checking) try c.checkNow(now, &fx),
                .provider => try c.askProvider(&fx),
            },
            .stepped => |r| try c.onStepped(now, r.gen, r.ok, r.text, r.out, &fx, a),
            .read => |r| if (c.reading != null and c.reading.? == r.gen) {
                c.reading = null;
                // a form opened meanwhile (the first setup's) stays
                if (c.form != null) {} else if (r.ok) {
                    try c.openForm(.change, setup.formOf(r.in_use), r.in_use, &fx);
                } else try fx.add(.{ .alert = .{ .title = "Couldn't read the settings", .text = r.text } });
            },
            .key => |k| try c.onKey(k, &fx, a),
            .stored => |r| if (c.form) |*f| if (f.step == .store and r.gen == c.form_gen) {
                if (r.ok) {
                    try c.finish(now, &fx);
                } else try c.failStep(r.text, "harness secret add failed.", &fx);
            },
            .loaded => |l| if (c.state == .in and (l.status == 401 or l.status == 403)) {
                if (now - c.last_enter_ms >= reenter_every_ms) {
                    try c.reenter(now, &fx);
                } else if (!c.entering) {
                    // refused right after an entry: the next check enters again
                    c.reentering = true;
                }
            },
            .failed => if (c.state == .in) {
                c.misses = @max(c.misses, 1);
                if (!c.checking) try c.checkNow(now, &fx);
            },
            .crashed => if (c.form != null) {
                try c.showForm(&fx);
            } else if (c.state == .in) {
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
                // the app's own copy isn't on PATH: the whole command
                if (x.code != 0 and now - at < early_exit_ms) try fx.add(.{ .alert = .{
                    .title = "harness stopped",
                    .text = try std.fmt.allocPrint(a, "It exited right after starting, with code {d}. To see why, run in Terminal: \"{s}\" run --home \"{s}\"", .{ x.code, c.binary() orelse "harness", c.home }),
                } });
            },
        }
        const m = c.menu(now);
        if (c.menu_sent == null or !std.meta.eql(c.menu_sent.?, m)) {
            c.menu_sent = m;
            try fx.add(.{ .menu = m });
        }
    }

    fn onChecked(c: *Controller, now: i64, result: CheckResult, fx: *Fx) !void {
        defer c.askAutostart(fx) catch {};
        if (c.form != null) {
            // the form stays until it is done or cancelled
            switch (result) {
                .dead, .alive => |d| try c.setDesk(d, fx),
                else => {},
            }
            return;
        }
        switch (result) {
            .no_config, .no_desk, .bad_desk => {
                // harness may be rewriting it: the desk page stays one check
                if (c.state == .in) {
                    c.misses +|= 1;
                    if (c.misses < 2) return;
                }
                try c.setDesk(null, fx);
                // a code that still comes has no port to go to
                c.entering = false;
                c.misses = 0;
                c.reentering = false;
                if (result == .no_config) {
                    c.state = .setup;
                    const e = setup.entry(.anthropic);
                    return c.openForm(.first, .{ .provider = e.id, .model = e.model }, null, fx);
                }
                // harness started from the app hasn't written desk.json yet
                if (result == .no_desk and c.starting(now) and c.state != .in) return;
                c.state = .down;
                try c.show(.down, if (result == .bad_desk) "Its state/desk.json can't be read." else "", fx);
            },
            .dead => |d| {
                try c.setDesk(d, fx);
                // harness started from the app isn't answering yet
                if (c.starting(now) and c.screen == .connecting and c.state != .in) return;
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
                if (c.state == .in) {
                    // back on another port: the page shown is on the old one,
                    // whose requests fail without a 401 to say so
                    if (c.entered_port != d.port) c.reentering = true;
                    if (c.reentering and !c.entering) try c.beginEntry(now, fx);
                    return;
                }
                c.state = .connecting;
                if (c.screen != .connecting) try c.show(.connecting, "", fx);
                if (!c.entering) try c.beginEntry(now, fx);
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
        if (c.entering) return;
        c.reentering = true;
        if (!c.checking) try c.checkNow(now, fx);
    }

    fn startHarness(c: *Controller, now: i64, fx: *Fx) !void {
        // once until it answers, exits, or 15 s pass
        if (c.starting(now)) return;
        const bin = c.binary() orelse return fx.add(.{ .alert = .{
            .title = "Couldn't start harness",
            .text = "There's no harness beside the app, and state/desk.json doesn't name one.",
        } });
        try fx.add(.{ .run = c.runOf(.run, bin) });
        c.started_ms = now;
        c.fast_until_ms = now + fast_for_ms;
        // the first check a second from now
        c.last_check_ms = @min(c.last_check_ms, now - check_every_ms + fast_check_every_ms);
    }

    fn starting(c: *const Controller, now: i64) bool {
        const at = c.started_ms orelse return false;
        return now - at < fast_for_ms;
    }

    fn show(c: *Controller, s: Screen, note: []const u8, fx: *Fx) !void {
        if (c.screen == s and std.mem.eql(u8, c.note, note)) return;
        c.screen = s;
        c.note = note;
        c.entered_port = null;
        try fx.add(.{ .show = .{ .screen = s, .note = note } });
    }

    /// The harness the commands run: the one desk.json names, else the
    /// app's own copy beside its program.
    fn binary(c: *const Controller) ?[]const u8 {
        if (c.desk) |d| if (d.binary.len > 0) return d.binary;
        return if (c.own.len > 0) c.own else null;
    }

    /// The PATH the commands get: harness's own, when desk.json says it.
    fn path(c: *const Controller) []const u8 {
        return if (c.desk) |d| d.path else "";
    }

    fn runOf(c: *const Controller, cmd: Command, bin: []const u8) @FieldType(Effect, "run") {
        return .{ .cmd = cmd, .binary = bin, .home = c.home, .path = c.path() };
    }

    /// Open at login's state, asked whenever the harness the commands run
    /// changes (once harness is set up).
    fn askAutostart(c: *Controller, fx: *Fx) !void {
        if (c.state == .setup) return;
        const bin = c.binary() orelse "";
        if (std.mem.eql(u8, bin, c.autostart_bin.items)) return;
        c.autostart_bin.clearRetainingCapacity();
        try c.autostart_bin.appendSlice(c.gpa, bin);
        c.autostart = null;
        if (bin.len > 0) try fx.add(.{ .run = c.runOf(.autostart_query, bin) });
    }

    // ---- the "Set up" screen ----

    fn openForm(c: *Controller, mode: pages.Mode, form: setup.Form, before: ?setup.InUse, fx: *Fx) !void {
        _ = c.form_arena.reset(.retain_capacity);
        const fa = c.form_arena.allocator();
        c.form = .{
            .mode = mode,
            .form = try copyForm(fa, form),
            .before = if (before) |b| try copyInUse(fa, b) else null,
            // "Provider and key…": config.ini is there
            .inited = mode == .change,
        };
        c.form_gen +%= 1;
        try c.showForm(fx);
    }

    fn showForm(c: *Controller, fx: *Fx) !void {
        const f = &c.form.?;
        c.screen = .setup;
        c.note = f.note;
        c.entered_port = null;
        try fx.add(.{ .show = .{ .screen = .setup, .note = f.note, .view = .{ .mode = f.mode, .form = f.form, .busy = f.step != null } } });
    }

    /// [Continue]: the form's own problems first, then `harness init`
    /// (unless config.ini is there), `harness config set`, the key, and
    /// harness started.
    fn submit(c: *Controller, form: setup.Form, fx: *Fx, a: std.mem.Allocator) !void {
        const f = &(c.form orelse return);
        if (f.step != null) return;
        f.form = try copyForm(c.form_arena.allocator(), form);
        f.note = "";
        f.key = .keep;
        if (setup.problem(f.form)) |why| {
            f.note = why;
        } else if (c.binary()) |bin| {
            if (needKey(f.*)) {
                // the key before anything is written: a cancel changes nothing
                f.step = .key;
                const e = setup.entry(f.form.provider);
                try fx.add(.{ .ask_key = .{
                    .title = if (f.form.provider == .other) "Key" else try std.fmt.allocPrint(a, "{s} key", .{e.label}),
                    .note = key_note,
                } });
            } else try c.runStep(if (f.inited) .config else .init, bin, fx, a);
        } else {
            f.note = "There's no harness beside the app, and state/desk.json names none.";
        }
        try c.showForm(fx);
    }

    /// Whether the app holds a key typed for the steps running now.
    pub fn holdsKey(c: *const Controller) bool {
        const f = c.form orelse return false;
        return f.key == .given and (f.step == .init or f.step == .config);
    }

    fn runStep(c: *Controller, step: Step, bin: []const u8, fx: *Fx, a: std.mem.Allocator) !void {
        const f = &c.form.?;
        f.step = step;
        c.form_gen +%= 1;
        const argv = switch (step) {
            .init => try setup.initArgv(a, bin, c.home),
            .config => try setup.configArgv(a, bin, c.home, f.form, f.before, f.key),
            .store => try setup.secretArgv(a, bin, c.home, setup.keyName(f.form, f.before)),
            .key => unreachable,
        };
        if (step == .store) {
            // the app hands the key over with this effect
            f.key = .keep;
            try fx.add(.{ .store_key = .{ .gen = c.form_gen, .argv = argv, .path = c.path() } });
        } else try fx.add(.{ .step = .{ .gen = c.form_gen, .argv = argv, .path = c.path() } });
    }

    fn onStepped(c: *Controller, now: i64, gen: u32, ok: bool, text: []const u8, out: []const u8, fx: *Fx, a: std.mem.Allocator) !void {
        const f = &(c.form orelse return);
        if (gen != c.form_gen) return;
        const step = f.step orelse return;
        if (step != .init and step != .config) return;
        if (!ok) return c.failStep(text, if (step == .init) "harness init failed." else "harness config set failed.", fx);
        const bin = c.binary() orelse return c.failStep("There's no harness beside the app, and state/desk.json names none.", "", fx);
        if (step == .init) {
            f.inited = true;
            if (f.mode == .first) try fx.add(.{ .mark = true });
            return c.runStep(.config, bin, fx, a);
        }
        f.said = try c.form_arena.allocator().dupe(u8, firstLine(out));
        if (f.key == .given) return c.runStep(.store, bin, fx, a);
        try c.finish(now, fx);
    }

    fn onKey(c: *Controller, k: @FieldType(Event, "key"), fx: *Fx, a: std.mem.Allocator) !void {
        const f = &(c.form orelse return);
        if (f.step != .key) return;
        const bin = c.binary() orelse return c.failStep("There's no harness beside the app, and state/desk.json names none.", "", fx);
        switch (k) {
            .given => f.key = .given,
            // a server of one's own may take no key
            .empty => if (setup.keyOptional(f.form.provider)) {
                f.key = .none;
            } else return c.failStep("No key was typed. Nothing was changed.", "", fx),
            .cancelled => return c.failStep("Cancelled. Nothing was changed.", "", fx),
        }
        try c.runStep(if (f.inited) .config else .init, bin, fx, a);
    }

    /// The step ended without doing its part: its line on the form, which
    /// keeps what was typed and waits for [Continue].
    fn failStep(c: *Controller, text: []const u8, otherwise: []const u8, fx: *Fx) !void {
        const f = &c.form.?;
        f.step = null;
        // a key typed is let go (the app drops it); Continue asks again
        f.key = .keep;
        f.note = try c.form_arena.allocator().dupe(u8, if (text.len > 0) text else otherwise);
        try c.showForm(fx);
    }

    /// Every step done. While harness runs, `harness config set` said what
    /// the change waits for (/reload, or a restart): that line, and the
    /// desk again. Otherwise harness is started and entered.
    fn finish(c: *Controller, now: i64, fx: *Fx) !void {
        const said = c.form.?.said;
        if (c.form.?.mode == .first) try fx.add(.{ .mark = false });
        c.form = null;
        c.state = .down;
        c.reentering = false;
        if (std.mem.startsWith(u8, said, "harness is running")) {
            try fx.add(.{ .alert = .{ .title = "Saved", .text = said } });
            return c.checkNow(now, fx);
        }
        c.screen = null;
        try c.show(.connecting, "", fx);
        try c.startHarness(now, fx);
    }

    /// [Cancel] ("Provider and key…" only): back to the desk, unchanged.
    fn cancelForm(c: *Controller, now: i64, fx: *Fx) !void {
        const f = c.form orelse return;
        if (f.mode != .change or f.step != null) return;
        c.form = null;
        c.state = .down;
        try c.checkNow(now, fx);
    }

    /// "Provider and key…": the values in use are read, then the form opens
    /// with them.
    fn askProvider(c: *Controller, fx: *Fx) !void {
        if (c.form != null or c.reading != null or c.state == .setup) return;
        const bin = c.binary() orelse return;
        c.form_gen +%= 1;
        c.reading = c.form_gen;
        try fx.add(.{ .read_config = .{ .gen = c.form_gen, .binary = bin, .home = c.home, .path = c.path() } });
    }

    /// Keeps its own copy of `d`.
    fn setDesk(c: *Controller, d: ?Desk, fx: *Fx) !void {
        _ = fx;
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
    }

    fn menu(c: *const Controller, now: i64) Menu {
        const known = c.binary() != null;
        // nothing to start before harness is set up
        const set_up = c.state != .setup;
        const up = c.state == .in or c.state == .connecting;
        return .{
            .start = known and set_up and !up and !c.starting(now),
            .stop = known and up,
            .autostart_enabled = known and set_up,
            .autostart = c.autostart,
            .provider = known and set_up and c.form == null and c.reading == null,
        };
    }
};

fn copyForm(a: std.mem.Allocator, f: setup.Form) !setup.Form {
    var out = f;
    out.model = try a.dupe(u8, f.model);
    out.url = try a.dupe(u8, f.url);
    return out;
}

fn copyInUse(a: std.mem.Allocator, u: setup.InUse) !setup.InUse {
    var out = u;
    inline for (@typeInfo(setup.InUse).@"struct".field_names) |name| @field(out, name) = try a.dupe(u8, @field(u, name));
    return out;
}

/// The first line with something on it.
fn firstLine(text: []const u8) []const u8 {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |l| {
        const line = std.mem.trim(u8, l, " \t");
        if (line.len > 0) return line;
    }
    return "";
}

/// Whether [Continue] asks for the key: always at the first setup; later
/// when the owner chose to replace it, or the provider's key is another
/// secret than the one in use.
fn needKey(f: Form) bool {
    if (f.mode == .first or f.form.replace) return true;
    const before = f.before orelse return true;
    return !std.mem.eql(u8, setup.keyName(f.form, before), setup.keyName(setup.formOf(before), before));
}

/// The "Set up" screen's state.
const Form = struct {
    mode: pages.Mode,
    form: setup.Form,
    /// "Provider and key…": the values in use when it opened.
    before: ?setup.InUse = null,
    /// The step running, or null while the form waits.
    step: ?Step = null,
    /// config.ini is there (harness init has run).
    inited: bool,
    /// What `harness config set` said (whether harness runs).
    said: []const u8 = "",
    /// The key: typed and held by the app (`given`), none for a server
    /// that takes none, or left as it is.
    key: setup.KeyChoice = .keep,
    note: []const u8 = "",
};

const Step = enum { init, config, key, store };

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
        return .{ .c = .init(t.allocator, "/data/harness", ""), .arena = .init(t.allocator) };
    }
    fn initOwn(own: []const u8) Rig {
        return .{ .c = .init(t.allocator, "/data/harness", own), .arena = .init(t.allocator) };
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

test "no_desk_json_shows_down" {
    // set up (config.ini is there) but never run: "harness isn't running"
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    const fx = try r.ev(.{ .checked = .{ .gen = g, .result = .no_desk } });
    try t.expectEqual(Screen.down, shown(fx).?);
    try t.expectEqual(State.down, r.c.state);
    try t.expect(r.c.showingBuiltin());
    try t.expect(r.c.port() == null);

    // a desk.json that can't be read: the same page, saying so
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    const bad = try r.ev(.{ .checked = .{ .gen = g2, .result = .bad_desk } });
    for (bad) |f| if (f == .show) try t.expect(f.show.note.len > 0);
    try t.expectEqual(Screen.down, shown(bad).?);
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
    const at_start = menuOf(first).?;
    try t.expect(!at_start.start and !at_start.stop and !at_start.autostart_enabled);
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
    try t.expectEqual(Screen.down, shown(try r.ev(.{ .checked = .{ .gen = g2, .result = .no_desk } })).?);
    try t.expect(loaded(try r.ev(.{ .entered = .{ .gen = e, .code = "late" } })) == null);
    try t.expectEqual(State.down, r.c.state);
}

test "a_new_port_while_in_enters_again_without_a_reenter" {
    // harness restarted on another port; the page's requests fail on the
    // old one, so it never posts reenter
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    var moved = d1;
    moved.port = 50000;
    r.wait(5000);
    const g = try Rig.checkGen(try r.ev(.tick));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = moved } } }));
    try t.expectEqualStrings("http://127.0.0.1:50000/enter?code=c2", loaded(try r.ev(.{ .entered = .{ .gen = e, .code = "c2" } })).?);
    // and once there, an alive check on the same port enters no more
    r.wait(5000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .alive = moved } } }), .enter));
}

test "a_code_refused_at_once_enters_again_at_the_next_check" {
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    // /enter answered 403 straight away: no check now (at most every 5 s) ...
    try t.expectEqual(@as(usize, 0), count(try r.ev(.{ .loaded = .{ .status = 403, .url = "http://127.0.0.1:41234/enter?code=c1" } }), .check));
    // ... but the next check enters again
    r.wait(5000);
    const g = try Rig.checkGen(try r.ev(.tick));
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }), .enter));
}

test "one_unreadable_desk_json_while_in_is_a_miss" {
    // harness may be rewriting it: the desk page stays for one check
    var r: Rig = .init();
    defer r.deinit();
    try r.getIn(d1, "c1");
    for ([_]CheckResult{ .bad_desk, .no_desk }) |first| {
        r.wait(5000);
        const g = try Rig.checkGen(try r.ev(.tick));
        try t.expect(shown(try r.ev(.{ .checked = .{ .gen = g, .result = first } })) == null);
        try t.expectEqual(State.in, r.c.state);
        try t.expectEqual(@as(?u16, 41234), r.c.port());
        r.wait(5000);
        const g2 = try Rig.checkGen(try r.ev(.tick));
        _ = try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .alive = d1 } } });
    }
    // two in a row: it's gone
    r.wait(5000);
    _ = try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(try r.ev(.tick)), .result = .no_desk } });
    r.wait(5000);
    try t.expectEqual(Screen.down, shown(try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(try r.ev(.tick)), .result = .no_desk } })).?);
}

test "alive_again_during_an_entry_shows_connecting" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    _ = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    r.wait(5000);
    // one slow /alive while harness writes the code
    try t.expectEqual(Screen.down, shown(try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(try r.ev(.tick)), .result = .{ .dead = d1 } } })).?);
    r.wait(5000);
    const fx = try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(try r.ev(.tick)), .result = .{ .alive = d1 } } });
    try t.expectEqual(Screen.connecting, shown(fx).?);
    try t.expectEqual(@as(usize, 0), count(fx, .enter));
    try t.expectEqual(State.connecting, r.c.state);
}

test "start_twice_runs_harness_once" {
    var r: Rig = .init();
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    _ = try r.ev(.{ .checked = .{ .gen = g, .result = .{ .dead = d1 } } });
    const first = try r.ev(.{ .menu = .start });
    try t.expectEqual(Command.run, ran(first).?);
    // the menu's Start is off while harness starts
    try t.expect(!menuOf(first).?.start);
    r.wait(1000);
    try t.expect(ran(try r.ev(.{ .message = .{ .msg = .{ .start = true }, .source = .builtin } })) == null);
    try t.expect(ran(try r.ev(.{ .menu = .start })) == null);
    // after 15 s with no answer, it can be tried again
    r.wait(15_000);
    _ = try r.ev(.tick);
    try t.expectEqual(Command.run, ran(try r.ev(.{ .menu = .start })).?);
    // and when it exits at once, straight away
    _ = try r.ev(.{ .exited = .{ .code = 1 } });
    try t.expectEqual(Command.run, ran(try r.ev(.{ .menu = .start })).?);
}

// ---- the "Set up" screen ----

fn viewOf(fx: []const Effect) ?pages.View {
    for (fx) |f| if (f == .show and f.show.screen == .setup) return f.show.view;
    return null;
}
fn noteOf(fx: []const Effect) ?[]const u8 {
    for (fx) |f| if (f == .show) return f.show.note;
    return null;
}
fn stepOf(fx: []const Effect) ?@FieldType(Effect, "step") {
    for (fx) |f| if (f == .step) return f.step;
    return null;
}
fn askOf(fx: []const Effect) ?@FieldType(Effect, "ask_key") {
    for (fx) |f| if (f == .ask_key) return f.ask_key;
    return null;
}
fn storeOf(fx: []const Effect) ?@FieldType(Effect, "store_key") {
    for (fx) |f| if (f == .store_key) return f.store_key;
    return null;
}
fn alertOf(fx: []const Effect) ?@FieldType(Effect, "alert") {
    for (fx) |f| if (f == .alert) return f.alert;
    return null;
}
fn runOfFx(fx: []const Effect) ?@FieldType(Effect, "run") {
    for (fx) |f| if (f == .run) return f.run;
    return null;
}
fn expectWords(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

const own_bin = "/Applications/harness-desk.app/Contents/MacOS/harness";
const anthropic_form: setup.Form = .{ .provider = .anthropic, .model = "claude-opus-4-8" };

fn builtin(r: *Rig, msg: bridge.Message) ![]const Effect {
    return r.ev(.{ .message = .{ .msg = msg, .source = .builtin } });
}

/// Starts on a data folder with no config.ini: the form.
fn toForm(r: *Rig) ![]const Effect {
    const g = try Rig.checkGen(try r.ev(.start));
    return r.ev(.{ .checked = .{ .gen = g, .result = .no_config } });
}

test "no_config_shows_the_form" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    const first = try r.ev(.start);
    const fx = try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(first), .result = .no_config } });
    const v = viewOf(fx).?;
    try t.expectEqual(pages.Mode.first, v.mode);
    try t.expectEqual(setup.Provider.anthropic, v.form.provider);
    try t.expectEqualStrings("claude-opus-4-8", v.form.model);
    try t.expect(!v.busy);
    try t.expectEqual(State.setup, r.c.state);
    try t.expect(r.c.showingBuiltin());
    // nothing to start, stop or change before it is set up
    const m = r.c.menu(r.now);
    try t.expect(!m.start and !m.stop and !m.autostart_enabled and !m.provider);
    // a desk page's message can't fill it in
    try t.expectEqual(@as(usize, 0), (try r.ev(.{ .message = .{ .msg = .{ .setup = anthropic_form }, .source = .desk } })).len);
}

fn markOf(fx: []const Effect) ?bool {
    for (fx) |f| if (f == .mark) return f.mark;
    return null;
}

test "continue_asks_the_key_then_runs_init_config_and_stores_it" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toForm(&r);
    const c1 = try builtin(&r, .{ .setup = anthropic_form });
    try t.expect(viewOf(c1).?.busy);
    // the key first: nothing is written before it is given
    try t.expect(stepOf(c1) == null);
    const ask = askOf(c1).?;
    try t.expectEqualStrings("Anthropic key", ask.title);
    try t.expectEqualStrings(key_note, ask.note);
    try t.expectEqualStrings("harness keeps it in this computer's key store.", keyNote(.macos));
    try t.expectEqualStrings("harness keeps it in this computer's key store.", keyNote(.windows));
    // Linux has no key store harness uses: it says the file
    try t.expect(std.mem.indexOf(u8, keyNote(.linux), "key store") == null);
    const c2 = try r.ev(.{ .key = .given });
    try t.expect(r.c.holdsKey());
    const s1 = stepOf(c2).?;
    try expectWords(&.{ own_bin, "init", "--home", "/data/harness" }, s1.argv);
    const c3 = try r.ev(.{ .stepped = .{ .gen = s1.gen, .ok = true, .out = "Data folder: /data/harness" } });
    // from here a setup left half done is set up again at the next start
    try t.expectEqual(@as(?bool, true), markOf(c3));
    const s2 = stepOf(c3).?;
    try expectWords(&.{ own_bin, "config", "set", "model.provider", "anthropic", "model.model", "claude-opus-4-8", "model.memory_model", "claude-haiku-4-5", "model.worker_model", "claude-haiku-4-5", "--home", "/data/harness" }, s2.argv);
    try t.expect(r.c.holdsKey());
    const c4 = try r.ev(.{ .stepped = .{ .gen = s2.gen, .ok = true } });
    const st = storeOf(c4).?;
    try expectWords(&.{ own_bin, "secret", "add", "anthropic", "--stdin", "--home", "/data/harness" }, st.argv);
    try t.expect(!r.c.holdsKey());
    const c5 = try r.ev(.{ .stored = .{ .gen = st.gen, .ok = true } });
    try t.expectEqual(@as(?bool, false), markOf(c5));
    const run = runOfFx(c5).?;
    try t.expectEqual(Command.run, run.cmd);
    try t.expectEqualStrings(own_bin, run.binary);
    try t.expectEqual(Screen.connecting, shown(c5).?);
    try t.expect(r.c.form == null);
    // harness hasn't written desk.json yet: still connecting, not "isn't running"
    r.wait(1000);
    const g = try Rig.checkGen(try r.ev(.tick));
    try t.expect(shown(try r.ev(.{ .checked = .{ .gen = g, .result = .no_desk } })) == null);
    r.wait(1000);
    const g2 = try Rig.checkGen(try r.ev(.tick));
    try t.expect(shown(try r.ev(.{ .checked = .{ .gen = g2, .result = .{ .dead = d1 } } })) == null);
    r.wait(1000);
    const g3 = try Rig.checkGen(try r.ev(.tick));
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .checked = .{ .gen = g3, .result = .{ .alive = d1 } } }), .enter));
}

/// Continue on the form, the key given: the first step's effect.
fn continueWithKey(r: *Rig, form: setup.Form) !@FieldType(Effect, "step") {
    _ = askOf(try builtin(r, .{ .setup = form })).?;
    return stepOf(try r.ev(.{ .key = .given })).?;
}

test "a_failing_step_shows_its_line_and_keeps_the_form" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toForm(&r);
    const typed: setup.Form = .{ .provider = .other, .model = "llama3.1:8b", .url = "http://127.0.0.1:11434/v1", .api = .openai };
    const s1 = try continueWithKey(&r, typed);
    const s2 = stepOf(try r.ev(.{ .stepped = .{ .gen = s1.gen, .ok = true } })).?;
    const line = "Not changed: config.ini line 12: a [provider NAME] section takes api = anthropic, openai or gemini";
    const fx = try r.ev(.{ .stepped = .{ .gen = s2.gen, .ok = false, .text = line } });
    const v = viewOf(fx).?;
    try t.expectEqualStrings(line, noteOf(fx).?);
    try t.expect(!v.busy);
    try t.expectEqual(setup.Provider.other, v.form.provider);
    try t.expectEqualStrings("llama3.1:8b", v.form.model);
    try t.expectEqualStrings("http://127.0.0.1:11434/v1", v.form.url);
    try t.expect(askOf(fx) == null and stepOf(fx) == null and storeOf(fx) == null);
    // the key typed is let go: Continue asks for it again
    try t.expect(!r.c.holdsKey());
    // a stale answer changes nothing
    try t.expectEqual(@as(usize, 0), (try r.ev(.{ .stepped = .{ .gen = s2.gen, .ok = true } })).len);
}

test "continue_again_after_a_failure_skips_init_and_keeps_the_form" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toForm(&r);
    const s1 = try continueWithKey(&r, anthropic_form);
    const s2 = stepOf(try r.ev(.{ .stepped = .{ .gen = s1.gen, .ok = true } })).?;
    _ = try r.ev(.{ .stepped = .{ .gen = s2.gen, .ok = false, .text = "can't read config.ini" } });
    // init ran: the folder has config.ini now, and init isn't run on it again
    const again = try continueWithKey(&r, anthropic_form);
    try t.expectEqualStrings("config", again.argv[1]);
    // a failed init is run again
    var r2: Rig = .initOwn(own_bin);
    defer r2.deinit();
    _ = try toForm(&r2);
    const first_init = try continueWithKey(&r2, anthropic_form);
    _ = try r2.ev(.{ .stepped = .{ .gen = first_init.gen, .ok = false, .text = "can't create /data/harness: AccessDenied" } });
    _ = askOf(try builtin(&r2, .{ .setup = anthropic_form })).?;
    // pressed again while the key is asked for: nothing more starts
    try t.expectEqual(@as(usize, 0), (try builtin(&r2, .{ .setup = anthropic_form })).len);
    const second_init = stepOf(try r2.ev(.{ .key = .given })).?;
    try t.expectEqualStrings("init", second_init.argv[1]);
    _ = try r2.ev(.{ .stepped = .{ .gen = second_init.gen, .ok = false, .text = "can't create /data/harness: AccessDenied" } });
    // the form's own problems are said before anything runs
    const empty = try builtin(&r2, .{ .setup = .{ .provider = .opencode, .model = " " } });
    try t.expect(stepOf(empty) == null and askOf(empty) == null);
    try t.expectEqualStrings("Model is empty.", noteOf(empty).?);
}

test "a_cancelled_key_changes_nothing_and_continue_asks_again" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toForm(&r);
    _ = askOf(try builtin(&r, .{ .setup = anthropic_form })).?;
    const cancelled = try r.ev(.{ .key = .cancelled });
    try t.expect(stepOf(cancelled) == null and storeOf(cancelled) == null);
    try t.expectEqualStrings("Cancelled. Nothing was changed.", noteOf(cancelled).?);
    try t.expect(!viewOf(cancelled).?.busy);
    _ = askOf(try builtin(&r, .{ .setup = anthropic_form })).?;
    const empty = try r.ev(.{ .key = .empty });
    try t.expect(stepOf(empty) == null);
    try t.expectEqualStrings("No key was typed. Nothing was changed.", noteOf(empty).?);
    // harness refusing the key: its own line
    const s1 = try continueWithKey(&r, anthropic_form);
    const s2 = stepOf(try r.ev(.{ .stepped = .{ .gen = s1.gen, .ok = true } })).?;
    const st = storeOf(try r.ev(.{ .stepped = .{ .gen = s2.gen, .ok = true } })).?;
    const refused = try r.ev(.{ .stored = .{ .gen = st.gen, .ok = false, .text = "values shorter than 8 characters can't be masked reliably; nothing stored" } });
    try t.expectEqualStrings("values shorter than 8 characters can't be masked reliably; nothing stored", noteOf(refused).?);
    try t.expect(runOfFx(refused) == null);
    // the setup isn't done: no mark taken off
    try t.expect(markOf(refused) == null);
    // a key answer nobody asked for is dropped
    try t.expectEqual(@as(usize, 0), (try r.ev(.{ .key = .given })).len);
    try t.expect(!r.c.holdsKey());
}

test "other_may_be_set_up_without_a_key" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toForm(&r);
    const local: setup.Form = .{ .provider = .other, .model = "llama3.1:8b", .url = "http://127.0.0.1:11434/v1" };
    _ = askOf(try builtin(&r, .{ .setup = local })).?;
    const s1 = stepOf(try r.ev(.{ .key = .empty })).?;
    try t.expectEqualStrings("init", s1.argv[1]);
    const s2 = stepOf(try r.ev(.{ .stepped = .{ .gen = s1.gen, .ok = true } })).?;
    var none = false;
    for (s2.argv, 0..) |w, i| if (std.mem.eql(u8, w, "provider other.auth") and std.mem.eql(u8, s2.argv[i + 1], "none")) {
        none = true;
    };
    try t.expect(none);
    const done = try r.ev(.{ .stepped = .{ .gen = s2.gen, .ok = true } });
    try t.expect(storeOf(done) == null);
    try t.expectEqual(Command.run, runOfFx(done).?.cmd);
}

test "checks_while_the_form_is_open_leave_it" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toForm(&r);
    const s1 = try continueWithKey(&r, anthropic_form);
    _ = try r.ev(.{ .stepped = .{ .gen = s1.gen, .ok = true } });
    for ([_]CheckResult{ .no_desk, .bad_desk, .{ .dead = d1 }, .{ .alive = d1 }, .no_config }) |res| {
        r.wait(5000);
        const fx = try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(try r.ev(.tick)), .result = res } });
        try t.expect(shown(fx) == null);
        try t.expectEqual(@as(usize, 0), count(fx, .enter));
    }
    try t.expect(r.c.form != null);
}

/// In, with the desk on d1, then "Provider and key…" read as `in_use`.
fn toChange(r: *Rig, in_use: setup.InUse) ![]const Effect {
    try r.getIn(d1, "c1");
    const m = try r.ev(.{ .menu = .provider });
    var rc: ?@FieldType(Effect, "read_config") = null;
    for (m) |f| if (f == .read_config) {
        rc = f.read_config;
    };
    try t.expectEqualStrings("/usr/local/bin/harness", rc.?.binary);
    return r.ev(.{ .read = .{ .gen = rc.?.gen, .ok = true, .in_use = in_use } });
}

test "provider_and_key_reads_the_values_in_use" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    try t.expect(menuOf(try r.ev(.start)) != null);
    r.c.state = .setup;
    try t.expect(!r.c.menu(r.now).provider);
    var r2: Rig = .initOwn(own_bin);
    defer r2.deinit();
    const fx = try toChange(&r2, .{ .provider = "openrouter", .model = "x/y" });
    const v = viewOf(fx).?;
    try t.expectEqual(pages.Mode.change, v.mode);
    try t.expectEqual(setup.Provider.openrouter, v.form.provider);
    try t.expectEqualStrings("x/y", v.form.model);
    try t.expect(!r2.c.menu(r2.now).provider);
    // [Cancel]: the desk again
    const back = try builtin(&r2, .{ .cancel = true });
    try t.expect(r2.c.form == null);
    const g = try Rig.checkGen(back);
    try t.expectEqual(@as(usize, 1), count(try r2.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }), .enter));
    // the values couldn't be read: said, and nothing opens
    const m = try r2.ev(.{ .menu = .provider });
    var gen: u32 = 0;
    for (m) |f| if (f == .read_config) {
        gen = f.read_config.gen;
    };
    const failed = try r2.ev(.{ .read = .{ .gen = gen, .ok = false, .text = "config.ini line 4: unknown key" } });
    try t.expectEqualStrings("config.ini line 4: unknown key", alertOf(failed).?.text);
    try t.expect(r2.c.form == null);
}

test "a_change_while_harness_runs_says_config_sets_line_and_enters_again" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toChange(&r, .{ .provider = "openai", .model = "gpt-5" });
    const s = stepOf(try builtin(&r, .{ .setup = .{ .provider = .openai, .model = "gpt-5-mini" } })).?;
    // config.ini is there: no init; the same provider: the helpers stay
    try expectWords(&.{ "/usr/local/bin/harness", "config", "set", "model.provider", "openai", "model.model", "gpt-5-mini", "--home", "/data/harness" }, s.argv);
    try t.expectEqualStrings("/opt/homebrew/bin:/usr/bin", s.path);
    const fx = try r.ev(.{ .stepped = .{ .gen = s.gen, .ok = true, .out = "harness is running: send /reload to use it." } });
    try t.expect(askOf(fx) == null);
    const al = alertOf(fx).?;
    try t.expectEqualStrings("Saved", al.title);
    try t.expectEqualStrings("harness is running: send /reload to use it.", al.text);
    try t.expect(runOfFx(fx) == null);
    try t.expect(r.c.form == null);
    const g = try Rig.checkGen(fx);
    try t.expectEqual(@as(usize, 1), count(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }), .enter));
    // harness not running: it is started
    var r2: Rig = .initOwn(own_bin);
    defer r2.deinit();
    _ = try toChange(&r2, .{ .provider = "openai", .model = "gpt-5" });
    const s2 = stepOf(try builtin(&r2, .{ .setup = .{ .provider = .openai, .model = "gpt-5" } })).?;
    const started = try r2.ev(.{ .stepped = .{ .gen = s2.gen, .ok = true } });
    try t.expectEqual(Command.run, runOfFx(started).?.cmd);
}

test "the_key_is_asked_again_only_when_chosen_or_new" {
    const before: setup.InUse = .{ .provider = "openai", .model = "gpt-5" };
    for ([_]struct { setup.Form, bool }{
        .{ .{ .provider = .openai, .model = "gpt-5" }, false },
        .{ .{ .provider = .openai, .model = "gpt-5", .replace = true }, true },
        .{ .{ .provider = .anthropic, .model = "claude-opus-4-8" }, true },
    }) |case| {
        var r: Rig = .initOwn(own_bin);
        defer r.deinit();
        _ = try toChange(&r, before);
        const c1 = try builtin(&r, .{ .setup = case[0] });
        try t.expectEqual(case[1], askOf(c1) != null);
        const s = if (case[1]) stepOf(try r.ev(.{ .key = .given })).? else stepOf(c1).?;
        try t.expectEqualStrings("config", s.argv[1]);
        const fx = try r.ev(.{ .stepped = .{ .gen = s.gen, .ok = true, .out = "harness is running: send /reload to use it." } });
        if (case[1]) {
            const st = storeOf(fx).?;
            try t.expectEqualStrings(if (case[0].provider == .anthropic) "anthropic" else "openai", st.argv[3]);
            const done = try r.ev(.{ .stored = .{ .gen = st.gen, .ok = true } });
            try t.expectEqualStrings("harness is running: send /reload to use it.", alertOf(done).?.text);
            // "Provider and key…" never marks the folder unfinished
            try t.expect(markOf(done) == null);
        } else try t.expect(storeOf(fx) == null and alertOf(fx) != null);
    }
}

test "cancelling_the_key_of_a_new_provider_leaves_config_ini_alone" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    _ = try toChange(&r, .{ .provider = "openai", .model = "gpt-5" });
    _ = askOf(try builtin(&r, .{ .setup = .{ .provider = .anthropic, .model = "claude-opus-4-8" } })).?;
    const fx = try r.ev(.{ .key = .cancelled });
    try t.expect(stepOf(fx) == null and storeOf(fx) == null);
    try t.expectEqualStrings("Cancelled. Nothing was changed.", noteOf(fx).?);
    // and [Cancel] goes back with nothing run
    const back = try builtin(&r, .{ .cancel = true });
    try t.expect(stepOf(back) == null);
    try t.expect(r.c.form == null);
}

test "a_late_read_doesnt_replace_an_open_form" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    try r.getIn(d1, "c1");
    var rc: u32 = 0;
    for (try r.ev(.{ .menu = .provider })) |f| if (f == .read_config) {
        rc = f.read_config.gen;
    };
    // config.ini went meanwhile: the first setup's form
    for (0..2) |_| {
        r.wait(5000);
        _ = try r.ev(.{ .checked = .{ .gen = try Rig.checkGen(try r.ev(.tick)), .result = .no_config } });
    }
    try t.expectEqual(pages.Mode.first, r.c.form.?.mode);
    try t.expectEqual(@as(usize, 0), (try r.ev(.{ .read = .{ .gen = rc, .ok = true, .in_use = .{ .provider = "openai" } } })).len);
    try t.expectEqual(pages.Mode.first, r.c.form.?.mode);
    // and "Provider and key…" can be asked again later
    try t.expect(r.c.reading == null);
}

test "an_early_exit_names_the_command_to_run" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    _ = try r.ev(.{ .checked = .{ .gen = g, .result = .no_desk } });
    _ = try r.ev(.{ .menu = .start });
    r.wait(1000);
    const al = alertOf(try r.ev(.{ .exited = .{ .code = 1 } })).?;
    try t.expectEqualStrings("It exited right after starting, with code 1. To see why, run in Terminal: \"" ++ own_bin ++ "\" run --home \"/data/harness\"", al.text);
    // no harness at all: said, with nothing to run in Terminal
    var r2: Rig = .init();
    defer r2.deinit();
    const g2 = try Rig.checkGen(try r2.ev(.start));
    _ = try r2.ev(.{ .checked = .{ .gen = g2, .result = .{ .dead = nobin } } });
    try t.expectEqualStrings("There's no harness beside the app, and state/desk.json doesn't name one.", alertOf(try r2.ev(.{ .menu = .start })).?.text);
}

test "the_own_copy_runs_when_desk_json_names_none" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    const g = try Rig.checkGen(try r.ev(.start));
    // set up, never run: "isn't running", and Start runs the app's own copy
    const fx = try r.ev(.{ .checked = .{ .gen = g, .result = .no_desk } });
    try t.expectEqual(Screen.down, shown(fx).?);
    try t.expect(menuOf(fx).?.start);
    const run = runOfFx(try r.ev(.{ .menu = .start })).?;
    try t.expectEqualStrings(own_bin, run.binary);
    try t.expectEqualStrings("", run.path);
    // desk.json naming a binary: that one
    var r2: Rig = .initOwn(own_bin);
    defer r2.deinit();
    const g2 = try Rig.checkGen(try r2.ev(.start));
    _ = try r2.ev(.{ .checked = .{ .gen = g2, .result = .{ .dead = d1 } } });
    try t.expectEqualStrings("/usr/local/bin/harness", runOfFx(try r2.ev(.{ .menu = .start })).?.binary);
    // naming none: the own copy again
    var r3: Rig = .initOwn(own_bin);
    defer r3.deinit();
    const g3 = try Rig.checkGen(try r3.ev(.start));
    _ = try r3.ev(.{ .checked = .{ .gen = g3, .result = .{ .dead = nobin } } });
    try t.expectEqualStrings(own_bin, runOfFx(try r3.ev(.{ .menu = .start })).?.binary);
    // none beside the app either: Continue says so
    var r4: Rig = .init();
    defer r4.deinit();
    _ = try toForm(&r4);
    const none = try builtin(&r4, .{ .setup = anthropic_form });
    try t.expect(stepOf(none) == null);
    try t.expectEqualStrings("There's no harness beside the app, and state/desk.json names none.", noteOf(none).?);
}

test "reload_a_crash_or_a_late_code_keep_the_form" {
    var r: Rig = .initOwn(own_bin);
    defer r.deinit();
    // "Provider and key…" opened while an entry was on its way
    try r.getIn(d1, "c1");
    const g = try Rig.checkGen(try r.ev(.{ .message = .{ .msg = .{ .reenter = true }, .source = .desk } }));
    const e = try Rig.enterGen(try r.ev(.{ .checked = .{ .gen = g, .result = .{ .alive = d1 } } }));
    var rc: u32 = 0;
    for (try r.ev(.{ .menu = .provider })) |f| if (f == .read_config) {
        rc = f.read_config.gen;
    };
    _ = try r.ev(.{ .read = .{ .gen = rc, .ok = true, .in_use = .{ .provider = "openai", .model = "gpt-5" } } });
    const typed: setup.Form = .{ .provider = .opencode, .model = "" };
    _ = try builtin(&r, .{ .setup = typed });
    try t.expect(loaded(try r.ev(.{ .entered = .{ .gen = e, .code = "late" } })) == null);
    for ([_]Event{ .{ .menu = .reload }, .crashed }) |ev| {
        const fx = try r.ev(ev);
        try t.expectEqual(@as(usize, 0), count(fx, .reload) + count(fx, .load) + count(fx, .check));
        try t.expectEqual(setup.Provider.opencode, viewOf(fx).?.form.provider);
    }
}
