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
const Io = std.Io;

pub const Answer = enum { once, day, deny, timeout };

/// Asks the owner whether a call may run; blocks until they answer or the
/// approval time runs out.
pub const Asker = struct {
    ctx: *anyopaque,
    /// `allow_day`: whether "Allow 24 h" may be offered (never for money).
    ask: *const fn (ctx: *anyopaque, what: []const u8, allow_day: bool) Answer,
};

/// A conversation, kept as whole turns so the oldest can be dropped
/// without leaving a tool result without its call.
pub const Conversation = struct {
    gpa: std.mem.Allocator,
    turns: std.ArrayList(*Turn) = .empty,
    /// Turns dropped to stay under the size limit.
    dropped: usize = 0,
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
    private: bool = false,
    auto_recall: bool = true,
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
    /// Tools of the MCP servers that are running.
    mcp: []const McpTool = &.{},
    money: config.Config.Money = .{},
    /// What money tools moved today; shared by all runs.
    money_ledger: ?*MoneyLedger = null,
    /// /dryrun on: money tools are not called.
    dry_run: bool = false,

    fn now(r: *const Run) i64 {
        return util.nowSeconds(r.io);
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
            // offered once its module is wired in
            .browse => return false,
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
    /// The input field holding the amount, for money tools.
    amount: []const u8,
};

pub fn mcpTools(arena: std.mem.Allocator, s: *mcp.Server, money: []const []const u8, amount: []const u8) ![]McpTool {
    var out: std.ArrayList(McpTool) = .empty;
    for (s.tools()) |tl| {
        var is_money = false;
        for (money) |m| if (std.mem.eql(u8, m, tl.name)) {
            is_money = true;
        };
        const name = try std.fmt.allocPrint(arena, "{s}__{s}", .{ tl.server, tl.name });
        if (name.len > 64) continue;
        const desc = if (is_money) try std.fmt.allocPrint(arena, "{s} (Moves money: the owner approves every call.)", .{tl.description}) else tl.description;
        try out.append(arena, .{ .def = .{ .name = name, .description = desc, .schema_json = tl.schema_json }, .server = s, .tool = tl.name, .money = is_money, .amount = amount });
    }
    return out.items;
}

/// What money tools moved today, in the owner's day.
pub const MoneyLedger = struct {
    mutex: Io.Mutex = .init,
    day: i64 = 0,
    total: f64 = 0,
    /// Where it is kept ("DAY TOTAL"); null in tests.
    path: ?[]const u8 = null,

    pub fn load(l: *MoneyLedger, io: Io) void {
        const p = l.path orelse return;
        var buf: [128]u8 = undefined;
        const got = Io.Dir.cwd().readFile(io, p, &buf) catch return;
        var it = std.mem.tokenizeAny(u8, got, " \n");
        l.day = std.fmt.parseInt(i64, it.next() orelse return, 10) catch return;
        l.total = std.fmt.parseFloat(f64, it.next() orelse return) catch 0;
    }

    fn spent(l: *MoneyLedger, day: i64) f64 {
        return if (l.day == day) l.total else 0;
    }

    fn add(l: *MoneyLedger, io: Io, day: i64, amount: f64) void {
        if (l.day != day) {
            l.day = day;
            l.total = 0;
        }
        l.total += amount;
        const p = l.path orelse return;
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d} {d}\n", .{ l.day, l.total }) catch return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text, .flags = .{ .permissions = util.private_file } }) catch {};
    }
};

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

/// The system prompt in two parts: `stable` stays the same from call to
/// call (it is marked for the prompt cache), `changing` is the rest.
pub const Prompt = struct { stable: []const u8, changing: []const u8 };

pub fn systemPrompt(arena: std.mem.Allocator, r: *const Run, recalled: memory.Recall, dropped: usize, now_s: i64) ![]const u8 {
    const p = try systemParts(arena, r, recalled, null, dropped, now_s);
    return std.mem.concat(arena, u8, &.{ p.stable, p.changing });
}

