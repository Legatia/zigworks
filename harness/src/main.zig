//! harness: a personal agent you talk to in Telegram or the terminal.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mcp = @import("mcp.zig");
const config = @import("config.zig");
const core_mod = @import("core.zig");
const store_mod = @import("store.zig");
const telegram = @import("telegram.zig");
const log_mod = @import("log.zig");
const util = @import("util.zig");
const agent = @import("agent.zig");
const logins = @import("logins.zig");
const totp = @import("totp.zig");
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
    \\  login add NAME --site HOST [--username U] [--stdin]
    \\                             an account of the agent's own (password and
    \\                             TOTP secret typed, not shown)
    \\  login list                 the agent's logins and what is stored for them
    \\  login rm NAME              remove a login, its secrets and its browser profile
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
            .named = app.namedSecrets(s),
        };
    }

    /// The MCP servers' secrets, and the logins' passwords and TOTP seeds
    /// (masked in all tool output).
    fn namedSecrets(app: *App, s: store_mod.Store) []const core_mod.Secrets.Named {
        var out: std.ArrayList(core_mod.Secrets.Named) = .empty;
        out.appendSlice(app.arena, app.mcpSecrets(s)) catch {};
        for (app.loginList()) |l| for ([_]logins.Kind{ .password, .totp }) |k| {
            var nb: [96]u8 = undefined;
            const name = logins.secretName(&nb, l.name, k);
            const v = (s.get(app.io, app.arena, name) catch null) orelse continue;
            out.append(app.arena, .{ .name = app.arena.dupe(u8, name) catch continue, .value = v }) catch {};
        };
        return out.items;
    }

    fn loginsPath(app: *App) []const u8 {
        return std.fs.path.join(app.arena, &.{ app.home, "logins.ini" }) catch "logins.ini";
    }

    fn loginList(app: *App) []const logins.Login {
        const text = Io.Dir.cwd().readFileAlloc(app.io, app.loginsPath(), app.arena, .limited(1 << 20)) catch return &.{};
        return logins.parse(app.arena, text) catch &.{};
    }

    /// The stored secrets the servers in mcp.ini name.
    fn mcpSecrets(app: *App, s: store_mod.Store) []const core_mod.Secrets.Named {
        const p = std.fs.path.join(app.arena, &.{ app.home, "mcp.ini" }) catch return &.{};
        const text = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20)) catch return &.{};
        const cfgs = mcp.parseConfig(app.arena, text) catch return &.{};
        var out: std.ArrayList(core_mod.Secrets.Named) = .empty;
        for (cfgs) |sc| for (sc.secrets) |es| {
            const v = (s.get(app.io, app.arena, es.secret) catch null) orelse continue;
            out.append(app.arena, .{ .name = es.secret, .value = v }) catch {};
        };
        return out.items;
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
        c.system_vars = util.pickVars(app.arena, app.env, util.system_var_names) catch &.{};
        c.store = app.store();
        c.startExtras();
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
    if (eql(cmd, "login")) return loginCmd(app, rest);
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
        const p = try std.fs.path.join(app.arena, &.{ app.home, "mcp.ini" });
        if (Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20))) |text| {
            const cfgs = mcp.parseConfig(app.arena, text) catch &.{};
            for (cfgs) |sc| for (sc.secrets) |es| {
                const v = s.get(app.io, app.arena, es.secret) catch null;
                try outPrint(app.io, "{s} (MCP {s}): {s}\n", .{ es.secret, sc.name, if (v != null) "stored" else "not stored" });
            };
        } else |_| {}
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

// ---- logins ----

