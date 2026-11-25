//! harness-desk: the controller on the main thread, the blocking work
//! (checks, entries, commands) on threads of its own, and the window
//! through the system's layer (src/mac/desk.m on macOS).
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const args_mod = @import("args.zig");
const home_mod = @import("home.zig");
const deskjson = @import("deskjson.zig");
const entry = @import("entry.zig");
const alive = @import("alive.zig");
const policy = @import("policy.zig");
const bridge = @import("bridge.zig");
const commands = @import("commands.zig");
const pages = @import("pages.zig");
const controller = @import("controller.zig");
const testhooks = @import("testhooks.zig");
const setup = @import("setup.zig");

const Controller = controller.Controller;
const Event = controller.Event;
const Effect = controller.Effect;

const hooks_on = build_options.test_hooks;

/// Longest wait for harness to answer `/alive`, and for its code.
const alive_timeout_ms = 3000;
const code_timeout_ms = 30_000;
const code_poll_ms = 100;

const sys = struct {
    extern fn hdesk_run(user_agent: [*:0]const u8) c_int;
    extern fn hdesk_quit() void;
    extern fn hdesk_show_html(html: [*:0]const u8) void;
    extern fn hdesk_load(url: [*:0]const u8) void;
    extern fn hdesk_reload() void;
    extern fn hdesk_eval_js(js: [*:0]const u8) void;
    extern fn hdesk_badge(label: [*:0]const u8) void;
    extern fn hdesk_badge_label(buf: [*]u8, len: c_int) void;
    extern fn hdesk_attention() void;
    extern fn hdesk_open_external(url: [*:0]const u8) void;
    extern fn hdesk_menu_state(start: c_int, stop: c_int, autostart_enabled: c_int, autostart_on: c_int, provider: c_int) void;
    extern fn hdesk_ask_key(title: [*:0]const u8, note: [*:0]const u8) void;
    extern fn hdesk_test_key(action: c_int) c_int;
    extern fn hdesk_alert(title: [*:0]const u8, text: [*:0]const u8) void;
    extern fn hdesk_post_main(f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;
    extern fn hdesk_every(seconds: f64, f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;
    extern fn hdesk_window_frame(x: *f64, y: *f64, w: *f64, h: *f64) void;
    extern fn hdesk_set_window_frame(x: f64, y: f64, w: f64, h: f64) void;
    extern fn hdesk_screen_frame(x: *f64, y: *f64, w: *f64, h: *f64) void;
    extern fn hdesk_min_frame(w: *f64, h: *f64) void;
};

const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    home: []const u8,
    ctl: Controller,
    effects: std.ArrayList(Effect) = .empty,
    /// For one event and its effects; reset after.
    turn: std.heap.ArenaAllocator,
    dispatching: bool = false,
    last_state: ?controller.State = null,
    hooks: if (hooks_on) ?testhooks.Hooks else void = if (hooks_on) null else {},
    /// The key just typed in the secure field, until `store_key` takes it
    /// (or the turn ends without it): then zeroed and freed.
    pending_key: ?[]u8 = null,
};

var app: App = undefined;

fn log(comptime fmt: []const u8, a: anytype) void {
    if (hooks_on) if (app.hooks) |*h| h.log(fmt, a);
}

fn z(a: std.mem.Allocator, s: []const u8) [:0]const u8 {
    return a.dupeSentinel(u8, s, 0) catch "";
}

/// The harness the app carries, beside its own program; "" when it isn't
/// there.
fn ownHarness(io: Io, gpa: std.mem.Allocator) []const u8 {
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return "";
    const p = setup.beside(gpa, dir, @import("builtin").os.tag == .windows) catch return "";
    Io.Dir.cwd().access(io, p, .{}) catch return "";
    return p;
}

fn nowMs() i64 {
    return @intCast(@divFloor(Io.Clock.awake.now(app.io).nanoseconds, std.time.ns_per_ms));
}

pub fn main(init: std.process.Init) u8 {
    const gpa = std.heap.c_allocator;
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    const args = args_mod.parse(argv);
    const home = args.home orelse home_mod.default(gpa, init.environ_map) catch {
        std.debug.print("harness-desk: no data folder: set HOME, or pass --home DIR\n", .{});
        return 1;
    };
    app = .{
        .io = init.io,
        .gpa = gpa,
        .env = init.environ_map,
        .home = home,
        .ctl = .init(gpa, home, ownHarness(init.io, gpa)),
        .turn = .init(gpa),
    };
    if (hooks_on) if (args.test_dir) |dir| {
        app.hooks = testhooks.Hooks.open(init.io, gpa, dir) catch null;
    };
    return @intCast(sys.hdesk_run("harness-desk/" ++ build_options.version));
}

// ---- events in, effects out ----

fn dispatch(ev: Event) void {
    std.debug.assert(!app.dispatching);
    app.dispatching = true;
    defer {
        app.dispatching = false;
        _ = app.turn.reset(.retain_capacity);
    }
    const a = app.turn.allocator();
    app.effects.clearRetainingCapacity();
    app.ctl.handle(nowMs(), ev, &app.effects, a) catch |e| {
        log("error {t}", .{e});
        return;
    };
    for (app.effects.items) |fx| perform(fx, a);
    // a key typed is held only while the steps it waits for run
    if (app.pending_key) |k| if (!app.ctl.holdsKey()) {
        dropKey(k);
        app.pending_key = null;
    };
    if (app.last_state != app.ctl.state) {
        app.last_state = app.ctl.state;
        log("state {t}", .{app.ctl.state});
    }
}

fn perform(fx: Effect, a: std.mem.Allocator) void {
    switch (fx) {
        .show => |s| {
            log("show {t}", .{s.screen});
            const html = pages.html(a, s.screen, s.note, app.home, s.view) catch return;
            sys.hdesk_show_html(z(a, html));
        },
        .load => |url| {
            log("load {s}", .{url});
            sys.hdesk_load(z(a, url));
        },
        .reload => {
            log("reload", .{});
            sys.hdesk_reload();
        },
        .check => |gen| startJob(CheckJob, .{ .gen = gen }),
        .enter => |gen| startJob(EnterJob, .{ .gen = gen }),
        .run => |r| startRun(r, a),
        .badge => |n| {
            var buf: [16]u8 = undefined;
            const label = if (n == 0) "" else std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";
            sys.hdesk_badge(z(a, label));
            if (hooks_on) {
                var back: [32]u8 = undefined;
                sys.hdesk_badge_label(&back, back.len);
                const shown = std.mem.sliceTo(&back, 0);
                log("badge {s}", .{if (shown.len == 0) "-" else shown});
            }
        },
        .attention => {
            log("attention", .{});
            sys.hdesk_attention();
        },
        .menu => |m| {
            log("menu start={d} stop={d} autostart={s} provider={d}", .{
                @intFromBool(m.start),                                                                       @intFromBool(m.stop),
                if (!m.autostart_enabled) "-" else if (m.autostart) |on| (if (on) "on" else "off") else "?", @intFromBool(m.provider),
            });
            sys.hdesk_menu_state(@intFromBool(m.start), @intFromBool(m.stop), @intFromBool(m.autostart_enabled), if (m.autostart) |on| @intFromBool(on) else -1, @intFromBool(m.provider));
        },
        .alert => |al| {
            log("alert {s} | {s}", .{ al.title, al.text });
            sys.hdesk_alert(z(a, al.title), z(a, al.text));
        },
        .step => |st| {
            log("step {s}", .{std.mem.join(a, " ", st.argv) catch ""});
            startStep(st.gen, st.argv, st.path, null);
        },
        .store_key => |st| {
            // the key itself is never logged: only the command it goes to
            log("store {s}", .{std.mem.join(a, " ", st.argv) catch ""});
            const key = app.pending_key orelse return;
            app.pending_key = null;
            startStep(st.gen, st.argv, st.path, key);
        },
        .read_config => |rc| {
            log("read config", .{});
            startRead(rc.gen, rc.binary, rc.home, rc.path);
        },
        .ask_key => |k| {
            log("ask key {s}", .{k.title});
            sys.hdesk_ask_key(z(a, k.title), z(a, k.note));
        },
        .mark => |on| {
            log("mark {s}", .{if (on) "on" else "off"});
            setMark(a, on);
        },
    }
}

/// `state/setup-unfinished`: the first setup ran harness init and isn't
/// done; while it is there the app shows "Set up" again.
const mark_file = "setup-unfinished";

fn setMark(a: std.mem.Allocator, on: bool) void {
    const p = std.fs.path.join(a, &.{ app.home, "state", mark_file }) catch return;
    if (on) {
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = p, .data = "harness-desk: the first setup isn't finished\n" }) catch |e| log("mark not written: {t}", .{e});
    } else Io.Dir.cwd().deleteFile(app.io, p) catch {};
}

