//! Signing in to an MCP server at a url (`login = oauth` in mcp.ini), as
//! MCP's authorization spec (2025-06-18) says, from the terminal
//! (`harness mcp login NAME`):
//!
//! 1. A request without a sign-in is answered 401, naming the server's
//!    protected resource metadata (RFC 9728; without it, the well-known
//!    places);
//! 2. that names the authorization server, whose metadata (RFC 8414, or
//!    OpenID discovery) gives its endpoints;
//! 3. harness registers itself (RFC 7591) unless `client_id =` is set;
//! 4. the owner opens a link (printed, not opened) carrying PKCE (S256), a
//!    `state` and the `resource` (RFC 8707); the authorization server sends
//!    the browser back to `http://127.0.0.1:PORT/callback`, a listener
//!    that takes one sign-in and ends after 5 minutes;
//! 5. the code is exchanged for tokens.
//!
//! Tokens and the client are kept in the store as secret `mcp-NAME`
//! (never in a file, never said). A `Keeper` hands the access token to
//! requests, renews it before it expires and once after a 401 (taking a
//! newer sign-in from the store first), and writes it back.
const std = @import("std");
const http = @import("http.zig");
const url_mod = @import("url.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const sock = @import("sock.zig");
const store_mod = @import("store.zig");
const masks_mod = @import("masks.zig");
const scrub = @import("scrub.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A renewal comes this long before the token expires (s).
pub const renew_margin_s = 60;
/// The longest metadata, registration or token answer read.
const max_answer = 1 << 20;

/// What `mcp-NAME` holds (as JSON).
pub const Tokens = struct {
    access_token: []const u8,
    refresh_token: []const u8 = "",
    /// Unix seconds; 0: not said.
    expires_at: i64 = 0,
    scope: []const u8 = "",
    client_id: []const u8,
    client_secret: []const u8 = "",
    /// How the client proves itself at the token endpoint: none,
    /// client_secret_post or client_secret_basic.
    auth_method: []const u8 = "none",
    token_endpoint: []const u8,
    issuer: []const u8 = "",
    /// The server, as the tokens are for it (RFC 8707).
    resource: []const u8,

    pub fn encode(tk: Tokens, a: Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(a, .{
            .v = 1,
            .access_token = tk.access_token,
            .refresh_token = tk.refresh_token,
            .expires_at = tk.expires_at,
            .scope = tk.scope,
            .client_id = tk.client_id,
            .client_secret = tk.client_secret,
            .auth_method = tk.auth_method,
            .token_endpoint = tk.token_endpoint,
            .issuer = tk.issuer,
            .resource = tk.resource,
        }, .{});
    }

    /// Null when `text` is not what `encode` wrote.
    pub fn decode(a: Allocator, text: []const u8) ?Tokens {
        const v = jv.parse(a, text) orelse return null;
        if ((jv.int(jv.get(v, "v")) orelse 0) != 1) return null;
        const access = jv.str(jv.get(v, "access_token")) orelse return null;
        const client = jv.str(jv.get(v, "client_id")) orelse return null;
        const endpoint = jv.str(jv.get(v, "token_endpoint")) orelse return null;
        if (access.len == 0 or client.len == 0 or endpoint.len == 0) return null;
        return .{
            .access_token = access,
            .refresh_token = jv.str(jv.get(v, "refresh_token")) orelse "",
            .expires_at = jv.int(jv.get(v, "expires_at")) orelse 0,
            .scope = jv.str(jv.get(v, "scope")) orelse "",
            .client_id = client,
            .client_secret = jv.str(jv.get(v, "client_secret")) orelse "",
            .auth_method = jv.str(jv.get(v, "auth_method")) orelse "none",
            .token_endpoint = endpoint,
            .issuer = jv.str(jv.get(v, "issuer")) orelse "",
            .resource = jv.str(jv.get(v, "resource")) orelse "",
        };
    }

    /// The values to mask, under the secret's name.
    pub fn secrets(tk: Tokens, a: Allocator, name: []const u8) ![]scrub.Secret {
        var out: std.ArrayList(scrub.Secret) = .empty;
        for ([_][]const u8{ tk.access_token, tk.refresh_token, tk.client_secret }) |v| if (v.len > 0) try out.append(a, .{ .name = name, .value = v });
        return out.items;
    }
};

/// The sign-in kept under `secret`, or null when there is none (or it is
/// not one harness wrote).
pub fn load(io: Io, a: Allocator, st: store_mod.Store, secret: []const u8) !?Tokens {
    const raw = (try st.getLong(io, a, secret)) orelse return null;
    return Tokens.decode(a, raw);
}

/// Keeps a sign-in under `secret` (in parts where the store limits a value).
pub fn save(io: Io, gpa: Allocator, st: store_mod.Store, secret: []const u8, tk: Tokens) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try tk.encode(arena.allocator());
    defer std.crypto.secureZero(u8, text);
    try st.putLong(io, gpa, secret, text);
}

// ---- the keeper ----

/// A server's sign-in while harness runs: shared by its requests and its
/// stream.
/// What a renewal came to.
pub const Renewal = enum {
    /// A new token is held: renewed, or a sign-in made since taken.
    renewed,
    /// The authorization server refused it, or the sign-in was forgotten:
    /// only a new sign-in mends it.
    refused,
    /// Not now: the authorization server was not reached in time, or the
    /// request was stopped.
    failed,
};

pub const Keeper = struct {
    gpa: Allocator,
    io: Io,
    store: store_mod.Store,
    /// The server's name (said in failures).
    name: []const u8,
    /// `mcp-NAME`.
    secret: []const u8,
    masks: ?*masks_mod.List,
    mutex: Io.Mutex = .init,
    /// Holds `tokens`, `stored` and the names (replaced whole on a
    /// renewal).
    arena_state: std.heap.ArenaAllocator,
    tokens: Tokens,
    /// The access token the store had when last read or written: a
    /// different one there is a sign-in made since. (A renewal the store
    /// could not take is held in memory only, and the store's older one is
    /// not taken for a newer.)
    stored: []const u8,
    refused_flag: std.atomic.Value(bool) = .init(false),

    /// error.NotSignedIn when nothing is kept under `secret`.
    pub fn open(gpa: Allocator, io: Io, st: store_mod.Store, name: []const u8, secret: []const u8, masks: ?*masks_mod.List) !*Keeper {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_state.deinit();
        const a = arena_state.allocator();
        const tokens = (try load(io, a, st, secret)) orelse return error.NotSignedIn;
        const k = try gpa.create(Keeper);
        k.* = .{
            .gpa = gpa,
            .io = io,
            .store = st,
            .name = try a.dupe(u8, name),
            .secret = try a.dupe(u8, secret),
            .masks = masks,
            .arena_state = arena_state,
            .tokens = tokens,
            .stored = tokens.access_token,
        };
        k.maskNow();
        return k;
    }

    pub fn destroy(k: *Keeper) void {
        k.arena_state.deinit();
        k.gpa.destroy(k);
    }

    /// The access token to send (a copy in `a`), renewed first when it
    /// expires within a minute (a sign-in made since is taken instead; one
    /// forgotten since is not renewed). The renewal ends by `ms` or `stop`;
    /// one that fails keeps the token held.
    pub fn bearer(k: *Keeper, a: Allocator, stop: ?*const std.atomic.Value(bool), ms: u32) error{OutOfMemory}![]const u8 {
        k.mutex.lockUncancelable(k.io);
        defer k.mutex.unlock(k.io);
        const tk = k.tokens;
        if (tk.expires_at > 0 and tk.refresh_token.len > 0 and !k.refused() and util.nowSeconds(k.io) >= tk.expires_at -| renew_margin_s) {
            switch (k.fromStore()) {
                .gone => k.markRefused(),
                .newer => {},
                .same => k.refresh(stop, ms) catch |e| if (e == error.Refused) k.markRefused(),
            }
        }
        return a.dupe(u8, k.tokens.access_token);
    }

    /// The access token held now (a copy in `a`), never renewed first: for
    /// what must not wait on the authorization server (a stop's DELETE).
    pub fn held(k: *Keeper, a: Allocator) error{OutOfMemory}![]const u8 {
        k.mutex.lockUncancelable(k.io);
        defer k.mutex.unlock(k.io);
        return a.dupe(u8, k.tokens.access_token);
    }

    /// After a 401 to a request that carried `used`: a sign-in made since
    /// (the store's), or a renewal ending by `ms` or `stop`.
    pub fn renew(k: *Keeper, a: Allocator, used: []const u8, stop: ?*const std.atomic.Value(bool), ms: u32) Renewal {
        _ = a;
        k.mutex.lockUncancelable(k.io);
        defer k.mutex.unlock(k.io);
        // renewed by another request meanwhile
        if (!std.mem.eql(u8, k.tokens.access_token, used)) return .renewed;
        switch (k.fromStore()) {
            // `harness mcp logout NAME` meanwhile: renewing would keep it again
            .gone => {
                k.markRefused();
                return .refused;
            },
            // `harness mcp login NAME` from the terminal while harness runs
            .newer => return .renewed,
            .same => {},
        }
        if (k.tokens.refresh_token.len == 0) {
            k.markRefused();
            return .refused;
        }
        k.refresh(stop, ms) catch |e| {
            // only the authorization server's own no is a refusal
            if (e != error.Refused) return .failed;
            k.markRefused();
            return .refused;
        };
        return .renewed;
    }

    /// Whether the server or its authorization server refused the sign-in
    /// since it was read (a renewal or a new sign-in mends it).
    pub fn refused(k: *const Keeper) bool {
        return k.refused_flag.load(.acquire);
    }

    pub fn markRefused(k: *Keeper) void {
        k.refused_flag.store(true, .release);
    }

    /// The values to mask now (names and values copied: a renewal replaces
    /// what the keeper holds).
    pub fn secrets(k: *Keeper, a: Allocator) ![]scrub.Secret {
        k.mutex.lockUncancelable(k.io);
        defer k.mutex.unlock(k.io);
        const list = try k.tokens.secrets(a, k.secret);
        const name = try a.dupe(u8, k.secret);
        for (list) |*x| {
            x.name = name;
            x.value = try a.dupe(u8, x.value);
        }
        return list;
    }

    // ---- inside (under `mutex`) ----

    fn maskNow(k: *Keeper) void {
        const m = k.masks orelse return;
        for ([_][]const u8{ k.tokens.access_token, k.tokens.refresh_token, k.tokens.client_secret }) |v| if (v.len > 0) m.add(k.secret, v) catch {};
    }

    const Stored = enum {
        /// Nothing kept: signed out.
        gone,
        /// Nothing new there.
        same,
        /// Another sign-in, now held.
        newer,
    };

    /// What the store keeps now; another sign-in is taken. A store that
    /// can't be read counts as the same.
    fn fromStore(k: *Keeper) Stored {
        var next: std.heap.ArenaAllocator = .init(k.gpa);
        const got = load(k.io, next.allocator(), k.store, k.secret) catch {
            next.deinit();
            return .same;
        };
        const tk = got orelse {
            next.deinit();
            return .gone;
        };
        if (std.mem.eql(u8, tk.access_token, k.stored)) {
            next.deinit();
            return .same;
        }
        k.swap(&next, tk, tk.access_token);
        k.refused_flag.store(false, .release);
        return .newer;
    }

    /// Holds `tk` (in `next`), with `stored` as the store's token.
    fn swap(k: *Keeper, next: *std.heap.ArenaAllocator, tk: Tokens, stored: []const u8) void {
        const a = next.allocator();
        const name = a.dupe(u8, k.name) catch k.name;
        const secret = a.dupe(u8, k.secret) catch k.secret;
        const kept = a.dupe(u8, stored) catch "";
        var old = k.arena_state;
        k.arena_state = next.*;
        k.tokens = tk;
        k.name = name;
        k.secret = secret;
        k.stored = kept;
        old.deinit();
        k.maskNow();
    }

    /// A refresh_token grant ending by `ms` or `stop`; the new tokens are
    /// kept (in the store when it takes them) and masked.
    fn refresh(k: *Keeper, stop: ?*const std.atomic.Value(bool), ms: u32) !void {
        var tmp: std.heap.ArenaAllocator = .init(k.gpa);
        defer tmp.deinit();
        const tk = k.tokens;
        var form: Form = .{ .a = tmp.allocator() };
        try form.add("grant_type", "refresh_token");
        try form.add("refresh_token", tk.refresh_token);
        if (tk.resource.len > 0) try form.add("resource", tk.resource);
        var next: std.heap.ArenaAllocator = .init(k.gpa);
        errdefer next.deinit();
        const got = try tokenRequest(k.gpa, k.io, next.allocator(), tk.token_endpoint, &form, tk.client_id, tk.client_secret, tk.auth_method, ms, stop, null);
        const a = next.allocator();
        const fresh: Tokens = .{
            .access_token = got.access_token,
            .refresh_token = if (got.refresh_token.len > 0) got.refresh_token else try a.dupe(u8, tk.refresh_token),
            .expires_at = if (got.expires_in > 0) util.nowSeconds(k.io) +| got.expires_in else 0,
            .scope = if (got.scope.len > 0) got.scope else try a.dupe(u8, tk.scope),
            .client_id = try a.dupe(u8, tk.client_id),
            .client_secret = try a.dupe(u8, tk.client_secret),
            .auth_method = try a.dupe(u8, tk.auth_method),
            .token_endpoint = try a.dupe(u8, tk.token_endpoint),
            .issuer = try a.dupe(u8, tk.issuer),
            .resource = try a.dupe(u8, tk.resource),
        };
        // kept before it is used: a renewed refresh token may be the only one left
        const saved = if (save(k.io, k.gpa, k.store, k.secret, fresh)) |_| true else |_| false;
        k.swap(&next, fresh, if (saved) fresh.access_token else k.stored);
        k.refused_flag.store(false, .release);
    }
};

// ---- signing in ----

pub const Link = struct {
    ctx: ?*anyopaque = null,
    /// Told the link to open once the listener waits for it, and the
    /// listener's port (for `ssh -L`).
    f: *const fn (ctx: ?*anyopaque, link: []const u8, port: u16) void,
};

pub const LoginOptions = struct {
    /// The server's name in mcp.ini (said in failures and on the page).
    name: []const u8,
    /// Its address (url.zig's form).
    url: []const u8,
    /// Its `header =` lines (sent to the server only).
    headers: []const std.http.Header = &.{},
    /// `client_id =`: no registration.
    client_id: []const u8 = "",
    /// `scope =`: else the server's.
    scope: []const u8 = "",
    link: Link,
    /// How long the listener waits for the browser.
    wait_ms: u32 = 5 * 60 * 1000,
    /// Each request's limit.
    request_ms: u32 = 30_000,
    stop: ?*const std.atomic.Value(bool) = null,
};

pub const Error = error{
    /// The server answered without a sign-in.
    NoSignInNeeded,
    /// Metadata missing or not usable, or an endpoint that is not https.
    BadMetadata,
    /// The authorization server takes no registration and no client_id is set.
    NoRegistration,
    /// The authorization server (or the server) refused.
    Refused,
    /// Nothing came back to the listener in time.
    TimedOut,
    /// The answer to the listener did not carry this sign-in's state.
    StateMismatch,
    Unreachable,
    Stopped,
    OutOfMemory,
};

/// Signs in: returns the tokens to keep. On failure `said.*` says why
/// (in `arena`).
pub fn login(gpa: Allocator, io: Io, arena: Allocator, o: LoginOptions, said: *[]const u8) Error!Tokens {
    var s: Login = .{ .gpa = gpa, .io = io, .a = arena, .o = o, .said = said };
    return s.run();
}

const Login = struct {
    gpa: Allocator,
    io: Io,
    a: Allocator,
    o: LoginOptions,
    said: *[]const u8,

    fn fail(s: *Login, e: Error, comptime fmt: []const u8, args: anytype) Error {
        s.note(fmt, args);
        return e;
    }

    /// Says why the sign-in failed.
    fn note(s: *Login, comptime fmt: []const u8, args: anytype) void {
        s.said.* = std.fmt.allocPrint(s.a, fmt, args) catch "the sign-in failed";
    }

    fn run(s: *Login) Error!Tokens {
        const a = s.a;
        const name = s.o.name;
        // 1. the server says where its sign-in is
        const first = try s.probe();
        var prm_v: ?jv.Value = null;
        var prm_url: []const u8 = "";
        for (try s.prmPlaces(first.resource_metadata)) |place| {
            const got = (try s.getJson(place)) orelse continue;
            if (jv.arr(jv.get(got, "authorization_servers")) == null) continue;
            prm_v = got;
            prm_url = place;
            break;
        }
        const prm = prm_v orelse return s.fail(error.BadMetadata, "{s} did not say where to sign in (no protected resource metadata)", .{name});
        // the resource the tokens are for: the metadata's, on the server's own address
        const server = url_mod.parse(a, s.o.url) catch return s.fail(error.BadMetadata, "{s}'s url is not usable", .{name});
        var resource = server.href;
        if (jv.str(jv.get(prm, "resource"))) |r| {
            const ru = url_mod.parse(a, r) catch return s.fail(error.BadMetadata, "{s}'s metadata names a resource that is not an address", .{name});
            if (!std.mem.eql(u8, ru.host_port, server.host_port) or ru.https != server.https) return s.fail(error.BadMetadata, "{s}'s metadata is for another server ({s})", .{ name, util.cut(r, 120) });
            resource = r;
        }
        const servers = jv.arr(jv.get(prm, "authorization_servers")).?;
        if (servers.len == 0) return s.fail(error.BadMetadata, "{s}'s metadata names no authorization server", .{name});
        const issuer = jv.str(servers[0]) orelse return s.fail(error.BadMetadata, "{s}'s metadata names no authorization server", .{name});
        const iu = try s.endpoint(issuer, "authorization server");
        // 2. the authorization server's metadata
        const asm_v = blk: {
            for (try asPlaces(a, iu)) |place| {
                const got = (try s.getJson(place)) orelse continue;
                if (jv.str(jv.get(got, "issuer"))) |said_issuer| {
                    if (!sameIssuer(said_issuer, issuer)) return s.fail(error.BadMetadata, "the authorization server's metadata names another issuer ({s})", .{util.cut(said_issuer, 120)});
                } else continue;
                break :blk got;
            }
            return s.fail(error.BadMetadata, "{s}'s authorization server ({s}) has no metadata harness can read", .{ name, util.cut(issuer, 120) });
        };
        const auth_ep = jv.str(jv.get(asm_v, "authorization_endpoint")) orelse return s.fail(error.BadMetadata, "the authorization server's metadata has no authorization_endpoint", .{});
        const token_ep = jv.str(jv.get(asm_v, "token_endpoint")) orelse return s.fail(error.BadMetadata, "the authorization server's metadata has no token_endpoint", .{});
        _ = try s.endpoint(auth_ep, "authorization endpoint");
        _ = try s.endpoint(token_ep, "token endpoint");
        if (jv.arr(jv.get(asm_v, "code_challenge_methods_supported"))) |methods| {
            for (methods) |m| {
                if (std.mem.eql(u8, jv.str(m) orelse "", "S256")) break;
            } else return s.fail(error.BadMetadata, "{s}'s authorization server does not take PKCE with S256", .{name});
        }
        // 3. where the browser comes back to
        var listener = sock.Listener.openExclusive(0) catch return s.fail(error.Unreachable, "no port on 127.0.0.1 for the sign-in to come back to", .{});
        defer listener.close();
        const redirect = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/callback", .{listener.port});
        // 4. the client
        var client_id = s.o.client_id;
        var client_secret: []const u8 = "";
        var auth_method: []const u8 = "none";
        if (client_id.len == 0) {
            const reg = jv.str(jv.get(asm_v, "registration_endpoint")) orelse return s.fail(error.NoRegistration, "{s}'s authorization server takes no client registration: set client_id = in [{s}] in mcp.ini", .{ name, name });
            _ = try s.endpoint(reg, "registration endpoint");
            const body = try std.fmt.allocPrint(a, "{{\"client_name\":\"harness\",\"redirect_uris\":[{f}],\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\"}}", .{std.json.fmt(redirect, .{})});
            const got = try s.request(reg, .POST, body, "application/json", &.{});
            if (got.status != 200 and got.status != 201) return s.fail(error.Refused, "{s}'s authorization server refused the registration ({d}){s}", .{ name, got.status, try oauthDetail(a, got.body) });
            const v = jv.parse(a, got.body) orelse return s.fail(error.BadMetadata, "the registration's answer is not JSON", .{});
            client_id = jv.str(jv.get(v, "client_id")) orelse return s.fail(error.BadMetadata, "the registration's answer has no client_id", .{});
            client_secret = jv.str(jv.get(v, "client_secret")) orelse "";
            if (client_secret.len > 0) {
                const m = jv.str(jv.get(v, "token_endpoint_auth_method")) orelse "client_secret_basic";
                auth_method = if (std.mem.eql(u8, m, "client_secret_post")) "client_secret_post" else "client_secret_basic";
            }
        }
        // 5. the link: PKCE, state, resource, scope
        var raw: [32]u8 = undefined;
        s.io.randomSecure(&raw) catch return s.fail(error.Unreachable, "no random numbers for the sign-in", .{});
        var verifier: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &raw);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&verifier, &digest, .{});
        var challenge: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
        var state_raw: [16]u8 = undefined;
        s.io.randomSecure(&state_raw) catch return s.fail(error.Unreachable, "no random numbers for the sign-in", .{});
        var state: [22]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&state, &state_raw);
        const scope = if (s.o.scope.len > 0) s.o.scope else if (first.scope.len > 0) first.scope else try joinScopes(a, jv.arr(jv.get(prm, "scopes_supported")) orelse &.{});
        var q: Form = .{ .a = a };
        try q.add("response_type", "code");
        try q.add("client_id", client_id);
        try q.add("redirect_uri", redirect);
        try q.add("code_challenge", &challenge);
        try q.add("code_challenge_method", "S256");
        try q.add("state", &state);
        try q.add("resource", resource);
        if (scope.len > 0) try q.add("scope", scope);
        const link = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ auth_ep, if (std.mem.indexOfScalar(u8, auth_ep, '?') != null) "&" else "?", q.text() });
        s.o.link.f(s.o.link.ctx, link, listener.port);
        // 6. the browser comes back
        const back = try s.wait(&listener, &state, issuer, struct {
            fn exchange(l: *Login, code: []const u8, ep: []const u8, id: []const u8, secret: []const u8, method: []const u8, redir: []const u8, v: []const u8, res: []const u8) Error!Answer {
                var form: Form = .{ .a = l.a };
                try form.add("grant_type", "authorization_code");
                try form.add("code", code);
                try form.add("redirect_uri", redir);
                try form.add("code_verifier", v);
                try form.add("resource", res);
                var said_buf: []const u8 = "";
                return tokenRequest(l.gpa, l.io, l.a, ep, &form, id, secret, method, l.o.request_ms, l.o.stop, &said_buf) catch |e| {
                    l.said.* = if (said_buf.len > 0) said_buf else std.fmt.allocPrint(l.a, "the code was not exchanged for tokens ({s})", .{@errorName(e)}) catch "the code was not exchanged for tokens";
                    return if (e == error.OutOfMemory) error.OutOfMemory else error.Refused;
                };
            }
        }.exchange, .{ token_ep, client_id, client_secret, auth_method, redirect, &verifier, resource });
        return .{
            .access_token = back.access_token,
            .refresh_token = back.refresh_token,
            .expires_at = if (back.expires_in > 0) util.nowSeconds(s.io) +| back.expires_in else 0,
            .scope = if (back.scope.len > 0) back.scope else scope,
            .client_id = client_id,
            .client_secret = client_secret,
            .auth_method = auth_method,
            .token_endpoint = token_ep,
            .issuer = issuer,
            .resource = resource,
        };
    }

    const Probe = struct { resource_metadata: []const u8 = "", scope: []const u8 = "" };

    /// A request without a sign-in: the 401's WWW-Authenticate.
    fn probe(s: *Login) Error!Probe {
        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"harness\",\"version\":\"" ++ @import("build_options").version ++ "\"}}}";
        const got = try s.request(s.o.url, .POST, body, "application/json", s.o.headers);
        if (got.status >= 200 and got.status < 300) return s.fail(error.NoSignInNeeded, "{s} answered without a sign-in: it needs none (remove login = oauth from [{s}] in mcp.ini)", .{ s.o.name, s.o.name });
        if (got.status != 401) return s.fail(error.Refused, "{s} answered {d} to a request without a sign-in, not 401", .{ s.o.name, got.status });
        return .{
            .resource_metadata = authParam(got.www_authenticate, "resource_metadata") orelse "",
            .scope = authParam(got.www_authenticate, "scope") orelse "",
        };
    }

    /// Where the protected resource metadata may be: the 401's, else the
    /// well-known places for the server's path and its root.
    fn prmPlaces(s: *Login, named: []const u8) Error![]const []const u8 {
        const a = s.a;
        var out: std.ArrayList([]const u8) = .empty;
        if (named.len > 0) {
            _ = try s.endpoint(named, "protected resource metadata");
            try out.append(a, named);
            return out.items;
        }
        const u = url_mod.parse(a, s.o.url) catch return out.items;
        const path = std.mem.trimEnd(u8, u.target[0 .. std.mem.indexOfScalar(u8, u.target, '?') orelse u.target.len], "/");
        if (path.len > 0) try out.append(a, try std.fmt.allocPrint(a, "{s}://{s}/.well-known/oauth-protected-resource{s}", .{ u.scheme(), u.host_port, path }));
        try out.append(a, try std.fmt.allocPrint(a, "{s}://{s}/.well-known/oauth-protected-resource", .{ u.scheme(), u.host_port }));
        return out.items;
    }

    /// An endpoint's address: https, or http to this machine.
    fn endpoint(s: *Login, raw: []const u8, what: []const u8) Error!url_mod.Url {
        const u = url_mod.parse(s.a, raw) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return s.fail(error.BadMetadata, "the {s} is not an address harness can use ({s})", .{ what, util.cut(raw, 120) });
        };
        if (!u.https and !loopback(u.host)) return s.fail(error.BadMetadata, "the {s} is not https ({s})", .{ what, util.cut(raw, 120) });
        return u;
    }

    /// A GET whose answer is a JSON object; null for any other answer.
    fn getJson(s: *Login, place: []const u8) Error!?jv.Value {
        const got = s.request(place, .GET, null, "", &.{}) catch |e| switch (e) {
            error.OutOfMemory, error.Stopped => return e,
            else => return null,
        };
        if (got.status != 200) return null;
        const v = jv.parse(s.a, got.body) orelse return null;
        return if (v == .object) v else null;
    }

    const Got = struct { status: u16, body: []const u8, www_authenticate: []const u8 = "" };

    fn request(s: *Login, place: []const u8, method: @FieldType(http.Request, "method"), body: ?[]const u8, content_type: []const u8, headers: []const std.http.Header) Error!Got {
        const u = try s.endpoint(place, "address");
        var c = http.Client.init(s.gpa, s.io, .{ .https = u.https, .host = u.connectHost(), .port = u.port, .prefix = "" });
        defer c.deinit();
        var resp = c.send(.{
            .method = method,
            .path = u.target,
            .body = body,
            .content_type = if (content_type.len > 0) content_type else "application/json",
            .headers = headers,
            .accept = "application/json, text/event-stream",
            .keep = &.{"www-authenticate"},
            .limits = .{ .idle_ms = s.o.request_ms, .total_ms = s.o.request_ms, .stop = s.o.stop },
        }) catch |e| {
            if (s.o.stop) |f| if (f.load(.acquire)) return error.Stopped;
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return s.fail(error.Unreachable, "{s} could not be reached ({s})", .{ util.cut(place, 120), @errorName(e) });
        };
        defer resp.deinit();
        const text = resp.readAll(s.a, max_answer) catch "";
        return .{ .status = resp.status, .body = text, .www_authenticate = if (resp.kept[0]) |w| try s.a.dupe(u8, w) else "" };
    }

    /// Takes connections until one asks for /callback (others get 404),
    /// within `wait_ms`; checks its state and iss, then exchanges its code.
    fn wait(s: *Login, listener: *sock.Listener, state: []const u8, issuer: []const u8, comptime exchangeFn: anytype, args: anytype) Error!Answer {
        const deadline = nowNs(s.io) + @as(i128, s.o.wait_ms) * std.time.ns_per_ms;
        while (true) {
            const left = @divFloor(deadline - nowNs(s.io), std.time.ns_per_ms);
            if (left <= 0) return s.fail(error.TimedOut, "no sign-in came back within {s}; nothing was stored", .{try waitText(s.a, s.o.wait_ms)});
            const conn = (listener.acceptWithin(s.io, @intCast(left), s.o.stop) catch return s.fail(error.Unreachable, "the sign-in's listener failed", .{})) orelse {
                if (s.o.stop) |f| if (f.load(.acquire)) return error.Stopped;
                continue;
            };
            defer sock.closeHandle(conn);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [4 * 1024]u8 = undefined;
            var sk: sock.Socket = undefined;
            sk.init(s.io, conn, &rbuf, &wbuf, 5000);
            sk.setLimits(@intCast(@min(left, 5000)), @intCast(@min(left, 10_000)), s.o.stop);
            var server = std.http.Server.init(&sk.reader, &sk.writer);
            var req = server.receiveHead() catch continue;
            const target = req.head.target;
            const qmark = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            if (req.head.method != .GET or !std.mem.eql(u8, target[0..qmark], "/callback")) {
                req.respond("Not found.\n", .{ .status = .not_found, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} }) catch {};
                continue;
            }
            // the one sign-in: whatever it carries, the listener ends with it
            const q = try parseQuery(s.a, target[@min(qmark + 1, target.len)..]);
            const failed: ?Error = blk: {
                if (!constantEql(q.get("state") orelse "", state)) {
                    s.note("the sign-in's answer did not carry the state harness sent, so it may not be this sign-in's; nothing was stored", .{});
                    break :blk error.StateMismatch;
                }
                if (q.get("error")) |e| {
                    const d = q.get("error_description") orelse "";
                    s.note("{s}'s authorization server said {s}{s}{s}; nothing was stored", .{ s.o.name, util.cut(e, 80), if (d.len > 0) ": " else "", util.cut(d, 200) });
                    break :blk error.Refused;
                }
                if (q.get("iss")) |iss| if (!sameIssuer(iss, issuer)) {
                    s.note("the sign-in's answer came from another issuer ({s}); nothing was stored", .{util.cut(iss, 120)});
                    break :blk error.Refused;
                };
                break :blk null;
            };
            if (failed) |e| {
                page(&req, false, s.o.name);
                return e;
            }
            const code = q.get("code") orelse {
                s.note("the sign-in's answer carried no code; nothing was stored", .{});
                page(&req, false, s.o.name);
                return error.Refused;
            };
            const got = @call(.auto, exchangeFn, .{ s, code } ++ args) catch |e| {
                page(&req, false, s.o.name);
                return e;
            };
            page(&req, true, s.o.name);
            return got;
        }
    }
};

