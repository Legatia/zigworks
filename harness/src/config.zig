//! The instance's settings: config.ini (models and providers, chat,
//! limits, memory), briefs.ini (topics and their sources) and tasks.ini
//! (scheduled instructions). All three are small INI files: `[section]`,
//! `key = value`, comments after `;` or `#`.
const std = @import("std");
const conversations = @import("conversations.zig");
const agents = @import("agents.zig");
const model = @import("model.zig");
const mcp = @import("mcp.zig");

pub const Error = error{ BadConfig, OutOfMemory };

/// What `parse` refuses besides a bad line: the `[provider NAME]`
/// sections' problems, which `reason` says.
pub const ParseError = Error || error{ BadProvider, BadHeader, ProviderNeedsApiAndUrl, UnknownProvider };

pub const Config = struct {
    model: Model = .{},
    search: Search = .{},
    chat: Chat = .{},
    limits: Limits = .{},
    memory: Memory = .{},
    agents: Agents = .{},
    browser: Browser = .{},
    money: Money = .{},
    apps: Apps = .{},
    inbox: Inbox = .{},
    /// The `[provider NAME]` sections, in the order their names first
    /// appear (not a section of its own: `parse` reads them apart).
    providers: []const model.Section = &.{},

    pub const Model = struct {
        /// The provider of a model value that names none: a preset or a
        /// `[provider NAME]` section.
        provider: []const u8 = "omnigate",
        /// omnigate's address; empty until the owner sets it (no default,
        /// so the key never goes to whatever happens to listen there).
        url: []const u8 = "",
        model: []const u8 = "claude-sonnet",
        memory_model: []const u8 = "claude-haiku",
        /// Route for helpers started with `delegate`.
        worker_model: []const u8 = "claude-haiku",
        key: []const u8 = "omnigate",
        max_tokens: u32 = 4096,
    };
    pub const Search = struct {
        url: []const u8 = "https://api.search.brave.com",
        key: []const u8 = "search",
    };
    pub const Chat = struct {
        telegram: bool = true,
        token: []const u8 = "telegram",
        api: []const u8 = "https://api.telegram.org",
        /// Minutes east of UTC.
        utc_offset: i32 = 0,
    };
    pub const Limits = struct {
        steps_per_turn: u32 = 20,
        turn_seconds: u32 = 600,
        tool_output_bytes: u32 = 16384,
        conversation_bytes: u32 = 200000,
        concurrent_runs: u32 = 2,
        approval_seconds: u32 = 600,
        /// Posts one run may make with `send`; the next is refused.
        sends_per_run: u32 = 10,
        /// Posts to one conversation in an hour, all runs and replies
        /// counted; past it they are logged, not sent.
        sends_per_hour: u32 = 60,
        /// Snapshots of folders, all together, at most (MiB).
        snapshot_mb: u32 = 5120,
    };
    pub const Memory = struct {
        auto: bool = true,
        top_size: u32 = 20,
    };
    /// Helpers started with `delegate`.
    pub const Agents = struct {
        /// Most helpers running at once, in the whole process.
        parallel: u32 = 4,
        steps: u32 = 12,
        /// Input tokens one helper may use, summed over its calls.
        tokens: u32 = 150000,
        answer_bytes: u32 = 4000,
    };
    pub const Browser = struct {
        /// Chrome or Chromium; empty: look in the usual places.
        path: []const u8 = "",
        seconds: u32 = 30,
    };
    /// For MCP tools listed under `money =` in mcp.ini. Caps are in the
    /// units of the tool's amount field; 0 means no cap.
    pub const Money = struct {
        max_per_call: u32 = 0,
        max_per_day: u32 = 0,
        /// Money calls in scheduled runs, without asking, inside the caps.
        scheduled: bool = false,
    };
    /// The app server (gap 8): apps shown in your browser.
    pub const Apps = struct {
        /// Off until the apps' API is in: before it, apps read nothing.
        on: bool = false,
        /// 0: a free one each start; a fixed one to reach it over ssh -L.
        port: u32 = 0,
    };
    /// What waits for the owner (state/inbox).
    pub const Inbox = struct {
        /// Questions and approvals of runs open at once; one more waits
        /// for a place until its turn ends.
        questions: u32 = 20,
        /// Minutes after midnight (owner's time) of the daily reminder of
        /// items open over 12 hours; null: off.
        remind: ?u16 = 9 * 60,
    };
};

/// One `key = value` line, with the section it is in.
pub const Line = struct { section: []const u8, key: []const u8, value: []const u8, n: usize };

/// Splits INI text into its lines; section headers become the `section` of
/// what follows. Lines that are neither are an error.
pub fn lines(arena: std.mem.Allocator, text: []const u8) Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.BadConfig;
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (section.len == 0) return error.BadConfig;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadConfig;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.BadConfig;
        try out.append(arena, .{ .section = section, .key = key, .value = std.mem.trim(u8, line[eq + 1 ..], " \t"), .n = n });
    }
    return out.items;
}

