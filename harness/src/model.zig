//! The model, through a provider: omnigate (the default), Anthropic,
//! OpenRouter, OpenCode Zen, OpenAI or any gateway that speaks Anthropic
//! Messages (`…/messages`) or OpenAI Chat Completions
//! (`…/chat/completions`): one request with the conversation and the
//! tools, one whole answer back.
const std = @import("std");
const http = @import("http.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const Block = union(enum) {
    text: []const u8,
    tool_use: struct { id: []const u8, name: []const u8, input_json: []const u8 },
    tool_result: struct { id: []const u8, content: []const u8, is_error: bool = false },
};

pub const Role = enum { user, assistant };

pub const Message = struct { role: Role, blocks: []const Block };

pub const ToolDef = struct { name: []const u8, description: []const u8, schema_json: []const u8 };

pub const Reply = struct {
    blocks: []Block,
    stop_reason: []const u8,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    /// Prompt-cache figures: input read from cache, input written to it.
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn text(r: Reply, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (r.blocks) |b| if (b == .text) {
            if (out.items.len > 0) try out.append(arena, '\n');
            try out.appendSlice(arena, b.text);
        };
        return out.items;
    }
};

pub const Error = error{
    /// omnigate answered 402: the key's budget is spent. Never retried.
    BudgetSpent,
    /// 429 twice in a row.
    RateLimited,
    /// 400 or 413: the request itself was refused (invalid, or too
    /// large); sent again unchanged it would be refused again.
    Rejected,
    /// Any other error status from omnigate or the provider.
    Upstream,
    /// The answer was not the expected JSON.
    BadReply,
    /// No key is stored: the call is refused before anything is sent.
    NoKey,
    /// 401 or 403: the provider refused the key. Never retried.
    KeyRefused,
    /// No url is set: the call is refused before anything is sent.
    NoUrl,
    /// /stop came while waiting to send again: nothing more was sent.
    Stopped,
    /// The turn's time ran out: the call was not sent, or was cut off at
    /// the turn's deadline (told apart from a call that took too long by
    /// itself, whatever the clocks round to).
    TimeUp,
} || http.Error;

// ---- providers ----

/// The request format a provider speaks.
pub const Api = enum {
    /// Anthropic Messages: POST URL/messages.
    anthropic,
    /// OpenAI Chat Completions: POST URL/chat/completions.
    openai,
};

/// How a provider takes its key: `x-api-key: KEY`, `Authorization:
/// Bearer KEY`, or not at all.
pub const Auth = enum { x_api_key, bearer, none };

pub fn parseApi(w: []const u8) ?Api {
    if (std.mem.eql(u8, w, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, w, "openai")) return .openai;
    return null;
}

pub fn parseAuth(w: []const u8) ?Auth {
    if (std.mem.eql(u8, w, "x-api-key")) return .x_api_key;
    if (std.mem.eql(u8, w, "bearer")) return .bearer;
    if (std.mem.eql(u8, w, "none")) return .none;
    return null;
}

pub const Header = std.http.Header;

/// Most `header =` lines one provider takes.
pub const max_headers = 8;

/// What a `[provider NAME]` section says (config.zig reads it); null: the
/// preset's value, or for a new provider the default.
pub const Section = struct {
    name: []const u8,
    api: ?Api = null,
    url: ?[]const u8 = null,
    auth: ?Auth = null,
    /// The stored secret holding its key.
    key: ?[]const u8 = null,
    cache: ?bool = null,
    headers: []const Header = &.{},
};

pub const Preset = struct {
    name: []const u8,
    api: Api,
    url: []const u8,
    auth: Auth,
    cache: bool,
    key: []const u8,
    tokens_field: []const u8 = "max_tokens",
};

/// The providers that need no section. omnigate's url and key secret are
/// `[model] url` and `[model] key`.
pub const presets = [_]Preset{
    .{ .name = "omnigate", .api = .anthropic, .url = "", .auth = .x_api_key, .cache = true, .key = "omnigate" },
    .{ .name = "anthropic", .api = .anthropic, .url = "https://api.anthropic.com/v1", .auth = .x_api_key, .cache = true, .key = "anthropic" },
    // its cache marks reach Anthropic's models
    .{ .name = "openrouter", .api = .openai, .url = "https://openrouter.ai/api/v1", .auth = .bearer, .cache = true, .key = "openrouter" },
    .{ .name = "opencode", .api = .openai, .url = "https://opencode.ai/zen/v1", .auth = .bearer, .cache = false, .key = "opencode" },
    // OpenAI caches by itself, and refuses max_tokens for its reasoning models
    .{ .name = "openai", .api = .openai, .url = "https://api.openai.com/v1", .auth = .bearer, .cache = false, .key = "openai", .tokens_field = "max_completion_tokens" },
};

pub fn isPreset(name: []const u8) bool {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

/// A provider's name: a-z, 0-9, `-` and `_`, up to 32, starting with a
/// letter or digit (never `:`, which ends it in a model value).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// A provider's address: http:// or https://, host, port, path.
pub fn validUrl(u: []const u8) bool {
    if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) return false;
    _ = http.Target.parse(u) catch return false;
    return true;
}

/// omnigate's address as 0.3 used it: the path before an optional
/// trailing /v1, then /v1 ("" stays "": not set).
pub fn omnigateUrl(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    var u = url;
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    if (u.len == 0) return "";
    if (std.mem.endsWith(u8, u, "/v1")) return u;
    return std.fmt.allocPrint(arena, "{s}/v1", .{u});
}

pub const Provider = struct {
    name: []const u8,
    api: Api,
    /// What comes before /messages or /chat/completions; "": not set.
    url: []const u8,
    auth: Auth,
    headers: []const Header = &.{},
    /// Prompt-cache marks in its requests.
    cache: bool,
    /// The stored secret holding its key.
    key_name: []const u8,
    /// Its key; "" when none is stored.
    key: []const u8 = "",
    /// The request's field for the most tokens an answer may have.
    tokens_field: []const u8 = "max_tokens",

    /// Whether its calls can be made as far as the key goes.
    pub fn hasKey(p: Provider) bool {
        return p.auth == .none or p.key.len > 0;
    }

    pub fn apiName(p: Provider) []const u8 {
        return switch (p.api) {
            .anthropic => "Anthropic Messages",
            .openai => "OpenAI Chat Completions",
        };
    }

    fn override(p: *Provider, s: Section) void {
        if (s.api) |v| p.api = v;
        if (s.url) |v| p.url = v;
        if (s.auth) |v| p.auth = v;
        if (s.key) |v| p.key_name = v;
        if (s.cache) |v| p.cache = v;
        if (s.headers.len > 0) p.headers = s.headers;
    }
};

