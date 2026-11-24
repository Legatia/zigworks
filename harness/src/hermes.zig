//! A Hermes setup (github.com/NousResearch/hermes-agent, as of v0.23.4),
//! read for `harness import hermes`: where its home is, its keys' names
//! (and values, held only to mask them), `SOUL.md`, the memory files,
//! the skills with what Hermes knows of each (bundled, from its hub,
//! disabled), the cron jobs and the parts of `config.yaml` that map.
//! Nothing here writes; Hermes's files are only read.
const std = @import("std");
const builtin = @import("builtin");
const yaml = @import("yaml.zig");
const scrub = @import("scrub.zig");
const Io = std.Io;
const Map = std.process.Environ.Map;
const skills_mod = @import("skills.zig");

// ---- where the home is ----

/// The Hermes home read: its root (`HERMES_HOME` or the default), the
/// profile's own folder in it, and the profile's name.
pub const Home = struct { root: []const u8, dir: []const u8, profile: []const u8 };

/// Hermes's default root: `~/.hermes`, or `%LOCALAPPDATA%\hermes` on
/// Windows (`%USERPROFILE%\AppData\Local\hermes` without LOCALAPPDATA).
pub fn defaultRoot(a: std.mem.Allocator, env: *const Map, os: std.Target.Os.Tag) ?[]const u8 {
    if (os == .windows) {
        if (env.get("LOCALAPPDATA")) |l| if (std.mem.trim(u8, l, " ").len > 0) return std.fs.path.join(a, &.{ std.mem.trim(u8, l, " "), "hermes" }) catch null;
        const up = env.get("USERPROFILE") orelse return null;
        return std.fs.path.join(a, &.{ up, "AppData", "Local", "hermes" }) catch null;
    }
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fs.path.join(a, &.{ home, ".hermes" }) catch null;
}

fn isDir(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

/// A profile's name as Hermes makes them: letters, digits, `-`, `_`, `.`
/// (not first), at most 64.
fn validProfile(p: []const u8) bool {
    if (p.len == 0 or p.len > 64 or p[0] == '.' or p[0] == '-') return false;
    for (p) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

/// Finds the Hermes home: `from`, else HERMES_HOME, else the default; the
/// profile `profile` names ("default" is the root), else the one in
/// `active_profile`, as plain `hermes` does. A HERMES_HOME that is a
/// profile's folder (`…/profiles/NAME`) is that profile.
pub fn locate(io: Io, a: std.mem.Allocator, env: *const Map, from: ?[]const u8, profile: ?[]const u8) !Home {
    const root = from orelse blk: {
        if (env.get("HERMES_HOME")) |h| {
            const x = std.mem.trim(u8, h, " ");
            if (x.len > 0) break :blk x;
        }
        break :blk defaultRoot(a, env, builtin.os.tag) orelse return error.NoHermes;
    };
    if (!isDir(io, root)) return error.NoHermes;
    if (profile) |p| {
        if (std.mem.eql(u8, p, "default")) return .{ .root = root, .dir = root, .profile = "default" };
        if (!validProfile(p)) return error.NoProfile;
        const d = try std.fs.path.join(a, &.{ root, "profiles", p });
        if (!isDir(io, d)) return error.NoProfile;
        return .{ .root = root, .dir = d, .profile = p };
    }
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    if (std.fs.path.dirname(trimmed)) |parent| if (std.mem.eql(u8, std.fs.path.basename(parent), "profiles"))
        return .{ .root = std.fs.path.dirname(parent) orelse root, .dir = root, .profile = std.fs.path.basename(trimmed) };
    const ap = try std.fs.path.join(a, &.{ root, "active_profile" });
    const raw = Io.Dir.cwd().readFileAlloc(io, ap, a, .limited(4096)) catch "";
    const active = std.mem.trim(u8, raw, " \t\r\n");
    if (active.len == 0 or std.mem.eql(u8, active, "default")) return .{ .root = root, .dir = root, .profile = "default" };
    if (!validProfile(active)) return error.NoProfile;
    const d = try std.fs.path.join(a, &.{ root, "profiles", active });
    if (!isDir(io, d)) return error.NoProfile;
    return .{ .root = root, .dir = d, .profile = active };
}

// ---- what is in it ----

pub const EnvLine = struct { name: []const u8, value: []const u8, line: usize };
pub const KV = struct { name: []const u8, value: []const u8 };
pub const MemEntry = struct { file: enum { memory, user }, text: []const u8 };

pub const FileInfo = struct {
    /// Path in the skill's folder, with `/`.
    rel: []const u8,
    size: u64,
    exec: bool = false,
    /// A link: never followed or copied.
    link: bool = false,
};

pub const Bundled = struct {
    /// Its files differ from what Hermes put there.
    edited: bool,
    /// The manifest has its hash (an old manifest has names alone).
    known: bool,
};
pub const Hub = struct { source: []const u8, identifier: []const u8 };

pub const SkillDir = struct {
    /// Its folder under skills/, with `/` (`research/arxiv`).
    rel: []const u8,
    /// The folder it sits in (`research`), or "".
    category: []const u8,
    /// Its folder's full path.
    folder: []const u8,
    /// Hermes's name for it: its frontmatter's `name`, else its folder's.
    name: []const u8,
    /// SKILL.md's text, when it is within harness's 64 KB.
    skill_md: []const u8,
    skill_md_bytes: u64,
    files: []const FileInfo,
    bytes: u64,
    bundled: ?Bundled = null,
    hub: ?Hub = null,
    disabled: bool = false,
};

pub const Schedule = struct {
    kind: Kind,
    minutes: ?i64 = null,
    expr: []const u8 = "",
    run_at: []const u8 = "",
    display: []const u8 = "",
    pub const Kind = enum { once, interval, cron, other };
};

pub const Job = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    prompt: []const u8 = "",
    skills: []const []const u8 = &.{},
    schedule: Schedule = .{ .kind = .other },
    enabled: bool = true,
    /// `deliver` as written; null when there is none (Hermes's "local").
    deliver_text: ?[]const u8 = null,
    repeat_times: ?i64 = null,
    /// Runs so far (`repeat.completed`).
    repeat_done: i64 = 0,
    model: []const u8 = "",
    provider: []const u8 = "",
    base_url: []const u8 = "",
    workdir: []const u8 = "",
    script: []const u8 = "",
    no_agent: bool = false,
    /// `enabled_toolsets` is given.
    toolsets: bool = false,
    timezone: []const u8 = "",
    /// The keys it has that don't come over: context_from, continuity, …
    others: []const []const u8 = &.{},
};

pub const Model = struct { provider: []const u8 = "", name: []const u8 = "", base_url: []const u8 = "", api_key: []const u8 = "", api_mode: []const u8 = "", key_env: []const u8 = "", line: usize = 0 };
pub const Provider = struct {
    name: []const u8,
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    key_env: []const u8 = "",
    api_mode: []const u8 = "",
    model: []const u8 = "",
    enabled: bool = true,
    line: usize = 0,
};
pub const Mcp = struct {
    name: []const u8,
    line: usize = 0,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const KV = &.{},
    url: []const u8 = "",
    headers: []const KV = &.{},
    auth: []const u8 = "",
    transport: []const u8 = "",
    include: ?[]const []const u8 = null,
    exclude: []const []const u8 = &.{},
    enabled: bool = true,
    /// Why it can't come over as it is read (args or env that are not plain values).
    problem: ?[]const u8 = null,
};
/// A top-level key of config.yaml that didn't read, and the line.
pub const Problem = struct { key: []const u8, line: usize };

pub const Config = struct {
    model: Model = .{},
    providers: []const Provider = &.{},
    mcp: []const Mcp = &.{},
    deny: []const []const u8 = &.{},
    allowlist: []const []const u8 = &.{},
    disabled: []const []const u8 = &.{},
    external_dirs: []const []const u8 = &.{},
    skill_config: []const KV = &.{},
    timezone: []const u8 = "",
    memory_provider: []const u8 = "",
    problems: []const Problem = &.{},
};

/// A part of Hermes that stays where it is, and where it is (a path in
/// the home, or the file that names it).
pub const Other = struct { what: []const u8, rel: []const u8 };

pub const Setup = struct {
    home: Home,
    env: []const EnvLine = &.{},
    has_config: bool = false,
    config: Config = .{},
    soul: ?[]const u8 = null,
    memory: []const MemEntry = &.{},
    skills: []const SkillDir = &.{},
    jobs: []const Job = &.{},
    /// Why `cron/jobs.json` didn't read, when it didn't.
    jobs_problem: ?[]const u8 = null,
    others: []const Other = &.{},
    /// Every key value found (`.env`, literal keys in config.yaml), to mask
    /// them wherever they turn up; never written or printed.
    secrets: []const scrub.Secret = &.{},
};

fn readOpt(io: Io, a: std.mem.Allocator, dir: []const u8, rel: []const []const u8, max: usize) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(a, dir);
    try parts.appendSlice(a, rel);
    const p = try std.fs.path.join(a, parts.items);
    return Io.Dir.cwd().readFileAlloc(io, p, a, .limited(max)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => null,
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// Reads the profile's folder: what `harness import hermes` may bring over.
pub fn read(io: Io, a: std.mem.Allocator, home: Home) !Setup {
    var s: Setup = .{ .home = home };
    var secrets: std.ArrayList(scrub.Secret) = .empty;
    if (try readOpt(io, a, home.dir, &.{".env"}, 1 << 20)) |text| {
        s.env = try parseEnv(a, text);
        for (s.env) |e| if (maskable(e.name, e.value)) try secrets.append(a, .{ .name = e.name, .value = e.value });
    }
    if (try readOpt(io, a, home.dir, &.{"config.yaml"}, 4 << 20)) |text| {
        s.has_config = true;
        s.config = try readConfig(a, text);
        try configSecrets(a, s.config, &secrets);
    }
    if (try readOpt(io, a, home.dir, &.{"SOUL.md"}, 1 << 20)) |text| s.soul = text;
    var mem: std.ArrayList(MemEntry) = .empty;
    inline for (.{ .{ "MEMORY.md", .memory }, .{ "USER.md", .user } }) |m| {
        if (try readOpt(io, a, home.dir, &.{ "memories", m[0] }, 1 << 20)) |text| {
            for (try splitEntries(a, text)) |e| try mem.append(a, .{ .file = m[1], .text = e });
        }
    }
    s.memory = mem.items;
    s.skills = try readSkills(io, a, home.dir, s.config.disabled);
    if (try readOpt(io, a, home.dir, &.{ "cron", "jobs.json" }, 16 << 20)) |text| {
        s.jobs = parseJobs(a, text) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => blk: {
                s.jobs_problem = "cron/jobs.json doesn't read as Hermes writes it";
                break :blk &.{};
            },
        };
    }
    s.others = try readOthers(io, a, home.dir, s.config);
    s.secrets = secrets.items;
    return s;
}

/// The parts that stay in Hermes, when they hold something.
fn readOthers(io: Io, a: std.mem.Allocator, dir: []const u8, cfg: Config) ![]const Other {
    var out: std.ArrayList(Other) = .empty;
    const items = [_][2][]const u8{
        .{ "conversations", "state.db" },
        .{ "conversation files", "sessions" },
        .{ "plugins", "plugins" },
        .{ "pairing data", "pairing" },
        .{ "pairing data", "platforms" ++ std.fs.path.sep_str ++ "pairing" },
        .{ "kanban", "kanban.db" },
        .{ "kanban", "kanban" },
        .{ "plans", "plans" },
        .{ "skins", "skins" },
        .{ "workspace", "workspace" },
    };
    for (items) |it| {
        const p = try std.fs.path.join(a, &.{ dir, it[1] });
        const st = Io.Dir.cwd().statFile(io, p, .{}) catch continue;
        if (st.kind == .directory and !hasEntries(io, p)) continue;
        try out.append(a, .{ .what = it[0], .rel = it[1] });
    }
    if (cfg.memory_provider.len > 0) try out.append(a, .{ .what = try std.fmt.allocPrint(a, "external memory, {s}", .{cfg.memory_provider}), .rel = "config.yaml" });
    return out.items;
}

fn hasEntries(io: Io, p: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    return (it.next(io) catch null) != null;
}

// ---- .env ----

/// `.env`'s `NAME=VALUE` lines (`export` before, quotes, ` #` comments,
/// `\r\n`); other lines are left out.
pub fn parseEnv(a: std.mem.Allocator, text: []const u8) ![]const EnvLine {
    var out: std.ArrayList(EnvLine) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        if (!envName(name)) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len > 0 and (value[0] == '"' or value[0] == '\'')) {
            const close = std.mem.indexOfScalarPos(u8, value, 1, value[0]) orelse value.len;
            value = value[1..close];
        } else if (std.mem.indexOf(u8, value, " #")) |c| value = std.mem.trimEnd(u8, value[0..c], " \t");
        try out.append(a, .{ .name = name, .value = value, .line = n });
    }
    return out.items;
}

