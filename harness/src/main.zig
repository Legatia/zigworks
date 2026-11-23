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
const session = @import("session.zig");
const history_mod = @import("history.zig");
const remote = @import("remote.zig");
const folders = @import("folders.zig");
const inbox_mod = @import("inbox.zig");
const model = @import("model.zig");
const oauth = @import("oauth.zig");
const scrub = @import("scrub.zig");
const undo_mod = @import("undo.zig");
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
    \\  trigger list | test NAME | run NAME
    \\                             the triggers (triggers.ini, tasks, briefs); a poll
    \\                             now that keeps nothing; a poll now and its action
    \\  workflow list | check FILE | start NAME [TEXT] | stop NAME#N|NAME
    \\                             the workflows and their instances; harness's
    \\                             reading of a file; an instance started and run
    \\                             here until it waits; one stopped
    \\  memory [list|pin|unpin|forget ID]
    \\  snapshot list FOLDER | take FOLDER [LABEL] | changes FOLDER ID | restore FOLDER ID
    \\                             a folder's snapshots, one now, what changed, put it back
    \\  undo RUN                   take back the files run RUN changed
    \\  env list | check NAME | rm NAME | key NAME
    \\                             where commands can run (environments.ini): list them,
    \\                             try one, remove one's home; a remote's own SSH key
    \\                             and its host key, kept once you confirm it
    \\  agent list | show NAME | rm NAME
    \\                             the agent definitions (agents/); rm keeps
    \\                             the file in state/agents/NAME/versions/
    \\  log verify                 check the action log's chain
    \\  log tail [N]               print the last N log lines (default 20)
    \\  log runs [N]               a line per run, the last N (default 20)
    \\  log session RID [--json]   a run and its helpers, step by step
    \\  log search WORDS           earlier turns with every word, newest first
    \\                             (an argument with spaces is a phrase)
    \\  app list | approve NAME | rm NAME
    \\                             the apps in apps/: list them, serve one as its files
    \\                             are now, remove one with its data
    \\  mcp list                   the MCP servers in mcp.ini: kind, sign-in and tools
    \\  mcp login NAME             sign in to a server with login = oauth (prints a link)
    \\  mcp logout NAME            forget a server's sign-in
    \\  inbox [--json]             what waits for you (--json: every item kept, format v1)
    \\  health                     exit 0 if `harness run` is running and recent
    \\  version | help
    \\
    \\The data folder is --home (anywhere on the line), else HARNESS_HOME, else
    \\~/.local/share/harness (%LOCALAPPDATA%\harness on Windows). Arguments a
    \\command does not take are refused. Secrets go to the macOS Keychain,
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
    /// Where this folder's secrets are kept (`prepareStore`).
    store_cache: ?store_mod.Store = null,

    fn defaultHome(app: *App) ![]const u8 {
        if (app.env.get("HARNESS_HOME")) |h| if (h.len > 0) return h;
        return app.builtinHome();
    }

    /// The folder harness uses with no --home and no HARNESS_HOME.
    fn builtinHome(app: *App) ![]const u8 {
        if (builtin.os.tag == .windows) {
            const base = app.env.get("LOCALAPPDATA") orelse return error.NoHomeDirectory;
            return std.fs.path.join(app.arena, &.{ base, "harness" });
        }
        if (app.env.get("XDG_DATA_HOME")) |x| if (x.len > 0) return std.fs.path.join(app.arena, &.{ x, "harness" });
        const home = app.env.get("HOME") orelse return error.NoHomeDirectory;
        return std.fs.path.join(app.arena, &.{ home, ".local", "share", "harness" });
    }

    /// Works out where this folder's secrets are kept: HARNESS_STORE=DIR as
    /// given; the Keychain or the Credential Manager under the folder's own
    /// namespace (the built-in folder, and any an earlier harness used, keep
    /// the one every earlier harness used); elsewhere DATA/secrets.
    fn prepareStore(app: *App) !void {
        app.store_cache = try store_mod.forFolder(app.io, app.arena, builtin.os.tag, app.env.get("HARNESS_STORE"), app.home, app.isDefaultHome());
    }

    /// Whether `home` is the folder harness uses with no --home and no
    /// HARNESS_HOME.
    fn isDefaultHome(app: *App) bool {
        const d = app.builtinHome() catch return false;
        return samePath(app.io, app.arena, app.home, d);
    }

    fn store(app: *App) store_mod.Store {
        return app.store_cache.?;
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
            const why = (core_mod.parseProblem(app.arena, p, text, config.parse) catch null) orelse "it has an error";
            complain("{s}", .{why});
            return error.Reported;
        };
    }

    fn secrets(app: *App, cfg: config.Config) core_mod.Secrets {
        const s = app.store();
        // the providers' key names ([provider omnigate] may rename omnigate's)
        const set = model.Providers.resolve(app.arena, config.providerSettings(cfg), model.no_keys) catch model.Providers{ .list = &.{} };
        return .{
            .omnigate = s.get(app.io, app.arena, if (set.find("omnigate")) |p| p.key_name else cfg.model.key) catch null,
            .telegram = s.get(app.io, app.arena, cfg.chat.token) catch null,
            .search = s.get(app.io, app.arena, cfg.search.key) catch null,
            .named = app.namedSecrets(s, set),
        };
    }

    /// The MCP servers' secrets, those folders.ini's vars name, the
    /// logins' passwords and TOTP seeds, and every provider's key but
    /// omnigate's (masked in all tool output; an agent definition may name
    /// any provider).
    fn namedSecrets(app: *App, s: store_mod.Store, providers: model.Providers) []const core_mod.Secrets.Named {
        var out: std.ArrayList(core_mod.Secrets.Named) = .empty;
        for (providers.list) |p| {
            if (std.mem.eql(u8, p.name, "omnigate") or p.auth == .none) continue;
            const known = for (out.items) |n| {
                if (std.mem.eql(u8, n.name, p.key_name)) break true;
            } else false;
            if (known) continue;
            const v = (s.get(app.io, app.arena, p.key_name) catch null) orelse continue;
            out.append(app.arena, .{ .name = p.key_name, .value = v }) catch {};
        }
        out.appendSlice(app.arena, app.mcpSecrets(s)) catch {};
        out.appendSlice(app.arena, app.folderSecrets(s)) catch {};
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

    /// The stored secrets folders.ini's `vars` name.
    fn folderSecrets(app: *App, s: store_mod.Store) []const core_mod.Secrets.Named {
        const p = std.fs.path.join(app.arena, &.{ app.home, "folders.ini" }) catch return &.{};
        const text = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20)) catch return &.{};
        const f = folders.parse(app.arena, text) catch return &.{};
        var out: std.ArrayList(core_mod.Secrets.Named) = .empty;
        for (f.sections) |sec| for (sec.vars) |v| {
            const value = (s.get(app.io, app.arena, v.secret) catch null) orelse continue;
            out.append(app.arena, .{ .name = v.secret, .value = value }) catch {};
        };
        return out.items;
    }

    /// The stored secrets the servers in mcp.ini name: their programs'
    /// variables, their tokens, and their sign-ins' tokens and client.
    fn mcpSecrets(app: *App, s: store_mod.Store) []const core_mod.Secrets.Named {
        const p = std.fs.path.join(app.arena, &.{ app.home, "mcp.ini" }) catch return &.{};
        const text = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20)) catch return &.{};
        const cfgs = mcp.parseConfig(app.arena, text) catch return &.{};
        var out: std.ArrayList(core_mod.Secrets.Named) = .empty;
        for (cfgs) |sc| {
            for (sc.secrets) |es| {
                const v = (s.get(app.io, app.arena, es.secret) catch null) orelse continue;
                out.append(app.arena, .{ .name = es.secret, .value = v }) catch {};
            }
            if (sc.token.len > 0) if (s.get(app.io, app.arena, sc.token) catch null) |v| out.append(app.arena, .{ .name = sc.token, .value = v }) catch {};
            if (sc.login) {
                var nb: [40]u8 = undefined;
                const name = app.arena.dupe(u8, mcp.signinSecret(&nb, sc.name)) catch continue;
                const tk = (oauth.load(app.io, app.arena, s, name) catch null) orelse continue;
                for (tk.secrets(app.arena, name) catch continue) |x| out.append(app.arena, .{ .name = x.name, .value = x.value }) catch {};
            }
        }
        return out.items;
    }

    /// What a command opens the instance for (in the status file; only
    /// `run` counts for `harness health`).
    const Role = enum {
        run,
        chat,
        brief,
        task,
        memory,
        snapshot,
        undo,
        env,
        app,
        agent,
        trigger,
        workflow,

        /// Whether it needs the MCP servers and the browser: a brief is
        /// one model call without tools, memory, snapshot, env, app and
        /// agent commands make none, and starting servers for them costs
        /// up to 20 s and runs their code.
        fn usesTools(r: Role) bool {
            return switch (r) {
                .run, .chat, .task, .trigger, .workflow => true,
                .brief, .memory, .snapshot, .undo, .env, .app, .agent => false,
            };
        }
    };

    /// Opens the instance, or explains why not.
    fn open(app: *App, role: Role) !*Core {
        const cfg = try app.settings();
        const sec = app.secrets(cfg);
        // each provider in use without its key or url, said once
        const set = try model.Providers.resolve(app.arena, config.providerSettings(cfg), .{ .ctx = @constCast(&sec), .get = startKey });
        for (try startNotes(app.arena, &set, &.{ cfg.model.model, cfg.model.worker_model, cfg.model.memory_model })) |n| complain("{s}", .{n});
        if (try voiceStartNote(app.arena, &set, cfg.voice.provider)) |n| complain("{s}", .{n});
        const c = Core.open(app.gpa, app.io, app.home, sec) catch |e| {
            switch (e) {
                error.AlreadyRunning => complain("harness is already running on {s}; talk to it there (or stop it first)", .{app.home}),
                error.BadUrl => complain("the omnigate url in config.ini ([model] url) is {s}", .{if (cfg.model.url.len == 0) "not set yet" else "not valid"}),
                error.BadSettings => {
                    const paths = core_mod.Paths.init(app.arena, app.home) catch return error.Reported;
                    const stored = core_mod.secretList(app.arena, sec) catch &.{};
                    const why = (core_mod.settingsProblemWith(app.io, app.arena, paths, stored) catch null) orelse "a settings file has an error, or one of config.ini, rules, logins.ini, mcp.ini, folders.ini, triggers.ini, environments.ini and workflows/ can be changed by other users (chmod 600 the files, chmod go-w the folder)";
                    complain("{s}", .{why});
                },
                else => complain("can't open {s}: {s}", .{ app.home, @errorName(e) }),
            }
            return error.Reported;
        };
        c.path_var = app.env.get("PATH") orelse c.path_var;
        c.home_var = app.env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "";
        c.system_vars = util.pickVars(app.arena, app.env, util.system_var_names) catch &.{};
        c.store = app.store();
        c.role = @tagName(role);
        c.writeStatus() catch {};
        // Ctrl-C and kill end it the way /stop and close do (from here on,
        // so a slow start of the MCP servers can be ended too)
        catchSignals();
        c.watcher = std.Thread.spawn(.{}, watchSignals, .{c}) catch null;
        if (c.watcher != null) watching.store(true, .release);
        if (role.usesTools()) c.startExtras();
        // apps in the browser, for as long as this start runs
        if ((role == .run or role == .chat) and c.cfg.apps.on) {
            if (c.startApps(app.arena)) |url| complain("Apps: {s}   (new each start)", .{url}) else |e| complain("note: the app server didn't start: {s}", .{@errorName(e)});
        }
        var warns = std.mem.tokenizeScalar(u8, c.mcp_warn, '\n');
        while (warns.next()) |w| complain("note: mcp.ini: {s}", .{w});
        if (c.money_ledger.trouble()) |why| complain("note: {s}; money calls are refused until it is fixed", .{why});
        return c;
    }
};

/// The key read at start for `provider` (omnigate's, or one of `named`).
fn startKey(ctx: ?*anyopaque, _: std.mem.Allocator, provider: []const u8, secret: []const u8) ?[]const u8 {
    const sec: *const core_mod.Secrets = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, provider, "omnigate")) return sec.omnigate;
    return sec.get(secret);
}

/// What a command says at start of the providers `values` pick: each one
/// without its key or its url (omnigate's in 0.3's words).
pub fn startNotes(a: std.mem.Allocator, set: *const model.Providers, values: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try set.used(a, values)) |p| {
        if (!p.hasKey()) try out.append(a, try std.fmt.allocPrint(a, "note: no {s} key stored under \"{s}\"; model calls will be refused. Run: harness secret add {s}", .{ p.name, p.key_name, p.key_name }));
        if (p.url.len == 0) {
            const where = if (std.mem.eql(u8, p.name, "omnigate")) "[model] url" else try std.fmt.allocPrint(a, "[provider {s}] url", .{p.name});
            try out.append(a, try std.fmt.allocPrint(a, "note: no {s} url is set ({s} in config.ini); model calls will be refused", .{ p.name, where }));
        }
    }
    return out.items;
}

/// The voice notes' service without its key, said at start; null when
/// none is set or its key is there (or it needs none).
pub fn voiceStartNote(a: std.mem.Allocator, set: *const model.Providers, provider: []const u8) !?[]const u8 {
    const p = set.find(provider) orelse return null;
    if (p.hasKey()) return null;
    return try std.fmt.allocPrint(a, "note: no {s} key stored under \"{s}\"; voice notes will be refused. Run: harness secret add {s}", .{ p.name, p.key_name, p.key_name });
}

