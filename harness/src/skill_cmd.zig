//! `harness skill`: skills in the agentskills.io format installed from
//! the owner's terminal, from a folder, a GitHub repo (codeload's tar.gz,
//! pinned to the commit the archive names) or a link to a `SKILL.md`;
//! each keeps its source and hash in `skills/.sources`, so `update` can
//! show what changed and tell an edited one apart. Fetching is the
//! owner's command, not the agent's: it doesn't pass the gate, and it
//! keeps https (or http to this machine) and the archive's limits. What
//! a skill asks for (`allowed-tools`) is shown and ignored: harness's
//! rules decide.
const std = @import("std");
const builtin = @import("builtin");
const skills = @import("skills.zig");
const skillsrc = @import("skillsrc.zig");
const targz = @import("targz.zig");
const http = @import("http.zig");
const url_mod = @import("url.zig");
const util = @import("util.zig");
const hermes_import = @import("hermes_import.zig");
const Io = std.Io;

pub const Run = struct {
    io: Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    /// harness's data folder.
    home: []const u8,
    env: *const std.process.Environ.Map,
    term: hermes_import.Term,
    now_s: i64,
};

pub const Args = struct {
    op: enum { add, list, show, update, rm },
    target: []const u8 = "",
    skill: ?[]const u8 = null,
    yes: bool = false,
    force: bool = false,
};

pub fn runSkill(r: Run, args: Args) !u8 {
    const dir = try std.fs.path.join(r.a, &.{ r.home, "skills" });
    try Io.Dir.cwd().createDirPath(r.io, dir);
    return switch (args.op) {
        .add => add(r, dir, args),
        .list => list(r, dir),
        .show => show(r, dir, args.target),
        .update => update(r, dir, args),
        .rm => rm(r, dir, args.target),
    };
}

/// `add SOURCE [--skill NAME] [--yes]`, `list`, `show NAME`,
/// `update [NAME] [--force] [--yes]`, `rm NAME`; null when the words don't read.
pub fn parseArgs(rest: []const []const u8) ?Args {
    if (rest.len == 0) return null;
    var out: Args = .{ .op = std.meta.stringToEnum(@FieldType(Args, "op"), rest[0]) orelse return null };
    var targets: usize = 0;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const w = rest[i];
        if (std.mem.eql(u8, w, "--yes") and (out.op == .add or out.op == .update)) {
            out.yes = true;
        } else if (std.mem.eql(u8, w, "--force") and out.op == .update) {
            out.force = true;
        } else if (std.mem.eql(u8, w, "--skill") and out.op == .add) {
            i += 1;
            if (i >= rest.len or rest[i].len == 0 or rest[i][0] == '-' or out.skill != null) return null;
            out.skill = rest[i];
        } else if (w.len > 0 and w[0] == '-') {
            return null;
        } else {
            targets += 1;
            out.target = w;
        }
    }
    return switch (out.op) {
        .add, .show, .rm => if (targets == 1) out else null,
        .update => if (targets <= 1) out else null,
        .list => if (targets == 0) out else null,
    };
}

fn say(r: Run, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(r.a, fmt, args) catch return;
    r.term.print(r.term.ctx, text);
}

/// A skill found at a source: its folder's name there, its files (paths
/// relative to it), and what its SKILL.md says.
const Found = struct { folder: []const u8, files: []skillsrc.File, facts: ?skillsrc.Facts = null, why: ?[]const u8 = null };

/// What was fetched: the skills in it, and the commit or "-".
const Fetched = struct { skills: []Found, pin: []const u8, source: []const u8 };

fn add(r: Run, dir: []const u8, args: Args) !u8 {
    const got = fetch(r, args.target) catch |e| {
        say(r, "{s}: {s}\n", .{ args.target, fetchWhy(e) });
        return 1;
    };
    var picked: std.ArrayList(Found) = .empty;
    for (got.skills) |f| {
        if (args.skill) |want| if (!std.mem.eql(u8, f.folder, want) and !(f.facts != null and std.mem.eql(u8, f.facts.?.name, want))) continue;
        try picked.append(r.a, f);
    }
    if (picked.items.len == 0) {
        say(r, "{s}: {s}\n", .{ args.target, if (args.skill) |w| try std.fmt.allocPrint(r.a, "no skill {s} there", .{w}) else "no SKILL.md there" });
        return 1;
    }
    const installed = try skills.list(r.a, r.io, dir);
    var ok: std.ArrayList(Found) = .empty;
    for (picked.items) |f| {
        const why = f.why orelse blk: {
            const name = f.facts.?.name;
            if (isInstalled(installed, name) or folderExists(r, dir, name)) break :blk try std.fmt.allocPrint(r.a, "installed already; harness skill update {s}", .{name});
            break :blk null;
        };
        if (why) |w| {
            say(r, "{s}: {s}\n", .{ if (f.facts) |fa| fa.name else f.folder, w });
            continue;
        }
        try describe(r, got, f);
        try ok.append(r.a, f);
    }
    if (ok.items.len == 0) return 1;
    if (!args.yes) {
        const ask = r.term.ask orelse {
            say(r, "Not a terminal: add --yes to install.\n", .{});
            return 2;
        };
        const answer = std.mem.trim(u8, ask(r.term.ctx, "Install? [y/N] ") orelse "", " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
            say(r, "Nothing installed.\n", .{});
            return 0;
        }
    }
    var tb: [20]u8 = undefined;
    const time = util.isoTime(&tb, r.now_s);
    var installed_n: usize = 0;
    for (ok.items) |f| {
        const name = f.facts.?.name;
        skillsrc.install(r.io, r.a, dir, name, f.files) catch |e| {
            say(r, "{s}: not installed ({s})\n", .{ name, @errorName(e) });
            continue;
        };
        try skillsrc.putSource(r.io, r.a, dir, .{ .name = name, .source = try skillSource(r.a, got, f), .pin = got.pin, .hash = &(try skillsrc.hashFiles(r.a, f.files)), .time = time });
        say(r, "Installed {s}.\n", .{name});
        installed_n += 1;
    }
    // something installed: done, the rest said; nothing: refused
    return if (installed_n > 0) 0 else 1;
}

