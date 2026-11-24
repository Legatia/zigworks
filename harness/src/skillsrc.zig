//! Skills harness installs (`harness skill add`, `harness import hermes`):
//! a skill's files and their hash, installing them into `skills/NAME/`,
//! and `skills/.sources`, one line per installed skill with where it came
//! from, so `harness skill update` can fetch it again and tell an edited
//! one apart.
const std = @import("std");
const builtin = @import("builtin");
const url_mod = @import("url.zig");
const Io = std.Io;

/// One file of a skill: its path in the skill's folder (with `/`), its
/// bytes, and whether it runs (kept for `scripts/` on Linux and macOS).
pub const File = struct { rel: []const u8, data: []const u8, exec: bool = false };

fn lessFile(_: void, x: File, y: File) bool {
    return std.mem.lessThan(u8, x.rel, y.rel);
}

/// A skill's hash: SHA-256 over its files in path order, each its path,
/// its length and its bytes; lowercase hex.
pub fn hashFiles(a: std.mem.Allocator, files: []const File) ![64]u8 {
    const sorted = try a.dupe(File, files);
    std.mem.sort(File, sorted, {}, lessFile);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted) |f| {
        var len: [32]u8 = undefined;
        h.update(f.rel);
        h.update("\x00");
        h.update(std.fmt.bufPrint(&len, "{d}\x00", .{f.data.len}) catch unreachable);
        h.update(f.data);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// Most files read from a folder, and most bytes in all.
pub const max_files = 300;
pub const max_total = 10 * 1024 * 1024;

/// A skill folder's files (paths with `/`), up to the limits
/// (error.TooLarge past them); links, `.tmp` files and `.git` left out.
pub fn readFolder(io: Io, a: std.mem.Allocator, folder: []const u8) ![]File {
    return readFolderMax(io, a, folder, max_files, max_total);
}

/// `readFolder` with other limits (a folder of several skills).
pub fn readFolderMax(io: Io, a: std.mem.Allocator, folder: []const u8, files_cap: usize, bytes_cap: usize) ![]File {
    var out: std.ArrayList(File) = .empty;
    var total: usize = 0;
    try readInto(io, a, folder, "", &out, &total, files_cap, bytes_cap);
    std.mem.sort(File, out.items, {}, lessFile);
    return out.items;
}

fn readInto(io: Io, a: std.mem.Allocator, folder: []const u8, rel: []const u8, out: *std.ArrayList(File), total: *usize, files_cap: usize, bytes_cap: usize) !void {
    const here = if (rel.len == 0) folder else try std.fs.path.join(a, &.{ folder, rel });
    var d = try Io.Dir.cwd().openDir(io, here, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const r = if (rel.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, e.name });
        switch (e.kind) {
            // a clone's history is no part of the skill
            .directory => if (!std.mem.eql(u8, e.name, ".git")) try readInto(io, a, folder, r, out, total, files_cap, bytes_cap),
            .file => {
                if (std.mem.endsWith(u8, e.name, ".tmp")) continue;
                if (out.items.len >= files_cap) return error.TooLarge;
                const data = d.readFileAlloc(io, e.name, a, .limited(bytes_cap - total.* + 1)) catch |err| switch (err) {
                    error.StreamTooLong => return error.TooLarge,
                    else => return err,
                };
                total.* += data.len;
                if (total.* > bytes_cap) return error.TooLarge;
                const exec = builtin.os.tag != .windows and if (d.statFile(io, e.name, .{})) |st| st.permissions.toMode() & 0o111 != 0 else |_| false;
                try out.append(a, .{ .rel = r, .data = data, .exec = exec });
            },
            else => {},
        }
    }
}

/// The hash of a skill folder as it is now (`hashFiles` of its files).
pub fn hashFolder(io: Io, a: std.mem.Allocator, folder: []const u8) ![64]u8 {
    return hashFiles(a, try readFolder(io, a, folder));
}

// ---- skills/.sources ----

/// One installed skill: its name, where it came from (a folder,
/// `OWNER/REPO[/PATH][@REF]`, a link, or `hermes`), the commit or link it
/// was pinned to ("-" for none), its hash when installed, when, and its
/// name at the source when harness renamed it ("" when it didn't).
pub const Line = struct { name: []const u8, source: []const u8, pin: []const u8, hash: []const u8, time: []const u8, upstream: []const u8 = "" };

pub const sources_file = ".sources";