pub fn main(init: std.process.Init) u8 {
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const raw = init.minimal.args.toSlice(arena) catch return @intFromEnum(Exit.failed);
    var app: App = .{ .gpa = gpa, .arena = arena, .io = init.io, .env = init.environ_map };
    const cli = parseCli(arena, raw[1..]) catch |e| switch (e) {
        error.Usage => {
            complain("--home takes one folder: harness --home DIR COMMAND (or after the command)", .{});
            return @intFromEnum(Exit.usage);
        },
        error.OutOfMemory => return @intFromEnum(Exit.failed),
    };
    app.home = cli.home orelse app.defaultHome() catch {
        complain("no home folder found; pass --home DIR", .{});
        return @intFromEnum(Exit.failed);
    };
    const code = dispatch(&app, cli.args) catch |e| switch (e) {
        error.Reported => Exit.failed,
        else => blk: {
            complain("{s}", .{@errorName(e)});
            break :blk Exit.failed;
        },
    };
    return @intFromEnum(code);
}

fn dispatch(app: *App, args: []const []const u8) !Exit {
    if (badArgs(args)) |line| {
        complain("{s}", .{line});
        return .usage;
    }
    if (args.len == 0 or eql(args[0], "help") or eql(args[0], "--help") or eql(args[0], "-h")) {
        try outAll(app.io, usage);
        return if (args.len == 0) .usage else .ok;
    }
    const cmd = args[0];
    const rest = args[1..];
    inline for (.{ "secret", "login", "run", "chat", "brief", "task", "memory", "snapshot", "undo", "env", "app", "agent", "trigger", "workflow", "mcp" }) |c| if (eql(cmd, c)) {
        app.prepareStore() catch |e| {
            complain("can't tell where the secrets of {s} are kept: {s} (state/store-id)", .{ app.home, @errorName(e) });
            return .failed;
        };
    };
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
    if (eql(cmd, "snapshot")) return snapshotCmd(app, rest);
    if (eql(cmd, "undo")) return undoCmd(app, rest);
    if (eql(cmd, "env")) return envCmd(app, rest);
    if (eql(cmd, "agent")) return agentCmd(app, rest);
    if (eql(cmd, "trigger")) return triggerCmd(app, rest);
    if (eql(cmd, "workflow")) return workflowCmd(app, rest);
    if (eql(cmd, "mcp")) return mcpCmd(app, rest);
    if (eql(cmd, "log")) return logCmd(app, rest);
    if (eql(cmd, "app")) return appCmd(app, rest);
    if (eql(cmd, "inbox")) return inboxCmd(app, rest);
    if (eql(cmd, "health")) return healthCmd(app);
    complain("unknown command {s}; see harness help", .{cmd});
    return .usage;
}

fn initCmd(app: *App) !Exit {
    // a folder made now gets a namespace of its own in the system's key
    // store before it has files: one with files and no state/store-id is
    // taken for a folder an earlier harness used (store.namespace)
    store_mod.claimNamespace(app.io, app.arena, builtin.os.tag, app.home, app.isDefaultHome()) catch |e| {
        complain("can't tell where the secrets of {s} are kept: {s} (state/store-id)", .{ app.home, @errorName(e) });
        return .failed;
    };
    try core_mod.initHome(app.io, app.arena, app.home);
    try outPrint(app.io,
        \\Data folder: {s}
        \\Next:
        \\  1. Set the omnigate url (there is none by default) and route names in config.ini,
        \\     or another provider: [model] provider (README: Models and providers).
        \\  2. harness secret add omnigate     (your omnigate key; another provider's under its name)
        \\  3. harness secret add telegram     (the bot token from @BotFather)
        \\  4. harness secret add search       (optional: Brave Search API key)
        \\  5. harness run, then harness pair, then send /pair CODE to the bot.
        \\
    , .{app.home});
    return .ok;
}

/// a-z, 0-9, - and _, starting with a letter or digit (so an option like
/// `--stdin` is never taken for a name).
fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    if (!(std.ascii.isLower(n[0]) or std.ascii.isDigit(n[0]))) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn secretCmd(app: *App, args: []const []const u8) !Exit {
    const sa = secretArgs(args) orelse {
        complain(secret_usage, .{});
        return .usage;
    };
    const s = app.store();
    if (sa.op == .list) {
        const cfg = try app.settings();
        for ([_][2][]const u8{ .{ "model key", cfg.model.key }, .{ "bot token", cfg.chat.token }, .{ "search key", cfg.search.key } }) |pair| {
            const v = s.get(app.io, app.arena, pair[1]) catch null;
            try outPrint(app.io, "{s} ({s}): {s}\n", .{ pair[1], pair[0], if (v != null) "stored" else "not stored" });
        }
        // the keys of the other providers in use or with a section
        const set = try model.Providers.resolve(app.arena, config.providerSettings(cfg), model.no_keys);
        const used = try set.used(app.arena, &.{ cfg.model.model, cfg.model.worker_model, cfg.model.memory_model });
        const voice_service = set.find(cfg.voice.provider);
        for (set.list) |*p| {
            if (std.mem.eql(u8, p.name, "omnigate") or p.auth == .none) continue;
            const has_section = for (cfg.providers) |sec| {
                if (std.mem.eql(u8, sec.name, p.name)) break true;
            } else false;
            if (std.mem.indexOfScalar(*const model.Provider, used, p) == null and !has_section and voice_service != p) continue;
            const v = s.get(app.io, app.arena, p.key_name) catch null;
            try outPrint(app.io, "{s} ({s} key): {s}\n", .{ p.key_name, p.name, if (v != null) "stored" else "not stored" });
        }
        const p = try std.fs.path.join(app.arena, &.{ app.home, "mcp.ini" });
        if (Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20))) |text| {
            const cfgs = mcp.parseConfig(app.arena, text) catch &.{};
            for (cfgs) |sc| {
                for (sc.secrets) |es| {
                    const v = s.get(app.io, app.arena, es.secret) catch null;
                    try outPrint(app.io, "{s} (MCP {s}): {s}\n", .{ es.secret, sc.name, if (v != null) "stored" else "not stored" });
                }
                if (sc.token.len > 0) {
                    const v = s.get(app.io, app.arena, sc.token) catch null;
                    try outPrint(app.io, "{s} (MCP {s} token): {s}\n", .{ sc.token, sc.name, if (v != null) "stored" else "not stored" });
                }
                if (sc.login) {
                    var nb: [40]u8 = undefined;
                    const name = mcp.signinSecret(&nb, sc.name);
                    const v = s.get(app.io, app.arena, name) catch null;
                    if (v != null)
                        try outPrint(app.io, "{s} (MCP {s} sign-in): stored\n", .{ name, sc.name })
                    else
                        try outPrint(app.io, "{s} (MCP {s} sign-in): not stored (harness mcp login {s})\n", .{ name, sc.name, sc.name });
                }
            }
        } else |_| {}
        return .ok;
    }
    if (!validName(sa.name)) {
        complain("secret names use a-z, 0-9, - and _, start with a letter or digit, and have at most 64 characters", .{});
        return .usage;
    }
    const name = sa.name;
    if (sa.op == .rm) {
        const gone = s.remove(app.io, name) catch {
            complain("could not remove {s}", .{name});
            return .failed;
        };
        try outPrint(app.io, "{s}\n", .{if (gone) "Removed." else "Nothing stored under that name."});
        return .ok;
    }
    const from_stdin = sa.stdin;
    const stdin = Io.File.stdin();
    const tty = stdin.isTty(app.io) catch false;
    if (Echo.msysTerminal(stdin) or (tty and !Echo.canHide(stdin))) {
        complain("{s}", .{would_show});
        return .usage;
    }
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
    var why_buf: [200]u8 = undefined;
    if (valueProblem(&why_buf, s, value.len)) |why| {
        complain("{s}", .{why});
        return .failed;
    }
    s.put(app.io, name, value) catch {
        complain("could not store the value in {s}", .{s.describe()});
        return .failed;
    };
    try errPrint(app.io, "Stored {s} in {s}.\n", .{ name, s.describe() });
    return .ok;
}

/// Why a value of `len` bytes is not stored, or null: too short to mask,
/// or longer than the store keeps (the Credential Manager: 2560 bytes).
fn valueProblem(buf: []u8, s: store_mod.Store, len: usize) ?[]const u8 {
    if (len < 8) return "values shorter than 8 characters can't be masked reliably; nothing stored";
    if (s.maxValue()) |m| if (len > m)
        return std.fmt.bufPrint(buf, "{s} keeps at most {d} bytes of a value and this one has {d}; nothing stored", .{ s.describe(), m, len }) catch "the value is longer than the store keeps; nothing stored";
    return null;
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
        var gone: [3]bool = .{ false, false, false };
        for ([_]logins.Kind{ .password, .totp, .passkeys }, &gone) |k, *g| {
            var nb: [96]u8 = undefined;
            // the passkeys may be in parts (store.Store.putLong)
            const secret = logins.secretName(&nb, name, k);
            g.* = (if (k == .passkeys) s.removeLong(app.io, app.arena, secret) else s.remove(app.io, secret)) catch {
                complain("could not remove the secrets of {s}", .{name});
                return .failed;
            };
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
        const said = try removedText(app.arena, name, known, gone, had_profile) orelse {
            try outAll(app.io, "No login with that name.\n");
            return .ok;
        };
        try outPrint(app.io, "{s}\n", .{said});
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
        complain("--site takes a host name in lowercase with at least one dot, like github.com, or localhost (no https://, no port, no path)", .{});
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
    if (Echo.msysTerminal(stdin) or (tty and !Echo.canHide(stdin))) {
        complain("{s}", .{would_show});
        return .usage;
    }
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
    try errPrint(app.io, "{s}\n", .{try addedText(app.arena, name, site, password.len > 0, seed.len > 0, s.describe())});
    return .ok;
}

/// What `login add` says it did.
fn addedText(a: std.mem.Allocator, name: []const u8, site: []const u8, password: bool, totp_seed: bool, store: []const u8) ![]const u8 {
    const head = try std.fmt.allocPrint(a, "Added {s} to logins.ini (site {s}).", .{ name, site });
    if (password and totp_seed) return std.fmt.allocPrint(a, "{s} Stored its password and TOTP secret in {s}.", .{ head, store });
    if (password) return std.fmt.allocPrint(a, "{s} Stored its password in {s}; no TOTP secret.", .{ head, store });
    if (totp_seed) return std.fmt.allocPrint(a, "{s} Stored its TOTP secret in {s}; no password: the agent makes one when it signs up.", .{ head, store });
    return std.fmt.allocPrint(a, "{s} Nothing stored: no password (the agent makes one when it signs up), no TOTP secret.", .{head});
}

/// What `login rm` says it removed (`secrets`: the password, the TOTP
/// secret, the passkeys); null when there was nothing to remove.
fn removedText(a: std.mem.Allocator, name: []const u8, entry: bool, secrets: [3]bool, profile: bool) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (entry) try parts.append(a, "its entry in logins.ini");
    for (secrets, [_][]const u8{ "its password", "its TOTP secret", "its passkeys" }) |g, what| if (g) try parts.append(a, what);
    if (profile) try parts.append(a, "its browser profile");
    if (parts.items.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    if (entry) try out.print(a, "Removed {s}: ", .{name}) else try out.print(a, "Removed what was left of {s} (it had no entry in logins.ini): ", .{name});
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, if (i == parts.items.len - 1) " and " else ", ");
        try out.appendSlice(a, p);
    }
    try out.append(a, '.');
    return out.items;
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
        return .{ .ctx = tc, .send = send, .buttons = buttons, .clear = clear, .edit = edit, .send_to = sendTo, .document = document, .open_topic = openTopic, .file = file };
    }

    /// A file a message carried (a voice note): getFile, then the file,
    /// through a bot of its own, so a download never holds up a send.
    fn file(ctx: *anyopaque, a: std.mem.Allocator, file_id: []const u8, max: usize) anyerror![]u8 {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        const api = blk: {
            tc.mutex.lockUncancelable(tc.io);
            defer tc.mutex.unlock(tc.io);
            break :blk try a.dupe(u8, tc.send_bot.api);
        };
        var bot = try telegram.Bot.init(tc.gpa, tc.io, api, tc.token);
        defer bot.deinit();
        const f = try bot.getFile(a, file_id);
        if (f.size > max) return error.TooLarge;
        return bot.download(a, f.path, max);
    }

    fn sendTo(ctx: *anyopaque, chat_id: i64, text: []const u8) anyerror!void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        try tc.send_bot.send(chat_id, text);
    }

    /// To the place's chat and topic; a topic Telegram refuses is
    /// error.TopicRefused (core then posts to main).
    fn send(ctx: *anyopaque, place: core_mod.Place, text: []const u8) anyerror!core_mod.Sent {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        if (place.chat == 0) return error.NotPaired;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        const sent = tc.send_bot.sendTo(place.chat, place.thread, text, .{ .quiet = place.quiet }) catch |e| {
            complain("telegram: sending failed: {s}", .{@errorName(e)});
            return if (e == error.TelegramRefused and place.thread != 0) error.TopicRefused else e;
        };
        return .{ .first = sent.first, .count = sent.count };
    }

    fn buttons(ctx: *anyopaque, place: core_mod.Place, text: []const u8, bs: []const [2][]const u8) ?i64 {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        if (place.chat == 0) return null;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        return tc.send_bot.sendButtonsTo(place.chat, place.thread, text, bs, .{ .quiet = place.quiet }) catch null;
    }

    fn clear(ctx: *anyopaque, place: core_mod.Place, id: i64) void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        if (place.chat == 0) return;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.clearButtons(place.chat, id) catch {};
    }

    /// An item's message once it closed: its text and the outcome, no buttons.
    fn edit(ctx: *anyopaque, place: core_mod.Place, id: i64, text: []const u8) void {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        if (place.chat == 0) return;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.editText(place.chat, id, text) catch {};
    }

    fn document(ctx: *anyopaque, place: core_mod.Place, name: []const u8, data: []const u8) anyerror!i64 {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        if (place.chat == 0) return error.NotPaired;
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        return tc.send_bot.sendDocumentAs(place.chat, place.thread, name, data, .{ .quiet = place.quiet }) catch |e| {
            complain("telegram: sending a file failed: {s}", .{@errorName(e)});
            return if (e == error.TelegramRefused and place.thread != 0) error.TopicRefused else e;
        };
    }

    fn openTopic(ctx: *anyopaque, chat: i64, name: []const u8) anyerror!i64 {
        const tc: *TgChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        return tc.send_bot.createForumTopic(chat, name);
    }

    /// Takes a button press, so Telegram stops showing it as pending.
    fn answer(tc: *TgChan, callback_id: []const u8) void {
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        tc.send_bot.answer(callback_id) catch {};
    }
};

