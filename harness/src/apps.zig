//! Apps (gap 8): a folder of web files, `apps/NAME/` with `app.ini`, that
//! harness serves to the owner's browser (appserver.zig). This file reads
//! and checks the manifest and the folder, and keeps what was approved:
//! only an approved version is served, so a file changed outside harness
//! (by an approved shell command, or by hand) waits for `/app approve`.
//!
//! ```ini
//! [app]
//! name = reading-list      ; = its folder: a-z, 0-9, -, up to 32
//! title = Reading list
//! description = Links I saved, with notes.
//! version = 3              ; written by harness
//! reads = files            ; any of memory, inbox, log, files
//! files = reading/*        ; workspace paths it may read and act on
//! acts = write_file, fetch, run:main
//! to = main                ; where its questions and runs report
//! ```
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const config = @import("config.zig");
const conversations = @import("conversations.zig");
const rules = @import("rules.zig");
const util = @import("util.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Read = enum { memory, inbox, log, files };

pub const Manifest = struct {
    name: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    version: u32 = 1,
    forked_from: []const u8 = "",
    reads: []const Read = &.{},
    /// Workspace paths it may read and act on, as file rules write them.
    files: []const []const u8 = &.{},
    /// Tools, `SERVER/TOOL`, `run:DEFINITION`.
    acts: []const []const u8 = &.{},
    to: []const u8 = "main",

    pub fn hasRead(m: Manifest, r: Read) bool {
        return std.mem.indexOfScalar(Read, m.reads, r) != null;
    }
};

pub const max_name = 32;
pub const max_files = 200;
pub const max_total: u64 = 4 << 20;
pub const max_file: u64 = 1 << 20;

/// Names an app can't have: the built-ins and the shell's own paths.
pub const reserved = [_][]const u8{ "inbox", "log", "files", "api", "home", "review", "pending", "desk" };

/// The tools an app may list in `acts`: never money, the browser, logins,
/// helpers, memory writes, skills, questions of its own or setup calls.
const tool_acts = [_][]const u8{ "shell", "read_file", "write_file", "fetch", "browse", "search", "recall", "snapshot", "send" };

/// What an app's files may be.
pub const extensions = [_][]const u8{ "html", "js", "mjs", "css", "json", "svg", "png", "jpg", "gif", "webp", "ico", "woff2", "txt", "md" };

pub const Error = error{
    /// A section other than [app], or a key before it.
    BadAppSection,
    /// An unknown key, one given twice, or a line that is not `key = value`.
    BadAppKey,
    BadAppName,
    ReservedAppName,
    MissingAppName,
    BadAppText,
    BadAppVersion,
    BadAppReads,
    BadAppFiles,
    BadAppActs,
    BadAppTo,
    /// `hosts =`: an app reaches no other host.
    AppHostsRefused,
    OutOfMemory,
};

/// What is wrong with an app.ini line, said so the owner can fix it.
pub fn reason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.BadAppSection => "app.ini has one section, [app]",
        error.BadAppKey => "[app] takes name, title, description, version, forked_from, reads, files, acts and to, each once, as key = value",
        error.BadAppName => "name = the app's folder: a-z, 0-9 and -, up to 32",
        error.ReservedAppName => "inbox, log, files, api, home, review and pending are harness's own",
        error.MissingAppName => "[app] needs name =",
        error.BadAppText => "title and description are one line of text, up to 200 bytes",
        error.BadAppVersion => "version = a whole number from 1 (harness writes it)",
        error.BadAppReads => "reads = any of memory, inbox, log and files, comma-separated",
        error.BadAppFiles => "files = workspace paths as file rules write them (work/*), comma-separated, no .. or absolute path",
        error.BadAppActs => "acts = tools (shell, read_file, write_file, fetch, browse, search, recall, snapshot, send), SERVER/TOOL for an MCP tool, or run:DEFINITION; never money, web, logins, delegate, remember, skills or setup calls",
        error.BadAppTo => "to = a conversation's name (a-z, 0-9, - and _)",
        error.AppHostsRefused => "an app reaches no other host: copy a library into the app instead of naming its host",
        else => null,
    };
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Manifest {
    var m: Manifest = .{};
    var in_app = false;
    var seen: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, config.stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (in_app or !std.mem.eql(u8, line, "[app]")) return error.BadAppSection;
            in_app = true;
            continue;
        }
        if (!in_app) return error.BadAppSection;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadAppKey;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "hosts")) return error.AppHostsRefused;
        for (seen.items) |k| if (std.mem.eql(u8, k, key)) return error.BadAppKey;
        try seen.append(arena, key);
        const eql = std.mem.eql;
        if (eql(u8, key, "name")) {
            if (!validName(value)) return error.BadAppName;
            for (reserved) |r| if (eql(u8, r, value)) return error.ReservedAppName;
            m.name = value;
        } else if (eql(u8, key, "title")) {
            m.title = try text1(value);
        } else if (eql(u8, key, "description")) {
            m.description = try text1(value);
        } else if (eql(u8, key, "version")) {
            m.version = std.fmt.parseInt(u32, value, 10) catch return error.BadAppVersion;
            if (m.version == 0) return error.BadAppVersion;
        } else if (eql(u8, key, "forked_from")) {
            if (!validName(value)) return error.BadAppName;
            m.forked_from = value;
        } else if (eql(u8, key, "reads")) {
            var out: std.ArrayList(Read) = .empty;
            for (try list(arena, value, error.BadAppReads)) |item| {
                const r = std.meta.stringToEnum(Read, item) orelse return error.BadAppReads;
                if (std.mem.indexOfScalar(Read, out.items, r) != null) return error.BadAppReads;
                try out.append(arena, r);
            }
            m.reads = out.items;
        } else if (eql(u8, key, "files")) {
            const items = try list(arena, value, error.BadAppFiles);
            for (items) |p| if (!filePattern(p)) return error.BadAppFiles;
            m.files = items;
        } else if (eql(u8, key, "acts")) {
            const items = try list(arena, value, error.BadAppActs);
            for (items) |act| if (!validAct(act)) return error.BadAppActs;
            m.acts = items;
        } else if (eql(u8, key, "to")) {
            if (!conversations.validName(value)) return error.BadAppTo;
            m.to = value;
        } else return error.BadAppKey;
    }
    if (m.name.len == 0) return error.MissingAppName;
    return m;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

fn text1(v: []const u8) Error![]const u8 {
    if (v.len > 200) return error.BadAppText;
    for (v) |c| if (c < 0x20 or c == 0x7f) return error.BadAppText;
    return v;
}

fn list(arena: std.mem.Allocator, value: []const u8, comptime err: Error) Error![]const []const u8 {
    if (value.len == 0) return err;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) return err;
        try out.append(arena, item);
    }
    return out.items;
}

/// A workspace path as file rules write one: relative, `*` allowed, no
/// `..` part, no drive or leading slash.
fn filePattern(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[0] == '\\' or (p.len >= 2 and p[1] == ':')) return false;
    var parts = std.mem.tokenizeAny(u8, p, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    for (p) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validAct(act: []const u8) bool {
    for (tool_acts) |t_| if (std.mem.eql(u8, t_, act)) return true;
    if (std.mem.startsWith(u8, act, "run:")) {
        const d = act["run:".len..];
        if (d.len == 0 or d.len > 32) return false;
        for (d) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
        return true;
    }
    // an MCP tool: SERVER/TOOL
    const slash = std.mem.indexOfScalar(u8, act, '/') orelse return false;
    const server = act[0..slash];
    const tool = act[slash + 1 ..];
    if (server.len == 0 or tool.len == 0) return false;
    for (server) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    for (tool) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

// ---- the folder ----

/// Whether a file of an app may be named `rel` (parts split by `/`): parts
/// of A-Z a-z 0-9 . _ -, none starting with `.` or ending with `.`, no
/// Windows device name (con, nul, com1...) even with an extension, an
/// extension an app's files may have, and not in `data/`.
pub fn servableName(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > 512) return false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    var first = true;
    var last: []const u8 = "";
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or part[part.len - 1] == '.') return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
        if (deviceName(part)) return false;
        if (first and std.mem.eql(u8, part, "data")) return false;
        first = false;
        last = part;
    }
    const dot = std.mem.lastIndexOfScalar(u8, last, '.') orelse return false;
    const ext = last[dot + 1 ..];
    for (extensions) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

