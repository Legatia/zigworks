//! Where commands run (environments.ini): the host workspace (`host`, built
//! in), sandboxes on the owner's machine and remote machines over SSH, the
//! environment a run gets unless something names another (`[default]`) and
//! the pins that put runs started by some who in one always (`[use]`).
//!
//! One sandbox is built in, `sandbox` (workspace rw, no network): what runs
//! nobody watches run in unless something names another (`[default]
//! unattended`). An owner's own `[sandbox]` section replaces it.
//!
//! ```ini
//! [default]
//! env = host
//! unattended = sandbox
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

/// How a sandbox sees the workspace: read-write, read-only, not at all,
/// or each run its own copy of it (its changes come back to be applied or
/// dropped).
pub const Mode = enum { rw, ro, none, copy };

/// What happens to a copy's changes: the owner is asked, or they are
/// applied at once when the check passes (and asked otherwise).
pub const Apply = enum { ask, check };

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
    /// `workspace = copy`: a command run in the copy after the run, in the
    /// sandbox; "": none.
    check: []const u8 = "",
    apply: Apply = .ask,
    /// `workspace = copy`: the most the workspace may hold, in MiB; a
    /// larger one is not copied.
    copy_mb: u32 = default_copy_mb,
    /// Remote: `USER@HOST` or `HOST`.
    host: []const u8 = "",
    port: u16 = 22,
    /// Remote: where its commands start; "" its login folder.
    dir: []const u8 = "",
    /// Commands it runs at once.
    parallel: u8 = default_parallel,
    /// The section has apply or copy_mb (they go with `workspace = copy`).
    copy_keys: bool = false,
    /// The built-in `sandbox`, not a section of the file.
    built_in: bool = false,
};

/// The sandbox every install has: what unattended runs run in unless
/// environments.ini says otherwise.
pub const sandbox_name = "sandbox";
pub const built_in_sandbox: Env = .{ .name = sandbox_name, .line = 0, .kind = .sandbox, .workspace = .rw, .network = false, .built_in = true };
const built_in_list = [_]Env{built_in_sandbox};

/// A `[use]` line: runs whose `by` matches `who` run in `env`.
pub const Pin = struct {
    who: []const u8,
    env: []const u8,
    line: usize,
};

pub const Environments = struct {
    /// The file's sections, and the built-in sandbox last unless a
    /// section replaces it.
    envs: []const Env = &built_in_list,
    /// A run's environment when nothing names one.
    default: []const u8 = "host",
    /// The same for a run nobody watches (`who.unattended`).
    unattended: []const u8 = sandbox_name,
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
    /// environment a workflow step names, its definition's, the default
    /// (`[default] unattended` for a run nobody watches, a workflow's tool
    /// step too; `[default] env` for the rest).
    pub fn pick(e: Environments, by: []const u8, step: ?[]const u8, definition: ?[]const u8) []const u8 {
        if (e.pinFor(by)) |p| return p.env;
        if (step) |s| return s;
        if (definition) |d| return d;
        return if ((who.Who{ .by = by }).unattended()) e.unattended else e.default;
    }

    /// How many sections of the file are environments.
    pub fn own(e: Environments) usize {
        var n: usize = 0;
        for (e.envs) |x| {
            if (!x.built_in) n += 1;
        }
        return n;
    }
};

/// The kinds of run nobody watches that the owner pins by name.
const routine_kinds = [_][]const u8{ "schedule", "trigger", "workflow" };

