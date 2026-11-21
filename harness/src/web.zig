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
};

pub fn toolDef(arena: Allocator, list: []const logins.Login) !model.ToolDef {
    var d: std.ArrayList(u8) = .empty;
    try d.appendSlice(arena,
        \\An interactive browser. Actions: open (a url, optionally with one of your logins), type (into an element by ref; enter: true presses Enter after), click (ref), key (Enter, Tab or Escape), read, close. Every action returns the page: its address, its interactive elements numbered by ref, and its text. One session per turn; it closes when the turn ends.
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

    pub fn init(gpa: Allocator, io: Io, env: Env, hooks: Hooks) Web {
        return .{ .gpa = gpa, .io = io, .env = env, .hooks = hooks, .arena = .init(gpa) };
    }

    pub fn deinit(w: *Web) void {
        w.close();
        for (w.extra.items) |x| std.crypto.secureZero(u8, @constCast(x.value));
        w.arena.deinit();
    }

    /// Ends the session: the browser, the throwaway profile, the grants.
    pub fn close(w: *Web) void {
        if (w.s) |s| {
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
        return .{ .text = try w.mask(a, raw.text), .is_error = raw.is_error };
    }

    fn mask(w: *Web, a: Allocator, text: []const u8) ![]const u8 {
        var all: std.ArrayList(scrub.Secret) = .empty;
        try all.appendSlice(a, w.env.secrets);
        try all.appendSlice(a, w.extra.items);
        var sc = try scrub.Scrubber.init(a, all.items);
        return sc.scrubAlloc(a, text);
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
                try w.pressKey(a, "Enter");
                try w.s.?.settle(a);
            }
        } else if (eql(u8, action, "click")) {
            const ref = jv.int(jv.get(v, "ref")) orelse return fail(a, "click needs a ref", .{});
            const r = try w.s.?.evaluateIsolated(a, try refScript(a, ref, "el.scrollIntoView({block: 'center'}); el.click(); return 'ok';"));
            if (!eql(u8, r, "\"ok\"")) return fail(a, "no element [{d}] on the page; read it again", .{ref});
            try w.s.?.settle(a);
        } else if (eql(u8, action, "key")) {
            const key = jv.str(jv.get(v, "key")) orelse return fail(a, "key needs Enter, Tab or Escape", .{});
            if (!(eql(u8, key, "Enter") or eql(u8, key, "Tab") or eql(u8, key, "Escape"))) return fail(a, "key needs Enter, Tab or Escape", .{});
            try w.pressKey(a, key);
            try w.s.?.settle(a);
        } else return fail(a, "unknown action {s}; use open, type, click, key, read or close", .{util.cut(action, 40)});
        return w.after(a, said);
    }

    /// Passkeys, the gate for where the page is now, then the page.
    fn after(w: *Web, a: Allocator, said: []const u8) !Output {
        try w.syncPasskeys(a);
        if (try w.checkHost(a)) |why| {
            _ = w.s.?.navigate(a, "about:blank") catch {};
            return fail(a, "{s}", .{why});
        }
        return .{ .text = try w.snapshot(a, said) };
    }

    fn open(w: *Web, a: Allocator, url: []const u8, login_name: ?[]const u8) !Output {
        const host = gate.urlHost(url) orelse return fail(a, "only http and https addresses can be opened", .{});
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
            var rnd: [8]u8 = undefined;
            w.io.random(&rnd);
            try Io.Dir.cwd().createDirPath(w.io, w.env.tmp_root);
            const p = try std.fs.path.join(w.arena.allocator(), &.{ w.env.tmp_root, try std.fmt.allocPrint(a, "harness-web-{x}", .{rnd}) });
            try Io.Dir.cwd().createDir(w.io, p, .default_dir);
            w.throwaway = p;
            break :blk p;
        };
        w.s = try cdp.Session.open(w.gpa, w.io, w.env.browser, profile, w.env.stop, w.env.timeout_ms);
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
            return;
        } orelse return;
        defer {
            std.crypto.secureZero(u8, raw);
            w.gpa.free(raw);
        }
        const list = logins.decode(w.arena.allocator(), raw) catch {
            w.passkeys_bad = true;
            try w.notes.appendSlice(w.arena.allocator(), "The stored passkeys of this login could not be read; none were loaded.\n");
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
        if (w.passkeys_bad) return;
        const merged = try mergePasskeys(a, w.stored, f.keep);
        if (!merged.changed) return;
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
        // the new list, kept for the next comparison
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
        if (spans.len == 0) return w.fill(a, ref, text, &.{}, &.{});
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
        const r = try w.fill(a, ref, out.items, sites.items, used.items);
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
    fn fill(w: *Web, a: Allocator, ref: i64, text: []const u8, sites: []const []const u8, used: []const logins.Login) !Output {
        const script = try fillScript(a, ref, text, sites);
        defer std.crypto.secureZero(u8, @constCast(script));
        const host = if (used.len > 0) (try w.location(a)).host else "";
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
        return fail(a, "no element [{d}] on the page; read it again", .{ref});
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
        const url = jv.str(jv.get(v, "url")) orelse "";
        const html = jv.str(jv.get(v, "html")) orelse "";
        var out: std.ArrayList(u8) = .empty;
        if (said.len > 0) try out.print(a, "{s}\n", .{said});
        try out.appendSlice(a, w.notes.items);
        try out.print(a, "URL: {s}\nTitle: {s}\n", .{ url, util.cut(jv.str(jv.get(v, "title")) orelse "", 300) });
        const items = jv.arr(jv.get(v, "items")) orelse &.{};
        if (items.len > 0) try out.appendSlice(a, "Elements:\n");
        for (items) |it| {
            const tag = jv.str(jv.get(it, "tag")) orelse "";
            const typ = jv.str(jv.get(it, "type")) orelse "";
            try out.print(a, "[{d}] {s}{s}{s} ", .{ jv.int(jv.get(it, "ref")) orelse 0, tag, if (typ.len > 0) " " else "", typ });
            try util.jsonString(&out, a, jv.str(jv.get(it, "label")) orelse "");
            try out.append(a, '\n');
        }
        const p = page.extract(a, html, url) catch page.Page{ .title = "", .text = "" };
        try out.print(a, "\n{s}", .{p.text});
        if (out.items.len > w.env.max_bytes) {
            const total = out.items.len;
            const cut = util.cut(out.items, w.env.max_bytes);
            return std.fmt.allocPrint(a, "{s}\n[page cut at {d} bytes of {d}]", .{ cut, w.env.max_bytes, total });
        }
        return out.items;
    }
};

