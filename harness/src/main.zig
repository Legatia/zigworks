//! harness: a personal agent you talk to in Telegram or the terminal.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config = @import("config.zig");
const core_mod = @import("core.zig");
const store_mod = @import("store.zig");
const telegram = @import("telegram.zig");
const log_mod = @import("log.zig");
const util = @import("util.zig");
const agent = @import("agent.zig");
const Io = std.Io;
const Core = core_mod.Core;

const usage =
    \\harness: a personal agent you talk to in Telegram or the terminal.
    \\
    \\Usage: harness [--home DIR] COMMAND
    \\
    \\  init                       write the data folder with commented defaults
    \\  secret add NAME [--stdin]  store a secret (typed, not shown)
    \\  secret rm NAME             remove a stored secret
    \\  secret list                which of the configured secrets are stored
    \\  pair                       print a code to send to the bot as /pair CODE
    \\  run                        run the agent: Telegram and the scheduler
    \\  chat                       talk to the agent in this terminal
    \\  brief [NAME]               collect and print a brief now
    \\  task run NAME              run a scheduled task now and print its answer
    \\  memory [list|pin|unpin|forget ID]
    \\  log verify                 check the action log's chain
    \\  log tail [N]               print the last N log lines (default 20)
    \\  health                     exit 0 if `harness run` is running and recent
    \\  version | help
    \\
    \\The data folder is --home, else HARNESS_HOME, else ~/.local/share/harness
    \\(%LOCALAPPDATA%\harness on Windows). Secrets go to the macOS Keychain,
    \\the Windows Credential Manager, or (Linux, or HARNESS_STORE=DIR) files
    \\readable only by you.
    \\
;

const Exit = enum(u8) { ok = 0, failed = 1, usage = 2 };

const App = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    home: []const u8 = "",

    fn defaultHome(app: *App) ![]const u8 {
        if (app.env.get("HARNESS_HOME")) |h| if (h.len > 0) return h;
        if (builtin.os.tag == .windows) {
            const base = app.env.get("LOCALAPPDATA") orelse return error.NoHomeDirectory;
            return std.fs.path.join(app.arena, &.{ base, "harness" });
        }
        if (app.env.get("XDG_DATA_HOME")) |x| if (x.len > 0) return std.fs.path.join(app.arena, &.{ x, "harness" });
        const home = app.env.get("HOME") orelse return error.NoHomeDirectory;
        return std.fs.path.join(app.arena, &.{ home, ".local", "share", "harness" });
    }

    fn store(app: *App) store_mod.Store {
        const override = if (app.env.get("HARNESS_STORE")) |s| (if (s.len > 0) s else null) else null;
        if (override != null or builtin.os.tag == .macos or builtin.os.tag == .windows) return store_mod.default(override, null);
        return store_mod.default(null, std.fs.path.join(app.arena, &.{ app.home, "secrets" }) catch "harness-secrets");
    }

    fn settings(app: *App) !config.Config {
        const p = try std.fs.path.join(app.arena, &.{ app.home, "config.ini" });
        const text = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => {
                complain("no data folder at {s}; run: harness init", .{app.home});
                return error.Reported;
            },
            else => return e,
        };
        return config.parse(app.arena, text) catch {
            complain("{s} has an error", .{p});
            return error.Reported;
        };
    }

    fn secrets(app: *App, cfg: config.Config) core_mod.Secrets {
        const s = app.store();
        return .{
            .omnigate = s.get(app.io, app.arena, cfg.model.key) catch null,
            .telegram = s.get(app.io, app.arena, cfg.chat.token) catch null,
            .search = s.get(app.io, app.arena, cfg.search.key) catch null,
        };
    }

    /// Opens the instance, or explains why not.
    fn open(app: *App) !*Core {
        const cfg = try app.settings();
        const sec = app.secrets(cfg);
        if (sec.omnigate == null) complain("note: no omnigate key stored under \"{s}\"; model calls will be refused. Run: harness secret add {s}", .{ cfg.model.key, cfg.model.key });
        const c = Core.open(app.gpa, app.io, app.home, sec) catch |e| {
            switch (e) {
                error.AlreadyRunning => complain("harness is already running on {s}; talk to it there (or stop it first)", .{app.home}),
                error.BadSettings => complain("a settings file in {s} has an error, or config.ini/rules can be changed by other users (chmod 600 them)", .{app.home}),
                else => complain("can't open {s}: {s}", .{ app.home, @errorName(e) }),
            }
            return error.Reported;
        };
        c.path_var = app.env.get("PATH") orelse c.path_var;
        c.home_var = app.env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "";
        return c;
    }
};

