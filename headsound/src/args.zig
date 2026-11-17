//! Command line to a Request. Pure: no I/O.
const std = @import("std");
const Fps = @import("markers.zig").Fps;

pub const Command = enum { info, scan, sounds, speech, voice, transcribe, cut, trim, normalize, convert, declick, dehum, listen, help, version };

pub const Request = struct {
    cmd: Command,
    /// The first file; `files` walks all of them.
    file: ?[]const u8 = null,
    file_count: usize = 0,
    second_file: []const u8 = "",
    out: ?[]const u8 = null,
    json: bool = false,
    min_pause_ms: u32 = 300,
    pause_ms: u32 = 500,
    pad_ms: u32 = 100,
    from_s: ?f64 = null,
    to_s: ?f64 = null,
    lufs: f64 = -16,
    peak: f64 = -1,
    rate: ?u32 = null,
    mono: bool = false,
    bits: ?u16 = null,
    timeout_s: f64 = 30,
    silence_ms: u32 = 800,
    max_s: f64 = 30,
    input: ?[]const u8 = null,
    help_topic: ?[]const u8 = null,
    /// Marker outputs: WAV with cue points, Audacity labels, CD cue sheet.
    markers: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    cue: ?[]const u8 = null,
    /// Audition marker list, Resolve marker EDL, SRT/WebVTT subtitles.
    audition: ?[]const u8 = null,
    edl: ?[]const u8 = null,
    /// Standard MIDI File with marker events (Pro Tools, Logic, Cubase).
    midi: ?[]const u8 = null,
    subtitles: ?[]const u8 = null,
    fps: ?Fps = null,
    /// HH:MM:SS:FF of the timeline's start, checked against `fps`.
    edl_start: [4]u32 = .{ 1, 0, 0, 0 },
    edl_start_given: bool = false,
    /// scan: also say what is heard (the classifier).
    sounds: bool = false,
    min_confidence: f64 = 0.5,
    list: bool = false,
    freq: ?f64 = null,
    /// transcribe: the language ("en-US"); null: the user's.
    lang: ?[]const u8 = null,
    /// transcribe: a line per word too.
    words: bool = false,
    /// listen: say what was said, too.
    text: bool = false,

    /// Every file named in `argv` (the same argv given to `parse`).
    pub fn files(_: Request, argv: []const []const u8) FileIterator {
        return .{ .argv = argv };
    }

    /// Several files: the measuring commands, without marker files.
    pub fn manyAllowed(r: Request) bool {
        const measuring = switch (r.cmd) {
            .info, .scan, .sounds, .speech, .voice, .transcribe => true,
            else => false,
        };
        return measuring and r.markers == null and r.labels == null and r.cue == null and
            r.audition == null and r.edl == null and r.midi == null and r.subtitles == null;
    }

    /// The EDL timeline's start timecode in frames.
    pub fn edlStart(r: Request) u64 {
        const t = r.edl_start;
        const base: u64 = if (r.fps) |f| f.base else 0;
        return ((@as(u64, t[0]) * 60 + t[1]) * 60 + t[2]) * base + t[3];
    }
};

pub const FileIterator = struct {
    argv: []const []const u8,
    i: usize = 1,

    pub fn next(it: *FileIterator) ?[]const u8 {
        while (it.i < it.argv.len) {
            const a = it.argv[it.i];
            it.i += 1;
            const is_short = a.len == 2 and a[0] == '-' and a[1] != '-';
            if (!std.mem.startsWith(u8, a, "--") and !is_short) return a;
            const body = if (is_short) a[1..] else a[2..];
            if (std.mem.indexOfScalar(u8, body, '=') != null) continue;
            if (parseFlag(body)) |f| if (takesValue(f)) {
                it.i += 1;
            };
        }
        return null;
    }
};

pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(d: *Diag, comptime fmt: []const u8, a: anytype) void {
        const s = std.fmt.bufPrint(&d.buf, fmt, a) catch d.buf[0..];
        d.len = s.len;
    }
    pub fn msg(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }
};

pub const Error = error{Usage};

