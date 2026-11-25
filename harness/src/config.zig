//! The instance's settings: config.ini (models and providers, chat,
//! limits, memory, voice notes, quiet hours), briefs.ini (topics and their sources) and tasks.ini
//! (scheduled instructions). All three are small INI files: `[section]`,
//! `key = value`, comments after `;` or `#`.
const std = @import("std");
const conversations = @import("conversations.zig");
const agents = @import("agents.zig");
const model = @import("model.zig");
const mcp = @import("mcp.zig");
const triggers = @import("triggers.zig");
const alerts = @import("alerts.zig");

pub const Error = error{ BadConfig, OutOfMemory };

/// What `parse` refuses besides a bad line: the `[provider NAME]`
/// sections' problems, which `reason` says.
pub const ParseError = Error || error{ BadProvider, BadHeader, ProviderNeedsApiAndUrl, UnknownProvider, BadVoice, BadVoiceAgent, BadDesk };

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
    triggers: Triggers = .{},
    workflows: Workflows = .{},
    voice: Voice = .{},
    butler: Butler = .{},
    voice_agent: VoiceAgent = .{},
    mail: Mail = .{},
    desk: Desk = .{},
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
        /// Summaries by day, week and month (long memory): one small model
        /// call per active conversation a day.
        summaries: bool = true,
        /// Their model; "": `[model] memory_model`.
        summary_model: []const u8 = "",
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
        /// What automation (unattended runs) may spend without asking, in
        /// the tool's amount units, counted apart from the owner's own
        /// spending; 0: limits nothing on its own. Automation spends only
        /// while one of them is above 0.
        budget_per_day: u32 = 0,
        budget_per_month: u32 = 0,
        /// Money calls in scheduled runs, without asking, within the caps
        /// and the budget (on: with no budget nothing moves).
        scheduled: bool = true,
        /// Runs a trigger starts follow `scheduled` (on) or never move
        /// money (off).
        triggers: bool = true,
        /// Agent steps of workflows follow `scheduled` (on) or never move
        /// money (off); a tool step's money call is asked every time
        /// either way.
        workflows: bool = true,
        /// Runs an app starts follow `scheduled` (on) or never move money
        /// (off: the owner has not decided yet); an app's own acts never.
        apps: bool = false,
    };
    /// The app server (gap 8): apps shown in your browser.
    pub const Apps = struct {
        on: bool = true,
        /// The desk app finds harness here; 0: one is picked at the next
        /// start and written (a taken one moves to the next of ten).
        port: u32 = 0,
        /// How long one act an app asks for may take, its question included.
        act_seconds: u32 = 120,
        /// Runs an app may start in an hour.
        runs_per_hour: u32 = 20,
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
    /// Event triggers (triggers.ini).
    pub const Triggers = struct {
        /// The model of `check =` lines; "": `[model] worker_model`.
        check_model: []const u8 = "",
        /// Check questions a day, all triggers together.
        checks_per_day: u32 = 200,
        /// Runs triggers start, all of them together.
        runs_per_hour: u32 = 20,
        runs_per_day: u32 = 100,
        /// Events waiting per trigger; past it the trigger pauses.
        queue: u32 = 200,
    };
    /// Workflows (workflows/NAME.wf).
    pub const Workflows = struct {
        /// Instances going at once, all workflows together; past it a
        /// start is refused.
        instances: u32 = 50,
        /// Agent steps a day, all workflows together; past it they wait
        /// for the next day.
        agent_steps_per_day: u32 = 100,
    };
    /// Voice notes in Telegram: transcribed by an OpenAI-compatible
    /// `/audio/transcriptions` of a provider.
    pub const Voice = struct {
        /// A preset or a `[provider NAME]` whose api is openai; "": off.
        provider: []const u8 = "",
        /// The transcription model (`whisper-large-v3-turbo` at Groq).
        model: []const u8 = "",
        /// The language spoken, as its ISO 639-1 code; "": the service
        /// finds it.
        language: []const u8 = "",
    };
    /// Home Assistant's conversation agent: speech in the house, answered
    /// by harness (README: Home Assistant's voice).
    pub const VoiceAgent = struct {
        /// An IP address of this machine and a port (`parseListen`); `off`:
        /// no listener. It runs with `harness run` while the token is stored.
        listen: []const u8 = "127.0.0.1:8765",
        /// The stored secret Home Assistant's API key must be.
        token: []const u8 = "ha-agent",
        /// A spoken answer's time, 5 to 60 s.
        seconds: u32 = 20,
        /// Its model (PROVIDER:MODEL as anywhere); "": the chat's.
        model: []const u8 = "",
    };
    /// Mail (the email spec): the butler's own address is conversation
    /// `email`; `owner` says whose mail there is a message.
    pub const Mail = struct {
        /// The owner's addresses, comma-separated: only their mail to the
        /// butler's address starts a turn. "": the email conversation is off.
        owner: []const u8 = "",
        /// mailmcp's section in mcp.ini.
        server: []const u8 = "mail",
        /// The mail file's sections: the butler's own mailbox, the owner's.
        butler: []const u8 = "butler",
        mine: []const u8 = "mine",
        /// mailmcp's program for /setup mail; "": next to harness, else on PATH.
        mailmcp: []const u8 = "",
        /// When the day's line about others' mail to the butler comes
        /// (HH:MM, the owner's time).
        others_at: []const u8 = "18:00",
    };
    /// The desk (harness's own window): what it shows and says.
    pub const Desk = struct {
        /// Telegram gets a quiet echo of what you type on the desk.
        echo: bool = true,
        /// The avatar: a folder of `avatars/` (`butler` is built in).
        avatar: []const u8 = "butler",
        /// Replies read aloud: off, browser (the system's voice), or a
        /// provider whose api is openai (`/audio/speech`).
        speak: []const u8 = "off",
        /// The provider's speech model and voice.
        speak_model: []const u8 = "tts-1",
        speak_voice: []const u8 = "alloy",
    };
    /// The butler's manners.
    pub const Butler = struct {
        /// Quiet hours, the owner's time: posts of runs nobody waits on
        /// are held for a digest at their end; null: off until set.
        quiet: ?Quiet = null,
        /// homemcp's and carcloud's programs for /setup; "": next to
        /// harness, else on PATH.
        homemcp: []const u8 = "",
        carcloud: []const u8 = "",
        /// `escalate = 5m anna, 15m piotr`: an urgent alert nobody
        /// acknowledged goes to these members in turn (a trigger's or a
        /// workflow's own `escalate` replaces it); none: to no one.
        escalate: []const alerts.Step = &.{},
        /// calmcp's, for /setup calendar; the same.
        calmcp: []const u8 = "",
        /// Minutes before an event with a place that the diary says it
        /// is time to leave ("30m", "1h", "1h30m").
        travel: u32 = 30,
        /// A maps MCP server's travel-time tool, SERVER/TOOL; "": none
        /// (`travel` for every event).
        maps: []const u8 = "",
        /// °C: below this at the car (its own reading), the warm-car
        /// routine asks to warm it before a morning leave-by.
        warm_below: f64 = 5,
        /// After it (the owner's time), the owner's first message of the
        /// night gets one gentle line; null: off.
        bedtime: ?u16 = null,
        /// The evening message's time (the owner's); null: off.
        evening: ?u16 = null,
        /// Away mode: everyone out this many minutes and it comes on.
        away_after: u32 = 12 * 60,
        /// The heating while away, and to come home to, °C (10 to 28).
        away_temp: u32 = 17,
        home_temp: u32 = 21,
        /// Minutes before a flight to be at the airport (the leave-by
        /// comes this much earlier, and the way there before it).
        airport: u32 = 120,
        /// A flight-status MCP server's tool, SERVER/TOOL; "": none (no
        /// status is ever claimed).
        flight_status: []const u8 = "",
    };
};