/// What the providers are made from: config.ini's `[model] provider`,
/// `url`, `key` and its `[provider NAME]` sections.
pub const Settings = struct {
    default: []const u8 = "omnigate",
    omnigate_url: []const u8 = "",
    omnigate_key: []const u8 = "omnigate",
    sections: []const Section = &.{},
};

/// Where providers' keys come from: the value stored under `secret` for
/// `provider`, allocated in `a` (or living longer), or null.
pub const KeyLookup = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, a: std.mem.Allocator, provider: []const u8, secret: []const u8) ?[]const u8,
};

pub const no_keys: KeyLookup = .{ .get = noKey };

fn noKey(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ?[]const u8 {
    return null;
}

/// The provider and model a model value names.
pub const Choice = struct { provider: *const Provider, model: []const u8 };

pub const Providers = struct {
    /// The presets, then the other sections in the order they appear.
    list: []const Provider,
    /// The provider of a model value without a known prefix.
    default: usize = 0,

    /// The presets, each overridden by its section, and the other
    /// sections; each one's key looked up unless it needs none.
    pub fn resolve(arena: std.mem.Allocator, s: Settings, keys: KeyLookup) error{OutOfMemory}!Providers {
        var list: std.ArrayList(Provider) = .empty;
        for (presets) |pr| {
            const omni = std.mem.eql(u8, pr.name, "omnigate");
            var p: Provider = .{ .name = pr.name, .api = pr.api, .url = if (omni) s.omnigate_url else pr.url, .auth = pr.auth, .cache = pr.cache, .key_name = if (omni) s.omnigate_key else pr.key, .tokens_field = pr.tokens_field };
            if (sectionOf(s.sections, pr.name)) |sec| p.override(sec);
            if (omni) p.url = try omnigateUrl(arena, p.url);
            try list.append(arena, p);
        }
        for (s.sections) |sec| {
            if (isPreset(sec.name)) continue;
            // config.ini refuses a new provider without api and url
            const api = sec.api orelse continue;
            var p: Provider = .{ .name = sec.name, .api = api, .url = "", .auth = if (api == .anthropic) .x_api_key else .bearer, .cache = api == .anthropic, .key_name = sec.name };
            p.override(sec);
            try list.append(arena, p);
        }
        for (list.items) |*p| {
            if (p.auth != .none) p.key = keys.get(keys.ctx, arena, p.name, p.key_name) orelse "";
        }
        var default: usize = 0;
        for (list.items, 0..) |p, i| if (std.mem.eql(u8, p.name, s.default)) {
            default = i;
            break;
        };
        return .{ .list = list.items, .default = default };
    }

    fn sectionOf(sections: []const Section, name: []const u8) ?Section {
        for (sections) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    pub fn find(p: *const Providers, name: []const u8) ?*const Provider {
        for (p.list) |*x| if (std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    /// The one way a model value is read, wherever it is written
    /// (`[model]`, agent definitions, workflow steps): `PROVIDER:MODEL`
    /// when the part before the first `:` is a provider's name, else a
    /// model of the default provider (so `llama3.1:8b` stays whole).
    pub fn pick(p: *const Providers, value: []const u8) Choice {
        if (std.mem.indexOfScalar(u8, value, ':')) |i| {
            if (p.find(value[0..i])) |prov| return .{ .provider = prov, .model = value[i + 1 ..] };
        }
        return .{ .provider = &p.list[p.default], .model = value };
    }

    /// A client for a model value (see `pick`).
    pub fn client(p: *const Providers, gpa: std.mem.Allocator, io: Io, value: []const u8, max_tokens: u32) http.Error!Client {
        const ch = p.pick(value);
        return Client.open(gpa, io, ch.provider.*, ch.model, max_tokens);
    }

    /// The providers `values` pick, each once, in the order first picked.
    pub fn used(p: *const Providers, arena: std.mem.Allocator, values: []const []const u8) ![]const *const Provider {
        var out: std.ArrayList(*const Provider) = .empty;
        for (values) |v| {
            const prov = p.pick(v).provider;
            if (std.mem.indexOfScalar(*const Provider, out.items, prov) == null) try out.append(arena, prov);
        }
        return out.items;
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Null when no url is set: every call is refused.
    http: ?http.Client,
    key: []const u8,
    model: []const u8,
    max_tokens: u32,
    /// Its provider's name, said in errors and on the log's model lines.
    provider: []const u8 = "omnigate",
    /// The stored secret holding the key, named when it is missing or refused.
    key_name: []const u8 = "omnigate",
    api: Api = .anthropic,
    auth: Auth = .x_api_key,
    headers: []const Header = &.{},
    /// Prompt-cache marks in its requests.
    cache: bool = true,
    /// Where requests go, after the address's path.
    path: []const u8 = "/v1/messages",
    tokens_field: []const u8 = "max_tokens",
    /// The error message the provider gave with the last failure, if any.
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
    /// Longest wait on a 429 (seconds).
    max_retry_wait: u32 = 60,
    /// Longest one call may take (ms), whatever the deadline.
    call_ms: u32 = 900_000,

    /// omnigate as 0.3 reached it: `url` (its path before an optional
    /// /v1), then /v1/messages, the key as x-api-key. An empty `url` or
    /// `key` gives a client whose calls are refused (error.NoUrl,
    /// error.NoKey), so nothing is sent without both.
    pub fn init(gpa: std.mem.Allocator, io: Io, url: []const u8, key: []const u8, model: []const u8, max_tokens: u32) http.Error!Client {
        const target: ?http.Target = if (url.len == 0) null else try http.Target.parse(url);
        return .{ .gpa = gpa, .io = io, .http = if (target) |tg| .init(gpa, io, tg) else null, .key = key, .model = model, .max_tokens = max_tokens };
    }

    /// A client for `model` at provider `p`: requests go to its url's
    /// path as written, then /messages or /chat/completions. Its strings
    /// must outlive the client. No url: every call is refused (NoUrl); no
    /// key where one is needed: refused too (NoKey).
    pub fn open(gpa: std.mem.Allocator, io: Io, p: Provider, model: []const u8, max_tokens: u32) http.Error!Client {
        var target: ?http.Target = null;
        if (p.url.len > 0) {
            var tg = try http.Target.parse(p.url);
            tg.prefix = urlPath(p.url);
            target = tg;
        }
        return .{
            .gpa = gpa,
            .io = io,
            .http = if (target) |tg| .init(gpa, io, tg) else null,
            .key = p.key,
            .model = model,
            .max_tokens = max_tokens,
            .provider = p.name,
            .key_name = p.key_name,
            .api = p.api,
            .auth = p.auth,
            .headers = p.headers,
            .cache = p.cache,
            .path = switch (p.api) {
                .anthropic => "/messages",
                .openai => "/chat/completions",
            },
            .tokens_field = p.tokens_field,
        };
    }

    /// The path of an address http.Target.parse took, as written,
    /// without a trailing `/` ("" for none).
    fn urlPath(url: []const u8) []const u8 {
        var rest = url;
        if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
        var path = rest[std.mem.indexOfScalar(u8, rest, '/') orelse rest.len ..];
        while (std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
        return path;
    }

    /// What the owner is told when a call failed with `e`: the same words
    /// for every provider, naming it (omnigate's are 0.3's, word for word).
    pub fn failure(c: *const Client, a: std.mem.Allocator, e: anyerror) ![]const u8 {
        const omni = std.mem.eql(u8, c.provider, "omnigate");
        const at = if (omni) "" else try std.fmt.allocPrint(a, " at {s}", .{c.provider});
        const msg = c.lastError();
        const out: []const u8 = switch (e) {
            error.BudgetSpent => try std.fmt.allocPrint(a, "Model budget used up{s}.", .{at}),
            error.RateLimited => try std.fmt.allocPrint(a, "The model is rate limited{s}; try again later.", .{at}),
            error.NoKey => try std.fmt.allocPrint(a, "Model calls are refused: no {s} key is stored (harness secret add {s}).", .{ c.provider, c.key_name }),
            error.NoUrl => if (omni)
                "Model calls are refused: no omnigate url is set ([model] url in config.ini, then /reload)."
            else
                try std.fmt.allocPrint(a, "Model calls are refused: no {s} url is set ([provider {s}] url in config.ini, then /reload).", .{ c.provider, c.provider }),
            error.KeyRefused => try std.fmt.allocPrint(a, "Model calls are refused: {s} refused the key stored as {s}{s}{s}{s}; store the right key with harness secret add {s}.", .{
                c.provider, c.key_name, if (msg.len > 0) " (" else "", msg, if (msg.len > 0) ")" else "", c.key_name,
            }),
            error.TimeUp => "Time limit reached for this turn.",
            error.Timeout => try std.fmt.allocPrint(a, "Model call failed{s}: Timeout {s}", .{ at, msg }),
            error.Rejected => try std.fmt.allocPrint(a, "The model API{s} refused the request: {s}", .{ at, msg }),
            else => try std.fmt.allocPrint(a, "Model call failed{s}: {s} {s}", .{ at, @errorName(e), msg }),
        };
        return out;
    }

    pub fn deinit(c: *Client) void {
        if (c.http) |*h| h.deinit();
    }

    pub fn lastError(c: *const Client) []const u8 {
        return c.last_error[0..c.last_error_len];
    }

    /// What a call's waits end on.
    pub const Limits = struct {
        /// Set: no retry and no wait after it is true.
        stop: ?*const std.atomic.Value(bool) = null,
        /// Unix seconds by which the call must be over; 0: none.
        deadline_s: i64 = 0,
    };

    /// A one-off call: the system prompt goes as plain text, unmarked.
    pub fn send(c: *Client, arena: std.mem.Allocator, system: []const u8, messages: []const Message, tools: []const ToolDef) Error!Reply {
        return c.sendSystem(arena, .{ .stable = system, .cache = false }, messages, tools, .{});
    }

    /// A call of a turn: `stable` is the part of the system prompt that
    /// stays the same from call to call (marked for the prompt cache),
    /// `changing` the rest.
    pub fn sendParts(c: *Client, arena: std.mem.Allocator, stable: []const u8, changing: []const u8, messages: []const Message, tools: []const ToolDef, lim: Limits) Error!Reply {
        return c.sendSystem(arena, .{ .stable = stable, .changing = changing }, messages, tools, lim);
    }

    fn sendSystem(c: *Client, arena: std.mem.Allocator, system: System, messages: []const Message, tools: []const ToolDef, lim: Limits) Error!Reply {
        if (c.http == null) return error.NoUrl;
        if (c.auth != .none and c.key.len == 0) return error.NoKey;
        const body = switch (c.api) {
            .anthropic => try anthropicBody(arena, c.model, c.max_tokens, system, messages, tools, c.cache),
            // the OpenAI format comes next
            .openai => try anthropicBody(arena, c.model, c.max_tokens, system, messages, tools, false),
        };
        var limited = false;
        var connect_retry = false;
        while (true) {
            if (stopped(lim)) return error.Stopped;
            // past the deadline nothing is sent; before it, the answer is
            // waited for only until then
            const ms = c.callLimit(lim) orelse return error.TimeUp;
            // shorter than a call may take: the turn's deadline set it
            const by_deadline = lim.deadline_s > 0 and ms < c.call_ms;
            const r = c.post(arena, body, ms) catch |e| switch (e) {
                // nothing reached the server: once more
                error.ConnectFailed => {
                    if (connect_retry) return e;
                    connect_retry = true;
                    continue;
                },
                error.Timeout => return if (by_deadline) error.TimeUp else e,
                // cut off after it was sent: the model may have answered
                // it, and sent again it may be billed twice
                else => return e,
            };
            switch (r.status) {
                200 => return switch (c.api) {
                    .anthropic => parseReply(arena, r.body),
                    .openai => null,
                } orelse error.BadReply,
                401, 403 => {
                    c.note(r.body);
                    return error.KeyRefused;
                },
                402 => {
                    c.note(r.body);
                    return error.BudgetSpent;
                },
                400, 413 => {
                    c.note(r.body);
                    return error.Rejected;
                },
                429 => {
                    c.note(r.body);
                    if (limited) return error.RateLimited;
                    limited = true;
                    try c.pause(@min(r.retry_after_s orelse 5, c.max_retry_wait), lim);
                },
                else => {
                    c.note(r.body);
                    return error.Upstream;
                },
            }
        }
    }

    fn stopped(lim: Limits) bool {
        const f = lim.stop orelse return false;
        return f.load(.acquire);
    }

    /// How long the next call may take (ms): `call_ms`, or less to end by
    /// the deadline; null once the deadline has passed.
    fn callLimit(c: *const Client, lim: Limits) ?u32 {
        if (lim.deadline_s == 0) return c.call_ms;
        const left = lim.deadline_s * 1000 - nowMs(c.io);
        // under 0.1 s no answer can come back: not sent
        if (left < 100) return null;
        return @intCast(@min(left, c.call_ms));
    }

    /// Waits `seconds` before asking again: error.Stopped on /stop,
    /// error.RateLimited at once when the wait would end past the deadline.
    fn pause(c: *Client, seconds: u32, lim: Limits) Error!void {
        const wait_ms = @as(i64, seconds) * 1000;
        if (lim.deadline_s > 0 and nowMs(c.io) + wait_ms >= lim.deadline_s * 1000) return error.RateLimited;
        const until = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, wait_ms) * std.time.ns_per_ms;
        while (Io.Clock.awake.now(c.io).nanoseconds < until) {
            if (stopped(lim)) return error.Stopped;
            c.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        if (stopped(lim)) return error.Stopped;
    }

    fn nowMs(io: Io) i64 {
        return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
    }

    const Raw = struct { status: u16, body: []u8, retry_after_s: ?u32 };

    fn post(c: *Client, arena: std.mem.Allocator, body: []const u8, total_ms: u32) http.Error!Raw {
        // the key as its provider takes it, the format's version, then the
        // provider's own headers
        var hs: [max_headers + 2]Header = undefined;
        var n: usize = 0;
        if (c.auth == .x_api_key) {
            hs[n] = .{ .name = "x-api-key", .value = c.key };
            n += 1;
        }
        if (c.api == .anthropic) {
            hs[n] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            n += 1;
        }
        for (c.headers[0..@min(c.headers.len, max_headers)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = try c.http.?.send(.{
            .path = c.path,
            .body = body,
            .key = if (c.auth == .bearer) c.key else null,
            .headers = hs[0..n],
            .limits = .{ .idle_ms = @min(300_000, total_ms), .total_ms = total_ms },
        });
        defer resp.deinit();
        const got = try resp.readAll(arena, 32 << 20);
        return .{ .status = resp.status, .body = got, .retry_after_s = resp.retry_after_s };
    }

    fn note(c: *Client, body: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = jv.parse(a, body);
        var msg = jv.str(jv.at(v, &.{ "error", "message" })) orelse body;
        // a gateway may say the key back: never kept, never shown
        if (c.key.len > 0) {
            const mark = std.fmt.allocPrint(a, "[secret:{s}]", .{c.key_name}) catch "[secret]";
            msg = std.mem.replaceOwned(u8, a, msg, c.key, mark) catch "(an error message that could not be masked)";
        }
        const s = util.cut(msg, c.last_error.len);
        @memcpy(c.last_error[0..s.len], s);
        c.last_error_len = s.len;
    }
};

const cache_mark = ",\"cache_control\":{\"type\":\"ephemeral\"}";

/// The system prompt of one request.
pub const System = struct {
    /// The same from call to call: marked for the prompt cache when `cache`.
    stable: []const u8,
    /// The rest, after it; never marked.
    changing: []const u8 = "",
    /// false: a one-off call, sent as plain text.
    cache: bool = true,
};

/// An Anthropic Messages request, with omnigate's prompt-cache marks.
pub fn requestBody(arena: std.mem.Allocator, model: []const u8, max_tokens: u32, system: System, messages: []const Message, tools: []const ToolDef) ![]u8 {
    return anthropicBody(arena, model, max_tokens, system, messages, tools, true);
}

/// An Anthropic Messages request. Prompt-cache marks when `marks` (at
/// most 4 are allowed): the last tool, the stable system part (calls of a
/// turn), and the last message's last block, so each step of a turn reads
/// the steps before it from cache, and a new turn reads at least the
/// tools and the instructions.
pub fn anthropicBody(arena: std.mem.Allocator, model: []const u8, max_tokens: u32, system: System, messages: []const Message, tools: []const ToolDef, marks: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"model\":");
    try util.jsonString(&out, arena, model);
    try out.print(arena, ",\"max_tokens\":{d},\"system\":", .{max_tokens});
    // an empty text block is refused, so an empty part is left out
    const marked = marks and system.cache and system.stable.len > 0;
    if (!marked and system.changing.len == 0) {
        try util.jsonString(&out, arena, system.stable);
    } else {
        try out.append(arena, '[');
        if (system.stable.len > 0) {
            try out.appendSlice(arena, "{\"type\":\"text\",\"text\":");
            try util.jsonString(&out, arena, system.stable);
            if (marked) try out.appendSlice(arena, cache_mark);
            try out.append(arena, '}');
        }
        if (system.changing.len > 0) {
            if (system.stable.len > 0) try out.append(arena, ',');
            try out.appendSlice(arena, "{\"type\":\"text\",\"text\":");
            try util.jsonString(&out, arena, system.changing);
            try out.append(arena, '}');
        }
        try out.append(arena, ']');
    }
    try out.appendSlice(arena, ",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try out.append(arena, ',');
        try out.print(arena, "{{\"role\":\"{s}\",\"content\":[", .{@tagName(m.role)});
        for (m.blocks, 0..) |b, j| {
            if (j > 0) try out.append(arena, ',');
            const mark = marks and i + 1 == messages.len and j + 1 == m.blocks.len;
            switch (b) {
                .text => |s| {
                    try out.appendSlice(arena, "{\"type\":\"text\",\"text\":");
                    try util.jsonString(&out, arena, s);
                    if (mark) try out.appendSlice(arena, cache_mark);
                    try out.append(arena, '}');
                },
                .tool_use => |u| {
                    try out.appendSlice(arena, "{\"type\":\"tool_use\",\"id\":");
                    try util.jsonString(&out, arena, u.id);
                    try out.appendSlice(arena, ",\"name\":");
                    try util.jsonString(&out, arena, u.name);
                    try out.print(arena, ",\"input\":{s}", .{if (u.input_json.len > 0) u.input_json else "{}"});
                    if (mark) try out.appendSlice(arena, cache_mark);
                    try out.append(arena, '}');
                },
                .tool_result => |r| {
                    try out.appendSlice(arena, "{\"type\":\"tool_result\",\"tool_use_id\":");
                    try util.jsonString(&out, arena, r.id);
                    try out.appendSlice(arena, ",\"content\":");
                    try util.jsonString(&out, arena, r.content);
                    try out.print(arena, ",\"is_error\":{s}", .{if (r.is_error) "true" else "false"});
                    if (mark) try out.appendSlice(arena, cache_mark);
                    try out.append(arena, '}');
                },
            }
        }
        try out.appendSlice(arena, "]}");
    }
    try out.append(arena, ']');
    if (tools.len > 0) {
        try out.appendSlice(arena, ",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, "{\"name\":");
            try util.jsonString(&out, arena, td.name);
            try out.appendSlice(arena, ",\"description\":");
            try util.jsonString(&out, arena, td.description);
            try out.print(arena, ",\"input_schema\":{s}", .{td.schema_json});
            if (marks and i + 1 == tools.len) try out.appendSlice(arena, cache_mark);
            try out.append(arena, '}');
        }
        try out.append(arena, ']');
    }
    try out.append(arena, '}');
    return out.items;
}

pub fn parseReply(arena: std.mem.Allocator, body: []const u8) ?Reply {
    const v = jv.parse(arena, body) orelse return null;
    const content = jv.arr(jv.get(v, "content")) orelse return null;
    var blocks: std.ArrayList(Block) = .empty;
    for (content) |b| {
        const typ = jv.str(jv.get(b, "type")) orelse continue;
        if (std.mem.eql(u8, typ, "text")) {
            blocks.append(arena, .{ .text = jv.str(jv.get(b, "text")) orelse "" }) catch return null;
        } else if (std.mem.eql(u8, typ, "tool_use")) {
            const input = jv.get(b, "input") orelse std.json.Value{ .object = .empty };
            const input_json = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(input, .{})}) catch return null;
            blocks.append(arena, .{ .tool_use = .{
                .id = jv.str(jv.get(b, "id")) orelse return null,
                .name = jv.str(jv.get(b, "name")) orelse return null,
                .input_json = input_json,
            } }) catch return null;
        }
    }
    return .{
        .blocks = blocks.items,
        .stop_reason = jv.str(jv.get(v, "stop_reason")) orelse "",
        .input_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "input_tokens" })) orelse 0)),
        .output_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "output_tokens" })) orelse 0)),
        .cache_read_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "cache_read_input_tokens" })) orelse 0)),
        .cache_write_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "cache_creation_input_tokens" })) orelse 0)),
    };
}

