//! llmcheck: checks a served language model through its OpenAI-style API.
//! Four commands on one binary: `check` (does the server do what its
//! interface promises), `fidelity` (does it give the same token
//! probabilities as a reference), `bench` (how fast under load) and
//! `probe` (one quick look, for a scheduler).

const std = @import("std");
const build_options = @import("build_options");
pub const sock = @import("sock.zig");
pub const http = @import("http.zig");
pub const jv = @import("jv.zig");
pub const sse = @import("sse.zig");
pub const stats = @import("stats.zig");
pub const fidelity = @import("fidelity.zig");
pub const api = @import("api.zig");
pub const check = @import("check.zig");
pub const args = @import("args.zig");
pub const bench = @import("bench.zig");
pub const probe = @import("probe.zig");

const Writer = std.Io.Writer;

const usage_text =
    \\llmcheck - checks a served language model through its OpenAI-style API
    \\
    \\Usage:
    \\  llmcheck check URL      does the server do what its interface promises
    \\  llmcheck fidelity URL   does it give the same token probabilities as a reference
    \\  llmcheck bench URL      how fast it answers when several ask at once
    \\  llmcheck probe URL      one quick look, for a scheduler; can repeat
    \\  llmcheck help [command]
    \\  llmcheck version
    \\
    \\URL is the server's address, such as http://localhost:8000 (with or
    \\without /v1 at the end).
    \\
    \\Options of every command:
    \\  --model M     the model to ask (default: the first the server lists)
    \\  --key K       API key; or set LLMCHECK_API_KEY
    \\  --timeout S   seconds to wait for the server before giving up
    \\  --insecure    accept any https certificate
    \\  --json        output as JSON
    \\
    \\Exit codes: 0 all good, 1 a check failed or a difference was found,
    \\2 wrong usage, 4 the server could not be reached or the run could not be made.
    \\
;

