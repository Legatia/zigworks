//! `harness doctor` and `harness report`, for testers: a plain line per
//! piece (harness run, the settings, the bot, the model, the home, the car,
//! the triggers, voice notes, quiet hours), each that doesn't work with
//! what to do; and one masked file for a bug report. Both read the data
//! folder without taking its lock, so they work while `harness run` does.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const core = @import("core.zig");
const model = @import("model.zig");
const mcp = @import("mcp.zig");
const oauth = @import("oauth.zig");
const scrub = @import("scrub.zig");
const store_mod = @import("store.zig");
const telegram = @import("telegram.zig");
const triggers = @import("triggers.zig");
const tstate = @import("tstate.zig");
const quiet_mod = @import("quiet.zig");
const folders = @import("folders.zig");
const logins = @import("logins.zig");
const environments = @import("environments.zig");
const sandbox = @import("sandbox.zig");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Env = struct {
    gpa: Allocator,
    io: Io,
    /// The data folder.
    home: []const u8,
    store: store_mod.Store,
    path_var: []const u8 = "/usr/local/bin:/usr/bin:/bin",
    home_var: []const u8 = "",
    system_vars: []const util.Var = &.{},
    now_s: i64,
};

/// One piece: its name, what doctor says of it, whether it works (a piece
/// not set up, and optional, works).
pub const Line = struct { name: []const u8, text: []const u8, ok: bool };

/// Doctor's lines, as it prints them.
pub fn text(a: Allocator, lines: []const Line) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (lines) |l| try o.print(a, "{s}: {s}\n", .{ l.name, l.text });
    return o.items;
}

pub fn allOk(lines: []const Line) bool {
    for (lines) |l| if (!l.ok) return false;
    return true;
}

fn read(env: Env, a: Allocator, path: []const u8) []const u8 {
    return Io.Dir.cwd().readFileAlloc(env.io, path, a, .limited(1 << 20)) catch "";
}

fn stored(env: Env, a: Allocator, name: []const u8) ?[]const u8 {
    return env.store.get(env.io, a, name) catch null;
}

/// Every piece, checked now. A check that reaches out (Telegram's getMe,
/// one short model request, homemcp's and carcloud's own checks) takes at
/// most its own time.
pub fn check(a: Allocator, env: Env) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    const p = try core.Paths.init(a, env.home);
    const cfg_text = Io.Dir.cwd().readFileAlloc(env.io, p.config, a, .limited(1 << 20)) catch {
        try out.append(a, .{ .name = "Settings", .text = try std.fmt.allocPrint(a, "no data folder at {s}. Make one: harness init", .{env.home}), .ok = false });
        return out.items;
    };
    // harness run
    var hb: [256]u8 = undefined;
    const h = core.health(env.io, p, env.now_s, &hb);
    try out.append(a, .{ .name = "harness run", .text = if (h.ok) try a.dupe(u8, h.text) else try std.fmt.allocPrint(a, "{s}. Start it: harness run (and keep it running)", .{h.text}), .ok = h.ok });
    // the settings files
    const cfg = config.parse(a, cfg_text) catch {
        const why = (core.parseProblem(a, "config.ini", cfg_text, config.parse) catch null) orelse "config.ini has an error";
        try out.append(a, .{ .name = "Settings", .text = try std.fmt.allocPrint(a, "{s}. Fix that line; harness doctor again", .{why}), .ok = false });
        return out.items;
    };
    if (try core.settingsProblem(env.io, a, p)) |why| {
        try out.append(a, .{ .name = "Settings", .text = try std.fmt.allocPrint(a, "{s}", .{why}), .ok = false });
    } else try out.append(a, .{ .name = "Settings", .text = "every file reads", .ok = true });
    try out.append(a, try bot(a, env, cfg, p));
    try out.append(a, try modelLine(a, env, cfg));
    try out.append(a, try program(a, env, p, "home"));
    try out.append(a, try program(a, env, p, "car"));
    try out.append(a, try sandboxLine(a, env, p));
    try out.appendSlice(a, try triggerLines(a, env, p));
    try out.append(a, try voiceLine(a, env, cfg));
    try out.append(a, try quietLine(a, env, cfg, p));
    return out.items;
}