/// The source a skill's line keeps: one skill of several gets its own
/// path (a folder's subfolder, a repo's path).
fn skillSource(a: std.mem.Allocator, got: Fetched, f: Found) ![]const u8 {
    if (got.skills.len == 1 and f.folder.len == 0) return got.source;
    if (std.mem.startsWith(u8, got.source, "https://") or std.mem.startsWith(u8, got.source, "http://")) return got.source;
    if (std.fs.path.isAbsolute(got.source)) return std.fs.path.join(a, &.{ got.source, f.folder });
    // OWNER/REPO[/PATH][@REF]: the path grows
    const at = std.mem.lastIndexOfScalar(u8, got.source, '@');
    const main = if (at) |i| got.source[0..i] else got.source;
    const ref = if (at) |i| got.source[i..] else "";
    if (f.folder.len == 0) return got.source;
    return std.fmt.allocPrint(a, "{s}/{s}{s}", .{ main, f.folder, ref });
}

fn isInstalled(list_: []const skills.Skill, name: []const u8) bool {
    for (list_) |s| if (std.mem.eql(u8, s.name, name)) return true;
    return false;
}

fn folderExists(r: Run, dir: []const u8, name: []const u8) bool {
    const p = std.fs.path.join(r.a, &.{ dir, name }) catch return false;
    _ = Io.Dir.cwd().statFile(r.io, p, .{}) catch return false;
    return true;
}

/// The lines `add` shows before asking, one thing each.
fn describe(r: Run, got: Fetched, f: Found) !void {
    const fa = f.facts.?;
    say(r, "Skill {s}: {s}\n", .{ fa.name, fa.description });
    const source = try skillSource(r.a, got, f);
    if (got.pin.len == 40) say(r, "  Source: {s}, commit {s}\n", .{ source, got.pin[0..12] }) else say(r, "  Source: {s}\n", .{source});
    var bytes: usize = 0;
    var scripts: std.ArrayList([]const u8) = .empty;
    for (f.files) |x| {
        bytes += x.data.len;
        if (std.mem.startsWith(u8, x.rel, "scripts/")) try scripts.append(r.a, x.rel);
    }
    say(r, "  {d} file{s}, {d} bytes\n", .{ f.files.len, if (f.files.len == 1) "" else "s", bytes });
    if (scripts.items.len > 0) say(r, "  Scripts: {s}\n", .{try std.mem.join(r.a, ", ", scripts.items)});
    if (fa.license.len > 0) say(r, "  License: {s}\n", .{fa.license});
    if (fa.compatibility.len > 0) say(r, "  Compatibility: {s}\n", .{fa.compatibility});
    if (fa.allowed_tools.len > 0) say(r, "  The skill asks for: {s}. harness's rules decide instead.\n", .{fa.allowed_tools});
    if (fa.platforms.len > 0 and !forThisSystem(fa.platforms)) say(r, "  For: {s} (not this system)\n", .{try std.mem.join(r.a, ", ", fa.platforms)});
    if (fa.env_vars.len > 0) say(r, "  This skill expects: {s}. harness doesn't put secrets into commands' environments; an MCP server's secret = in mcp.ini would give them to that program.\n", .{try std.mem.join(r.a, ", ", fa.env_vars)});
    if (got.skills.len == 1 and got.pin.len > 0 and std.mem.eql(u8, got.pin, "-") and isLink(got.source)) {
        const refs = try referredFiles(r.a, f.files[0].data);
        if (refs.len > 0) say(r, "  It refers to other files ({s}): a skill with files of its own needs the repo form, OWNER/REPO/PATH\n", .{try std.mem.join(r.a, ", ", refs)});
    }
    say(r, "  Once installed, harness skill show {s} prints its whole SKILL.md.\n", .{fa.name});
}

fn isLink(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://");
}

/// Whether Hermes's `platforms` list holds this system (macos, linux, windows).
fn forThisSystem(platforms: []const []const u8) bool {
    const here = switch (builtin.os.tag) {
        .macos => "macos",
        .windows => "windows",
        else => "linux",
    };
    for (platforms) |p| {
        if (std.ascii.eqlIgnoreCase(p, here)) return true;
        if (std.ascii.eqlIgnoreCase(p, "darwin") and builtin.os.tag == .macos) return true;
        if (std.ascii.eqlIgnoreCase(p, "win32") and builtin.os.tag == .windows) return true;
    }
    return false;
}

/// Files a SKILL.md refers to: markdown links to relative paths, and
/// words like `scripts/x` or `references/y`.
fn referredFiles(a: std.mem.Allocator, md: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < md.len) : (i += 1) {
        var start: ?usize = null;
        if (md[i] == '(' and i > 0 and md[i - 1] == ']') start = i + 1;
        for ([_][]const u8{ "scripts/", "references/", "templates/", "assets/" }) |pre| {
            if (std.mem.startsWith(u8, md[i..], pre) and (i == 0 or md[i - 1] == ' ' or md[i - 1] == '`' or md[i - 1] == '\n' or md[i - 1] == '(')) start = i;
        }
        const s = start orelse continue;
        var e = s;
        while (e < md.len and !std.ascii.isWhitespace(md[e]) and md[e] != ')' and md[e] != '`' and md[e] != ',') e += 1;
        var ref = md[s..e];
        while (ref.len > 0 and (ref[ref.len - 1] == '.' or ref[ref.len - 1] == ':')) ref = ref[0 .. ref.len - 1];
        i = e;
        if (ref.len == 0 or std.mem.indexOf(u8, ref, "://") != null or ref[0] == '#' or std.mem.startsWith(u8, ref, "mailto:")) continue;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, ref)) break;
        } else try out.append(a, ref);
    }
    return out.items;
}

