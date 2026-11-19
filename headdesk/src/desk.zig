//! One desktop: a process that is the display server for its apps and
//! answers the commands of `headdesk` over a control socket.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const png = @import("png.zig");
const keymap = @import("keymap.zig");
const server = @import("server.zig");
const box = @import("box.zig");
const boxes = @import("boxes.zig");
const Recorder = @import("record.zig").Recorder;
const Server = server.Server;

/// Separates the fields of a command on the control socket.
pub const field_sep = '\x1f';
/// Stands for a line break inside a field.
pub const newline_mark = '\x1e';

pub const Options = struct {
    name: []const u8,
    dir: []const u8,
    width: i32 = 1280,
    height: i32 = 800,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    envp: [:null]const ?[*:0]const u8,
    /// Apps run in this box instead of on the system as it is.
    sandbox: ?box.Spec = null,
    box_name: []const u8 = "",
};

const App = struct {
    pid: sys.pid_t,
    name: []u8,
    exit: sys.Exit = .running,
};

const Wait = struct {
    start_ms: u64,
    idle_ms: u64,
    deadline_ms: u64,
    windows: u32,
};

const Conn = struct {
    fd: sys.fd_t,
    buf: std.ArrayList(u8) = .empty,
    wait: ?Wait = null,
    done: bool = false,
};

