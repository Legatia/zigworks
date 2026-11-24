//! Sandboxes on the owner's machine (environments.ini `kind = sandbox`,
//! gap 2): a command gets the workspace (read-write, read-only or not at
//! all), a home of its own kept between commands and the system's
//! programs; never the data folder, the owner's home, a secret, or the
//! network unless switched on. What it starts ends with it, by a stop, the
//! time limit or its own end, as on the host.
//!
//! Linux: bubblewrap (namespaces, a PID namespace that ends with the
//! command). Windows: an AppContainer, with ACEs for its SID on the folders
//! it may use, in a job object. macOS: sandbox-exec, with a profile written
//! per command, in a process group of its own. A missing backend refuses
//! the command; it never runs on the host instead.
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
const is_macos = builtin.os.tag == .macos;

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
    /// Linux, `workspace = copy`: where the sandbox sees `workspace` (the
    /// copy): at the workspace's own path; "": at its own.
    mount_at: []const u8 = "",
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

/// Tests: where sandbox-exec is, instead of /usr/bin/sandbox-exec.
pub var sandbox_exec_override: ?[]const u8 = null;

/// What runs sandboxes here, as `/env check` names it.
pub const backend = switch (builtin.os.tag) {
    .windows => "AppContainer",
    .macos => "sandbox-exec",
    else => "bubblewrap",
};

/// Why sandboxes can't run here; null when they can.
pub fn unavailable(io: Io, arena: std.mem.Allocator) !?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const bwrap = (try findBwrap(io, arena)) orelse break :blk "install bubblewrap (the bwrap command) to use sandboxes";
            break :blk try canSandbox(io, arena, bwrap);
        },
        .windows => null,
        .macos => blk: {
            const exe = sandboxExec();
            const st = Io.Dir.cwd().statFile(io, exe, .{}) catch break :blk try std.fmt.allocPrint(arena, "sandbox-exec ({s}) is not on this Mac", .{exe});
            if (st.kind != .file) break :blk try std.fmt.allocPrint(arena, "sandbox-exec ({s}) is not a program", .{exe});
            break :blk try canSandboxMac(io, arena, exe);
        },
        else => "sandboxes are not built for this system",
    };
}

/// Whether bwrap can make a sandbox here: on some systems (Ubuntu 24.04
/// with its AppArmor rule for user namespaces, a container) it is there
/// and can't. Tried once per bwrap.
fn canSandbox(io: Io, arena: std.mem.Allocator, bwrap: []const u8) !?[]const u8 {
    return tryOnce(io, arena, bwrap, "bubblewrap", &.{ bwrap, "--unshare-all", "--die-with-parent", "--ro-bind", "/", "/", "true" }, "bubblewrap can't make a sandbox here ({s}); on Ubuntu, user namespaces may be restricted (kernel.apparmor_restrict_unprivileged_userns)");
}

/// Runs `argv` once per `exe` (until another is tried): null when it
/// exits 0, else `why` with the first line it said (or its exit code).
fn tryOnce(io: Io, arena: std.mem.Allocator, exe: []const u8, name: []const u8, argv: []const []const u8, comptime why: []const u8) !?[]const u8 {
    probe_mutex.lockUncancelable(io);
    defer probe_mutex.unlock(io);
    if (probed) |p| if (std.mem.eql(u8, p.exe[0..p.len], exe)) return if (p.why_len == 0) null else try arena.dupe(u8, p.why[0..p.why_len]);
    const r = std.process.run(arena, io, .{ .argv = argv }) catch |e| return try std.fmt.allocPrint(arena, "{s} didn't start: {s}", .{ name, @errorName(e) });
    var p: Probed = .{};
    if (!r.term.success()) {
        var first = std.mem.trim(u8, r.stderr[0 .. std.mem.indexOfScalar(u8, r.stderr, '\n') orelse r.stderr.len], " \r");
        if (first.len == 0) first = switch (r.term) {
            .exited => |code| try std.fmt.allocPrint(arena, "exit code {d}", .{code}),
            else => @tagName(r.term),
        };
        const text = try std.fmt.allocPrint(arena, why, .{util.cut(first, 200)});
        p.why_len = @min(text.len, p.why.len);
        @memcpy(p.why[0..p.why_len], text[0..p.why_len]);
    }
    p.len = @min(exe.len, p.exe.len);
    @memcpy(p.exe[0..p.len], exe[0..p.len]);
    probed = p;
    return if (p.why_len == 0) null else try arena.dupe(u8, p.why[0..p.why_len]);
}

const Probed = struct { exe: [256]u8 = undefined, len: usize = 0, why: [512]u8 = undefined, why_len: usize = 0 };
var probed: ?Probed = null;
var probe_mutex: Io.Mutex = .init;

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
        .macos => try spawnSandboxExec(tenv.io, arena, req, home),
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
    // `read =` folders first: the workspace and the data folder's cover go
    // over them (a later mount covers an earlier one)
    const data = dataFolder(req.dir);
    var covers_data = false;
    for (req.env.read) |r| {
        const p = try expandHome(arena, r, req.owner_home);
        try a.appendSlice(arena, &.{ "--ro-bind-try", p, p });
        if (data.len > 0 and within(realOr(io, arena, p), realOr(io, arena, data))) covers_data = true;
    }
    // never the data folder, inside a `read =` folder too: an empty folder
    // in its place
    if (covers_data) try a.appendSlice(arena, &.{ "--tmpfs", data });
    const at = if (req.mount_at.len > 0) req.mount_at else req.workspace;
    switch (req.env.workspace) {
        .rw, .copy => try a.appendSlice(arena, &.{ "--bind", req.workspace, at }),
        .ro => try a.appendSlice(arena, &.{ "--ro-bind", req.workspace, at }),
        .none => {},
    }
    try a.appendSlice(arena, &.{ "--bind", home, linux_home });
    const cwd = if (req.env.workspace == .none) linux_home else if (req.cwd.len > 0) req.cwd else at;
    try a.appendSlice(arena, &.{ "--chdir", cwd, "--", "/bin/sh", "-c", req.command });
    return a.items;
}

// ---- macOS: sandbox-exec ----

fn sandboxExec() []const u8 {
    return sandbox_exec_override orelse "/usr/bin/sandbox-exec";
}