/// con, prn, aux, nul, com1-9, lpt1-9, with or without an extension (as
/// Windows reads them, `con.txt` is the console too).
fn deviceName(part: []const u8) bool {
    const base = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |d| if (std.ascii.eqlIgnoreCase(base, d)) return true;
    if (base.len == 4 and (std.ascii.startsWithIgnoreCase(base, "com") or std.ascii.startsWithIgnoreCase(base, "lpt")) and base[3] >= '1' and base[3] <= '9') return true;
    return false;
}

pub const File = struct { rel: []const u8, size: u64, sha: [64]u8 };

pub const Folder = struct {
    manifest: Manifest,
    files: []const File,
    total: u64,
    /// SHA-256 over app.ini and every file (path and content).
    digest: [64]u8,
};

pub const FolderError = error{
    NoManifest,
    BadManifest,
    /// app.ini's name isn't the folder's.
    NameNotFolder,
    NoIndex,
    BadFileName,
    SymbolicLink,
    TooManyFiles,
    TooBig,
    FileTooBig,
    /// Two names that differ only in case.
    CaseClash,
    OutOfMemory,
    Unexpected,
};

pub fn folderReason(e: anyerror) []const u8 {
    return switch (e) {
        error.NoManifest => "it has no app.ini",
        error.BadManifest => "its app.ini has an error",
        error.NameNotFolder => "app.ini's name is not the folder's",
        error.NoIndex => "it has no index.html",
        error.BadFileName => "a file's name or kind isn't one an app may have (parts of A-Z a-z 0-9 . _ -, html js mjs css json svg png jpg gif webp ico woff2 txt md)",
        error.SymbolicLink => "it holds a symbolic link",
        error.TooManyFiles => "it has more than 200 files",
        error.TooBig => "its files are over 4 MiB together",
        error.FileTooBig => "a file is over 1 MiB",
        error.CaseClash => "two of its files' names differ only in case",
        else => "it can't be read",
    };
}

/// Reads and checks the folder `dir` of app `name` (its `data/` left out).
pub fn checkFolder(io: Io, arena: std.mem.Allocator, dir: []const u8, name: []const u8) FolderError!Folder {
    const ini_path = std.fs.path.join(arena, &.{ dir, "app.ini" }) catch return error.OutOfMemory;
    const ini = Io.Dir.cwd().readFileAlloc(io, ini_path, arena, .limited(64 << 10)) catch return error.NoManifest;
    const m = parse(arena, ini) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadManifest;
    if (!std.mem.eql(u8, m.name, name)) return error.NameNotFolder;
    var files: std.ArrayList(File) = .empty;
    var total: u64 = 0;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return error.Unexpected;
    defer d.close(io);
    var walker = d.walk(arena) catch return error.OutOfMemory;
    defer walker.deinit();
    while (walker.next(io) catch return error.Unexpected) |e| {
        const rel = arena.dupe(u8, e.path) catch return error.OutOfMemory;
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, rel, '\\', '/');
        if (std.mem.eql(u8, rel, "data") or std.mem.startsWith(u8, rel, "data/")) continue;
        switch (e.kind) {
            .directory => continue,
            .sym_link => return error.SymbolicLink,
            .file => {},
            else => return error.BadFileName,
        }
        if (std.mem.eql(u8, rel, "app.ini")) continue;
        if (!servableName(rel)) return error.BadFileName;
        const content = e.dir.readFileAlloc(io, e.basename, arena, .limited(max_file + 1)) catch |err| return if (err == error.StreamTooLong) error.FileTooBig else error.Unexpected;
        if (content.len > max_file) return error.FileTooBig;
        total += content.len;
        if (total > max_total) return error.TooBig;
        if (files.items.len + 1 > max_files) return error.TooManyFiles;
        var h: [32]u8 = undefined;
        Sha256.hash(content, &h, .{});
        for (files.items) |f| if (std.ascii.eqlIgnoreCase(f.rel, rel)) return error.CaseClash;
        files.append(arena, .{ .rel = rel, .size = content.len, .sha = std.fmt.bytesToHex(h, .lower) }) catch return error.OutOfMemory;
    }
    const has_index = for (files.items) |f| {
        if (std.mem.eql(u8, f.rel, "index.html")) break true;
    } else false;
    if (!has_index) return error.NoIndex;
    std.mem.sort(File, files.items, {}, struct {
        fn lt(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.rel, y.rel);
        }
    }.lt);
    var all = Sha256.init(.{});
    all.update("app.ini\x00");
    all.update(ini);
    for (files.items) |f| {
        all.update("\x00");
        all.update(f.rel);
        all.update("\x00");
        all.update(&f.sha);
    }
    return .{ .manifest = m, .files = files.items, .total = total, .digest = std.fmt.bytesToHex(all.finalResult(), .lower) };
}

// ---- what was approved ----

pub const Approved = struct {
    version: u32,
    digest: [64]u8,
    when: i64,
    by: []const u8,
};

/// `state/apps/NAME/approved`, or null when the app has none.
pub fn readApproved(io: Io, arena: std.mem.Allocator, state_dir: []const u8, name: []const u8) !?Approved {
    const p = try std.fs.path.join(arena, &.{ state_dir, name, "approved" });
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4096)) catch return null;
    var a: Approved = .{ .version = 0, .digest = @splat('0'), .when = 0, .by = "" };
    var have_digest = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const k = line[0..sp];
        const v = line[sp + 1 ..];
        if (std.mem.eql(u8, k, "version")) a.version = std.fmt.parseInt(u32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "sha256") and v.len == 64) {
            @memcpy(&a.digest, v);
            have_digest = true;
        }
        if (std.mem.eql(u8, k, "when")) a.when = std.fmt.parseInt(i64, v, 10) catch 0;
        if (std.mem.eql(u8, k, "by")) a.by = v;
    }
    if (!have_digest or a.version == 0) return null;
    return a;
}

/// Approves app `name` as its files are now: a new version when they
/// changed since the last approval (app.ini's `version` line written to
/// match first). Returns the version.
pub fn approve(io: Io, arena: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8, by: []const u8, now_s: i64) !u32 {
    const dir = try std.fs.path.join(arena, &.{ apps_dir, name });
    var f = try checkFolder(io, arena, dir, name);
    const before = try readApproved(io, arena, state_dir, name);
    if (before) |b| if (std.mem.eql(u8, &b.digest, &f.digest)) return b.version;
    const version: u32 = if (before) |b| @max(b.version + 1, f.manifest.version) else f.manifest.version;
    if (version != f.manifest.version) {
        try setKey(io, arena, dir, "version", try std.fmt.allocPrint(arena, "{d}", .{version}));
        f = try checkFolder(io, arena, dir, name);
    }
    const sdir = try std.fs.path.join(arena, &.{ state_dir, name });
    try Io.Dir.cwd().createDirPath(io, sdir);
    const text = try std.fmt.allocPrint(arena, "version {d}\nsha256 {s}\nwhen {d}\nby {s}\n", .{ version, &f.digest, now_s, by });
    try util.writeReplace(io, try std.fs.path.join(arena, &.{ sdir, "approved" }), text);
    return version;
}

