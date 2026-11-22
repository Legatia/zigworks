//! Sandboxes on the owner's machine (environments.ini `kind = sandbox`,
//! gap 2): a command gets the workspace (read-write, read-only or not at
//! all), a home of its own kept between commands and the system's
//! programs; never the data folder, the owner's home, a secret, or the
//! network unless switched on. What it starts ends with it, by a stop, the
//! time limit or its own end, as on the host.
//!
//! Linux: bubblewrap (namespaces, a PID namespace that ends with the
//! command). Windows: an AppContainer, with ACEs for its SID on the folders
//! it may use, in a job object. macOS: sandbox-exec, the Mac session's;
//! refused until it is here. A missing backend refuses the command; it
//! never runs on the host instead.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;
const environments = @import("environments.zig");
const tools = @import("tools.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

/// Where a sandbox's home is on Linux, inside.
pub const linux_home = "/home/agent";

pub const Request = struct {
    env: *const environments.Env,
    command: []const u8,
    /// The workspace's real path.
    workspace: []const u8,
    /// The environment's own folder (state/env/NAME), made if missing; the
    /// sandbox's home is `home` in it.
    dir: []const u8,
    /// Where the command starts: a real path in the workspace; "" the
    /// workspace, or the home when the sandbox doesn't see the workspace.
    cwd: []const u8 = "",
    /// PATH inside.
    path_var: []const u8,
    /// Windows: the system's own variables (util.system_var_names); the
    /// profile folders among them become folders in the home.
    system_vars: []const util.Var = &.{},
    /// The owner's home, for `read = ~/...`.
    owner_home: []const u8 = "",
    /// Windows: its AppContainer's name (profileName).
    profile: []const u8 = "",
    /// Tests: a job of the caller's, left open to look into afterwards.
    job: ?*proc.Job = null,
};

/// Tests: where bwrap is, instead of looking for it.
pub var bwrap_override: ?[]const u8 = null;

/// Why sandboxes can't run here; null when they can.
pub fn unavailable(io: Io, arena: std.mem.Allocator) !?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => if (try findBwrap(io, arena) == null) "install bubblewrap (the bwrap command) to use sandboxes" else null,
        .windows => null,
        .macos => "sandboxes on macOS (sandbox-exec) are not built yet",
        else => "sandboxes are not built for this system",
    };
}

/// The AppContainer name of environment `name` of the data folder
/// `data_home`: two data folders' environments of one name are two.
pub fn profileName(arena: std.mem.Allocator, data_home: []const u8, name: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data_home, &h, .{});
    return std.fmt.allocPrint(arena, "harness-{s}-{s}", .{ &std.fmt.bytesToHex(h[0..8].*, .lower), name });
}

/// Runs `req.command` in the sandbox under `tenv`'s limits (time, output,
/// masking, stop), the way the shell tool runs one on the host.
pub fn run(tenv: tools.Env, arena: std.mem.Allocator, req: Request) !tools.Output {
    std.debug.assert(req.env.kind == .sandbox);
    if (try unavailable(tenv.io, arena)) |why| return .{ .text = try std.fmt.allocPrint(arena, "not run: {s}", .{why}), .is_error = true };
    const home = try std.fs.path.join(arena, &.{ req.dir, "home" });
    try Io.Dir.cwd().createDirPath(tenv.io, home);
    var own_job = proc.Job.create();
    defer own_job.close();
    const job = req.job orelse &own_job;
    var child = switch (builtin.os.tag) {
        .linux => try spawnBwrap(tenv.io, arena, req, home),
        .windows => try spawnAppContainer(tenv.io, arena, req, home),
        else => unreachable,
    };
    // Windows: in the job before it runs (it was started suspended)
    job.adopt(&child);
    return tools.runChild(tenv, arena, &child, job);
}

/// Takes back what an environment was given: on Windows its ACEs and its
/// AppContainer profile; everywhere its folder (home and all).
pub fn remove(io: Io, arena: std.mem.Allocator, dir: []const u8, profile: []const u8) !void {
    if (is_windows and profile.len > 0) {
        if (containerSid(arena, profile)) |sid| {
            defer _ = win.FreeSid(sid);
            for (try readGrants(io, arena, dir)) |g| setAce(arena, g.path, sid, 0, win.REVOKE_ACCESS) catch {};
        } else |_| {}
        _ = win.DeleteAppContainerProfile(try std.unicode.utf8ToUtf16LeAllocZ(arena, profile));
    }
    try Io.Dir.cwd().deleteTree(io, dir);
}

