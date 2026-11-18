//! Does a served model give the same token probabilities as a reference?
//! Both are asked the same prompts at temperature 0 with the probabilities
//! of each produced token and its most likely alternatives; the answers are
//! compared position by position for as long as both produced the same text.
const std = @import("std");
const jv = @import("jv.zig");
const api = @import("api.zig");
const http = @import("http.zig");
const check = @import("check.zig");

pub const Alt = struct { token: []const u8, logprob: f64 };

/// One produced token with the alternatives the server reported, most likely first.
pub const Step = struct { token: []const u8, logprob: f64, top: []const Alt = &.{} };

pub const Compared = struct {
    /// Positions where both had seen the same text before.
    positions: usize = 0,
    /// Of those, where both rated the same token most likely.
    top1_same: usize = 0,
    kl_sum: f64 = 0,
    kl_max: f64 = 0,
    /// |difference in log probability| of the produced token, where both produced the same.
    dlogprob_sum: f64 = 0,
    dlogprob_n: usize = 0,
    /// The first position where the two produced different tokens.
    first_divergence: ?usize = null,

    pub fn add(a: *Compared, b: Compared) void {
        a.positions += b.positions;
        a.top1_same += b.top1_same;
        a.kl_sum += b.kl_sum;
        a.kl_max = @max(a.kl_max, b.kl_max);
        a.dlogprob_sum += b.dlogprob_sum;
        a.dlogprob_n += b.dlogprob_n;
    }
    /// Share of positions where both rated the same token most likely.
    pub fn top1(c: Compared) f64 {
        return if (c.positions == 0) 1 else @as(f64, @floatFromInt(c.top1_same)) / @as(f64, @floatFromInt(c.positions));
    }
    pub fn meanKl(c: Compared) f64 {
        return if (c.positions == 0) 0 else c.kl_sum / @as(f64, @floatFromInt(c.positions));
    }
    pub fn meanDlogprob(c: Compared) f64 {
        return if (c.dlogprob_n == 0) 0 else c.dlogprob_sum / @as(f64, @floatFromInt(c.dlogprob_n));
    }
};

const floor_p = 1e-10;

fn alts(s: *const Step, one: *[1]Alt) []const Alt {
    if (s.top.len > 0) return s.top;
    one[0] = .{ .token = s.token, .logprob = s.logprob };
    return one;
}

/// How far the candidate's probabilities at one position are from the
/// reference's (Kullback-Leibler divergence, in nats), over the reference's
/// reported alternatives plus one bucket for everything else. A token the
/// candidate did not report gets the most it could have had: the smaller of
/// its lowest reported probability and its unreported remainder.
pub fn klStep(ref: Step, cand: Step) f64 {
    var ref_one: [1]Alt = undefined;
    var cand_one: [1]Alt = undefined;
    const r = alts(&ref, &ref_one);
    const c = alts(&cand, &cand_one);

    var c_sum: f64 = 0;
    var c_low: f64 = 1;
    for (c) |a| {
        const p = @exp(a.logprob);
        c_sum += p;
        c_low = @min(c_low, p);
    }
    const unseen = @max(@min(c_low, 1 - c_sum), floor_p);

    var kl: f64 = 0;
    var p_sum: f64 = 0;
    var q_sum: f64 = 0;
    for (r) |a| {
        const p = @exp(a.logprob);
        var q = unseen;
        for (c) |b| {
            if (std.mem.eql(u8, a.token, b.token)) {
                q = @max(@exp(b.logprob), floor_p);
                break;
            }
        }
        p_sum += p;
        q_sum += q;
        if (p > 0) kl += p * @log(p / q);
    }
    const p_rest = 1 - p_sum;
    if (p_rest > 1e-9) kl += p_rest * @log(p_rest / @max(1 - q_sum, floor_p));
    // rounding can leave a hair below zero
    return @max(kl, 0);
}

fn likeliest(s: Step) []const u8 {
    return if (s.top.len > 0) s.top[0].token else s.token;
}

pub fn compare(ref: []const Step, cand: []const Step) Compared {
    var out: Compared = .{};
    const n = @min(ref.len, cand.len);
    for (ref[0..n], cand[0..n], 0..) |r, c, i| {
        out.positions += 1;
        if (std.mem.eql(u8, likeliest(r), likeliest(c))) out.top1_same += 1;
        const kl = klStep(r, c);
        out.kl_sum += kl;
        out.kl_max = @max(out.kl_max, kl);
        if (!std.mem.eql(u8, r.token, c.token)) {
            out.first_divergence = i;
            break;
        }
        out.dlogprob_sum += @abs(r.logprob - c.logprob);
        out.dlogprob_n += 1;
    }
    if (out.first_divergence == null and ref.len != cand.len) out.first_divergence = n;
    return out;
}

pub const Kind = enum { raw, chat };

