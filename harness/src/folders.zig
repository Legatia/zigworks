//! Roles on workspace folders (folders.ini): who may read, write and start
//! commands in each folder, the variables its commands get from stored
//! secrets, and which folders keep snapshots.
//!
//! A section is a workspace folder, written as file rules write paths
//! (`work/shop`), `[/]` for the whole workspace. `read`, `write` and `run`
//! list who may (who patterns, see who.zig, or `none`); a folder without
//! the key takes the nearest folder above that has it, and with none the
//! key does not limit. `vars = NAME:secret, ...` are variables for host
//! commands started in the folder or below; `snapshots = on|off|N`;
//! `skip = patterns` not kept in snapshots.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const who = @import("who.zig");
const mcp = @import("mcp.zig");

/// Volumes on macOS and Windows ignore case by default, so folders do too
/// there (as gate.zig's file rules do).
const fold = builtin.os.tag == .macos or builtin.os.tag == .windows;

pub const Access = enum { read, write, run };

/// A variable for commands started in a folder, from a stored secret.
pub const Var = struct {
    name: []const u8,
    secret: []const u8,
    /// The section it is set in, as written.
    section: []const u8 = "",
};

pub const Section = struct {
    /// The header as written (`work/shop`, `/`), for messages.
    name: []const u8,
    /// The folder inside the workspace, `/` between parts; "" for `[/]`.
    folder: []const u8,
    /// The header's line.
    line: usize,
    read: ?[]const []const u8 = null,
    write: ?[]const []const u8 = null,
    run: ?[]const []const u8 = null,
    vars: []const Var = &.{},
    /// Snapshots kept: null no key, 0 off, else that many.
    snapshots: ?u32 = null,
    skip: []const []const u8 = &.{},

    pub fn list(s: Section, access: Access) ?[]const []const u8 {
        return switch (access) {
            .read => s.read,
            .write => s.write,
            .run => s.run,
        };
    }
};

pub const Folders = struct {
    sections: []const Section = &.{},
};

/// What `snapshots = on` keeps, and what a folder keeps that sets nothing.
pub const default_keep = 50;
pub const max_keep = 10000;

pub const Error = error{
    /// A header that is not a folder inside the workspace, or a key before any.
    BadFolderName,
    DuplicateFolder,
    /// An unknown key, one given twice, or a line that is not `key = value`.
    BadFolderKey,
    BadWhoList,
    BadVar,
    /// PATH, HOME, LANG, TERM or one of Windows's system variables.
    ReservedVar,
    BadSnapshots,
    /// `snapshots` in a folder inside one that keeps them.
    NestedSnapshots,
    BadSkip,
    OutOfMemory,
};

/// What is wrong with a folders.ini line, said so the owner can fix it.
pub fn reason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.BadFolderName => "a section is a folder inside the workspace, written from it like work/shop, or / for all of it, with no *, .. or absolute path; keys come after one",
        error.DuplicateFolder => "this folder has a section already",
        error.BadFolderKey => "a section takes read, write, run, vars, snapshots and skip, each once, as key = value",
        error.BadWhoList => "read, write and run list who may, comma-separated: owner, schedule:NAME, trigger:NAME, workflow:NAME/STEP, app:NAME or agent:NAME (a kind alone covers all its names, and * works as in rules), or none alone",
        error.BadVar => "vars = NAME:secret, ...: a variable's name (letters, digits and _, not starting with a digit), each once, and a stored secret's name (a-z, 0-9, - and _)",
        error.ReservedVar => "PATH, HOME, LANG, TERM and Windows's system variables can't be set",
        error.BadSnapshots => "snapshots = on (keeps the newest 50), off, or how many to keep (1 to 10000)",
        error.NestedSnapshots => "a folder inside one that keeps snapshots can't set its own",
        error.BadSkip => "skip = patterns, comma-separated, like node_modules, *.log",
        else => null,
    };
}

/// Written by `harness init`: comments only, so nothing changes until the
/// owner writes a section.
pub const example =
    \\; Roles on workspace folders: who may read, write and start commands in
    \\; each folder and below it, the variables its commands get, and the
    \\; folders that keep snapshots. Without a section the rules alone decide.
    \\; A folder without a key takes the nearest folder above that has it.
    \\; Who: owner, schedule:NAME, agent:main, agent:helper (and trigger:NAME,
    \\; workflow:NAME/STEP, app:NAME once those exist), or none. A run you or
    \\; a schedule started passes if owner or its schedule is listed; else
    \\; its definition and those that delegated it must be. Changes apply
    \\; after /reload.
    \\;
    \\; [notes]
    \\; write = agent:main                 ; the agent itself, not its helpers
    \\;
    \\; [work/shop]
    \\; run = agent:main                   ; who may start commands here
    \\; vars = STRIPE_KEY:stripe-test      ; variable : stored secret, for commands started here
    \\; snapshots = on                     ; before and after runs that change it; the newest 50
    \\; skip = node_modules, *.log         ; not kept in snapshots
    \\;
    \\; [private]
    \\; read = owner
    \\