/// Whether app `name` is as approved now (its files unchanged since).
pub fn asApproved(io: Io, arena: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8) !?Approved {
    const a = (try readApproved(io, arena, state_dir, name)) orelse return null;
    const dir = try std.fs.path.join(arena, &.{ apps_dir, name });
    const f = checkFolder(io, arena, dir, name) catch return null;
    return if (std.mem.eql(u8, &f.digest, &a.digest)) a else null;
}

// ---- what an app may read and do ----

/// The built-in apps' manifests (their files are in the binary).
pub fn builtinManifest(name: []const u8) ?Manifest {
    const eql = std.mem.eql;
    if (eql(u8, name, "inbox")) return .{ .name = "inbox", .title = "Inbox", .description = "What waits for you, by kind and starter, with what was answered.", .reads = &.{.inbox} };
    if (eql(u8, name, "log")) return .{ .name = "log", .title = "Log", .description = "The runs in the action log and each one's steps.", .reads = &.{.log} };
    if (eql(u8, name, "files")) return .{ .name = "files", .title = "Files", .description = "The workspace: folders, text and images.", .reads = &.{.files}, .files = &.{"*"} };
    return null;
}

/// Whether workspace path `rel` (`/` between parts, "" the workspace
/// itself) is one the manifest's `files` names; a folder above a listed
/// path is, so it can be listed on the way there.
pub fn fileListed(m: Manifest, rel: []const u8) bool {
    for (m.files) |p| {
        if (rules.glob(p, rel)) return true;
        // `reading/*` also names `reading`
        if (std.mem.endsWith(u8, p, "/*") and std.mem.eql(u8, p[0 .. p.len - 2], rel)) return true;
    }
    return false;
}

/// Whether `rel` is a folder on the way to a listed path (`reading` for
/// `reading/notes/*`), or the workspace itself.
pub fn fileAbove(m: Manifest, rel: []const u8) bool {
    if (m.files.len == 0) return false;
    if (rel.len == 0) return true;
    for (m.files) |p| if (p.len > rel.len and std.mem.startsWith(u8, p, rel) and p[rel.len] == '/') return true;
    return false;
}

pub fn actListed(m: Manifest, act: []const u8) bool {
    for (m.acts) |x| if (std.mem.eql(u8, x, act)) return true;
    return false;
}

/// The manifest as app.ini's text.
pub fn iniText(a: std.mem.Allocator, m: Manifest) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "[app]\nname = {s}\n", .{m.name});
    if (m.title.len > 0) try out.print(a, "title = {s}\n", .{m.title});
    if (m.description.len > 0) try out.print(a, "description = {s}\n", .{m.description});
    try out.print(a, "version = {d}\n", .{m.version});
    if (m.forked_from.len > 0) try out.print(a, "forked_from = {s}\n", .{m.forked_from});
    if (m.reads.len > 0) {
        try out.appendSlice(a, "reads = ");
        for (m.reads, 0..) |r, i| try out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", @tagName(r) });
        try out.append(a, '\n');
    }
    if (m.files.len > 0) try out.print(a, "files = {s}\n", .{try std.mem.join(a, ", ", m.files)});
    if (m.acts.len > 0) try out.print(a, "acts = {s}\n", .{try std.mem.join(a, ", ", m.acts)});
    try out.print(a, "to = {s}\n", .{m.to});
    return out.items;
}

fn readsText(a: std.mem.Allocator, m: Manifest) ![]const u8 {
    if (m.reads.len == 0) return "nothing";
    var out: std.ArrayList(u8) = .empty;
    for (m.reads, 0..) |r, i| try out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", @tagName(r) });
    return out.items;
}

fn listText(a: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    return if (items.len == 0) "nothing" else std.mem.join(a, ", ", items);
}

// ---- an app's own data ----

pub const max_keys = 1000;
pub const max_value: usize = 256 << 10;

/// A data key: 1 to 64 of A-Z a-z 0-9 . _ -, not starting or ending with
/// `.`, no Windows device name.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64 or key[0] == '.' or key[key.len - 1] == '.') return false;
    for (key) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return !deviceName(key);
}

fn dataDir(a: std.mem.Allocator, apps_dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ apps_dir, name, "data" });
}

/// The app's keys, sorted.
pub fn dataKeys(io: Io, a: std.mem.Allocator, apps_dir: []const u8, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(io, try dataDir(a, apps_dir, name), .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !validKey(e.name)) continue;
        try out.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

pub fn dataGet(io: Io, a: std.mem.Allocator, apps_dir: []const u8, name: []const u8, key: []const u8) !?[]const u8 {
    if (!validKey(key)) return null;
    const p = try std.fs.path.join(a, &.{ try dataDir(a, apps_dir, name), key });
    const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return null;
    if (st.kind != .file) return null;
    return Io.Dir.cwd().readFileAlloc(io, p, a, .limited(max_value)) catch null;
}

pub const DataError = error{ BadKey, TooBig, TooManyKeys };

pub fn dataPut(io: Io, a: std.mem.Allocator, apps_dir: []const u8, name: []const u8, key: []const u8, value: []const u8) !void {
    if (!validKey(key)) return error.BadKey;
    if (value.len > max_value) return error.TooBig;
    const dir = try dataDir(a, apps_dir, name);
    const p = try std.fs.path.join(a, &.{ dir, key });
    const there = if (Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false })) |st| st.kind == .file else |_| false;
    if (!there and (try dataKeys(io, a, apps_dir, name)).len >= max_keys) return error.TooManyKeys;
    try Io.Dir.cwd().createDirPath(io, dir);
    try util.writeReplace(io, p, value);
}

pub fn dataDelete(io: Io, a: std.mem.Allocator, apps_dir: []const u8, name: []const u8, key: []const u8) !bool {
    if (!validKey(key)) return false;
    const p = try std.fs.path.join(a, &.{ try dataDir(a, apps_dir, name), key });
    Io.Dir.cwd().deleteFile(io, p) catch return false;
    return true;
}

// ---- saves being asked, installs, versions ----

/// Where an app's files come from: a folder, or the binary (a built-in).
pub const Source = union(enum) {
    dir: []const u8,
    mem: struct { ini: []const u8, files: []const [2][]const u8 },
};

/// An id for a save being asked: 16 hex.
pub fn validId(id: []const u8) bool {
    if (id.len != 16) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// Copies the app in `src` (app.ini and its files, never its data) into
/// the new folder `dest`.
fn copyApp(io: Io, a: std.mem.Allocator, src: Source, name: []const u8, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dest);
    switch (src) {
        .dir => |dir| {
            const f = try checkFolder(io, a, dir, name);
            const ini = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "app.ini" }), a, .limited(64 << 10));
            try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dest, "app.ini" }), .data = ini });
            for (f.files) |file| {
                const to = try std.fs.path.join(a, &.{ dest, file.rel });
                if (std.fs.path.dirname(to)) |d| try cwd.createDirPath(io, d);
                const data = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, file.rel }), a, .limited(max_file));
                try cwd.writeFile(io, .{ .sub_path = to, .data = data });
            }
        },
        .mem => |m| {
            try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dest, "app.ini" }), .data = m.ini });
            for (m.files) |file| {
                const to = try std.fs.path.join(a, &.{ dest, file[0] });
                if (std.fs.path.dirname(to)) |d| try cwd.createDirPath(io, d);
                try cwd.writeFile(io, .{ .sub_path = to, .data = file[1] });
            }
        },
    }
}