/// `raw`: text to continue as it is. `chat`: a user's message.
pub const Prompt = struct { id: []const u8, kind: Kind, text: []const u8 };

pub const Item = struct {
    prompt: Prompt,
    steps: []const Step = &.{},
    /// Why there are no steps.
    problem: ?[]const u8 = null,
};

/// How far a server's answers are from its own when it is asked twice.
pub const Noise = struct { mean_kl: f64 = 0, max_kl: f64 = 0, top1: f64 = 1 };

/// A server's answers to a set of prompts, with their probabilities.
pub const Record = struct {
    model: []const u8 = "",
    url: []const u8 = "",
    tokens: u32 = 16,
    top: u32 = 5,
    noise: ?Noise = null,
    items: []const Item = &.{},

    pub fn answered(r: Record) usize {
        var n: usize = 0;
        for (r.items) |it| n += @intFromBool(it.steps.len > 0);
        return n;
    }
};

pub const Group = struct {
    compared: Compared = .{},
    /// Prompts both servers answered with probabilities.
    prompts: usize = 0,
    /// Of those, where the two texts part.
    diverged: usize = 0,
    /// Prompts one of the two did not answer with probabilities.
    unavailable: usize = 0,
    /// Why, for the first of them, and which of the two it was.
    problem: ?[]const u8 = null,
    problem_side: Side = .server,
};

pub const Side = enum { reference, server };

pub const Worst = struct { id: []const u8, position: usize, kl: f64 };

pub const Summary = struct {
    raw: Group = .{},
    chat: Group = .{},
    /// The position where the two are furthest apart.
    worst: ?Worst = null,

    pub fn all(s: Summary) Compared {
        var c = s.raw.compared;
        c.add(s.chat.compared);
        return c;
    }
};

pub const Verdict = enum { same, differs, unknown };

pub const Judgement = struct {
    verdict: Verdict,
    reason: []const u8,
    /// The mean distance allowed: --max-kl, or three times the reference's own noise if that is more.
    kl_limit: f64,
};

pub const default_prompts = [_]Prompt{
    .{ .id = "raw-1", .kind = .raw, .text = "The capital of France is" },
    .{ .id = "raw-2", .kind = .raw, .text = "def fibonacci(n):\n    " },
    .{ .id = "raw-3", .kind = .raw, .text = "Once upon a time, in a village by the sea," },
    .{ .id = "raw-4", .kind = .raw, .text = "The three primary colours are red," },
    .{ .id = "raw-5", .kind = .raw, .text = "Water boils at 100 degrees Celsius, which is" },
    .{ .id = "raw-6", .kind = .raw, .text = "SELECT name, email FROM users WHERE" },
    .{ .id = "raw-7", .kind = .raw, .text = "In 1969, the first humans landed on" },
    .{ .id = "raw-8", .kind = .raw, .text = "To make bread you need flour, water," },
    .{ .id = "chat-1", .kind = .chat, .text = "What is the capital of Japan? Answer in one sentence." },
    .{ .id = "chat-2", .kind = .chat, .text = "Write a Python function that reverses a string." },
    .{ .id = "chat-3", .kind = .chat, .text = "Explain in one sentence why the sky is blue." },
    .{ .id = "chat-4", .kind = .chat, .text = "List three fruits, separated by commas." },
    .{ .id = "chat-5", .kind = .chat, .text = "Translate 'good morning' into French and Spanish." },
    .{ .id = "chat-6", .kind = .chat, .text = "What is 17 times 23? Show the steps briefly." },
    .{ .id = "chat-7", .kind = .chat, .text = "Give me a JSON object with the keys name and age for a fictional person." },
    .{ .id = "chat-8", .kind = .chat, .text = "Summarise the plot of Romeo and Juliet in two sentences." },
};

/// A prompts file: one prompt to a line, "raw: text" to continue the text as
/// it is or "chat: text" (or just the text) for a user's message; \n in a
/// line is a line break; empty lines and lines starting with # are skipped.
pub fn parsePrompts(arena: std.mem.Allocator, text: []const u8) ![]Prompt {
    var out: std.ArrayList(Prompt) = .empty;
    var counts = [2]usize{ 0, 0 };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var kind: Kind = .chat;
        if (std.mem.startsWith(u8, line, "raw:")) {
            kind = .raw;
            line = line[4..];
        } else if (std.mem.startsWith(u8, line, "chat:")) {
            line = line[5..];
        }
        line = std.mem.trimStart(u8, line, " \t");
        if (line.len == 0) continue;
        var body: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) {
                const c: ?u8 = switch (line[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    else => null,
                };
                if (c) |ch| {
                    try body.append(arena, ch);
                    i += 1;
                    continue;
                }
            }
            try body.append(arena, line[i]);
        }
        counts[@backingInt(kind)] += 1;
        try out.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ @tagName(kind), counts[@backingInt(kind)] }),
            .kind = kind,
            .text = body.items,
        });
    }
    return out.items;
}

