//! Command line to Options. Pure: no I/O.
const std = @import("std");

pub const Mode = enum { check, fidelity, bench, probe, help, version };

pub const Options = struct {
    mode: Mode = .help,
    /// For help: the command it was asked about.
    topic: ?Mode = null,

    url: []const u8 = "",
    model: ?[]const u8 = null,
    key: ?[]const u8 = null,
    timeout_s: ?u32 = null,
    insecure: bool = false,
    json: bool = false,

    // check, fidelity
    ref: ?[]const u8 = null,
    ref_model: ?[]const u8 = null,
    ref_key: ?[]const u8 = null,

    // check
    only: ?[]const u8 = null,
    skip: ?[]const u8 = null,
    max_prompt_words: u32 = 8192,

    // fidelity (the two limits also for probe --baseline)
    against: ?[]const u8 = null,
    record: ?[]const u8 = null,
    prompts: ?[]const u8 = null,
    tokens: u32 = 16,
    top: u32 = 5,
    max_kl: f64 = 0.01,
    min_top1: f64 = 0.95,

    // bench
    concurrency: u32 = 16,
    requests: ?u32 = null,
    duration_s: ?f64 = null,
    rate: ?f64 = null,
    max_tokens: u32 = 64,
    prompt_words: u32 = 64,
    warmup: u32 = 1,

    // probe
    every_s: ?f64 = null,
    count: ?u32 = null,
    baseline: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    ok: Options,
    /// What is wrong with the command line, for the user.
    err: []const u8,
};

const Kind = enum { flag, text, whole, positive, seconds, fraction, amount };

const Opt = struct {
    name: []const u8,
    field: []const u8,
    kind: Kind,
    modes: []const Mode,
};

const served = [_]Mode{ .check, .fidelity, .bench, .probe };

const opts = [_]Opt{
    .{ .name = "--model", .field = "model", .kind = .text, .modes = &served },
    .{ .name = "--key", .field = "key", .kind = .text, .modes = &served },
    .{ .name = "--timeout", .field = "timeout_s", .kind = .positive, .modes = &served },
    .{ .name = "--insecure", .field = "insecure", .kind = .flag, .modes = &served },
    .{ .name = "--json", .field = "json", .kind = .flag, .modes = &served },
    .{ .name = "--ref", .field = "ref", .kind = .text, .modes = &.{ .check, .fidelity } },
    .{ .name = "--ref-model", .field = "ref_model", .kind = .text, .modes = &.{ .check, .fidelity } },
    .{ .name = "--ref-key", .field = "ref_key", .kind = .text, .modes = &.{ .check, .fidelity } },
    .{ .name = "--only", .field = "only", .kind = .text, .modes = &.{.check} },
    .{ .name = "--skip", .field = "skip", .kind = .text, .modes = &.{.check} },
    .{ .name = "--max-prompt-words", .field = "max_prompt_words", .kind = .whole, .modes = &.{.check} },
    .{ .name = "--against", .field = "against", .kind = .text, .modes = &.{.fidelity} },
    .{ .name = "--record", .field = "record", .kind = .text, .modes = &.{.fidelity} },
    .{ .name = "--prompts", .field = "prompts", .kind = .text, .modes = &.{.fidelity} },
    .{ .name = "--tokens", .field = "tokens", .kind = .positive, .modes = &.{.fidelity} },
    .{ .name = "--top", .field = "top", .kind = .positive, .modes = &.{.fidelity} },
    .{ .name = "--max-kl", .field = "max_kl", .kind = .amount, .modes = &.{ .fidelity, .probe } },
    .{ .name = "--min-top1", .field = "min_top1", .kind = .fraction, .modes = &.{ .fidelity, .probe } },
    .{ .name = "--concurrency", .field = "concurrency", .kind = .positive, .modes = &.{.bench} },
    .{ .name = "--requests", .field = "requests", .kind = .positive, .modes = &.{.bench} },
    .{ .name = "--duration", .field = "duration_s", .kind = .seconds, .modes = &.{.bench} },
    .{ .name = "--rate", .field = "rate", .kind = .seconds, .modes = &.{.bench} },
    .{ .name = "--max-tokens", .field = "max_tokens", .kind = .positive, .modes = &.{.bench} },
    .{ .name = "--prompt-words", .field = "prompt_words", .kind = .positive, .modes = &.{.bench} },
    .{ .name = "--warmup", .field = "warmup", .kind = .whole, .modes = &.{.bench} },
    .{ .name = "--every", .field = "every_s", .kind = .seconds, .modes = &.{.probe} },
    .{ .name = "--count", .field = "count", .kind = .positive, .modes = &.{.probe} },
    .{ .name = "--baseline", .field = "baseline", .kind = .text, .modes = &.{.probe} },
};

const commands = "check, fidelity, bench, probe";