/// app.ini in `dir` with `key = value` (the line replaced, or added after
/// [app]); an empty `value` takes the line out.
fn setKey(io: Io, a: std.mem.Allocator, dir: []const u8, key: []const u8, value: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ dir, "app.ini" });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 10));
    var out: std.ArrayList(u8) = .empty;
    var done = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, config.stripComment(raw), " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        if (eq != null and std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), key)) {
            if (done or value.len == 0) continue;
            if (!first) try out.append(a, '\n');
            first = false;
            try out.print(a, "{s} = {s}", .{ key, value });
            done = true;
            continue;
        }
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, raw);
        if (!done and value.len > 0 and std.mem.eql(u8, line, "[app]")) {
            try out.print(a, "\n{s} = {s}", .{ key, value });
            done = true;
        }
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

pub const Change = enum { new, changed, same, removed };

pub const FileChange = struct { rel: []const u8, size: u64, sha: [64]u8, change: Change };

/// A save being asked: the folder as copied to `state/apps/pending/ID/`
/// (what is shown is what is installed), against the app as it is now.
pub const Staged = struct {
    id: []const u8,
    name: []const u8,
    version: u32,
    /// The approved version it replaces; null: a new app.
    was: ?u32,
    ini: []const u8,
    manifest: Manifest,
    /// The app as it is now; null: new, or its folder doesn't read.
    old: ?Manifest,
    files: []const FileChange,
    digest: [64]u8,
    /// HTML files with a script or handler written into the page, which
    /// an app's pages never run.
    inline_in: []const []const u8,
};

/// Checks the folder `from` as app `name`, copies it to
/// `state_dir/pending/ID/` with the version it would get, and says what
/// it changes.
pub fn stage(io: Io, a: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8, from: Source, id: []const u8) !Staged {
    if (!validName(name)) return error.BadManifest;
    for (reserved) |r| if (std.mem.eql(u8, r, name)) return error.BadManifest;
    if (!validId(id)) return error.Unexpected;
    const pending = try std.fs.path.join(a, &.{ state_dir, "pending", id });
    Io.Dir.cwd().deleteTree(io, pending) catch {};
    errdefer Io.Dir.cwd().deleteTree(io, pending) catch {};
    try copyApp(io, a, from, name, pending);
    const before = try readApproved(io, a, state_dir, name);
    const version: u32 = if (before) |b| b.version + 1 else 1;
    try setKey(io, a, pending, "version", try std.fmt.allocPrint(a, "{d}", .{version}));
    const f = try checkFolder(io, a, pending, name);
    const ini = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ pending, "app.ini" }), a, .limited(64 << 10));
    const now: ?Folder = checkFolder(io, a, try std.fs.path.join(a, &.{ apps_dir, name }), name) catch null;
    var files: std.ArrayList(FileChange) = .empty;
    var inline_in: std.ArrayList([]const u8) = .empty;
    for (f.files) |file| {
        var change: Change = .new;
        if (now) |o| for (o.files) |of| if (std.mem.eql(u8, of.rel, file.rel)) {
            change = if (std.mem.eql(u8, &of.sha, &file.sha)) .same else .changed;
        };
        try files.append(a, .{ .rel = file.rel, .size = file.size, .sha = file.sha, .change = change });
        if (std.ascii.endsWithIgnoreCase(file.rel, ".html")) {
            const html = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ pending, file.rel }), a, .limited(max_file));
            if (hasInline(html)) try inline_in.append(a, file.rel);
        }
    }
    if (now) |o| for (o.files) |of| {
        const kept = for (f.files) |file| {
            if (std.mem.eql(u8, of.rel, file.rel)) break true;
        } else false;
        if (!kept) try files.append(a, .{ .rel = of.rel, .size = of.size, .sha = of.sha, .change = .removed });
    };
    return .{
        .id = try a.dupe(u8, id),
        .name = try a.dupe(u8, name),
        .version = version,
        .was = if (before) |b| b.version else null,
        .ini = ini,
        .manifest = f.manifest,
        .old = if (now) |o| o.manifest else null,
        .files = files.items,
        .digest = f.digest,
        .inline_in = inline_in.items,
    };
}

/// Whether a page holds a script written into it (`<script>` without
/// `src`) or an `on...=` handler: an app's pages run neither.
pub fn hasInline(html: []const u8) bool {
    var i: usize = 0;
    while (std.ascii.findIgnoreCasePos(html, i, "<script")) |at| {
        const end = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return true;
        if (std.ascii.findIgnoreCase(html[at..end], "src") == null) return true;
        i = end;
    }
    // an attribute: space, on, letters, =, inside a tag
    i = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |at| {
        const end = std.mem.indexOfScalarPos(u8, html, at, '>') orelse html.len;
        const tag = html[at..end];
        var j: usize = 0;
        while (std.ascii.findIgnoreCasePos(tag, j, " on")) |k| {
            var e = k + 3;
            while (e < tag.len and std.ascii.isAlphabetic(tag[e])) e += 1;
            if (e > k + 3 and e < tag.len and tag[e] == '=') return true;
            j = k + 3;
        }
        i = end;
        if (end == html.len) break;
    }
    return false;
}

fn sizeText(a: std.mem.Allocator, n: u64) ![]const u8 {
    if (n < 1024) return std.fmt.allocPrint(a, "{d} B", .{n});
    if (n < 1024 * 1024) return std.fmt.allocPrint(a, "{d}.{d} KB", .{ n / 1024, (n % 1024) * 10 / 1024 });
    return std.fmt.allocPrint(a, "{d}.{d} MB", .{ n >> 20, (n % (1 << 20)) * 10 >> 20 });
}

/// What the owner is asked: the version, app.ini in full, what widens,
/// each file's size, SHA-256 and whether it is new, changed, the same or
/// removed (files that changed first; past `budget` bytes the rest are
/// counted, and are on the review page), and where the review page is.
pub fn describe(a: std.mem.Allocator, s: Staged, asked_by: []const u8, budget: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (s.was) |w| try out.print(a, "{s} v{d} (was v{d}), asked by {s}\n", .{ s.name, s.version, w, asked_by }) else try out.print(a, "{s} v{d} (a new app), asked by {s}\n", .{ s.name, s.version, asked_by });
    const old: Manifest = s.old orelse .{};
    const m = s.manifest;
    const was_reads = try readsText(a, old);
    const now_reads = try readsText(a, m);
    if (s.old == null) {
        try out.print(a, "It reads: {s}. Files: {s}. It may ask harness to: {s}.\n", .{ now_reads, try listText(a, m.files), try listText(a, m.acts) });
    } else {
        if (!std.mem.eql(u8, was_reads, now_reads)) try out.print(a, "Reads change: {s} (was {s}).\n", .{ now_reads, was_reads });
        const was_files = try listText(a, old.files);
        const now_files = try listText(a, m.files);
        if (!std.mem.eql(u8, was_files, now_files)) try out.print(a, "Files change: {s} (was {s}).\n", .{ now_files, was_files });
        const was_acts = try listText(a, old.acts);
        const now_acts = try listText(a, m.acts);
        if (!std.mem.eql(u8, was_acts, now_acts)) try out.print(a, "Acts change: {s} (was {s}).\n", .{ now_acts, was_acts });
    }
    try out.print(a, "app.ini:\n{s}\n", .{std.mem.trimEnd(u8, s.ini, "\r\n")});
    const tail = try std.fmt.allocPrint(a, "Every file in full: {{app-review:{s}}}", .{s.id});
    try out.appendSlice(a, "Files (size, SHA-256):\n");
    var left: usize = 0;
    for ([_]bool{ true, false }) |changed_pass| for (s.files) |f| {
        if ((f.change != .same) != changed_pass) continue;
        const line = try std.fmt.allocPrint(a, "{s}  {s}  {s}  {s}\n", .{ f.rel, try sizeText(a, f.size), &f.sha, @tagName(f.change) });
        if (out.items.len + line.len + tail.len + 64 > budget) {
            left += 1;
            continue;
        }
        try out.appendSlice(a, line);
    };
    if (left > 0) try out.print(a, "and {d} more file{s}, on the review page\n", .{ left, if (left == 1) "" else "s" });
    try out.appendSlice(a, tail);
    return out.items;
}

