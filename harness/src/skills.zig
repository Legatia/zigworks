//! Skills in the agentskills.io format: `dir/NAME/SKILL.md` with frontmatter
//! `name` and `description`, a markdown body, and any files the body refers to.
const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;

pub const Skill = struct { name: []const u8, description: []const u8 };

pub const max_skills = 200;
pub const max_name = 64;
pub const max_description = 1024;
pub const max_body = 64 * 1024;
pub const max_file = 256 * 1024;
pub const max_listed_files = 50;
const prompt_desc = 200;

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    var prev_hyphen = false;
    for (name) |c| {
        const hyphen = c == '-';
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or hyphen)) return false;
        if (hyphen and prev_hyphen) return false;
        prev_hyphen = hyphen;
    }
    return true;
}

const Parsed = struct { name: []const u8, description: []const u8, body: []const u8 };

fn trimLine(l: []const u8) []const u8 {
    return std.mem.trimEnd(u8, l, "\r");
}

fn unquote(arena: std.mem.Allocator, v: []const u8) ![]const u8 {
    if (v.len < 2 or v[v.len - 1] != v[0]) return v;
    const inner = v[1 .. v.len - 1];
    if (v[0] == '\'') return inner;
    if (v[0] != '"') return v;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len and (inner[i + 1] == '"' or inner[i + 1] == '\\')) i += 1;
        try out.append(arena, inner[i]);
    }
    return out.items;
}

/// One line of a header: `key: value` (a block value `>` or `|` joined
/// with spaces, quotes taken off a one-line value), a nested (indented)
/// line, or a line that is neither (`key` "").
pub const Field = struct { key: []const u8, value: []const u8, line: usize, nested: bool = false };

/// A file's header and the body after it.
pub const Header = struct { fields: []const Field, body: []const u8 };

/// The header between a first `---` line and the next `---` line, each
/// line with its number; `#` lines are comments. error.NoFrontmatter when
/// there is none, or it is not closed. Skills and agent definitions read
/// their headers so.
pub fn readHeader(arena: std.mem.Allocator, text: []const u8) !Header {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = trimLine(lines.next() orelse return error.NoFrontmatter);
    // a UTF-8 BOM before the first fence is tolerated
    if (!std.mem.eql(u8, std.mem.trimStart(u8, first, "\xEF\xBB\xBF"), "---")) return error.NoFrontmatter;
    var fields: std.ArrayList(Field) = .empty;
    var n: usize = 1;
    var closed = false;
    var pending: ?usize = null; // the field whose block value is being collected
    var block: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw| {
        n += 1;
        const line = trimLine(raw);
        const indented = line.len > 0 and (line[0] == ' ' or line[0] == '\t');
        if (pending != null and (indented or line.len == 0)) {
            const piece = std.mem.trim(u8, line, " \t");
            if (piece.len > 0) {
                if (block.items.len > 0) try block.append(arena, ' ');
                try block.appendSlice(arena, piece);
            }
            continue;
        }
        if (pending) |i| {
            fields.items[i].value = block.items;
            pending = null;
            block = .empty;
        }
        // a closing fence may have spaces after it, as Hermes writes them
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t"), "---")) {
            closed = true;
            break;
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (indented) {
            try fields.append(arena, .{ .key = "", .value = std.mem.trim(u8, line, " \t"), .line = n, .nested = true });
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            try fields.append(arena, .{ .key = "", .value = line, .line = n });
            continue;
        };
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len > 0 and (value[0] == '>' or value[0] == '|')) {
            try fields.append(arena, .{ .key = key, .value = "", .line = n });
            pending = fields.items.len - 1;
        } else try fields.append(arena, .{ .key = key, .value = try unquote(arena, value), .line = n });
    }
    if (!closed) return error.NoFrontmatter;
    return .{ .fields = fields.items, .body = lines.rest() };
}

/// Frontmatter between a first `---` line and the next `---` line. Unknown
/// keys, lists and nested values are ignored.
fn parse(arena: std.mem.Allocator, text: []const u8) !Parsed {
    const h = try readHeader(arena, text);
    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    for (h.fields) |f| {
        if (f.nested) continue;
        if (std.mem.eql(u8, f.key, "name")) name = f.value;
        if (std.mem.eql(u8, f.key, "description")) desc = f.value;
    }
    return .{ .name = name orelse return error.NoFrontmatter, .description = desc orelse return error.NoFrontmatter, .body = h.body };
}

