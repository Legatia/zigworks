//! The `web` tool: an interactive headless Chrome for the model, one
//! session per turn. With a login it uses the login's own profile (its
//! cookies stay) and a software security key holding the login's passkeys.
//! Login values are typed by placeholder, only into pages on the login's
//! site; the model never sees them.
const std = @import("std");
const builtin = @import("builtin");
const cdp = @import("cdp.zig");
const logins = @import("logins.zig");
const totp = @import("totp.zig");
const page = @import("page.zig");
const scrub = @import("scrub.zig");
const store_mod = @import("store.zig");
const gate = @import("gate.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const model = @import("model.zig");
const tools = @import("tools.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const is_windows = builtin.os.tag == .windows;

pub const Output = tools.Output;

pub const Env = struct {
    browser: []const u8,
    /// All of the browser's environment (PATH and HOME of harness's own).
    chrome_env: page.BrowserEnv = .{},
    /// The data folder's `profiles/`: one folder per login.
    profiles: []const u8,
    /// Where a throwaway profile goes.
    tmp_root: []const u8,
    timeout_ms: u32 = 30_000,
    max_bytes: u32 = 16384,
    logins: []const logins.Login = &.{},
    store: ?store_mod.Store = null,
    /// Masked in everything returned (stored login values among them).
    secrets: []const scrub.Secret = &.{},
    stop: *std.atomic.Value(bool),
};

/// What the tool asks of the run it is part of.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// The gate for `web` (argument: the page's host) or `login` ("NAME
    /// HOST"); null when allowed, else why not.
    allow: *const fn (ctx: *anyopaque, arena: Allocator, tool: gate.Tool, arg: []const u8) ?[]const u8,
    /// A line for the log: "web fill", "web fill refused", "web passkey
    /// saved", "web passkey removed"; names and hosts only.
    note: *const fn (ctx: *anyopaque, event: []const u8, login: []const u8, detail: []const u8) void,
    /// A value made here (a new password): masked in every tool's output
    /// from now on, not only in web's.
    secret: ?*const fn (ctx: *anyopaque, name: []const u8, value: []const u8) void = null,
};

pub fn toolDef(arena: Allocator, list: []const logins.Login) !model.ToolDef {
    var d: std.ArrayList(u8) = .empty;
    try d.appendSlice(arena,
        \\An interactive browser. Actions: open (a url, optionally with one of your logins), type (into an element by ref; enter: true presses Enter after), click (ref), key (Enter, Tab or Escape), read, close. Every action returns the page: its address, its interactive elements numbered by ref, and its text. One session per turn; it closes when the turn ends. A new tab or window a page opens is closed at once (you are told its address); downloads are refused.
        \\To sign in, open with `login` (its own cookies and passkeys) and type placeholders: {login:NAME.username}, {login:NAME.password}, {login:NAME.code} (the current one-time code). They are filled in only on the login's site; you never see the values. A login without a password gets a new one the first time its password placeholder is typed on its site (for signing up). Passkeys made on the login's site are kept for it. CAPTCHAs and codes sent by SMS or e-mail: ask the owner.
    );
    if (list.len == 0) {
        try d.appendSlice(arena, "\nYou have no logins.");
    } else {
        try d.appendSlice(arena, "\nYour logins:");
        for (list) |l| try d.print(arena, "\n- {s}: {s}{s}{s}", .{ l.name, l.site, if (l.username.len > 0) ", username " else "", l.username });
    }
    return .{
        .name = "web",
        .description = d.items,
        .schema_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["open","type","click","key","read","close"]},"url":{"type":"string"},"login":{"type":"string","description":"open: the login to use"},"ref":{"type":"integer"},"text":{"type":"string"},"enter":{"type":"boolean"},"key":{"type":"string","enum":["Enter","Tab","Escape"]}},"required":["action"]}
        ,
    };
}

// A login's profile can be used by one browser at a time.
var busy_mutex: Io.Mutex = .init;
var busy_names: std.StringHashMapUnmanaged(void) = .empty;

fn claim(io: Io, name: []const u8) bool {
    busy_mutex.lockUncancelable(io);
    defer busy_mutex.unlock(io);
    if (busy_names.contains(name)) return false;
    const k = std.heap.page_allocator.dupe(u8, name) catch return false;
    busy_names.put(std.heap.page_allocator, k, {}) catch {
        std.heap.page_allocator.free(k);
        return false;
    };
    return true;
}

fn release(io: Io, name: []const u8) void {
    busy_mutex.lockUncancelable(io);
    defer busy_mutex.unlock(io);
    if (busy_names.fetchRemove(name)) |kv| std.heap.page_allocator.free(kv.key);
}