const command_help = .{
    .{ "check",
        \\llmcheck check URL [--ref URL] [--only a,b] [--skip a,b]
        \\
        \\Sends a few dozen small requests and says for each part of the interface
        \\whether the server does what it accepts. A line per check:
        \\  check id=auth status=pass detail="a request without the key is refused (HTTP 401)"
        \\then a summary line. Status is pass, fail, warn or skip.
        \\
        \\Checks:
        \\  models         the server lists its models
        \\  chat           a short chat is answered, with finish_reason and token counts
        \\  auth           a request without the key is refused
        \\  stream         a streamed answer is well formed and ends properly
        \\  deterministic  the same request twice at temperature 0 gives the same text
        \\  max_tokens     the answer stops at the limit, and says so
        \\  stop           the answer ends before a stop string
        \\  json_schema    output follows a JSON schema (not accepted and then ignored)
        \\  json_object    JSON output is JSON
        \\  tools          a tool call comes back as tool_calls with arguments that parse
        \\  tools_stream   the same, streamed
        \\  context        a prompt longer than the context is refused, not cut silently
        \\  sampling       a seed repeats its text, another seed gives another
        \\  logprobs       token probabilities are returned (fidelity needs them)
        \\  usage_match    with --ref: prompts count the same tokens on both servers
        \\
        \\Options:
        \\  --ref URL              a reference server to compare token counts with
        \\  --ref-model M          its model (default: the first it lists)
        \\  --ref-key K            its API key; or set LLMCHECK_REF_API_KEY
        \\  --only a,b             run only these checks
        \\  --skip a,b             leave these out
        \\  --max-prompt-words N   longest prompt the context check tries (default 8192)
        \\  --timeout S            default 120
        \\
        \\Exit 1 when a check fails; warnings do not change the exit code.
        \\
    },
    .{ "fidelity",
        \\llmcheck fidelity URL --ref URL
        \\llmcheck fidelity URL --record FILE
        \\llmcheck fidelity URL --against FILE
        \\
        \\Asks both servers the same prompts at temperature 0 and compares the
        \\probabilities they give each token. Half the prompts are raw text
        \\(/v1/completions), half are chat messages: a difference already in raw
        \\text is in the model itself (other weights, quantization or build), a
        \\difference only in chat is in the chat template or a system prompt.
        \\
        \\--record saves this server's answers to a file; --against compares a
        \\server with such a file later, or somewhere the reference cannot be reached.
        \\
        \\Output: a line per group (raw, chat) with mean_kl (KL divergence per
        \\token, 0 = identical) and top1 (share of positions with the same most
        \\likely token), then a verdict line: same, differs or unknown.
        \\
        \\The reference is asked twice; if it differs from itself, three times
        \\that noise is allowed instead of --max-kl.
        \\
        \\Options:
        \\  --ref URL        the reference server
        \\  --ref-model M    its model (default: the first it lists)
        \\  --ref-key K      its API key; or set LLMCHECK_REF_API_KEY
        \\  --record FILE    save this server's answers, compare nothing
        \\  --against FILE   compare with answers saved by --record
        \\  --prompts FILE   your own prompts, one to a line: "raw: text" or
        \\                   "chat: text" (default chat); \n is a line break
        \\  --tokens N       tokens to generate per prompt (default 16, at most 256)
        \\  --top K          alternatives per token (default 5, at most 20)
        \\  --max-kl X       mean KL above this is a difference (default 0.01)
        \\  --min-top1 X     top1 below this is a difference (default 0.95)
        \\  --timeout S      default 120
        \\
        \\Each answer is compared up to where the two texts part. Exit 1 when the
        \\servers differ, 4 when there are no token probabilities to compare.
        \\
    },
    .{ "bench",
        \\llmcheck bench URL [--concurrency N] [--requests N | --duration S] [--rate R]
        \\
        \\Sends streamed chat requests and measures time to the first token, time
        \\per request, the gaps between tokens and tokens per second.
        \\
        \\Without --rate, N askers each send their next request as soon as the
        \\last is answered. With --rate R, requests start R times a second
        \\whatever the server does, and a request's time counts from the moment
        \\it was due, so a server that falls behind shows.
        \\
        \\Options:
        \\  --concurrency N    requests at a time (default 16, at most 256)
        \\  --requests N       end after N requests (default: twice the concurrency, 32 at least)
        \\  --duration S       end after S seconds instead
        \\  --rate R           requests per second
        \\  --max-tokens N     tokens per answer (default 64)
        \\  --prompt-words N   words in each prompt (default 64)
        \\  --warmup N         requests sent first and not counted (default 1)
        \\  --timeout S        default 120
        \\
        \\Exit 1 when some requests fail, 4 when all do.
        \\
    },
    .{ "probe",
        \\llmcheck probe URL [--every S [--count N]] [--baseline FILE]
        \\
        \\Three requests: the model list, a short chat, a short stream. One line:
        \\  probe status=ok time=2026-11-17T09:30:00Z model=m models_ms=3.1 chat_ms=212.0 ttft_ms=48.3
        \\Status is ok, fail (reached, something does not work), drift (answers
        \\differ from the baseline) or down (not reached).
        \\
        \\Options:
        \\  --every S          repeat every S seconds until stopped
        \\  --count N          with --every: stop after N probes
        \\  --baseline FILE    a file from `llmcheck fidelity --record`: its prompts
        \\                     are asked again and compared (drift_kl, drift_top1)
        \\  --max-kl X         mean KL above this is drift (default 0.01)
        \\  --min-top1 X       top1 below this is drift (default 0.95)
        \\  --timeout S        default 10
        \\
        \\Exit 1 when a probe found a fault or drift, 4 when the server was down.
        \\
    },
};