const Flag = enum { out, json, min_pause, pause, pad, from, to, lufs, peak, rate, mono, bits, timeout, silence, max, input, markers, labels, cue, audition, edl, midi, subtitles, fps, edl_start, sounds, min_confidence, list, freq, lang, words, text };

fn isMarkerFlag(f: Flag) bool {
    return switch (f) {
        .markers, .labels, .cue, .audition, .edl, .midi, .subtitles, .fps, .edl_start => true,
        else => false,
    };
}

fn allowed(cmd: Command, f: Flag) bool {
    return switch (cmd) {
        .info => f == .json,
        .scan => f == .json or f == .sounds or f == .min_confidence or isMarkerFlag(f),
        .sounds => f == .json or f == .min_confidence or f == .list or isMarkerFlag(f),
        .speech => f == .json or f == .min_pause or isMarkerFlag(f),
        .voice => f == .json or f == .min_pause,
        .transcribe => f == .json or f == .lang or f == .words or isMarkerFlag(f),
        .declick => f == .out or f == .json,
        .dehum => f == .out or f == .json or f == .freq,
        .cut => switch (f) {
            .out, .json, .pause, .min_pause => true,
            else => false,
        },
        .trim => switch (f) {
            .out, .json, .from, .to, .pad => true,
            else => false,
        },
        .normalize => switch (f) {
            .out, .json, .lufs, .peak, .bits => true,
            else => false,
        },
        .convert => switch (f) {
            .out, .json, .rate, .mono, .bits => true,
            else => false,
        },
        .listen => switch (f) {
            .out, .json, .timeout, .silence, .max, .input, .text, .lang => true,
            else => false,
        },
        .help, .version => false,
    };
}

fn takesValue(f: Flag) bool {
    return switch (f) {
        .json, .mono, .sounds, .list, .words, .text => false,
        else => true,
    };
}

fn flagName(f: Flag) []const u8 {
    return switch (f) {
        .min_pause => "min-pause",
        .min_confidence => "min-confidence",
        .edl_start => "edl-start",
        else => @tagName(f),
    };
}

fn parseFlag(name: []const u8) ?Flag {
    if (std.mem.eql(u8, name, "o")) return .out;
    if (std.mem.eql(u8, name, "min-pause")) return .min_pause;
    if (std.mem.eql(u8, name, "min-confidence")) return .min_confidence;
    if (std.mem.eql(u8, name, "edl-start")) return .edl_start;
    if (std.mem.indexOfScalar(u8, name, '_') != null) return null;
    return std.meta.stringToEnum(Flag, name);
}