/// The file a record is kept in: JSON, marked with "llmcheck_record".
pub fn writeRecord(arena: std.mem.Allocator, r: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    writeRecordTo(&s, r) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

fn writeRecordTo(s: *std.json.Stringify, r: Record) !void {
    try s.beginObject();
    try s.objectField("llmcheck_record");
    try s.write(1);
    try s.objectField("model");
    try s.write(r.model);
    try s.objectField("url");
    try s.write(r.url);
    try s.objectField("tokens");
    try s.write(r.tokens);
    try s.objectField("top");
    try s.write(r.top);
    if (r.noise) |n| {
        try s.objectField("noise");
        try s.beginObject();
        try s.objectField("mean_kl");
        try s.write(n.mean_kl);
        try s.objectField("max_kl");
        try s.write(n.max_kl);
        try s.objectField("top1");
        try s.write(n.top1);
        try s.endObject();
    }
    try s.objectField("prompts");
    try s.beginArray();
    for (r.items) |it| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(it.prompt.id);
        try s.objectField("kind");
        try s.write(@tagName(it.prompt.kind));
        try s.objectField("prompt");
        try s.write(it.prompt.text);
        if (it.problem) |p| {
            try s.objectField("problem");
            try s.write(p);
        }
        try s.objectField("steps");
        try s.beginArray();
        for (it.steps) |st| {
            try s.beginObject();
            try s.objectField("t");
            try s.write(st.token);
            try s.objectField("lp");
            try s.write(st.logprob);
            try s.objectField("top");
            try s.beginArray();
            for (st.top) |a| {
                try s.beginArray();
                try s.write(a.token);
                try s.write(a.logprob);
                try s.endArray();
            }
            try s.endArray();
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// Null: `bytes` is not a record file.
pub fn readRecord(arena: std.mem.Allocator, bytes: []const u8) !?Record {
    const v = jv.parse(arena, bytes) orelse return null;
    if ((jv.int(jv.get(v, "llmcheck_record")) orelse 0) != 1) return null;
    var r: Record = .{
        .model = jv.str(jv.get(v, "model")) orelse "",
        .url = jv.str(jv.get(v, "url")) orelse "",
    };
    if (jv.int(jv.get(v, "tokens"))) |n| r.tokens = std.math.cast(u32, n) orelse return null;
    if (jv.int(jv.get(v, "top"))) |n| r.top = std.math.cast(u32, n) orelse return null;
    if (jv.get(v, "noise")) |n| r.noise = .{
        .mean_kl = jv.num(jv.get(n, "mean_kl")) orelse 0,
        .max_kl = jv.num(jv.get(n, "max_kl")) orelse 0,
        .top1 = jv.num(jv.get(n, "top1")) orelse 1,
    };
    var items: std.ArrayList(Item) = .empty;
    for (jv.arr(jv.get(v, "prompts")) orelse return null) |p| {
        const kind = std.meta.stringToEnum(Kind, jv.str(jv.get(p, "kind")) orelse "") orelse return null;
        var steps: std.ArrayList(Step) = .empty;
        for (jv.arr(jv.get(p, "steps")) orelse &[_]jv.Value{}) |st| {
            var top: std.ArrayList(Alt) = .empty;
            for (jv.arr(jv.get(st, "top")) orelse &[_]jv.Value{}) |a| {
                const pair = jv.arr(a) orelse return null;
                if (pair.len != 2) return null;
                try top.append(arena, .{ .token = jv.str(pair[0]) orelse return null, .logprob = jv.num(pair[1]) orelse return null });
            }
            try steps.append(arena, .{
                .token = jv.str(jv.get(st, "t")) orelse return null,
                .logprob = jv.num(jv.get(st, "lp")) orelse return null,
                .top = top.items,
            });
        }
        try items.append(arena, .{
            .prompt = .{
                .id = jv.str(jv.get(p, "id")) orelse return null,
                .kind = kind,
                .text = jv.str(jv.get(p, "prompt")) orelse return null,
            },
            .steps = steps.items,
            .problem = jv.str(jv.get(p, "problem")),
        });
    }
    r.items = items.items;
    return r;
}

fn find(r: Record, id: []const u8) ?Item {
    for (r.items) |it| if (std.mem.eql(u8, it.prompt.id, id)) return it;
    return null;
}

/// Compares the answers of `cand` with those of `ref` to the same prompts.
pub fn compareRecords(ref: Record, cand: Record) Summary {
    var s: Summary = .{};
    for (ref.items) |r| {
        const g = switch (r.prompt.kind) {
            .raw => &s.raw,
            .chat => &s.chat,
        };
        const c: Item = find(cand, r.prompt.id) orelse .{ .prompt = r.prompt, .problem = "not asked" };
        if (r.steps.len == 0 or c.steps.len == 0) {
            g.unavailable += 1;
            if (g.problem == null) {
                g.problem_side = if (r.steps.len == 0) .reference else .server;
                g.problem = (if (r.steps.len == 0) r.problem else c.problem) orelse "no token probabilities in the answer";
            }
            continue;
        }
        const one = compare(r.steps, c.steps);
        g.prompts += 1;
        g.compared.add(one);
        if (one.first_divergence) |d| {
            // a shorter answer that is the start of the longer one has not parted from it
            if (d < @min(r.steps.len, c.steps.len)) g.diverged += 1;
        }
        for (0..one.positions) |i| {
            const kl = klStep(r.steps[i], c.steps[i]);
            if (kl > 0 and (s.worst == null or kl > s.worst.?.kl)) s.worst = .{ .id = r.prompt.id, .position = i, .kl = kl };
        }
    }
    return s;
}

/// How far two records of the same server are apart.
pub fn noiseOf(a: Record, b: Record) Noise {
    const all = compareRecords(a, b).all();
    return .{ .mean_kl = all.meanKl(), .max_kl = all.kl_max, .top1 = all.top1() };
}

fn beyond(g: Group, kl_limit: f64, min_top1: f64) bool {
    return g.compared.positions > 0 and (g.compared.meanKl() > kl_limit or g.compared.top1() < min_top1);
}

/// Same model or not, and if not, where the difference comes in: raw text
/// goes to the model as it is, so a difference there is in the model itself;
/// a difference only in chat is in what is put around the messages.
pub fn judge(s: Summary, noise: ?Noise, max_kl: f64, min_top1: f64) Judgement {
    const limit = @max(max_kl, 3 * (if (noise) |n| n.mean_kl else 0));
    const have_raw = s.raw.compared.positions > 0;
    const have_chat = s.chat.compared.positions > 0;
    const verdict: Verdict, const reason: []const u8 = blk: {
        if (!have_raw and !have_chat) break :blk .{ .unknown, "there are no token probabilities to compare" };
        if (beyond(s.raw, limit, min_top1)) break :blk .{ .differs, "the model itself answers differently: raw text, which no chat template touches, already differs (other weights, quantization or build)" };
        if (beyond(s.chat, limit, min_top1)) {
            if (have_raw) break :blk .{ .differs, "raw text agrees but chat does not: the chat template (or an added system prompt) differs" };
            break :blk .{ .differs, "chat answers differ; raw text could not be compared, so this is either the model or its chat template" };
        }
        if (!have_raw) break :blk .{ .same, "chat answers agree (raw text could not be compared)" };
        if (!have_chat) break :blk .{ .same, "raw text agrees (chat could not be compared)" };
        break :blk .{ .same, "raw text and chat answers agree" };
    };
    return .{ .verdict = verdict, .reason = reason, .kl_limit = limit };
}

/// Asks `server` each prompt at temperature 0 for `tokens` tokens with the
/// probabilities of each and of `top` alternatives. A prompt the server does
/// not answer that way is kept with the reason; an error means the server
/// could not be reached.
pub fn record(arena: std.mem.Allocator, server: *api.Server, prompts: []const Prompt, tokens: u32, top: u32) http.Error!Record {
    const items = try arena.alloc(Item, prompts.len);
    for (prompts, items) |p, *it| {
        it.* = .{ .prompt = p };
        const message = [_]api.Message{.{ .content = p.text }};
        var ask: api.Ask = .{ .max_tokens = tokens, .temperature = 0, .seed = 1, .logprobs = top };
        switch (p.kind) {
            .raw => ask.prompt = p.text,
            .chat => ask.messages = &message,
        }
        const c = server.ask(arena, ask) catch |e| switch (e) {
            error.ConnectionClosed, error.BadResponse => {
                it.problem = try check.describe(arena, e, server.limits);
                continue;
            },
            else => return e,
        };
        if (!c.ok()) {
            it.problem = if (c.error_message) |m|
                try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ c.status, try check.clip(arena, m, 140) })
            else
                try std.fmt.allocPrint(arena, "HTTP {d}", .{c.status});
        } else if (c.steps.len == 0) {
            it.problem = "no token probabilities in the answer";
        } else {
            it.steps = c.steps;
        }
    }
    return .{
        .model = server.model orelse "",
        .tokens = tokens,
        .top = top,
        .items = items,
    };
}

// ---- tests ----

const testing = std.testing;

fn lp(p: f64) f64 {
    return @log(p);
}

test "identical_probabilities_are_no_distance_apart" {
    const s: Step = .{ .token = "a", .logprob = lp(0.6), .top = &.{
        .{ .token = "a", .logprob = lp(0.6) }, .{ .token = "b", .logprob = lp(0.3) },
    } };
    try testing.expectApproxEqAbs(@as(f64, 0), klStep(s, s), 1e-12);
}

test "the_distance_between_two_distributions_is_the_textbook_one" {
    const ref: Step = .{ .token = "a", .logprob = lp(0.5), .top = &.{
        .{ .token = "a", .logprob = lp(0.5) }, .{ .token = "b", .logprob = lp(0.5) },
    } };
    const cand: Step = .{ .token = "a", .logprob = lp(0.9), .top = &.{
        .{ .token = "a", .logprob = lp(0.9) }, .{ .token = "b", .logprob = lp(0.1) },
    } };
    // 0.5 ln(0.5/0.9) + 0.5 ln(0.5/0.1)
    try testing.expectApproxEqAbs(@as(f64, 0.510826), klStep(ref, cand), 1e-5);
}

test "everything_not_reported_counts_as_one_bucket" {
    const ref: Step = .{ .token = "a", .logprob = lp(0.5), .top = &.{
        .{ .token = "a", .logprob = lp(0.5) }, .{ .token = "b", .logprob = lp(0.25) },
    } };
    const cand: Step = .{ .token = "a", .logprob = lp(0.25), .top = &.{
        .{ .token = "a", .logprob = lp(0.25) }, .{ .token = "b", .logprob = lp(0.5) },
    } };
    // a: 0.5 ln 2; b: 0.25 ln 0.5; the rest: 0.25 ln(0.25/0.25)
    try testing.expectApproxEqAbs(@as(f64, 0.25 * @log(2.0)), klStep(ref, cand), 1e-9);
}

test "a_token_the_candidate_did_not_report_gets_the_most_it_could_have_had" {
    const ref: Step = .{ .token = "a", .logprob = lp(0.7), .top = &.{
        .{ .token = "a", .logprob = lp(0.7) }, .{ .token = "b", .logprob = lp(0.3) },
    } };
    // "b" is missing: at most min(lowest reported 0.2, remainder 0.05) = 0.05
    const cand: Step = .{ .token = "a", .logprob = lp(0.75), .top = &.{
        .{ .token = "a", .logprob = lp(0.75) }, .{ .token = "c", .logprob = lp(0.2) },
    } };
    const want = 0.7 * @log(0.7 / 0.75) + 0.3 * @log(0.3 / 0.05);
    try testing.expectApproxEqAbs(want, klStep(ref, cand), 1e-9);
    // nothing left over at all: a floor keeps the distance finite
    const sure: Step = .{ .token = "a", .logprob = 0, .top = &.{.{ .token = "a", .logprob = 0 }} };
    const d = klStep(ref, sure);
    try testing.expect(std.math.isFinite(d) and d > 5);
}

test "answers_are_compared_until_their_texts_part" {
    const top_a = [_]Alt{ .{ .token = "a", .logprob = lp(0.6) }, .{ .token = "b", .logprob = lp(0.4) } };
    const top_b = [_]Alt{ .{ .token = "b", .logprob = lp(0.6) }, .{ .token = "a", .logprob = lp(0.4) } };
    const ref = [_]Step{
        .{ .token = "a", .logprob = lp(0.6), .top = &top_a },
        .{ .token = "a", .logprob = lp(0.6), .top = &top_a },
        .{ .token = "a", .logprob = lp(0.6), .top = &top_a },
        .{ .token = "a", .logprob = lp(0.6), .top = &top_a },
    };
    const cand = [_]Step{
        .{ .token = "a", .logprob = lp(0.6), .top = &top_a },
        .{ .token = "a", .logprob = lp(0.5), .top = &top_a },
        .{ .token = "b", .logprob = lp(0.6), .top = &top_b }, // parts here
        .{ .token = "a", .logprob = lp(0.6), .top = &top_a }, // after another text: not compared
    };
    const c = compare(&ref, &cand);
    try testing.expectEqual(@as(usize, 3), c.positions);
    try testing.expectEqual(@as(usize, 2), c.top1_same);
    try testing.expectEqual(@as(?usize, 2), c.first_divergence);
    try testing.expectEqual(@as(usize, 2), c.dlogprob_n);
    try testing.expectApproxEqAbs(@log(0.6) - @log(0.5), c.dlogprob_sum, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), c.top1(), 1e-9);
    try testing.expect(c.kl_max > 0.05);
    try testing.expectApproxEqAbs(c.kl_max / 3, c.meanKl(), 1e-9);

    const same = compare(&ref, &ref);
    try testing.expectEqual(@as(usize, 4), same.positions);
    try testing.expectEqual(@as(?usize, null), same.first_divergence);
    try testing.expectEqual(@as(f64, 1), same.top1());
    try testing.expectEqual(@as(f64, 0), same.meanKl());

    // one answer shorter than the other: its end is where they part
    const short = compare(&ref, ref[0..2]);
    try testing.expectEqual(@as(usize, 2), short.positions);
    try testing.expectEqual(@as(?usize, 2), short.first_divergence);

    var total: Compared = .{};
    total.add(c);
    total.add(same);
    try testing.expectEqual(@as(usize, 7), total.positions);
    try testing.expectEqual(@as(usize, 6), total.top1_same);
    try testing.expectEqual(c.kl_max, total.kl_max);
}