pub fn main(init: std.process.Init) u8 {
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const raw = init.minimal.args.toSlice(arena) catch return @intFromEnum(Exit.failed);
    var app: App = .{ .gpa = gpa, .arena = arena, .io = init.io, .env = init.environ_map };
    var args: []const []const u8 = raw[1..];
    var home: ?[]const u8 = null;
    if (args.len >= 2 and eql(args[0], "--home")) {
        home = args[1];
        args = args[2..];
    }
    app.home = home orelse app.defaultHome() catch {
        complain("no home folder found; pass --home DIR", .{});
        return @intFromEnum(Exit.failed);
    };
    const code = dispatch(&app, args) catch |e| switch (e) {
        error.Reported => Exit.failed,
        else => blk: {
            complain("{s}", .{@errorName(e)});
            break :blk Exit.failed;
        },
    };
    return @intFromEnum(code);
}

fn dispatch(app: *App, args: []const []const u8) !Exit {
    if (args.len == 0 or eql(args[0], "help") or eql(args[0], "--help") or eql(args[0], "-h")) {
        try outAll(app.io, usage);
        return if (args.len == 0) .usage else .ok;
    }
    const cmd = args[0];
    const rest = args[1..];
    if (eql(cmd, "version")) {
        try outAll(app.io, "harness " ++ build_options.version ++ "\n");
        return .ok;
    }
    if (eql(cmd, "init")) return initCmd(app);
    if (eql(cmd, "secret")) return secretCmd(app, rest);
    if (eql(cmd, "pair")) return pairCmd(app);
    if (eql(cmd, "run")) return runCmd(app);
    if (eql(cmd, "chat")) return chatCmd(app);
    if (eql(cmd, "brief")) return briefCmd(app, rest);
    if (eql(cmd, "task")) return taskCmd(app, rest);
    if (eql(cmd, "memory")) return memoryCmd(app, rest);
    if (eql(cmd, "log")) return logCmd(app, rest);
    if (eql(cmd, "health")) return healthCmd(app);
    complain("unknown command {s}; see harness help", .{cmd});
    return .usage;
}