/// What a macOS sandbox's profile is made of, each path as the system
/// resolves it: the sandbox matches real paths (/private/tmp, not /tmp).
pub const MacPaths = struct {
    workspace: []const u8,
    mode: environments.Mode = .rw,
    network: bool = false,
    /// Its home and its temp: read and written.
    home: []const u8,
    tmp: []const u8,
    /// `read =` folders, read-only.
    read: []const []const u8 = &.{},
    /// The data folder: refused even inside a `read =` folder, but for the
    /// workspace and the environment's own folders in it; "": none.
    data: []const u8 = "",
    /// The owner's home: its Keychains are refused; "": none.
    owner_home: []const u8 = "",
    /// The developer folder xcode-select names, when /Library doesn't hold
    /// it (Xcode's .app); "": none.
    developer: []const u8 = "",
};

/// The system's folders a sandbox reads and runs programs from: what
/// /bin/sh, the usual tools and their libraries need (/private/var/select
/// is where /bin/sh and xcode-select look), Homebrew's on Apple silicon
/// as /usr/local is on Intel Macs; but what Homebrew's services keep in
/// its `var` (databases, logs), unless a `read =` folder names it.
const mac_system = [_][]const u8{ "/usr", "/bin", "/sbin", "/System", "/Library", "/opt/homebrew", "/private/etc", "/private/var/select", "/private/var/db/timezone" };