// ---- tests ----

const t = std.testing;
const fake = @import("fake.zig");

pub const TestEnv = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    server: *fake.Server,

    pub fn init(e: *TestEnv) !void {
        e.tmp = t.tmpDir(.{});
        e.arena = .init(t.allocator);
        e.dir = try e.tmp.dir.realPathFileAlloc(t.io, ".", e.arena.allocator());
        e.server = try fake.Server.start(t.io, e.dir, 0);
    }

    pub fn deinit(e: *TestEnv) void {
        e.server.stop();
        e.arena.deinit();
        e.tmp.cleanup();
    }

    pub fn url(e: *TestEnv) ![]const u8 {
        return std.fmt.allocPrint(e.arena.allocator(), "http://127.0.0.1:{d}", .{e.server.port});
    }

    /// Writes the n-th scripted model answer.
    pub fn script(e: *TestEnv, n: u32, body: []const u8) !void {
        const name = try std.fmt.allocPrint(e.arena.allocator(), "model/{d:0>3}.json", .{n});
        try e.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = body });
    }

    pub fn request(e: *TestEnv, n: u32) ![]u8 {
        const name = try std.fmt.allocPrint(e.arena.allocator(), "requests/{d:0>3}.json", .{n});
        return e.tmp.dir.readFileAlloc(t.io, name, e.arena.allocator(), .unlimited);
    }

    pub fn client(e: *TestEnv) !Client {
        var c = try Client.init(t.allocator, t.io, try e.url(), "og-test-key", "claude-test", 1000);
        c.max_retry_wait = 1;
        return c;
    }

    /// A provider at the fake server: its address with /v1, its key
    /// stored under its own name.
    pub fn provider(e: *TestEnv, name: []const u8, api: Api, auth: Auth, key: []const u8) !Provider {
        const address = try std.fmt.allocPrint(e.arena.allocator(), "http://127.0.0.1:{d}/v1", .{e.server.port});
        return .{ .name = name, .api = api, .url = address, .auth = auth, .cache = api == .anthropic, .key_name = name, .key = key };
    }

    pub fn clientFor(e: *TestEnv, p: Provider, model_name: []const u8) !Client {
        _ = e;
        var c = try Client.open(t.allocator, t.io, p, model_name, 1000);
        c.max_retry_wait = 1;
        return c;
    }
};