fn envName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// NAME when `value` is a `${NAME}` reference and nothing else.
pub fn envRef(value: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len < 4 or !std.mem.startsWith(u8, v, "${") or v[v.len - 1] != '}') return null;
    const name = v[2 .. v.len - 1];
    return if (envName(name)) name else null;
}

/// NAME of the first `${NAME}` in `value` (`Bearer ${TOKEN}`).
pub fn envRefIn(value: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, value, "${") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, value, start, '}') orelse return null;
    const name = value[start + 2 .. end];
    return if (envName(name)) name else null;
}

/// Names that hold no secret by Hermes's own rule (`_URL`, `_HOST`, …).
fn plainName(name: []const u8) bool {
    for ([_][]const u8{ "_URL", "_HOST", "_USER", "_ID", "_DOMAIN", "_SCHEME", "_USERS", "_MODEL", "_DIR", "_PATH" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

/// Whether a value read from `.env` or config.yaml is masked: long enough
/// not to match ordinary words (harness keeps no secret under 8), and
/// not under a name that says it is plain.
fn maskable(name: []const u8, value: []const u8) bool {
    return value.len >= 8 and envRef(value) == null and !plainName(name);
}

/// Whether a variable given under `name` holds a secret, by the import's
/// test: its name says so (TOKEN, KEY, SECRET, PASSWORD, PASSWD, PASS,
/// PWD, AUTH, CREDENTIAL, PRIVATE, COOKIE, SESSION, BEARER, JWT), or its
/// value looks like a key (a known prefix, or 24 or more letters and
/// digits without spaces). A `${VAR}` reference is always one.
pub fn looksSecret(name: []const u8, value: []const u8) bool {
    if (envRefIn(value) != null) return true;
    for ([_][]const u8{ "token", "key", "secret", "password", "passwd", "pass", "pwd", "auth", "credential", "private", "cookie", "session", "bearer", "jwt" }) |w| {
        if (std.ascii.findIgnoreCase(name, w) != null) return true;
    }
    const v = std.mem.trim(u8, value, " \t");
    for ([_][]const u8{ "sk-", "sk_", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "xoxb-", "xoxp-", "xoxa-", "glpat-", "AKIA", "AIza", "ya29.", "eyJ" }) |pre| {
        if (std.mem.startsWith(u8, v, pre)) return true;
    }
    if (v.len < 24) return false;
    var letters = false;
    var digits = false;
    for (v) |c| {
        if (std.ascii.isAlphabetic(c)) letters = true else if (std.ascii.isDigit(c)) digits = true else if (std.mem.indexOfScalar(u8, "-_.=+", c) == null) return false;
    }
    return letters and digits;
}

fn configSecrets(a: std.mem.Allocator, cfg: Config, out: *std.ArrayList(scrub.Secret)) !void {
    if (maskable("api_key", cfg.model.api_key)) try out.append(a, .{ .name = "model.api_key", .value = cfg.model.api_key });
    for (cfg.providers) |p| if (maskable("api_key", p.api_key)) try out.append(a, .{ .name = try std.fmt.allocPrint(a, "providers.{s}.api_key", .{p.name}), .value = p.api_key });
    for (cfg.mcp) |m| {
        for (m.env) |e| if (looksSecret(e.name, e.value) and maskable(e.name, e.value)) try out.append(a, .{ .name = try std.fmt.allocPrint(a, "mcp_servers.{s}.env.{s}", .{ m.name, e.name }), .value = e.value });
        for (m.headers) |h| {
            var v = h.value;
            if (std.ascii.startsWithIgnoreCase(v, "bearer ")) v = std.mem.trim(u8, v["bearer ".len..], " ");
            if (looksSecret(h.name, v) and maskable(h.name, v)) try out.append(a, .{ .name = try std.fmt.allocPrint(a, "mcp_servers.{s}.headers.{s}", .{ m.name, h.name }), .value = v });
        }
    }
}

// ---- memory and SOUL.md ----

/// A memory file's entries: split on a `§` line, each trimmed, empty ones
/// dropped (`\r\n` read as `\n`).
pub fn splitEntries(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const norm = try std.mem.replaceOwned(u8, a, text, "\r\n", "\n");
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, norm, "\n§\n");
    while (it.next()) |e| {
        const x = std.mem.trim(u8, e, " \t\r\n");
        if (x.len > 0) try out.append(a, x);
    }
    return out.items;
}

/// SHA-256 of the SOUL.md texts Hermes writes itself, normalized as Hermes
/// does (line ends, a BOM, spaces around): the current default, its
/// ASCII-dashed copy, the earlier default, and two comment scaffolds.
const stock_souls = [_][]const u8{
    "36c1f5a2e92cd1d018311eaf4c8f1e8886672eae78212e033c681d0e3d5d506f",
    "731f9a403cdc6a5c5c0e5c956a9238f54dae8b6e253bc29f9e47efb38eb6081a",
    "2765a846e1bb371d78d3b93b403dfb0f8d1ba1a9895edb5f608367abfe81194d",
    "82fa3438d86f8b95c6e96be89d853c8b561b3e6973ed61c90e70e0231dd24a7e",
    "6bc146a50e8fe3bd555e89a77e93af1f781cece8cf549f0d7a02ee2389811c72",
};

/// Whether SOUL.md is one Hermes wrote and nobody changed.
pub fn isStockSoul(text: []const u8) bool {
    var buf: [8192]u8 = undefined;
    if (text.len > buf.len) return false;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            buf[n] = '\n';
            n += 1;
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            continue;
        }
        buf[n] = text[i];
        n += 1;
    }
    var norm = std.mem.trimStart(u8, buf[0..n], "\xEF\xBB\xBF");
    norm = std.mem.trim(u8, norm, " \t\n\x0b\x0c");
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(norm, &h, .{});
    const hex = std.fmt.bytesToHex(h, .lower);
    for (stock_souls) |s| if (std.mem.eql(u8, s, &hex)) return true;
    return false;
}