/// The skills at a source, each with its files and facts (or why it can't be installed).
fn fetch(r: Run, text: []const u8) !Fetched {
    const cwd = Io.Dir.cwd();
    const is_folder = if (cwd.statFile(r.io, text, .{})) |st| st.kind == .directory else |_| false;
    const src = try skillsrc.parseSource(r.a, if (is_folder) (cwd.realPathFileAlloc(r.io, text, r.a) catch text) else text, is_folder);
    switch (src) {
        .hermes => return error.NoSource,
        .folder => |f| return .{ .skills = try skillsIn(r.a, try folderFiles(r, f), std.fs.path.basename(f)), .pin = "-", .source = f },
        .link => |l| {
            const body = try download(r, l, skills.max_body + 1);
            if (body.len > skills.max_body) return error.SkillMdTooLarge;
            const files = try r.a.alloc(skillsrc.File, 1);
            files[0] = .{ .rel = "SKILL.md", .data = body };
            var found = try skillsIn(r.a, files, "");
            // a link names no folder: the skill's own name is its folder's
            for (found) |*fd| if (fd.facts) |fa| {
                fd.folder = fa.name;
                if (fd.why != null and std.mem.indexOf(u8, fd.why.?, "doesn't match its folder") != null) fd.why = null;
            };
            if (found.len == 1) found[0].folder = "";
            return .{ .skills = found, .pin = "-", .source = l };
        },
        .github => |g| {
            const base = r.env.get("HARNESS_CODELOAD_URL") orelse "https://codeload.github.com";
            const u = try std.fmt.allocPrint(r.a, "{s}/{s}/{s}/tar.gz/{s}", .{ std.mem.trimEnd(u8, base, "/"), g.owner, g.repo, if (g.ref.len > 0) g.ref else "HEAD" });
            const gz = download(r, u, 50 * 1024 * 1024) catch |e| return if (e == error.NotFound) error.NoSuchRepo else e;
            var d: targz.Diag = .{};
            const ar = targz.read(r.a, gz, .{ .path = g.path }, &d) catch |e| {
                say(r, "{s}/{s}: {s}\n", .{ g.owner, g.repo, d.why });
                return e;
            };
            // a path's last part is the skill's folder; a repo's root has none
            return .{ .skills = try skillsIn(r.a, ar.files, std.fs.path.basenamePosix(g.path)), .pin = ar.commit, .source = try skillsrc.sourceText(r.a, src) };
        },
    }
}

fn fetchWhy(e: anyerror) []const u8 {
    return switch (e) {
        error.NoSuchRepo => "GitHub has no such repo or ref",
        error.PlainHttp => "https only (plain http only to this machine)",
        error.BadSource => "not a folder, OWNER/REPO[/PATH][@REF], a github.com link or an https link to a SKILL.md",
        error.NoSource => "a skill from Hermes has no source to fetch",
        error.SkillMdTooLarge => "the SKILL.md is over 64 KB",
        error.TooLarge => "over harness's limits for a skill (300 files, 10 MB, 64 KB for SKILL.md, 256 KB a file)",
        error.NotFound => "the link answers 404",
        error.BadStatus => "the server answered with an error",
        error.TooLong => "the download is over its limit",
        else => @errorName(e),
    };
}

fn folderFiles(r: Run, folder: []const u8) ![]skillsrc.File {
    return skillsrc.readFolder(r.io, r.a, folder);
}

/// The skills in a set of files: one, when SKILL.md is at the top (its
/// folder named `top`, "" when it has no folder to match); else one per
/// folder holding a SKILL.md (its files those under it).
fn skillsIn(a: std.mem.Allocator, files: []skillsrc.File, top: []const u8) ![]Found {
    var out: std.ArrayList(Found) = .empty;
    for (files) |f| if (std.mem.eql(u8, f.rel, "SKILL.md")) {
        var one = try check(a, top, files);
        one.folder = "";
        try out.append(a, one);
        return out.items;
    };
    for (files) |f| {
        if (!std.mem.endsWith(u8, f.rel, "/SKILL.md")) continue;
        const folder = f.rel[0 .. f.rel.len - "/SKILL.md".len];
        // a skill inside another skill's folder belongs to that one
        var nested = false;
        for (out.items) |o| if (std.mem.startsWith(u8, folder, o.folder) and folder.len > o.folder.len and folder[o.folder.len] == '/') {
            nested = true;
        };
        if (nested) continue;
        var mine: std.ArrayList(skillsrc.File) = .empty;
        for (files) |g| if (std.mem.startsWith(u8, g.rel, folder) and g.rel.len > folder.len and g.rel[folder.len] == '/') {
            try mine.append(a, .{ .rel = g.rel[folder.len + 1 ..], .data = g.data, .exec = g.exec });
        };
        try out.append(a, try check(a, folder, mine.items));
    }
    return out.items;
}