/// One update from Telegram: a message (text, or a voice note) or a press.
fn takeUpdate(c: *Core, tc: *TgChan, u: telegram.Update) void {
    switch (u) {
        .message => |m| if (m.text.len > 0 or m.voice != null) c.handleIncoming(.{
            .from = m.from_id,
            .chat = m.chat_id,
            .chat_type = m.chat_type,
            .thread = m.thread,
            .topic = m.topic,
            .text = m.text,
            .reply_to = m.reply_to,
            .voice = m.voice,
        }) catch |e| complain("handling a message: {s}", .{@errorName(e)}),
        .callback => |cb| {
            tc.answer(cb.id);
            c.handleCallbackText(cb.from_id, cb.chat_id, cb.thread, cb.message_id, cb.data, cb.text);
        },
    }
}

fn ticker(c: *Core) void {
    while (!c.quitting.load(.acquire)) {
        c.tick();
        var i: u32 = 0;
        while (i < 50 and !c.quitting.load(.acquire)) : (i += 1) c.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

fn runCmd(app: *App) !Exit {
    const c = try app.open(.run);
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
    // the bot's name (a command may end in @ and it) and whether topics are on
    {
        var me_arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer me_arena.deinit();
        if (tc.poll.getMe(me_arena.allocator())) |me| c.setBot(me.username, me.topics) else |e|
            complain("telegram: getMe failed ({s}); topics are taken to be on", .{@errorName(e)});
    }
    try c.startWorker();
    // triggers are polled where harness runs
    c.poller_on = true;
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
            takeUpdate(c, &tc, u);
        }
        // a /reload among those messages may have changed the api url
        _ = tc.refresh() catch |e| complain("telegram: {s}", .{@errorName(e)});
    }
}

// ---- terminal ----

/// The terminal: every post is printed, with its conversation's name in
/// front when it is not this terminal's own.
const TermChan = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    /// The conversation printed without its name: `terminal` for `harness
    /// chat`, a brief's or task's `to` for `brief` and `task run`.
    home: []const u8 = "terminal",

    fn channel(tc: *TermChan) core_mod.Channel {
        return .{ .ctx = tc, .send = send, .buttons = buttons, .clear = clear, .document = document };
    }

    /// "[NAME] " for a post that is not for this terminal's conversation.
    fn tag(tc: *const TermChan, buf: []u8, place: core_mod.Place) []const u8 {
        if (std.mem.eql(u8, place.name, tc.home)) return "";
        return std.fmt.bufPrint(buf, "[{s}] ", .{util.cut(place.name, 40)}) catch "";
    }

    fn send(ctx: *anyopaque, place: core_mod.Place, text: []const u8) anyerror!core_mod.Sent {
        const tc: *TermChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        var tb: [48]u8 = undefined;
        try outPrint(tc.io, "{s}{s}\n", .{ tc.tag(&tb, place), text });
        return .{};
    }

    fn buttons(ctx: *anyopaque, place: core_mod.Place, text: []const u8, bs: []const [2][]const u8) ?i64 {
        const tc: *TermChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        var tb: [48]u8 = undefined;
        // /inbox's Show buttons: the list says it all here
        if (bs.len > 0 and bs[0][1].len > 0 and bs[0][1][0] == 's') {
            outPrint(tc.io, "{s}{s}\n", .{ tc.tag(&tb, place), text }) catch {};
            return 0;
        }
        // quick replies: type one (a press is a message here); a run's
        // Undo: typed as /undo RUN
        if (bs.len > 0 and bs[0][1].len > 0 and (bs[0][1][0] == 'r' or bs[0][1][0] == 'u')) {
            outPrint(tc.io, "{s}{s}\n", .{ tc.tag(&tb, place), text }) catch {};
            for (bs) |b| {
                var lb: [64]u8 = undefined;
                outPrint(tc.io, "{s}\n", .{termButton(&lb, b)}) catch {};
            }
            return 0;
        }
        // only the answers this question has: money has no 24 h
        var buf: [128]u8 = undefined;
        outPrint(tc.io, "{s}{s}\n{s}\n", .{ tc.tag(&tb, place), text, keysLine(&buf, bs) }) catch {};
        return 0;
    }

    fn clear(ctx: *anyopaque, place: core_mod.Place, id: i64) void {
        _ = ctx;
        _ = place;
        _ = id;
    }

    /// A file can't be shown here: its name and size are.
    fn document(ctx: *anyopaque, place: core_mod.Place, name: []const u8, data: []const u8) anyerror!i64 {
        const tc: *TermChan = @ptrCast(@alignCast(ctx));
        tc.mutex.lockUncancelable(tc.io);
        defer tc.mutex.unlock(tc.io);
        var tb: [48]u8 = undefined;
        try outPrint(tc.io, "{s}file {s} ({d} bytes)\n", .{ tc.tag(&tb, place), name, data.len });
        return 0;
    }
};

/// How the terminal shows a post's button: a quick reply to type
/// ("  > Yes"), or a run's Undo as its command ("/undo 41").
fn termButton(buf: []u8, b: [2][]const u8) []const u8 {
    if (undo_mod.runOf(b[1])) |run| return std.fmt.bufPrint(buf, "/undo {d}", .{run}) catch "/undo";
    return std.fmt.bufPrint(buf, "  > {s}", .{util.cut(b[0], buf.len - 4)}) catch b[0];
}

/// The keys for an item's buttons ("[o] allow once  [n] deny"): an
/// approval's by what each answers, another item's by their place
/// ("[1] personal  [2] work").
fn keysLine(buf: []u8, bs: []const [2][]const u8) []const u8 {
    var n: usize = 0;
    const places = "1234";
    for (bs, 0..) |b, i| {
        if (b[0].len == 0) continue;
        const key: []const u8 = if (std.mem.endsWith(u8, b[1], ":once")) "o" else if (std.mem.endsWith(u8, b[1], ":day")) "d" else if (std.mem.endsWith(u8, b[1], ":deny")) "n" else places[@min(i, 3) .. @min(i, 3) + 1];
        const part = std.fmt.bufPrint(buf[n..], "{s}[{s}] {c}{s}", .{ if (n > 0) "  " else "", key, std.ascii.toLower(b[0][0]), b[0][1..] }) catch break;
        n += part.len;
    }
    return buf[0..n];
}

/// Windows: a line that is only Ctrl-D (and Enter) leaves the chat too, as
/// Ctrl-D does elsewhere; a console delivers it as a character.
fn leaves(line: []const u8) bool {
    return builtin.os.tag == .windows and std.mem.eql(u8, line, "\x04");
}

fn chatCmd(app: *App) !Exit {
    const c = try app.open(.chat);
    defer c.close();
    var tc: TermChan = .{ .io = app.io };
    c.attach(tc.channel());
    try c.startWorker();
    c.poller_on = true;
    const tick_thread = try std.Thread.spawn(.{}, ticker, .{c});
    defer tick_thread.join();
    defer c.quitting.store(true, .release);
    // a Windows console ends input with Ctrl-Z and Enter; Ctrl-D is a character there
    try errAll(app.io, if (builtin.os.tag == .windows)
        "harness chat. /help for commands, /stop to stop, Ctrl-Z and Enter to leave.\n"
    else
        "harness chat. /help for commands, /stop to stop, Ctrl-D to leave.\n");
    const stdin = Io.File.stdin();
    var ended = false;
    while (!ended) {
        const line = try readLineEof(app, stdin, &ended);
        if (leaves(line)) break;
        if (line.len == 0) continue;
        // an item's answer: o, d, n or 1 to 4, with its id when several wait
        var said_arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer said_arena.deinit();
        if (c.terminalAnswer(said_arena.allocator(), line)) |said| {
            if (said.len > 0) try errPrint(app.io, "{s}\n", .{said});
            continue;
        }
        try c.handleTextIn("terminal", line);
    }
    // no one is left to answer: the question waiting, and any after it, is Deny
    c.closeQuestions();
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
    const c = try app.open(.brief);
    defer c.close();
    var tc: TermChan = .{ .io = app.io };
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
    tc.home = b.to;
    c.attach(tc.channel());
    _ = try c.runBrief(b);
    return .ok;
}

fn taskCmd(app: *App, args: []const []const u8) !Exit {
    if (args.len != 2 or !eql(args[0], "run")) {
        complain("usage: harness task run NAME", .{});
        return .usage;
    }
    const c = try app.open(.task);
    defer c.close();
    var tc: TermChan = .{ .io = app.io };
    const tk = for (c.tasks) |tk| {
        if (eql(tk.name, args[1])) break tk;
    } else {
        complain("no task called {s}", .{args[1]});
        return .failed;
    };
    tc.home = tk.to;
    c.attach(tc.channel());
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
    const c = try app.open(.memory);
    defer c.close();
    try outPrint(app.io, "{s}\n", .{try c.command(app.arena, text)});
    return .ok;
}

const snapshot_usage = "usage: harness snapshot list FOLDER | take FOLDER [LABEL] | changes FOLDER ID | restore FOLDER ID";

/// Whether a `harness snapshot` line has what its action takes.
fn snapshotArgsOk(rest: []const []const u8) bool {
    if (rest.len == 0) return false;
    const op = rest[0];
    if (eql(op, "list")) return rest.len == 2;
    if (eql(op, "take")) return rest.len >= 2;
    if (eql(op, "changes") or eql(op, "restore")) return rest.len == 3;
    return false;
}

/// `harness snapshot ...`: the chat's snapshot commands, as `harness memory`.
fn snapshotCmd(app: *App, args: []const []const u8) !Exit {
    if (!snapshotArgsOk(args)) {
        complain(snapshot_usage, .{});
        return .usage;
    }
    const op = args[0];
    const command = if (eql(op, "list")) "/snapshots" else if (eql(op, "take")) "/snapshot" else if (eql(op, "changes")) "/changes" else "/restore";
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(app.arena, command);
    for (args[1..]) |w| try text.print(app.arena, " {s}", .{w});
    const c = try app.open(.snapshot);
    defer c.close();
    try outPrint(app.io, "{s}\n", .{try c.command(app.arena, text.items)});
    return .ok;
}

const undo_usage = "usage: harness undo RUN (a run's number)";

/// `harness undo RUN`: the chat's /undo RUN, holding the data folder as
/// `harness snapshot restore` does (so not while `harness run` holds it).
fn undoCmd(app: *App, args: []const []const u8) !Exit {
    const c = try app.open(.undo);
    defer c.close();
    try outPrint(app.io, "{s}\n", .{try c.command(app.arena, try std.fmt.allocPrint(app.arena, "/undo {s}", .{args[0]}))});
    return .ok;
}

const env_usage = "usage: harness env list | env check NAME | env rm NAME | env key NAME";

fn envArgsOk(rest: []const []const u8) bool {
    if (rest.len == 1) return eql(rest[0], "list");
    if (rest.len == 2) return eql(rest[0], "check") or eql(rest[0], "rm") or eql(rest[0], "key");
    return false;
}

/// `harness env ...`: the chat's /envs and /env commands, as `harness
/// memory`; `env key` is here alone, since it asks you in the terminal.
fn envCmd(app: *App, args: []const []const u8) !Exit {
    if (!envArgsOk(args)) {
        complain(env_usage, .{});
        return .usage;
    }
    if (eql(args[0], "key")) return envKeyCmd(app, args[1]);
    const text = if (eql(args[0], "list")) "/envs" else try std.fmt.allocPrint(app.arena, "/env {s} {s}", .{ args[0], args[1] });
    const c = try app.open(.env);
    defer c.close();
    try outPrint(app.io, "{s}\n", .{try c.command(app.arena, text)});
    return .ok;
}

/// `harness env key NAME`: a remote's own key (made once, in its folder),
/// the line that authorizes it there, and its host key, kept once you
/// have compared its fingerprint with the machine's own.
fn envKeyCmd(app: *App, name: []const u8) !Exit {
    const c = try app.open(.env);
    defer c.close();
    const e = c.env_list.find(name) orelse {
        complain("no environment {s} in environments.ini (harness env list)", .{name});
        return .failed;
    };
    if (e.kind != .remote) {
        complain("{s} is a sandbox; keys are for remotes", .{name});
        return .failed;
    }
    const dir = try std.fs.path.join(app.arena, &.{ c.paths.env_dir, name });
    const key = remote.makeKey(app.io, app.arena, name, dir) catch |err| {
        complain("can't make its key: {s} (OpenSSH's ssh-keygen is needed)", .{@errorName(err)});
        return .failed;
    };
    if (key.made) try c.log.write(.config, false, .{ .event = "env key made", .name = name, .fingerprint = key.fingerprint });
    try outPrint(app.io, "{s}'s key{s}: {s}\nPut this line in ~/.ssh/authorized_keys of {s}:\n{s}\n\n", .{ name, if (key.made) " (made now)" else "", key.fingerprint, e.host, key.authorized });
    const hk = remote.scanHost(app.io, app.arena, e, dir, c.path_var, c.system_vars) catch |err| {
        complain("can't ask {s} for its host key: {s}", .{ e.host, @errorName(err) });
        return .failed;
    };
    if (hk.lines.len == 0) {
        complain("{s} (port {d}) gave no host key{s}{s}; run harness env key {s} again when it answers", .{ e.host, e.port, if (hk.why.len > 0) ": " else "", hk.why, name });
        return .failed;
    }
    try outPrint(app.io, "{s} answers with these host keys:\n{s}\nCompare them with the machine's own (there: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub). Keep them? Type yes: ", .{ e.host, hk.fingerprints });
    const answer = readLine(app, Io.File.stdin()) catch "";
    if (!eql(std.mem.trim(u8, answer, " \t\r\n"), "yes")) {
        try outPrint(app.io, "Not kept: commands in {s} are refused until its host key is.\n", .{name});
        return .failed;
    }
    try remote.keepHostKeys(app.io, app.arena, dir, hk.lines);
    try c.log.write(.config, false, .{ .event = "env host key kept", .name = name, .fingerprints = hk.fingerprints });
    try outPrint(app.io, "Kept: {s} accepts only these keys. harness env check {s} tries it.\n", .{ name, name });
    return .ok;
}