pub const Desk = struct {
    gpa: Allocator,
    opts: Options,
    srv: Server,
    wayland_fd: sys.fd_t,
    control_fd: sys.fd_t,
    conns: std.ArrayList(*Conn) = .empty,
    apps: std.ArrayList(App) = .empty,
    env: std.ArrayList(?[*:0]const u8) = .empty,
    log_fd: ?sys.fd_t = null,
    /// What apps get as XDG_RUNTIME_DIR: the Wayland socket and nothing else.
    rt_dir: []const u8 = "",
    /// Process 1 of the box, while there is one.
    box_init: ?sys.pid_t = null,
    rec: ?*Recorder = null,
    last_frame_ms: u64 = 0,
    quit: bool = false,

    pub fn init(gpa: Allocator, opts: Options) !Desk {
        var buf: [256]u8 = undefined;
        const rt_dir = try std.fmt.allocPrint(gpa, "{s}/rt", .{opts.dir});
        try sys.mkdir(try std.fmt.bufPrintSentinel(&buf, "{s}", .{rt_dir}, 0));
        const wayland = try sys.listenUnix(try std.fmt.bufPrint(&buf, "{s}/wayland-0", .{rt_dir}));
        errdefer sys.close(wayland);
        const control = try sys.listenUnix(try std.fmt.bufPrint(&buf, "{s}/control.sock", .{opts.dir}));
        errdefer sys.close(control);
        var d: Desk = .{
            .gpa = gpa,
            .opts = opts,
            .srv = try Server.init(gpa, opts.width, opts.height),
            .wayland_fd = wayland,
            .control_fd = control,
            .rt_dir = rt_dir,
        };
        if (d.opts.sandbox) |*spec| {
            spec.rt_dir = rt_dir;
            boxes.lock(spec.box_dir, spec.home);
        }
        const log_path = try std.fmt.bufPrintSentinel(&buf, "{s}/app.log", .{opts.dir}, 0);
        d.log_fd = sys.openAppend(log_path) catch null;
        try d.buildEnv();
        return d;
    }

    /// The environment apps get: the caller's, pointed at this desktop.
    fn buildEnv(d: *Desk) !void {
        // in a box the home is where the box shows it (root's, with --as-root)
        const home: []const u8 = if (d.opts.sandbox) |spec| spec.home else "";
        const all = [_][2][]const u8{
            .{ "XDG_RUNTIME_DIR", d.rt_dir },
            .{ "WAYLAND_DISPLAY", "wayland-0" },
            .{ "XDG_SESSION_TYPE", "wayland" },
            .{ "HOME", home },
        };
        const set = all[0..if (home.len > 0) all.len else all.len - 1];
        // only if the caller did not choose otherwise
        const defaults = [_][2][]const u8{
            .{ "GDK_BACKEND", "wayland" },
            .{ "QT_QPA_PLATFORM", "wayland" },
            .{ "MOZ_ENABLE_WAYLAND", "1" },
            .{ "NO_AT_BRIDGE", "1" },
        };
        const drop = [_][]const u8{ "DISPLAY", "WAYLAND_SOCKET" };
        var have_default: [defaults.len]bool = @splat(false);
        outer: for (d.opts.envp) |entry| {
            const e = std.mem.span(entry.?);
            const eq = std.mem.findScalar(u8, e, '=') orelse continue;
            const key = e[0..eq];
            for (set) |kv| {
                if (std.mem.eql(u8, key, kv[0])) continue :outer;
            }
            for (drop) |k| {
                if (std.mem.eql(u8, key, k)) continue :outer;
            }
            for (defaults, 0..) |kv, i| {
                if (std.mem.eql(u8, key, kv[0])) have_default[i] = true;
            }
            try d.env.append(d.gpa, entry);
        }
        for (set) |kv| try d.env.append(d.gpa, (try std.fmt.allocPrintSentinel(d.gpa, "{s}={s}", .{ kv[0], kv[1] }, 0)).ptr);
        for (defaults, 0..) |kv, i| {
            if (!have_default[i]) try d.env.append(d.gpa, (try std.fmt.allocPrintSentinel(d.gpa, "{s}={s}", .{ kv[0], kv[1] }, 0)).ptr);
        }
        try d.env.append(d.gpa, null);
    }

    /// Starts a program on this desktop.
    pub fn spawn(d: *Desk, argv: []const []const u8, cwd: ?[]const u8) !sys.pid_t {
        var arena_state = std.heap.ArenaAllocator.init(d.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const args = try arena.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |a, i| args[i] = (try arena.dupeSentinel(u8, a, 0)).ptr;
        args[argv.len] = null;
        const dir: ?[*:0]const u8 = if (cwd) |c| (try arena.dupeSentinel(u8, c, 0)).ptr else null;
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(d.env.items.ptr);
        const pid = if (d.opts.sandbox != null) try d.spawnBoxed(@ptrCast(args.ptr), envp, dir) else try sys.spawn(@ptrCast(args.ptr), envp, dir, d.log_fd, null);
        try d.apps.append(d.gpa, .{ .pid = pid, .name = try d.gpa.dupe(u8, argv[0]) });
        d.srv.note("start {s} pid {d}{s}", .{ argv[0], pid, if (d.opts.sandbox != null) " in the box" else "" });
        return pid;
    }

    fn enterBox(ctx: *const anyopaque) void {
        box.enter(@ptrCast(@alignCast(ctx)));
    }

    fn joinBox(ctx: *const anyopaque) void {
        const pid: *const sys.pid_t = @ptrCast(@alignCast(ctx));
        box.join(pid.*);
    }

    /// The first program makes the box; later ones join it while it lives.
    fn spawnBoxed(d: *Desk, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8) !sys.pid_t {
        if (d.box_init) |init_pid| {
            if (sys.alive(init_pid)) return sys.spawn(argv, envp, cwd, d.log_fd, .{ .ctx = &init_pid, .run = joinBox });
            d.box_init = null;
        }
        const report = try sys.pipe();
        var spec = d.opts.sandbox.?;
        spec.report_fd = report[1];
        const pid = sys.spawn(argv, envp, cwd, d.log_fd, .{ .ctx = &spec, .run = enterBox }) catch |err| {
            sys.close(report[0]);
            sys.close(report[1]);
            return err;
        };
        sys.close(report[1]);
        defer sys.close(report[0]);
        // the box's first process says who it is, or the box failed
        var items = [_]sys.PollItem{sys.pollIn(report[0])};
        sys.poll(&items, 5000);
        var init_pid: sys.pid_t = 0;
        const n = sys.read(report[0], std.mem.asBytes(&init_pid)) catch 0;
        if (n == @sizeOf(sys.pid_t)) d.box_init = init_pid;
        return pid;
    }

    /// Runs until `kill`.
    pub fn run(d: *Desk) void {
        var items: std.ArrayList(sys.PollItem) = .empty;
        defer items.deinit(d.gpa);
        while (!d.quit) {
            items.clearRetainingCapacity();
            items.append(d.gpa, sys.pollIn(d.wayland_fd)) catch return;
            items.append(d.gpa, sys.pollIn(d.control_fd)) catch return;
            const n_clients = d.srv.clients.items.len;
            for (d.srv.clients.items) |c| items.append(d.gpa, sys.pollIn(c.fd)) catch return;
            const n_conns = d.conns.items.len;
            for (d.conns.items) |c| items.append(d.gpa, sys.pollIn(c.fd)) catch return;

            var busy = d.srv.framesWaiting() and !(d.srv.frozen and d.srv.step_budget == 0);
            for (d.conns.items) |c| {
                if (c.wait != null) busy = true;
            }
            // a picture is owed to the recording
            if (d.rec) |rec| {
                if (rec.last_changes != d.srv.changes) busy = true;
            }
            sys.poll(items.items, if (busy) 8 else 500);

            if (sys.readable(items.items[0])) {
                while (sys.accept(d.wayland_fd)) |fd| d.srv.addClient(fd) catch sys.close(fd);
            }
            if (sys.readable(items.items[1])) {
                while (sys.accept(d.control_fd)) |fd| {
                    const c = d.gpa.create(Conn) catch {
                        sys.close(fd);
                        continue;
                    };
                    c.* = .{ .fd = fd };
                    d.conns.append(d.gpa, c) catch {
                        sys.close(fd);
                        d.gpa.destroy(c);
                    };
                }
            }
            for (0..n_clients) |i| {
                if (sys.readable(items.items[2 + i])) d.srv.readClient(d.srv.clients.items[i]);
            }
            for (0..n_conns) |i| {
                if (sys.readable(items.items[2 + n_clients + i])) d.readConn(d.conns.items[i]);
            }

            const now = sys.nowMs();
            if (now - d.last_frame_ms >= 16) {
                if (d.srv.frameTick()) d.last_frame_ms = now;
            }
            d.srv.flush();
            if (d.rec) |rec| rec.tick(&d.srv);
            d.checkWaits();
            d.reapApps();

            var i: usize = 0;
            while (i < d.conns.items.len) {
                const c = d.conns.items[i];
                if (c.done) {
                    sys.close(c.fd);
                    c.buf.deinit(d.gpa);
                    d.gpa.destroy(c);
                    _ = d.conns.orderedRemove(i);
                } else i += 1;
            }
        }
        d.shutdown();
    }

    fn reapApps(d: *Desk) void {
        for (d.apps.items) |*a| {
            if (a.exit != .running) continue;
            a.exit = sys.reap(a.pid);
            switch (a.exit) {
                .running => {},
                .code => |c| d.srv.note("{s} (pid {d}) ended with exit code {d}", .{ a.name, a.pid, c }),
                .signal => |sig| d.srv.note("{s} (pid {d}) ended by signal {d}", .{ a.name, a.pid, sig }),
            }
        }
    }

    fn shutdown(d: *Desk) void {
        if (d.rec) |rec| {
            _ = rec.stop(&d.srv);
            d.rec = null;
        }
        for (d.apps.items) |a| {
            if (a.exit == .running) sys.killGroup(a.pid, .TERM);
        }
        var waited: u32 = 0;
        while (waited < 50) : (waited += 1) {
            var left = false;
            for (d.apps.items) |*a| {
                if (a.exit == .running) a.exit = sys.reap(a.pid);
                if (a.exit == .running) left = true;
            }
            if (!left) break;
            sys.sleepMs(10);
        }
        for (d.apps.items) |a| {
            if (a.exit == .running) sys.killGroup(a.pid, .KILL);
        }
        var buf: [256]u8 = undefined;
        if (d.opts.sandbox) |spec| boxes.unlock(spec.box_dir);
        for ([_][]const u8{ "rt/wayland-0", "control.sock" }) |f| {
            if (std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ d.opts.dir, f }, 0)) |p| sys.unlink(p) else |_| {}
        }
    }

    // -----------------------------------------------------------------
    // Commands

    fn readConn(d: *Desk, c: *Conn) void {
        if (c.wait != null) {
            // nothing more is expected; the caller went away
            var scratch: [64]u8 = undefined;
            const n = sys.read(c.fd, &scratch) catch 0;
            if (n == 0) c.done = true;
            return;
        }
        var chunk: [4096]u8 = undefined;
        const n = sys.read(c.fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => return,
            else => 0,
        };
        if (n == 0) {
            c.done = true;
            return;
        }
        c.buf.appendSlice(d.gpa, chunk[0..n]) catch {
            c.done = true;
            return;
        };
        const end = std.mem.findScalar(u8, c.buf.items, '\n') orelse return;
        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(d.gpa);
        const finished = d.command(c, c.buf.items[0..end], &reply) catch blk: {
            reply.clearRetainingCapacity();
            reply.appendSlice(d.gpa, "error out of memory\n") catch {};
            break :blk true;
        };
        if (finished) {
            sys.writeAll(c.fd, reply.items) catch {};
            c.done = true;
        }
    }

    fn checkWaits(d: *Desk) void {
        const now = sys.nowMs();
        for (d.conns.items) |c| {
            const w = c.wait orelse continue;
            var open: u32 = 0;
            for (d.srv.windows.items) |x| {
                if (x.mapped) open += 1;
            }
            const quiet_since = @max(d.srv.last_change_ms, w.start_ms);
            const settled = open >= w.windows and now - quiet_since >= w.idle_ms;
            if (!settled and now < w.deadline_ms) continue;
            var buf: [200]u8 = undefined;
            const r = d.srv.changed;
            const what = if (r.w > 0) std.fmt.bufPrint(buf[100..], "changed={d},{d},{d}x{d}", .{ r.x, r.y, r.w, r.h }) catch "" else "changed=none";
            const line = std.fmt.bufPrint(buf[0..100], "{s} after={d}ms windows={d} ", .{ if (settled) "ok settled" else "fail timeout", now - w.start_ms, open }) catch "";
            sys.writeAll(c.fd, line) catch {};
            sys.writeAll(c.fd, what) catch {};
            sys.writeAll(c.fd, "\n") catch {};
            if (settled) d.srv.clearChanged();
            c.wait = null;
            c.done = true;
        }
    }

    fn windowArg(d: *Desk, text: []const u8, reply: *std.ArrayList(u8)) !?*server.Xdg {
        const n = std.fmt.parseInt(u32, text, 10) catch {
            try reply.print(d.gpa, "error not a window number: {s}\n", .{text});
            return null;
        };
        const x = d.srv.window(n) orelse {
            try reply.print(d.gpa, "error no window {d}\n", .{n});
            return null;
        };
        return x;
    }

    /// Acts on one command line. Returns false when the answer comes later.
    fn command(d: *Desk, c: *Conn, line: []const u8, reply: *std.ArrayList(u8)) !bool {
        var fields: [64][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, field_sep);
        while (it.next()) |f| {
            if (count == fields.len) break;
            fields[count] = f;
            count += 1;
        }
        const cmd = fields[0];
        const args = fields[1..count];
        const s = &d.srv;

        // inputs go into the recording as they came, to be sent again
        const is_input = std.mem.eql(u8, cmd, "click") or std.mem.eql(u8, cmd, "move") or std.mem.eql(u8, cmd, "scroll") or std.mem.eql(u8, cmd, "key") or std.mem.eql(u8, cmd, "type");
        defer if (is_input) {
            if (d.rec) |rec| {
                if (std.mem.startsWith(u8, reply.items, "ok")) rec.input(line);
            }
        };

        if (std.mem.eql(u8, cmd, "record")) {
            // dir fps, or "stop"
            if (args.len >= 1 and std.mem.eql(u8, args[0], "stop")) {
                const rec = d.rec orelse return fail(d, reply, "nothing is being recorded");
                d.rec = null;
                const dir = try d.gpa.dupe(u8, rec.dir);
                defer d.gpa.free(dir);
                const totals = rec.stop(s);
                try reply.print(d.gpa, "ok stopped pictures={d} inputs={d} dir={s}\n", .{ totals.pictures, totals.inputs, dir });
                return true;
            }
            if (args.len < 1) return fail(d, reply, "record needs a directory");
            if (d.rec != null) return fail(d, reply, "a recording is already running; stop it first");
            const fps = if (args.len >= 2) (std.fmt.parseInt(u32, args[1], 10) catch 10) else 10;
            d.rec = Recorder.start(d.gpa, args[0], fps, s) catch return fail(d, reply, "can't write to that directory");
            try reply.print(d.gpa, "ok recording dir={s} fps={d}\n", .{ args[0], @max(1, @min(fps, 60)) });
        } else if (std.mem.eql(u8, cmd, "hash")) {
            const pixels = try s.render(d.gpa);
            defer d.gpa.free(pixels);
            try reply.print(d.gpa, "ok {x:0>16}\n", .{std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels))});
        } else if (std.mem.eql(u8, cmd, "ping")) {
            try reply.print(d.gpa, "ok {s} {d}x{d} pid={d}\n", .{ d.opts.name, s.width, s.height, sys.getpid() });
        } else if (std.mem.eql(u8, cmd, "windows")) {
            s.layout();
            try reply.appendSlice(d.gpa, "ok\n");
            for (s.windows.items) |x| {
                if (!x.mapped) continue;
                const r = s.windowRect(x);
                try reply.print(d.gpa, "window {d} {s} at={d},{d} size={d}x{d}", .{ x.win, @tagName(x.kind), r.x, r.y, r.w, r.h });
                if (x.parent) |p| try reply.print(d.gpa, " parent={d}", .{p.win});
                if (s.keyboard_focus == x.surface) try reply.appendSlice(d.gpa, " keyboard");
                if (x.app_id.len > 0) try reply.print(d.gpa, " app={s}", .{x.app_id});
                if (x.kind == .toplevel) try reply.print(d.gpa, " title=\"{s}\"", .{x.title});
                try reply.append(d.gpa, '\n');
            }
        } else if (std.mem.eql(u8, cmd, "shot")) {
            if (args.len < 1) return fail(d, reply, "shot needs a file");
            var buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&buf, "{s}", .{args[0]}, 0) catch return fail(d, reply, "the file name is too long");
            var w = s.width;
            var h = s.height;
            var pixels: []u32 = undefined;
            if (args.len >= 2) {
                const x = (try d.windowArg(args[1], reply)) orelse return true;
                const one = s.renderWindow(d.gpa, x) catch return fail(d, reply, "that window has nothing drawn");
                pixels = one.pixels;
                w = one.w;
                h = one.h;
            } else pixels = try s.render(d.gpa);
            defer d.gpa.free(pixels);
            const file = try png.encode(d.gpa, pixels, @intCast(w), @intCast(h));
            defer d.gpa.free(file);
            const fd = sys.create(path) catch return fail(d, reply, "can't write the file");
            defer sys.close(fd);
            sys.writeAll(fd, file) catch return fail(d, reply, "can't write the file");
            try reply.print(d.gpa, "ok shot file={s} size={d}x{d} bytes={d}\n", .{ args[0], w, h, file.len });
        } else if (std.mem.eql(u8, cmd, "move") or std.mem.eql(u8, cmd, "click")) {
            // x y [button count window]
            if (args.len < 2) return fail(d, reply, "needs X and Y");
            var x = std.fmt.parseFloat(f64, args[0]) catch return fail(d, reply, "X is not a number");
            var y = std.fmt.parseFloat(f64, args[1]) catch return fail(d, reply, "Y is not a number");
            if (args.len >= 5 and args[4].len > 0) {
                const win = (try d.windowArg(args[4], reply)) orelse return true;
                const r = s.windowRect(win);
                x += @floatFromInt(r.x);
                y += @floatFromInt(r.y);
            }
            if (x < 0 or y < 0 or x >= @as(f64, @floatFromInt(s.width)) or y >= @as(f64, @floatFromInt(s.height)))
                return fail(d, reply, "that point is off the desktop");
            s.pointerMove(x, y);
            if (std.mem.eql(u8, cmd, "click")) {
                const button = if (args.len >= 3 and args[2].len > 0) (std.meta.stringToEnum(Server.Button, args[2]) orelse return fail(d, reply, "the button is left, right or middle")) else Server.Button.left;
                const times = if (args.len >= 4 and args[3].len > 0) (std.fmt.parseInt(u32, args[3], 10) catch 1) else 1;
                for (0..@max(1, @min(times, 3))) |_| {
                    s.pointerButton(button, true);
                    s.pointerButton(button, false);
                }
            }
            if (s.pointer_focus) |f| {
                var root = f;
                while (root.parent) |p| root = p;
                try reply.print(d.gpa, "ok at={d},{d} window={d}\n", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), if (root.xdg) |xdg| xdg.win else 0 });
            } else try reply.print(d.gpa, "ok at={d},{d} window=none\n", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)) });
        } else if (std.mem.eql(u8, cmd, "scroll")) {
            if (args.len < 1) return fail(d, reply, "scroll needs a number of steps");
            const steps = std.fmt.parseInt(i32, args[0], 10) catch return fail(d, reply, "the steps are not a number");
            s.pointerScroll(steps);
            try reply.appendSlice(d.gpa, "ok\n");
        } else if (std.mem.eql(u8, cmd, "key")) {
            if (args.len < 1) return fail(d, reply, "key needs a key");
            for (args) |a| {
                if (keymap.parseCombo(a) == null) {
                    try reply.print(d.gpa, "error no such key: {s}\n", .{a});
                    return true;
                }
            }
            for (args) |a| {
                s.note("key {s}", .{a});
                if (!s.pressCombo(keymap.parseCombo(a).?)) return fail(d, reply, "no window has the keyboard");
            }
            try reply.appendSlice(d.gpa, "ok\n");
        } else if (std.mem.eql(u8, cmd, "type")) {
            if (args.len < 1) return fail(d, reply, "type needs text");
            if (s.keyboard_focus == null) return fail(d, reply, "no window has the keyboard");
            const text = try d.gpa.dupe(u8, args[0]);
            defer d.gpa.free(text);
            std.mem.replaceScalar(u8, text, newline_mark, '\n');
            s.note("type {d} characters", .{text.len});
            if (s.typeText(text)) |bad| {
                try reply.print(d.gpa, "error no key types the byte 0x{x:0>2}; only ASCII can be typed\n", .{bad});
                return true;
            }
            try reply.appendSlice(d.gpa, "ok\n");
        } else if (std.mem.eql(u8, cmd, "wait")) {
            // idle_ms timeout_ms windows
            const now = sys.nowMs();
            const idle = if (args.len >= 1) (std.fmt.parseInt(u64, args[0], 10) catch 300) else 300;
            const timeout = if (args.len >= 2) (std.fmt.parseInt(u64, args[1], 10) catch 10000) else 10000;
            const windows = if (args.len >= 3) (std.fmt.parseInt(u32, args[2], 10) catch 0) else 0;
            c.wait = .{ .start_ms = now, .idle_ms = idle, .deadline_ms = now + timeout, .windows = windows };
            return false;
        } else if (std.mem.eql(u8, cmd, "freeze")) {
            s.frozen = true;
            s.step_budget = 0;
            s.note("freeze", .{});
            try reply.appendSlice(d.gpa, "ok frozen\n");
        } else if (std.mem.eql(u8, cmd, "thaw")) {
            s.frozen = false;
            s.note("thaw", .{});
            try reply.appendSlice(d.gpa, "ok running\n");
        } else if (std.mem.eql(u8, cmd, "step")) {
            if (!s.frozen) return fail(d, reply, "step needs a frozen desktop: run freeze first");
            const n = if (args.len >= 1) (std.fmt.parseInt(u32, args[0], 10) catch 1) else 1;
            s.step_budget += @max(1, n);
            try reply.print(d.gpa, "ok {d} waiting={s}\n", .{ @max(1, n), if (s.framesWaiting()) "yes" else "no" });
        } else if (std.mem.eql(u8, cmd, "log")) {
            const since = if (args.len >= 1) (std.fmt.parseInt(u64, args[0], 10) catch 0) else 0;
            try reply.appendSlice(d.gpa, "ok\n");
            for (s.log.items, 0..) |l, i| {
                if (s.log_base + i + 1 > since) {
                    try reply.appendSlice(d.gpa, l);
                    try reply.append(d.gpa, '\n');
                }
            }
        } else if (std.mem.eql(u8, cmd, "close") or std.mem.eql(u8, cmd, "focus")) {
            if (args.len < 1) return fail(d, reply, "needs a window number");
            const x = (try d.windowArg(args[0], reply)) orelse return true;
            if (std.mem.eql(u8, cmd, "close")) s.askClose(x) else s.raise(x);
            try reply.appendSlice(d.gpa, "ok\n");
        } else if (std.mem.eql(u8, cmd, "status")) {
            var open: u32 = 0;
            for (s.windows.items) |x| {
                if (x.mapped) open += 1;
            }
            try reply.print(d.gpa, "ok {s} size={d}x{d} windows={d} clients={d} {s} draws={d}\n", .{ d.opts.name, s.width, s.height, open, s.clients.items.len, if (s.frozen) "frozen" else "running", s.changes });
            for (d.apps.items) |a| {
                switch (a.exit) {
                    .running => try reply.print(d.gpa, "app pid={d} running {s}\n", .{ a.pid, a.name }),
                    .code => |code| try reply.print(d.gpa, "app pid={d} exited={d} {s}\n", .{ a.pid, code, a.name }),
                    .signal => |sig| try reply.print(d.gpa, "app pid={d} signal={d} {s}\n", .{ a.pid, sig, a.name }),
                }
            }
            if (d.opts.sandbox) |spec| try reply.print(d.gpa, "sandbox box={s} network={s} user={s} shared={d}\n", .{ d.opts.box_name, if (spec.network) "yes" else "no", if (spec.as_root) "root" else "same", spec.shares.len });
            for (s.unknown.items) |u| try reply.print(d.gpa, "unknown {s}\n", .{u});
        } else if (std.mem.eql(u8, cmd, "exec")) {
            if (args.len < 1) return fail(d, reply, "exec needs a program");
            const pid = d.spawn(args, null) catch return fail(d, reply, "can't start the program");
            try reply.print(d.gpa, "ok pid={d}\n", .{pid});
        } else if (std.mem.eql(u8, cmd, "kill")) {
            d.quit = true;
            try reply.appendSlice(d.gpa, "ok\n");
        } else {
            try reply.print(d.gpa, "error unknown command: {s}\n", .{cmd});
        }
        return true;
    }

    fn fail(d: *Desk, reply: *std.ArrayList(u8), text: []const u8) !bool {
        try reply.print(d.gpa, "error {s}\n", .{text});
        return true;
    }
};