fn initCmd(app: *App) !Exit {
    try core_mod.initHome(app.io, app.arena, app.home);
    try outPrint(app.io,
        \\Data folder: {s}
        \\Next:
        \\  1. Set the omnigate url and route names in config.ini.
        \\  2. harness secret add omnigate     (your omnigate key)
        \\  3. harness secret add telegram     (the bot token from @BotFather)
        \\  4. harness secret add search       (optional: Brave Search API key)
        \\  5. harness run, then harness pair, then send /pair CODE to the bot.
        \\
    , .{app.home});
    return .ok;
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn secretCmd(app: *App, args: []const []const u8) !Exit {
    if (args.len == 0) {
        complain("usage: harness secret add|rm|list NAME", .{});
        return .usage;
    }
    const s = app.store();
    if (eql(args[0], "list")) {
        const cfg = try app.settings();
        for ([_][2][]const u8{ .{ "model key", cfg.model.key }, .{ "bot token", cfg.chat.token }, .{ "search key", cfg.search.key } }) |pair| {
            const v = s.get(app.io, app.arena, pair[1]) catch null;
            try outPrint(app.io, "{s} ({s}): {s}\n", .{ pair[1], pair[0], if (v != null) "stored" else "not stored" });
        }
        return .ok;
    }
    if (args.len < 2 or !validName(args[1])) {
        complain("secret names use a-z, 0-9, - and _", .{});
        return .usage;
    }
    const name = args[1];
    if (eql(args[0], "rm")) {
        const gone = s.remove(app.io, name) catch {
            complain("could not remove {s}", .{name});
            return .failed;
        };
        try outPrint(app.io, "{s}\n", .{if (gone) "Removed." else "Nothing stored under that name."});
        return .ok;
    }
    if (!eql(args[0], "add")) {
        complain("usage: harness secret add|rm|list NAME", .{});
        return .usage;
    }
    const from_stdin = args.len > 2 and eql(args[2], "--stdin");
    const stdin = Io.File.stdin();
    const tty = stdin.isTty(app.io) catch false;
    if (!tty and !from_stdin) {
        complain("type the value at a terminal, or pass --stdin to read it from a pipe", .{});
        return .usage;
    }
    var echo: ?Echo = null;
    if (tty) {
        try errPrint(app.io, "Value for {s} (not shown): ", .{name});
        echo = Echo.off(stdin);
    }
    const value = readLine(app, stdin) catch |e| {
        if (echo) |*x| x.restore();
        return e;
    };
    if (echo) |*x| {
        x.restore();
        try errAll(app.io, "\n");
    }
    defer std.crypto.secureZero(u8, value);
    if (value.len < 8) {
        complain("values shorter than 8 characters can't be masked reliably; nothing stored", .{});
        return .failed;
    }
    s.put(app.io, name, value) catch {
        complain("could not store the value in {s}", .{s.describe()});
        return .failed;
    };
    try errPrint(app.io, "Stored {s} in {s}.\n", .{ name, s.describe() });
    return .ok;
}

fn pairCmd(app: *App) !Exit {
    const p = try core_mod.Paths.init(app.arena, app.home);
    var buf: [8]u8 = undefined;
    const code = try core_mod.newPairCode(app.io, p, util.nowSeconds(app.io), &buf);
    try outPrint(app.io, "Send this to your bot within 10 minutes (harness run must be running):\n/pair {s}\n", .{code});
    return .ok;
}

// ---- Telegram ----

const TgChan = struct {
    bot: *telegram.Bot,
    core: *Core,

    fn channel(tc: *TgChan) core_mod.Channel {
        return .{ .ctx = tc, .send = send, .buttons = buttons, .clear = clear };
    }

    fn send(ctx: *anyopaque, text: []const u8) void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const chat = tc.core.owner orelse return;
        tc.bot.send(chat, text) catch |e| complain("telegram: sending failed: {s}", .{@errorName(e)});
    }

    fn buttons(ctx: *anyopaque, text: []const u8, bs: []const [2][]const u8) ?i64 {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const chat = tc.core.owner orelse return null;
        return tc.bot.sendButtons(chat, text, bs) catch null;
    }

    fn clear(ctx: *anyopaque, id: i64) void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const chat = tc.core.owner orelse return;
        tc.bot.clearButtons(chat, id) catch {};
    }
};

