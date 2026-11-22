//! Where commands run (environments.ini): the host workspace (`host`, built
//! in), sandboxes on the owner's machine and remote machines over SSH, the
//! environment a run gets unless something names another (`[default]`) and
//! the pins that put runs started by some who in one always (`[use]`).
//!
//! ```ini
//! [default]
//! env = host
//! [box]
//! kind = sandbox
//! workspace = rw        ; rw | ro | none
//! network = off         ; off | on
//! read = /opt/tools     ; more folders it may read
//! [buildbox]
//! kind = remote
//! host = agent@10.0.0.5
//! port = 22
//! dir = /home/agent/work
//! [use]
//! app = box
//! schedule = box
//! ```
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const rules = @import("rules.zig");
const who = @import("who.zig");

pub const Kind = enum { sandbox, remote };

/// How a sandbox sees the workspace.
pub const Mode = enum { rw, ro, none };

pub const Env = struct {
    name: []const u8,
    /// The header's line.
    line: usize,
    kind: Kind,
    /// Sandbox: the workspace read-write, read-only or not at all.
    workspace: Mode = .rw,
    /// Sandbox: outside hosts reachable.
    network: bool = false,
    /// Sandbox: more folders it may read, as written (absolute, or `~/...`).
    read: []const []const u8 = &.{},
    /// Remote: `USER@HOST` or `HOST`.
    host: []const u8 = "",
    port: u16 = 22,
    /// Remote: where its commands start; "" its login folder.
    dir: []const u8 = "",
    /// Commands it runs at once.
    parallel: u8 = default_parallel,
};

/// A `[use]` line: runs whose `by` matches `who` run in `env`.
pub const Pin = struct {
    who: []const u8,
    env: []const u8,
    line: usize,
};

pub const Environments = struct {
    envs: []const Env = &.{},
    /// A run's environment when nothing names one.
    default: []const u8 = "host",
    pins: []const Pin = &.{},

    pub fn find(e: Environments, name: []const u8) ?*const Env {
        for (e.envs) |*x| if (std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    /// Whether `name` is an environment: `host` or a section.
    pub fn has(e: Environments, name: []const u8) bool {
        return std.mem.eql(u8, name, "host") or e.find(name) != null;
    }

    /// The pin for a run started by `by`, if one matches: one naming it
    /// beats one with a `*`, which beats a kind alone; among equals the
    /// first in the file.
    pub fn pinFor(e: Environments, by: []const u8) ?Pin {
        var best: ?Pin = null;
        var best_rank: u8 = 0;
        for (e.pins) |p| {
            if (!who.matchesBy(p.who, by)) continue;
            const rank: u8 = if (std.mem.indexOfScalar(u8, p.who, ':') == null) 1 else if (std.mem.indexOfScalar(u8, p.who, '*') != null) 2 else 3;
            if (rank > best_rank) {
                best = p;
                best_rank = rank;
            }
        }
        return best;
    }

    /// Where a run runs, the first that applies: a pin over its `by`, the
    /// environment a workflow step names, its definition's, the default.
    pub fn pick(e: Environments, by: []const u8, step: ?[]const u8, definition: ?[]const u8) []const u8 {
        if (e.pinFor(by)) |p| return p.env;
        if (step) |s| return s;
        if (definition) |d| return d;
        return e.default;
    }
};

pub const default_parallel = 2;
pub const max_parallel = 16;
pub const max_name = 32;

pub const Error = error{
    /// A header that is not [default], [use] or a name of a-z, 0-9, - and
    /// _ (up to 32), or a key before any header.
    BadEnvName,
    /// [host]: host is built in.
    HostIsBuiltIn,
    DuplicateEnv,
    /// An unknown key for the section, one given twice, or a line that is
    /// not `key = value`.
    BadEnvKey,
    /// A key before `kind`, in a section that names an environment.
    EnvKindFirst,
    BadEnvKind,
    BadWorkspaceMode,
    BadNetwork,
    BadReadList,
    BadParallel,
    BadRemoteHost,
    MissingRemoteHost,
    BadRemotePort,
    BadRemoteDir,
    /// A [use] line whose key is not a who pattern over what starts runs.
    BadPin,
    /// [default] or a pin naming no environment.
    UnknownEnv,
    OutOfMemory,
};

/// What is wrong with an environments.ini line, said so the owner can fix it.
pub fn reason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.BadEnvName => "a section is [default], [use] or an environment's name: a-z, 0-9, - and _, up to 32; keys come after one",
        error.HostIsBuiltIn => "host is built in: it is the workspace on this machine, as without environments.ini",
        error.DuplicateEnv => "this section is there already",
        error.BadEnvKey => "a sandbox takes kind, workspace, network, read and parallel; a remote kind, host, port, dir and parallel; [default] env; [use] WHO = NAME; each once, as key = value",
        error.EnvKindFirst => "an environment's first line is kind = sandbox or kind = remote",
        error.BadEnvKind => "kind = sandbox or kind = remote",
        error.BadWorkspaceMode => "workspace = rw, ro or none",
        error.BadNetwork => "network = off or on",
        error.BadReadList => "read = folders it may read, comma-separated, each absolute or starting with ~/",
        error.BadParallel => "parallel = how many commands it runs at once, 1 to 16",
        error.BadRemoteHost => "host = USER@HOST or HOST: letters, digits, . _ - and : (no spaces, not starting with -)",
        error.MissingRemoteHost => "a remote needs host = USER@HOST",
        error.BadRemotePort => "port = 1 to 65535",
        error.BadRemoteDir => "dir = an absolute folder on the remote machine, or one starting with ~/",
        error.BadPin => "a [use] line is WHO = NAME, WHO being what starts runs: owner, schedule, trigger, workflow or app, alone or as KIND:NAME (* works as in rules)",
        error.UnknownEnv => "no environment has that name: host, or a section of this file",
        else => null,
    };
}