const top_x = [_]Alt{ .{ .token = "x", .logprob = @log(0.7) }, .{ .token = "y", .logprob = @log(0.2) } };
const top_y = [_]Alt{ .{ .token = "y", .logprob = @log(0.7) }, .{ .token = "x", .logprob = @log(0.2) } };
const steps_x = [_]Step{ .{ .token = "x", .logprob = @log(0.7), .top = &top_x }, .{ .token = "x", .logprob = @log(0.7), .top = &top_x } };
const steps_y = [_]Step{.{ .token = "y", .logprob = @log(0.7), .top = &top_y }};

fn rec(raw: []const Step, chat: []const Step) Record {
    const S = struct {
        var items: [64][2]Item = undefined;
        var used: usize = 0;
    };
    const slot = &S.items[S.used];
    S.used += 1;
    slot.* = .{
        .{ .prompt = .{ .id = "raw-1", .kind = .raw, .text = "Once" }, .steps = raw, .problem = if (raw.len == 0) "HTTP 404" else null },
        .{ .prompt = .{ .id = "chat-1", .kind = .chat, .text = "Hi" }, .steps = chat, .problem = if (chat.len == 0) "no token probabilities in the answer" else null },
    };
    return .{ .model = "m", .url = "http://h", .tokens = 2, .top = 2, .items = slot };
}