/// Zeroes and frees the key, wherever it is held.
fn dropKey(key: []u8) void {
    std.crypto.secureZero(u8, key);
    app.gpa.free(key);
}

// ---- work off the main thread ----

/// A job runs `work` on a thread of its own, then `deliver` on the main
/// thread, which hands the controller its event and frees the job.
fn startJob(comptime J: type, init: J) void {
    const job = app.gpa.create(J) catch return;
    job.* = init;
    job.arena = .init(app.gpa);
    const th = std.Thread.spawn(.{}, J.work, .{job}) catch {
        J.work(job); // no thread: do it here, as a failure would
        return;
    };
    th.detach();
}

fn post(comptime J: type, job: *J) void {
    sys.hdesk_post_main(struct {
        fn f(p: ?*anyopaque) callconv(.c) void {
            const j: *J = @ptrCast(@alignCast(p.?));
            defer {
                j.arena.deinit();
                app.gpa.destroy(j);
            }
            j.deliver();
        }
    }.f, job);
}

const CheckJob = struct {
    gen: u32,
    arena: std.heap.ArenaAllocator = undefined,
    result: controller.CheckResult = .no_desk,

    fn work(j: *CheckJob) void {
        const a = j.arena.allocator();
        // never set up here: no config.ini
        const config = std.fs.path.join(a, &.{ app.home, "config.ini" }) catch "";
        const mark = std.fs.path.join(a, &.{ app.home, "state", mark_file }) catch "";
        const unfinished = if (Io.Dir.cwd().access(app.io, mark, .{})) |_| true else |_| false;
        if (unfinished) {
            j.result = .no_config;
        } else if (Io.Dir.cwd().access(app.io, config, .{})) |_| {
            j.result = if (deskjson.read(app.io, a, app.home)) |found| r: {
                var d = found orelse break :r .no_desk;
                // a harness that isn't there any more: the app's own runs instead
                if (d.binary.len > 0) Io.Dir.cwd().access(app.io, d.binary, .{}) catch {
                    d.binary = "";
                };
                break :r if (alive.check(d.port, alive_timeout_ms)) .{ .alive = d } else .{ .dead = d };
            } else |_| .bad_desk;
        } else |e| {
            j.result = if (e == error.FileNotFound) .no_config else .bad_desk;
        }
        post(CheckJob, j);
    }

    fn deliver(j: *CheckJob) void {
        dispatch(.{ .checked = .{ .gen = j.gen, .result = j.result } });
    }
};