/// The profile for one command (SBPL): nothing but what it lists, later
/// rules winning over earlier ones. Read: the system's folders, `read =`
/// folders, the workspace (rw, ro or none), its home and temp, and only
/// the metadata of the folders above those. Written: the workspace when
/// rw, its home and temp. Never: the data folder (even inside a `read =`
/// folder), the Keychain's files and services, the terminal, this
/// machine's network; outside hosts only when the network is on.
pub fn macProfile(arena: std.mem.Allocator, p: MacPaths) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    // its own processes alone; set-id programs never run (the sandbox
    // refuses them: ps, sudo)
    try o.appendSlice(arena,
        \\(version 1)
        \\(deny default)
        \\(allow process-fork)
        \\(allow signal (target same-sandbox))
        \\(allow process-info* (target same-sandbox))
        \\(allow sysctl-read)
        \\
    );
    try o.appendSlice(arena, "(allow file-read* process-exec file-map-executable");
    for (mac_system) |sp| try filter(&o, arena, "subpath", sp);
    try o.appendSlice(arena, " (literal \"/private/var/db/xcode_select_link\")");
    if (p.developer.len > 0) try filter(&o, arena, "subpath", p.developer);
    try o.appendSlice(arena, ")\n");
    try o.appendSlice(arena,
        \\(allow file-read* (literal "/"))
        \\(allow file-read-metadata (literal "/etc") (literal "/tmp") (literal "/var") (literal "/private") (literal "/private/var") (literal "/private/var/db") (literal "/Applications") (literal "/opt"))
        \\(allow file-read* file-write-data (literal "/dev/null") (literal "/dev/zero") (literal "/dev/stdin") (literal "/dev/stdout") (literal "/dev/stderr") (subpath "/dev/fd"))
        \\(allow file-read* (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/autofs_nowait"))
        \\(allow file-read* file-write-data file-ioctl (literal "/dev/dtracehelper"))
        \\(allow ipc-posix-shm-read-data (ipc-posix-name "apple.shm.notification_center"))
        \\(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo") (global-name "com.apple.system.notification_center"))
        \\(deny file-read* file-write* process-exec (subpath "/opt/homebrew/var") (subpath "/usr/local/var"))
        \\
    );
    // refused without a report in the system log: the owner's per-user
    // temp (without these the system's tools fall back to TMPDIR), logging,
    // the terminal (a command could type into it), the owner's encoding file
    try o.appendSlice(arena,
        \\(deny mach-lookup (with no-log) (global-name "com.apple.bsd.dirhelper") (global-name "com.apple.system.opendirectoryd.membership") (global-name "com.apple.logd"))
        \\(deny file-read* file-write* (with no-log) (literal "/dev/tty")
    );
    if (p.owner_home.len > 0) try filter(&o, arena, "literal", try under(arena, p.owner_home, ".CFUserTextEncoding"));
    try o.appendSlice(arena, ")\n");
    if (p.read.len > 0) {
        try o.appendSlice(arena, "(allow file-read* process-exec file-map-executable");
        for (p.read) |r| try filter(&o, arena, "subpath", r);
        try o.appendSlice(arena, ")\n");
        try ancestors(&o, arena, p.read);
    }
    // never, even inside a `read =` folder: the data folder
    if (p.data.len > 0) {
        try o.appendSlice(arena, "(deny file-read* file-write* process-exec");
        try filter(&o, arena, "subpath", p.data);
        try o.appendSlice(arena, ")\n");
    }
    try o.appendSlice(arena, switch (p.mode) {
        .rw, .copy => "(allow file-read* file-write* process-exec file-map-executable",
        .ro => "(allow file-read* process-exec file-map-executable",
        .none => "(deny file-read* file-write* process-exec",
    });
    try filter(&o, arena, "subpath", p.workspace);
    try o.appendSlice(arena, ")\n");
    if (p.mode != .none) try ancestors(&o, arena, &.{p.workspace});
    // a workspace that holds the data folder (a link to the owner's home)
    // doesn't give it back
    if (p.mode != .none and p.data.len > 0 and std.mem.startsWith(u8, p.data, p.workspace) and
        p.data.len > p.workspace.len and (p.data[p.workspace.len] == '/' or std.mem.eql(u8, p.workspace, "/")))
    {
        try o.appendSlice(arena, "(deny file-read* file-write* process-exec");
        try filter(&o, arena, "subpath", p.data);
        try o.appendSlice(arena, ")\n");
    }
    try o.appendSlice(arena, "(allow file-read* file-write* process-exec file-map-executable");
    try filter(&o, arena, "subpath", p.home);
    try filter(&o, arena, "subpath", p.tmp);
    try o.appendSlice(arena, ")\n");
    try ancestors(&o, arena, &.{ p.home, p.tmp });
    if (p.network) {
        // outside hosts; never this machine ("localhost" is every address
        // of it); names through the system's resolver; certificates
        // checked by trustd; proxy and DNS settings
        try o.appendSlice(arena,
            \\(allow network-outbound (remote ip "*:*"))
            \\(deny network-outbound (remote ip "localhost:*"))
            \\(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
            \\(allow file-read* (literal "/private/var/run/resolv.conf"))
            \\(allow mach-lookup (global-name "com.apple.trustd") (global-name "com.apple.trustd.agent") (global-name "com.apple.SystemConfiguration.configd") (global-name "com.apple.SystemConfiguration.DNSConfiguration"))
            \\
        );
    } else try o.appendSlice(arena, "(deny network*)\n");
    // the Keychain: its services and its files, whatever came before
    try o.appendSlice(arena,
        \\(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.secd") (global-name-prefix "com.apple.securityd") (global-name-prefix "com.apple.security.") (global-name-prefix "com.apple.ctkd"))
        \\(deny file-read* file-write* (subpath "/Library/Keychains")
    );
    if (p.owner_home.len > 0) try filter(&o, arena, "subpath", try under(arena, p.owner_home, "Library/Keychains"));
    try o.appendSlice(arena, ")\n");
    return o.items;
}

/// `rest` in the folder `dir`, with `/` whatever system the text is made on
/// (the profile is checked on every system).
fn under(arena: std.mem.Allocator, dir: []const u8, rest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), rest });
}

/// ` (KIND "PATH")`, the path quoted: `\` and `"` escaped, so no path can
/// end its string and add rules of its own.
fn filter(o: *std.ArrayList(u8), arena: std.mem.Allocator, kind: []const u8, path: []const u8) !void {
    try o.print(arena, " ({s} \"", .{kind});
    for (path) |c| {
        if (c == '\\' or c == '"') try o.append(arena, '\\');
        try o.append(arena, c);
    }
    try o.appendSlice(arena, "\")");
}

/// The metadata (never a listing) of the folders above `paths`: git and
/// realpath look at each folder on the way.
fn ancestors(o: *std.ArrayList(u8), arena: std.mem.Allocator, paths: []const []const u8) !void {
    try o.appendSlice(arena, "(allow file-read-metadata");
    for (paths) |p| try filter(o, arena, "path-ancestors", p);
    try o.appendSlice(arena, ")\n");
}

/// The real path of `path`, or `path` as it is when it can't be resolved
/// (not there yet).
fn realOr(io: Io, arena: std.mem.Allocator, path: []const u8) []const u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch path;
}

/// Whether `child` is `parent` or inside it (both real paths); letters'
/// case aside on Windows.
fn within(parent: []const u8, child: []const u8) bool {
    const p = std.mem.trimEnd(u8, parent, "/\\");
    if (child.len < p.len) return false;
    const head = child[0..p.len];
    if (!(if (is_windows) std.ascii.eqlIgnoreCase(head, p) else std.mem.eql(u8, head, p))) return false;
    return child.len == p.len or child[p.len] == '/' or child[p.len] == '\\';
}

/// The data folder, from the environment's folder (DATA/state/env/NAME);
/// "" when it is not laid out so.
fn dataFolder(env_dir: []const u8) []const u8 {
    const envs = std.fs.path.dirname(env_dir) orelse return "";
    if (!std.mem.eql(u8, std.fs.path.basename(envs), "env")) return "";
    const state = std.fs.path.dirname(envs) orelse return "";
    if (!std.mem.eql(u8, std.fs.path.basename(state), "state")) return "";
    const data = std.fs.path.dirname(state) orelse return "";
    return if (std.fs.path.dirname(data) == null) "" else data;
}

/// The developer folder xcode-select names (git, make, cc and python3 in
/// /usr/bin start what is there): the whole .app when it is in one
/// (xcodebuild reads beside it); "" when /Library holds it or none is set.
fn developerFolder(io: Io, arena: std.mem.Allocator) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = for ([_][]const u8{ "/private/var/select/developer_dir", "/private/var/db/xcode_select_link" }) |link| {
        if (Io.Dir.cwd().readLink(io, link, &buf)) |n| break buf[0..n] else |_| {}
    } else return "";
    if (target.len == 0 or target[0] != '/') return "";
    const dir = if (std.mem.indexOf(u8, target, ".app/")) |i| target[0 .. i + ".app".len] else target;
    const real = realOr(io, arena, arena.dupe(u8, dir) catch return "");
    return if (std.mem.startsWith(u8, real, "/Library/")) "" else real;
}

/// The profile's paths for `req`, resolved; `home` and `tmp` exist.
fn macPaths(io: Io, arena: std.mem.Allocator, req: Request, home: []const u8, tmp: []const u8) !MacPaths {
    var read: std.ArrayList([]const u8) = .empty;
    for (req.env.read) |r| {
        const p = try expandHome(arena, r, req.owner_home);
        // `~/x` without an owner's home is no folder
        if (std.fs.path.isAbsolute(p)) try read.append(arena, realOr(io, arena, p));
    }
    const env_dir = realOr(io, arena, req.dir);
    return .{
        .workspace = realOr(io, arena, req.workspace),
        .mode = req.env.workspace,
        .network = req.env.network,
        .home = realOr(io, arena, home),
        .tmp = realOr(io, arena, tmp),
        .read = read.items,
        .data = dataFolder(env_dir),
        .owner_home = if (req.owner_home.len > 0) realOr(io, arena, req.owner_home) else "",
        .developer = developerFolder(io, arena),
    };
}

/// Whether sandbox-exec applies harness's profile here (inside another
/// sandbox it can't). Tried once per path, with the profile's every kind
/// of rule.
fn canSandboxMac(io: Io, arena: std.mem.Allocator, exe: []const u8) !?[]const u8 {
    const empty = "/private/var/empty";
    const profile = try macProfile(arena, .{ .workspace = empty, .network = true, .home = empty, .tmp = empty, .read = &.{empty}, .data = empty, .owner_home = empty });
    return tryOnce(io, arena, exe, "sandbox-exec", &.{ exe, "-p", profile, "/usr/bin/true" }, "sandbox-exec can't make a sandbox here ({s})");
}

fn spawnSandboxExec(io: Io, arena: std.mem.Allocator, req: Request, home: []const u8) !std.process.Child {
    const tmp = try std.fs.path.join(arena, &.{ req.dir, "tmp" });
    try Io.Dir.cwd().createDirPath(io, tmp);
    const p = try macPaths(io, arena, req, home, tmp);
    const profile = try macProfile(arena, p);
    var vars = std.process.Environ.Map.init(arena);
    try vars.put("PATH", req.path_var);
    try vars.put("HOME", p.home);
    try vars.put("TMPDIR", p.tmp);
    try vars.put("LANG", "C.UTF-8");
    try vars.put("TERM", "dumb");
    return std.process.spawn(io, .{
        .argv = &.{ sandboxExec(), "-p", profile, "/bin/sh", "-c", req.command },
        .cwd = .{ .path = if (req.env.workspace == .none) p.home else if (req.cwd.len > 0) req.cwd else p.workspace },
        .environ_map = &vars,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // its own group: a stop, the time limit and its end end it and
        // what it started (tools.runChild); one that leaves the group
        // survives, inside the profile, as on the host
        .pgid = 0,
    });
}

// ---- Windows: an AppContainer in a job ----

/// What the AppContainer's SID gets on a folder and all in it.
const read_access: u32 = 0x1200A9; // FILE_GENERIC_READ | FILE_GENERIC_EXECUTE
const modify_access: u32 = 0x1301BF; // and FILE_GENERIC_WRITE and DELETE

/// A grant's access that means: refused, whatever a folder above gives.
const deny_all: u32 = 0;

const Grant = struct { path: []const u8, access: u32 };

/// The folders the sandbox may use, with what it may do there.
fn wantedGrants(arena: std.mem.Allocator, req: Request, home: []const u8) ![]const Grant {
    var out: std.ArrayList(Grant) = .empty;
    switch (req.env.workspace) {
        .rw => try out.append(arena, .{ .path = req.workspace, .access = modify_access }),
        // the folder its runs' copies are in, once for all of them (each
        // copy made later inherits it)
        // (only a copy in the environment's own folder: never the folder
        // above some other workspace)
        .copy => try out.append(arena, .{ .path = if (within(req.dir, req.workspace)) std.fs.path.dirname(req.workspace) orelse req.workspace else req.workspace, .access = modify_access }),
        .ro => try out.append(arena, .{ .path = req.workspace, .access = read_access }),
        .none => {},
    }
    try out.append(arena, .{ .path = home, .access = modify_access });
    const data = dataFolder(req.dir);
    var covers_data = false;
    for (req.env.read) |r| {
        const p = try expandHome(arena, r, req.owner_home);
        try out.append(arena, .{ .path = p, .access = read_access });
        if (data.len > 0 and within(p, data)) covers_data = true;
    }
    // never the data folder, inside a `read =` folder too: cut off there
    // (access 0), but for the workspace and its home, which have entries
    // of their own
    if (covers_data) try out.append(arena, .{ .path = data, .access = deny_all });
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
    if (mode == win.SET_ACCESS and access == deny_all) return cutOff(arena, path, sid);
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

/// Refuses `path` and all in it to the SID, whatever a folder above gives:
/// Windows ignores a deny entry for an AppContainer, so the folder stops
/// inheriting (its inherited entries become its own, as `icacls
/// /inheritance:d` does) and the SID's entries are taken out. Folders in it
/// with entries of their own for the SID (the workspace, its home) keep
/// them. It stays so after `env rm`: who may use the folder is unchanged.
fn cutOff(arena: std.mem.Allocator, path: []const u8, sid: win.PSID) !void {
    if (!is_windows) return;
    const p16 = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
    var dacl: ?*anyopaque = null;
    var sd: ?*anyopaque = null;
    if (win.GetNamedSecurityInfoW(p16, win.SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd) != 0) return error.AccessDenied;
    defer _ = win.LocalFree(sd);
    const acl = dacl orelse return;
    // ACL: revision u8, pad u8, size u16, count u16, pad u16
    const count: *align(1) u16 = @ptrCast(@as([*]u8, @ptrCast(acl)) + 4);
    var i: u32 = 0;
    while (i < count.*) {
        var ace: ?*anyopaque = null;
        if (!win.GetAce(acl, i, &ace).toBool()) return error.Unexpected;
        // ACE: type u8, flags u8, size u16, mask u32, the SID (the kinds
        // files carry: allowed 0, denied 1)
        const b: [*]u8 = @ptrCast(ace.?);
        if (b[0] <= 1 and win.EqualSid(@ptrCast(b + 8), sid).toBool()) {
            if (!win.DeleteAce(acl, i).toBool()) return error.Unexpected;
            continue;
        }
        b[1] &= ~@as(u8, win.INHERITED_ACE);
        i += 1;
    }
    if (win.SetNamedSecurityInfoW(p16, win.SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION | win.PROTECTED_DACL_SECURITY_INFORMATION, null, null, acl, null) != 0) return error.AccessDenied;
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

/// The letters a sandbox's drives get: the first two of W down to L that
/// are no drive of this machine.
pub fn freeLetters(taken: u32) ?[2]u8 {
    var out: [2]u8 = undefined;
    var n: usize = 0;
    var letter: u8 = 'W';
    while (letter >= 'L') : (letter -= 1) {
        if (taken & (@as(u32, 1) << @intCast(letter - 'A')) != 0) continue;
        out[n] = letter;
        n += 1;
        if (n == 2) return out;
    }
    return null;
}

/// `path` (inside `root`, or `root` itself) on drive `letter`.
fn onDrive(arena: std.mem.Allocator, letter: u8, root: []const u8, path: []const u8) ![]const u8 {
    const rest = if (path.len > root.len) std.mem.trimStart(u8, path[root.len..], "\\/") else "";
    const out = try std.fmt.allocPrint(arena, "{c}:\\{s}", .{ letter, rest });
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

fn spawnAppContainer(io: Io, arena: std.mem.Allocator, req: Request, home: []const u8) !std.process.Child {
    if (!is_windows) unreachable;
    const sid = try containerSid(arena, req.profile);
    defer _ = win.FreeSid(sid);
    const vars = try windowsVars(arena, req, home);
    for ([_][]const u8{ "APPDATA", "LOCALAPPDATA", "TEMP" }) |k| try Io.Dir.cwd().createDirPath(io, vars.get(k).?);
    // Windows gives an AppContainer's processes its own LOCALAPPDATA and
    // TEMP under the one it was started with: Packages\PROFILE\AC[\Temp]
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ vars.get("LOCALAPPDATA").?, "Packages", req.profile, "AC", "Temp" }));
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
    const cmd_exe = try std.fs.path.join(arena, &.{ sys, "cmd.exe" });
    const sees = req.env.workspace != .none;
    // with drives of its own (see proc.zig): the workspace's (the home's,
    // where it doesn't see the workspace) and the home's, whose folders
    // its variables then name. The launcher starts in the home by its real
    // path; the command changes to its drive, and is not run if it can't.
    if (drive_letters and !no_session.load(.acquire)) if (freeLetters(proc.logicalDrives())) |letters| {
        var on = try vars.clone(arena);
        for ([_][]const u8{ "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "HOME" }) |k|
            try on.put(k, try onDrive(arena, letters[1], home, vars.get(k).?));
        const start = if (!sees) try onDrive(arena, letters[0], home, home) else try onDrive(arena, letters[0], req.workspace, if (req.cwd.len > 0) req.cwd else req.workspace);
        const spawn: proc.SessionSpawn = .{
            .launcher = try launcher(io, arena),
            .app = cmd_exe,
            .command_line = try proc.cmdLine(arena, try std.fmt.allocPrint(arena, "cd /d \"{s}\"||exit 1&{s}", .{ start, req.command })),
            .env = &on,
            .cwd = home,
            .profile = req.profile,
            .network = req.env.network,
            .drives = &.{ .{ .letter = letters[0], .folder = if (sees) req.workspace else home }, .{ .letter = letters[1], .folder = home } },
        };
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (proc.spawnInSession(io, arena, spawn)) |child| return child else |e| switch (e) {
                // no session of its own on this machine: from now on as
                // before, by its real paths (cmd's own dir, del, ren,
                // copy, move and cd /d then fail)
                error.NoSession => {
                    no_session.store(true, .release);
                    break;
                },
                // not this time (the service was busy): tried again, then
                // this one command runs by its real paths
                error.SessionNotNow => {
                    if (tries >= 4) break;
                    io.sleep(.fromMilliseconds(100 * (@as(i64, tries) + 1)), .awake) catch {};
                },
                else => return e,
            }
        }
    };
    return proc.spawnRaw(io, arena, .{
        .app = cmd_exe,
        .command_line = try proc.cmdLine(arena, req.command),
        .env = &vars,
        .cwd = if (!sees) home else if (req.cwd.len > 0) req.cwd else req.workspace,
        .security_capabilities = &sc,
    });
}

/// Tests: off, a sandbox runs by its real paths, as where no logon
/// session of its own can be made.
pub var drive_letters: bool = true;

/// Set once the Secondary Logon service refused: not tried again until
/// harness starts again.
var no_session: std.atomic.Value(bool) = .init(false);

/// Whether sandboxes here get drive letters of their own, so far as is
/// known (true until a command found they can't).
pub fn hasDriveLetters() bool {
    return is_windows and drive_letters and !no_session.load(.acquire);
}

/// Whether a sandbox here can open NUL (`>nul`, `2>nul`, a program's own
/// null output). Windows Server gives the device no entry for app
/// containers (Windows 11 does), and only an administrator could add one.
/// True where it can't be told.
pub fn nulOpen() bool {
    if (!is_windows) return true;
    const known = nul_known.load(.acquire);
    if (known != 0) return known == 1;
    const yes = nulAllowsAppContainers() catch true;
    nul_known.store(if (yes) 1 else 2, .release);
    return yes;
}

var nul_known: std.atomic.Value(u8) = .init(0);

fn nulAllowsAppContainers() !bool {
    var dacl: ?*anyopaque = null;
    var sd: ?*anyopaque = null;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\NUL");
    if (win.GetNamedSecurityInfoW(name, win.SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &sd) != 0) return error.Unknown;
    defer _ = win.LocalFree(sd);
    var text: ?[*:0]u16 = null;
    if (win.ConvertSecurityDescriptorToStringSecurityDescriptorW(sd.?, 1, win.DACL_SECURITY_INFORMATION, &text, null) == .FALSE) return error.Unknown;
    defer _ = win.LocalFree(text);
    // an allow entry for ALL APPLICATION PACKAGES: `(A;…;;;AC)`
    return std.mem.indexOf(u16, std.mem.span(text.?), std.unicode.utf8ToUtf16LeStringLiteral(";;;AC)")) != null;
}

/// The program that is the launcher: harness itself; in the unit tests,
/// harness-fake.
fn launcher(io: Io, arena: std.mem.Allocator) ![2][]const u8 {
    if (builtin.is_test) return .{ @import("build_options").fake_path, "--" ++ proc.launch_arg };
    return .{ try std.process.executablePathAlloc(io, arena), proc.launch_arg };
}

const win = struct {
    const PSID = *anyopaque;
    const HRESULT = i32;

    const SE_FILE_OBJECT: c_int = 1;
    const DACL_SECURITY_INFORMATION: u32 = 0x4;
    const PROTECTED_DACL_SECURITY_INFORMATION: u32 = 0x80000000;
    const INHERITED_ACE: u8 = 0x10;
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
    extern "advapi32" fn ConvertSecurityDescriptorToStringSecurityDescriptorW(sd: *anyopaque, rev: u32, info: u32, text: *?[*:0]u16, len: ?*u32) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetAce(acl: *anyopaque, index: u32, ace: *?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn DeleteAce(acl: *anyopaque, index: u32) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn EqualSid(a: PSID, b: PSID) callconv(.winapi) windows.BOOL;
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

/// Skips where the backend isn't here (Linux without bwrap, a Mac where
/// sandbox-exec can't make a sandbox).
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

test "sandbox_cannot_read_the_data_folder_inside_a_read_folder" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    const a = f.a;
    // a `read =` folder that holds the data folder (as `read = ~` does)
    f.env.read = &.{f.root};
    const own = try f.run(try readCmd(a, try std.fs.path.join(a, &.{ f.owner, "private.txt" })));
    try expectOk(own);
    try expectHas(own.text, "the owner's own");
    for ([_][]const []const u8{ &.{ f.data, "rules" }, &.{ f.data, "state", "grants" }, &.{ f.data, "log", "actions.jsonl" } }) |parts| {
        const o = try f.run(try readCmd(a, try std.fs.path.join(a, parts)));
        if (!o.is_error and is_windows) std.debug.print("XDEBUG {s}\n{s}\n{s}\n", .{ o.text, try icacls(a, f.data), try icacls(a, try std.fs.path.join(a, parts)) });
        try t.expect(o.is_error);
        try expectNot(o.text, "allow shell");
        try expectNot(o.text, "secret-grant-line");
        try expectNot(o.text, "\"log\":1");
    }
    // the workspace in it, and its home, as before
    const ws = try f.run(try readCmd(a, try std.fs.path.join(a, &.{ f.ws, "a.txt" })));
    try expectOk(ws);
    try expectHas(ws.text, "in the workspace");
    try expectOk(try f.run(if (is_windows) "echo kept> \"%USERPROFILE%\\k.txt\" && echo new> new.txt" else "echo kept > ~/k.txt && echo new > new.txt"));
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
    // Linux shows the home at linux_home, Windows as a drive of the
    // sandbox's own, macOS where it is
    try expectHas(where.text, if (is_linux) linux_home else if (is_windows and hasDriveLetters()) ":\\\r\n" else "home");
}

test "windows_sandbox_without_a_session_of_its_own_runs_by_its_real_paths" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    // as where the Secondary Logon service is switched off
    drive_letters = false;
    defer drive_letters = true;
    try expectHas((try f.run("cd")).text, f.ws);
    try expectHas((try f.run("type a.txt")).text, "in the workspace");
    try expectOk(try f.run("echo more>> a.txt"));
    // cmd's own commands that ask the drive's root: refused, as before
    try expectHas((try f.run("dir /b")).text, "Access is denied");
}

test "a_sandboxes_drive_letters_are_none_of_the_machines" {
    // W and V on a machine with C and D
    try t.expectEqualSlices(u8, "WV", &freeLetters(0b1100).?);
    // W is a drive here: V and U
    try t.expectEqualSlices(u8, "VU", &freeLetters(0b1100 | (1 << 22)).?);
    // none left from L to W but one: none
    var taken: u32 = 0;
    for ('L'..'W' + 1) |c| taken |= @as(u32, 1) << @intCast(c - 'A');
    try t.expectEqual(null, freeLetters(taken));
    try t.expectEqual(null, freeLetters(taken & ~(@as(u32, 1) << ('P' - 'A'))));
    if (is_windows) {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        try t.expectEqualStrings("W:\\", try onDrive(arena.allocator(), 'W', "D:\\data\\workspace", "D:\\data\\workspace"));
        try t.expectEqualStrings("W:\\sub\\x", try onDrive(arena.allocator(), 'W', "D:\\data\\workspace", "D:\\data\\workspace\\sub/x"));
    }
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
    // every name it sees is one harness gives it (and what the shell adds);
    // macOS: its own temp too
    const allowed = [_][]const u8{ "PATH", "HOME", "LANG", "TERM", "PWD", "OLDPWD", "SHLVL", "_", "PROMPT" } ++ if (is_macos) [_][]const u8{"TMPDIR"} else [_][]const u8{};
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
    } else {
        // on: outside hosts only, never this machine (Windows:
        // internetClient; macOS: no address of this machine)
        f.env.network = true;
        const on = try f.run(probe);
        try expectHas(on.text, "BLOCKED");
        try t.expectEqual(before, stub.hits.load(.acquire));
    }
    if (is_macos) {
        // an outside address: refused when off, let out when on. 192.0.2.1
        // (TEST-NET-1) reaches no one, so this needs no internet: online
        // the connection times out, offline it is unreachable, and only a
        // sandbox (or a filter of the machine's own) says "not permitted"
        const outside = "nc -v -z -G 2 -w 2 192.0.2.1 9 2>&1; true";
        f.env.network = false;
        try expectHas((try f.run(outside)).text, "not permitted");
        // a network filter of this Mac's own refuses it outside any sandbox
        const here = try std.process.run(f.a, t.io, .{ .argv = &.{ "/bin/sh", "-c", outside } });
        if (has(here.stdout, "not permitted")) {
            std.debug.print("sandbox_network_off: this Mac refuses 192.0.2.1 outside the sandbox too (a network filter); the half with the network on is not checked\n", .{});
            return;
        }
        f.env.network = true;
        try expectNot((try f.run(outside)).text, "not permitted");
    }
}

test "sandbox_stop_and_limit_end_every_process" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    // a sleeper in the background (Linux: one in a session of its own too;
    // macOS has no setsid, and one that leaves the group survives there as
    // on the host), and the command waiting in front
    // a marker made here, at run time: no other process's command line
    // (the shell that started the tests included) can hold it
    var rnd: [4]u8 = undefined;
    t.io.random(&rnd);
    var mb: [16]u8 = undefined;
    const marker = try std.fmt.bufPrint(&mb, "31.{d:0>6}", .{std.mem.readInt(u32, &rnd, .little) % 1000000});
    var cb: [128]u8 = undefined;
    const command = if (is_windows)
        "start /b cmd /c \"for /l %i in (1,1,2000000000) do @rem\" & for /l %i in (1,1,2000000000) do @rem"
    else if (is_linux)
        try std.fmt.bufPrint(&cb, "sleep {s} & setsid sleep {s} & sleep {s}", .{ marker, marker, marker })
    else
        try std.fmt.bufPrint(&cb, "sleep {s} & sleep {s}", .{ marker, marker });
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
    if (ms >= 800 + 2300) {
        std.debug.print("the stop took {d} ms (stopped at 800 ms)\n", .{ms});
        return error.TestUnexpectedResult;
    }
    try expectNoneLeft(&job, marker);
    // the time limit the same way
    f.stop.store(false, .release);
    f.seconds = 1;
    var job2 = proc.Job.create();
    defer job2.close();
    req.job = &job2;
    const o2 = try sandboxRun(&f, req);
    try expectHas(o2.text, "time limit reached");
    try expectNoneLeft(&job2, marker);
}

