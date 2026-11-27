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
    /// The model's thinking before an answer, as Anthropic sent it: the
    /// whole block's JSON (`thinking` or `redacted_thinking`; its text
    /// may be empty, its signature is what counts). It goes back as it
    /// came, in the same place, and only while what was sent before it is
    /// the same: the API refuses it after any other request (the agent
    /// sends it within its own turn only). Never shown, logged or summed.
    thinking: []const u8,
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
    /// 402: the key's budget or credits at the provider are spent. Never
    /// retried.
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
    /// The provider speaks Gemini's format, which harness uses for speech
    /// only: nothing is sent.
    SpeechOnly,
} || http.Error;

// ---- providers ----

/// The request format a provider speaks.
pub const Api = enum {
    /// Anthropic Messages: POST URL/messages.
    anthropic,
    /// OpenAI Chat Completions: POST URL/chat/completions.
    openai,
    /// Gemini's generateContent: POST URL/models/MODEL:generateContent.
    /// For speech only for now (the desk's voice): a chat call refuses it.
    gemini,
};

/// How a provider takes its key: `x-api-key: KEY`, `x-goog-api-key:
/// KEY` (Gemini's), `Authorization: Bearer KEY`, or not at all.
pub const Auth = enum { x_api_key, x_goog_api_key, bearer, none };

pub fn parseApi(w: []const u8) ?Api {
    if (std.mem.eql(u8, w, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, w, "openai")) return .openai;
    if (std.mem.eql(u8, w, "gemini")) return .gemini;
    return null;
}

/// The header a key goes in, for the ways that send it in one of its
/// own; null for a bearer token or none.
pub fn keyHeader(auth: Auth) ?[]const u8 {
    return switch (auth) {
        .x_api_key => "x-api-key",
        .x_goog_api_key => "x-goog-api-key",
        .bearer, .none => null,
    };
}

/// How a new `[provider NAME]` of this format takes its key unless it says.
pub fn defaultAuth(api: Api) Auth {
    return switch (api) {
        .anthropic => .x_api_key,
        .openai => .bearer,
        .gemini => .x_goog_api_key,
    };
}

pub fn parseAuth(w: []const u8) ?Auth {
    if (std.mem.eql(u8, w, "x-api-key")) return .x_api_key;
    if (std.mem.eql(u8, w, "x-goog-api-key")) return .x_goog_api_key;
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
    // the Gemini API, for the desk's voice only for now
    .{ .name = "gemini", .api = .gemini, .url = "https://generativelanguage.googleapis.com/v1beta", .auth = .x_goog_api_key, .cache = false, .key = "gemini" },
};