fn command(name: []const u8) ?Mode {
    for (served) |m| if (std.mem.eql(u8, name, @tagName(m))) return m;
    return null;
}

fn has(modes: []const Mode, mode: Mode) bool {
    for (modes) |m| if (m == mode) return true;
    return false;
}

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help");
}

/// `argv` without the program's name.
pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) !Parsed {
    if (argv.len == 0 or isHelp(argv[0])) return .{ .ok = .{ .mode = .help } };
    const first = argv[0];
    if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version")) return .{ .ok = .{ .mode = .version } };
    if (std.mem.eql(u8, first, "help")) {
        if (argv.len < 2) return .{ .ok = .{ .mode = .help } };
        const topic = command(argv[1]) orelse return fail(arena, "no command '{s}' (" ++ commands ++ ")", .{argv[1]});
        return .{ .ok = .{ .mode = .help, .topic = topic } };
    }
    const mode = command(first) orelse return fail(arena, "no command '{s}' (" ++ commands ++ ")", .{first});
    for (argv[1..]) |a| if (isHelp(a)) return .{ .ok = .{ .mode = .help, .topic = mode } };

    var o: Options = .{ .mode = mode };
    var given = [_]bool{false} ** opts.len;
    var have_url = false;
    var i: usize = 1;
    args: while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') {
            if (have_url) return fail(arena, "one address at a time: '{s}' is a second one", .{a});
            o.url = a;
            have_url = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = if (eq) |e| a[0..e] else a;
        inline for (opts, 0..) |opt, n| {
            if (std.mem.eql(u8, name, opt.name)) {
                if (!has(opt.modes, mode)) {
                    var of: std.ArrayList(u8) = .empty;
                    for (opt.modes, 0..) |m, k| {
                        if (k > 0) try of.appendSlice(arena, " and ");
                        try of.appendSlice(arena, @tagName(m));
                    }
                    return fail(arena, "{s} is an option of {s}, not of {s}", .{ name, of.items, @tagName(mode) });
                }
                given[n] = true;
                if (opt.kind == .flag) {
                    if (eq != null) return fail(arena, "{s} takes no value", .{name});
                    @field(o, opt.field) = true;
                    continue :args;
                }
                const value = if (eq) |e| a[e + 1 ..] else blk: {
                    i += 1;
                    if (i >= argv.len) return fail(arena, "{s} needs a value", .{name});
                    break :blk argv[i];
                };
                switch (opt.kind) {
                    .flag => unreachable,
                    .text => {
                        if (value.len == 0) return fail(arena, "{s} needs a value", .{name});
                        @field(o, opt.field) = value;
                    },
                    .whole => @field(o, opt.field) = std.fmt.parseInt(u32, value, 10) catch
                        return fail(arena, "{s} needs a whole number, not '{s}'", .{ name, value }),
                    .positive => {
                        const v = std.fmt.parseInt(u32, value, 10) catch 0;
                        if (v == 0) return fail(arena, "{s} needs a whole number above 0, not '{s}'", .{ name, value });
                        @field(o, opt.field) = v;
                    },
                    .seconds => {
                        const v = number(value) orelse -1;
                        if (v <= 0) return fail(arena, "{s} needs a number above 0, not '{s}'", .{ name, value });
                        @field(o, opt.field) = v;
                    },
                    .fraction => {
                        const v = number(value) orelse -1;
                        if (v < 0 or v > 1) return fail(arena, "{s} needs a number from 0 to 1, not '{s}'", .{ name, value });
                        @field(o, opt.field) = v;
                    },
                    .amount => {
                        const v = number(value) orelse -1;
                        if (v < 0) return fail(arena, "{s} needs a number of 0 or more, not '{s}'", .{ name, value });
                        @field(o, opt.field) = v;
                    },
                }
                continue :args;
            }
        }
        return fail(arena, "no option '{s}'", .{name});
    }
    if (!have_url) return fail(arena, "{s} needs the server's address, such as http://localhost:8000", .{@tagName(mode)});

    switch (mode) {
        .fidelity => {
            if (o.ref != null and o.against != null) return fail(arena, "--ref and --against are two references: give one", .{});
            if (o.record != null and o.ref != null) return fail(arena, "--record saves this server's answers and compares nothing: leave out --ref", .{});
            if (o.record != null and o.against != null) return fail(arena, "--record saves this server's answers and compares nothing: leave out --against", .{});
            if (o.ref == null and o.against == null and o.record == null) {
                return fail(arena, "fidelity needs --ref URL or --against FILE to compare with, or --record FILE to save this server's answers", .{});
            }
            if (o.against != null) {
                if (o.prompts != null) return fail(arena, "--against asks the prompts in its file: leave out --prompts", .{});
                inline for (opts, 0..) |opt, n| {
                    if (comptime (std.mem.eql(u8, opt.name, "--tokens") or std.mem.eql(u8, opt.name, "--top"))) {
                        if (given[n]) return fail(arena, "--against uses the {s} of its file: leave it out", .{opt.name});
                    }
                }
            }
            if (o.top > 20) return fail(arena, "--top is at most 20", .{});
            if (o.tokens > 256) return fail(arena, "--tokens is at most 256", .{});
        },
        .bench => {
            if (o.requests != null and o.duration_s != null) return fail(arena, "--requests and --duration are two ways to end: give one", .{});
            if (o.concurrency > 256) return fail(arena, "--concurrency is at most 256", .{});
        },
        .probe => {
            if (o.count != null and o.every_s == null) return fail(arena, "--count needs --every: how long to wait between probes", .{});
        },
        else => {},
    }
    return .{ .ok = o };
}