/// The page the browser shows once it came back (400 for a sign-in
/// that failed).
fn page(req: *std.http.Server.Request, ok: bool, name: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = (if (ok)
        std.fmt.bufPrint(&buf, "<!doctype html><meta charset=\"utf-8\"><title>harness</title><p>Signed in to {s}.</p><p>You can close this tab.</p>\n", .{name})
    else
        std.fmt.bufPrint(&buf, "<!doctype html><meta charset=\"utf-8\"><title>harness</title><p>Sign-in to {s} failed.</p><p>Nothing was stored; the terminal says why.</p>\n", .{name})) catch return;
    req.respond(text, .{ .status = if (ok) .ok else .bad_request, .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } }) catch {};
}

/// What a token endpoint gave.
pub const Answer = struct {
    access_token: []const u8,
    refresh_token: []const u8 = "",
    expires_in: i64 = 0,
    scope: []const u8 = "",
};

/// A form posted to a token endpoint, with the client proving itself as
/// `method` says; the answer's strings are in `a`. `said` (optional) gets
/// why it failed.
fn tokenRequest(gpa: Allocator, io: Io, a: Allocator, endpoint_url: []const u8, form: *Form, client_id: []const u8, client_secret: []const u8, method: []const u8, ms: u32, stop: ?*const std.atomic.Value(bool), said: ?*[]const u8) !Answer {
    var hs: [1]std.http.Header = undefined;
    var n: usize = 0;
    if (std.mem.eql(u8, method, "client_secret_basic")) {
        var idf: Form = .{ .a = a };
        try idf.escape(client_id);
        const id_enc = try a.dupe(u8, idf.text());
        var sf: Form = .{ .a = a };
        try sf.escape(client_secret);
        const pair = try std.fmt.allocPrint(a, "{s}:{s}", .{ id_enc, sf.text() });
        const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(pair.len));
        _ = std.base64.standard.Encoder.encode(b64, pair);
        hs[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Basic {s}", .{b64}) };
        n = 1;
    } else {
        try form.add("client_id", client_id);
        if (std.mem.eql(u8, method, "client_secret_post")) try form.add("client_secret", client_secret);
    }
    const u = url_mod.parse(a, endpoint_url) catch return error.BadMetadata;
    if (!u.https and !loopback(u.host)) return error.BadMetadata;
    var c = http.Client.init(gpa, io, .{ .https = u.https, .host = u.connectHost(), .port = u.port, .prefix = "" });
    defer c.deinit();
    var resp = c.send(.{
        .method = .POST,
        .path = u.target,
        .body = form.text(),
        .content_type = "application/x-www-form-urlencoded",
        .headers = hs[0..n],
        .accept = "application/json",
        // a code or a refresh token is used once: never sent twice
        .resend = false,
        .limits = .{ .idle_ms = @max(ms, 1), .total_ms = @max(ms, 1), .stop = stop },
    }) catch |e| {
        if (stop) |f| if (f.load(.acquire)) return error.Stopped;
        if (said) |p| p.* = std.fmt.allocPrint(a, "the token endpoint could not be reached ({s})", .{@errorName(e)}) catch "";
        return error.Unreachable;
    };
    defer resp.deinit();
    const body = resp.readAll(a, max_answer) catch "";
    if (resp.status != 200) {
        if (said) |p| p.* = std.fmt.allocPrint(a, "the token endpoint refused ({d}){s}", .{ resp.status, oauthDetail(a, body) catch "" }) catch "";
        return error.Refused;
    }
    const v = jv.parse(a, body) orelse return error.BadMetadata;
    const access = jv.str(jv.get(v, "access_token")) orelse return error.BadMetadata;
    if (access.len == 0) return error.BadMetadata;
    const kind = jv.str(jv.get(v, "token_type")) orelse "Bearer";
    if (!std.ascii.eqlIgnoreCase(kind, "bearer")) {
        if (said) |p| p.* = std.fmt.allocPrint(a, "the token endpoint gave a {s} token, not a Bearer one", .{util.cut(kind, 40)}) catch "";
        return error.BadMetadata;
    }
    return .{
        .access_token = access,
        .refresh_token = jv.str(jv.get(v, "refresh_token")) orelse "",
        .expires_in = jv.int(jv.get(v, "expires_in")) orelse 0,
        .scope = jv.str(jv.get(v, "scope")) orelse "",
    };
}