fn loginCmd(app: *App, args: []const []const u8) !Exit {
    const usage_line = "usage: harness login add NAME --site HOST [--username U] [--stdin] | login list | login rm NAME";
    if (args.len == 0) {
        complain(usage_line, .{});
        return .usage;
    }
    const s = app.store();
    const path = app.loginsPath();
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, app.arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const list = logins.parse(app.arena, text) catch {
        complain("{s} has an error", .{path});
        return .failed;
    };
    if (eql(args[0], "list")) {
        if (list.len == 0) {
            try outAll(app.io, "No logins.\n");
            return .ok;
        }
        for (list) |l| {
            const st = core_mod.loginState(app.io, app.arena, s, l.name);
            try outPrint(app.io, "{s}: {s}, username {s}, password {s}, TOTP {s}, passkeys {d}\n", .{ l.name, l.site, if (l.username.len > 0) l.username else "(none)", if (st.password) "yes" else "no", if (st.totp) "yes" else "no", st.passkeys });
        }
        return .ok;
    }
    if (args.len < 2 or !logins.validName(args[1])) {
        complain("login names use a-z, 0-9, - and _ (at most {d})", .{logins.max_name});
        return .usage;
    }
    const name = args[1];
    if (eql(args[0], "rm")) {
        const known = logins.find(list, name) != null;
        var removed: u32 = 0;
        for ([_]logins.Kind{ .password, .totp, .passkeys }) |k| {
            var nb: [96]u8 = undefined;
            if (s.remove(app.io, logins.secretName(&nb, name, k)) catch {
                complain("could not remove the secrets of {s}", .{name});
                return .failed;
            }) removed += 1;
        }
        const profile = try std.fs.path.join(app.arena, &.{ app.home, "profiles", name });
        const had_profile = if (Io.Dir.cwd().statFile(app.io, profile, .{})) |_| true else |_| false;
        if (had_profile) Io.Dir.cwd().deleteTree(app.io, profile) catch {
            complain("could not delete {s}", .{profile});
            return .failed;
        };
        if (known) {
            const rest = try core_mod.removeSection(app.arena, text, name);
            try writePrivate(app.io, path, rest);
        }
        if (!known and removed == 0 and !had_profile) {
            try outAll(app.io, "No login with that name.\n");
            return .ok;
        }
        try outPrint(app.io, "Removed {s}: its entry, {d} stored secret{s} and its browser profile.\n", .{ name, removed, if (removed == 1) "" else "s" });
        return .ok;
    }
    if (!eql(args[0], "add")) {
        complain(usage_line, .{});
        return .usage;
    }
    var site: []const u8 = "";
    var username: []const u8 = "";
    var from_stdin = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--site") and i + 1 < args.len) {
            i += 1;
            site = args[i];
        } else if (eql(args[i], "--username") and i + 1 < args.len) {
            i += 1;
            username = args[i];
        } else if (eql(args[i], "--stdin")) {
            from_stdin = true;
        } else {
            complain(usage_line, .{});
            return .usage;
        }
    }
    if (!logins.validSite(site)) {
        complain("--site takes a host name in lowercase, like github.com (no https://, no path)", .{});
        return .usage;
    }
    if (std.mem.indexOfAny(u8, username, "\n\r;#") != null) {
        complain("the username can't hold line breaks, ; or #", .{});
        return .usage;
    }
    if (logins.find(list, name) != null) {
        complain("a login called {s} exists; remove it first (harness login rm {s})", .{ name, name });
        return .failed;
    }
    // what an old login of this name left behind would go to the new one
    {
        const left = core_mod.loginState(app.io, app.arena, s, name);
        const profile = try std.fs.path.join(app.arena, &.{ app.home, "profiles", name });
        const has_profile = if (Io.Dir.cwd().statFile(app.io, profile, .{})) |_| true else |_| false;
        if (left.password or left.totp or left.passkeys_stored or has_profile) {
            complain("secrets or a browser profile of an earlier login called {s} are still there; run harness login rm {s} first", .{ name, name });
            return .failed;
        }
    }
    const stdin = Io.File.stdin();
    const tty = stdin.isTty(app.io) catch false;
    if (!tty and !from_stdin) {
        complain("type the values at a terminal, or pass --stdin to read two lines (password, TOTP secret) from a pipe", .{});
        return .usage;
    }
    const password = try readHidden(app, stdin, tty, "Password for {s} (not shown; empty: the agent makes one when it signs up): ", name);
    defer std.crypto.secureZero(u8, password);
    const seed = try readHidden(app, stdin, tty, "TOTP secret for {s} (not shown; empty for none): ", name);
    defer std.crypto.secureZero(u8, seed);
    if (password.len > 0 and password.len < 8) {
        complain("passwords shorter than 8 characters can't be masked reliably; nothing stored", .{});
        return .failed;
    }
    if (seed.len > 0) {
        var buf: [128]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        const raw = totp.base32Decode(&buf, seed) catch {
            complain("the TOTP secret is not base32 (letters A-Z and digits 2-7); nothing stored", .{});
            return .failed;
        };
        if (raw.len < 10) {
            complain("the TOTP secret is too short; nothing stored", .{});
            return .failed;
        }
    }
    var nb: [96]u8 = undefined;
    if (password.len > 0) s.put(app.io, logins.secretName(&nb, name, .password), password) catch {
        complain("could not store the password in {s}", .{s.describe()});
        return .failed;
    };
    if (seed.len > 0) s.put(app.io, logins.secretName(&nb, name, .totp), seed) catch {
        complain("could not store the TOTP secret in {s}", .{s.describe()});
        return .failed;
    };
    const entry = try std.fmt.allocPrint(app.arena, "{s}{s}[{s}]\nsite = {s}\n{s}{s}{s}", .{
        std.mem.trimEnd(u8, text, "\n"),             if (std.mem.trim(u8, text, " \n").len > 0) "\n\n" else "",
        name,                                          site,
        if (username.len > 0) "username = " else "", username,
        if (username.len > 0) "\n" else "",
    });
    try writePrivate(app.io, path, entry);
    try errPrint(app.io, "Stored {s} in {s}.\n", .{ name, s.describe() });
    return .ok;
}

