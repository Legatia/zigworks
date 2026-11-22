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

/// Section i's folder: as the gate reads it (`real`, symbolic links
/// followed), else as written.
fn folderAt(f: Folders, real: ?[]const []const u8, i: usize) []const u8 {
    return if (real) |r| r[i] else f.sections[i].folder;
}

/// Whether `w` may `access` the path `rel` (inside the workspace, `/`
/// between parts): null if so, else why not, naming the section, the key
/// and who is not listed. The deepest section holding `rel` that has the
/// key decides; with none, the key does not limit. `real`: each section's
/// folder as the gate reads it, in the sections' order; null: as written.
pub fn allows(f: Folders, arena: std.mem.Allocator, real: ?[]const []const u8, rel: []const u8, access: Access, w: who.Who) ?[]const u8 {
    var best: ?usize = null;
    for (f.sections, 0..) |s, i| {
        if (s.list(access) == null) continue;
        const folder = folderAt(f, real, i);
        if (!inFolder(rel, folder)) continue;
        if (best == null or folder.len > folderAt(f, real, best.?).len) best = i;
    }
    const s = f.sections[best orelse return null];
    const list = s.list(access).?;
    if (list.len == 1 and std.mem.eql(u8, list[0], "none"))
        return std.fmt.allocPrint(arena, "folders.ini [{s}] {s}: none", .{ s.name, @tagName(access) }) catch "folders.ini: none may";
    const missing = notListed(list, w) orelse return null;
    return std.fmt.allocPrint(arena, "folders.ini [{s}] {s}: {s}{s} is not listed", .{ s.name, @tagName(access), missing.prefix, missing.name }) catch "folders.ini: not listed";
}

const Missing = struct { prefix: []const u8, name: []const u8 };

/// Who of `w` the list does not let through, or null when it does: a run
/// the owner or a schedule started passes when that origin is listed (then
/// any definition does); otherwise the definition, those that delegated
/// it and (for other origins) the origin must each be listed. A call with
/// no definition (`agent` "", an app's own) is its origin alone.
fn notListed(list: []const []const u8, w: who.Who) ?Missing {
    const kind = w.by[0 .. std.mem.indexOfScalar(u8, w.by, ':') orelse w.by.len];
    const own = std.mem.eql(u8, kind, "owner") or std.mem.eql(u8, kind, "schedule");
    if (own and originListed(list, w.by)) return null;
    if (w.agent.len > 0) {
        if (!agentListed(list, w.agent)) return .{ .prefix = "agent:", .name = w.agent };
        var p = w.parent;
        while (p) |x| : (p = x.parent) if (!agentListed(list, x.agent)) return .{ .prefix = "agent:", .name = x.agent };
    }
    if (!own and !originListed(list, w.by)) return .{ .prefix = "", .name = w.by };
    return null;
}

fn agentListed(list: []const []const u8, agent: []const u8) bool {
    for (list) |e| if (who.matchesAgent(e, agent)) return true;
    return false;
}

fn originListed(list: []const []const u8, by: []const u8) bool {
    for (list) |e| if (who.matchesBy(e, by)) return true;
    return false;
}

/// A folder of the workspace and what a who may do there, for a sandbox to
/// mount (gap 2): `write` reads and writes, `read` only reads, `none` not
/// at all.
pub const Mount = struct {
    folder: []const u8,
    access: enum { none, read, write },
};

/// What `w` may read and write: the workspace ("") and each section's
/// folder, outermost first, so that a sandbox mounting them in this order
/// lets a deeper one replace the one around it.
pub fn view(f: Folders, arena: std.mem.Allocator, w: who.Who) ![]const Mount {
    var folders: std.ArrayList([]const u8) = .empty;
    try folders.append(arena, "");
    for (f.sections) |s| if (s.folder.len > 0) try folders.append(arena, s.folder);
    std.mem.sort([]const u8, folders.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            const dx = std.mem.count(u8, x, "/") + @intFromBool(x.len > 0);
            const dy = std.mem.count(u8, y, "/") + @intFromBool(y.len > 0);
            return if (dx != dy) dx < dy else std.mem.lessThan(u8, x, y);
        }
    }.lt);
    const out = try arena.alloc(Mount, folders.items.len);
    for (folders.items, out) |folder, *m| {
        const reads = allows(f, arena, null, folder, .read, w) == null;
        const writes = allows(f, arena, null, folder, .write, w) == null;
        m.* = .{ .folder = folder, .access = if (reads and writes) .write else if (reads) .read else .none };
    }
    return out;
}

/// Whether a sandbox with this view sees `rel`: the deepest folder holding
/// it is mounted.
pub fn sees(mounts: []const Mount, rel: []const u8) bool {
    var best: ?Mount = null;
    for (mounts) |m| {
        if (!inFolder(rel, m.folder)) continue;
        if (best == null or m.folder.len >= best.?.folder.len) best = m;
    }
    const m = best orelse return false;
    return m.access != .none;
}