const app_usage = "usage: harness app list | app approve NAME | app rm NAME";

fn appArgsOk(rest: []const []const u8) bool {
    if (rest.len == 1) return eql(rest[0], "list");
    if (rest.len == 2) return eql(rest[0], "approve") or eql(rest[0], "rm");
    return false;
}

/// `harness app ...`: the chat's /apps and /app commands.
fn appCmd(app: *App, args: []const []const u8) !Exit {
    if (!appArgsOk(args)) {
        complain(app_usage, .{});
        return .usage;
    }
    const text = if (eql(args[0], "list")) "/apps" else try std.fmt.allocPrint(app.arena, "/app {s} {s}", .{ args[0], args[1] });
    const c = try app.open(.app);
    defer c.close();
    try outPrint(app.io, "{s}\n", .{try c.command(app.arena, text)});
    return .ok;
}

const agent_usage = "usage: harness agent list | agent show NAME | agent rm NAME";

/// The chat command `harness agent ARGS` sends; null when the arguments
/// are not one (in `a`).
fn agentCommandText(a: std.mem.Allocator, args: []const []const u8) !?[]const u8 {
    if (args.len == 1 and eql(args[0], "list")) return "/agents";
    if (args.len != 2 or args[1].len == 0 or args[1][0] == '-') return null;
    if (eql(args[0], "show") or eql(args[0], "rm")) return try std.fmt.allocPrint(a, "/agent {s} {s}", .{ args[0], args[1] });
    return null;
}

fn agentCmd(app: *App, args: []const []const u8) !Exit {
    const text = (try agentCommandText(app.arena, args)) orelse {
        complain(agent_usage, .{});
        return .usage;
    };
    const c = try app.open(.agent);
    defer c.close();
    try outPrint(app.io, "{s}\n", .{std.mem.trimEnd(u8, try c.command(app.arena, text), "\n")});
    return .ok;
}

const trigger_usage = "usage: harness trigger list | trigger test NAME | trigger run NAME";

/// Whether a `harness trigger` line has what its action takes.
fn triggerArgsOk(rest: []const []const u8) bool {
    if (rest.len == 1) return eql(rest[0], "list");
    if (rest.len != 2 or rest[1].len == 0 or rest[1][0] == '-') return false;
    return eql(rest[0], "test") or eql(rest[0], "run");
}

/// `harness trigger list | test NAME | run NAME`: the chat's commands, and
/// a poll now whose action runs here, its posts printed.
fn triggerCmd(app: *App, args: []const []const u8) !Exit {
    if (!triggerArgsOk(args)) {
        complain(trigger_usage, .{});
        return .usage;
    }
    const c = try app.open(.trigger);
    defer c.close();
    if (eql(args[0], "list")) {
        try outPrint(app.io, "{s}\n", .{std.mem.trimEnd(u8, try c.command(app.arena, "/triggers"), "\n")});
        return .ok;
    }
    if (eql(args[0], "test")) {
        try outPrint(app.io, "{s}\n", .{try c.command(app.arena, try std.fmt.allocPrint(app.arena, "/trigger test {s}", .{args[1]}))});
        return .ok;
    }
    var tc: TermChan = .{ .io = app.io };
    tc.home = c.triggerTo(app.arena, args[1]);
    c.attach(tc.channel());
    const said = try c.runTriggerHere(app.arena, args[1]);
    if (said.len > 0) try errPrint(app.io, "{s}\n", .{said});
    return .ok;
}

const workflow_usage = "usage: harness workflow list | workflow check FILE | workflow start NAME [TEXT] | workflow stop NAME#N|NAME";

/// Whether a `harness workflow` line has what its action takes.
fn workflowArgsOk(rest: []const []const u8) bool {
    if (rest.len == 0) return false;
    if (rest.len > 1 and (rest[1].len == 0 or rest[1][0] == '-')) return false;
    if (eql(rest[0], "list")) return rest.len == 1;
    if (eql(rest[0], "check") or eql(rest[0], "stop")) return rest.len == 2;
    if (eql(rest[0], "start")) return rest.len >= 2;
    return false;
}

/// `harness workflow list | check FILE | start NAME [TEXT] | stop ID`: the
/// chat's commands; `check` reads the file without opening the folder; a
/// start runs its instance here until it waits or ends (R18), its posts
/// printed.
fn workflowCmd(app: *App, args: []const []const u8) !Exit {
    if (!workflowArgsOk(args)) {
        complain(workflow_usage, .{});
        return .usage;
    }
    if (eql(args[0], "check")) {
        const text = Io.Dir.cwd().readFileAlloc(app.io, args[1], app.arena, .limited(1 << 20)) catch |e| {
            complain("can't read {s}: {s}", .{ args[1], @errorName(e) });
            return .failed;
        };
        const p = try core_mod.Paths.init(app.arena, app.home);
        const got = try core_mod.checkWorkflowFile(app.io, app.arena, p, args[1], text);
        try outPrint(app.io, "{s}\n", .{got.text});
        return if (got.ok) .ok else .failed;
    }
    const c = try app.open(.workflow);
    defer c.close();
    if (eql(args[0], "list")) {
        try outPrint(app.io, "{s}\n", .{std.mem.trimEnd(u8, try c.command(app.arena, "/workflows"), "\n")});
        return .ok;
    }
    if (eql(args[0], "stop")) {
        try outPrint(app.io, "{s}\n", .{try c.command(app.arena, try std.fmt.allocPrint(app.arena, "/workflow stop {s}", .{args[1]}))});
        return .ok;
    }
    var tc: TermChan = .{ .io = app.io, .home = "main" };
    c.attach(tc.channel());
    const said = try c.command(app.arena, try std.fmt.allocPrint(app.arena, "/workflow start {s}", .{try std.mem.join(app.arena, " ", args[1..])}));
    try errPrint(app.io, "{s}\n", .{said});
    c.driveWorkflows();
    return if (std.mem.startsWith(u8, said, "Not started")) .failed else .ok;
}

// ---- MCP servers ----

const mcp_usage = "usage: harness mcp list | mcp login NAME | mcp logout NAME";

fn mcpArgsOk(rest: []const []const u8) bool {
    if (rest.len == 1 and eql(rest[0], "list")) return true;
    // an option is never a server's name
    if (rest.len == 2 and (eql(rest[0], "login") or eql(rest[0], "logout"))) return mcp.validName(rest[1]) and rest[1][0] != '-';
    return false;
}

fn mcpCmd(app: *App, args: []const []const u8) !Exit {
    if (!mcpArgsOk(args)) {
        complain(mcp_usage, .{});
        return .usage;
    }
    const s = app.store();
    const p = try std.fs.path.join(app.arena, &.{ app.home, "mcp.ini" });
    const text: []const u8 = Io.Dir.cwd().readFileAlloc(app.io, p, app.arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const cfgs = mcp.parseConfig(app.arena, text) catch {
        const why = (core_mod.parseProblem(app.arena, "mcp.ini", text, mcp.parseConfig) catch null) orelse "mcp.ini has an error";
        complain("{s}", .{why});
        return .failed;
    };
    if (eql(args[0], "list")) {
        if (cfgs.len == 0) {
            try outAll(app.io, "No MCP servers: mcp.ini has none.\n");
            return .ok;
        }
        try outAll(app.io, try mcpListText(app.gpa, app.arena, app.io, cfgs, .{
            .store = s,
            .home = app.home,
            .path_var = app.env.get("PATH") orelse "",
            .home_var = app.env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "",
            .system_vars = util.pickVars(app.arena, app.env, util.system_var_names) catch &.{},
        }));
        return .ok;
    }
    const name = args[1];
    var nb: [40]u8 = undefined;
    const secret = mcp.signinSecret(&nb, name);
    if (eql(args[0], "logout")) {
        const gone = s.removeLong(app.io, app.gpa, secret) catch {
            complain("could not remove the sign-in of {s} from {s}", .{ name, s.describe() });
            return .failed;
        };
        try outPrint(app.io, "{s}\n", .{if (gone) try std.fmt.allocPrint(app.arena, "Signed out of {s}.", .{name}) else try std.fmt.allocPrint(app.arena, "{s} was not signed in.", .{name})});
        return .ok;
    }
    const sc = for (cfgs) |c| {
        if (eql(c.name, name)) break c;
    } else {
        complain("mcp.ini has no server {s}", .{name});
        return .failed;
    };
    if (!sc.login) {
        complain("{s} does not sign in: set login = oauth in [{s}] in mcp.ini", .{ name, name });
        return .failed;
    }
    var show: LinkShow = .{ .app = app, .name = name };
    var said: []const u8 = "";
    const tokens = oauth.login(app.gpa, app.io, app.arena, .{
        .name = name,
        .url = sc.url,
        .headers = sc.headers,
        .client_id = sc.client_id,
        .scope = sc.scope,
        .link = .{ .ctx = &show, .f = LinkShow.f },
    }, &said) catch |e| {
        complain("{s}", .{if (said.len > 0) said else @errorName(e)});
        return .failed;
    };
    oauth.save(app.io, app.gpa, s, secret, tokens) catch |e| {
        complain("could not keep the sign-in in {s}: {s}", .{ s.describe(), @errorName(e) });
        return .failed;
    };
    try outPrint(app.io, "Signed in to {s}. Its tokens are kept as the secret {s} ({s}).\nA harness that is running takes them at its next request to {s}; /reload starts {s} if it did not start.\n", .{ name, secret, s.describe(), name, name });
    return .ok;
}

/// Prints the sign-in's link (never opens it).
const LinkShow = struct {
    app: *App,
    name: []const u8,

    fn f(ctx: ?*anyopaque, link: []const u8, port: u16) void {
        const ls: *LinkShow = @ptrCast(@alignCast(ctx.?));
        outPrint(ls.app.io, "To sign in to {s}, open this link in a browser on this machine within 5 minutes:\n\n{s}\n\nNo browser here? Forward the port first (ssh -L {d}:127.0.0.1:{d} to this machine), then open the link where you are.\n", .{ ls.name, link, port, port }) catch {};
    }
};

/// What `mcp list` starts the servers with.
const McpListEnv = struct {
    store: store_mod.Store,
    /// The data folder: a program starts in state/mcp/NAME.
    home: []const u8,
    path_var: []const u8,
    home_var: []const u8,
    system_vars: []const util.Var,
    /// All the starts end by then.
    start_ms: u32 = 20_000,
};

/// One server of `mcp list`, started on a thread of its own.
const McpProbe = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cfg: mcp.ServerConfig,
    env: *const McpListEnv,
    deadline_ns: i128 = 0,
    label: []const u8 = "",
    /// What to do instead, when it was not started.
    skipped: ?[]const u8 = null,
    values: []const []const u8 = &.{},
    auth: mcp.Auth = .none,
    dir: []const u8 = "",
    srv: ?*mcp.Server = null,
    err: anyerror = error.NotStarted,
    diag: mcp.Diag = .{},

    fn run(p: *McpProbe) void {
        p.srv = mcp.Server.start(p.gpa, p.io, p.cfg, .{
            .cwd = p.dir,
            .path_var = p.env.path_var,
            .home = p.env.home_var,
            .system_vars = p.env.system_vars,
            .secret_values = p.values,
            .deadline_ns = p.deadline_ns,
            .diag = &p.diag,
            .auth = p.auth,
        }) catch |e| {
            p.err = e;
            return;
        };
    }
};