/// Nothing of the command is left: on Windows its job is empty; on Linux
/// and macOS no process has `marker` in its command line.
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
    std.debug.print("a process with {s} in its command line was still there 2 s after the command ended:\n", .{marker});
    printProcessesWith(marker);
    return error.TestUnexpectedResult;
}

/// What a test failure shows: each process with `marker` in its command
/// line, with its parent, group and state.
fn printProcessesWith(marker: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    if (is_windows) return;
    const r = std.process.run(arena.allocator(), t.io, .{ .argv = &.{ "/bin/ps", "-axww", "-o", "pid=,ppid=,pgid=,stat=,command=" } }) catch return;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |l| if (std.mem.indexOf(u8, l, marker) != null) std.debug.print("  {s}\n", .{l});
}

fn anyProcessWith(marker: []const u8) !bool {
    if (is_macos) {
        // no /proc: ps (run here, outside any sandbox) lists every process
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const r = try std.process.run(arena.allocator(), t.io, .{ .argv = &.{ "/bin/ps", "-axww", "-o", "command=" } });
        return std.mem.indexOf(u8, r.stdout, marker) != null;
    }
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

test "linux_where_bwrap_cannot_make_a_sandbox_it_says_why" {
    if (!is_linux) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    // a bwrap that fails as one does under Ubuntu's user-namespace rule
    bwrap_override = "/bin/false";
    defer bwrap_override = null;
    const o = try f.run("echo should-not-run");
    try t.expect(o.is_error);
    try expectHas(o.text, "bubblewrap can't make a sandbox here");
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

test "the_macos_profile_shows_only_what_the_environment_says" {
    // the profile is text: checked on every system
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: MacPaths = .{
        .workspace = "/data/workspace",
        .mode = .ro,
        .home = "/data/state/env/box/home",
        .tmp = "/data/state/env/box/tmp",
        .read = &.{ "/opt/tools", "/Users/me/go" },
        .data = "/data",
        .owner_home = "/Users/me",
        .developer = "/Applications/Xcode.app",
    };
    const p = try macProfile(a, base);
    try t.expect(std.mem.startsWith(u8, p, "(version 1)\n(deny default)\n"));
    // the system's folders and programs, read-only
    try expectHas(p, "(subpath \"/usr\")");
    try expectHas(p, "(subpath \"/System\")");
    try expectHas(p, "(subpath \"/Applications/Xcode.app\")");
    // the workspace read-only: read and run, never write
    const ws_line = "(allow file-read* process-exec file-map-executable (subpath \"/data/workspace\"))";
    try expectHas(p, ws_line);
    try expectNot(p, "file-write* (subpath \"/data/workspace\")");
    // its home and its temp: read and write
    const own_line = "(allow file-read* file-write* process-exec file-map-executable (subpath \"/data/state/env/box/home\") (subpath \"/data/state/env/box/tmp\"))";
    try expectHas(p, own_line);
    // read = folders, read-only
    const read_line = "(allow file-read* process-exec file-map-executable (subpath \"/opt/tools\") (subpath \"/Users/me/go\"))";
    try expectHas(p, read_line);
    // the data folder never, even inside a read = folder: refused after
    // them, and the workspace and the home given back after that
    const data_line = "(deny file-read* file-write* process-exec (subpath \"/data\"))";
    try expectHas(p, data_line);
    const i_read = std.mem.indexOf(u8, p, read_line).?;
    const i_data = std.mem.indexOf(u8, p, data_line).?;
    try t.expect(i_read < i_data);
    try t.expect(i_data < std.mem.indexOf(u8, p, ws_line).?);
    try t.expect(i_data < std.mem.indexOf(u8, p, own_line).?);
    // the Keychain never: its services and its files, last
    try expectHas(p, "(global-name \"com.apple.SecurityServer\")");
    const kc = "(subpath \"/Users/me/Library/Keychains\")";
    try expectHas(p, kc);
    try t.expect(std.mem.indexOf(u8, p, kc).? > std.mem.indexOf(u8, p, own_line).?);
    // never the terminal
    try expectNot(p, "(allow file-read* (literal \"/dev/tty\"))");
    // Homebrew's services' data: refused before read = folders, which may
    // name it
    const brew = "(deny file-read* file-write* process-exec (subpath \"/opt/homebrew/var\") (subpath \"/usr/local/var\"))";
    try expectHas(p, brew);
    try t.expect(std.mem.indexOf(u8, p, brew).? < i_read);
    // network off: none, this machine included
    try expectHas(p, "(deny network*)");
    try expectNot(p, "(allow network-outbound");
    // on: outside hosts, never this machine (the deny after the allow)
    var with_net = base;
    with_net.network = true;
    const on = try macProfile(a, with_net);
    const out_any = "(allow network-outbound (remote ip \"*:*\"))";
    const not_here = "(deny network-outbound (remote ip \"localhost:*\"))";
    try expectHas(on, out_any);
    try expectHas(on, not_here);
    try t.expect(std.mem.indexOf(u8, on, out_any).? < std.mem.indexOf(u8, on, not_here).?);
    try expectNot(on, "(deny network*)");
    // read-write: the workspace written too
    var rw = base;
    rw.mode = .rw;
    try expectHas(try macProfile(a, rw), "(allow file-read* file-write* process-exec file-map-executable (subpath \"/data/workspace\"))");
    // none: not given, and refused even inside a read = folder
    var none = base;
    none.mode = .none;
    const n = try macProfile(a, none);
    try expectNot(n, "file-map-executable (subpath \"/data/workspace\")");
    try expectHas(n, "(deny file-read* file-write* process-exec (subpath \"/data/workspace\"))");
    // a workspace that holds the data folder doesn't give it back; its
    // home and temp, inside it, are given after that
    var wide = rw;
    wide.workspace = "/Users/me";
    wide.data = "/Users/me/.local/share/harness";
    wide.home = "/Users/me/.local/share/harness/state/env/box/home";
    const w = try macProfile(a, wide);
    const again = "(deny file-read* file-write* process-exec (subpath \"/Users/me/.local/share/harness\"))";
    const i_ws = std.mem.indexOf(u8, w, "(allow file-read* file-write* process-exec file-map-executable (subpath \"/Users/me\"))").?;
    // refused after the read = folders, and again after the workspace
    if (std.mem.count(u8, w, again) != 2) {
        std.debug.print("expected {s} twice in:\n{s}\n", .{ again, w });
        return error.TestExpectedEqual;
    }
    const i_again = std.mem.lastIndexOf(u8, w, again).?;
    try t.expect(i_ws < i_again);
    try t.expect(i_again < std.mem.indexOf(u8, w, "(subpath \"/Users/me/.local/share/harness/state/env/box/home\")").?);
    // the usual layout (the workspace in the data folder) has it once
    try t.expectEqual(1, std.mem.count(u8, try macProfile(a, rw), "(subpath \"/data\")"));
}

test "a_path_cannot_break_out_of_the_profile" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    // quoted: a " or \ inside is escaped, a ) is just a character
    const q = try macProfile(arena.allocator(), .{ .workspace = "/w/a\"b\\c)d", .home = "/h", .tmp = "/t" });
    try expectHas(q, "(subpath \"/w/a\\\"b\\\\c)d\")");
    if (!is_macos) return;
    // a workspace whose name tries to give the sandbox the whole disk
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    const a = f.a;
    const odd = "data/ws\") (allow file-read* (subpath \"/\")) (\\ \"x)";
    try f.tmp.dir.createDirPath(t.io, odd);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = odd ++ "/a.txt", .data = "in the odd workspace\n" });
    var req = f.request("");
    req.workspace = try std.fs.path.join(a, &.{ f.root, odd });
    req.command = try readCmd(a, try std.fs.path.join(a, &.{ req.workspace, "a.txt" }));
    const inside = try sandboxRun(&f, req);
    try expectOk(inside);
    try expectHas(inside.text, "in the odd workspace");
    // and the rest of the disk is still refused
    req.command = try readCmd(a, try std.fs.path.join(a, &.{ f.data, "rules" }));
    const rules = try sandboxRun(&f, req);
    try t.expect(rules.is_error);
    try expectNot(rules.text, "allow shell");
}