test "prompts_are_read_one_to_a_line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parsePrompts(arena_state.allocator(),
        \\# a comment
        \\raw: The sea is
        \\
        \\chat: Name a colour.
        \\What is 2+2?
        \\raw:def f():\n    return
        \\
    );
    try testing.expectEqual(@as(usize, 4), p.len);
    try testing.expectEqualStrings("raw-1", p[0].id);
    try testing.expectEqual(Kind.raw, p[0].kind);
    try testing.expectEqualStrings("The sea is", p[0].text);
    try testing.expectEqualStrings("chat-1", p[1].id);
    try testing.expectEqualStrings("Name a colour.", p[1].text);
    // a line that names no kind is a chat message
    try testing.expectEqualStrings("chat-2", p[2].id);
    try testing.expectEqualStrings("What is 2+2?", p[2].text);
    // \n in a line is a line break
    try testing.expectEqualStrings("raw-2", p[3].id);
    try testing.expectEqualStrings("def f():\n    return", p[3].text);
}

test "a_record_comes_back_from_its_file_as_it_was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = rec(&steps_x, &.{});
    r.noise = .{ .mean_kl = 0.001, .max_kl = 0.01, .top1 = 0.5 };
    const text = try writeRecord(arena, r);
    const back = (try readRecord(arena, text)).?;
    try testing.expectEqualStrings("m", back.model);
    try testing.expectEqualStrings("http://h", back.url);
    try testing.expect(back.tokens == 2 and back.top == 2);
    try testing.expectEqual(@as(f64, 0.001), back.noise.?.mean_kl);
    try testing.expectEqual(@as(f64, 0.01), back.noise.?.max_kl);
    try testing.expectEqual(@as(f64, 0.5), back.noise.?.top1);
    try testing.expectEqual(@as(usize, 2), back.items.len);
    try testing.expectEqualStrings("raw-1", back.items[0].prompt.id);
    try testing.expectEqual(Kind.raw, back.items[0].prompt.kind);
    try testing.expectEqualStrings("Once", back.items[0].prompt.text);
    try testing.expectEqual(@as(usize, 2), back.items[0].steps.len);
    try testing.expectEqualStrings("x", back.items[0].steps[1].token);
    try testing.expectEqual(@log(@as(f64, 0.7)), back.items[0].steps[1].logprob);
    try testing.expectEqualStrings("y", back.items[0].steps[1].top[1].token);
    try testing.expectEqual(@log(@as(f64, 0.2)), back.items[0].steps[1].top[1].logprob);
    try testing.expectEqual(Kind.chat, back.items[1].prompt.kind);
    try testing.expectEqual(@as(usize, 0), back.items[1].steps.len);
    try testing.expectEqualStrings("no token probabilities in the answer", back.items[1].problem.?);
    try testing.expectEqual(@as(usize, 1), back.answered());
    // any other file is not a record
    try testing.expect(try readRecord(arena, "{\"model\":\"m\"}") == null);
    try testing.expect(try readRecord(arena, "not json") == null);
}