pub const Web = struct {
    gpa: Allocator,
    io: Io,
    env: Env,
    hooks: Hooks,
    /// Lives as long as the Web (one turn).
    arena: std.heap.ArenaAllocator,
    s: ?*cdp.Session = null,
    login: ?logins.Login = null,
    /// A throwaway profile to delete at close.
    throwaway: ?[]const u8 = null,
    granted_host: []const u8 = "",
    /// "NAME HOST" pairs the gate allowed in this session.
    login_ok: std.ArrayList([]const u8) = .empty,
    /// Values handed out in this turn, masked like stored secrets.
    extra: std.ArrayList(scrub.Secret) = .empty,
    auth_id: []const u8 = "",
    /// The login's passkeys as last stored.
    stored: []logins.Passkey = &.{},
    /// The stored passkeys could not be read: never overwrite them.
    passkeys_bad: bool = false,
    /// Said with the next result.
    notes: std.ArrayList(u8) = .empty,
    /// Why the last snapshot was refused (error.HostRefused).
    refused: []const u8 = "",
    /// Every login's stored password and TOTP seed were read for masking.
    loaded_all: bool = false,
    /// The TOTP seeds (raw), by login, for masking their current codes.
    seeds: std.ArrayList(struct { name: []const u8, seed: []const u8 }) = .empty,

    pub fn init(gpa: Allocator, io: Io, env: Env, hooks: Hooks) Web {
        return .{ .gpa = gpa, .io = io, .env = env, .hooks = hooks, .arena = .init(gpa) };
    }

    pub fn deinit(w: *Web) void {
        w.close();
        for (w.extra.items) |x| std.crypto.secureZero(u8, @constCast(x.value));
        for (w.seeds.items) |x| std.crypto.secureZero(u8, @constCast(x.seed));
        w.arena.deinit();
    }

    /// Ends the session: the browser, the throwaway profile, the grants.
    pub fn close(w: *Web) void {
        if (w.s) |s| {
            // a passkey made since the last action is not lost
            if (!s.inbox.closed.load(.acquire) and !w.env.stop.load(.acquire)) {
                var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
                defer arena_state.deinit();
                w.syncPasskeys(arena_state.allocator()) catch {};
            }
            s.destroy();
            w.s = null;
        }
        if (w.login) |l| release(w.io, l.name);
        w.login = null;
        if (w.throwaway) |p| removeTree(w.io, p);
        w.throwaway = null;
        w.granted_host = "";
        w.login_ok.clearRetainingCapacity();
        w.auth_id = "";
        w.stored = &.{};
        w.passkeys_bad = false;
    }

    pub fn active(w: *const Web) bool {
        return w.s != null;
    }

    /// One action; every one but close returns the page afterwards.
    pub fn run(w: *Web, a: Allocator, input_json: []const u8) !Output {
        w.notes.clearRetainingCapacity();
        const raw = w.runRaw(a, input_json) catch |e| blk: {
            const detail = if (w.s) |s| s.lastError() else "";
            break :blk Output{ .text = try std.fmt.allocPrint(a, "failed: {s}{s}{s}", .{ @errorName(e), if (detail.len > 0) ": " else "", detail }), .is_error = true };
        };
        // a browser that died or was stopped is no use for the next action
        if (w.s) |s| if (s.inbox.closed.load(.acquire)) w.close();
        const masked = try w.mask(a, raw.text);
        if (masked.len <= w.env.max_bytes) return .{ .text = masked, .is_error = raw.is_error };
        const cut = util.cut(masked, w.env.max_bytes);
        return .{ .text = try std.fmt.allocPrint(a, "{s}\n[page cut at {d} bytes of {d}]", .{ cut, w.env.max_bytes, masked.len }), .is_error = raw.is_error };
    }

    /// Reads every login's password and TOTP seed once a turn, so the
    /// output masks them even when they were stored after harness started.
    fn loadAll(w: *Web) void {
        if (w.loaded_all) return;
        w.loaded_all = true;
        const st = w.env.store orelse return;
        const wa = w.arena.allocator();
        for (w.env.logins) |l| for ([_]logins.Kind{ .password, .totp }) |k| {
            var nb: [96]u8 = undefined;
            const name = logins.secretName(&nb, l.name, k);
            const raw = (st.get(w.io, w.gpa, name) catch null) orelse continue;
            defer {
                std.crypto.secureZero(u8, raw);
                w.gpa.free(raw);
            }
            const v = w.keepValue(name, std.mem.trim(u8, raw, " \r\n\t")) catch continue;
            if (k != .totp) continue;
            var buf: [128]u8 = undefined;
            defer std.crypto.secureZero(u8, &buf);
            const seed = totp.base32Decode(&buf, v) catch continue;
            w.seeds.append(wa, .{ .name = wa.dupe(u8, l.name) catch continue, .seed = wa.dupe(u8, seed) catch continue }) catch {};
        };
    }

    fn mask(w: *Web, a: Allocator, text: []const u8) ![]const u8 {
        var sc = try w.scrubber(a);
        return sc.scrubAlloc(a, text);
    }

    /// Masks every login value known in this turn (see mask).
    fn scrubber(w: *Web, a: Allocator) !scrub.Scrubber {
        w.loadAll();
        var all: std.ArrayList(scrub.Secret) = .empty;
        try all.appendSlice(a, w.env.secrets);
        try all.appendSlice(a, w.extra.items);
        // the current one-time code of every login, and the one before
        const now = util.nowSeconds(w.io);
        for (w.seeds.items) |sd| for ([_]i64{ now, now - totp.step_s }) |at| {
            const c = totp.code(sd.seed, at);
            try all.append(a, .{ .name = try std.fmt.allocPrint(a, "login-{s}-code", .{sd.name}), .value = try a.dupe(u8, &c) });
        };
        return scrub.Scrubber.init(a, all.items);
    }

    fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) !Output {
        return .{ .text = try std.fmt.allocPrint(a, fmt, args), .is_error = true };
    }

    fn runRaw(w: *Web, a: Allocator, input_json: []const u8) !Output {
        if (is_windows) return fail(a, "the web tool is not available on Windows yet", .{});
        const v = jv.parse(a, input_json) orelse return fail(a, "the input is not JSON", .{});
        const action = jv.str(jv.get(v, "action")) orelse return fail(a, "say which action: open, type, click, key, read or close", .{});
        const eql = std.mem.eql;
        if (eql(u8, action, "close")) {
            w.close();
            return .{ .text = "closed" };
        }
        if (eql(u8, action, "open")) return w.open(a, jv.str(jv.get(v, "url")) orelse return fail(a, "open needs a url", .{}), jv.str(jv.get(v, "login")));
        if (w.s == null) return fail(a, "no page is open; start with open", .{});
        if (try w.checkHost(a)) |why| return fail(a, "{s}", .{why});
        var said: []const u8 = "";
        if (eql(u8, action, "read")) {
            // nothing to do
        } else if (eql(u8, action, "type")) {
            const ref = jv.int(jv.get(v, "ref")) orelse return fail(a, "type needs a ref", .{});
            const text = jv.str(jv.get(v, "text")) orelse return fail(a, "type needs text", .{});
            const r = try w.typeInto(a, ref, text);
            if (r.is_error) return r;
            said = r.text;
            if (jv.boolean(jv.get(v, "enter")) orelse false) {
                const m = w.s.?.mark();
                try w.pressKey(a, "Enter");
                try w.s.?.settle(a, m);
            }
        } else if (eql(u8, action, "click")) {
            const ref = jv.int(jv.get(v, "ref")) orelse return fail(a, "click needs a ref", .{});
            const m = w.s.?.mark();
            if (try w.click(a, ref)) |why| return fail(a, "{s}", .{why});
            try w.s.?.settle(a, m);
        } else if (eql(u8, action, "key")) {
            const key = jv.str(jv.get(v, "key")) orelse return fail(a, "key needs Enter, Tab or Escape", .{});
            if (!(eql(u8, key, "Enter") or eql(u8, key, "Tab") or eql(u8, key, "Escape"))) return fail(a, "key needs Enter, Tab or Escape", .{});
            const m = w.s.?.mark();
            try w.pressKey(a, key);
            try w.s.?.settle(a, m);
        } else return fail(a, "unknown action {s}; use open, type, click, key, read or close", .{util.cut(action, 40)});
        return w.after(a, said);
    }

    /// Passkeys, the gate for where the page is now, then the page.
    fn after(w: *Web, a: Allocator, said: []const u8) !Output {
        try w.syncPasskeys(a);
        // a load under way now (one that began later than the action
        // waited for one, from a timer, say): the page once it has loaded,
        // or as far as it got in the time allowed
        if (w.s.?.inbox.loading(w.io).busy) w.s.?.waitLoaded(a) catch |e| switch (e) {
            error.Timeout => {},
            else => return e,
        };
        const text = w.snapshot(a, said) catch |e| switch (e) {
            error.HostRefused => return fail(a, "{s}", .{w.refused}),
            else => return e,
        };
        return .{ .text = text };
    }

    fn open(w: *Web, a: Allocator, url: []const u8, login_name: ?[]const u8) !Output {
        // as the page's location.host will have it, so that the grants,
        // the login's key and the later checks all name the same host
        const host = try pageHost(a, url) orelse return fail(a, "only http and https addresses can be opened", .{});
        const want: ?logins.Login = if (login_name) |n| (logins.find(w.env.logins, n) orelse return fail(a, "no login called {s}", .{util.cut(n, 60)})) else null;
        if (w.hooks.allow(w.hooks.ctx, a, .web, host)) |why| return fail(a, "refused by the gate: {s}", .{why});
        // the same session goes on if it has the same login
        const same = if (w.s == null) false else if (want) |l| (w.login != null and std.mem.eql(u8, w.login.?.name, l.name)) else w.login == null;
        if (!same) {
            w.close();
            if (want) |l| {
                const key = try std.fmt.allocPrint(a, "{s} {s}", .{ l.name, host });
                if (w.hooks.allow(w.hooks.ctx, a, .login, key)) |why| return fail(a, "refused by the gate: {s}", .{why});
                if (!claim(w.io, l.name)) return fail(a, "the login {s} is in use by another run; try again when it ends", .{l.name});
                w.login = l;
                try w.login_ok.append(w.arena.allocator(), try w.arena.allocator().dupe(u8, key));
            }
            try w.start(a);
        }
        w.granted_host = try w.arena.allocator().dupe(u8, host);
        try w.s.?.navigate(a, url);
        return w.after(a, "");
    }

    fn start(w: *Web, a: Allocator) !void {
        const profile = if (w.login) |l| blk: {
            // a data folder from before 0.3 has no profiles/ yet
            try Io.Dir.cwd().createDirPath(w.io, w.env.profiles);
            try setPrivate(w.io, w.env.profiles);
            const p = try std.fs.path.join(a, &.{ w.env.profiles, l.name });
            try Io.Dir.cwd().createDirPath(w.io, p);
            try setPrivate(w.io, p);
            break :blk p;
        } else blk: {
            // (the first one also removes those a killed run left)
            const p = try page.newProfile(w.io, w.arena.allocator(), w.env.tmp_root, "harness-web-");
            w.throwaway = p;
            break :blk p;
        };
        try page.prepareProfile(w.io, a, profile);
        // a login's cookies stay, those that end with the session too; its
        // last tabs don't come back
        if (w.login != null) try cdp.forgetLastTabs(w.io, a, profile);
        w.s = try cdp.Session.open(w.gpa, w.io, w.env.browser, profile, w.env.stop, w.env.timeout_ms, .{ .env = w.env.chrome_env, .keep_session = w.login != null });
        if (w.login) |l| try w.loadPasskeys(a, l);
    }

    // ---- passkeys ----

    fn loadPasskeys(w: *Web, a: Allocator, l: logins.Login) !void {
        const s = w.s.?;
        _ = try s.call(a, "WebAuthn.enable", "{\"enableUI\":false}");
        const res = try s.call(a, "WebAuthn.addVirtualAuthenticator",
            \\{"options":{"protocol":"ctap2","transport":"internal","hasResidentKey":true,"hasUserVerification":true,"isUserVerified":true,"automaticPresenceSimulation":true}}
        );
        w.auth_id = try w.arena.allocator().dupe(u8, jv.str(jv.get(res, "authenticatorId")) orelse return error.Cdp);
        const st = w.env.store orelse return;
        var nb: [96]u8 = undefined;
        const raw = st.get(w.io, w.gpa, logins.secretName(&nb, l.name, .passkeys)) catch {
            w.passkeys_bad = true;
            try w.notes.appendSlice(w.arena.allocator(), "The stored passkeys of this login could not be read from the key store; none were loaded, and a new one would not be saved.\n");
            return;
        } orelse return;
        defer {
            std.crypto.secureZero(u8, raw);
            w.gpa.free(raw);
        }
        const list = logins.decode(w.arena.allocator(), raw) catch {
            w.passkeys_bad = true;
            try w.notes.appendSlice(w.arena.allocator(), "The stored passkeys of this login could not be read; none were loaded, and a new one would not be saved.\n");
            return;
        };
        w.stored = list;
        for (list) |pk| {
            if (!logins.rpIdAllowed(l.site, pk.rp_id)) continue;
            var p: std.ArrayList(u8) = .empty;
            try p.appendSlice(a, "{\"authenticatorId\":");
            try util.jsonString(&p, a, w.auth_id);
            try p.appendSlice(a, ",\"credential\":{\"credentialId\":");
            try util.jsonString(&p, a, pk.id);
            try p.appendSlice(a, ",\"isResidentCredential\":true,\"rpId\":");
            try util.jsonString(&p, a, pk.rp_id);
            try p.appendSlice(a, ",\"privateKey\":");
            try util.jsonString(&p, a, pk.key);
            if (pk.user.len > 0) {
                try p.appendSlice(a, ",\"userHandle\":");
                try util.jsonString(&p, a, pk.user);
            }
            try p.print(a, ",\"signCount\":{d}}}}}", .{pk.count});
            _ = try s.call(a, "WebAuthn.addCredential", p.items);
        }
    }

    /// Reads the security key's credentials back: those for another site
    /// are removed, new or used ones of the login's site are stored.
    fn syncPasskeys(w: *Web, a: Allocator) !void {
        const l = w.login orelse return;
        if (w.auth_id.len == 0) return;
        const s = w.s.?;
        var p: std.ArrayList(u8) = .empty;
        try p.appendSlice(a, "{\"authenticatorId\":");
        try util.jsonString(&p, a, w.auth_id);
        try p.append(a, '}');
        const res = try s.call(a, "WebAuthn.getCredentials", p.items);
        const creds = jv.arr(jv.get(res, "credentials")) orelse return;
        var found: std.ArrayList(logins.Passkey) = .empty;
        for (creds) |c| {
            const pk: logins.Passkey = .{
                .id = jv.str(jv.get(c, "credentialId")) orelse continue,
                .rp_id = jv.str(jv.get(c, "rpId")) orelse "",
                .key = jv.str(jv.get(c, "privateKey")) orelse continue,
                .user = jv.str(jv.get(c, "userHandle")) orelse "",
                .count = @intCast(std.math.clamp(jv.int(jv.get(c, "signCount")) orelse 0, 0, std.math.maxInt(u32))),
            };
            try found.append(a, pk);
        }
        const f = try filterPasskeys(a, l.site, found.items);
        for (f.drop) |pk| {
            var rp: std.ArrayList(u8) = .empty;
            try rp.appendSlice(a, "{\"authenticatorId\":");
            try util.jsonString(&rp, a, w.auth_id);
            try rp.appendSlice(a, ",\"credentialId\":");
            try util.jsonString(&rp, a, pk.id);
            try rp.append(a, '}');
            _ = s.call(a, "WebAuthn.removeCredential", rp.items) catch {};
            w.hooks.note(w.hooks.ctx, "web passkey removed", l.name, pk.rp_id);
            try w.notes.print(w.arena.allocator(), "A passkey for {s} was removed: this login is for {s}.\n", .{ pk.rp_id, l.site });
        }
        const merged = try mergePasskeys(a, w.stored, f.keep);
        if (!merged.changed) return;
        if (w.passkeys_bad) {
            // the stored list could not be read: writing would replace it
            for (merged.added) |rp| try w.notes.print(w.arena.allocator(), "A passkey for {s} was made but not saved: the stored passkeys of this login could not be read.\n", .{rp});
        } else {
            const st = w.env.store orelse return;
            var nb: [96]u8 = undefined;
            const json = try logins.encode(a, merged.list);
            defer std.crypto.secureZero(u8, @constCast(json));
            st.put(w.io, logins.secretName(&nb, l.name, .passkeys), json) catch {
                try w.notes.appendSlice(w.arena.allocator(), "A new passkey could not be saved to the key store.\n");
                return;
            };
            for (merged.added) |rp| {
                w.hooks.note(w.hooks.ctx, "web passkey saved", l.name, rp);
                try w.notes.print(w.arena.allocator(), "A passkey for {s} was saved for this login.\n", .{rp});
            }
        }
        // the new list, kept for the next comparison (said once)
        const keep = try w.arena.allocator().alloc(logins.Passkey, merged.list.len);
        const wa = w.arena.allocator();
        for (merged.list, 0..) |pk, i| keep[i] = .{ .id = try wa.dupe(u8, pk.id), .rp_id = try wa.dupe(u8, pk.rp_id), .key = try wa.dupe(u8, pk.key), .user = try wa.dupe(u8, pk.user), .count = pk.count };
        w.stored = keep;
    }

    // ---- typing ----

    const Loc = struct { protocol: []const u8, host: []const u8, hostname: []const u8, href: []const u8 };

    fn location(w: *Web, a: Allocator) !Loc {
        const r = try w.s.?.evaluateIsolated(a, "({protocol: location.protocol, host: location.host, hostname: location.hostname, href: location.href})");
        const v = jv.parse(a, r);
        return .{
            .protocol = jv.str(jv.get(v, "protocol")) orelse "",
            .host = jv.str(jv.get(v, "host")) orelse "",
            .hostname = jv.str(jv.get(v, "hostname")) orelse "",
            .href = jv.str(jv.get(v, "href")) orelse "",
        };
    }

    /// The gate for the page's host when it is not the one last granted;
    /// null when the page may be used.
    fn checkHost(w: *Web, a: Allocator) !?[]const u8 {
        const loc = try w.location(a);
        if (std.mem.eql(u8, loc.protocol, "about:")) return null;
        if (!std.mem.eql(u8, loc.protocol, "http:") and !std.mem.eql(u8, loc.protocol, "https:")) return try std.fmt.allocPrint(a, "the page went to a {s} address; only http and https pages can be used", .{util.cut(loc.protocol, 20)});
        if (std.ascii.eqlIgnoreCase(loc.host, w.granted_host)) return null;
        if (w.hooks.allow(w.hooks.ctx, a, .web, loc.host)) |why| return try std.fmt.allocPrint(a, "the page is now on {s}: refused by the gate: {s}", .{ loc.host, why });
        w.granted_host = try w.arena.allocator().dupe(u8, loc.host);
        return null;
    }

    fn typeInto(w: *Web, a: Allocator, ref: i64, text: []const u8) !Output {
        const spans = logins.placeholders(a, text) catch return fail(a, "a placeholder is not valid; use {{login:NAME.username}}, {{login:NAME.password}} or {{login:NAME.code}}", .{});
        if (spans.len == 0) return w.fill(a, ref, text, &.{}, &.{}, null, "");
        // a value goes in alone: no text around it, one per field, so it
        // can't be made part of a message or a comment
        if (spans.len > 1 or spans[0].start != 0 or spans[0].end != text.len)
            return fail(a, "a login placeholder must be the whole text, one per type action", .{});
        const loc = try w.location(a);
        // every login named, checked before any value is fetched
        var used: std.ArrayList(logins.Login) = .empty;
        for (spans) |sp| {
            const l = logins.find(w.env.logins, sp.login) orelse return fail(a, "no login called {s}", .{sp.login});
            for (used.items) |u| {
                if (std.mem.eql(u8, u.name, l.name)) break;
            } else try used.append(a, l);
        }
        for (used.items) |l| if (!logins.hostAllowed(l.site, loc.protocol, loc.hostname)) {
            w.hooks.note(w.hooks.ctx, "web fill refused", l.name, loc.host);
            return fail(a, "Not typed: the page is on {s}//{s}, and the login {s} is for {s}{s}.", .{ loc.protocol, loc.host, l.name, if (std.mem.eql(u8, l.site, "localhost")) "" else "https://", l.site });
        };
        for (used.items) |l| {
            const key = try std.fmt.allocPrint(a, "{s} {s}", .{ l.name, loc.host });
            const ok = for (w.login_ok.items) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (ok) continue;
            if (w.hooks.allow(w.hooks.ctx, a, .login, key)) |why| return fail(a, "refused by the gate: {s}", .{why});
            try w.login_ok.append(w.arena.allocator(), try w.arena.allocator().dupe(u8, key));
        }
        var out: std.ArrayList(u8) = .empty;
        defer std.crypto.secureZero(u8, out.items);
        var made = false;
        var last: usize = 0;
        for (spans) |sp| {
            try out.appendSlice(a, text[last..sp.start]);
            last = sp.end;
            const l = logins.find(w.env.logins, sp.login).?;
            const val = w.value(a, l, sp.field, &made) catch |e| return switch (e) {
                error.NoUsername => fail(a, "the login {s} has no username in logins.ini", .{l.name}),
                error.NoTotp => fail(a, "the login {s} has no one-time code seed stored", .{l.name}),
                error.NoStore => fail(a, "no key store is available", .{}),
                error.BadSeed => fail(a, "the one-time code seed of {s} is not valid base32", .{l.name}),
                else => e,
            };
            try out.appendSlice(a, val);
        }
        try out.appendSlice(a, text[last..]);
        var sites: std.ArrayList([]const u8) = .empty;
        for (used.items) |l| try sites.append(a, l.site);
        // the host the gate allowed the login on, not just any on its site
        const r = try w.fill(a, ref, out.items, sites.items, used.items, spans[0].field, loc.host);
        if (made and !r.is_error) try w.notes.appendSlice(w.arena.allocator(), "A new password was made and stored for this login.\n");
        return r;
    }

    /// The value of one placeholder; a missing password is made here.
    fn value(w: *Web, a: Allocator, l: logins.Login, field: logins.Field, made: *bool) ![]const u8 {
        switch (field) {
            .username => return if (l.username.len > 0) l.username else error.NoUsername,
            .password => {
                const st = w.env.store orelse return error.NoStore;
                var nb: [96]u8 = undefined;
                const name = logins.secretName(&nb, l.name, .password);
                if (try st.get(w.io, w.gpa, name)) |raw| {
                    defer {
                        std.crypto.secureZero(u8, raw);
                        w.gpa.free(raw);
                    }
                    return w.keepValue(name, raw);
                }
                // the site was checked before: this is its sign-up page
                var pw = try logins.genPassword(w.io);
                defer std.crypto.secureZero(u8, &pw);
                try st.put(w.io, name, &pw);
                if (w.hooks.secret) |h| h(w.hooks.ctx, name, &pw);
                made.* = true;
                return w.keepValue(name, &pw);
            },
            .code => {
                const st = w.env.store orelse return error.NoStore;
                var nb: [96]u8 = undefined;
                const name = logins.secretName(&nb, l.name, .totp);
                const raw = (try st.get(w.io, w.gpa, name)) orelse return error.NoTotp;
                defer {
                    std.crypto.secureZero(u8, raw);
                    w.gpa.free(raw);
                }
                _ = try w.keepValue(name, std.mem.trim(u8, raw, " \r\n\t"));
                var seed_buf: [128]u8 = undefined;
                defer std.crypto.secureZero(u8, &seed_buf);
                const seed = totp.base32Decode(&seed_buf, std.mem.trim(u8, raw, " \r\n\t")) catch return error.BadSeed;
                const c = totp.code(seed, util.nowSeconds(w.io));
                const cname = try std.fmt.allocPrint(a, "login-{s}-code", .{l.name});
                return w.keepValue(cname, &c);
            },
        }
    }

    /// A copy that lives for the turn and is masked in every result.
    fn keepValue(w: *Web, name: []const u8, v: []const u8) ![]const u8 {
        const wa = w.arena.allocator();
        for (w.extra.items) |x| if (std.mem.eql(u8, x.value, v)) return x.value;
        const copy = try wa.dupe(u8, v);
        try w.extra.append(wa, .{ .name = try wa.dupe(u8, name), .value = copy });
        return copy;
    }

    /// One script in the page checks where it is and types (see
    /// fillScript); `sites` empty: no check (no login value in the text).
    /// `host`: the one the gate allowed the login on.
    fn fill(w: *Web, a: Allocator, ref: i64, text: []const u8, sites: []const []const u8, used: []const logins.Login, field: ?logins.Field, host: []const u8) !Output {
        const script = try fillScript(a, ref, text, sites, field, host);
        defer std.crypto.secureZero(u8, @constCast(script));
        const r = try w.s.?.evaluateIsolated(a, script);
        const res = jv.str(jv.parse(a, r)) orelse "";
        if (std.mem.eql(u8, res, "ok")) {
            for (used) |l| w.hooks.note(w.hooks.ctx, "web fill", l.name, host);
            return .{ .text = try std.fmt.allocPrint(a, "Typed into [{d}].", .{ref}) };
        }
        if (std.mem.startsWith(u8, res, "wrong-site")) {
            for (used) |l| w.hooks.note(w.hooks.ctx, "web fill refused", l.name, util.cut(res["wrong-site".len..], 200));
            return fail(a, "Not typed: the page moved to{s}, which is not the login's site.", .{util.cut(res["wrong-site".len..], 200)});
        }
        if (std.mem.eql(u8, res, "not-a-field")) return fail(a, "[{d}] is not a field that takes text", .{ref});
        if (std.mem.startsWith(u8, res, "wrong-field")) {
            for (used) |l| w.hooks.note(w.hooks.ctx, "web fill refused", l.name, host);
            return fail(a, "Not typed: a {s} goes only into {s}; [{d}] is a{s}.", .{ @tagName(field.?), switch (field.?) {
                .password => "a password field",
                .username => "a text or e-mail field",
                .code => "a text, number or phone field, or one marked for one-time codes",
            }, ref, util.cut(res["wrong-field".len..], 40) });
        }
        return fail(a, "no element [{d}] on the page; read it again", .{ref});
    }

    /// A click as a person's: the mouse pressed and released at the
    /// element's centre, scrolled into view first. Not when something else
    /// is on top of it there (a banner, a dialog): why not, then.
    fn click(w: *Web, a: Allocator, ref: i64) !?[]const u8 {
        const s = w.s.?;
        const r = jv.parse(a, try s.evaluateIsolated(a, try refScript(a, ref, click_point_body)));
        if (jv.str(r)) |no| {
            if (std.mem.eql(u8, no, "no-element")) return try std.fmt.allocPrint(a, "no element [{d}] on the page; read it again", .{ref});
            if (std.mem.startsWith(u8, no, "covered ")) return try std.fmt.allocPrint(a, "[{d}] is under another element where it would be clicked ({s}); close or answer that first", .{ ref, util.cut(no["covered ".len..], 100) });
            return try std.fmt.allocPrint(a, "[{d}] can't be clicked: it takes no room on the page", .{ref});
        }
        const x = jv.num(jv.get(r, "x")) orelse return error.Script;
        const y = jv.num(jv.get(r, "y")) orelse return error.Script;
        const steps = [_][2][]const u8{
            .{ "mouseMoved", "" },
            .{ "mousePressed", ",\"button\":\"left\",\"buttons\":1,\"clickCount\":1" },
            .{ "mouseReleased", ",\"button\":\"left\",\"buttons\":0,\"clickCount\":1" },
        };
        for (steps) |st| _ = try s.call(a, "Input.dispatchMouseEvent", try std.fmt.allocPrint(a, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d}{s}}}", .{ st[0], x, y, st[1] }));
        return null;
    }

    fn pressKey(w: *Web, a: Allocator, key: []const u8) !void {
        const s = w.s.?;
        const Key = struct { code: u8, text: []const u8 };
        const k: Key = if (std.mem.eql(u8, key, "Enter")) .{ .code = 13, .text = "\r" } else if (std.mem.eql(u8, key, "Tab")) .{ .code = 9, .text = "" } else .{ .code = 27, .text = "" };
        const down = try std.fmt.allocPrint(a, "{{\"type\":\"{s}\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"nativeVirtualKeyCode\":{d}{s}{s}{s}}}", .{
            if (k.text.len > 0) "keyDown" else "rawKeyDown", key, key, k.code, k.code,
            if (k.text.len > 0) ",\"text\":\"" else "",         if (k.text.len > 0) "\\r" else "",
            if (k.text.len > 0) "\"" else "",
        });
        _ = try s.call(a, "Input.dispatchKeyEvent", down);
        const up = try std.fmt.allocPrint(a, "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"nativeVirtualKeyCode\":{d}}}", .{ key, key, k.code, k.code });
        _ = try s.call(a, "Input.dispatchKeyEvent", up);
    }

    // ---- the page ----

    fn snapshot(w: *Web, a: Allocator, said: []const u8) ![]const u8 {
        const r = try w.s.?.evaluateIsolated(a, snapshot_script);
        const v = jv.parse(a, r);
        // the host of the very document read, not of an earlier check: its
        // text reaches the model only if the gate allowed that host
        const protocol = jv.str(jv.get(v, "protocol")) orelse "";
        const host = jv.str(jv.get(v, "host")) orelse "";
        if (!std.mem.eql(u8, protocol, "about:")) {
            const why: ?[]const u8 = if (!std.mem.eql(u8, protocol, "http:") and !std.mem.eql(u8, protocol, "https:"))
                try std.fmt.allocPrint(a, "the page went to a {s} address; only http and https pages can be used", .{util.cut(protocol, 20)})
            else if (std.ascii.eqlIgnoreCase(host, w.granted_host))
                null
            else if (w.hooks.allow(w.hooks.ctx, a, .web, host)) |no|
                try std.fmt.allocPrint(a, "the page is now on {s}: refused by the gate: {s}", .{ host, no })
            else blk: {
                w.granted_host = try w.arena.allocator().dupe(u8, host);
                break :blk null;
            };
            if (why) |x| {
                w.refused = x;
                _ = w.s.?.navigate(a, "about:blank") catch {};
                return error.HostRefused;
            }
        }
        const url = jv.str(jv.get(v, "url")) orelse "";
        const html = jv.str(jv.get(v, "html")) orelse "";
        var out: std.ArrayList(u8) = .empty;
        if (said.len > 0) try out.print(a, "{s}\n", .{said});
        try out.appendSlice(a, w.notes.items);
        const downloads = try w.s.?.inbox.takeDownloads(w.io, w.gpa);
        defer {
            for (downloads) |d| w.gpa.free(d);
            w.gpa.free(downloads);
        }
        for (downloads) |d| try out.print(a, "A download was refused (downloads are off): {s}\n", .{util.cut(d, 300)});
        // new tabs and windows: closed before they load anything
        const tabs = try w.s.?.inbox.takeTabs(w.io, w.gpa);
        defer w.s.?.inbox.freeTabs(w.gpa, tabs);
        for (tabs) |x| {
            if (x.state != .closing) {
                var p: std.ArrayList(u8) = .empty;
                try p.appendSlice(a, "{\"targetId\":");
                try util.jsonString(&p, a, x.target);
                try p.append(a, '}');
                _ = w.s.?.callIn(a, "Target.closeTarget", p.items, null) catch {};
            }
            if (x.url.len > 0)
                try out.print(a, "A new tab for {s} was closed before it loaded; open that address to go there.\n", .{util.cut(x.url, 300)})
            else
                try out.appendSlice(a, "A new tab the page opened was closed.\n");
        }
        const dialogs = try w.s.?.inbox.takeDialogs(w.io, a);
        for (dialogs) |d| {
            defer d.free(w.gpa);
            // its text only from the host the gate allowed (not a frame of
            // another, not a page that was refused)
            const from = try pageHost(a, d.url) orelse "";
            if (from.len == 0) {
                try out.print(a, "A dialog ({s}) from a frame with no web address was answered; its text is not shown.\n", .{d.kind});
                continue;
            }
            if (!std.ascii.eqlIgnoreCase(from, w.granted_host)) {
                try out.print(a, "A dialog ({s}) from another host ({s}) was answered; its text is not shown.\n", .{ d.kind, util.cut(from, 200) });
                continue;
            }
            try out.print(a, "Dialog ({s}): {s}{s}\n", .{ d.kind, d.message, if (std.mem.eql(u8, d.kind, "alert") or std.mem.eql(u8, d.kind, "beforeunload")) "" else " (dismissed)" });
        }
        try out.print(a, "URL: {s}\nTitle: {s}\n", .{ url, util.cut(jv.str(jv.get(v, "title")) orelse "", 300) });
        const items = jv.arr(jv.get(v, "items")) orelse &.{};
        if (items.len > 0) try out.appendSlice(a, "Elements:\n");
        // labels are masked before they are escaped: an escaped value
        // (a quote, a backslash) would no longer match
        var sc = try w.scrubber(a);
        for (items) |it| {
            const tag = jv.str(jv.get(it, "tag")) orelse "";
            const typ = jv.str(jv.get(it, "type")) orelse "";
            try out.print(a, "[{d}] {s}{s}{s} ", .{ jv.int(jv.get(it, "ref")) orelse 0, tag, if (typ.len > 0) " " else "", typ });
            try util.jsonString(&out, a, try sc.scrubAlloc(a, jv.str(jv.get(it, "label")) orelse ""));
            try out.append(a, '\n');
        }
        const p = page.extract(a, html, url) catch page.Page{ .title = "", .text = "" };
        try out.print(a, "\n{s}", .{p.text});
        // cut by run(), after masking: a cut must not leave half a value
        return out.items;
    }
};