/// Quiet hours: minutes after midnight, the owner's time; `start` is in
/// them, `end` is not; they may go past midnight.
pub const Quiet = struct {
    start: u16,
    end: u16,

    /// Whether minute `m` of the day (the owner's time) is in them.
    pub fn inside(q: Quiet, m: u16) bool {
        if (q.start < q.end) return m >= q.start and m < q.end;
        return m >= q.start or m < q.end;
    }
};

/// "22:00-07:00" (spaces and an en dash too) → quiet hours.
pub fn parseQuiet(v: []const u8) error{BadQuiet}!Quiet {
    const dash = std.mem.indexOf(u8, v, "–") orelse std.mem.indexOfScalar(u8, v, '-') orelse return error.BadQuiet;
    const width: usize = if (std.mem.startsWith(u8, v[dash..], "–")) "–".len else 1;
    const start = parseClock(std.mem.trim(u8, v[0..dash], " \t")) catch return error.BadQuiet;
    const end = parseClock(std.mem.trim(u8, v[dash + width ..], " \t")) catch return error.BadQuiet;
    if (start == end) return error.BadQuiet;
    return .{ .start = start, .end = end };
}

/// "22:00-07:00", as /quiet and the files write quiet hours.
pub fn formatQuiet(buf: *[16]u8, q: Quiet) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}-{d:0>2}:{d:0>2}", .{ q.start / 60, q.start % 60, q.end / 60, q.end % 60 }) catch "";
}

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
        // the household's order for urgent alerts: read whole here
        if (std.mem.eql(u8, l.section, "butler") and std.mem.eql(u8, l.key, "escalate")) {
            var why: []const u8 = "";
            cfg.butler.escalate = alerts.parseEscalate(arena, l.value, &why) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.BadEscalate => error.BadConfig,
            };
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
    if (cfg.inbox.questions == 0 or cfg.triggers.queue == 0 or cfg.workflows.instances == 0) return error.BadConfig;
    cfg.providers = try providerSections(arena, text, provs.items);
    if (!model.isPreset(cfg.model.provider)) {
        for (cfg.providers) |p| {
            if (std.mem.eql(u8, p.name, cfg.model.provider)) break;
        } else return error.UnknownProvider;
    }
    const va = cfg.voice_agent;
    if (!std.mem.eql(u8, va.listen, "off") and parseListen(va.listen) == null) return error.BadVoiceAgent;
    if (va.seconds < 5 or va.seconds > 60 or !secretName(va.token)) return error.BadVoiceAgent;
    if (cfg.voice.provider.len > 0) {
        if (voiceApi(cfg, cfg.voice.provider) != .openai) return error.BadVoice;
        if (cfg.voice.model.len == 0) return error.BadVoice;
        const l = cfg.voice.language;
        if (l.len > 0) {
            if (l.len < 2 or l.len > 3) return error.BadVoice;
            for (l) |ch| if (!std.ascii.isLower(ch)) return error.BadVoice;
        }
    }
    const dk = cfg.desk;
    if (!avatarName(dk.avatar)) return error.BadDesk;
    if (!std.mem.eql(u8, dk.speak, "off") and !std.mem.eql(u8, dk.speak, "browser")) {
        if (voiceApi(cfg, dk.speak) != .openai) return error.BadDesk;
        if (dk.speak_model.len == 0 or dk.speak_voice.len == 0) return error.BadDesk;
    }
    return cfg;
}

/// An avatar's folder name in `avatars/`: a-z, 0-9 and -, 1 to 32.
pub fn avatarName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-')) return false;
    return true;
}

