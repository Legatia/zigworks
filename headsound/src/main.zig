const std = @import("std");
const build_options = @import("build_options");
const args = @import("args.zig");
const audio = @import("audio.zig");
const wav = @import("wav.zig");
const loudness = @import("loudness.zig");
const resample = @import("resample.zig");
const vad = @import("vad.zig");
const pitch = @import("pitch.zig");
const edit = @import("edit.zig");
const store = @import("store.zig");
const platform = @import("platform.zig");
const markers = @import("markers.zig");
const scan = @import("scan.zig");
const faults = @import("faults.zig");
const clicks = @import("clicks.zig");
const hum = @import("hum.zig");
const sounds = @import("sounds.zig");
const fnd = @import("finding.zig");
const transcript = @import("transcript.zig");
const builtin = @import("builtin");
const Audio = audio.Audio;
const Writer = std.Io.Writer;

const usage_text =
    \\usage: headsound <command> [options]
    \\
    \\  info       length, format, loudness, loudness range, true peak, clipping, speech
    \\  scan       what to fix and where: clicks, clipping, dropouts, hum, pops,
    \\             harsh s, DC offset, phase
    \\  sounds     what is heard when: speech, music, laughter, applause... (macOS)
    \\  speech     where the speech is: start and end of each stretch
    \\  voice      pitch, pauses and pace of the speaker
    \\  transcribe what is said, with times, recognised on this Mac (macOS)
    \\  cut        shorten long pauses (dead air) and write a new file
    \\  trim       keep a span, or cut the silence at both ends
    \\  normalize  set the loudness (LUFS) without going over a peak level
    \\  convert    change the sample rate, mix to mono, change the bit depth
    \\  declick    repair clicks and pops and write a new file
    \\  dehum      remove mains hum (50 or 60 Hz and harmonics) and write a new file
    \\  listen     record from the microphone until you stop talking (macOS)
    \\  help [command], version
    \\
    \\scan, sounds, speech and transcribe mark what they find for editors:
    \\  --markers OUT.wav  a copy with cue points (GoldWave, Audition, Sound Forge,
    \\                     WaveLab, Reaper); the audio itself is not changed
    \\  --labels OUT.txt   an Audacity label track (File > Import > Labels)
    \\  --cue OUT.cue      a cue sheet (GoldWave: Cue Points > Import)
    \\  --audition OUT.csv an Audition marker list (Markers panel > Import Markers)
    \\  --edl OUT.edl --fps N [--edl-start HH:MM:SS:FF]
    \\                     DaVinci Resolve timeline markers (Timelines > Import >
    \\                     Timeline Markers from EDL); N is the timeline's frame
    \\                     rate, the start defaults to Resolve's 01:00:00:00
    \\  --midi OUT.mid     a MIDI file of markers at 120 bpm (Pro Tools: File >
    \\                     Import > MIDI, into a session without markers; Logic:
    \\                     File > Import > MIDI File; Cubase: Import Markers on)
    \\  --subtitles OUT.srt|OUT.vtt  each finding as a caption, for video editors
    \\                     and players (Premiere, Resolve, Final Cut, YouTube)
    \\
    \\Reads WAV everywhere; on macOS also m4a/AAC, MP3, ALAC, FLAC, AIFF and CAF.
    \\Writes WAV (16-bit, or 24-bit with --bits 24). Times are in seconds.
    \\Nothing is sent anywhere: all analysis runs on this machine.
    \\Exit codes: 0 ok, 1 nothing found (speech, clicks, hum) / timeout, 2 usage error,
    \\3 permission missing, 4 failed (unreadable file, no microphone).
    \\
    \\Run 'headsound help <command>' for its options.
    \\
;