/// Written by `harness init`: comments only, so nothing changes until the
/// owner writes a section.
pub const example =
    \\; Where commands run. Without a section every command runs in the
    \\; workspace on this machine (host), as before. A sandbox runs them on
    \\; this machine without the data folder, your home, your secrets or the
    \\; network unless allowed; a remote runs them on another machine over
    \\; SSH (harness env key NAME makes its own key). Changes apply after
    \\; /reload.
    \\;
    \\; [default]
    \\; env = host               ; a run's environment unless named below
    \\;
    \\; [box]
    \\; kind = sandbox
    \\; workspace = rw           ; rw | ro | none
    \\; network = off            ; off | on
    \\; read = /opt/tools        ; more folders it may read
    \\;
    \\; [buildbox]
    \\; kind = remote
    \\; host = agent@10.0.0.5    ; port = 22
    \\; dir = /home/agent/work   ; where its commands start
    \\;
    \\; [use]                    ; runs started by these always run there
    \\; schedule = box
    \\
;

const Section = union(enum) { none, default, use, env: usize };

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Environments {
    var envs: std.ArrayList(Env) = .empty;
    var pins: std.ArrayList(Pin) = .empty;
    var default: ?[]const u8 = null;
    var default_line: usize = 0;
    var seen_default = false;
    var seen_use = false;
    // keys of the section being read, each once
    var keys: std.ArrayList([]const u8) = .empty;
    var cur: Section = .none;
    // a header with nothing under it yet: an environment once its kind comes
    var pending: ?struct { name: []const u8, line: usize } = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, config.stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (cur == .env) try finish(envs.items[cur.env]);
            if (line.len < 2 or line[line.len - 1] != ']') return error.BadEnvName;
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            keys.clearRetainingCapacity();
            pending = null;
            if (std.mem.eql(u8, name, "default")) {
                if (seen_default) return error.DuplicateEnv;
                seen_default = true;
                cur = .default;
            } else if (std.mem.eql(u8, name, "use")) {
                if (seen_use) return error.DuplicateEnv;
                seen_use = true;
                cur = .use;
            } else {
                if (std.mem.eql(u8, name, "host")) return error.HostIsBuiltIn;
                // the names rules' `shell@ENV` and snapshots' `env:NAME` take
                if (!rules.envName(name)) return error.BadEnvName;
                for (envs.items) |x| if (std.mem.eql(u8, x.name, name)) return error.DuplicateEnv;
                pending = .{ .name = name, .line = n };
                cur = .none;
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadEnvKey;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return error.BadEnvKey;
        for (keys.items) |k| if (std.mem.eql(u8, k, key)) return error.BadEnvKey;
        try keys.append(arena, key);
        if (pending) |p| {
            // an environment's section: kind first
            if (!std.mem.eql(u8, key, "kind")) return error.EnvKindFirst;
            const kind = std.meta.stringToEnum(Kind, value) orelse return error.BadEnvKind;
            try envs.append(arena, .{ .name = p.name, .line = p.line, .kind = kind });
            cur = .{ .env = envs.items.len - 1 };
            pending = null;
            continue;
        }
        switch (cur) {
            .none => return error.BadEnvName,
            .default => {
                if (!std.mem.eql(u8, key, "env") or value.len == 0) return error.BadEnvKey;
                default = value;
                default_line = n;
            },
            .use => {
                if (!who.isPattern(key) or std.mem.startsWith(u8, key, "agent")) return error.BadPin;
                if (value.len == 0) return error.UnknownEnv;
                try pins.append(arena, .{ .who = key, .env = value, .line = n });
            },
            .env => |i| try setKey(arena, &envs.items[i], key, value),
        }
    }
    if (cur == .env) try finish(envs.items[cur.env]);
    const out: Environments = .{ .envs = envs.items, .default = default orelse "host", .pins = pins.items };
    // names point at environments, wherever in the file those are
    if (!out.has(out.default)) return error.UnknownEnv;
    for (out.pins) |p| if (!out.has(p.env)) return error.UnknownEnv;
    return out;
}