/// Marks the top document's interactive elements with data-hx-ref and
/// lists them; the page's HTML for its text. Never reads a field's value.
const snapshot_script =
    \\(() => {
    \\  for (const el of document.querySelectorAll('[data-hx-ref]')) el.removeAttribute('data-hx-ref');
    \\  const items = [];
    \\  let n = 0;
    \\  for (const el of document.querySelectorAll('input, textarea, select, button, a[href], [role=button]')) {
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
    \\  return {url: location.href, title: document.title, html: document.documentElement ? document.documentElement.outerHTML.slice(0, 4194304) : '', items};
    \\})()
;

/// `body` runs with `el` the element marked `ref`; 'no-element' if none.
fn refScript(a: Allocator, ref: i64, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "(() => {{ const el = document.querySelector('[data-hx-ref=\"{d}\"]'); if (!el) return 'no-element'; {s} }})()", .{ ref, body });
}

/// Checks that the page is on every one of `sites` (the rules of
/// logins.hostAllowed, with string indexing and comparisons only), then
/// sets the field's value with its prototype's own setter and sends input
/// and change. Check and fill are one script: no navigation can come
/// between them. It runs in an isolated world, where the page can't have
/// changed `location` or the prototypes it uses.
fn fillScript(a: Allocator, ref: i64, value: []const u8, sites: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "(() => {\nconst sites = [");
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
    try out.print(a, "const el = document.querySelector('[data-hx-ref=\"{d}\"]');\n", .{ref});
    try out.appendSlice(a,
        \\if (!el) return 'no-element';
        \\let proto = null;
        \\if (el instanceof HTMLInputElement) proto = HTMLInputElement.prototype;
        \\else if (el instanceof HTMLTextAreaElement) proto = HTMLTextAreaElement.prototype;
        \\else if (el instanceof HTMLSelectElement) proto = HTMLSelectElement.prototype;
        \\if (!proto) return 'not-a-field';
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
        _ = arena;
        const f: *Fix = @ptrCast(@alignCast(ctx));
        f.asked.print(t.allocator, "{s} {s}\n", .{ @tagName(tool), arg }) catch {};
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
    for ([_][]const u8{ "example.com", "calhost" }) |site| {
        const r = try f.web.s.?.evaluateIsolated(a, try fillScript(a, 1, "must-not-arrive", &.{site}));
        try t.expect(std.mem.startsWith(u8, r, "\"wrong-site http://localhost:"));
    }
    try t.expectEqualStrings("\"\"", try f.eval("document.getElementById('pw').value"));
    const ok = try f.web.s.?.evaluateIsolated(a, try fillScript(a, 1, "fine", &.{"localhost"}));
    try t.expectEqualStrings("\"ok\"", ok);
    try t.expectEqualStrings("\"fine\"", try f.eval("document.getElementById('pw').value"));
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