test "records_are_compared_prompt_by_prompt_in_two_groups" {
    const s = compareRecords(rec(&steps_x, &steps_x), rec(&steps_x, &steps_y));
    try testing.expectEqual(@as(usize, 1), s.raw.prompts);
    try testing.expectEqual(@as(usize, 2), s.raw.compared.positions);
    try testing.expectEqual(@as(f64, 0), s.raw.compared.meanKl());
    try testing.expectEqual(@as(usize, 0), s.raw.diverged);
    try testing.expectEqual(@as(usize, 1), s.chat.compared.positions);
    try testing.expectEqual(@as(usize, 1), s.chat.diverged);
    try testing.expect(s.chat.compared.meanKl() > 0.5);
    try testing.expectEqualStrings("chat-1", s.worst.?.id);
    try testing.expectEqual(@as(usize, 0), s.worst.?.position);
    try testing.expectEqual(@as(usize, 3), s.all().positions);

    const missing = compareRecords(rec(&steps_x, &steps_x), rec(&.{}, &steps_x));
    try testing.expectEqual(@as(usize, 0), missing.raw.prompts);
    try testing.expectEqual(@as(usize, 1), missing.raw.unavailable);
    try testing.expectEqualStrings("HTTP 404", missing.raw.problem.?);
    try testing.expectEqual(Side.server, missing.raw.problem_side);
    try testing.expect(missing.worst == null);

    const n = noiseOf(rec(&steps_x, &steps_x), rec(&steps_x, &steps_y));
    try testing.expectApproxEqAbs(s.all().meanKl(), n.mean_kl, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), n.top1, 1e-12);
    try testing.expect(n.max_kl > 0.5);
}