/// `skills/.sources`, a line each (tab-separated); a line that doesn't
/// read is skipped.
pub fn readSources(io: Io, a: std.mem.Allocator, skills_dir: []const u8) ![]Line {
    const p = try std.fs.path.join(a, &.{ skills_dir, sources_file });
    const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0 or l[0] == '#') continue;
        var f = std.mem.splitScalar(u8, l, '\t');
        const line: Line = .{
            .name = f.next() orelse continue,
            .source = f.next() orelse continue,
            .pin = f.next() orelse continue,
            .hash = f.next() orelse continue,
            .time = f.next() orelse continue,
            .upstream = f.next() orelse "",
        };
        if (f.next() != null or line.name.len == 0 or line.source.len == 0) continue;
        try out.append(a, line);
    }
    return out.items;
}

pub fn writeSources(io: Io, a: std.mem.Allocator, skills_dir: []const u8, lines: []const Line) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# Installed skills: name, source, commit or link, hash, time, name at the source (harness skill list)\n");
    for (lines) |l| try out.print(a, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ l.name, l.source, l.pin, l.hash, l.time, l.upstream });
    try @import("util.zig").writeReplace(io, try std.fs.path.join(a, &.{ skills_dir, sources_file }), out.items);
}

/// Adds `line`, replacing the line of the same name; sorted by name.
pub fn putSource(io: Io, a: std.mem.Allocator, skills_dir: []const u8, line: Line) !void {
    var lines: std.ArrayList(Line) = .empty;
    for (try readSources(io, a, skills_dir)) |l| if (!std.mem.eql(u8, l.name, line.name)) try lines.append(a, l);
    try lines.append(a, line);
    std.mem.sort(Line, lines.items, {}, struct {
        fn lt(_: void, x: Line, y: Line) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    try writeSources(io, a, skills_dir, lines.items);
}

/// Removes `name`'s line; whether it had one.
pub fn dropSource(io: Io, a: std.mem.Allocator, skills_dir: []const u8, name: []const u8) !bool {
    var lines: std.ArrayList(Line) = .empty;
    var found = false;
    for (try readSources(io, a, skills_dir)) |l| {
        if (std.mem.eql(u8, l.name, name)) found = true else try lines.append(a, l);
    }
    if (found) try writeSources(io, a, skills_dir, lines.items);
    return found;
}

pub fn findSource(lines: []const Line, name: []const u8) ?Line {
    for (lines) |l| if (std.mem.eql(u8, l.name, name)) return l;
    return null;
}

// ---- sources ----

/// Where a skill comes from: a folder, a GitHub repo (the path in it, the
/// ref; "" for the default branch), a link to a SKILL.md, or Hermes
/// (nothing to update from).
pub const Source = union(enum) {
    folder: []const u8,
    github: Github,
    link: []const u8,
    hermes,
};

pub const Github = struct { owner: []const u8, repo: []const u8, path: []const u8 = "", ref: []const u8 = "" };

/// SOURCE as `harness skill add` takes it (`is_folder`: it names a folder
/// on this machine, which the caller found): a folder; `OWNER/REPO[/PATH][@REF]`;
/// a github.com link (`/tree/REF/PATH`, `/blob/REF/PATH/SKILL.md`); another
/// https link (or http to this machine): one SKILL.md; or `hermes`.
pub fn parseSource(a: std.mem.Allocator, text: []const u8, is_folder: bool) !Source {
    if (is_folder) return .{ .folder = text };
    if (std.mem.eql(u8, text, "hermes")) return .hermes;
    if (std.mem.startsWith(u8, text, "https://github.com/") or std.mem.startsWith(u8, text, "http://github.com/")) {
        const rest = text[std.mem.indexOf(u8, text, "github.com/").? + "github.com/".len ..];
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rest, "/"), '/');
        const owner = it.next() orelse return error.BadSource;
        var repo = it.next() orelse return error.BadSource;
        if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
        var g: Github = .{ .owner = owner, .repo = repo };
        if (it.next()) |kind| {
            if (!std.mem.eql(u8, kind, "tree") and !std.mem.eql(u8, kind, "blob")) return error.BadSource;
            g.ref = it.next() orelse return error.BadSource;
            var path = it.rest();
            if (std.mem.eql(u8, kind, "blob")) path = std.fs.path.dirnamePosix(path) orelse "";
            g.path = path;
        }
        try checkGithub(g);
        return .{ .github = g };
    }
    if (std.mem.startsWith(u8, text, "https://") or std.mem.startsWith(u8, text, "http://")) {
        const u = url_mod.parse(a, text) catch return error.BadSource;
        if (!u.https and !loopback(u.host)) return error.PlainHttp;
        return .{ .link = text };
    }
    if (std.mem.indexOf(u8, text, "://") != null) return error.BadSource;
    var g: Github = .{ .owner = "", .repo = "" };
    var main = text;
    if (std.mem.lastIndexOfScalar(u8, text, '@')) |at| {
        g.ref = text[at + 1 ..];
        if (g.ref.len == 0) return error.BadSource;
        main = text[0..at];
    }
    var it = std.mem.splitScalar(u8, main, '/');
    g.owner = it.next() orelse return error.BadSource;
    g.repo = it.next() orelse return error.BadSource;
    g.path = it.rest();
    try checkGithub(g);
    return .{ .github = g };
}