pub fn systemParts(arena: std.mem.Allocator, r: *const Run, recalled: memory.Recall, summary: ?[]const u8, dropped: usize, now_s: i64) !Prompt {
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
    var pinned_header = false;
    for (recalled.always) |it| if (it.pinned) {
        if (!pinned_header) try out.appendSlice(arena, "\nStanding instructions from the owner (always follow):\n");
        pinned_header = true;
        try out.print(arena, "- {s}\n", .{it.body});
    };
    var top_header = false;
    for (recalled.always) |it| if (!it.pinned) {
        if (!top_header) try out.appendSlice(arena, "\nWhat you know about the owner:\n");
        top_header = true;
        try out.print(arena, "- {s}\n", .{it.body});
    };
    if (summary) |sm| try out.print(arena, "\nSummary of the earlier conversation:\n{s}\n", .{sm});
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
    if (dropped > 0 and summary == null) try out.print(arena, "\n{d} earlier turns of this conversation were dropped to keep it short.\n", .{dropped});
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
        if (from_owner and !r.private) {
            const ids = try r.mem.noteMentions(a, user_text, started);
            for (ids) |id| try r.log.write(.memory, false, .{ .event = "mention", .id = id });
        }
    }
    try r.log.write(.turn, r.private, .{ .run = r.label, .text = user_text });

    const tn = try conv.begin();
    // a turn that fails half way could leave a tool call without its result,
    // which the model API refuses from then on: drop it whole
    errdefer conv.dropLast();
    tn.private = r.private;
    try keep(tn, .{ .role = .user, .blocks = &.{.{ .text = user_text }} });

    var result: TurnResult = .{ .text = "" };
    var used_tokens: u64 = 0;
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
        // one lock for both: the items are read while no one can forget them
        const system = blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            const recalled = try r.mem.recall(a, user_text, r.now(), r.top_size, r.auto_recall);
            break :blk try systemParts(a, r, recalled, conv.summary, conv.dropped, r.now());
        };
        const msgs = try conv.messages(a);
        const reply = r.client.sendParts(a, system.stable, system.changing, msgs, defs) catch |e| {
            const why: []const u8 = switch (e) {
                error.BudgetSpent => "Model budget used up.",
                error.RateLimited => "The model is rate limited; try again later.",
                else => try std.fmt.allocPrint(a, "Model call failed: {s} {s}", .{ @errorName(e), r.client.lastError() }),
            };
            try r.log.write(.model, false, .{ .run = r.label, .result = @errorName(e), .detail = r.client.lastError() });
            result.ended_by = try r.gpa.dupe(u8, why);
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
        for (reply.blocks) |b| {
            if (b != .tool_use) continue;
            const u = b.tool_use;
            const out = try callTool(r, a, u.name, u.input_json);
            try results.append(a, .{ .tool_result = .{ .id = u.id, .content = out.text, .is_error = out.is_error } });
        }
        if (results.items.len == 0) break;
        try keep(tn, .{ .role = .user, .blocks = results.items });
    }
    if (result.ended_by) |why| if (result.text.len == 0 or result.stopped) {
        r.gpa.free(result.text);
        result.text = try r.gpa.dupe(u8, why);
    };
    const dropped = try compact(r, conv);
    try r.log.write(.turn, r.private, .{ .run = r.label, .answer = result.text, .steps = result.steps, .ended_by = result.ended_by, .dropped_turns = dropped });
    return result;
}

/// Frees what `turn` allocated in its result.
pub fn freeResult(r: *Run, res: TurnResult) void {
    r.gpa.free(res.text);
    if (res.ended_by) |w| r.gpa.free(w);
}