/// ": DESCRIPTION" of an OAuth error answer ("" without one).
fn oauthDetail(a: Allocator, body: []const u8) ![]const u8 {
    const v = jv.parse(a, body);
    const d = jv.str(jv.get(v, "error_description")) orelse jv.str(jv.get(v, "error")) orelse return "";
    return std.fmt.allocPrint(a, ": {s}", .{util.cut(d, 200)});
}

/// Where an authorization server's metadata may be (RFC 8414's place,
/// then OpenID discovery's two).
fn asPlaces(a: Allocator, issuer: url_mod.Url) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const path = std.mem.trimEnd(u8, issuer.target[0 .. std.mem.indexOfScalar(u8, issuer.target, '?') orelse issuer.target.len], "/");
    const root = try std.fmt.allocPrint(a, "{s}://{s}", .{ issuer.scheme(), issuer.host_port });
    try out.append(a, try std.fmt.allocPrint(a, "{s}/.well-known/oauth-authorization-server{s}", .{ root, path }));
    try out.append(a, try std.fmt.allocPrint(a, "{s}/.well-known/openid-configuration{s}", .{ root, path }));
    if (path.len > 0) try out.append(a, try std.fmt.allocPrint(a, "{s}{s}/.well-known/openid-configuration", .{ root, path }));
    return out.items;
}