/// The host of an http or https `url` as the page's `location.host` gives
/// it: lowercase, without user info or the scheme's default port. Null for
/// any other address.
pub fn pageHost(a: Allocator, url: []const u8) !?[]const u8 {
    const hp = page.urlHostPort(url) orelse return null;
    var host = hp.host;
    const default_port = if (hp.https) ":443" else ":80";
    if (std.mem.endsWith(u8, host, default_port)) host = host[0 .. host.len - default_port.len];
    if (host.len == 0) return null;
    return try std.ascii.allocLowerString(a, host);
}

/// `hxAll(sel)`: the elements of the top document matching `sel`, open
/// shadow roots included (each right after its host), in page order.
const deep_js =
    \\const hxAll = (sel) => {
    \\  const out = [];
    \\  const walk = (root) => { for (const el of root.querySelectorAll('*')) { if (el.matches(sel)) out.push(el); if (el.shadowRoot) walk(el.shadowRoot); } };
    \\  walk(document);
    \\  return out;
    \\};
    \\
;

/// Marks the top document's interactive elements (those in open shadow
/// roots too) with data-hx-ref and lists them; the page's HTML for its
/// text. Never reads a field's value.
const snapshot_script =
    \\(() => {
++ deep_js ++
    \\  for (const el of hxAll('[data-hx-ref]')) el.removeAttribute('data-hx-ref');
    \\  const items = [];
    \\  let n = 0;
    \\  for (const el of hxAll('input, textarea, select, button, a[href], [role=button]')) {
    \\    const tag = el.tagName.toLowerCase();
    \\    const type = tag === 'input' ? (el.getAttribute('type') || 'text').toLowerCase() : (tag === 'button' ? (el.getAttribute('type') || 'submit').toLowerCase() : '');
    \\    if (type === 'hidden' || el.getClientRects().length === 0) continue;
    \\    n += 1;
    \\    el.setAttribute('data-hx-ref', String(n));
    \\    let label = el.getAttribute('aria-label') || '';
    \\    if (!label && el.labels && el.labels.length > 0) label = el.labels[0].innerText || '';
    \\    if (!label) label = el.getAttribute('placeholder') || '';
    \\    if (!label && tag === 'input' && (type === 'submit' || type === 'button' || type === 'reset')) label = el.getAttribute('value') || type;
    \\    if (!label && tag !== 'input' && tag !== 'textarea' && tag !== 'select') label = el.innerText || '';
    \\    if (!label) label = el.getAttribute('name') || el.getAttribute('title') || '';
    \\    label = label.replace(/\s+/g, ' ').trim().slice(0, 80);
    \\    items.push({ref: n, tag, type: tag === 'a' ? '' : type, label});
    \\    if (n >= 300) break;
    \\  }
    \\  return {protocol: location.protocol, host: location.host, url: location.href, title: document.title, html: document.documentElement ? document.documentElement.outerHTML.slice(0, 4194304) : '', items};
    \\})()