/// The variables a host command started in `dir` gets: those of every
/// section holding it, outermost first, a nearer one replacing a variable
/// of the same name.
pub fn varsFor(f: Folders, arena: std.mem.Allocator, real: ?[]const []const u8, dir: []const u8) ![]const Var {
    var holding: std.ArrayList(usize) = .empty;
    for (f.sections, 0..) |s, i| if (s.vars.len > 0 and inFolder(dir, folderAt(f, real, i))) try holding.append(arena, i);
    const Ctx = struct { f: Folders, real: ?[]const []const u8 };
    std.mem.sort(usize, holding.items, Ctx{ .f = f, .real = real }, struct {
        fn lt(c: Ctx, x: usize, y: usize) bool {
            return folderAt(c.f, c.real, x).len < folderAt(c.f, c.real, y).len;
        }
    }.lt);
    var out: std.ArrayList(Var) = .empty;
    for (holding.items) |i| for (f.sections[i].vars) |v| {
        for (out.items) |*o| {
            if (sameVar(o.name, v.name)) {
                o.* = v;
                break;
            }
        } else try out.append(arena, v);
    };
    return out.items;
}

/// folders.ini as `/folders` says it: a line a section, variables by name
/// and the secret they come from (never a value).
pub fn render(f: Folders, arena: std.mem.Allocator) ![]const u8 {
    if (f.sections.len == 0) return "No folders.ini sections: the rules alone decide where runs may read, write and start commands.";
    var out: std.ArrayList(u8) = .empty;
    for (f.sections) |s| {
        try out.print(arena, "[{s}]", .{s.name});
        var n: usize = 0;
        for ([_]Access{ .read, .write, .run }) |acc| if (s.list(acc)) |l| {
            try out.print(arena, "{s}{s} = ", .{ sep(n), @tagName(acc) });
            n += 1;
            for (l, 0..) |e, i| try out.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", e });
        };
        if (s.vars.len > 0) {
            try out.print(arena, "{s}vars = ", .{sep(n)});
            n += 1;
            for (s.vars, 0..) |v, i| try out.print(arena, "{s}{s} (from {s})", .{ if (i > 0) ", " else "", v.name, v.secret });
        }
        if (s.snapshots) |k| {
            if (k == 0) try out.print(arena, "{s}snapshots = off", .{sep(n)}) else try out.print(arena, "{s}snapshots = {d}", .{ sep(n), k });
            n += 1;
        }
        if (s.skip.len > 0) {
            try out.print(arena, "{s}skip = ", .{sep(n)});
            for (s.skip, 0..) |p, i| try out.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", p });
        }
        try out.append(arena, '\n');
    }
    return out.items;
}

fn sep(n: usize) []const u8 {
    return if (n == 0) " " else "; ";
}

/// What `w` may do in the workspace (`/`) and in each section's folder,
/// after `heading`: `FOLDER: read, write, run`, or `nothing`.
pub fn accessText(f: Folders, arena: std.mem.Allocator, real: ?[]const []const u8, w: who.Who, heading: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}\n", .{heading});
    var places: std.ArrayList([]const u8) = .empty;
    try places.append(arena, "");
    for (f.sections, 0..) |s, i| if (s.folder.len > 0) try places.append(arena, folderAt(f, real, i));
    for (places.items) |folder| {
        try out.print(arena, "{s}: ", .{if (folder.len == 0) "/" else folder});
        var n: usize = 0;
        for ([_]Access{ .read, .write, .run }) |acc| if (allows(f, arena, real, folder, acc, w) == null) {
            try out.print(arena, "{s}{s}", .{ if (n > 0) ", " else "", @tagName(acc) });
            n += 1;
        };
        try out.appendSlice(arena, if (n == 0) "nothing\n" else "\n");
    }
    return out.items;
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

/// What `allows` says of `rel` for `w` in the folders.ini `text`.
fn verdict(a: std.mem.Allocator, text: []const u8, rel: []const u8, access: Access, w: who.Who) !?[]const u8 {
    return allows(try parse(a, text), a, null, rel, access, w);
}

fn expectRefused(want: []const u8, got: ?[]const u8) !void {
    const g = got orelse {
        std.debug.print("allowed, not refused with: {s}\n", .{want});
        return error.TestExpectedRefusal;
    };
    try t.expectEqualStrings(want, g);
}

test "a_list_limits_only_its_access" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "[notes]\nwrite = agent:coder\n";
    const main: who.Who = .{};
    try t.expectEqual(null, try verdict(a, text, "notes/a", .read, main));
    try expectRefused("folders.ini [notes] write: agent:main is not listed", try verdict(a, text, "notes/a", .write, main));
    try t.expectEqual(null, try verdict(a, text, "notes", .run, main));
    try t.expectEqual(null, try verdict(a, text, "notes/a", .write, .{ .agent = "coder" }));
    try t.expectEqual(null, try verdict(a, text, "notes2/a", .write, main));
}

test "the_nearest_folder_with_the_key_wins" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "[/]\nwrite = agent:main\n[work]\nwrite = agent:coder\n[work/shop]\nread = owner, agent:main\n";
    const main: who.Who = .{};
    try t.expectEqual(null, try verdict(a, text, "notes/x", .write, main));
    try expectRefused("folders.ini [work] write: agent:main is not listed", try verdict(a, text, "work/shop/x", .write, main));
    try t.expectEqual(null, try verdict(a, text, "work/shop/x", .write, .{ .agent = "coder" }));
    try expectRefused("folders.ini [work/shop] read: trigger:mail is not listed", try verdict(a, text, "work/shop/x", .read, .{ .by = "trigger:mail" }));
}

