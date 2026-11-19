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
const Io = std.Io;

pub const Answer = enum { once, day, deny, timeout };

/// Asks the owner whether a call may run; blocks until they answer or the
/// approval time runs out.
pub const Asker = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, what: []const u8) Answer,
};

/// A conversation, kept as whole turns so the oldest can be dropped
/// without leaving a tool result without its call.
pub const Conversation = struct {
    gpa: std.mem.Allocator,
    turns: std.ArrayList(*Turn) = .empty,
    /// Turns dropped to stay under the size limit.
    dropped: usize = 0,

    pub const Turn = struct {
        arena: std.heap.ArenaAllocator,
        messages: std.ArrayList(model.Message) = .empty,
        bytes: usize = 0,
    };

    pub fn init(gpa: std.mem.Allocator) Conversation {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Conversation) void {
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

    fn now(r: *const Run) i64 {
        return util.nowSeconds(r.io);
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

pub fn systemPrompt(arena: std.mem.Allocator, r: *const Run, recalled: memory.Recall, dropped: usize, now_s: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, base_prompt);
    const local = now_s + @as(i64, r.utc_offset) * 60;
    const c = util.civil(@divFloor(local, 86400));
    const mins: i64 = @divFloor(@mod(local, 86400), 60);
    try out.print(arena, "\nNow: {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} (owner's time, UTC{s}{d}min).\n", .{ @as(u64, @intCast(c.y)), c.m, c.d, @as(u64, @intCast(@divFloor(mins, 60))), @as(u64, @intCast(@mod(mins, 60))), if (r.utc_offset >= 0) "+" else "-", @abs(r.utc_offset) });
    if (r.scheduled) try out.appendSlice(arena, "This is a scheduled run: the owner is not watching and cannot approve anything.\n");
    if (r.extra_instructions.len > 0) try out.print(arena, "{s}\n", .{r.extra_instructions});
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
    if (recalled.found.len > 0) {
        try out.appendSlice(arena, "\nPossibly relevant from earlier:\n");
        for (recalled.found) |it| try out.print(arena, "- {s}\n", .{it.body});
    }
    if (dropped > 0) try out.print(arena, "\n{d} earlier turns of this conversation were dropped to keep it short.\n", .{dropped});
    return out.items;
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
    try keep(tn, .{ .role = .user, .blocks = &.{.{ .text = user_text }} });

    var result: TurnResult = .{ .text = "" };
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
        result.steps += 1;
        const recalled = blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            break :blk try r.mem.recall(a, user_text, r.now(), r.top_size, r.auto_recall);
        };
        // pinned items and the top level are copied out while locked
        const system = blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            break :blk try systemPrompt(a, r, recalled, conv.dropped, r.now());
        };
        const msgs = try conv.messages(a);
        const reply = r.client.send(a, system, msgs, tools.defs()) catch |e| {
            const why: []const u8 = switch (e) {
                error.BudgetSpent => "Model budget used up.",
                error.RateLimited => "The model is rate limited; try again later.",
                else => try std.fmt.allocPrint(a, "Model call failed: {s} {s}", .{ @errorName(e), r.client.lastError() }),
            };
            try r.log.write(.model, false, .{ .run = r.label, .result = @errorName(e), .detail = r.client.lastError() });
            result.ended_by = try r.gpa.dupe(u8, why);
            break;
        };
        try r.log.write(.model, false, .{ .run = r.label, .result = "ok", .stop_reason = reply.stop_reason, .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens });
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
    const dropped = conv.trim(r.limits.conversation_bytes);
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
    const tool = gate.Tool.fromName(name) orelse return .{ .text = "no such tool", .is_error = true };
    const arg = tools.mainArg(a, tool, input_json) catch return .{ .text = "the tool's input is missing its main field", .is_error = true };
    const now_s = r.now();
    const d = blk: {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        break :blk r.gate.decide(a, tool, arg, now_s, .{ .scheduled = r.scheduled });
    };
    var action = d.action;
    var why = d.why;
    if (action == .ask) {
        if (r.asker) |asker| {
            const what = try std.fmt.allocPrint(a, "{s}: {s}", .{ name, util.cut(arg, 1500) });
            const ans = asker.ask(asker.ctx, what);
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
        else => try tools.run(r.env, a, tool, input_json),
    };
    try r.log.write(.tool, r.private, .{ .run = r.label, .tool = name, .arg = arg, .is_error = out.is_error, .output = out.text });
    return out;
}

// ---- tests ----

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

    fn askFn(ctx: *anyopaque, what: []const u8) Answer {
        _ = what;
        const f: *Fix = @ptrCast(@alignCast(ctx));
        f.asked += 1;
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