/// `~` and `~/x` in the owner's home; anything else as written.
fn expandHome(arena: std.mem.Allocator, p: []const u8, owner_home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, p, "~")) return owner_home;
    if (std.mem.startsWith(u8, p, "~/") or std.mem.startsWith(u8, p, "~\\")) return std.fs.path.join(arena, &.{ owner_home, p[2..] });
    return p;
}

// ---- Linux: bubblewrap ----

fn findBwrap(io: Io, arena: std.mem.Allocator) !?[]const u8 {
    if (!is_linux) return null;
    const candidates: []const []const u8 = if (bwrap_override) |o| &.{o} else &.{ "/usr/bin/bwrap", "/usr/local/bin/bwrap", "/bin/bwrap" };
    for (candidates) |c| {
        const st = Io.Dir.cwd().statFile(io, c, .{}) catch continue;
        if (st.kind == .file) return try arena.dupe(u8, c);
    }
    return null;
}

fn spawnBwrap(io: Io, arena: std.mem.Allocator, req: Request, home: []const u8) !std.process.Child {
    const bwrap = (try findBwrap(io, arena)).?;
    const argv = try bwrapArgv(io, arena, req, bwrap, home);
    var vars = std.process.Environ.Map.init(arena);
    try vars.put("PATH", req.path_var);
    try vars.put("HOME", linux_home);
    try vars.put("LANG", "C.UTF-8");
    try vars.put("TERM", "dumb");
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = "/" },
        .environ_map = &vars,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // its own group: a stop kills bwrap, and with it (--die-with-parent)
        // the PID namespace and all that runs in it, sessions of its own too
        .pgid = 0,
    });
}

/// bwrap's arguments: nothing of the host but the system's folders (read
/// only), the workspace as its mode says, the home and `read =` folders.
pub fn bwrapArgv(io: Io, arena: std.mem.Allocator, req: Request, bwrap: []const u8, home: []const u8) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(arena, &.{ bwrap, "--unshare-all", "--die-with-parent", "--new-session" });
    if (req.env.network) try a.append(arena, "--share-net");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc" }) |p| {
        // a link (/bin -> usr/bin) stays a link
        if (Io.Dir.cwd().readLink(io, p, &buf)) |n| {
            try a.appendSlice(arena, &.{ "--symlink", try arena.dupe(u8, buf[0..n]), p });
        } else |_| {
            const st = Io.Dir.cwd().statFile(io, p, .{}) catch continue;
            if (st.kind == .directory) try a.appendSlice(arena, &.{ "--ro-bind", p, p });
        }
    }
    if (req.env.network) {
        // /etc/resolv.conf often points elsewhere (/run/systemd/resolve,
        // /mnt/wsl): without its target no name resolves
        if (Io.Dir.cwd().readLink(io, "/etc/resolv.conf", &buf)) |n| {
            const target = if (buf[0] == '/') try arena.dupe(u8, buf[0..n]) else try std.fs.path.resolvePosix(arena, &.{ "/etc", buf[0..n] });
            try a.appendSlice(arena, &.{ "--ro-bind-try", target, target });
        } else |_| {}
    }
    try a.appendSlice(arena, &.{ "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp" });
    switch (req.env.workspace) {
        .rw => try a.appendSlice(arena, &.{ "--bind", req.workspace, req.workspace }),
        .ro => try a.appendSlice(arena, &.{ "--ro-bind", req.workspace, req.workspace }),
        .none => {},
    }
    try a.appendSlice(arena, &.{ "--bind", home, linux_home });
    for (req.env.read) |r| {
        const p = try expandHome(arena, r, req.owner_home);
        try a.appendSlice(arena, &.{ "--ro-bind-try", p, p });
    }
    const cwd = if (req.env.workspace == .none) linux_home else if (req.cwd.len > 0) req.cwd else req.workspace;
    try a.appendSlice(arena, &.{ "--chdir", cwd, "--", "/bin/sh", "-c", req.command });
    return a.items;
}

// ---- Windows: an AppContainer in a job ----

/// What the AppContainer's SID gets on a folder and all in it.
const read_access: u32 = 0x1200A9; // FILE_GENERIC_READ | FILE_GENERIC_EXECUTE
const modify_access: u32 = 0x1301BF; // and FILE_GENERIC_WRITE and DELETE

const Grant = struct { path: []const u8, access: u32 };