// ---- cron/jobs.json ----

fn jstr(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        else => "",
    };
}

fn jint(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jtrue(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => false,
    };
}

fn jgiven(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .null => false,
        .string => |s| s.len > 0,
        .array => |l| l.items.len > 0,
        .object => |o| o.count() > 0,
        .bool => |b| b,
        else => true,
    };
}

/// `cron/jobs.json`: `{"jobs":[…]}` (or a bare list), each job's fields
/// as Hermes stores them; fields it doesn't know are left.
pub fn parseJobs(a: std.mem.Allocator, text: []const u8) ![]const Job {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.BadJobs;
    const list = switch (root) {
        .array => |l| l.items,
        .object => |o| switch (o.get("jobs") orelse return error.BadJobs) {
            .array => |l| l.items,
            else => return error.BadJobs,
        },
        else => return error.BadJobs,
    };
    var out: std.ArrayList(Job) = .empty;
    for (list) |item| {
        if (item != .object) continue;
        const o = item.object;
        var j: Job = .{
            .id = jstr(o.get("id")),
            .name = jstr(o.get("name")),
            .prompt = jstr(o.get("prompt")),
            .model = jstr(o.get("model")),
            .provider = jstr(o.get("provider")),
            .base_url = jstr(o.get("base_url")),
            .workdir = jstr(o.get("workdir")),
            .script = jstr(o.get("script")),
            .no_agent = jtrue(o.get("no_agent")),
            .toolsets = jgiven(o.get("enabled_toolsets")),
            .timezone = jstr(o.get("timezone")),
        };
        if (o.get("enabled")) |e| if (e == .bool and !e.bool) {
            j.enabled = false;
        };
        if (std.mem.eql(u8, jstr(o.get("state")), "paused")) j.enabled = false;
        // `skills`, else the older single `skill`
        var skills: std.ArrayList([]const u8) = .empty;
        if (o.get("skills")) |sv| if (sv == .array) for (sv.array.items) |x| if (x == .string and x.string.len > 0) try skills.append(a, x.string);
        if (skills.items.len == 0 and jstr(o.get("skill")).len > 0) try skills.append(a, jstr(o.get("skill")));
        j.skills = skills.items;
        if (o.get("schedule")) |sv| if (sv == .object) {
            const so = sv.object;
            const kind = jstr(so.get("kind"));
            j.schedule = .{
                .kind = std.meta.stringToEnum(Schedule.Kind, kind) orelse .other,
                .minutes = jint(so.get("minutes")),
                .expr = jstr(so.get("expr")),
                .run_at = jstr(so.get("run_at")),
                .display = jstr(so.get("display")),
            };
            if (j.schedule.kind == .other) j.schedule.display = if (kind.len > 0) kind else jstr(so.get("display"));
        };
        if (o.get("repeat")) |rv| if (rv == .object) {
            j.repeat_times = jint(rv.object.get("times"));
            j.repeat_done = jint(rv.object.get("completed")) orelse 0;
        };
        if (o.get("deliver")) |dv| switch (dv) {
            .string => |x| j.deliver_text = x,
            .array => |l| {
                var parts: std.ArrayList([]const u8) = .empty;
                for (l.items) |x| if (x == .string) try parts.append(a, x.string);
                j.deliver_text = try std.mem.join(a, ",", parts.items);
            },
            else => {},
        };
        var others: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "context_from", "continuity", "attach_to_session", "monitor_script", "monitor_url" }) |k| {
            if (jgiven(o.get(k))) try others.append(a, k);
        }
        j.others = others.items;
        try out.append(a, j);
    }
    return out.items;
}

// ---- config.yaml ----

fn ystr(v: ?yaml.Value) []const u8 {
    return yaml.str(v) orelse "";
}

/// A list of plain values (`[a, b]`, `- a`, or one value).
fn ylist(a: std.mem.Allocator, v: ?yaml.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try yaml.list(a, v)) |x| if (yaml.str(x)) |s| try out.append(a, s);
    return out.items;
}

/// The parts of config.yaml that map, each top-level key read apart: a
/// part that doesn't read is a `Problem` (its key and line), never guessed.
pub fn readConfig(a: std.mem.Allocator, text: []const u8) !Config {
    var c: Config = .{};
    var problems: std.ArrayList(Problem) = .empty;
    const wanted = [_][]const u8{ "model", "provider", "base_url", "providers", "custom_providers", "mcp_servers", "approvals", "command_allowlist", "skills", "timezone", "memory" };
    var doc: std.ArrayList(yaml.Entry) = .empty;
    for (try yaml.topBlocks(a, text)) |b| {
        const want = for (wanted) |w| {
            if (std.mem.eql(u8, w, b.key)) break true;
        } else false;
        if (!want) continue;
        var d: yaml.Diag = .{};
        const v = yaml.parseLines(a, text, b.first, b.last, &d) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.BadYaml => {
                try problems.append(a, .{ .key = b.key, .line = d.line });
                continue;
            },
        };
        if (v == .map) for (v.map) |e| try doc.append(a, e);
    }
    const root: yaml.Value = .{ .map = doc.items };
    // model: a string, or a map; older homes keep provider and base_url at the top
    if (yaml.get(root, "model")) |m| switch (m) {
        .str => |s| c.model.name = s.text,
        .map => {
            c.model.provider = ystr(yaml.get(m, "provider"));
            c.model.name = ystr(yaml.get(m, "default"));
            if (c.model.name.len == 0) c.model.name = ystr(yaml.get(m, "model"));
            if (c.model.name.len == 0) c.model.name = ystr(yaml.get(m, "name"));
            c.model.base_url = ystr(yaml.get(m, "base_url"));
            if (c.model.base_url.len == 0) c.model.base_url = ystr(yaml.get(m, "api_base"));
            c.model.api_key = ystr(yaml.get(m, "api_key"));
            c.model.api_mode = ystr(yaml.get(m, "api_mode"));
        },
        else => {},
    };
    c.model.line = yaml.lineOf(root, "model");
    if (c.model.provider.len == 0) c.model.provider = ystr(yaml.get(root, "provider"));
    if (c.model.base_url.len == 0) c.model.base_url = ystr(yaml.get(root, "base_url"));
    var providers: std.ArrayList(Provider) = .empty;
    if (yaml.get(root, "providers")) |pm| if (pm == .map) for (pm.map) |e| {
        try providers.append(a, try provider(e.key, e.value, e.line));
    };
    for (try yaml.list(a, yaml.get(root, "custom_providers"))) |item| {
        if (item != .map) continue;
        try providers.append(a, try provider(ystr(yaml.get(item, "name")), item, yaml.lineOf(item, "name")));
    }
    c.providers = providers.items;
    var servers: std.ArrayList(Mcp) = .empty;
    if (yaml.get(root, "mcp_servers")) |sm| if (sm == .map) for (sm.map) |e| {
        try servers.append(a, try mcpServer(a, e));
    };
    c.mcp = servers.items;
    c.deny = try ylist(a, yaml.get(yaml.get(root, "approvals"), "deny"));
    c.allowlist = try ylist(a, yaml.get(root, "command_allowlist"));
    const sk = yaml.get(root, "skills");
    c.disabled = try ylist(a, yaml.get(sk, "disabled"));
    c.external_dirs = try ylist(a, yaml.get(sk, "external_dirs"));
    var kv: std.ArrayList(KV) = .empty;
    try flatten(a, "", yaml.get(sk, "config"), &kv);
    c.skill_config = kv.items;
    c.timezone = ystr(yaml.get(root, "timezone"));
    c.memory_provider = ystr(yaml.get(yaml.get(root, "memory"), "provider"));
    c.problems = problems.items;
    return c;
}

