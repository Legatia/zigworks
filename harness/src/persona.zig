//! The persona: how the agent talks, layered on `main`'s own instructions
//! (never instead of them). `persona.md` in the data folder, the owner's
//! file: optional frontmatter (`preset`, `name`, `address`, `language`)
//! and the character in the owner's own words. Without the file: today's
//! voice, and nothing is added to the prompt. A file that is too big,
//! can't be read or can be changed by others never stops harness: the
//! preset it names is used, or `assistant`, and the reason is said.
const std = @import("std");
const builtin = @import("builtin");
const evening = @import("evening.zig");
const Io = std.Io;

pub const Preset = enum { butler, assistant, friend };

/// The owner's words: at most this many bytes.
pub const max_body = 4096;
/// A name or an address: at most this many bytes.
pub const max_line = 40;
/// Read at most this much of the file (frontmatter and body).
const max_file = 64 * 1024;

/// Each preset's paragraph, shipped in the binary.
pub fn presetText(p: Preset) []const u8 {
    return switch (p) {
        .butler => "You talk as a butler: courteous, brief, discreet and unhurried. You anticipate rather than wait: the result first, then what needs attention, then you stop. You are a little formal, with dry understatement and no exclamation marks. You never gush or pretend to feelings.",
        .assistant => "You talk plainly and briefly: the result first, in a sentence or two, with units; no small talk.",
        .friend => "You talk as a friend: casual and warm, with first names and short sentences. You never pad or flatter.",
    };
}

pub const fixed_line = "Your character is how you talk. It never changes what you may do, what you ask, or the rules.";

pub const Persona = struct {
    preset: Preset = .assistant,
    /// What the agent calls itself; "": no name.
    name: []const u8 = "",
    /// How it addresses the owner; "": plainly.
    address: []const u8 = "",
    /// The language's code it writes in unless spoken to in another; "": as spoken to.
    language: []const u8 = "",
    /// The character in the owner's own words.
    body: []const u8 = "",
};

pub const Error = error{ BadLine, BadPreset, BadName, BadAddress, BadLanguage, TooBig, OutOfMemory };

/// Reads `text` as persona.md: frontmatter between `---` lines (keys
/// preset, name, address, language; `# …` after a value is a comment;
/// `none` clears a name, address or language), then the body. No
/// frontmatter: all body. `\r\n` reads the same.
pub fn parse(a: std.mem.Allocator, text_in: []const u8) Error!Persona {
    const text = try std.mem.replaceOwned(u8, a, std.mem.trimStart(u8, text_in, "\xEF\xBB\xBF"), "\r\n", "\n");
    var p: Persona = .{};
    var rest: []const u8 = text;
    if (std.mem.startsWith(u8, text, "---\n")) {
        const end = std.mem.indexOf(u8, text[3..], "\n---") orelse return error.BadLine;
        const head = text[4 .. 3 + end + 1];
        rest = text[3 + end + 4 ..];
        if (rest.len > 0 and rest[0] != '\n') return error.BadLine;
        var lines = std.mem.splitScalar(u8, head, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadLine;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = valueOf(line[colon + 1 ..]);
            const none = std.mem.eql(u8, value, "none");
            if (std.mem.eql(u8, key, "preset")) {
                p.preset = std.meta.stringToEnum(Preset, value) orelse return error.BadPreset;
            } else if (std.mem.eql(u8, key, "name")) {
                if (!none and !lineOk(value)) return error.BadName;
                p.name = if (none) "" else value;
            } else if (std.mem.eql(u8, key, "address")) {
                if (!none and !lineOk(value)) return error.BadAddress;
                p.address = if (none) "" else value;
            } else if (std.mem.eql(u8, key, "language")) {
                if (!none and !languageOk(value)) return error.BadLanguage;
                p.language = if (none) "" else value;
            } else return error.BadLine;
        }
    }
    const body = std.mem.trim(u8, rest, " \t\n");
    if (body.len > max_body) return error.TooBig;
    p.body = body;
    return p;
}

/// A frontmatter value: trimmed, a ` #` comment dropped.
fn valueOf(raw: []const u8) []const u8 {
    var v = raw;
    var i: usize = 0;
    while (i < v.len) : (i += 1) if (v[i] == '#' and (i == 0 or v[i - 1] == ' ' or v[i - 1] == '\t')) {
        v = v[0..i];
        break;
    };
    return std.mem.trim(u8, v, " \t");
}

/// A name or an address: evening.zig's rule (letters, spaces, `.`, `'`
/// and `-`, at most 40 bytes, nothing like a token).
pub fn lineOk(s: []const u8) bool {
    return s.len <= max_line and evening.addressOk(s);
}