const Help = struct { []const u8, []const u8 };
const command_help = [_]Help{
    .{ "info",
    \\usage: headsound info FILE [--json]
    \\
    \\One line: duration, sample rate, channels, format, integrated loudness
    \\(LUFS, ITU-R BS.1770), loudness range (LU, EBU Tech 3342), sample peak
    \\(dBFS), true peak (dBTP, 4x oversampled), clipped stretches, background
    \\level (dBFS) and seconds of speech.
    \\
    \\example: headsound info memo.m4a
    \\
    },
    .{ "scan",
    \\usage: headsound scan FILE [--sounds] [MARKER OPTIONS] [--json]
    \\
    \\One line per problem, in time order, then a summary:
    \\  clipping  flat tops (3+ equal samples near the peak, also after the
    \\            level was lowered) and samples over full scale
    \\  click     clicks, pops and crackle (drum hits and consonants are not;
    \\            in AAC, MP3 and Opus files only clicks above -40 dBFS, as
    \\            the codec's own artifacts look like small clicks)
    \\  dropout   the sound cut to digital silence for 2 ms or more
    \\  hum       steady 50 or 60 Hz hum: its frequency, harmonics and level
    \\  pop       a "p" or "b" hitting the microphone (a burst below 80 Hz)
    \\  ess       a harsh s: the band above 5 kHz 3 dB or more over the voice
    \\  dc        a channel whose average is off zero (0.2% or more)
    \\  phase     stereo channels that cancel when mixed to mono
    \\The summary has the counts, loudness, loudness range and true peak.
    \\  --sounds   also say what is heard (see 'headsound help sounds'; macOS)
    \\  MARKER OPTIONS   mark every finding for an editor ('headsound help')
    \\
    \\examples: headsound scan interview.wav
    \\          headsound scan take3.flac --markers take3-marked.wav
    \\
    },
    .{ "sounds",
    \\usage: headsound sounds FILE [--min-confidence N] [MARKER OPTIONS] [--json]
    \\       headsound sounds --list
    \\
    \\What is heard when, from Apple's on-device sound classifier (about 300
    \\kinds: speech, music, laughter, applause, cough, dog, siren...). One line
    \\per stretch with the classifier's name, start, end and mean confidence;
    \\several can overlap (speech over music). --min-confidence (default 0.5)
    \\sets how sure it must be. --list prints every name it knows.
    \\Exit 1 when nothing is recognised. macOS only so far.
    \\
    },
    .{ "speech",
    \\usage: headsound speech FILE [--min-pause MS] [MARKER OPTIONS] [--json]
    \\
    \\One line per stretch of speech (start and end), then a total. Pauses
    \\shorter than --min-pause (default 300 ms) don't split a stretch. Speech
    \\is told from noise, clicks and hiss by its pitch; music with a clear
    \\pitch can count as speech. Exit 1 when there is no speech.
    \\
    \\With --markers or --cue, each stretch gets a cue point "speech N" and
    \\each pause one named "pause [-Exclude-]": GoldWave's Split File then
    \\writes the speech as separate files and leaves the pauses out. The other
    \\marker options ('headsound help') mark each stretch as a range.
    \\
    \\example: headsound speech interview.wav --min-pause 600
    \\
    },
    .{ "transcribe",
    \\usage: headsound transcribe FILE [--lang en-US] [--words] [MARKER OPTIONS] [--json]
    \\
    \\What is said, one line per phrase (start, end, text), then a total.
    \\Recognised by Apple's speech recogniser on this Mac; the audio is never
    \\sent anywhere, so it needs the language's on-device model (System
    \\Settings > Keyboard > Dictation adds languages). --lang picks the
    \\language (default: yours); --words adds a line per word with its
    \\confidence. The marker options mark each phrase: --subtitles writes
    \\captions, --markers puts the words in the editor's cue points.
    \\Exit 1 when nothing is said. macOS only so far.
    \\
    \\Speech recognition needs permission for the app this runs in (Terminal,
    \\iTerm, your editor); macOS asks the first time.
    \\
    \\examples: headsound transcribe interview.m4a
    \\          headsound transcribe talk.wav --subtitles talk.srt
    \\
    },
    .{ "voice",
    \\usage: headsound voice FILE [--min-pause MS] [--json]
    \\
    \\The speaker's pitch (median, and the 10th to 90th percentile range),
    \\seconds spoken, the number of pauses and the longest, and the pace in
    \\syllables per second (an estimate from the loudness peaks; conversational
    \\English is about 4 to 5). Exit 1 when there is no speech.
    \\
    },
    .{ "cut",
    \\usage: headsound cut FILE -o OUT.wav [--pause MS] [--min-pause MS] [--json]
    \\
    \\Shortens every pause longer than --pause (default 500 ms) to that length,
    \\and the silence before the first and after the last word to half of it.
    \\Joins fade over 5 ms so they don't click. Exit 1 when there is no speech.
    \\
    \\example: headsound cut podcast.wav -o tight.wav --pause 400
    \\
    },
    .{ "trim",
    \\usage: headsound trim FILE -o OUT.wav [--from S] [--to S] [--pad MS] [--json]
    \\
    \\With --from and/or --to, keeps that span. Without them, cuts the silence
    \\at both ends, keeping --pad (default 100 ms) around the speech.
    \\
    \\examples: headsound trim take.wav -o clean.wav
    \\          headsound trim long.wav --from 61.5 --to 90 -o clip.wav
    \\
    },
    .{ "normalize",
    \\usage: headsound normalize FILE -o OUT.wav [--lufs N] [--peak DB] [--bits 16|24] [--json]
    \\
    \\Changes the level so the integrated loudness is --lufs (default -16, the
    \\usual target for podcasts and voice; -23 for EBU R128 broadcast) unless
    \\the sample peak would go over --peak (default -1 dBFS); then it stops
    \\there and says so. Gain only: no compression or limiting.
    \\
    },
    .{ "convert",
    \\usage: headsound convert FILE -o OUT.wav [--rate HZ] [--mono] [--bits 16|24] [--json]
    \\
    \\Resamples (windowed sinc), mixes the channels to one, or changes the bit
    \\depth. Speech recognisers usually want: --rate 16000 --mono
    \\
    },
    .{ "declick",
    \\usage: headsound declick FILE -o OUT.wav [--json]
    \\
    \\Finds clicks the way 'scan' does and rebuilds each one from the sound on
    \\both sides of it (least-squares autoregressive interpolation). Samples
    \\outside the clicks are written back unchanged. Clicks in the first or
    \\last 12 ms aren't found (too little sound around them to judge); one
    \\that can't be rebuilt is left alone and counted as skipped. Exit 1 when
    \\there are none (nothing is written).
    \\
    },
    .{ "dehum",
    \\usage: headsound dehum FILE -o OUT.wav [--freq 50|60] [--json]
    \\
    \\Finds the hum the way 'scan' does and removes its fundamental and
    \\harmonics with narrow notch filters (1 Hz wide at the fundamental), run
    \\forwards and backwards so nothing shifts in time. Prints the hum level
    \\before and after. --freq removes hum at 50 or 60 Hz (8 harmonics, 2 Hz
    \\notches) even when none was found. Exit 1 when there is no hum and no
    \\--freq.
    \\
    },
    .{ "listen",
    \\usage: headsound listen [-o OUT.wav] [--text [--lang en-US]] [--timeout S] [--silence MS] [--max S] [--json]
    \\
    \\Waits for someone to speak (up to --timeout, default 30 s), records until
    \\they have been quiet for --silence (default 800 ms) or --max seconds
    \\(default 30) have passed, and writes the utterance as 16 kHz mono WAV to
    \\OUT, or to a private folder under $TMPDIR/headsound (kept one day).
    \\Prints one line: when the speech started, its length and the file.
    \\Exit 1 if nobody spoke before the timeout.
    \\
    \\The microphone needs permission for the app this runs in (Terminal,
    \\iTerm, your editor); macOS asks the first time.
    \\  --text         also say what was said (text=, last on the line), from
    \\                 Apple's on-device recogniser; see 'headsound help transcribe'
    \\  --input FILE   listen to a recording instead of the microphone (tests)
    \\
    \\example: headsound listen --timeout 10 --json
    \\
    },
};

pub const Exit = enum(u8) { ok = 0, nothing = 1, usage = 2, permission = 3, failed = 4 };

pub fn main() u8 {
    const alloc = std.heap.c_allocator;
    var out_buf: [8192]u8 = undefined;
    var err_buf: [2048]u8 = undefined;
    var out_w = std.fs.File.stdout().writerStreaming(&out_buf);
    var err_w = std.fs.File.stderr().writerStreaming(&err_buf);
    const out = &out_w.interface;
    const err = &err_w.interface;
    defer {
        out.flush() catch {};
        err.flush() catch {};
    }
    const argv = std.process.argsAlloc(alloc) catch return @intFromEnum(Exit.failed);
    defer std.process.argsFree(alloc, argv);

    var diag = args.Diag{};
    const req = args.parse(argv[1..], &diag) catch {
        err.print("headsound: {s}\n", .{diag.msg()}) catch {};
        return @intFromEnum(Exit.usage);
    };
    var app = App{ .alloc = alloc, .req = req, .argv = argv[1..], .out = out, .err = err };
    const code = app.run() catch |e| app.failure(e, null);
    return @intFromEnum(code);
}

pub fn errorText(e: anyerror, file: []const u8) []const u8 {
    _ = file;
    return switch (e) {
        error.FileNotFound => "no such file",
        error.AccessDenied => "can't read or write that file (permission denied)",
        error.IsDir => "that is a folder, not a file",
        error.UnsupportedFormat => if (platform.is_mac) "not an audio file Core Audio can read" else "only WAV can be read on this system so far",
        error.UnsupportedWav => "this WAV uses a codec other than PCM or float (convert it to PCM first)",
        error.BadWav, error.NotWav => "the file looks like WAV but is damaged",
        error.UnsupportedLayout => "its sample rate or channel count is outside what headsound handles (1 to 768 kHz, up to 64 channels)",
        error.DecodeFailed => "the file could not be decoded to the end",
        error.FileTooBig => "the file is too big (over 4 GB)",
        error.NoSpaceLeft => "the disk is full",
        error.OutOfMemory => "out of memory",
        error.UnsafeStore => "the recordings folder is shared with other users or is a symlink; remove it or set TMPDIR",
        error.NoMicrophone => "no microphone is available",
        error.ClassifierFailed => "Apple's sound classifier could not analyse this audio",
        error.NoRecognizer => "this Mac has no on-device speech recognition for that language (System Settings > Keyboard > Dictation adds languages; headsound never sends audio to a server)",
        error.TranscribeFailed => "Apple's speech recogniser could not transcribe this audio",
        else => @errorName(e),
    };
}