;

/// Where to click `el`: the centre of the first of its boxes where it (or
/// what is in it, or its label) is what a click there would hit, after
/// scrolling it into view; else 'covered WHAT', or 'no-room'.
const click_point_body =
    \\el.scrollIntoView({block: 'center', inline: 'center'});
    \\const root = el.getRootNode();
    \\const hits = (h) => h && (h === el || el.contains(h) || (el.labels && Array.from(el.labels).some((l) => l === h || l.contains(h))));
    \\const boxes = Array.from(el.getClientRects()).filter((b) => b.width > 0 && b.height > 0);
    \\for (const b of boxes) {
    \\  const x = b.left + b.width / 2, y = b.top + b.height / 2;
    \\  if (hits(root.elementFromPoint(x, y))) return {x, y};
    \\}
    \\if (el.labels) for (const l of el.labels) for (const b of Array.from(l.getClientRects())) {
    \\  const x = b.left + b.width / 2, y = b.top + b.height / 2;
    \\  if (b.width > 0 && b.height > 0 && hits(root.elementFromPoint(x, y))) return {x, y};
    \\}
    \\if (boxes.length === 0) return 'no-room';
    \\const top = root.elementFromPoint(boxes[0].left + boxes[0].width / 2, boxes[0].top + boxes[0].height / 2);
    \\return 'covered ' + (top ? top.tagName.toLowerCase() + ' "' + (top.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 60) + '"' : 'by nothing it can reach');
;

/// `body` runs with `el` the element marked `ref`; 'no-element' if none.
fn refScript(a: Allocator, ref: i64, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "(() => {{\n{s}const el = hxAll('[data-hx-ref=\"{d}\"]')[0]; if (!el) return 'no-element'; {s} }})()", .{ deep_js, ref, body });
}

/// Checks that the page is on every one of `sites` (the rules of
/// logins.hostAllowed, with string indexing and comparisons only) and on
/// `host`, the very host the gate allowed (unless empty: no login value),
/// then sets the field's value with its prototype's own setter and sends
/// input and change. Check and fill are one script: no navigation can come
/// between them. It runs in an isolated world, where the page can't have
/// changed `location` or the prototypes it uses.
fn fillScript(a: Allocator, ref: i64, value: []const u8, sites: []const []const u8, field: ?logins.Field, host: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "(() => {\nconst approved = ");
    try util.jsonString(&out, a, host);
    try out.appendSlice(a, ";\nif (approved !== '' && location.host !== approved) return 'wrong-site ' + location.protocol + '//' + location.host;\nconst sites = [");
    for (sites, 0..) |s, i| {
        if (i > 0) try out.append(a, ',');
        try util.jsonString(&out, a, s);
    }
    try out.appendSlice(a,
        \\];
        \\const p = location.protocol, h = location.hostname;
        \\for (let i = 0; i < sites.length; i++) {
        \\  const s = sites[i];
        \\  const scheme = p === 'https:' || (p === 'http:' && s === 'localhost');
        \\  let under = h === s;
        \\  if (!under && h.length > s.length + 1 && h[h.length - s.length - 1] === '.') {
        \\    under = true;
        \\    for (let j = 0; j < s.length; j++) if (h[h.length - s.length + j] !== s[j]) { under = false; break; }
        \\  }
        \\  if (!scheme || !under) return 'wrong-site ' + p + '//' + location.host;
        \\}
        \\if (window !== window.top) return 'wrong-site (a frame)';
        \\
    );
    try out.appendSlice(a, deep_js);
    try out.print(a, "const el = hxAll('[data-hx-ref=\"{d}\"]')[0];\n", .{ref});
    try out.appendSlice(a,
        \\if (!el) return 'no-element';
        \\let proto = null;
        \\if (el instanceof HTMLInputElement) proto = HTMLInputElement.prototype;
        \\else if (el instanceof HTMLTextAreaElement) proto = HTMLTextAreaElement.prototype;
        \\else if (el instanceof HTMLSelectElement) proto = HTMLSelectElement.prototype;
        \\if (!proto) return 'not-a-field';
        \\const kind = el instanceof HTMLInputElement ? el.type : (el instanceof HTMLTextAreaElement ? 'textarea' : 'select');
        \\const field = '
    );
    try out.appendSlice(a, if (field) |x| @tagName(x) else "");
    try out.appendSlice(a,
        \\';
        \\const fits = field === '' ||
        \\  (field === 'password' && kind === 'password') ||
        \\  (field === 'username' && (kind === 'text' || kind === 'email')) ||
        \\  (field === 'code' && el instanceof HTMLInputElement && (kind === 'text' || kind === 'number' || kind === 'tel' || el.getAttribute('autocomplete') === 'one-time-code'));
        \\if (!fits) return 'wrong-field ' + kind;
        \\el.focus();
        \\Object.getOwnPropertyDescriptor(proto, 'value').set.call(el,
    );
    try util.jsonString(&out, a, value);
    try out.appendSlice(a,
        \\);
        \\el.dispatchEvent(new Event('input', {bubbles: true}));
        \\el.dispatchEvent(new Event('change', {bubbles: true}));
        \\return 'ok';
        \\})()
    );
    return out.items;
}

pub const Filtered = struct { keep: []const logins.Passkey, drop: []const logins.Passkey };

/// Splits credentials into those the login may hold and the rest.
pub fn filterPasskeys(a: Allocator, site: []const u8, list: []const logins.Passkey) !Filtered {
    var keep: std.ArrayList(logins.Passkey) = .empty;
    var drop: std.ArrayList(logins.Passkey) = .empty;
    for (list) |pk| try (if (logins.rpIdAllowed(site, pk.rp_id)) &keep else &drop).append(a, pk);
    return .{ .keep = keep.items, .drop = drop.items };
}

const Merged = struct { list: []const logins.Passkey, changed: bool, added: []const []const u8 };

/// The stored list updated with what the security key holds now: new
/// credentials added, sign counts raised. Stored ones it lacks stay.
fn mergePasskeys(a: Allocator, stored: []const logins.Passkey, now: []const logins.Passkey) !Merged {
    var list: std.ArrayList(logins.Passkey) = .empty;
    try list.appendSlice(a, stored);
    var added: std.ArrayList([]const u8) = .empty;
    var changed = false;
    for (now) |pk| {
        for (list.items) |*old| {
            if (!std.mem.eql(u8, old.id, pk.id)) continue;
            if (pk.count > old.count) {
                old.count = pk.count;
                changed = true;
            }
            break;
        } else {
            try list.append(a, pk);
            try added.append(a, pk.rp_id);
            changed = true;
        }
    }
    return .{ .list = list.items, .changed = changed, .added = added.items };
}

fn setPrivate(io: Io, path: []const u8) !void {
    if (is_windows) return;
    var d = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer d.close(io);
    try d.setPermissions(io, .fromMode(0o700));
}