/// `[voice_agent] listen`: an IP address of this machine and its port
/// (`192.168.1.20:8765`, `[::1]:8765` for IPv6); null for a name, a
/// missing port, every address at once (`0.0.0.0`, `::`), or an IPv4
/// address written as IPv6 (`[::ffff:0.0.0.0]` could be every IPv4
/// address): the voice agent listens on the house's network, never on
/// every network the machine is on.
pub fn parseListen(text: []const u8) ?std.Io.net.IpAddress {
    // the port is always written
    const port_at = if (text.len > 0 and text[0] == '[') std.mem.indexOf(u8, text, "]:") else std.mem.indexOfScalar(u8, text, ':');
    if (port_at == null) return null;
    const ip = std.Io.net.IpAddress.parseLiteral(text) catch return null;
    switch (ip) {
        .ip4 => |x| if (std.mem.allEqual(u8, &x.bytes, 0)) return null,
        .ip6 => |x| {
            if (std.mem.allEqual(u8, &x.bytes, 0)) return null;
            if (std.mem.allEqual(u8, x.bytes[0..10], 0) and x.bytes[10] == 0xff and x.bytes[11] == 0xff) return null;
        },
    }
    return ip;
}

/// A stored secret's name: a-z, 0-9, `-` and `_`, starting with a letter
/// or digit, at most 64 (as `harness secret add` takes it).
fn secretName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// The format provider `name` speaks: its section's api, else its
/// preset's; null when there is no such provider.
fn voiceApi(cfg: Config, name: []const u8) ?model.Api {
    for (cfg.providers) |p| if (std.mem.eql(u8, p.name, name)) if (p.api) |api| return api;
    for (model.presets) |pr| if (std.mem.eql(u8, pr.name, name)) return pr.api;
    return null;
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
        error.BadVoice => "[voice] provider = openai or a [provider NAME] section with api = openai (Groq, a whisper.cpp server), model = its transcription model (whisper-large-v3-turbo at Groq, gpt-4o-mini-transcribe at OpenAI), language = a two-letter code (pl) or nothing",
        error.BadVoiceAgent => "[voice_agent] listen = an IP address of this machine and a port, like 127.0.0.1:8765 or 192.168.1.20:8765 (not a name, not 0.0.0.0 or ::), or off; seconds = 5 to 60; token = a stored secret's name (a-z, 0-9, - and _)",
        error.BadDesk => "[desk] avatar = a folder name in avatars/ (a-z, 0-9, -), speak = off, browser, or a provider whose api is openai (with speak_model and speak_voice)",
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
            } else if (comptime std.mem.eql(u8, fname, "remind") or std.mem.eql(u8, fname, "bedtime") or std.mem.eql(u8, fname, "evening")) {
                @field(sec.*, fname) = if (std.ascii.eqlIgnoreCase(l.value, "off")) null else parseClock(l.value) catch return error.BadConfig;
            } else if (comptime std.mem.eql(u8, fname, "quiet")) {
                @field(sec.*, fname) = if (std.ascii.eqlIgnoreCase(l.value, "off")) null else parseQuiet(l.value) catch return error.BadConfig;
            } else if (comptime std.mem.eql(u8, fname, "escalate")) {
                // `parse` reads it (it needs the arena)
                return error.BadConfig;
            } else if (comptime T == Config.Butler and (std.mem.eql(u8, fname, "travel") or std.mem.eql(u8, fname, "away_after") or std.mem.eql(u8, fname, "airport"))) {
                @field(sec.*, fname) = parseMinutes(l.value) orelse return error.BadConfig;
            } else if (comptime T == Config.Butler and std.mem.eql(u8, fname, "warm_below")) {
                // °C, from -40 to 25: "3", "-2.5", "3 °C"
                var v = std.mem.trim(u8, l.value, " \t");
                if (std.mem.endsWith(u8, v, "°C")) v = std.mem.trim(u8, v[0 .. v.len - "°C".len], " \t");
                const x = std.fmt.parseFloat(f64, v) catch return error.BadConfig;
                if (!(x >= -40 and x <= 25)) return error.BadConfig;
                @field(sec.*, fname) = x;
            } else if (comptime T == Config.Butler and (std.mem.eql(u8, fname, "away_temp") or std.mem.eql(u8, fname, "home_temp"))) {
                const x = std.fmt.parseInt(u32, l.value, 10) catch return error.BadConfig;
                if (x < 10 or x > 28) return error.BadConfig;
                @field(sec.*, fname) = x;
            } else if (comptime T == Config.Butler and (std.mem.eql(u8, fname, "maps") or std.mem.eql(u8, fname, "flight_status"))) {
                // SERVER/TOOL
                const slash = std.mem.indexOfScalar(u8, l.value, '/') orelse return error.BadConfig;
                if (slash == 0 or slash + 1 == l.value.len or std.mem.indexOfAny(u8, l.value, " \t") != null) return error.BadConfig;
                @field(sec.*, fname) = l.value;
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

/// "30m", "45 min", "1h", "1h30m", "1 h 30 min", "20" → minutes (1 to
/// 24 hours); null for anything else.
pub fn parseMinutes(v: []const u8) ?u32 {
    var total: u32 = 0;
    var num: ?u32 = null;
    var any = false;
    var i: usize = 0;
    while (i < v.len) {
        const ch = v[i];
        if (ch == ' ' or ch == '\t') {
            i += 1;
            continue;
        }
        if (std.ascii.isDigit(ch)) {
            if (num != null) return null;
            var j = i;
            while (j < v.len and std.ascii.isDigit(v[j])) j += 1;
            num = std.fmt.parseInt(u32, v[i..j], 10) catch return null;
            i = j;
            continue;
        }
        if (!std.ascii.isAlphabetic(ch)) return null;
        var j = i;
        while (j < v.len and std.ascii.isAlphabetic(v[j])) j += 1;
        const w = v[i..j];
        i = j;
        const n = num orelse return null;
        num = null;
        if (std.ascii.eqlIgnoreCase(w, "h") or std.ascii.eqlIgnoreCase(w, "hour") or std.ascii.eqlIgnoreCase(w, "hours")) {
            total += n * 60;
        } else if (std.ascii.eqlIgnoreCase(w, "m") or std.ascii.eqlIgnoreCase(w, "min") or std.ascii.eqlIgnoreCase(w, "minutes")) {
            total += n;
        } else return null;
        any = true;
    }
    if (num) |n| {
        // a number alone is minutes
        if (any) return null;
        total = n;
        any = true;
    }
    if (!any or total == 0 or total > 24 * 60) return null;
    return total;
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

    /// A copy whose every slice is in `a` (a background run's own).
    pub fn clone(b: Brief, a: std.mem.Allocator) !Brief {
        const topics = try a.alloc(Topic, b.topics.len);
        for (b.topics, topics) |tp, *o| o.* = .{ .name = try a.dupe(u8, tp.name), .feeds = try dupeList(a, tp.feeds), .searches = try dupeList(a, tp.searches) };
        return .{ .name = try a.dupe(u8, b.name), .at_minutes = b.at_minutes, .topics = topics, .to = try a.dupe(u8, b.to) };
    }
};

fn dupeList(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

/// briefs.ini, read by the one parser of tasks.ini, briefs.ini and
/// triggers.ini (triggers.zig): at, to, topic lines.
pub fn parseBriefs(arena: std.mem.Allocator, text: []const u8) Error![]Brief {
    var d: triggers.Diag = .{};
    const list = triggers.parse(arena, text, .briefs, &d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadTrigger => error.BadConfig,
    };
    return triggers.briefsOf(arena, list);
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
    /// A schedule of triggers.ini may say a fixed text instead of `do`
    /// (no model call), or start a workflow (its name).
    say: []const u8 = "",
    start: []const u8 = "",
    /// The text a schedule's workflow starts with (`start = workflow NAME TEXT`).
    start_input: []const u8 = "",
    /// It is a schedule of triggers.ini, not a task of tasks.ini.
    in_triggers: bool = false,
    /// `do_file = NAME.md`: `do` is read from tasks/NAME.md (taskfiles.zig).
    do_file: []const u8 = "",

    /// A copy whose every slice is in `a` (a background run's own).
    pub fn clone(tk: Task, a: std.mem.Allocator) !Task {
        var o = tk;
        inline for (.{ "name", "do", "to", "agent", "say", "start", "start_input", "do_file" }) |f| @field(o, f) = try a.dupe(u8, @field(tk, f));
        return o;
    }
};

pub const day_names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

/// tasks.ini, read by the one parser of tasks.ini, briefs.ini and
/// triggers.ini (triggers.zig): at, every, days, do, to, agent.
pub fn parseTasks(arena: std.mem.Allocator, text: []const u8) Error![]Task {
    var d: triggers.Diag = .{};
    const list = triggers.parse(arena, text, .tasks, &d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadTrigger => error.BadConfig,
    };
    return triggers.tasksOf(arena, list);
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
    \\summaries = on                      ; by day, week and month, in the prompt: a small model call per active conversation a day
    \\; summary_model = claude-haiku       ; their model; default memory_model
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
    \\max_per_day = 0                     ; everything spent in a day, yours and routines'
    \\budget_per_day = 0                  ; what routines may spend without asking you; 0 = none set
    \\budget_per_month = 0                ; routines spend only while a budget is above 0
    \\scheduled = on                      ; on: scheduled runs may move money, within the caps and the budget
    \\triggers = on                       ; on: runs a trigger starts move money as scheduled = says; off: never
    \\workflows = on                      ; on: agent steps of workflows move money as scheduled = says; off: never (tool steps are asked every time)
    \\apps = off                          ; on: runs an app starts move money as scheduled = says; off: never (an app's own acts never do)
    \\
    \\[apps]                              ; apps in your browser, on this machine only
    \\on = on
    \\port = 0                            ; the desk finds harness here; 0: harness picks a free one and writes it here
    \\act_seconds = 120                   ; the longest one act an app asks for may take
    \\runs_per_hour = 20                  ; runs an app may start in an hour
    \\
    \\[inbox]                             ; what waits for you (/inbox)
    \\questions = 20                      ; questions and approvals waiting at once
    \\remind = 09:00                      ; once a day, if something waited over 12 hours; off: never
    \\
    \\[triggers]                          ; event triggers (triggers.ini)
    \\; check_model = claude-haiku         ; the model of check = lines; default worker_model
    \\checks_per_day = 200                ; check questions a day, all triggers together
    \\runs_per_hour = 20                  ; runs triggers start, all together
    \\runs_per_day = 100
    \\queue = 200                         ; events waiting per trigger; past it the trigger pauses
    \\
    \\[workflows]                         ; workflows (workflows/NAME.wf)
    \\instances = 50                      ; instances going at once, all workflows; past it a start is refused
    \\agent_steps_per_day = 100           ; agent steps a day, all workflows; past it they wait for the next day
    \\
    \\[voice]                             ; voice notes in Telegram (README: Voice notes)
    \\; provider = groq                    ; openai, or a [provider NAME] with api = openai (Groq, a local whisper.cpp)
    \\; model = whisper-large-v3-turbo
    \\; language = pl                      ; the language you speak; empty: found by the service
    \\
    \\[desk]                              ; the desk, harness's own window (README: Desk)
    \\echo = on                           ; Telegram gets a quiet echo of what you type on the desk
    \\avatar = butler                     ; a folder in avatars/
    \\speak = off                         ; replies read aloud: off, browser, or a provider with api = openai
    \\speak_model = tts-1                 ; that provider's speech model and voice
    \\speak_voice = alloy
    \\
    \\[butler]
    \\; quiet = 22:00-07:00                ; quiet hours, your time: posts of schedules, triggers and workflows wait for a digest
    \\; homemcp = /usr/local/bin/homemcp   ; /setup home runs it; default: next to harness, else on PATH
    \\; carcloud = /usr/local/bin/carcloud ; /setup car runs it; the same
    \\; escalate = 5m anna, 15m piotr      ; an urgent alert you don't answer goes to these members in turn
    \\; calmcp = /usr/local/bin/calmcp     ; /setup calendar runs it; the same
    \\; travel = 30m                      ; how long before an event with a place the diary says it's time to leave
    \\; maps = maps/travel_time           ; a maps MCP server's tool that gives the travel time instead
    \\; warm_below = 5                    ; °C at the car: below it, the warm-car routine asks to warm it before a morning leave-by
    \\; bedtime = 23:30                   ; after it, your first message of the night gets one gentle line (/bedtime)
    \\; evening = 21:00                   ; one message about tomorrow (/evening): the first event, the weather, the car, bills, the inbox
    \\; away_after = 12h                  ; everyone out this long and away mode comes on (README: Away and travel)
    \\; away_temp = 17                    ; the heating while you're away (asked once), °C
    \\; home_temp = 21                    ; the heating to come home to, °C
    \\; airport = 2h                      ; how long before a flight to be at the airport
    \\; flight_status = flights/flight_status ; a flight-status MCP server's tool; none: no status is claimed
    \\
    \\[voice_agent]                       ; Home Assistant's voice assistant answered by harness (README: Home Assistant's voice)
    \\; listen = 192.168.1.20:8765         ; for Home Assistant on another machine: this one's LAN address (default: this machine only)
    \\; token = ha-agent                   ; the secret Home Assistant's API key must be: harness secret add ha-agent
    \\; seconds = 20                       ; a spoken answer's time
    \\
    \\[mail]                              ; mail (README: Mail); /setup mail writes it
    \\; owner = me@example.com             ; your addresses: only your mail to the butler's address is a message
    \\; mailmcp = /usr/local/bin/mailmcp   ; /setup mail runs it; default: next to harness, else on PATH
    \\; others_at = 18:00                  ; when the day's line about others' mail to the butler comes
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
    \\# agent_save (a new agent definition, or a change to the agent's own),
    \\# trigger add (a trigger the agent proposes) and workflow save (a
    \\# workflow it proposes) are asked every time, whatever the rules; a deny
    \\# rule stops them; trigger rm, workflow start and workflow stop ask.
    \\# app_save (an app the agent built) and env_save (an environment it
    \\# proposes) are asked every time, whatever the rules; a deny rule stops
    \\# them. Not used yet (its tool comes later): mail asks.
    \\# A line [agent:NAME], [owner], [schedule:NAME], [trigger:NAME] or
    \\# [workflow:NAME] starts rules for those calls only (a workflow's tool
    \\# steps are [workflow:NAME]'s, not a definition's); [all] goes back to
    \\# rules for every call. shell@NAME is for
    \\# commands in environment NAME (host is the only one for now).
    \\# [member] and [member:NAME] are for household members (README:
    \\# Household); for a member, lines outside them only deny or ask.
    \\# [room] and [room:NAME] are for speech in the house through Home
    \\# Assistant's voice assistant (README: Home Assistant's voice), the
    \\# same way: [room:living_room] for one room.
    \\# [harness:NAME] is for harness's own jobs ([harness:away]: away
    \\# mode's lights); no task, brief or schedule of yours is ever one.
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

pub const triggers_example =
    \\; Triggers: an event source with a filter; a match starts a run (do),
    \\; says a line without the model (say), or starts a workflow (start).
    \\; A section's keys give its kind: feed = URL, search = WORDS,
    \\; page = URL (json = PATH for a value), file = FOLDER/PATTERN,
    \\; mcp = SERVER resource URI or SERVER/TOOL {"json": "input"} (key = FIELD);
    \\; every or at alone is a schedule, topic lines a brief.
    \\; Then: every (feed 1h, search 6h, page 1h, file 1m, mcp 15m) or at
    \\; (+ days); match = FIELD OP VALUE (each must hold), skip = FIELD OP
    \\; VALUE; check = a yes/no question for the model; one of do, say
    \\; ({field} filled in) and start = workflow NAME; agent, tools, to,
    \\; max_runs (6 an hour), max_events (20 a run), checks_per_day (50).
    \\; A first poll only marks what is there. README: Triggers.
    \\;
    \\; [btc]
    \\; page = https://api.coinbase.com/v2/prices/BTC-USD/spot
    \\; json = data.amount
    \\; every = 5m
    \\; match = move > 3
    \\; say = BTC {value} ({change}% since the last message)
    \\
;

pub const tasks_example =
    \\; Scheduled tasks: the agent runs `do` at a time (`at`, optional `days`)
    \\; or every N minutes (`every = 15m`, at least 5m). Its answer is sent to
    \\; you unless it is NOTHING; to = NAME posts it to that conversation
    \\; (default main, the private chat; a new name opens that topic);
    \\; agent = NAME runs it as that definition (default main, agents/).
    \\; do_file = NAME.md instead of do: the instructions are the file
    \\; tasks/NAME.md, read whole (several lines, ; and # kept).
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

test "memory_reads_summaries_and_their_model" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // on, with the memory model, unless config.ini says otherwise
    const d = try parse(a, "");
    try t.expect(d.memory.summaries);
    try t.expectEqualStrings("", d.memory.summary_model);
    const c = try parse(a, "[memory]\nsummaries = off\nsummary_model = anthropic:claude-haiku-4-5\n");
    try t.expect(!c.memory.summaries);
    try t.expectEqualStrings("anthropic:claude-haiku-4-5", c.memory.summary_model);
    try t.expectError(error.BadConfig, parse(a, "[memory]\nsummaries = sometimes\n"));
    try t.expect(std.mem.indexOf(u8, defaults_ini, "summaries = on") != null);
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
    // on by default: with no budget nothing moves unattended
    try t.expect(d.money.scheduled);
    try t.expectEqual(0, d.money.budget_per_day);
    try t.expectEqual(0, d.money.budget_per_month);
    const c = try parse(arena.allocator(), "[model]\nworker_model = tiny\n[agents]\nparallel = 2\n[browser]\npath = /opt/chrome\n[money]\nmax_per_call = 100\nmax_per_day = 500\nscheduled = on\n");
    try t.expectEqualStrings("tiny", c.model.worker_model);
    try t.expectEqual(2, c.agents.parallel);
    try t.expectEqualStrings("/opt/chrome", c.browser.path);
    try t.expectEqual(100, c.money.max_per_call);
    try t.expectEqual(500, c.money.max_per_day);
    try t.expect(c.money.scheduled);
    _ = try parse(arena.allocator(), defaults_ini);
}

test "budgets_are_read_from_money" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, "[money]\nbudget_per_day = 30\nbudget_per_month = 200\n");
    try t.expectEqual(30, c.money.budget_per_day);
    try t.expectEqual(200, c.money.budget_per_month);
    // 0: limits nothing on its own
    try t.expectEqual(0, (try parse(a, "[money]\nbudget_per_day = 0\n")).money.budget_per_day);
    try t.expectError(error.BadConfig, parse(a, "[money]\nbudget_per_day = lots\n"));
    // the shipped file says each key, so an upgrade can tell it from an old one
    try t.expect(std.mem.indexOf(u8, defaults_ini, "\nbudget_per_day = 0") != null);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "\nscheduled = on") != null);
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