fn number(text: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

fn fail(arena: std.mem.Allocator, comptime fmt: []const u8, a: anytype) !Parsed {
    return .{ .err = try std.fmt.allocPrint(arena, fmt, a) };
}

// ---- tests ----

const testing = std.testing;

fn ok(argv: []const []const u8) !Options {
    const arena = arena_state.allocator();
    const p = try parse(arena, argv);
    switch (p) {
        .ok => |o| return o,
        .err => |m| {
            std.debug.print("refused: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

fn refused(argv: []const []const u8, text: []const u8) !void {
    const arena = arena_state.allocator();
    const p = try parse(arena, argv);
    switch (p) {
        .ok => {
            std.debug.print("accepted, but wanted \"{s}\"\n", .{text});
            return error.TestUnexpectedResult;
        },
        .err => |m| try testing.expectEqualStrings(text, m),
    }
}

var arena_state: std.heap.ArenaAllocator = undefined;

fn begin() void {
    arena_state = std.heap.ArenaAllocator.init(testing.allocator);
}

test "a_check_takes_an_address_and_its_options" {
    begin();
    defer arena_state.deinit();
    const o = try ok(&.{ "check", "http://localhost:8000", "--model", "m", "--key=k", "--ref", "http://ref:8080", "--only", "chat,stream", "--timeout", "30", "--json", "--insecure", "--max-prompt-words", "0" });
    try testing.expectEqual(Mode.check, o.mode);
    try testing.expectEqualStrings("http://localhost:8000", o.url);
    try testing.expectEqualStrings("m", o.model.?);
    try testing.expectEqualStrings("k", o.key.?);
    try testing.expectEqualStrings("http://ref:8080", o.ref.?);
    try testing.expectEqualStrings("chat,stream", o.only.?);
    try testing.expectEqual(@as(?u32, 30), o.timeout_s);
    try testing.expect(o.json and o.insecure);
    try testing.expectEqual(@as(u32, 0), o.max_prompt_words);
    // options may come before the address
    const p = try ok(&.{ "check", "--json", "http://h" });
    try testing.expectEqualStrings("http://h", p.url);
    try testing.expect(p.model == null and p.timeout_s == null and p.max_prompt_words == 8192);
}

test "nothing_or_help_asks_for_the_usage" {
    begin();
    defer arena_state.deinit();
    try testing.expectEqual(Mode.help, (try ok(&.{})).mode);
    try testing.expect((try ok(&.{"help"})).topic == null);
    try testing.expectEqual(@as(?Mode, .bench), (try ok(&.{ "help", "bench" })).topic);
    const o = try ok(&.{ "fidelity", "--help" });
    try testing.expectEqual(Mode.help, o.mode);
    try testing.expectEqual(@as(?Mode, .fidelity), o.topic);
    try testing.expectEqual(Mode.help, (try ok(&.{"-h"})).mode);
    try testing.expectEqual(Mode.version, (try ok(&.{"version"})).mode);
    try testing.expectEqual(Mode.version, (try ok(&.{"--version"})).mode);
    try refused(&.{ "help", "nonsense" }, "no command 'nonsense' (check, fidelity, bench, probe)");
}

test "what_is_wrong_with_a_command_line_is_said" {
    begin();
    defer arena_state.deinit();
    try refused(&.{"chek"}, "no command 'chek' (check, fidelity, bench, probe)");
    try refused(&.{"check"}, "check needs the server's address, such as http://localhost:8000");
    try refused(&.{ "check", "http://a", "http://b" }, "one address at a time: 'http://b' is a second one");
    try refused(&.{ "check", "http://a", "--modle", "m" }, "no option '--modle'");
    try refused(&.{ "check", "http://a", "--concurrency", "4" }, "--concurrency is an option of bench, not of check");
    try refused(&.{ "check", "http://a", "--model" }, "--model needs a value");
    try refused(&.{ "check", "http://a", "--json=yes" }, "--json takes no value");
    try refused(&.{ "check", "http://a", "--timeout", "soon" }, "--timeout needs a whole number above 0, not 'soon'");
    try refused(&.{ "check", "http://a", "--timeout", "0" }, "--timeout needs a whole number above 0, not '0'");
    try refused(&.{ "check", "http://a", "--max-prompt-words", "-1" }, "--max-prompt-words needs a whole number, not '-1'");
    try refused(&.{ "bench", "http://a", "--duration", "0" }, "--duration needs a number above 0, not '0'");
    try refused(&.{ "fidelity", "http://a", "--against", "f", "--min-top1", "95" }, "--min-top1 needs a number from 0 to 1, not '95'");
    try refused(&.{ "fidelity", "http://a", "--against", "f", "--max-kl", "-1" }, "--max-kl needs a number of 0 or more, not '-1'");
}

test "fidelity_needs_something_to_compare_with_or_to_record" {
    begin();
    defer arena_state.deinit();
    const a = try ok(&.{ "fidelity", "http://a", "--ref", "http://b", "--tokens", "8", "--top", "3", "--max-kl", "0.05", "--min-top1", "0.9" });
    try testing.expectEqual(@as(u32, 8), a.tokens);
    try testing.expectEqual(@as(u32, 3), a.top);
    try testing.expectEqual(@as(f64, 0.05), a.max_kl);
    try testing.expectEqual(@as(f64, 0.9), a.min_top1);
    const b = try ok(&.{ "fidelity", "http://a", "--against", "ref.json" });
    try testing.expectEqualStrings("ref.json", b.against.?);
    try testing.expect(b.tokens == 16 and b.top == 5 and b.max_kl == 0.01 and b.min_top1 == 0.95);
    _ = try ok(&.{ "fidelity", "http://a", "--record", "ref.json", "--prompts", "p.txt" });
    try refused(&.{ "fidelity", "http://a" }, "fidelity needs --ref URL or --against FILE to compare with, or --record FILE to save this server's answers");
    try refused(&.{ "fidelity", "http://a", "--ref", "http://b", "--against", "f" }, "--ref and --against are two references: give one");
    try refused(&.{ "fidelity", "http://a", "--ref", "http://b", "--record", "f" }, "--record saves this server's answers and compares nothing: leave out --ref");
    try refused(&.{ "fidelity", "http://a", "--against", "f", "--prompts", "p" }, "--against asks the prompts in its file: leave out --prompts");
    try refused(&.{ "fidelity", "http://a", "--against", "f", "--tokens", "4" }, "--against uses the --tokens of its file: leave it out");
    try refused(&.{ "fidelity", "http://a", "--ref", "http://b", "--top", "21" }, "--top is at most 20");
    try refused(&.{ "fidelity", "http://a", "--ref", "http://b", "--tokens", "999" }, "--tokens is at most 256");
}

test "a_benchmark_runs_for_a_count_or_a_time" {
    begin();
    defer arena_state.deinit();
    const a = try ok(&.{ "bench", "http://a" });
    try testing.expect(a.concurrency == 16 and a.requests == null and a.duration_s == null and a.rate == null);
    try testing.expect(a.max_tokens == 64 and a.prompt_words == 64 and a.warmup == 1);
    const b = try ok(&.{ "bench", "http://a", "--concurrency", "4", "--duration", "2.5", "--rate", "10", "--max-tokens", "8", "--prompt-words", "200", "--warmup", "0" });
    try testing.expectEqual(@as(u32, 4), b.concurrency);
    try testing.expectEqual(@as(?f64, 2.5), b.duration_s);
    try testing.expectEqual(@as(?f64, 10), b.rate);
    try testing.expect(b.max_tokens == 8 and b.prompt_words == 200 and b.warmup == 0);
    try refused(&.{ "bench", "http://a", "--requests", "5", "--duration", "2" }, "--requests and --duration are two ways to end: give one");
    try refused(&.{ "bench", "http://a", "--concurrency", "257" }, "--concurrency is at most 256");
}

test "a_probe_runs_once_or_again_and_again" {
    begin();
    defer arena_state.deinit();
    const a = try ok(&.{ "probe", "http://a" });
    try testing.expect(a.every_s == null and a.count == null and a.baseline == null);
    const b = try ok(&.{ "probe", "http://a", "--every", "60", "--count", "3", "--baseline", "ref.json", "--max-kl", "0.02" });
    try testing.expectEqual(@as(?f64, 60), b.every_s);
    try testing.expectEqual(@as(?u32, 3), b.count);
    try testing.expectEqualStrings("ref.json", b.baseline.?);
    try testing.expectEqual(@as(f64, 0.02), b.max_kl);
    try refused(&.{ "probe", "http://a", "--count", "3" }, "--count needs --every: how long to wait between probes");
}