fn provider(name: []const u8, v: yaml.Value, line: usize) !Provider {
    var p: Provider = .{ .name = name, .line = line };
    for ([_][]const u8{ "base_url", "url", "api" }) |k| if (p.base_url.len == 0) {
        p.base_url = ystr(yaml.get(v, k));
    };
    p.api_key = ystr(yaml.get(v, "api_key"));
    p.key_env = ystr(yaml.get(v, "key_env"));
    if (p.key_env.len == 0) p.key_env = ystr(yaml.get(v, "api_key_env"));
    p.api_mode = ystr(yaml.get(v, "api_mode"));
    if (p.api_mode.len == 0) p.api_mode = ystr(yaml.get(v, "transport"));
    p.model = ystr(yaml.get(v, "model"));
    if (p.model.len == 0) p.model = ystr(yaml.get(v, "default_model"));
    p.enabled = yaml.boolish(yaml.get(v, "enabled"), true);
    return p;
}

fn mcpServer(a: std.mem.Allocator, e: yaml.Entry) !Mcp {
    const v = e.value;
    var m: Mcp = .{ .name = e.key, .line = e.line };
    m.command = ystr(yaml.get(v, "command"));
    m.url = ystr(yaml.get(v, "url"));
    m.auth = ystr(yaml.get(v, "auth"));
    m.transport = ystr(yaml.get(v, "transport"));
    m.enabled = yaml.boolish(yaml.get(v, "enabled"), true) and !yaml.boolish(yaml.get(v, "disabled"), false);
    var args: std.ArrayList([]const u8) = .empty;
    for (try yaml.list(a, yaml.get(v, "args"))) |x| {
        if (yaml.str(x)) |s| try args.append(a, s) else m.problem = "its args are not plain values";
    }
    m.args = args.items;
    inline for (.{ .{ "env", "env" }, .{ "headers", "headers" } }) |f| {
        var kv: std.ArrayList(KV) = .empty;
        if (yaml.get(v, f[0])) |mv| if (mv == .map) for (mv.map) |x| {
            if (yaml.str(x.value)) |s| try kv.append(a, .{ .name = x.key, .value = s }) else m.problem = "its " ++ f[0] ++ " are not plain values";
        };
        @field(m, f[1]) = kv.items;
    }
    const tools = yaml.get(v, "tools");
    if (yaml.get(tools, "include")) |inc| if (inc != .null) {
        m.include = try ylist(a, inc);
    };
    m.exclude = try ylist(a, yaml.get(tools, "exclude"));
    return m;
}

/// `skills.config`'s settings as dotted names (`wiki.path`), lists joined.
fn flatten(a: std.mem.Allocator, prefix: []const u8, v: ?yaml.Value, out: *std.ArrayList(KV)) !void {
    const x = v orelse return;
    switch (x) {
        .map => |m| for (m) |e| {
            const name = if (prefix.len == 0) e.key else try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, e.key });
            try flatten(a, name, e.value, out);
        },
        .seq => |l| {
            var parts: std.ArrayList([]const u8) = .empty;
            for (l) |i| if (yaml.str(i)) |s| try parts.append(a, s);
            try out.append(a, .{ .name = prefix, .value = try std.mem.join(a, ", ", parts.items) });
        },
        .str => |s| try out.append(a, .{ .name = prefix, .value = s.text }),
        .null => try out.append(a, .{ .name = prefix, .value = "" }),
    }
}

// ---- skills ----

/// Folders Hermes never reads skills from.
const excluded_dirs = [_][]const u8{ ".git", ".github", ".hub", ".archive", ".curator_backups", ".locks", ".hermes-dist", ".venv", "venv", "node_modules", "site-packages", "__pycache__", ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache" };
/// Inside a skill: generated files, never copied.
const cache_dirs = [_][]const u8{ "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache" };

fn oneOf(x: []const u8, list: []const []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

fn readSkills(io: Io, a: std.mem.Allocator, dir: []const u8, disabled: []const []const u8) ![]const SkillDir {
    const root = try std.fs.path.join(a, &.{ dir, "skills" });
    var found: std.ArrayList(SkillDir) = .empty;
    try walkSkills(io, a, root, "", &found);
    std.mem.sort(SkillDir, found.items, {}, struct {
        fn lt(_: void, x: SkillDir, y: SkillDir) bool {
            return std.mem.lessThan(u8, x.rel, y.rel);
        }
    }.lt);
    // what Hermes's own files say of each
    var manifest: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (try readOpt(io, a, root, &.{".bundled_manifest"}, 1 << 20)) |text| {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r\xEF\xBB\xBF");
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            try manifest.put(a, std.mem.trim(u8, line[0..colon], " "), if (colon < line.len) std.mem.trim(u8, line[colon + 1 ..], " ") else "");
        }
    }
    var hub_entries: std.ArrayList(struct { name: []const u8, path: []const u8, hub: Hub }) = .empty;
    if (try readOpt(io, a, root, &.{ ".hub", "lock.json" }, 4 << 20)) |text| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})) |v| {
            if (v == .object) if (v.object.get("installed")) |inst| if (inst == .object) {
                var it = inst.object.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* != .object) continue;
                    const o = e.value_ptr.object;
                    const ip = std.mem.trim(u8, jstr(o.get("install_path")), "/");
                    try hub_entries.append(a, .{ .name = e.key_ptr.*, .path = ip, .hub = .{ .source = jstr(o.get("source")), .identifier = jstr(o.get("identifier")) } });
                }
            };
        } else |_| {}
    }
    for (found.items) |*sk| {
        if (manifest.get(sk.name)) |hash| {
            const known = hash.len > 0;
            var same = false;
            if (known) {
                const h1 = try bundledHash(io, a, sk.folder, false);
                const h2 = try bundledHash(io, a, sk.folder, true);
                same = std.ascii.eqlIgnoreCase(&h1, hash) or std.ascii.eqlIgnoreCase(&h2, hash);
            }
            sk.bundled = .{ .edited = known and !same, .known = known };
        }
        for (hub_entries.items) |h| if (std.mem.eql(u8, h.path, sk.rel)) {
            sk.hub = h.hub;
        };
        if (sk.hub == null) for (hub_entries.items) |h| if (std.mem.eql(u8, h.name, sk.name)) {
            sk.hub = h.hub;
        };
        sk.disabled = oneOf(sk.name, disabled);
    }
    return found.items;
}

/// Each folder holding a SKILL.md, below `root` (`rel` the path walked so
/// far); a skill's own subfolders hold no skills of their own here.
fn walkSkills(io: Io, a: std.mem.Allocator, root: []const u8, rel: []const u8, out: *std.ArrayList(SkillDir)) !void {
    const here = if (rel.len == 0) root else try std.fs.path.join(a, &.{ root, rel });
    var d = Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch return;
    defer d.close(io);
    if (rel.len > 0) if (d.statFile(io, "SKILL.md", .{})) |_| {
        try out.append(a, try skillAt(io, a, here, try slashes(a, rel)));
        return;
    } else |_| {};
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        if (oneOf(e.name, &excluded_dirs)) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    for (names.items) |n| try walkSkills(io, a, root, if (rel.len == 0) n else try std.fs.path.join(a, &.{ rel, n }), out);
}

fn slashes(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try a.dupe(u8, p);
    for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return out;
}

fn skillAt(io: Io, a: std.mem.Allocator, folder: []const u8, rel: []const u8) !SkillDir {
    var files: std.ArrayList(FileInfo) = .empty;
    try listFiles(io, a, folder, "", &files);
    std.mem.sort(FileInfo, files.items, {}, struct {
        fn lt(_: void, x: FileInfo, y: FileInfo) bool {
            return std.mem.lessThan(u8, x.rel, y.rel);
        }
    }.lt);
    var bytes: u64 = 0;
    var md_bytes: u64 = 0;
    for (files.items) |f| {
        bytes += f.size;
        if (std.mem.eql(u8, f.rel, "SKILL.md")) md_bytes = f.size;
    }
    const md_path = try std.fs.path.join(a, &.{ folder, "SKILL.md" });
    const md = if (md_bytes <= skills_mod.max_body) (Io.Dir.cwd().readFileAlloc(io, md_path, a, .limited(skills_mod.max_body + 1)) catch "") else "";
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
    const folder_name = if (slash) |i| rel[i + 1 ..] else rel;
    var name = folder_name;
    if (md.len > 0) if (skills_mod.readHeader(a, md)) |h| {
        for (h.fields) |f| if (!f.nested and std.mem.eql(u8, f.key, "name") and f.value.len > 0) {
            name = f.value;
        };
    } else |_| {};
    return .{
        .rel = rel,
        .category = if (slash) |i| rel[0..i] else "",
        .folder = folder,
        .name = name,
        .skill_md = md,
        .skill_md_bytes = md_bytes,
        .files = files.items,
        .bytes = bytes,
    };
}