pub fn isPreset(name: []const u8) bool {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

/// A preset a model can be called on (gemini's is for speech only).
pub fn chatPreset(name: []const u8) bool {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return p.api != .gemini;
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
            .gemini => "Gemini, speech only",
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
            var p: Provider = .{ .name = sec.name, .api = api, .url = "", .auth = defaultAuth(api), .cache = api == .anthropic, .key_name = sec.name };
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

    /// The providers `values` pick, as /status says them: "omnigate
    /// (Anthropic Messages, key stored); local (OpenAI Chat Completions,
    /// no key needed)".
    pub fn describe(p: *const Providers, arena: std.mem.Allocator, values: []const []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (try p.used(arena, values), 0..) |prov, i| {
            if (i > 0) try out.appendSlice(arena, "; ");
            try out.print(arena, "{s} ({s}, ", .{ prov.name, prov.apiName() });
            if (prov.auth == .none) {
                try out.appendSlice(arena, "no key needed");
            } else if (prov.key.len > 0) {
                try out.appendSlice(arena, "key stored");
            } else try out.print(arena, "key not stored: harness secret add {s}", .{prov.key_name});
            if (prov.url.len == 0) try out.appendSlice(arena, ", no url set");
            try out.append(arena, ')');
        }
        return out.items;
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
    /// The status of the last answer (0: none came).
    last_status: u16 = 0,
    /// The setting that names this client's model with its provider, when
    /// it is not one of `[model] model` and its like: what `failure` says
    /// to change when the provider has no such model.
    named_by: []const u8 = "",
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
                // never sent: a chat call on it is refused (SpeechOnly)
                .gemini => "/models",
            },
            .tokens_field = p.tokens_field,
        };
    }

    /// The path of an address http.Target.parse took, as written,
    /// without a trailing `/` ("" for none).
    pub fn urlPath(url: []const u8) []const u8 {
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
            error.SpeechOnly => try std.fmt.allocPrint(a, "Model calls are refused: {s} has api = gemini, which harness uses for speech only for now; use a provider with api = anthropic or openai for this model.", .{c.provider}),
            error.TimeUp => "Time limit reached for this turn.",
            error.Timeout => try std.fmt.allocPrint(a, "Model call failed{s}: Timeout {s}", .{ at, msg }),
            error.Rejected => try std.fmt.allocPrint(a, "The model API{s} refused the request: {s}", .{ at, msg }),
            // a 404 from a provider of one's own: nearly always a model
            // name it doesn't have (config.ini's defaults are omnigate's
            // route names), so say what to change
            error.Upstream => if (!omni and c.last_status == 404 and c.named_by.len > 0)
                try std.fmt.allocPrint(a, "Model call failed{s}: {s} has no model named {s} (404{s}{s}). Name one it has: harness config set {s} {s}:NAME, then /reload.", .{
                    at, c.provider, c.model, if (msg.len > 0) ": " else "", msg, c.named_by, c.provider,
                })
            else if (!omni and c.last_status == 404)
                try std.fmt.allocPrint(a, "Model call failed{s}: {s} has no model named {s} (404{s}{s}). Name one it has: harness config set model.model NAME (model.memory_model and model.worker_model the same way), then /reload.", .{
                    at, c.provider, c.model, if (msg.len > 0) ": " else "", msg,
                })
            else
                try std.fmt.allocPrint(a, "Model call failed{s}: {s} {s}", .{ at, @errorName(e), msg }),
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
        if (c.api == .gemini) return error.SpeechOnly;
        if (c.http == null) return error.NoUrl;
        if (c.auth != .none and c.key.len == 0) return error.NoKey;
        const body = switch (c.api) {
            .anthropic => try anthropicBody(arena, c.model, c.max_tokens, system, messages, tools, c.cache),
            .openai => try openaiBody(arena, c.model, c.tokens_field, c.max_tokens, system, messages, tools, c.cache),
            .gemini => unreachable,
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
            c.last_status = r.status;
            switch (r.status) {
                200 => return switch (c.api) {
                    .anthropic => parseReply(arena, r.body),
                    .openai => parseOpenAIReply(arena, r.body),
                    .gemini => unreachable,
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
        if (keyHeader(c.auth)) |name| {
            hs[n] = .{ .name = name, .value = c.key };
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
                // as it came: a cache mark is not allowed on it
                .thinking => |raw| try out.appendSlice(arena, raw),
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

/// An OpenAI Chat Completions request. The system prompt is one message,
/// its stable part first; with `marks` that part carries OpenRouter's
/// `cache_control` (passed on to Anthropic's models). A tool result has
/// no error flag in this format: its text says what failed.
pub fn openaiBody(arena: std.mem.Allocator, model: []const u8, tokens_field: []const u8, max_tokens: u32, system: System, messages: []const Message, tools: []const ToolDef, marks: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"model\":");
    try util.jsonString(&out, arena, model);
    try out.print(arena, ",\"{s}\":{d},\"messages\":[", .{ tokens_field, max_tokens });
    var first = true;
    if (system.stable.len > 0 or system.changing.len > 0) {
        first = false;
        try out.appendSlice(arena, "{\"role\":\"system\",\"content\":");
        if (marks and system.cache and system.stable.len > 0) {
            try out.appendSlice(arena, "[{\"type\":\"text\",\"text\":");
            try util.jsonString(&out, arena, system.stable);
            try out.appendSlice(arena, cache_mark);
            try out.append(arena, '}');
            if (system.changing.len > 0) {
                try out.appendSlice(arena, ",{\"type\":\"text\",\"text\":");
                try util.jsonString(&out, arena, system.changing);
                try out.append(arena, '}');
            }
            try out.append(arena, ']');
        } else if (system.stable.len > 0 and system.changing.len > 0) {
            try util.jsonString(&out, arena, try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ system.stable, system.changing }));
        } else {
            try util.jsonString(&out, arena, if (system.stable.len > 0) system.stable else system.changing);
        }
        try out.append(arena, '}');
    }
    for (messages) |m| {
        const text = try joinText(arena, m.blocks);
        switch (m.role) {
            .user => {
                // the results answer the calls just before them: first
                for (m.blocks) |b| if (b == .tool_result) {
                    if (!first) try out.append(arena, ',');
                    first = false;
                    try out.appendSlice(arena, "{\"role\":\"tool\",\"tool_call_id\":");
                    try util.jsonString(&out, arena, b.tool_result.id);
                    try out.appendSlice(arena, ",\"content\":");
                    try util.jsonString(&out, arena, b.tool_result.content);
                    try out.append(arena, '}');
                };
                if (text) |tx| {
                    if (!first) try out.append(arena, ',');
                    first = false;
                    try out.appendSlice(arena, "{\"role\":\"user\",\"content\":");
                    try util.jsonString(&out, arena, tx);
                    try out.append(arena, '}');
                }
            },
            .assistant => {
                if (!first) try out.append(arena, ',');
                first = false;
                var calls: usize = 0;
                for (m.blocks) |b| if (b == .tool_use) {
                    calls += 1;
                };
                try out.appendSlice(arena, "{\"role\":\"assistant\",\"content\":");
                if (text) |tx| {
                    try util.jsonString(&out, arena, tx);
                } else try out.appendSlice(arena, if (calls > 0) "null" else "\"\"");
                if (calls > 0) {
                    try out.appendSlice(arena, ",\"tool_calls\":[");
                    var i: usize = 0;
                    for (m.blocks) |b| if (b == .tool_use) {
                        if (i > 0) try out.append(arena, ',');
                        i += 1;
                        try out.appendSlice(arena, "{\"id\":");
                        try util.jsonString(&out, arena, b.tool_use.id);
                        try out.appendSlice(arena, ",\"type\":\"function\",\"function\":{\"name\":");
                        try util.jsonString(&out, arena, b.tool_use.name);
                        try out.appendSlice(arena, ",\"arguments\":");
                        try util.jsonString(&out, arena, if (b.tool_use.input_json.len > 0) b.tool_use.input_json else "{}");
                        try out.appendSlice(arena, "}}");
                    };
                    try out.append(arena, ']');
                }
                try out.append(arena, '}');
            },
        }
    }
    try out.append(arena, ']');
    if (tools.len > 0) {
        try out.appendSlice(arena, ",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, "{\"type\":\"function\",\"function\":{\"name\":");
            try util.jsonString(&out, arena, td.name);
            try out.appendSlice(arena, ",\"description\":");
            try util.jsonString(&out, arena, td.description);
            try out.print(arena, ",\"parameters\":{s}}}}}", .{td.schema_json});
        }
        try out.append(arena, ']');
    }
    try out.append(arena, '}');
    return out.items;
}

/// A message's text blocks as one text; null when it has none.
fn joinText(arena: std.mem.Allocator, blocks: []const Block) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    for (blocks) |b| if (b == .text) {
        if (any) try out.appendSlice(arena, "\n\n");
        any = true;
        try out.appendSlice(arena, b.text);
    };
    return if (any) out.items else null;
}

/// An OpenAI Chat Completions answer: its first choice's text and tool
/// calls. Null when it is not one, or when a call's arguments are not a
/// JSON object, so the call is not run (`""` reads as `{}`, as local
/// servers send it; a call without an id gets one).
pub fn parseOpenAIReply(arena: std.mem.Allocator, body: []const u8) ?Reply {
    const v = jv.parse(arena, body) orelse return null;
    const choices = jv.arr(jv.get(v, "choices")) orelse return null;
    if (choices.len == 0) return null;
    const msg = jv.get(choices[0], "message") orelse return null;
    if (msg != .object) return null;
    var blocks: std.ArrayList(Block) = .empty;
    if (jv.get(msg, "content")) |content| switch (content) {
        .string => |text| if (text.len > 0) blocks.append(arena, .{ .text = text }) catch return null,
        .array => |parts| for (parts.items) |part| {
            const text = jv.str(jv.get(part, "text")) orelse continue;
            if (text.len > 0) blocks.append(arena, .{ .text = text }) catch return null;
        },
        else => {},
    };
    if (jv.arr(jv.get(msg, "tool_calls"))) |calls| for (calls, 0..) |call, i| {
        const f = jv.get(call, "function") orelse return null;
        const name = jv.str(jv.get(f, "name")) orelse return null;
        const input_json: []const u8 = if (jv.get(f, "arguments")) |args| switch (args) {
            .string => |raw| blk: {
                const text = std.mem.trim(u8, raw, " \t\r\n");
                if (text.len == 0) break :blk "{}";
                const parsed = jv.parse(arena, text) orelse return null;
                if (parsed != .object) return null;
                break :blk text;
            },
            .object => std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(args, .{})}) catch return null,
            else => return null,
        } else "{}";
        const given = jv.str(jv.get(call, "id")) orelse "";
        const id = if (given.len > 0) given else std.fmt.allocPrint(arena, "call_{x}", .{std.hash.Wyhash.hash(@intCast(i), body)}) catch return null;
        blocks.append(arena, .{ .tool_use = .{ .id = id, .name = name, .input_json = input_json } }) catch return null;
    };
    // prompt_tokens counts the cached ones too: input is what was not
    const prompt: u64 = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "prompt_tokens" })) orelse 0));
    const cached: u64 = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "prompt_tokens_details", "cached_tokens" })) orelse 0));
    return .{
        .blocks = blocks.items,
        .stop_reason = stopReason(jv.str(jv.get(choices[0], "finish_reason")) orelse ""),
        .input_tokens = prompt -| cached,
        .output_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "completion_tokens" })) orelse 0)),
        .cache_read_tokens = cached,
    };
}