test "old_task_and_brief_files_run_as_before" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // read by the one parser of the three files, the same tasks and briefs
    const ts = try parseTasks(a, "; a comment\n[btc-watch]\nevery = 15m\ndo = Check the price.\nto = house-search\n[weekly review]\nat = 18:00\ndays = fri\nagent = researcher\ndo = Summarise.\n");
    try t.expectEqual(2, ts.len);
    try t.expectEqualStrings("btc-watch", ts[0].name);
    try t.expectEqual(15, ts[0].every_minutes.?);
    try t.expectEqual(null, ts[0].at_minutes);
    try t.expectEqualStrings("Check the price.", ts[0].do);
    try t.expectEqualStrings("house-search", ts[0].to);
    try t.expectEqualStrings("main", ts[0].agent);
    try t.expectEqualStrings("", ts[0].say);
    try t.expect(!ts[0].in_triggers);
    // a name 0.3 allowed still reads
    try t.expectEqualStrings("weekly review", ts[1].name);
    try t.expectEqual(18 * 60, ts[1].at_minutes.?);
    try t.expectEqual(0b0010000, ts[1].days);
    try t.expectEqualStrings("researcher", ts[1].agent);
    // the keys tasks.ini takes, and no others
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m\nsay = hi\n"));
    try t.expectError(error.BadConfig, parseTasks(a, "[x]\nevery = 5m\nfeed = https://z.org/f\ndo = y\n"));
    try t.expectError(error.BadConfig, parseTasks(a, "every = 5m\n[x]\ndo = y\n"));
    try t.expectError(error.BadConfig, parseTasks(a, "[a]\nevery = 5m\ndo = y\n[b]\nevery = 5m\ndo = y\n[a]\ndo = z\n"));
    const bs = try parseBriefs(a, "[morning]\ntopic = Zig | https://ziglang.org/news/index.xml\n[Evening News]\nat = 19:30\nto = news\n");
    try t.expectEqual(2, bs.len);
    try t.expectEqual(7 * 60, bs[0].at_minutes);
    try t.expectEqual(1, bs[0].topics.len);
    try t.expectEqualStrings("Evening News", bs[1].name);
    try t.expectEqual(0, bs[1].topics.len);
    try t.expectEqualStrings("news", bs[1].to);
    try t.expectError(error.BadConfig, parseBriefs(a, "[m]\nevery = 5m\n"));
    // a clone shares nothing with the settings it came from
    var other: std.heap.ArenaAllocator = .init(t.allocator);
    const tk = try ts[0].clone(other.allocator());
    const br = try bs[0].clone(other.allocator());
    arena.deinit();
    arena = .init(t.allocator);
    try t.expectEqualStrings("btc-watch", tk.name);
    try t.expectEqualStrings("Check the price.", tk.do);
    try t.expectEqualStrings("https://ziglang.org/news/index.xml", br.topics[0].feeds[0]);
    other.deinit();
}