fn setKey(arena: std.mem.Allocator, e: *Env, key: []const u8, value: []const u8) Error!void {
    const eql = std.mem.eql;
    if (eql(u8, key, "parallel")) {
        const p = std.fmt.parseInt(u8, value, 10) catch return error.BadParallel;
        if (p == 0 or p > max_parallel) return error.BadParallel;
        e.parallel = p;
        return;
    }
    switch (e.kind) {
        .sandbox => if (eql(u8, key, "workspace")) {
            e.workspace = std.meta.stringToEnum(Mode, value) orelse return error.BadWorkspaceMode;
        } else if (eql(u8, key, "network")) {
            e.network = if (std.ascii.eqlIgnoreCase(value, "on")) true else if (std.ascii.eqlIgnoreCase(value, "off")) false else return error.BadNetwork;
        } else if (eql(u8, key, "read")) {
            e.read = try readList(arena, value);
        } else return error.BadEnvKey,
        .remote => if (eql(u8, key, "host")) {
            if (!validHost(value)) return error.BadRemoteHost;
            e.host = value;
        } else if (eql(u8, key, "port")) {
            const p = std.fmt.parseInt(u16, value, 10) catch return error.BadRemotePort;
            if (p == 0) return error.BadRemotePort;
            e.port = p;
        } else if (eql(u8, key, "dir")) {
            if (!validRemoteDir(value)) return error.BadRemoteDir;
            e.dir = value;
        } else return error.BadEnvKey,
    }
}

/// What a section must have once it ends.
fn finish(e: Env) Error!void {
    if (e.kind == .remote and e.host.len == 0) return error.MissingRemoteHost;
}

fn readList(arena: std.mem.Allocator, value: []const u8) Error![]const []const u8 {
    if (value.len == 0) return error.BadReadList;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (!absoluteOrHome(item)) return error.BadReadList;
        for (item) |c| if (c < 0x20 or c == 0x7f) return error.BadReadList;
        try out.append(arena, item);
    }
    return out.items;
}