/// Issuers are compared as written, a trailing "/" aside.
fn sameIssuer(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, x, "/"), std.mem.trimEnd(u8, y, "/"));
}

fn loopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]")) return true;
    return url_mod.isIp(host) and std.mem.startsWith(u8, host, "127.");
}

/// A parameter of a WWW-Authenticate header (`name="value"` or
/// `name=value`).
pub fn authParam(header: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.ascii.findIgnoreCasePos(header, i, name)) |at| {
        i = at + name.len;
        // a whole word: not the end of another parameter's name
        if (at > 0 and (std.ascii.isAlphanumeric(header[at - 1]) or header[at - 1] == '_')) continue;
        var j = at + name.len;
        while (j < header.len and header[j] == ' ') j += 1;
        if (j >= header.len or header[j] != '=') continue;
        j += 1;
        while (j < header.len and header[j] == ' ') j += 1;
        if (j < header.len and header[j] == '"') {
            const end = std.mem.indexOfScalarPos(u8, header, j + 1, '"') orelse return null;
            return header[j + 1 .. end];
        }
        const end = std.mem.indexOfAnyPos(u8, header, j, ", ") orelse header.len;
        return header[j..end];
    }
    return null;
}

fn joinScopes(a: Allocator, list: []const jv.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |v| {
        const scope = jv.str(v) orelse continue;
        if (scope.len == 0 or std.mem.indexOfAny(u8, scope, " \"\\") != null) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, scope);
    }
    return out.items;
}