/// The browser's helpers may still be writing as they die: a few tries.
fn removeTree(io: Io, path: []const u8) void {
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        Io.Dir.cwd().deleteTree(io, path) catch {
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        return;
    }
}

// ---- tests ----

const t = std.testing;

const Fix = struct {
    e: model.TestEnv,
    stop: std.atomic.Value(bool) = .init(false),
    store: store_mod.Store,
    notes: std.ArrayList(u8) = .empty,
    asked: std.ArrayList(u8) = .empty,
    /// What the gate refuses: a tool's name, or "" for nothing.
    refuse: []const u8 = "",
    /// Where the page goes while the gate is asked about a login (a
    /// navigation between the check and the fill).
    move_to: []const u8 = "",
    web: Web,
    browser: []const u8,

    fn init(f: *Fix, logins_ini: []const u8) !void {
        try f.e.init();
        errdefer f.e.deinit();
        const a = f.e.arena.allocator();
        f.browser = (try cdp.testBrowser(a)) orelse return error.SkipZigTest;
        f.stop = .init(false);
        f.notes = .empty;
        f.asked = .empty;
        f.refuse = "";
        f.move_to = "";
        f.store = .{ .dir = try std.fs.path.join(a, &.{ f.e.dir, "secrets" }) };
        try f.e.tmp.dir.createDirPath(t.io, "profiles");
        try f.e.tmp.dir.createDirPath(t.io, "tmp");
        f.web = Web.init(t.allocator, t.io, .{
            .browser = f.browser,
            .profiles = try std.fs.path.join(a, &.{ f.e.dir, "profiles" }),
            .tmp_root = try std.fs.path.join(a, &.{ f.e.dir, "tmp" }),
            .timeout_ms = 20_000,
            .logins = try logins.parse(a, logins_ini),
            .store = f.store,
            .stop = &f.stop,
        }, .{ .ctx = f, .allow = allowFn, .note = noteFn });
    }

    fn deinit(f: *Fix) void {
        f.web.deinit();
        f.notes.deinit(t.allocator);
        f.asked.deinit(t.allocator);
        f.e.deinit();
    }

    fn allowFn(ctx: *anyopaque, arena: Allocator, tool: gate.Tool, arg: []const u8) ?[]const u8 {
        const f: *Fix = @ptrCast(@alignCast(ctx));
        f.asked.print(t.allocator, "{s} {s}\n", .{ @tagName(tool), arg }) catch {};
        if (tool == .login and f.move_to.len > 0) {
            f.web.s.?.navigate(arena, f.move_to) catch {};
            f.move_to = "";
        }
        if (std.mem.eql(u8, f.refuse, @tagName(tool))) return "denied by the owner";
        return null;
    }

    fn noteFn(ctx: *anyopaque, event: []const u8, login: []const u8, detail: []const u8) void {
        const f: *Fix = @ptrCast(@alignCast(ctx));
        f.notes.print(t.allocator, "{s} {s} {s}\n", .{ event, login, detail }) catch {};
    }

    fn page(f: *Fix, name: []const u8, html: []const u8) !void {
        const p = try std.fmt.allocPrint(f.e.arena.allocator(), "pages/{s}", .{name});
        try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = html });
    }

    fn url(f: *Fix, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.e.arena.allocator(), "http://localhost:{d}/page/{s}", .{ f.e.server.port, name });
    }

    fn act(f: *Fix, json: []const u8) !Output {
        return f.web.run(f.e.arena.allocator(), json);
    }

    fn openJson(f: *Fix, name: []const u8, login: ?[]const u8) ![]const u8 {
        const a = f.e.arena.allocator();
        if (login) |l| return std.fmt.allocPrint(a, "{{\"action\":\"open\",\"url\":\"{s}\",\"login\":\"{s}\"}}", .{ try f.url(name), l });
        return std.fmt.allocPrint(a, "{{\"action\":\"open\",\"url\":\"{s}\"}}", .{try f.url(name)});
    }

    fn eval(f: *Fix, expr: []const u8) ![]const u8 {
        return f.web.s.?.evaluate(f.e.arena.allocator(), expr);
    }

    fn stored(f: *Fix, name: []const u8) !?[]u8 {
        return f.store.get(t.io, f.e.arena.allocator(), name);
    }
};

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (has(hay, needle)) return;
    std.debug.print("\nexpected {s} in:\n{s}\n", .{ needle, hay });
    return error.TestExpectedEqual;
}

const login_page =
    \\<html><head><title>Sign in</title></head><body>
    \\<form id="f"><label for="user">Email</label><input id="user" name="user">
    \\<label for="pw">Password</label><input id="pw" type="password" name="pw">
    \\<input type="hidden" name="csrf" value="x"><button type="submit">Sign in</button></form>
    \\<p id="out"></p>
    \\<script>
    \\document.getElementById('f').addEventListener('submit', (e) => {
    \\  e.preventDefault();
    \\  const ok = document.getElementById('pw').value === 'fake-Pass-7351!';
    \\  document.getElementById('out').textContent = ok ? 'welcome ' + document.getElementById('user').value : 'wrong password';
    \\});
    \\</script></body></html>
;

test "web_fills_a_login_on_its_site" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    try f.store.put(t.io, "login-agent-password", "fake-Pass-7351!");
    try f.page("login.html", login_page);
    const opened = try f.act(try f.openJson("login.html", "agent"));
    try t.expect(!opened.is_error);
    try expectHas(opened.text, "Title: Sign in");
    try expectHas(opened.text, "[1] input text \"Email\"");
    try expectHas(opened.text, "[2] input password \"Password\"");
    try expectHas(opened.text, "[3] button submit \"Sign in\"");
    try t.expect(!has(opened.text, "csrf"));
    const r1 = try f.act("{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.username}\"}");
    try expectHas(r1.text, "Typed into [1].");
    const r2 = try f.act("{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.password}\"}");
    try expectHas(r2.text, "Typed into [2].");
    const r3 = try f.act("{\"action\":\"click\",\"ref\":3}");
    try expectHas(r3.text, "welcome agent-bot");
    for ([_][]const u8{ opened.text, r1.text, r2.text, r3.text, f.notes.items, f.asked.items }) |s| try t.expect(!has(s, "fake-Pass-7351!"));
    try expectHas(f.notes.items, "web fill agent localhost:");
    try expectHas(f.asked.items, "login agent localhost:");
    // the login's profile is kept, private
    if (is_windows) return else {
        const st = try f.e.tmp.dir.statFile(t.io, "profiles/agent", .{});
        try t.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

/// Whether any file below `dir` holds `needle`.
fn treeHas(io: Io, a: Allocator, dir: []const u8, needle: []const u8) !bool {
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const data = d.readFileAlloc(io, e.path, a, .limited(64 << 20)) catch continue;
        if (has(data, needle)) return true;
    }
    return false;
}

/// The names in `dir` (relative to the test's folder), or "" if it is not there.
fn listDir(f: *Fix, dir: []const u8) ![]const u8 {
    const a = f.e.arena.allocator();
    var d = f.e.tmp.dir.openDir(t.io, dir, .{ .iterate = true }) catch return "";
    defer d.close(t.io);
    var out: std.ArrayList(u8) = .empty;
    var it = d.iterate();
    while (try it.next(t.io)) |e| try out.print(a, "{s} ", .{e.name});
    return out.items;
}

test "web_refuses_downloads_and_says_so" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\n");
    defer f.deinit();
    // where a download would land (never the real Downloads folder)
    try f.e.tmp.dir.createDirPath(t.io, "dl");
    try f.e.tmp.dir.createDirPath(t.io, "profiles/agent/Default");
    const prefs = try std.fmt.allocPrint(f.e.arena.allocator(), "{{\"download\":{{\"default_directory\":\"{s}/dl\",\"prompt_for_download\":false}}}}", .{f.e.dir});
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "profiles/agent/Default/Preferences", .data = prefs });
    try f.page("get.html", "<html><body><a href=\"/page/file.bin\">get it</a></body></html>");
    try f.page("file.bin", "\x00\x01 some bytes");
    _ = try f.act(try f.openJson("get.html", "agent"));
    const r = try f.act("{\"action\":\"click\",\"ref\":1}");
    // a finished download would be there by now
    var tries: u32 = 0;
    while (tries < 30 and (try listDir(&f, "dl")).len == 0) : (tries += 1) t.io.sleep(.fromMilliseconds(100), .awake) catch {};
    try t.expectEqualStrings("", try listDir(&f, "dl"));
    try t.expectEqualStrings("", try listDir(&f, "profiles/agent/Downloads"));
    try expectHas(r.text, "A download was refused");
    try expectHas(r.text, "/page/file.bin");
}

test "web_login_cookies_survive_to_the_next_browser" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\n");
    defer f.deinit();
    try f.page("c.html", "<html><body><p>cookies</p></body></html>");
    _ = try f.act(try f.openJson("c.html", "agent"));
    // one that expires in an hour (as a site's \"remember me\")
    _ = try f.eval("document.cookie = 'kept=1; max-age=3600; path=/'");
    _ = try f.act("{\"action\":\"close\"}");
    _ = try f.act(try f.openJson("c.html", "agent"));
    try expectHas(try f.eval("document.cookie"), "kept=1");
    // a throwaway profile has none of them
    _ = try f.act(try f.openJson("c.html", null));
    try t.expectEqualStrings("\"\"", try f.eval("document.cookie"));
}

test "web_login_session_cookies_survive_and_no_old_tab_comes_back" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\n");
    defer f.deinit();
    try f.page("c.html", "<html><body><p>cookies</p></body></html>");
    try f.page("last.html", "<html><body><script>localStorage.setItem('last', String(Number(localStorage.getItem('last') || 0) + 1))</script></body></html>");
    _ = try f.act(try f.openJson("c.html", "agent"));
    // most sign-ins: a cookie that ends with the session
    _ = try f.eval("document.cookie = 'sid=7; path=/'");
    // the last page of a browser is not opened again by the next one
    _ = try f.act(try f.openJson("last.html", "agent"));
    try t.expectEqualStrings("\"1\"", try f.eval("localStorage.getItem('last')"));
    _ = try f.act("{\"action\":\"close\"}");
    for (0..2) |_| {
        _ = try f.act(try f.openJson("c.html", "agent"));
        try expectHas(try f.eval("document.cookie"), "sid=7");
        try t.expectEqual(1, try pageTargets(&f));
        try t.expectEqualStrings("\"1\"", try f.eval("localStorage.getItem('last')"));
        _ = try f.act("{\"action\":\"close\"}");
    }
}

test "web_profiles_keep_no_saved_passwords" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.store.put(t.io, "login-agent-password", "fake-Pass-7351!");
    try f.page("real.html", "<html><head><title>Sign in</title></head><body><form method=\"post\" action=\"/page/in.html\"><input name=\"user\" autocomplete=\"username\"><input name=\"pw\" type=\"password\" autocomplete=\"current-password\"><button>Sign in</button></form></body></html>");
    try f.page("in.html", "<html><head><title>Welcome</title></head><body><p>signed in</p></body></html>");
    _ = try f.act(try f.openJson("real.html", "agent"));
    _ = try f.act("{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.username}\"}");
    _ = try f.act("{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.password}\"}");
    const r = try f.act("{\"action\":\"click\",\"ref\":3}");
    try expectHas(r.text, "Title: Welcome");
    f.web.close();
    const profile = try std.fs.path.join(a, &.{ f.e.dir, "profiles", "agent" });
    const prefs = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(a, &.{ profile, "Default", "Preferences" }), a, .limited(4 << 20));
    const v = jv.parse(a, prefs);
    try t.expectEqual(false, jv.boolean(jv.get(v, "credentials_enable_service")) orelse true);
    try t.expectEqual(false, jv.boolean(jv.at(v, &.{ "profile", "password_manager_enabled" })) orelse true);
    try t.expect(!try treeHas(t.io, a, profile, "fake-Pass-7351!"));
}