/// OpenAI's finish reasons in the words the turn reads (Anthropic's).
fn stopReason(finish: []const u8) []const u8 {
    if (std.mem.eql(u8, finish, "stop")) return "end_turn";
    if (std.mem.eql(u8, finish, "length")) return "max_tokens";
    if (std.mem.eql(u8, finish, "tool_calls") or std.mem.eql(u8, finish, "function_call")) return "tool_use";
    return finish;
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
        } else if (std.mem.eql(u8, typ, "thinking") or std.mem.eql(u8, typ, "redacted_thinking")) {
            // every field, the ones this code does not know too
            const raw = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(b, .{})}) catch return null;
            blocks.append(arena, .{ .thinking = raw }) catch return null;
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

/// An OpenAI-format text answer.
pub fn oaTextReply(comptime s: []const u8) []const u8 {
    return "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"" ++ s ++ "\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}";
}

/// An OpenAI-format answer that says "Let me check." and calls `name`.
pub fn oaToolReply(a: std.mem.Allocator, id: []const u8, name: []const u8, input_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":\"Let me check.\",\"tool_calls\":[{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{f}}}}}]}},\"finish_reason\":\"tool_calls\"}}]}}", .{ id, name, std.json.fmt(input_json, .{}) });
}

/// An answer that thinks first (a block signed `sig`, its text left out as
/// the API sends it), then says "Let me check." and calls `name`.
pub fn thinkingToolReply(comptime sig: []const u8, comptime id: []const u8, comptime name: []const u8, comptime input: []const u8) []const u8 {
    return "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"" ++ sig ++ "\"}," ++ comptime toolReply(id, name, input)["{\"content\":[".len..];
}