/// One line, read with the terminal's echo off when it is one.
fn readHidden(app: *App, stdin: Io.File, tty: bool, comptime prompt: []const u8, name: []const u8) ![]u8 {
    var echo: ?Echo = null;
    if (tty) {
        try errPrint(app.io, prompt, .{name});
        echo = Echo.off(stdin);
    }
    const v = readLine(app, stdin) catch |e| {
        if (echo) |*x| x.restore();
        return e;
    };
    if (echo) |*x| {
        x.restore();
        try errAll(app.io, "\n");
    }
    return @constCast(std.mem.trim(u8, v, " \t"));
}

fn writePrivate(io: Io, path: []const u8, data: []const u8) !void {
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = util.private_file });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

fn pairCmd(app: *App) !Exit {
    const p = try core_mod.Paths.init(app.arena, app.home);
    var buf: [8]u8 = undefined;
    const code = try core_mod.newPairCode(app.io, p, util.nowSeconds(app.io), &buf);
    try outPrint(app.io, "Send this to your bot within 10 minutes (harness run must be running):\n/pair {s}\n", .{code});
    return .ok;
}

// ---- Telegram ----

/// `harness run`'s Telegram side: one bot for the long poll and one for
/// sending, so sends and button presses never wait behind the poll. Each
/// bot keeps its own copy of the api url; `refresh` makes both again when
/// /reload changed `[chat] api`.
const TgChan = struct {
    gpa: std.mem.Allocator,
    io: Io,
    core: *Core,
    token: []const u8,
    /// The long poll: only the thread that polls uses it.
    poll: telegram.Bot,
    /// Held while `send_bot` is used or replaced.
    mutex: Io.Mutex = .init,
    send_bot: telegram.Bot,
    /// An api url from config.ini that is not valid (owned), so it is
    /// refused once, not after every poll.
    rejected: ?[]u8 = null,

    fn init(tc: *TgChan, gpa: std.mem.Allocator, io: Io, core: *Core, api: []const u8, token: []const u8) !void {
        var poll = try telegram.Bot.init(gpa, io, api, token);
        errdefer poll.deinit();
        const send_bot = try telegram.Bot.init(gpa, io, api, token);
        tc.* = .{ .gpa = gpa, .io = io, .core = core, .token = token, .poll = poll, .send_bot = send_bot };
    }

    fn deinit(tc: *TgChan) void {
        tc.poll.deinit();
        tc.send_bot.deinit();
        if (tc.rejected) |r| tc.gpa.free(r);
    }

    /// After /reload: makes both bots again if `[chat] api` changed; true
    /// when it did. Call from the polling thread, where commands (and so
    /// /reload) run.
    fn refresh(tc: *TgChan) !bool {
        const api = tc.core.cfg.chat.api;
        if (std.mem.eql(u8, api, tc.poll.api)) return false;
        if (tc.rejected) |r| if (std.mem.eql(u8, api, r)) return false;
        var poll = telegram.Bot.init(tc.gpa, tc.io, api, tc.token) catch |e| switch (e) {
            error.BadUrl => {
                if (tc.rejected) |r| tc.gpa.free(r);
                tc.rejected = try tc.gpa.dupe(u8, api);
                tc.core.say("The Telegram api url in config.ini is not valid; I keep using the one from before.");
                return false;
            },
            else => return e,
        };
        errdefer poll.deinit();
        const send_bot = try telegram.Bot.init(tc.gpa, tc.io, api, tc.token);
        tc.poll.deinit();
        tc.poll = poll;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.deinit();
        tc.send_bot = send_bot;
        return true;
    }

    fn channel(tc: *TgChan) core_mod.Channel {
        return .{ .ctx = tc, .send = send, .buttons = buttons, .clear = clear };
    }

    fn send(ctx: *anyopaque, text: []const u8) anyerror!void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const chat = tc.core.owner orelse return error.NotPaired;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.send(chat, text) catch |e| {
            complain("telegram: sending failed: {s}", .{@errorName(e)});
            return e;
        };
    }

    fn buttons(ctx: *anyopaque, text: []const u8, bs: []const [2][]const u8) ?i64 {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const chat = tc.core.owner orelse return null;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        return tc.send_bot.sendButtons(chat, text, bs) catch null;
    }

    fn clear(ctx: *anyopaque, id: i64) void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const chat = tc.core.owner orelse return;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.clearButtons(chat, id) catch {};
    }

    /// Takes a button press, so Telegram stops showing it as pending.
    fn answer(tc: *TgChan, callback_id: []const u8) void {
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.answer(callback_id) catch {};
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
    // the bots outlive the core: its threads talk through them until close
    var tc: TgChan = undefined;
    var tc_made = false;
    defer {
        c.close();
        if (tc_made) tc.deinit();
    }
    if (!c.cfg.chat.telegram) {
        complain("Telegram is off in config.ini; use harness chat", .{});
        return .failed;
    }
    const token = c.secrets.telegram orelse {
        complain("no bot token stored under \"{s}\"; run: harness secret add {s}", .{ c.cfg.chat.token, c.cfg.chat.token });
        return .failed;
    };
    tc.init(app.gpa, app.io, c, c.cfg.chat.api, token) catch {
        complain("the Telegram api url in config.ini is not valid", .{});
        return .failed;
    };
    tc_made = true;
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
        const ups = tc.poll.getUpdates(a, offset, 50) catch |e| {
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
                    tc.answer(cb.id);
                    c.handleCallback(cb.from_id, cb.data);
                },
            }
        }
        // a /reload among those messages may have changed the api url
        _ = tc.refresh() catch |e| complain("telegram: {s}", .{@errorName(e)});
    }
}