const EnterJob = struct {
    gen: u32,
    arena: std.heap.ArenaAllocator = undefined,
    code: ?[]const u8 = null,

    fn work(j: *EnterJob) void {
        const a = j.arena.allocator();
        if (entry.request(app.io, app.home)) |_| {
            j.code = entry.wait(app.io, a, app.home, code_timeout_ms, code_poll_ms) catch null;
        } else |_| {}
        post(EnterJob, j);
    }

    fn deliver(j: *EnterJob) void {
        dispatch(.{ .entered = .{ .gen = j.gen, .code = j.code } });
    }
};

/// A command run to its end (stop, autostart), or `harness run` waited on
/// until it exits.
const RunJob = struct {
    cmd: commands.Command,
    arena: std.heap.ArenaAllocator = undefined,
    argv: []const []const u8 = &.{},
    env: ?std.process.Environ.Map = null,
    child: ?std.process.Child = null,
    ok: bool = false,
    text: []const u8 = "",
    autostart: ?bool = null,
    exit_code: ?u8 = null,

    fn work(j: *RunJob) void {
        const a = j.arena.allocator();
        const env: ?*const std.process.Environ.Map = if (j.env) |*e| e else null;
        if (j.child) |*child| {
            // `harness run`, started on the main thread: reap it
            const term = child.wait(app.io) catch {
                j.exit_code = 0;
                return post(RunJob, j);
            };
            j.exit_code = switch (term) {
                .exited => |c| c,
                else => 1,
            };
            return post(RunJob, j);
        }
        if (commands.runWait(app.io, a, j.argv, env)) |r| {
            j.ok = r.ok;
            j.text = r.why(a) catch "";
            if (j.cmd == .autostart_query and r.ok) j.autostart = commands.parseAutostart(r.out);
        } else |e| {
            j.text = std.fmt.allocPrint(a, "{s} couldn't be run ({t}).", .{ j.argv[0], e }) catch "";
        }
        post(RunJob, j);
    }

    fn deliver(j: *RunJob) void {
        if (j.exit_code) |c| {
            log("exit {d} run", .{c});
            dispatch(.{ .exited = .{ .code = c } });
        } else {
            log("ran {t} ok={d} {s}", .{ j.cmd, @intFromBool(j.ok), j.text });
            dispatch(.{ .ran = .{ .cmd = j.cmd, .ok = j.ok, .text = j.text, .autostart = j.autostart } });
        }
    }
};