/// An answer that thinks first (a block signed `sig`), then says `s`.
pub fn thinkingTextReply(comptime sig: []const u8, comptime s: []const u8) []const u8 {
    return "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"" ++ sig ++ "\"}," ++ comptime textReply(s)["{\"content\":[".len..];
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

test "a_replys_thinking_blocks_are_kept_as_they_came" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig-one\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque-two\"},{\"type\":\"text\",\"text\":\"Let me check.\"},{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"shell\",\"input\":{}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}");
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "", &.{.{ .role = .user, .blocks = &.{.{ .text = "list" }} }}, &.{.{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" }});
    try t.expectEqual(4, r.blocks.len);
    // every field as it was sent, an empty text and the signature too
    try t.expectEqualStrings("{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig-one\"}", r.blocks[0].thinking);
    try t.expectEqualStrings("{\"type\":\"redacted_thinking\",\"data\":\"opaque-two\"}", r.blocks[1].thinking);
    // the answer's words are its text blocks alone
    try t.expectEqualStrings("Let me check.", try r.text(a));
    try t.expectEqualStrings("tu_1", r.blocks[3].tool_use.id);
}

const thought_messages: []const Message = &.{
    .{ .role = .user, .blocks = &.{.{ .text = "run it" }} },
    .{ .role = .assistant, .blocks = &.{
        .{ .thinking = "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig-one\"}" },
        .{ .text = "Let me check." },
        .{ .tool_use = .{ .id = "tu_9", .name = "shell", .input_json = "{\"command\":\"date\"}" } },
    } },
    .{ .role = .user, .blocks = &.{.{ .tool_result = .{ .id = "tu_9", .content = "Thu", .is_error = false } }} },
};

test "thinking_blocks_go_back_to_anthropic_as_they_came" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try anthropicBody(a, "claude-test", 1000, .{ .stable = "sys" }, thought_messages, &.{}, true);
    // in its place, before the text and the call it led to, with no cache mark of its own
    try t.expect(std.mem.indexOf(u8, body, "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig-one\"},{\"type\":\"text\",\"text\":\"Let me check.\"},{\"type\":\"tool_use\"") != null);
    try t.expect(jv.parse(a, body) != null);
}