fn loopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]") or std.mem.startsWith(u8, host, "127.");
}

fn checkGithub(g: Github) !void {
    for ([_][]const u8{ g.owner, g.repo }) |n| {
        if (n.len == 0 or n.len > 100 or n[0] == '-' or n[0] == '.') return error.BadSource;
        for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return error.BadSource;
    }
    if (g.path.len > 0 and !safeRel(g.path)) return error.BadSource;
    for (g.ref) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./", c) != null)) return error.BadSource;
    if (std.mem.indexOf(u8, g.ref, "..") != null) return error.BadSource;
}

/// The source as `skills/.sources` keeps it (and `parseSource` reads back:
/// a folder is kept absolute).
pub fn sourceText(a: std.mem.Allocator, src: Source) ![]const u8 {
    return switch (src) {
        .folder => |f| f,
        .link => |l| l,
        .hermes => "hermes",
        .github => |g| std.fmt.allocPrint(a, "{s}/{s}{s}{s}{s}{s}", .{ g.owner, g.repo, if (g.path.len > 0) "/" else "", g.path, if (g.ref.len > 0) "@" else "", g.ref }),
    };
}

/// What `skill add` shows of a SKILL.md: its frontmatter's name,
/// description, license, compatibility, allowed-tools, and Hermes's
/// platforms and required environment variables.
pub const Facts = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    license: []const u8 = "",
    compatibility: []const u8 = "",
    allowed_tools: []const u8 = "",
    platforms: []const []const u8 = &.{},
    env_vars: []const []const u8 = &.{},
};

pub fn facts(a: std.mem.Allocator, md: []const u8) !Facts {
    const yaml = @import("yaml.zig");
    // the frontmatter's lines, read as YAML (a closing fence may have spaces)
    const h = try @import("skills.zig").readHeader(a, md);
    const head_end = @intFromPtr(h.body.ptr) - @intFromPtr(md.ptr);
    const first_nl = (std.mem.indexOfScalar(u8, md, '\n') orelse return error.NoFrontmatter) + 1;
    const block = md[first_nl..head_end];
    const close = std.mem.lastIndexOf(u8, std.mem.trimEnd(u8, block, "\r\n \t"), "\n") orelse 0;
    const yaml_text = block[0..close];
    var f: Facts = .{};
    var d: yaml.Diag = .{};
    if (yaml.parse(a, yaml_text, &d)) |v| {
        const str = struct {
            fn s(x: ?yaml.Value) []const u8 {
                return std.mem.trim(u8, yaml.str(x) orelse "", " \n");
            }
        }.s;
        f.name = str(yaml.get(v, "name"));
        f.description = try std.mem.replaceOwned(u8, a, str(yaml.get(v, "description")), "\n", " ");
        f.license = str(yaml.get(v, "license"));
        f.compatibility = str(yaml.get(v, "compatibility"));
        var tools: std.ArrayList([]const u8) = .empty;
        for (try yaml.list(a, yaml.get(v, "allowed-tools"))) |x| if (yaml.str(x)) |sx| try tools.append(a, sx);
        f.allowed_tools = try std.mem.join(a, " ", tools.items);
        var plats: std.ArrayList([]const u8) = .empty;
        for (try yaml.list(a, yaml.get(v, "platforms"))) |x| if (yaml.str(x)) |sx| try plats.append(a, sx);
        f.platforms = plats.items;
        var vars: std.ArrayList([]const u8) = .empty;
        for (try yaml.list(a, yaml.get(v, "required_environment_variables"))) |x| {
            const n = yaml.str(x) orelse yaml.str(yaml.get(x, "name")) orelse continue;
            try vars.append(a, n);
        }
        for (try yaml.list(a, yaml.get(yaml.get(v, "prerequisites"), "env_vars"))) |x| if (yaml.str(x)) |n| try vars.append(a, n);
        for (try yaml.list(a, yaml.get(yaml.get(v, "setup"), "collect_secrets"))) |x| if (yaml.str(yaml.get(x, "env_var"))) |n| try vars.append(a, n);
        f.env_vars = vars.items;
    } else |_| {
        // skills.zig's own reading, for the plain fields
        for (h.fields) |fl| {
            if (fl.nested) continue;
            if (std.mem.eql(u8, fl.key, "name")) f.name = fl.value;
            if (std.mem.eql(u8, fl.key, "description")) f.description = fl.value;
            if (std.mem.eql(u8, fl.key, "license")) f.license = fl.value;
            if (std.mem.eql(u8, fl.key, "compatibility")) f.compatibility = fl.value;
            if (std.mem.eql(u8, fl.key, "allowed-tools")) f.allowed_tools = fl.value;
        }
    }
    return f;
}