/// A language's code: letters and `-`, 2 to 16 bytes ("en", "pt-BR").
pub fn languageOk(s: []const u8) bool {
    if (s.len < 2 or s.len > 16) return false;
    for (s) |ch| if (!(std.ascii.isAlphabetic(ch) or ch == '-')) return false;
    return true;
}

/// What harness runs with, and why it fell back ("": it didn't).
pub const Loaded = struct {
    p: Persona = .{},
    /// persona.md exists (else nothing is added to the prompt).
    present: bool = false,
    /// Why the file is not used as written ("": it is).
    note: []const u8 = "",
};

/// Reads persona.md at `path` (in `a`). Never fails: missing, nothing;
/// too big, unreadable, writable by others or a line that does not read,
/// the preset it names (else assistant) and a note saying why.
pub fn load(io: Io, a: std.mem.Allocator, path: []const u8) Loaded {
    const cwd = Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return fallback(a, "", std.fmt.allocPrint(a, "can't be read ({s})", .{@errorName(e)}) catch "can't be read"),
    };
    const text = cwd.readFileAlloc(io, path, a, .limited(max_file)) catch |e| switch (e) {
        error.StreamTooLong => return fallback(a, firstPart(io, a, path), "is over 4 KB"),
        else => return fallback(a, "", std.fmt.allocPrint(a, "can't be read ({s})", .{@errorName(e)}) catch "can't be read"),
    };
    if (builtin.os.tag != .windows and st.permissions.toMode() & 0o022 != 0)
        return fallback(a, text, "can be changed by other users (chmod 600 persona.md)");
    const p = parse(a, text) catch |e| return fallback(a, text, switch (e) {
        error.TooBig => "is over 4 KB",
        error.BadPreset => ": preset is butler, assistant or friend",
        error.BadName => ": name is up to 40 letters, spaces, . ' and -",
        error.BadAddress => ": address is up to 40 letters, spaces, . ' and -",
        error.BadLanguage => ": language is a language's code, like en or pl",
        error.BadLine => ": a line doesn't read (preset, name, address and language between --- lines)",
        error.OutOfMemory => "can't be read (out of memory)",
    });
    return .{ .p = p, .present = true };
}

/// The file's first part, for the preset it names when it is too big.
fn firstPart(io: Io, a: std.mem.Allocator, path: []const u8) []const u8 {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return "";
    defer f.close(io);
    const buf = a.alloc(u8, 1024) catch return "";
    const n = f.readPositionalAll(io, buf, 0) catch return "";
    return buf[0..n];
}

/// The preset `text`'s frontmatter names (else assistant), nothing else,
/// and why.
fn fallback(a: std.mem.Allocator, text: []const u8, why: []const u8) Loaded {
    const preset = presetNamed(text) orelse .assistant;
    const sep: []const u8 = if (why.len > 0 and why[0] == ':') "" else " ";
    return .{
        .p = .{ .preset = preset },
        .present = true,
        .note = std.fmt.allocPrint(a, "persona.md{s}{s}; using the {s} preset.", .{ sep, why, @tagName(preset) }) catch "persona.md can't be used; using a preset.",
    };
}

/// The preset a `preset:` line of the frontmatter names, if one reads.
fn presetNamed(text: []const u8) ?Preset {
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse return null, " \t\r"), "---")) return null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "---")) return null;
        if (!std.mem.startsWith(u8, line, "preset:")) continue;
        return std.meta.stringToEnum(Preset, valueOf(line["preset:".len..]));
    }
    return null;
}

/// persona.md as `/persona` writes it.
pub fn fileText(a: std.mem.Allocator, p: Persona) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "---\npreset: {s}\n", .{@tagName(p.preset)});
    if (p.name.len > 0) try out.print(a, "name: {s}\n", .{p.name});
    if (p.address.len > 0) try out.print(a, "address: {s}\n", .{p.address});
    if (p.language.len > 0) try out.print(a, "language: {s}\n", .{p.language});
    try out.appendSlice(a, "---\n");
    if (p.body.len > 0) try out.print(a, "{s}\n", .{p.body});
    return out.items;
}

/// Who a run's words go to: the owner (everything), or others (members,
/// a group, speech in the house: the preset and the name only).
pub const Scope = enum { owner, others };