/// `harness mcp list`: each server, its kind, its sign-in, and its tools
/// when it can be reached (programs are started for it, then stopped);
/// masked.
fn mcpListText(gpa: std.mem.Allocator, a: std.mem.Allocator, io: Io, cfgs: []const mcp.ServerConfig, env: McpListEnv) ![]const u8 {
    const st = env.store;
    var shown: std.ArrayList(scrub.Secret) = .empty;
    const probes = try a.alloc(McpProbe, cfgs.len);
    const threads = try a.alloc(?std.Thread, cfgs.len);
    const deadline = Io.Clock.awake.now(io).nanoseconds + @as(i96, env.start_ms) * std.time.ns_per_ms;
    for (cfgs, probes, threads) |sc, *p, *th| {
        p.* = .{ .gpa = gpa, .io = io, .cfg = sc, .env = &env, .deadline_ns = deadline };
        th.* = null;
        switch (mcp.kindOf(sc)) {
            .program => {
                p.label = "program";
                const values = try a.alloc([]const u8, sc.secrets.len);
                for (sc.secrets, values) |es, *v| v.* = (st.get(io, a, es.secret) catch null) orelse {
                    p.skipped = try std.fmt.allocPrint(a, "secret {s} is not stored: harness secret add {s}", .{ es.secret, es.secret });
                    break;
                };
                // one missing: the values after it were never read
                if (p.skipped != null) continue;
                for (sc.secrets, values) |es, v| try shown.append(a, .{ .name = es.secret, .value = v });
                p.values = values;
                p.dir = mcpServerDir(io, a, env.home, sc.name) catch |e| {
                    p.skipped = try std.fmt.allocPrint(a, "its folder can't be made ({s})", .{@errorName(e)});
                    continue;
                };
            },
            .token => {
                const v = (st.get(io, a, sc.token) catch null) orelse {
                    p.label = try std.fmt.allocPrint(a, "token {s}, not stored", .{sc.token});
                    p.skipped = try std.fmt.allocPrint(a, "harness secret add {s}", .{sc.token});
                    continue;
                };
                p.label = try std.fmt.allocPrint(a, "token {s}, stored", .{sc.token});
                p.auth = .{ .token = .{ .name = sc.token, .value = v } };
                try shown.append(a, .{ .name = sc.token, .value = v });
            },
            .signin => {
                var nb: [40]u8 = undefined;
                const secret = try a.dupe(u8, mcp.signinSecret(&nb, sc.name));
                const tk = (oauth.load(io, a, st, secret) catch null) orelse {
                    p.label = "sign-in, not signed in";
                    p.skipped = try std.fmt.allocPrint(a, "harness mcp login {s}", .{sc.name});
                    continue;
                };
                p.label = "sign-in, signed in";
                p.auth = .{ .signin = .{ .store = st } };
                try shown.appendSlice(a, try tk.secrets(a, secret));
            },
            .url => p.label = "url",
        }
        if (p.skipped != null) continue;
        th.* = std.Thread.spawn(.{}, McpProbe.run, .{p}) catch blk: {
            p.run();
            break :blk null;
        };
    }
    for (threads) |th| if (th) |x| x.join();
    var out: std.ArrayList(u8) = .empty;
    var started: std.ArrayList(*mcp.Server) = .empty;
    for (probes) |*p| {
        const name = p.cfg.name;
        if (p.skipped) |why| {
            try out.print(a, "{s} ({s}): {s}\n", .{ name, p.label, why });
            continue;
        }
        const srv = p.srv orelse {
            if (p.cfg.url.len > 0)
                try out.print(a, "{s} ({s}): not reached: {s}\n", .{ name, p.label, if (p.diag.len > 0) p.diag.text() else @errorName(p.err) })
            else
                try out.print(a, "{s} ({s}): did not start ({s}) {s}\n", .{ name, p.label, @errorName(p.err), util.cut(p.diag.text(), 200) });
            continue;
        };
        try started.append(a, srv);
        try out.print(a, "{s} ({s}): {d} tools\n", .{ name, p.label, srv.tools().len });
        for (srv.tools()) |tl| {
            const desc = std.mem.trim(u8, tl.description[0 .. std.mem.indexOfAny(u8, tl.description, "\r\n") orelse tl.description.len], " \t");
            try out.print(a, "  {s}/{s}{s}{s}\n", .{ name, tl.name, if (desc.len > 0) "  " else "", util.cut(desc, 100) });
        }
    }
    mcp.stopAll(started.items);
    if (shown.items.len == 0) return out.items;
    var sc_mask = try scrub.Scrubber.init(a, shown.items);
    return sc_mask.scrubAlloc(a, out.items);
}

/// state/mcp/NAME (0700): a program's own folder, as `harness run` makes it.
fn mcpServerDir(io: Io, a: std.mem.Allocator, home: []const u8, name: []const u8) ![]const u8 {
    const base = try std.fs.path.join(a, &.{ home, "state", "mcp" });
    const dir = try std.fs.path.join(a, &.{ base, name });
    try Io.Dir.cwd().createDirPath(io, dir);
    if (builtin.os.tag != .windows) for ([_][]const u8{ base, dir }) |d| {
        var h = try Io.Dir.cwd().openDir(io, d, .{ .iterate = true });
        defer h.close(io);
        try h.setPermissions(io, .fromMode(0o700));
    };
    return dir;
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
    if (args.len >= 1 and eql(args[0], "runs")) {
        const n = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 20 else 20;
        const text = Io.Dir.cwd().readFileAlloc(app.io, p.log, app.arena, .limited(256 << 20)) catch |e| {
            complain("can't read {s}: {s}", .{ p.log, @errorName(e) });
            return .failed;
        };
        try outAll(app.io, try session.runsText(app.arena, text, n));
        return .ok;
    }
    if (args.len >= 2 and eql(args[0], "session")) {
        const rid = std.fmt.parseInt(u64, args[1], 10) catch {
            complain("usage: harness log session RID [--json] (RID: a run's id, as harness log runs lists it)", .{});
            return .usage;
        };
        const text = Io.Dir.cwd().readFileAlloc(app.io, p.log, app.arena, .limited(256 << 20)) catch |e| {
            complain("can't read {s}: {s}", .{ p.log, @errorName(e) });
            return .failed;
        };
        if (args.len == 3) {
            const lines = try session.raw(app.arena, text, rid);
            if (lines.len == 0) {
                complain("no run {d} in {s}", .{ rid, p.log });
                return .failed;
            }
            try outAll(app.io, lines);
            return .ok;
        }
        const shown = (try session.render(app.arena, text, rid, 0)) orelse {
            complain("no run {d} in {s}", .{ rid, p.log });
            return .failed;
        };
        try outAll(app.io, shown);
        return .ok;
    }
    if (args.len >= 2 and eql(args[0], "search")) {
        // dates in the owner's time, as config.ini says (UTC without it)
        const offset: i32 = blk: {
            const text = Io.Dir.cwd().readFileAlloc(app.io, p.config, app.arena, .limited(1 << 20)) catch break :blk 0;
            break :blk (config.parse(app.arena, text) catch break :blk 0).chat.utc_offset;
        };
        const shown = history_mod.searchText(app.arena, app.io, p.log, args[1..], offset) catch |e| {
            complain("can't read {s}: {s}", .{ p.log, @errorName(e) });
            return .failed;
        } orelse {
            complain("usage: harness log search WORDS (a phrase in double quotes, or an argument with spaces)", .{});
            return .usage;
        };
        try outPrint(app.io, "{s}\n", .{shown});
        return .ok;
    }
    complain("usage: harness log verify | log tail [N] | log runs [N] | log session RID [--json] | log search WORDS", .{});
    return .usage;
}

/// `harness inbox [--json]`: reads state/inbox only, so it works while
/// harness runs.
fn inboxCmd(app: *App, args: []const []const u8) !Exit {
    const p = try core_mod.Paths.init(app.arena, app.home);
    var box: inbox_mod.Box = .init(app.gpa, app.io, p.inbox);
    defer box.deinit();
    box.load("") catch |e| {
        complain("can't read {s}: {s}", .{ p.inbox, @errorName(e) });
        return .failed;
    };
    try outAll(app.io, try inboxText(app.arena, &box, args.len == 1, util.nowSeconds(app.io)));
    return .ok;
}

/// What `harness inbox` prints: a line per open item (or that nothing
/// waits); with `json`, every item kept in format v1, a line each.
fn inboxText(a: std.mem.Allocator, box: *const inbox_mod.Box, json: bool, now_s: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (box.items.items) |it| {
        if (json) {
            try inbox_mod.render(&out, a, it, false);
            try out.append(a, '\n');
        } else if (it.status == .open) try out.print(a, "{s}\n", .{try inbox_mod.listLine(a, it, now_s)});
    }
    if (!json and out.items.len == 0) return "Nothing is waiting for you.\n";
    return out.items;
}

fn healthCmd(app: *App) !Exit {
    const p = try core_mod.Paths.init(app.arena, app.home);
    var buf: [256]u8 = undefined;
    const h = core_mod.health(app.io, p, util.nowSeconds(app.io), &buf);
    try outPrint(app.io, "{s}\n", .{h.text});
    return if (h.ok) .ok else .failed;
}

// ---- ending on a signal ----

/// The signal that asked harness to end; 0 until one came. On Windows the
/// console event plus one.
var got_signal: std.atomic.Value(u32) = .init(0);

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    // all a handler may do: the watcher does the rest. A second signal ends
    // the process the default way (SA.RESETHAND).
    got_signal.store(@intFromEnum(sig), .release);
}

const console = struct {
    const CTRL_C_EVENT = 0;
    const CTRL_BREAK_EVENT = 1;
    const CTRL_CLOSE_EVENT = 2;
    const CTRL_LOGOFF_EVENT = 5;
    const CTRL_SHUTDOWN_EVENT = 6;
    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) std.os.windows.BOOL, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

    /// Runs on a thread of its own, not in a signal context.
    fn handler(event: u32) callconv(.winapi) std.os.windows.BOOL {
        // a second Ctrl-C: end now
        if (got_signal.swap(event + 1, .acq_rel) != 0) std.process.exit(1);
        // after close, logoff and shutdown Windows ends the process when
        // this returns: give the watcher its time (it exits the process)
        if (event == CTRL_CLOSE_EVENT or event == CTRL_LOGOFF_EVENT or event == CTRL_SHUTDOWN_EVENT) Sleep(4500);
        return .TRUE;
    }
};