// ---- installing ----

/// Why a path kept from an archive can't be written here or on Windows
/// (`..`, `\`, a reserved device name, `<>:"|?*`, a control character, a
/// part ending in a dot or space), or null.
pub fn badName(a: std.mem.Allocator, rel: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return try std.fmt.allocPrint(a, "it holds a .. path ({s})", .{rel});
        for (part) |c| if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"|?*\\", c) != null) return try std.fmt.allocPrint(a, "it holds a name Windows can't hold ({s})", .{rel});
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return try std.fmt.allocPrint(a, "it holds a name Windows can't hold ({s})", .{rel});
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" }) |dev| {
            if (std.ascii.eqlIgnoreCase(stem, dev)) return try std.fmt.allocPrint(a, "it holds a name Windows can't hold ({s})", .{rel});
        }
    }
    return null;
}

/// SKILL.md with its frontmatter's `name` set to `name` (added after the
/// first fence when there is none); line ends kept.
pub fn renameSkill(a: std.mem.Allocator, md: []const u8, name: []const u8) ![]const u8 {
    const crlf = std.mem.indexOf(u8, md, "\r\n") != null;
    const nl: []const u8 = if (crlf) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, md, '\n');
    var n: usize = 0;
    var done = false;
    var in_header = false;
    while (it.next()) |raw| {
        n += 1;
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (n > 1) try out.append(a, '\n');
        if (n == 1) {
            in_header = true;
            try out.appendSlice(a, raw);
            continue;
        }
        if (in_header and std.mem.eql(u8, std.mem.trimEnd(u8, l, " \t"), "---")) {
            in_header = false;
            if (!done) {
                try out.print(a, "name: {s}{s}", .{ name, nl });
                done = true;
            }
            try out.appendSlice(a, raw);
            continue;
        }
        if (in_header and !done and std.mem.startsWith(u8, l, "name:")) {
            try out.print(a, "name: {s}{s}", .{ name, if (crlf) "\r" else "" });
            done = true;
            continue;
        }
        try out.appendSlice(a, raw);
    }
    return out.items;
}