pub fn parse(argv: []const []const u8, diag: *Diag) Error!Request {
    if (argv.len == 0) return .{ .cmd = .help };
    const first = argv[0];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) return .{ .cmd = .help };
    if (std.mem.eql(u8, first, "--version")) return .{ .cmd = .version };
    const cmd = std.meta.stringToEnum(Command, first) orelse {
        diag.set("unknown command '{s}' (try 'headsound help')", .{first});
        return error.Usage;
    };
    var r = Request{ .cmd = cmd };
    if (cmd == .help) {
        if (argv.len > 1) r.help_topic = argv[1];
        return r;
    }
    if (cmd == .version) return r;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const is_short = a.len == 2 and a[0] == '-' and a[1] != '-';
        if (!std.mem.startsWith(u8, a, "--") and !is_short) {
            if (r.file == null) r.file = a else if (r.file_count == 1) {
                r.second_file = a;
            }
            r.file_count += 1;
            continue;
        }
        const body = if (is_short) a[1..] else a[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const name = if (eq) |e| body[0..e] else body;
        const flag = parseFlag(name) orelse {
            diag.set("unknown option '{s}' (try 'headsound help {s}')", .{ a, @tagName(cmd) });
            return error.Usage;
        };
        if (!allowed(cmd, flag)) {
            diag.set("'{s}' doesn't take --{s}", .{ @tagName(cmd), flagName(flag) });
            return error.Usage;
        }
        var value: []const u8 = "";
        if (takesValue(flag)) {
            if (eq) |e| {
                value = body[e + 1 ..];
            } else {
                i += 1;
                if (i >= argv.len) {
                    diag.set("--{s} needs a value", .{flagName(flag)});
                    return error.Usage;
                }
                value = argv[i];
            }
        } else if (eq != null) {
            diag.set("--{s} takes no value", .{flagName(flag)});
            return error.Usage;
        }
        switch (flag) {
            .out => r.out = value,
            .input => r.input = value,
            .markers => r.markers = value,
            .labels => r.labels = value,
            .cue => r.cue = value,
            .audition => r.audition = value,
            .edl => r.edl = value,
            .midi => r.midi = value,
            .subtitles => r.subtitles = value,
            .fps => r.fps = Fps.parse(value) orelse {
                diag.set("--fps is the timeline's frame rate: {s}", .{Fps.names});
                return error.Usage;
            },
            .edl_start => {
                r.edl_start = timecode(value) orelse {
                    diag.set("--edl-start is the timeline's start timecode, HH:MM:SS:FF (non-drop frame)", .{});
                    return error.Usage;
                };
                r.edl_start_given = true;
            },
            .json => r.json = true,
            .mono => r.mono = true,
            .sounds => r.sounds = true,
            .list => r.list = true,
            .words => r.words = true,
            .text => r.text = true,
            .lang => {
                if (!@import("transcript.zig").validLocale(value)) {
                    diag.set("--lang is a language and region, as en-US or en-GB", .{});
                    return error.Usage;
                }
                r.lang = value;
            },
            .min_confidence => r.min_confidence = try float(value, "min-confidence", 0.05, 1, diag),
            .freq => {
                const f = try float(value, "freq", 40, 70, diag);
                if (f != 50 and f != 60) {
                    diag.set("--freq is 50 or 60 (the mains frequency)", .{});
                    return error.Usage;
                }
                r.freq = f;
            },
            .min_pause => r.min_pause_ms = try int(u32, value, "min-pause", 10, 60_000, "milliseconds", diag),
            .pause => r.pause_ms = try int(u32, value, "pause", 50, 60_000, "milliseconds", diag),
            .pad => r.pad_ms = try int(u32, value, "pad", 0, 10_000, "milliseconds", diag),
            .silence => r.silence_ms = try int(u32, value, "silence", 100, 60_000, "milliseconds", diag),
            .rate => r.rate = try int(u32, value, "rate", 4000, 192_000, "Hz", diag),
            .bits => {
                const b = try int(u16, value, "bits", 16, 24, "", diag);
                if (b != 16 and b != 24) {
                    diag.set("--bits is 16 or 24", .{});
                    return error.Usage;
                }
                r.bits = b;
            },
            .from => r.from_s = try float(value, "from", 0, 1e7, diag),
            .to => r.to_s = try float(value, "to", 0, 1e7, diag),
            .lufs => r.lufs = try float(value, "lufs", -70, 0, diag),
            .peak => r.peak = try float(value, "peak", -40, 0, diag),
            .timeout => r.timeout_s = try float(value, "timeout", 0.5, 86_400, diag),
            .max => r.max_s = try float(value, "max", 1, 3600, diag),
        }
    }
    try check(&r, diag);
    return r;
}