test "the_verdict_says_whether_the_weights_or_the_template_differ" {
    const same = judge(compareRecords(rec(&steps_x, &steps_x), rec(&steps_x, &steps_x)), null, 0.01, 0.95);
    try testing.expectEqual(Verdict.same, same.verdict);
    try testing.expectEqual(@as(f64, 0.01), same.kl_limit);

    const weights = judge(compareRecords(rec(&steps_x, &steps_x), rec(&steps_y, &steps_y)), null, 0.01, 0.95);
    try testing.expectEqual(Verdict.differs, weights.verdict);
    try testing.expect(std.mem.indexOf(u8, weights.reason, "the model itself") != null);

    const template = judge(compareRecords(rec(&steps_x, &steps_x), rec(&steps_x, &steps_y)), null, 0.01, 0.95);
    try testing.expectEqual(Verdict.differs, template.verdict);
    try testing.expect(std.mem.indexOf(u8, template.reason, "chat template") != null);

    const no_raw = judge(compareRecords(rec(&.{}, &steps_x), rec(&.{}, &steps_y)), null, 0.01, 0.95);
    try testing.expectEqual(Verdict.differs, no_raw.verdict);
    try testing.expect(std.mem.indexOf(u8, no_raw.reason, "could not be compared") != null);

    const nothing = judge(compareRecords(rec(&.{}, &.{}), rec(&steps_x, &steps_x)), null, 0.01, 0.95);
    try testing.expectEqual(Verdict.unknown, nothing.verdict);
}

test "a_reference_that_differs_from_itself_widens_the_limit" {
    var s: Summary = .{};
    s.raw = .{ .prompts = 1, .compared = .{ .positions = 10, .top1_same = 10, .kl_sum = 0.5 } }; // mean 0.05
    s.chat = s.raw;
    try testing.expectEqual(Verdict.differs, judge(s, null, 0.01, 0.95).verdict);
    try testing.expectEqual(Verdict.differs, judge(s, .{ .mean_kl = 0.01 }, 0.01, 0.95).verdict);
    const wide = judge(s, .{ .mean_kl = 0.02 }, 0.01, 0.95);
    try testing.expectEqual(Verdict.same, wide.verdict);
    try testing.expectApproxEqAbs(@as(f64, 0.06), wide.kl_limit, 1e-12);
    // the same most likely token too rarely is a difference whatever the distance
    s.raw.compared.top1_same = 9;
    s.raw.compared.kl_sum = 0;
    s.chat.compared.kl_sum = 0;
    try testing.expectEqual(Verdict.differs, judge(s, null, 0.01, 0.95).verdict);
    try testing.expectEqual(Verdict.same, judge(s, null, 0.01, 0.9).verdict);
}

const fake = @import("fake.zig");

const Rig = struct {
    arena_state: std.heap.ArenaAllocator,
    fake_server: *fake.Server,
    server: api.Server,

    fn init(r: *Rig, faults: fake.Faults) !void {
        r.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        r.fake_server = try fake.Server.start(testing.io, faults, 0);
        r.server = api.Server.init(testing.allocator, testing.io, .{ .https = false, .host = "127.0.0.1", .port = r.fake_server.port, .prefix = "" });
        r.server.model = fake.model_name;
    }
    fn deinit(r: *Rig) void {
        r.server.deinit();
        r.fake_server.stop();
        r.arena_state.deinit();
    }
    fn take(r: *Rig) !Record {
        return record(r.arena_state.allocator(), &r.server, &default_prompts, 16, 5);
    }
};