// ---- terminal ----

const TermChan = struct {
    io: Io,
    mutex: Io.Mutex = .init,

    fn channel(tc: *TermChan) core_mod.Channel {
        return .{ .ctx = tc, .send = send, .buttons = buttons, .clear = clear };
    }

    fn send(ctx: *anyopaque, text: []const u8) anyerror!void {
        const tc: *TermChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        try outPrint(tc.io, "{s}\n", .{text});
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
        // where harness last left the log, so a cut end is found too
        var sbuf: [512]u8 = undefined;
        const expect = if (Io.Dir.cwd().readFile(app.io, p.status, &sbuf)) |got| log_mod.statusLogHash(got) else |_| null;
        const r = log_mod.check(app.io, app.arena, p.log, expect) catch |e| {
            complain("can't read {s}: {s}", .{ p.log, @errorName(e) });
            return .failed;
        };
        try outPrint(app.io, "{s}\n", .{r.text});
        return if (r.ok) .ok else .failed;
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

// ---- tests ----

const t = std.testing;
const model = @import("model.zig");

/// Frees nothing until `deinit` and fills what is freed with 0xaa first: a
/// pointer kept into freed memory reads garbage, every time.
const Quarantine = struct {
    child: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    freed: std.ArrayList(Block) = .empty,

    const Block = struct { mem: []u8, alignment: std.mem.Alignment };

    fn allocator(q: *Quarantine) std.mem.Allocator {
        return .{ .ptr = q, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn deinit(q: *Quarantine) void {
        for (q.freed.items) |b| q.child.rawFree(b.mem, b.alignment, @returnAddress());
        q.freed.deinit(q.child);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const q: *Quarantine = @ptrCast(@alignCast(ctx));
        return q.child.rawAlloc(len, alignment, ret);
    }

    // never in place: growing goes through alloc, copy and free
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const q: *Quarantine = @ptrCast(@alignCast(ctx));
        @memset(mem, 0xaa);
        q.mutex.lockUncancelable(t.io);
        defer q.mutex.unlock(t.io);
        q.freed.append(q.child, .{ .mem = mem, .alignment = alignment }) catch q.child.rawFree(mem, alignment, ret);
    }
};

/// A data folder whose config.ini points the model, search and Telegram at
/// the fake server.
fn testHome(e: *model.TestEnv) ![]const u8 {
    const a = e.arena.allocator();
    const home = try std.fs.path.join(a, &.{ e.dir, "home" });
    try core_mod.initHome(t.io, a, home);
    const p = try core_mod.Paths.init(a, home);
    const url = try e.url();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.config, .data = try std.fmt.allocPrint(a, "[model]\nurl = {s}\n[search]\nurl = {s}\n[chat]\napi = {s}\n", .{ url, url, url }) });
    return home;
}

test "a_telegram_bot_keeps_its_server_after_reload" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var q: Quarantine = .{ .child = t.allocator };
    defer q.deinit();
    const c = try Core.open(q.allocator(), t.io, try testHome(&e), .{ .telegram = "123:abc" });
    defer c.close();
    // made from the settings, as `harness run` makes its bots
    var bot = try telegram.Bot.init(t.allocator, t.io, c.cfg.chat.api, "123:abc");
    defer bot.deinit();
    // /reload frees the settings the bot was made from
    try t.expectEqualStrings("Settings reloaded.", try c.reload());
    try t.expectEqualStrings("127.0.0.1", bot.http.target.host);
    try bot.send(42, "after the reload");
    try t.expect(std.mem.indexOf(u8, try telegram.outbox(&e), "after the reload") != null);
}