;

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Folders {
    var sections: std.ArrayList(Section) = .empty;
    const keys = [_][]const u8{ "read", "write", "run", "vars", "snapshots", "skip" };
    var seen: [keys.len]bool = @splat(false);
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, config.stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') return error.BadFolderName;
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            const folder = try folderOf(arena, name);
            for (sections.items) |s| if (eqlPath(s.folder, folder)) return error.DuplicateFolder;
            try sections.append(arena, .{ .name = name, .folder = folder, .line = n });
            seen = @splat(false);
            continue;
        }
        if (sections.items.len == 0) return error.BadFolderName;
        const s = &sections.items[sections.items.len - 1];
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadFolderKey;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const k = for (keys, 0..) |name, i| {
            if (std.mem.eql(u8, key, name)) break i;
        } else return error.BadFolderKey;
        if (seen[k]) return error.BadFolderKey;
        seen[k] = true;
        switch (k) {
            0 => s.read = try whoList(arena, value),
            1 => s.write = try whoList(arena, value),
            2 => s.run = try whoList(arena, value),
            3 => s.vars = try varList(arena, value, s.name),
            4 => {
                s.snapshots = try keepOf(value);
                try checkNesting(sections.items, sections.items.len - 1);
            },
            5 => s.skip = try listOf(arena, value, error.BadSkip),
            else => unreachable,
        }
    }
    return .{ .sections = sections.items };
}

/// A header's folder: "" for `/` (or `.`), else its parts joined by `/`.
fn folderOf(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, name, "/")) return "";
    if (name.len == 0 or name[0] == '/' or name[0] == '\\') return error.BadFolderName;
    // a drive (C:) is outside the workspace too
    if (name.len >= 2 and name[1] == ':') return error.BadFolderName;
    if (std.mem.indexOfScalar(u8, name, '*') != null) return error.BadFolderName;
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.tokenizeAny(u8, name, if (builtin.os.tag == .windows) "/\\" else "/");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.BadFolderName;
        for (part) |c| if (c < 0x20 or c == 0x7f) return error.BadFolderName;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    return out.items;
}

/// "a, b ,c" → {"a","b","c"}; an empty value or item is `err`.
fn listOf(arena: std.mem.Allocator, value: []const u8, comptime err: Error) Error![]const []const u8 {
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

fn whoList(arena: std.mem.Allocator, value: []const u8) Error![]const []const u8 {
    const items = try listOf(arena, value, error.BadWhoList);
    for (items) |item| {
        if (std.mem.eql(u8, item, "none")) {
            if (items.len != 1) return error.BadWhoList;
            continue;
        }
        if (!who.isPattern(item)) return error.BadWhoList;
    }
    return items;
}

/// Names a command's variables can't take: the four every command gets,
/// and Windows's own (on every platform, so a folders.ini reads the same
/// on all of them).
const reserved_vars = [_][]const u8{
    "PATH",               "HOME",                    "LANG",               "TERM",
    "SystemRoot",         "SystemDrive",             "windir",             "ComSpec",
    "PATHEXT",            "TEMP",                    "TMP",                "USERPROFILE",
    "HOMEDRIVE",          "HOMEPATH",                "APPDATA",            "LOCALAPPDATA",
    "ProgramData",        "ProgramFiles",            "ProgramFiles(x86)",  "ProgramW6432",
    "CommonProgramFiles", "CommonProgramFiles(x86)", "CommonProgramW6432", "USERNAME",
    "USERDOMAIN",         "COMPUTERNAME",            "OS",                 "PROCESSOR_ARCHITECTURE",
    "NUMBER_OF_PROCESSORS",
};

fn varList(arena: std.mem.Allocator, value: []const u8, section: []const u8) Error![]const Var {
    const items = try listOf(arena, value, error.BadVar);
    var out: std.ArrayList(Var) = .empty;
    for (items) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return error.BadVar;
        const name = std.mem.trim(u8, item[0..colon], " \t");
        const secret = std.mem.trim(u8, item[colon + 1 ..], " \t");
        if (!varName(name) or !mcp.validSecretName(secret)) return error.BadVar;
        for (reserved_vars) |r| if (std.ascii.eqlIgnoreCase(r, name)) return error.ReservedVar;
        for (out.items) |o| if (sameVar(o.name, name)) return error.BadVar;
        try out.append(arena, .{ .name = name, .secret = secret, .section = section });
    }
    return out.items;
}