fn waitText(a: Allocator, ms: u32) ![]const u8 {
    if (ms >= 60_000 and ms % 60_000 == 0) return std.fmt.allocPrint(a, "{d} minutes", .{ms / 60_000});
    if (ms >= 1000 and ms % 1000 == 0) return std.fmt.allocPrint(a, "{d} s", .{ms / 1000});
    return std.fmt.allocPrint(a, "{d} ms", .{ms});
}

fn constantEql(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var d: u8 = 0;
    for (x, y) |p, q| d |= p ^ q;
    return d == 0;
}

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// application/x-www-form-urlencoded (a link's query too): unreserved
/// characters as they are, the rest %XX.
pub const Form = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn add(f: *Form, name: []const u8, value: []const u8) !void {
        if (f.buf.items.len > 0) try f.buf.append(f.a, '&');
        try f.escape(name);
        try f.buf.append(f.a, '=');
        try f.escape(value);
    }

    pub fn escape(f: *Form, s: []const u8) !void {
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
                try f.buf.append(f.a, c);
            } else try f.buf.print(f.a, "%{X:0>2}", .{c});
        }
    }

    pub fn text(f: *const Form) []const u8 {
        return f.buf.items;
    }
};

/// A query's parameters, decoded (`+` is a space).
pub const Query = struct {
    names: []const []const u8,
    values: []const []const u8,

    pub fn get(q: Query, name: []const u8) ?[]const u8 {
        for (q.names, q.values) |n, v| if (std.mem.eql(u8, n, name)) return v;
        return null;
    }
};