/// Where the commands of runs nobody watches run (`[default] unattended`,
/// the built-in sandbox unless environments.ini says otherwise), and
/// whether that can be made here: where it can't they are refused.
fn sandboxLine(a: Allocator, env: Env, p: core.Paths) !Line {
    const name = "Routines' commands";
    // (a file that doesn't read is the Settings line's)
    const list = environments.parse(a, read(env, a, p.environments)) catch return .{ .name = name, .text = "environments.ini doesn't read: see Settings", .ok = false };
    const e = list.find(list.unattended) orelse return .{ .name = name, .text = "run on this machine (environments.ini: unattended = host)", .ok = true };
    if (e.kind != .sandbox) return .{ .name = name, .text = try std.fmt.allocPrint(a, "run in {s} ({s})", .{ e.name, try environments.describe(a, e.*) }), .ok = true };
    if (try core.Core.sandboxMissing(env.io, a, list)) |why| return .{ .name = name, .text = std.mem.trimEnd(u8, why, "."), .ok = false };
    return .{ .name = name, .text = try std.fmt.allocPrint(a, "run in {s} ({s}), by {s}", .{ e.name, try environments.describe(a, e.*), sandbox.backend }), .ok = true };
}

fn bot(a: Allocator, env: Env, cfg: config.Config, p: core.Paths) !Line {
    if (!cfg.chat.telegram) return .{ .name = "Bot", .text = "Telegram is off in config.ini; harness chat talks in a terminal", .ok = true };
    const token = stored(env, a, cfg.chat.token) orelse return .{ .name = "Bot", .text = try std.fmt.allocPrint(a, "no bot token stored. Store the one @BotFather gave you: harness secret add {s}", .{cfg.chat.token}), .ok = false };
    var b = telegram.Bot.init(env.gpa, env.io, cfg.chat.api, token) catch return .{ .name = "Bot", .text = "[chat] api in config.ini is not a valid address", .ok = false };
    defer b.deinit();
    const me = b.getMe(a) catch |e| return .{ .name = "Bot", .text = if (e == error.TelegramRefused) try std.fmt.allocPrint(a, "Telegram refused the token stored as {s}. Store the right one: harness secret add {s}", .{ cfg.chat.token, cfg.chat.token }) else try std.fmt.allocPrint(a, "Telegram didn't answer ({s}). Check the network, then harness doctor again", .{@errorName(e)}), .ok = false };
    const paired = if (Io.Dir.cwd().statFile(env.io, p.owner, .{})) |_| true else |_| false;
    if (!paired) return .{ .name = "Bot", .text = try std.fmt.allocPrint(a, "@{s} answers, but nobody is paired. With harness run going: harness pair, then send /pair CODE to @{s}", .{ me.username, me.username }), .ok = false };
    return .{ .name = "Bot", .text = try std.fmt.allocPrint(a, "@{s} answers; you are paired", .{me.username}), .ok = true };
}

/// The key `secret` of provider `provider`, from the store (doctor's own
/// lookup: it holds no Core).
fn storeKey(ctx: ?*anyopaque, a: Allocator, provider: []const u8, secret: []const u8) ?[]const u8 {
    _ = provider;
    const env: *const Env = @ptrCast(@alignCast(ctx.?));
    return env.store.get(env.io, a, secret) catch null;
}

fn modelLine(a: Allocator, env: Env, cfg: config.Config) !Line {
    var e = env;
    const set = try model.Providers.resolve(a, config.providerSettings(cfg), .{ .ctx = @ptrCast(&e), .get = storeKey });
    const choice = set.pick(cfg.model.model);
    var client = set.client(env.gpa, env.io, cfg.model.model, 8) catch return .{ .name = "Model", .text = try std.fmt.allocPrint(a, "the address for {s} in config.ini is not valid", .{choice.provider.name}), .ok = false };
    defer client.deinit();
    // one short request: whether the address and the key work
    const started = util.nowMs(env.io);
    _ = client.send(a, "Answer with the word ok.", &.{.{ .role = .user, .blocks = &.{.{ .text = "ok?" }} }}, &.{}) catch |err| {
        return .{ .name = "Model", .text = std.mem.trimEnd(u8, try client.failure(a, err), "."), .ok = false };
    };
    const ms = util.nowMs(env.io) - started;
    return .{ .name = "Model", .text = try std.fmt.allocPrint(a, "{s} at {s} answers ({d}.{d} s; doctor's one short request)", .{ choice.model, choice.provider.name, @divFloor(ms, 1000), @divFloor(@mod(ms, 1000), 100) }), .ok = true };
}