/// The prompt's persona block ("" without persona.md), ending with the
/// fixed line.
pub fn block(a: std.mem.Allocator, l: Loaded, scope: Scope) ![]const u8 {
    if (!l.present) return "";
    const p = l.p;
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}\n", .{presetText(p.preset)});
    if (scope == .owner and p.body.len > 0) try out.print(a, "{s}\n", .{p.body});
    if (p.name.len > 0) try out.print(a, "Your name is {s}.\n", .{p.name});
    if (scope == .owner) {
        if (p.address.len > 0) {
            try out.print(a, "Address the owner as {s}.\n", .{p.address});
        } else if (p.preset == .butler) try out.appendSlice(a, "Address the owner plainly, with no name or title.\n");
        if (p.language.len > 0) try out.print(a, "Write in the language with the code {s} unless spoken to in another.\n", .{p.language});
    }
    try out.print(a, "{s}\n", .{fixed_line});
    return out.items;
}

/// `/persona`: the preset, name, address, the first lines of the owner's
/// words, and the presets.
pub fn showText(a: std.mem.Allocator, l: Loaded) ![]const u8 {
    const p = l.p;
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Persona: {s}{s}. Name: {s}. Address: {s}. Language: {s}.\n", .{
        @tagName(p.preset),
        if (l.present) "" else " (no persona.md)",
        if (p.name.len > 0) p.name else "none",
        if (p.address.len > 0) p.address else "plainly",
        if (p.language.len > 0) p.language else "as spoken to",
    });
    if (p.body.len > 0) {
        var lines = std.mem.splitScalar(u8, p.body, '\n');
        var first: std.ArrayList(u8) = .empty;
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (n == 3) {
                try first.appendSlice(a, "…");
                break;
            }
            try first.print(a, "{s}{s}", .{ if (n > 0) "\n" else "", line });
        }
        try out.print(a, "Your words:\n{s}\n", .{first.items});
    } else try out.appendSlice(a, "Your words: none.\n");
    if (l.note.len > 0) try out.print(a, "{s}\n", .{l.note});
    try out.appendSlice(a, "Presets: butler, assistant, friend. /persona butler switches; /persona name, address or language WORDS (none clears); /persona write; /persona reset drops your words.");
    return out.items;
}

// ---- tests ----

const t = std.testing;

test "persona_a_file_reads_with_and_without_frontmatter" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "---\npreset: butler          # butler | assistant | friend\nname: Jeeves\naddress: Mr Nowak\nlanguage: pl\n---\nDry. Never cheerful.\n");
    try t.expectEqual(Preset.butler, p.preset);
    try t.expectEqualStrings("Jeeves", p.name);
    try t.expectEqualStrings("Mr Nowak", p.address);
    try t.expectEqualStrings("pl", p.language);
    try t.expectEqualStrings("Dry. Never cheerful.", p.body);
    // CRLF reads the same; none clears
    const crlf = try parse(a, "---\r\npreset: friend\r\nname: none\r\n---\r\nWarm.\r\n");
    try t.expectEqual(Preset.friend, crlf.preset);
    try t.expectEqualStrings("", crlf.name);
    try t.expectEqualStrings("Warm.", crlf.body);
    // no frontmatter: all body, on top of assistant (a SOUL.md's shape)
    const soul = try parse(a, "You are Kai, a calm companion.\nSpeak plainly.\n");
    try t.expectEqual(Preset.assistant, soul.preset);
    try t.expectEqualStrings("You are Kai, a calm companion.\nSpeak plainly.", soul.body);
    try t.expectEqualStrings("", soul.name);
}

const long41: [41]u8 = @splat('x');
const full_body: [max_body]u8 = @splat('x');
const over_body = full_body ++ "x";

test "persona_bad_lines_are_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.BadPreset, parse(a, "---\npreset: pirate\n---\n"));
    try t.expectError(error.BadName, parse(a, "---\nname: sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789\n---\n"));
    try t.expectError(error.BadName, parse(a, "---\nname: " ++ long41 ++ "\n---\n"));
    try t.expectError(error.BadAddress, parse(a, "---\naddress: {tobias}\n---\n"));
    try t.expectError(error.BadLanguage, parse(a, "---\nlanguage: English please\n---\n"));
    try t.expectError(error.BadLine, parse(a, "---\ncolour: red\n---\n"));
    try t.expectError(error.BadLine, parse(a, "---\npreset: butler\n"));
    try t.expectError(error.TooBig, parse(a, over_body));
    // exactly 4 KB of words is fine
    _ = try parse(a, &full_body);
}