test "web_refuses_a_login_on_another_site" {
    var f: Fix = undefined;
    try f.init("[other]\nsite = example.com\nusername = agent-bot\n");
    defer f.deinit();
    try f.store.put(t.io, "login-other-password", "other-Pass-0042");
    try f.page("login.html", login_page);
    _ = try f.act(try f.openJson("login.html", null));
    const r = try f.act("{\"action\":\"type\",\"ref\":2,\"text\":\"{login:other.password}\"}");
    try t.expect(r.is_error);
    try expectHas(r.text, "Not typed");
    try expectHas(r.text, "example.com");
    try t.expectEqualStrings("\"\"", try f.eval("document.getElementById('pw').value"));
    try expectHas(f.notes.items, "web fill refused other");
    // the gate was never asked for the login: nothing was going to be typed
    try t.expect(!has(f.asked.items, "login other"));
}

test "web_types_a_login_value_only_on_the_host_the_gate_allowed" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\n");
    defer f.deinit();
    try f.store.put(t.io, "login-agent-password", "fake-Pass-7351!");
    try f.page("login.html", login_page);
    // a page that marks its own field the way the snapshot would have
    try f.page("trap.html", "<html><body><input id=\"pw\" type=\"password\" data-hx-ref=\"2\"></body></html>");
    _ = try f.act(try f.openJson("login.html", null));
    // the owner allows the login on localhost; meanwhile the page went to
    // another host under the same site
    f.move_to = try std.fmt.allocPrint(f.e.arena.allocator(), "http://a.localhost:{d}/page/trap.html", .{f.e.server.port});
    const r = try f.act("{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.password}\"}");
    try expectHas(f.asked.items, "login agent localhost:");
    try expectHas(try f.eval("location.host"), "a.localhost:");
    try t.expect(r.is_error);
    try expectHas(r.text, "Not typed");
    try t.expectEqualStrings("\"\"", try f.eval("document.getElementById('pw').value"));
}

test "web_fill_script_refuses_a_page_that_lies_about_its_host" {
    // the page's own globals can't fool the check: it runs in an isolated world
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.page("liar.html",
        \\<html><body><input id="pw"><script>
        \\String.prototype.endsWith = () => true; String.prototype.includes = () => true;
        \\</script></body></html>
    );
    _ = try f.act(try f.openJson("liar.html", null));
    const a = f.e.arena.allocator();
    const here = try std.fmt.allocPrint(a, "localhost:{d}", .{f.e.server.port});
    for ([_][2][]const u8{ .{ "example.com", here }, .{ "calhost", here }, .{ "localhost", "localhost:1" } }) |c| {
        const r = try f.web.s.?.evaluateIsolated(a, try fillScript(a, 1, "must-not-arrive", &.{c[0]}, null, c[1]));
        try t.expect(std.mem.startsWith(u8, r, "\"wrong-site http://localhost:"));
    }
    try t.expectEqualStrings("\"\"", try f.eval("document.getElementById('pw').value"));
    const ok = try f.web.s.?.evaluateIsolated(a, try fillScript(a, 1, "fine", &.{"localhost"}, null, here));
    try t.expectEqualStrings("\"ok\"", ok);
    try t.expectEqualStrings("\"fine\"", try f.eval("document.getElementById('pw').value"));
}

test "web_output_masks_every_login_value_typed_or_not" {
    var f: Fix = undefined;
    try f.init("[a]\nsite = example.com\n[b]\nsite = example.org\n");
    defer f.deinit();
    try f.store.put(t.io, "login-a-password", "stored-Pass-a-991");
    try f.store.put(t.io, "login-b-totp", "JBSWY3DPEHPK3PXP");
    var seed_buf: [32]u8 = undefined;
    const c = totp.code(try totp.base32Decode(&seed_buf, "JBSWY3DPEHPK3PXP"), util.nowSeconds(t.io));
    try f.page("leak.html", try std.fmt.allocPrint(f.e.arena.allocator(), "<html><body><p>pw stored-Pass-a-991 seed JBSWY3DPEHPK3PXP code {s}</p></body></html>", .{&c}));
    const r = try f.act(try f.openJson("leak.html", null));
    try expectHas(r.text, "pw [secret:login-a-password] seed [secret:login-b-totp] code [secret:login-b-code]");
}

test "web_makes_a_password_on_sign_up" {
    var f: Fix = undefined;
    try f.init("[new]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    try f.page("login.html", login_page);
    _ = try f.act(try f.openJson("login.html", "new"));
    try t.expectEqual(null, try f.stored("login-new-password"));
    const r = try f.act("{\"action\":\"type\",\"ref\":2,\"text\":\"{login:new.password}\"}");
    try t.expect(!r.is_error);
    try expectHas(r.text, "A new password was made and stored");
    const pw = (try f.stored("login-new-password")).?;
    try t.expectEqual(24, pw.len);
    const got = try f.eval("document.getElementById('pw').value");
    try t.expectEqualStrings(pw, got[1 .. got.len - 1]);
    try t.expect(!has(r.text, pw));
}

test "web_totp_code_is_current" {
    var f: Fix = undefined;
    try f.init("[t]\nsite = localhost\n");
    defer f.deinit();
    try f.store.put(t.io, "login-t-totp", "JBSWY3DPEHPK3PXP");
    try f.page("code.html",
        \\<html><body><input id="c" aria-label="Code"><p id="shown"></p><script>
        \\document.getElementById('c').addEventListener('input', (e) => { document.getElementById('shown').textContent = 'code ' + e.target.value; });
        \\</script></body></html>
    );
    _ = try f.act(try f.openJson("code.html", "t"));
    const r = try f.act("{\"action\":\"type\",\"ref\":1,\"text\":\"{login:t.code}\"}");
    try t.expect(!r.is_error);
    // the page shows the code, the result masks it
    try expectHas(r.text, "code [secret:login-t-code]");
    const got = try f.eval("document.getElementById('c').value");
    var seed_buf: [32]u8 = undefined;
    const seed = try totp.base32Decode(&seed_buf, "JBSWY3DPEHPK3PXP");
    const now = util.nowSeconds(t.io);
    const want = [_][6]u8{ totp.code(seed, now), totp.code(seed, now - 30) };
    try t.expect(std.mem.eql(u8, got[1..7], &want[0]) or std.mem.eql(u8, got[1..7], &want[1]));
}

const passkey_page =
    \\<html><head><title>Passkeys</title></head><body>
    \\<button id="reg">Register</button><button id="in">Sign in</button><p id="out"></p><script>
    \\const out = (s) => { document.getElementById('out').textContent = s; };
    \\document.getElementById('reg').onclick = async () => {
    \\  try {
    \\    await navigator.credentials.create({publicKey: {
    \\      rp: {id: 'localhost', name: 'Local'},
    \\      user: {id: new TextEncoder().encode('agent-bot'), name: 'agent-bot', displayName: 'Agent'},
    \\      challenge: new Uint8Array(16), pubKeyCredParams: [{type: 'public-key', alg: -7}],
    \\      authenticatorSelection: {residentKey: 'required', userVerification: 'required'}}});
    \\    out('registered');
    \\  } catch (e) { out('failed ' + e.name); }
    \\};
    \\document.getElementById('in').onclick = async () => {
    \\  try {
    \\    const c = await navigator.credentials.get({publicKey: {challenge: new Uint8Array(16), rpId: 'localhost', userVerification: 'required'}});
    \\    out('signed in as ' + new TextDecoder().decode(c.response.userHandle));
    \\  } catch (e) { out('failed ' + e.name); }
    \\};
    \\</script></body></html>
;

/// Reads the page until `needle` shows (an answer that comes a moment later).
fn readUntil(f: *Fix, needle: []const u8) !Output {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const r = try f.act("{\"action\":\"read\"}");
        if (has(r.text, needle) or tries >= 20) return r;
        t.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

test "web_passkey_registers_then_signs_in" {
    var f: Fix = undefined;
    try f.init("[p]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    try f.page("pk.html", passkey_page);
    _ = try f.act(try f.openJson("pk.html", "p"));
    _ = try f.act("{\"action\":\"click\",\"ref\":1}");
    const r1 = try readUntil(&f, "registered");
    try expectHas(r1.text, "registered");
    const a = f.e.arena.allocator();
    const saved = try logins.decode(a, (try f.stored("login-p-passkeys")).?);
    try t.expectEqual(1, saved.len);
    try t.expectEqualStrings("localhost", saved[0].rp_id);
    try expectHas(f.notes.items, "web passkey saved p localhost");
    _ = try f.act("{\"action\":\"close\"}");

    // a new browser, the same login: the passkey signs in
    _ = try f.act(try f.openJson("pk.html", "p"));
    _ = try f.act("{\"action\":\"click\",\"ref\":2}");
    const r2 = try readUntil(&f, "signed in as");
    try expectHas(r2.text, "signed in as agent-bot");
    // the private key never shows
    try t.expect(!has(r1.text, saved[0].key) and !has(r2.text, saved[0].key));
}

test "web_passkey_made_just_before_close_is_kept" {
    var f: Fix = undefined;
    try f.init("[p]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    try f.page("pk.html", passkey_page);
    _ = try f.act(try f.openJson("pk.html", "p"));
    const a = f.e.arena.allocator();
    // made by the page after the last action's read-back (a script, a timer)
    _ = try f.web.s.?.evaluate(a, "document.getElementById('reg').click()");
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        if (std.mem.eql(u8, try f.eval("document.getElementById('out').textContent"), "\"registered\"")) break;
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    f.web.close();
    const saved = try logins.decode(a, (try f.stored("login-p-passkeys")) orelse "");
    try t.expectEqual(1, saved.len);
}

test "web_says_when_the_stored_passkeys_cannot_be_read" {
    var f: Fix = undefined;
    try f.init("[p]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    // the key store fails to read this login's passkeys (a folder where
    // the value should be)
    try f.e.tmp.dir.createDirPath(t.io, "secrets/login-p-passkeys");
    try f.page("pk.html", passkey_page);
    const r0 = try f.act(try f.openJson("pk.html", "p"));
    try expectHas(r0.text, "could not be read");
    // everything said from the click until the page says it registered,
    // and once more
    var said: std.ArrayList(u8) = .empty;
    const a = f.e.arena.allocator();
    try said.appendSlice(a, (try f.act("{\"action\":\"click\",\"ref\":1}")).text);
    var tries: u32 = 0;
    while (!has(said.items, "registered") and tries < 20) : (tries += 1) {
        t.io.sleep(.fromMilliseconds(100), .awake) catch {};
        try said.appendSlice(a, (try f.act("{\"action\":\"read\"}")).text);
    }
    try said.appendSlice(a, (try f.act("{\"action\":\"read\"}")).text);
    try expectHas(said.items, "registered");
    try expectHas(said.items, "was made but not saved");
    // said once, not after every action
    try t.expectEqual(1, std.mem.count(u8, said.items, "not saved"));
    // what is stored was left as it was
    try t.expectEqual(.directory, (try f.e.tmp.dir.statFile(t.io, "secrets/login-p-passkeys", .{})).kind);
}

test "web_passkey_for_another_site_is_removed" {
    var f: Fix = undefined;
    try f.init("[p]\nsite = localhost\n");
    defer f.deinit();
    try f.page("pk.html", passkey_page);
    _ = try f.act(try f.openJson("pk.html", "p"));
    const a = f.e.arena.allocator();
    // a credential for another site, put there behind harness's back
    // (with a real key: one the security key made for this page)
    _ = try f.web.s.?.evaluate(a, "document.getElementById('reg').click()");
    var tries: u32 = 0;
    const made = while (tries < 40) : (tries += 1) {
        const got = try f.web.s.?.call(a, "WebAuthn.getCredentials", try std.fmt.allocPrint(a, "{{\"authenticatorId\":\"{s}\"}}", .{f.web.auth_id}));
        const cs = jv.arr(jv.get(got, "credentials")).?;
        if (cs.len > 0) break cs[0];
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    } else return error.TestUnexpectedResult;
    const key = jv.str(jv.get(made, "privateKey")).?;
    const params = try std.fmt.allocPrint(a, "{{\"authenticatorId\":\"{s}\",\"credential\":{{\"credentialId\":\"ZXZpbC1jcmVk\",\"isResidentCredential\":true,\"rpId\":\"example.com\",\"privateKey\":\"{s}\",\"userHandle\":\"dXNlcg==\",\"signCount\":0}}}}", .{ f.web.auth_id, key });
    _ = try f.web.s.?.call(a, "WebAuthn.addCredential", params);
    const r = try f.act("{\"action\":\"read\"}");
    try expectHas(r.text, "A passkey for example.com was removed");
    try expectHas(f.notes.items, "web passkey removed p example.com");
    // only the one for this site is stored, and only it is left
    const saved = try logins.decode(a, (try f.stored("login-p-passkeys")).?);
    try t.expectEqual(1, saved.len);
    try t.expectEqualStrings("localhost", saved[0].rp_id);
    const left = try f.web.s.?.call(a, "WebAuthn.getCredentials", try std.fmt.allocPrint(a, "{{\"authenticatorId\":\"{s}\"}}", .{f.web.auth_id}));
    const lc = jv.arr(jv.get(left, "credentials")).?;
    try t.expectEqual(1, lc.len);
    try t.expectEqualStrings("localhost", jv.str(jv.get(lc[0], "rpId")).?);
}

test "web_asks_once_for_a_host_written_in_capitals" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.page("login.html", login_page);
    const r0 = try f.act(try std.fmt.allocPrint(a, "{{\"action\":\"open\",\"url\":\"http://LocalHost:{d}/page/login.html\",\"login\":\"agent\"}}", .{f.e.server.port}));
    try t.expect(!r0.is_error);
    const r1 = try f.act("{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.username}\"}");
    try expectHas(r1.text, "Typed into [1].");
    // the host as the page has it: asked once for the page, once for the login
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "web localhost:{d}\nlogin agent localhost:{d}\n", .{ f.e.server.port, f.e.server.port }), f.asked.items);
}

test "web_page_hosts_are_lowercase_without_user_or_default_port" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][2][]const u8{
        .{ "https://GitHub.com/login", "github.com" },
        .{ "https://github.com:443/x", "github.com" },
        .{ "http://Example.org:80", "example.org" },
        .{ "https://example.org:80/", "example.org:80" },
        .{ "http://example.org:443/", "example.org:443" },
        .{ "http://localhost:8080/a?b#c", "localhost:8080" },
        .{ "https://user:pw@Evil.example:443/", "evil.example" },
        .{ "https://github.com\\@evil.example/", "github.com" },
        .{ "HTTPS://[::1]:443/", "[::1]" },
    }) |c| try t.expectEqualStrings(c[1], (try pageHost(a, c[0])).?);
    for ([_][]const u8{ "ftp://x.org/", "https://", "https:///x", "javascript:alert(1)", "https://user@/" }) |u| try t.expectEqual(null, try pageHost(a, u));
}