test "trigger_and_money_settings_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "");
    try t.expectEqualStrings("", d.triggers.check_model);
    try t.expectEqual(200, d.triggers.checks_per_day);
    try t.expectEqual(20, d.triggers.runs_per_hour);
    try t.expectEqual(100, d.triggers.runs_per_day);
    try t.expectEqual(200, d.triggers.queue);
    try t.expect(d.money.triggers);
    const c = try parse(a, "[triggers]\ncheck_model = tiny\nqueue = 5\n[money]\ntriggers = off\n");
    try t.expectEqualStrings("tiny", c.triggers.check_model);
    try t.expectEqual(5, c.triggers.queue);
    try t.expect(!c.money.triggers);
    try t.expectError(error.BadConfig, parse(a, "[triggers]\nqueue = 0\n"));
    try t.expectEqualDeep(d.triggers, (try parse(a, defaults_ini)).triggers);
    try t.expectEqualDeep(d.money, (try parse(a, defaults_ini)).money);
}


test "workflow_settings_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "");
    try t.expectEqual(50, d.workflows.instances);
    try t.expectEqual(100, d.workflows.agent_steps_per_day);
    try t.expect(d.money.workflows);
    const c = try parse(a, "[workflows]\ninstances = 5\nagent_steps_per_day = 7\n[money]\nworkflows = off\n");
    try t.expectEqual(5, c.workflows.instances);
    try t.expectEqual(7, c.workflows.agent_steps_per_day);
    try t.expect(!c.money.workflows);
    try t.expectError(error.BadConfig, parse(a, "[workflows]\ninstances = 0\n"));
    try t.expectEqualDeep(d.workflows, (try parse(a, defaults_ini)).workflows);
    try t.expectEqualDeep(d.money, (try parse(a, defaults_ini)).money);
}