pub const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, unreached = 4 };

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_w = std.fs.File.stdout().writerStreaming(&out_buf);
    const out = &out_w.interface;

    const argv = std.process.argsAlloc(arena) catch return @intFromEnum(Exit.unreached);
    const parsed = args.parse(arena, argv[1..]) catch return @intFromEnum(Exit.unreached);
    const o = switch (parsed) {
        .ok => |o| o,
        .err => |text| {
            complain("{s}\nSee `llmcheck help`.", .{text});
            return @intFromEnum(Exit.usage);
        },
    };
    var app: App = .{ .gpa = std.heap.smp_allocator, .arena = arena, .out = out, .o = o };
    const exit = app.run() catch |e| switch (e) {
        error.WriteFailed => Exit.failed, // nobody reads the output any more
        error.OutOfMemory => blk: {
            complain("out of memory", .{});
            break :blk Exit.unreached;
        },
    };
    out.flush() catch {};
    return @intFromEnum(exit);
}

fn complain(comptime fmt: []const u8, a: anytype) void {
    std.debug.print("llmcheck: " ++ fmt ++ "\n", a);
}

/// One output line: a name, then key=value pairs.
const Line = struct {
    out: *Writer,

    fn begin(out: *Writer, name: []const u8) !Line {
        try out.writeAll(name);
        return .{ .out = out };
    }
    fn text(l: Line, key: []const u8, value: []const u8) !void {
        try l.out.print(" {s}=", .{key});
        try writeValue(l.out, value);
    }
    fn int(l: Line, key: []const u8, value: anytype) !void {
        try l.out.print(" {s}={d}", .{ key, value });
    }
    fn num(l: Line, key: []const u8, value: f64, comptime digits: u8) !void {
        try l.out.print(" {s}={d:." ++ std.fmt.comptimePrint("{d}", .{digits}) ++ "}", .{ key, value });
    }
    fn end(l: Line) !void {
        try l.out.writeByte('\n');
    }
};

/// A value as it stands when it is one plain word, in quotes otherwise.
fn writeValue(out: *Writer, value: []const u8) !void {
    var plain = value.len > 0;
    for (value) |ch| {
        if (ch <= ' ' or ch == '"' or ch == '\\' or ch == '=') plain = false;
    }
    if (plain) return out.writeAll(value);
    try out.writeByte('"');
    for (value) |ch| {
        if (ch == '"' or ch == '\\') try out.writeByte('\\');
        try out.writeByte(if (ch < ' ') ' ' else ch);
    }
    try out.writeByte('"');
}

fn field(s: *std.json.Stringify, key: []const u8, value: anytype) !void {
    try s.objectField(key);
    try s.write(value);
}

const not_an_address = "'{s}' is not an address llmcheck can use: give http://host:port or https://host";