test "web_asks_the_gate_when_a_click_lands_on_another_host" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    // 127.0.0.1 is another host than localhost
    try f.page("to.html", try std.fmt.allocPrint(a, "<html><body><a href=\"http://127.0.0.1:{d}/page/there.html\">away</a></body></html>", .{f.e.server.port}));
    try f.page("there.html", "<html><body><p>secret page text</p></body></html>");
    _ = try f.act(try f.openJson("to.html", null));
    f.refuse = "web";
    const r = try f.act("{\"action\":\"click\",\"ref\":1}");
    try t.expect(r.is_error);
    try expectHas(r.text, "refused by the gate");
    try t.expect(!has(r.text, "secret page text"));
    try expectHas(f.asked.items, "web 127.0.0.1:");
}

test "web_login_values_go_only_into_matching_fields" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\nusername = agent-bot\n");
    defer f.deinit();
    try f.store.put(t.io, "login-agent-password", "fake-Pass-7351!");
    try f.store.put(t.io, "login-agent-totp", "JBSWY3DPEHPK3PXP");
    try f.page("fields.html",
        \\<html><body><input id="user" aria-label="Name"><input id="pw" type="password" aria-label="Password">
        \\<textarea id="c" aria-label="Comment"></textarea><input id="e" type="email" aria-label="Mail">
        \\<input id="otp" type="text" autocomplete="one-time-code" aria-label="Code"><input id="s" type="search" aria-label="Search"></body></html>
    );
    _ = try f.act(try f.openJson("fields.html", "agent"));
    const refused = [_][]const u8{
        "{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.password}\"}",
        "{\"action\":\"type\",\"ref\":3,\"text\":\"{login:agent.password}\"}",
        "{\"action\":\"type\",\"ref\":3,\"text\":\"{login:agent.username}\"}",
        "{\"action\":\"type\",\"ref\":6,\"text\":\"{login:agent.username}\"}",
        "{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.code}\"}",
        "{\"action\":\"type\",\"ref\":2,\"text\":\"x{login:agent.password}\"}",
        "{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.password}{login:agent.password}\"}",
    };
    for (refused) |j| {
        const r = try f.act(j);
        if (!r.is_error) std.debug.print("\nnot refused: {s}\n", .{j});
        try t.expect(r.is_error);
    }
    try t.expectEqualStrings("[\"\",\"\",\"\",\"\",\"\"]", try f.eval("['user','pw','c','s','otp'].map((i) => document.getElementById(i).value)"));
    for ([_][]const u8{
        "{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.username}\"}",
        "{\"action\":\"type\",\"ref\":4,\"text\":\"{login:agent.username}\"}",
        "{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.password}\"}",
        "{\"action\":\"type\",\"ref\":5,\"text\":\"{login:agent.code}\"}",
    }) |j| {
        const r = try f.act(j);
        if (r.is_error) std.debug.print("\nrefused: {s}\n{s}\n", .{ j, r.text });
        try t.expect(!r.is_error);
    }
}

test "web_output_is_masked_before_it_is_cut" {
    var f: Fix = undefined;
    try f.init("[a]\nsite = example.com\n");
    defer f.deinit();
    try f.store.put(t.io, "login-a-password", "Zq9-fake-Pass-77");
    try f.page("cut.html", "<html><body><p>some words first, then Zq9-fake-Pass-77 and more words after it</p></body></html>");
    const whole = try f.act(try f.openJson("cut.html", null));
    const at = std.mem.indexOf(u8, whole.text, "[secret:login-a-password]").?;
    // a cut in the middle of where the value is on the page
    f.web.env.max_bytes = @intCast(at + 5);
    const r = try f.act("{\"action\":\"read\"}");
    try t.expect(!has(r.text, "Zq9-f"));
    try expectHas(r.text, "[page cut at");
}

test "web_labels_are_masked_before_they_are_escaped" {
    var f: Fix = undefined;
    try f.init("[a]\nsite = example.com\n");
    defer f.deinit();
    try f.store.put(t.io, "login-a-password", "fake\"Pass\\7351x");
    try f.page("label.html", "<html><body><input aria-label='hint fake\"Pass\\7351x'></body></html>");
    const r = try f.act(try f.openJson("label.html", null));
    try expectHas(r.text, "[1] input text \"hint [secret:login-a-password]\"");
    try t.expect(!has(r.text, "7351x"));
}

test "web_answers_dialogs_and_shows_them" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    f.web.env.timeout_ms = 4000;
    try f.page("dlg.html",
        \\<html><body><button onclick="alert('hello there')">Alert</button>
        \\<button onclick="document.getElementById('o').textContent = 'answer ' + (confirm('sure?') ? 'yes' : 'no')">Ask</button>
        \\<p id="o"></p></body></html>
    );
    _ = try f.act(try f.openJson("dlg.html", null));
    const r1 = try f.act("{\"action\":\"click\",\"ref\":1}");
    try t.expect(!r1.is_error);
    try expectHas(r1.text, "Dialog (alert): hello there");
    const r2 = try f.act("{\"action\":\"click\",\"ref\":2}");
    try t.expect(!r2.is_error);
    try expectHas(r2.text, "Dialog (confirm): sure?");
    try expectHas(r2.text, "answer no");
    try t.expect(!has(r2.text, "hello there"));
}

test "web_shows_no_dialog_text_from_a_host_not_allowed" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    // a frame from another host (127.0.0.1) on an allowed page (localhost)
    try f.page("framed.html", try std.fmt.allocPrint(a, "<html><body><p>outer page</p><iframe src=\"http://127.0.0.1:{d}/page/inner.html\"></iframe></body></html>", .{f.e.server.port}));
    try f.page("inner.html", "<html><body><script>alert('iframe secret text')</script></body></html>");
    const r = try f.act(try f.openJson("framed.html", null));
    try expectHas(r.text, "outer page");
    try t.expect(!has(r.text, "iframe secret text"));
    try expectHas(r.text, "from another host (127.0.0.1:");
    // a refused page's dialog doesn't come out later either
    try f.page("loud.html", "<html><body><script>alert('refused page text')</script></body></html>");
    try f.page("to.html", try std.fmt.allocPrint(a, "<html><body><a href=\"http://127.0.0.1:{d}/page/loud.html\">away</a></body></html>", .{f.e.server.port}));
    _ = try f.act(try f.openJson("to.html", null));
    f.refuse = "web";
    const r2 = try f.act("{\"action\":\"click\",\"ref\":1}");
    try t.expect(r2.is_error);
    f.refuse = "";
    const r3 = try f.act(try f.openJson("to.html", null));
    for ([_][]const u8{ r2.text, r3.text }) |x| try t.expect(!has(x, "refused page text"));
}

/// The page targets the browser has now.
fn pageTargets(f: *Fix) !usize {
    const a = f.e.arena.allocator();
    const got = try f.web.s.?.callIn(a, "Target.getTargets", "{}", null);
    var n: usize = 0;
    for (jv.arr(jv.get(got, "targetInfos")) orelse &.{}) |ti| {
        if (std.mem.eql(u8, jv.str(jv.get(ti, "type")) orelse "", "page")) n += 1;
    }
    return n;
}

test "web_closes_a_new_tab_before_it_loads_and_says_where_it_went" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.page("opener.html", "<html><body><button id=\"b\" onclick=\"window.open('/page/tab.html?from=opener')\">open</button><p id=\"o\"></p></body></html>");
    // it would leave a mark the opener can see, had it loaded
    try f.page("tab.html", "<html><body><script>localStorage.setItem('tab', 'loaded')</script></body></html>");
    _ = try f.act(try f.openJson("opener.html", null));
    // as a person's click would (a popup needs one)
    _ = try f.web.s.?.call(a, "Runtime.evaluate", "{\"expression\":\"document.getElementById('b').click()\",\"userGesture\":true}");
    var tries: u32 = 0;
    var r = try f.act("{\"action\":\"read\"}");
    var said: std.ArrayList(u8) = .empty;
    try said.appendSlice(a, r.text);
    while (!has(said.items, "new tab") and tries < 20) : (tries += 1) {
        t.io.sleep(.fromMilliseconds(100), .awake) catch {};
        r = try f.act("{\"action\":\"read\"}");
        try said.appendSlice(a, r.text);
    }
    try expectHas(said.items, "A new tab for ");
    try expectHas(said.items, "/page/tab.html?from=opener");
    try t.expectEqual(1, try pageTargets(&f));
    try t.expectEqualStrings("null", try f.eval("localStorage.getItem('tab')"));
    // a link to a new tab, and an empty window (no address ever)
    try f.page("more.html", "<html><body><a id=\"l\" target=\"_blank\" href=\"/page/tab.html?from=link\">link</a><button id=\"e\" onclick=\"window.open()\">empty</button></body></html>");
    _ = try f.act(try f.openJson("more.html", null));
    for ([_][]const u8{ "l", "e" }) |id| {
        _ = try f.web.s.?.call(a, "Runtime.evaluate", try std.fmt.allocPrint(a, "{{\"expression\":\"document.getElementById('{s}').click()\",\"userGesture\":true}}", .{id}));
        t.io.sleep(.fromMilliseconds(500), .awake) catch {};
    }
    const r2 = try f.act("{\"action\":\"read\"}");
    try expectHas(r2.text, "/page/tab.html?from=link was closed before it loaded");
    try expectHas(r2.text, "A new tab the page opened was closed.");
    try t.expectEqual(1, try pageTargets(&f));
    try t.expectEqualStrings("null", try f.eval("localStorage.getItem('tab')"));
}