/// Installs the save `id` as app `name`: `approved` is written first,
/// then the app's folder goes to `versions/` and the copy takes its place
/// (its data moves with it). A crash between leaves one version whole;
/// `finishInstalls` at the next start ends it. Returns the version.
pub fn install(io: Io, a: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8, id: []const u8, by: []const u8, now_s: i64) !u32 {
    if (!validId(id)) return error.Unexpected;
    const pending = try std.fs.path.join(a, &.{ state_dir, "pending", id });
    const f = try checkFolder(io, a, pending, name);
    const sdir = try std.fs.path.join(a, &.{ state_dir, name });
    try Io.Dir.cwd().createDirPath(io, sdir);
    try util.writeReplace(io, try std.fs.path.join(a, &.{ sdir, "installing" }), id);
    const text = try std.fmt.allocPrint(a, "version {d}\nsha256 {s}\nwhen {d}\nby {s}\n", .{ f.manifest.version, &f.digest, now_s, by });
    try util.writeReplace(io, try std.fs.path.join(a, &.{ sdir, "approved" }), text);
    try finish(io, a, apps_dir, state_dir, name, id);
    return f.manifest.version;
}

pub const kept_versions = 10;

/// The swap of an install, from wherever it stopped.
fn finish(io: Io, a: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8, id: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const sdir = try std.fs.path.join(a, &.{ state_dir, name });
    const marker = try std.fs.path.join(a, &.{ sdir, "installing" });
    const pending = try std.fs.path.join(a, &.{ state_dir, "pending", id });
    if (exists(io, pending)) {
        const dir = try std.fs.path.join(a, &.{ apps_dir, name });
        if (exists(io, dir)) {
            // its data stays the app's
            const data = try std.fs.path.join(a, &.{ dir, "data" });
            const new_data = try std.fs.path.join(a, &.{ pending, "data" });
            if (exists(io, data) and !exists(io, new_data)) try cwd.rename(data, cwd, new_data, io);
            // the folder as it was: its version by its own app.ini
            const old_v: u32 = blk: {
                const ini = cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "app.ini" }), a, .limited(64 << 10)) catch break :blk 0;
                break :blk (parse(a, ini) catch break :blk 0).version;
            };
            const vdir = try std.fs.path.join(a, &.{ sdir, "versions" });
            try cwd.createDirPath(io, vdir);
            const to = try std.fmt.allocPrint(a, "{s}{c}{d}", .{ vdir, std.fs.path.sep, old_v });
            cwd.deleteTree(io, to) catch {};
            try cwd.rename(dir, cwd, to, io);
        }
        try cwd.createDirPath(io, apps_dir);
        try cwd.rename(pending, cwd, dir, io);
    }
    cwd.deleteFile(io, marker) catch {};
    // the last ten earlier versions
    const vs = try versions(io, a, state_dir, name);
    if (vs.len > kept_versions) for (vs[0 .. vs.len - kept_versions]) |v| {
        cwd.deleteTree(io, try std.fmt.allocPrint(a, "{s}{c}versions{c}{d}", .{ sdir, std.fs.path.sep, std.fs.path.sep, v })) catch {};
    };
}

/// At a start: ends installs a crash cut, and drops the saves that were
/// being asked (their questions are void).
pub fn finishInstalls(io: Io, a: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var d = cwd.openDir(io, state_dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory or !validName(e.name) or std.mem.eql(u8, e.name, "pending")) continue;
        const id = cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ state_dir, e.name, "installing" }), a, .limited(64)) catch continue;
        if (validId(id)) finish(io, a, apps_dir, state_dir, e.name, id) catch {};
    }
    cwd.deleteTree(io, try std.fs.path.join(a, &.{ state_dir, "pending" })) catch {};
}

/// Takes the save `id` away (denied, or never answered).
pub fn dropPending(io: Io, a: std.mem.Allocator, state_dir: []const u8, id: []const u8) void {
    if (!validId(id)) return;
    Io.Dir.cwd().deleteTree(io, std.fs.path.join(a, &.{ state_dir, "pending", id }) catch return) catch {};
}

/// The earlier versions kept of app `name`, oldest first.
pub fn versions(io: Io, a: std.mem.Allocator, state_dir: []const u8, name: []const u8) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var d = Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ state_dir, name, "versions" }), .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        try out.append(a, std.fmt.parseInt(u32, e.name, 10) catch continue);
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return out.items;
}

/// The files of earlier version `n` become a new version, installed.
pub fn revert(io: Io, a: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8, n: u32, id: []const u8, by: []const u8, now_s: i64) !u32 {
    const from = try std.fmt.allocPrint(a, "{s}{c}{s}{c}versions{c}{d}", .{ state_dir, std.fs.path.sep, name, std.fs.path.sep, std.fs.path.sep, n });
    if (!exists(io, from)) return error.NoSuchVersion;
    _ = try stage(io, a, apps_dir, state_dir, name, .{ .dir = from }, id);
    return install(io, a, apps_dir, state_dir, name, id, by, now_s);
}

/// A copy of app `src` (not its data) as the new app `new`: its name,
/// `forked_from` and version 1 written, approved as the owner's.
pub fn fork(io: Io, a: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, src: Source, src_name: []const u8, new: []const u8, id: []const u8, by: []const u8, now_s: i64) !void {
    if (!validName(new)) return error.BadAppName;
    for (reserved) |r| if (std.mem.eql(u8, r, new)) return error.ReservedAppName;
    if (exists(io, try std.fs.path.join(a, &.{ apps_dir, new }))) return error.AppExists;
    const tmp = try std.fs.path.join(a, &.{ state_dir, "pending", try std.fmt.allocPrint(a, "{s}.fork", .{id}) });
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try copyApp(io, a, src, src_name, tmp);
    try setKey(io, a, tmp, "name", new);
    try setKey(io, a, tmp, "forked_from", src_name);
    _ = try stage(io, a, apps_dir, state_dir, new, .{ .dir = tmp }, id);
    _ = try install(io, a, apps_dir, state_dir, new, id, by, now_s);
}

/// A copy of app `src` in the new folder `dest` for the agent to change:
/// app.ini's name is `as` (with `forked_from` when that is another name).
pub fn draft(io: Io, a: std.mem.Allocator, src: Source, src_name: []const u8, dest: []const u8, as: []const u8) !void {
    if (!validName(as)) return error.BadAppName;
    for (reserved) |r| if (std.mem.eql(u8, r, as)) return error.ReservedAppName;
    if (exists(io, dest)) return error.AppExists;
    errdefer Io.Dir.cwd().deleteTree(io, dest) catch {};
    try copyApp(io, a, src, src_name, dest);
    if (!std.mem.eql(u8, as, src_name)) {
        try setKey(io, a, dest, "name", as);
        try setKey(io, a, dest, "forked_from", src_name);
    }
}

// ---- tests ----

const t = std.testing;