/// The home (`home`, homemcp) or the car (`car`, carcloud): mcp.ini's
/// section, its program's own check of its file.
fn program(a: Allocator, env: Env, p: core.Paths, which: []const u8) !Line {
    const home = std.mem.eql(u8, which, "home");
    const name: []const u8 = if (home) "Home" else "Car";
    const cfgs = mcp.parseConfig(a, read(env, a, p.mcp)) catch &.{};
    const sc = for (cfgs) |x| {
        if (std.mem.eql(u8, x.name, which)) break x;
    } else return .{ .name = name, .text = if (home) "not connected. In the chat: /setup home" else "not connected. In the chat: /setup car, if your car is on Smartcar", .ok = true };
    const argv = mcp.splitCommand(a, sc.command) catch return .{ .name = name, .text = try std.fmt.allocPrint(a, "mcp.ini's [{s}] command doesn't read", .{which}), .ok = false };
    if (argv.len != 2) return .{ .name = name, .text = try std.fmt.allocPrint(a, "mcp.ini's [{s}] is not as /setup writes it (PROGRAM FILE); harness can't check it", .{which}), .ok = true };
    var vars = std.process.Environ.Map.init(a);
    for (env.system_vars) |v| try vars.put(v.name, v.value);
    try vars.put("PATH", env.path_var);
    if (env.home_var.len > 0) try vars.put("HOME", env.home_var);
    var secrets: std.ArrayList(scrub.Secret) = .empty;
    for (sc.secrets) |es| {
        const v = stored(env, a, es.secret) orelse return .{ .name = name, .text = try std.fmt.allocPrint(a, "its secret {s} is not stored: harness secret add {s}", .{ es.secret, es.secret }), .ok = false };
        try vars.put(es.env, v);
        try secrets.append(a, .{ .name = es.secret, .value = v });
    }
    const r = std.process.run(a, env.io, .{
        .argv = &.{ argv[0], "check", argv[1] },
        .environ_map = &vars,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    }) catch |e| return .{ .name = name, .text = try std.fmt.allocPrint(a, "{s} didn't run ({s}). Is it still at {s}?", .{ std.fs.path.basename(argv[0]), @errorName(e), argv[0] }), .ok = false };
    var mask = try scrub.Scrubber.init(a, secrets.items);
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        const err = try mask.scrubAlloc(a, std.mem.trim(u8, r.stderr, " \t\r\n"));
        var first: []const u8 = err[0 .. std.mem.indexOfScalar(u8, err, '\n') orelse err.len];
        // its own name in front goes ("homemcp: …")
        const prog: []const u8 = if (home) "homemcp" else "carcloud";
        for ([_][]const u8{ "homemcp: discover: ", "homemcp: ", "carcloud: " }) |own| if (std.mem.startsWith(u8, first, own)) {
            first = first[own.len..];
            break;
        };
        first = std.mem.trimEnd(u8, first, ".");
        const what_to_do: []const u8 = if (home) "Fix it, or /setup home again" else "Fix it, or /setup car again";
        return .{ .name = name, .text = try std.fmt.allocPrint(a, "{s} check says: {s}. {s}", .{ prog, first, what_to_do }), .ok = false };
    }
    const outp = try mask.scrubAlloc(a, r.stdout);
    if (home) {
        // its first two lines: the home, and whether changes come in
        var it = std.mem.splitScalar(u8, outp, '\n');
        const first = std.mem.trim(u8, it.next() orelse "", " \r");
        const second = std.mem.trim(u8, it.next() orelse "", " \r");
        return .{ .name = name, .text = try std.fmt.allocPrint(a, "{s} {s}", .{ first, second }), .ok = true };
    }
    var battery: []const u8 = "?";
    var age: []const u8 = "";
    var it = std.mem.splitScalar(u8, outp, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "battery: ")) battery = std.mem.trimEnd(u8, l["battery: ".len..], "% \r");
        if (std.mem.startsWith(u8, l, "data: ")) age = std.mem.trimEnd(u8, l["data: ".len..], " \r");
    }
    return .{ .name = name, .text = try std.fmt.allocPrint(a, "answers: battery {s} %{s}{s}", .{ battery, if (age.len > 0) ", data " else "", age }), .ok = true };
}