pub fn parseQuery(a: Allocator, query: []const u8) !Query {
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try names.append(a, try unescape(a, pair[0..eq]));
        try values.append(a, try unescape(a, if (eq < pair.len) pair[eq + 1 ..] else ""));
    }
    return .{ .names = names.items, .values = values.items };
}

fn unescape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try out.append(a, ' ');
        } else if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            try out.append(a, (std.fmt.charToDigit(s[i + 1], 16) catch 0) * 16 + (std.fmt.charToDigit(s[i + 2], 16) catch 0));
            i += 2;
        } else try out.append(a, c);
    }
    return out.items;
}

// ---- tests ----

const t = std.testing;
const model = @import("model.zig");
const fake = @import("fake.zig");
const mcp = @import("mcp.zig");

fn nowMs() i64 {
    return @intCast(@divFloor(nowNs(t.io), std.time.ns_per_ms));
}

/// A link the browser is not told (nobody signs in).
fn nobody(_: ?*anyopaque, _: []const u8, _: u16) void {}

test "oauth_login_registers_exchanges_and_refreshes" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    const server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/signin", .{e.server.port});
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{e.server.port});
    // the token expires within the minute renewals come early by
    h.setExpiresIn(30);
    var b: fake.Browser = .{ .io = t.io };
    var said: []const u8 = "";
    const tokens = login(t.allocator, t.io, a, .{ .name = "web", .url = server, .link = .{ .ctx = &b, .f = fake.Browser.opened } }, &said) catch |err| {
        std.debug.print("said: {s}\n", .{said});
        return err;
    };
    b.join();
    // registered, then a link with PKCE, a state, the resource and the
    // metadata's scopes; the stand-in checked the verifier against it
    try t.expectEqual(1, h.registered.load(.acquire));
    try t.expectEqual(1, h.pkce_ok.load(.acquire));
    const asked = try h.lastAuthorize(a);
    for ([_][]const u8{ "response_type=code", "client_id=client-1", "code_challenge_method=S256", "code_challenge=", "state=", "scope=mcp.read%20mcp.write", "redirect_uri=http%3A%2F%2F127.0.0.1%3A" }) |want| {
        if (std.mem.indexOf(u8, asked, want) == null) std.debug.print("{s} not in {s}\n", .{ want, asked });
        try t.expect(std.mem.indexOf(u8, asked, want) != null);
    }
    try t.expect(std.mem.indexOf(u8, asked, try std.fmt.allocPrint(a, "resource=http%3A%2F%2F127.0.0.1%3A{d}%2Fmcp%2Fsignin", .{e.server.port})) != null);
    try t.expectEqual(200, b.status);
    try t.expect(std.mem.indexOf(u8, b.body(), "Signed in to web.") != null);
    try t.expect(std.mem.startsWith(u8, tokens.access_token, "fake-access-"));
    try t.expect(std.mem.startsWith(u8, tokens.refresh_token, "fake-refresh-"));
    try t.expectEqualStrings("client-1", tokens.client_id);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/auth/token", .{base}), tokens.token_endpoint);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/auth", .{base}), tokens.issuer);
    try t.expectEqualStrings(server, tokens.resource);
    try t.expectEqualStrings("mcp.read mcp.write", tokens.scope);

    // kept in the store, masked once read
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ e.dir, "secrets" }) };
    try save(t.io, t.allocator, st, "mcp-web", tokens);
    var ml: masks_mod.List = .init(t.allocator, t.io);
    defer ml.deinit();
    const k = try Keeper.open(t.allocator, t.io, st, "web", "mcp-web", &ml);
    defer k.destroy();
    try t.expectEqual(2, ml.count());
    // renewed before it is sent, once
    h.setExpiresIn(3600);
    const first = try k.bearer(a, null, 5000);
    try t.expect(!std.mem.eql(u8, first, tokens.access_token));
    try t.expectEqual(1, h.refreshes.load(.acquire));
    try t.expectEqualStrings(first, try k.bearer(a, null, 5000));
    try t.expectEqual(1, h.refreshes.load(.acquire));
    // the renewed tokens are kept and masked
    try t.expectEqualStrings(first, (try load(t.io, a, st, "mcp-web")).?.access_token);
    try t.expect(ml.count() >= 3);

    // a server that refuses the token (401): renewed once, and the call goes on
    var stop: std.atomic.Value(bool) = .init(false);
    const srv = try mcp.Server.start(t.allocator, t.io, .{ .name = "web", .command = "", .url = server, .login = true, .secrets = &.{}, .money = &.{} }, .{
        .cwd = "",
        .path_var = "",
        .home = "",
        .secret_values = &.{},
        .start_timeout_ms = 10000,
        .auth = .{ .signin = .{ .store = st, .masks = &ml } },
    });
    defer srv.deinit();
    h.expireTokens();
    try t.expectEqualStrings("after a refresh", (try srv.call(a, "echo", "{\"text\":\"after a refresh\"}", &stop, 5000, 4096)).text);
    try t.expectEqual(2, h.refreshes.load(.acquire));
    // what it says back is masked, the renewed token too
    try t.expectEqualStrings("Bearer [secret:mcp-web]", (try srv.call(a, "echo", "{\"text\":\"auth\"}", &stop, 5000, 4096)).text);
    // the refresh token refused too: said, and remembered for /status
    h.revokeRefresh();
    h.expireTokens();
    const no = try srv.call(a, "echo", "{\"text\":\"x\"}", &stop, 5000, 4096);
    try t.expect(no.is_error);
    try t.expectEqualStrings("web refused the sign-in: harness mcp login web", no.text);
    try t.expect(srv.signInRefused());
    // a sign-in made meanwhile from the terminal is taken at the next 401
    var b2: fake.Browser = .{ .io = t.io };
    const again = try login(t.allocator, t.io, a, .{ .name = "web", .url = server, .link = .{ .ctx = &b2, .f = fake.Browser.opened } }, &said);
    b2.join();
    try save(t.io, t.allocator, st, "mcp-web", again);
    try t.expectEqualStrings("back", (try srv.call(a, "echo", "{\"text\":\"back\"}", &stop, 5000, 4096)).text);
    try t.expect(!srv.signInRefused());
}