/// A comment starts at `;` or `#` at the start of a line or after a space,
/// so URLs with `#` fragments and values like `a;b` survive.
pub fn stripComment(raw: []const u8) []const u8 {
    for (raw, 0..) |c, i| {
        if ((c == ';' or c == '#') and (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) return raw[0..i];
    }
    return raw;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Config {
    var cfg: Config = .{};
    var provs: std.ArrayList(ProviderLines) = .empty;
    for (try lines(arena, text)) |l| {
        if (providerSection(l.section)) |name| {
            try providerLine(arena, &provs, name, l);
            continue;
        }
        var found = false;
        inline for (@typeInfo(Config).@"struct".field_names) |sname| {
            if (comptime !std.mem.eql(u8, sname, "providers")) {
                if (std.mem.eql(u8, l.section, sname)) {
                    found = true;
                    try setField(&@field(cfg, sname), l);
                }
            }
        }
        if (!found) return error.BadConfig;
    }
    if (cfg.inbox.questions == 0) return error.BadConfig;
    cfg.providers = try providerSections(arena, text, provs.items);
    if (!model.isPreset(cfg.model.provider)) {
        for (cfg.providers) |p| {
            if (std.mem.eql(u8, p.name, cfg.model.provider)) break;
        } else return error.UnknownProvider;
    }
    return cfg;
}

/// What the providers are made from (`model.Providers.resolve`).
pub fn providerSettings(cfg: Config) model.Settings {
    return .{ .default = cfg.model.provider, .omnigate_url = cfg.model.url, .omnigate_key = cfg.model.key, .sections = cfg.providers };
}

/// What config.ini's errors beyond a bad line mean.
pub fn reason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.BadProvider => "a [provider NAME] section takes api = anthropic or openai, url = http(s)://..., auth = x-api-key, bearer or none, key = a stored secret's name, cache = on or off, and header = Name: value; NAME uses a-z, 0-9, - and _",
        error.BadHeader => "header = Name: value, at most 8 a provider; not Authorization or x-api-key (the key is the stored secret key = names), nor Host, Connection, Content-Length, Content-Type, Transfer-Encoding or anthropic-version",
        error.ProviderNeedsApiAndUrl => "a provider that is not a preset needs api = (anthropic or openai) and url =",
        error.UnknownProvider => "no provider has that name: use a preset (omnigate, anthropic, openrouter, opencode, openai) or a [provider NAME] section with api and url",
        else => null,
    };
}

/// One `[provider NAME]` section's lines so far.
const ProviderLines = struct {
    section: model.Section,
    headers: std.ArrayList(model.Header) = .empty,
};

/// "provider NAME" → NAME as written (the caller checks it).
fn providerSection(section: []const u8) ?[]const u8 {
    const word = "provider";
    if (section.len <= word.len or !std.mem.startsWith(u8, section, word)) return null;
    if (section[word.len] != ' ' and section[word.len] != '\t') return null;
    return std.mem.trim(u8, section[word.len..], " \t");
}

fn providerLine(arena: std.mem.Allocator, provs: *std.ArrayList(ProviderLines), name: []const u8, l: Line) ParseError!void {
    if (!model.validName(name)) return error.BadProvider;
    const p = for (provs.items) |*x| {
        if (std.mem.eql(u8, x.section.name, name)) break x;
    } else blk: {
        try provs.append(arena, .{ .section = .{ .name = name } });
        break :blk &provs.items[provs.items.len - 1];
    };
    const v = l.value;
    if (std.mem.eql(u8, l.key, "api")) {
        p.section.api = model.parseApi(v) orelse return error.BadProvider;
    } else if (std.mem.eql(u8, l.key, "url")) {
        if (!model.validUrl(v)) return error.BadProvider;
        p.section.url = v;
    } else if (std.mem.eql(u8, l.key, "auth")) {
        p.section.auth = model.parseAuth(v) orelse return error.BadProvider;
    } else if (std.mem.eql(u8, l.key, "key")) {
        if (!mcp.validSecretName(v)) return error.BadProvider;
        p.section.key = v;
    } else if (std.mem.eql(u8, l.key, "cache")) {
        p.section.cache = parseBool(v) orelse return error.BadProvider;
    } else if (std.mem.eql(u8, l.key, "header")) {
        if (p.headers.items.len >= model.max_headers) return error.BadHeader;
        try p.headers.append(arena, try parseHeader(v));
    } else return error.BadProvider;
}

/// "Name: value". Not a header harness sets itself, nor one that carries a
/// key: keys are stored secrets (`key =`), masked, never config.ini text.
fn parseHeader(v: []const u8) error{BadHeader}!model.Header {
    const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadHeader;
    const name = std.mem.trim(u8, v[0..colon], " \t");
    const value = std.mem.trim(u8, v[colon + 1 ..], " \t");
    if (name.len == 0 or value.len == 0) return error.BadHeader;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return error.BadHeader;
    for (value) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return error.BadHeader;
    const refused = [_][]const u8{ "authorization", "x-api-key", "host", "connection", "content-length", "content-type", "transfer-encoding", "anthropic-version" };
    for (refused) |r| if (std.ascii.eqlIgnoreCase(name, r)) return error.BadHeader;
    return .{ .name = name, .value = value };
}