fn triggerLines(a: Allocator, env: Env, p: core.Paths) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    var d: triggers.Diag = .{};
    const list = triggers.parse(a, read(env, a, p.triggers), .triggers, &d) catch {
        try out.append(a, .{ .name = "Triggers", .text = try std.fmt.allocPrint(a, "triggers.ini line {d} doesn't read: {s}", .{ d.line, d.why }), .ok = false });
        return out.items;
    };
    var bad: usize = 0;
    for (list) |tr| {
        if (!tr.isEvent()) continue;
        const st = (tstate.Dir{ .io = env.io, .path = try std.fs.path.join(a, &.{ p.triggers_state, tr.name }) }).loadState(a);
        if (st.paused.len > 0) {
            bad += 1;
            try out.append(a, .{ .name = "Triggers", .text = try std.fmt.allocPrint(a, "{s} is paused: {s}. In the chat: /trigger resume {s}", .{ tr.name, st.paused, tr.name }), .ok = false });
        } else if (st.failures >= 5) {
            bad += 1;
            try out.append(a, .{ .name = "Triggers", .text = try std.fmt.allocPrint(a, "{s} failed its last {d} polls. In the chat: /trigger test {s} says why", .{ tr.name, st.failures, tr.name }), .ok = false });
        }
    }
    if (bad == 0) try out.append(a, .{ .name = "Triggers", .text = if (list.len == 0) "none in triggers.ini" else try std.fmt.allocPrint(a, "{d} in triggers.ini, none paused or failing", .{list.len}), .ok = true });
    return out.items;
}

fn voiceLine(a: Allocator, env: Env, cfg: config.Config) !Line {
    if (cfg.voice.provider.len == 0) return .{ .name = "Voice notes", .text = "off. To have them: [voice] in config.ini (README: Voice notes)", .ok = true };
    const set = try model.Providers.resolve(a, config.providerSettings(cfg), model.no_keys);
    const prov = set.find(cfg.voice.provider) orelse return .{ .name = "Voice notes", .text = try std.fmt.allocPrint(a, "no provider called {s}", .{cfg.voice.provider}), .ok = false };
    if (prov.auth == .none) return .{ .name = "Voice notes", .text = try std.fmt.allocPrint(a, "{s} ({s}), no key needed", .{ prov.name, cfg.voice.model }), .ok = true };
    if (stored(env, a, prov.key_name) == null) return .{ .name = "Voice notes", .text = try std.fmt.allocPrint(a, "no {s} key stored. harness secret add {s}", .{ prov.name, prov.key_name }), .ok = false };
    return .{ .name = "Voice notes", .text = try std.fmt.allocPrint(a, "{s} ({s}), its key stored", .{ prov.name, cfg.voice.model }), .ok = true };
}

fn quietLine(a: Allocator, env: Env, cfg: config.Config, p: core.Paths) !Line {
    var q = quiet_mod.Store.init(env.gpa, env.io, try std.fs.path.join(a, &.{ p.state, "quiet" }));
    defer q.deinit();
    q.load() catch {};
    const hours = q.effective(cfg.butler.quiet) orelse return .{ .name = "Quiet hours", .text = "off. In the chat: /quiet on (22:00-07:00)", .ok = true };
    var hb: [24]u8 = undefined;
    return .{ .name = "Quiet hours", .text = try std.fmt.allocPrint(a, "{s}; only urgent things come through then", .{quiet_mod.hoursText(&hb, hours)}), .ok = true };
}

// ---- the report ----