test "macos_sandbox_cannot_reach_the_keychain" {
    if (!is_macos) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    const a = f.a;
    // a keychain of the test's own, never the owner's: in the workspace,
    // so the sandbox may read its file; what it may not is the Keychain's
    // services, which alone open it
    const kc = try std.fs.path.join(a, &.{ f.ws, "probe.keychain" });
    var rnd: [12]u8 = undefined;
    t.io.random(&rnd);
    const pass = try std.fmt.allocPrint(a, "{s}", .{&std.fmt.bytesToHex(rnd, .lower)});
    t.io.random(&rnd);
    const value = try std.fmt.allocPrint(a, "{s}", .{&std.fmt.bytesToHex(rnd, .lower)});
    const service = "harness-sandbox-probe";
    try security(a, &.{ "create-keychain", "-p", pass, kc });
    defer security(a, &.{ "delete-keychain", kc }) catch {};
    try security(a, &.{ "add-generic-password", "-s", service, "-a", "probe", "-w", value, kc });
    // outside the sandbox the item is there (its attributes; never its value)
    try security(a, &.{ "find-generic-password", "-s", service, kc });
    // inside, not
    const o = try f.run(try std.fmt.allocPrint(a, "security find-generic-password -s {s} '{s}'", .{ service, kc }));
    try t.expect(o.is_error);
    try expectNot(o.text, "\"acct\"");
    try expectNot(o.text, value);
    // nor the owner's keychains
    const list = try f.run("security list-keychains");
    try t.expect(list.is_error);
    try expectNot(list.text, "login.keychain");
}