fn check(r: *Request, diag: *Diag) Error!void {
    const needs_file = switch (r.cmd) {
        .info, .scan, .speech, .voice, .transcribe, .cut, .trim, .normalize, .convert, .declick, .dehum => true,
        .sounds => !r.list,
        else => false,
    };
    if (needs_file and r.file == null) {
        diag.set("{s}: which file? (headsound {s} FILE)", .{ @tagName(r.cmd), @tagName(r.cmd) });
        return error.Usage;
    }
    if (r.file_count > 1 and !r.manyAllowed()) {
        if (r.cmd == .listen) {
            diag.set("listen takes no file; to listen to a recording use --input FILE", .{});
        } else if (r.cmd == .help or r.cmd == .version or r.out != null or r.cmd == .cut or r.cmd == .trim or r.cmd == .normalize or r.cmd == .convert or r.cmd == .declick or r.cmd == .dehum) {
            diag.set("{s}: one file at a time ('{s}' is extra)", .{ @tagName(r.cmd), r.second_file });
        } else {
            diag.set("marker files are written for one file at a time ('{s}' is extra)", .{r.second_file});
        }
        return error.Usage;
    }
    if (r.cmd == .listen and r.lang != null and !r.text) {
        diag.set("--lang goes only with --text", .{});
        return error.Usage;
    }
    if (r.cmd == .listen and r.file != null) {
        diag.set("listen takes no file; to listen to a recording use --input FILE", .{});
        return error.Usage;
    }
    if (r.list and r.file != null) {
        diag.set("sounds --list takes no file", .{});
        return error.Usage;
    }
    const edits = switch (r.cmd) {
        .cut, .trim, .normalize, .convert, .declick, .dehum => true,
        else => false,
    };
    if (edits and r.out == null) {
        diag.set("{s}: where to? (-o OUT.wav)", .{@tagName(r.cmd)});
        return error.Usage;
    }
    if (r.out) |o| if (!std.ascii.endsWithIgnoreCase(o, ".wav")) {
        diag.set("only WAV is written: give -o a name ending in .wav", .{});
        return error.Usage;
    };
    if (r.markers) |o| if (!std.ascii.endsWithIgnoreCase(o, ".wav")) {
        diag.set("--markers writes a WAV copy with cue points: give it a name ending in .wav", .{});
        return error.Usage;
    };
    if (r.labels) |o| if (!std.ascii.endsWithIgnoreCase(o, ".txt")) {
        diag.set("--labels writes an Audacity label file: give it a name ending in .txt", .{});
        return error.Usage;
    };
    if (r.cue) |o| if (!std.ascii.endsWithIgnoreCase(o, ".cue")) {
        diag.set("--cue writes a cue sheet: give it a name ending in .cue", .{});
        return error.Usage;
    };
    if (r.audition) |o| if (!std.ascii.endsWithIgnoreCase(o, ".csv")) {
        diag.set("--audition writes an Audition marker list: give it a name ending in .csv", .{});
        return error.Usage;
    };
    if (r.edl) |o| if (!std.ascii.endsWithIgnoreCase(o, ".edl")) {
        diag.set("--edl writes Resolve timeline markers: give it a name ending in .edl", .{});
        return error.Usage;
    };
    if (r.midi) |o| if (!std.ascii.endsWithIgnoreCase(o, ".mid")) {
        diag.set("--midi writes a MIDI file of markers: give it a name ending in .mid", .{});
        return error.Usage;
    };
    if (r.subtitles) |o| if (!std.ascii.endsWithIgnoreCase(o, ".srt") and !std.ascii.endsWithIgnoreCase(o, ".vtt")) {
        diag.set("--subtitles writes SRT or WebVTT: give it a name ending in .srt or .vtt", .{});
        return error.Usage;
    };
    if (r.edl != null and r.fps == null) {
        diag.set("--edl needs the timeline's frame rate: --fps {s}", .{Fps.names});
        return error.Usage;
    }
    if (r.edl == null and (r.fps != null or r.edl_start_given)) {
        diag.set("--fps and --edl-start go only with --edl", .{});
        return error.Usage;
    }
    if (r.fps) |f| if (r.edl_start[3] >= f.base) {
        diag.set("--edl-start is HH:MM:SS:FF, with fewer than {d} frames", .{f.base});
        return error.Usage;
    };
    if (r.file) |f| for ([_]?[]const u8{ r.out, r.markers }) |o| if (o) |path| if (std.mem.eql(u8, f, path)) {
        diag.set("write to a new file, not over '{s}'", .{f});
        return error.Usage;
    };
    if (r.from_s != null and r.to_s != null and r.to_s.? <= r.from_s.?) {
        diag.set("--to must be after --from", .{});
        return error.Usage;
    }
    if (r.cmd == .convert and r.rate == null and !r.mono and r.bits == null) {
        diag.set("convert: nothing to change (--rate HZ, --mono, --bits 16|24)", .{});
        return error.Usage;
    }
}