/// A setup step run to its end (`init`, `config set`), or with `key` on its
/// input (`secret add NAME --stdin`): the key is zeroed and freed as soon
/// as the command has ended.
const StepJob = struct {
    gen: u32,
    arena: std.heap.ArenaAllocator = undefined,
    argv: []const []const u8 = &.{},
    env: ?std.process.Environ.Map = null,
    key: ?[]u8 = null,
    ok: bool = false,
    text: []const u8 = "",
    out: []const u8 = "",

    fn work(j: *StepJob) void {
        const a = j.arena.allocator();
        const env: ?*const std.process.Environ.Map = if (j.env) |*e| e else null;
        const result = if (j.key) |k| commands.runWithStdin(app.io, a, j.argv, env, k) else commands.runWait(app.io, a, j.argv, env);
        if (j.key) |k| {
            dropKey(k);
            j.key = null;
        }
        if (result) |r| {
            j.ok = r.ok;
            j.text = if (r.ok) "" else r.why(a) catch "";
            j.out = r.out;
        } else |e| {
            j.text = commands.notRun(a, j.argv[0], e) catch "";
        }
        post(StepJob, j);
    }

    fn deliver(j: *StepJob) void {
        log("stepped ok={d} {s}", .{ @intFromBool(j.ok), j.text });
        if (j.argv.len > 2 and std.mem.eql(u8, j.argv[1], "secret")) {
            dispatch(.{ .stored = .{ .gen = j.gen, .ok = j.ok, .text = j.text } });
        } else dispatch(.{ .stepped = .{ .gen = j.gen, .ok = j.ok, .text = j.text, .out = j.out } });
    }
};

fn startStep(gen: u32, argv: []const []const u8, path: []const u8, key: ?[]u8) void {
    const job = app.gpa.create(StepJob) catch {
        if (key) |k| dropKey(k);
        return;
    };
    job.* = .{ .gen = gen, .arena = .init(app.gpa), .key = key };
    const a = job.arena.allocator();
    var copy: std.ArrayList([]const u8) = .empty;
    for (argv) |w| copy.append(a, a.dupe(u8, w) catch "") catch {};
    job.argv = copy.items;
    if (path.len > 0) job.env = commands.withPath(a, app.env, path) catch null;
    const th = std.Thread.spawn(.{}, StepJob.work, .{job}) catch {
        StepJob.work(job);
        return;
    };
    th.detach();
}