test "voice_settings_read_and_checked" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // off until set; harness init's file says the same
    const d = try parse(a, "");
    try t.expectEqualStrings("", d.voice.provider);
    try t.expectEqualDeep(d.voice, (try parse(a, defaults_ini)).voice);
    // Groq as a section of its own, or OpenAI's preset
    const g = try parse(a, "[voice]\nprovider = groq\nmodel = whisper-large-v3-turbo\nlanguage = pl\n[provider groq]\napi = openai\nurl = https://api.groq.com/openai/v1\n");
    try t.expectEqualStrings("groq", g.voice.provider);
    try t.expectEqualStrings("whisper-large-v3-turbo", g.voice.model);
    try t.expectEqualStrings("pl", g.voice.language);
    const o = try parse(a, "[voice]\nprovider = openai\nmodel = gpt-4o-mini-transcribe\n");
    try t.expectEqualStrings("", o.voice.language);
    // a preset made to speak OpenAI's format may be one
    _ = try parse(a, "[provider omnigate]\napi = openai\n[voice]\nprovider = omnigate\nmodel = whisper-1\n");
    // refused: no such provider, one that speaks only Anthropic's format,
    // no model, a language that is not a code
    for ([_][]const u8{
        "[voice]\nprovider = nowhere\nmodel = m\n",
        "[voice]\nprovider = anthropic\nmodel = m\n",
        "[voice]\nprovider = omnigate\nmodel = m\n",
        "[provider proxy]\napi = anthropic\nurl = https://p.example.com/v1\n[voice]\nprovider = proxy\nmodel = m\n",
        "[voice]\nprovider = openai\n",
        "[voice]\nprovider = openai\nmodel = m\nlanguage = Polish\n",
    }) |text| try t.expectError(error.BadVoice, parse(a, text));
    try t.expect(reason(error.BadVoice) != null);
    // named at its line, with why
    const why = (try @import("core.zig").parseProblem(a, "config.ini", "[voice]\nprovider = anthropic\nmodel = m\n", parse)).?;
    if (!std.mem.startsWith(u8, why, "config.ini line 2 has an error: provider = anthropic ([voice] provider = ")) {
        std.debug.print("got: {s}\n", .{why});
        return error.TestUnexpectedResult;
    }
}