test "thinking_blocks_are_left_out_of_an_openai_request" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try openaiBody(a, "gpt-test", "max_tokens", 1000, .{ .stable = "sys" }, thought_messages, &.{}, false);
    try t.expect(std.mem.indexOf(u8, body, "sig-one") == null);
    try t.expect(std.mem.indexOf(u8, body, "thinking") == null);
    try t.expect(std.mem.indexOf(u8, body, "\"content\":\"Let me check.\"") != null);
    try t.expect(jv.parse(a, body) != null);
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
        // the desk's voice (speech only)
        .{ .name = "gemini", .api = .gemini, .url = "https://generativelanguage.googleapis.com/v1beta", .auth = .x_goog_api_key, .cache = false, .key = "gemini" },
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

test "openai_requests_carry_system_messages_tools_and_tool_results" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs: []const Message = &.{
        .{ .role = .user, .blocks = &.{ .{ .text = "context" }, .{ .text = "list two files" } } },
        .{ .role = .assistant, .blocks = &.{
            .{ .text = "Checking." },
            .{ .tool_use = .{ .id = "tu_1", .name = "shell", .input_json = "{\"command\":\"ls a\"}" } },
            .{ .tool_use = .{ .id = "tu_2", .name = "read_file", .input_json = "{\"path\":\"b.txt\"}" } },
        } },
        .{ .role = .user, .blocks = &.{
            .{ .tool_result = .{ .id = "tu_1", .content = "a.txt" } },
            .{ .tool_result = .{ .id = "tu_2", .content = "no such file", .is_error = true } },
        } },
    };
    const tools: []const ToolDef = &.{
        .{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" },
        .{ .name = "read_file", .description = "read", .schema_json = "{\"type\":\"object\"}" },
    };
    const golden =
        \\{"model":"gpt-test","max_tokens":1000,"messages":[{"role":"system","content":"sys stable"},{"role":"user","content":"context\n\nlist two files"},{"role":"assistant","content":"Checking.","tool_calls":[{"id":"tu_1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls a\"}"}},{"id":"tu_2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"b.txt\"}"}}]},{"role":"tool","tool_call_id":"tu_1","content":"a.txt"},{"role":"tool","tool_call_id":"tu_2","content":"no such file"}],"tools":[{"type":"function","function":{"name":"shell","description":"run","parameters":{"type":"object"}}},{"type":"function","function":{"name":"read_file","description":"read","parameters":{"type":"object"}}}]}
    ;
    try t.expectEqualStrings(golden, try openaiBody(a, "gpt-test", "max_tokens", 1000, .{ .stable = "sys stable" }, msgs, tools, false));
    // with cache marks (OpenRouter): the stable part of the system prompt marked
    const marked = try openaiBody(a, "gpt-test", "max_tokens", 1000, .{ .stable = "sys stable" }, msgs[0..1], &.{}, true);
    try t.expect(std.mem.indexOf(u8, marked, "\"messages\":[{\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"sys stable\",\"cache_control\":{\"type\":\"ephemeral\"}}]}") != null);
    // OpenAI's own field for the answer's length; a one-off call's system unmarked
    const own = try openaiBody(a, "gpt-5", "max_completion_tokens", 1000, .{ .stable = "sys", .cache = false }, msgs[0..1], &.{}, true);
    try t.expect(std.mem.startsWith(u8, own, "{\"model\":\"gpt-5\",\"max_completion_tokens\":1000,\"messages\":[{\"role\":\"system\",\"content\":\"sys\"}"));
    // calls without text; their results, then the next message's text
    const next = try openaiBody(a, "m", "max_tokens", 10, .{ .stable = "" }, &.{
        .{ .role = .user, .blocks = &.{.{ .text = "go" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_use = .{ .id = "tu_3", .name = "shell", .input_json = "" } }} },
        .{ .role = .user, .blocks = &.{ .{ .tool_result = .{ .id = "tu_3", .content = "done" } }, .{ .text = "next" } } },
    }, &.{}, false);
    try t.expectEqualStrings(
        \\{"model":"m","max_tokens":10,"messages":[{"role":"user","content":"go"},{"role":"assistant","content":null,"tool_calls":[{"id":"tu_3","type":"function","function":{"name":"shell","arguments":"{}"}}]},{"role":"tool","tool_call_id":"tu_3","content":"done"},{"role":"user","content":"next"}]}
    , next);
}