/// What an install from before the sandbox default is told at its first
/// start after it, or null where nothing of it ran commands on this
/// machine unattended. It did when rules.ini allows `shell` in the shared
/// part or in a section of a schedule, a trigger or a workflow, or has a
/// `shell@host` rule, or a run nobody watches holds a grant for the host
/// (`grant_whos`: the whos of the shell grants there). Each kind found
/// gets the `[use]` line that keeps it on this machine, by its name where
/// the rules or the grants give one.
pub fn upgradeLine(arena: std.mem.Allocator, list: Environments, rule_list: []const rules.Rule, grant_whos: []const []const u8) !?[]const u8 {
    // the owner's file already says the host: nothing changes
    if (std.mem.eql(u8, list.unattended, "host")) return null;
    var found: [routine_kinds.len]bool = @splat(false);
    var names: [routine_kinds.len]std.ArrayList([]const u8) = @splat(.empty);
    var every = false;
    for (rule_list) |r| {
        if (!std.mem.eql(u8, r.tool, "shell") or r.action == .deny) continue;
        const on_host = if (r.env) |e| std.mem.eql(u8, e, "host") else false;
        // shell@box: never the host's
        if (r.env != null and !on_host) continue;
        if (r.section) |s| {
            if (r.action != .allow and !on_host) continue;
            if (!try noteRoutine(arena, s, &found, &names) and on_host) every = true;
        } else if (r.action == .allow or on_host) every = true;
    }
    for (grant_whos) |w| _ = try noteRoutine(arena, w, &found, &names);
    if (every) found = @splat(true);
    if (!found[0] and !found[1] and !found[2]) return null;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "Commands that routines run now run in a sandbox: no network, no home folder. To keep one on this machine, add its line under [use] in environments.ini and send /reload:");
    var n: usize = 0;
    for (routine_kinds, 0..) |kind, i| {
        if (!found[i]) continue;
        if (names[i].items.len == 0) {
            try out.print(arena, "{s} {s}:NAME = host", .{ if (n > 0) "," else "", kind });
            n += 1;
        } else for (names[i].items) |name| {
            try out.print(arena, "{s} {s}:{s} = host", .{ if (n > 0) "," else "", kind, name });
            n += 1;
        }
    }
    try out.appendSlice(arena, ". (unattended = host under [default] keeps them all there.)");
    if (list.find(sandbox_name)) |s| if (!s.built_in) try out.appendSlice(arena, " Your [sandbox] section is now what routines run in.");
    return out.items;
}

/// Notes `text` (a rules section's who pattern, or a grant's who) when it
/// is a routine's: its kind, and its name when it has one without a `*`
/// (a workflow step's is its workflow's). False for any other who.
fn noteRoutine(arena: std.mem.Allocator, text: []const u8, found: *[routine_kinds.len]bool, names: *[routine_kinds.len]std.ArrayList([]const u8)) !bool {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const kind = text[0 .. colon orelse text.len];
    const i = for (routine_kinds, 0..) |k, j| {
        if (std.mem.eql(u8, k, kind)) break j;
    } else return false;
    found[i] = true;
    var name = if (colon) |c| text[c + 1 ..] else return true;
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| name = name[0..slash];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '*') != null) return true;
    for (names[i].items) |x| if (std.mem.eql(u8, x, name)) return true;
    if (names[i].items.len < 6) try names[i].append(arena, name);
    return true;
}