fn listFiles(io: Io, a: std.mem.Allocator, folder: []const u8, rel: []const u8, out: *std.ArrayList(FileInfo)) !void {
    const here = if (rel.len == 0) folder else try std.fs.path.join(a, &.{ folder, rel });
    var d = Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const r = if (rel.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, e.name });
        switch (e.kind) {
            .directory => {
                if (oneOf(e.name, &cache_dirs) or oneOf(e.name, &.{ ".git", "node_modules", ".venv", "venv" })) continue;
                try listFiles(io, a, folder, r, out);
            },
            .file => {
                const st = d.statFile(io, e.name, .{}) catch continue;
                const exec = builtin.os.tag != .windows and st.permissions.toMode() & 0o111 != 0;
                try out.append(a, .{ .rel = r, .size = st.size, .exec = exec });
            },
            .sym_link => try out.append(a, .{ .rel = r, .size = 0, .link = true }),
            else => {},
        }
    }
}

/// Hermes's hash of a skill's folder (`dir_hash` in tools/skills_sync.py):
/// MD5 over each file's path (as Python writes it on this system) and
/// bytes, in the order of the paths' parts; generated caches left out
/// unless `with_cache` (the older hashes counted them).
pub fn bundledHash(io: Io, a: std.mem.Allocator, folder: []const u8, with_cache: bool) ![32]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try hashWalk(io, a, folder, "", with_cache, &all);
    std.mem.sort([]const u8, all.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return partsLess(x, y);
        }
    }.lt);
    var h = std.crypto.hash.Md5.init(.{});
    for (all.items) |rel| {
        const data = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ folder, rel }), a, .limited(64 << 20)) catch continue;
        h.update(rel);
        h.update(data);
    }
    var out: [16]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

fn hashWalk(io: Io, a: std.mem.Allocator, folder: []const u8, rel: []const u8, with_cache: bool, out: *std.ArrayList([]const u8)) !void {
    const here = if (rel.len == 0) folder else try std.fs.path.join(a, &.{ folder, rel });
    var d = Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    var py: std.StringHashMapUnmanaged(void) = .empty;
    var pyc: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |e| {
        const r = if (rel.len == 0) try a.dupe(u8, e.name) else try std.fs.path.join(a, &.{ rel, e.name });
        switch (e.kind) {
            .directory => {
                if (!with_cache and oneOf(e.name, &cache_dirs)) continue;
                try hashWalk(io, a, folder, r, with_cache, out);
            },
            .file, .sym_link => {
                if (e.kind == .sym_link) {
                    const st = d.statFile(io, e.name, .{}) catch continue;
                    if (st.kind != .file) continue;
                }
                if (std.mem.endsWith(u8, e.name, ".py")) try py.put(a, try a.dupe(u8, e.name[0 .. e.name.len - 3]), {});
                if (!with_cache and (std.mem.endsWith(u8, e.name, ".pyc") or std.mem.endsWith(u8, e.name, ".pyo"))) {
                    try pyc.append(a, r);
                    continue;
                }
                try out.append(a, r);
            },
            else => {},
        }
    }
    // bytecode beside its source is a cache; a .pyc alone is content
    for (pyc.items) |r| {
        const base = std.fs.path.basename(r);
        if (!py.contains(base[0 .. base.len - 4])) try out.append(a, r);
    }
}

/// Python's order of paths: by their parts, compared one by one (case
/// folded on Windows).
fn partsLess(x: []const u8, y: []const u8) bool {
    var xi = std.mem.splitScalar(u8, x, std.fs.path.sep);
    var yi = std.mem.splitScalar(u8, y, std.fs.path.sep);
    while (true) {
        const xp = xi.next() orelse return yi.next() != null;
        const yp = yi.next() orelse return false;
        const o = if (builtin.os.tag == .windows) std.ascii.orderIgnoreCase(xp, yp) else std.mem.order(u8, xp, yp);
        if (o != .eq) return o == .lt;
    }
}

// ---- tests and their fixture homes ----

const t = std.testing;