test "telegram_send_before_pairing_is_an_error" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const c = try Core.open(t.allocator, t.io, try testHome(&e), .{ .telegram = "123:abc" });
    var tc: TgChan = undefined;
    tc.init(t.allocator, t.io, c, c.cfg.chat.api, "123:abc") catch |err| {
        c.close();
        return err;
    };
    defer {
        c.close();
        tc.deinit();
    }
    const ch = tc.channel();
    try t.expectError(error.NotPaired, ch.send(ch.ctx, "hello, anyone?"));
    try t.expectEqual(0, std.mem.count(u8, try telegram.outbox(&e), "hello, anyone?"));
}

test "telegram_bots_follow_a_changed_api_after_reload" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var moved: model.TestEnv = undefined;
    try moved.init();
    defer moved.deinit();
    const a = e.arena.allocator();
    const c = try Core.open(t.allocator, t.io, try testHome(&e), .{ .telegram = "123:abc" });
    var tc: TgChan = undefined;
    tc.init(t.allocator, t.io, c, c.cfg.chat.api, "123:abc") catch |err| {
        c.close();
        return err;
    };
    defer {
        c.close();
        tc.deinit();
    }
    c.attach(tc.channel());
    try c.setOwner(42);
    try t.expect(!try tc.refresh());
    const url = try e.url();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = c.paths.config, .data = try std.fmt.allocPrint(a, "[model]\nurl = {s}\n[chat]\napi = {s}\n", .{ url, try moved.url() }) });
    try t.expectEqualStrings("Settings reloaded.", try c.reload());
    try t.expect(try tc.refresh());
    try t.expectEqualStrings(try moved.url(), tc.poll.api);
    c.say("sent after the move");
    try t.expect(std.mem.indexOf(u8, try telegram.outbox(&moved), "sent after the move") != null);
    try t.expect(std.mem.indexOf(u8, try telegram.outbox(&e), "sent after the move") == null);
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
    _ = @import("page.zig");
    _ = @import("totp.zig");
    _ = @import("logins.zig");
    _ = @import("cdp.zig");
    _ = @import("web.zig");
}