/// Runs `security ARGS` outside any sandbox; an error unless it exits 0.
/// What it prints is not shown: it may name the owner's keychains.
fn security(a: std.mem.Allocator, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "/usr/bin/security");
    try argv.appendSlice(a, args);
    const r = try std.process.run(a, t.io, .{ .argv = argv.items });
    if (!(r.term == .exited and r.term.exited == 0)) {
        std.debug.print("security {s} failed\n", .{args[0]});
        return error.TestUnexpectedResult;
    }
}

test "macos_without_sandbox_exec_refuses_plainly" {
    if (!is_macos) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    sandbox_exec_override = "/nonexistent/sandbox-exec";
    defer sandbox_exec_override = null;
    const o = try f.run("echo should-not-run");
    try t.expect(o.is_error);
    try expectHas(o.text, "sandbox-exec");
    try expectNot(o.text, "should-not-run");
}

test "macos_where_sandbox_exec_cannot_make_a_sandbox_it_says_why" {
    if (!is_macos) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    // one that fails, as sandbox-exec does inside another sandbox
    sandbox_exec_override = "/usr/bin/false";
    defer sandbox_exec_override = null;
    const o = try f.run("echo should-not-run");
    try t.expect(o.is_error);
    try expectHas(o.text, "sandbox-exec can't make a sandbox here");
    try expectNot(o.text, "should-not-run");
}