test "the_upgrade_line_is_for_installs_whose_routines_ran_commands_on_the_host" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = try parse(a, "");
    // nothing allowed shell unattended: no line
    for ([_][]const u8{ "", "allow fetch https://example.com/*\n", "[owner]\nallow shell *\n", "[agent:coder]\nallow shell make\n", "allow shell@sandbox echo *\n", "deny shell *\n", "[member:anna]\nallow shell ls\n" }) |text|
        try t.expectEqual(null, try upgradeLine(a, none, try rules.parse(a, text), &.{}));
    // the shared part, or [all]: every kind, by NAME
    for ([_][]const u8{ "allow shell echo *\n", "[owner]\nallow fetch https://example.com/*\n[all]\nallow shell ls\n", "ask shell@host make\n", "[agent:coder]\nallow shell@host make\n" }) |text| {
        const line = (try upgradeLine(a, none, try rules.parse(a, text), &.{})).?;
        try t.expectEqualStrings("Commands that routines run now run in a sandbox: no network, no home folder. To keep one on this machine, add its line under [use] in environments.ini and send /reload: schedule:NAME = host, trigger:NAME = host, workflow:NAME = host. (unattended = host under [default] keeps them all there.)", line);
    }
    // a routine's own section: its kind alone, by its name where it has one
    const named = (try upgradeLine(a, none, try rules.parse(a, "[schedule:news]\nallow shell git pull\n[schedule:n*]\nallow shell ls\n[workflow:deploy/build]\nallow shell make\n"), &.{})).?;
    try t.expect(std.mem.indexOf(u8, named, "/reload: schedule:news = host, workflow:deploy = host. (") != null);
    try t.expect(std.mem.indexOf(u8, named, "trigger") == null);
    const kind_only = (try upgradeLine(a, none, try rules.parse(a, "[trigger]\nallow shell ls\n"), &.{})).?;
    try t.expect(std.mem.indexOf(u8, kind_only, "/reload: trigger:NAME = host. (") != null);
    // a grant for the host a routine holds; an owner's or any run's is none
    try t.expectEqual(null, try upgradeLine(a, none, &.{}, &.{ "", "owner", "agent:coder", "app:notes" }));
    const granted = (try upgradeLine(a, none, &.{}, &.{ "trigger:mail", "workflow:deploy/build", "trigger:mail" })).?;
    try t.expect(std.mem.indexOf(u8, granted, "/reload: trigger:mail = host, workflow:deploy = host. (") != null);
    // an owner's own [sandbox] section: said too
    const own_box = try parse(a, "[sandbox]\nkind = sandbox\nnetwork = on\n");
    const with_own = (try upgradeLine(a, own_box, try rules.parse(a, "allow shell ls\n"), &.{})).?;
    try t.expect(std.mem.endsWith(u8, with_own, " Your [sandbox] section is now what routines run in."));
    // the file already keeps them on the host: nothing changes, no line
    try t.expectEqual(null, try upgradeLine(a, try parse(a, "[default]\nunattended = host\n"), try rules.parse(a, "allow shell ls\n"), &.{}));
}

/// environments.ini's `text` with section `[name]` replaced by `section`
/// (a header and its lines, a comment line above them or not), or with it
/// added at the end; and the lines it replaced ("" when new). A comment
/// line right above the old header (who saved it) goes with it.
pub fn swapSection(arena: std.mem.Allocator, text: []const u8, name: []const u8, section: []const u8) !struct { text: []const u8, old: []const u8 } {
    var before: std.ArrayList(u8) = .empty;
    var old: std.ArrayList(u8) = .empty;
    var after: std.ArrayList(u8) = .empty;
    var state: enum { before, in, after } = .before;
    var held: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tl = std.mem.trim(u8, line, " \t");
        const header: ?[]const u8 = if (tl.len > 2 and tl[0] == '[' and tl[tl.len - 1] == ']') std.mem.trim(u8, tl[1 .. tl.len - 1], " \t") else null;
        switch (state) {
            .before => {
                if (header) |h| if (std.mem.eql(u8, h, name)) {
                    // the mark above it goes; any other held line stays
                    if (held) |x| if (!std.mem.startsWith(u8, std.mem.trim(u8, x, " \t"), "; saved by ")) try before.print(arena, "{s}\n", .{x});
                    held = null;
                    try old.print(arena, "{s}\n", .{tl});
                    state = .in;
                    continue;
                };
                if (held) |x| try before.print(arena, "{s}\n", .{x});
                held = line;
            },
            .in => {
                if (header != null) {
                    state = .after;
                    try after.print(arena, "{s}\n", .{line});
                } else if (tl.len > 0) try old.print(arena, "{s}\n", .{tl});
            },
            .after => try after.print(arena, "{s}\n", .{line}),
        }
    }
    if (held) |x| try before.print(arena, "{s}\n", .{x});
    var out: std.ArrayList(u8) = .empty;
    const head = std.mem.trimEnd(u8, before.items, " \t\r\n");
    try out.appendSlice(arena, head);
    if (head.len > 0) try out.appendSlice(arena, "\n\n");
    try out.print(arena, "{s}\n", .{std.mem.trim(u8, section, " \t\r\n")});
    const tail = std.mem.trim(u8, after.items, " \t\r\n");
    if (tail.len > 0) try out.print(arena, "\n{s}\n", .{tail});
    return .{ .text = out.items, .old = std.mem.trimEnd(u8, old.items, "\n") };
}