/// `/x`, `~`, `~/x`; on Windows also `C:\x` and `C:/x`. No `..` part.
fn absoluteOrHome(p: []const u8) bool {
    if (p.len == 0) return false;
    const ok = p[0] == '/' or std.mem.eql(u8, p, "~") or std.mem.startsWith(u8, p, "~/") or
        (builtin.os.tag == .windows and (std.mem.startsWith(u8, p, "~\\") or
            (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/'))));
    if (!ok) return false;
    var parts = std.mem.tokenizeAny(u8, p, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// `USER@HOST` or `HOST`: never an option to ssh, never a space or quote.
fn validHost(v: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, v, '@');
    const user = if (at) |i| v[0..i] else "";
    const host = if (at) |i| v[i + 1 ..] else v;
    if (at != null and user.len == 0) return false;
    if (host.len == 0 or host.len > 253 or host[0] == '-' or (user.len > 0 and user[0] == '-')) return false;
    for (user) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    for (host) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-', ':' => {},
        else => return false,
    };
    return true;
}

/// A POSIX folder on the remote: `/x`, `~` or `~/x`, nothing a shell
/// would read as more than a path (it is quoted all the same).
fn validRemoteDir(v: []const u8) bool {
    if (!(v.len > 0 and (v[0] == '/' or std.mem.eql(u8, v, "~") or std.mem.startsWith(u8, v, "~/")))) return false;
    for (v) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

const t = std.testing;

test "environments_ini_reads_sandboxes_remotes_pins_and_the_default" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const text =
        \\[default]
        \\env = box   ; most runs in the sandbox
        \\[box]
        \\kind = sandbox
        \\workspace = ro
        \\network = on
        \\read = /opt/tools, ~/go
        \\[buildbox]
        \\kind = remote
        \\host = agent@10.0.0.5
        \\port = 2222
        \\dir = /home/agent/work
        \\parallel = 4
        \\[use]
        \\app = box
        \\app:notes = host
        \\schedule = buildbox
        \\
    ;
    const e = try parse(arena.allocator(), text);
    try t.expectEqualStrings("box", e.default);
    try t.expectEqual(2, e.envs.len);
    const box = e.find("box").?;
    try t.expectEqual(Kind.sandbox, box.kind);
    try t.expectEqual(Mode.ro, box.workspace);
    try t.expect(box.network);
    try t.expectEqual(2, box.read.len);
    try t.expectEqualStrings("~/go", box.read[1]);
    try t.expectEqual(default_parallel, box.parallel);
    try t.expectEqual(3, box.line);
    const bb = e.find("buildbox").?;
    try t.expectEqual(Kind.remote, bb.kind);
    try t.expectEqualStrings("agent@10.0.0.5", bb.host);
    try t.expectEqual(2222, bb.port);
    try t.expectEqualStrings("/home/agent/work", bb.dir);
    try t.expectEqual(4, bb.parallel);
    try t.expectEqual(3, e.pins.len);
    try t.expect(e.has("host"));
    try t.expect(!e.has("nobox"));
}

test "environments_ini_without_sections_is_the_host_alone" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", example, "; nothing\n\n" }) |text| {
        const e = try parse(arena.allocator(), text);
        try t.expectEqualStrings("host", e.default);
        try t.expectEqual(0, e.envs.len);
        try t.expectEqualStrings("host", e.pick("schedule:news", null, null));
    }
}

test "environments_ini_refuses_bad_sections" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const long_name: [max_name + 1]u8 = @splat('x');
    const cases = [_]struct { []const u8, Error }{
        .{ "kind = sandbox\n", error.BadEnvName },
        .{ "[Box]\nkind = sandbox\n", error.BadEnvName },
        .{ "[a b]\nkind = sandbox\n", error.BadEnvName },
        .{ "[" ++ long_name ++ "]\nkind = sandbox\n", error.BadEnvName },
        .{ "[box\nkind = sandbox\n", error.BadEnvName },
        .{ "[host]\nkind = sandbox\n", error.HostIsBuiltIn },
        .{ "[box]\nkind = sandbox\n[box]\nkind = remote\nhost = h\n", error.DuplicateEnv },
        .{ "[use]\n[use]\n", error.DuplicateEnv },
        .{ "[box]\nworkspace = rw\nkind = sandbox\n", error.EnvKindFirst },
        .{ "[box]\nkind = vm\n", error.BadEnvKind },
        .{ "[box]\nkind = host\n", error.BadEnvKind },
        .{ "[box]\nkind = sandbox\nkind = sandbox\n", error.BadEnvKey },
        .{ "[box]\nkind = sandbox\nhost = h\n", error.BadEnvKey },
        .{ "[box]\nkind = sandbox\nworkspace\n", error.BadEnvKey },
        .{ "[box]\nkind = sandbox\nworkspace = rwx\n", error.BadWorkspaceMode },
        .{ "[box]\nkind = sandbox\nnetwork = yes\n", error.BadNetwork },
        .{ "[box]\nkind = sandbox\nread = opt/tools\n", error.BadReadList },
        .{ "[box]\nkind = sandbox\nread = /opt/../etc\n", error.BadReadList },
        .{ "[box]\nkind = sandbox\nread = /opt, \n", error.BadReadList },
        .{ "[box]\nkind = sandbox\nparallel = 0\n", error.BadParallel },
        .{ "[box]\nkind = sandbox\nparallel = 17\n", error.BadParallel },
        .{ "[r]\nkind = remote\n", error.MissingRemoteHost },
        .{ "[r]\nkind = remote\ndir = /w\n[box]\nkind = sandbox\n", error.MissingRemoteHost },
        .{ "[r]\nkind = remote\nhost = -oProxyCommand=x\n", error.BadRemoteHost },
        .{ "[r]\nkind = remote\nhost = a b\n", error.BadRemoteHost },
        .{ "[r]\nkind = remote\nhost = @h\n", error.BadRemoteHost },
        .{ "[r]\nkind = remote\nhost = h\nport = 0\n", error.BadRemotePort },
        .{ "[r]\nkind = remote\nhost = h\nport = 70000\n", error.BadRemotePort },
        .{ "[r]\nkind = remote\nhost = h\ndir = work\n", error.BadRemoteDir },
        .{ "[r]\nkind = remote\nhost = h\nworkspace = ro\n", error.BadEnvKey },
        .{ "[default]\nenv = nobox\n", error.UnknownEnv },
        .{ "[default]\nhost = box\n", error.BadEnvKey },
        .{ "[use]\napp = nobox\n", error.UnknownEnv },
        .{ "[use]\nagent:main = host\n", error.BadPin },
        .{ "[use]\nrobot = host\n", error.BadPin },
        .{ "[use]\napp\n", error.BadEnvKey },
        .{ "[use]\napp = host\napp = host\n", error.BadEnvKey },
    };
    for (cases) |c| {
        if (parse(arena.allocator(), c[0])) |_| {
            std.debug.print("read but should not: {s}\n", .{c[0]});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e != c[1]) std.debug.print("{s}: {s}, not {s}\n", .{ c[0], @errorName(e), @errorName(c[1]) });
            try t.expectEqual(c[1], e);
            try t.expect(reason(e) != null);
        }
    }
    // a name used before its section is written is fine
    _ = try parse(arena.allocator(), "[default]\nenv = box\n[use]\napp = box\n[box]\nkind = sandbox\n");
    // a header with nothing under it yet, at the end, is not an error
    _ = try parse(arena.allocator(), "[box]\nkind = sandbox\n[next]\n");
}

test "a_pin_naming_the_run_beats_a_pattern_and_a_kind_alone" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(),
        \\[a]
        \\kind = sandbox
        \\[b]
        \\kind = sandbox
        \\[c]
        \\kind = sandbox
        \\[default]
        \\env = c
        \\[use]
        \\app = a
        \\app:no* = b
        \\app:notes = host
        \\schedule:n* = a
        \\schedule:*s = b
        \\
    );
    try t.expectEqualStrings("host", e.pick("app:notes", null, null));
    try t.expectEqualStrings("b", e.pick("app:novels", null, null));
    try t.expectEqualStrings("a", e.pick("app:shop", null, null));
    // among equals the first in the file
    try t.expectEqualStrings("a", e.pick("schedule:news", null, null));
    // unpinned: the step's, then the definition's, then the default
    try t.expectEqualStrings("b", e.pick("owner", "b", "a"));
    try t.expectEqualStrings("a", e.pick("owner", null, "a"));
    try t.expectEqualStrings("c", e.pick("trigger:mail", null, null));
    // a pin beats what the step and the definition name
    try t.expectEqualStrings("a", e.pick("app:shop", "b", "c"));
}