/// The `[provider NAME]` sections in the order their headers first
/// appear, a header with no keys under it too, so that a new provider
/// missing api or url is named at its header.
fn providerSections(arena: std.mem.Allocator, text: []const u8, provs: []const ProviderLines) ParseError![]const model.Section {
    var out: std.ArrayList(model.Section) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') continue;
        const name = providerSection(std.mem.trim(u8, line[1 .. line.len - 1], " \t")) orelse continue;
        if (!model.validName(name)) return error.BadProvider;
        for (out.items) |o| {
            if (std.mem.eql(u8, o.name, name)) break;
        } else {
            var sec: model.Section = .{ .name = name };
            for (provs) |p| if (std.mem.eql(u8, p.section.name, name)) {
                sec = p.section;
                sec.headers = p.headers.items;
            };
            if (!model.isPreset(name) and (sec.api == null or sec.url == null)) return error.ProviderNeedsApiAndUrl;
            try out.append(arena, sec);
        }
    }
    return out.items;
}

fn setField(sec: anytype, l: Line) Error!void {
    const T = @TypeOf(sec.*);
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, l.key, fname)) {
            if (comptime std.mem.eql(u8, fname, "utc_offset")) {
                @field(sec.*, fname) = parseOffset(l.value) catch return error.BadConfig;
            } else if (comptime std.mem.eql(u8, fname, "remind")) {
                @field(sec.*, fname) = if (std.ascii.eqlIgnoreCase(l.value, "off")) null else parseClock(l.value) catch return error.BadConfig;
            } else switch (ftype) {
                []const u8 => {
                    // only omnigate's address may be left empty (not set yet)
                    const may_be_empty = comptime (T == Config.Model and std.mem.eql(u8, fname, "url"));
                    if (l.value.len == 0 and !may_be_empty) return error.BadConfig;
                    @field(sec.*, fname) = l.value;
                },
                u32 => @field(sec.*, fname) = std.fmt.parseInt(u32, l.value, 10) catch return error.BadConfig,
                bool => @field(sec.*, fname) = parseBool(l.value) orelse return error.BadConfig,
                else => @compileError("no parser for " ++ @typeName(ftype)),
            }
            return;
        }
    }
    return error.BadConfig;
}

pub fn parseBool(v: []const u8) ?bool {
    const yes = [_][]const u8{ "on", "yes", "true", "1" };
    const no = [_][]const u8{ "off", "no", "false", "0" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(v, y)) return true;
    for (no) |n| if (std.ascii.eqlIgnoreCase(v, n)) return false;
    return null;
}

/// "+01:00", "-05:30", "+00:00" → minutes east of UTC.
pub fn parseOffset(v: []const u8) error{BadOffset}!i32 {
    if (v.len != 6 or (v[0] != '+' and v[0] != '-') or v[3] != ':') return error.BadOffset;
    const h = std.fmt.parseInt(u8, v[1..3], 10) catch return error.BadOffset;
    const m = std.fmt.parseInt(u8, v[4..6], 10) catch return error.BadOffset;
    if (h > 14 or m > 59) return error.BadOffset;
    const total: i32 = @as(i32, h) * 60 + m;
    return if (v[0] == '-') -total else total;
}

/// "07:00" → minutes after midnight.
pub fn parseClock(v: []const u8) error{BadClock}!u16 {
    if (v.len != 5 or v[2] != ':') return error.BadClock;
    const h = std.fmt.parseInt(u8, v[0..2], 10) catch return error.BadClock;
    const m = std.fmt.parseInt(u8, v[3..5], 10) catch return error.BadClock;
    if (h > 23 or m > 59) return error.BadClock;
    return @as(u16, h) * 60 + m;
}

pub const Topic = struct {
    name: []const u8,
    feeds: []const []const u8,
    searches: []const []const u8,
};

pub const Brief = struct {
    name: []const u8,
    at_minutes: u16,
    topics: []const Topic,
    /// The conversation it posts to (`to =`).
    to: []const u8 = "main",
};

pub fn parseBriefs(arena: std.mem.Allocator, text: []const u8) Error![]Brief {
    var briefs: std.ArrayList(Brief) = .empty;
    var topics: std.ArrayList(Topic) = .empty;
    var cur: ?Brief = null;
    for (try lines(arena, text)) |l| {
        if (l.section.len == 0) return error.BadConfig;
        if (cur == null or !std.mem.eql(u8, cur.?.name, l.section)) {
            if (cur) |*c| {
                c.topics = try topics.toOwnedSlice(arena);
                try briefs.append(arena, c.*);
            }
            for (briefs.items) |b| if (std.mem.eql(u8, b.name, l.section)) return error.BadConfig;
            cur = .{ .name = l.section, .at_minutes = 7 * 60, .topics = &.{} };
        }
        if (std.mem.eql(u8, l.key, "at")) {
            cur.?.at_minutes = parseClock(l.value) catch return error.BadConfig;
        } else if (std.mem.eql(u8, l.key, "to")) {
            cur.?.to = try conversationName(l.value);
        } else if (std.mem.eql(u8, l.key, "topic")) {
            try topics.append(arena, try parseTopic(arena, l.value));
        } else return error.BadConfig;
    }
    if (cur) |*c| {
        c.topics = try topics.toOwnedSlice(arena);
        try briefs.append(arena, c.*);
    }
    return briefs.items;
}