test "the_login_listener_takes_one_request_and_ends" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    const server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/signin", .{e.server.port});
    // an icon asked first is not the sign-in; the callback that follows,
    // with a state that is not this sign-in's, ends it
    var b: fake.Browser = .{ .io = t.io, .first = "/favicon.ico", .state = "not-this-sign-in" };
    var said: []const u8 = "";
    try t.expectError(error.StateMismatch, login(t.allocator, t.io, a, .{ .name = "web", .url = server, .link = .{ .ctx = &b, .f = fake.Browser.opened } }, &said));
    b.join();
    try t.expectEqual(404, b.first_status);
    try t.expectEqual(400, b.status);
    try t.expect(std.mem.indexOf(u8, b.body(), "Sign-in to web failed.") != null);
    try t.expectEqualStrings("the sign-in's answer did not carry the state harness sent, so it may not be this sign-in's; nothing was stored", said);
    // no code was exchanged
    try t.expectEqual(0, h.pkce_ok.load(.acquire));
    // the listener is gone
    const back = try url_mod.parse(a, b.back());
    try t.expect(back.port != e.server.port);
    if (sock.connect(t.io, "127.0.0.1", back.port, 1000)) |conn| {
        sock.closeHandle(conn);
        return error.TestUnexpectedResult;
    } else |_| {}
    // nobody comes: it ends at its time
    const t0 = nowMs();
    try t.expectError(error.TimedOut, login(t.allocator, t.io, a, .{ .name = "web", .url = server, .wait_ms = 300, .link = .{ .f = nobody } }, &said));
    const took = nowMs() - t0;
    if (took >= 3000) std.debug.print("a listener waiting 300 ms took {d} ms\n", .{took});
    try t.expect(took < 3000);
    try t.expectEqualStrings("no sign-in came back within 300 ms; nothing was stored", said);
}

test "a_set_client_id_skips_registration_and_openid_is_the_fallback" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    // its 401 names no metadata: the well-known place for its path; its
    // authorization server has only OpenID discovery
    h.setOpenIdOnly(true);
    const server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/signin-hidden", .{e.server.port});
    var b: fake.Browser = .{ .io = t.io };
    var said: []const u8 = "";
    const tokens = login(t.allocator, t.io, a, .{ .name = "web", .url = server, .client_id = "fixed-client", .scope = "mcp.read", .link = .{ .ctx = &b, .f = fake.Browser.opened } }, &said) catch |err| {
        std.debug.print("said: {s}\n", .{said});
        return err;
    };
    b.join();
    try t.expectEqual(0, h.registered.load(.acquire));
    try t.expectEqualStrings("fixed-client", tokens.client_id);
    const asked = try h.lastAuthorize(a);
    try t.expect(std.mem.indexOf(u8, asked, "client_id=fixed-client") != null);
    try t.expect(std.mem.indexOf(u8, asked, "scope=mcp.read&") != null or std.mem.endsWith(u8, asked, "scope=mcp.read"));
    const log = try e.tmp.dir.readFileAlloc(t.io, "mcp-requests.jsonl", a, .unlimited);
    try t.expect(std.mem.indexOf(u8, log, "/.well-known/oauth-protected-resource/mcp/signin-hidden") != null);
    try t.expect(std.mem.indexOf(u8, log, "/auth/.well-known/openid-configuration") != null);
    // a server that needs no sign-in says so
    try t.expectError(error.NoSignInNeeded, login(t.allocator, t.io, a, .{ .name = "open", .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/json", .{e.server.port}), .link = .{ .f = nobody } }, &said));
    try t.expectEqualStrings("open answered without a sign-in: it needs none (remove login = oauth from [open] in mcp.ini)", said);
}

test "a_www_authenticate_header_gives_its_parameters" {
    const h = "Bearer realm=\"mcp\", error=\"invalid_token\", resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=files:read";
    try t.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource", authParam(h, "resource_metadata").?);
    try t.expectEqualStrings("files:read", authParam(h, "scope").?);
    try t.expectEqual(null, authParam("Bearer error=\"x\"", "resource_metadata"));
    try t.expectEqual(null, authParam("Bearer my_scope=\"x\"", "scope"));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const q = try parseQuery(arena.allocator(), "code=a%2Bb&state=x+y&iss=http%3A%2F%2Fh&empty=&bare");
    try t.expectEqualStrings("a+b", q.get("code").?);
    try t.expectEqualStrings("x y", q.get("state").?);
    try t.expectEqualStrings("http://h", q.get("iss").?);
    try t.expectEqualStrings("", q.get("empty").?);
    try t.expectEqualStrings("", q.get("bare").?);
    var f: Form = .{ .a = arena.allocator() };
    try f.add("redirect_uri", "http://127.0.0.1:8/callback");
    try f.add("scope", "a b");
    try t.expectEqualStrings("redirect_uri=http%3A%2F%2F127.0.0.1%3A8%2Fcallback&scope=a%20b", f.text());
}

test "a_sign_in_forgotten_by_logout_is_not_renewed" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    const server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/signin", .{e.server.port});
    h.setExpiresIn(30);
    var b: fake.Browser = .{ .io = t.io };
    var said: []const u8 = "";
    const tokens = try login(t.allocator, t.io, a, .{ .name = "web", .url = server, .link = .{ .ctx = &b, .f = fake.Browser.opened } }, &said);
    b.join();
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ e.dir, "secrets" }) };
    try save(t.io, t.allocator, st, "mcp-web", tokens);
    const k = try Keeper.open(t.allocator, t.io, st, "web", "mcp-web", null);
    defer k.destroy();
    // harness mcp logout, while harness runs
    try t.expect(try st.removeLong(t.io, t.allocator, "mcp-web"));
    // about to expire: not renewed (that would keep it again)
    try t.expectEqualStrings(tokens.access_token, try k.bearer(a, null, 5000));
    try t.expectEqual(0, h.refreshes.load(.acquire));
    // refused: not renewed either, and said as refused
    try t.expectEqual(Renewal.refused, k.renew(a, tokens.access_token, null, 5000));
    try t.expect(k.refused());
    try t.expectEqual(0, h.refreshes.load(.acquire));
    try t.expectEqual(null, try load(t.io, a, st, "mcp-web"));
}