test "desk_section_reads_and_checks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "");
    try t.expect(d.desk.echo);
    try t.expectEqualStrings("butler", d.desk.avatar);
    try t.expectEqualStrings("off", d.desk.speak);
    try t.expectEqualStrings("tts-1", d.desk.speak_model);
    try t.expectEqualStrings("alloy", d.desk.speak_voice);
    try t.expectEqualDeep(d.desk, (try parse(a, defaults_ini)).desk);
    const b = try parse(a, "[desk]\necho = off\navatar = my-face\nspeak = browser\n");
    try t.expect(!b.desk.echo);
    try t.expectEqualStrings("my-face", b.desk.avatar);
    try t.expectEqualStrings("browser", b.desk.speak);
    _ = try parse(a, "[desk]\nspeak = openai\n");
    _ = try parse(a, "[provider tts]\napi = openai\nurl = https://tts.example.com/v1\n[desk]\nspeak = tts\nspeak_voice = onyx\n");
    for ([_][]const u8{
        "[desk]\nspeak = anthropic\n",
        "[desk]\nspeak = nowhere\n",
        "[desk]\navatar = Bad Name\n",
        "[desk]\navatar = ../x\n",
    }) |text| try t.expectError(error.BadDesk, parse(a, text));
    // an empty value is any section's error
    try t.expectError(error.BadConfig, parse(a, "[desk]\navatar = \n"));
    try t.expect(reason(error.BadDesk) != null);
}

test "butler_escalate_reads" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // none until set; harness init's file has the line as a comment
    try t.expectEqual(0, (try parse(a, "")).butler.escalate.len);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "; escalate = 5m anna, 15m piotr") != null);
    const c = try parse(a, "[butler]\nescalate = 5m anna, 15m piotr\n");
    try t.expectEqual(2, c.butler.escalate.len);
    try t.expectEqual(900, c.butler.escalate[1].after_s);
    try t.expectEqualStrings("piotr", c.butler.escalate[1].member);
    try t.expectEqual(0, (try parse(a, "[butler]\nescalate = no\n")).butler.escalate.len);
    for ([_][]const u8{ "5m", "anna", "15m piotr, 5m anna", "" }) |v| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\nescalate = {s}\n", .{v})));
    }
}

test "butler_quiet_reads_hours_or_off" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // off until set; harness init's file has the line as a comment
    const d = try parse(a, "");
    try t.expect(d.butler.quiet == null);
    try t.expectEqualDeep(d.butler, (try parse(a, defaults_ini)).butler);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "; quiet = 22:00-07:00") != null);
    const c = try parse(a, "[butler]\nquiet = 22:00-07:00\n");
    try t.expectEqual(22 * 60, c.butler.quiet.?.start);
    try t.expectEqual(7 * 60, c.butler.quiet.?.end);
    // as the README writes it, with spaces or an en dash
    try t.expectEqual(13 * 60 + 30, (try parse(a, "[butler]\nquiet = 13:30 – 15:00\n")).butler.quiet.?.start);
    try t.expect((try parse(a, "[butler]\nquiet = off\n")).butler.quiet == null);
    for ([_][]const u8{ "22:00", "22:00-22:00", "25:00-07:00", "22-07", "22:00-07:00-08:00", "" }) |v| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\nquiet = {s}\n", .{v})));
    }
}

test "butler_travel_maps_and_calmcp_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 30 minutes unless set; the lines are comments in harness init's file
    try t.expectEqual(@as(u32, 30), (try parse(a, "")).butler.travel);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "; travel = 30m") != null);
    for ([_]struct { []const u8, u32 }{ .{ "45m", 45 }, .{ "45 min", 45 }, .{ "1h", 60 }, .{ "1h30m", 90 }, .{ "1 h 30 min", 90 }, .{ "20", 20 } }) |c| {
        try t.expectEqual(c[1], (try parse(a, try std.fmt.allocPrint(a, "[butler]\ntravel = {s}\n", .{c[0]}))).butler.travel);
    }
    for ([_][]const u8{ "fast", "0m", "25h", "-5m" }) |v| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\ntravel = {s}\n", .{v})));
    }
    const c = try parse(a, "[butler]\nmaps = maps/travel_time\ncalmcp = /opt/calmcp\n");
    try t.expectEqualStrings("maps/travel_time", c.butler.maps);
    try t.expectEqualStrings("/opt/calmcp", c.butler.calmcp);
    try t.expectError(error.BadConfig, parse(a, "[butler]\nmaps = travel_time\n"));
}