fn callTool(r: *Run, a: std.mem.Allocator, name: []const u8, input_json: []const u8) !tools.Output {
    if (r.env.stop.load(.acquire)) return .{ .text = "stopped by the owner", .is_error = true };
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
    const arg = switch (tool) {
        .delegate => delegateArg(a, input_json) catch return .{ .text = "delegate needs a list of 1 to 8 tasks", .is_error = true },
        .mcp, .money => try std.fmt.allocPrint(a, "{s}/{s} {s}", .{ mt.?.server.name, mt.?.tool, util.cut(input_json, 1500) }),
        else => tools.mainArg(a, tool, input_json) catch return .{ .text = "the tool's input is missing its main field", .is_error = true },
    };
    const now_s = r.now();
    var amount: f64 = 0;
    if (tool == .money) {
        if (moneyCheck(r, a, mt.?, input_json, now_s, &amount)) |why| {
            try r.log.write(.gate, r.private, .{ .run = r.label, .tool = name, .decision = "deny", .why = why, .arg = arg });
            return .{ .text = try std.fmt.allocPrint(a, "refused by the gate: {s}", .{why}), .is_error = true };
        }
    }
    const d = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        break :blk r.gate.decide(a, tool, arg, now_s, .{ .scheduled = r.scheduled, .money_unattended = r.money.scheduled });
    };
    var action = d.action;
    var why = d.why;
    if (action == .ask) {
        if (r.asker) |asker| {
            const who = if (r.helper) try std.fmt.allocPrint(a, "[{s}] ", .{r.label}) else "";
            const what = try std.fmt.allocPrint(a, "{s}{s}: {s}", .{ who, name, util.cut(arg, 1500) });
            // helpers working at once still ask one question at a time
            if (r.ask_lock) |l| l.lockUncancelable(r.io);
            var ans = if (r.env.stop.load(.acquire)) Answer.deny else asker.ask(asker.ctx, what, tool != .money);
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
                    try r.gate.grants.add(tool, gate.grantKey(tool, arg), now_s + 86400);
                    if (r.grants_path) |p| r.gate.grants.save(r.io, p, now_s) catch {};
                },
                .deny => {
                    action = .deny;
                    why = "denied by the owner";
                },
                .timeout => {
                    action = .deny;
                    why = "no answer from the owner in time";
                },
            }
        } else {
            action = .deny;
            why = "no one to ask";
        }
    }
    try r.log.write(.gate, r.private, .{ .run = r.label, .tool = name, .decision = @tagName(action), .why = why, .arg = arg });
    if (action != .allow) return .{ .text = try std.fmt.allocPrint(a, "refused by the gate: {s}", .{why}), .is_error = true };

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
            if (r.private) break :blk tools.Output{ .text = "not saved: this conversation is private" };
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            const res = r.mem.add(arg, null, now_s) catch |e| break :blk tools.Output{ .text = @errorName(e), .is_error = true };
            try r.log.write(.memory, false, .{ .event = if (res.merged) "mention" else "add", .id = res.id, .by = "agent" });
            break :blk .{ .text = try std.fmt.allocPrint(a, "saved as {s}", .{res.id}) };
        },
        .delegate => try delegate(r, a, input_json),
        .mcp, .money => try callMcp(r, a, mt.?, arg, input_json, amount),
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
            const out = try tools.run(r.env, a, tool, input_json);
            if (r.cache) |c| if (!out.is_error) c.put(r.io, key, out.text);
            break :blk out;
        },
        else => try tools.run(r.env, a, tool, input_json),
    };
    try r.log.write(.tool, r.private, .{ .run = r.label, .tool = name, .arg = arg, .is_error = out.is_error, .output = out.text });
    return out;
}

// ---- tests ----



// ---- MCP calls and money ----