/// SIGINT and SIGTERM (Windows: the console's Ctrl-C, Ctrl-Break and
/// close) no longer end the process on the spot, leaving approved commands
/// running in their own process groups and the folder held.
fn catchSignals() void {
    if (builtin.os.tag == .windows) {
        _ = console.SetConsoleCtrlHandler(console.handler, .TRUE);
        return;
    }
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART | std.posix.SA.RESETHAND,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn signalName(n: u32) []const u8 {
    if (builtin.os.tag == .windows) return switch (n -| 1) {
        console.CTRL_C_EVENT => "Ctrl-C",
        console.CTRL_BREAK_EVENT => "Ctrl-Break",
        console.CTRL_CLOSE_EVENT => "console closed",
        console.CTRL_LOGOFF_EVENT => "logoff",
        console.CTRL_SHUTDOWN_EVENT => "shutdown",
        else => "console event",
    };
    if (n == @intFromEnum(std.posix.SIG.INT)) return "SIGINT";
    if (n == @intFromEnum(std.posix.SIG.TERM)) return "SIGTERM";
    return "signal";
}

/// Beside the command until the core closes: on a signal, runs the stop
/// and the end (Core.endBySignal), then ends the process.
fn watchSignals(c: *Core) void {
    while (true) {
        const n = got_signal.load(.acquire);
        if (n != 0) {
            c.endBySignal(signalName(n));
            std.process.exit(0);
        }
        if (c.quitting.load(.acquire)) {
            watching.store(false, .release);
            return;
        }
        c.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
}

/// watchSignals runs: a signal ends the process there.
var watching: std.atomic.Value(bool) = .init(false);

/// A signal has come, or comes within half a second (Windows can break a
/// read off a moment before the handler's thread has run).
fn signalComing(io: Io) bool {
    var waited: u32 = 0;
    while (waited <= 500) : (waited += 20) {
        if (got_signal.load(.acquire) != 0) return true;
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    return false;
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
            else => {
                // Windows breaks a console read off when Ctrl-C comes or the
                // console closes (STATUS_ALERTED, error.Unexpected to Zig).
                // The signal's own path ends harness then (watchSignals):
                // wait for it, rather than end in an error trace beside it.
                if (watching.load(.acquire) and signalComing(app.io)) while (true) app.io.sleep(.fromMilliseconds(1000), .awake) catch {};
                return e;
            },
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

/// Why a secret is not read at a terminal that can't hide it (Windows).
const would_show = "this terminal would show what you type (Git Bash and other MSYS terminals do): type it in a Windows console (cmd, PowerShell, Windows Terminal), or pipe it in with --stdin; nothing stored";

/// Terminal echo, off while a value is typed.
const Echo = struct {
    /// What to put back; null when nothing was changed.
    saved: Saved,
    file: Io.File,
    const Saved = if (builtin.os.tag == .windows) ?u32 else ?std.posix.termios;
    const k32 = struct {
        extern "kernel32" fn GetConsoleMode(h: std.os.windows.HANDLE, mode: *u32) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn SetConsoleMode(h: std.os.windows.HANDLE, mode: u32) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn GetFileType(h: std.os.windows.HANDLE) callconv(.winapi) u32;
        extern "kernel32" fn GetFileInformationByHandleEx(h: std.os.windows.HANDLE, class: c_int, info: *anyopaque, size: u32) callconv(.winapi) std.os.windows.BOOL;
    };

    /// Windows: whether `f` is the terminal of an MSYS or Cygwin program,
    /// as Git Bash's mintty gives one: a pipe named \msys-…-ptyN-… or
    /// \cygwin-…-ptyN-… (what is typed there shows, whatever we do).
    fn msysTerminal(f: Io.File) bool {
        if (builtin.os.tag != .windows) return false;
        if (k32.GetFileType(f.handle) != 3) return false; // FILE_TYPE_PIPE
        // FILE_NAME_INFO: the name's length in bytes, then the name (UTF-16)
        var info: [4 + 2 * 260]u8 align(4) = undefined;
        if (!k32.GetFileInformationByHandleEx(f.handle, 2, &info, info.len).toBool()) return false; // FileNameInfo
        const len = std.mem.readInt(u32, info[0..4], .little);
        if (len > info.len - 4) return false;
        var wide: [260]u16 = undefined;
        const n = len / 2;
        for (0..n) |i| wide[i] = std.mem.readInt(u16, info[4 + 2 * i ..][0..2], .little);
        return msysPtyName(wide[0..n]);
    }

    fn msysPtyName(name: []const u16) bool {
        const L = std.unicode.utf8ToUtf16LeStringLiteral;
        return (std.mem.startsWith(u16, name, L("\\msys-")) or std.mem.startsWith(u16, name, L("\\cygwin-"))) and
            std.mem.indexOf(u16, name, L("-pty")) != null;
    }

    /// Whether what is typed at the terminal `f` can be kept off the
    /// screen. Windows: a console can; the terminals of Git Bash and other
    /// MSYS or Cygwin programs (mintty) can't, since their input reaches us
    /// through a pipe the console API can't switch the echo off for.
    fn canHide(f: Io.File) bool {
        if (builtin.os.tag != .windows) return true;
        var mode: u32 = 0;
        return k32.GetConsoleMode(f.handle, &mode).toBool();
    }

    fn off(f: Io.File) Echo {
        if (builtin.os.tag == .windows) {
            var mode: u32 = 0;
            if (!k32.GetConsoleMode(f.handle, &mode).toBool()) return .{ .saved = null, .file = f };
            if (!k32.SetConsoleMode(f.handle, mode & ~@as(u32, 0x0004)).toBool()) return .{ .saved = null, .file = f }; // ENABLE_ECHO_INPUT
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
            if (e.saved) |mode| _ = k32.SetConsoleMode(e.file.handle, mode);
            return;
        }
        if (e.saved) |old| std.posix.tcsetattr(e.file.handle, .FLUSH, old) catch {};
    }
};

/// The command line without the global options. `--home DIR` (or
/// `--home=DIR`) counts wherever it is, so `harness init --home X` and
/// `harness login rm NAME --home X` act on X.
const Cli = struct { home: ?[]const u8 = null, args: []const []const u8 };

fn parseCli(a: std.mem.Allocator, raw: []const []const u8) error{ Usage, OutOfMemory }!Cli {
    var out: std.ArrayList([]const u8) = .empty;
    var home: ?[]const u8 = null;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];
        const value = if (eql(arg, "--home")) blk: {
            i += 1;
            if (i >= raw.len) return error.Usage;
            break :blk raw[i];
        } else if (std.mem.startsWith(u8, arg, "--home=")) arg["--home=".len..] else {
            try out.append(a, arg);
            continue;
        };
        // a folder, not the next option; and one only
        if (value.len == 0 or value[0] == '-' or home != null) return error.Usage;
        home = value;
    }
    return .{ .home = home, .args = out.items };
}

const secret_usage = "usage: harness secret add NAME [--stdin] | secret rm NAME | secret list";
const login_usage = "usage: harness login add NAME --site HOST [--username U] [--stdin] | login list | login rm NAME";

const SecretArgs = struct {
    op: enum { add, rm, list },
    name: []const u8 = "",
    stdin: bool = false,
};

/// `secret add NAME [--stdin]` (the option before or after the name),
/// `secret rm NAME`, `secret list`; null for anything else.
fn secretArgs(rest: []const []const u8) ?SecretArgs {
    if (rest.len == 0) return null;
    var out: SecretArgs = .{ .op = std.meta.stringToEnum(@FieldType(SecretArgs, "op"), rest[0]) orelse return null };
    var names: usize = 0;
    for (rest[1..]) |arg| {
        if (eql(arg, "--stdin") and out.op == .add and !out.stdin) {
            out.stdin = true;
            continue;
        }
        // an option it does not take; no name starts with "-"
        if (arg.len > 0 and arg[0] == '-') return null;
        names += 1;
        out.name = arg;
    }
    return switch (out.op) {
        .list => if (names == 0) out else null,
        .add, .rm => if (names == 1) out else null,
    };
}

/// The usage line when a command's arguments are wrong, else null: extra
/// or unknown arguments are refused, never ignored.
fn badArgs(args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    const cmd = args[0];
    const rest = args[1..];
    inline for (.{ "help", "--help", "-h", "version", "init", "pair", "run", "chat", "health" }) |c| {
        if (eql(cmd, c)) return if (rest.len == 0) null else "usage: harness " ++ c ++ " (it takes no arguments)";
    }
    if (eql(cmd, "brief")) return if (rest.len <= 1) null else "usage: harness brief [NAME]";
    if (eql(cmd, "task")) return if (rest.len == 2 and eql(rest[0], "run")) null else "usage: harness task run NAME";
    if (eql(cmd, "memory")) {
        if (rest.len == 0 or (rest.len == 1 and eql(rest[0], "list"))) return null;
        if (rest.len == 2) for ([_][]const u8{ "pin", "unpin", "forget" }) |op| if (eql(rest[0], op)) return null;
        return "usage: harness memory [list|pin|unpin|forget ID]";
    }
    if (eql(cmd, "log")) {
        if (rest.len == 1 and eql(rest[0], "verify")) return null;
        if (rest.len >= 1 and (eql(rest[0], "tail") or eql(rest[0], "runs"))) {
            if (rest.len == 1) return null;
            if (rest.len == 2 and (std.fmt.parseInt(usize, rest[1], 10) catch null) != null) return null;
        }
        if (rest.len >= 2 and eql(rest[0], "session") and (std.fmt.parseInt(u64, rest[1], 10) catch null) != null) {
            if (rest.len == 2) return null;
            if (rest.len == 3 and eql(rest[2], "--json")) return null;
        }
        if (rest.len >= 2 and eql(rest[0], "search")) return null;
        return "usage: harness log verify | log tail [N] | log runs [N] | log session RID [--json] | log search WORDS";
    }
    if (eql(cmd, "app")) return if (appArgsOk(rest)) null else app_usage;
    if (eql(cmd, "agent")) {
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        return if ((agentCommandText(fba.allocator(), rest) catch null) == null) agent_usage else null;
    }
    if (eql(cmd, "inbox")) return if (rest.len == 0 or (rest.len == 1 and eql(rest[0], "--json"))) null else "usage: harness inbox [--json]";
    if (eql(cmd, "trigger")) return if (triggerArgsOk(rest)) null else trigger_usage;
    if (eql(cmd, "workflow")) return if (workflowArgsOk(rest)) null else workflow_usage;
    if (eql(cmd, "mcp")) return if (mcpArgsOk(rest)) null else mcp_usage;
    if (eql(cmd, "secret")) return if (secretArgs(rest) == null) secret_usage else null;
    if (eql(cmd, "snapshot")) return if (snapshotArgsOk(rest)) null else snapshot_usage;
    if (eql(cmd, "undo")) return if (rest.len == 1 and (std.fmt.parseInt(u64, rest[0], 10) catch null) != null) null else undo_usage;
    if (eql(cmd, "env")) return if (envArgsOk(rest)) null else env_usage;
    if (eql(cmd, "login")) {
        if (rest.len == 0) return login_usage;
        if (eql(rest[0], "list") and rest.len != 1) return login_usage;
        if (eql(rest[0], "rm") and rest.len != 2) return login_usage;
        // an option is never a login's name (`login add --stdin x` is no login "--stdin")
        if (rest.len >= 2 and rest[1].len > 0 and rest[1][0] == '-') return login_usage;
        // `login add` checks its own options
        return null;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether two paths name the same folder: their real paths when they
/// exist, else the paths made absolute (case ignored where the file system
/// usually does).
fn samePath(io: Io, a: std.mem.Allocator, x: []const u8, y: []const u8) bool {
    const rx = absolute(io, a, x) orelse return false;
    const ry = absolute(io, a, y) orelse return false;
    if (builtin.os.tag == .macos or builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(rx, ry);
    return std.mem.eql(u8, rx, ry);
}

fn absolute(io: Io, a: std.mem.Allocator, p: []const u8) ?[]const u8 {
    if (Io.Dir.cwd().realPathFileAlloc(io, p, a)) |r| return r else |_| {}
    if (std.fs.path.isAbsolute(p)) return std.fs.path.resolve(a, &.{p}) catch null;
    const cwd = Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch return null;
    return std.fs.path.resolve(a, &.{ cwd, p }) catch null;
}

const t = std.testing;

test "global_options_count_anywhere_on_the_line" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c1 = try parseCli(a, &.{ "init", "--home", "/x" });
    try t.expectEqualStrings("/x", c1.home.?);
    try t.expectEqual(1, c1.args.len);
    try t.expectEqualStrings("init", c1.args[0]);
    const c2 = try parseCli(a, &.{ "login", "rm", "victim", "--home", "other" });
    try t.expectEqualStrings("other", c2.home.?);
    try t.expectEqual(3, c2.args.len);
    try t.expectEqualStrings("victim", c2.args[2]);
    const c3 = try parseCli(a, &.{ "--home=/y", "run" });
    try t.expectEqualStrings("/y", c3.home.?);
    try t.expectEqualStrings("run", c3.args[0]);
    const c4 = try parseCli(a, &.{ "--home", "/z", "chat" });
    try t.expectEqualStrings("/z", c4.home.?);
    try t.expectEqual(1, c4.args.len);
    try t.expectEqual(null, (try parseCli(a, &.{"health"})).home);
    // no folder, or two
    try t.expectError(error.Usage, parseCli(a, &.{ "run", "--home" }));
    try t.expectError(error.Usage, parseCli(a, &.{ "run", "--home", "--stdin" }));
    try t.expectError(error.Usage, parseCli(a, &.{ "--home", "a", "run", "--home", "b" }));
    try t.expectError(error.Usage, parseCli(a, &.{ "run", "--home=" }));
}

test "extra_or_unknown_arguments_are_refused" {
    const bad = [_][]const []const u8{
        &.{ "init", "x" },              &.{ "run", "x" },               &.{ "chat", "now" },
        &.{ "pair", "x" },              &.{ "health", "x" },            &.{ "version", "x" },
        &.{ "help", "x" },              &.{ "brief", "a", "b" },        &.{ "task", "run" },
        &.{ "task", "run", "a", "b" },  &.{ "task", "go", "a" },        &.{ "memory", "list", "x" },
        &.{ "memory", "pin" },          &.{ "memory", "drop", "m" },    &.{ "log" },
        &.{ "log", "verify", "x" },     &.{ "log", "tail", "x" },       &.{ "log", "tail", "5", "6" },
        &.{ "secret" },                 &.{ "secret", "list", "x" },    &.{ "secret", "rm" },
        &.{ "secret", "rm", "a", "b" }, &.{ "secret", "add", "a", "b" }, &.{ "secret", "add", "a", "--x" },
        &.{ "secret", "rm", "a", "--stdin" }, &.{ "secret", "add", "--stdin" }, &.{ "login", "list", "x" },
        &.{ "login", "rm", "a", "b" },  &.{ "login", "rm", "-x" },      &.{ "login", "add", "--stdin", "x", "--site", "a.org" },
    };
    for (bad) |line| if (badArgs(line) == null) {
        printLine("accepted:", line);
        return error.TestUnexpectedResult;
    };
    const good = [_][]const []const u8{
        &.{"init"},                     &.{"run"},                       &.{"brief"},
        &.{ "brief", "morning" },       &.{ "task", "run", "x" },        &.{"memory"},
        &.{ "memory", "list" },         &.{ "memory", "forget", "m-1" }, &.{ "log", "verify" },
        &.{ "log", "tail" },            &.{ "log", "tail", "5" },        &.{ "secret", "list" },
        &.{ "secret", "add", "a" },     &.{ "secret", "add", "a", "--stdin" }, &.{ "secret", "add", "--stdin", "a" },
        &.{ "secret", "rm", "a" },      &.{ "login", "list" },           &.{ "login", "rm", "a" },
        &.{ "login", "add", "a", "--site", "x.org" }, &.{"help"},         &.{"version"},
        &.{"nonsense"}, // unknown commands are refused by dispatch
    };
    for (good) |line| if (badArgs(line)) |why| {
        printLine("refused:", line);
        std.debug.print("  {s}\n", .{why});
        return error.TestUnexpectedResult;
    };
}

test "agent_takes_list_show_and_rm" {
    for ([_][]const []const u8{ &.{"agent"}, &.{ "agent", "list", "x" }, &.{ "agent", "show" }, &.{ "agent", "rm" }, &.{ "agent", "rm", "a", "b" }, &.{ "agent", "drop", "a" }, &.{ "agent", "show", "-x" } }) |line| if (badArgs(line) == null) {
        printLine("accepted:", line);
        return error.TestUnexpectedResult;
    };
    for ([_][]const []const u8{ &.{ "agent", "list" }, &.{ "agent", "show", "researcher" }, &.{ "agent", "rm", "researcher" } }) |line| if (badArgs(line)) |why| {
        printLine("refused:", line);
        std.debug.print("  {s}\n", .{why});
        return error.TestUnexpectedResult;
    };
    // the commands they send in chat
    try t.expectEqualStrings("/agents", (try agentCommandText(t.allocator, &.{"list"})).?);
    const show = (try agentCommandText(t.allocator, &.{ "show", "researcher" })).?;
    defer t.allocator.free(show);
    try t.expectEqualStrings("/agent show researcher", show);
    try t.expect(!App.Role.agent.usesTools());
    try t.expect(std.mem.indexOf(u8, usage, "agent list | show NAME | rm NAME") != null);
}

test "names_start_with_a_letter_or_digit" {
    try t.expect(validName("omnigate"));
    try t.expect(validName("login-bot-password"));
    try t.expect(validName("2fa_seed"));
    try t.expect(!validName("--stdin"));
    try t.expect(!validName("-x"));
    try t.expect(!validName("_x"));
    try t.expect(!validName(""));
    try t.expect(!validName("Upper"));
    // `secret add --stdin foo` stores foo
    const sa = secretArgs(&.{ "add", "--stdin", "foo" }).?;
    try t.expectEqualStrings("foo", sa.name);
    try t.expect(sa.stdin);
}

test "sigterm_is_caught_and_noted_not_the_end_of_the_process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    got_signal.store(0, .release);
    catchSignals();
    defer {
        const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &dfl, null);
        std.posix.sigaction(.TERM, &dfl, null);
        got_signal.store(0, .release);
    }
    try std.posix.raise(.TERM);
    try t.expectEqualStrings("SIGTERM", signalName(got_signal.load(.acquire)));
}

test "mcp_servers_and_the_browser_only_for_commands_that_use_tools" {
    // a brief is one model call without tools; memory commands make none
    try t.expect(!App.Role.memory.usesTools());
    try t.expect(!App.Role.brief.usesTools());
    try t.expect(App.Role.task.usesTools());
    try t.expect(App.Role.chat.usesTools());
    try t.expect(App.Role.run.usesTools());
}

test "a_value_too_long_for_the_store_is_refused_with_its_limit" {
    var buf: [200]u8 = undefined;
    const why = valueProblem(&buf, .{ .wincred = store_mod.legacy_namespace }, 3000) orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, why, "Credential Manager") != null);
    try t.expect(std.mem.indexOf(u8, why, "2560") != null);
    try t.expect(valueProblem(&buf, .{ .wincred = store_mod.legacy_namespace }, 2560) == null);
    try t.expect(valueProblem(&buf, .{ .wincred = store_mod.legacy_namespace }, 7) != null);
}