/// "Provider and key…": `harness config get` for `model.provider`, then for
/// the settings that go with it (setup.readKeys).
const ReadJob = struct {
    gen: u32,
    arena: std.heap.ArenaAllocator = undefined,
    binary: []const u8 = "",
    home: []const u8 = "",
    env: ?std.process.Environ.Map = null,
    ok: bool = false,
    text: []const u8 = "",
    in_use: setup.InUse = .{},

    fn get(j: *ReadJob, key: []const u8) ![]const u8 {
        const a = j.arena.allocator();
        const env: ?*const std.process.Environ.Map = if (j.env) |*e| e else null;
        const argv = try setup.readArgv(a, j.binary, j.home, key);
        const r = commands.runWait(app.io, a, argv, env) catch |e| {
            j.text = try commands.notRun(a, j.binary, e);
            return error.Reported;
        };
        if (!r.ok) {
            j.text = try r.why(a);
            return error.Reported;
        }
        return std.mem.trim(u8, r.out, " \t\r\n");
    }

    fn work(j: *ReadJob) void {
        j.read() catch |e| {
            if (e != error.Reported) j.text = "The settings couldn't be read.";
            j.ok = false;
        };
        post(ReadJob, j);
    }

    fn read(j: *ReadJob) !void {
        const provider = try j.get("model.provider");
        var values: [7][]const u8 = undefined;
        for (try setup.readKeys(j.arena.allocator(), provider), 0..) |key, i| values[i] = try j.get(key);
        j.in_use = setup.inUse(provider, values);
        j.ok = true;
    }

    fn deliver(j: *ReadJob) void {
        log("read ok={d} {s}", .{ @intFromBool(j.ok), j.text });
        dispatch(.{ .read = .{ .gen = j.gen, .ok = j.ok, .text = j.text, .in_use = j.in_use } });
    }
};

fn startRead(gen: u32, binary: []const u8, home: []const u8, path: []const u8) void {
    const job = app.gpa.create(ReadJob) catch return;
    job.* = .{ .gen = gen, .arena = .init(app.gpa) };
    const a = job.arena.allocator();
    job.binary = a.dupe(u8, binary) catch "";
    job.home = a.dupe(u8, home) catch "";
    if (path.len > 0) job.env = commands.withPath(a, app.env, path) catch null;
    const th = std.Thread.spawn(.{}, ReadJob.work, .{job}) catch {
        ReadJob.work(job);
        return;
    };
    th.detach();
}

fn startRun(r: @FieldType(Effect, "run"), turn: std.mem.Allocator) void {
    const job = app.gpa.create(RunJob) catch return;
    job.* = .{ .cmd = r.cmd, .arena = .init(app.gpa) };
    const a = job.arena.allocator();
    job.argv = commands.argv(a, r.cmd, r.binary, r.home) catch &.{};
    if (r.path.len > 0) job.env = commands.withPath(a, app.env, r.path) catch null;
    log("run {s}", .{std.mem.join(turn, " ", job.argv) catch ""});
    if (r.cmd == .run) {
        const env: ?*const std.process.Environ.Map = if (job.env) |*e| e else null;
        job.child = commands.spawnDetached(app.io, job.argv, env) catch |e| {
            job.text = std.fmt.allocPrint(a, "{s} couldn't be run ({t}).", .{ r.binary, e }) catch "";
            // said on the next turn, not inside this one
            post(RunJob, job);
            return;
        };
    }
    const th = std.Thread.spawn(.{}, RunJob.work, .{job}) catch {
        RunJob.work(job);
        return;
    };
    th.detach();
}

// ---- called by the system's layer, on the main thread ----

export fn hdesk_on_ready() void {
    log("ready", .{});
    logFrame();
    logScreen();
    dispatch(.start);
    sys.hdesk_every(1.0, onTick, null);
    if (hooks_on) if (app.hooks != null) sys.hdesk_every(0.1, onHooks, null);
}

fn onTick(_: ?*anyopaque) callconv(.c) void {
    dispatch(.tick);
}

export fn hdesk_on_message(json: [*:0]const u8, main_frame: c_int, proto: [*:0]const u8, host: [*:0]const u8, port: c_int) void {
    const text = std.mem.span(json);
    const src = bridge.source(main_frame != 0, std.mem.span(proto), std.mem.span(host), @intCast(@max(port, 0)), app.ctl.port(), app.ctl.showingBuiltin());
    log("message {t} {s}", .{ src, text });
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const msg = bridge.parse(arena.allocator(), text) orelse return;
    dispatch(.{ .message = .{ .msg = msg, .source = src } });
}

export fn hdesk_on_navigate(url_z: [*:0]const u8, frame: c_int) c_int {
    const url = std.mem.span(url_z);
    const f: policy.Frame = switch (frame) {
        0 => .main,
        1 => .sub,
        else => .new_window,
    };
    const d = policy.decide(url, app.ctl.port(), f);
    if (d != .allow) log("nav {t} {t} {s}", .{ d, f, url });
    if (d == .external) {
        if (hooks_on and app.hooks != null) log("external {s}", .{url}) else sys.hdesk_open_external(url_z);
    }
    return switch (d) {
        .allow => 0,
        .external => 1,
        .cancel => 2,
    };
}