pub fn textReply(comptime s: []const u8) []const u8 {
    return "{\"content\":[{\"type\":\"text\",\"text\":\"" ++ s ++ "\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}";
}

pub fn toolReply(comptime id: []const u8, comptime name: []const u8, comptime input: []const u8) []const u8 {
    return "{\"content\":[{\"type\":\"text\",\"text\":\"Let me check.\"},{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":" ++ input ++ "}],\"stop_reason\":\"tool_use\"}";
}

test "text_reply_parsed" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("Hello there."));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "be brief", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{});
    try t.expectEqualStrings("Hello there.", try r.text(a));
    try t.expectEqualStrings("end_turn", r.stop_reason);
    try t.expectEqual(10, r.input_tokens);
}

test "tool_use_reply_parsed_with_input_json" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, toolReply("tu_1", "shell", "{\"command\":\"ls -l\"}"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "", &.{.{ .role = .user, .blocks = &.{.{ .text = "list" }} }}, &.{.{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" }});
    try t.expectEqual(2, r.blocks.len);
    const u = r.blocks[1].tool_use;
    try t.expectEqualStrings("tu_1", u.id);
    try t.expectEqualStrings("shell", u.name);
    try t.expectEqualStrings("{\"command\":\"ls -l\"}", u.input_json);
}

test "request_carries_x_api_key_and_version" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("ok"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    _ = try c.send(a, "sys", &.{
        .{ .role = .user, .blocks = &.{.{ .text = "run it" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_use = .{ .id = "tu_9", .name = "shell", .input_json = "{\"command\":\"date\"}" } }} },
        .{ .role = .user, .blocks = &.{.{ .tool_result = .{ .id = "tu_9", .content = "Thu \"Nov\"", .is_error = false } }} },
    }, &.{.{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" }});
    const req = try e.request(1);
    const v = jv.parse(a, req).?;
    try t.expectEqualStrings("og-test-key", jv.str(jv.at(v, &.{ "headers", "x-api-key" })).?);
    try t.expectEqualStrings("2023-06-01", jv.str(jv.at(v, &.{ "headers", "anthropic-version" })).?);
    try t.expectEqualStrings("claude-test", jv.str(jv.at(v, &.{ "body", "model" })).?);
    try t.expectEqualStrings("sys", jv.str(jv.at(v, &.{ "body", "system" })).?);
    const msgs = jv.arr(jv.at(v, &.{ "body", "messages" })).?;
    try t.expectEqual(3, msgs.len);
    const result = jv.arr(jv.get(msgs[2], "content")).?[0];
    try t.expectEqualStrings("Thu \"Nov\"", jv.str(jv.get(result, "content")).?);
    try t.expectEqualStrings("date", jv.str(jv.at(jv.arr(jv.get(msgs[1], "content")).?[0], &.{ "input", "command" })).?);
}

test "budget_spent_is_not_retried" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":402}");
    try e.script(2, textReply("should not be reached"));
    var c = try e.client();
    defer c.deinit();
    try t.expectError(error.BudgetSpent, c.send(e.arena.allocator(), "", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{}));
    try t.expectEqual(1, e.server.modelRequests());
    try t.expectEqualStrings("scripted error", c.lastError());
}

test "rate_limited_waits_once_then_succeeds" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":429,\"retry_after\":1}");
    try e.script(2, textReply("ok now"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{});
    try t.expectEqualStrings("ok now", try r.text(a));
    try t.expectEqual(2, e.server.modelRequests());
}

test "rate_limited_twice_gives_up" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":429,\"retry_after\":1}");
    try e.script(2, "{\"status\":429,\"retry_after\":1}");
    try e.script(3, textReply("too late"));
    var c = try e.client();
    defer c.deinit();
    try t.expectError(error.RateLimited, c.send(e.arena.allocator(), "", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{}));
    try t.expectEqual(2, e.server.modelRequests());
}