test "web_clicks_like_a_person" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.page("trust.html",
        \\<html><body><p id="o"></p><button onclick="document.getElementById('o').textContent = event.isTrusted ? 'a trusted click' : 'a script click'">Press</button>
        \\<div style="height: 1500px"></div><button onclick="document.getElementById('o').textContent = 'far one ' + event.isTrusted">Far</button>
        \\<div style="position: relative"><button onclick="document.getElementById('o').textContent = 'under was clicked'">Under</button>
        \\<div style="position: absolute; left: 0; top: 0; width: 100%; height: 100%; background: white">Accept our cookies</div></div>
        \\<label><input type="checkbox" id="c" style="opacity: 0; position: absolute"><span>Remember me</span></label></body></html>
    );
    _ = try f.act(try f.openJson("trust.html", null));
    const r1 = try f.act("{\"action\":\"click\",\"ref\":1}");
    try expectHas(r1.text, "a trusted click");
    // below the fold: scrolled to first
    const r2 = try f.act("{\"action\":\"click\",\"ref\":2}");
    try expectHas(r2.text, "far one true");
    // under something else: not clicked, and said
    const r3 = try f.act("{\"action\":\"click\",\"ref\":3}");
    try t.expect(r3.is_error);
    try expectHas(r3.text, "under another element where it would be clicked (div \"Accept our cookies\")");
    try t.expect(!has(try f.eval("document.getElementById('o').textContent"), "under was clicked"));
    // a box hidden under its own label is clicked through the label
    const r4 = try f.act("{\"action\":\"click\",\"ref\":4}");
    try t.expect(!r4.is_error);
    try t.expectEqualStrings("true", try f.eval("document.getElementById('c').checked"));
}

test "web_sees_and_fills_fields_inside_open_shadow_roots" {
    var f: Fix = undefined;
    try f.init("[agent]\nsite = localhost\n");
    defer f.deinit();
    try f.store.put(t.io, "login-agent-password", "fake-Pass-7351!");
    try f.page("shadow.html",
        \\<html><head><title>Shadow</title></head><body><sign-in></sign-in><p id="o"></p><script>
        \\customElements.define('sign-in', class extends HTMLElement { constructor() { super();
        \\  const r = this.attachShadow({mode: 'open'});
        \\  r.innerHTML = '<label for="pw">Password</label><input id="pw" type="password"><button id="go">Sign in</button>';
        \\  r.getElementById('go').onclick = () => { document.getElementById('o').textContent = r.getElementById('pw').value === 'fake-Pass-7351!' ? 'shadow welcome' : 'wrong'; };
        \\} });
        \\</script></body></html>
    );
    const r0 = try f.act(try f.openJson("shadow.html", "agent"));
    try expectHas(r0.text, "[1] input password \"Password\"");
    try expectHas(r0.text, "[2] button submit \"Sign in\"");
    const r1 = try f.act("{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.password}\"}");
    try expectHas(r1.text, "Typed into [1].");
    const r2 = try f.act("{\"action\":\"click\",\"ref\":2}");
    try expectHas(r2.text, "shadow welcome");
    for ([_][]const u8{ r0.text, r1.text, r2.text }) |x| try t.expect(!has(x, "fake-Pass-7351!"));
}

test "web_click_on_a_select_leaves_the_page_usable" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.page("sel.html", "<html><body><select aria-label=\"Size\"><option value=\"s\">Small</option><option value=\"l\">Large</option></select><input aria-label=\"Name\"><button onclick=\"document.getElementById('o').textContent = 'pressed'\">Go</button><p id=\"o\"></p></body></html>");
    _ = try f.act(try f.openJson("sel.html", null));
    const r1 = try f.act("{\"action\":\"click\",\"ref\":1}");
    try t.expect(!r1.is_error);
    const r2 = try f.act("{\"action\":\"type\",\"ref\":1,\"text\":\"l\"}");
    try t.expect(!r2.is_error);
    const r3 = try f.act("{\"action\":\"type\",\"ref\":2,\"text\":\"agent\"}");
    try t.expect(!r3.is_error);
    const r4 = try f.act("{\"action\":\"click\",\"ref\":3}");
    try expectHas(r4.text, "pressed");
    try t.expectEqualStrings("[\"l\",\"agent\"]", try f.eval("[document.querySelector('select').value, document.querySelector('input').value]"));
}

test "web_clicks_that_open_a_tab_or_a_download_are_handled" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.page("both.html", "<html><body><a target=\"_blank\" href=\"/page/tab.html?by=click\">tab</a> <button onclick=\"window.open('/page/tab.html?by=script')\">win</button> <a href=\"/page/f.bin\" download>file</a></body></html>");
    try f.page("tab.html", "<html><body><script>localStorage.setItem('tab', 'loaded')</script></body></html>");
    try f.page("f.bin", "bytes");
    _ = try f.act(try f.openJson("both.html", null));
    var said: std.ArrayList(u8) = .empty;
    const a = f.e.arena.allocator();
    for ([_][]const u8{ "1", "2", "3" }) |ref| try said.appendSlice(a, (try f.act(try std.fmt.allocPrint(a, "{{\"action\":\"click\",\"ref\":{s}}}", .{ref}))).text);
    var tries: u32 = 0;
    while (tries < 20 and !(has(said.items, "by=click") and has(said.items, "by=script") and has(said.items, "refused"))) : (tries += 1) {
        t.io.sleep(.fromMilliseconds(100), .awake) catch {};
        try said.appendSlice(a, (try f.act("{\"action\":\"read\"}")).text);
    }
    try expectHas(said.items, "/page/tab.html?by=click was closed before it loaded");
    try expectHas(said.items, "/page/tab.html?by=script was closed before it loaded");
    try expectHas(said.items, "A download was refused (downloads are off): ");
    try t.expectEqual(1, try pageTargets(&f));
    try t.expectEqualStrings("null", try f.eval("localStorage.getItem('tab')"));
}

test "web_waits_for_a_slow_navigation_after_a_click" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.page("form.html", "<html><head><title>Form</title></head><body><form method=\"post\" action=\"/page/slow.html?delay_ms=1500\"><input name=\"q\"><button>Go</button></form><a href=\"/page/slow.html?delay_ms=1500&amp;b\">link</a><button onclick=\"setTimeout(() => { location.href = '/page/slow.html?delay_ms=1500&c'; }, 450)\">Later</button></body></html>");
    try f.page("slow.html", "<html><head><title>Arrived</title></head><body><p>the slow page</p></body></html>");
    _ = try f.act(try f.openJson("form.html", null));
    const r = try f.act("{\"action\":\"click\",\"ref\":2}");
    try expectHas(r.text, "Title: Arrived");
    try expectHas(r.text, "the slow page");
    // a link, and a navigation a script starts a moment after the click
    for ([_][]const u8{ "3", "4" }) |ref| {
        _ = try f.act(try f.openJson("form.html", null));
        const rl = try f.act(try std.fmt.allocPrint(f.e.arena.allocator(), "{{\"action\":\"click\",\"ref\":{s}}}", .{ref}));
        try expectHas(rl.text, "Title: Arrived");
    }
    // a same-document move (a fragment) needs no new document
    const frag = try std.fmt.allocPrint(f.e.arena.allocator(), "{{\"action\":\"open\",\"url\":\"{s}#part\"}}", .{try f.url("slow.html")});
    const r2 = try f.act(frag);
    try t.expect(!r2.is_error);
    try expectHas(r2.text, "#part");
}

test "web_removes_throwaway_profiles_a_killed_run_left" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.tmp.dir.createDirPath(t.io, "tmp/harness-web-89abcdef/Default");
    try f.e.tmp.dir.createDirPath(t.io, "tmp/harness-browser-01234567");
    try f.page("here.html", "<html><body><p>here</p></body></html>");
    _ = try f.act(try f.openJson("here.html", null));
    for ([_][]const u8{ "tmp/harness-web-89abcdef", "tmp/harness-browser-01234567" }) |p| try t.expectError(error.FileNotFound, f.e.tmp.dir.statFile(t.io, p, .{}));
    // its own is there until it closes
    try t.expect(f.web.throwaway != null);
    _ = try Io.Dir.cwd().statFile(t.io, f.web.throwaway.?, .{});
}

test "web_waits_for_a_load_under_way_when_the_page_is_read" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.page("here.html", "<html><head><title>Here</title></head><body><p>the old page</p></body></html>");
    // there at once, but loaded only when its slow image is
    try f.page("late.html", "<html><head><title>Arrived</title></head><body><p>the new page</p><img src=\"/page/img.bin?delay_ms=1500\"><script>window.addEventListener('load', () => { document.body.append('and all of it'); });</script></body></html>");
    try f.page("img.bin", "not an image");
    _ = try f.act(try f.openJson("here.html", null));
    // a load that starts later than an action waits for one (a script's
    // timer), still under way when the page is read
    _ = try f.web.s.?.evaluate(a, "setTimeout(() => { location.href = '/page/late.html'; }, 0)");
    var tries: u32 = 0;
    while (!f.web.s.?.inbox.loading(t.io).busy and tries < 100) : (tries += 1) t.io.sleep(.fromMilliseconds(10), .awake) catch {};
    try t.expect(f.web.s.?.inbox.loading(t.io).busy);
    const r = try f.web.after(a, "");
    try expectHas(r.text, "Title: Arrived");
    try expectHas(r.text, "and all of it");
}

test "web_page_scripts_cannot_stall_the_waits" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    f.web.env.timeout_ms = 4000;
    // a page that says it is never loaded, and fakes the mark of an old page
    try f.page("stall.html", "<html><head><title>Stall</title></head><body><p>stalling page</p><script>Object.defineProperty(document, 'readyState', {get: () => 'loading'}); window.__hxOld = true;</script></body></html>");
    try f.page("to.html", "<html><body><a href=\"/page/stall.html\">go</a></body></html>");
    const r = try f.act(try f.openJson("stall.html", null));
    if (r.is_error) std.debug.print("\n{s}\n", .{r.text});
    try t.expect(!r.is_error);
    try expectHas(r.text, "stalling page");
    _ = try f.act(try f.openJson("to.html", null));
    const r2 = try f.act("{\"action\":\"click\",\"ref\":1}");
    try t.expect(!r2.is_error);
    try expectHas(r2.text, "Title: Stall");
    const r3 = try f.act(try f.openJson("to.html", null));
    try t.expect(!r3.is_error);
}

test "web_snapshot_never_shows_a_host_the_gate_did_not_allow" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.page("here.html", "<html><body><p>here</p></body></html>");
    try f.page("there.html", "<html><body><p>secret page text</p></body></html>");
    _ = try f.act(try f.openJson("here.html", null));
    // the page moves to another host behind the tool's back (as between
    // the host check and the snapshot)
    try f.web.s.?.navigate(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/page/there.html", .{f.e.server.port}));
    f.refuse = "web";
    const text = f.web.snapshot(a, "") catch "";
    try t.expect(!has(text, "secret page text"));
    try expectHas(f.asked.items, "web 127.0.0.1:");
}

test "web_passkey_filter_keeps_the_site_and_drops_others" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const list = [_]logins.Passkey{
        .{ .id = "a", .rp_id = "localhost", .key = "k" },
        .{ .id = "b", .rp_id = "example.com", .key = "k" },
    };
    const f = try filterPasskeys(arena.allocator(), "localhost", &list);
    try t.expectEqual(1, f.keep.len);
    try t.expectEqualStrings("a", f.keep[0].id);
    try t.expectEqual(1, f.drop.len);
    try t.expectEqualStrings("example.com", f.drop[0].rp_id);
    const m = try mergePasskeys(arena.allocator(), &.{.{ .id = "a", .rp_id = "localhost", .key = "k", .count = 1 }}, &.{.{ .id = "a", .rp_id = "localhost", .key = "k", .count = 1 }});
    try t.expect(!m.changed);
    const m2 = try mergePasskeys(arena.allocator(), &.{.{ .id = "a", .rp_id = "localhost", .key = "k", .count = 1 }}, &.{.{ .id = "a", .rp_id = "localhost", .key = "k", .count = 2 }});
    try t.expect(m2.changed and m2.added.len == 0 and m2.list[0].count == 2);
}