const App = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *Writer,
    o: args.Options,

    const Error = error{ OutOfMemory, WriteFailed };

    fn run(a: *App) Error!Exit {
        return switch (a.o.mode) {
            .help => a.help(),
            .version => {
                try a.out.print("llmcheck {s}\n", .{build_options.version});
                return .ok;
            },
            .check => a.checkCmd(),
            .fidelity => a.fidelityCmd(),
            .bench => a.benchCmd(),
            .probe => a.probeCmd(),
        };
    }

    fn help(a: *App) Error!Exit {
        if (a.o.topic) |topic| {
            inline for (command_help) |entry| {
                if (std.mem.eql(u8, entry[0], @tagName(topic))) {
                    try a.out.writeAll(entry[1]);
                    return .ok;
                }
            }
        }
        try a.out.writeAll(usage_text);
        return .ok;
    }

    fn env(a: *App, name: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(a.arena, name) catch return null;
        return if (v.len > 0) v else null;
    }

    /// Null (after a message) when `url` is no address.
    fn open(a: *App, url: []const u8, model: ?[]const u8, key: ?[]const u8, default_timeout_s: u32) ?api.Server {
        const target = http.Target.parse(url) catch {
            complain(not_an_address, .{url});
            return null;
        };
        var s = api.Server.init(a.gpa, target);
        s.model = model;
        s.key = key;
        s.client.insecure = a.o.insecure;
        s.limits = .{ .idle_ms = (a.o.timeout_s orelse default_timeout_s) *| 1000 };
        return s;
    }

    fn openMain(a: *App, default_timeout_s: u32) ?api.Server {
        return a.open(a.o.url, a.o.model, a.o.key orelse a.env("LLMCHECK_API_KEY"), default_timeout_s);
    }

    /// The reference gets its own key, never the server's.
    fn openRef(a: *App, url: []const u8) ?api.Server {
        return a.open(url, a.o.ref_model, a.o.ref_key orelse a.env("LLMCHECK_REF_API_KEY"), 120);
    }

    fn down(a: *App, url: []const u8, e: http.Error, limits: http.Limits) Error!Exit {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        complain("{s}: {s}", .{ url, try check.describe(a.arena, e, limits) });
        return .unreached;
    }

    /// Sets the model of `s` to the first it lists when none was named.
    fn pickModel(a: *App, s: *api.Server) http.Error!void {
        if (s.model != null) return;
        const m = try s.models(a.arena);
        if (m.ids.len > 0) s.model = m.ids[0];
    }

    /// Asks the reference for its models, so that one that is down or
    /// refuses is named by its own address before anything is compared.
    /// An exit code when it cannot be used.
    fn refReady(a: *App, ref: *api.Server, url: []const u8) Error!?Exit {
        const m = ref.models(a.arena) catch |e| return try a.down(url, e, ref.limits);
        if (m.status != 200) {
            const hint = if (m.status == 401 or m.status == 403) " (--ref-key or LLMCHECK_REF_API_KEY gives the reference its key)" else "";
            complain("{s}: the reference answers HTTP {d} to /v1/models{s}", .{ url, m.status, hint });
            return .unreached;
        }
        if (ref.model == null and m.ids.len > 0) ref.model = m.ids[0];
        return null;
    }

    // ---- check ----

    fn checkCmd(a: *App) Error!Exit {
        for ([_]?[]const u8{ a.o.only, a.o.skip }) |list| {
            var it = std.mem.splitScalar(u8, list orelse continue, ',');
            while (it.next()) |id| {
                if (check.known(id)) continue;
                var all: std.ArrayList(u8) = .empty;
                for (check.names, 0..) |n, i| {
                    if (i > 0) try all.appendSlice(a.arena, ", ");
                    try all.appendSlice(a.arena, n);
                }
                complain("no check '{s}'; there are: {s}", .{ id, all.items });
                return .usage;
            }
        }
        var s = a.openMain(120) orelse return .usage;
        defer s.deinit();
        var ref: ?api.Server = null;
        defer if (ref) |*r| r.deinit();
        if (a.o.ref) |url| {
            ref = a.openRef(url) orelse return .usage;
            if (try a.refReady(&ref.?, url)) |exit| return exit;
        }
        const report = check.run(a.arena, &s, if (ref) |*r| r else null, .{
            .only = a.o.only,
            .skip = a.o.skip,
            .max_prompt_words = a.o.max_prompt_words,
        }) catch |e| return a.down(a.o.url, e, s.limits);

        const counted = .{ "pass", "fail", "warn", "skip" };
        if (a.o.json) {
            var j: std.json.Stringify = .{ .writer = a.out, .options = .{} };
            try j.beginObject();
            try field(&j, "command", "check");
            try field(&j, "url", a.o.url);
            try field(&j, "model", report.model);
            try j.objectField("results");
            try j.beginArray();
            for (report.results) |r| {
                try j.beginObject();
                try field(&j, "id", r.id);
                try field(&j, "status", @tagName(r.status));
                try field(&j, "detail", r.detail);
                try j.endObject();
            }
            try j.endArray();
            try j.objectField("summary");
            try j.beginObject();
            inline for (counted) |name| try field(&j, name, report.count(@field(check.Status, name)));
            try j.endObject();
            try j.endObject();
            try a.out.writeByte('\n');
        } else {
            for (report.results) |r| {
                const l = try Line.begin(a.out, "check");
                try l.text("id", r.id);
                try l.text("status", @tagName(r.status));
                try l.text("detail", r.detail);
                try l.end();
            }
            const l = try Line.begin(a.out, "summary");
            inline for (counted) |name| try l.int(name, report.count(@field(check.Status, name)));
            if (report.model) |m| try l.text("model", m);
            try l.end();
        }
        return if (report.count(.fail) > 0) .failed else .ok;
    }

    // ---- fidelity ----

    fn readFile(a: *App, path: []const u8) ?[]u8 {
        return std.fs.cwd().readFileAlloc(a.arena, path, 256 << 20) catch |e| {
            complain("cannot read {s}: {s}", .{ path, @errorName(e) });
            return null;
        };
    }

    /// Null (after a message) when `path` holds nothing to compare with.
    fn readRecord(a: *App, path: []const u8) Error!?fidelity.Record {
        const bytes = a.readFile(path) orelse return null;
        const rec = (fidelity.readRecord(a.arena, bytes) catch null) orelse {
            complain("{s} is not a file made with `llmcheck fidelity --record`", .{path});
            return null;
        };
        if (rec.answered() == 0) {
            complain("{s} holds no token probabilities to compare with", .{path});
            return null;
        }
        return rec;
    }

    fn fidelityCmd(a: *App) Error!Exit {
        const o = a.o;
        var prompts: []const fidelity.Prompt = &fidelity.default_prompts;
        var tokens = o.tokens;
        var top = o.top;
        var kept: ?fidelity.Record = null;
        if (o.against) |path| {
            kept = try a.readRecord(path) orelse return .usage;
            const from_file = try a.arena.alloc(fidelity.Prompt, kept.?.items.len);
            for (kept.?.items, from_file) |it, *p| p.* = it.prompt;
            prompts = from_file;
            tokens = kept.?.tokens;
            top = kept.?.top;
        } else if (o.prompts) |path| {
            const text = a.readFile(path) orelse return .usage;
            prompts = fidelity.parsePrompts(a.arena, text) catch return error.OutOfMemory;
            if (prompts.len == 0) {
                complain("{s} holds no prompts", .{path});
                return .usage;
            }
        }

        var s = a.openMain(120) orelse return .usage;
        defer s.deinit();
        a.pickModel(&s) catch |e| return a.down(o.url, e, s.limits);

        if (o.record) |path| {
            var rec = fidelity.record(a.arena, &s, prompts, tokens, top) catch |e| return a.down(o.url, e, s.limits);
            const again = fidelity.record(a.arena, &s, prompts, tokens, top) catch |e| return a.down(o.url, e, s.limits);
            rec.url = o.url;
            rec.noise = fidelity.noiseOf(rec, again);
            if (rec.answered() == 0) {
                complain("{s} gave no token probabilities: {s}", .{ o.url, rec.items[0].problem orelse "no answer" });
                return .unreached;
            }
            std.fs.cwd().writeFile(.{ .sub_path = path, .data = try fidelity.writeRecord(a.arena, rec) }) catch |e| {
                complain("cannot write {s}: {s}", .{ path, @errorName(e) });
                return .unreached;
            };
            if (o.json) {
                var j: std.json.Stringify = .{ .writer = a.out, .options = .{} };
                try j.beginObject();
                try field(&j, "command", "fidelity");
                try field(&j, "recorded", path);
                try field(&j, "url", o.url);
                try field(&j, "model", rec.model);
                try field(&j, "prompts", rec.items.len);
                try field(&j, "answered", rec.answered());
                try field(&j, "noise", rec.noise);
                try j.endObject();
                try a.out.writeByte('\n');
            } else {
                const l = try Line.begin(a.out, "recorded");
                try l.text("file", path);
                try l.text("model", rec.model);
                try l.int("prompts", rec.items.len);
                try l.int("answered", rec.answered());
                try l.num("noise_kl", rec.noise.?.mean_kl, 4);
                try l.end();
            }
            return .ok;
        }

        var reference: fidelity.Record = undefined;
        var reference_name: []const u8 = undefined;
        if (kept) |k| {
            reference = k;
            reference_name = o.against.?;
        } else {
            const url = o.ref.?;
            var ref = a.openRef(url) orelse return .usage;
            defer ref.deinit();
            if (try a.refReady(&ref, url)) |exit| return exit;
            reference = fidelity.record(a.arena, &ref, prompts, tokens, top) catch |e| return a.down(url, e, ref.limits);
            const again = fidelity.record(a.arena, &ref, prompts, tokens, top) catch |e| return a.down(url, e, ref.limits);
            reference.url = url;
            reference.noise = fidelity.noiseOf(reference, again);
            reference_name = url;
        }
        const now = fidelity.record(a.arena, &s, prompts, tokens, top) catch |e| return a.down(o.url, e, s.limits);
        const summary = fidelity.compareRecords(reference, now);
        const judged = fidelity.judge(summary, reference.noise, o.max_kl, o.min_top1);

        if (o.json) {
            var j: std.json.Stringify = .{ .writer = a.out, .options = .{} };
            try j.beginObject();
            try field(&j, "command", "fidelity");
            try field(&j, "url", o.url);
            try field(&j, "model", now.model);
            try field(&j, "reference", reference_name);
            try field(&j, "reference_model", reference.model);
            try field(&j, "verdict", @tagName(judged.verdict));
            try field(&j, "reason", judged.reason);
            try field(&j, "kl_limit", judged.kl_limit);
            try field(&j, "min_top1", o.min_top1);
            try field(&j, "noise", reference.noise);
            inline for (.{ "raw", "chat" }) |name| {
                const g: fidelity.Group = @field(summary, name);
                const some = g.compared.positions > 0;
                try j.objectField(name);
                try j.beginObject();
                try field(&j, "prompts", g.prompts);
                try field(&j, "positions", g.compared.positions);
                try field(&j, "mean_kl", if (some) @as(?f64, g.compared.meanKl()) else null);
                try field(&j, "max_kl", if (some) @as(?f64, g.compared.kl_max) else null);
                try field(&j, "top1", if (some) @as(?f64, g.compared.top1()) else null);
                try field(&j, "diverged", g.diverged);
                try field(&j, "unavailable", g.unavailable);
                try field(&j, "problem", g.problem);
                try field(&j, "problem_side", if (g.problem != null) @as(?[]const u8, @tagName(g.problem_side)) else null);
                try j.endObject();
            }
            try field(&j, "worst", summary.worst);
            try j.endObject();
            try a.out.writeByte('\n');
        } else {
            inline for (.{ "raw", "chat" }) |name| {
                const g: fidelity.Group = @field(summary, name);
                const l = try Line.begin(a.out, "fidelity");
                try l.text("group", name);
                try l.int("prompts", g.prompts);
                try l.int("positions", g.compared.positions);
                if (g.compared.positions > 0) {
                    try l.num("mean_kl", g.compared.meanKl(), 4);
                    try l.num("max_kl", g.compared.kl_max, 4);
                    try l.num("top1", g.compared.top1(), 3);
                    try l.int("diverged", g.diverged);
                }
                if (g.unavailable > 0) {
                    try l.int("unavailable", g.unavailable);
                    try l.text("problem", try std.fmt.allocPrint(a.arena, "{s}: {s}", .{
                        if (g.problem_side == .reference) "the reference" else "the server",
                        g.problem orelse "no token probabilities in the answer",
                    }));
                }
                try l.end();
            }
            if (summary.worst) |w| {
                const l = try Line.begin(a.out, "worst");
                try l.text("prompt", w.id);
                try l.int("position", w.position);
                try l.num("kl", w.kl, 4);
                try l.end();
            }
            if (reference.noise) |n| {
                const l = try Line.begin(a.out, "noise");
                try l.num("mean_kl", n.mean_kl, 4);
                try l.num("max_kl", n.max_kl, 4);
                try l.num("top1", n.top1, 3);
                try l.end();
            }
            const l = try Line.begin(a.out, "verdict");
            try l.text("result", @tagName(judged.verdict));
            try l.num("kl_limit", judged.kl_limit, 4);
            try l.num("min_top1", o.min_top1, 3);
            try l.text("reason", judged.reason);
            try l.end();
        }
        return switch (judged.verdict) {
            .same => .ok,
            .differs => .failed,
            .unknown => .unreached,
        };
    }

    // ---- bench ----

    fn benchCmd(a: *App) Error!Exit {
        const o = a.o;
        const target = http.Target.parse(o.url) catch {
            complain(not_an_address, .{o.url});
            return .usage;
        };
        const limits: http.Limits = .{ .idle_ms = (o.timeout_s orelse 120) *| 1000 };
        const res = bench.run(a.gpa, a.arena, .{
            .target = target,
            .key = o.key orelse a.env("LLMCHECK_API_KEY"),
            .model = o.model,
            .insecure = o.insecure,
            .limits = limits,
        }, .{
            .concurrency = o.concurrency,
            .requests = o.requests,
            .duration_s = o.duration_s,
            .rate = o.rate,
            .max_tokens = o.max_tokens,
            .prompt_words = o.prompt_words,
            .warmup = o.warmup,
        }) catch |e| return a.down(o.url, e, limits);

        const summaries = .{ "ttft_ms", "latency_ms", "token_gap_ms", "stream_tokens_per_s" };
        if (o.json) {
            var j: std.json.Stringify = .{ .writer = a.out, .options = .{} };
            try j.beginObject();
            try field(&j, "command", "bench");
            try field(&j, "url", o.url);
            try field(&j, "model", res.model);
            try field(&j, "concurrency", o.concurrency);
            try field(&j, "rate", o.rate);
            try field(&j, "requests", res.requests);
            try field(&j, "errors", res.errors);
            try field(&j, "first_error", res.first_error);
            try field(&j, "late", if (o.rate != null) @as(?usize, res.late) else null);
            try field(&j, "seconds", res.seconds);
            try field(&j, "output_tokens", res.output_tokens);
            try field(&j, "output_tokens_estimated", res.estimated);
            try field(&j, "tokens_per_s", res.tokensPerS());
            try field(&j, "requests_per_s", res.requestsPerS());
            inline for (summaries) |name| try field(&j, name, @field(res, name));
            try j.endObject();
            try a.out.writeByte('\n');
        } else {
            var l = try Line.begin(a.out, "bench");
            if (res.model) |m| try l.text("model", m);
            try l.int("requests", res.requests);
            try l.int("errors", res.errors);
            try l.int("concurrency", o.concurrency);
            if (o.rate) |r| {
                try l.num("rate", r, 2);
                try l.int("late", res.late);
            }
            try l.num("seconds", res.seconds, 2);
            try l.int("output_tokens", res.output_tokens);
            if (res.estimated) try l.text("token_counts", "estimated");
            try l.num("tokens_per_s", res.tokensPerS(), 1);
            try l.num("requests_per_s", res.requestsPerS(), 2);
            try l.end();
            inline for (summaries) |name| {
                const sm: stats.Summary = @field(res, name);
                if (sm.n > 0) {
                    l = try Line.begin(a.out, name);
                    try l.int("n", sm.n);
                    try l.num("mean", sm.mean, 1);
                    try l.num("min", sm.min, 1);
                    try l.num("p50", sm.p50, 1);
                    try l.num("p90", sm.p90, 1);
                    try l.num("p99", sm.p99, 1);
                    try l.num("max", sm.max, 1);
                    try l.end();
                }
            }
            if (res.first_error) |e| {
                l = try Line.begin(a.out, "error");
                try l.text("first", e);
                try l.end();
            }
        }
        if (res.errors == 0) return .ok;
        return if (res.errors == res.requests) .unreached else .failed;
    }

    // ---- probe ----

    fn probeCmd(a: *App) Error!Exit {
        const o = a.o;
        var opts: probe.Options = .{ .max_kl = o.max_kl, .min_top1 = o.min_top1 };
        if (o.baseline) |path| opts.baseline = try a.readRecord(path) orelse return .usage;
        var s = a.openMain(10) orelse return .usage;
        defer s.deinit();

        var worst: Exit = .ok;
        var done: u32 = 0;
        while (true) {
            // what one probe needs is given back before the next
            var scratch = std.heap.ArenaAllocator.init(a.gpa);
            defer scratch.deinit();
            const started = std.time.Instant.now() catch null;
            const got = try probe.once(scratch.allocator(), &s, opts);
            var time_buf: [20]u8 = undefined;
            const time = probe.isoTime(&time_buf, @intCast(@max(0, std.time.timestamp())));
            if (o.json) {
                var j: std.json.Stringify = .{ .writer = a.out, .options = .{} };
                try j.beginObject();
                try field(&j, "command", "probe");
                try field(&j, "url", o.url);
                try field(&j, "time", time);
                try field(&j, "status", @tagName(got.status));
                inline for (.{ "problem", "model", "models_ms", "chat_ms", "ttft_ms", "drift_kl", "drift_top1" }) |name| {
                    try field(&j, name, @field(got, name));
                }
                try j.endObject();
                try a.out.writeByte('\n');
            } else {
                const l = try Line.begin(a.out, "probe");
                try l.text("status", @tagName(got.status));
                try l.text("time", time);
                if (got.model) |m| try l.text("model", m);
                if (got.models_ms) |v| try l.num("models_ms", v, 1);
                if (got.chat_ms) |v| try l.num("chat_ms", v, 1);
                if (got.ttft_ms) |v| try l.num("ttft_ms", v, 1);
                if (got.drift_kl) |v| try l.num("drift_kl", v, 4);
                if (got.drift_top1) |v| try l.num("drift_top1", v, 3);
                if (got.problem) |p| try l.text("problem", p);
                try l.end();
            }
            try a.out.flush();
            switch (got.status) {
                .ok => {},
                .fail, .drift => if (worst == .ok) {
                    worst = .failed;
                },
                .down => worst = .unreached,
            }
            done += 1;
            const every = o.every_s orelse break;
            if (o.count) |n| if (done >= n) break;
            // from start to start, so that the probes keep their beat
            const period: u64 = @intFromFloat(every * std.time.ns_per_s);
            var spent: u64 = 0;
            if (started) |t0| {
                if (std.time.Instant.now()) |t1| spent = t1.since(t0) else |_| {}
            }
            if (spent < period) std.Thread.sleep(period - spent);
        }
        return worst;
    }
};

// ---- tests ----

const testing = std.testing;

test "a_value_with_spaces_is_quoted_and_a_plain_word_is_not" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeValue(&w, "pass");
    try w.writeByte('|');
    try writeValue(&w, "no answer within 2 s");
    try w.writeByte('|');
    try writeValue(&w, "");
    try w.writeByte('|');
    try writeValue(&w, "got '{\"a\":1}'\nnext");
    try testing.expectEqualStrings("pass|\"no answer within 2 s\"|\"\"|\"got '{\\\"a\\\":1}' next\"", w.buffered());
}

test {
    std.testing.refAllDecls(@This());
    _ = sock;
    _ = http;
    _ = jv;
    _ = sse;
    _ = stats;
    _ = fidelity;
    _ = api;
    _ = check;
    _ = args;
    _ = bench;
    _ = probe;
}
