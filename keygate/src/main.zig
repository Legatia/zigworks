//! keygate: lets an agent use API keys it never sees.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const rules = @import("rules.zig");
const store_mod = @import("store.zig");
const scrub = @import("scrub.zig");
const gate = @import("gate.zig");
const Io = std.Io;

const usage =
    \\keygate: lets an agent use API keys it never sees.
    \\
    \\  keygate add NAME [--stdin]   Store a value; typed at the terminal, not shown
    \\  keygate rm NAME              Remove a stored value
    \\  keygate list                 Secrets in the rules file, and whether each is stored
    \\  keygate serve [--port N] [--env-file PATH]
    \\                               Run the gateway on 127.0.0.1 (port 7311; 0: any free)
    \\                               and print the placeholders and URLs to give the agent
    \\  keygate run NAME[,NAME] -- COMMAND [ARGS]
    \\                               Run one command with the real values in its
    \\                               environment and its output masked (weaker: the
    \\                               command can read the values)
    \\  keygate version
    \\
    \\Files (override with the variable in brackets):
    \\  rules  ~/.config/keygate/rules [KEYGATE_RULES]
    \\  log    ~/.local/state/keygate/log.jsonl [KEYGATE_LOG]
    \\  values the macOS Keychain, the Windows Credential Manager, or on Linux
    \\         ~/.local/share/keygate/secrets [KEYGATE_STORE: a directory]
    \\
;

const Exit = enum(u8) { ok = 0, failed = 1, usage = 2 };

const App = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,

    fn home(app: *App) ?[]const u8 {
        return app.env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    }

    fn path(app: *App, override: ?[]const u8, xdg: []const u8, win_var: []const u8, fallback: []const []const u8, leaf: []const []const u8) ![]const u8 {
        if (override) |o| if (app.env.get(o)) |p| if (p.len > 0) return p;
        var parts: std.ArrayList([]const u8) = .empty;
        if (builtin.os.tag == .windows) {
            try parts.append(app.arena, app.env.get(win_var) orelse return error.NoHomeDirectory);
        } else if (app.env.get(xdg)) |x| {
            try parts.append(app.arena, x);
        } else {
            try parts.append(app.arena, app.home() orelse return error.NoHomeDirectory);
            try parts.appendSlice(app.arena, fallback);
        }
        try parts.append(app.arena, "keygate");
        try parts.appendSlice(app.arena, leaf);
        return std.fs.path.join(app.arena, parts.items);
    }

    fn rulesPath(app: *App) ![]const u8 {
        return app.path("KEYGATE_RULES", "XDG_CONFIG_HOME", "APPDATA", &.{".config"}, &.{"rules"});
    }

    fn logPath(app: *App) ![]const u8 {
        return app.path("KEYGATE_LOG", "XDG_STATE_HOME", "LOCALAPPDATA", &.{ ".local", "state" }, &.{"log.jsonl"});
    }

    fn store(app: *App) !store_mod.Store {
        const override = if (app.env.get("KEYGATE_STORE")) |s| (if (s.len > 0) s else null) else null;
        if (override != null or builtin.os.tag == .macos or builtin.os.tag == .windows) return store_mod.default(override, null);
        return store_mod.default(null, try app.path(null, "XDG_DATA_HOME", "LOCALAPPDATA", &.{ ".local", "share" }, &.{"secrets"}));
    }

    /// The rules, or null after saying what's wrong.
    fn loadRules(app: *App) !?[]const rules.Rule {
        const p = try app.rulesPath();
        const text = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => {
                complain("no rules file at {s}\nWrite one; see the README for the format.", .{p});
                return null;
            },
            else => {
                complain("can't read {s}: {s}", .{ p, @errorName(e) });
                return null;
            },
        };
        if (builtin.os.tag != .windows) {
            const st = Io.Dir.cwd().statFile(app.io, p, .{}) catch |e| {
                complain("can't check {s}: {s}", .{ p, @errorName(e) });
                return null;
            };
            if (st.permissions.toMode() & 0o022 != 0) {
                complain("{s} can be changed by other users; run: chmod go-w {s}", .{ p, p });
                return null;
            }
        }
        switch (try rules.parse(app.arena, text)) {
            .ok => |r| return r,
            .err => |e| {
                complain("{s}:{d}: {s}", .{ p, e.line, e.msg });
                return null;
            },
        }
    }

    fn now(app: *App) i64 {
        return @intCast(@divFloor(Io.Clock.real.now(app.io).nanoseconds, std.time.ns_per_s));
    }
};

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const raw = init.minimal.args.toSlice(arena) catch return @intFromEnum(Exit.failed);
    const argv = arena.alloc([]const u8, raw.len) catch return @intFromEnum(Exit.failed);
    for (argv, raw) |*to, from| to.* = from;
    var app: App = .{ .gpa = std.heap.smp_allocator, .arena = arena, .io = io, .env = init.environ_map };
    const exit = run(&app, argv[@min(1, argv.len)..]) catch |e| blk: {
        complain("{s}", .{@errorName(e)});
        break :blk Exit.failed;
    };
    return @intFromEnum(exit);
}