/// A skill's checks: its SKILL.md reads, its name is valid and its folder's.
fn check(a: std.mem.Allocator, folder: []const u8, files: []skillsrc.File) !Found {
    var out: Found = .{ .folder = folder, .files = files };
    var md: []const u8 = "";
    for (files) |f| if (std.mem.eql(u8, f.rel, "SKILL.md")) {
        md = f.data;
    };
    if (md.len > skills.max_body) {
        out.why = "its SKILL.md is over 64 KB";
        return out;
    }
    const fa = skillsrc.facts(a, md) catch {
        out.why = "its SKILL.md has no frontmatter (--- lines around name and description)";
        return out;
    };
    out.facts = fa;
    const base = if (std.mem.lastIndexOfScalar(u8, folder, '/')) |i| folder[i + 1 ..] else folder;
    if (fa.name.len == 0) {
        out.why = "its SKILL.md has no name";
    } else if (!skills.validName(fa.name)) {
        out.why = try std.fmt.allocPrint(a, "its name {s} isn't a skill name (a-z, 0-9 and single -, up to 64)", .{fa.name});
    } else if (fa.description.len == 0 or fa.description.len > skills.max_description) {
        out.why = "its SKILL.md has no description of at most 1,024 characters";
    } else if (base.len > 0 and !std.mem.eql(u8, base, fa.name)) {
        out.why = try std.fmt.allocPrint(a, "its name {s} doesn't match its folder {s}", .{ fa.name, base });
    }
    for (files) |f| if (f.data.len > skills.max_file) {
        out.why = try std.fmt.allocPrint(a, "{s} is over 256 KB", .{f.rel});
    };
    return out;
}

/// GETs `link` (https, or http to this machine), following up to three
/// redirects; at most `max` bytes (error.TooLong past them).
fn download(r: Run, link: []const u8, max: usize) ![]u8 {
    var current = link;
    var hops: u8 = 0;
    while (true) : (hops += 1) {
        const u = url_mod.parse(r.a, current) catch return error.BadSource;
        if (!u.https and !(std.mem.eql(u8, u.host, "localhost") or std.mem.eql(u8, u.host, "[::1]") or std.mem.startsWith(u8, u.host, "127."))) return error.PlainHttp;
        const host = if (u.host.len > 1 and u.host[0] == '[') u.host[1 .. u.host.len - 1] else u.host;
        var c = http.Client.init(r.gpa, r.io, .{ .https = u.https, .host = host, .port = u.port, .prefix = "" });
        defer c.deinit();
        var resp = try c.send(.{ .method = .GET, .path = u.target, .limits = .{ .idle_ms = 30_000, .total_ms = 300_000 } });
        defer resp.deinit();
        if (resp.status >= 300 and resp.status < 400) {
            const loc = resp.location orelse return error.BadStatus;
            if (hops >= 3) return error.BadStatus;
            current = if (std.mem.startsWith(u8, loc, "http")) try r.a.dupe(u8, loc) else try std.fmt.allocPrint(r.a, "{s}://{s}{s}", .{ if (u.https) "https" else "http", u.host, loc });
            continue;
        }
        if (resp.status == 404) return error.NotFound;
        if (resp.status != 200) return error.BadStatus;
        var out: std.ArrayList(u8) = .empty;
        while (try resp.next()) |part| {
            if (out.items.len + part.len > max) return error.TooLong;
            try out.appendSlice(r.a, part);
        }
        return out.items;
    }
}

fn list(r: Run, dir: []const u8) !u8 {
    const installed = try skills.list(r.a, r.io, dir);
    const lines = try skillsrc.readSources(r.io, r.a, dir);
    if (installed.len == 0 and lines.len == 0) {
        say(r, "No skills.\n", .{});
        return 0;
    }
    for (installed) |s| {
        const line = skillsrc.findSource(lines, s.name) orelse {
            say(r, "{s}  saved by the agent\n", .{s.name});
            continue;
        };
        const now: [64]u8 = skillsrc.hashFolder(r.io, r.a, try std.fs.path.join(r.a, &.{ dir, s.name })) catch @splat('?');
        const edited = !std.mem.eql(u8, &now, line.hash);
        const where = if (std.mem.eql(u8, line.source, "hermes")) "from Hermes (no source to update from)" else if (line.pin.len == 40) try std.fmt.allocPrint(r.a, "{s}, commit {s}", .{ line.source, line.pin[0..12] }) else line.source;
        say(r, "{s}  {s}{s}\n", .{ s.name, where, if (edited) " (edited since it was installed)" else "" });
    }
    for (lines) |l| if (!isInstalled(installed, l.name)) say(r, "{s}  its folder is gone or doesn't read (harness skill rm {s} forgets it)\n", .{ l.name, l.name });
    return 0;
}

fn show(r: Run, dir: []const u8, name: []const u8) !u8 {
    if (!skills.validName(name)) {
        say(r, "No skill {s}.\n", .{name});
        return 1;
    }
    const md = Io.Dir.cwd().readFileAlloc(r.io, try std.fs.path.join(r.a, &.{ dir, name, "SKILL.md" }), r.a, .limited(skills.max_body + 1)) catch {
        say(r, "No skill {s}.\n", .{name});
        return 1;
    };
    say(r, "{s}{s}", .{ md, if (md.len > 0 and md[md.len - 1] != '\n') "\n" else "" });
    const files = skillsrc.readFolder(r.io, r.a, try std.fs.path.join(r.a, &.{ dir, name })) catch &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (files) |f| if (!std.mem.eql(u8, f.rel, "SKILL.md")) try names.append(r.a, f.rel);
    if (names.items.len > 0) say(r, "\nOther files: {s}\n", .{try std.mem.join(r.a, ", ", names.items)});
    if (skillsrc.findSource(try skillsrc.readSources(r.io, r.a, dir), name)) |l| say(r, "Source: {s}{s}{s}\n", .{ l.source, if (l.pin.len == 40) ", commit " else "", if (l.pin.len == 40) l.pin[0..12] else "" });
    return 0;
}