/// Whether a path in a skill stays in it: relative, `/` between parts,
/// none empty, `.` or `..`.
pub fn safeRel(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/' or std.mem.indexOfAny(u8, rel, "\\\x00:") != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Writes `files` as `skills_dir/NAME/`, whole or not at all: into a
/// hidden folder beside it, then renamed. error.Exists when there is one;
/// error.BadPath for a path that would leave it. The executable bit is
/// kept for files under `scripts/` (Linux and macOS).
pub fn install(io: Io, a: std.mem.Allocator, skills_dir: []const u8, name: []const u8, files: []const File) !void {
    for (files) |f| if (!safeRel(f.rel)) return error.BadPath;
    const cwd = Io.Dir.cwd();
    const dest = try std.fs.path.join(a, &.{ skills_dir, name });
    if (cwd.statFile(io, dest, .{ .follow_symlinks = false })) |_| return error.Exists else |_| {}
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fs.path.join(a, &.{ skills_dir, try std.fmt.allocPrint(a, ".{s}.install-{s}", .{ name, &std.fmt.bytesToHex(rnd, .lower) }) });
    try cwd.createDirPath(io, tmp);
    errdefer cwd.deleteTree(io, tmp) catch {};
    for (files) |f| {
        const parts = try a.dupe(u8, f.rel);
        for (parts) |*c| if (c.* == '/') {
            c.* = std.fs.path.sep;
        };
        const path = try std.fs.path.join(a, &.{ tmp, parts });
        if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
        const exec = builtin.os.tag != .windows and f.exec and std.mem.startsWith(u8, f.rel, "scripts/");
        var file = try cwd.createFile(io, path, .{ .exclusive = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(if (exec) 0o700 else 0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, f.data);
    }
    try cwd.rename(tmp, cwd, dest, io);
}

const t = std.testing;

test "a_skills_hash_covers_names_and_contents" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_]File{ .{ .rel = "SKILL.md", .data = "---\nname: x\n---\n" }, .{ .rel = "scripts/run.sh", .data = "echo" } };
    const reordered = [_]File{ one[1], one[0] };
    const h = try hashFiles(a, &one);
    // the order given doesn't count; a name or a byte does
    try t.expectEqualStrings(&h, &(try hashFiles(a, &reordered)));
    try t.expect(!std.mem.eql(u8, &h, &(try hashFiles(a, &.{ one[0], .{ .rel = "scripts/run2.sh", .data = "echo" } }))));
    try t.expect(!std.mem.eql(u8, &h, &(try hashFiles(a, &.{ one[0], .{ .rel = "scripts/run.sh", .data = "echo!" } }))));
    // a name and bytes can't be shifted into each other
    try t.expect(!std.mem.eql(u8, &(try hashFiles(a, &.{.{ .rel = "ab", .data = "c" }})), &(try hashFiles(a, &.{.{ .rel = "a", .data = "bc" }}))));
    // a folder hashes as its files
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "s/scripts");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s/SKILL.md", .data = one[0].data });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s/scripts/run.sh", .data = one[1].data });
    const dir = try tmp.dir.realPathFileAlloc(t.io, "s", a);
    try t.expectEqualStrings(&h, &(try hashFolder(t.io, a, dir)));
}

test "sources_lines_round_trip" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "skills");
    const dir = try tmp.dir.realPathFileAlloc(t.io, "skills", a);
    try t.expectEqual(0, (try readSources(t.io, a, dir)).len);
    try putSource(t.io, a, dir, .{ .name = "pdf", .source = "anthropics/skills/skills/pdf", .pin = "e4bb5d960d87126ff3b3a8af1a104b7db67560ba", .hash = "abababababababababababababababababababababababababababababababab", .time = "2026-11-24T12:00:00Z" });
    try putSource(t.io, a, dir, .{ .name = "notes", .source = "/home/me/My Skills/notes", .pin = "-", .hash = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .time = "2026-11-24T12:00:00Z" });
    // the same name again replaces its line
    try putSource(t.io, a, dir, .{ .name = "pdf", .source = "anthropics/skills/skills/pdf", .pin = "1111111111111111111111111111111111111111", .hash = "efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef", .time = "2026-11-25T12:00:00Z" });
    const got = try readSources(t.io, a, dir);
    try t.expectEqual(2, got.len);
    try t.expectEqualStrings("notes", got[0].name);
    try t.expectEqualStrings("/home/me/My Skills/notes", got[0].source);
    try t.expectEqualStrings("pdf", got[1].name);
    try t.expectEqualStrings("1111111111111111111111111111111111111111", got[1].pin);
    try t.expectEqualStrings("efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef", got[1].hash);
    try t.expect(dropSource(t.io, a, dir, "notes") catch false);
    try t.expectEqual(1, (try readSources(t.io, a, dir)).len);
    // a line that doesn't read is skipped, the rest kept
    try tmp.dir.writeFile(t.io, .{ .sub_path = "skills/.sources", .data = "broken line\r\nx\tsrc\t-\t" ++ "0000000000000000000000000000000000000000000000000000000000000000" ++ "\t2026-11-24T12:00:00Z\r\n" });
    try t.expectEqual(1, (try readSources(t.io, a, dir)).len);
}

