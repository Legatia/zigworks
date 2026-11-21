//! The instance's settings: config.ini (model, chat, limits, memory),
//! briefs.ini (topics and their sources) and tasks.ini (scheduled
//! instructions). All three are small INI files: `[section]`,
//! `key = value`, comments after `;` or `#`.
const std = @import("std");

pub const Error = error{ BadConfig, OutOfMemory };

pub const Config = struct {
    model: Model = .{},
    search: Search = .{},
    chat: Chat = .{},
    limits: Limits = .{},
    memory: Memory = .{},
    agents: Agents = .{},
    browser: Browser = .{},
    money: Money = .{},

    pub const Model = struct {
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
fn stripComment(raw: []const u8) []const u8 {
    for (raw, 0..) |c, i| {
        if ((c == ';' or c == '#') and (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) return raw[0..i];
    }
    return raw;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Config {
    var cfg: Config = .{};
    for (try lines(arena, text)) |l| {
        var found = false;
        inline for (@typeInfo(Config).@"struct".field_names) |sname| {
            if (std.mem.eql(u8, l.section, sname)) {
                found = true;
                try setField(&@field(cfg, sname), l);
            }
        }
        if (!found) return error.BadConfig;
    }
    return cfg;
}

fn setField(sec: anytype, l: Line) Error!void {
    const T = @TypeOf(sec.*);
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, l.key, fname)) {
            if (comptime std.mem.eql(u8, fname, "utc_offset")) {
                @field(sec.*, fname) = parseOffset(l.value) catch return error.BadConfig;
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
        } else return error.BadConfig;
    }
    for (tasks.items) |tk| {
        if (tk.do.len == 0) return error.BadConfig;
        if ((tk.at_minutes == null) == (tk.every_minutes == null)) return error.BadConfig;
    }
    return tasks.items;
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
    \\url =                               ; required: your omnigate's address, like https://omnigate.example.com
    \\model = claude-sonnet               ; omnigate route for the agent
    \\memory_model = claude-haiku         ; omnigate route for writing memories
    \\worker_model = claude-haiku         ; omnigate route for helpers (delegate)
    \\key = omnigate                      ; secret holding the omnigate key
    \\max_tokens = 4096
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
;

pub const rules_example =
    \\# Gate rules: allow | ask | deny, a tool, a pattern (* matches anything).
    \\# A matching deny always wins; otherwise the first matching line decides;
    \\# otherwise the tool's default (shell: ask, fetch: ask, others: allow).
    \\#
    \\# deny  shell rm -rf *
    \\# allow fetch https://news.ycombinator.com/*
    \\# allow shell git status
    \\
;

pub const briefs_example =
    \\; Briefs: when to send, and topics with their sources.
    \\; topic = Name | feed URL | search: words
    \\;
    \\; [morning]
    \\; at = 07:00
    \\; topic = Zig | https://ziglang.org/news/index.xml | search: zig release
    \\
;

pub const tasks_example =
    \\; Scheduled tasks: the agent runs `do` at a time (`at`, optional `days`)
    \\; or every N minutes (`every = 15m`, at least 5m). Its answer is sent to
    \\; you unless it is NOTHING.
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