test "butler_warm_below_reads" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 5 °C unless set; the line is a comment in harness init's file
    try t.expectEqual(@as(f64, 5), (try parse(a, "")).butler.warm_below);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "; warm_below = 5") != null);
    for ([_]struct { []const u8, f64 }{ .{ "2", 2 }, .{ "-2.5", -2.5 }, .{ "3 °C", 3 }, .{ "0", 0 } }) |c| {
        try t.expectEqual(c[1], (try parse(a, try std.fmt.allocPrint(a, "[butler]\nwarm_below = {s}\n", .{c[0]}))).butler.warm_below);
    }
    for ([_][]const u8{ "cold", "30", "-41", "5 F" }) |v| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\nwarm_below = {s}\n", .{v})));
    }
}

test "butler_bedtime_and_evening_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // both off until set; harness init's file has them as comments
    const d = try parse(a, "");
    try t.expect(d.butler.bedtime == null);
    try t.expect(d.butler.evening == null);
    try t.expectEqualDeep(d.butler, (try parse(a, defaults_ini)).butler);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "; bedtime = 23:30") != null);
    try t.expect(std.mem.indexOf(u8, defaults_ini, "; evening = 21:00") != null);
    const c = try parse(a, "[butler]\nbedtime = 23:30\nevening = 21:00\n");
    try t.expectEqual(@as(?u16, 23 * 60 + 30), c.butler.bedtime);
    try t.expectEqual(@as(?u16, 21 * 60), c.butler.evening);
    const off = try parse(a, "[butler]\nbedtime = off\nevening = off\n");
    try t.expect(off.butler.bedtime == null and off.butler.evening == null);
    for ([_][]const u8{ "24:00", "23.30", "11pm", "" }) |v| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\nbedtime = {s}\n", .{v})));
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\nevening = {s}\n", .{v})));
    }
}

test "voice_agent_settings_read_and_checked" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // on this machine alone until the owner names a LAN address
    const d = try parse(a, "");
    try t.expectEqualStrings("127.0.0.1:8765", d.voice_agent.listen);
    try t.expectEqualStrings("ha-agent", d.voice_agent.token);
    try t.expectEqual(20, d.voice_agent.seconds);
    try t.expectEqualStrings("", d.voice_agent.model);
    try t.expectEqualDeep(d.voice_agent, (try parse(a, defaults_ini)).voice_agent);
    const lan = try parse(a, "[voice_agent]\nlisten = 192.168.1.20:8765\nseconds = 30\nmodel = anthropic:claude-haiku-4-5\n");
    try t.expectEqualStrings("192.168.1.20:8765", lan.voice_agent.listen);
    try t.expectEqual(30, lan.voice_agent.seconds);
    try t.expectEqual(8765, parseListen(lan.voice_agent.listen).?.ip4.port);
    try t.expectEqual(8765, parseListen("[::1]:8765").?.ip6.port);
    try t.expectEqualStrings("off", (try parse(a, "[voice_agent]\nlisten = off\n")).voice_agent.listen);
    // a name, every address, no port, a time out of range: refused
    for ([_][]const u8{
        "listen = homeassistant.local:8765", "listen = 0.0.0.0:8765", "listen = [::]:8765",
        "listen = 192.168.1.20",             "listen = ::1:8765",     "listen = 192.168.1.20:99999",
        "seconds = 3",                       "seconds = 90",          "token = Bad Name",
        // an IPv4 address in IPv6's clothes: every IPv4 address, maybe
        "listen = [::ffff:0.0.0.0]:8765",    "listen = [::ffff:192.168.1.20]:8765",
    }) |line| {
        const text = try std.fmt.allocPrint(a, "[voice_agent]\n{s}\n", .{line});
        if (parse(a, text)) |_| {
            std.debug.print("read: {s}\n", .{line});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    const why = (try @import("core.zig").parseProblem(a, "config.ini", "[voice_agent]\nlisten = 0.0.0.0:8765\n", parse)).?;
    try t.expect(std.mem.indexOf(u8, why, "an IP address of this machine and a port") != null);
}

test "butler_away_and_travel_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // away after 12 hours out, 17 °C while away, 21 °C to come home to, at
    // the airport 2 hours before a flight; no flight status unless set
    const d = (try parse(a, "")).butler;
    try t.expectEqual(@as(u32, 12 * 60), d.away_after);
    try t.expectEqual(@as(u32, 17), d.away_temp);
    try t.expectEqual(@as(u32, 21), d.home_temp);
    try t.expectEqual(@as(u32, 120), d.airport);
    try t.expectEqualStrings("", d.flight_status);
    for ([_][]const u8{ "; away_after = 12h", "; away_temp = 17", "; home_temp = 21", "; airport = 2h", "; flight_status = flights/flight_status" }) |line| try t.expect(std.mem.indexOf(u8, defaults_ini, line) != null);
    const c = (try parse(a, "[butler]\naway_after = 8h\naway_temp = 16\nhome_temp = 22\nairport = 1h30m\nflight_status = flights/status\n")).butler;
    try t.expectEqual(@as(u32, 8 * 60), c.away_after);
    try t.expectEqual(@as(u32, 16), c.away_temp);
    try t.expectEqual(@as(u32, 22), c.home_temp);
    try t.expectEqual(@as(u32, 90), c.airport);
    try t.expectEqualStrings("flights/status", c.flight_status);
    for ([_][]const u8{ "away_after = soon", "away_temp = 40", "home_temp = 3", "airport = 0m", "flight_status = status" }) |v| {
        try t.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "[butler]\n{s}\n", .{v})));
    }
}