test "no_url_or_no_key_refuses_the_call_without_sending_it" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("should not be reached"));
    const a = e.arena.allocator();
    const msgs: []const Message = &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }};
    // config.ini has no url yet
    var no_url = try Client.init(t.allocator, t.io, "", "og-test-key", "claude-test", 100);
    defer no_url.deinit();
    try t.expectError(error.NoUrl, no_url.send(a, "", msgs, &.{}));
    // no key stored: the request would go out with an empty key
    var no_key = try Client.init(t.allocator, t.io, try e.url(), "", "claude-test", 100);
    defer no_key.deinit();
    try t.expectError(error.NoKey, no_key.send(a, "", msgs, &.{}));
    try t.expectEqual(0, e.server.modelRequests());
}

fn sinceMs(start: Io.Timestamp) i64 {
    return start.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds();
}

const hi: []const Message = &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }};

test "a_timed_out_call_is_not_sent_again" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    // the model may be at work on it: sent again, it may be billed again
    try e.script(1, comptime "{\"delay_ms\":2000," ++ textReply("late")[1..]);
    try e.script(2, textReply("sent twice"));
    var c = try e.client();
    defer c.deinit();
    c.call_ms = 500;
    try t.expectError(error.Timeout, c.send(e.arena.allocator(), "", hi, &.{}));
    try t.expectEqual(1, e.server.modelRequests());
}