/// A Hermes home in a temporary folder, for the tests here and in
/// hermes_import.zig. Every key in it is an obvious fake (`sk-fixture-…`).
pub const Fixture = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// The folder holding the Hermes home (`hermes/`) and a harness home (`harness/`).
    base: []const u8,
    root: []const u8,

    pub fn init(f: *Fixture) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        try f.tmp.dir.createDirPath(t.io, "hermes");
        f.base = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.arena.allocator());
        f.root = try std.fs.path.join(f.arena.allocator(), &.{ f.base, "hermes" });
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    pub fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    /// Writes `data` at `rel` (with `/`) under the Hermes home.
    pub fn put(f: *Fixture, rel: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(f.a(), &.{ "hermes", rel });
        if (std.fs.path.dirname(p)) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = data });
    }

    /// `put`, every `\n` written as `\r\n` (a home edited on Windows).
    pub fn putCrlf(f: *Fixture, rel: []const u8, data: []const u8) !void {
        try f.put(rel, try std.mem.replaceOwned(u8, f.a(), data, "\n", "\r\n"));
    }

    pub fn path(f: *Fixture, rel: []const u8) []const u8 {
        return std.fs.path.join(f.a(), &.{ f.root, rel }) catch unreachable;
    }

    /// The secret values the full fixture holds: none may reach harness.
    pub const secrets = [_][]const u8{
        "sk-fixture-openrouter-0001",
        "ghp_fixture_github_0002",
        "123456:fixture-telegram-0003",
        "lin_fixture_linear_0004",
        "sk-fixture-local-0005",
        "sk-fixture-files-0006",
        "sk-fixture-weather-0007",
        "sk-fixture-workgw-0008",
    };

    /// Hermes's hash of the fixture's `arxiv` skill (computed with Python's
    /// pathlib on each system: Windows writes `\` and orders parts case-folded).
    pub const arxiv_hash = if (builtin.os.tag == .windows) "6476dfb171e3eda196813fd2351f2b9c" else "feaae2e88c3a3cdd9a8f3ae3b1ecd72f";
    pub const arxiv_hash_cache = if (builtin.os.tag == .windows) "1cbb125426a531507faea4f88ca0b10b" else "9bdb881448c187e1991a6b3c650499bf";

    /// A Hermes home with something of every kind.
    fn w(f: *Fixture, crlf: bool, rel: []const u8, data: []const u8) !void {
        return if (crlf) f.putCrlf(rel, data) else f.put(rel, data);
    }

    pub fn full(f: *Fixture, crlf: bool) !void {
        try f.w(crlf, ".env",
            \\# Hermes keys
            \\OPENROUTER_API_KEY=sk-fixture-openrouter-0001
            \\export GITHUB_TOKEN="ghp_fixture_github_0002"
            \\TELEGRAM_BOT_TOKEN=123456:fixture-telegram-0003
            \\TELEGRAM_ALLOWED_USERS=42
            \\LINEAR_API_KEY='lin_fixture_linear_0004'   # the team's
            \\WORK_GW_KEY=sk-fixture-workgw-0008
            \\API_SERVER_URL=https://hermes.example.com
            \\
        );
        try f.w(crlf, "config.yaml",
            \\model:
            \\  provider: openrouter
            \\  default: anthropic/claude-sonnet-4
            \\providers:
            \\  local-llm:
            \\    base_url: http://localhost:8080/v1
            \\    api_key: sk-fixture-local-0005
            \\    api_mode: chat_completions
            \\    default_model: qwen3:8b
            \\  codex:
            \\    base_url: https://codex.example.com/v1
            \\    api_mode: codex_responses
            \\custom_providers:
            \\  - name: work-gw
            \\    base_url: https://gw.example.com/anthropic
            \\    api_mode: anthropic_messages
            \\    key_env: WORK_GW_KEY
            \\timezone: Europe/Warsaw
            \\memory:
            \\  provider: honcho
            \\mcp_servers:
            \\  github:
            \\    command: npx
            \\    args: ["-y", "@modelcontextprotocol/server-github"]
            \\    env:
            \\      GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_TOKEN}
            \\      LOG_LEVEL: info
            \\    tools:
            \\      exclude: [delete_repository, "*_admin_?"]
            \\  files:
            \\    command: /opt/mcp/files
            \\    args:
            \\      - --root
            \\      - /home/me/My Documents
            \\    env:
            \\      FILES_SECRET: sk-fixture-files-0006
            \\  linear:
            \\    url: https://mcp.linear.app/mcp
            \\    headers:
            \\      Authorization: Bearer ${LINEAR_API_KEY}
            \\      X-Workspace: acme
            \\  notion:
            \\    url: https://mcp.notion.com/mcp
            \\    auth: oauth
            \\  weather:
            \\    url: https://weather.example.com/mcp
            \\    headers:
            \\      X-API-Key: sk-fixture-weather-0007
            \\  old-sse:
            \\    url: https://sse.example.com/sse
            \\    transport: sse
            \\  picky:
            \\    command: uvx picky-mcp
            \\    tools:
            \\      include: [read_*, search]
            \\  sleepy:
            \\    command: sleepy-mcp
            \\    enabled: false
            \\approvals:
            \\  deny:
            \\    - "rm -rf /*"
            \\    - "git push --force*"
            \\    - "curl ?ttp*"
            \\    - "shutdown [nr]*"
            \\command_allowlist:
            \\  - "git status*"
            \\  - recursive delete
            \\skills:
            \\  disabled: [noisy]
            \\  external_dirs: ["~/.agents/skills"]
            \\  config:
            \\    wiki:
            \\      path: ~/wiki
            \\plugins:
            \\  base: &b {x: 1}
            \\
        );
        try f.w(crlf, "SOUL.md", "Speak plainly. Use metric units.\n");
        try f.w(crlf, "memories/MEMORY.md", "Owner's server is at home.example.com.\n§\nUses Zig 0.17 for side projects.\n§\nThe staging key is sk-fixture-openrouter-0001, never share it.");
        try f.w(crlf, "memories/USER.md", "Lives in Kraków.\n§\nPrefers short answers.\n");
        // skills: a bundled one unedited (its manifest hash is Hermes's own,
        // computed with Python), one edited, a name harness can't take, a
        // disabled one, two from the hub, one too big, and things that are
        // no skills
        try f.w(crlf, "skills/.bundled_manifest", "arxiv:" ++ arxiv_hash ++ "\nedited-bundle:00000000000000000000000000000000\n");
        try f.put("skills/research/arxiv/SKILL.md", "---\nname: arxiv\ndescription: Search arXiv papers.\n---\nSearch arXiv.\n");
        try f.put("skills/research/arxiv/a-b.md", "dash\n");
        try f.put("skills/research/arxiv/a/x.md", "slash\n");
        try f.w(crlf, "skills/research/edited-bundle/SKILL.md", "---\nname: edited-bundle\ndescription: A bundled skill the owner changed.\n---\nMine now.\n");
        try f.w(crlf, "skills/devops/deploy.helper_v2/SKILL.md", "---\nname: deploy.helper_v2\ndescription: Deploy the site.\nplatforms: [linux, macos]\nrequired_environment_variables:\n  - name: DEPLOY_TOKEN\n---  \nRun scripts/run.sh.\n");
        try f.w(crlf, "skills/devops/deploy.helper_v2/scripts/run.sh", "#!/bin/sh\necho deploy\n");
        try f.w(crlf, "skills/devops/deploy.helper_v2/scripts/inner/SKILL.md", "---\nname: inner\ndescription: not a skill of its own\n---\n");
        try f.w(crlf, "skills/noisy/SKILL.md", "---\nname: noisy\ndescription: Too chatty.\n---\nx\n");
        try f.w(crlf, "skills/.hub/lock.json",
            \\{"version": 1, "installed": {
            \\  "pdf-tools": {"source": "github", "identifier": "anthropics/skills/skills/pdf", "trust_level": "trusted", "content_hash": "x", "install_path": "docs/pdf-tools", "files": ["SKILL.md"], "metadata": {"source_revision": "abc"}},
            \\  "claw": {"source": "clawhub", "identifier": "@x/claw", "install_path": "claw"}
            \\}}
        );
        try f.w(crlf, "skills/docs/pdf-tools/SKILL.md", "---\nname: pdf-tools\ndescription: Work with PDFs.\nlicense: Apache-2.0\n---\nUse pdftotext.\n");
        try f.w(crlf, "skills/claw/SKILL.md", "---\nname: claw\ndescription: From ClawHub.\n---\nx\n");
        const filler = try f.a().alloc(u8, 70 * 1024);
        @memset(filler, 'x');
        try f.put("skills/big/SKILL.md", try std.fmt.allocPrint(f.a(), "---\nname: big\ndescription: Too big.\n---\n{s}\n", .{filler}));
        try f.put("skills/.git/SKILL.md", "---\nname: git\ndescription: no\n---\n");
        try f.w(crlf, "cron/jobs.json",
            \\{"jobs": [
            \\ {"id": "a1", "name": "Morning brief", "prompt": "Summarise my unread mail and the weather.", "skills": ["arxiv"], "skill": "arxiv", "schedule": {"kind": "cron", "expr": "0 7 * * 1-5", "display": "weekdays at 7am"}, "repeat": {"times": null, "completed": 3}, "enabled": true, "state": "scheduled", "deliver": "origin", "origin": {"platform": "telegram", "chat_id": "42"}, "timezone": "Europe/Warsaw", "next_run_at": "2026-11-25T07:00:00+01:00"},
            \\ {"id": "a2", "name": "poll", "prompt": "Check the build ; report failures #ci", "schedule": {"kind": "interval", "minutes": 30, "display": "every 30m"}, "enabled": true, "deliver": "telegram:-100123:17", "repeat": {"times": 10, "completed": 0}, "model": "gpt-5"},
            \\ {"id": "a3", "name": "fast", "prompt": "ping", "schedule": {"kind": "interval", "minutes": 2}, "enabled": true, "deliver": "origin"},
            \\ {"id": "a4", "name": "once", "prompt": "Remind me about the dentist", "schedule": {"kind": "once", "run_at": "2026-12-01T09:00:00+01:00"}, "enabled": true, "deliver": "origin"},
            \\ {"id": "a5", "name": "queue", "prompt": "Look at the queue", "schedule": {"kind": "cron", "expr": "0 */4 * * *"}, "enabled": false, "deliver": "origin"},
            \\ {"id": "a6", "name": "odd", "prompt": "x", "schedule": {"kind": "cron", "expr": "*/15 9-17 * * *"}, "deliver": "origin"},
            \\ {"id": "a7", "name": "saver", "prompt": "Write a note", "schedule": {"kind": "interval", "minutes": 60}, "deliver": "local"},
            \\ {"id": "a8", "name": "backup", "prompt": "", "script": "backup.sh", "no_agent": true, "schedule": {"kind": "interval", "minutes": 60}},
            \\ {"id": "a9", "name": "weekly", "prompt": "Line one\nLine two", "schedule": {"kind": "cron", "expr": "30 0 * * 1"}, "deliver": "all", "timezone": "Asia/Tokyo", "workdir": "/tmp", "enabled_toolsets": ["web"], "context_from": ["a1"]},
            \\ {"id": "b1", "name": "discord only", "prompt": "Post the digest", "schedule": {"kind": "interval", "minutes": 120}, "deliver": "discord"}
            \\]}
        );
        try f.put("state.db", "SQLite format 3\x00");
        try f.put("sessions/s1.json", "{}");
        try f.put("plugins/x/plugin.yaml", "name: x\n");
    }
};

test "the_home_follows_active_profile_and_the_profile_flag" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a();
    try f.put("active_profile", "work\n");
    try f.put("config.yaml", "model: x\n");
    try f.put("profiles/work/config.yaml", "model: y\n");
    var env = Map.init(a);
    try env.put("HERMES_HOME", f.root);
    const work = try locate(t.io, a, &env, null, null);
    try t.expectEqualStrings("work", work.profile);
    try t.expectEqualStrings(f.path("profiles" ++ std.fs.path.sep_str ++ "work"), work.dir);
    const def = try locate(t.io, a, &env, null, "default");
    try t.expectEqualStrings("default", def.profile);
    try t.expectEqualStrings(f.root, def.dir);
    try t.expectError(error.NoProfile, locate(t.io, a, &env, null, "nope"));
    try t.expectError(error.NoProfile, locate(t.io, a, &env, null, "../x"));
    // HERMES_HOME naming a profile is that profile
    var env2 = Map.init(a);
    try env2.put("HERMES_HOME", f.path("profiles" ++ std.fs.path.sep_str ++ "work"));
    const direct = try locate(t.io, a, &env2, null, null);
    try t.expectEqualStrings("work", direct.profile);
    // --from wins over HERMES_HOME
    var empty = Map.init(a);
    const from = try locate(t.io, a, &empty, f.root, "default");
    try t.expectEqualStrings(f.root, from.dir);
    try t.expectError(error.NoHermes, locate(t.io, a, &empty, f.path("missing"), null));
    // an active_profile naming no profile
    try f.put("active_profile", "gone\n");
    try t.expectError(error.NoProfile, locate(t.io, a, &env, null, null));
}

test "the_default_home_on_each_system" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Map.init(a);
    try env.put("HOME", "/home/me");
    try env.put("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local");
    try env.put("USERPROFILE", "C:\\Users\\me");
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ "/home/me", ".hermes" }), defaultRoot(a, &env, .linux).?);
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ "C:\\Users\\me\\AppData\\Local", "hermes" }), defaultRoot(a, &env, .windows).?);
    var env2 = Map.init(a);
    try env2.put("USERPROFILE", "C:\\Users\\me");
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ "C:\\Users\\me", "AppData", "Local", "hermes" }), defaultRoot(a, &env2, .windows).?);
    try t.expect(defaultRoot(a, &env2, .macos) == null);
}