test "a_section_is_swapped_in_place_or_added_at_the_end" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = "; mine\n[default]\nenv = host\n\n; saved by agent:main 2026-11-23\n[box]\nkind = sandbox\nnetwork = on\n\n[use]\nschedule = box\n";
    const sw = try swapSection(a, file, "box", "; saved by agent:main 2026-11-24\n[box]\nkind = sandbox");
    try t.expectEqualStrings("; mine\n[default]\nenv = host\n\n; saved by agent:main 2026-11-24\n[box]\nkind = sandbox\n\n[use]\nschedule = box\n", sw.text);
    try t.expectEqualStrings("[box]\nkind = sandbox\nnetwork = on", sw.old);
    _ = try parse(a, sw.text);
    const added = try swapSection(a, file, "far", "[far]\nkind = remote\nhost = a@b");
    try t.expect(std.mem.endsWith(u8, added.text, "schedule = box\n\n[far]\nkind = remote\nhost = a@b\n"));
    try t.expectEqualStrings("", added.old);
    const first = try swapSection(a, "", "box", "[box]\nkind = sandbox");
    try t.expectEqualStrings("[box]\nkind = sandbox\n", first.text);
}

/// What an environment is, as a question and the shell tool say it:
/// "sandbox; workspace rw, no network", "remote agent@10.0.0.5".
pub fn describe(arena: std.mem.Allocator, e: Env) ![]const u8 {
    return switch (e.kind) {
        .sandbox => std.fmt.allocPrint(arena, "sandbox; {s}, {s}", .{
            switch (e.workspace) {
                .rw => "workspace rw",
                .ro => "workspace ro",
                .none => "no workspace",
                .copy => "a copy of the workspace",
            },
            if (e.network) "network" else "no network",
        }),
        .remote => std.fmt.allocPrint(arena, "remote {s}", .{e.host}),
    };
}

pub const default_parallel = 2;
pub const default_copy_mb = 2048;
pub const max_copy_mb = 1 << 20;
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
    BadCheck,
    BadApply,
    BadCopyMb,
    /// check, apply or copy_mb without `workspace = copy`.
    CopyKeyWithoutCopy,
    /// `apply = check` without a check.
    ApplyNeedsCheck,
    BadRemoteHost,
    MissingRemoteHost,
    BadRemotePort,
    BadRemoteDir,
    /// A [use] line whose key is not a who pattern over what starts runs.
    BadPin,
    /// [default] or a pin naming no environment.
    UnknownEnv,
    /// [sandbox] that is not `kind = sandbox`.
    SandboxIsASandbox,
    OutOfMemory,
};

/// What is wrong with an environments.ini line, said so the owner can fix it.
pub fn reason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.BadEnvName => "a section is [default], [use] or an environment's name: a-z, 0-9, - and _, up to 32; keys come after one",
        error.HostIsBuiltIn => "host is built in: it is the workspace on this machine, as without environments.ini",
        error.DuplicateEnv => "this section is there already",
        error.BadEnvKey => "a sandbox takes kind, workspace, network, read and parallel (and with workspace = copy: check, apply, copy_mb); a remote kind, host, port, dir and parallel; [default] env and unattended; [use] WHO = NAME; each once, as key = value",
        error.BadCheck => "check = a command to run in the copy after the run",
        error.BadApply => "apply = ask or check",
        error.BadCopyMb => "copy_mb = the most the workspace may hold, in MiB, 1 to 1048576",
        error.CopyKeyWithoutCopy => "check, apply and copy_mb go with workspace = copy",
        error.ApplyNeedsCheck => "apply = check needs a check = COMMAND",
        error.EnvKindFirst => "an environment's first line is kind = sandbox or kind = remote",
        error.BadEnvKind => "kind = sandbox or kind = remote",
        error.BadWorkspaceMode => "workspace = rw, ro, none or copy",
        error.BadNetwork => "network = off or on",
        error.BadReadList => "read = folders it may read, comma-separated, each absolute or starting with ~/",
        error.BadParallel => "parallel = how many commands it runs at once, 1 to 16",
        error.BadRemoteHost => "host = USER@HOST or HOST: letters, digits, . _ - and : (no spaces, not starting with -)",
        error.MissingRemoteHost => "a remote needs host = USER@HOST",
        error.BadRemotePort => "port = 1 to 65535",
        error.BadRemoteDir => "dir = an absolute folder on the remote machine, or one starting with ~/",
        error.BadPin => "a [use] line is WHO = NAME, WHO being what starts runs: owner, schedule, trigger, workflow or app, alone or as KIND:NAME (* works as in rules)",
        error.UnknownEnv => "no environment has that name: host, sandbox, or a section of this file",
        error.SandboxIsASandbox => "[sandbox] is what routines run in when nobody watches: it must be kind = sandbox (name a remote something else)",
        else => null,
    };
}