test "sandbox_changes_files_the_owner_made" {
    var f: Fix = undefined;
    try f.init(.{ .name = "box", .line = 1, .kind = .sandbox });
    defer f.deinit();
    try need(&f);
    // a.txt was made outside the sandbox
    try expectOk(try f.run(if (is_windows) "echo changed> a.txt" else "echo changed > a.txt"));
    try expectHas((try f.run(if (is_windows) "type a.txt" else "cat a.txt")).text, "changed");
    if (is_windows) {
        // cmd's own commands ask a path's drive what file system it has:
        // the workspace is a drive of the sandbox's own, so they work
        // (and what cmd starts sees that drive too: another cmd, a program)
        try expectHas((try f.run("cd")).text, ":\\");
        try expectHas((try f.run("cmd /c dir /b")).text, "a.txt");
        try expectHas((try f.run("findstr changed a.txt")).text, "changed");
        try expectHas((try f.run("more a.txt")).text, "changed");
        try expectHas((try f.run("dir /b")).text, "a.txt");
        try expectOk(try f.run("copy a.txt b.txt"));
        try expectOk(try f.run("ren b.txt c.txt"));
        try expectOk(try f.run("md moved && move c.txt moved && cd /d moved && dir /b"));
        try expectHas((try f.run("dir /b moved")).text, "c.txt");
        try expectOk(try f.run("del a.txt"));
        try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "data/workspace/a.txt", .{}));
        _ = try f.tmp.dir.statFile(t.io, "data/workspace/moved/c.txt", .{});
        // in its home and its temporary folder too (a drive of their own)
        try expectOk(try f.run("echo t> \"%TEMP%\\t.txt\" && dir /b \"%TEMP%\" && del \"%TEMP%\\t.txt\""));
        try expectOk(try f.run("cd /d \"%USERPROFILE%\" && echo h> h.txt && ren h.txt i.txt && del i.txt"));
        // a drive's root lists, the home's too
        try expectOk(try f.run("dir W:\\"));
        try expectOk(try f.run("dir \"%USERPROFILE%\""));
        // NUL opens where Windows lets app containers at it (Windows 11),
        // and not where it doesn't (Windows Server): as nulOpen says
        try t.expectEqual(nulOpen(), !(try f.run("echo x>nul")).is_error);
        // the real path still names the same files, for programs
        const real = try std.fmt.allocPrint(f.a, "type \"{s}\\moved\\c.txt\"", .{f.ws});
        try expectHas((try f.run(real)).text, "changed");
        // and it can't make a drive of its own, or reach a real drive's root
        try expectHas((try f.run("subst K: C:\\Windows & dir K:\\ 2>&1")).text, "cannot find");
        const drive = f.ws[0..2];
        try expectHas((try f.run(try std.fmt.allocPrint(f.a, "dir {s}\\ 2>&1", .{drive}))).text, "denied");
        return;
    }
    try expectOk(try f.run("rm a.txt"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "data/workspace/a.txt", .{}));
}