export fn hdesk_on_response(url: [*:0]const u8, status: c_int, main_frame: c_int) void {
    if (main_frame == 0) return;
    log("response {d} {s}", .{ status, url });
    dispatch(.{ .loaded = .{ .status = @intCast(std.math.clamp(status, 0, 999)), .url = std.mem.span(url) } });
}

export fn hdesk_on_finish(url: [*:0]const u8) void {
    log("finish {s}", .{url});
}

export fn hdesk_on_failed(url: [*:0]const u8, code: c_int) void {
    log("failed {d} {s}", .{ code, url });
    dispatch(.failed);
}

export fn hdesk_on_media(proto: [*:0]const u8, host: [*:0]const u8, port: c_int, main_frame: c_int, kind: c_int) c_int {
    const k: policy.MediaKind = switch (kind) {
        0 => .mic,
        1 => .camera,
        else => .both,
    };
    const ok = policy.media(std.mem.span(proto), std.mem.span(host), @intCast(@max(port, 0)), app.ctl.port(), main_frame != 0, k);
    log("media {s} {t} {s}://{s}:{d}", .{ if (ok) "grant" else "deny", k, proto, host, port });
    return @intFromBool(ok);
}

/// The secure field's answer: `len` bytes typed (`len` < 0: cancelled).
/// They are copied here and the caller clears its own; this copy goes to
/// `harness secret add` and is zeroed after.
export fn hdesk_on_key(buf: ?[*]const u8, len: c_int) void {
    if (app.pending_key) |old| {
        dropKey(old);
        app.pending_key = null;
    }
    if (len < 0 or buf == null) {
        log("key cancelled", .{});
        return dispatch(.{ .key = .cancelled });
    }
    const typed = setup.trimKey(buf.?[0..@intCast(len)]);
    if (typed.len == 0) {
        log("key empty", .{});
        return dispatch(.{ .key = .empty });
    }
    const key = app.gpa.alloc(u8, typed.len) catch return dispatch(.{ .key = .cancelled });
    @memcpy(key, typed);
    app.pending_key = key;
    log("key given", .{});
    // held while the controller's steps wait for it (dispatch lets it go
    // otherwise), then handed to `harness secret add` with `store_key`
    dispatch(.{ .key = .given });
}

export fn hdesk_on_menu(item: c_int) void {
    const m: controller.MenuItem = switch (item) {
        0 => .start,
        1 => .stop,
        2 => .autostart,
        4 => .provider,
        else => .reload,
    };
    dispatch(.{ .menu = m });
}

export fn hdesk_on_crashed() void {
    log("crashed", .{});
    dispatch(.crashed);
}

// ---- test hooks ----

fn logFrame() void {
    if (!hooks_on) return;
    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    sys.hdesk_window_frame(&x, &y, &w, &h);
    log("frame {d} {d} {d} {d}", .{ x, y, w, h });
}

/// Where the window can go: the screen's visible frame, and the smallest
/// frame the window takes (so the smoke picks a frame that fits).
fn logScreen() void {
    if (!hooks_on) return;
    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    sys.hdesk_screen_frame(&x, &y, &w, &h);
    var mw: f64 = 0;
    var mh: f64 = 0;
    sys.hdesk_min_frame(&mw, &mh);
    log("screen {d} {d} {d} {d} min {d} {d}", .{ x, y, w, h, mw, mh });
}

fn onHooks(_: ?*anyopaque) callconv(.c) void {
    if (!hooks_on) return;
    const h = &(app.hooks orelse return);
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cmds = h.take(a) catch return;
    for (cmds) |c| switch (c) {
        .js => |js| sys.hdesk_eval_js(z(a, js)),
        .menu => |m| dispatch(.{ .menu = m }),
        .frame => |f| {
            sys.hdesk_set_window_frame(f[0], f[1], f[2], f[3]);
            logFrame();
        },
        .log_frame => logFrame(),
        .key => |k| {
            const secure = sys.hdesk_test_key(if (k == .fill) 1 else 0);
            log("key-sheet {t} secure={d}", .{ k, secure });
        },
        .quit => sys.hdesk_quit(),
    };
}