test "openai_replies_become_text_and_tool_uses" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    try e.script(1, try oaToolReply(a, "call_1", "shell", "{\"command\":\"ls -l\"}"));
    try e.script(2, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"cut he\"},\"finish_reason\":\"length\"}]}");
    try e.script(3, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    var c = try e.clientFor(try e.provider("local", .openai, .bearer, "sk-local-test-1"), "gpt-test");
    defer c.deinit();
    const r = try c.send(a, "", hi, &.{});
    try t.expectEqual(2, r.blocks.len);
    try t.expectEqualStrings("Let me check.", r.blocks[0].text);
    try t.expectEqualStrings("call_1", r.blocks[1].tool_use.id);
    try t.expectEqualStrings("shell", r.blocks[1].tool_use.name);
    try t.expectEqualStrings("{\"command\":\"ls -l\"}", r.blocks[1].tool_use.input_json);
    try t.expectEqualStrings("tool_use", r.stop_reason);
    const cut = try c.send(a, "", hi, &.{});
    try t.expectEqualStrings("max_tokens", cut.stop_reason);
    try t.expectEqualStrings("cut he", try cut.text(a));
    // arguments that are not JSON: a bad reply, so the call is not run
    try t.expectError(error.BadReply, c.send(a, "", hi, &.{}));
    // what local servers send: text parts, no ids, arguments "" or an object
    const lax = parseOpenAIReply(a,
        \\{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}],"tool_calls":[
        \\{"type":"function","function":{"name":"recall","arguments":""}},
        \\{"id":"","type":"function","function":{"name":"shell","arguments":{"command":"ls"}}}]},"finish_reason":"stop"}],
        \\"usage":{"prompt_tokens":100,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":60}}}
    ).?;
    try t.expectEqual(4, lax.blocks.len);
    try t.expectEqualStrings("a", lax.blocks[0].text);
    try t.expectEqualStrings("b", lax.blocks[1].text);
    try t.expectEqualStrings("{}", lax.blocks[2].tool_use.input_json);
    try t.expectEqualStrings("{\"command\":\"ls\"}", lax.blocks[3].tool_use.input_json);
    try t.expect(std.mem.startsWith(u8, lax.blocks[2].tool_use.id, "call_"));
    try t.expect(std.mem.startsWith(u8, lax.blocks[3].tool_use.id, "call_"));
    try t.expect(!std.mem.eql(u8, lax.blocks[2].tool_use.id, lax.blocks[3].tool_use.id));
    try t.expectEqualStrings("end_turn", lax.stop_reason);
    // input as the log counts it: what was not read from the cache
    try t.expectEqual(40, lax.input_tokens);
    try t.expectEqual(7, lax.output_tokens);
    try t.expectEqual(60, lax.cache_read_tokens);
    try t.expect(parseOpenAIReply(a, "{\"choices\":[]}") == null);
    try t.expect(parseOpenAIReply(a, "{\"choices\":[{\"message\":{\"tool_calls\":[{\"function\":{\"name\":\"x\",\"arguments\":\"[1]\"}}]}}]}") == null);
}