fn update(r: Run, dir: []const u8, args: Args) !u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (args.target.len > 0) try names.append(r.a, args.target) else for (try skillsrc.readSources(r.io, r.a, dir)) |l| try names.append(r.a, l.name);
    if (names.items.len == 0) {
        say(r, "No installed skill has a source to update from.\n", .{});
        return 0;
    }
    var code: u8 = 0;
    for (names.items) |n| {
        const c = try updateOne(r, dir, n, args);
        if (c > code) code = c;
    }
    return code;
}

fn updateOne(r: Run, dir: []const u8, name: []const u8, args: Args) !u8 {
    const folder = try std.fs.path.join(r.a, &.{ dir, name });
    if (!skills.validName(name) or !folderExists(r, dir, name)) {
        say(r, "{s}: no such skill\n", .{name});
        return 1;
    }
    const line = skillsrc.findSource(try skillsrc.readSources(r.io, r.a, dir), name) orelse {
        say(r, "{s}: saved by the agent; nothing to update from\n", .{name});
        return 0;
    };
    if (std.mem.eql(u8, line.source, "hermes")) {
        say(r, "{s}: from Hermes; nothing to update from\n", .{name});
        return 0;
    }
    const now = try skillsrc.hashFolder(r.io, r.a, folder);
    if (!std.mem.eql(u8, &now, line.hash) and !args.force) {
        say(r, "{s}: edited since it was installed; harness skill update {s} --force replaces it\n", .{ name, name });
        return 1;
    }
    const got = fetch(r, line.source) catch |e| {
        say(r, "{s}: {s}: {s}\n", .{ name, line.source, fetchWhy(e) });
        return 1;
    };
    var fresh: ?Found = null;
    for (got.skills) |f| if (f.facts != null and std.mem.eql(u8, f.facts.?.name, name)) {
        fresh = f;
    };
    const f = fresh orelse {
        say(r, "{s}: {s} no longer has it\n", .{ name, line.source });
        return 1;
    };
    if (f.why) |why| {
        say(r, "{s}: {s}\n", .{ name, why });
        return 1;
    }
    const new_hash = try skillsrc.hashFiles(r.a, f.files);
    if (std.mem.eql(u8, &new_hash, &now)) {
        if (got.pin.len == 40) say(r, "{s}: up to date (commit {s})\n", .{ name, got.pin[0..12] }) else say(r, "{s}: up to date\n", .{name});
        return 0;
    }
    // what changes
    const old_files = try skillsrc.readFolder(r.io, r.a, folder);
    say(r, "{s}: {s}{s}{s}\n", .{ name, line.source, if (got.pin.len == 40) ", commit " else "", if (got.pin.len == 40) got.pin[0..12] else "" });
    for (f.files) |nf| {
        for (old_files) |of| {
            if (std.mem.eql(u8, of.rel, nf.rel)) {
                if (!std.mem.eql(u8, of.data, nf.data)) say(r, "  changed: {s}\n", .{nf.rel});
                break;
            }
        } else say(r, "  new: {s}\n", .{nf.rel});
    }
    for (old_files) |of| {
        for (f.files) |nf| {
            if (std.mem.eql(u8, of.rel, nf.rel)) break;
        } else say(r, "  gone: {s}\n", .{of.rel});
    }
    if (!args.yes) {
        const ask = r.term.ask orelse {
            say(r, "Not a terminal: add --yes to replace it.\n", .{});
            return 2;
        };
        const answer = std.mem.trim(u8, ask(r.term.ctx, "Replace it? [y/N] ") orelse "", " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
            say(r, "{s}: left as it is.\n", .{name});
            return 0;
        }
    }
    // the old one kept, as a skill the agent replaces is
    var tb: [20]u8 = undefined;
    const time = util.isoTime(&tb, r.now_s);
    const stamp = try std.fmt.allocPrint(r.a, "{s}{s}{s}-{s}{s}{s}", .{ time[0..4], time[5..7], time[8..10], time[11..13], time[14..16], time[17..19] });
    const versions = try std.fs.path.join(r.a, &.{ r.home, "state", "skills", name, "versions" });
    try Io.Dir.cwd().createDirPath(r.io, versions);
    const kept = try std.fs.path.join(r.a, &.{ versions, stamp });
    try Io.Dir.cwd().rename(folder, Io.Dir.cwd(), kept, r.io);
    skillsrc.install(r.io, r.a, dir, name, f.files) catch |e| {
        // put the old one back
        Io.Dir.cwd().rename(kept, Io.Dir.cwd(), folder, r.io) catch {};
        say(r, "{s}: not replaced ({s})\n", .{ name, @errorName(e) });
        return 1;
    };
    try skillsrc.putSource(r.io, r.a, dir, .{ .name = name, .source = line.source, .pin = got.pin, .hash = &new_hash, .time = time });
    say(r, "{s}: replaced (the old one is in {s}).\n", .{ name, kept });
    return 0;
}

fn rm(r: Run, dir: []const u8, name: []const u8) !u8 {
    const gone = try skills.remove(r.io, dir, name);
    const dropped = skillsrc.dropSource(r.io, r.a, dir, name) catch false;
    if (!gone and !dropped) {
        say(r, "No skill {s}.\n", .{name});
        return 1;
    }
    say(r, "Removed {s}.\n", .{name});
    return 0;
}

// ---- tests ----

const t = std.testing;
const model = @import("model.zig");