test "env_lines_names_and_values" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try parseEnv(a, "# c\r\nA=1\r\nexport B=\"two words\"\nC='x # y'  # note\nD = spaced \n\nnot a line\nE=\n");
    try t.expectEqual(5, lines.len);
    try t.expectEqualStrings("A", lines[0].name);
    try t.expectEqualStrings("1", lines[0].value);
    try t.expectEqualStrings("two words", lines[1].value);
    try t.expectEqualStrings("x # y", lines[2].value);
    try t.expectEqualStrings("D", lines[3].name);
    try t.expectEqualStrings("spaced", lines[3].value);
    try t.expectEqualStrings("", lines[4].value);
    try t.expectEqual(2, lines[0].line);
    try t.expectEqualStrings("GITHUB_TOKEN", envRef("${GITHUB_TOKEN}").?);
    try t.expectEqualStrings("X", envRef(" ${X} ").?);
    try t.expect(envRef("Bearer ${X}") == null);
    try t.expectEqualStrings("X", envRefIn("Bearer ${X}").?);
    try t.expect(envRef("$X") == null);
}

test "memory_entries_split_on_the_section_sign" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try splitEntries(a, "one\n§\ntwo\nlines\n§\n\n§\n  three  \r\n§\r\nfour § in text");
    try t.expectEqual(4, e.len);
    try t.expectEqualStrings("one", e[0]);
    try t.expectEqualStrings("two\nlines", e[1]);
    try t.expectEqualStrings("three", e[2]);
    try t.expectEqualStrings("four § in text", e[3]);
    try t.expectEqual(0, (try splitEntries(a, " \n")).len);
}

test "stock_souls_are_known" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expect(isStockSoul(stock_soul_for_tests));
    try t.expect(isStockSoul("\xEF\xBB\xBF" ++ stock_soul_for_tests ++ "\r\n"));
    // the ASCII-dashed copy Windows installs wrote
    try t.expect(isStockSoul(try std.mem.replaceOwned(u8, arena.allocator(), stock_soul_for_tests, "\u{2014}", "--")));
    try t.expect(isStockSoul(older_soul_for_tests));
    try t.expect(!isStockSoul(stock_soul_for_tests[0 .. stock_soul_for_tests.len - 1] ++ "!"));
    try t.expect(!isStockSoul("Speak plainly."));
}

test "jobs_read_every_schedule_kind" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.full(false);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, f.path("cron" ++ std.fs.path.sep_str ++ "jobs.json"), f.a(), .unlimited);
    const jobs = try parseJobs(f.a(), text);
    try t.expectEqual(10, jobs.len);
    try t.expectEqualStrings("Morning brief", jobs[0].name);
    try t.expectEqual(Schedule.Kind.cron, jobs[0].schedule.kind);
    try t.expectEqualStrings("0 7 * * 1-5", jobs[0].schedule.expr);
    try t.expectEqualStrings("arxiv", jobs[0].skills[0]);
    try t.expectEqualStrings("Europe/Warsaw", jobs[0].timezone);
    try t.expect(jobs[0].repeat_times == null);
    try t.expectEqual(Schedule.Kind.interval, jobs[1].schedule.kind);
    try t.expectEqual(@as(?i64, 30), jobs[1].schedule.minutes);
    try t.expectEqual(@as(?i64, 10), jobs[1].repeat_times);
    try t.expectEqualStrings("gpt-5", jobs[1].model);
    try t.expectEqual(Schedule.Kind.once, jobs[3].schedule.kind);
    try t.expect(!jobs[4].enabled);
    try t.expect(jobs[5].enabled);
    try t.expectEqualStrings("origin", jobs[5].deliver_text.?);
    try t.expect(jobs[7].deliver_text == null);
    try t.expect(jobs[7].no_agent);
    try t.expectEqualStrings("backup.sh", jobs[7].script);
    try t.expectEqualStrings("Line one\nLine two", jobs[8].prompt);
    try t.expectEqualStrings("/tmp", jobs[8].workdir);
    try t.expect(jobs[8].toolsets);
    try t.expectEqualStrings("context_from", jobs[8].others[0]);
    // a bare list reads too; unknown fields and kinds are kept as they are
    const bare = try parseJobs(f.a(), "[{\"name\":\"x\",\"prompt\":\"p\",\"schedule\":{\"kind\":\"weird\"},\"new_field\":1}]");
    try t.expectEqual(Schedule.Kind.other, bare[0].schedule.kind);
    try t.expectError(error.BadJobs, parseJobs(f.a(), "{\"jobs\": 3}"));
    try t.expectError(error.BadJobs, parseJobs(f.a(), "not json"));
}

test "skills_are_found_with_category_hub_and_bundled_facts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.full(false);
    const s = try read(t.io, f.a(), .{ .root = f.root, .dir = f.root, .profile = "default" });
    var names: std.ArrayList([]const u8) = .empty;
    for (s.skills) |sk| try names.append(f.a(), sk.name);
    const joined = try std.mem.join(f.a(), ",", names.items);
    // sorted by their path under skills/; .git and scripts/inner are no skills
    try t.expectEqualStrings("big,claw,deploy.helper_v2,pdf-tools,noisy,arxiv,edited-bundle", joined);
    const by = struct {
        fn name(list: []const SkillDir, n: []const u8) SkillDir {
            for (list) |x| if (std.mem.eql(u8, x.name, n)) return x;
            unreachable;
        }
    };
    const arxiv = by.name(s.skills, "arxiv");
    try t.expectEqualStrings("research", arxiv.category);
    try t.expect(arxiv.bundled != null and !arxiv.bundled.?.edited);
    try t.expect(by.name(s.skills, "edited-bundle").bundled.?.edited);
    try t.expect(by.name(s.skills, "deploy.helper_v2").bundled == null);
    try t.expectEqualStrings("github", by.name(s.skills, "pdf-tools").hub.?.source);
    try t.expectEqualStrings("anthropics/skills/skills/pdf", by.name(s.skills, "pdf-tools").hub.?.identifier);
    try t.expectEqualStrings("clawhub", by.name(s.skills, "claw").hub.?.source);
    try t.expect(by.name(s.skills, "noisy").disabled);
    try t.expect(by.name(s.skills, "big").skill_md_bytes > 64 * 1024);
    const deploy = by.name(s.skills, "deploy.helper_v2");
    try t.expectEqual(3, deploy.files.len);
    try t.expectEqualStrings("SKILL.md", deploy.files[0].rel);
    try t.expectEqualStrings("scripts/inner/SKILL.md", deploy.files[1].rel);
    try t.expectEqualStrings("scripts/run.sh", deploy.files[2].rel);
    // Hermes's own hash: the parts of the path in order, then the bytes
    try t.expectEqualStrings(Fixture.arxiv_hash, &(try bundledHash(t.io, f.a(), arxiv.folder, false)));
    try f.put("skills/research/arxiv/__pycache__/c.pyc", "cache");
    try t.expectEqualStrings(Fixture.arxiv_hash, &(try bundledHash(t.io, f.a(), arxiv.folder, false)));
    try t.expectEqualStrings(Fixture.arxiv_hash_cache, &(try bundledHash(t.io, f.a(), arxiv.folder, true)));
}