/// "Name | https://feed | search: words" → a topic.
pub fn parseTopic(arena: std.mem.Allocator, v: []const u8) Error!Topic {
    var feeds: std.ArrayList([]const u8) = .empty;
    var searches: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v, '|');
    const name = std.mem.trim(u8, it.next() orelse "", " \t");
    if (name.len == 0) return error.BadConfig;
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == 0) continue;
        if (std.mem.startsWith(u8, p, "search:")) {
            const q = std.mem.trim(u8, p["search:".len..], " \t");
            if (q.len == 0) return error.BadConfig;
            try searches.append(arena, q);
        } else if (std.mem.startsWith(u8, p, "https://") or std.mem.startsWith(u8, p, "http://")) {
            try feeds.append(arena, p);
        } else return error.BadConfig;
    }
    if (feeds.items.len + searches.items.len == 0) return error.BadConfig;
    return .{ .name = name, .feeds = feeds.items, .searches = searches.items };
}

/// The line `/topic add` appends to a brief section.
pub fn formatTopic(arena: std.mem.Allocator, topic: Topic) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "topic = {s}", .{topic.name});
    for (topic.feeds) |f| try out.print(arena, " | {s}", .{f});
    for (topic.searches) |s| try out.print(arena, " | search: {s}", .{s});
    return out.items;
}

pub const Task = struct {
    name: []const u8,
    at_minutes: ?u16 = null,
    every_minutes: ?u32 = null,
    /// Bit 0 = Monday … bit 6 = Sunday.
    days: u7 = 0x7f,
    do: []const u8 = "",
    /// The conversation it posts to (`to =`).
    to: []const u8 = "main",
    /// The definition that runs it (`agent =`).
    agent: []const u8 = "main",
};

pub const day_names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

pub fn parseTasks(arena: std.mem.Allocator, text: []const u8) Error![]Task {
    var tasks: std.ArrayList(Task) = .empty;
    for (try lines(arena, text)) |l| {
        if (l.section.len == 0) return error.BadConfig;
        if (tasks.items.len == 0 or !std.mem.eql(u8, tasks.items[tasks.items.len - 1].name, l.section)) {
            for (tasks.items) |other| if (std.mem.eql(u8, other.name, l.section)) return error.BadConfig;
            try tasks.append(arena, .{ .name = l.section });
        }
        const tk = &tasks.items[tasks.items.len - 1];
        if (std.mem.eql(u8, l.key, "at")) {
            tk.at_minutes = parseClock(l.value) catch return error.BadConfig;
        } else if (std.mem.eql(u8, l.key, "every")) {
            tk.every_minutes = parseEvery(l.value) catch return error.BadConfig;
        } else if (std.mem.eql(u8, l.key, "days")) {
            tk.days = parseDays(l.value) catch return error.BadConfig;
        } else if (std.mem.eql(u8, l.key, "do")) {
            tk.do = l.value;
        } else if (std.mem.eql(u8, l.key, "to")) {
            tk.to = try conversationName(l.value);
        } else if (std.mem.eql(u8, l.key, "agent")) {
            if (!agents.validName(l.value)) return error.BadConfig;
            tk.agent = l.value;
        } else return error.BadConfig;
    }
    for (tasks.items) |tk| {
        if (tk.do.len == 0) return error.BadConfig;
        if ((tk.at_minutes == null) == (tk.every_minutes == null)) return error.BadConfig;
    }
    return tasks.items;
}

/// A `to =` value: a conversation's name (a-z, 0-9, - and _, up to 32);
/// one that is no conversation yet opens that topic at its first post.
fn conversationName(v: []const u8) Error![]const u8 {
    if (!conversations.validName(v)) return error.BadConfig;
    return v;
}

/// "15m", "2h" → minutes; at least 5.
pub fn parseEvery(v: []const u8) error{BadEvery}!u32 {
    if (v.len < 2) return error.BadEvery;
    const n = std.fmt.parseInt(u32, v[0 .. v.len - 1], 10) catch return error.BadEvery;
    const minutes = switch (v[v.len - 1]) {
        'm' => n,
        'h' => std.math.mul(u32, n, 60) catch return error.BadEvery,
        else => return error.BadEvery,
    };
    if (minutes < 5) return error.BadEvery;
    return minutes;
}

pub fn parseDays(v: []const u8) error{BadDays}!u7 {
    var mask: u7 = 0;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |raw| {
        const d = std.mem.trim(u8, raw, " \t");
        const i = for (day_names, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(d, name)) break i;
        } else return error.BadDays;
        mask |= @as(u7, 1) << @intCast(i);
    }
    if (mask == 0) return error.BadDays;
    return mask;
}