test "install_writes_the_folder_whole" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "skills");
    const dir = try tmp.dir.realPathFileAlloc(t.io, "skills", a);
    const files = [_]File{ .{ .rel = "SKILL.md", .data = "---\nname: x\ndescription: d\n---\n" }, .{ .rel = "scripts/run.sh", .data = "echo", .exec = true }, .{ .rel = "notes/a.txt", .data = "n", .exec = true } };
    try install(t.io, a, dir, "x", &files);
    try t.expectEqualStrings("echo", try tmp.dir.readFileAlloc(t.io, "skills/x/scripts/run.sh", a, .unlimited));
    if (builtin.os.tag != .windows) {
        // the executable bit is kept for scripts/ alone
        try t.expect((try tmp.dir.statFile(t.io, "skills/x/scripts/run.sh", .{})).permissions.toMode() & 0o100 != 0);
        try t.expect((try tmp.dir.statFile(t.io, "skills/x/notes/a.txt", .{})).permissions.toMode() & 0o111 == 0);
    }
    try t.expectError(error.Exists, install(t.io, a, dir, "x", &files));
    for ([_][]const u8{ "../x", "/abs", "a/../../b", "a\\b", "" }) |bad| {
        try t.expectError(error.BadPath, install(t.io, a, dir, "y", &.{.{ .rel = bad, .data = "" }}));
    }
    // nothing left of a refused one
    var d = try tmp.dir.openDir(t.io, "skills", .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(t.io)) |_| n += 1;
    try t.expectEqual(1, n);
}

test "sources_are_told_apart" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/home/me/skills/x", (try parseSource(a, "/home/me/skills/x", true)).folder);
    const short = (try parseSource(a, "anthropics/skills", false)).github;
    try t.expectEqualStrings("anthropics", short.owner);
    try t.expectEqualStrings("skills", short.repo);
    try t.expectEqualStrings("", short.path);
    try t.expectEqualStrings("", short.ref);
    const full = (try parseSource(a, "anthropics/skills/skills/pdf@v1.2", false)).github;
    try t.expectEqualStrings("skills/pdf", full.path);
    try t.expectEqualStrings("v1.2", full.ref);
    try t.expectEqualStrings("anthropics/skills/skills/pdf@v1.2", try sourceText(a, .{ .github = full }));
    const tree = (try parseSource(a, "https://github.com/anthropics/skills/tree/main/skills/pdf", false)).github;
    try t.expectEqualStrings("main", tree.ref);
    try t.expectEqualStrings("skills/pdf", tree.path);
    const blob = (try parseSource(a, "https://github.com/anthropics/skills/blob/main/skills/pdf/SKILL.md", false)).github;
    try t.expectEqualStrings("skills/pdf", blob.path);
    const bare = (try parseSource(a, "https://github.com/anthropics/skills.git", false)).github;
    try t.expectEqualStrings("skills", bare.repo);
    try t.expectEqualStrings("https://raw.githubusercontent.com/o/r/main/s/SKILL.md", (try parseSource(a, "https://raw.githubusercontent.com/o/r/main/s/SKILL.md", false)).link);
    try t.expectEqualStrings("http://127.0.0.1:8080/SKILL.md", (try parseSource(a, "http://127.0.0.1:8080/SKILL.md", false)).link);
    for ([_][]const u8{ "http://example.com/SKILL.md", "ftp://x/y", "justaword", "a/../b", "o/r@", "o/r/../x", "-x/y" }) |bad| {
        if (parseSource(a, bad, false)) |_| {
            std.debug.print("taken: {s}\n", .{bad});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try t.expect(try parseSource(a, "hermes", false) == .hermes);
}

test "facts_show_what_the_skill_asks_for" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try facts(a,
        \\---
        \\name: deploy
        \\description: >
        \\  Deploy the site,
        \\  safely.
        \\license: MIT
        \\compatibility: needs git and ssh
        \\allowed-tools: Bash(git:*) Read
        \\platforms: [linux, macos]
        \\required_environment_variables:
        \\  - name: DEPLOY_TOKEN
        \\    prompt: Your token
        \\  - SSH_HOST
        \\metadata:
        \\  hermes:
        \\    tags: [x]
        \\---  
        \\Body
    );
    try t.expectEqualStrings("deploy", f.name);
    try t.expectEqualStrings("Deploy the site, safely.", f.description);
    try t.expectEqualStrings("MIT", f.license);
    try t.expectEqualStrings("needs git and ssh", f.compatibility);
    try t.expectEqualStrings("Bash(git:*) Read", f.allowed_tools);
    try t.expectEqual(2, f.platforms.len);
    try t.expectEqualStrings("DEPLOY_TOKEN", f.env_vars[0]);
    try t.expectEqualStrings("SSH_HOST", f.env_vars[1]);
    // a list of tools reads too; no frontmatter: error
    try t.expectEqualStrings("Read Write", (try facts(a, "---\nname: x\ndescription: d\nallowed-tools: [Read, Write]\n---\n")).allowed_tools);
    try t.expectError(error.NoFrontmatter, facts(a, "no header"));
}