fn run(app: *App, args: []const []const u8) !Exit {
    if (args.len == 0) {
        try outAll(app.io, usage);
        return .usage;
    }
    const cmd = args[0];
    const rest = args[1..];
    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) {
        try outAll(app.io, usage);
        return .ok;
    }
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try outAll(app.io, "keygate " ++ build_options.version ++ "\n");
        return .ok;
    }
    if (eql(cmd, "add")) return add(app, rest);
    if (eql(cmd, "rm")) return remove(app, rest);
    if (eql(cmd, "list")) return list(app, rest);
    if (eql(cmd, "serve")) return serve(app, rest);
    if (eql(cmd, "run")) return runCmd(app, rest);
    complain("unknown command: {s}\nSee `keygate help`.", .{cmd});
    return .usage;
}

fn add(app: *App, args: []const []const u8) !Exit {
    var name: ?[]const u8 = null;
    var from_stdin = false;
    for (args) |a| {
        if (eql(a, "--stdin")) {
            from_stdin = true;
        } else if (name == null) {
            name = a;
        } else {
            complain("add takes one NAME", .{});
            return .usage;
        }
    }
    const n = name orelse {
        complain("usage: keygate add NAME [--stdin]", .{});
        return .usage;
    };
    if (!rules.validName(n)) {
        complain("secret names use a-z, 0-9, - and _", .{});
        return .usage;
    }
    const stdin = Io.File.stdin();
    const tty = stdin.isTty(app.io) catch false;
    if (!tty and !from_stdin) {
        complain("type the value at a terminal, or pass --stdin to read it from a pipe", .{});
        return .usage;
    }
    var echo: ?Echo = null;
    if (tty) {
        try errPrint(app.io, "Value for {s} (not shown): ", .{n});
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
    const s = try app.store();
    s.put(app.io, n, value) catch {
        complain("could not store the value in {s}", .{s.describe()});
        return .failed;
    };
    try errPrint(app.io, "Stored {s} in {s}.\n", .{ n, s.describe() });
    return .ok;
}

fn readLine(app: *App, f: Io.File) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [512]u8 = undefined;
    while (buf.items.len < 64 * 1024) {
        const got = f.readStreaming(app.io, &.{&chunk}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (std.mem.indexOfScalar(u8, chunk[0..got], '\n')) |nl| {
            try buf.appendSlice(app.arena, chunk[0..nl]);
            break;
        }
        try buf.appendSlice(app.arena, chunk[0..got]);
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

fn remove(app: *App, args: []const []const u8) !Exit {
    if (args.len != 1) {
        complain("usage: keygate rm NAME", .{});
        return .usage;
    }
    const s = try app.store();
    const gone = s.remove(app.io, args[0]) catch {
        complain("could not remove it from {s}", .{s.describe()});
        return .failed;
    };
    if (!gone) {
        complain("nothing stored under {s}", .{args[0]});
        return .failed;
    }
    try errPrint(app.io, "Removed {s}.\n", .{args[0]});
    return .ok;
}

fn list(app: *App, args: []const []const u8) !Exit {
    if (args.len != 0) {
        complain("usage: keygate list", .{});
        return .usage;
    }
    const rs = (try app.loadRules()) orelse return .failed;
    const s = try app.store();
    const now = app.now();
    var text: Io.Writer.Allocating = .init(app.arena);
    const out = &text.writer;
    for (rs) |r| {
        const v = s.get(app.io, app.gpa, r.name) catch null;
        if (v) |x| {
            std.crypto.secureZero(u8, x);
            app.gpa.free(x);
        }
        try out.print("{s}  {s}://{s}{s}  {d} allow line{s}", .{ r.name, if (r.upstream.https) "https" else "http", r.upstream.host, r.upstream.base, r.allows.len, if (r.allows.len == 1) "" else "s" });
        if (r.expires) |e| {
            var tb: [20]u8 = undefined;
            try out.print("  {s} {s}", .{ if (now >= e) "expired" else "expires", gate.isoTime(&tb, e) });
        }
        if (v != null) try out.writeAll("  stored\n") else try out.print("  not stored: keygate add {s}\n", .{r.name});
    }
    try outAll(app.io, text.written());
    return .ok;
}

fn upperName(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const up = try a.alloc(u8, name.len);
    for (name, up) |c, *o| o.* = if (c == '-') '_' else std.ascii.toUpper(c);
    return up;
}

fn envName(a: std.mem.Allocator, r: rules.Rule) ![]const u8 {
    if (r.env) |e| return e;
    return std.fmt.allocPrint(a, "KEYGATE_{s}", .{try upperName(a, r.name)});
}

fn urlName(a: std.mem.Allocator, r: rules.Rule) ![]const u8 {
    return std.fmt.allocPrint(a, "KEYGATE_{s}_URL", .{try upperName(a, r.name)});
}

fn serve(app: *App, args: []const []const u8) !Exit {
    var port: u16 = 7311;
    var env_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                complain("--port takes a number", .{});
                return .usage;
            };
        } else if (eql(args[i], "--env-file") and i + 1 < args.len) {
            i += 1;
            env_file = args[i];
        } else {
            complain("usage: keygate serve [--port N] [--env-file PATH]", .{});
            return .usage;
        }
    }
    const rs = (try app.loadRules()) orelse return .failed;
    if (rs.len == 0) {
        complain("the rules file names no secrets", .{});
        return .failed;
    }
    const s = try app.store();
    const entries = try app.gpa.alloc(gate.Entry, rs.len);
    for (rs, entries) |r, *e| {
        const v = (s.get(app.io, app.gpa, r.name) catch {
            complain("could not read {s} from {s}", .{ r.name, s.describe() });
            return .failed;
        }) orelse {
            complain("no value stored for {s}; run: keygate add {s}", .{ r.name, r.name });
            return .failed;
        };
        var rnd: [16]u8 = undefined;
        app.io.randomSecure(&rnd) catch {
            complain("no secure random numbers on this system", .{});
            return .failed;
        };
        const hex = std.fmt.bytesToHex(rnd, .lower);
        e.* = .{ .rule = r, .value = v, .placeholder = try std.fmt.allocPrint(app.gpa, "kg-{s}-{s}", .{ r.name, &hex }) };
    }

    const log_path = try app.logPath();
    var log = gate.Log.open(app.io, log_path) catch |e| {
        complain("can't open the log {s}: {s}", .{ log_path, @errorName(e) });
        return .failed;
    };
    const g = gate.Gate.start(app.gpa, app.io, entries, port, &log) catch |e| {
        complain("can't listen on 127.0.0.1:{d}: {s}", .{ port, @errorName(e) });
        return .failed;
    };

    var text: Io.Writer.Allocating = .init(app.arena);
    for (entries) |e| {
        try text.writer.print("{s}={s}\n", .{ try envName(app.arena, e.rule), e.placeholder });
        try text.writer.print("{s}=http://127.0.0.1:{d}/{s}\n", .{ try urlName(app.arena, e.rule), g.port, e.rule.name });
    }
    if (env_file) |p| {
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = p, .data = text.written(), .flags = .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) } }) catch |e| {
            complain("can't write {s}: {s}", .{ p, @errorName(e) });
            return .failed;
        };
    }
    try errPrint(app.io, "keygate {s}: listening on 127.0.0.1:{d}, logging to {s}\nGive the agent these (placeholders, not the values):\n", .{ build_options.version, g.port, log_path });
    try outAll(app.io, text.written());
    g.wait();
    return .ok;
}