/// Written by `harness init`.
pub const defaults_ini =
    \\; harness settings. Lines starting with ; are comments.
    \\[model]
    \\provider = omnigate                 ; the default provider: omnigate, anthropic, openrouter, opencode, openai or a [provider NAME] section
    \\url =                               ; omnigate's address (required for omnigate), like https://omnigate.example.com
    \\model = claude-sonnet               ; the agent's model (PROVIDER:MODEL picks another provider)
    \\memory_model = claude-haiku         ; for writing memories
    \\worker_model = claude-haiku         ; for helpers (delegate)
    \\key = omnigate                      ; secret holding the omnigate key
    \\max_tokens = 4096
    \\; Other gateways: a [provider NAME] section each (README: Models and providers),
    \\; their keys stored with harness secret add NAME.
    \\
    \\[search]
    \\url = https://api.search.brave.com
    \\key = search                        ; secret holding the search API key
    \\
    \\[chat]
    \\telegram = on
    \\token = telegram                    ; secret holding the bot token
    \\api = https://api.telegram.org
    \\utc_offset = +00:00                 ; for brief and task times
    \\
    \\[limits]
    \\steps_per_turn = 20
    \\turn_seconds = 600
    \\tool_output_bytes = 16384
    \\conversation_bytes = 200000
    \\concurrent_runs = 2
    \\approval_seconds = 600
    \\sends_per_run = 10                  ; posts one run may make with send
    \\sends_per_hour = 60                 ; posts to one conversation an hour; past it: logged, not sent
    \\snapshot_mb = 5120                  ; snapshots of folders, all together, at most (MiB)
    \\
    \\[memory]
    \\auto = on
    \\top_size = 20
    \\
    \\[agents]                            ; helpers started with delegate
    \\parallel = 4                        ; most running at once
    \\steps = 12                          ; model calls per helper
    \\tokens = 150000                     ; input tokens per helper
    \\answer_bytes = 4000
    \\
    \\[browser]
    \\; path = /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
    \\seconds = 30
    \\
    \\[money]                             ; MCP tools listed under money = in mcp.ini
    \\max_per_call = 0                    ; in the tool's amount units; 0 = no cap
    \\max_per_day = 0
    \\scheduled = off                     ; on: scheduled runs may move money, within the caps
    \\
    \\[apps]                              ; apps in your browser, on this machine only
    \\on = off
    \\port = 0                            ; 0 = a free one each start
    \\
    \\[inbox]                             ; what waits for you (/inbox)
    \\questions = 20                      ; questions and approvals waiting at once
    \\remind = 09:00                      ; once a day, if something waited over 12 hours; off: never
    \\
;

pub const rules_example =
    \\# Gate rules: allow | ask | deny, a tool, a pattern (* matches anything).
    \\# A matching deny always wins; otherwise the first matching line decides;
    \\# otherwise the tool's default: shell, fetch, browse, web, login,
    \\# skill_save, mcp (MCP tools, matched as "mcp SERVER/TOOL INPUT") and
    \\# write_file to a path with a part starting with "." (.git/config,
    \\# .npmrc: programs read those as settings) ask; money tools are asked
    \\# every time, whatever the rules; the others are allowed.
    \\# send (a post) to a conversation others read is asked every time
    \\# unless an allow rule names it (allow send family).
    \\# agent_save (a new agent definition, or a change to the agent's own)
    \\# is asked every time, whatever the rules; a deny rule stops it.
    \\# Not used yet (their tools come later): mail, trigger rm and workflow
    \\# start and stop ask; app_save, env_save, trigger add and workflow save
    \\# are asked every time.
    \\# A line [agent:NAME], [owner] or [schedule:NAME] starts rules for those
    \\# calls only; [all] goes back to rules for every call. shell@NAME is for
    \\# commands in environment NAME (host is the only one for now).
    \\# After the agent writes a file in the workspace, a shell command that
    \\# a rule or a 24 h grant allows is asked first, naming the files, until
    \\# you allow one; a scheduled run skips it.
    \\#
    \\# deny  shell rm -rf *
    \\# allow fetch https://news.ycombinator.com/*
    \\# allow shell git status
    \\
;

pub const briefs_example =
    \\; Briefs: when to send, and topics with their sources.
    \\; topic = Name | feed URL | search: words
    \\; to = NAME posts it to that conversation (default main, the private chat).
    \\;
    \\; [morning]
    \\; at = 07:00
    \\; topic = Zig | https://ziglang.org/news/index.xml | search: zig release
    \\
;

pub const tasks_example =
    \\; Scheduled tasks: the agent runs `do` at a time (`at`, optional `days`)
    \\; or every N minutes (`every = 15m`, at least 5m). Its answer is sent to
    \\; you unless it is NOTHING; to = NAME posts it to that conversation
    \\; (default main, the private chat; a new name opens that topic);
    \\; agent = NAME runs it as that definition (default main, agents/).
    \\;
    \\; [weekly-review]
    \\; at = 18:00
    \\; days = fri
    \\; do = Summarise what you did for me this week.
    \\
;

const t = std.testing;

test "config_defaults_when_empty" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), "");
    // no omnigate address until the owner sets one: a default could hand the key to whatever listens there
    try t.expectEqualStrings("", c.model.url);
    try t.expectEqualStrings("", (try parse(arena.allocator(), "[model]\nurl =\n")).model.url);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "127.0.0.1") == null);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[model]\nmodel =\n"));
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[search]\nurl =\n"));
    try t.expectEqual(20, c.limits.steps_per_turn);
    try t.expectEqual(600, c.limits.turn_seconds);
    try t.expectEqual(16384, c.limits.tool_output_bytes);
    try t.expectEqual(200000, c.limits.conversation_bytes);
    try t.expectEqual(2, c.limits.concurrent_runs);
    try t.expectEqual(600, c.limits.approval_seconds);
    try t.expectEqual(20, c.memory.top_size);
    try t.expect(c.memory.auto);
    try t.expectEqual(4096, c.model.max_tokens);
    // the written defaults read back as the defaults
    const d = try parse(arena.allocator(), defaults_ini);
    try t.expectEqualDeep(c, d);
}