test "same_path_sees_one_folder_however_it_is_written" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "data/harness");
    const real = try tmp.dir.realPathFileAlloc(t.io, "data/harness", a);
    try t.expect(samePath(t.io, a, real, try std.fmt.allocPrint(a, "{s}/", .{real})));
    try t.expect(samePath(t.io, a, real, try std.fs.path.join(a, &.{ real, "..", "harness" })));
    try t.expect(!samePath(t.io, a, real, try std.fs.path.join(a, &.{ real, "..", "other" })));
    // not made yet: compared as written
    try t.expect(samePath(t.io, a, "/no/such/place", "/no/such/./place"));
}

fn printLine(what: []const u8, line: []const []const u8) void {
    std.debug.print("{s}", .{what});
    for (line) |w| std.debug.print(" {s}", .{w});
    std.debug.print("\n", .{});
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
    try t.expectError(error.NotPaired, ch.send(ch.ctx, .{}, "hello, anyone?"));
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

test "a_voice_note_from_telegram_is_transcribed_end_to_end" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const home = try testHome(&e);
    const url = try e.url();
    // a local whisper.cpp server at the stand-in: no key
    const p = try core_mod.Paths.init(a, home);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.config, .data = try std.fmt.allocPrint(a, "[model]\nurl = {s}\n[search]\nurl = {s}\n[chat]\napi = {s}\n[provider whisper]\napi = openai\nurl = {s}/v1\nauth = none\n[voice]\nprovider = whisper\nmodel = large-v3-turbo\nlanguage = pl\n", .{ url, url, url, url }) });
    const c = try Core.open(t.allocator, t.io, home, .{ .telegram = "123:abc", .omnigate = "og-key-for-tests" });
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
    try c.startWorker();
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/files/AwACAgIAAxk", .data = "OggS-e2e-audio" });
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "transcribe/001.json", .data = "{\"text\":\"włącz światło w kuchni\"}" });
    try e.script(1, model.textReply("Światło w kuchni jest włączone."));
    try telegram.inbox(&e, 1, "{\"message\":{\"message_id\":5,\"from\":{\"id\":42},\"chat\":{\"id\":42,\"type\":\"private\"},\"voice\":{\"file_id\":\"AwACAgIAAxk\",\"duration\":3,\"mime_type\":\"audio/ogg\",\"file_size\":14}}}");
    // as the poll loop takes them
    for (try tc.poll.getUpdates(a, 0, 0)) |u| takeUpdate(c, &tc, u);
    var waited: u32 = 0;
    while (std.mem.indexOf(u8, try telegram.outbox(&e), "jest włączone") == null and waited < 8000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    const out = try telegram.outbox(&e);
    if (std.mem.indexOf(u8, out, "jest włączone") == null) std.debug.print("out.jsonl:\n{s}\n", .{out});
    // fetched from Telegram, then the quoted words without a sound, then the reply
    try t.expect(std.mem.indexOf(u8, out, "\"method\":\"getFile\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "{\"method\":\"download\",\"path\":\"voice/AwACAgIAAxk.oga\"}") != null);
    const heard = std.mem.indexOf(u8, out, "\"text\":\"\\\"włącz światło w kuchni\\\"\",\"link_preview_options\":{\"is_disabled\":true},\"disable_notification\":true") orelse {
        std.debug.print("out.jsonl:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    };
    try t.expect(heard < std.mem.indexOf(u8, out, "jest włączone").?);
    // the model got the words; the stand-in got the audio, with no key
    try t.expect(std.mem.indexOf(u8, try e.request(1), "włącz światło w kuchni") != null);
    const sreq = try e.tmp.dir.readFileAlloc(t.io, "transcribe-requests/001.json", a, .unlimited);
    try t.expect(std.mem.indexOf(u8, sreq, "OggS-e2e-audio") != null);
    try t.expect(std.mem.indexOf(u8, sreq, "Authorization") == null);
    // the token went nowhere but the request paths
    try t.expect(std.mem.indexOf(u8, out, "123:abc") == null);
}

test "login_add_and_rm_say_exactly_what_they_stored_and_removed" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kc = "the macOS Keychain";
    try t.expectEqualStrings("Added bot to logins.ini (site github.com). Stored its password and TOTP secret in the macOS Keychain.", try addedText(a, "bot", "github.com", true, true, kc));
    try t.expectEqualStrings("Added bot to logins.ini (site github.com). Stored its password in the macOS Keychain; no TOTP secret.", try addedText(a, "bot", "github.com", true, false, kc));
    try t.expectEqualStrings("Added bot to logins.ini (site github.com). Stored its TOTP secret in the macOS Keychain; no password: the agent makes one when it signs up.", try addedText(a, "bot", "github.com", false, true, kc));
    try t.expectEqualStrings("Added bot to logins.ini (site github.com). Nothing stored: no password (the agent makes one when it signs up), no TOTP secret.", try addedText(a, "bot", "github.com", false, false, kc));
    try t.expectEqualStrings("Removed bot: its entry in logins.ini, its password, its TOTP secret, its passkeys and its browser profile.", (try removedText(a, "bot", true, .{ true, true, true }, true)).?);
    try t.expectEqualStrings("Removed bot: its entry in logins.ini.", (try removedText(a, "bot", true, .{ false, false, false }, false)).?);
    try t.expectEqualStrings("Removed bot: its entry in logins.ini and its passkeys.", (try removedText(a, "bot", true, .{ false, false, true }, false)).?);
    try t.expectEqualStrings("Removed what was left of bot (it had no entry in logins.ini): its password and its browser profile.", (try removedText(a, "bot", false, .{ true, false, false }, true)).?);
    try t.expectEqual(null, try removedText(a, "bot", false, .{ false, false, false }, false));
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
    _ = @import("who.zig");
    _ = @import("conversations.zig");
    _ = @import("inbox.zig");
    _ = @import("session.zig");
    _ = @import("folders.zig");
    _ = @import("environments.zig");
    _ = @import("sandbox.zig");
    _ = @import("remote.zig");
    _ = @import("snapshots.zig");
    _ = @import("undo.zig");
    _ = @import("sock.zig");
    _ = @import("store.zig");
    _ = @import("scrub.zig");
    _ = @import("masks.zig");
    _ = @import("skills.zig");
    _ = @import("agents.zig");
    _ = @import("mcp.zig");
    _ = @import("mcp_http.zig");
    _ = @import("oauth.zig");
    _ = @import("page.zig");
    _ = @import("totp.zig");
    _ = @import("logins.zig");
    _ = @import("cdp.zig");
    _ = @import("web.zig");
    _ = @import("url.zig");
    _ = @import("proc.zig");
    _ = @import("triggers.zig");
    _ = @import("tstate.zig");
    _ = @import("sources.zig");
    _ = @import("apps.zig");
    _ = @import("appserver.zig");
    _ = @import("clone.zig");
    _ = @import("workflows.zig");
    _ = @import("wstate.zig");
    _ = @import("voice.zig");
    _ = @import("quiet.zig");
    _ = @import("household.zig");
}

test "a_line_of_ctrl_d_leaves_the_chat_in_a_windows_console" {
    try std.testing.expectEqual(builtin.os.tag == .windows, leaves("\x04"));
    try std.testing.expect(!leaves("hello"));
    try std.testing.expect(!leaves(""));
    try std.testing.expect(!leaves("\x04 more"));
}

test "msys_and_cygwin_terminals_are_known_by_their_pipe_names" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(Echo.msysPtyName(L("\\msys-1888ae32e00d56aa-pty0-from-master")));
    try std.testing.expect(Echo.msysPtyName(L("\\cygwin-1888ae32e00d56aa-pty3-to-master")));
    // a pipe of bash's (`a | b`) is not a terminal, nor is anyone else's
    try std.testing.expect(!Echo.msysPtyName(L("\\msys-1888ae32e00d56aa-pipe-0x15")));
    try std.testing.expect(!Echo.msysPtyName(L("\\zig-childprocess-1234-pty")));
    try std.testing.expect(!Echo.msysPtyName(L("")));
}

test "a_pipe_named_like_a_git_bash_terminal_is_one_and_a_plain_pipe_is_not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const k = struct {
        extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max: u32, out_size: u32, in_size: u32, timeout: u32, sa: ?*anyopaque) callconv(.winapi) std.os.windows.HANDLE;
    };
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const invalid: std.os.windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));
    // the end a program reads typed input from: the pipe's server end
    const pty = k.CreateNamedPipeW(L("\\\\.\\pipe\\msys-harnesstest01-pty0-from-master"), 1, 0, 1, 4096, 4096, 0, null);
    try std.testing.expect(pty != invalid);
    defer std.os.windows.CloseHandle(pty);
    try std.testing.expect(Echo.msysTerminal(.{ .handle = pty, .flags = .{ .nonblocking = false } }));
    const plain = k.CreateNamedPipeW(L("\\\\.\\pipe\\harnesstest01-plain"), 1, 0, 1, 4096, 4096, 0, null);
    try std.testing.expect(plain != invalid);
    defer std.os.windows.CloseHandle(plain);
    try std.testing.expect(!Echo.msysTerminal(.{ .handle = plain, .flags = .{ .nonblocking = false } }));
}

test "log_runs_and_log_session_read_runs_back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "actions.jsonl" });
    var l = try log_mod.Log.open(t.allocator, t.io, path);
    const hs = "house-search";
    const rid = try l.writeRun(.turn, false, .{ .run = "chat", .by = "owner", .agent = "main", .conversation = hs }, .{ .text = "find flats" });
    _ = try l.writeRun(.model, false, .{ .rid = rid, .run = "chat", .conversation = hs }, .{ .result = "ok", .input_tokens = 1520, .output_tokens = 85 });
    _ = try l.writeRun(.gate, false, .{ .rid = rid, .run = "chat", .agent = "main", .conversation = hs }, .{ .tool = "shell", .decision = "allow", .why = "rule on line 1", .arg = "ls -l" });
    _ = try l.writeRun(.tool, false, .{ .rid = rid, .run = "chat", .agent = "main", .conversation = hs }, .{ .tool = "shell", .arg = "ls -l", .is_error = false, .output = "a\nb", .bytes = 3 });
    _ = try l.writeRun(.gate, false, .{ .rid = rid, .run = "chat", .agent = "main", .conversation = hs }, .{ .tool = "fetch", .decision = "deny", .why = "denied by the owner", .arg = "https://x.example/" });
    const h = try l.writeRun(.turn, false, .{ .run = "chat/h1", .by = "owner", .agent = "helper", .parent = rid, .conversation = hs }, .{ .text = "look at site a" });
    _ = try l.writeRun(.model, false, .{ .rid = h, .run = "chat/h1", .conversation = hs }, .{ .result = "ok", .input_tokens = 7, .output_tokens = 3 });
    _ = try l.writeRun(.turn, false, .{ .rid = h, .run = "chat/h1", .conversation = hs }, .{ .answer = "site a: 2 flats", .steps = 1, .ended_by = @as(?[]const u8, null) });
    _ = try l.writeRun(.send, false, .{ .rid = rid, .run = "chat", .conversation = hs }, .{ .to = hs, .event = "sent", .bytes = 18, .text = "Three flats match.", .final = true, .implicit = false, .delivered = true });
    _ = try l.writeRun(.turn, false, .{ .rid = rid, .run = "chat", .conversation = hs }, .{ .answer = "", .steps = 2, .ended_by = @as(?[]const u8, null) });
    try l.write(.config, false, .{ .event = "not a run's" });
    const task = try l.writeRun(.turn, false, .{ .run = "task check", .by = "schedule:check", .agent = "main", .conversation = "main" }, .{ .text = "Check the price." });
    _ = try l.writeRun(.turn, false, .{ .rid = task, .run = "task check", .conversation = "main" }, .{ .answer = "", .steps = 20, .ended_by = "Step limit reached for this turn." });
    l.close();
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
    // harness log runs: a line per run
    const runs = try session.runsText(a, text, 20);
    for ([_][]const u8{
        try std.fmt.allocPrint(a, "{d}  ", .{rid}),
        "  chat  by owner  in house-search  2 steps  answered\n",
        "  chat/h1  by owner  in house-search  1 step  answered\n",
        "  task check  by schedule:check  in main  20 steps  Step limit reached for this turn.\n",
    }) |want| {
        if (std.mem.indexOf(u8, runs, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, runs });
        try t.expect(std.mem.indexOf(u8, runs, want) != null);
    }
    try t.expectEqual(1, std.mem.count(u8, try session.runsText(a, text, 1), "\n"));
    // harness log session RID: the run and its helpers, readable
    const shown = (try session.render(a, text, rid, 0)).?;
    for ([_][]const u8{
        "Owner: find flats\n",
        "Model: 1520 in, 85 out\n",
        "shell ls -l: allow (rule on line 1), ok, 3 bytes\n",
        "fetch https://x.example/: deny (denied by the owner)\n",
        "Helper chat/h1: look at site a (1 model calls, 0 tool calls; answered)\n",
        "Posted to house-search: Three flats match. (final)\n",
        "Ended: answered in 2 steps\n",
    }) |want| {
        if (std.mem.indexOf(u8, shown, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, shown });
        try t.expect(std.mem.indexOf(u8, shown, want) != null);
    }
    try t.expect(std.mem.indexOf(u8, shown, "Check the price") == null);
    // cut to a size: whole lines, then where the rest is
    const short = (try session.render(a, text, rid, 120)).?;
    try t.expect(short.len <= 120);
    try t.expect(std.mem.endsWith(u8, short, try std.fmt.allocPrint(a, "harness log session {d} shows all", .{rid})));
    // --json: the lines as they are, the helper's too
    const raw = try session.raw(a, text, rid);
    try t.expectEqual(10, std.mem.count(u8, raw, "\n"));
    try t.expect(std.mem.indexOf(u8, raw, "not a run's") == null);
    try t.expectEqual(null, try session.render(a, text, 9999, 0));
    // the session view's choice of run
    try t.expectEqual(rid, (try session.lastRunIn(a, text, "house-search", 1)).?);
    try t.expectEqual(task, (try session.lastRunIn(a, text, "main", 1)).?);
    try t.expectEqual(null, try session.lastRunIn(a, text, "house-search", 2));
    // the arguments
    try t.expect(badArgs(&.{ "log", "runs" }) == null);
    try t.expect(badArgs(&.{ "log", "runs", "5" }) == null);
    try t.expect(badArgs(&.{ "log", "session", "12" }) == null);
    try t.expect(badArgs(&.{ "log", "session", "12", "--json" }) == null);
    try t.expect(badArgs(&.{ "log", "session" }) != null);
    try t.expect(badArgs(&.{ "log", "session", "x" }) != null);
    try t.expect(badArgs(&.{ "log", "runs", "x" }) != null);
}