/// Every stored secret the folder names (its config's keys, the providers',
/// MCP servers' secrets, tokens and sign-ins, folders.ini's variables, the
/// logins', Home Assistant's and Smartcar's) and, with the file store,
/// every file in it: what the report is masked with. (The Keychain and the
/// Credential Manager are asked by name: they aren't listed.)
pub fn storedSecrets(a: Allocator, env: Env) ![]const scrub.Secret {
    const p = try core.Paths.init(a, env.home);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(a, &.{ "ha", "smartcar", "omnigate", "telegram", "search" });
    if (config.parse(a, read(env, a, p.config))) |cfg| {
        try names.appendSlice(a, &.{ cfg.model.key, cfg.chat.token, cfg.search.key });
        const set = try model.Providers.resolve(a, config.providerSettings(cfg), model.no_keys);
        for (set.list) |pr| try names.append(a, pr.key_name);
    } else |_| {}
    const cfgs = mcp.parseConfig(a, read(env, a, p.mcp)) catch &.{};
    var out: std.ArrayList(scrub.Secret) = .empty;
    for (cfgs) |sc| {
        for (sc.secrets) |es| try names.append(a, es.secret);
        if (sc.token.len > 0) try names.append(a, sc.token);
        if (sc.login) {
            var nb: [40]u8 = undefined;
            const name = try a.dupe(u8, mcp.signinSecret(&nb, sc.name));
            if (oauth.load(env.io, a, env.store, name) catch null) |tk| try out.appendSlice(a, try tk.secrets(a, name));
        }
    }
    if (folders.parse(a, read(env, a, p.folders))) |f| {
        for (f.sections) |sec| for (sec.vars) |v| try names.append(a, v.secret);
    } else |_| {}
    for (logins.parse(a, read(env, a, p.logins)) catch &.{}) |l| for ([_]logins.Kind{ .password, .totp }) |k| {
        var nb: [96]u8 = undefined;
        try names.append(a, try a.dupe(u8, logins.secretName(&nb, l.name, k)));
    };
    switch (env.store) {
        .dir => |d| if (Io.Dir.cwd().openDir(env.io, d, .{ .iterate = true })) |dir_c| {
            var dir = dir_c;
            defer dir.close(env.io);
            var it = dir.iterate();
            while (it.next(env.io) catch null) |e| if (e.kind == .file) try names.append(a, try a.dupe(u8, e.name));
        } else |_| {},
        else => {},
    }
    for (names.items, 0..) |n, i| {
        if (n.len == 0) continue;
        const seen = for (names.items[0..i]) |m| {
            if (std.mem.eql(u8, m, n)) break true;
        } else false;
        if (seen) continue;
        const v = stored(env, a, n) orelse continue;
        try out.append(a, .{ .name = n, .value = v });
    }
    return out.items;
}

/// The report: version, where, doctor's lines, the settings files, the
/// last 200 log lines; every stored secret's value masked, and what looks
/// like a bot token or a password in an address taken out.
pub fn report(a: Allocator, env: Env, version: []const u8, doctor_text: []const u8) ![]const u8 {
    const p = try core.Paths.init(a, env.home);
    var o: std.ArrayList(u8) = .empty;
    var tb: [20]u8 = undefined;
    try o.print(a, "harness report, {s} UTC\nVersion: harness {s} ({s} {s})\nData folder: {s}\n", .{ util.isoTime(&tb, env.now_s)[0..16], version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), env.home });
    try o.appendSlice(a, "It holds the settings files (stored secrets masked), the log's last 200 lines (masked: what you and harness said in conversations that are not private is in them) and harness doctor's lines. Read it before you send it.\n");
    try o.print(a, "\n== harness doctor ==\n{s}", .{doctor_text});
    const files = [_][2][]const u8{
        .{ "config.ini", p.config },         .{ "rules", p.rules },               .{ "mcp.ini", p.mcp },
        .{ "triggers.ini", p.triggers },     .{ "tasks.ini", p.tasks },           .{ "briefs.ini", p.briefs },
        .{ "folders.ini", p.folders },       .{ "environments.ini", p.environments }, .{ "logins.ini", p.logins },
        .{ "home.ini", try std.fs.path.join(a, &.{ env.home, "home.ini" }) }, .{ "car.ini", try std.fs.path.join(a, &.{ env.home, "car.ini" }) },
    };
    for (files) |f| {
        const t0 = read(env, a, f[1]);
        if (t0.len == 0) continue;
        try o.print(a, "\n== {s} ==\n{s}{s}", .{ f[0], t0, if (std.mem.endsWith(u8, t0, "\n")) "" else "\n" });
    }
    // the workflows, whole (the butler's routines among them)
    if (Io.Dir.cwd().openDir(env.io, p.workflows, .{ .iterate = true })) |dir_c| {
        var dir = dir_c;
        defer dir.close(env.io);
        var it = dir.iterate();
        while (it.next(env.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".wf")) continue;
            const t0 = dir.readFileAlloc(env.io, e.name, a, .limited(1 << 20)) catch continue;
            try o.print(a, "\n== workflows/{s} ==\n{s}{s}", .{ e.name, t0, if (std.mem.endsWith(u8, t0, "\n")) "" else "\n" });
        }
    } else |_| {}
    try o.print(a, "\n== state/status ==\n{s}", .{read(env, a, p.status)});
    // the log's last 200 lines
    const log_text = Io.Dir.cwd().readFileAlloc(env.io, p.log, a, .limited(256 << 20)) catch "";
    var lines: std.ArrayList([]const u8) = .empty;
    var li = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log_text, "\n"), '\n');
    while (li.next()) |l| if (l.len > 0) try lines.append(a, l);
    try o.print(a, "\n== the log's last {d} lines ==\n", .{@min(lines.items.len, 200)});
    for (lines.items[lines.items.len -| 200 ..]) |l| try o.print(a, "{s}\n", .{l});
    var mask = try scrub.Scrubber.init(a, try storedSecrets(a, env));
    return redact(a, try mask.scrubAlloc(a, o.items));
}