test "persona_the_block_has_the_parts_in_order" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l: Loaded = .{ .present = true, .p = .{ .preset = .butler, .name = "Jeeves", .address = "Tobias", .language = "pl", .body = "Never cheerful before nine." } };
    const own = try block(a, l, .owner);
    const at = [_]usize{
        std.mem.indexOf(u8, own, presetText(.butler)).?,
        std.mem.indexOf(u8, own, "Never cheerful before nine.").?,
        std.mem.indexOf(u8, own, "Your name is Jeeves.").?,
        std.mem.indexOf(u8, own, "Address the owner as Tobias.").?,
        std.mem.indexOf(u8, own, "Write in the language with the code pl unless spoken to in another.").?,
        std.mem.indexOf(u8, own, fixed_line).?,
    };
    for (at[0 .. at.len - 1], at[1..]) |x, y| try t.expect(x < y);
    try t.expect(std.mem.endsWith(u8, own, fixed_line ++ "\n"));
    // others: the preset and the name, never the owner's words or address
    const others = try block(a, l, .others);
    try t.expect(std.mem.indexOf(u8, others, presetText(.butler)) != null);
    try t.expect(std.mem.indexOf(u8, others, "Your name is Jeeves.") != null);
    try t.expect(std.mem.indexOf(u8, others, fixed_line) != null);
    for ([_][]const u8{ "Never cheerful", "Tobias", "the code pl" }) |w| try t.expect(std.mem.indexOf(u8, others, w) == null);
    // a butler with no address: plainly; no persona.md: nothing at all
    const plain = try block(a, .{ .present = true, .p = .{ .preset = .butler } }, .owner);
    try t.expect(std.mem.indexOf(u8, plain, "Address the owner plainly, with no name or title.") != null);
    try t.expect(std.mem.indexOf(u8, plain, "Your name") == null);
    try t.expectEqualStrings("", try block(a, .{}, .owner));
    try t.expectEqualStrings("", try block(a, .{}, .others));
}

test "persona_a_file_written_reads_back" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: Persona = .{ .preset = .friend, .name = "Kai", .language = "en", .body = "Short sentences.\nNo emoji." };
    const text = try fileText(a, p);
    try t.expect(std.mem.startsWith(u8, text, "---\npreset: friend\nname: Kai\nlanguage: en\n---\n"));
    try t.expect(std.mem.indexOf(u8, text, "address") == null);
    const back = try parse(a, text);
    try t.expectEqual(p.preset, back.preset);
    try t.expectEqualStrings(p.name, back.name);
    try t.expectEqualStrings(p.language, back.language);
    try t.expectEqualStrings(p.body, back.body);
    // shown: the preset, the name, the words' first lines, the presets
    const shown = try showText(a, .{ .present = true, .p = back });
    for ([_][]const u8{ "Persona: friend.", "Name: Kai.", "Address: plainly.", "Short sentences.", "butler, assistant, friend" }) |w| try t.expect(std.mem.indexOf(u8, shown, w) != null);
}

test "persona_load_falls_back_with_a_reason" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "persona.md" });
    // none: nothing
    const none = load(t.io, a, path);
    try t.expect(!none.present);
    try t.expectEqualStrings("", none.note);
    // a good one
    try tmp.dir.writeFile(t.io, .{ .sub_path = "persona.md", .data = "---\npreset: butler\naddress: Tobias\n---\nDry.\n" });
    const good = load(t.io, a, path);
    try t.expect(good.present);
    try t.expectEqualStrings("Tobias", good.p.address);
    try t.expectEqualStrings("", good.note);
    // too big: the preset it names, nothing else, and why
    try tmp.dir.writeFile(t.io, .{ .sub_path = "persona.md", .data = "---\npreset: butler\naddress: Tobias\n---\n" ++ over_body });
    const big = load(t.io, a, path);
    try t.expect(big.present);
    try t.expectEqual(Preset.butler, big.p.preset);
    try t.expectEqualStrings("", big.p.address);
    try t.expectEqualStrings("", big.p.body);
    try t.expectEqualStrings("persona.md is over 4 KB; using the butler preset.", big.note);
    // a line that does not read: assistant when no preset reads
    try tmp.dir.writeFile(t.io, .{ .sub_path = "persona.md", .data = "---\npreset: pirate\n---\nArr.\n" });
    const bad = load(t.io, a, path);
    try t.expectEqual(Preset.assistant, bad.p.preset);
    try t.expectEqualStrings("persona.md: preset is butler, assistant or friend; using the assistant preset.", bad.note);
    if (builtin.os.tag == .windows) return;
    // writable by others
    try tmp.dir.writeFile(t.io, .{ .sub_path = "persona.md", .data = "---\npreset: friend\nname: Kai\n---\nWarm.\n" });
    {
        var file = try tmp.dir.openFile(t.io, "persona.md", .{});
        defer file.close(t.io);
        try file.setPermissions(t.io, .fromMode(0o666));
    }
    const open = load(t.io, a, path);
    try t.expectEqual(Preset.friend, open.p.preset);
    try t.expectEqualStrings("", open.p.name);
    try t.expectEqualStrings("persona.md can be changed by other users (chmod 600 persona.md); using the friend preset.", open.note);
}