test "log_search_takes_words" {
    try t.expect(badArgs(&.{ "log", "search", "flats" }) == null);
    try t.expect(badArgs(&.{ "log", "search", "flight to oslo", "2026" }) == null);
    try t.expect(badArgs(&.{ "log", "search" }) != null);
}

test "the_terminal_shows_a_runs_undo_as_its_command" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/undo 41", termButton(&buf, .{ "Undo", "u41-0123456789abcdef" }));
    try std.testing.expectEqualStrings("  > Yes", termButton(&buf, .{ "Yes", "r3-abc:1" }));
}

test "the_terminal_offers_only_the_answers_the_question_has" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("[o] allow once  [n] deny", keysLine(&buf, &.{ .{ "Allow once", "a3:once" }, .{ "Deny", "a3:deny" } }));
    try std.testing.expectEqualStrings("[o] allow once  [d] allow 24 h  [n] deny", keysLine(&buf, &.{ .{ "Allow once", "a4:once" }, .{ "Allow 24 h", "a4:day" }, .{ "Deny", "a4:deny" } }));
}

test "snapshot_arguments_are_checked" {
    for ([_][]const []const u8{
        &.{"snapshot"},                          &.{ "snapshot", "list" },              &.{ "snapshot", "take" },
        &.{ "snapshot", "changes", "n" },        &.{ "snapshot", "restore", "n", "1", "x" }, &.{ "snapshot", "drop", "n" },
        &.{ "snapshot", "list", "n", "m" },
    }) |line| if (badArgs(line) == null) {
        printLine("accepted:", line);
        return error.TestUnexpectedResult;
    };
    for ([_][]const []const u8{
        &.{ "snapshot", "list", "n" },       &.{ "snapshot", "take", "n" }, &.{ "snapshot", "take", "n", "a", "label" },
        &.{ "snapshot", "changes", "n", "2" }, &.{ "snapshot", "restore", "n", "1" },
    }) |line| if (badArgs(line)) |why| {
        printLine("refused:", line);
        std.debug.print("  {s}\n", .{why});
        return error.TestUnexpectedResult;
    };
}

test "undo_arguments_are_checked" {
    for ([_][]const []const u8{
        &.{"undo"}, &.{ "undo", "x" }, &.{ "undo", "1", "2" }, &.{ "undo", "-1" },
    }) |line| if (badArgs(line) == null) {
        printLine("accepted:", line);
        return error.TestUnexpectedResult;
    };
    try t.expect(badArgs(&.{ "undo", "41" }) == null);
}

test "the_terminal_answers_by_id_when_several_are_open" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const c = try Core.open(t.allocator, t.io, try testHome(&e), .{});
    defer c.close();
    const a = e.arena.allocator();
    const two: inbox_mod.New = .{ .kind = "question", .title = "Which one?", .body = "Which one?", .choices = &.{ .{ .key = "1", .label = "Personal" }, .{ .key = "2", .label = "Work" } } };
    _ = try c.addItem(two);
    _ = try c.addItem(two);
    // a key alone: several take it, so the id is needed
    try t.expectEqualStrings("Several are waiting: 1, 2. Add the id, as in 1 1.", c.terminalAnswer(a, "1").?);
    // with the id, that item
    try t.expectEqualStrings("", c.terminalAnswer(a, "2 2").?);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, c.paths.inbox, a, .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "\"answer\":{\"key\":\"2\",\"text\":null,") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"via\":\"terminal\"") != null);
    // one left: a key alone answers it
    try t.expectEqualStrings("", c.terminalAnswer(a, "1").?);
    try t.expectEqualStrings("No item 2 is waiting.", c.terminalAnswer(a, "1 2").?);
    // with no approval waiting, o is a message for the agent
    try t.expectEqual(null, c.terminalAnswer(a, "o"));
    try t.expectEqual(null, c.terminalAnswer(a, "ok then"));
    // the keys the terminal shows for a question
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("[1] personal  [2] work", keysLine(&buf, &.{ .{ "Personal", "i44-0123456789abcdef:1" }, .{ "Work", "i44-0123456789abcdef:2" } }));
}

test "harness_inbox_json_prints_v1_without_the_kept_fields" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(t.io, ".", a), "inbox" });
    const at: i64 = 1795356180;
    {
        var box: inbox_mod.Box = .init(t.allocator, t.io, path);
        defer box.deinit();
        const it = try box.add(.{
            .kind = "delivery",
            .title = "Three flats match.",
            .body = "Three flats match.",
            .choices = &.{ .{ .key = "again", .label = "Send again" }, .{ .key = "drop", .label = "Drop" } },
            .post = .{ .conversation = "main", .text = "Three flats match.", .next = at + 300 },
            .grant = .{ .tool = "shell@host", .key = "ls", .who = "schedule:x" },
            .skip = "schedule:x\tshell@host\tls",
        }, at, "0123456789abcdef".*);
        try it.shown.append(it.arena.allocator(), .{ .chat = 42, .thread = 0, .message = 7 });
        const done = try box.add(.{ .kind = "approval", .title = "shell: ls", .body = "shell: ls" }, at, "fedcba9876543210".*);
        box.close(done, .answered, .{ .key = "once", .at = at + 20, .via = .telegram });
        try box.save(at + 120);
    }
    var read: inbox_mod.Box = .init(t.allocator, t.io, path);
    defer read.deinit();
    try read.load("");
    const json = try inboxText(a, &read, true, at + 120);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, json, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        n += 1;
        try t.expect(std.mem.startsWith(u8, l, "{\"v\":1,"));
        for ([_][]const u8{ "\"token\"", "\"shown\"", "\"post\"", "\"grant\"", "\"skip\"", "\"private\"", "0123456789abcdef" }) |k| try t.expect(std.mem.indexOf(u8, l, k) == null);
    }
    try t.expectEqual(2, n);
    // without --json: what waits, a line each
    try t.expectEqualStrings("[1] delivery, main, 2 min: Three flats match.\n", try inboxText(a, &read, false, at + 120));
    try t.expect(badArgs(&.{"inbox"}) == null);
    try t.expect(badArgs(&.{ "inbox", "--json" }) == null);
    try t.expect(badArgs(&.{ "inbox", "x" }) != null);
}

test "start_notes_name_each_provider_in_use_without_its_key" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // harness init's settings, nothing stored: 0.3's two notes
    const d = try config.parse(a, config.defaults_ini);
    const ds = try model.Providers.resolve(a, config.providerSettings(d), model.no_keys);
    const dn = try startNotes(a, &ds, &.{ d.model.model, d.model.worker_model, d.model.memory_model });
    try t.expectEqual(2, dn.len);
    try t.expectEqualStrings("note: no omnigate key stored under \"omnigate\"; model calls will be refused. Run: harness secret add omnigate", dn[0]);
    try t.expectEqualStrings("note: no omnigate url is set ([model] url in config.ini); model calls will be refused", dn[1]);
    // everything on openrouter: only its key is said
    const o = try config.parse(a, "[model]\nprovider = openrouter\nmodel = openrouter:deepseek/deepseek-chat\n");
    const os = try model.Providers.resolve(a, config.providerSettings(o), model.no_keys);
    const on = try startNotes(a, &os, &.{ o.model.model, o.model.worker_model, o.model.memory_model });
    try t.expectEqual(1, on.len);
    try t.expectEqualStrings("note: no openrouter key stored under \"openrouter\"; model calls will be refused. Run: harness secret add openrouter", on[0]);
}

test "a_voice_service_without_its_key_is_named_at_start" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try config.parse(a, "[voice]\nprovider = groq\nmodel = whisper-large-v3-turbo\n[provider groq]\napi = openai\nurl = https://api.groq.com/openai/v1\n");
    const gs = try model.Providers.resolve(a, config.providerSettings(g), model.no_keys);
    try t.expectEqualStrings("note: no groq key stored under \"groq\"; voice notes will be refused. Run: harness secret add groq", (try voiceStartNote(a, &gs, g.voice.provider)).?);
    // a local server needs none; no [voice], nothing to say
    const l = try config.parse(a, "[voice]\nprovider = whisper\nmodel = m\n[provider whisper]\napi = openai\nurl = http://127.0.0.1:8090/v1\nauth = none\n");
    const ls = try model.Providers.resolve(a, config.providerSettings(l), model.no_keys);
    try t.expect((try voiceStartNote(a, &ls, l.voice.provider)) == null);
    const d = try config.parse(a, "");
    const ds = try model.Providers.resolve(a, config.providerSettings(d), model.no_keys);
    try t.expect((try voiceStartNote(a, &ds, d.voice.provider)) == null);
}

test "mcp_commands_take_their_arguments" {
    for ([_][]const []const u8{ &.{ "mcp", "list" }, &.{ "mcp", "login", "atlassian" }, &.{ "mcp", "logout", "my_server-2" } }) |line| if (badArgs(line)) |why| {
        std.debug.print("{s}: {s}\n", .{ line[1], why });
        return error.TestUnexpectedResult;
    };
    for ([_][]const []const u8{ &.{"mcp"}, &.{ "mcp", "list", "x" }, &.{ "mcp", "login" }, &.{ "mcp", "logout" }, &.{ "mcp", "login", "--x" }, &.{ "mcp", "login", "a", "b" }, &.{ "mcp", "login", "Bad" }, &.{ "mcp", "login", "a__b" }, &.{ "mcp", "add", "x" }, &.{ "mcp", "logout", "" } }) |line|
        try std.testing.expect(badArgs(line) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "mcp list") != null);
}

test "mcp_list_says_each_servers_kind_sign_in_and_tools" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ e.dir, "secrets" }) };
    try st.put(t.io, "webtok", "mcp-test-token-1");
    const home = try std.fs.path.join(a, &.{ e.dir, "home" });
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, build_options.fake_path, a);
    const text = try std.fmt.allocPrint(a,
        \\[prog]
        \\command = "{s}" --mcp
        \\[needs]
        \\command = "{s}" --mcp
        \\secret = KEY_ONE:webtok, KEY_TWO:nothere, KEY_THREE:webtok
        \\[web]
        \\url = {s}/mcp/token
        \\token = webtok
        \\[nokey]
        \\url = {s}/mcp/token
        \\token = missing
        \\[cloud]
        \\url = {s}/mcp/signin
        \\login = oauth
        \\[gone]
        \\url = http://127.0.0.1:1/mcp
        \\
    , .{ fake, fake, try e.url(), try e.url(), try e.url() });
    const out = try mcpListText(t.allocator, a, t.io, try mcp.parseConfig(a, text), .{
        .store = st,
        .home = home,
        .path_var = "/usr/bin:/bin",
        .home_var = "/tmp",
        .system_vars = &.{},
    });
    for ([_][]const u8{
        "prog (program): 3 tools\n  prog/echo  Echo text back.\n  prog/fail  Always fails.\n  prog/sleep  Wait ms milliseconds.\n",
        "web (token webtok, stored): 3 tools\n  web/echo  Echo text back.\n",
        "nokey (token missing, not stored): harness secret add missing\n",
        "needs (program): secret nothere is not stored: harness secret add nothere\n",
        "cloud (sign-in, not signed in): harness mcp login cloud\n",
        "gone (url): not reached: gone could not be reached (ConnectFailed)\n",
    }) |want| {
        if (std.mem.indexOf(u8, out, want) == null) std.debug.print("not in:\n{s}\nwanted:\n{s}\n", .{ out, want });
        try std.testing.expect(std.mem.indexOf(u8, out, want) != null);
    }
    // in mcp.ini's order, and nothing secret in it
    try std.testing.expect(std.mem.indexOf(u8, out, "prog").? < std.mem.indexOf(u8, out, "gone").?);
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp-test-token-1") == null);
}

test "harness_trigger_takes_list_test_and_run" {
    for ([_][]const []const u8{ &.{ "trigger", "list" }, &.{ "trigger", "test", "btc" }, &.{ "trigger", "run", "btc" } }) |line| if (badArgs(line)) |why| {
        std.debug.print("{s}: {s}\n", .{ line[1], why });
        return error.TestUnexpectedResult;
    };
    for ([_][]const []const u8{ &.{"trigger"}, &.{ "trigger", "list", "x" }, &.{ "trigger", "go", "x" }, &.{ "trigger", "test" }, &.{ "trigger", "run", "-x" }, &.{ "trigger", "run", "a", "b" } }) |line|
        try std.testing.expect(badArgs(line) != null);
}


test "harness_workflow_takes_list_check_start_stop" {
    for ([_][]const []const u8{ &.{ "workflow", "list" }, &.{ "workflow", "check", "x.wf" }, &.{ "workflow", "start", "hello" }, &.{ "workflow", "start", "hello", "some", "text" }, &.{ "workflow", "stop", "hello#1" }, &.{ "workflow", "stop", "hello" } }) |line| if (badArgs(line)) |why| {
        std.debug.print("{s}: {s}\n", .{ line[1], why });
        return error.TestUnexpectedResult;
    };
    for ([_][]const []const u8{ &.{"workflow"}, &.{ "workflow", "list", "x" }, &.{ "workflow", "go" }, &.{ "workflow", "check" }, &.{ "workflow", "start" }, &.{ "workflow", "stop" }, &.{ "workflow", "stop", "a", "b" }, &.{ "workflow", "start", "-x" } }) |line|
        try std.testing.expect(badArgs(line) != null);
}