/// What looks like a secret no store names: a Telegram bot token
/// (digits:35 more), a password in an address (`://user:pass@`).
fn redact(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        // ://user:pass@host
        if (std.mem.startsWith(u8, s[i..], "://")) {
            const rest = s[i + 3 ..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n\"'/") orelse rest.len;
            if (std.mem.indexOfScalar(u8, rest[0..end], '@')) |at| {
                try o.appendSlice(a, "://[removed]@");
                i += 3 + at + 1;
                continue;
            }
        }
        // a bot token: 6 to 12 digits, a colon, 30 or more of [A-Za-z0-9_-]
        if (std.ascii.isDigit(s[i]) and (i == 0 or !std.ascii.isAlphanumeric(s[i - 1]))) {
            var j = i;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j - i >= 6 and j - i <= 12 and j < s.len and s[j] == ':') {
                var k = j + 1;
                while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_' or s[k] == '-')) k += 1;
                if (k - j - 1 >= 30) {
                    try o.appendSlice(a, "[a bot token, removed]");
                    i = k;
                    continue;
                }
            }
        }
        try o.append(a, s[i]);
        i += 1;
    }
    return o.items;
}

// ---- tests ----

const t = std.testing;
const fake_mcp = @import("fake_mcp.zig");

/// A data folder at the fake server, its store in `e`.
const Fold = struct {
    e: model.TestEnv,
    env: Env,
    p: core.Paths,

    fn init(f: *Fold, cfg_extra: []const u8) !void {
        try f.e.init();
        const a = f.e.arena.allocator();
        const home = try std.fs.path.join(a, &.{ f.e.dir, "home" });
        try core.initHome(t.io, a, home);
        f.p = try core.Paths.init(a, home);
        const url = try f.e.url();
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.config, .data = try std.fmt.allocPrint(a, "[model]\nurl = {s}\n[search]\nurl = {s}\n[chat]\napi = {s}\n{s}", .{ url, url, url, cfg_extra }) });
        f.env = .{ .gpa = t.allocator, .io = t.io, .home = home, .store = .{ .dir = try std.fs.path.join(a, &.{ f.e.dir, "secrets" }) }, .now_s = util.nowSeconds(t.io) };
    }

    fn deinit(f: *Fold) void {
        f.e.deinit();
    }

    fn lineOf(f: *Fold, lines: []const Line, name: []const u8) !Line {
        _ = f;
        for (lines) |l| if (std.mem.eql(u8, l.name, name)) return l;
        return error.NoSuchLine;
    }
};

fn expectLine(lines: []const Line, name: []const u8, ok: bool, has: []const u8) !void {
    for (lines) |l| if (std.mem.eql(u8, l.name, name) and std.mem.indexOf(u8, l.text, has) != null) {
        if (l.ok != ok) {
            std.debug.print("{s}: {s} is {s}\n", .{ name, l.text, if (l.ok) "ok" else "not ok" });
            return error.TestUnexpectedResult;
        }
        return;
    };
    std.debug.print("no line {s} with {s} in:\n", .{ name, has });
    for (lines) |l| std.debug.print("  {s}: {s}\n", .{ l.name, l.text });
    return error.TestUnexpectedResult;
}