/// Written by `harness init`: comments only, so nothing changes until the
/// owner writes a section.
pub const example =
    \\; Where commands run. Without a section your own runs' commands run in
    \\; the workspace on this machine (host), and those of runs nobody watches
    \\; (schedules, triggers, workflows) in the built-in sandbox: the
    \\; workspace read-write, no network, no home folder. A sandbox runs
    \\; commands on this machine without the data folder, your home, your
    \\; secrets or the network unless allowed; a remote runs them on another
    \\; machine over SSH (harness env key NAME makes its own key). Changes
    \\; apply after /reload.
    \\;
    \\; [default]
    \\; env = host               ; a run's environment unless named below
    \\; unattended = sandbox     ; the same for runs nobody watches; host
    \\;                          ; puts them on this machine as before
    \\;
    \\; [sandbox]                ; your own in place of the built-in one
    \\; kind = sandbox
    \\; network = on
    \\;
    \\; [box]
    \\; kind = sandbox
    \\; workspace = rw           ; rw | ro | none | copy (each run works in
    \\;                          ; its own copy; you apply or drop its changes;
    \\;                          ; check = COMMAND, apply = ask | check, copy_mb)
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
    var unattended: ?[]const u8 = null;
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
            if (kind != .sandbox and std.mem.eql(u8, p.name, sandbox_name)) return error.SandboxIsASandbox;
            try envs.append(arena, .{ .name = p.name, .line = p.line, .kind = kind });
            cur = .{ .env = envs.items.len - 1 };
            pending = null;
            continue;
        }
        switch (cur) {
            .none => return error.BadEnvName,
            .default => {
                if (value.len == 0) return error.BadEnvKey;
                if (std.mem.eql(u8, key, "env")) {
                    default = value;
                } else if (std.mem.eql(u8, key, "unattended")) {
                    unattended = value;
                } else return error.BadEnvKey;
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
    // the built-in sandbox, unless a section of that name replaces it
    const replaced = for (envs.items) |x| {
        if (std.mem.eql(u8, x.name, sandbox_name)) break true;
    } else false;
    if (!replaced) try envs.append(arena, built_in_sandbox);
    const out: Environments = .{ .envs = envs.items, .default = default orelse "host", .unattended = unattended orelse sandbox_name, .pins = pins.items };
    // names point at environments, wherever in the file those are
    if (!out.has(out.default) or !out.has(out.unattended)) return error.UnknownEnv;
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
        } else if (eql(u8, key, "check")) {
            if (value.len == 0) return error.BadCheck;
            for (value) |c| if (c < 0x20 or c == 0x7f) return error.BadCheck;
            e.check = value;
        } else if (eql(u8, key, "apply")) {
            e.apply = std.meta.stringToEnum(Apply, value) orelse return error.BadApply;
            e.copy_keys = true;
        } else if (eql(u8, key, "copy_mb")) {
            const mb = std.fmt.parseInt(u32, value, 10) catch return error.BadCopyMb;
            if (mb == 0 or mb > max_copy_mb) return error.BadCopyMb;
            e.copy_mb = mb;
            e.copy_keys = true;
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
    if ((e.copy_keys or e.check.len > 0) and e.workspace != .copy) return error.CopyKeyWithoutCopy;
    if (e.apply == .check and e.check.len == 0) return error.ApplyNeedsCheck;
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
    // its two sections, and the built-in sandbox after them
    try t.expectEqual(3, e.envs.len);
    try t.expectEqual(2, e.own());
    try t.expect(e.envs[2].built_in);
    try t.expectEqualStrings("sandbox", e.unattended);
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

test "environments_ini_without_sections_is_the_host_and_the_built_in_sandbox" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", example, "; nothing\n\n" }) |text| {
        const e = try parse(arena.allocator(), text);
        try t.expectEqualStrings("host", e.default);
        try t.expectEqualStrings("sandbox", e.unattended);
        try t.expectEqual(1, e.envs.len);
        try t.expectEqual(0, e.own());
        const s = e.find("sandbox").?;
        try t.expect(s.built_in);
        try t.expectEqual(Kind.sandbox, s.kind);
        try t.expectEqual(Mode.rw, s.workspace);
        try t.expect(!s.network);
        try t.expectEqual(0, s.read.len);
    }
    // a list nothing was read into is the same
    const none: Environments = .{};
    try t.expectEqualStrings("sandbox", none.pick("schedule:news", null, null));
    try t.expectEqualStrings("host", none.pick("owner", null, null));
}