/// The amount in a money call's input: a number or a numeric string.
fn amountOf(a: std.mem.Allocator, input_json: []const u8, field: []const u8) ?f64 {
    if (field.len == 0) return null;
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

/// Why a money call is refused before anyone is asked, or null.
fn moneyCheck(r: *Run, a: std.mem.Allocator, m: *const McpTool, input_json: []const u8, now_s: i64, amount: *f64) ?[]const u8 {
    const capped = r.money.max_per_call > 0 or r.money.max_per_day > 0;
    const got = amountOf(a, input_json, m.amount);
    if (got) |x| {
        if (x < 0 or std.math.isNan(x)) return "the amount is not a positive number";
        amount.* = x;
    } else if (capped) {
        return std.fmt.allocPrint(a, "no amount in the field \"{s}\", so the caps cannot be checked", .{m.amount}) catch "no amount";
    }
    if (r.money.max_per_call > 0 and amount.* > @as(f64, @floatFromInt(r.money.max_per_call)))
        return std.fmt.allocPrint(a, "{d} is over the cap of {d} per call", .{ amount.*, r.money.max_per_call }) catch "over the cap per call";
    if (r.money.max_per_day > 0) {
        const l = r.money_ledger orelse return "no record of today's total";
        l.mutex.lockUncancelable(r.io);
        defer l.mutex.unlock(r.io);
        const spent = l.spent(moneyDay(r, now_s));
        if (spent + amount.* > @as(f64, @floatFromInt(r.money.max_per_day)))
            return std.fmt.allocPrint(a, "{d} more would be over the cap of {d} per day ({d} so far today)", .{ amount.*, r.money.max_per_day, spent }) catch "over the cap per day";
    }
    return null;
}

fn callMcp(r: *Run, a: std.mem.Allocator, m: *const McpTool, arg: []const u8, input_json: []const u8, amount: f64) !tools.Output {
    if (m.money and r.dry_run) return .{ .text = try std.fmt.allocPrint(a, "dry run: would call {s}", .{arg}) };
    const timeout_ms: u32 = @intCast(@min(@as(u64, r.limits.turn_seconds) * 1000, std.math.maxInt(u32)));
    const res = m.server.call(a, m.tool, input_json, r.env.stop, timeout_ms, r.env.tool_output_bytes) catch |e|
        return .{ .text = try std.fmt.allocPrint(a, "failed: {s}", .{@errorName(e)}), .is_error = true };
    var sc = try scrub.Scrubber.init(a, r.env.secrets);
    const text = try sc.scrubAlloc(a, res.text);
    if (m.money and !res.is_error) if (r.money_ledger) |l| {
        l.mutex.lockUncancelable(r.io);
        defer l.mutex.unlock(r.io);
        l.add(r.io, moneyDay(r, r.now()), amount);
    };
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

/// What the gate and the log see for a delegate call.
fn delegateArg(a: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    const tasks = try parseTasks(a, input_json);
    return std.fmt.allocPrint(a, "{d} task{s}: {s}", .{ tasks.len, if (tasks.len == 1) "" else "s", util.cut(tasks[0].text, 200) });
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
    const deadline = r.now() + r.limits.turn_seconds;
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
        if (summarise(r, conv, n)) |text| {
            if (conv.summary) |old| conv.gpa.free(old);
            conv.summary = text;
            conv.dropOldest(n);
            gone = n;
            try r.log.write(.turn, r.private, .{ .run = r.label, .event = "summarised", .turns = n });
        } else |e| {
            try r.log.write(.model, false, .{ .run = r.label, .event = "summary failed", .result = @errorName(e) });
        }
    }
    return gone + conv.trim(limit);
}

fn summarise(r: *Run, conv: *Conversation, n: usize) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    if (conv.summary) |old| try text.print(a, "Earlier summary:\n{s}\n\n", .{old});
    for (conv.turns.items[0..n]) |tn| for (tn.messages.items) |m| for (m.blocks) |b| {
        if (text.items.len > 60000) break;
        switch (b) {
            .text => |x| try text.print(a, "{s}: {s}\n", .{ if (m.role == .user) "Owner" else "Agent", util.cut(x, 2000) }),
            .tool_use => |u| try text.print(a, "(tool {s}: {s})\n", .{ u.name, util.cut(u.input_json, 300) }),
            .tool_result => |x| try text.print(a, "(result: {s})\n", .{util.cut(x.content, 500)}),
        }
    };
    const cfg = r.model_cfg.?;
    var client = try model.Client.init(r.gpa, r.io, cfg.url, cfg.key, cfg.memory, 1024);
    defer client.deinit();
    const reply = try client.send(a, summary_prompt, &.{.{ .role = .user, .blocks = &.{.{ .text = text.items }} }}, &.{});
    try r.log.write(.model, false, .{ .run = r.label, .result = "ok", .purpose = "summary", .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens });
    const out = try reply.text(a);
    if (out.len == 0) return error.EmptySummary;
    return r.gpa.dupe(u8, out);
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
    mcp_tools: []const McpTool = &.{},
    ledger: MoneyLedger = .{},
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
        f.mcp_tools = &.{};
        f.ledger = .{};
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

    fn askFn(ctx: *anyopaque, what: []const u8, allow_day: bool) Answer {
        _ = what;
        const f: *Fix = @ptrCast(@alignCast(ctx));
        f.last_allow_day = allow_day;
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
    for (2..5) |n| try f.e.script(@intCast(n), "{\"delay_ms\":600,\"content\":[{\"type\":\"text\",\"text\":\"helper answer\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}");
    try f.e.script(5, model.textReply("Combined."));
    const started = std.Io.Clock.awake.now(t.io);
    const r = try f.say("research three things");
    defer freeResult(&f.run, r);
    const ms = started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds();
    try t.expectEqualStrings("Combined.", r.text);
    try t.expect(ms < 1500); // three 600 ms helpers at once, not one after another
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

test "long_conversation_is_summarised_not_dropped" {
    var f: Fix = undefined;
    try f.init("");
    defer f.deinit();
    try withHelpers(&f);
    // each turn is about 121 bytes: five fit, the sixth crosses the limit
    f.run.limits.conversation_bytes = 700;
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

// ---- MCP tools and money ----

const mcp_fake_path = if (@import("builtin").is_test) @import("build_options").fake_path else "";

fn withMcp(f: *Fix, money: bool) !*mcp.Server {
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, mcp_fake_path, a);
    const s = try mcp.Server.start(t.allocator, t.io, .{ .name = "fake", .command = try std.fmt.allocPrint(a, "\"{s}\" --mcp", .{fake}), .secrets = &.{}, .money = &.{} }, .{
        .workspace = f.run.env.workspace,
        .path_var = "/usr/bin:/bin",
        .home = "/tmp",
        .secret_values = &.{},
    });
    f.mcp_tools = try mcpTools(a, s, if (money) &.{"echo"} else &.{}, "amount");
    f.run.mcp = f.mcp_tools;
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
    try t.expectEqual(@as(f64, 0), f.ledger.total);
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
    try t.expectEqual(@as(f64, 2), f.ledger.total);
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
