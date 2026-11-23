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
pub const reserved = [_][]const u8{ "inbox", "log", "files", "api", "home", "review", "pending" };

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
        try writeVersion(io, arena, dir, version);
        f = try checkFolder(io, arena, dir, name);
    }
    const sdir = try std.fs.path.join(arena, &.{ state_dir, name });
    try Io.Dir.cwd().createDirPath(io, sdir);
    const text = try std.fmt.allocPrint(arena, "version {d}\nsha256 {s}\nwhen {d}\nby {s}\n", .{ version, &f.digest, now_s, by });
    try util.writeReplace(io, try std.fs.path.join(arena, &.{ sdir, "approved" }), text);
    return version;
}

/// app.ini with its `version` line saying `version` (added after [app]
/// when it has none).
fn writeVersion(io: Io, arena: std.mem.Allocator, dir: []const u8, version: u32) !void {
    const path = try std.fs.path.join(arena, &.{ dir, "app.ini" });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10));
    var out: std.ArrayList(u8) = .empty;
    var done = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const line = std.mem.trim(u8, config.stripComment(raw), " \t\r");
        if (!done and std.mem.startsWith(u8, line, "version") and std.mem.indexOfScalar(u8, line, '=') != null) {
            try out.print(arena, "version = {d}", .{version});
            done = true;
            continue;
        }
        try out.appendSlice(arena, raw);
        if (!done and std.mem.eql(u8, line, "[app]")) {
            try out.print(arena, "\nversion = {d}", .{version});
            done = true;
        }
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Whether app `name` is as approved now (its files unchanged since).
pub fn asApproved(io: Io, arena: std.mem.Allocator, apps_dir: []const u8, state_dir: []const u8, name: []const u8) !?Approved {
    const a = (try readApproved(io, arena, state_dir, name)) orelse return null;
    const dir = try std.fs.path.join(arena, &.{ apps_dir, name });
    const f = checkFolder(io, arena, dir, name) catch return null;
    return if (std.mem.eql(u8, &f.digest, &a.digest)) a else null;
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
