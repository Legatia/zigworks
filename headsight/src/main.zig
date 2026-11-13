const std = @import("std");
const build_options = @import("build_options");
const args = @import("args.zig");
const frame = @import("frame.zig");
const diff = @import("diff.zig");
const boxes = @import("boxes.zig");
const watch = @import("watch.zig");
const store = @import("store.zig");
const output = @import("output.zig");
const platform = @import("platform.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;
const Writer = std.Io.Writer;

const usage_text =
    \\usage: headsight <command> [options]
    \\
    \\  snap     save a crop of the screen, a window or the camera
    \\  wait     wait until a region changes, goes still, or shows some text
    \\  diff     what changed since a reference made with 'snap --name'
    \\  drop     delete a reference
    \\  text     read the text in a region
    \\  windows  list windows that can be watched
    \\  help [command], version
    \\
    \\Sources: the main display (default), --window TEXT, --source camera, --camera NAME.
    \\Coordinates are pixels of the source, origin top left: --region X,Y,W,H.
    \\Crops are PNG files under $TMPDIR/headsight; open them with your image tool.
    \\Exit codes: 0 ok, 1 timeout, 2 usage error, 3 permission missing, 4 capture failed.
    \\
    \\Run 'headsight help <command>' for its options.
    \\
;

const Help = struct { []const u8, []const u8 };
const command_help = [_]Help{
    .{ "snap",
    \\usage: headsight snap [source] [--region X,Y,W,H] [--name NAME] [--json]
    \\
    \\Saves a crop of the region (or of the whole source, downscaled so the long
    \\side is at most 1024 px) and prints its path, the source size and the
    \\pixel scale. With --name, also keeps the region at full resolution as a
    \\reference for 'wait --since' and 'diff --since' (one hour, or until
    \\'headsight drop NAME'). The reference is never shown, only compared.
    \\
    \\source: --window TEXT (frontmost window whose app or title contains TEXT)
    \\        --source screen|camera   --camera NAME
    \\With --window, 'wait' and 'diff' leave out the title bar (top 28 points): it
    \\changes with focus and shows macOS's recording indicator.
    \\
    \\example: headsight snap --window Safari --name before
    \\
    },
    .{ "wait",
    \\usage: headsight wait (--change | --still[=MS] | --text TEXT) [source]
    \\                      [--region X,Y,W,H] [--ignore X,Y,W,H]... [--since NAME]
    \\                      [--timeout S] [--fps N] [--json]
    \\
    \\Blocks until the region changes, stays unchanged for MS milliseconds
    \\(default 800), or shows TEXT (case-insensitive; text already there counts).
    \\Prints one line with a crop of what changed, the settled region, or the
    \\line of text. Nothing is sent anywhere while it waits.
    \\
    \\  --since NAME   compare with a reference from 'snap --name NAME', so a
    \\                 change made before this call is reported at once
    \\  --ignore R     leave out an area, e.g. a clock (repeatable)
    \\  --timeout S    give up after S seconds (default 120); exit code 1
    \\  --fps N        screen frames per second (default 30)
    \\
    \\examples: headsight wait --text "Export done" --window Preview --timeout 300
    \\          headsight wait --still --window Safari
    \\          headsight wait --change --region 0,0,800,200 --source camera
    \\
    },
    .{ "diff",
    \\usage: headsight diff --since NAME [--json]
    \\
    \\Captures the reference's source and region again and prints every changed
    \\area as a box with a crop of each (up to 8). Exit 0 with or without changes.
    \\
    \\typical use: headsight snap --window Safari --name before
    \\             (make the change)
    \\             headsight wait --still --window Safari
    \\             headsight diff --since before
    \\
    },
    .{ "drop",
    \\usage: headsight drop NAME
    \\
    \\Deletes the reference NAME. References also expire after one hour.
    \\
    },
    .{ "text",
    \\usage: headsight text [source] [--region X,Y,W,H] [--accurate] [--json]
    \\
    \\Reads the text in the region on this Mac (Apple's text recognition) and
    \\prints each line with its box. --accurate is slower and better on small
    \\or unusual text.
    \\
    \\example: headsight text --window Preview --region 0,0,1200,300
    \\
    },
    .{ "windows",
    \\usage: headsight windows [--json]
    \\
    \\Lists on-screen windows, front to back, with their size and position in
    \\pixels. Use part of the app name or title with --window.
    \\
    },
};

const Exit = enum(u8) { ok = 0, timeout = 1, usage = 2, permission = 3, failed = 4 };

pub fn main() u8 {
    const alloc = std.heap.c_allocator;
    var out_buf: [8192]u8 = undefined;
    var err_buf: [2048]u8 = undefined;
    var out_w = std.fs.File.stdout().writerStreaming(&out_buf);
    var err_w = std.fs.File.stderr().writerStreaming(&err_buf);
    const out = &out_w.interface;
    const err = &err_w.interface;
    defer {
        out.flush() catch {};
        err.flush() catch {};
    }
    const argv = std.process.argsAlloc(alloc) catch return @intFromEnum(Exit.failed);
    defer std.process.argsFree(alloc, argv);

    var diag = args.Diag{};
    var req = args.parse(alloc, argv[1..], &diag) catch {
        err.print("headsight: {s}\n", .{diag.msg()}) catch {};
        return @intFromEnum(Exit.usage);
    };
    defer req.deinit(alloc);

    var app = App{ .alloc = alloc, .req = req, .out = .{ .w = out, .json = req.json }, .err = err };
    const code = app.run() catch |e| blk: {
        err.print("headsight: {s}\n", .{@errorName(e)}) catch {};
        break :blk Exit.failed;
    };
    return @intFromEnum(code);
}

const App = struct {
    alloc: std.mem.Allocator,
    req: args.Request,
    out: output.Out,
    err: *Writer,

    fn run(a: *App) !Exit {
        switch (a.req.cmd) {
            .help => return a.help(),
            .version => {
                try a.out.w.print("headsight {s}\n", .{build_options.version});
                return .ok;
            },
            .drop => return a.drop(),
            else => {},
        }
        if (!platform.supported) {
            try output.unsupported(a.err);
            return .failed;
        }
        return switch (a.req.cmd) {
            .windows => a.windows(),
            .snap => a.snap(),
            .text => a.text(),
            .wait => a.wait(),
            .diff => a.diffSince(),
            else => unreachable,
        };
    }

    fn help(a: *App) !Exit {
        const topic = a.req.help_topic orelse {
            try a.out.w.writeAll(usage_text);
            return .ok;
        };
        for (command_help) |h| if (std.mem.eql(u8, h[0], topic)) {
            try a.out.w.writeAll(h[1]);
            return .ok;
        };
        try a.err.print("headsight: no help for '{s}'\n", .{topic});
        return .usage;
    }

    fn usage(a: *App, comptime fmt: []const u8, v: anytype) !Exit {
        try a.err.print("headsight: " ++ fmt ++ "\n", v);
        return .usage;
    }

    fn openStore(a: *App) !store.Store {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        const base = try std.fs.path.join(a.alloc, &.{ tmp, "headsight" });
        defer a.alloc.free(base);
        return store.Store.open(a.alloc, base, std.time.timestamp());
    }

    fn drop(a: *App) !Exit {
        var s = try a.openStore();
        defer s.close();
        if (!try s.dropRef(a.req.name.?)) return a.usage("no reference named \"{s}\"", .{a.req.name.?});
        try a.out.w.print("dropped {s}\n", .{a.req.name.?});
        return .ok;
    }

    // ---- permissions and sources ----

    /// null when access is fine, else the exit code after printing why.
    fn access(a: *App, source: args.Source) !?Exit {
        var buf: [256]u8 = undefined;
        if (source == .camera) {
            switch (platform.cameraAccess()) {
                platform.OK => return null,
                platform.NO_HOST => try output.noGuiHost(a.err),
                else => try output.permission(a.err, .camera, platform.hostApp(&buf) orelse "the app that runs the agent"),
            }
            return .permission;
        }
        if (platform.screenAccess(true)) {
            if (platform.screenLocked())
                try a.err.writeAll("headsight: note: the screen is locked; macOS doesn't redraw windows until it is unlocked, so nothing on screen will change\n");
            return null;
        }
        if (platform.hostApp(&buf)) |name| try output.permission(a.err, .screen, name) else try output.noGuiHost(a.err);
        return .permission;
    }

    const Resolved = struct { src: platform.HsSource, label: []const u8, gone: []const u8, cam_name: ?[:0]u8 = null };

    fn resolve(a: *App, source: args.Source, window_id: u32) !?Resolved {
        switch (source) {
            .screen => return .{ .src = .{ .kind = 0, .window_id = 0, .camera_name = null, .fps = @intCast(a.req.fps) }, .label = "screen", .gone = "display stopped" },
            .camera => |name| {
                const z = if (name) |n| try a.alloc.dupeZ(u8, n) else null;
                return .{ .src = .{ .kind = 2, .window_id = 0, .camera_name = if (z) |p| p.ptr else null, .fps = 30 }, .label = "camera", .gone = "camera stopped", .cam_name = z };
            },
            .window => |wanted| {
                var list = try a.listWindows();
                defer freeWindows(a.alloc, &list);
                var pick: ?output.WindowInfo = null;
                if (window_id != 0) for (list.items) |w| if (w.id == window_id) {
                    pick = w;
                    break;
                };
                if (pick == null) for (list.items) |w| {
                    if (std.ascii.indexOfIgnoreCase(w.app, wanted) != null or std.ascii.indexOfIgnoreCase(w.title, wanted) != null) {
                        pick = w;
                        break;
                    }
                };
                const w = pick orelse {
                    try a.err.print("headsight: no window matches \"{s}\"; on screen now:\n", .{wanted});
                    for (list.items[0..@min(5, list.items.len)]) |c| try a.err.print("  app=\"{s}\" title=\"{s}\"\n", .{ c.app, c.title });
                    return null;
                };
                return .{ .src = .{ .kind = 1, .window_id = w.id, .camera_name = null, .fps = @intCast(a.req.fps) }, .label = "window", .gone = "window gone" };
            },
        }
    }

    fn listWindows(a: *App) !std.ArrayList(output.WindowInfo) {
        const Ctx = struct {
            alloc: std.mem.Allocator,
            list: std.ArrayList(output.WindowInfo) = .empty,
            failed: bool = false,
            fn add(ctx: ?*anyopaque, id: u32, app: [*:0]const u8, title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                const a1 = self.alloc.dupe(u8, std.mem.span(app)) catch return self.fail();
                const t1 = self.alloc.dupe(u8, std.mem.span(title)) catch return self.fail();
                self.list.append(self.alloc, .{ .id = id, .app = a1, .title = t1, .x = x, .y = y, .w = @intCast(@max(w, 0)), .h = @intCast(@max(h, 0)) }) catch self.fail();
            }
            fn fail(self: *@This()) void {
                self.failed = true;
            }
        };
        var ctx = Ctx{ .alloc = a.alloc };
        try platform.windows(Ctx.add, &ctx);
        if (ctx.failed) return error.OutOfMemory;
        return ctx.list;
    }

    fn freeWindows(alloc: std.mem.Allocator, list: *std.ArrayList(output.WindowInfo)) void {
        for (list.items) |w| {
            alloc.free(w.app);
            alloc.free(w.title);
        }
        list.deinit(alloc);
    }

    fn windows(a: *App) !Exit {
        if (try a.access(.screen)) |code| return code;
        var list = try a.listWindows();
        defer freeWindows(a.alloc, &list);
        try a.out.windows(list.items);
        return .ok;
    }

    // ---- one frame ----

    const Captured = struct {
        frame: Frame,
        pixel_scale: f64,
        shot: ?platform.Shot = null,
        owned: ?[]u8 = null,

        fn deinit(c: *Captured, alloc: std.mem.Allocator) void {
            if (c.shot) |*s| s.deinit();
            if (c.owned) |o| alloc.free(o);
        }
    };

    /// One frame of the source; the camera is warmed up first. null: reported, exit with `code`.
    fn grab(a: *App, r: Resolved, code: *Exit) !?Captured {
        if (r.src.kind != 2) {
            const s = platform.shot(r.src) catch |e| {
                code.* = try a.captureError(e, r);
                return null;
            };
            return .{ .frame = s.frame, .pixel_scale = s.pixel_scale, .shot = s };
        }
        const Ctx = struct {
            alloc: std.mem.Allocator,
            n: u32 = 0,
            buf: ?[]u8 = null,
            w: u32 = 0,
            h: u32 = 0,
            fn onFrame(ctx: ?*anyopaque, hf: ?*const platform.HsFrame) callconv(.c) c_int {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                const f = platform.toFrame(hf orelse return 0);
                self.n += 1;
                if (self.n <= watch.camera_warmup) return 0;
                const row = @as(usize, f.w) * 4;
                const buf = self.alloc.alloc(u8, row * f.h) catch return 1;
                for (0..f.h) |y| @memcpy(buf[y * row ..][0..row], f.px[y * @as(usize, f.stride) ..][0..row]);
                self.buf = buf;
                self.w = f.w;
                self.h = f.h;
                return 1;
            }
        };
        var ctx = Ctx{ .alloc = a.alloc };
        const rc = try platform.stream(r.src, 15_000, Ctx.onFrame, &ctx);
        const buf = ctx.buf orelse {
            code.* = try a.streamError(rc, r);
            return null;
        };
        return .{ .frame = .{ .px = buf, .w = ctx.w, .h = ctx.h, .stride = ctx.w * 4 }, .pixel_scale = 1, .owned = buf };
    }

    fn captureError(a: *App, e: platform.Error, r: Resolved) !Exit {
        switch (e) {
            error.Permission => return (try a.access(.screen)) orelse .permission,
            error.Gone => try a.err.print("headsight: the {s} is gone\n", .{r.label}),
            else => try a.err.print("headsight: capturing the {s} failed\n", .{r.label}),
        }
        return .failed;
    }

    fn streamError(a: *App, rc: c_int, r: Resolved) !Exit {
        switch (rc) {
            platform.PERMISSION => return (try a.access(.screen)) orelse .permission,
            platform.NOT_FOUND => try a.err.print("headsight: no camera matches \"{s}\"\n", .{if (r.cam_name) |n| n else "default"}),
            platform.GONE => try a.err.print("headsight: {s}\n", .{r.gone}),
            platform.TIMEOUT => try a.err.print("headsight: the {s} sent no picture\n", .{r.label}),
            else => try a.err.print("headsight: capturing the {s} failed\n", .{r.label}),
        }
        return .failed;
    }

    fn writeCrop(a: *App, s: *store.Store, f: Frame, r: Rect, origin_x: u32, origin_y: u32) !output.CropInfo {
        const path = try s.cropPath();
        const z = try a.alloc.dupeZ(u8, path);
        defer a.alloc.free(z);
        const scale = try platform.writePng(z, f, r, 1024);
        return .{ .path = path, .origin_x = origin_x + r.x, .origin_y = origin_y + r.y, .scale = @floatCast(scale) };
    }

    fn checkRegion(a: *App, r: Rect, f: Frame) !bool {
        var d = args.Diag{};
        args.checkRegion(r, f.w, f.h, &d) catch {
            try a.err.print("headsight: {s}\n", .{d.msg()});
            return false;
        };
        return true;
    }

    // ---- commands ----

    fn snap(a: *App) !Exit {
        if (try a.access(a.req.source)) |code| return code;
        const r = (try a.resolve(a.req.source, 0)) orelse return .usage;
        defer if (r.cam_name) |n| a.alloc.free(n);
        var code: Exit = .failed;
        var cap = (try a.grab(r, &code)) orelse return code;
        defer cap.deinit(a.alloc);
        const f = cap.frame;
        const region = a.req.region orelse f.full();
        if (!try a.checkRegion(region, f)) return .usage;
        var s = try a.openStore();
        defer s.close();
        const crop = try a.writeCrop(&s, f, region, 0, 0);
        defer a.alloc.free(crop.path);
        if (a.req.name) |name| {
            try s.saveRef(name, .{ .source = a.req.source, .window_id = r.src.window_id, .region = region, .created_s = std.time.timestamp(), .src_w = f.w, .src_h = f.h }, f);
        }
        try a.out.snap(.{ .source = r.label, .src_w = f.w, .src_h = f.h, .pixel_scale = @floatCast(cap.pixel_scale), .region = region, .crop = crop, .ref = a.req.name });
        return .ok;
    }

    fn text(a: *App) !Exit {
        if (try a.access(a.req.source)) |code| return code;
        const r = (try a.resolve(a.req.source, 0)) orelse return .usage;
        defer if (r.cam_name) |n| a.alloc.free(n);
        var code: Exit = .failed;
        var cap = (try a.grab(r, &code)) orelse return code;
        defer cap.deinit(a.alloc);
        const region = a.req.region orelse cap.frame.full();
        if (!try a.checkRegion(region, cap.frame)) return .usage;
        var lines: std.ArrayList(watch.TextLine) = .empty;
        defer {
            for (lines.items) |l| a.alloc.free(l.text);
            lines.deinit(a.alloc);
        }
        try platform.ocr(a.alloc, cap.frame, region, a.req.accurate, &lines);
        try a.out.textLines(lines.items);
        return .ok;
    }

    fn openRef(a: *App, s: *store.Store, name: []const u8) !?store.Ref {
        return s.loadRef(name, std.time.timestamp()) catch |e| switch (e) {
            error.NoSuchRef => {
                _ = try a.usage("no reference named \"{s}\"", .{name});
                return null;
            },
            error.RefExpired => {
                _ = try a.usage("reference \"{s}\" expired (references last an hour); take a new one with 'snap --name {s}'", .{ name, name });
                return null;
            },
            else => return e,
        };
    }

    fn sizeChanged(a: *App, name: []const u8, ref: store.Ref, f: Frame) !bool {
        store.checkSize(ref, f.w, f.h) catch {
            try a.err.print("headsight: reference \"{s}\" is {d}x{d} but the {s} is now {d}x{d}; take a new one with 'snap --name {s}'\n", .{ name, ref.meta.src_w, ref.meta.src_h, @tagName(ref.meta.source), f.w, f.h, name });
            return true;
        };
        return false;
    }

    fn diffSince(a: *App) !Exit {
        const name = a.req.since.?;
        var s = try a.openStore();
        defer s.close();
        var ref = (try a.openRef(&s, name)) orelse return .usage;
        defer ref.deinit(a.alloc);
        if (try a.access(ref.meta.source)) |code| return code;
        const r = (try a.resolve(ref.meta.source, ref.meta.window_id)) orelse return .failed;
        defer if (r.cam_name) |n| a.alloc.free(n);
        var code: Exit = .failed;
        var cap = (try a.grab(r, &code)) orelse return code;
        defer cap.deinit(a.alloc);
        if (try a.sizeChanged(name, ref, cap.frame)) return .failed;

        const region = ref.meta.region;
        const cur = cap.frame.sub(region);
        var g = try diff.Grid.init(a.alloc, cur.full());
        defer g.deinit(a.alloc);
        const mask = try a.alloc.alloc(bool, g.scores.len);
        defer a.alloc.free(mask);
        diff.score(&g, ref.frame, cur);
        _ = diff.changedUniform(g, if (ref.meta.source == .camera) watch.camera_min else watch.screen_thresh, mask);
        if (ref.meta.source == .window) if (titleBar(region, cap.pixel_scale)) |tb| {
            _ = diff.clearRects(g, mask, &.{tb});
        };
        var res = try boxes.find(a.alloc, g, mask, 8);
        defer res.deinit(a.alloc);

        var shown: std.ArrayList(Rect) = .empty;
        defer shown.deinit(a.alloc);
        var crops: std.ArrayList(output.CropInfo) = .empty;
        defer {
            for (crops.items) |c| a.alloc.free(c.path);
            crops.deinit(a.alloc);
        }
        for (res.boxes) |b| {
            try shown.append(a.alloc, .{ .x = b.x + region.x, .y = b.y + region.y, .w = b.w, .h = b.h });
            try crops.append(a.alloc, try a.writeCrop(&s, cur, b.pad(16, cur.w, cur.h), region.x, region.y));
        }
        try a.out.diffResult(name, std.time.timestamp() - ref.meta.created_s, shown.items, res.total, crops.items);
        return .ok;
    }

    fn wait(a: *App) !Exit {
        var s = try a.openStore();
        defer s.close();
        var ref: ?store.Ref = null;
        defer if (ref) |*x| x.deinit(a.alloc);
        var source = a.req.source;
        var window_id: u32 = 0;
        if (a.req.since) |name| {
            if (a.req.region != null) return a.usage("--region can't be combined with --since; the reference keeps its own region", .{});
            ref = (try a.openRef(&s, name)) orelse return .usage;
            source = ref.?.meta.source;
            window_id = ref.?.meta.window_id;
        }
        if (try a.access(source)) |code| return code;
        const r = (try a.resolve(source, window_id)) orelse return if (a.req.since != null) .failed else .usage;
        defer if (r.cam_name) |n| a.alloc.free(n);

        var st = WaitState{ .app = a, .store = &s, .ref = if (ref) |*x| x else null, .camera = r.src.kind == 2, .window = r.src.kind == 1, .timer = try std.time.Timer.start() };
        defer st.deinit();
        const rc = try platform.stream(r.src, a.req.timeout_ms, WaitState.onFrame, &st);
        if (st.failure) |code| return code;
        const now = st.elapsedMs();
        if (st.event == null) {
            switch (rc) {
                platform.TIMEOUT => st.event = .{ .timeout = .{ .at_ms = now } },
                platform.GONE => st.event = .{ .source_gone = .{ .at_ms = now } },
                else => return a.streamError(rc, r),
            }
        }
        const ev = st.event.?;
        const shown = try st.shownEvent(ev);
        defer if (shown == .changed) a.alloc.free(shown.changed.boxes);
        try a.out.event(shown, st.crop, r.gone);
        return switch (ev) {
            .timeout => .timeout,
            .source_gone => .failed,
            else => .ok,
        };
    }
};

/// State for one `wait`, fed from the capture queue.
const WaitState = struct {
    app: *App,
    store: *store.Store,
    ref: ?*store.Ref,
    camera: bool,
    window: bool,
    scale: f64 = 1,
    /// Monotonic: a wall-clock step must not break timings.
    timer: std.time.Timer,
    w: ?watch.Watch = null,
    region: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    event: ?watch.Event = null,
    crop: ?output.CropInfo = null,
    failure: ?Exit = null,
    ignore: []Rect = &.{},

    fn deinit(st: *WaitState) void {
        if (st.w) |*w| w.deinit();
        if (st.crop) |c| st.app.alloc.free(c.path);
        st.app.alloc.free(st.ignore);
    }

    fn elapsedMs(st: *WaitState) u64 {
        return st.timer.read() / std.time.ns_per_ms;
    }

    fn onFrame(ctx: ?*anyopaque, hf: ?*const platform.HsFrame) callconv(.c) c_int {
        const st: *WaitState = @ptrCast(@alignCast(ctx.?));
        if (hf) |p| st.scale = p.scale;
        return st.step(if (hf) |p| platform.toFrame(p) else null) catch |e| {
            st.app.err.print("headsight: {s}\n", .{@errorName(e)}) catch {};
            st.failure = .failed;
            return 1;
        };
    }

    fn step(st: *WaitState, full: ?Frame) !c_int {
        const a = st.app;
        const now = st.elapsedMs();
        if (st.w == null) {
            const f = full orelse return 0; // wait for the first frame
            if (st.ref) |ref| {
                if (try a.sizeChanged(a.req.since.?, ref.*, f)) {
                    st.failure = .failed;
                    return 1;
                }
                st.region = ref.meta.region;
            } else {
                st.region = a.req.region orelse f.full();
                if (!try a.checkRegion(st.region, f)) {
                    st.failure = .usage;
                    return 1;
                }
            }
            // --ignore areas are in source coordinates; the watch sees the region only.
            var ig: std.ArrayList(Rect) = .empty;
            for (a.req.ignore) |r| {
                const x0 = @max(r.x, st.region.x);
                const y0 = @max(r.y, st.region.y);
                const x1 = @min(r.right(), st.region.right());
                const y1 = @min(r.bottom(), st.region.bottom());
                if (x1 > x0 and y1 > y0) try ig.append(a.alloc, .{ .x = x0 - st.region.x, .y = y0 - st.region.y, .w = x1 - x0, .h = y1 - y0 });
            }
            if (st.window) if (titleBar(st.region, st.scale)) |tb| try ig.append(a.alloc, tb);
            st.ignore = try ig.toOwnedSlice(a.alloc);
            const sub_rect = Rect{ .x = 0, .y = 0, .w = st.region.w, .h = st.region.h };
            st.w = try watch.Watch.init(a.alloc, .{ .mode = a.req.mode.?, .region = sub_rect, .ignore = st.ignore, .timeout_ms = a.req.timeout_ms, .camera = st.camera }, ocrRead, null, if (st.ref) |ref| ref.frame else null);
        }
        const cur: ?Frame = if (full) |f| blk: {
            if (f.w < st.region.right() or f.h < st.region.bottom()) {
                st.event = .{ .size_changed = .{ .at_ms = now, .w = f.w, .h = f.h } };
                return 1;
            }
            break :blk f.sub(st.region);
        } else null;
        const ev = (try st.w.?.feed(cur, now)) orelse return 0;
        st.event = ev;
        try st.makeCrop(ev, cur);
        return 1;
    }

    fn makeCrop(st: *WaitState, ev: watch.Event, cur: ?Frame) !void {
        const a = st.app;
        const src = cur orelse st.w.?.last() orelse return;
        const r: Rect = switch (ev) {
            .changed => |c| boxes.unionOf(c.boxes).pad(16, src.w, src.h),
            .still => src.full(),
            .text => |t| t.line.box.pad(16, src.w, src.h),
            else => return,
        };
        if (r.w == 0 or r.h == 0) return;
        st.crop = try a.writeCrop(st.store, src, r, st.region.x, st.region.y);
    }

    /// The event with boxes moved from region to source coordinates.
    fn shownEvent(st: *WaitState, ev: watch.Event) !watch.Event {
        switch (ev) {
            .changed => |c| {
                const out = try st.app.alloc.alloc(Rect, c.boxes.len);
                for (c.boxes, out) |b, *o| o.* = .{ .x = b.x + st.region.x, .y = b.y + st.region.y, .w = b.w, .h = b.h };
                return .{ .changed = .{ .at_ms = c.at_ms, .boxes = out, .total = c.total } };
            },
            .text => |t| {
                var line = t.line;
                line.box.x += st.region.x;
                line.box.y += st.region.y;
                return .{ .text = .{ .at_ms = t.at_ms, .line = line } };
            },
            else => return ev,
        }
    }

    fn ocrRead(_: ?*anyopaque, alloc: std.mem.Allocator, f: Frame, r: Rect, out: *std.ArrayList(watch.TextLine)) anyerror!void {
        try platform.ocr(alloc, f, r, false, out);
    }
};

/// A window's title bar changes with focus and shows macOS's recording
/// indicator while it is captured, so window sources leave out the top
/// strip. Returns that strip relative to `region`, or null if they don't meet.
pub fn titleBar(region: Rect, pixel_scale: f64) ?Rect {
    const bar_h: u32 = @intFromFloat(@round(28 * @max(pixel_scale, 1)));
    if (region.y >= bar_h) return null;
    return .{ .x = 0, .y = 0, .w = region.w, .h = @min(bar_h - region.y, region.h) };
}

test "title_bar_relative_to_region" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 2000, .h = 56 }, titleBar(.{ .x = 0, .y = 0, .w = 2000, .h = 1336 }, 2).?);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 500, .h = 36 }, titleBar(.{ .x = 50, .y = 20, .w = 500, .h = 500 }, 2).?);
    try std.testing.expect(titleBar(.{ .x = 100, .y = 700, .w = 10, .h = 10 }, 2) == null);
    // 1x display: 28 px, so content below 28 px is still watched
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1000, .h = 28 }, titleBar(.{ .x = 0, .y = 0, .w = 1000, .h = 668 }, 1).?);
    try std.testing.expect(titleBar(.{ .x = 0, .y = 30, .w = 100, .h = 100 }, 1) == null);
}

test {
    _ = @import("frame.zig");
    _ = @import("diff.zig");
    _ = @import("boxes.zig");
    _ = @import("watch.zig");
    _ = @import("args.zig");
    _ = @import("store.zig");
    _ = @import("output.zig");
    _ = @import("platform.zig");
}