fn varName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Windows's variable names ignore case.
fn sameVar(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn keepOf(value: []const u8) Error!u32 {
    if (std.ascii.eqlIgnoreCase(value, "on")) return default_keep;
    if (std.ascii.eqlIgnoreCase(value, "off")) return 0;
    const n = std.fmt.parseInt(u32, value, 10) catch return error.BadSnapshots;
    if (n == 0 or n > max_keep) return error.BadSnapshots;
    return n;
}

/// Section `i` just set `snapshots`: it may not if a folder around it keeps
/// them, and if it keeps them no folder inside it may have set its own.
fn checkNesting(sections: []const Section, i: usize) Error!void {
    const s = sections[i];
    for (sections, 0..) |o, j| {
        if (j == i) continue;
        const theirs = o.snapshots orelse continue;
        if (theirs > 0 and inFolder(s.folder, o.folder)) return error.NestedSnapshots;
        if (s.snapshots.? > 0 and inFolder(o.folder, s.folder)) return error.NestedSnapshots;
    }
}

/// Whether `rel` (a path inside the workspace, `/` between parts) is in
/// `folder` or is it: "" holds everything; `notes2/a` is not in `notes`.
pub fn inFolder(rel: []const u8, folder: []const u8) bool {
    if (folder.len == 0) return true;
    if (rel.len < folder.len or !eqlPath(rel[0..folder.len], folder)) return false;
    return rel.len == folder.len or rel[folder.len] == '/';
}

fn eqlPath(a: []const u8, b: []const u8) bool {
    return if (fold) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

const t = std.testing;

const spec_example =
    \\[/]
    \\write = agent:main, agent:coder
    \\
    \\[notes]
    \\write = owner, agent:researcher, app:notes
    \\
    \\[work/shop]
    \\read = agent:main, agent:coder
    \\write = agent:coder
    \\run = agent:coder
    \\vars = STRIPE_KEY:stripe-test, DATABASE_URL:shop-db
    \\snapshots = on
    \\skip = node_modules, *.log
    \\
    \\[private]
    \\read = owner
;

fn expectList(want: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedList;
    try t.expectEqual(want.len, g.len);
    for (want, g) |w, x| try t.expectEqualStrings(w, x);
}

test "folders_ini_reads_sections_lists_vars_snapshots_and_skip" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try parse(a, spec_example);
    try t.expectEqual(4, f.sections.len);
    const root = f.sections[0];
    try t.expectEqualStrings("/", root.name);
    try t.expectEqualStrings("", root.folder);
    try expectList(&.{ "agent:main", "agent:coder" }, root.write);
    try t.expectEqual(null, root.read);
    try expectList(&.{ "owner", "agent:researcher", "app:notes" }, f.sections[1].write);
    const shop = f.sections[2];
    try t.expectEqualStrings("work/shop", shop.folder);
    try expectList(&.{ "agent:main", "agent:coder" }, shop.read);
    try expectList(&.{"agent:coder"}, shop.write);
    try expectList(&.{"agent:coder"}, shop.run);
    try t.expectEqual(2, shop.vars.len);
    try t.expectEqualStrings("STRIPE_KEY", shop.vars[0].name);
    try t.expectEqualStrings("stripe-test", shop.vars[0].secret);
    try t.expectEqualStrings("work/shop", shop.vars[0].section);
    try t.expectEqualStrings("DATABASE_URL", shop.vars[1].name);
    try t.expectEqualStrings("shop-db", shop.vars[1].secret);
    try t.expectEqual(50, shop.snapshots.?);
    try expectList(&.{ "node_modules", "*.log" }, shop.skip);
    try expectList(&.{"owner"}, f.sections[3].read);
    // folders read like file paths
    const g = try parse(a, "[./notes/]\nread = owner ; a comment\n[notes//sub/.]\nsnapshots = 7\n[other]\nsnapshots = off\n");
    try t.expectEqualStrings("notes", g.sections[0].folder);
    try expectList(&.{"owner"}, g.sections[0].read);
    try t.expectEqualStrings("notes/sub", g.sections[1].folder);
    try t.expectEqual(7, g.sections[1].snapshots.?);
    try t.expectEqual(0, g.sections[2].snapshots.?);
    if (@import("builtin").os.tag == .windows) try t.expectEqualStrings("notes/sub", (try parse(a, "[notes\\sub]\nread = owner\n")).sections[0].folder);
    // what init writes has no section
    try t.expectEqual(0, (try parse(a, example)).sections.len);
}

test "folders_ini_refuses_bad_lines" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { err: anyerror, text: []const u8 }{
        .{ .err = error.BadFolderName, .text = "[*]\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "[notes/*]\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "[../x]\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "[a/../b]\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "[/etc]\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "[]\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "[notes\nread = owner\n" },
        .{ .err = error.BadFolderName, .text = "read = owner\n" },
        .{ .err = error.DuplicateFolder, .text = "[notes]\nread = owner\n[./notes]\nwrite = owner\n" },
        .{ .err = error.BadFolderKey, .text = "[notes]\ncolour = red\n" },
        .{ .err = error.BadFolderKey, .text = "[notes]\nread = owner\nread = agent:main\n" },
        .{ .err = error.BadFolderKey, .text = "[notes]\njust words\n" },
        .{ .err = error.BadWhoList, .text = "[notes]\nread = agnet:x\n" },
        .{ .err = error.BadWhoList, .text = "[notes]\nread = none, owner\n" },
        .{ .err = error.BadWhoList, .text = "[notes]\nread =\n" },
        .{ .err = error.BadWhoList, .text = "[notes]\nwrite = owner,\n" },
        .{ .err = error.BadVar, .text = "[notes]\nvars = X\n" },
        .{ .err = error.BadVar, .text = "[notes]\nvars = 1X:y\n" },
        .{ .err = error.BadVar, .text = "[notes]\nvars = X:Upper\n" },
        .{ .err = error.BadVar, .text = "[notes]\nvars = X:a/b\n" },
        .{ .err = error.BadVar, .text = "[notes]\nvars = X:a, X:b\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = PATH:x\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = path:x\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = HOME:x\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = LANG:x\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = TERM:x\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = SystemRoot:x\n" },
        .{ .err = error.ReservedVar, .text = "[notes]\nvars = temp:x\n" },
        .{ .err = error.BadSnapshots, .text = "[notes]\nsnapshots = maybe\n" },
        .{ .err = error.BadSnapshots, .text = "[notes]\nsnapshots = 0\n" },
        .{ .err = error.BadSnapshots, .text = "[notes]\nsnapshots = 10001\n" },
        .{ .err = error.NestedSnapshots, .text = "[work]\nsnapshots = on\n[work/shop]\nsnapshots = off\n" },
        .{ .err = error.NestedSnapshots, .text = "[work/shop]\nsnapshots = 3\n[work]\nsnapshots = on\n" },
        .{ .err = error.NestedSnapshots, .text = "[/]\nsnapshots = 3\n[x]\nsnapshots = on\n" },
        .{ .err = error.BadSkip, .text = "[notes]\nskip =\n" },
        .{ .err = error.BadSkip, .text = "[notes]\nskip = a,,b\n" },
    };
    for (cases) |c| {
        if (parse(a, c.text)) |_| {
            std.debug.print("accepted: {s}\n", .{c.text});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e != c.err) std.debug.print("{s}: {s}, not {s}\n", .{ c.text, @errorName(e), @errorName(c.err) });
            try t.expectEqual(c.err, e);
            try t.expect(reason(e) != null);
        }
    }
    // a folder twice in another case, where volumes ignore case
    const twice = parse(a, "[Notes]\nread = owner\n[notes]\nwrite = owner\n");
    if (fold) try t.expectError(error.DuplicateFolder, twice) else _ = try twice;
    // off in a folder outside the snapshotted one is fine
    _ = try parse(a, "[work]\nsnapshots = on\n[workshop]\nsnapshots = off\n");
}

test "in_folder_is_the_folder_or_below" {
    try t.expect(inFolder("notes/a", "notes"));
    try t.expect(inFolder("notes", "notes"));
    try t.expect(inFolder("x/y", ""));
    try t.expect(inFolder("", ""));
    try t.expect(!inFolder("notes2/a", "notes"));
    try t.expect(!inFolder("note", "notes"));
    try t.expect(!inFolder("", "notes"));
    try t.expectEqual(fold, inFolder("Notes/a", "notes"));
}