test "a_call_ends_by_the_turn_deadline" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, comptime "{\"delay_ms\":5000," ++ textReply("too late")[1..]);
    var c = try e.client();
    defer c.deinit();
    const start = Io.Clock.awake.now(t.io);
    // said as the turn's time running out, not as a failed call: the
    // limit was the deadline, however the clocks round
    try t.expectError(error.TimeUp, c.sendParts(e.arena.allocator(), "", "", hi, &.{}, .{ .deadline_s = util.nowSeconds(t.io) + 1 }));
    try t.expect(sinceMs(start) < 3000);
}

fn stopSoon(flag: *std.atomic.Value(bool)) void {
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    flag.store(true, .release);
}

test "stop_and_the_deadline_end_the_wait_after_a_429" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":429,\"retry_after\":10}");
    try e.script(2, "{\"status\":429,\"retry_after\":10}");
    try e.script(3, textReply("after the wait"));
    var c = try e.client();
    defer c.deinit();
    c.max_retry_wait = 10;
    const a = e.arena.allocator();
    var stop: std.atomic.Value(bool) = .init(false);
    const th = try std.Thread.spawn(.{}, stopSoon, .{&stop});
    var start = Io.Clock.awake.now(t.io);
    const stopped = c.sendParts(a, "", "", hi, &.{}, .{ .stop = &stop });
    th.join();
    try t.expectError(error.Stopped, stopped);
    try t.expect(sinceMs(start) < 3000);
    try t.expectEqual(1, e.server.modelRequests());
    // a wait that would end past the deadline is not begun
    start = Io.Clock.awake.now(t.io);
    try t.expectError(error.RateLimited, c.sendParts(a, "", "", hi, &.{}, .{ .deadline_s = util.nowSeconds(t.io) + 2 }));
    try t.expect(sinceMs(start) < 3000);
    try t.expectEqual(2, e.server.modelRequests());
}