test "app_ini_refuses_bad_manifests" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try parse(a,
        \\[app]
        \\name = reading-list
        \\title = Reading list
        \\description = Links I saved, with notes.
        \\version = 3
        \\reads = files, log
        \\files = reading/*
        \\acts = write_file, fetch, run:main, notes/add_note
        \\to = main
        \\
    );
    try t.expectEqualStrings("reading-list", good.name);
    try t.expectEqual(3, good.version);
    try t.expect(good.hasRead(.log) and !good.hasRead(.memory));
    try t.expectEqual(4, good.acts.len);
    const cases = [_]struct { []const u8, Error }{
        .{ "name = x\n", error.BadAppSection },
        .{ "[app]\nname = x\n[more]\n", error.BadAppSection },
        .{ "[apps]\nname = x\n", error.BadAppSection },
        .{ "[app]\ntitle = no name\n", error.MissingAppName },
        .{ "[app]\nname = Reading\n", error.BadAppName },
        .{ "[app]\nname = a_b\n", error.BadAppName },
        .{ "[app]\nname = inbox\n", error.ReservedAppName },
        .{ "[app]\nname = pending\n", error.ReservedAppName },
        .{ "[app]\nname = x\nname = y\n", error.BadAppKey },
        .{ "[app]\nname = x\ncolor = red\n", error.BadAppKey },
        .{ "[app]\nname = x\nhosts = cdn.example.com\n", error.AppHostsRefused },
        .{ "[app]\nname = x\nversion = 0\n", error.BadAppVersion },
        .{ "[app]\nname = x\nreads = secrets\n", error.BadAppReads },
        .{ "[app]\nname = x\nreads = log, log\n", error.BadAppReads },
        .{ "[app]\nname = x\nfiles = ../outside\n", error.BadAppFiles },
        .{ "[app]\nname = x\nfiles = /etc/*\n", error.BadAppFiles },
        .{ "[app]\nname = x\nacts = money\n", error.BadAppActs },
        .{ "[app]\nname = x\nacts = web\n", error.BadAppActs },
        .{ "[app]\nname = x\nacts = delegate\n", error.BadAppActs },
        .{ "[app]\nname = x\nacts = app_save\n", error.BadAppActs },
        .{ "[app]\nname = x\nacts = run:\n", error.BadAppActs },
        .{ "[app]\nname = x\nto = Main Chat\n", error.BadAppTo },
    };
    for (cases) |c| {
        if (parse(a, c[0])) |_| {
            std.debug.print("read but should not: {s}\n", .{c[0]});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e != c[1]) std.debug.print("{s}: {s}, not {s}\n", .{ c[0], @errorName(e), @errorName(c[1]) });
            try t.expectEqual(c[1], e);
            try t.expect(reason(e) != null);
        }
    }
}

test "app_paths_refuse_tricks" {
    for ([_][]const u8{ "index.html", "js/app.js", "img/a-b_c.png", "fonts/x.woff2", "README.md" }) |ok| {
        if (!servableName(ok)) std.debug.print("refused: {s}\n", .{ok});
        try t.expect(servableName(ok));
    }
    for ([_][]const u8{ "", "../x.html", "a/../b.html", ".hidden.html", "x.html.", "con.txt", "NUL.html", "com1.js", "lpt9.css", "a::$DATA", "a:b.html", "a\\b.html", "data/x.json", "x.exe", "noext", "sp ace.html", "%2e%2e/x.html", "a//b.html" }) |bad| {
        if (servableName(bad)) std.debug.print("allowed: {s}\n", .{bad});
        try t.expect(!servableName(bad));
    }
}

fn writeApp(dir: Io.Dir, name: []const u8, ini: []const u8, files: []const [2][]const u8) !void {
    var buf: [256]u8 = undefined;
    try dir.createDirPath(t.io, name);
    try dir.writeFile(t.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/app.ini", .{name}), .data = ini });
    for (files) |f| {
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, f[0] });
        if (std.fs.path.dirname(p)) |d| try dir.createDirPath(t.io, d);
        try dir.writeFile(t.io, .{ .sub_path = p, .data = f[1] });
    }
}

test "an_app_folder_is_checked_and_approved_versions_follow_its_files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "apps");
    try tmp.dir.createDirPath(t.io, "state");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const apps_dir = try std.fs.path.join(a, &.{ root, "apps" });
    const state_dir = try std.fs.path.join(a, &.{ root, "state" });
    var apps = try tmp.dir.openDir(t.io, "apps", .{});
    defer apps.close(t.io);
    try writeApp(apps, "notes", "[app]\nname = notes\ntitle = Notes\n", &.{ .{ "index.html", "<p>notes</p>" }, .{ "app.js", "1" }, .{ "data/k.json", "{}" } });
    const f = try checkFolder(t.io, a, try std.fs.path.join(a, &.{ apps_dir, "notes" }), "notes");
    // data/ is the app's own, not part of it
    try t.expectEqual(2, f.files.len);
    try t.expectEqual(null, try asApproved(t.io, a, apps_dir, state_dir, "notes"));
    try t.expectEqual(1, try approve(t.io, a, apps_dir, state_dir, "notes", "owner", 100));
    try t.expect(try asApproved(t.io, a, apps_dir, state_dir, "notes") != null);
    // approving again without a change keeps the version
    try t.expectEqual(1, try approve(t.io, a, apps_dir, state_dir, "notes", "owner", 101));
    // its data changes nothing
    try apps.writeFile(t.io, .{ .sub_path = "notes/data/k.json", .data = "{\"a\":1}" });
    try t.expect(try asApproved(t.io, a, apps_dir, state_dir, "notes") != null);
    // a file changed outside harness: not as approved until approved again
    try apps.writeFile(t.io, .{ .sub_path = "notes/app.js", .data = "2" });
    try t.expectEqual(null, try asApproved(t.io, a, apps_dir, state_dir, "notes"));
    try t.expectEqual(2, try approve(t.io, a, apps_dir, state_dir, "notes", "owner", 102));
    try t.expect(std.mem.indexOf(u8, try apps.readFileAlloc(t.io, "notes/app.ini", a, .limited(4096)), "version = 2") != null);
    try t.expect(try asApproved(t.io, a, apps_dir, state_dir, "notes") != null);
    // again, now that app.ini has its version line: one line, not two
    try apps.writeFile(t.io, .{ .sub_path = "notes/app.js", .data = "3" });
    try t.expectEqual(3, try approve(t.io, a, apps_dir, state_dir, "notes", "owner", 103));
    const ini3 = try apps.readFileAlloc(t.io, "notes/app.ini", a, .limited(4096));
    try t.expectEqual(1, std.mem.count(u8, ini3, "version"));
    try t.expect(std.mem.indexOf(u8, ini3, "version = 3") != null);
    // what the folder may not hold
    try writeApp(apps, "bad", "[app]\nname = bad\n", &.{.{ "index.html", "x" }});
    try apps.writeFile(t.io, .{ .sub_path = "bad/run.exe", .data = "MZ" });
    try t.expectError(error.BadFileName, checkFolder(t.io, a, try std.fs.path.join(a, &.{ apps_dir, "bad" }), "bad"));
    try writeApp(apps, "noindex", "[app]\nname = noindex\n", &.{.{ "main.html", "x" }});
    try t.expectError(error.NoIndex, checkFolder(t.io, a, try std.fs.path.join(a, &.{ apps_dir, "noindex" }), "noindex"));
    try writeApp(apps, "other", "[app]\nname = notother\n", &.{.{ "index.html", "x" }});
    try t.expectError(error.NameNotFolder, checkFolder(t.io, a, try std.fs.path.join(a, &.{ apps_dir, "other" }), "other"));
    const big: [max_file + 1]u8 = @splat('x');
    try writeApp(apps, "big", "[app]\nname = big\n", &.{ .{ "index.html", "x" }, .{ "big.txt", &big } });
    try t.expectError(error.FileTooBig, checkFolder(t.io, a, try std.fs.path.join(a, &.{ apps_dir, "big" }), "big"));
}

/// A tree of apps and state in a temporary folder.
const Tree = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    apps_dir: []const u8,
    state_dir: []const u8,
    root: []const u8,

    fn init(f: *Tree) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        f.a = f.arena.allocator();
        try f.tmp.dir.createDirPath(t.io, "apps");
        try f.tmp.dir.createDirPath(t.io, "state");
        try f.tmp.dir.createDirPath(t.io, "ws");
        f.root = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.a);
        f.apps_dir = try std.fs.path.join(f.a, &.{ f.root, "apps" });
        f.state_dir = try std.fs.path.join(f.a, &.{ f.root, "state" });
    }

    fn deinit(f: *Tree) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn draftDir(f: *Tree, name: []const u8) ![]const u8 {
        return std.fs.path.join(f.a, &.{ f.root, "ws", name });
    }

    fn read(f: *Tree, rel: []const u8) ![]const u8 {
        return f.tmp.dir.readFileAlloc(t.io, rel, f.a, .limited(1 << 20));
    }
};

test "app_save_installs_what_was_shown" {
    var f: Tree = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var ws = try f.tmp.dir.openDir(t.io, "ws", .{});
    defer ws.close(t.io);
    try writeApp(ws, "notes", "[app]\nname = notes\ntitle = Notes\nreads = files\nfiles = notes/*\n", &.{ .{ "index.html", "<p>one</p><script src=\"app.js\"></script>" }, .{ "app.js", "1" } });
    const id = "00000000000000a1";
    const s = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, id);
    try t.expectEqual(1, s.version);
    try t.expectEqual(null, s.was);
    try t.expectEqual(2, s.files.len);
    try t.expectEqual(.new, s.files[0].change);
    try t.expectEqual(0, s.inline_in.len);
    const text = try describe(a, s, "main", 12000);
    for ([_][]const u8{ "notes v1 (a new app), asked by main", "It reads: files. Files: notes/*. It may ask harness to: nothing.", "version = 1", "app.js  1 B  6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b  new", "{app-review:00000000000000a1}" }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
        try t.expect(std.mem.indexOf(u8, text, want) != null);
    }
    // the draft changes after the question: what was shown is installed
    try ws.writeFile(t.io, .{ .sub_path = "notes/app.js", .data = "evil()" });
    try t.expectEqual(1, try install(t.io, a, f.apps_dir, f.state_dir, "notes", id, "agent:main", 100));
    try t.expectEqualStrings("1", try f.read("apps/notes/app.js"));
    try t.expect(try asApproved(t.io, a, f.apps_dir, f.state_dir, "notes") != null);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/pending/00000000000000a1", .{}));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/notes/installing", .{}));
    // the app keeps data; a second save: v2, what changes named, data kept
    try dataPut(t.io, a, f.apps_dir, "notes", "k.json", "{\"a\":1}");
    try ws.writeFile(t.io, .{ .sub_path = "notes/app.ini", .data = "[app]\nname = notes\ntitle = Notes\nreads = files, log\nfiles = notes/*\nacts = write_file\n" });
    try ws.writeFile(t.io, .{ .sub_path = "notes/index.html", .data = "<p onclick=\"x()\">two</p><script>inline()</script>" });
    try ws.writeFile(t.io, .{ .sub_path = "notes/extra.css", .data = "p{}" });
    try ws.deleteFile(t.io, "notes/app.js");
    const id2 = "00000000000000a2";
    const s2 = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, id2);
    try t.expectEqual(2, s2.version);
    try t.expectEqual(1, s2.was.?);
    try t.expectEqual(1, s2.inline_in.len);
    const text2 = try describe(a, s2, "main", 12000);
    for ([_][]const u8{ "notes v2 (was v1)", "Reads change: files, log (was files).", "Acts change: write_file (was nothing).", "  new\n", "  changed\n", "  removed\n" }) |want| {
        if (std.mem.indexOf(u8, text2, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, text2 });
        try t.expect(std.mem.indexOf(u8, text2, want) != null);
    }
    try t.expect(std.mem.indexOf(u8, text2, "Files change") == null);
    try t.expectEqual(2, try install(t.io, a, f.apps_dir, f.state_dir, "notes", id2, "agent:main", 101));
    try t.expectEqualStrings("{\"a\":1}", (try dataGet(t.io, a, f.apps_dir, "notes", "k.json")).?);
    try t.expectEqualStrings("1", try f.read("state/notes/versions/1/app.js"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/notes/versions/1/data", .{}));
    // a denied save leaves nothing
    const id3 = "00000000000000a3";
    _ = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, id3);
    dropPending(t.io, a, f.state_dir, id3);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/pending/00000000000000a3", .{}));
    // a folder that doesn't check is not copied
    try ws.writeFile(t.io, .{ .sub_path = "notes/run.exe", .data = "MZ" });
    try t.expectError(error.BadFileName, stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, id3));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/pending/00000000000000a3", .{}));
    try t.expectError(error.BadManifest, stage(t.io, a, f.apps_dir, f.state_dir, "inbox", .{ .dir = try f.draftDir("notes") }, id3));
}

test "a_long_file_list_is_cut_to_the_question" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList(FileChange) = .empty;
    for (0..200) |i| try files.append(a, .{ .rel = try std.fmt.allocPrint(a, "img/picture-{d}.png", .{i}), .size = 2048, .sha = @splat('a'), .change = if (i == 150) .changed else .same });
    const s: Staged = .{ .id = "00000000000000a1", .name = "big", .version = 2, .was = 1, .ini = "[app]\nname = big\n", .manifest = .{ .name = "big" }, .old = .{ .name = "big" }, .files = files.items, .digest = @splat('0'), .inline_in = &.{} };
    const text = try describe(a, s, "main", 11000);
    try t.expect(text.len <= 11000);
    // the changed file first, the rest counted, the review page last
    const changed = std.mem.indexOf(u8, text, "img/picture-150.png").?;
    try t.expect(changed < std.mem.indexOf(u8, text, "img/picture-0.png").?);
    try t.expect(std.mem.indexOf(u8, text, " more files, on the review page\n") != null);
    try t.expect(std.mem.endsWith(u8, text, "{app-review:00000000000000a1}"));
}

test "an_install_cut_by_a_crash_ends_at_the_next_start" {
    var f: Tree = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var ws = try f.tmp.dir.openDir(t.io, "ws", .{});
    defer ws.close(t.io);
    try writeApp(ws, "notes", "[app]\nname = notes\n", &.{.{ "index.html", "one" }});
    _ = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, "00000000000000b1");
    _ = try install(t.io, a, f.apps_dir, f.state_dir, "notes", "00000000000000b1", "owner", 1);
    try ws.writeFile(t.io, .{ .sub_path = "notes/index.html", .data = "two" });
    const s = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, "00000000000000b2");
    // as install leaves it when it stops after `approved`, before the swap
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "state/notes/installing", .data = "00000000000000b2" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "state/notes/approved", .data = try std.fmt.allocPrint(a, "version 2\nsha256 {s}\nwhen 2\nby owner\n", .{&s.digest}) });
    // the old files are whole, and not served as the new version
    try t.expectEqual(null, try asApproved(t.io, a, f.apps_dir, f.state_dir, "notes"));
    try t.expectEqualStrings("one", try f.read("apps/notes/index.html"));
    // a save that was being asked, too: its question is void
    _ = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, "00000000000000b3");
    try finishInstalls(t.io, a, f.apps_dir, f.state_dir);
    try t.expectEqualStrings("two", try f.read("apps/notes/index.html"));
    try t.expect(try asApproved(t.io, a, f.apps_dir, f.state_dir, "notes") != null);
    try t.expectEqualStrings("one", try f.read("state/notes/versions/1/index.html"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/pending", .{}));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/notes/installing", .{}));
}

test "app_versions_fork_revert" {
    var f: Tree = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var ws = try f.tmp.dir.openDir(t.io, "ws", .{});
    defer ws.close(t.io);
    try writeApp(ws, "notes", "[app]\nname = notes\ntitle = Notes\n", &.{.{ "index.html", "v1" }});
    var buf: [16]u8 = undefined;
    // twelve versions: the last ten earlier ones are kept
    for (1..13) |i| {
        try ws.writeFile(t.io, .{ .sub_path = "notes/index.html", .data = try std.fmt.allocPrint(a, "v{d}", .{i}) });
        const id = try std.fmt.bufPrint(&buf, "{x:0>16}", .{i});
        _ = try stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try f.draftDir("notes") }, id);
        try t.expectEqual(@as(u32, @intCast(i)), try install(t.io, a, f.apps_dir, f.state_dir, "notes", id, "owner", 1));
    }
    try t.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, try versions(t.io, a, f.state_dir, "notes"));
    // revert: version 5's files as a new version, 12 kept as an earlier one
    try dataPut(t.io, a, f.apps_dir, "notes", "k", "kept");
    try t.expectEqual(13, try revert(t.io, a, f.apps_dir, f.state_dir, "notes", 5, "00000000000000c1", "owner", 2));
    try t.expectEqualStrings("v5", try f.read("apps/notes/index.html"));
    try t.expect(std.mem.indexOf(u8, try f.read("apps/notes/app.ini"), "version = 13") != null);
    try t.expectEqualStrings("kept", (try dataGet(t.io, a, f.apps_dir, "notes", "k")).?);
    try t.expectEqualStrings("v12", try f.read("state/notes/versions/12/index.html"));
    try t.expectError(error.NoSuchVersion, revert(t.io, a, f.apps_dir, f.state_dir, "notes", 1, "00000000000000c2", "owner", 2));
    // fork: a copy under its own name, not its data; from the binary too
    const notes_dir = try std.fs.path.join(a, &.{ f.apps_dir, "notes" });
    try fork(t.io, a, f.apps_dir, f.state_dir, .{ .dir = notes_dir }, "notes", "my-notes", "00000000000000c3", "owner", 3);
    const ini = try f.read("apps/my-notes/app.ini");
    for ([_][]const u8{ "name = my-notes", "forked_from = notes", "version = 1", "title = Notes" }) |want| try t.expect(std.mem.indexOf(u8, ini, want) != null);
    try t.expectEqualStrings("v5", try f.read("apps/my-notes/index.html"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "apps/my-notes/data", .{}));
    try t.expect(try asApproved(t.io, a, f.apps_dir, f.state_dir, "my-notes") != null);
    try t.expectError(error.AppExists, fork(t.io, a, f.apps_dir, f.state_dir, .{ .dir = notes_dir }, "notes", "my-notes", "00000000000000c4", "owner", 3));
    try t.expectError(error.ReservedAppName, fork(t.io, a, f.apps_dir, f.state_dir, .{ .dir = notes_dir }, "notes", "log", "00000000000000c4", "owner", 3));
    // the desk is harness's own page
    try t.expectError(error.ReservedAppName, fork(t.io, a, f.apps_dir, f.state_dir, .{ .dir = notes_dir }, "notes", "desk", "00000000000000c4", "owner", 3));
    const log_ini = try iniText(a, builtinManifest("log").?);
    try fork(t.io, a, f.apps_dir, f.state_dir, .{ .mem = .{ .ini = log_ini, .files = &.{ .{ "index.html", "<p>log</p>" }, .{ "app.js", "x" } } } }, "log", "my-log", "00000000000000c5", "owner", 4);
    const mine = try parse(a, try f.read("apps/my-log/app.ini"));
    try t.expectEqualStrings("log", mine.forked_from);
    try t.expect(mine.hasRead(.log));
    // a draft for the agent, in the workspace
    try draft(t.io, a, .{ .dir = notes_dir }, "notes", try f.draftDir("app-drafts/notes2"), "notes2");
    try t.expect(std.mem.indexOf(u8, try f.read("ws/app-drafts/notes2/app.ini"), "name = notes2") != null);
    try t.expectError(error.AppExists, draft(t.io, a, .{ .dir = notes_dir }, "notes", try f.draftDir("app-drafts/notes2"), "notes2"));
}

test "an_apps_data_is_its_own_keys" {
    var f: Tree = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    try t.expectEqual(null, try dataGet(t.io, a, f.apps_dir, "notes", "k"));
    try dataPut(t.io, a, f.apps_dir, "notes", "b.json", "2");
    try dataPut(t.io, a, f.apps_dir, "notes", "a.json", "1");
    try dataPut(t.io, a, f.apps_dir, "notes", "a.json", "one");
    try t.expectEqualStrings("one", (try dataGet(t.io, a, f.apps_dir, "notes", "a.json")).?);
    const keys = try dataKeys(t.io, a, f.apps_dir, "notes");
    try t.expectEqual(2, keys.len);
    try t.expectEqualStrings("a.json", keys[0]);
    const long: [65]u8 = @splat('k');
    for ([_][]const u8{ "", "../x", "a/b", ".hidden", "con", "nul.txt", "x.", "a b", &long }) |bad| {
        try t.expect(!validKey(bad));
        try t.expectError(error.BadKey, dataPut(t.io, a, f.apps_dir, "notes", bad, "x"));
        try t.expectEqual(null, try dataGet(t.io, a, f.apps_dir, "notes", bad));
    }
    const big = try a.alloc(u8, max_value + 1);
    @memset(big, 'x');
    try t.expectError(error.TooBig, dataPut(t.io, a, f.apps_dir, "notes", "big", big));
    try t.expect(try dataDelete(t.io, a, f.apps_dir, "notes", "a.json"));
    try t.expect(!try dataDelete(t.io, a, f.apps_dir, "notes", "a.json"));
    try t.expectEqual(1, (try dataKeys(t.io, a, f.apps_dir, "notes")).len);
}

test "an_apps_files_and_acts_follow_its_manifest" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "[app]\nname = x\nfiles = reading/*, notes/todo.md, deep/in/here/*\nacts = write_file, home/light_on, run:main\n");
    for ([_][]const u8{ "reading/a.md", "reading/sub/b.md", "reading", "notes/todo.md", "deep/in/here/x" }) |p| try t.expect(fileListed(m, p));
    for ([_][]const u8{ "notes/other.md", "readingx/a.md", "", "deep", "private/k" }) |p| try t.expect(!fileListed(m, p));
    for ([_][]const u8{ "", "deep", "deep/in" }) |p| try t.expect(fileAbove(m, p));
    for ([_][]const u8{ "de", "private", "notes/todo.md" }) |p| try t.expect(!fileAbove(m, p));
    try t.expect(actListed(m, "write_file") and actListed(m, "home/light_on") and actListed(m, "run:main"));
    try t.expect(!actListed(m, "shell") and !actListed(m, "run:other"));
    try t.expect(hasInline("<p>x</p><script>go()</script>"));
    try t.expect(hasInline("<button onclick=\"go()\">x</button>"));
    try t.expect(hasInline("<BODY ONLOAD='x'>"));
    try t.expect(!hasInline("<p>turn it on</p><script src=\"app.js\"></script>"));
    try t.expect(!hasInline("<p class=\"x\" data-on=\"1\">only text: onclick=</p>"));
}