fn inside(root: []const u8, p: []const u8) bool {
    if (!std.mem.startsWith(u8, p, root)) return false;
    return p.len == root.len or p[root.len] == std.fs.path.sep;
}

/// Reads `rel` inside `folder`; the real path (symlinks followed) must stay
/// inside the real folder. At most `cap` bytes; `truncate` cuts, else error.TooLarge.
fn readInside(arena: std.mem.Allocator, io: Io, folder: []const u8, rel: []const u8, cap: usize, truncate: bool) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const root = cwd.realPathFileAlloc(io, folder, arena) catch return error.FileNotFound;
    const path = try std.fs.path.join(arena, &.{ folder, rel });
    const real = cwd.realPathFileAlloc(io, path, arena) catch return error.FileNotFound;
    if (!inside(root, real)) return error.OutsideSkill;
    var f = cwd.openFile(io, real, .{}) catch return error.FileNotFound;
    defer f.close(io);
    const st = try f.stat(io);
    if (st.kind != .file) return error.FileNotFound;
    if (st.size > cap and !truncate) return error.TooLarge;
    const n: usize = @intCast(@min(st.size, cap));
    const buf = try arena.alloc(u8, n);
    const got = try f.readPositionalAll(io, buf, 0);
    return buf[0..got];
}

fn skillFolder(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ dir, name });
}

fn lessSkill(_: void, a: Skill, b: Skill) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn list(arena: std.mem.Allocator, io: Io, dir: []const u8) ![]Skill {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var out: std.ArrayList(Skill) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory and e.kind != .sym_link) continue;
        if (!validName(e.name)) continue;
        const folder = try skillFolder(arena, dir, e.name);
        const text = readInside(arena, io, folder, "SKILL.md", max_body, false) catch continue;
        const p = parse(arena, text) catch continue;
        if (!std.mem.eql(u8, p.name, e.name)) continue;
        if (p.description.len == 0 or p.description.len > max_description) continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .description = p.description });
    }
    std.mem.sort(Skill, out.items, {}, lessSkill);
    if (out.items.len > max_skills) out.shrinkRetainingCapacity(max_skills);
    return out.items;
}

pub fn load(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) ![]const u8 {
    if (!validName(name)) return error.NoSuchSkill;
    const folder = try skillFolder(arena, dir, name);
    const text = readInside(arena, io, folder, "SKILL.md", max_body, true) catch return error.NoSuchSkill;
    const p = parse(arena, text) catch return error.NoSuchSkill;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, std.mem.trimStart(u8, p.body, "\r\n"));
    const files = try otherFiles(arena, io, folder);
    if (files.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
        try out.appendSlice(arena, "Other files in this skill folder (read with the skill file tool): ");
        for (files, 0..) |f, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, f);
        }
        try out.append(arena, '\n');
    }
    return out.items;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Relative paths of the files in the folder, recursing one level; sorted, at most 50.
fn otherFiles(arena: std.mem.Allocator, io: Io, folder: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        switch (e.kind) {
            .file, .sym_link => {
                if (std.mem.eql(u8, e.name, "SKILL.md") or std.mem.endsWith(u8, e.name, ".tmp")) continue;
                try out.append(arena, try arena.dupe(u8, e.name));
            },
            .directory => {
                var sub = d.openDir(io, e.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var si = sub.iterate();
                while (try si.next(io)) |s| {
                    if (s.kind != .file and s.kind != .sym_link) continue;
                    try out.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ e.name, s.name }));
                }
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessStr);
    if (out.items.len > max_listed_files) out.shrinkRetainingCapacity(max_listed_files);
    return out.items;
}

pub fn readFile(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, rel: []const u8) ![]const u8 {
    if (!validName(name)) return error.NoSuchSkill;
    if (rel.len == 0 or std.mem.indexOfScalar(u8, rel, 0) != null) return error.OutsideSkill;
    if (std.fs.path.isAbsolute(rel) or rel[0] == '/' or rel[0] == '\\' or (rel.len > 1 and rel[1] == ':')) return error.OutsideSkill;
    var parts = std.mem.tokenizeAny(u8, rel, "/\\");
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return error.OutsideSkill;
    const folder = try skillFolder(arena, dir, name);
    return readInside(arena, io, folder, rel, max_file, false);
}