test "doctor_names_each_broken_piece" {
    var f: Fold = undefined;
    try f.init("[voice]\nprovider = groq\nmodel = whisper-large-v3-turbo\n[provider groq]\napi = openai\nurl = https://api.groq.com/openai/v1\n");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    // the home: its token is a wrong one; the car: its secret not stored
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.mcp, .data = try std.fmt.allocPrint(a, "[home]\ncommand = \"{s}\" \"{s}/home.ini\"\nsecret = HA_TOKEN:ha\nmoney = home_guarded\namount = home_guarded:none\n[car]\ncommand = \"{s}\" \"{s}/car.ini\"\nsecret = SMARTCAR_CLIENT_SECRET:smartcar\n", .{ fake, f.env.home, fake, f.env.home }) });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ f.env.home, "home.ini" }), .data = fake_mcp.discovered_home });
    try f.env.store.put(t.io, "ha", "a-wrong-token-12345");
    // a trigger paused
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.triggers, .data = "[news]\nfeed = https://z.org/f\nsay = {title}\n" });
    try Io.Dir.cwd().createDirPath(t.io, try std.fs.path.join(a, &.{ f.p.triggers_state, "news" }));
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ f.p.triggers_state, "news", "state" }), .data = "{\"polled\":true,\"paused\":\"its source answered 401\"}" });
    const lines = try check(a, f.env);
    try expectLine(lines, "harness run", false, "not running. Start it: harness run");
    try expectLine(lines, "Settings", true, "every file reads");
    try expectLine(lines, "Bot", false, "no bot token stored. Store the one @BotFather gave you: harness secret add telegram");
    try expectLine(lines, "Model", false, "no omnigate key is stored (harness secret add omnigate)");
    try expectLine(lines, "Home", false, "check says: Home Assistant at http://127.0.0.1:8123 refused the token (HA_TOKEN). Fix it, or /setup home again");
    try expectLine(lines, "Car", false, "its secret smartcar is not stored: harness secret add smartcar");
    try expectLine(lines, "Triggers", false, "news is paused: its source answered 401. In the chat: /trigger resume news");
    try expectLine(lines, "Voice notes", false, "no groq key stored. harness secret add groq");
    try expectLine(lines, "Quiet hours", true, "off. In the chat: /quiet on");
    try t.expect(!allOk(lines));
    // a stored secret never in what it says
    try t.expect(std.mem.indexOf(u8, try text(a, lines), "a-wrong-token-12345") == null);
}

test "doctor_says_where_routines_commands_run_and_when_they_cannot" {
    var f: Fold = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const name = "Routines' commands";
    // the built-in sandbox, where one can be made
    if (try sandbox.unavailable(t.io, a) == null)
        try expectLine(try check(a, f.env), name, true, "run in sandbox (sandbox; workspace rw, no network), by " ++ sandbox.backend);
    // none can: said, with both ways out
    sandbox.unavailable_override = "install bubblewrap (the bwrap command) to use sandboxes";
    defer sandbox.unavailable_override = null;
    try expectLine(try check(a, f.env), name, false, "are refused on this machine: they run in sandbox, a sandbox, and install bubblewrap (the bwrap command) to use sandboxes. Fix that; or keep them on this machine with unattended = host under [default] in environments.ini, then /reload");
    // on the host by the owner's own line: nothing wrong
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.environments, .data = "[default]\nunattended = host\n" });
    try expectLine(try check(a, f.env), name, true, "run on this machine (environments.ini: unattended = host)");
    // a remote
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.environments, .data = "[default]\nunattended = far\n[far]\nkind = remote\nhost = a@192.0.2.1\n" });
    try expectLine(try check(a, f.env), name, true, "run in far (remote a@192.0.2.1)");
}

test "doctor_says_all_is_well_when_it_is" {
    var f: Fold = undefined;
    try f.init("[butler]\nquiet = 22:00-07:00\n");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try f.env.store.put(t.io, "omnigate", "og-doctor-key-1");
    try f.env.store.put(t.io, "telegram", "123:doctor-telegram-token");
    try f.env.store.put(t.io, "ha", fake_mcp.ha_test_token);
    try f.env.store.put(t.io, "smartcar", fake_mcp.smartcar_test_secret);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.owner, .data = "42" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.mcp, .data = try std.fmt.allocPrint(a, "[home]\ncommand = \"{s}\" \"{s}/home.ini\"\nsecret = HA_TOKEN:ha\n[car]\ncommand = \"{s}\" \"{s}/car.ini\"\nsecret = SMARTCAR_CLIENT_SECRET:smartcar\n", .{ fake, f.env.home, fake, f.env.home }) });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ f.env.home, "home.ini" }), .data = fake_mcp.discovered_home });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ f.env.home, "car.ini" }), .data = "[car]\nname = The car\n" });
    try f.e.script(1, model.textReply("ok"));
    const lines = try check(a, f.env);
    try expectLine(lines, "Bot", true, "answers; you are paired");
    try expectLine(lines, "Model", true, "claude-sonnet at omnigate answers");
    try expectLine(lines, "Home", true, "Test flat: 7 devices in 4 rooms. Home Assistant at http://127.0.0.1:8123. Changes come in as they happen");
    try expectLine(lines, "Car", true, "answers: battery 34 %, data from 5 minutes ago");
    try expectLine(lines, "Triggers", true, "none in triggers.ini");
    try expectLine(lines, "Voice notes", true, "off");
    try expectLine(lines, "Quiet hours", true, "22:00–07:00; only urgent things come through then");
    // the one short request carried the key, as harness's own would
    try t.expect(std.mem.indexOf(u8, try f.e.request(1), "og-doctor-key-1") != null);
}