fn runCmd(app: *App, args: []const []const u8) !Exit {
    const dash = for (args, 0..) |a, i| {
        if (eql(a, "--")) break i;
    } else args.len;
    if (dash != 1 or dash + 1 >= args.len) {
        complain("usage: keygate run NAME[,NAME] -- COMMAND [ARGS]", .{});
        return .usage;
    }
    const rs = (try app.loadRules()) orelse return .failed;
    const s = try app.store();
    const now = app.now();
    var secrets: std.ArrayList(scrub.Secret) = .empty;
    var env = try app.env.clone(app.arena);
    var names = std.mem.splitScalar(u8, args[0], ',');
    while (names.next()) |n| {
        const r = for (rs) |r| {
            if (eql(r.name, n)) break r;
        } else {
            complain("{s} is not in the rules file", .{n});
            return .failed;
        };
        if (r.expires) |e| if (now >= e) {
            complain("the rule for {s} has expired", .{n});
            return .failed;
        };
        const v = (s.get(app.io, app.arena, n) catch null) orelse {
            complain("no value stored for {s}; run: keygate add {s}", .{ n, n });
            return .failed;
        };
        const var_name = try envName(app.arena, r);
        try env.put(var_name, v);
        try secrets.append(app.arena, .{ .name = n, .value = v });
        try errPrint(app.io, "keygate: {s} is in this command's environment as {s}; its output is masked, but the command itself can read and send the value.\n", .{ n, var_name });
    }

    const cmd = args[dash + 1 ..];
    var child = std.process.spawn(app.io, .{ .argv = cmd, .environ_map = &env, .stdout = .pipe, .stderr = .pipe }) catch |e| {
        complain("can't run {s}: {s}", .{ cmd[0], @errorName(e) });
        return .failed;
    };
    var masked = std.atomic.Value(usize).init(0);
    const t_out = try std.Thread.spawn(.{}, pump, .{ app.io, child.stdout.?, Io.File.stdout(), secrets.items, &masked });
    const t_err = try std.Thread.spawn(.{}, pump, .{ app.io, child.stderr.?, Io.File.stderr(), secrets.items, &masked });
    t_out.join();
    t_err.join();
    const term = try child.wait(app.io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    const log_path = try app.logPath();
    if (gate.Log.open(app.io, log_path)) |log_val| {
        var log = log_val;
        defer log.close(app.io);
        for (secrets.items) |sec| log.write(app.io, .{ .time = now, .secret = sec.name, .method = "RUN", .path = std.fs.path.basename(cmd[0]), .result = "allowed", .status = code, .masked = masked.load(.acquire) });
    } else |_| {}
    std.process.exit(code);
}

/// Copies `from` to `to`, masking the values. `child.wait` closes `from`.
fn pump(io: Io, from: Io.File, to: Io.File, secrets: []const scrub.Secret, masked: *std.atomic.Value(usize)) void {
    var s = scrub.Scrubber.init(std.heap.smp_allocator, secrets) catch return;
    defer s.deinit();
    var outbuf: Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer outbuf.deinit();
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const got = from.readStreaming(io, &.{&chunk}) catch break;
        s.feed(chunk[0..got], &outbuf.writer) catch break;
        to.writeStreamingAll(io, outbuf.written()) catch {};
        outbuf.clearRetainingCapacity();
    }
    s.finish(&outbuf.writer) catch {};
    to.writeStreamingAll(io, outbuf.written()) catch {};
    _ = masked.fetchAdd(s.hits, .acq_rel);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn outAll(io: Io, s: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, s);
}

fn errAll(io: Io, s: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, s);
}

fn errPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    try errAll(io, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
}

fn complain(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("keygate: " ++ fmt ++ "\n", args);
}

test {
    _ = @import("sock.zig");
    _ = @import("rules.zig");
    _ = @import("scrub.zig");
    _ = @import("store.zig");
    _ = @import("gate.zig");
}