fn validDescription(s: []const u8) bool {
    if (s.len == 0 or s.len > max_description) return false;
    return std.mem.indexOfAny(u8, s, "\r\n\x00") == null;
}

pub fn save(io: Io, dir: []const u8, name: []const u8, description: []const u8, body: []const u8) !void {
    if (!validName(name)) return error.InvalidName;
    if (!validDescription(description)) return error.InvalidDescription;
    if (body.len > max_body) return error.TooLarge;
    var buf: [max_description + max_body + 256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("---\nname: {s}\ndescription: \"", .{name});
    for (description) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.print("\"\n---\n{s}", .{body});
    if (body.len > 0 and body[body.len - 1] != '\n') try w.writeByte('\n');
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const folder = std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch return error.NameTooLong;
    try Io.Dir.cwd().createDirPath(io, folder);
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&file_buf, "{s}{c}SKILL.md", .{ folder, std.fs.path.sep }) catch return error.NameTooLong;
    // whole or not at all, even with it open in an editor (util.writeReplace)
    try util.writeReplace(io, file, w.buffered());
}

pub fn remove(io: Io, dir: []const u8, name: []const u8) !bool {
    if (!validName(name)) return false;
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer d.close(io);
    _ = d.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    try d.deleteTree(io, name);
    return true;
}

pub fn promptList(arena: std.mem.Allocator, skills: []const Skill, max_bytes: usize) ![]const u8 {
    if (skills.len == 0) return "";
    const head = "Skills (load one with the `skill` tool when it fits the task):\n";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, head);
    for (skills, 0..) |s, i| {
        var line: std.ArrayList(u8) = .empty;
        try line.print(arena, "- {s}: ", .{s.name});
        var dlen = @min(s.description.len, prompt_desc);
        const cut = dlen < s.description.len;
        // do not cut inside a UTF-8 sequence
        while (cut and dlen > 0 and (s.description[dlen] & 0xC0) == 0x80) dlen -= 1;
        try line.appendSlice(arena, s.description[0..dlen]);
        if (cut) try line.appendSlice(arena, "...");
        try line.append(arena, '\n');
        const rest = skills.len - i - 1;
        // keep room for the "… and N more" line if this is not the last one
        const reserve: usize = if (rest > 0) 32 else 0;
        if (out.items.len + line.items.len + reserve > max_bytes) {
            return finish(arena, out.items, skills.len - i);
        }
        try out.appendSlice(arena, line.items);
    }
    return out.items;
}

fn finish(arena: std.mem.Allocator, so_far: []const u8, more: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\u{2026} and {d} more\n", .{ so_far, more });
}

const t = std.testing;

fn put(tmp: *t.TmpDir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |p| try tmp.dir.createDirPath(t.io, p);
    try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = data });
}

fn tmpPath(tmp: *t.TmpDir, a: std.mem.Allocator, sub: []const u8) ![]const u8 {
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    return std.fs.path.join(a, &.{ root, sub });
}

fn rep(a: std.mem.Allocator, c: u8, n: usize) []const u8 {
    const b = a.alloc(u8, n) catch @panic("oom");
    @memset(b, c);
    return b;
}

test "validName" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect(validName("a"));
    try t.expect(validName("pdf-tools2"));
    try t.expect(!validName(""));
    try t.expect(!validName("-a"));
    try t.expect(!validName("a-"));
    try t.expect(!validName("a--b"));
    try t.expect(!validName("A"));
    try t.expect(!validName("a_b"));
    try t.expect(!validName("a/b"));
    try t.expect(!validName(".."));
    try t.expect(validName(rep(a, 'a', 64)));
    try t.expect(!validName(rep(a, 'a', 65)));
}