const Sx = struct {
    e: model.TestEnv,
    home: []const u8,
    env: std.process.Environ.Map,
    out: std.ArrayList(u8) = .empty,
    answer: ?[]const u8 = null,

    fn init(sx: *Sx) !void {
        try sx.e.init();
        const al = sx.e.arena.allocator();
        sx.home = try std.fs.path.join(al, &.{ sx.e.dir, "harness" });
        try @import("core.zig").initHome(t.io, al, sx.home);
        sx.env = std.process.Environ.Map.init(al);
        try sx.env.put("HARNESS_CODELOAD_URL", try std.fmt.allocPrint(al, "{s}/codeload", .{try sx.e.url()}));
        sx.out = .empty;
        sx.answer = null;
    }

    fn deinit(sx: *Sx) void {
        sx.e.deinit();
    }

    fn a(sx: *Sx) std.mem.Allocator {
        return sx.e.arena.allocator();
    }

    fn print(ctx: ?*anyopaque, text: []const u8) void {
        const sx: *Sx = @ptrCast(@alignCast(ctx.?));
        sx.out.appendSlice(sx.a(), text) catch {};
    }

    fn ask(ctx: ?*anyopaque, q: []const u8) ?[]const u8 {
        const sx: *Sx = @ptrCast(@alignCast(ctx.?));
        sx.out.appendSlice(sx.a(), q) catch {};
        return sx.answer;
    }

    fn run(sx: *Sx, words: []const []const u8) !u8 {
        const args = parseArgs(words) orelse return error.BadArgs;
        return runSkill(.{ .io = t.io, .gpa = t.allocator, .a = sx.a(), .home = sx.home, .env = &sx.env, .term = .{ .ctx = sx, .print = print, .ask = if (sx.answer != null) ask else null }, .now_s = 1795521600 }, args);
    }

    /// A file in the fake's script folder (`repos/…`, `pages/…`) or anywhere under it.
    fn put(sx: *Sx, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try sx.e.tmp.dir.createDirPath(t.io, d);
        try sx.e.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    fn path(sx: *Sx, rel: []const u8) []const u8 {
        return std.fs.path.join(sx.a(), &.{ sx.e.dir, rel }) catch unreachable;
    }

    fn installed(sx: *Sx, rel: []const u8) ?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(t.io, std.fs.path.join(sx.a(), &.{ sx.home, "skills", rel }) catch return null, sx.a(), .unlimited) catch null;
    }

    fn sources(sx: *Sx) ![]skillsrc.Line {
        return skillsrc.readSources(t.io, sx.a(), try std.fs.path.join(sx.a(), &.{ sx.home, "skills" }));
    }

    fn said(sx: *Sx, needle: []const u8) bool {
        return std.mem.indexOf(u8, sx.out.items, needle) != null;
    }
};

const deploy_md =
    \\---
    \\name: deploy
    \\description: Deploy the site.
    \\license: MIT
    \\compatibility: needs git
    \\allowed-tools: Bash(git:*) Read
    \\platforms: [PLATFORM]
    \\required_environment_variables:
    \\  - name: DEPLOY_TOKEN
    \\---
    \\Run scripts/run.sh.
    \\
;

fn deployMd(a: std.mem.Allocator) ![]const u8 {
    return std.mem.replaceOwned(u8, a, deploy_md, "PLATFORM", if (builtin.os.tag == .windows) "linux" else "windows");
}

test "add_from_a_folder_shows_then_installs" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("src/deploy/SKILL.md", try deployMd(sx.a()));
    try sx.put("src/deploy/scripts/run.sh", "#!/bin/sh\necho deploy\n");
    // a clone's .git is no part of the skill
    try sx.put("src/deploy/.git/config", "[core]\n");
    // no terminal and no --yes: shown, not installed
    try t.expectEqual(2, try sx.run(&.{ "add", sx.path("src/deploy") }));
    try t.expect(sx.said("add --yes"));
    try t.expect(sx.installed("deploy/SKILL.md") == null);
    for ([_][]const u8{
        "Skill deploy: Deploy the site.",
        "2 files, ",
        "Scripts: scripts/run.sh",
        "License: MIT",
        "Compatibility: needs git",
        "The skill asks for: Bash(git:*) Read. harness's rules decide instead.",
        " (not this system)",
        "This skill expects: DEPLOY_TOKEN. harness doesn't put secrets into commands' environments",
        "harness skill show deploy",
    }) |line| if (!sx.said(line)) {
        std.debug.print("missing: {s}\n{s}\n", .{ line, sx.out.items });
        return error.TestUnexpectedResult;
    };
    try t.expect(sx.said(try std.fmt.allocPrint(sx.a(), "Source: {s}", .{sx.path("src/deploy")})));
    // at a terminal, yes installs it
    sx.answer = "y";
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("src/deploy") }));
    try t.expect(sx.said("Install? [y/N] "));
    try t.expectEqualStrings(try deployMd(sx.a()), sx.installed("deploy/SKILL.md").?);
    try t.expect(sx.installed("deploy/.git/config") == null);
    const src = (try sx.sources())[0];
    try t.expectEqualStrings("deploy", src.name);
    try t.expectEqualStrings(sx.path("src/deploy"), src.source);
    try t.expectEqualStrings("-", src.pin);
    // a folder of skill folders: all of them, or the one --skill names
    try sx.put("many/one/SKILL.md", "---\nname: one\ndescription: One.\n---\n");
    try sx.put("many/two/SKILL.md", "---\nname: two\ndescription: Two.\n---\n");
    sx.answer = null;
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("many"), "--skill", "two", "--yes" }));
    try t.expect(sx.installed("two/SKILL.md") != null);
    try t.expect(sx.installed("one/SKILL.md") == null);
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("many"), "--yes" }));
    try t.expect(sx.installed("one/SKILL.md") != null);
    try t.expect(sx.said("two: installed already; harness skill update two"));
}