test "config_reads_every_section" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(),
        \\[model]
        \\url = http://10.0.0.2:9000   ; gateway
        \\model = big
        \\memory_model = small
        \\key = og
        \\max_tokens = 1000
        \\[search]
        \\url = http://127.0.0.1:5000
        \\key = brave
        \\[chat]
        \\telegram = off
        \\token = bot
        \\api = http://127.0.0.1:5001
        \\utc_offset = +01:00
        \\[limits]
        \\steps_per_turn = 3
        \\turn_seconds = 30
        \\tool_output_bytes = 100
        \\conversation_bytes = 5000
        \\concurrent_runs = 1
        \\approval_seconds = 5
        \\[memory]
        \\auto = off
        \\top_size = 4
    );
    try t.expectEqualStrings("http://10.0.0.2:9000", c.model.url);
    try t.expectEqualStrings("big", c.model.model);
    try t.expectEqualStrings("small", c.model.memory_model);
    try t.expectEqualStrings("og", c.model.key);
    try t.expectEqual(1000, c.model.max_tokens);
    try t.expectEqualStrings("brave", c.search.key);
    try t.expect(!c.chat.telegram);
    try t.expectEqualStrings("bot", c.chat.token);
    try t.expectEqualStrings("http://127.0.0.1:5001", c.chat.api);
    try t.expectEqual(60, c.chat.utc_offset);
    try t.expectEqual(3, c.limits.steps_per_turn);
    try t.expectEqual(30, c.limits.turn_seconds);
    try t.expectEqual(100, c.limits.tool_output_bytes);
    try t.expectEqual(5000, c.limits.conversation_bytes);
    try t.expectEqual(1, c.limits.concurrent_runs);
    try t.expectEqual(5, c.limits.approval_seconds);
    try t.expect(!c.memory.auto);
    try t.expectEqual(4, c.memory.top_size);
}

test "config_rejects_unknown_section_and_bad_numbers" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.BadConfig, parse(a, "[nope]\nx = 1"));
    try t.expectError(error.BadConfig, parse(a, "[limits]\nsteps_per_turn = many"));
    try t.expectError(error.BadConfig, parse(a, "[limits]\nunknown = 1"));
    try t.expectError(error.BadConfig, parse(a, "[memory]\nauto = maybe"));
    try t.expectError(error.BadConfig, parse(a, "[model]\njust words"));
    try t.expectError(error.BadConfig, parse(a, "[chat]\nutc_offset = 1"));
}

test "briefs_parse_topics_with_feeds_and_searches" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const b = try parseBriefs(arena.allocator(),
        \\[morning]
        \\at = 07:00
        \\topic = Zig | https://ziglang.org/news/index.xml | search: zig 0.18 release
        \\topic = AI agents | https://news.ycombinator.com/rss | search: agent harness
    );
    try t.expectEqual(1, b.len);
    try t.expectEqualStrings("morning", b[0].name);
    try t.expectEqual(420, b[0].at_minutes);
    try t.expectEqual(2, b[0].topics.len);
    try t.expectEqualStrings("Zig", b[0].topics[0].name);
    try t.expectEqualStrings("https://ziglang.org/news/index.xml", b[0].topics[0].feeds[0]);
    try t.expectEqualStrings("zig 0.18 release", b[0].topics[0].searches[0]);
    try t.expectEqualStrings("AI agents", b[0].topics[1].name);
    const line = try formatTopic(arena.allocator(), b[0].topics[0]);
    try t.expectEqualStrings("topic = Zig | https://ziglang.org/news/index.xml | search: zig 0.18 release", line);
    try t.expectError(error.BadConfig, parseBriefs(arena.allocator(), "[m]\ntopic = X | ftp://x"));
    try t.expectError(error.BadConfig, parseBriefs(arena.allocator(), "[m]\ntopic = X"));
    try t.expectError(error.BadConfig, parseBriefs(arena.allocator(), "[m]\nat = 25:00"));
}

test "offset_parses_signs_and_rejects_garbage" {
    try t.expectEqual(60, try parseOffset("+01:00"));
    try t.expectEqual(-330, try parseOffset("-05:30"));
    try t.expectEqual(0, try parseOffset("+00:00"));
    try t.expectError(error.BadOffset, parseOffset("01:00"));
    try t.expectError(error.BadOffset, parseOffset("+1:00"));
    try t.expectError(error.BadOffset, parseOffset("+15:00"));
    try t.expectError(error.BadOffset, parseOffset("+01:60"));
}

test "tasks_parse_at_every_days_and_refuse_every_under_5m" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try parseTasks(a,
        \\[btc-watch]
        \\every = 15m
        \\do = Check the BTC price and tell me if it moved more than 3% since the last check.
        \\[weekly-review]
        \\at = 18:00
        \\days = fri, sat
        \\do = Summarise the week.
    );
    try t.expectEqual(2, ts.len);
    try t.expectEqual(15, ts[0].every_minutes.?);
    try t.expectEqual(null, ts[0].at_minutes);
    try t.expectEqual(0x7f, ts[0].days);
    try t.expectEqual(18 * 60, ts[1].at_minutes.?);
    try t.expectEqual(0b0110000, ts[1].days);
    try t.expectEqual(120, try parseEvery("2h"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 4m\ndo = y"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nat = 07:00\nevery = 5m\ndo = y"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\ndo = y"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nat = 07:00\ndays = someday\ndo = y"));
}