/// HH:MM:SS:FF (frames checked later, against the frame rate).
fn timecode(v: []const u8) ?[4]u32 {
    var out: [4]u32 = undefined;
    var it = std.mem.splitScalar(u8, v, ':');
    for (&out, 0..) |*p, i| {
        const part = it.next() orelse return null;
        if (part.len != 2) return null;
        p.* = std.fmt.parseInt(u32, part, 10) catch return null;
        if (i > 0 and i < 3 and p.* >= 60) return null;
    }
    if (it.next() != null) return null;
    return out;
}

fn int(comptime T: type, v: []const u8, name: []const u8, lo: T, hi: T, unit: []const u8, diag: *Diag) Error!T {
    const n = std.fmt.parseInt(T, v, 10) catch {
        diag.set("--{s} needs a whole number{s}{s}, not '{s}'", .{ name, if (unit.len > 0) " of " else "", unit, v });
        return error.Usage;
    };
    if (n < lo or n > hi) {
        diag.set("--{s} must be {d} to {d}{s}{s}", .{ name, lo, hi, if (unit.len > 0) " " else "", unit });
        return error.Usage;
    }
    return n;
}

fn float(v: []const u8, name: []const u8, lo: f64, hi: f64, diag: *Diag) Error!f64 {
    const n = std.fmt.parseFloat(f64, v) catch {
        diag.set("--{s} needs a number, not '{s}'", .{ name, v });
        return error.Usage;
    };
    if (!(n >= lo and n <= hi)) {
        diag.set("--{s} must be {d} to {d}", .{ name, lo, hi });
        return error.Usage;
    }
    return n;
}

// ---- tests ----

const testing = std.testing;

fn ok(argv: []const []const u8) !Request {
    var d = Diag{};
    return parse(argv, &d) catch |e| {
        std.debug.print("unexpected: {s}\n", .{d.msg()});
        return e;
    };
}

fn bad(argv: []const []const u8, want: []const u8) !void {
    var d = Diag{};
    try testing.expectError(error.Usage, parse(argv, &d));
    if (std.mem.indexOf(u8, d.msg(), want) == null) {
        std.debug.print("message '{s}' lacks '{s}'\n", .{ d.msg(), want });
        return error.TestUnexpectedResult;
    }
}

test "commands_and_files" {
    const r = try ok(&.{ "info", "a.m4a", "--json" });
    try testing.expectEqual(Command.info, r.cmd);
    try testing.expectEqualStrings("a.m4a", r.file.?);
    try testing.expect(r.json);
    try testing.expectEqual(Command.help, (try ok(&.{})).cmd);
    try testing.expectEqualStrings("cut", (try ok(&.{ "help", "cut" })).help_topic.?);
    try testing.expectEqual(Command.version, (try ok(&.{"--version"})).cmd);
}

test "edit_options" {
    const r = try ok(&.{ "cut", "talk.wav", "-o", "out.WAV", "--pause=400" });
    try testing.expectEqualStrings("out.WAV", r.out.?);
    try testing.expectEqual(@as(u32, 400), r.pause_ms);
    const t = try ok(&.{ "trim", "a.wav", "--from", "1.5", "--to", "3", "-o", "b.wav" });
    try testing.expectEqual(@as(f64, 1.5), t.from_s.?);
    const c = try ok(&.{ "convert", "a.wav", "--rate", "16000", "--mono", "-o", "b.wav" });
    try testing.expectEqual(@as(u32, 16000), c.rate.?);
    try testing.expect(c.mono);
    const n = try ok(&.{ "normalize", "a.wav", "--lufs", "-23", "--peak=-2", "-o", "b.wav" });
    try testing.expectEqual(@as(f64, -23), n.lufs);
    try testing.expectEqual(@as(f64, -2), n.peak);
}

test "listen_options" {
    const r = try ok(&.{ "listen", "--timeout", "5", "--silence", "1200", "--input", "x.wav" });
    try testing.expectEqual(@as(f64, 5), r.timeout_s);
    try testing.expectEqual(@as(u32, 1200), r.silence_ms);
    try testing.expectEqualStrings("x.wav", r.input.?);
}