test "each_status_maps_to_the_same_message_for_every_provider" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var og = try e.client();
    defer og.deinit();
    var local = try e.clientFor(try e.provider("local", .openai, .bearer, "sk-local-test-1"), "gpt-test");
    defer local.deinit();
    const Case = struct { script: []const u8, err: anyerror, said: []const u8, requests: u32 = 1 };
    const cases = [_]Case{
        .{ .script = "{\"status\":401}", .err = error.KeyRefused, .said = "Model calls are refused: omnigate refused the key stored as omnigate (scripted error); store the right key with harness secret add omnigate." },
        .{ .script = "{\"status\":402}", .err = error.BudgetSpent, .said = "Model budget used up." },
        .{ .script = "{\"status\":429,\"retry_after\":1}", .err = error.RateLimited, .said = "The model is rate limited; try again later.", .requests = 2 },
        .{ .script = "{\"status\":400}", .err = error.Rejected, .said = "The model API refused the request: scripted error" },
        .{ .script = "{\"status\":500}", .err = error.Upstream, .said = "Model call failed: Upstream scripted error" },
    };
    var n: u32 = 0;
    for (cases) |cs| {
        for ([_]*Client{ &og, &local }) |c| {
            for (0..cs.requests) |_| {
                n += 1;
                try e.script(n, cs.script);
            }
            const before = e.server.modelRequests();
            try t.expectError(cs.err, c.send(a, "", hi, &.{}));
            // 429: waited as told, asked once more
            try t.expectEqual(before + cs.requests, e.server.modelRequests());
            const said = try c.failure(a, cs.err);
            // omnigate's words are 0.3's; another provider's the same, naming it
            if (c == &og) {
                try t.expectEqualStrings(cs.said, said);
            } else {
                try t.expect(std.mem.indexOf(u8, said, "local") != null);
                const as_omnigate = if (cs.err == error.KeyRefused)
                    try std.mem.replaceOwned(u8, a, said, "local", "omnigate")
                else
                    try std.mem.replaceOwned(u8, a, said, " at local", "");
                try t.expectEqualStrings(cs.said, as_omnigate);
            }
        }
    }
    // a 404 from one's own provider says what to change; omnigate's words stay
    for ([_]*Client{ &og, &local }) |c| {
        n += 1;
        try e.script(n, "{\"status\":404}");
        try t.expectError(error.Upstream, c.send(a, "", hi, &.{}));
        try t.expectEqualStrings(if (c == &og)
            "Model call failed: Upstream scripted error"
        else
            "Model call failed at local: local has no model named gpt-test (404: scripted error). Name one it has: harness config set model.model NAME (model.memory_model and model.worker_model the same way), then /reload.", try c.failure(a, error.Upstream));
    }
    // and a 500 after it is an upstream error again
    n += 1;
    try e.script(n, "{\"status\":500}");
    try t.expectError(error.Upstream, local.send(a, "", hi, &.{}));
    try t.expectEqualStrings("Model call failed at local: Upstream scripted error", try local.failure(a, error.Upstream));
}