test "tasks_and_briefs_name_their_conversation" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try parseTasks(a, "[watch]\nevery = 5m\nto = house-search\ndo = Look for flats.\n[plain]\nevery = 5m\ndo = x\n");
    try t.expectEqualStrings("house-search", ts[0].to);
    // no `to`: the private chat
    try t.expectEqualStrings("main", ts[1].to);
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m\nto = House Search\ndo = y"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m\nto = a/b\ndo = y"));
    const bs = try parseBriefs(a, "[morning]\nat = 07:00\nto = news\ntopic = Zig | https://ziglang.org/news/index.xml\n");
    try t.expectEqualStrings("news", bs[0].to);
    try t.expectEqualStrings("main", (try parseBriefs(a, "[m]\ntopic = Z | https://z.org/f\n"))[0].to);
    try t.expectError(error.BadConfig, parseBriefs(a, "[m]\nto = rm\ntopic = Z | https://z.org/f\n"));
    const c = try parse(a, "");
    try t.expectEqual(10, c.limits.sends_per_run);
    try t.expectEqual(60, c.limits.sends_per_hour);
    try t.expectEqual(3, (try parse(a, "[limits]\nsends_per_hour = 3\n")).limits.sends_per_hour);
}

test "tasks_name_their_agent" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try parseTasks(a, "[watch]\nevery = 5m\nagent = researcher\ndo = Look.\n[plain]\nevery = 5m\ndo = x\n");
    try t.expectEqualStrings("researcher", ts[0].agent);
    // no agent: main
    try t.expectEqualStrings("main", ts[1].agent);
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m\nagent = Research\ndo = y"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m\nagent = rm\ndo = y"));
}

test "agents_browser_and_money_sections" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(), "");
    try t.expectEqualStrings("claude-haiku", d.model.worker_model);
    try t.expectEqual(4, d.agents.parallel);
    try t.expectEqual(12, d.agents.steps);
    try t.expectEqual(150000, d.agents.tokens);
    try t.expectEqual(4000, d.agents.answer_bytes);
    try t.expectEqual(0, d.money.max_per_call);
    try t.expect(!d.money.scheduled);
    const c = try parse(arena.allocator(), "[model]\nworker_model = tiny\n[agents]\nparallel = 2\n[browser]\npath = /opt/chrome\n[money]\nmax_per_call = 100\nmax_per_day = 500\nscheduled = on\n");
    try t.expectEqualStrings("tiny", c.model.worker_model);
    try t.expectEqual(2, c.agents.parallel);
    try t.expectEqualStrings("/opt/chrome", c.browser.path);
    try t.expectEqual(100, c.money.max_per_call);
    try t.expectEqual(500, c.money.max_per_day);
    try t.expect(c.money.scheduled);
    _ = try parse(arena.allocator(), defaults_ini);
}

test "inbox_settings_read_questions_and_remind" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "");
    try t.expectEqual(20, d.inbox.questions);
    try t.expectEqual(9 * 60, d.inbox.remind.?);
    const c = try parse(a, "[inbox]\nquestions = 3\nremind = 18:30\n");
    try t.expectEqual(3, c.inbox.questions);
    try t.expectEqual(18 * 60 + 30, c.inbox.remind.?);
    try t.expectEqual(null, (try parse(a, "[inbox]\nremind = off\n")).inbox.remind);
    try t.expectError(error.BadConfig, parse(a, "[inbox]\nremind = 25:00\n"));
    try t.expectError(error.BadConfig, parse(a, "[inbox]\nquestions = 0\n"));
    try t.expectEqualDeep(d.inbox, (try parse(a, defaults_ini)).inbox);
}

test "inits_rules_comment_names_each_tool_that_asks_by_default" {
    const gate = @import("gate.zig");
    // the comment is what an owner reads to learn the defaults: every tool
    // that asks must be named there, and none that is always allowed; one
    // that asks only for some arguments (write_file to a dot path, which
    // programs read as settings) is named with when
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var grants: gate.Grants = .init(t.allocator);
    defer grants.deinit();
    const g: gate.Gate = .{ .io = t.io, .rules = &.{}, .grants = &grants, .workspace = try tmp.dir.realPathFileAlloc(t.io, ".", a) };
    const comment = rules_example[0 .. std.mem.indexOf(u8, rules_example, "#\n") orelse rules_example.len];
    inline for (@typeInfo(gate.Tool).@"enum".field_names) |name| {
        const tool = @field(gate.Tool, name);
        const asks = tool.default() == .ask or g.decide(a, tool, ".npmrc", 1000, .{}).action == .ask;
        const named = hasWord(comment, name);
        if (asks != named) {
            std.debug.print("{s} (asks by default: {}) is {s} in:\n{s}\n", .{ name, asks, if (named) "named" else "not named", comment });
            return error.TestUnexpectedResult;
        }
    }
    try t.expect(std.mem.indexOf(u8, comment, "write_file to a path with a part starting with \".\"") != null);
}