test "cache_marks_on_last_tool_stable_system_and_last_message" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1,\"cache_read_input_tokens\":900,\"cache_creation_input_tokens\":40}}");
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.sendParts(a, "stable part", "changing part", &.{
        .{ .role = .user, .blocks = &.{.{ .text = "first" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "answer" }} },
        .{ .role = .user, .blocks = &.{ .{ .text = "a" }, .{ .text = "last" } } },
    }, &.{
        .{ .name = "one", .description = "1", .schema_json = "{\"type\":\"object\"}" },
        .{ .name = "two", .description = "2", .schema_json = "{\"type\":\"object\"}" },
    }, .{});
    try t.expectEqual(900, r.cache_read_tokens);
    try t.expectEqual(40, r.cache_write_tokens);
    const v = jv.parse(a, try e.request(1)).?;
    const sys = jv.arr(jv.at(v, &.{ "body", "system" })).?;
    try t.expectEqual(2, sys.len);
    try t.expectEqualStrings("stable part", jv.str(jv.get(sys[0], "text")).?);
    try t.expectEqualStrings("ephemeral", jv.str(jv.at(sys[0], &.{ "cache_control", "type" })).?);
    try t.expectEqualStrings("changing part", jv.str(jv.get(sys[1], "text")).?);
    try t.expect(jv.get(sys[1], "cache_control") == null);
    const tl = jv.arr(jv.at(v, &.{ "body", "tools" })).?;
    try t.expect(jv.get(tl[0], "cache_control") == null);
    try t.expect(jv.get(tl[1], "cache_control") != null);
    const msgs = jv.arr(jv.at(v, &.{ "body", "messages" })).?;
    try t.expect(jv.get(jv.arr(jv.get(msgs[0], "content")).?[0], "cache_control") == null);
    const last = jv.arr(jv.get(msgs[2], "content")).?;
    try t.expect(jv.get(last[0], "cache_control") == null);
    try t.expect(jv.get(last[1], "cache_control") != null);
}

test "a_turn_call_marks_its_stable_instructions_for_the_cache" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("ok"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    // what a turn sends: nothing changing in the system prompt
    _ = try c.sendParts(a, "stable part", "", hi, &.{}, .{});
    const v = jv.parse(a, try e.request(1)).?;
    const sys = jv.arr(jv.at(v, &.{ "body", "system" })).?;
    try t.expectEqual(1, sys.len);
    try t.expectEqualStrings("stable part", jv.str(jv.get(sys[0], "text")).?);
    try t.expectEqualStrings("ephemeral", jv.str(jv.at(sys[0], &.{ "cache_control", "type" })).?);
}

test "plain_send_keeps_system_a_string" {
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const body = try requestBody(arena.allocator(), "m", 10, .{ .stable = "sys", .cache = false }, &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{});
    const v = jv.parse(arena.allocator(), body).?;
    try t.expectEqualStrings("sys", jv.str(jv.get(v, "system")).?);
}

fn testKeys(_: ?*anyopaque, _: std.mem.Allocator, provider: []const u8, _: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "openrouter")) return "or-test-key";
    if (std.mem.eql(u8, provider, "local")) return "never-asked";
    return null;
}

test "a_model_value_picks_its_provider_by_its_prefix" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local: Section = .{ .name = "local", .api = .openai, .url = "http://127.0.0.1:11434/v1", .auth = .none };
    const set = try Providers.resolve(a, .{ .sections = &.{local} }, .{ .get = testKeys });
    const cases = [_][3][]const u8{
        .{ "claude-sonnet", "omnigate", "claude-sonnet" },
        .{ "openrouter:deepseek/deepseek-chat", "openrouter", "deepseek/deepseek-chat" },
        .{ "local:llama3.1:8b", "local", "llama3.1:8b" },
        // no provider is called llama3.1: a model of the default one
        .{ "llama3.1:8b", "omnigate", "llama3.1:8b" },
        .{ "openrouter:meta-llama/llama-3.3-70b-instruct:free", "openrouter", "meta-llama/llama-3.3-70b-instruct:free" },
    };
    for (cases) |c| {
        const ch = set.pick(c[0]);
        try t.expectEqualStrings(c[1], ch.provider.name);
        try t.expectEqualStrings(c[2], ch.model);
    }
    const on_local = try Providers.resolve(a, .{ .default = "local", .sections = &.{local} }, no_keys);
    try t.expectEqualStrings("local", on_local.pick("qwen2:7b").provider.name);
    try t.expectEqualStrings("qwen2:7b", on_local.pick("qwen2:7b").model);
    // keys are looked up by provider; one that needs none is never asked
    try t.expectEqualStrings("or-test-key", set.find("openrouter").?.key);
    try t.expect(set.find("openrouter").?.hasKey());
    try t.expectEqualStrings("", set.find("local").?.key);
    try t.expect(set.find("local").?.hasKey());
    try t.expect(!set.find("anthropic").?.hasKey());
    try t.expectEqual(2, (try set.used(a, &.{ "claude-sonnet", "local:x", "claude-haiku" })).len);
}

fn ogKey(_: ?*anyopaque, _: std.mem.Allocator, provider: []const u8, _: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, provider, "omnigate")) "og-test-key" else null;
}