test "none_refuses_every_run" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "[private]\nread = none\n";
    for ([_]who.Who{ .{}, .{ .agent = "coder" }, .{ .by = "schedule:x" }, .{ .agent = "", .by = "app:notes" } }) |w|
        try expectRefused("folders.ini [private] read: none", try verdict(a, text, "private/k", .read, w));
}

test "every_definition_in_the_chain_must_be_listed" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const main: who.Who = .{};
    const helper: who.Who = .{ .agent = "helper", .parent = &main };
    try expectRefused("folders.ini [notes] write: agent:main is not listed", try verdict(a, "[notes]\nwrite = agent:helper\n", "notes/a", .write, helper));
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = agent:helper, agent:main\n", "notes/a", .write, helper));
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = agent:*\n", "notes/a", .write, helper));
}

test "owner_listed_lets_its_runs_through" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const main: who.Who = .{};
    const helper: who.Who = .{ .agent = "helper", .parent = &main };
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = owner\n", "notes/a", .write, helper));
    try expectRefused("folders.ini [notes] write: agent:main is not listed", try verdict(a, "[notes]\nwrite = owner\n", "notes/a", .write, .{ .by = "schedule:x" }));
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = owner, schedule:*\n", "notes/a", .write, .{ .by = "schedule:x" }));
    try t.expectEqual(null, try verdict(a, "[notes]\nread = agent:*\n", "notes/a", .read, .{ .by = "schedule:x" }));
    try expectRefused("folders.ini [notes] read: trigger:mail is not listed", try verdict(a, "[notes]\nread = agent:*\n", "notes/a", .read, .{ .by = "trigger:mail" }));
}

test "trigger_workflow_and_app_origins_must_be_listed" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const trig: who.Who = .{ .by = "trigger:mail" };
    try expectRefused("folders.ini [notes] write: trigger:mail is not listed", try verdict(a, "[notes]\nwrite = agent:main\n", "notes/a", .write, trig));
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = agent:main, trigger:mail\n", "notes/a", .write, trig));
    const step: who.Who = .{ .by = "workflow:release/draft" };
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = agent:main, workflow:release\n", "notes/a", .write, step));
    try expectRefused("folders.ini [notes] write: workflow:release/draft is not listed", try verdict(a, "[notes]\nwrite = agent:main, workflow:other\n", "notes/a", .write, step));
    // an app's own call has no definition: the app alone must be listed
    const app: who.Who = .{ .agent = "", .by = "app:notes" };
    try t.expectEqual(null, try verdict(a, "[notes]\nwrite = app:notes\n", "notes/a", .write, app));
    try expectRefused("folders.ini [notes] write: app:notes is not listed", try verdict(a, "[notes]\nwrite = agent:main\n", "notes/a", .write, app));
}

test "a_view_lists_what_a_who_may_mount" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try parse(a, "[/]\nwrite = agent:main\n[private]\nread = owner\n[shared]\nwrite = trigger:mail, agent:main\n");
    const own = try view(f, a, .{});
    try t.expectEqual(3, own.len);
    try t.expectEqualStrings("", own[0].folder);
    try t.expectEqual(.write, own[0].access);
    try t.expectEqualStrings("private", own[1].folder);
    try t.expectEqual(.write, own[1].access);
    try t.expectEqualStrings("shared", own[2].folder);
    try t.expectEqual(.write, own[2].access);
    const trig = try view(f, a, .{ .by = "trigger:mail" });
    try t.expectEqual(.read, trig[0].access);
    try t.expectEqual(.none, trig[1].access);
    try t.expectEqual(.write, trig[2].access);
    try t.expect(sees(trig, "notes/a"));
    try t.expect(!sees(trig, "private/k"));
    try t.expect(sees(trig, "shared/x"));
    try t.expect(!sees(&.{}, "notes/a"));
}

test "vars_come_from_every_folder_down_to_the_start_folder" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try parse(a, "[/]\nvars = A:a-all, B:b-all\n[work]\nvars = B:b-work\n[work/shop]\nvars = C:c-shop\n");
    const deep = try varsFor(f, a, null, "work/shop/src");
    try t.expectEqual(3, deep.len);
    try t.expectEqualStrings("A", deep[0].name);
    try t.expectEqualStrings("a-all", deep[0].secret);
    try t.expectEqualStrings("B", deep[1].name);
    try t.expectEqualStrings("b-work", deep[1].secret);
    try t.expectEqualStrings("work", deep[1].section);
    try t.expectEqualStrings("C", deep[2].name);
    try t.expectEqualStrings("c-shop", deep[2].secret);
    for ([_][]const u8{ "notes", "" }) |dir| {
        const vs = try varsFor(f, a, null, dir);
        try t.expectEqual(2, vs.len);
        try t.expectEqualStrings("b-all", vs[1].secret);
    }
}