test "config_yaml_keys_are_read" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.full(true);
    const s = try read(t.io, f.a(), .{ .root = f.root, .dir = f.root, .profile = "default" });
    const c = s.config;
    try t.expectEqualStrings("openrouter", c.model.provider);
    try t.expectEqualStrings("anthropic/claude-sonnet-4", c.model.name);
    try t.expectEqual(3, c.providers.len);
    try t.expectEqualStrings("local-llm", c.providers[0].name);
    try t.expectEqualStrings("http://localhost:8080/v1", c.providers[0].base_url);
    try t.expectEqualStrings("qwen3:8b", c.providers[0].model);
    try t.expectEqualStrings("sk-fixture-local-0005", c.providers[0].api_key);
    try t.expectEqualStrings("work-gw", c.providers[2].name);
    try t.expectEqualStrings("WORK_GW_KEY", c.providers[2].key_env);
    try t.expectEqualStrings("anthropic_messages", c.providers[2].api_mode);
    try t.expectEqualStrings("Europe/Warsaw", c.timezone);
    try t.expectEqualStrings("honcho", c.memory_provider);
    try t.expectEqual(8, c.mcp.len);
    const gh = c.mcp[0];
    try t.expectEqualStrings("github", gh.name);
    try t.expectEqualStrings("npx", gh.command);
    try t.expectEqualStrings("@modelcontextprotocol/server-github", gh.args[1]);
    try t.expectEqualStrings("${GITHUB_TOKEN}", gh.env[0].value);
    try t.expectEqual(2, gh.exclude.len);
    try t.expect(gh.include == null);
    try t.expectEqualStrings("/home/me/My Documents", c.mcp[1].args[1]);
    try t.expectEqualStrings("Bearer ${LINEAR_API_KEY}", c.mcp[2].headers[0].value);
    try t.expectEqualStrings("oauth", c.mcp[3].auth);
    try t.expectEqualStrings("sse", c.mcp[5].transport);
    try t.expectEqual(2, c.mcp[6].include.?.len);
    try t.expect(!c.mcp[7].enabled);
    try t.expectEqual(4, c.deny.len);
    try t.expectEqual(2, c.allowlist.len);
    try t.expectEqualStrings("noisy", c.disabled[0]);
    try t.expectEqualStrings("~/.agents/skills", c.external_dirs[0]);
    try t.expectEqualStrings("wiki.path", c.skill_config[0].name);
    try t.expectEqualStrings("~/wiki", c.skill_config[0].value);
    try t.expectEqual(0, c.problems.len);
    // .env and the literal keys in config.yaml are held for masking
    for (Fixture.secrets) |v| {
        for (s.secrets) |x| {
            if (std.mem.eql(u8, x.value, v)) break;
        } else {
            std.debug.print("not held for masking: {s}\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
    // the other parts are named, with their paths
    var others: std.ArrayList(u8) = .empty;
    for (s.others) |o| try others.print(f.a(), "{s} ({s});", .{ o.what, o.rel });
    try t.expectEqualStrings("conversations (state.db);conversation files (sessions);plugins (plugins);external memory, honcho (config.yaml);", others.items);
    // an mcp_servers part that doesn't read stops only that part
    try f.put("config.yaml", "model: openrouter/x\nmcp_servers:\n  a:\n    command: &c x\napprovals:\n  deny: [\"rm *\"]\n");
    const bad = try read(t.io, f.a(), .{ .root = f.root, .dir = f.root, .profile = "default" });
    try t.expectEqual(1, bad.config.problems.len);
    try t.expectEqualStrings("mcp_servers", bad.config.problems[0].key);
    try t.expectEqual(4, bad.config.problems[0].line);
    try t.expectEqual(1, bad.config.deny.len);
    try t.expectEqualStrings("openrouter/x", bad.config.model.name);
}

/// Hermes's current stock SOUL.md (hermes_cli/default_soul.py, MIT), the
/// one text the tests need to recognise it by.
const stock_soul_for_tests = "You are Hermes Agent, built by Nous Research. Be direct: match the length of your reply to the weight of the ask \u{2014} a one-line question gets a one-line answer, and finished work gets a short report of what changed, what's verified, and what's left, never a replay of the process. No filler (\"Great question,\" \"I'd be happy to\"), no restating the request back, no re-summarizing what you already said, no narrating tool calls the user can see. Plain claims over adjectives; when unsure, say so plainly. Agree because it's right, not because the user said it. Depth is earned \u{2014} give it when the user asks for detail, teaches, or the stakes demand it, not by default.";
/// The default before it (same file, the earlier generation).
const older_soul_for_tests = "You are Hermes Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct. You assist users with a wide range of tasks including answering questions, writing and editing code, analyzing information, creative work, and executing actions via your tools. You communicate clearly, admit uncertainty when appropriate, and prioritize being genuinely useful over being verbose unless otherwise directed below. Be targeted and efficient in your exploration and investigations.";

/// Used by hermes_import.zig's tests.
pub const stock_soul = stock_soul_for_tests;
/// The names of Hermes's dangerous-command patterns (tools/approval_detection.py,
/// DANGEROUS_PATTERNS, v0.23.4, MIT): `command_allowlist` holds these for
/// "always" approvals; any other entry is a command or a command glob.
pub const pattern_names = [_][]const u8{
    "delete in root path",
    "recursive delete",
    "recursive delete (long flag)",
    "Windows cmd destructive delete",
    "Windows PowerShell destructive delete",
    "Windows PowerShell destructive delete (later in the script)",
    "PowerShell encoded command execution",
    "PowerShell destructive delete (Remove-Item)",
    "PowerShell destructive delete (alias after pipe)",
    "Windows destructive delete (recursive/quiet switch)",
    "pipe remote content to PowerShell (iwr | iex)",
    "execute remote content via Invoke-Expression",
    "force kill processes (taskkill /F)",
    "force kill processes (Stop-Process -Force)",
    "format filesystem (Format-Volume)",
    "wipe disk (Clear-Disk)",
    "disk partitioning (diskpart)",
    "format drive (format.com)",
    "wipe free space (cipher /w)",
    "grant Everyone access (icacls)",
    "reset ACLs recursively (icacls /reset)",
    "delete volume shadow copies (vssadmin)",
    "delete backups (wbadmin)",
    "modify boot configuration (bcdedit /set)",
    "registry delete (reg delete)",
    "registry value delete (Remove-ItemProperty -Force)",
    "registry write (reg add/import/copy/restore/load/unload)",
    "registry write (regedit /s silent .reg import)",
    "registry write (sp/ni/Set-Item/New-Item on a registry path)",
    "registry write (setx persistent environment variable)",
    "registry value write (Set-ItemProperty / New-ItemProperty)",
    "force stop service (Stop-Service -Force)",
    "stop/delete service (sc)",
    "access to SSH keys (Windows path)",
    "access to Hermes secrets (Windows path)",
    "world/other-writable permissions",
    "recursive world/other-writable (long flag)",
    "recursive chown to root",
    "recursive chown to root (long flag)",
    "format filesystem",
    "disk copy",
    "write to block device",
    "SQL DROP",
    "SQL DELETE without WHERE",
    "SQL TRUNCATE",
    "overwrite system config",
    "stop/restart system service",
    "kill all processes",
    "force kill processes",
    "force kill processes (killall -KILL)",
    "force kill processes (killall -s KILL)",
    "kill processes by regex (killall -r)",
    "fork bomb",
    "pipe remote content to shell",
    "execute remote script via process substitution",
    "execute remote content via command substitution",
    "reverse shell via netcat -e/-c",
    "reverse shell via socat EXEC:/SYSTEM:",
    "cloud metadata endpoint access (instance credentials)",
    "pipe decoded content to shell (possible command obfuscation)",
    "pipe xxd-decoded content to shell (possible command obfuscation)",
    "pipe tr-transformed output to shell (possible command obfuscation)",
    "pipe openssl-decoded content to shell (possible command obfuscation)",
    "pipe a credential file into a curl/wget upload (possible exfiltration)",
    "overwrite system file via tee",
    "overwrite system file via redirection",
    "overwrite project env/config via tee",
    "overwrite project env/config via redirection",
    "xargs with rm",
    "find -exec/-execdir rm",
    "find dynamic shell word may expand to destructive flag",
    "find -delete",
    "dynamic shell word may expand to arbitrary program execution flag",
    "stop/restart hermes gateway (kills running agents)",
    "hermes update (restarts gateway, kills running agents)",
    "docker with remote daemon redirect (-H/--host)",
    "docker with daemon redirect (--context: alternate daemon)",
    "docker context use (switches default daemon for future commands)",
    "podman with remote daemon redirect (--url/--connection/--identity)",
    "podman remote mode (-r/--remote: remote daemon)",
    "docker/podman daemon redirect via environment (DOCKER_HOST/CONTAINER_HOST)",
    "docker compose restart/stop/kill/down (container lifecycle)",
    "docker restart/stop/kill (container lifecycle)",
    "docker/podman rm (container destruction)",
    "docker compose rm (container destruction)",
    "docker/podman volume rm/prune (volume data destruction)",
    "docker/podman container/system prune, podman system reset (deletes stopped containers and unused data)",
    "start gateway outside systemd (use 'systemctl --user restart hermes-gateway')",
    "kill hermes/gateway process (self-termination)",
    "kill process via pgrep/pidof expansion (self-termination)",
    "kill process via backtick pgrep/pidof expansion (self-termination)",
    "stop/restart hermes launchd service (kills running agents)",
    "copy/move file into system config path",
    "overwrite project env/config file",
    "copy/move file into sensitive credential/SSH/shell-rc path",
    "create a file in a sensitive credential/SSH/shell-rc path",
    "link a file into a sensitive credential/SSH/shell-rc path",
    "delete/move/wipe Hermes home or session store",
    "overwrite Hermes session/credential store",
    "modify Hermes session store via sqlite3",
    "in-place edit of sensitive credential/SSH/shell-rc path",
    "in-place edit of sensitive credential/SSH/shell-rc path (long flag)",
    "in-place edit of sensitive credential/SSH/shell-rc path (perl/ruby)",
    "in-place edit of system config",
    "in-place edit of system config (long flag)",
    "in-place edit of Hermes config/env",
    "in-place edit of Hermes config/env (long flag)",
    "in-place edit of Hermes config/env (perl/ruby)",
    "shell execution via heredoc",
    "git reset --hard (destroys uncommitted changes)",
    "git force push (rewrites remote history)",
    "git force push short flag (rewrites remote history)",
    "hermes config set approval settings",
    "git clean with force (deletes untracked files)",
    "git branch force delete",
    "git branch force delete (long flags)",
    "git branch force delete (long flags, force-first)",
    "chmod +x followed by immediate execution",
    "sudo with privilege flag (stdin/askpass/shell/list)",
    "sudo with combined-flag privilege escalation",
    "package manager uninstall",
    "recursive delete (flags after operands)",
};