test "scan_sounds_and_repair_options" {
    const r = try ok(&.{ "scan", "a.wav", "--markers", "m.wav", "--labels", "l.txt", "--cue", "a.cue", "--sounds" });
    try testing.expectEqualStrings("m.wav", r.markers.?);
    try testing.expectEqualStrings("l.txt", r.labels.?);
    try testing.expectEqualStrings("a.cue", r.cue.?);
    try testing.expect(r.sounds);
    const l = try ok(&.{ "sounds", "--list" });
    try testing.expect(l.list and l.file == null);
    const s = try ok(&.{ "sounds", "a.m4a", "--min-confidence", "0.7" });
    try testing.expectEqual(@as(f64, 0.7), s.min_confidence);
    const d = try ok(&.{ "dehum", "a.wav", "--freq", "50", "-o", "b.wav" });
    try testing.expectEqual(@as(f64, 50), d.freq.?);
    _ = try ok(&.{ "declick", "a.wav", "-o", "b.wav" });
    _ = try ok(&.{ "speech", "a.wav", "--markers", "split.wav" });
}

test "editor_and_video_outputs" {
    const r = try ok(&.{ "scan", "a.wav", "--audition", "m.csv", "--edl", "m.edl", "--fps", "29.97", "--subtitles", "s.vtt" });
    try testing.expectEqualStrings("m.csv", r.audition.?);
    try testing.expectEqualStrings("m.edl", r.edl.?);
    try testing.expectEqualStrings("s.vtt", r.subtitles.?);
    try testing.expectEqual(@as(u32, 30), r.fps.?.base);
    // Resolve's timelines start at 01:00:00:00
    try testing.expectEqual(@as(u64, 30 * 3600), r.edlStart());
    const s = try ok(&.{ "speech", "a.wav", "--edl", "m.edl", "--fps", "25", "--edl-start", "00:00:10:05" });
    try testing.expectEqual(@as(u64, 255), s.edlStart());
    _ = try ok(&.{ "sounds", "a.m4a", "--subtitles", "s.srt" });
    try testing.expectEqualStrings("m.mid", (try ok(&.{ "speech", "a.wav", "--midi", "m.mid" })).midi.?);
    try bad(&.{ "scan", "a.wav", "--midi", "m.midi" }, "ending in .mid");
    try bad(&.{ "scan", "a.wav", "--audition", "m.txt" }, "ending in .csv");
    try bad(&.{ "scan", "a.wav", "--edl", "m.txt", "--fps", "25" }, "ending in .edl");
    try bad(&.{ "scan", "a.wav", "--subtitles", "s.txt" }, ".srt or .vtt");
    try bad(&.{ "scan", "a.wav", "--edl", "m.edl" }, "--fps");
    try bad(&.{ "scan", "a.wav", "--edl", "m.edl", "--fps", "26" }, "29.97");
    try bad(&.{ "scan", "a.wav", "--fps", "25" }, "only with --edl");
    try bad(&.{ "scan", "a.wav", "--edl", "m.edl", "--fps", "25", "--edl-start", "01:00:00:25" }, "HH:MM:SS:FF");
    try bad(&.{ "scan", "a.wav", "--edl", "m.edl", "--fps", "25", "--edl-start", "1:00" }, "HH:MM:SS:FF");
    try bad(&.{ "voice", "a.wav", "--subtitles", "s.srt" }, "doesn't take --subtitles");
}