/// One result line: `event key=value ...` or, with --json, a JSON object.
pub const Line = struct {
    w: *Writer,
    json: bool,

    pub fn begin(w: *Writer, json: bool, event: []const u8) !Line {
        if (json) try w.print("{{\"event\":\"{s}\"", .{event}) else try w.writeAll(event);
        return .{ .w = w, .json = json };
    }

    fn key(l: Line, k: []const u8) !void {
        if (l.json) try l.w.print(",\"{s}\":", .{k}) else try l.w.print(" {s}=", .{k});
    }

    /// A number with `places` decimals and a unit shown in text only; -inf or
    /// NaN as "-inf"/null.
    pub fn num(l: Line, k: []const u8, v: f64, places: u8, unit: []const u8) !void {
        try l.key(k);
        if (!std.math.isFinite(v)) {
            try l.w.writeAll(if (l.json) "null" else "-inf");
            return;
        }
        const r = std.math.pow(f64, 10, @floatFromInt(places));
        const rounded = @round(v * r) / r;
        switch (places) {
            0 => try l.w.print("{d:.0}", .{rounded}),
            1 => try l.w.print("{d:.1}", .{rounded}),
            2 => try l.w.print("{d:.2}", .{rounded}),
            else => try l.w.print("{d:.3}", .{rounded}),
        }
        if (!l.json) try l.w.writeAll(unit);
    }

    pub fn int(l: Line, k: []const u8, v: anytype) !void {
        try l.key(k);
        try l.w.print("{d}", .{v});
    }

    pub fn str(l: Line, k: []const u8, v: []const u8) !void {
        try l.key(k);
        if (l.json) try quote(l.w, v) else try l.w.writeAll(v);
    }

    pub fn flag(l: Line, k: []const u8) !void {
        if (l.json) try l.w.print(",\"{s}\":true", .{k}) else try l.w.print(" {s}", .{k});
    }

    pub fn end(l: Line) !void {
        try l.w.writeAll(if (l.json) "}\n" else "\n");
    }
};