test "gemini_is_a_preset_for_speech_only" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const tts: Section = .{ .name = "tts", .api = .gemini, .url = try std.fmt.allocPrint(a, "{s}/v1beta", .{try e.url()}) };
    const set = try Providers.resolve(a, .{ .sections = &.{tts} }, .{ .get = geminiKeys });
    const g = set.find("gemini").?;
    try t.expectEqual(Api.gemini, g.api);
    try t.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta", g.url);
    try t.expectEqual(Auth.x_goog_api_key, g.auth);
    try t.expectEqualStrings("gemini", g.key_name);
    try t.expect(!g.cache);
    try t.expectEqualStrings("Gemini, speech only", g.apiName());
    // a section of its own takes Gemini's key header and its own name's key
    const s = set.find("tts").?;
    try t.expectEqual(Auth.x_goog_api_key, s.auth);
    try t.expectEqualStrings("tts", s.key_name);
    try t.expectEqualStrings("gm-test-key-1", s.key);
    try t.expect(!isPreset("tts") and isPreset("gemini"));
    try t.expect(chatPreset("openai") and !chatPreset("gemini") and !chatPreset("tts"));
    // a chat call on it: refused before anything is sent, in plain words
    var c = try e.clientFor(s.*, "gemini-3.8-flash-lite-tts");
    defer c.deinit();
    try t.expectError(error.SpeechOnly, c.send(a, "sys", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{}));
    try t.expectEqual(0, e.server.modelRequests());
    try t.expectEqualStrings("Model calls are refused: tts has api = gemini, which harness uses for speech only for now; use a provider with api = anthropic or openai for this model.", try c.failure(a, error.SpeechOnly));
}

fn geminiKeys(_: ?*anyopaque, _: std.mem.Allocator, provider: []const u8, _: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, provider, "tts")) "gm-test-key-1" else null;
}

test "key_headers_follow_auth" {
    try t.expectEqualStrings("x-api-key", keyHeader(.x_api_key).?);
    try t.expectEqualStrings("x-goog-api-key", keyHeader(.x_goog_api_key).?);
    try t.expect(keyHeader(.bearer) == null);
    try t.expect(keyHeader(.none) == null);
    try t.expectEqual(Auth.x_goog_api_key, parseAuth("x-goog-api-key").?);
    try t.expectEqual(Api.gemini, parseApi("gemini").?);
    try t.expectEqual(Auth.x_api_key, defaultAuth(.anthropic));
    try t.expectEqual(Auth.bearer, defaultAuth(.openai));
    try t.expectEqual(Auth.x_goog_api_key, defaultAuth(.gemini));
}