/// The folders the sandbox may use, with what it may do there.
fn wantedGrants(arena: std.mem.Allocator, req: Request, home: []const u8) ![]const Grant {
    var out: std.ArrayList(Grant) = .empty;
    switch (req.env.workspace) {
        .rw => try out.append(arena, .{ .path = req.workspace, .access = modify_access }),
        .ro => try out.append(arena, .{ .path = req.workspace, .access = read_access }),
        .none => {},
    }
    try out.append(arena, .{ .path = home, .access = modify_access });
    for (req.env.read) |r| try out.append(arena, .{ .path = try expandHome(arena, r, req.owner_home), .access = read_access });
    return out.items;
}

/// What was given before: `ACCESS PATH` lines in the environment's folder,
/// so a folder's tree is walked when its grant changes, not every command.
fn readGrants(io: Io, arena: std.mem.Allocator, dir: []const u8) ![]const Grant {
    const path = try std.fs.path.join(arena, &.{ dir, "aces" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList(Grant) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const access = std.fmt.parseInt(u32, line[0..sp], 16) catch continue;
        try out.append(arena, .{ .path = line[sp + 1 ..], .access = access });
    }
    return out.items;
}

fn writeGrants(io: Io, arena: std.mem.Allocator, dir: []const u8, grants: []const Grant) !void {
    var text: std.ArrayList(u8) = .empty;
    for (grants) |g| try text.print(arena, "{x} {s}\n", .{ g.access, g.path });
    try util.writeReplace(io, try std.fs.path.join(arena, &.{ dir, "aces" }), text.items);
}

/// Gives the SID what `req` says, takes back what it no longer says.
fn applyGrants(io: Io, arena: std.mem.Allocator, req: Request, home: []const u8, sid: win.PSID) !void {
    const want = try wantedGrants(arena, req, home);
    const had = try readGrants(io, arena, req.dir);
    var kept: std.ArrayList(Grant) = .empty;
    var changed = false;
    for (want) |w| {
        const same = for (had) |h| {
            if (h.access == w.access and std.mem.eql(u8, h.path, w.path)) break true;
        } else false;
        if (!same) {
            setAce(arena, w.path, sid, w.access, win.SET_ACCESS) catch |e| {
                // a `read =` folder that isn't there is left out
                if (w.access == read_access and w.path.ptr != req.workspace.ptr) continue;
                return e;
            };
            changed = true;
        }
        try kept.append(arena, w);
    }
    for (had) |h| {
        const still = for (want) |w| {
            if (std.mem.eql(u8, h.path, w.path)) break true;
        } else false;
        if (!still) {
            setAce(arena, h.path, sid, 0, win.REVOKE_ACCESS) catch {};
            changed = true;
        }
    }
    if (changed or had.len != kept.items.len) try writeGrants(io, arena, req.dir, kept.items);
}

/// Sets (or, with REVOKE_ACCESS, removes) the SID's ACE on `path`, inherited
/// by all below it; Windows walks the folder's tree for it.
fn setAce(arena: std.mem.Allocator, path: []const u8, sid: win.PSID, access: u32, mode: c_int) !void {
    if (!is_windows) return;
    const p16 = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
    var old: ?*anyopaque = null;
    var sd: ?*anyopaque = null;
    if (win.GetNamedSecurityInfoW(p16, win.SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION, null, null, &old, null, &sd) != 0) return error.AccessDenied;
    defer _ = win.LocalFree(sd);
    var ea = [1]win.EXPLICIT_ACCESS_W{.{
        .permissions = access,
        .mode = mode,
        .inheritance = win.OBJECT_INHERIT_ACE | win.CONTAINER_INHERIT_ACE,
        .trustee = .{ .name = sid },
    }};
    var new: ?*anyopaque = null;
    if (win.SetEntriesInAclW(1, &ea, old, &new) != 0) return error.Unexpected;
    defer _ = win.LocalFree(new);
    if (win.SetNamedSecurityInfoW(p16, win.SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION, null, null, new, null) != 0) return error.AccessDenied;
}

/// The SID of AppContainer `profile`, made the first time; FreeSid it.
fn containerSid(arena: std.mem.Allocator, profile: []const u8) !win.PSID {
    if (!is_windows) return error.Unsupported;
    const name = try std.unicode.utf8ToUtf16LeAllocZ(arena, profile);
    const label = std.unicode.utf8ToUtf16LeStringLiteral("harness sandbox");
    var sid: ?win.PSID = null;
    const hr = win.CreateAppContainerProfile(name, label, label, null, 0, &sid);
    if (hr >= 0) return sid orelse error.Unexpected;
    // HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)
    if (@as(u32, @bitCast(hr)) == 0x800700B7 and win.DeriveAppContainerSidFromAppContainerName(name, &sid) >= 0) return sid orelse error.Unexpected;
    return error.SandboxProfile;
}

/// The variables a sandboxed command gets: the system's, its profile
/// folders in its own home, and PATH, HOME, LANG, TERM; never a secret.
fn windowsVars(arena: std.mem.Allocator, req: Request, home: []const u8) !std.process.Environ.Map {
    const local = try std.fs.path.join(arena, &.{ home, "AppData", "Local" });
    const roaming = try std.fs.path.join(arena, &.{ home, "AppData", "Roaming" });
    const temp = try std.fs.path.join(arena, &.{ local, "Temp" });
    var m = std.process.Environ.Map.init(arena);
    const replaced = [_][]const u8{ "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "HOMEDRIVE", "HOMEPATH" };
    outer: for (req.system_vars) |v| {
        for (replaced) |r| if (std.ascii.eqlIgnoreCase(r, v.name)) continue :outer;
        try m.put(v.name, v.value);
    }
    try m.put("USERPROFILE", home);
    try m.put("APPDATA", roaming);
    try m.put("LOCALAPPDATA", local);
    try m.put("TEMP", temp);
    try m.put("TMP", temp);
    try m.put("PATH", req.path_var);
    try m.put("HOME", home);
    try m.put("LANG", "C.UTF-8");
    try m.put("TERM", "dumb");
    return m;
}

fn spawnAppContainer(io: Io, arena: std.mem.Allocator, req: Request, home: []const u8) !std.process.Child {
    if (!is_windows) unreachable;
    const sid = try containerSid(arena, req.profile);
    defer _ = win.FreeSid(sid);
    const vars = try windowsVars(arena, req, home);
    for ([_][]const u8{ "APPDATA", "LOCALAPPDATA", "TEMP" }) |k| try Io.Dir.cwd().createDirPath(io, vars.get(k).?);
    try applyGrants(io, arena, req, home, sid);

    // network = on: internetClient (outside hosts; never loopback or the LAN)
    var net_sid: ?win.PSID = null;
    defer if (net_sid) |s| {
        _ = win.LocalFree(s);
    };
    var caps: [1]win.SID_AND_ATTRIBUTES = undefined;
    var cap_count: u32 = 0;
    if (req.env.network) {
        if (!win.ConvertStringSidToSidW(std.unicode.utf8ToUtf16LeStringLiteral("S-1-15-3-1"), &net_sid).toBool()) return error.Unexpected;
        caps[0] = .{ .sid = net_sid, .attributes = win.SE_GROUP_ENABLED };
        cap_count = 1;
    }
    const sc: win.SECURITY_CAPABILITIES = .{
        .app_container_sid = sid,
        .capabilities = if (cap_count > 0) &caps else null,
        .capability_count = cap_count,
    };
    const sys = try proc.systemDir(arena);
    return proc.spawnRaw(io, arena, .{
        .app = try std.fs.path.join(arena, &.{ sys, "cmd.exe" }),
        .command_line = try proc.cmdLine(arena, req.command),
        .env = &vars,
        .cwd = if (req.env.workspace == .none) home else if (req.cwd.len > 0) req.cwd else req.workspace,
        .security_capabilities = &sc,
    });
}

const win = struct {
    const PSID = *anyopaque;
    const HRESULT = i32;

    const SE_FILE_OBJECT: c_int = 1;
    const DACL_SECURITY_INFORMATION: u32 = 0x4;
    const SET_ACCESS: c_int = 2;
    const REVOKE_ACCESS: c_int = 4;
    const OBJECT_INHERIT_ACE: u32 = 0x1;
    const CONTAINER_INHERIT_ACE: u32 = 0x2;
    const SE_GROUP_ENABLED: u32 = 0x4;

    const SID_AND_ATTRIBUTES = extern struct { sid: ?PSID, attributes: u32 };
    const SECURITY_CAPABILITIES = extern struct {
        app_container_sid: ?PSID,
        capabilities: ?[*]SID_AND_ATTRIBUTES,
        capability_count: u32,
        reserved: u32 = 0,
    };
    const TRUSTEE_W = extern struct {
        multiple: ?*anyopaque = null,
        multiple_op: c_int = 0,
        /// TRUSTEE_IS_SID
        form: c_int = 0,
        /// TRUSTEE_IS_UNKNOWN
        kind: c_int = 0,
        name: ?*anyopaque,
    };
    const EXPLICIT_ACCESS_W = extern struct {
        permissions: u32,
        mode: c_int,
        inheritance: u32,
        trustee: TRUSTEE_W,
    };

    extern "userenv" fn CreateAppContainerProfile(name: [*:0]const u16, display: [*:0]const u16, description: [*:0]const u16, caps: ?[*]SID_AND_ATTRIBUTES, count: u32, sid: *?PSID) callconv(.winapi) HRESULT;
    extern "userenv" fn DeriveAppContainerSidFromAppContainerName(name: [*:0]const u16, sid: *?PSID) callconv(.winapi) HRESULT;
    extern "userenv" fn DeleteAppContainerProfile(name: [*:0]const u16) callconv(.winapi) HRESULT;
    extern "advapi32" fn FreeSid(sid: PSID) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn ConvertStringSidToSidW(s: [*:0]const u16, sid: *?PSID) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(sid: PSID, s: *?[*:0]u16) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetNamedSecurityInfoW(name: [*:0]const u16, kind: c_int, info: u32, owner: ?*?PSID, group: ?*?PSID, dacl: *?*anyopaque, sacl: ?*?*anyopaque, sd: *?*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn SetEntriesInAclW(count: u32, entries: [*]EXPLICIT_ACCESS_W, old: ?*anyopaque, new: *?*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn SetNamedSecurityInfoW(name: [*:0]u16, kind: c_int, info: u32, owner: ?PSID, group: ?PSID, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) u32;
    extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
};

// ---- tests ----

const t = std.testing;

const Fix = struct {
    tmp: t.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    /// tmp's real path.
    root: []const u8,
    /// A data folder: workspace, state, rules, log.
    data: []const u8,
    ws: []const u8,
    /// The environment's folder (data/state/env/box).
    dir: []const u8,
    /// A stand-in for the owner's home, outside the data folder.
    owner: []const u8,
    env: environments.Env,
    profile: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    seconds: u32 = 30,
    path_var: []const u8,
    system_vars: []const util.Var = &.{},

    fn init(f: *Fix, env: environments.Env) !void {
        f.tmp = t.tmpDir(.{});
        f.arena_state = .init(t.allocator);
        f.a = f.arena_state.allocator();
        f.env = env;
        f.stop = .init(false);
        f.seconds = 30;
        const a = f.a;
        f.root = try f.tmp.dir.realPathFileAlloc(t.io, ".", a);
        f.data = try std.fs.path.join(a, &.{ f.root, "data" });
        f.ws = try std.fs.path.join(a, &.{ f.data, "workspace" });
        f.dir = try std.fs.path.join(a, &.{ f.data, "state", "env", env.name });
        f.owner = try std.fs.path.join(a, &.{ f.root, "owner" });
        for ([_][]const u8{ "data/workspace/sub", "data/state", "data/log", "owner" }) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "data/rules", .data = "allow shell *\n" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "data/state/grants", .data = "secret-grant-line\n" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "data/log/actions.jsonl", .data = "{\"log\":1}\n" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "data/workspace/a.txt", .data = "in the workspace\n" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "owner/private.txt", .data = "the owner's own\n" });
        f.profile = try profileName(a, f.root, env.name);
        if (is_windows) {
            const sys = try proc.systemDir(a);
            f.path_var = try std.fmt.allocPrint(a, "{s};{s}", .{ sys, std.fs.path.dirname(sys).? });
            var map = try t.environ.createMap(a);
            f.system_vars = try util.pickVars(a, &map, util.system_var_names);
        } else f.path_var = "/usr/local/bin:/usr/bin:/bin";
    }

    fn deinit(f: *Fix) void {
        remove(t.io, f.a, f.dir, f.profile) catch {};
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    fn request(f: *Fix, command: []const u8) Request {
        return .{
            .env = &f.env,
            .command = command,
            .workspace = f.ws,
            .dir = f.dir,
            .path_var = f.path_var,
            .system_vars = f.system_vars,
            .owner_home = f.owner,
            .profile = f.profile,
        };
    }

    fn tenv(f: *Fix) tools.Env {
        return .{ .gpa = t.allocator, .io = t.io, .workspace = f.ws, .stop = &f.stop, .shell_seconds = f.seconds };
    }

    fn run(f: *Fix, command: []const u8) !tools.Output {
        return sandboxRun(f, f.request(command));
    }
};

fn sandboxRun(f: *Fix, req: Request) !tools.Output {
    return run(f.tenv(), f.a, req);
}

/// Skips where the backend isn't here (macOS until the Mac session's
/// runner; Linux without bwrap).
fn need(f: *Fix) !void {
    if (try unavailable(t.io, f.a)) |_| return error.SkipZigTest;
}

fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (!has(text, part)) {
        std.debug.print("expected {s} in:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

fn expectNot(text: []const u8, part: []const u8) !void {
    if (has(text, part)) {
        std.debug.print("did not expect {s} in:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    }
}

/// The command ran and exited 0; else what it said.
fn expectOk(o: tools.Output) !void {
    if (o.is_error) {
        std.debug.print("the command failed:\n{s}\n", .{o.text});
        return error.TestUnexpectedResult;
    }
}

/// `cat` there, `type` on Windows.
fn readCmd(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return if (is_windows) std.fmt.allocPrint(a, "type \"{s}\"", .{path}) else std.fmt.allocPrint(a, "cat '{s}'", .{path});
}

test "sandbox_cannot_read_data_folder_or_home" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    const a = f.a;
    // the workspace, yes
    const ws = try f.run(try readCmd(a, try std.fs.path.join(a, &.{ f.ws, "a.txt" })));
    try expectOk(ws);
    try expectHas(ws.text, "in the workspace");
    // the data folder around it, the log, state and the owner's home: no
    for ([_][]const []const u8{ &.{ f.data, "rules" }, &.{ f.data, "state", "grants" }, &.{ f.data, "log", "actions.jsonl" }, &.{ f.owner, "private.txt" } }) |parts| {
        const o = try f.run(try readCmd(a, try std.fs.path.join(a, parts)));
        try t.expect(o.is_error);
        try expectNot(o.text, "allow shell");
        try expectNot(o.text, "secret-grant-line");
        try expectNot(o.text, "\"log\":1");
        try expectNot(o.text, "the owner's own");
    }
}

test "sandbox_workspace_modes" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    const a = f.a;
    const new_file = try std.fs.path.join(a, &.{ f.ws, "new.txt" });
    const write_cmd = if (is_windows) try std.fmt.allocPrint(a, "echo made> \"{s}\"", .{new_file}) else try std.fmt.allocPrint(a, "echo made > '{s}'", .{new_file});
    const read_a = try readCmd(a, try std.fs.path.join(a, &.{ f.ws, "a.txt" }));
    // rw: reads and writes
    try expectOk(try f.run(write_cmd));
    try t.expect(std.mem.startsWith(u8, try f.tmp.dir.readFileAlloc(t.io, "data/workspace/new.txt", a, .limited(100)), "made"));
    try f.tmp.dir.deleteFile(t.io, "data/workspace/new.txt");
    // ro: reads, can't write
    f.env.workspace = .ro;
    try expectHas((try f.run(read_a)).text, "in the workspace");
    try t.expect((try f.run(write_cmd)).is_error);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "data/workspace/new.txt", .{}));
    // none: not even read, and it starts in its home
    f.env.workspace = .none;
    const none = try f.run(read_a);
    try t.expect(none.is_error);
    try expectNot(none.text, "in the workspace");
    const where = try f.run(if (is_windows) "cd" else "pwd");
    try expectHas(where.text, if (is_windows) "home" else linux_home);
}

test "sandbox_home_persists" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    try expectOk(try f.run(if (is_windows) "echo kept-between-commands> \"%USERPROFILE%\\note.txt\"" else "echo kept-between-commands > \"$HOME/note.txt\""));
    const again = try f.run(if (is_windows) "type \"%USERPROFILE%\\note.txt\"" else "cat \"$HOME/note.txt\"");
    try expectOk(again);
    try expectHas(again.text, "kept-between-commands");
    // it is the environment's own folder, in state/env/NAME/home
    try expectHas(try f.tmp.dir.readFileAlloc(t.io, "data/state/env/box/home/note.txt", f.a, .limited(100)), "kept-between-commands");
}

test "sandbox_env_has_no_secrets" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    const o = try f.run(if (is_windows) "set" else "env");
    try expectOk(o);
    // every name it sees is one harness gives it (and what the shell adds)
    const allowed = [_][]const u8{ "PATH", "HOME", "LANG", "TERM", "PWD", "OLDPWD", "SHLVL", "_", "PROMPT" };
    var lines = std.mem.splitScalar(u8, o.text, '\n');
    _ = lines.next(); // "exit code 0"
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = line[0..eq];
        if (name.len == 0) continue;
        const known = for (allowed) |n| {
            if (std.ascii.eqlIgnoreCase(n, name)) break true;
        } else for (util.system_var_names) |n| {
            if (std.ascii.eqlIgnoreCase(n, name)) break true;
        } else false;
        if (!known) {
            std.debug.print("unexpected variable in the sandbox: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

const Stub = struct {
    l: @import("sock.zig").Listener,
    hits: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn serve(s: *Stub) void {
        const sock = @import("sock.zig");
        while (!s.done.load(.acquire)) {
            const h = s.l.accept() catch return;
            if (s.done.load(.acquire)) {
                sock.closeHandle(h);
                return;
            }
            _ = s.hits.fetchAdd(1, .acq_rel);
            sock.closeHandle(h);
        }
    }
};

test "sandbox_network_off" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    var stub: Stub = .{ .l = try @import("sock.zig").Listener.open(0) };
    const th = try std.Thread.spawn(.{}, Stub.serve, .{&stub});
    defer {
        stub.done.store(true, .release);
        // wake the accept
        const h = @import("sock.zig").connect(t.io, "127.0.0.1", stub.l.port, 2000) catch null;
        if (h) |x| @import("sock.zig").closeHandle(x);
        th.join();
        stub.l.close();
    }
    const probe = if (is_windows)
        try std.fmt.allocPrint(f.a, "curl.exe -s -m 3 -o NUL http://127.0.0.1:{d}/ && echo REACHED || echo BLOCKED", .{stub.l.port})
    else
        try std.fmt.allocPrint(f.a, "if command -v curl >/dev/null; then curl -s -m 3 -o /dev/null http://127.0.0.1:{d}/; else exit 9; fi; c=$?; if [ $c = 9 ]; then echo NOCURL; elif [ $c = 0 ] || [ $c = 52 ]; then echo REACHED; else echo BLOCKED; fi", .{stub.l.port});
    // the host itself reaches the stand-in
    const before = stub.hits.load(.acquire);
    const off = try f.run(probe);
    if (has(off.text, "NOCURL")) return error.SkipZigTest;
    try expectHas(off.text, "BLOCKED");
    try t.expectEqual(before, stub.hits.load(.acquire));
    if (is_linux) {
        // on: the host's network, its loopback too (the stand-in counts the
        // connection; curl may call an abrupt close an error)
        f.env.network = true;
        const on = try f.run(probe);
        var waited: u32 = 0;
        while (stub.hits.load(.acquire) == before and waited < 2000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
        if (stub.hits.load(.acquire) == before) {
            std.debug.print("the sandbox did not reach the stand-in with the network on:\n{s}\n", .{on.text});
            return error.TestUnexpectedResult;
        }
    } else if (is_windows) {
        // on (internetClient): outside hosts only, never this machine
        f.env.network = true;
        const on = try f.run(probe);
        try expectHas(on.text, "BLOCKED");
        try t.expectEqual(before, stub.hits.load(.acquire));
    }
}

test "sandbox_stop_and_limit_end_every_process" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    // a sleeper in the background (Linux: one in a session of its own too),
    // and the command waiting in front
    const command = if (is_windows)
        "start /b cmd /c \"for /l %i in (1,1,2000000000) do @rem\" & for /l %i in (1,1,2000000000) do @rem"
    else
        "sleep 31.7 & setsid sleep 31.7 & sleep 31.7";
    var job = proc.Job.create();
    defer job.close();
    var req = f.request(command);
    req.job = &job;
    const Stopper = struct {
        fn go(flag: *std.atomic.Value(bool)) void {
            t.io.sleep(.fromMilliseconds(800), .awake) catch {};
            flag.store(true, .release);
        }
    };
    const started = Io.Clock.awake.now(t.io);
    const th = try std.Thread.spawn(.{}, Stopper.go, .{&f.stop});
    const o = try sandboxRun(&f, req);
    th.join();
    const ms = started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds();
    try expectHas(o.text, "stopped by the owner");
    try t.expect(ms < 800 + 2300);
    try expectNoneLeft(&job, "31.7");
    // the time limit the same way
    f.stop.store(false, .release);
    f.seconds = 1;
    var job2 = proc.Job.create();
    defer job2.close();
    req.job = &job2;
    const o2 = try sandboxRun(&f, req);
    try expectHas(o2.text, "time limit reached");
    try expectNoneLeft(&job2, "31.7");
}

/// Nothing of the command is left: on Windows its job is empty; on Linux
/// no process has `marker` in its command line.
fn expectNoneLeft(job: *proc.Job, marker: []const u8) !void {
    if (is_windows) {
        try t.expect(job.waitEmpty(t.io, 2000, null));
        return;
    }
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 50) {
        if (!(try anyProcessWith(marker))) return;
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn anyProcessWith(marker: []const u8) !bool {
    var d = try Io.Dir.cwd().openDir(t.io, "/proc", .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    var buf: [4096]u8 = undefined;
    while (try it.next(t.io)) |e| {
        if (e.name.len == 0 or !std.ascii.isDigit(e.name[0])) continue;
        var pb: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "/proc/{s}/cmdline", .{e.name}) catch continue;
        const n = (Io.Dir.cwd().readFile(t.io, p, &buf) catch continue).len;
        if (std.mem.indexOf(u8, buf[0..n], marker) != null) return true;
    }
    return false;
}

test "linux_without_bwrap_refuses_plainly" {
    if (!is_linux) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    bwrap_override = "/nonexistent/bwrap";
    defer bwrap_override = null;
    const o = try f.run("echo should-not-run");
    try t.expect(o.is_error);
    try expectHas(o.text, "install bubblewrap");
    try expectNot(o.text, "should-not-run");
}

test "windows_appcontainer_cannot_read_credentials" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    // a credential of a folder's own, in the Credential Manager
    const st: @import("store.zig").Store = .{ .wincred = "harness-5a4dbe0000000777" };
    const name = "sandbox-probe-77";
    try st.put(t.io, name, "probe-Value-381");
    defer _ = st.remove(t.io, name) catch false;
    const o = try f.run("cmdkey /list");
    try expectNot(o.text, name);
    try expectNot(o.text, "probe-Value-381");
}

test "windows_aces_go_with_env_rm" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox, .read = &.{"~/"} });
    defer f.deinit();
    try expectOk(try f.run("echo hi"));
    const sid = try containerSid(f.a, f.profile);
    var sid_text: ?[*:0]u16 = null;
    try t.expect(win.ConvertSidToStringSidW(sid, &sid_text).toBool());
    const sid_s = try std.unicode.utf16LeToUtf8Alloc(f.a, std.mem.span(sid_text.?));
    _ = win.LocalFree(sid_text);
    _ = win.FreeSid(sid);
    try expectHas(try icacls(f.a, f.ws), sid_s);
    try expectHas(try icacls(f.a, f.owner), sid_s);
    try remove(t.io, f.a, f.dir, f.profile);
    try expectNot(try icacls(f.a, f.ws), sid_s);
    try expectNot(try icacls(f.a, f.owner), sid_s);
}