fn quote(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

pub const Loaded = struct {
    audio: Audio,
    format_buf: [16]u8 = std.mem.zeroes([16]u8),

    /// "wav/16", "wav/f32", "aac", "mp3"...
    pub fn format(l: *const Loaded) []const u8 {
        return std.mem.sliceTo(&l.format_buf, 0);
    }

    pub fn deinit(l: *Loaded, alloc: std.mem.Allocator) void {
        l.audio.deinit(alloc);
    }

    /// Decoded from a lossy codec.
    pub fn lossy(l: *const Loaded) bool {
        const f = l.format();
        for ([_][]const u8{ "aac", "mp3", "opus" }) |k| if (std.mem.eql(u8, f, k)) return true;
        return false;
    }
};

pub fn load(alloc: std.mem.Allocator, path: []const u8) !Loaded {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var head: [12]u8 = undefined;
    const got = try f.readAll(&head);
    var l = Loaded{ .audio = undefined };
    if (wav.isWav(head[0..got])) {
        const st = try f.stat();
        if (st.size > std.math.maxInt(u32)) return error.FileTooBig;
        try f.seekTo(0);
        const bytes = try alloc.alloc(u8, @intCast(st.size));
        defer alloc.free(bytes);
        _ = try f.readAll(bytes);
        const d = try wav.decode(alloc, bytes);
        l.audio = d.audio;
        _ = std.fmt.bufPrint(l.format_buf[0 .. l.format_buf.len - 1], "wav/{s}{d}", .{ if (d.format.float) "f" else "", d.format.bits }) catch {};
        return l;
    }
    const d = try platform.decode(alloc, path, l.format_buf[0 .. l.format_buf.len - 1]);
    l.audio = d.audio;
    return l;
}

/// The bit depth to write: as the input for 16/24-bit PCM, else 24.
fn outBits(format: []const u8, want: ?u16) u16 {
    if (want) |b| return b;
    if (std.mem.eql(u8, format, "wav/16") or std.mem.eql(u8, format, "wav/8")) return 16;
    if (std.mem.eql(u8, format, "aac") or std.mem.eql(u8, format, "mp3") or std.mem.eql(u8, format, "opus")) return 16;
    return 24;
}

fn frames(t: f64, rate: u32) u64 {
    return @intFromFloat(@max(0, @round(t * @as(f64, @floatFromInt(rate)))));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

/// A classifier name as words: "electric_piano" as "electric piano".
fn spaced(ar: std.mem.Allocator, label: []const u8) ![]u8 {
    const out = try ar.dupe(u8, label);
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

/// Speech analysis of any audio (mixed to mono at 16 kHz first).
pub fn analyzeSpeech(alloc: std.mem.Allocator, a: Audio, opts: vad.Options) !vad.Analysis {
    const m = try audio.mono(alloc, a);
    defer alloc.free(m);
    const x = try resample.resample(alloc, m, a.rate, vad.rate);
    defer alloc.free(x);
    return vad.analyze(alloc, x, opts);
}

const App = struct {
    alloc: std.mem.Allocator,
    req: args.Request,
    argv: []const []const u8 = &.{},
    out: *Writer,
    err: *Writer,
    /// Speech recognition permission already given in this run.
    speech_ok: bool = false,

    /// The exit for an error, explained on stderr (`path`: which of several
    /// files it was about).
    fn failure(a: *App, e: anyerror, path: ?[]const u8) Exit {
        a.out.flush() catch {};
        defer a.err.flush() catch {};
        switch (e) {
            error.Reported => return .failed,
            error.SpeechDenied => {
                a.err.writeAll("permission: speech recognition was refused (System Settings > Privacy & Security > Speech Recognition, and Keyboard > Dictation)\n") catch {};
                return .permission;
            },
            else => {},
        }
        if (path) |p| {
            a.err.print("headsound: {s}: {s}\n", .{ p, errorText(e, p) }) catch {};
        } else {
            a.err.print("headsound: {s}\n", .{errorText(e, a.req.file orelse a.req.input orelse "")}) catch {};
        }
        return .failed;
    }

    fn line(a: *App, event: []const u8) !Line {
        return Line.begin(a.out, a.req.json, event);
    }

    fn run(a: *App) !Exit {
        switch (a.req.cmd) {
            .help => return a.help(),
            .version => {
                try a.out.print("headsound {s}\n", .{build_options.version});
                return .ok;
            },
            .listen => return a.listen(),
            .sounds => if (a.req.list) return a.listNames(),
            else => {},
        }
        if (a.req.file_count > 1) return a.many();
        return a.one(a.req.file.?);
    }

    /// Each file in turn, each one's lines after a `file` line; a file that
    /// fails is reported and the rest still run.
    fn many(a: *App) !Exit {
        // asked once, not once per file
        if (a.req.cmd == .transcribe) if (try a.speechPermission()) |code| return code;
        var n = std.EnumArray(Exit, usize).initFill(0);
        var it = a.req.files(a.argv);
        while (it.next()) |path| {
            a.req.file = path;
            const ln = try a.line("file");
            try ln.str("path", path);
            try ln.end();
            try a.out.flush();
            const code = a.one(path) catch |e| a.failure(e, path);
            // each file's messages next to its lines
            try a.out.flush();
            try a.err.flush();
            n.getPtr(code).* += 1;
        }
        const ln = try a.line("files");
        try ln.int("count", a.req.file_count);
        try ln.int("ok", n.get(.ok));
        try ln.int("nothing_found", n.get(.nothing));
        try ln.int("failed", n.get(.failed) + n.get(.permission));
        try ln.end();
        if (n.get(.failed) > 0) return .failed;
        if (n.get(.permission) > 0) return .permission;
        return if (n.get(.ok) > 0) .ok else .nothing;
    }

    fn one(a: *App, path: []const u8) !Exit {
        var l = try load(a.alloc, path);
        defer l.deinit(a.alloc);
        if (l.audio.frames() == 0) {
            try a.out.flush();
            try a.err.print("headsound: {s}: the file has no audio\n", .{path});
            try a.err.flush();
            return .failed;
        }
        return switch (a.req.cmd) {
            .info => a.info(&l),
            .scan => a.scanCmd(&l),
            .sounds => a.soundsCmd(&l),
            .declick => a.declick(&l),
            .dehum => a.dehum(&l),
            .speech => a.speech(&l),
            .voice => a.voice(&l),
            .transcribe => a.transcribeCmd(&l),
            .cut => a.cut(&l),
            .trim => a.trim(&l),
            .normalize => a.normalize(&l),
            .convert => a.convert(&l),
            else => unreachable,
        };
    }

    fn help(a: *App) !Exit {
        const topic = a.req.help_topic orelse {
            try a.out.writeAll(usage_text);
            return .ok;
        };
        for (command_help) |h| if (std.mem.eql(u8, h[0], topic)) {
            try a.out.writeAll(h[1]);
            return .ok;
        };
        try a.err.print("headsound: no help for '{s}' (commands: info scan sounds speech voice transcribe cut trim normalize convert declick dehum listen)\n", .{topic});
        return .usage;
    }

    fn info(a: *App, l: *Loaded) !Exit {
        const m = try loudness.measure(a.alloc, l.audio);
        var an = try analyzeSpeech(a.alloc, l.audio, .{});
        defer an.deinit(a.alloc);
        var clips: std.ArrayList(fnd.Finding) = .empty;
        defer clips.deinit(a.alloc);
        try faults.clipping(a.alloc, l.audio, &clips);
        const ln = try a.line("info");
        try ln.num("duration", l.audio.seconds(), 2, "s");
        try ln.int("rate", l.audio.rate);
        try ln.int("channels", l.audio.channels);
        try ln.str("format", l.format());
        try ln.num("loudness", m.integrated, 1, "LUFS");
        try ln.num("lra", m.lra, 1, "LU");
        try ln.num("peak", audio.db(audio.peak(l.audio.samples)), 1, "dBFS");
        try ln.num("true_peak", loudness.truePeak(l.audio), 1, "dBTP");
        try ln.int("clipped", clips.items.len);
        try ln.num("background", an.floor, 0, "dBFS");
        try ln.num("speech", an.speechSeconds(), 2, "s");
        try ln.end();
        return .ok;
    }

    fn opts(a: *App) vad.Options {
        return .{ .min_pause_s = @as(f64, @floatFromInt(a.req.min_pause_ms)) / 1000 };
    }

    fn speech(a: *App, l: *Loaded) !Exit {
        var an = try analyzeSpeech(a.alloc, l.audio, a.opts());
        defer an.deinit(a.alloc);
        for (an.segments) |s| {
            const ln = try a.line("speech");
            try ln.num("start", s.start, 2, "s");
            try ln.num("end", s.end, 2, "s");
            try ln.end();
        }
        const ln = try a.line("total");
        try ln.int("stretches", an.segments.len);
        try ln.num("speech", an.speechSeconds(), 2, "s");
        try ln.num("longest_pause", an.longestPause(), 2, "s");
        try ln.num("duration", an.duration, 2, "s");
        try ln.end();
        if (an.segments.len > 0 and a.wantsMarkers()) {
            // Cue points GoldWave's Split File understands: each stretch a
            // piece, each pause excluded. Labels only need the stretches.
            var arena = std.heap.ArenaAllocator.init(a.alloc);
            defer arena.deinit();
            const ar = arena.allocator();
            var all: std.ArrayList(markers.Marker) = .empty;
            var spans: std.ArrayList(markers.Marker) = .empty;
            const r = l.audio.rate;
            const dur = l.audio.seconds();
            if (an.segments[0].start > 0.01) try all.append(ar, .{ .start = 0, .name = "silence [-Exclude-]" });
            for (an.segments, 1..) |sg, i| {
                const m = markers.Marker{ .start = frames(sg.start, r), .length = frames(sg.end, r) - frames(sg.start, r), .name = try std.fmt.allocPrint(ar, "speech {d}", .{i}) };
                try all.append(ar, m);
                try spans.append(ar, m);
                if (sg.end < dur - 0.01) try all.append(ar, .{ .start = frames(sg.end, r), .name = "pause [-Exclude-]" });
            }
            try a.writeMarkers(l, all.items, spans.items);
        }
        return if (an.segments.len == 0) .nothing else .ok;
    }

    fn voice(a: *App, l: *Loaded) !Exit {
        var an = try analyzeSpeech(a.alloc, l.audio, a.opts());
        defer an.deinit(a.alloc);
        if (an.segments.len == 0) {
            const ln = try a.line("voice");
            try ln.num("speech", 0, 2, "s");
            try ln.end();
            return .nothing;
        }
        const st = try pitch.stats(a.alloc, an.hz);
        const ln = try a.line("voice");
        if (st) |s| {
            try ln.num("pitch", s.median, 0, "Hz");
            try ln.num("low", s.low, 0, "Hz");
            try ln.num("high", s.high, 0, "Hz");
        }
        try ln.num("speech", an.speechSeconds(), 2, "s");
        try ln.int("pauses", an.segments.len - 1);
        try ln.num("longest_pause", an.longestPause(), 2, "s");
        if (vad.syllableRate(an)) |r| try ln.num("syllables_per_s", r, 1, "");
        try ln.end();
        return .ok;
    }

    /// null when speech recognition may run; else the exit, explained.
    fn speechPermission(a: *App) !?Exit {
        if (!platform.is_mac) {
            try a.err.writeAll("headsound: speech to text needs macOS so far (Apple's on-device recogniser)\n");
            return .failed;
        }
        if (a.speech_ok) return null;
        switch (platform.speechAccess()) {
            .granted => {
                a.speech_ok = true;
                return null;
            },
            .no_host => {
                try a.err.writeAll("permission: no app on this Mac started this process (ssh or launchd?), so macOS has nowhere to grant speech recognition. Run it from a terminal app on this Mac.\n");
                return .permission;
            },
            .denied => {
                var buf: [256]u8 = undefined;
                const app = platform.hostApp(&buf) orelse "your terminal";
                try a.err.print("permission: Speech Recognition is off for \"{s}\". System Settings > Privacy & Security > Speech Recognition.\n", .{app});
                return .permission;
            },
            .unanswered => {
                try a.err.writeAll("permission: macOS asked whether this terminal may use Speech Recognition and nobody answered within two minutes. Answer the prompt (or turn it on in System Settings > Privacy & Security > Speech Recognition) and run it again.\n");
                return .permission;
            },
        }
    }

    const Heard = struct { words: []transcript.Word, lang: []const u8 };

    /// The words in mono `x` at vad.rate, handed to the recogniser in pieces
    /// cut in the pauses between `speech` stretches (strings in `ar`).
    fn recognise(a: *App, ar: std.mem.Allocator, x: []const f32, spans: []const transcript.Span) !Heard {
        const dur = @as(f64, @floatFromInt(x.len)) / vad.rate;
        const cs = try transcript.chunks(a.alloc, spans, dur, transcript.max_chunk_s);
        defer a.alloc.free(cs);
        var all: std.ArrayList(transcript.Word) = .empty;
        const lang = try ar.alloc(u8, 64);
        @memset(lang, 0);
        for (cs) |ch| {
            const s: usize = @intFromFloat(ch.start * vad.rate);
            const e: usize = @min(x.len, @as(usize, @intFromFloat(ch.end * vad.rate)));
            if (e <= s) continue;
            const ws = try platform.transcribe(ar, x[s..e], vad.rate, a.req.lang, lang);
            for (ws) |w| {
                var v = w;
                v.start += ch.start;
                v.end += ch.start;
                try all.append(ar, v);
            }
        }
        return .{ .words = all.items, .lang = std.mem.sliceTo(lang, 0) };
    }

    fn transcribeCmd(a: *App, l: *Loaded) !Exit {
        if (try a.speechPermission()) |code| return code;
        var arena = std.heap.ArenaAllocator.init(a.alloc);
        defer arena.deinit();
        const ar = arena.allocator();
        const m = try audio.mono(a.alloc, l.audio);
        defer a.alloc.free(m);
        const x = try resample.resample(a.alloc, m, l.audio.rate, vad.rate);
        defer a.alloc.free(x);
        var an = try vad.analyze(a.alloc, x, a.opts());
        defer an.deinit(a.alloc);
        const spans = try ar.alloc(transcript.Span, an.segments.len);
        for (an.segments, spans) |sg, *sp| sp.* = .{ .start = sg.start, .end = sg.end };
        const said = try a.recognise(ar, x, spans);
        const ls = try transcript.lines(ar, said.words);
        var ms: std.ArrayList(markers.Marker) = .empty;
        for (ls) |line_| {
            const t = try transcript.text(ar, said.words, line_);
            if (a.req.words) for (said.words[line_.first..line_.last]) |w| {
                const ln = try a.line("word");
                try ln.num("start", w.start, 2, "s");
                try ln.num("end", w.end, 2, "s");
                try ln.num("confidence", w.confidence, 2, "");
                try ln.str("text", w.text);
                try ln.end();
            };
            const ln = try a.line("said");
            try ln.num("start", line_.start, 2, "s");
            try ln.num("end", line_.end, 2, "s");
            try ln.str("text", t);
            try ln.end();
            const r = l.audio.rate;
            try ms.append(ar, .{ .start = frames(line_.start, r), .length = frames(line_.end, r) -| frames(line_.start, r), .name = t });
        }
        const ln = try a.line("transcript");
        try ln.int("lines", ls.len);
        try ln.int("words", said.words.len);
        try ln.num("speech", an.speechSeconds(), 2, "s");
        try ln.num("duration", l.audio.seconds(), 2, "s");
        if (said.lang.len > 0) try ln.str("lang", said.lang);
        try ln.end();
        if (ms.items.len > 0 and a.wantsMarkers()) try a.writeMarkers(l, ms.items, ms.items);
        return if (said.words.len == 0) .nothing else .ok;
    }

    fn wantsMarkers(a: *App) bool {
        const r = a.req;
        return r.markers != null or r.labels != null or r.cue != null or r.audition != null or r.edl != null or r.midi != null or r.subtitles != null;
    }

    /// Writes `bytes` to the output file `path`; on failure says which file
    /// and why, and returns error.Reported.
    fn writeMarkerFile(a: *App, path: []const u8, bytes: []const u8) !void {
        writeFile(path, bytes) catch |e| {
            try a.out.flush();
            try a.err.print("headsound: can't write {s}: {s}\n", .{ path, errorText(e, path) });
            try a.err.flush();
            return error.Reported;
        };
    }

    /// Writes the marker outputs asked for: `ms` as cue points in a WAV copy,
    /// a cue sheet and a MIDI file, `label_ms` (ranges) in the other formats.
    /// The `markers` line comes after every file is written.
    fn writeMarkers(a: *App, l: *Loaded, ms: []const markers.Marker, label_ms: []const markers.Marker) !void {
        const rate = l.audio.rate;
        var buf: std.Io.Writer.Allocating = .init(a.alloc);
        defer buf.deinit();
        const w = &buf.writer;
        var cue_kept: ?usize = null;
        var edl_kept: ?usize = null;
        if (a.req.markers) |path| {
            const src = a.req.file.?;
            // A WAV keeps its own bytes; anything else is written out as WAV first.
            const original = blk: {
                var f = try std.fs.cwd().openFile(src, .{});
                defer f.close();
                var head: [12]u8 = undefined;
                const got = try f.readAll(&head);
                if (!wav.isWav(head[0..got])) break :blk null;
                const st = try f.stat();
                if (st.size > std.math.maxInt(u32)) return error.FileTooBig;
                try f.seekTo(0);
                const bytes = try a.alloc.alloc(u8, @intCast(st.size));
                errdefer a.alloc.free(bytes);
                _ = try f.readAll(bytes);
                break :blk bytes;
            };
            const base = original orelse try wav.encode(a.alloc, l.audio, outBits(l.format(), null));
            defer a.alloc.free(base);
            const out = try markers.addToWav(a.alloc, base, ms);
            defer a.alloc.free(out);
            try a.writeMarkerFile(path, out);
        }
        if (a.req.labels) |path| {
            buf.clearRetainingCapacity();
            try markers.writeLabels(w, label_ms, rate);
            try a.writeMarkerFile(path, buf.written());
        }
        if (a.req.cue) |path| {
            buf.clearRetainingCapacity();
            const n = try markers.writeCueSheet(a.alloc, w, ms, rate, a.req.markers orelse a.req.file.?);
            try a.writeMarkerFile(path, buf.written());
            if (n < ms.len) cue_kept = n; // a cue sheet holds 99
        }
        if (a.req.midi) |path| {
            buf.clearRetainingCapacity();
            // "[-Exclude-]" only means something to GoldWave
            const plain = try a.alloc.dupe(markers.Marker, ms);
            defer a.alloc.free(plain);
            for (plain) |*m| if (std.mem.endsWith(u8, m.name, " [-Exclude-]")) {
                m.name = m.name[0 .. m.name.len - " [-Exclude-]".len];
            };
            try markers.writeMidi(a.alloc, w, plain, rate);
            try a.writeMarkerFile(path, buf.written());
        }
        if (a.req.audition) |path| {
            buf.clearRetainingCapacity();
            try markers.writeAudition(w, label_ms, rate);
            try a.writeMarkerFile(path, buf.written());
        }
        if (a.req.edl) |path| {
            buf.clearRetainingCapacity();
            const name = std.fs.path.basename(a.req.file.?);
            const title = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
            const n = try markers.writeEdl(w, label_ms, rate, a.req.fps.?, a.req.edlStart(), title);
            try a.writeMarkerFile(path, buf.written());
            if (n < label_ms.len) edl_kept = n; // three-digit event numbers
        }
        if (a.req.subtitles) |path| {
            buf.clearRetainingCapacity();
            const vtt = std.ascii.endsWithIgnoreCase(path, ".vtt");
            try markers.writeSubtitles(a.alloc, w, label_ms, rate, if (vtt) .vtt else .srt);
            try a.writeMarkerFile(path, buf.written());
        }
        const ln = try a.line("markers");
        try ln.int("count", ms.len);
        const r = a.req;
        if (r.markers) |p| try ln.str("wav", p);
        if (r.labels) |p| try ln.str("labels", p);
        if (r.cue) |p| try ln.str("cue", p);
        if (cue_kept) |n| try ln.int("cue_kept", n);
        if (r.midi) |p| try ln.str("midi", p);
        if (r.audition) |p| try ln.str("audition", p);
        if (r.edl) |p| try ln.str("edl", p);
        if (edl_kept) |n| try ln.int("edl_kept", n);
        if (r.subtitles) |p| try ln.str("subtitles", p);
        try ln.end();
    }

    fn printFinding(a: *App, f: fnd.Finding) !void {
        const ln = try a.line(@tagName(f.kind));
        switch (f.kind) {
            .dc => {
                try ln.int("channel", f.channel);
                try ln.num("offset", f.value, 2, "%");
            },
            .sound => {
                try ln.str("label", f.label);
                try ln.num("start", f.start, 2, "s");
                try ln.num("end", f.end, 2, "s");
                try ln.num("confidence", f.value, 2, "");
            },
            else => {
                try ln.num("start", f.start, 3, "s");
                try ln.num("end", f.end, 3, "s");
                switch (f.kind) {
                    .clipping => {
                        try ln.num("level", f.level, 1, "dBFS");
                        try ln.int("samples", f.count);
                    },
                    .click => try ln.num("level", f.level, 1, "dBFS"),
                    .hum => {
                        try ln.num("freq", f.freq, 1, "Hz");
                        try ln.int("harmonics", f.count);
                        try ln.num("level", f.level, 1, "dBFS");
                    },
                    .pop, .ess => {
                        try ln.num("level", f.level, 1, "dBFS");
                        try ln.num("over", f.value, 1, "dB");
                    },
                    .phase => try ln.num("correlation", f.value, 2, ""),
                    else => {},
                }
            },
        }
        try ln.end();
    }

    /// Cue point names, numbered per kind ("click 3") so they can be told
    /// apart in an editor's list.
    fn findingMarkers(ar: std.mem.Allocator, fs: []const fnd.Finding, rate: u32) ![]markers.Marker {
        var seen = std.EnumArray(fnd.Kind, u32).initFill(0);
        const ms = try ar.alloc(markers.Marker, fs.len);
        for (fs, ms) |f, *m| {
            const n = seen.getPtr(f.kind);
            n.* += 1;
            m.* = try findingMarker(ar, f, rate, n.*);
        }
        return ms;
    }

    fn findingMarker(ar: std.mem.Allocator, f: fnd.Finding, rate: u32, n: u32) !markers.Marker {
        const name = switch (f.kind) {
            .hum => try std.fmt.allocPrint(ar, "hum {d:.0} Hz", .{f.freq}),
            .dc => try std.fmt.allocPrint(ar, "DC offset {d:.2}% (channel {d})", .{ f.value, f.channel }),
            .sound => try spaced(ar, f.label),
            else => try std.fmt.allocPrint(ar, "{s} {d}", .{ f.kind.label(), n }),
        };
        const s = frames(f.start, rate);
        const len = if (f.kind == .dc) 0 else frames(f.end, rate) -| s;
        return .{ .start = s, .length = len, .name = name };
    }

    /// Classifier stretches of `l` as findings (labels in `ar`).
    fn heard(a: *App, ar: std.mem.Allocator, l: *Loaded, out: *std.ArrayList(fnd.Finding)) !void {
        const m = try audio.mono(a.alloc, l.audio);
        defer a.alloc.free(m);
        const ws = try platform.classify(ar, m, l.audio.rate, 1.0, @min(0.3, a.req.min_confidence));
        const st = try sounds.stretches(a.alloc, ws, a.req.min_confidence);
        defer a.alloc.free(st);
        for (st) |x| try out.append(a.alloc, .{ .kind = .sound, .start = x.start, .end = @min(x.end, l.audio.seconds()), .label = x.label, .value = x.confidence });
    }

    fn scanCmd(a: *App, l: *Loaded) !Exit {
        var rep = try scan.run(a.alloc, l.audio, l.lossy());
        defer rep.deinit(a.alloc);
        var arena = std.heap.ArenaAllocator.init(a.alloc);
        defer arena.deinit();
        const ar = arena.allocator();
        if (a.req.sounds) {
            if (platform.is_mac) {
                try a.heard(ar, l, &rep.findings);
                std.mem.sort(fnd.Finding, rep.findings.items, {}, fnd.Finding.lessThan);
            } else try a.err.writeAll("headsound: --sounds needs macOS so far; scanning without it\n");
        }
        for (rep.findings.items) |f| try a.printFinding(f);
        const ln = try a.line("scan");
        try ln.num("duration", l.audio.seconds(), 2, "s");
        try ln.int("clipping", rep.count(.clipping));
        try ln.int("clicks", rep.count(.click));
        try ln.int("dropouts", rep.count(.dropout));
        try ln.int("hum", rep.count(.hum));
        if (rep.strongestHum()) |h| try ln.num("hum_freq", h.freq, 1, "Hz");
        try ln.int("pops", rep.count(.pop));
        try ln.int("ess", rep.count(.ess));
        try ln.int("dc", rep.count(.dc));
        try ln.int("phase", rep.count(.phase));
        if (a.req.sounds and platform.is_mac) try ln.int("sounds", rep.count(.sound));
        try ln.num("loudness", rep.loudness.integrated, 1, "LUFS");
        try ln.num("lra", rep.loudness.lra, 1, "LU");
        try ln.num("true_peak", rep.true_peak, 1, "dBTP");
        if (rep.correlation) |c| try ln.num("correlation", c, 2, "");
        try ln.end();
        if (a.wantsMarkers()) {
            const ms = try findingMarkers(ar, rep.findings.items, l.audio.rate);
            try a.writeMarkers(l, ms, ms);
        }
        return .ok;
    }

    fn soundsCmd(a: *App, l: *Loaded) !Exit {
        if (!platform.is_mac) {
            try a.err.writeAll("headsound: recognising sounds needs macOS so far (Apple's classifier)\n");
            return .failed;
        }
        var arena = std.heap.ArenaAllocator.init(a.alloc);
        defer arena.deinit();
        const ar = arena.allocator();
        var found: std.ArrayList(fnd.Finding) = .empty;
        defer found.deinit(a.alloc);
        try a.heard(ar, l, &found);
        for (found.items) |f| try a.printFinding(f);
        const ln = try a.line("total");
        try ln.int("stretches", found.items.len);
        try ln.num("duration", l.audio.seconds(), 2, "s");
        try ln.end();
        if (found.items.len > 0 and a.wantsMarkers()) {
            const ms = try findingMarkers(ar, found.items, l.audio.rate);
            try a.writeMarkers(l, ms, ms);
        }
        return if (found.items.len == 0) .nothing else .ok;
    }

    fn listNames(a: *App) !Exit {
        if (!platform.is_mac) {
            try a.err.writeAll("headsound: recognising sounds needs macOS so far (Apple's classifier)\n");
            return .failed;
        }
        var arena = std.heap.ArenaAllocator.init(a.alloc);
        defer arena.deinit();
        const names = try platform.classNames(arena.allocator());
        for (names) |n| {
            const ln = try a.line("class");
            try ln.str("label", n);
            try ln.end();
        }
        return .ok;
    }

    fn declick(a: *App, l: *Loaded) !Exit {
        const au = l.audio;
        // counted once when they are in several channels, as scan does
        var fixes: std.ArrayList(scan.Fix) = .empty;
        defer fixes.deinit(a.alloc);
        var longest: usize = 0;
        const pad = 2;
        // The clicks scan reports: not the edges of pops, harsh s, clipping
        // or dropouts.
        var others: std.ArrayList(fnd.Finding) = .empty;
        defer others.deinit(a.alloc);
        try scan.otherFaults(a.alloc, au, &others);
        const r: f64 = @floatFromInt(au.rate);
        for (0..au.channels) |c| {
            const x = try scan.channel(a.alloc, au, c);
            defer a.alloc.free(x);
            const cs = try clicks.detect(a.alloc, x, au.rate, if (l.lossy()) clicks.floor_lossy else clicks.floor_pcm);
            defer a.alloc.free(cs);
            for (cs) |k| {
                const as_finding = fnd.Finding{ .kind = .click, .start = @as(f64, @floatFromInt(k.start)) / r, .end = @as(f64, @floatFromInt(k.end)) / r };
                if (scan.partOfOther(as_finding, others.items)) continue;
                const s0 = k.start -| pad;
                const s1 = @min(x.len, k.end + pad);
                const ok = try clicks.repair(a.alloc, x, s0, s1, au.rate);
                if (ok) longest = @max(longest, s1 - s0);
                try fixes.append(a.alloc, .{ .start = k.start, .end = k.end, .ok = ok });
            }
            for (x, 0..) |v, i| au.samples[i * au.channels + c] = v;
        }
        const count = try scan.countFixes(a.alloc, fixes.items, au.rate / 1000);
        const found = count.found;
        const fixed = count.repaired;
        if (found == 0) {
            try a.err.writeAll("headsound: no clicks found; nothing written\n");
            return .nothing;
        }
        try a.writeOut(au, outBits(l.format(), null));
        const ln = try a.line("declick");
        try ln.str("file", a.req.out.?);
        try ln.int("found", found);
        try ln.int("repaired", fixed);
        try ln.int("skipped", found - fixed);
        try ln.num("longest", @as(f64, @floatFromInt(longest)) * 1000 / @as(f64, @floatFromInt(au.rate)), 1, "ms");
        try ln.end();
        return .ok;
    }

    fn strongestHum(a: *App, au: Audio, want: ?f64) !?hum.Hum {
        const m = try audio.mono(a.alloc, au);
        defer a.alloc.free(m);
        const hs = try hum.detect(a.alloc, m, au.rate);
        defer a.alloc.free(hs);
        var best: ?hum.Hum = null;
        for (hs) |h| {
            if (want) |w| if (@abs(h.freq - w) > 1) continue;
            if (best) |*b| {
                b.mask |= h.mask;
                if (h.level > b.level) {
                    b.level = h.level;
                    b.freq = h.freq;
                }
            } else best = h;
        }
        return best;
    }

    fn dehum(a: *App, l: *Loaded) !Exit {
        const before = try a.strongestHum(l.audio, a.req.freq);
        var freq: f64 = undefined;
        var mask: u32 = undefined;
        // A measured frequency is good to a few hundredths of a hertz: narrow
        // notches. A given one may be off by a tenth (the grid drifts): wider.
        var width: f64 = undefined;
        if (before) |h| {
            freq = h.freq;
            mask = h.mask;
            width = 1.0;
        } else if (a.req.freq) |f| {
            freq = f;
            mask = 0xFF;
            width = 2.0;
        } else {
            try a.err.writeAll("headsound: no hum found; nothing written (--freq 50 or 60 removes it anyway)\n");
            return .nothing;
        }
        try hum.remove(a.alloc, l.audio, freq, mask, width);
        const after = try a.strongestHum(l.audio, freq);
        try a.writeOut(l.audio, outBits(l.format(), null));
        const ln = try a.line("dehum");
        try ln.str("file", a.req.out.?);
        try ln.num("freq", freq, 1, "Hz");
        try ln.int("harmonics", @popCount(mask));
        if (before) |h| try ln.num("before", h.level, 1, "dBFS") else try ln.str("before", "none");
        if (after) |h| try ln.num("after", h.level, 1, "dBFS") else try ln.str("after", "none");
        try ln.end();
        return .ok;
    }

    fn writeOut(a: *App, x: Audio, bits: u16) !void {
        try wav.write(a.alloc, a.req.out.?, x, bits);
    }

    fn cut(a: *App, l: *Loaded) !Exit {
        var an = try analyzeSpeech(a.alloc, l.audio, a.opts());
        defer an.deinit(a.alloc);
        if (an.segments.len == 0) {
            try a.err.writeAll("headsound: no speech found; nothing written\n");
            return .nothing;
        }
        const keep = @as(f64, @floatFromInt(a.req.pause_ms)) / 1000;
        const spans = try edit.pauseKeeps(a.alloc, an.segments, l.audio.seconds(), keep);
        defer a.alloc.free(spans);
        var j = try edit.join(a.alloc, l.audio, spans);
        defer j.deinit(a.alloc);
        try a.writeOut(j, outBits(l.format(), null));
        var shortened: usize = 0;
        for (1..an.segments.len) |i| {
            if (an.segments[i].start - an.segments[i - 1].end > keep) shortened += 1;
        }
        const ln = try a.line("cut");
        try ln.str("file", a.req.out.?);
        try ln.num("before", l.audio.seconds(), 2, "s");
        try ln.num("after", j.seconds(), 2, "s");
        try ln.num("removed", l.audio.seconds() - j.seconds(), 2, "s");
        try ln.int("pauses_shortened", shortened);
        try ln.end();
        return .ok;
    }

    fn trim(a: *App, l: *Loaded) !Exit {
        const dur = l.audio.seconds();
        var span = edit.Span{ .start = 0, .end = dur };
        if (a.req.from_s != null or a.req.to_s != null) {
            span.start = @min(a.req.from_s orelse 0, dur);
            span.end = @min(a.req.to_s orelse dur, dur);
            if (span.end <= span.start) {
                try a.err.print("headsound: the file is only {d:.2} s long\n", .{dur});
                return .usage;
            }
        } else {
            var an = try analyzeSpeech(a.alloc, l.audio, .{ .pad_s = @as(f64, @floatFromInt(a.req.pad_ms)) / 1000 });
            defer an.deinit(a.alloc);
            if (an.segments.len == 0) {
                try a.err.writeAll("headsound: no speech found; nothing written\n");
                return .nothing;
            }
            span = .{ .start = an.segments[0].start, .end = an.segments[an.segments.len - 1].end };
        }
        var j = try edit.join(a.alloc, l.audio, &.{span});
        defer j.deinit(a.alloc);
        try a.writeOut(j, outBits(l.format(), null));
        const ln = try a.line("trim");
        try ln.str("file", a.req.out.?);
        try ln.num("from", span.start, 2, "s");
        try ln.num("to", span.end, 2, "s");
        try ln.num("duration", j.seconds(), 2, "s");
        try ln.end();
        return .ok;
    }

    fn normalize(a: *App, l: *Loaded) !Exit {
        const before = try loudness.integrated(a.alloc, l.audio);
        if (!std.math.isFinite(before)) {
            try a.err.writeAll("headsound: too quiet (or too short) to measure its loudness; nothing written\n");
            return .nothing;
        }
        const pk = audio.db(audio.peak(l.audio.samples));
        var g = a.req.lufs - before;
        var limited = false;
        if (pk + g > a.req.peak) {
            g = a.req.peak - pk;
            limited = true;
        }
        edit.gain(l.audio, g);
        try a.writeOut(l.audio, outBits(l.format(), a.req.bits));
        const ln = try a.line("normalize");
        try ln.str("file", a.req.out.?);
        try ln.num("before", before, 1, "LUFS");
        try ln.num("after", before + g, 1, "LUFS");
        try ln.num("gain", g, 1, "dB");
        try ln.num("peak", pk + g, 1, "dBFS");
        if (limited) try ln.flag("limited_by_peak");
        try ln.end();
        return .ok;
    }

    fn convert(a: *App, l: *Loaded) !Exit {
        var c = try edit.convert(a.alloc, l.audio, a.req.rate orelse l.audio.rate, a.req.mono);
        defer c.deinit(a.alloc);
        const bits = outBits(l.format(), a.req.bits);
        try a.writeOut(c, bits);
        const ln = try a.line("convert");
        try ln.str("file", a.req.out.?);
        try ln.int("rate", c.rate);
        try ln.int("channels", c.channels);
        try ln.int("bits", bits);
        try ln.num("duration", c.seconds(), 2, "s");
        try ln.end();
        return .ok;
    }

    // ---- listen ----

    const Sink = struct {
        live: *vad.Live,
        timeout_s: f64,
        fed: usize = 0,
        timed_out: bool = false,
        failed: bool = false,

        /// True to stop.
        pub fn feed(s: *Sink, x: []const f32) bool {
            const st = s.live.feed(x) catch {
                s.failed = true;
                return true;
            };
            s.fed += x.len;
            if (st == .done) return true;
            if (st == .waiting and @as(f64, @floatFromInt(s.fed)) / vad.rate >= s.timeout_s) {
                s.timed_out = true;
                return true;
            }
            return false;
        }
    };

    fn listen(a: *App) !Exit {
        // before anyone speaks, so nobody talks to a recogniser that can't run
        if (a.req.text) if (try a.speechPermission()) |code| return code;
        var live = try vad.Live.init(a.alloc, @as(f64, @floatFromInt(a.req.silence_ms)) / 1000, a.req.max_s);
        defer live.deinit();
        var sink = Sink{ .live = &live, .timeout_s = a.req.timeout_s };
        if (a.req.input) |path| {
            var l = try load(a.alloc, path);
            defer l.deinit(a.alloc);
            var c = try edit.convert(a.alloc, l.audio, vad.rate, true);
            defer c.deinit(a.alloc);
            var i: usize = 0;
            var stopped = false;
            while (i < c.samples.len and !stopped) : (i += vad.rate / 10) {
                stopped = sink.feed(c.samples[i..@min(c.samples.len, i + vad.rate / 10)]);
            }
            // A recording that ends while someone speaks ends the utterance.
            if (!stopped and live.state == .speaking) {
                const pad = try a.alloc.alloc(f32, @intFromFloat(@ceil((live.silence_s + 0.5) * vad.rate)));
                defer a.alloc.free(pad);
                @memset(pad, 0);
                _ = sink.feed(pad);
            }
        } else {
            if (!platform.is_mac) {
                try a.err.writeAll(if (builtin.os.tag == .windows)
                    "headsound: listening to the microphone needs macOS so far (record with Sound Recorder or GoldWave, then use the file commands)\n"
                else
                    "headsound: listening to the microphone needs macOS so far (on Linux: record with arecord, then use the file commands)\n");
                return .failed;
            }
            switch (platform.micAccess()) {
                .granted => {},
                .no_host => {
                    try a.err.writeAll("permission: no app on this Mac started this process (ssh or launchd?), so macOS has nowhere to grant the microphone. Run it from a terminal app on this Mac.\n");
                    return .permission;
                },
                .denied => {
                    var buf: [256]u8 = undefined;
                    const app = platform.hostApp(&buf) orelse "your terminal";
                    try a.err.print("permission: Microphone is off for \"{s}\". System Settings > Privacy & Security > Microphone.\n", .{app});
                    return .permission;
                },
                .unanswered => {
                    try a.err.writeAll("permission: macOS asked whether this terminal may use the microphone and nobody answered within two minutes. Answer the prompt and run it again.\n");
                    return .permission;
                },
            }
            const max_ms: u32 = @intFromFloat((a.req.timeout_s + a.req.max_s + 5) * 1000);
            try platform.listen(vad.rate, &sink, max_ms);
        }
        if (sink.failed) return error.OutOfMemory;
        if (live.state != .done) {
            const ln = try a.line("timeout");
            try ln.num("after", @as(f64, @floatFromInt(sink.fed)) / vad.rate, 1, "s");
            try ln.end();
            return .nothing;
        }
        const u = live.utterance();
        const clip = Audio{ .rate = vad.rate, .channels = 1, .samples = @constCast(u) };
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = if (a.req.out) |o| blk: {
            try wav.write(a.alloc, o, clip, 16);
            break :blk o;
        } else blk: {
            const base = try store.defaultDir(a.alloc);
            defer a.alloc.free(base);
            var dir = try store.open(base, std.time.timestamp());
            defer dir.close();
            const pid = if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
            const name = try std.fmt.allocPrint(a.alloc, "listen-{d}-{d}.wav", .{ std.time.milliTimestamp(), pid });
            defer a.alloc.free(name);
            const bytes = try wav.encode(a.alloc, clip, 16);
            defer a.alloc.free(bytes);
            var f = try dir.createFile(name, .{ .mode = store.file_mode });
            defer f.close();
            try f.writeAll(bytes);
            break :blk try std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ base, std.fs.path.sep, name });
        };
        var arena = std.heap.ArenaAllocator.init(a.alloc);
        defer arena.deinit();
        const ar = arena.allocator();
        const dur = @as(f64, @floatFromInt(u.len)) / vad.rate;
        // recognised before the line starts, so a failure leaves no half line
        const said: ?[]const u8 = if (a.req.text) blk: {
            const h = a.recognise(ar, u, &.{.{ .start = 0, .end = dur }}) catch |e| {
                try a.out.flush();
                try a.err.print("headsound: the recording is in {s}, but it could not be turned into text\n", .{path});
                return e;
            };
            break :blk try transcript.text(ar, h.words, .{ .start = 0, .end = dur, .first = 0, .last = h.words.len });
        } else null;
        const ln = try a.line("heard");
        try ln.num("after", live.startedAt(), 2, "s");
        try ln.num("duration", dur, 2, "s");
        try ln.str("file", path);
        if (said) |t| try ln.str("text", t);
        try ln.end();
        return .ok;
    }
};

// ---- tests ----

const testing = std.testing;

test {
    _ = markers;
    _ = scan;
    _ = faults;
    _ = clicks;
    _ = hum;
    _ = sounds;
    _ = fnd;
    _ = @import("fft.zig");
    _ = @import("transcript.zig");
    _ = @import("voicefx.zig");
    _ = args;
    _ = audio;
    _ = wav;
    _ = loudness;
    _ = resample;
    _ = vad;
    _ = pitch;
    _ = edit;
    _ = store;
}

test "sound_names_read_as_words_in_markers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try App.findingMarker(arena.allocator(), .{ .kind = .sound, .start = 1, .end = 2, .label = "electric_piano" }, 1000, 1);
    try testing.expectEqualStrings("electric piano", m.name);
    try testing.expectEqual(@as(u64, 1000), m.length);
}