test "stopping_a_server_does_not_wait_for_a_renewal" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    const server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/signin", .{e.server.port});
    // every token expires within the minute renewals come early by
    h.setExpiresIn(30);
    var b: fake.Browser = .{ .io = t.io };
    var said: []const u8 = "";
    const tokens = try login(t.allocator, t.io, a, .{ .name = "web", .url = server, .link = .{ .ctx = &b, .f = fake.Browser.opened } }, &said);
    b.join();
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ e.dir, "secrets" }) };
    try save(t.io, t.allocator, st, "mcp-web", tokens);
    const srv = try mcp.Server.start(t.allocator, t.io, .{ .name = "web", .command = "", .url = server, .login = true, .secrets = &.{}, .money = &.{} }, .{
        .cwd = "",
        .path_var = "",
        .home = "",
        .secret_values = &.{},
        .start_timeout_ms = 10000,
        .auth = .{ .signin = .{ .store = st } },
    });
    // the requests renewed the token as they went; the session's DELETE
    // goes with the token held
    const before = h.refreshes.load(.acquire);
    try t.expect(before > 0);
    srv.deinit();
    try t.expectEqual(1, h.deleted.load(.acquire));
    try t.expectEqual(before, h.refreshes.load(.acquire));
}

/// A login to the stand-in's /mcp/signin, kept in a folder store.
const Signed = struct {
    st: store_mod.Store,
    tokens: Tokens,
    server: []const u8,
};

fn signIn(e: *model.TestEnv) !Signed {
    const a = e.arena.allocator();
    const server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/signin", .{e.server.port});
    var b: fake.Browser = .{ .io = t.io };
    var said: []const u8 = "";
    const tokens = login(t.allocator, t.io, a, .{ .name = "web", .url = server, .link = .{ .ctx = &b, .f = fake.Browser.opened } }, &said) catch |err| {
        std.debug.print("said: {s}\n", .{said});
        return err;
    };
    b.join();
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ e.dir, "secrets" }) };
    try save(t.io, t.allocator, st, "mcp-web", tokens);
    return .{ .st = st, .tokens = tokens, .server = server };
}

test "a_renewal_ends_with_the_call" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    h.setExpiresIn(30);
    const sg = try signIn(&e);
    var stop: std.atomic.Value(bool) = .init(false);
    const srv = try mcp.Server.start(t.allocator, t.io, .{ .name = "web", .command = "", .url = sg.server, .login = true, .secrets = &.{}, .money = &.{} }, .{
        .cwd = "",
        .path_var = "",
        .home = "",
        .secret_values = &.{},
        .start_timeout_ms = 10000,
        .auth = .{ .signin = .{ .store = sg.st } },
    });
    defer srv.deinit();
    // the authorization server is slow: the renewal ends when the call's time does
    h.setTokenDelay(5000);
    const t0 = nowMs();
    try t.expectError(error.Timeout, srv.call(a, "echo", "{\"text\":\"x\"}", &stop, 500, 4096));
    const took = nowMs() - t0;
    if (took >= 2500) std.debug.print("a call of 500 ms took {d} ms\n", .{took});
    try t.expect(took < 2500);
    // and when it is stopped
    const th = try std.Thread.spawn(.{}, struct {
        fn later(f: *std.atomic.Value(bool)) void {
            t.io.sleep(.fromMilliseconds(300), .awake) catch {};
            f.store(true, .release);
        }
    }.later, .{&stop});
    const t1 = nowMs();
    try t.expectError(error.Stopped, srv.call(a, "echo", "{\"text\":\"x\"}", &stop, 30000, 4096));
    th.join();
    const stopped = nowMs() - t1;
    if (stopped >= 2500) std.debug.print("a call stopped after 300 ms took {d} ms\n", .{stopped});
    try t.expect(stopped < 2500);
    // neither is a refusal
    try t.expect(!srv.signInRefused());
}

test "a_renewal_that_could_not_reach_the_server_is_not_a_refusal" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const sg = try signIn(&e);
    // a token endpoint nobody listens on
    var away = sg.tokens;
    away.token_endpoint = "http://127.0.0.1:1/auth/token";
    try save(t.io, t.allocator, sg.st, "mcp-web", away);
    const k = try Keeper.open(t.allocator, t.io, sg.st, "web", "mcp-web", null);
    defer k.destroy();
    try t.expectEqual(Renewal.failed, k.renew(a, away.access_token, null, 2000));
    try t.expect(!k.refused());
    // refused once, then renewed: no longer refused
    try save(t.io, t.allocator, sg.st, "mcp-web", sg.tokens);
    const k2 = try Keeper.open(t.allocator, t.io, sg.st, "web", "mcp-web", null);
    defer k2.destroy();
    k2.markRefused();
    try t.expectEqual(Renewal.renewed, k2.renew(a, sg.tokens.access_token, null, 5000));
    try t.expect(!k2.refused());
}

test "secret_names_outlive_a_renewal" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const sg = try signIn(&e);
    const k = try Keeper.open(t.allocator, t.io, sg.st, "web", "mcp-web", null);
    defer k.destroy();
    const before = try k.secrets(a);
    // a renewal replaces what the keeper holds
    try t.expectEqual(Renewal.renewed, k.renew(a, sg.tokens.access_token, null, 5000));
    for (before) |x| try t.expectEqualStrings("mcp-web", x.name);
}

test "a_huge_expiry_is_kept_not_overflowed" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    e.server.mcp.setExpiresIn(std.math.maxInt(i64));
    const sg = try signIn(&e);
    try t.expectEqual(std.math.maxInt(i64), sg.tokens.expires_at);
}

test "a_renewal_kept_only_in_memory_is_not_undone" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const h = &e.server.mcp;
    // every token expires within the minute renewals come early by
    h.setExpiresIn(30);
    const sg = try signIn(&e);
    const k = try Keeper.open(t.allocator, t.io, sg.st, "web", "mcp-web", null);
    defer k.destroy();
    // the store can't be written: renewals are held in memory only
    var dir = try Io.Dir.cwd().openDir(t.io, sg.st.dir, .{ .iterate = true });
    defer dir.close(t.io);
    try dir.setPermissions(t.io, .fromMode(0o500));
    defer dir.setPermissions(t.io, .fromMode(0o700)) catch {};
    const first = try k.bearer(a, null, 5000);
    try t.expect(!std.mem.eql(u8, first, sg.tokens.access_token));
    // the store's older sign-in is not taken for a newer one: the next
    // renewal uses the refresh token held (the stand-in ended the old one)
    const second = try k.bearer(a, null, 5000);
    try t.expect(!std.mem.eql(u8, second, sg.tokens.access_token));
    try t.expect(!std.mem.eql(u8, second, first));
    try t.expectEqual(2, h.refreshes.load(.acquire));
    try t.expect(!k.refused());
}