test "provider_presets_resolve_and_old_settings_still_reach_omnigate" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const config = @import("config.zig");
    // a 0.3 config.ini: omnigate's address without a path
    const old = try config.parse(a, try std.fmt.allocPrint(a, "[model]\nurl = {s}\nmodel = claude-sonnet\nkey = omnigate\n", .{try e.url()}));
    const set = try Providers.resolve(a, config.providerSettings(old), .{ .get = ogKey });
    for (1..4) |n| try e.script(@intCast(n), textReply("ok"));
    var c = try set.client(t.allocator, t.io, old.model.model, 1000);
    defer c.deinit();
    _ = try c.sendParts(a, "stable", "", hi, &.{.{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" }}, .{});
    const v = jv.parse(a, try e.request(1)).?;
    try t.expectEqualStrings("/v1/messages", jv.str(jv.get(v, "target")).?);
    try t.expectEqualStrings("og-test-key", jv.str(jv.at(v, &.{ "headers", "x-api-key" })).?);
    try t.expectEqualStrings("2023-06-01", jv.str(jv.at(v, &.{ "headers", "anthropic-version" })).?);
    try t.expect(jv.at(v, &.{ "headers", "Authorization" }) == null);
    try t.expectEqualStrings("claude-sonnet", jv.str(jv.at(v, &.{ "body", "model" })).?);
    // the cache marks as before
    try t.expect(jv.at(v, &.{ "body", "tools", "0", "cache_control" }) != null);
    try t.expect(jv.at(v, &.{ "body", "system", "0", "cache_control" }) != null);
    // an address ending in /v1, or with a path of its own, as 0.3 read it
    for ([_][2][]const u8{ .{ "/v1/", "/v1/messages" }, .{ "/proxy", "/proxy/v1/messages" } }, 2..) |case, n| {
        const s = try config.parse(a, try std.fmt.allocPrint(a, "[model]\nurl = {s}{s}\n", .{ try e.url(), case[0] }));
        const ps = try Providers.resolve(a, config.providerSettings(s), .{ .get = ogKey });
        var pc = try ps.client(t.allocator, t.io, "claude-sonnet", 1000);
        defer pc.deinit();
        _ = try pc.send(a, "", hi, &.{});
        try t.expectEqualStrings(case[1], jv.str(jv.get(jv.parse(a, try e.request(@intCast(n))).?, "target")).?);
    }
    // the presets, as the spec's table has them
    const Want = struct { name: []const u8, api: Api, url: []const u8, auth: Auth, cache: bool, key: []const u8 };
    const want = [_]Want{
        .{ .name = "omnigate", .api = .anthropic, .url = try std.fmt.allocPrint(a, "{s}/v1", .{try e.url()}), .auth = .x_api_key, .cache = true, .key = "omnigate" },
        .{ .name = "anthropic", .api = .anthropic, .url = "https://api.anthropic.com/v1", .auth = .x_api_key, .cache = true, .key = "anthropic" },
        .{ .name = "openrouter", .api = .openai, .url = "https://openrouter.ai/api/v1", .auth = .bearer, .cache = true, .key = "openrouter" },
        .{ .name = "opencode", .api = .openai, .url = "https://opencode.ai/zen/v1", .auth = .bearer, .cache = false, .key = "opencode" },
        .{ .name = "openai", .api = .openai, .url = "https://api.openai.com/v1", .auth = .bearer, .cache = false, .key = "openai" },
    };
    try t.expectEqual(want.len, set.list.len);
    for (want, set.list) |w, p| {
        try t.expectEqualStrings(w.name, p.name);
        try t.expectEqual(w.api, p.api);
        try t.expectEqualStrings(w.url, p.url);
        try t.expectEqual(w.auth, p.auth);
        try t.expectEqual(w.cache, p.cache);
        try t.expectEqualStrings(w.key, p.key_name);
    }
    try t.expectEqualStrings("max_completion_tokens", set.find("openai").?.tokens_field);
    try t.expectEqualStrings("max_tokens", set.find("openrouter").?.tokens_field);
    try t.expectEqualStrings("og-test-key", set.find("omnigate").?.key);
}

test "bearer_and_none_auth_send_the_right_headers" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    for (1..4) |n| try e.script(@intCast(n), textReply("ok"));
    // only the requests are looked at here
    var p = try e.provider("local", .openai, .bearer, "sk-bearer-test-1");
    p.headers = &.{.{ .name = "HTTP-Referer", .value = "https://example.org" }};
    var c1 = try e.clientFor(p, "gpt-test");
    defer c1.deinit();
    _ = c1.send(a, "", hi, &.{}) catch {};
    const r1 = jv.parse(a, try e.request(1)).?;
    try t.expectEqualStrings("/v1/chat/completions", jv.str(jv.get(r1, "target")).?);
    try t.expectEqualStrings("Bearer sk-bearer-test-1", jv.str(jv.at(r1, &.{ "headers", "Authorization" })).?);
    try t.expectEqualStrings("https://example.org", jv.str(jv.at(r1, &.{ "headers", "HTTP-Referer" })).?);
    try t.expect(jv.at(r1, &.{ "headers", "x-api-key" }) == null);
    try t.expect(jv.at(r1, &.{ "headers", "anthropic-version" }) == null);
    // an Anthropic-format gateway that takes a bearer token
    var c2 = try e.clientFor(try e.provider("proxy", .anthropic, .bearer, "sk-bearer-test-2"), "claude-test");
    defer c2.deinit();
    _ = try c2.send(a, "", hi, &.{});
    const r2 = jv.parse(a, try e.request(2)).?;
    try t.expectEqualStrings("/v1/messages", jv.str(jv.get(r2, "target")).?);
    try t.expectEqualStrings("Bearer sk-bearer-test-2", jv.str(jv.at(r2, &.{ "headers", "Authorization" })).?);
    try t.expectEqualStrings("2023-06-01", jv.str(jv.at(r2, &.{ "headers", "anthropic-version" })).?);
    try t.expect(jv.at(r2, &.{ "headers", "x-api-key" }) == null);
    // none: no key needed, none sent
    var c3 = try e.clientFor(try e.provider("ollama", .openai, .none, ""), "llama3.1:8b");
    defer c3.deinit();
    if (c3.send(a, "", hi, &.{})) |_| {} else |err| try t.expect(err != error.NoKey);
    try t.expectEqual(3, e.server.modelRequests());
    const r3 = jv.parse(a, try e.request(3)).?;
    try t.expect(jv.at(r3, &.{ "headers", "Authorization" }) == null);
    try t.expect(jv.at(r3, &.{ "headers", "x-api-key" }) == null);
    // a refused key: the provider and the secret named, the key never said back
    try e.script(4, "{\"status\":401,\"echo_key\":true}");
    try t.expectError(error.KeyRefused, c1.send(a, "", hi, &.{}));
    try t.expectEqual(4, e.server.modelRequests());
    try t.expect(std.mem.indexOf(u8, c1.lastError(), "sk-bearer-test-1") == null);
    try t.expect(std.mem.indexOf(u8, c1.lastError(), "[secret:local]") != null);
    try t.expectEqualStrings("Model calls are refused: local refused the key stored as local (scripted error for key [secret:local]); store the right key with harness secret add local.", try c1.failure(a, error.KeyRefused));
}