fn ticker(c: *Core) void {
    while (!c.quitting.load(.acquire)) {
        c.tick();
        var i: u32 = 0;
        while (i < 50 and !c.quitting.load(.acquire)) : (i += 1) c.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

fn runCmd(app: *App) !Exit {
    const c = try app.open();
    defer c.close();
    if (!c.cfg.chat.telegram) {
        complain("Telegram is off in config.ini; use harness chat", .{});
        return .failed;
    }
    const token = c.secrets.telegram orelse {
        complain("no bot token stored under \"{s}\"; run: harness secret add {s}", .{ c.cfg.chat.token, c.cfg.chat.token });
        return .failed;
    };
    var bot = telegram.Bot.init(app.gpa, app.io, c.cfg.chat.api, token) catch {
        complain("the Telegram api url in config.ini is not valid", .{});
        return .failed;
    };
    defer bot.deinit();
    // sends and button presses must not wait behind the long poll
    var send_bot = try telegram.Bot.init(app.gpa, app.io, c.cfg.chat.api, token);
    defer send_bot.deinit();
    var tc: TgChan = .{ .bot = &send_bot, .core = c };
    c.attach(tc.channel());
    try c.startWorker();
    const tick_thread = try std.Thread.spawn(.{}, ticker, .{c});
    defer tick_thread.join();
    defer c.quitting.store(true, .release);
    try errPrint(app.io, "harness {s}: running on {s}{s}\n", .{ build_options.version, app.home, if (c.owner == null) "; not paired yet: run harness pair" else "" });

    var offset = telegram.Offset.load(app.io, c.paths.telegram);
    var failures: u32 = 0;
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const ups = bot.getUpdates(a, offset, 50) catch |e| {
            failures += 1;
            if (failures == 1 or failures % 20 == 0) complain("telegram: {s}; retrying", .{@errorName(e)});
            app.io.sleep(.fromSeconds(@min(60, 2 * failures)), .awake) catch {};
            continue;
        };
        failures = 0;
        for (ups) |u| {
            offset = u.updateId() + 1;
            // saved first: after a crash an update is not handled twice
            telegram.Offset.save(app.io, c.paths.telegram, offset) catch {};
            switch (u) {
                .message => |m| if (m.text.len > 0) c.handleMessage(m.from_id, m.text) catch |e| complain("handling a message: {s}", .{@errorName(e)}),
                .callback => |cb| {
                    send_bot.answer(cb.id) catch {};
                    c.handleCallback(cb.from_id, cb.data);
                },
            }
        }
    }
}

// ---- terminal ----

const TermChan = struct {
    io: Io,
    mutex: Io.Mutex = .init,

    fn channel(tc: *TermChan) core_mod.Channel {
        return .{ .ctx = tc, .send = send, .buttons = buttons, .clear = clear };
    }

    fn send(ctx: *anyopaque, text: []const u8) void {
        const tc: *TermChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        outPrint(tc.io, "{s}\n", .{text}) catch {};
    }

    fn buttons(ctx: *anyopaque, text: []const u8, bs: []const [2][]const u8) ?i64 {
        _ = bs;
        const tc: *TermChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        outPrint(tc.io, "{s}\n[o] allow once  [d] allow 24 h  [n] deny\n", .{text}) catch {};
        return 0;
    }

    fn clear(ctx: *anyopaque, id: i64) void {
        _ = ctx;
        _ = id;
    }
};

fn chatCmd(app: *App) !Exit {
    const c = try app.open();
    defer c.close();
    var tc: TermChan = .{ .io = app.io };
    c.attach(tc.channel());
    try c.startWorker();
    const tick_thread = try std.Thread.spawn(.{}, ticker, .{c});
    defer tick_thread.join();
    defer c.quitting.store(true, .release);
    try errAll(app.io, "harness chat. /help for commands, /stop to stop, Ctrl-D to leave.\n");
    const stdin = Io.File.stdin();
    var ended = false;
    while (!ended) {
        const line = try readLineEof(app, stdin, &ended);
        if (line.len == 0) continue;
        if (c.approvalWaiting()) {
            const ans: ?agent.Answer = if (eql(line, "o")) .once else if (eql(line, "d")) .day else if (eql(line, "n")) .deny else null;
            if (ans) |x| {
                _ = c.answerPending(x);
                continue;
            }
        }
        try c.handleText(line);
    }
    // let queued and running turns finish their answers
    var waited: u32 = 0;
    while (waited < 15 * 60 * 1000) : (waited += 50) {
        c.queue_mutex.lockUncancelable(c.io);
        const pending = c.queue.items.len;
        c.queue_mutex.unlock(c.io);
        if (pending == 0 and !c.busy.load(.acquire)) break;
        app.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return .ok;
}

// ---- one-off runs ----

fn briefCmd(app: *App, args: []const []const u8) !Exit {
    const c = try app.open();
    defer c.close();
    var tc: TermChan = .{ .io = app.io };
    c.attach(tc.channel());
    if (c.briefs.len == 0) {
        complain("no briefs in briefs.ini", .{});
        return .failed;
    }
    const b = for (c.briefs) |b| {
        if (args.len == 0 or eql(b.name, args[0])) break b;
    } else {
        complain("no brief called {s}", .{args[0]});
        return .failed;
    };
    _ = try c.runBrief(b);
    return .ok;
}

fn taskCmd(app: *App, args: []const []const u8) !Exit {
    if (args.len != 2 or !eql(args[0], "run")) {
        complain("usage: harness task run NAME", .{});
        return .usage;
    }
    const c = try app.open();
    defer c.close();
    var tc: TermChan = .{ .io = app.io };
    c.attach(tc.channel());
    const tk = for (c.tasks) |tk| {
        if (eql(tk.name, args[1])) break tk;
    } else {
        complain("no task called {s}", .{args[1]});
        return .failed;
    };
    _ = try c.runTask(tk);
    return .ok;
}

fn memoryCmd(app: *App, args: []const []const u8) !Exit {
    const text = if (args.len == 0 or eql(args[0], "list"))
        "/memory"
    else if (args.len == 2 and (eql(args[0], "pin") or eql(args[0], "unpin") or eql(args[0], "forget")))
        try std.fmt.allocPrint(app.arena, "/{s} {s}", .{ args[0], args[1] })
    else {
        complain("usage: harness memory [list|pin|unpin|forget ID]", .{});
        return .usage;
    };
    const c = try app.open();
    defer c.close();
    try outPrint(app.io, "{s}\n", .{try c.command(app.arena, text)});
    return .ok;
}

fn logCmd(app: *App, args: []const []const u8) !Exit {
    const p = try core_mod.Paths.init(app.arena, app.home);
    if (args.len >= 1 and eql(args[0], "verify")) {
        const v = log_mod.verify(app.io, p.log) catch |e| {
            complain("can't read {s}: {s}", .{ p.log, @errorName(e) });
            return .failed;
        };
        if (v.broken_at) |n| {
            try outPrint(app.io, "Broken at line {d} of {s}: that line, or one before it, was changed, removed or reordered.\n", .{ n, p.log });
            return .failed;
        }
        try outPrint(app.io, "OK: {d} lines, chain intact.\n", .{v.lines});
        return .ok;
    }
    if (args.len >= 1 and eql(args[0], "tail")) {
        const n = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 20 else 20;
        const text = Io.Dir.cwd().readFileAlloc(app.io, p.log, app.arena, .limited(256 << 20)) catch |e| {
            complain("can't read {s}: {s}", .{ p.log, @errorName(e) });
            return .failed;
        };
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |l| try lines.append(app.arena, l);
        for (lines.items[lines.items.len -| n ..]) |l| try outPrint(app.io, "{s}\n", .{l});
        return .ok;
    }
    complain("usage: harness log verify | harness log tail [N]", .{});
    return .usage;
}

fn healthCmd(app: *App) !Exit {
    const p = try core_mod.Paths.init(app.arena, app.home);
    var buf: [256]u8 = undefined;
    var lbuf: [32]u8 = undefined;
    _ = Io.Dir.cwd().readFile(app.io, p.lock, &lbuf) catch {
        try outAll(app.io, "not running\n");
        return .failed;
    };
    const got = Io.Dir.cwd().readFile(app.io, p.status, &buf) catch {
        try outAll(app.io, "not running\n");
        return .failed;
    };
    const i = std.mem.indexOf(u8, got, "tick ") orelse return .failed;
    const tick = util.parseIso(got[i + 5 .. @min(got.len, i + 25)]) orelse return .failed;
    const age = util.nowSeconds(app.io) - tick;
    if (age > 90) {
        try outPrint(app.io, "stale: last tick {d} s ago\n", .{age});
        return .failed;
    }
    try outPrint(app.io, "running: last tick {d} s ago\n", .{age});
    return .ok;
}

// ---- terminal input ----

fn readLine(app: *App, f: Io.File) ![]u8 {
    var ended = false;
    return readLineEof(app, f, &ended);
}

fn readLineEof(app: *App, f: Io.File, ended: *bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var ch: [1]u8 = undefined;
    while (buf.items.len < 64 * 1024) {
        const got = f.readStreaming(app.io, &.{&ch}) catch |e| switch (e) {
            error.EndOfStream => {
                ended.* = true;
                break;
            },
            else => return e,
        };
        if (got == 0) {
            ended.* = true;
            break;
        }
        if (ch[0] == '\n') break;
        try buf.append(app.arena, ch[0]);
    }
    var v = buf.items;
    while (v.len > 0 and (v[v.len - 1] == '\r' or v[v.len - 1] == '\n')) v = v[0 .. v.len - 1];
    return v;
}

/// Terminal echo, off while a value is typed.
const Echo = struct {
    saved: Saved,
    file: Io.File,
    const Saved = if (builtin.os.tag == .windows) u32 else ?std.posix.termios;
    const k32 = struct {
        extern "kernel32" fn GetConsoleMode(h: std.os.windows.HANDLE, mode: *u32) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn SetConsoleMode(h: std.os.windows.HANDLE, mode: u32) callconv(.winapi) std.os.windows.BOOL;
    };

    fn off(f: Io.File) Echo {
        if (builtin.os.tag == .windows) {
            var mode: u32 = 0;
            _ = k32.GetConsoleMode(f.handle, &mode);
            _ = k32.SetConsoleMode(f.handle, mode & ~@as(u32, 0x0004)); // ENABLE_ECHO_INPUT
            return .{ .saved = mode, .file = f };
        }
        const old = std.posix.tcgetattr(f.handle) catch return .{ .saved = null, .file = f };
        var tio = old;
        tio.lflag.ECHO = false;
        std.posix.tcsetattr(f.handle, .FLUSH, tio) catch {};
        return .{ .saved = old, .file = f };
    }

    fn restore(e: *Echo) void {
        if (builtin.os.tag == .windows) {
            _ = k32.SetConsoleMode(e.file.handle, e.saved);
            return;
        }
        if (e.saved) |old| std.posix.tcsetattr(e.file.handle, .FLUSH, old) catch {};
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn outAll(io: Io, s: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, s);
}

fn outPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.smp_allocator, fmt, args);
    defer std.heap.smp_allocator.free(s);
    try outAll(io, s);
}

fn errAll(io: Io, s: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, s);
}

fn errPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    try errAll(io, std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn complain(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("harness: " ++ fmt ++ "\n", args);
}

test {
    _ = @import("config.zig");
    _ = @import("rules.zig");
    _ = @import("gate.zig");
    _ = @import("util.zig");
    _ = @import("log.zig");
    _ = @import("memory.zig");
    _ = @import("model.zig");
    _ = @import("tools.zig");
    _ = @import("agent.zig");
    _ = @import("feeds.zig");
    _ = @import("brief.zig");
    _ = @import("telegram.zig");
    _ = @import("core.zig");
    _ = @import("http.zig");
    _ = @import("jv.zig");
    _ = @import("sock.zig");
    _ = @import("store.zig");
    _ = @import("scrub.zig");
    _ = @import("skills.zig");
    _ = @import("mcp.zig");
}