test "unattended_runs_default_to_the_sandbox_and_the_rest_to_the_host" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(), "");
    // nobody watches: a schedule's, a trigger's, a workflow's agent step
    // and its tool step (`workflow:NAME/STEP`), harness's own jobs
    for ([_][]const u8{ "schedule:news", "trigger:mail", "workflow:deploy", "workflow:deploy/build", "harness:away" }) |by|
        try t.expectEqualStrings("sandbox", e.pick(by, null, null));
    // someone can answer: the owner's, a member's, a room's, an app's
    for ([_][]const u8{ "owner", "member:anna", "room:kitchen", "app:notes" }) |by|
        try t.expectEqualStrings("host", e.pick(by, null, null));
    // a pin, a step or a definition wins, the host too
    const pinned = try parse(arena.allocator(), "[box]\nkind = sandbox\n[use]\nschedule:news = host\ntrigger = box\n");
    try t.expectEqualStrings("host", pinned.pick("schedule:news", "box", "box"));
    try t.expectEqualStrings("sandbox", pinned.pick("schedule:other", null, null));
    try t.expectEqualStrings("box", pinned.pick("trigger:mail", null, null));
    try t.expectEqualStrings("box", pinned.pick("workflow:deploy/build", "box", "host"));
    try t.expectEqualStrings("host", pinned.pick("workflow:deploy/build", null, "host"));
    // [default] unattended names another, the host too; env stays its own
    const opted = try parse(arena.allocator(), "[default]\nunattended = host\n");
    try t.expectEqualStrings("host", opted.pick("schedule:news", null, null));
    const both = try parse(arena.allocator(), "[default]\nenv = box\nunattended = far\n[box]\nkind = sandbox\n[far]\nkind = remote\nhost = h\n");
    try t.expectEqualStrings("far", both.pick("trigger:mail", null, null));
    try t.expectEqualStrings("box", both.pick("owner", null, null));
}

test "an_owners_sandbox_section_replaces_the_built_in_one" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(), "[sandbox]\nkind = sandbox\nnetwork = on\nworkspace = ro\n");
    try t.expectEqual(1, e.envs.len);
    try t.expectEqual(1, e.own());
    const s = e.find("sandbox").?;
    try t.expect(!s.built_in);
    try t.expect(s.network);
    try t.expectEqual(Mode.ro, s.workspace);
    try t.expectEqualStrings("sandbox", e.pick("schedule:news", null, null));
    // it must be a sandbox: the file is refused, with why
    try t.expectError(error.SandboxIsASandbox, parse(arena.allocator(), "[sandbox]\nkind = remote\nhost = h\n"));
    try t.expect(std.mem.indexOf(u8, reason(error.SandboxIsASandbox).?, "kind = sandbox") != null);
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
        .{ "[default]\nunattended = nobox\n", error.UnknownEnv },
        .{ "[default]\nunattended =\n", error.BadEnvKey },
        .{ "[default]\nunattended = host\nunattended = host\n", error.BadEnvKey },
        .{ "[sandbox]\nkind = remote\nhost = h\n", error.SandboxIsASandbox },
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
    try t.expectEqualStrings("c", e.pick("member:anna", null, null));
    // (a run nobody watches goes by [default] unattended)
    try t.expectEqualStrings("sandbox", e.pick("trigger:mail", null, null));
    // a pin beats what the step and the definition name
    try t.expectEqualStrings("a", e.pick("app:shop", "b", "c"));
}