test "several_files_for_the_measuring_commands" {
    const argv = [_][]const u8{ "scan", "a.wav", "--json", "b.wav", "--min-confidence", "0.7", "c d.m4a" };
    const r = try ok(&argv);
    try testing.expectEqual(@as(usize, 3), r.file_count);
    var it = r.files(&argv);
    try testing.expectEqualStrings("a.wav", it.next().?);
    try testing.expectEqualStrings("b.wav", it.next().?);
    try testing.expectEqualStrings("c d.m4a", it.next().?);
    try testing.expect(it.next() == null);
    const eq = [_][]const u8{ "info", "--json", "x.wav", "y.wav" };
    var it2 = (try ok(&eq)).files(&eq);
    try testing.expectEqualStrings("x.wav", it2.next().?);
    try testing.expectEqualStrings("y.wav", it2.next().?);
    try bad(&.{ "scan", "a.wav", "b.wav", "--labels", "l.txt" }, "one file at a time");
    try bad(&.{ "declick", "a.wav", "b.wav", "-o", "c.wav" }, "one file at a time");
    try bad(&.{ "listen", "--input", "a.wav", "b.wav" }, "takes no file");
}

test "transcribe_options" {
    const r = try ok(&.{ "transcribe", "talk.m4a", "--lang", "en-GB", "--words", "--subtitles", "t.srt" });
    try testing.expectEqualStrings("en-GB", r.lang.?);
    try testing.expect(r.words);
    try testing.expect((try ok(&.{ "transcribe", "a.wav" })).lang == null);
    try testing.expect((try ok(&.{ "listen", "--text", "--lang", "en-US" })).text);
    try bad(&.{ "transcribe", "a.wav", "--lang", "en US" }, "en-US");
    try bad(&.{"transcribe"}, "which file?");
    try bad(&.{ "scan", "a.wav", "--words" }, "doesn't take --words");
}

test "options_that_would_be_ignored_are_refused" {
    try bad(&.{ "listen", "--lang", "en-US" }, "only with --text");
    try bad(&.{ "scan", "a.wav", "--edl-start", "01:00:00:00" }, "only with --edl");
    try bad(&.{ "scan", "a.wav", "--edl", "m.edl", "--fps", "29.97", "--edl-start", "01:00:00;00" }, "HH:MM:SS:FF");
}

test "mistakes_are_explained" {
    try bad(&.{ "scan", "a.wav", "--markers", "m.txt" }, "ending in .wav");
    try bad(&.{ "scan", "a.wav", "--labels", "l.csv" }, "ending in .txt");
    try bad(&.{ "scan", "a.wav", "--cue", "l.txt" }, "ending in .cue");
    try bad(&.{ "scan", "a.wav", "--markers", "a.wav" }, "new file");
    try bad(&.{ "declick", "a.wav", "-o", "a.wav" }, "new file");
    try bad(&.{ "dehum", "a.wav", "-o", "b.wav", "--freq", "55" }, "50 or 60");
    try bad(&.{"declick"}, "which file?");
    try bad(&.{ "dehum", "a.wav" }, "-o OUT.wav");
    try bad(&.{ "sounds", "--list", "a.wav" }, "no file");
    try bad(&.{ "voice", "a.wav", "--markers", "m.wav" }, "doesn't take --markers");
    try bad(&.{"frobnicate"}, "unknown command");
    try bad(&.{"info"}, "which file?");
    try bad(&.{ "cut", "a.wav" }, "-o OUT.wav");
    try bad(&.{ "cut", "a.wav", "-o", "b.mp3" }, "ending in .wav");
    try bad(&.{ "trim", "a.wav", "b.wav", "-o", "c.wav" }, "one file at a time");
    try bad(&.{ "info", "a.wav", "--rate", "8000" }, "doesn't take --rate");
    try bad(&.{ "trim", "a.wav", "-o", "b.wav", "--from", "3", "--to", "2" }, "after --from");
    try bad(&.{ "convert", "a.wav", "-o", "b.wav" }, "nothing to change");
    try bad(&.{ "convert", "a.wav", "-o", "b.wav", "--bits", "20" }, "16 or 24");
    try bad(&.{ "cut", "a.wav", "-o", "b.wav", "--pause", "abc" }, "whole number");
    try bad(&.{ "cut", "a.wav", "-o", "b.wav", "--pause" }, "needs a value");
    try bad(&.{ "listen", "a.wav" }, "--input FILE");
    try bad(&.{ "normalize", "a.wav", "-o", "b.wav", "--lufs", "5" }, "-70 to 0");
    try bad(&.{ "info", "a.wav", "--json=yes" }, "takes no value");
}