test "report_holds_no_secret" {
    var f: Fold = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const values = [_][2][]const u8{
        .{ "omnigate", "og-report-key-1234" },          .{ "telegram", "7654321:report-telegram-token-abcdefghijklmnop" },
        .{ "search", "brave-report-key-1" },            .{ "ha", "ha-report-token-123456" },
        .{ "smartcar", "smartcar-report-secret-1" },    .{ "github", "ghp_reportgithubtoken1234" },
        .{ "shop-db", "postgres-report-password-1" },   .{ "login-bot-password", "bot-report-password-1" },
        // stored, and no setting names it
        .{ "spare", "spare-report-value-1" },
    };
    for (values) |v| try f.env.store.put(t.io, v[0], v[1]);
    // the settings name them (as they should) and, by mistake, hold them
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.mcp, .data = "[github]\nurl = https://api.githubcopilot.com/mcp/\ntoken = github\n; pasted here by mistake: ghp_reportgithubtoken1234 and spare-report-value-1\n" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.folders, .data = "[shop]\nvars = DATABASE_URL:shop-db\n" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.logins, .data = "[bot]\nsite = example.com\nusername = bot\n" });
    const cfg = read(f.env, a, f.p.config);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.config, .data = try std.fmt.allocPrint(a, "{s}; my key, pasted: og-report-key-1234 and the bot's 7654321:report-telegram-token-abcdefghijklmnop\n", .{cfg}) });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ f.env.home, "home.ini" }), .data = "[home]\nurl = http://user:hunter2-report@192.168.1.5:8123\n" });
    // a log whose lines hold them (as an older harness might have written)
    try Io.Dir.cwd().createDirPath(t.io, f.p.log_dir);
    var log: std.ArrayList(u8) = .empty;
    for (0..250) |i| try log.print(a, "{{\"n\":{d},\"text\":\"line {d}\"}}\n", .{ i, i });
    for (values) |v| try log.print(a, "{{\"text\":\"leaked {s}\"}}\n", .{v[1]});
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.p.log, .data = log.items });
    const r = try report(a, f.env, "0.3.0", "Bot: no bot token stored.\n");
    for (values) |v| if (std.mem.indexOf(u8, r, v[1]) != null) {
        std.debug.print("{s}'s value is in the report\n", .{v[0]});
        return error.TestUnexpectedResult;
    };
    try t.expect(std.mem.indexOf(u8, r, "hunter2-report") == null);
    // what it holds: the version, doctor's lines, the settings, the log's last 200
    for ([_][]const u8{ "Version: harness 0.3.0", "== harness doctor ==\nBot: no bot token stored.", "== config.ini ==", "[secret:omnigate]", "== mcp.ini ==\n[github]", "token = github", "== the log's last 200 lines ==", "[secret:ha]", "://[removed]@192.168.1.5:8123" }) |w| if (std.mem.indexOf(u8, r, w) == null) {
        std.debug.print("no {s} in the report:\n{s}\n", .{ w, r });
        return error.TestUnexpectedResult;
    };
    // the last 200 of 250 numbered lines and the leaked ones after them
    const first = 250 + values.len - 200;
    try t.expect(std.mem.indexOf(u8, r, try std.fmt.allocPrint(a, "{{\"n\":{d},", .{first - 1})) == null);
    try t.expect(std.mem.indexOf(u8, r, try std.fmt.allocPrint(a, "{{\"n\":{d},", .{first})) != null);
}