/// `word` as a whole word in `text` ("skill" is not in "skill_save").
fn hasWord(text: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |i| {
        const end = i + word.len;
        const before_ok = i == 0 or !(std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_');
        const after_ok = end == text.len or !(std.ascii.isAlphanumeric(text[end]) or text[end] == '_');
        if (before_ok and after_ok) return true;
        from = i + 1;
    }
    return false;
}

test "a_provider_section_overrides_a_preset" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a,
        \\[provider openrouter]
        \\key = or-key
        \\url = http://127.0.0.1:9/api/v1
        \\header = HTTP-Referer: https://example.org
        \\header = X-Title: harness
        \\cache = off
    );
    const set = try model.Providers.resolve(a, providerSettings(c), model.no_keys);
    const orp = set.find("openrouter").?;
    // what the section says, and the preset's for the rest
    try t.expectEqual(model.Api.openai, orp.api);
    try t.expectEqual(model.Auth.bearer, orp.auth);
    try t.expectEqualStrings("http://127.0.0.1:9/api/v1", orp.url);
    try t.expectEqualStrings("or-key", orp.key_name);
    try t.expect(!orp.cache);
    try t.expectEqual(2, orp.headers.len);
    try t.expectEqualStrings("HTTP-Referer", orp.headers[0].name);
    try t.expectEqualStrings("https://example.org", orp.headers[0].value);
    try t.expectEqualStrings("X-Title", orp.headers[1].name);
    try t.expectEqualStrings("harness", orp.headers[1].value);
    // the other presets as they are
    const an = set.find("anthropic").?;
    try t.expectEqual(model.Api.anthropic, an.api);
    try t.expectEqualStrings("https://api.anthropic.com/v1", an.url);
    try t.expectEqual(model.Auth.x_api_key, an.auth);
    try t.expect(an.cache);
    try t.expectEqualStrings("anthropic", an.key_name);
    try t.expectEqual(0, an.headers.len);
    // harness init's settings: no section, omnigate the default
    const d = try parse(a, defaults_ini);
    try t.expectEqual(0, d.providers.len);
    try t.expectEqualStrings("omnigate", d.model.provider);
}

test "a_new_provider_needs_api_and_url" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.ProviderNeedsApiAndUrl, parse(a, "[provider local]\n"));
    try t.expectError(error.ProviderNeedsApiAndUrl, parse(a, "[provider local]\nurl = http://127.0.0.1:11434/v1\n"));
    try t.expectError(error.ProviderNeedsApiAndUrl, parse(a, "[provider local]\napi = openai\n"));
    const c = try parse(a, "[provider local]\napi = openai\nurl = http://127.0.0.1:11434/v1\n[provider proxy]\napi = anthropic\nurl = https://proxy.example.com/v1\n");
    const set = try model.Providers.resolve(a, providerSettings(c), model.no_keys);
    // the defaults of a new provider follow its format
    const local = set.find("local").?;
    try t.expectEqual(model.Api.openai, local.api);
    try t.expectEqual(model.Auth.bearer, local.auth);
    try t.expect(!local.cache);
    try t.expectEqualStrings("local", local.key_name);
    try t.expectEqualStrings("http://127.0.0.1:11434/v1", local.url);
    const proxy = set.find("proxy").?;
    try t.expectEqual(model.Api.anthropic, proxy.api);
    try t.expectEqual(model.Auth.x_api_key, proxy.auth);
    try t.expect(proxy.cache);
    // the default provider must be one
    try t.expectError(error.UnknownProvider, parse(a, "[model]\nprovider = nowhere\n"));
    const lc = try parse(a, "[model]\nprovider = local\n[provider local]\napi = openai\nurl = http://127.0.0.1:11434/v1\n");
    const ls = try model.Providers.resolve(a, providerSettings(lc), model.no_keys);
    try t.expectEqualStrings("local", ls.list[ls.default].name);
    // a section missing a key is named at its header
    const why = (try @import("core.zig").parseProblem(a, "config.ini", "[model]\nurl = http://127.0.0.1:1\n[provider local]\nurl = http://127.0.0.1:11434/v1\n", parse)).?;
    if (!std.mem.startsWith(u8, why, "config.ini line 3 has an error: [provider local] (a provider that is not a preset needs api")) {
        std.debug.print("got: {s}\n", .{why});
        return error.TestUnexpectedResult;
    }
}

test "provider_sections_refuse_bad_values" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "api = grpc", "auth = basic", "cache = maybe", "url = ftp://x", "url = http://h/a b", "key = Bad Key", "colour = red" }) |line| {
        try t.expectError(error.BadProvider, parse(a, try std.fmt.allocPrint(a, "[provider openrouter]\n{s}\n", .{line})));
    }
    try t.expectError(error.BadProvider, parse(a, "[provider Bad:Name]\napi = openai\nurl = http://h\n"));
    try t.expectError(error.BadProvider, parse(a, "[provider a/b]\napi = openai\nurl = http://h\n"));
    for ([_][]const u8{ "NoColon", "Authorization: Bearer x", "x-api-key: y", "Host: h", ": v", "X-A:", "anthropic-version: 2024-01-01" }) |h| {
        try t.expectError(error.BadHeader, parse(a, try std.fmt.allocPrint(a, "[provider openrouter]\nheader = {s}\n", .{h})));
    }
    var nine: std.ArrayList(u8) = .empty;
    try nine.appendSlice(a, "[provider openrouter]\n");
    for (0..9) |i| try nine.print(a, "header = X-H{d}: v\n", .{i});
    try t.expectError(error.BadHeader, parse(a, nine.items));
    for ([_]anyerror{ error.BadProvider, error.BadHeader, error.ProviderNeedsApiAndUrl, error.UnknownProvider }) |e| try t.expect(reason(e) != null);
}