test "add_from_github_pins_the_commit" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("repos/anthropics/skills/README.md", "# skills\n");
    try sx.put("repos/anthropics/skills/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Work with PDFs.\n---\nUse pdftotext.\n");
    try sx.put("repos/anthropics/skills/skills/pdf/reference.md", "ref\n");
    try sx.put("repos/anthropics/skills/skills/xlsx/SKILL.md", "---\nname: xlsx\ndescription: Spreadsheets.\n---\nx\n");
    try sx.put("repos/anthropics/skills.commit", "e4bb5d960d87126ff3b3a8af1a104b7db67560ba\n");
    try t.expectEqual(0, try sx.run(&.{ "add", "anthropics/skills/skills/pdf", "--yes" }));
    try t.expect(sx.said("Source: anthropics/skills/skills/pdf, commit e4bb5d960d87"));
    try t.expectEqualStrings("ref\n", sx.installed("pdf/reference.md").?);
    const src = (try sx.sources())[0];
    try t.expectEqualStrings("anthropics/skills/skills/pdf", src.source);
    try t.expectEqualStrings("e4bb5d960d87126ff3b3a8af1a104b7db67560ba", src.pin);
    // the default branch is asked for as HEAD; a ref as given; a github.com link too
    try t.expectEqual(0, try sx.run(&.{ "add", "https://github.com/anthropics/skills/tree/v1/skills/xlsx", "--yes" }));
    try t.expect(sx.installed("xlsx/SKILL.md") != null);
    const reqs = try sx.e.tmp.dir.readFileAlloc(t.io, "codeload-requests.jsonl", sx.a(), .unlimited);
    try t.expect(std.mem.indexOf(u8, reqs, "/codeload/anthropics/skills/tar.gz/HEAD") != null);
    try t.expect(std.mem.indexOf(u8, reqs, "/codeload/anthropics/skills/tar.gz/v1") != null);
    // no such repo
    try t.expectEqual(1, try sx.run(&.{ "add", "nobody/nothing", "--yes" }));
    try t.expect(sx.said("nobody/nothing: GitHub has no such repo or ref"));
}

test "add_from_a_link_fetches_one_file" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("pages/notes.md", "---\nname: notes\ndescription: Keep notes.\n---\nSee scripts/tidy.sh and [the guide](references/guide.md).\n");
    const link = try std.fmt.allocPrint(sx.a(), "{s}/page/notes.md", .{try sx.e.url()});
    try t.expectEqual(0, try sx.run(&.{ "add", link, "--yes" }));
    try t.expect(sx.installed("notes/SKILL.md") != null);
    try t.expect(sx.said("It refers to other files (scripts/tidy.sh, references/guide.md): a skill with files of its own needs the repo form, OWNER/REPO/PATH"));
    try t.expectEqualStrings(link, (try sx.sources())[0].source);
    // plain http only to this machine
    try t.expectEqual(1, try sx.run(&.{ "add", "http://skills.example.com/SKILL.md", "--yes" }));
}

test "a_name_already_installed_is_refused_naming_update" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try skills.save(t.io, try std.fs.path.join(sx.a(), &.{ sx.home, "skills" }), "deploy", "Mine.", "Body\n");
    try sx.put("src/deploy/SKILL.md", try deployMd(sx.a()));
    try t.expectEqual(1, try sx.run(&.{ "add", sx.path("src/deploy"), "--yes" }));
    try t.expect(sx.said("deploy: installed already; harness skill update deploy"));
    try t.expectEqualStrings("Body\n", (try skills.load(sx.a(), t.io, try std.fs.path.join(sx.a(), &.{ sx.home, "skills" }), "deploy")));
    // a name that doesn't match its folder, a SKILL.md that doesn't read
    try sx.put("src/wrong/SKILL.md", "---\nname: right\ndescription: d\n---\n");
    try t.expectEqual(1, try sx.run(&.{ "add", sx.path("src/wrong"), "--yes" }));
    try t.expect(sx.said("its name right doesn't match its folder wrong"));
    try sx.put("src/bad/SKILL.md", "no frontmatter\n");
    try t.expectEqual(1, try sx.run(&.{ "add", sx.path("src/bad"), "--yes" }));
    try t.expect(sx.said("its SKILL.md has no frontmatter"));
}

test "update_shows_changed_files_and_asks" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("repos/o/r/SKILL.md", "---\nname: r\ndescription: First.\n---\nOne.\n");
    try sx.put("repos/o/r/old.md", "old\n");
    try sx.put("repos/o/r.commit", "1111111111111111111111111111111111111111");
    try t.expectEqual(0, try sx.run(&.{ "add", "o/r", "--yes" }));
    try t.expectEqual(0, try sx.run(&.{ "update", "r" }));
    try t.expect(sx.said("r: up to date (commit 111111111111)"));
    try sx.put("repos/o/r/SKILL.md", "---\nname: r\ndescription: Second.\n---\nTwo.\n");
    try sx.e.tmp.dir.deleteFile(t.io, "repos/o/r/old.md");
    try sx.put("repos/o/r/new.md", "new\n");
    try sx.put("repos/o/r.commit", "2222222222222222222222222222222222222222");
    sx.out = .empty;
    // no terminal, no --yes: shown and left
    try t.expectEqual(2, try sx.run(&.{ "update", "r" }));
    for ([_][]const u8{ "changed: SKILL.md", "new: new.md", "gone: old.md" }) |l| try t.expect(sx.said(l));
    try t.expect(sx.installed("old.md") != null or sx.installed("r/old.md") != null);
    try t.expectEqual(0, try sx.run(&.{ "update", "r", "--yes" }));
    try t.expect(std.mem.indexOf(u8, sx.installed("r/SKILL.md").?, "Second.") != null);
    try t.expect(sx.installed("r/old.md") == null);
    try t.expectEqualStrings("2222222222222222222222222222222222222222", (try sx.sources())[0].pin);
    // the replaced one is kept
    const kept = try std.fs.path.join(sx.a(), &.{ sx.home, "state", "skills", "r", "versions" });
    var d = try Io.Dir.cwd().openDir(t.io, kept, .{ .iterate = true });
    d.close(t.io);
}