test "list: valid, invalid and missing dir" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try put(&tmp, "s/zeta/SKILL.md", "---\nname: zeta\ndescription: 'Last one'\nlicense: MIT\nmetadata:\n  author: me\ntags:\n  - x\n---\nBody z\n");
    try put(&tmp, "s/alpha/SKILL.md", "---\r\nname: alpha\r\ndescription: \"First: one\"\r\n---\r\nBody\r\n");
    try put(&tmp, "s/Bad_Name/SKILL.md", "---\nname: Bad_Name\ndescription: x\n---\n");
    try put(&tmp, "s/mismatch/SKILL.md", "---\nname: other\ndescription: x\n---\n");
    try put(&tmp, "s/nofront/SKILL.md", "just text\n");
    try put(&tmp, "s/unclosed/SKILL.md", "---\nname: unclosed\ndescription: x\n");
    try put(&tmp, "s/nodesc/SKILL.md", "---\nname: nodesc\n---\n");
    try put(&tmp, "s/empty/other.txt", "x");
    try put(&tmp, "s/file.md", "x");
    const dir = try tmpPath(&tmp, a, "s");
    const got = try list(a, t.io, dir);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("alpha", got[0].name);
    try t.expectEqualStrings("First: one", got[0].description);
    try t.expectEqualStrings("zeta", got[1].name);
    try t.expectEqualStrings("Last one", got[1].description);
    const none = try list(a, t.io, try tmpPath(&tmp, a, "missing"));
    try t.expectEqual(@as(usize, 0), none.len);
}

test "folded and literal descriptions" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try put(&tmp, "s/fold/SKILL.md", "---\nname: fold\ndescription: >\n  Does one thing\n  and another.\n\n  Third.\nlicense: MIT\n---\nB\n");
    try put(&tmp, "s/lit/SKILL.md", "---\nname: lit\ndescription: |-\n  Line one\n  line two\n---\nB\n");
    const got = try list(a, t.io, try tmpPath(&tmp, a, "s"));
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("Does one thing and another. Third.", got[0].description);
    try t.expectEqualStrings("Line one line two", got[1].description);
}

test "load strips frontmatter and lists extra files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try put(&tmp, "s/pdf/SKILL.md", "---\nname: pdf\ndescription: Work with PDFs\n---\n# PDF\nSee REFERENCE.md\n");
    try put(&tmp, "s/pdf/REFERENCE.md", "ref");
    try put(&tmp, "s/pdf/scripts/run.sh", "echo");
    try put(&tmp, "s/pdf/scripts/deep/x.txt", "x");
    const dir = try tmpPath(&tmp, a, "s");
    const text = try load(a, t.io, dir, "pdf");
    try t.expect(std.mem.startsWith(u8, text, "# PDF\nSee REFERENCE.md\n"));
    try t.expect(std.mem.indexOf(u8, text, "name: pdf") == null);
    try t.expect(std.mem.indexOf(u8, text, "REFERENCE.md, scripts/run.sh\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "deep") == null);
    try t.expectError(error.NoSuchSkill, load(a, t.io, dir, "nope"));
    try t.expectError(error.NoSuchSkill, load(a, t.io, dir, "../x"));
    try t.expectError(error.NoSuchSkill, load(a, t.io, dir, "a/b"));
    try t.expectError(error.NoSuchSkill, load(a, t.io, dir, ""));
}

test "readFile stays inside the skill folder" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try put(&tmp, "s/pdf/SKILL.md", "---\nname: pdf\ndescription: d\n---\nB\n");
    try put(&tmp, "s/pdf/sub/a.txt", "hello");
    try put(&tmp, "s/other/SKILL.md", "---\nname: other\ndescription: d\n---\nB\n");
    try put(&tmp, "secret.txt", "secret");
    const dir = try tmpPath(&tmp, a, "s");
    try t.expectEqualStrings("hello", try readFile(a, t.io, dir, "pdf", "sub/a.txt"));
    try t.expectError(error.OutsideSkill, readFile(a, t.io, dir, "pdf", "../other/SKILL.md"));
    try t.expectError(error.OutsideSkill, readFile(a, t.io, dir, "pdf", "sub/../../other/SKILL.md"));
    try t.expectError(error.OutsideSkill, readFile(a, t.io, dir, "pdf", "/etc/passwd"));
    try t.expectError(error.OutsideSkill, readFile(a, t.io, dir, "pdf", ""));
    try t.expectError(error.NoSuchSkill, readFile(a, t.io, dir, "../pdf", "SKILL.md"));
    try t.expectError(error.FileNotFound, readFile(a, t.io, dir, "pdf", "missing.txt"));
    if (@import("builtin").os.tag != .windows) {
        const target = try tmpPath(&tmp, a, "secret.txt");
        try tmp.dir.symLink(t.io, target, "s/pdf/link.txt", .{});
        try t.expectError(error.OutsideSkill, readFile(a, t.io, dir, "pdf", "link.txt"));
        try tmp.dir.symLink(t.io, try tmpPath(&tmp, a, "s/other"), "s/pdf/linkdir", .{ .is_directory = true });
        try t.expectError(error.OutsideSkill, readFile(a, t.io, dir, "pdf", "linkdir/SKILL.md"));
    }
}