test "line_text_and_json" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var ln = try Line.begin(&w, false, "info");
    try ln.num("duration", 12.3456, 2, "s");
    try ln.num("loudness", -std.math.inf(f64), 1, "LUFS");
    try ln.str("file", "a b.wav");
    try ln.flag("limited_by_peak");
    try ln.end();
    try testing.expectEqualStrings("info duration=12.35s loudness=-inf file=a b.wav limited_by_peak\n", w.buffered());
    w = .fixed(&buf);
    ln = try Line.begin(&w, true, "info");
    try ln.num("duration", 12.3456, 2, "s");
    try ln.num("loudness", -std.math.inf(f64), 1, "LUFS");
    try ln.str("file", "a\"b.wav");
    try ln.int("channels", @as(u16, 2));
    try ln.flag("limited_by_peak");
    try ln.end();
    try testing.expectEqualStrings("{\"event\":\"info\",\"duration\":12.35,\"loudness\":null,\"file\":\"a\\\"b.wav\",\"channels\":2,\"limited_by_peak\":true}\n", w.buffered());
}

test "out_bits_follow_the_input" {
    try testing.expectEqual(@as(u16, 16), outBits("wav/16", null));
    try testing.expectEqual(@as(u16, 24), outBits("wav/f32", null));
    try testing.expectEqual(@as(u16, 16), outBits("aac", null));
    try testing.expectEqual(@as(u16, 24), outBits("wav/16", 24));
}

test "every_command_has_help" {
    inline for (@typeInfo(args.Command).@"enum".fields) |f| {
        if (comptime !std.mem.eql(u8, f.name, "help") and !std.mem.eql(u8, f.name, "version")) {
            var found = false;
            for (command_help) |h| if (std.mem.eql(u8, h[0], f.name)) {
                found = true;
            };
            try testing.expect(found);
            try testing.expect(std.mem.indexOf(u8, usage_text, "  " ++ f.name) != null);
        }
    }
}