fn icacls(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const r = try std.process.run(a, t.io, .{ .argv = &.{ "icacls", path }, .create_no_window = true });
    return r.stdout;
}

test "the_bwrap_command_shows_only_what_the_environment_says" {
    if (!is_linux) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox, .workspace = .ro, .read = &.{ "/opt/tools", "~/go" } });
    defer f.deinit();
    const argv = try bwrapArgv(t.io, f.a, f.request("make test"), "/usr/bin/bwrap", "/data/state/env/box/home");
    const line = try std.mem.join(f.a, " ", argv);
    try expectHas(line, "--unshare-all --die-with-parent --new-session");
    try expectNot(line, "--share-net");
    try expectHas(line, try std.fmt.allocPrint(f.a, "--ro-bind {s} {s}", .{ f.ws, f.ws }));
    try expectHas(line, "--bind /data/state/env/box/home " ++ linux_home);
    try expectHas(line, "--ro-bind-try /opt/tools /opt/tools");
    try expectHas(line, try std.fmt.allocPrint(f.a, "--ro-bind-try {s}/go {s}/go", .{ f.owner, f.owner }));
    try t.expectEqualStrings("make test", argv[argv.len - 1]);
    // the data folder around the workspace is not shown
    try expectNot(line, try std.fmt.allocPrint(f.a, "bind {s} ", .{f.data}));
}