fn against(faults: fake.Faults) !Summary {
    const S = struct {
        var ref: Rig = undefined;
        var cand: Rig = undefined;
        var live = false;
    };
    if (S.live) {
        S.ref.deinit();
        S.cand.deinit();
        S.live = false;
    }
    if (faults.hang) return .{}; // only to take the servers down
    try S.ref.init(.{});
    try S.cand.init(faults);
    S.live = true;
    return compareRecords(try S.ref.take(), try S.cand.take());
}

test "two_servers_with_the_same_model_agree" {
    defer _ = against(.{ .hang = true }) catch {};
    const s = try against(.{});
    try testing.expectEqual(@as(usize, 8), s.raw.prompts);
    try testing.expectEqual(@as(usize, 8), s.chat.prompts);
    try testing.expectEqual(@as(usize, 8 * 16), s.raw.compared.positions);
    try testing.expectEqual(@as(usize, 8 * 16), s.chat.compared.positions);
    try testing.expectEqual(@as(f64, 0), s.all().kl_max);
    try testing.expectEqual(@as(f64, 1), s.all().top1());
    try testing.expectEqual(@as(usize, 0), s.raw.diverged + s.chat.diverged);
    try testing.expect(s.worst == null);
    try testing.expectEqual(Verdict.same, judge(s, null, 0.01, 0.95).verdict);
}

test "other_weights_show_in_raw_text_another_template_only_in_chat" {
    defer _ = against(.{ .hang = true }) catch {};
    const weights = try against(.{ .weights_differ = true });
    try testing.expect(weights.raw.compared.meanKl() > 0.01);
    const w = judge(weights, null, 0.01, 0.95);
    try testing.expectEqual(Verdict.differs, w.verdict);
    try testing.expect(std.mem.indexOf(u8, w.reason, "the model itself") != null);
    try testing.expect(weights.worst.?.kl > 0.01);

    const template = try against(.{ .template_differs = true });
    try testing.expectEqual(@as(f64, 0), template.raw.compared.kl_max);
    try testing.expect(template.chat.compared.meanKl() > 0.01);
    const t = judge(template, null, 0.01, 0.95);
    try testing.expectEqual(Verdict.differs, t.verdict);
    try testing.expect(std.mem.indexOf(u8, t.reason, "chat template") != null);
}

test "a_server_without_probabilities_cannot_be_compared" {
    defer _ = against(.{ .hang = true }) catch {};
    const s = try against(.{ .no_logprobs = true });
    try testing.expectEqual(@as(usize, 8), s.raw.unavailable);
    try testing.expectEqual(@as(usize, 8), s.chat.unavailable);
    try testing.expectEqual(Side.server, s.raw.problem_side);
    try testing.expectEqualStrings("no token probabilities in the answer", s.raw.problem.?);
    try testing.expectEqual(Verdict.unknown, judge(s, null, 0.01, 0.95).verdict);
}

test "a_record_kept_in_a_file_stands_in_for_the_reference" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    const arena = r.arena_state.allocator();
    var first = try r.take();
    first.noise = noiseOf(first, try r.take());
    try testing.expectEqual(@as(f64, 0), first.noise.?.mean_kl);
    try testing.expectEqualStrings("fake-1", first.model);
    try testing.expectEqual(@as(usize, 16), first.answered());
    const kept = (try readRecord(arena, try writeRecord(arena, first))).?;
    // the prompts come from the file
    var prompts: std.ArrayList(Prompt) = .empty;
    for (kept.items) |it| try prompts.append(arena, it.prompt);
    const now = try record(arena, &r.server, prompts.items, kept.tokens, kept.top);
    const s = compareRecords(kept, now);
    try testing.expectEqual(@as(usize, 2 * 8 * 16), s.all().positions);
    try testing.expectEqual(@as(f64, 0), s.all().kl_max);
    try testing.expectEqual(Verdict.same, judge(s, kept.noise, 0.01, 0.95).verdict);
}

test "a_prompt_the_server_refuses_is_kept_with_the_reason" {
    var r: Rig = undefined;
    try r.init(.{ .context = 4 });
    defer r.deinit();
    const got = try r.take();
    try testing.expect(got.items[0].steps.len == 0); // "The capital of France is": 5 words
    try testing.expect(std.mem.startsWith(u8, got.items[0].problem.?, "HTTP 400: This model's maximum context length is 4 tokens."));
    r.fake_server.stop();
    r.fake_server = try fake.Server.start(testing.io, .{}, 0); // elsewhere now: the old address is dead
    try testing.expectError(error.ConnectFailed, r.take());
}