test "an_edited_skill_needs_force" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("src/deploy/SKILL.md", try deployMd(sx.a()));
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("src/deploy"), "--yes" }));
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(sx.a(), &.{ sx.home, "skills", "deploy", "SKILL.md" }), .data = "---\nname: deploy\ndescription: Edited here.\n---\n" });
    try sx.put("src/deploy/extra.md", "more\n");
    try t.expectEqual(1, try sx.run(&.{ "update", "deploy", "--yes" }));
    try t.expect(sx.said("deploy: edited since it was installed; harness skill update deploy --force replaces it"));
    try t.expect(std.mem.indexOf(u8, sx.installed("deploy/SKILL.md").?, "Edited here.") != null);
    try t.expectEqual(0, try sx.run(&.{ "update", "deploy", "--force", "--yes" }));
    try t.expect(sx.installed("deploy/extra.md") != null);
    // a skill the agent saved, or one from Hermes, has nothing to update from
    try skills.save(t.io, try std.fs.path.join(sx.a(), &.{ sx.home, "skills" }), "mine", "Mine.", "Body\n");
    try t.expectEqual(0, try sx.run(&.{ "update", "mine" }));
    try t.expect(sx.said("mine: saved by the agent; nothing to update from"));
}

test "rm_removes_the_folder_and_its_line" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("src/deploy/SKILL.md", try deployMd(sx.a()));
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("src/deploy"), "--yes" }));
    try t.expectEqual(0, try sx.run(&.{ "rm", "deploy" }));
    try t.expect(sx.installed("deploy/SKILL.md") == null);
    try t.expectEqual(0, (try sx.sources()).len);
    try t.expectEqual(1, try sx.run(&.{ "rm", "deploy" }));
    try t.expect(sx.said("No skill deploy."));
}

test "list_shows_each_source" {
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("src/deploy/SKILL.md", try deployMd(sx.a()));
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("src/deploy"), "--yes" }));
    const dir = try std.fs.path.join(sx.a(), &.{ sx.home, "skills" });
    try skills.save(t.io, dir, "mine", "Mine.", "Body\n");
    try skills.save(t.io, dir, "imported", "From Hermes.", "Body\n");
    try skillsrc.putSource(t.io, sx.a(), dir, .{ .name = "imported", .source = "hermes", .pin = "-", .hash = &(try skillsrc.hashFolder(t.io, sx.a(), try std.fs.path.join(sx.a(), &.{ dir, "imported" }))), .time = "2026-11-24T12:00:00Z" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(sx.a(), &.{ dir, "deploy", "SKILL.md" }), .data = "---\nname: deploy\ndescription: Edited.\n---\n" });
    sx.out = .empty;
    try t.expectEqual(0, try sx.run(&.{"list"}));
    try t.expect(sx.said(try std.fmt.allocPrint(sx.a(), "deploy  {s} (edited since it was installed)", .{sx.path("src/deploy")})));
    try t.expect(sx.said("imported  from Hermes (no source to update from)"));
    try t.expect(sx.said("mine  saved by the agent"));
    sx.out = .empty;
    try t.expectEqual(0, try sx.run(&.{ "show", "mine" }));
    try t.expect(sx.said("description: \"Mine.\""));
    try t.expectEqual(1, try sx.run(&.{ "show", "nope" }));
}

test "scripts_keep_their_executable_bit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var sx: Sx = undefined;
    try sx.init();
    defer sx.deinit();
    try sx.put("src/deploy/SKILL.md", try deployMd(sx.a()));
    try sx.put("src/deploy/scripts/run.sh", "#!/bin/sh\n");
    {
        var f = try sx.e.tmp.dir.openFile(t.io, "src/deploy/scripts/run.sh", .{});
        defer f.close(t.io);
        try f.setPermissions(t.io, .fromMode(0o755));
    }
    try t.expectEqual(0, try sx.run(&.{ "add", sx.path("src/deploy"), "--yes" }));
    const st = try Io.Dir.cwd().statFile(t.io, try std.fs.path.join(sx.a(), &.{ sx.home, "skills", "deploy", "scripts", "run.sh" }), .{});
    try t.expect(st.permissions.toMode() & 0o100 != 0);
}

test "skill_commands_take_their_arguments" {
    for ([_][]const []const u8{ &.{"list"}, &.{ "show", "x" }, &.{ "rm", "x" }, &.{"update"}, &.{ "update", "x", "--force", "--yes" }, &.{ "add", "o/r", "--skill", "pdf", "--yes" } }) |w| try t.expect(parseArgs(w) != null);
    for ([_][]const []const u8{ &.{}, &.{"add"}, &.{ "show" }, &.{ "rm", "a", "b" }, &.{ "list", "x" }, &.{ "add", "o/r", "--skill" }, &.{ "add", "o/r", "--force" }, &.{ "update", "a", "b" } }) |w| try t.expect(parseArgs(w) == null);
}