test "save, list, load roundtrip; save replaces; remove" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const dir = try tmpPath(&tmp, a, "skills");
    try save(t.io, dir, "deploy", "Deploy: \"safely\" \\ now", "Step 1\nStep 2");
    var got = try list(a, t.io, dir);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("Deploy: \"safely\" \\ now", got[0].description);
    try t.expectEqualStrings("Step 1\nStep 2\n", try load(a, t.io, dir, "deploy"));
    try save(t.io, dir, "deploy", "New", "Other body\n");
    got = try list(a, t.io, dir);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("New", got[0].description);
    try t.expectEqualStrings("Other body\n", try load(a, t.io, dir, "deploy"));
    // no temp file left behind
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "skills/deploy/SKILL.md.tmp", .{}));
    try t.expectError(error.InvalidName, save(t.io, dir, "../x", "d", "b"));
    try t.expectError(error.InvalidName, save(t.io, dir, "Bad", "d", "b"));
    try t.expectError(error.InvalidDescription, save(t.io, dir, "ok", "a\nb", "b"));
    try t.expectError(error.InvalidDescription, save(t.io, dir, "ok", "", "b"));
    try t.expectError(error.InvalidDescription, save(t.io, dir, "ok", rep(a, 'x', 1025), "b"));
    try t.expectError(error.TooLarge, save(t.io, dir, "ok", "d", rep(a, 'x', max_body + 1)));
    try t.expect(!try remove(t.io, dir, "nope"));
    try t.expect(!try remove(t.io, dir, "../x"));
    try t.expect(try remove(t.io, dir, "deploy"));
    try t.expectEqual(@as(usize, 0), (try list(a, t.io, dir)).len);
    try t.expect(!try remove(t.io, dir, "deploy"));
}

test "promptList" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("", try promptList(a, &.{}, 1000));
    const long = rep(a, 'd', 300);
    const skills = [_]Skill{
        .{ .name = "a", .description = "one" },
        .{ .name = "b", .description = long },
        .{ .name = "c", .description = "three" },
    };
    const full = try promptList(a, &skills, 10000);
    try t.expect(std.mem.startsWith(u8, full, "Skills (load one with the `skill` tool when it fits the task):\n- a: one\n- b: "));
    const want = try std.fmt.allocPrint(a, "{s}...\n- c: three\n", .{rep(a, 'd', 200)});
    try t.expect(std.mem.indexOf(u8, full, want) != null);
    try t.expect(std.mem.indexOf(u8, full, rep(a, 'd', 201)) == null);
    const cutoff = try promptList(a, &skills, 120);
    try t.expect(cutoff.len <= 120 + 32);
    try t.expect(std.mem.endsWith(u8, cutoff, "\u{2026} and 2 more\n"));
    try t.expect(std.mem.indexOf(u8, cutoff, "- a: one\n") != null);
}

test "a_closing_fence_with_trailing_spaces_reads" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Hermes writes (and reads) a closing `---` with spaces after it
    try put(&tmp, "s/spaced/SKILL.md", "---\nname: spaced\ndescription: Fence with spaces\n---  \nBody\n");
    try put(&tmp, "s/crlf/SKILL.md", "---\r\nname: crlf\r\ndescription: Tabbed fence\r\n---\t\r\nBody\r\n");
    const got = try list(a, t.io, try tmpPath(&tmp, a, "s"));
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("crlf", got[0].name);
    try t.expectEqualStrings("spaced", got[1].name);
    try t.expectEqualStrings("Body\n", try load(a, t.io, try tmpPath(&tmp, a, "s"), "spaced"));
}
