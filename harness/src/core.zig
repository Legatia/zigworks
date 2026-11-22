//! The running instance: one data folder, one owner, one chat, the
//! scheduler, and the commands the owner sends. Transport-free: Telegram
//! and the terminal plug in as a `Channel`.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const rules = @import("rules.zig");
const gate = @import("gate.zig");
const log_mod = @import("log.zig");
const memory = @import("memory.zig");
const model = @import("model.zig");
const tools = @import("tools.zig");
const skills = @import("skills.zig");
const mcp = @import("mcp.zig");
const page = @import("page.zig");
const agent = @import("agent.zig");
const brief = @import("brief.zig");
const scrub = @import("scrub.zig");
const util = @import("util.zig");
const logins = @import("logins.zig");
const store_mod = @import("store.zig");
const masks = @import("masks.zig");
const Io = std.Io;

pub const Paths = struct {
    home: []const u8,
    config: []const u8,
    rules: []const u8,
    briefs: []const u8,
    tasks: []const u8,
    memory: []const u8,
    workspace: []const u8,
    state: []const u8,
    log_dir: []const u8,
    log: []const u8,
    grants: []const u8,
    seen: []const u8,
    owner: []const u8,
    pair: []const u8,
    switches: []const u8,
    ran: []const u8,
    paused: []const u8,
    status: []const u8,
    lock: []const u8,
    telegram: []const u8,
    skills: []const u8,
    mcp: []const u8,
    money: []const u8,
    logins: []const u8,
    profiles: []const u8,

    pub fn init(a: std.mem.Allocator, home: []const u8) !Paths {
        const j = struct {
            fn f(al: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
                return std.fs.path.join(al, parts);
            }
        }.f;
        const state = try j(a, &.{ home, "state" });
        return .{
            .home = home,
            .config = try j(a, &.{ home, "config.ini" }),
            .rules = try j(a, &.{ home, "rules" }),
            .briefs = try j(a, &.{ home, "briefs.ini" }),
            .tasks = try j(a, &.{ home, "tasks.ini" }),
            .memory = try j(a, &.{ home, "memory" }),
            .workspace = try j(a, &.{ home, "workspace" }),
            .state = state,
            .log_dir = try j(a, &.{ home, "log" }),
            .log = try j(a, &.{ home, "log", "actions.jsonl" }),
            .grants = try j(a, &.{ state, "grants" }),
            .seen = try j(a, &.{ state, "seen" }),
            .owner = try j(a, &.{ state, "owner" }),
            .pair = try j(a, &.{ state, "pair" }),
            .switches = try j(a, &.{ state, "switches" }),
            .ran = try j(a, &.{ state, "ran" }),
            .paused = try j(a, &.{ state, "paused" }),
            .status = try j(a, &.{ state, "status" }),
            .lock = try j(a, &.{ state, "lock" }),
            .telegram = try j(a, &.{ state, "telegram" }),
            .skills = try j(a, &.{ home, "skills" }),
            .mcp = try j(a, &.{ home, "mcp.ini" }),
            .money = try j(a, &.{ state, "money" }),
            .logins = try j(a, &.{ home, "logins.ini" }),
            .profiles = try j(a, &.{ home, "profiles" }),
        };
    }
};

/// Writes the data folder with commented defaults; existing files are kept.
pub fn initHome(io: Io, a: std.mem.Allocator, home: []const u8) !void {
    const p = try Paths.init(a, home);
    for ([_][]const u8{ home, p.memory, p.workspace, p.state, p.log_dir, p.skills, p.profiles }) |d| try Io.Dir.cwd().createDirPath(io, d);
    if (builtin.os.tag != .windows) {
        // the logins' browser profiles hold their cookies
        for ([_][]const u8{ home, p.profiles }) |dir| {
            // iterate: on Linux a plain open is O_PATH, and fchmod on it fails with EBADF
            var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
            defer d.close(io);
            try d.setPermissions(io, .fromMode(0o700));
        }
    }
    const files = [_][2][]const u8{ .{ p.config, config.defaults_ini }, .{ p.rules, config.rules_example }, .{ p.briefs, config.briefs_example }, .{ p.tasks, config.tasks_example } };
    for (files) |f| {
        var file = Io.Dir.cwd().createFile(io, f[0], .{ .exclusive = true, .permissions = util.private_file }) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        defer file.close(io);
        try file.writeStreamingAll(io, f[1]);
    }
}

pub const Channel = struct {
    ctx: *anyopaque,
    /// Sends `text` to the owner; an error when it did not get there
    /// (error.NotPaired: there is no owner to send it to yet).
    send: *const fn (ctx: *anyopaque, text: []const u8) anyerror!void,
    /// Returns an id for `clear`, or null when buttons can't be shown.
    buttons: *const fn (ctx: *anyopaque, text: []const u8, buttons: []const [2][]const u8) ?i64,
    clear: *const fn (ctx: *anyopaque, id: i64) void,
    /// Sends to someone other than the owner (an account trying to pair);
    /// null where there is no one else (the terminal).
    send_to: ?*const fn (ctx: *anyopaque, chat_id: i64, text: []const u8) anyerror!void = null,
};

pub const Secrets = struct {
    omnigate: ?[]const u8 = null,
    telegram: ?[]const u8 = null,
    search: ?[]const u8 = null,
    /// Other stored secrets by name, for MCP servers.
    named: []const Named = &.{},

    pub const Named = struct { name: []const u8, value: []const u8 };

    pub fn get(s: Secrets, name: []const u8) ?[]const u8 {
        for (s.named) |n| if (std.mem.eql(u8, n.name, name)) return n.value;
        return null;
    }
};

pub const Error = error{ AlreadyRunning, BadSettings, NoModelKey };

/// The question waiting for the owner. Its buttons carry its number and
/// the instance's nonce (`a7-9f3c0a1be27d4c55:once`), and a press counts
/// only from the message they were sent in: a button left in the chat from
/// before a restart, or under another question, answers nothing.
const Approval = struct {
    mutex: Io.Mutex = .init,
    /// The last question's number; it goes on from the last instance's
    /// (state/approvals).
    id: u32 = 0,
    loaded: bool = false,
    waiting: bool = false,
    /// Whether the waiting question offers "Allow 24 h" (money does not).
    allow_day: bool = true,
    /// No one is there to answer: nothing more is asked.
    closed: bool = false,
    answer: ?agent.Answer = null,
    /// The message the waiting question's buttons are in, as the channel
    /// said when it sent them (null: it said none).
    msg: ?i64 = null,
    /// The buttons have been sent and `msg` is what the channel said.
    shown: bool = false,
    /// A press of the waiting question's buttons that came before the
    /// channel said where they are: checked against `msg` once it has.
    early: ?Early = null,

    const Early = struct { msg: i64, ans: agent.Answer };
};

/// What a button's data says: `a<number>-<nonce>:once|day|deny`.
const Press = struct {
    id: u32,
    nonce: []const u8,
    ans: agent.Answer,

    fn parse(data: []const u8) ?Press {
        if (data.len < 4 or data[0] != 'a') return null;
        const colon = std.mem.lastIndexOfScalar(u8, data, ':') orelse return null;
        const dash = std.mem.indexOfScalar(u8, data[0..colon], '-') orelse return null;
        const id = std.fmt.parseInt(u32, data[1..dash], 10) catch return null;
        const word = data[colon + 1 ..];
        const ans: agent.Answer = if (std.mem.eql(u8, word, "once")) .once else if (std.mem.eql(u8, word, "day")) .day else if (std.mem.eql(u8, word, "deny")) .deny else return null;
        return .{ .id = id, .nonce = data[dash + 1 .. colon], .ans = ans };
    }
};

pub const Core = struct {
    gpa: std.mem.Allocator,
    io: Io,
    paths: Paths,
    /// Holds settings; replaced as a whole on /reload.
    settings_arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    rule_list: []const rules.Rule,
    briefs: []const config.Brief,
    tasks: []const config.Task,
    settings_hash: [32]u8,
    told_settings_changed: bool = false,
    secrets: Secrets,
    /// The stored secrets read at open. What every tool's output is
    /// masked against is `masks`: these and the values added since.
    secret_list: []const scrub.Secret,
    /// The values masked in tool output: the stored secrets, secrets
    /// fetched later for MCP servers, passwords made at sign-ups.
    masks: masks.List,
    /// The list the log and memory mask with (see masksChanged).
    mask_snap: []const scrub.Secret,
    workspace: []const u8,

    grants: gate.Grants,
    gate: gate.Gate,
    log: log_mod.Log,
    mem: memory.Store,
    lock: Io.Mutex = .init,
    /// How many helpers run at once, across all runs.
    helper_pool: agent.Pool = .{},
    /// The owner is asked one question at a time.
    ask_lock: Io.Mutex = .init,
    mcp_arena: std.heap.ArenaAllocator = undefined,
    /// Guards the list of servers (endBySignal reads it from its thread).
    mcp_mutex: Io.Mutex = .init,
    /// startMcp is under way (endBySignal waits for it to end).
    mcp_starting: std.atomic.Value(bool) = .init(false),
    /// /reload is restarting the MCP servers: no run starts meanwhile.
    restarting: std.atomic.Value(bool) = .init(false),
    mcp_servers: std.ArrayList(*mcp.Server) = .empty,
    mcp_tools: []const agent.McpTool = &.{},
    /// What started and what did not, for /status.
    mcp_note: []const u8 = "",
    /// What the owner should fix in mcp.ini (also in `mcp_note`), said at start.
    mcp_warn: []const u8 = "",
    money_ledger: agent.MoneyLedger = .{},
    /// Chrome or Chromium for `browse` and `web`; empty: none.
    browser: []const u8 = "",
    /// The agent's logins (logins.ini, in the settings arena).
    login_list: []const logins.Login = &.{},
    /// Where secrets are kept, for the logins' values; set by main.
    store: ?store_mod.Store = null,
    seen: brief.Seen,
    /// Set on close: nothing new starts.
    stop: std.atomic.Value(bool) = .init(false),
    /// The stop flag of every run going on; /stop sets them all and nothing
    /// clears them, so a stopped run stays stopped however long it takes.
    runs_mutex: Io.Mutex = .init,
    run_flags: std.ArrayList(*std.atomic.Value(bool)) = .empty,
    /// Held while settings are read by the scheduler or replaced by /reload.
    settings_mutex: Io.Mutex = .init,
    /// Guards `seen` (briefs read a copy).
    seen_mutex: Io.Mutex = .init,

    chan: ?Channel = null,
    owner: ?i64 = null,
    /// /dryrun, /private, /memory auto: runs read them when they use them.
    switches: agent.Switches = .{},

    // the chat
    chat_client: model.Client,
    conv: agent.Conversation,
    queue_mutex: Io.Mutex = .init,
    queue: std.ArrayList([]u8) = .empty,
    busy: std.atomic.Value(bool) = .init(false),
    approval: Approval = .{},
    /// Random for each start, in every question's button data: a button
    /// from before a restart never matches, whatever its number.
    approval_nonce: [16]u8 = undefined,
    last_owner_s: i64 = 0,
    turns_since_memory: u32 = 0,
    /// The memory writer has read the conversation's turns before this one
    /// (counted from the start, dropped turns included).
    memory_upto: usize = 0,
    worker: ?std.Thread = null,
    /// /new: the chat worker starts a fresh conversation before its next turn.
    reset_conv: std.atomic.Value(bool) = .init(false),
    quitting: std.atomic.Value(bool) = .init(false),

    // background runs
    bg_active: std.atomic.Value(u32) = .init(0),
    state_mutex: Io.Mutex = .init,
    /// "brief:NAME" → local day number it last ran; "task:NAME" → seconds.
    ran: std.StringHashMapUnmanaged(i64) = .empty,
    running: std.StringHashMapUnmanaged(void) = .empty,
    paused: std.StringHashMapUnmanaged(void) = .empty,
    /// Briefs and tasks whose message did not get through, by the same
    /// keys as `ran`: when they run again.
    retry: std.StringHashMapUnmanaged(Retry) = .empty,
    last_status_s: i64 = 0,

    /// Tests set this to fix the clock.
    fixed_now: ?i64 = null,
    /// Seconds of quiet before memories are written from the chat.
    memory_quiet_s: i64 = 30 * 60,
    /// How long /stop waits for runs to end before answering.
    stop_wait_ms: u32 = 3_000,
    /// How long the MCP servers have to start, all of them together.
    mcp_start_ms: u32 = 20_000,
    path_var: []const u8 = "/usr/local/bin:/usr/bin:/bin",
    home_var: []const u8 = "",
    /// On Windows, the system's own variables, for commands and MCP servers.
    system_vars: []const util.Var = &.{},
    paths_arena: std.heap.ArenaAllocator,
    home_owned: []u8,
    /// state/lock, open and locked while this core holds the folder.
    folder_lock: ?Io.File = null,
    /// What holds the folder ("run", "chat", "task" ...), in the status file.
    role: []const u8 = "open",
    /// main's thread acting on SIGINT/SIGTERM; joined first by close.
    watcher: ?std.Thread = null,
    /// Said to the owner when a channel is attached.
    pending_warning: ?[]const u8 = null,
    /// What /reload says when the settings files have an error.
    problem_buf: [800]u8 = undefined,

    pub fn now(c: *const Core) i64 {
        return c.fixed_now orelse util.nowSeconds(c.io);
    }

    /// Opens the data folder: takes the lock, reads settings, memory, log.
    pub fn open(gpa: std.mem.Allocator, io: Io, home: []const u8, secrets: Secrets) !*Core {
        const c = try gpa.create(Core);
        errdefer gpa.destroy(c);
        c.* = undefined;
        c.gpa = gpa;
        c.io = io;
        c.settings_arena = .init(gpa);
        errdefer c.settings_arena.deinit();
        const sa = c.settings_arena.allocator();
        // the paths live as long as the core, so in their own arena slot
        const home_owned = try gpa.dupe(u8, home);
        errdefer gpa.free(home_owned);
        var paths_arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer paths_arena.deinit();
        c.paths = try Paths.init(paths_arena.allocator(), home_owned);
        c.paths_arena = paths_arena;
        c.home_owned = home_owned;
        c.folder_lock = try takeLock(io, c.paths);
        errdefer c.releaseFolder();

        try Io.Dir.cwd().createDirPath(io, c.paths.workspace);
        c.workspace = try Io.Dir.cwd().realPathFileAlloc(io, c.paths.workspace, c.paths_arena.allocator());
        try c.loadSettings(sa);
        c.secrets = secrets;
        var sl: std.ArrayList(scrub.Secret) = .empty;
        if (secrets.omnigate) |v| try sl.append(c.paths_arena.allocator(), .{ .name = "omnigate", .value = v });
        if (secrets.telegram) |v| try sl.append(c.paths_arena.allocator(), .{ .name = "telegram", .value = v });
        if (secrets.search) |v| try sl.append(c.paths_arena.allocator(), .{ .name = "search", .value = v });
        for (secrets.named) |n| try sl.append(c.paths_arena.allocator(), .{ .name = n.name, .value = n.value });
        c.secret_list = sl.items;
        c.masks = .init(gpa, io);
        errdefer c.masks.deinit();
        for (sl.items) |x| try c.masks.add(x.name, x.value);

        c.grants = .init(gpa);
        errdefer c.grants.deinit();
        c.grants.load(io, c.paths.grants, util.nowSeconds(io)) catch {};
        c.gate = .{ .io = io, .rules = c.rule_list, .grants = &c.grants, .workspace = c.workspace };
        try Io.Dir.cwd().createDirPath(io, c.paths.log_dir);
        c.log = try log_mod.Log.open(gpa, io, c.paths.log);
        errdefer c.log.close();
        try c.log.setSecrets(c.secret_list);
        // without it private lines keep only sizes
        c.log.useKey(io, try std.fs.path.join(c.paths_arena.allocator(), &.{ c.paths.state, "log-key" })) catch {};
        c.mem = try memory.Store.load(gpa, io, c.paths.memory);
        errdefer c.mem.deinit();
        c.mem.secrets = c.secret_list;
        // values added later (a sign-up password, a secret found on
        // /reload) reach the log's and memory's masks too
        c.mask_snap = &.{};
        c.masks.on_change = .{ .ctx = c, .changed = masksChanged };
        c.seen = .init(gpa);
        c.seen.load(io, c.paths.seen) catch {};
        c.lock = .init;
        c.helper_pool = .{};
        c.ask_lock = .init;
        c.money_ledger = .{ .path = c.paths.money };
        c.money_ledger.load(io);
        c.mcp_servers = .empty;
        c.mcp_mutex = .init;
        c.mcp_starting = .init(false);
        c.restarting = .init(false);
        c.watcher = null;
        c.stop = .init(false);
        c.runs_mutex = .init;
        c.run_flags = .empty;
        c.seen_mutex = .init;
        c.settings_mutex = .init;
        c.chan = null;
        c.owner = readOwner(io, c.paths.owner);
        c.switches = .{};
        c.switches.auto_recall.store(c.cfg.memory.auto, .release);
        c.loadSwitches();
        c.chat_client = try model.Client.init(gpa, io, c.cfg.model.url, secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens);
        c.conv = .init(gpa);
        c.queue_mutex = .init;
        c.queue = .empty;
        c.busy = .init(false);
        c.approval = .{};
        var nonce_raw: [8]u8 = undefined;
        io.random(&nonce_raw);
        c.approval_nonce = std.fmt.bytesToHex(nonce_raw, .lower);
        c.last_owner_s = 0;
        c.turns_since_memory = 0;
        c.memory_upto = 0;
        c.worker = null;
        c.reset_conv = .init(false);
        c.quitting = .init(false);
        c.bg_active = .init(0);
        c.state_mutex = .init;
        c.ran = .empty;
        c.running = .empty;
        c.paused = .empty;
        c.retry = .empty;
        c.last_status_s = 0;
        c.fixed_now = null;
        c.memory_quiet_s = 30 * 60;
        c.stop_wait_ms = 3_000;
        c.mcp_start_ms = 20_000;
        c.path_var = "/usr/local/bin:/usr/bin:/bin";
        c.home_var = "";
        c.system_vars = &.{};
        c.told_settings_changed = false;
        c.pending_warning = null;
        c.role = "open";
        // problem_buf: written before it is read
        c.loadRan();
        c.checkLogAgainstStatus();
        try c.log.write(.config, false, .{ .event = "start", .pid = pidNumber() });
        // the status says who holds the folder now, not who held it last
        c.writeStatus() catch {};
        c.mcp_arena = .init(gpa);
        c.mcp_tools = &.{};
        c.mcp_note = "";
        c.mcp_warn = "";
        c.browser = "";
        c.store = null;
        return c;
    }

    pub fn close(c: *Core) void {
        c.quitting.store(true, .release);
        c.stop.store(true, .release);
        // first: once it is gone no signal handling can touch the core
        if (c.watcher) |w| w.join();
        c.watcher = null;
        c.stopRuns();
        if (c.worker) |w| w.join();
        while (c.bg_active.load(.acquire) > 0) c.io.sleep(.fromMilliseconds(20), .awake) catch {};
        c.log.write(.config, false, .{ .event = "stop" }) catch {};
        c.writeStatus() catch {};
        c.stopMcp();
        for (c.queue.items) |q| c.gpa.free(q);
        c.queue.deinit(c.gpa);
        c.run_flags.deinit(c.gpa);
        c.conv.deinit();
        c.chat_client.deinit();
        c.seen.deinit();
        c.mem.deinit();
        c.log.close();
        c.grants.deinit();
        c.masks.deinit();
        if (c.mask_snap.len > 0) c.gpa.free(c.mask_snap);
        freeKeys(c.gpa, &c.ran);
        freeKeys(c.gpa, &c.running);
        freeKeys(c.gpa, &c.paused);
        freeKeys(c.gpa, &c.retry);
        c.releaseFolder();
        c.settings_arena.deinit();
        c.paths_arena.deinit();
        c.gpa.free(c.home_owned);
        c.gpa.destroy(c);
    }

    /// The mask list grew: the log and memory mask with the new list from
    /// now on. The strings belong to the list; only the slice is ours.
    fn masksChanged(ctx: *anyopaque) void {
        const c: *Core = @ptrCast(@alignCast(ctx));
        const snap = c.masks.snapshot(c.gpa) catch return;
        c.log.setSecrets(snap) catch {
            c.gpa.free(snap);
            return;
        };
        c.lock.lockUncancelable(c.io);
        const old = c.mask_snap;
        c.mem.secrets = snap;
        c.mask_snap = snap;
        c.lock.unlock(c.io);
        if (old.len > 0) c.gpa.free(old);
    }

    /// Lets go of the data folder (the lock file stays: the lock is what counts).
    fn releaseFolder(c: *Core) void {
        if (c.folder_lock) |f| f.close(c.io);
        c.folder_lock = null;
    }

    // ---- settings ----

    /// The settings files, in this order; a change to any of them is noticed.
    fn settingsFiles(c: *const Core) [6][]const u8 {
        return .{ c.paths.config, c.paths.rules, c.paths.briefs, c.paths.tasks, c.paths.logins, c.paths.mcp };
    }

    fn readSettingsFiles(c: *Core, a: std.mem.Allocator) ![6][]const u8 {
        var out: [6][]const u8 = undefined;
        for (c.settingsFiles(), 0..) |p, i| {
            out[i] = Io.Dir.cwd().readFileAlloc(c.io, p, a, .limited(1 << 20)) catch |e| switch (e) {
                error.FileNotFound => "",
                else => return e,
            };
        }
        return out;
    }

    fn hashSettings(texts: [6][]const u8) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for (texts) |tx| {
            h.update(tx);
            h.update("\x00");
        }
        return h.finalResult();
    }

    fn loadSettings(c: *Core, a: std.mem.Allocator) !void {
        if (builtin.os.tag != .windows) {
            for (guardedFiles(c.paths)) |p| {
                const st = Io.Dir.cwd().statFile(c.io, p, .{}) catch continue;
                if (st.permissions.toMode() & 0o022 != 0) return error.BadSettings;
            }
        }
        const texts = try c.readSettingsFiles(a);
        c.cfg = config.parse(a, texts[0]) catch return error.BadSettings;
        c.rule_list = rules.parse(a, texts[1]) catch return error.BadSettings;
        c.briefs = config.parseBriefs(a, texts[2]) catch return error.BadSettings;
        c.tasks = config.parseTasks(a, texts[3]) catch return error.BadSettings;
        c.login_list = logins.parse(a, texts[4]) catch return error.BadSettings;
        c.settings_hash = hashSettings(texts);
    }

    /// Re-reads the settings files; refused while anything runs.
    pub fn reload(c: *Core) ![]const u8 {
        // nothing may start while the settings are replaced: the scheduler
        // waits on settings_mutex, the chat worker on queue_mutex
        c.settings_mutex.lockUncancelable(c.io);
        var settings_locked = true;
        defer if (settings_locked) c.settings_mutex.unlock(c.io);
        c.queue_mutex.lockUncancelable(c.io);
        var queue_locked = true;
        defer if (queue_locked) c.queue_mutex.unlock(c.io);
        if (c.busy.load(.acquire) or c.queue.items.len > 0 or c.bg_active.load(.acquire) > 0 or c.restarting.load(.acquire)) return "Busy; send /reload again when nothing is running.";
        var fresh: std.heap.ArenaAllocator = .init(c.gpa);
        const saved_cfg = c.cfg;
        const saved_rules = c.rule_list;
        const saved_briefs = c.briefs;
        const saved_tasks = c.tasks;
        const saved_logins = c.login_list;
        const saved_hash = c.settings_hash;
        c.loadSettings(fresh.allocator()) catch {
            fresh.deinit();
            c.cfg = saved_cfg;
            c.rule_list = saved_rules;
            c.briefs = saved_briefs;
            c.tasks = saved_tasks;
            c.login_list = saved_logins;
            c.settings_hash = saved_hash;
            return c.settingsErrorReply();
        };
        // the chat's client points into the old settings: build it again
        const client = model.Client.init(c.gpa, c.io, c.cfg.model.url, c.secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens) catch {
            fresh.deinit();
            c.cfg = saved_cfg;
            c.rule_list = saved_rules;
            c.briefs = saved_briefs;
            c.tasks = saved_tasks;
            c.login_list = saved_logins;
            c.settings_hash = saved_hash;
            return "The model url in config.ini is not valid; nothing changed.";
        };
        c.chat_client.deinit();
        c.chat_client = client;
        c.settings_arena.deinit();
        c.settings_arena = fresh;
        c.gate.rules = c.rule_list;
        c.findBrowser();
        c.told_settings_changed = false;
        // nothing runs now (reload waits for that), so servers can restart;
        // nothing may start until they have (popQueue, claimIdle and
        // startBackground look at `restarting`), but the locks are let go:
        // /stop, a signal and the scheduler's status do not wait for it
        c.restarting.store(true, .release);
        queue_locked = false;
        c.queue_mutex.unlock(c.io);
        settings_locked = false;
        c.settings_mutex.unlock(c.io);
        return c.restartMcp();
    }

    /// The second half of reload, outside its locks.
    fn restartMcp(c: *Core) ![]const u8 {
        defer c.restarting.store(false, .release);
        c.stopMcp();
        c.startMcp();
        try c.log.write(.config, false, .{ .event = "reload" });
        return "Settings reloaded.";
    }

    /// The answer to a /reload the settings files refused, naming the file
    /// and line (in `problem_buf`).
    fn settingsErrorReply(c: *Core) []const u8 {
        const generic = "The settings files have an error; nothing changed. Check config.ini, rules, briefs.ini, tasks.ini, logins.ini and mcp.ini.";
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const why = (settingsProblem(c.io, arena.allocator(), c.paths) catch return generic) orelse return generic;
        return std.fmt.bufPrint(&c.problem_buf, "The settings files have an error; nothing changed: {s}", .{why}) catch generic;
    }

    fn checkSettingsChanged(c: *Core) void {
        if (c.told_settings_changed) return;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const texts = c.readSettingsFiles(arena.allocator()) catch return;
        const h = hashSettings(texts);
        if (std.mem.eql(u8, &h, &c.settings_hash)) return;
        c.told_settings_changed = true;
        c.log.write(.config, false, .{ .event = "settings files changed" }) catch {};
        c.say("The settings files changed. The change is not applied until you send /reload.");
    }

    // ---- small state files ----

    fn loadSwitches(c: *Core) void {
        var buf: [256]u8 = undefined;
        const got = Io.Dir.cwd().readFile(c.io, c.paths.switches, &buf) catch return;
        var it = std.mem.splitScalar(u8, got, '\n');
        while (it.next()) |line| {
            if (std.mem.eql(u8, line, "auto off")) c.switches.auto_recall.store(false, .release);
            if (std.mem.eql(u8, line, "auto on")) c.switches.auto_recall.store(true, .release);
            if (std.mem.eql(u8, line, "private on")) c.switches.private.store(true, .release);
            if (std.mem.eql(u8, line, "dryrun on")) c.switches.dry_run.store(true, .release);
        }
    }

    fn saveSwitches(c: *Core) void {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "auto {s}\nprivate {s}\ndryrun {s}\n", .{ onOff(c.switches.auto_recall.load(.acquire)), onOff(c.switches.private.load(.acquire)), onOff(c.switches.dry_run.load(.acquire)) }) catch return;
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.paths.switches, .data = s }) catch {};
    }

    fn loadRan(c: *Core) void {
        const text = Io.Dir.cwd().readFileAlloc(c.io, c.paths.ran, c.gpa, .limited(1 << 20)) catch return;
        defer c.gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const v = std.fmt.parseInt(i64, line[tab + 1 ..], 10) catch continue;
            putKey(c.gpa, &c.ran, line[0..tab], v) catch {};
        }
        const ptext = Io.Dir.cwd().readFileAlloc(c.io, c.paths.paused, c.gpa, .limited(1 << 20)) catch return;
        defer c.gpa.free(ptext);
        var pit = std.mem.splitScalar(u8, ptext, '\n');
        while (pit.next()) |line| if (line.len > 0) putKey(c.gpa, &c.paused, line, {}) catch {};
    }

    fn saveRan(c: *Core) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(c.gpa);
        var it = c.ran.iterator();
        while (it.next()) |e| out.print(c.gpa, "{s}\t{d}\n", .{ e.key_ptr.*, e.value_ptr.* }) catch return;
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.paths.ran, .data = out.items }) catch {};
        out.clearRetainingCapacity();
        var pit = c.paused.iterator();
        while (pit.next()) |e| out.print(c.gpa, "{s}\n", .{e.key_ptr.*}) catch return;
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.paths.paused, .data = out.items }) catch {};
    }

    pub fn writeStatus(c: *Core) !void {
        var tb: [20]u8 = undefined;
        var buf: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "pid {d}\nrole {s}\ntick {s}\nlog {s}\n", .{ pidNumber(), c.role, util.isoTime(&tb, util.nowSeconds(c.io)), c.log.lastHash() });
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.paths.status, .data = s });
    }

    fn checkLogAgainstStatus(c: *Core) void {
        var buf: [256]u8 = undefined;
        const got = Io.Dir.cwd().readFile(c.io, c.paths.status, &buf) catch return;
        const i = std.mem.indexOf(u8, got, "\nlog ") orelse return;
        const h = std.mem.trim(u8, got[i + 5 ..], " \n");
        // the log may have grown after the last status (an unclean stop);
        // only a log that no longer contains that point is a warning
        if (h.len == 64 and !(c.log.contains(h[0..64]) catch true)) {
            c.log.write(.config, false, .{ .event = "the log does not end where the last run left it", .expected = h }) catch {};
            c.pending_warning = "Warning: the action log changed while harness was not running. Run `harness log verify`.";
        }
    }

    // ---- talking to the owner ----

    pub fn say(c: *Core, text: []const u8) void {
        c.deliver(text) catch {};
    }

    /// Sends `text` to the owner; an error (logged) when it did not get
    /// there. error.NoChannel: nothing to send it through.
    pub fn deliver(c: *Core, text: []const u8) !void {
        const ch = c.chan orelse return error.NoChannel;
        ch.send(ch.ctx, text) catch |e| {
            c.log.write(.chat, false, .{ .event = "not delivered", .why = whyUndelivered(e), .bytes = text.len }) catch {};
            return e;
        };
    }

    pub fn attach(c: *Core, ch: Channel) void {
        c.chan = ch;
        if (c.pending_warning) |w| {
            c.say(w);
            c.pending_warning = null;
        }
    }

    pub fn setOwner(c: *Core, id: i64) !void {
        c.owner = id;
        var buf: [32]u8 = undefined;
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.paths.owner, .data = try std.fmt.bufPrint(&buf, "{d}\n", .{id}) });
    }

    /// A Telegram message. Strangers are dropped, though an attempt to
    /// pair is answered; `/pair CODE` with a code from `harness pair` pairs
    /// the account it comes from, also when another one was paired before.
    pub fn handleMessage(c: *Core, from_id: i64, text: []const u8) !void {
        const is_owner = if (c.owner) |o| o == from_id else false;
        if (!is_owner and std.mem.startsWith(u8, text, "/pair ")) {
            if (checkPairCode(c.io, c.paths.pair, std.mem.trim(u8, text[6..], " "), c.now())) {
                const before = c.owner;
                try c.setOwner(from_id);
                Io.Dir.cwd().deleteFile(c.io, c.paths.pair) catch {};
                if (before) |old| {
                    // another account: the old one is told, the new one
                    // starts a fresh conversation
                    c.sayTo(old, "This bot is now paired with another account, with a code from harness pair.");
                    c.reset_conv.store(true, .release);
                }
                try c.log.write(.chat, false, .{ .event = "paired", .from = from_id, .before = before });
                c.say("Paired. I answer only you from now on. Send /help for commands.");
                return;
            }
            try c.log.write(.chat, false, .{ .event = "dropped", .from = from_id, .why = "pairing code wrong or expired" });
            c.sayTo(from_id, if (c.owner == null)
                "That pairing code is wrong or has expired. Run `harness pair` where harness runs for a new one."
            else
                "This bot is paired with another account. To pair a new one, its owner runs `harness pair` where harness runs and sends the code it prints from that account.");
            return;
        }
        if (c.owner == null) {
            try c.log.write(.chat, false, .{ .event = "dropped", .from = from_id, .why = "not paired" });
            return;
        }
        if (!is_owner) {
            try c.log.write(.chat, false, .{ .event = "dropped", .from = from_id, .why = "not the owner" });
            return;
        }
        try c.handleText(text);
    }

    /// Sends to an account other than the owner, where the channel can.
    fn sayTo(c: *Core, chat_id: i64, text: []const u8) void {
        const ch = c.chan orelse return;
        const f = ch.send_to orelse return;
        f(ch.ctx, chat_id, text) catch {};
    }

    /// The owner's text: a command now, or a message for the chat queue.
    pub fn handleText(c: *Core, text_in: []const u8) !void {
        const text = std.mem.trim(u8, text_in, " \t\r\n");
        if (text.len == 0) return;
        if (text[0] == '/') {
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            const reply = try c.command(arena.allocator(), text);
            if (reply.len > 0) c.say(reply);
            return;
        }
        c.last_owner_s = c.now();
        const owned = try c.gpa.dupe(u8, text);
        const queued_behind = blk: {
            c.queue_mutex.lockUncancelable(c.io);
            defer c.queue_mutex.unlock(c.io);
            try c.queue.append(c.gpa, owned);
            break :blk c.busy.load(.acquire) or c.queue.items.len > 1;
        };
        if (queued_behind) c.say("Queued; /stop cancels the current turn.");
    }

    /// A button press (`data`, see Approval) in message `message_id`. It
    /// answers the waiting question only if it is one of that question's
    /// buttons: this start's nonce, the question's number, and the message
    /// the question was sent in. Any other press of the owner's is out of
    /// date (from before a restart, or under another question), and the
    /// owner is told so.
    pub fn handleCallback(c: *Core, from_id: i64, message_id: i64, data: []const u8) void {
        if (c.owner == null or from_id != c.owner.?) {
            c.log.write(.chat, false, .{ .event = "dropped", .from = from_id, .why = "button from someone else" }) catch {};
            return;
        }
        const current = blk: {
            const p = Press.parse(data) orelse break :blk false;
            c.approval.mutex.lockUncancelable(c.io);
            defer c.approval.mutex.unlock(c.io);
            const ap = &c.approval;
            if (!ap.waiting or p.id != ap.id or !std.mem.eql(u8, p.nonce, &c.approval_nonce)) break :blk false;
            // a "24 h" the question never offered is no answer
            if (p.ans == .day and !ap.allow_day) break :blk true;
            if (!ap.shown) {
                // pressed before the channel said where the buttons are
                ap.early = .{ .msg = message_id, .ans = p.ans };
                break :blk true;
            }
            if (ap.msg == null or ap.msg.? != message_id) break :blk false;
            ap.answer = p.ans;
            break :blk true;
        };
        if (!current) c.tellOutOfDate(message_id);
    }

    fn tellOutOfDate(c: *Core, message_id: i64) void {
        c.log.write(.chat, false, .{ .event = "button out of date", .message = message_id }) catch {};
        c.say("That button is out of date: it answers nothing.");
    }

    /// The terminal's way to answer: "o", "d" or "n" while asked; false if
    /// nothing is asked or the question does not offer that answer.
    pub fn answerPending(c: *Core, ans: agent.Answer) bool {
        c.approval.mutex.lockUncancelable(c.io);
        defer c.approval.mutex.unlock(c.io);
        if (!c.approval.waiting) return false;
        if (ans == .day and !c.approval.allow_day) return false;
        c.approval.answer = ans;
        return true;
    }

    /// No one is there to answer any more (the terminal's input ended): the
    /// question waiting is denied, and later calls that would ask are too.
    pub fn closeQuestions(c: *Core) void {
        c.approval.mutex.lockUncancelable(c.io);
        defer c.approval.mutex.unlock(c.io);
        c.approval.closed = true;
        if (c.approval.waiting) c.approval.answer = .deny;
    }

    pub fn approvalWaiting(c: *Core) bool {
        c.approval.mutex.lockUncancelable(c.io);
        defer c.approval.mutex.unlock(c.io);
        return c.approval.waiting;
    }

    const ChatAsk = struct { core: *Core, flag: *std.atomic.Value(bool) };

    fn askOwner(ctx: *anyopaque, q: agent.Question) agent.Answer {
        const ca: *ChatAsk = @ptrCast(@alignCast(ctx));
        const what = q.text;
        const allow_day = q.allow_day;
        const c = ca.core;
        const ch = c.chan orelse return .deny;
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // the whole question, in as many messages as it takes; the buttons
        // go on the last, so it is answered after all of it was shown
        const parts = questionParts(a, what) catch return .deny;
        const heads = a.alloc([]const u8, parts.len - 1) catch return .deny;
        for (heads, parts[0 .. parts.len - 1], 1..) |*h, p, i| h.* = std.fmt.allocPrint(a, "Allow this? ({d}/{d})\n{s}", .{ i, parts.len, p }) catch return .deny;
        const text = (if (parts.len == 1)
            std.fmt.allocPrint(a, "Allow this?\n{s}", .{what})
        else
            std.fmt.allocPrint(a, "Allow this? ({d}/{d})\n{s}", .{ parts.len, parts.len, parts[parts.len - 1] })) catch return .deny;
        // once, day, deny
        var data_buf: [3][48]u8 = undefined;
        var data: [3][]const u8 = undefined;
        {
            c.approval.mutex.lockUncancelable(c.io);
            defer c.approval.mutex.unlock(c.io);
            if (c.approval.closed) return .deny;
            if (!c.approval.loaded) {
                c.approval.id = c.loadApprovalId();
                c.approval.loaded = true;
            }
            c.approval.id += 1;
            // the numbers go on after a restart; the nonce is what tells an
            // old button from a new one, so a number not kept asks all the same
            c.saveApprovalId(c.approval.id) catch {};
            for (&data, &data_buf, [_][]const u8{ "once", "day", "deny" }) |*d, *buf, word|
                d.* = std.fmt.bufPrint(buf, "a{d}-{s}:{s}", .{ c.approval.id, &c.approval_nonce, word }) catch return .deny;
            c.approval.waiting = true;
            c.approval.allow_day = allow_day;
            c.approval.answer = null;
            c.approval.msg = null;
            c.approval.shown = false;
            c.approval.early = null;
        }
        for (heads) |h| c.say(h);
        const msg = if (allow_day)
            ch.buttons(ch.ctx, text, &.{ .{ "Allow once", data[0] }, .{ "Allow 24 h", data[1] }, .{ "Deny", data[2] } })
        else
            ch.buttons(ch.ctx, text, &.{ .{ "Allow once", data[0] }, .{ "Deny", data[2] } });
        // a press that came before the channel said where the buttons are
        // counts only if it was in that message
        const early_elsewhere: ?i64 = blk: {
            c.approval.mutex.lockUncancelable(c.io);
            defer c.approval.mutex.unlock(c.io);
            c.approval.msg = msg;
            c.approval.shown = true;
            const e = c.approval.early orelse break :blk null;
            c.approval.early = null;
            if (msg != null and msg.? == e.msg) {
                c.approval.answer = e.ans;
                break :blk null;
            }
            break :blk e.msg;
        };
        if (early_elsewhere) |m| c.tellOutOfDate(m);
        const deadline = c.now() + c.cfg.limits.approval_seconds;
        var ans: agent.Answer = .timeout;
        while (true) {
            {
                c.approval.mutex.lockUncancelable(c.io);
                defer c.approval.mutex.unlock(c.io);
                if (c.approval.answer) |got| {
                    ans = got;
                    break;
                }
            }
            if (ca.flag.load(.acquire)) {
                ans = .deny;
                break;
            }
            if (c.now() >= deadline) break;
            // an answer after the run must end is of no use to it
            if (q.deadline_s > 0 and util.nowSeconds(c.io) >= q.deadline_s) break;
            c.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        {
            c.approval.mutex.lockUncancelable(c.io);
            defer c.approval.mutex.unlock(c.io);
            c.approval.waiting = false;
            c.approval.msg = null;
            c.approval.shown = false;
            c.approval.early = null;
        }
        if (msg) |m| ch.clear(ch.ctx, m);
        if (ans == .timeout) c.say("No answer in time; not allowed.");
        return ans;
    }

    fn approvalsPath(c: *Core, buf: []u8) ![]const u8 {
        var fba = std.heap.FixedBufferAllocator.init(buf);
        return std.fs.path.join(fba.allocator(), &.{ c.paths.state, "approvals" });
    }

    fn loadApprovalId(c: *Core) u32 {
        var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = c.approvalsPath(&pbuf) catch return 0;
        var buf: [32]u8 = undefined;
        const got = Io.Dir.cwd().readFile(c.io, p, &buf) catch return 0;
        return std.fmt.parseInt(u32, std.mem.trim(u8, got, " \r\n"), 10) catch 0;
    }

    fn saveApprovalId(c: *Core, id: u32) !void {
        var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = try c.approvalsPath(&pbuf);
        var buf: [32]u8 = undefined;
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = p, .data = try std.fmt.bufPrint(&buf, "{d}\n", .{id}) });
    }

    /// Telegram's limit for one message, in bytes (it counts characters, and
    /// a character takes at least a byte).
    const message_max = 4096;

    /// `what` in parts that each fit one message with their heading ("Allow
    /// this? (2/3)"), cut after a line break near the end where there is one.
    fn questionParts(a: std.mem.Allocator, what: []const u8) ![]const []const u8 {
        const room = message_max - 32;
        var out: std.ArrayList([]const u8) = .empty;
        var rest = what;
        while (rest.len > room) {
            var n = util.cut(rest, room).len;
            const from = room - room / 5;
            if (n > from) if (std.mem.lastIndexOfScalar(u8, rest[from..n], '\n')) |k| {
                n = from + k + 1;
            };
            try out.append(a, rest[0..n]);
            rest = rest[n..];
        }
        try out.append(a, rest);
        return out.items;
    }

    // ---- the chat worker ----

    pub fn startWorker(c: *Core) !void {
        c.worker = try std.Thread.spawn(.{}, workerLoop, .{c});
    }

    fn popQueue(c: *Core) ?[]u8 {
        c.queue_mutex.lockUncancelable(c.io);
        defer c.queue_mutex.unlock(c.io);
        // while the MCP servers restart, messages wait
        if (c.queue.items.len == 0 or c.restarting.load(.acquire)) return null;
        c.busy.store(true, .release);
        return c.queue.orderedRemove(0);
    }

    /// Marks the worker busy if nothing is queued (so /reload waits).
    fn claimIdle(c: *Core) bool {
        c.queue_mutex.lockUncancelable(c.io);
        defer c.queue_mutex.unlock(c.io);
        if (c.queue.items.len > 0 or c.busy.load(.acquire) or c.restarting.load(.acquire)) return false;
        c.busy.store(true, .release);
        return true;
    }

    fn workerLoop(c: *Core) void {
        while (!c.quitting.load(.acquire)) {
            if (c.popQueue()) |text| {
                defer c.gpa.free(text);
                c.chatTurn(text);
                c.busy.store(false, .release);
                continue;
            }
            if (c.turns_since_memory > 0 and !c.switches.private.load(.acquire) and c.last_owner_s > 0 and c.now() - c.last_owner_s >= c.memory_quiet_s and c.claimIdle()) {
                c.writeMemories() catch |e| c.log.write(.memory, false, .{ .event = "writer failed", .why = @errorName(e) }) catch {};
                c.turns_since_memory = 0;
                c.busy.store(false, .release);
            }
            c.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }

    fn register(c: *Core, flag: *std.atomic.Value(bool)) void {
        c.runs_mutex.lockUncancelable(c.io);
        defer c.runs_mutex.unlock(c.io);
        c.run_flags.append(c.gpa, flag) catch {};
        if (c.stop.load(.acquire)) flag.store(true, .release);
    }

    fn unregister(c: *Core, flag: *std.atomic.Value(bool)) void {
        c.runs_mutex.lockUncancelable(c.io);
        defer c.runs_mutex.unlock(c.io);
        for (c.run_flags.items, 0..) |f, i| if (f == flag) {
            _ = c.run_flags.swapRemove(i);
            return;
        };
    }

    fn stopRuns(c: *Core) void {
        c.runs_mutex.lockUncancelable(c.io);
        defer c.runs_mutex.unlock(c.io);
        for (c.run_flags.items) |f| f.store(true, .release);
    }

    fn baseRun(c: *Core, client: *model.Client, label: []const u8, scheduled: bool, flag: *std.atomic.Value(bool)) agent.Run {
        return .{
            .gpa = c.gpa,
            .io = c.io,
            .client = client,
            .gate = &c.gate,
            .grants_path = c.paths.grants,
            .log = &c.log,
            .mem = &c.mem,
            .lock = &c.lock,
            .env = .{
                .gpa = c.gpa,
                .io = c.io,
                .workspace = c.workspace,
                .tool_output_bytes = c.cfg.limits.tool_output_bytes,
                .shell_seconds = c.cfg.limits.turn_seconds,
                .secrets = c.secret_list,
                .search_url = c.cfg.search.url,
                .search_key = c.secrets.search,
                .path_var = c.path_var,
                .home = c.home_var,
                .system_vars = c.system_vars,
                .stop = flag,
                .browser = c.browser,
                .browser_seconds = c.cfg.browser.seconds,
                .tmp_root = c.paths.state,
            },
            .limits = c.cfg.limits,
            .top_size = c.cfg.memory.top_size,
            .utc_offset = c.cfg.chat.utc_offset,
            .scheduled = scheduled,
            // on from the start stays on for the run; the switches are read again when used
            .private = c.switches.private.load(.acquire),
            .switches = &c.switches,
            .label = label,
            .model_cfg = if (c.secrets.omnigate) |key| .{
                .url = c.cfg.model.url,
                .key = key,
                .main = c.cfg.model.model,
                .worker = c.cfg.model.worker_model,
                .memory = c.cfg.model.memory_model,
                .max_tokens = c.cfg.model.max_tokens,
            } else null,
            .agents = c.cfg.agents,
            .pool = &c.helper_pool,
            .ask_lock = &c.ask_lock,
            .skills_dir = c.paths.skills,
            .mcp = c.mcp_tools,
            .money = c.cfg.money,
            .money_ledger = &c.money_ledger,
            .dry_run = c.switches.dry_run.load(.acquire),
            .logins = c.login_list,
            .store = c.store,
            .profiles_dir = c.paths.profiles,
            .masks = &c.masks,
        };
    }

    /// Starts the MCP servers and looks for a browser. Call after setting
    /// `path_var` and `home_var`: the servers get them.
    pub fn startExtras(c: *Core) void {
        c.findBrowser();
        c.stopMcp();
        c.startMcp();
    }

    fn findBrowser(c: *Core) void {
        c.browser = (page.findBrowser(c.settings_arena.allocator(), c.io, c.cfg.browser.path, "", c.path_var) catch null) orelse "";
    }

    // ---- MCP servers ----

    /// One server being started, on a thread of its own.
    const McpStart = struct {
        core: *Core,
        cfg: mcp.ServerConfig,
        values: []const []const u8 = &.{},
        dir: []const u8 = "",
        timeout_ms: u32 = 0,
        stop: *std.atomic.Value(bool),
        /// Why it was not even tried.
        skipped: ?[]const u8 = null,
        srv: ?*mcp.Server = null,
        err: anyerror = error.NotStarted,
        diag: mcp.Diag = .{},

        fn run(st: *McpStart) void {
            const c = st.core;
            st.srv = mcp.Server.start(c.gpa, c.io, st.cfg, .{
                .cwd = st.dir,
                .path_var = c.path_var,
                .home = c.home_var,
                .system_vars = c.system_vars,
                .secret_values = st.values,
                .start_timeout_ms = st.timeout_ms,
                .diag = &st.diag,
                .stop = st.stop,
            }) catch |e| {
                st.err = e;
                return;
            };
        }
    };

    /// Starts the servers in mcp.ini, all at once under one deadline
    /// (`mcp_start_ms`); one that fails is noted and skipped. /stop and a
    /// signal cut the starts short.
    fn startMcp(c: *Core) void {
        c.mcp_starting.store(true, .release);
        defer c.mcp_starting.store(false, .release);
        c.mcp_arena = .init(c.gpa);
        c.mcp_tools = &.{};
        c.mcp_note = "";
        c.mcp_warn = "";
        const a = c.mcp_arena.allocator();
        const text = Io.Dir.cwd().readFileAlloc(c.io, c.paths.mcp, a, .limited(1 << 20)) catch return;
        const cfgs = mcp.parseConfig(a, text) catch {
            const why = (parseProblem(a, "mcp.ini", text, mcp.parseConfig) catch null) orelse "mcp.ini has an error";
            c.mcp_note = std.fmt.allocPrint(a, "{s}; no servers started.", .{why}) catch "mcp.ini has an error; no servers started.";
            // said at start too (as "note: mcp.ini: line 5 has …"): the owner fixes the file
            c.mcp_warn = if (std.mem.startsWith(u8, c.mcp_note, "mcp.ini ")) c.mcp_note["mcp.ini ".len..] else c.mcp_note;
            return;
        };
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        const starts = a.alloc(McpStart, cfgs.len) catch return;
        const threads = a.alloc(?std.Thread, cfgs.len) catch return;
        const deadline = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, c.mcp_start_ms) * std.time.ns_per_ms;
        for (cfgs, starts, threads) |sc, *st, *th| {
            st.* = .{ .core = c, .cfg = sc, .stop = &flag };
            th.* = null;
            const values = a.alloc([]const u8, sc.secrets.len) catch {
                st.skipped = "out of memory";
                continue;
            };
            for (sc.secrets, values) |es, *v| v.* = c.secretValue(a, es.secret) orelse {
                st.skipped = std.fmt.allocPrint(a, "secret \"{s}\" is not stored (harness secret add {s})", .{ es.secret, es.secret }) catch "a secret is not stored";
                break;
            };
            if (st.skipped != null) continue;
            st.values = values;
            st.dir = c.mcpDir(a, sc.name) catch |e| {
                st.skipped = std.fmt.allocPrint(a, "did not start (its folder: {s})", .{@errorName(e)}) catch "did not start";
                continue;
            };
            const left_ms = @divFloor(deadline - Io.Clock.awake.now(c.io).nanoseconds, std.time.ns_per_ms);
            st.timeout_ms = @intCast(std.math.clamp(left_ms, 1, std.math.maxInt(u32)));
            th.* = std.Thread.spawn(.{}, McpStart.run, .{st}) catch blk: {
                st.run();
                break :blk null;
            };
        }
        for (threads) |th| if (th) |x| x.join();

        // said and kept in mcp.ini's order
        var note: std.ArrayList(u8) = .empty;
        var warn: std.ArrayList(u8) = .empty;
        var all: std.ArrayList(agent.McpTool) = .empty;
        for (starts) |*st| {
            const name = st.cfg.name;
            if (st.skipped) |why| {
                note.print(a, "{s}: {s}\n", .{ name, why }) catch {};
                continue;
            }
            const srv = st.srv orelse {
                // a server may print its key when it fails: mask before keeping
                var sc_mask = scrub.Scrubber.init(a, c.masks.snapshot(a) catch c.secret_list) catch continue;
                const detail = sc_mask.scrubAlloc(a, st.diag.text()) catch "";
                note.print(a, "{s}: did not start ({s}) {s}\n", .{ name, @errorName(st.err), util.cut(detail, 200) }) catch {};
                c.log.write(.config, false, .{ .event = "mcp failed", .server = name, .why = @errorName(st.err), .detail = detail }) catch {};
                continue;
            };
            // the money list is checked against what the server offers
            // before the server is kept: a name it doesn't have stops it
            const offer = agent.mcpTools(a, srv, st.cfg, c.cfg.money, all.items) catch agent.Offer{ .tools = &.{}, .refused = "out of memory" };
            if (offer.refused) |why| {
                srv.deinit();
                note.print(a, "{s}: not started: {s}\n", .{ name, why }) catch {};
                warn.print(a, "{s}: not started: {s}\n", .{ name, why }) catch {};
                c.log.write(.config, false, .{ .event = "mcp refused", .server = name, .why = why }) catch {};
                continue;
            }
            {
                c.mcp_mutex.lockUncancelable(c.io);
                defer c.mcp_mutex.unlock(c.io);
                c.mcp_servers.append(c.gpa, srv) catch {
                    srv.deinit();
                    continue;
                };
            }
            all.appendSlice(a, offer.tools) catch {};
            note.print(a, "{s} ({d} tools)\n{s}", .{ name, offer.tools.len, offer.notes }) catch {};
            warn.appendSlice(a, offer.notes) catch {};
            c.log.write(.config, false, .{ .event = "mcp started", .server = name, .tools = offer.tools.len, .notes = offer.notes }) catch {};
        }
        c.mcp_tools = all.items;
        c.mcp_note = note.items;
        c.mcp_warn = warn.items;
    }

    /// A stored secret for an MCP server: one read at start, else from the
    /// store now (a secret added since, picked up by /reload), which is
    /// then masked like the others. Null when none is stored.
    fn secretValue(c: *Core, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
        if (c.secrets.get(name)) |v| return v;
        const st = c.store orelse return null;
        const v = (st.get(c.io, a, name) catch null) orelse return null;
        // never handed to a server unless it is masked from now on
        c.masks.add(name, v) catch return null;
        return v;
    }

    /// A folder of the server's own, state/mcp/NAME (0700): never the
    /// workspace, where what the agent writes would become the server's
    /// code or settings.
    fn mcpDir(c: *Core, a: std.mem.Allocator, name: []const u8) ![]const u8 {
        const base = try std.fs.path.join(a, &.{ c.paths.state, "mcp" });
        const dir = try std.fs.path.join(a, &.{ base, name });
        try Io.Dir.cwd().createDirPath(c.io, dir);
        if (builtin.os.tag != .windows) for ([_][]const u8{ base, dir }) |d| {
            // iterate: on Linux a plain open is O_PATH, and fchmod on it fails with EBADF
            var h = try Io.Dir.cwd().openDir(c.io, d, .{ .iterate = true });
            defer h.close(c.io);
            try h.setPermissions(c.io, .fromMode(0o700));
        };
        return dir;
    }

    fn stopMcp(c: *Core) void {
        const list = blk: {
            c.mcp_mutex.lockUncancelable(c.io);
            defer c.mcp_mutex.unlock(c.io);
            const l = c.mcp_servers;
            c.mcp_servers = .empty;
            break :blk l;
        };
        var servers = list;
        for (servers.items) |srv| srv.deinit();
        servers.deinit(c.gpa);
        c.mcp_tools = &.{};
        c.mcp_note = "";
        c.mcp_warn = "";
        c.mcp_arena.deinit();
    }

    /// Kills the MCP servers' processes, each with its group, freeing
    /// nothing (for endBySignal, while other threads may still hold them).
    fn killMcp(c: *Core) void {
        c.mcp_mutex.lockUncancelable(c.io);
        defer c.mcp_mutex.unlock(c.io);
        for (c.mcp_servers.items) |srv| srv.kill();
    }

    fn chatTurn(c: *Core, text: []const u8) void {
        if (c.reset_conv.swap(false, .acq_rel)) {
            c.conv.deinit();
            c.conv = .init(c.gpa);
            c.memory_upto = 0;
        }
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        var ask: ChatAsk = .{ .core = c, .flag = &flag };
        var run = c.baseRun(&c.chat_client, "chat", false, &flag);
        run.asker = .{ .ctx = &ask, .ask = askOwner };
        run.notice = .{ .ctx = c, .say = noticeSay };
        const res = agent.turn(&run, &c.conv, text, true) catch |e| {
            var buf: [128]u8 = undefined;
            c.say(std.fmt.bufPrint(&buf, "Something went wrong: {s}", .{@errorName(e)}) catch "Something went wrong.");
            return;
        };
        defer agent.freeResult(&run, res);
        // /private switched on while the turn ran: it stays out of memory
        // and summaries too
        const private = run.isPrivate();
        if (private) if (c.conv.turns.getLastOrNull()) |tn| {
            tn.private = true;
        };
        if (!res.stopped) c.say(res.text);
        if (!private) c.turns_since_memory += 1;
    }

    const memory_prompt =
        \\From the conversation below, list at most 5 lasting facts about the owner or their wishes that would help in later conversations: preferences, standing instructions, projects, people. One per line, each starting with "- ". Leave out passing details, anything already obvious, and anything already in memory. If there is nothing worth keeping, answer NONE.
    ;
    /// Most of the conversation one writer call reads; the newest turns are
    /// kept.
    const memory_transcript_max = 60_000;
    /// Most of the memory items it is shown, so it does not repeat them.
    const memory_known_max = 8_000;

    /// The quiet-time writer: one model call over the turns since its last
    /// run (not private ones), which picks up to 5 lasting facts.
    fn writeMemories(c: *Core) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const turns = c.conv.turns.items;
        const first_new = c.memory_upto -| c.conv.dropped;
        // newest first, so a long talk keeps its latest part
        var parts: std.ArrayList([]const u8) = .empty;
        var size: usize = 0;
        var i = turns.len;
        while (i > first_new) {
            i -= 1;
            const tn = turns[i];
            if (tn.private) continue;
            var one: std.ArrayList(u8) = .empty;
            for (tn.messages.items) |m| for (m.blocks) |b| if (b == .text and !std.mem.startsWith(u8, b.text, agent.context_mark)) {
                try one.print(a, "{s}: {s}\n", .{ if (m.role == .user) "Owner" else "Agent", util.cut(b.text, 2000) });
            };
            if (size + one.items.len > memory_transcript_max) break;
            size += one.items.len;
            try parts.append(a, one.items);
        }
        const upto = c.conv.dropped + turns.len;
        if (parts.items.len == 0) {
            c.memory_upto = upto;
            return;
        }
        var msg: std.ArrayList(u8) = .empty;
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            const known = try c.mem.levels(a, c.now(), c.cfg.memory.top_size);
            var known_size: usize = 0;
            for (known) |r| {
                const line = util.cut(r.item.body, 300);
                if (known_size + line.len > memory_known_max) break;
                if (known_size == 0) try msg.appendSlice(a, "Already in memory:\n");
                known_size += line.len;
                try msg.print(a, "- {s}\n", .{line});
            }
        }
        if (msg.items.len > 0) try msg.append(a, '\n');
        try msg.appendSlice(a, "The conversation:\n");
        var j = parts.items.len;
        while (j > 0) {
            j -= 1;
            try msg.appendSlice(a, parts.items[j]);
        }
        var client = try model.Client.init(c.gpa, c.io, c.cfg.model.url, c.secrets.omnigate orelse "", c.cfg.model.memory_model, 1024);
        defer client.deinit();
        const reply = client.send(a, memory_prompt, &.{.{ .role = .user, .blocks = &.{.{ .text = msg.items }} }}, &.{}) catch |e| {
            // the same turns are read again next time
            try c.log.write(.model, false, .{ .run = "memory writer", .result = @errorName(e) });
            return;
        };
        c.memory_upto = upto;
        try c.log.write(.model, false, .{ .run = "memory writer", .result = "ok", .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens });
        const out = try reply.text(a);
        var it = std.mem.splitScalar(u8, out, '\n');
        var n: usize = 0;
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, l, "- ") or n >= 5) continue;
            // switched on while the writer's call ran
            if (c.switches.private.load(.acquire)) break;
            n += 1;
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            const res = c.mem.addFrom(l[2..], null, c.now(), .other) catch continue;
            try c.log.write(.memory, false, .{ .event = if (res.merged) "known" else "add", .id = res.id, .by = "memory writer" });
            // the owner sees what goes into every later prompt
            if (!res.merged) if (c.mem.find(res.id)) |item| c.say(try memory.savedNote(a, item.id, item.body));
        }
    }

    fn noticeSay(ctx: *anyopaque, text: []const u8) void {
        const c: *Core = @ptrCast(@alignCast(ctx));
        c.say(text);
    }

    // ---- stop ----

    pub fn stopAll(c: *Core) []const u8 {
        const chat_busy = c.busy.load(.acquire);
        const bg = c.bg_active.load(.acquire);
        var dropped: usize = 0;
        {
            c.queue_mutex.lockUncancelable(c.io);
            defer c.queue_mutex.unlock(c.io);
            for (c.queue.items) |q| c.gpa.free(q);
            dropped = c.queue.items.len;
            c.queue.clearRetainingCapacity();
        }
        c.stopRuns();
        // by the clock: a 20 ms sleep lasts longer than that on Windows
        const until = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, c.stop_wait_ms) * std.time.ns_per_ms;
        while ((c.busy.load(.acquire) or c.bg_active.load(.acquire) > 0) and Io.Clock.awake.now(c.io).nanoseconds < until) c.io.sleep(.fromMilliseconds(20), .awake) catch {};
        // Commands and their processes end at once. A model call under way
        // cannot be cut off: the owner is not kept waiting for it, and is
        // told (the run's stop flag stays set, so nothing follows it).
        const still = c.busy.load(.acquire) or c.bg_active.load(.acquire) > 0;
        c.log.write(.chat, false, .{ .event = "stop", .chat_turn = chat_busy, .background_runs = bg, .queued_dropped = dropped, .still_ending = still }) catch {};
        if (!chat_busy and bg == 0 and dropped == 0) return "Nothing was running.";
        if (still) return "Stopped. A model call already under way ends on its own; its answer is dropped and nothing it asked for runs.";
        return "Stopped everything that was running.";
    }

    /// SIGINT or SIGTERM (on Windows the console's Ctrl-C, Ctrl-Break or
    /// close): what /stop does, then what close does that matters outside
    /// this process — the log, the status, the MCP servers' processes and
    /// the lock. Nothing is freed: the caller ends the process right after.
    pub fn endBySignal(c: *Core, what: []const u8) void {
        c.quitting.store(true, .release);
        c.stop.store(true, .release);
        c.log.write(.config, false, .{ .event = "signal", .signal = what }) catch {};
        _ = c.stopAll();
        // servers being started end their starts at the stop; then all go
        var waited: u32 = 0;
        while (c.mcp_starting.load(.acquire) and waited < 3000) : (waited += 20) c.io.sleep(.fromMilliseconds(20), .awake) catch {};
        c.killMcp();
        c.log.write(.config, false, .{ .event = "stop" }) catch {};
        c.writeStatus() catch {};
        c.releaseFolder();
    }

    // ---- scheduler ----

    fn localDay(c: *const Core, now_s: i64) i64 {
        return @divFloor(now_s + @as(i64, c.cfg.chat.utc_offset) * 60, 86400);
    }

    fn localMinutes(c: *const Core, now_s: i64) i64 {
        return @divFloor(@mod(now_s + @as(i64, c.cfg.chat.utc_offset) * 60, 86400), 60);
    }

    /// Called every few seconds: due briefs and tasks start, the status
    /// file is refreshed, changed settings are noticed.
    pub fn tick(c: *Core) void {
        const now_s = c.now();
        if (util.nowSeconds(c.io) - c.last_status_s >= 30) {
            c.last_status_s = util.nowSeconds(c.io);
            c.writeStatus() catch {};
            c.checkSettingsChanged();
        }
        if (c.stop.load(.acquire)) return;
        c.settings_mutex.lockUncancelable(c.io);
        defer c.settings_mutex.unlock(c.io);
        const today = c.localDay(now_s);
        const minutes = c.localMinutes(now_s);
        for (c.briefs) |b| {
            if (minutes < b.at_minutes) continue;
            const key = keyFor("brief", b.name);
            if ((c.getRan(key.slice()) orelse -1) >= today) continue;
            if (c.retryLater(key.slice(), now_s)) continue;
            _ = c.startBackground(.{ .brief = b }, key.slice(), now_s);
        }
        const weekday = util.weekday(today);
        for (c.tasks) |tk| {
            const key = keyFor("task", tk.name);
            if (c.isPaused(tk.name)) continue;
            const last = c.getRan(key.slice());
            if (tk.every_minutes) |every| {
                if (last) |l| if (now_s - l < @as(i64, every) * 60) continue;
            } else if (tk.at_minutes) |at| {
                if (tk.days & (@as(u7, 1) << weekday) == 0) continue;
                if (minutes < at) continue;
                if (last) |l| if (c.localDay(l) >= today) continue;
            }
            if (c.retryLater(key.slice(), now_s)) continue;
            _ = c.startBackground(.{ .task = tk }, key.slice(), now_s);
        }
    }

    /// Whether `key`'s last message did not get through and it waits
    /// before it runs again.
    fn retryLater(c: *Core, key: []const u8, now_s: i64) bool {
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        const r = c.retry.get(key) orelse return false;
        return now_s < r.at;
    }

    const Key = struct {
        buf: [96]u8 = undefined,
        len: usize = 0,
        fn slice(k: *const Key) []const u8 {
            return k.buf[0..k.len];
        }
    };

    fn keyFor(kind: []const u8, name: []const u8) Key {
        var k: Key = .{};
        const got = std.fmt.bufPrint(&k.buf, "{s}:{s}", .{ kind, util.cut(name, 80) }) catch k.buf[0..0];
        k.len = got.len;
        return k;
    }

    fn getRan(c: *Core, key: []const u8) ?i64 {
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        return c.ran.get(key);
    }

    fn isPaused(c: *Core, name: []const u8) bool {
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        return c.paused.contains(name);
    }

    const Job = union(enum) { brief: config.Brief, task: config.Task };

    const Start = enum { started, already_running, restarting, slots_taken, failed };

    /// Starts a brief or task found due at `due_s`, unless it is running
    /// already or the background slots are taken.
    fn startBackground(c: *Core, job: Job, key: []const u8, due_s: i64) Start {
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        if (c.running.contains(key)) return .already_running;
        // the next tick starts it once the MCP servers are back
        if (c.restarting.load(.acquire)) return .restarting;
        // the chat keeps one of the slots
        const slots = @max(1, c.cfg.limits.concurrent_runs) - 1;
        if (c.bg_active.load(.acquire) >= @max(1, slots)) return .slots_taken;
        putKey(c.gpa, &c.running, key, {}) catch return .failed;
        _ = c.bg_active.fetchAdd(1, .acq_rel);
        const owned_key = c.running.getKey(key).?;
        const th = std.Thread.spawn(.{}, background, .{ c, job, owned_key, due_s }) catch {
            _ = c.bg_active.fetchSub(1, .acq_rel);
            removeKey(c.gpa, &c.running, key);
            return .failed;
        };
        th.detach();
        return .started;
    }

    fn background(c: *Core, job: Job, key: []const u8, due_s: i64) void {
        defer {
            c.state_mutex.lockUncancelable(c.io);
            removeKey(c.gpa, &c.running, key);
            c.state_mutex.unlock(c.io);
            _ = c.bg_active.fetchSub(1, .acq_rel);
        }
        // a run that failed or was stopped still counts for its slot, so
        // the scheduler does not start it again right away
        const outcome: Outcome = switch (job) {
            .brief => |b| c.runBrief(b) catch .done,
            .task => |tk| c.runTask(tk) catch .done,
        };
        const now_s = c.now();
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        if (outcome == .undelivered) {
            // not counted as run: again in 5 minutes, then 10, 20, … 2 hours
            const tries: u32 = if (c.retry.get(key)) |r| r.tries + 1 else 1;
            const wait = @min(@as(i64, 5 * 60) << @intCast(@min(tries - 1, 8)), 2 * 3600);
            putKey(c.gpa, &c.retry, key, Retry{ .at = now_s + wait, .tries = tries }) catch {};
            return;
        }
        removeKey(c.gpa, &c.retry, key);
        // the day it was due, though it may have ended after midnight
        const v: i64 = switch (job) {
            .brief => c.localDay(due_s),
            .task => due_s,
        };
        putKey(c.gpa, &c.ran, key, v) catch {};
        c.saveRan();
    }

    /// How a brief or task run ended, for the scheduler.
    pub const Outcome = enum {
        /// Done, failed or stopped: it waits for its next time.
        done,
        /// Its message did not get through: it runs again a little later.
        undelivered,
    };

    /// Collects, writes and sends a brief. Its items count as seen only
    /// once it got through.
    pub fn runBrief(c: *Core, b: config.Brief) !Outcome {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client = try model.Client.init(c.gpa, c.io, c.cfg.model.url, c.secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens);
        defer client.deinit();
        const label = try std.fmt.allocPrint(a, "brief {s}", .{b.name});
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        var run = c.baseRun(&client, label, true, &flag);
        // a copy, so the fetches hold no lock
        var snap = blk: {
            c.seen_mutex.lockUncancelable(c.io);
            defer c.seen_mutex.unlock(c.io);
            break :blk try c.seen.clone();
        };
        defer snap.deinit();
        const collected = try brief.collect(&run, a, b, &snap);
        if (flag.load(.acquire)) return .done;
        const w = try brief.compose(&run, a, b, collected);
        if (flag.load(.acquire)) return .done;
        c.deliver(w.text) catch |e| {
            try c.log.write(.brief, false, .{ .name = b.name, .event = "not delivered", .why = whyUndelivered(e) });
            return if (worthRetry(e)) .undelivered else .done;
        };
        c.seen_mutex.lockUncancelable(c.io);
        defer c.seen_mutex.unlock(c.io);
        const now_s = c.now();
        for (w.links) |l| try c.seen.add(l, now_s);
        c.seen.prune(now_s);
        c.seen.save(c.io, c.paths.seen) catch {};
        return .done;
    }

    /// Runs a scheduled task once.
    pub fn runTask(c: *Core, tk: config.Task) !Outcome {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client = try model.Client.init(c.gpa, c.io, c.cfg.model.url, c.secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens);
        defer client.deinit();
        const label = try std.fmt.allocPrint(a, "task {s}", .{tk.name});
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        var run = c.baseRun(&client, label, true, &flag);
        run.extra_instructions = try std.fmt.allocPrint(a, "This is the scheduled task \"{s}\". If there is nothing worth telling the owner this time, answer exactly NOTHING.", .{tk.name});
        var skipped: agent.Skipped = .init(c.gpa);
        defer skipped.deinit();
        run.skipped = &skipped;
        run.notice = .{ .ctx = c, .say = noticeSay };
        var conv: agent.Conversation = .init(c.gpa);
        defer conv.deinit();
        try c.log.write(.task, false, .{ .name = tk.name, .event = "start" });
        const res = try agent.turn(&run, &conv, tk.do, false);
        defer agent.freeResult(&run, res);
        if (res.stopped) return .done;
        if (res.ended_by) |why| if (std.mem.eql(u8, why, "Model budget used up.")) {
            {
                c.state_mutex.lockUncancelable(c.io);
                defer c.state_mutex.unlock(c.io);
                putKey(c.gpa, &c.paused, tk.name, {}) catch {};
                c.saveRan();
            }
            try c.log.write(.task, false, .{ .name = tk.name, .event = "paused", .why = why });
            c.say(try std.fmt.allocPrint(a, "Task {s} is paused: model budget used up. Send /task resume {s} to start it again.", .{ tk.name, tk.name }));
            return .done;
        };
        const answer = std.mem.trim(u8, res.text, " \t\r\n.");
        const silent = std.mem.eql(u8, answer, "NOTHING");
        // what it could not do without the owner is said even then
        const note = try skipped.text(c.io, a);
        if (silent and note.len == 0) {
            try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = "the answer was NOTHING" });
            return .done;
        }
        const msg = if (silent)
            try std.fmt.allocPrint(a, "[{s}] {s}", .{ tk.name, note })
        else
            try std.fmt.allocPrint(a, "[{s}] {s}{s}{s}", .{ tk.name, res.text, if (note.len > 0) "\n\n" else "", note });
        c.deliver(msg) catch |e| {
            try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = whyUndelivered(e) });
            return if (worthRetry(e)) .undelivered else .done;
        };
        try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = true });
        return .done;
    }

    // ---- commands ----

    const help_text =
        \\Commands
        \\/stop: stop everything running now
        \\/new: start a new conversation (memory stays)
        \\/status: what is running and the switches
        \\/brief [NAME]: send a brief now
        \\/topics: list brief topics
        \\/topic add NAME | feed URL | search: words
        \\/topic rm NAME
        \\/tasks: list scheduled tasks
        \\/task add NAME | every 15m | instruction   (or: at 07:00)
        \\/task rm NAME, /task resume NAME
        \\/memory: list memories by level
        \\/memory auto on|off: automatic recall
        \\/remember TEXT, /pin ID, /unpin ID, /forget ID
        \\/private on|off: no memories written while on
        \\/skills: list saved skills, /skill rm NAME
        \\/logins: the agent's own logins
        \\/dryrun on|off: money tools are not called while on
        \\/reload: apply changed settings files
    ;

    pub fn command(c: *Core, a: std.mem.Allocator, text: []const u8) ![]const u8 {
        var words = std.mem.tokenizeAny(u8, text, " \t");
        const cmd = words.next() orelse return "";
        const rest = std.mem.trim(u8, words.rest(), " \t");
        try c.log.write(.chat, c.switches.private.load(.acquire), .{ .event = "command", .command = cmd, .args = rest });
        const eql = std.mem.eql;
        if (eql(u8, cmd, "/help") or eql(u8, cmd, "/start")) return help_text;
        if (eql(u8, cmd, "/pair")) return "Already paired.";
        if (eql(u8, cmd, "/stop")) return c.stopAll();
        if (eql(u8, cmd, "/new")) {
            c.reset_conv.store(true, .release);
            return "New conversation.";
        }
        if (eql(u8, cmd, "/reload")) return c.reload();
        if (eql(u8, cmd, "/status")) {
            return std.fmt.allocPrint(a, "Chat: {s}. Background runs: {d}. Queued: {d}.\nAutomatic recall: {s}. Private: {s}. Dry run: {s}.\nBrowser: {s}. Logins: {d}.{s}{s}", .{
                if (c.busy.load(.acquire)) "working" else "idle", c.bg_active.load(.acquire), c.queue.items.len,
                onOff(c.switches.auto_recall.load(.acquire)), onOff(c.switches.private.load(.acquire)),
                onOff(c.switches.dry_run.load(.acquire)),
                if (c.browser.len == 0) "none found" else if (builtin.os.tag == .windows) "found (web not available on Windows yet)" else "found",
                c.login_list.len,
                if (c.mcp_note.len > 0) "\nMCP: " else "",
                std.mem.trimEnd(u8, c.mcp_note, "\n"),
            });
        }
        if (eql(u8, cmd, "/dryrun")) {
            const v = config.parseBool(rest) orelse return "Use /dryrun on or /dryrun off.";
            c.switches.dry_run.store(v, .release);
            c.saveSwitches();
            try c.log.write(.config, false, .{ .event = "dry run", .on = v });
            return if (v) "Dry run is on: tools that move money are not called; the agent is told what would have been sent." else "Dry run is off: approved money calls are made.";
        }
        if (eql(u8, cmd, "/memory")) {
            if (rest.len == 0) {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                return c.mem.render(a, c.now(), c.cfg.memory.top_size);
            }
            if (std.mem.startsWith(u8, rest, "auto ")) {
                const v = config.parseBool(std.mem.trim(u8, rest[5..], " ")) orelse return "Use /memory auto on or /memory auto off.";
                c.switches.auto_recall.store(v, .release);
                c.saveSwitches();
                return if (v) "Automatic recall is on." else "Automatic recall is off. Pinned items still apply; I look things up only when asked.";
            }
            return "Use /memory, or /memory auto on|off.";
        }
        if (eql(u8, cmd, "/private")) {
            const v = config.parseBool(rest) orelse return "Use /private on or /private off.";
            c.switches.private.store(v, .release);
            c.saveSwitches();
            return if (v) "Private: nothing from this chat is written to memory, and the log keeps only sizes and hashes." else "Private is off.";
        }
        if (eql(u8, cmd, "/remember")) {
            if (rest.len == 0) return "Use /remember TEXT.";
            if (c.switches.private.load(.acquire)) return "Not saved: private is on, so nothing is written to memory. Send /private off first.";
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            const res = try c.mem.add(rest, null, c.now());
            try c.log.write(.memory, false, .{ .event = if (res.merged) "mention" else "add", .id = res.id, .by = "owner" });
            return std.fmt.allocPrint(a, "{s} {s}.", .{ if (res.merged) "Already known; counted again as" else "Remembered as", res.id });
        }
        if (eql(u8, cmd, "/pin") or eql(u8, cmd, "/unpin") or eql(u8, cmd, "/forget")) {
            if (rest.len == 0) return "Give the memory's id, as /memory lists it.";
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            const ok = if (eql(u8, cmd, "/forget")) try c.mem.forget(rest) else try c.mem.setPinned(rest, eql(u8, cmd, "/pin"));
            try c.log.write(.memory, false, .{ .event = cmd[1..], .id = rest, .found = ok });
            if (!ok) return "No memory with that id.";
            return if (eql(u8, cmd, "/forget")) "Forgotten." else if (eql(u8, cmd, "/pin")) "Pinned: it applies in every conversation." else "Unpinned.";
        }
        if (eql(u8, cmd, "/topics")) {
            var out: std.ArrayList(u8) = .empty;
            for (c.briefs) |b| {
                try out.print(a, "{s} at {d:0>2}:{d:0>2}\n", .{ b.name, b.at_minutes / 60, b.at_minutes % 60 });
                for (b.topics) |tp| try out.print(a, "  {s}\n", .{try config.formatTopic(a, tp)});
            }
            return if (out.items.len > 0) out.items else "No briefs yet. Add a topic with /topic add NAME | feed URL | search: words";
        }
        if (eql(u8, cmd, "/topic")) return c.topicCommand(a, rest);
        if (eql(u8, cmd, "/brief")) {
            if (c.briefs.len == 0) return "No briefs set up.";
            const b = for (c.briefs) |b| {
                if (rest.len == 0 or eql(u8, b.name, rest)) break b;
            } else return "No brief with that name.";
            const key = keyFor("brief-now", b.name);
            c.settings_mutex.lockUncancelable(c.io);
            defer c.settings_mutex.unlock(c.io);
            return switch (c.startBackground(.{ .brief = b }, key.slice(), c.now())) {
                .started => "Collecting.",
                .already_running => "That brief is being collected already.",
                .restarting => "Settings are being reloaded. Send /brief again in a moment.",
                .slots_taken => "Busy: another brief or task is running. Send /brief again when it is done.",
                .failed => "Could not start the brief.",
            };
        }
        if (eql(u8, cmd, "/tasks")) {
            var out: std.ArrayList(u8) = .empty;
            for (c.tasks) |tk| {
                if (tk.every_minutes) |e| try out.print(a, "{s}: every {d}m", .{ tk.name, e }) else try out.print(a, "{s}: at {d:0>2}:{d:0>2}", .{ tk.name, tk.at_minutes.? / 60, tk.at_minutes.? % 60 });
                try out.print(a, "{s}\n  {s}\n", .{ if (c.isPaused(tk.name)) " (paused)" else "", tk.do });
            }
            return if (out.items.len > 0) out.items else "No scheduled tasks. Add one with /task add NAME | every 15m | instruction";
        }
        if (eql(u8, cmd, "/task")) return c.taskCommand(a, rest);
        if (eql(u8, cmd, "/logins")) return c.loginsText(a);
        if (eql(u8, cmd, "/skills")) {
            const list = try skills.list(a, c.io, c.paths.skills);
            if (list.len == 0) return "No skills yet. The agent saves one (with your approval) when it learns how to do a kind of task.";
            var out: std.ArrayList(u8) = .empty;
            for (list) |sk| try out.print(a, "{s}: {s}\n", .{ sk.name, sk.description });
            return out.items;
        }
        if (eql(u8, cmd, "/skill")) {
            if (std.mem.startsWith(u8, rest, "rm ")) {
                const name = std.mem.trim(u8, rest[3..], " ");
                if (try skills.remove(c.io, c.paths.skills, name)) {
                    try c.log.write(.config, false, .{ .event = "skill removed", .name = name });
                    return "Removed.";
                }
                return "No such skill.";
            }
            return "Use /skills or /skill rm NAME.";
        }
        return "Unknown command. Send /help for the list.";
    }

    /// One line per login: what is stored for it (never the values).
    pub fn loginsText(c: *Core, a: std.mem.Allocator) ![]const u8 {
        if (c.login_list.len == 0) return "No logins. Add one with: harness login add NAME --site HOST --username U";
        var out: std.ArrayList(u8) = .empty;
        for (c.login_list) |l| {
            const st = loginState(c.io, a, c.store, l.name);
            try out.print(a, "{s}: {s}, username {s}, password {s}, TOTP {s}, passkeys {d}\n", .{ l.name, l.site, if (l.username.len > 0) l.username else "(none)", if (st.password) "yes" else "no", if (st.totp) "yes" else "no", st.passkeys });
        }
        return out.items;
    }

    fn appendSettingsLine(c: *Core, path: []const u8, text: []const u8) !void {
        var f = try Io.Dir.cwd().createFile(c.io, path, .{ .truncate = false, .permissions = util.private_file });
        defer f.close(c.io);
        const len = try f.length(c.io);
        try f.writePositionalAll(c.io, text, len);
    }

    /// Writes a settings file and applies it, keeping the change detector quiet.
    fn rewriteSettings(c: *Core, path: []const u8, text: []const u8) ![]const u8 {
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = text });
        const r = try c.reload();
        if (std.mem.startsWith(u8, r, "Busy")) return "Saved; it applies after /reload when nothing is running.";
        if (!std.mem.startsWith(u8, r, "Settings reloaded")) return r;
        return "";
    }

    fn topicCommand(c: *Core, a: std.mem.Allocator, rest: []const u8) ![]const u8 {
        const old = Io.Dir.cwd().readFileAlloc(c.io, c.paths.briefs, a, .limited(1 << 20)) catch "";
        if (std.mem.startsWith(u8, rest, "add ")) {
            const topic = config.parseTopic(a, rest[4..]) catch return "Use /topic add NAME | feed URL | search: words";
            const line = try config.formatTopic(a, topic);
            const text = if (c.briefs.len == 0)
                try std.fmt.allocPrint(a, "{s}\n[morning]\nat = 07:00\n{s}\n", .{ old, line })
            else
                try insertInSection(a, old, c.briefs[0].name, line);
            const r = try c.rewriteSettings(c.paths.briefs, text);
            try c.log.write(.config, false, .{ .event = "topic added", .line = line });
            return if (r.len > 0) r else std.fmt.allocPrint(a, "Added to the {s} brief: {s}", .{ if (c.briefs.len > 0) c.briefs[0].name else "morning", topic.name });
        }
        if (std.mem.startsWith(u8, rest, "rm ")) {
            const name = std.mem.trim(u8, rest[3..], " ");
            var out: std.ArrayList(u8) = .empty;
            var found = false;
            var it = std.mem.splitScalar(u8, old, '\n');
            var first = true;
            while (it.next()) |line| {
                const tl = std.mem.trim(u8, line, " \t");
                if (std.mem.startsWith(u8, tl, "topic")) {
                    if (std.mem.indexOfScalar(u8, tl, '=')) |eq| {
                        const tp = config.parseTopic(a, tl[eq + 1 ..]) catch null;
                        if (tp != null and std.mem.eql(u8, tp.?.name, name)) {
                            found = true;
                            continue;
                        }
                    }
                }
                if (!first) try out.append(a, '\n');
                first = false;
                try out.appendSlice(a, line);
            }
            if (!found) return "No topic with that name.";
            const r = try c.rewriteSettings(c.paths.briefs, out.items);
            try c.log.write(.config, false, .{ .event = "topic removed", .name = name });
            return if (r.len > 0) r else "Removed.";
        }
        return "Use /topic add NAME | feed URL | search: words, or /topic rm NAME.";
    }

    fn taskCommand(c: *Core, a: std.mem.Allocator, rest: []const u8) ![]const u8 {
        const old = Io.Dir.cwd().readFileAlloc(c.io, c.paths.tasks, a, .limited(1 << 20)) catch "";
        if (std.mem.startsWith(u8, rest, "add ")) {
            var parts = std.mem.splitScalar(u8, rest[4..], '|');
            const name = std.mem.trim(u8, parts.next() orelse "", " ");
            const when = std.mem.trim(u8, parts.next() orelse "", " ");
            const do = std.mem.trim(u8, parts.rest(), " ");
            if (name.len == 0 or do.len == 0 or std.mem.indexOfAny(u8, name, "[]\n") != null) return "Use /task add NAME | every 15m | instruction (or at 07:00).";
            const when_line = if (std.mem.startsWith(u8, when, "every "))
                try std.fmt.allocPrint(a, "every = {s}", .{std.mem.trim(u8, when[6..], " ")})
            else if (std.mem.startsWith(u8, when, "at "))
                try std.fmt.allocPrint(a, "at = {s}", .{std.mem.trim(u8, when[3..], " ")})
            else
                return "Say when: every 15m, or at 07:00.";
            for (c.tasks) |tk| if (std.mem.eql(u8, tk.name, name)) return "A task with that name exists.";
            const text = try std.fmt.allocPrint(a, "{s}\n[{s}]\n{s}\ndo = {s}\n", .{ old, name, when_line, std.mem.replaceOwned(u8, a, do, "\n", " ") catch do });
            _ = config.parseTasks(a, text) catch return "That task is not valid (every is at least 5m; at is HH:MM).";
            const r = try c.rewriteSettings(c.paths.tasks, text);
            try c.log.write(.config, false, .{ .event = "task added", .name = name });
            return if (r.len > 0) r else "Added.";
        }
        if (std.mem.startsWith(u8, rest, "rm ")) {
            const name = std.mem.trim(u8, rest[3..], " ");
            const text = removeSection(a, old, name) catch return "No task with that name.";
            const r = try c.rewriteSettings(c.paths.tasks, text);
            try c.log.write(.config, false, .{ .event = "task removed", .name = name });
            return if (r.len > 0) r else "Removed.";
        }
        if (std.mem.startsWith(u8, rest, "resume ")) {
            const name = std.mem.trim(u8, rest[7..], " ");
            c.state_mutex.lockUncancelable(c.io);
            defer c.state_mutex.unlock(c.io);
            if (!c.paused.contains(name)) return "That task is not paused.";
            removeKey(c.gpa, &c.paused, name);
            c.saveRan();
            try c.log.write(.task, false, .{ .name = name, .event = "resumed" });
            return "Resumed.";
        }
        return "Use /task add, /task rm NAME or /task resume NAME.";
    }
};

/// Adds `line` at the end of section `name` in INI `text`.
fn insertInSection(a: std.mem.Allocator, text: []const u8, name: []const u8, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var in_section = false;
    var done = false;
    var first = true;
    while (it.next()) |l| {
        const tl = std.mem.trim(u8, l, " \t\r");
        if (tl.len > 0 and tl[0] == '[') {
            if (in_section and !done) {
                try out.print(a, "{s}{s}", .{ if (first) "" else "\n", line });
                first = false;
                done = true;
            }
            in_section = std.mem.eql(u8, std.mem.trim(u8, tl[1 .. tl.len - 1], " "), name);
        }
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, l);
    }
    if (!done) {
        while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
        try out.print(a, "\n{s}\n", .{line});
    }
    return out.items;
}

/// The settings files other users must not be able to change: they decide
/// what runs (rules, MCP servers' commands) and where values are typed.
pub fn guardedFiles(p: Paths) [4][]const u8 {
    return .{ p.config, p.rules, p.logins, p.mcp };
}

/// What is wrong with the settings files, said so the owner can fix it:
/// the file other users can change, or the file and line that does not
/// read. Null when nothing is.
pub fn settingsProblem(io: Io, a: std.mem.Allocator, p: Paths) !?[]const u8 {
    if (builtin.os.tag != .windows) {
        for (guardedFiles(p)) |path| {
            const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
            if (st.permissions.toMode() & 0o022 != 0)
                return try std.fmt.allocPrint(a, "{s} can be changed by other users; run chmod 600 {s} (config.ini, rules, logins.ini and mcp.ini must be writable only by you)", .{ path, path });
        }
    }
    inline for (.{
        .{ p.config, config.parse },
        .{ p.rules, rules.parse },
        .{ p.briefs, config.parseBriefs },
        .{ p.tasks, config.parseTasks },
        .{ p.logins, logins.parse },
    }) |item| {
        const text = Io.Dir.cwd().readFileAlloc(io, item[0], a, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => "",
            else => return try std.fmt.allocPrint(a, "{s} can't be read: {s}", .{ item[0], @errorName(e) }),
        };
        if (try parseProblem(a, std.fs.path.basename(item[0]), text, item[1])) |why| return why;
    }
    return null;
}

/// "rules line 3 has an error: alow shell ls"; null when `text` reads.
pub fn parseProblem(a: std.mem.Allocator, name: []const u8, text: []const u8, comptime parseFn: anytype) !?[]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    if (parseFn(scratch.allocator(), text)) |_| return null else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }
    const n = badLine(&scratch, text, parseFn);
    if (n == 0) return try std.fmt.allocPrint(a, "{s} has an error", .{name});
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: []const u8 = "";
    for (0..n) |_| line = it.next() orelse "";
    // what the parser says of that line (the lines up to it are fine)
    _ = scratch.reset(.retain_capacity);
    const why: ?[]const u8 = if (parseFn(scratch.allocator(), text[0 .. it.index orelse text.len])) |_| null else |e| rules.reason(e) orelse mcp.configReason(e);
    return try std.fmt.allocPrint(a, "{s} line {d} has an error: {s}{s}{s}{s}", .{ name, n, util.cut(std.mem.trim(u8, line, " \t\r"), 80), if (why != null) " (" else "", why orelse "", if (why != null) ")" else "" });
}

/// The first line of `text` that does not read: the one after the longest
/// start of the text that still parses (an unfinished section counts from
/// its header). 0 for files too long to search this way.
fn badLine(scratch: *std.heap.ArenaAllocator, text: []const u8, comptime parseFn: anytype) usize {
    // ends[j]: where the first j lines end
    var ends: [2001]usize = undefined;
    ends[0] = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| nl + 1 else text.len;
        n += 1;
        if (n >= ends.len) return 0;
        ends[n] = end;
        i = end;
    }
    var j = n;
    while (j > 0) {
        j -= 1;
        _ = scratch.reset(.retain_capacity);
        if (parseFn(scratch.allocator(), text[0..ends[j]])) |_| return j + 1 else |_| {}
    }
    return 1;
}

pub const LoginState = struct { password: bool = false, totp: bool = false, passkeys: usize = 0, passkeys_stored: bool = false };

/// What the key store holds for a login.
pub fn loginState(io: Io, a: std.mem.Allocator, store: ?store_mod.Store, name: []const u8) LoginState {
    const st = store orelse return .{};
    var out: LoginState = .{};
    var nb: [96]u8 = undefined;
    if (st.get(io, a, logins.secretName(&nb, name, .password)) catch null) |v| {
        out.password = true;
        std.crypto.secureZero(u8, v);
    }
    if (st.get(io, a, logins.secretName(&nb, name, .totp)) catch null) |v| {
        out.totp = true;
        std.crypto.secureZero(u8, v);
    }
    if (st.get(io, a, logins.secretName(&nb, name, .passkeys)) catch null) |v| {
        out.passkeys_stored = true;
        out.passkeys = if (logins.decode(a, v)) |l| l.len else |_| 0;
        std.crypto.secureZero(u8, v);
    }
    return out;
}

pub fn removeSection(a: std.mem.Allocator, text: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var skipping = false;
    var found = false;
    var first = true;
    while (it.next()) |l| {
        const tl = std.mem.trim(u8, l, " \t\r");
        if (tl.len > 1 and tl[0] == '[' and tl[tl.len - 1] == ']') {
            skipping = std.mem.eql(u8, std.mem.trim(u8, tl[1 .. tl.len - 1], " "), name);
            if (skipping) found = true;
        }
        if (skipping) continue;
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, l);
    }
    if (!found) return error.NotFound;
    return out.items;
}

/// When a brief or task whose message did not get through runs again.
const Retry = struct { at: i64, tries: u32 };

/// Why a message did not get to the owner, in words for the log.
fn whyUndelivered(e: anyerror) []const u8 {
    return switch (e) {
        error.NotPaired => "not paired yet",
        error.NoChannel => "nothing to send it through",
        else => @errorName(e),
    };
}

/// Whether a message that did not get through is worth sending again
/// later: not while there is nobody to send it to.
fn worthRetry(e: anyerror) bool {
    return e != error.NotPaired and e != error.NoChannel;
}

fn putKey(gpa: std.mem.Allocator, map: anytype, key: []const u8, v: anytype) !void {
    if (map.getPtr(key)) |p| {
        p.* = v;
        return;
    }
    const k = try gpa.dupe(u8, key);
    errdefer gpa.free(k);
    try map.put(gpa, k, v);
}

fn removeKey(gpa: std.mem.Allocator, map: anytype, key: []const u8) void {
    if (map.fetchRemove(key)) |kv| gpa.free(kv.key);
}

fn freeKeys(gpa: std.mem.Allocator, map: anytype) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    map.deinit(gpa);
}

fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}

fn readOwner(io: Io, path: []const u8) ?i64 {
    var buf: [32]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, got, " \n"), 10) catch null;
}

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

pub fn pidNumber() i64 {
    return switch (builtin.os.tag) {
        .windows => GetCurrentProcessId(),
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

/// Takes the data folder for this process: an exclusive lock on
/// state/lock, held as long as the file is open and dropped by the system
/// when the process ends, however it ends. error.AlreadyRunning while
/// another process holds it, or another core of this one.
pub fn takeLock(io: Io, p: Paths) !Io.File {
    try Io.Dir.cwd().createDirPath(io, p.state);
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const f = Io.Dir.cwd().createFile(io, p.lock, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = util.private_file,
        }) catch |e| switch (e) {
            // `health` looks at it for a moment; a running instance keeps it
            error.WouldBlock => {
                if (tries >= 10) return error.AlreadyRunning;
                io.sleep(.fromMilliseconds(30), .awake) catch {};
                continue;
            },
            else => return e,
        };
        // the pid, for people (on Windows others can't read the locked first byte)
        var b: [32]u8 = undefined;
        f.setLength(io, 0) catch {};
        f.writePositionalAll(io, std.fmt.bufPrint(&b, "{d}\n", .{pidNumber()}) catch "", 0) catch {};
        return f;
    }
}

/// Whether some process holds the data folder (`takeLock`).
pub fn lockHeld(io: Io, p: Paths) bool {
    const f = Io.Dir.cwd().openFile(io, p.lock, .{}) catch return false;
    defer f.close(io);
    const got = f.tryLock(io, .shared) catch return false;
    if (got) f.unlock(io);
    return !got;
}

pub const Health = struct { ok: bool, text: []const u8 };

/// What `harness health` says: ok only while `harness run` holds the
/// folder (its lock, not just a lock file left behind) and has ticked in
/// the last 90 s.
pub fn health(io: Io, p: Paths, now_s: i64, buf: []u8) Health {
    if (!lockHeld(io, p)) return .{ .ok = false, .text = "not running" };
    var sbuf: [256]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, p.status, &sbuf) catch return .{ .ok = false, .text = "the folder is held, but its status file can't be read" };
    const role = statusField(got, "role") orelse "";
    if (!std.mem.eql(u8, role, "run"))
        return .{ .ok = false, .text = std.fmt.bufPrint(buf, "not running: harness {s} holds the folder, not harness run", .{if (role.len > 0) role else "(an older one)"}) catch "not running" };
    const tick = util.parseIso(statusField(got, "tick") orelse "") orelse return .{ .ok = false, .text = "no tick in the status file" };
    const age = now_s - tick;
    if (age > 90) return .{ .ok = false, .text = std.fmt.bufPrint(buf, "stale: last tick {d} s ago", .{age}) catch "stale" };
    return .{ .ok = true, .text = std.fmt.bufPrint(buf, "running: last tick {d} s ago", .{age}) catch "running" };
}

/// The value of a `key value` line of the status file.
fn statusField(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len > key.len and std.mem.startsWith(u8, line, key) and line[key.len] == ' ') return std.mem.trim(u8, line[key.len + 1 ..], " \r");
    }
    return null;
}

/// Writes a pairing code valid for 10 minutes; returns it.
pub fn newPairCode(io: Io, p: Paths, now_s: i64, out: *[8]u8) ![]const u8 {
    var raw: [8]u8 = undefined;
    try io.randomSecure(&raw);
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    for (out, raw) |*ch, r| ch.* = alphabet[r % alphabet.len];
    var buf: [64]u8 = undefined;
    try Io.Dir.cwd().createDirPath(io, p.state);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p.pair, .data = try std.fmt.bufPrint(&buf, "{s} {d}\n", .{ out, now_s + 600 }) });
    return out;
}

fn checkPairCode(io: Io, path: []const u8, code: []const u8, now_s: i64) bool {
    var buf: [64]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, path, &buf) catch return false;
    const sp = std.mem.indexOfScalar(u8, got, ' ') orelse return false;
    const want = got[0..sp];
    const until = std.fmt.parseInt(i64, std.mem.trim(u8, got[sp + 1 ..], " \n"), 10) catch return false;
    if (now_s > until) return false;
    if (want.len != code.len or code.len != 8) return false;
    var diff: u8 = 0;
    for (want, code) |x, y| diff |= x ^ std.ascii.toUpper(y);
    return diff == 0;
}

// ---- tests ----

const t = std.testing;

const Recorder = struct {
    mutex: Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    next_id: i64 = 0,
    /// While set, sends fail with it and nothing is recorded.
    fail: ?anyerror = null,
    /// The last question's buttons and the message they are in.
    last: Buttons = .{},
    /// Called once buttons are recorded, before their message id is
    /// returned: an owner who presses before harness knows the message.
    early: ?Early = null,

    const Early = struct { ctx: *anyopaque, press: *const fn (ctx: *anyopaque, b: *const Buttons) void };

    const Buttons = struct {
        msg: i64 = 0,
        n: usize = 0,
        buf: [3][64]u8 = undefined,
        len: [3]usize = @splat(0),

        /// The data of the button that answers `which` ("once", "day", "deny").
        fn get(b: *const Buttons, which: []const u8) ?[]const u8 {
            for (0..b.n) |i| {
                const d = b.buf[i][0..b.len[i]];
                const colon = std.mem.lastIndexOfScalar(u8, d, ':') orelse continue;
                if (std.mem.eql(u8, d[colon + 1 ..], which)) return d;
            }
            return null;
        }
    };

    fn deinit(r: *Recorder) void {
        for (r.lines.items) |l| t.allocator.free(l);
        r.lines.deinit(t.allocator);
    }

    fn channel(r: *Recorder) Channel {
        return .{ .ctx = r, .send = send, .buttons = buttons, .clear = clear, .send_to = sendTo };
    }

    fn sendTo(ctx: *anyopaque, chat_id: i64, text: []const u8) anyerror!void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        try r.lines.append(t.allocator, try std.fmt.allocPrint(t.allocator, "TO {d}: {s}", .{ chat_id, text }));
    }

    fn setFail(r: *Recorder, e: ?anyerror) void {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        r.fail = e;
    }

    fn send(ctx: *anyopaque, text: []const u8) anyerror!void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        if (r.fail) |e| return e;
        try r.lines.append(t.allocator, try t.allocator.dupe(u8, text));
    }

    fn buttons(ctx: *anyopaque, text: []const u8, bs: []const [2][]const u8) ?i64 {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const shown = blk: {
            r.mutex.lockUncancelable(t.io);
            defer r.mutex.unlock(t.io);
            const line = std.fmt.allocPrint(t.allocator, "BUTTONS {s} [{s}]", .{ text, bs[0][1] }) catch return null;
            r.lines.append(t.allocator, line) catch {};
            r.next_id += 1;
            r.last = .{ .msg = r.next_id, .n = @min(bs.len, 3) };
            for (bs[0..r.last.n], 0..) |b, i| {
                r.last.len[i] = @min(b[1].len, 64);
                @memcpy(r.last.buf[i][0..r.last.len[i]], b[1][0..r.last.len[i]]);
            }
            break :blk r.last;
        };
        if (r.early) |e| e.press(e.ctx, &shown);
        return shown.msg;
    }

    fn clear(ctx: *anyopaque, id: i64) void {
        _ = ctx;
        _ = id;
    }

    /// Waits until some line contains `needle`.
    fn waitFor(r: *Recorder, needle: []const u8) !void {
        var waited: u32 = 0;
        while (waited < 8000) : (waited += 20) {
            {
                r.mutex.lockUncancelable(t.io);
                defer r.mutex.unlock(t.io);
                for (r.lines.items) |l| if (std.mem.indexOf(u8, l, needle) != null) return;
            }
            t.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        std.debug.print("waited for {s}; got:\n", .{needle});
        for (r.lines.items) |l| std.debug.print("  {s}\n", .{l});
        return error.TestTimedOut;
    }

    fn count(r: *Recorder, needle: []const u8) usize {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        var n: usize = 0;
        for (r.lines.items) |l| if (std.mem.indexOf(u8, l, needle) != null) {
            n += 1;
        };
        return n;
    }
};

const Fix = struct {
    e: model.TestEnv,
    home: []const u8,
    rec: Recorder = .{},
    core: *Core,

    fn init(f: *Fix, extra_config: []const u8, briefs_text: []const u8, tasks_text: []const u8) !void {
        try f.e.init();
        const a = f.e.arena.allocator();
        f.home = try std.fs.path.join(a, &.{ f.e.dir, "home" });
        try initHome(t.io, a, f.home);
        const p = try Paths.init(a, f.home);
        const cfg = try std.fmt.allocPrint(a, "[model]\nurl = {s}\n[search]\nurl = {s}\n{s}", .{ try f.e.url(), try f.e.url(), extra_config });
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.config, .data = cfg });
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.briefs, .data = briefs_text });
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.tasks, .data = tasks_text });
        f.rec = .{};
        f.core = try Core.open(t.allocator, t.io, f.home, .{ .omnigate = "og-key-for-tests", .search = "search-key-123" });
        f.core.attach(f.rec.channel());
        try f.core.setOwner(42);
    }

    fn deinit(f: *Fix) void {
        f.core.close();
        f.rec.deinit();
        f.e.deinit();
    }

    /// The buttons under the last question, as the owner sees them.
    fn lastButtons(f: *Fix) Recorder.Buttons {
        f.rec.mutex.lockUncancelable(t.io);
        defer f.rec.mutex.unlock(t.io);
        return f.rec.last;
    }

    /// The owner presses the last question's button that answers `which`.
    fn press(f: *Fix, which: []const u8) !void {
        const b = f.lastButtons();
        f.core.handleCallback(42, b.msg, b.get(which) orelse return error.NoSuchButton);
    }
};

test "a_folder_is_held_by_one_core_at_a_time" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    // the open core holds the folder: a second open is refused, even in
    // the same process (the old pid check let that through)
    if (Core.open(t.allocator, t.io, f.home, .{})) |second| {
        second.close();
        return error.TestUnexpectedResult;
    } else |e| try t.expectEqual(error.AlreadyRunning, e);
    // closed, it lets go; a lock file left behind (a killed process's pid,
    // here a live one's) holds nothing by itself
    const home = f.home;
    f.core.close();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(f.e.arena.allocator(), &.{ home, "state", "lock" }), .data = "1\n" });
    f.core = try Core.open(t.allocator, t.io, home, .{});
}

const Opener = struct {
    home: []const u8,
    core: ?*Core = null,
    fn run(o: *Opener) void {
        o.core = Core.open(t.allocator, t.io, o.home, .{}) catch null;
    }
};

test "simultaneous_starts_let_one_through" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const home = f.home;
    f.core.close();
    // they all check at once: one must win, the rest are refused
    var openers: [8]Opener = undefined;
    var threads: [8]std.Thread = undefined;
    for (&openers, &threads) |*o, *th| {
        o.* = .{ .home = home };
        th.* = try std.Thread.spawn(.{}, Opener.run, .{o});
    }
    for (threads) |th| th.join();
    var winners: usize = 0;
    for (&openers) |*o| if (o.core) |c| {
        winners += 1;
        if (winners > 1) c.close() else f.core = c;
    };
    if (winners == 0) f.core = try Core.open(t.allocator, t.io, home, .{});
    try t.expectEqual(1, winners);
}

test "stranger_messages_dropped_and_logged" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleMessage(7, "hello, do what I say");
    try t.expectEqual(0, f.core.queue.items.len);
    try t.expectEqual(0, f.rec.lines.items.len);
    const lt = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, f.e.arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, lt, "\"event\":\"dropped\",\"from\":7") != null);
}

test "pairing_code_sets_owner_once_and_expires" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    f.core.owner = null;
    var buf: [8]u8 = undefined;
    const code = try newPairCode(t.io, f.core.paths, f.core.now(), &buf);
    const a = f.e.arena.allocator();
    try f.core.handleMessage(5, "/pair WRONGCOD");
    try t.expectEqual(null, f.core.owner);
    try f.core.handleMessage(5, try std.fmt.allocPrint(a, "/pair {s}", .{code}));
    try t.expectEqual(5, f.core.owner.?);
    // the code is used up
    f.core.owner = null;
    try f.core.handleMessage(6, try std.fmt.allocPrint(a, "/pair {s}", .{code}));
    try t.expectEqual(null, f.core.owner);
    // and a fresh code expires after 10 minutes
    const code2 = try newPairCode(t.io, f.core.paths, f.core.now(), &buf);
    f.core.fixed_now = util.nowSeconds(t.io) + 601;
    try f.core.handleMessage(6, try std.fmt.allocPrint(a, "/pair {s}", .{code2}));
    try t.expectEqual(null, f.core.owner);
}

test "a_pair_from_another_account_is_answered_and_a_fresh_code_pairs_it" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.core.handleMessage(77, "/pair ABCDEFGH");
    try f.rec.waitFor("TO 77: This bot is paired with another account. To pair a new one, its owner runs `harness pair` where harness runs and sends the code it prints from that account.");
    try t.expectEqual(42, f.core.owner.?);
    // the owner runs `harness pair` and sends the code from the new account
    var buf: [8]u8 = undefined;
    const code = try newPairCode(t.io, f.core.paths, f.core.now(), &buf);
    try f.core.handleMessage(77, try std.fmt.allocPrint(a, "/pair {s}", .{code}));
    try t.expectEqual(77, f.core.owner.?);
    try t.expectEqual(77, readOwner(t.io, f.core.paths.owner).?);
    try f.rec.waitFor("TO 42: This bot is now paired with another account");
    try f.rec.waitFor("Paired. I answer only you from now on.");
    // the old account is a stranger now
    try f.core.handleMessage(42, "hello?");
    try t.expectEqual(0, f.core.queue.items.len);
}

test "message_during_turn_is_queued" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const slow = comptime "{\"delay_ms\":600," ++ model.textReply("first answer")[1..];
    try f.e.script(1, slow);
    try f.e.script(2, model.textReply("second answer"));
    try f.core.startWorker();
    try f.core.handleText("first");
    t.io.sleep(.fromMilliseconds(150), .awake) catch {};
    try f.core.handleText("second");
    try f.rec.waitFor("Queued; /stop cancels the current turn.");
    try f.rec.waitFor("second answer");
    try t.expectEqual(1, f.rec.count("first answer"));
}

test "text_during_approval_is_queued_button_answers" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo approved-run\"}"));
    try f.e.script(2, model.textReply("ran it"));
    try f.e.script(3, model.textReply("answer to the queued text"));
    try f.core.startWorker();
    try f.core.handleText("run echo");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo approved-run [");
    try f.core.handleText("what about this?");
    try f.rec.waitFor("Queued");
    try t.expect(f.core.approvalWaiting());
    const b = f.lastButtons();
    f.core.handleCallback(99, b.msg, b.get("once").?); // not the owner: ignored
    t.io.sleep(.fromMilliseconds(100), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    try t.expectEqual(0, f.rec.count("out of date"));
    try f.press("once");
    try f.rec.waitFor("ran it");
    try f.rec.waitFor("answer to the queued text");
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "approved-run") != null);
}

test "a_long_question_goes_whole_in_parts_with_the_buttons_on_the_last" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const ys = try a.alloc(u8, 6000);
    @memset(ys, 'y');
    try f.e.script(1, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"shell\",\"input\":{{\"command\":\"echo {s} end-of-it\"}}}}],\"stop_reason\":\"tool_use\"}}", .{ys}));
    try f.e.script(2, model.textReply("not run"));
    try f.core.startWorker();
    try f.core.handleText("run the long one");
    try f.rec.waitFor("BUTTONS Allow this? (2/2)\n");
    var whole: std.ArrayList(u8) = .empty;
    {
        f.rec.mutex.lockUncancelable(t.io);
        defer f.rec.mutex.unlock(t.io);
        try t.expectEqual(2, f.rec.lines.items.len);
        const first = f.rec.lines.items[0];
        const last = f.rec.lines.items[1];
        try t.expect(std.mem.startsWith(u8, first, "Allow this? (1/2)\n"));
        try t.expect(first.len <= 4096);
        // "BUTTONS " and " [a1:once]" are the recorder's
        const last_text = last["BUTTONS ".len .. std.mem.lastIndexOf(u8, last, " [").?];
        try t.expect(last_text.len <= 4096);
        try whole.appendSlice(a, first["Allow this? (1/2)\n".len..]);
        try whole.appendSlice(a, last_text["Allow this? (2/2)\n".len..]);
    }
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "shell: echo {s} end-of-it", .{ys}), whole.items);
    try f.press("deny");
    try f.rec.waitFor("not run");
}

test "the_owner_is_waited_for_only_until_the_turn_ends" {
    var f: Fix = undefined;
    try f.init("[limits]\nturn_seconds = 2\n", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo late\"}"));
    try f.e.script(2, model.textReply("never asked for"));
    try f.core.startWorker();
    try f.core.handleText("run it");
    try f.rec.waitFor("BUTTONS Allow this?");
    // approval_seconds is 10 minutes; the turn has 2 s
    try f.rec.waitFor("No answer in time; not allowed.");
}

/// Closes the core and opens the folder again, as a restart does.
fn restart(f: *Fix) !void {
    f.core.close();
    f.core = try Core.open(t.allocator, t.io, f.home, .{ .omnigate = "og-key-for-tests", .search = "search-key-123" });
    f.core.attach(f.rec.channel());
}

const out_of_date = "That button is out of date: it answers nothing.";

test "approval_numbers_go_on_after_a_restart_and_an_old_button_answers_nothing" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(2, model.textReply("first done"));
    try f.core.startWorker();
    try f.core.handleText("one");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo one [a1");
    const old = f.lastButtons();
    try f.press("once");
    try f.rec.waitFor("first done");
    // a restart: the buttons under the old question may still be in the chat
    try restart(&f);
    // pressed with nothing asked
    f.core.handleCallback(42, old.msg, old.get("once").?);
    try f.rec.waitFor(out_of_date);
    try f.e.script(3, model.toolReply("tu_2", "shell", "{\"command\":\"echo two\"}"));
    try f.e.script(4, model.textReply("second done"));
    try f.core.startWorker();
    try f.core.handleText("two");
    // the numbers go on from before the restart
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo two [a2");
    // pressed while another question waits: it answers nothing either
    f.core.handleCallback(42, old.msg, old.get("once").?);
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    try t.expectEqual(2, f.rec.count(out_of_date));
    try f.press("deny");
    try f.rec.waitFor("second done");
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "denied by the owner") != null);
}

test "a_button_from_before_a_restart_answers_nothing_even_with_the_same_number_and_message" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(2, model.textReply("first done"));
    try f.core.startWorker();
    try f.core.handleText("one");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo one");
    const old = f.lastButtons();
    try f.press("deny");
    try f.rec.waitFor("first done");
    // a restart with the numbers lost (a state folder restored from a
    // backup) and a chat whose message ids are the same again: only the
    // instance's nonce tells the old button from the new one
    f.core.close();
    try Io.Dir.cwd().deleteFile(t.io, try std.fs.path.join(f.e.arena.allocator(), &.{ f.home, "state", "approvals" }));
    f.core = try Core.open(t.allocator, t.io, f.home, .{ .omnigate = "og-key-for-tests", .search = "search-key-123" });
    f.core.attach(f.rec.channel());
    f.rec.next_id = old.msg - 1;
    try f.e.script(3, model.toolReply("tu_2", "shell", "{\"command\":\"echo two\"}"));
    try f.e.script(4, model.textReply("second done"));
    try f.core.startWorker();
    try f.core.handleText("two");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo two [a1");
    const now = f.lastButtons();
    try t.expectEqual(old.msg, now.msg);
    try t.expect(!std.mem.eql(u8, old.get("once").?, now.get("once").?));
    f.core.handleCallback(42, old.msg, old.get("once").?);
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    try f.rec.waitFor(out_of_date);
    try f.press("deny");
    try f.rec.waitFor("second done");
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "denied by the owner") != null);
}

test "a_press_counts_only_in_the_message_its_question_was_sent_in" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(2, model.toolReply("tu_2", "shell", "{\"command\":\"echo two\"}"));
    try f.e.script(3, model.textReply("both asked"));
    try f.core.startWorker();
    try f.core.handleText("one, then two");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo one");
    const first = f.lastButtons();
    // the question's own data, but from another message
    f.core.handleCallback(42, first.msg + 7, first.get("once").?);
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    try f.rec.waitFor(out_of_date);
    try f.press("deny");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo two");
    // a button under the question before answers nothing
    f.core.handleCallback(42, first.msg, first.get("once").?);
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    try t.expectEqual(2, f.rec.count(out_of_date));
    try f.press("deny");
    try f.rec.waitFor("both asked");
    try t.expectEqual(2, std.mem.count(u8, try f.e.request(3), "denied by the owner"));
}

/// Presses "Allow once" before the channel has returned the buttons'
/// message id, from message `id + offset`.
const EarlyPress = struct {
    core: *Core,
    offset: std.atomic.Value(i64) = .init(0),

    fn press(ctx: *anyopaque, b: *const Recorder.Buttons) void {
        const ep: *EarlyPress = @ptrCast(@alignCast(ctx));
        ep.core.handleCallback(42, b.msg + ep.offset.load(.acquire), b.get("once").?);
    }
};

test "a_press_before_the_message_id_is_known_is_checked_once_it_is" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(2, model.toolReply("tu_2", "shell", "{\"command\":\"echo early-two\"}"));
    try f.e.script(3, model.textReply("done"));
    var ep: EarlyPress = .{ .core = f.core };
    ep.offset.store(5, .release);
    f.rec.early = .{ .ctx = &ep, .press = EarlyPress.press };
    try f.core.startWorker();
    try f.core.handleText("one, then two");
    // pressed in another message: out of date once the message is known
    try f.rec.waitFor(out_of_date);
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    // pressed in the question's own message: it answers
    ep.offset.store(0, .release);
    try f.press("deny");
    try f.rec.waitFor("done");
    try t.expectEqual(1, f.rec.count(out_of_date));
    const req3 = try f.e.request(3);
    try t.expectEqual(1, std.mem.count(u8, req3, "denied by the owner"));
    try t.expect(std.mem.indexOf(u8, req3, "early-two") != null);
}

test "closing_the_terminal_denies_the_question_and_any_after_it" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo one\"}"));
    try f.e.script(2, model.toolReply("tu_2", "shell", "{\"command\":\"echo two\"}"));
    try f.e.script(3, model.textReply("gave up"));
    try f.core.startWorker();
    try f.core.handleText("run both");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo one");
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    f.core.closeQuestions();
    try f.rec.waitFor("gave up");
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - start < 3 * std.time.ns_per_s);
    // the second call was not asked at all
    try t.expectEqual(1, f.rec.count("BUTTONS"));
    try t.expectEqual(2, std.mem.count(u8, try f.e.request(3), "denied by the owner"));
}

test "stop_ends_running_turn_and_reports" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell sleep *\n" });
    _ = try f.core.reload();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"sleep 30\"}"));
    try f.e.script(2, model.textReply("never"));
    try f.core.startWorker();
    try f.core.handleText("sleep a while");
    var waited: u32 = 0;
    while (!f.core.busy.load(.acquire) and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    try f.core.handleText("/stop");
    try f.rec.waitFor("Stopped everything that was running.");
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - start < 5 * std.time.ns_per_s);
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqual(0, f.core.run_flags.items.len);
}

test "missed_brief_runs_once_on_start" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/z.xml", .data = "<rss><channel><item><title>New thing</title><link>https://z.org/1</link></item></channel></rss>" });
    // due at midnight: already past whenever the test runs
    const bt = try std.fmt.allocPrint(f.e.arena.allocator(), "[morning]\nat = 00:00\ntopic = Zig | {s}/page/z.xml\n", .{try f.e.url()});
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.briefs, .data = bt });
    _ = try f.core.reload();
    try f.e.script(1, model.textReply("Zig: New thing (https://z.org/1)"));
    f.core.tick();
    try f.rec.waitFor("Zig: New thing (https://z.org/1)");
    var waited: u32 = 0;
    while (f.core.bg_active.load(.acquire) > 0 and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    f.core.tick();
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try t.expectEqual(1, f.rec.count("New thing"));
    try t.expectEqual(1, f.e.server.modelRequests());
}

test "config_change_needs_reload" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const old_steps = f.core.cfg.limits.steps_per_turn;
    const text = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.config, f.e.arena.allocator(), .unlimited);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.config, .data = try std.fmt.allocPrint(f.e.arena.allocator(), "{s}[limits]\nsteps_per_turn = 99\n", .{text}) });
    f.core.last_status_s = 0;
    f.core.tick();
    try f.rec.waitFor("not applied until you send /reload");
    try t.expectEqual(old_steps, f.core.cfg.limits.steps_per_turn);
    try f.core.handleText("/reload");
    try f.rec.waitFor("Settings reloaded.");
    try t.expectEqual(99, f.core.cfg.limits.steps_per_turn);
}

test "topic_add_writes_briefs_ini_and_logs" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleText("/topic add Zig | https://ziglang.org/news/index.xml | search: zig release");
    try f.rec.waitFor("Added to the morning brief: Zig");
    try t.expectEqual(1, f.core.briefs.len);
    try t.expectEqualStrings("https://ziglang.org/news/index.xml", f.core.briefs[0].topics[0].feeds[0]);
    try f.core.handleText("/topic add Rust | https://blog.rust-lang.org/feed.xml");
    try f.rec.waitFor("Added to the morning brief: Rust");
    try t.expectEqual(2, f.core.briefs[0].topics.len);
    try f.core.handleText("/topic rm Zig");
    try f.rec.waitFor("Removed.");
    try t.expectEqual(1, f.core.briefs[0].topics.len);
    const lt = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, f.e.arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, lt, "\"event\":\"topic added\"") != null);
    // the change detector stays quiet: the change came through chat
    f.core.last_status_s = 0;
    f.core.tick();
    try t.expectEqual(0, f.rec.count("not applied"));
}

test "task_every_runs_and_nothing_answer_is_silent" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\ndo = Check the price.\n");
    defer f.deinit();
    try f.e.script(1, model.textReply("NOTHING"));
    f.core.tick();
    var waited: u32 = 0;
    while (f.e.server.modelRequests() < 1 and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    while (f.core.bg_active.load(.acquire) > 0 and waited < 6000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try t.expectEqual(0, f.rec.lines.items.len);
    // not again within 5 minutes
    f.core.tick();
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expectEqual(1, f.e.server.modelRequests());
    // after 5 minutes it runs and this time has something to say
    try f.e.script(2, model.textReply("Price moved 4%."));
    f.core.fixed_now = util.nowSeconds(t.io) + 301;
    f.core.tick();
    try f.rec.waitFor("[check] Price moved 4%.");
    const req = try f.e.request(1);
    try t.expect(std.mem.indexOf(u8, req, "scheduled task") != null);
}

test "task_paused_after_budget_spent_until_resume" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\ndo = Check the price.\n");
    defer f.deinit();
    try f.e.script(1, "{\"status\":402}");
    f.core.tick();
    try f.rec.waitFor("Task check is paused: model budget used up.");
    var waited: u32 = 0;
    while (f.core.bg_active.load(.acquire) > 0 and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    f.core.fixed_now = util.nowSeconds(t.io) + 3600;
    f.core.tick();
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expectEqual(1, f.e.server.modelRequests());
    try f.core.handleText("/task resume check");
    try f.rec.waitFor("Resumed.");
    try f.e.script(2, model.textReply("Back."));
    f.core.tick();
    try f.rec.waitFor("[check] Back.");
}

test "log_that_grew_after_the_last_status_is_not_a_warning" {
    var f: Fix = undefined;
    try f.init("", "", "");
    const home = f.home;
    const a = f.e.arena.allocator();
    const p = try Paths.init(a, home);
    f.core.close();
    // the killed run wrote more after its last status
    {
        var l = try log_mod.Log.open(t.allocator, t.io, p.log);
        defer l.close();
        try l.write(.chat, false, .{ .text = "after the last status" });
    }
    f.core = try Core.open(t.allocator, t.io, home, .{});
    try t.expectEqual(null, f.core.pending_warning);
    f.core.close();
    // a status hash that is nowhere in the log is a warning
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.status, .data = "pid 1\ntick 2026-11-19T00:00:00Z\nlog abababababababababababababababababababababababababababababababab\n" });
    f.core = try Core.open(t.allocator, t.io, home, .{});
    try t.expect(f.core.pending_warning != null);
    f.core.close();
    f.rec.deinit();
    f.e.deinit();
}

fn waitFile(e: *model.TestEnv, name: []const u8) !void {
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 20) {
        if (e.tmp.dir.access(t.io, name, .{})) |_| return else |_| {}
        t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    return error.TestTimedOut;
}

/// Waits until no brief or task runs.
fn waitIdle(c: *Core) void {
    var waited: u32 = 0;
    while (c.bg_active.load(.acquire) > 0 and waited < 8000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
}

fn logText(f: *Fix) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, f.e.arena.allocator(), .unlimited);
}

/// A brief due at midnight (so due whenever the test runs) on one feed.
fn dueBrief(f: *Fix, items: []const u8) !void {
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/z.xml", .data = try std.fmt.allocPrint(a, "<rss><channel>{s}</channel></rss>", .{items}) });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.briefs, .data = try std.fmt.allocPrint(a, "[morning]\nat = 00:00\ntopic = Zig | {s}/page/z.xml\n", .{try f.e.url()}) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
}

test "an_undelivered_brief_is_not_marked_seen_and_is_tried_later" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try dueBrief(&f, "<item><title>New thing</title><link>https://z.org/1</link></item>");
    try f.e.script(1, model.textReply("Zig: New thing (https://z.org/1)"));
    f.rec.setFail(error.ConnectionClosed);
    f.core.tick();
    waitIdle(f.core);
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expect(!f.core.seen.has("https://z.org/1"));
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"event\":\"not delivered\"") != null);
    // not again at once
    f.core.tick();
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    waitIdle(f.core);
    try t.expectEqual(1, f.e.server.modelRequests());
    // a while later it runs again, and this time it arrives
    f.rec.setFail(null);
    try f.e.script(2, model.textReply("Zig: New thing, again (https://z.org/1)"));
    f.core.fixed_now = util.nowSeconds(t.io) + 15 * 60;
    f.core.tick();
    try f.rec.waitFor("New thing, again");
    waitIdle(f.core);
    try t.expect(f.core.seen.has("https://z.org/1"));
}

test "a_task_answer_that_did_not_arrive_is_logged_as_not_sent" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\ndo = Check the price.\n");
    defer f.deinit();
    f.rec.setFail(error.NotPaired);
    try f.e.script(1, model.textReply("Price moved 4%."));
    f.core.tick();
    waitIdle(f.core);
    const lt = try logText(&f);
    try t.expect(std.mem.indexOf(u8, lt, "\"event\":\"done\",\"sent\":false,\"why\":\"not paired yet\"") != null);
    try t.expect(std.mem.indexOf(u8, lt, "\"sent\":true") == null);
}

test "brief_command_says_when_it_could_not_start" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/z.xml", .data = "<rss><channel><item><title>New thing</title><link>https://z.org/1</link></item></channel></rss>" });
    const url = try f.e.url();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.briefs, .data = try std.fmt.allocPrint(a, "[morning]\nat = 07:00\ntopic = Zig | {s}/page/z.xml\n[evening]\nat = 19:00\ntopic = Zig | {s}/page/z.xml\n", .{ url, url }) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    const slow = comptime "{\"delay_ms\":1000," ++ model.textReply("Zig: New thing (https://z.org/1)")[1..];
    try f.e.script(1, slow);
    try f.core.handleText("/brief morning");
    try f.rec.waitFor("Collecting.");
    try f.core.handleText("/brief morning");
    try f.rec.waitFor("That brief is being collected already.");
    // the one background slot is taken
    try f.core.handleText("/brief evening");
    try f.rec.waitFor("Busy: ");
    try f.rec.waitFor("Zig: New thing");
    waitIdle(f.core);
    try t.expectEqual(1, f.rec.count("Collecting."));
}

test "a_scheduled_run_says_what_it_skipped_even_when_it_answers_nothing" {
    var f: Fix = undefined;
    try f.init("", "", "[disk]\nevery = 5m\ndo = Check the disk.\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"df -h\"}"));
    try f.e.script(2, model.textReply("NOTHING"));
    f.core.tick();
    try f.rec.waitFor("[disk] Skipped (needs approval): shell: df -h");
    waitIdle(f.core);
    // with an answer, the note goes after it
    try f.e.script(3, model.toolReply("tu_2", "fetch", "{\"url\":\"https://example.com/status\"}"));
    try f.e.script(4, model.textReply("Disk is fine."));
    f.core.fixed_now = util.nowSeconds(t.io) + 301;
    f.core.tick();
    try f.rec.waitFor("[disk] Disk is fine.\n\nSkipped (needs approval): fetch: https://example.com/status");
}

test "a_run_that_ends_after_midnight_counts_for_the_day_it_was_due" {
    var f: Fix = undefined;
    try f.init("", "", "[late]\nat = 23:59\ndo = Check the day.\n");
    defer f.deinit();
    const due = @divFloor(util.nowSeconds(t.io), 86400) * 86400 + 23 * 3600 + 59 * 60 + 10;
    f.core.fixed_now = due;
    const slow = comptime "{\"delay_ms\":800," ++ model.textReply("Late answer.")[1..];
    try f.e.script(1, slow);
    f.core.tick();
    try waitFile(&f.e, "requests/001.json");
    // the clock passes midnight while it runs
    f.core.fixed_now = due + 120;
    try f.rec.waitFor("[late] Late answer.");
    waitIdle(f.core);
    // so the next evening it runs again
    try f.e.script(2, model.textReply("Next day."));
    f.core.fixed_now = due + 86400;
    f.core.tick();
    try f.rec.waitFor("[late] Next day.");
}

test "stop_holds_through_a_slow_model_call" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell echo *\n" });
    _ = try f.core.reload();
    f.core.stop_wait_ms = 200;
    const slow = comptime "{\"delay_ms\":1500," ++ model.toolReply("tu_1", "shell", "{\"command\":\"echo after-stop\"}")[1..];
    try f.e.script(1, slow);
    try f.e.script(2, model.textReply("should not happen"));
    try f.core.startWorker();
    try f.core.handleText("go");
    try waitFile(&f.e, "requests/001.json");
    try f.core.handleText("/stop");
    t.io.sleep(.fromMilliseconds(2500), .awake) catch {};
    try t.expectEqual(1, f.e.server.modelRequests());
    const lt = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, f.e.arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, lt, "\"kind\":\"tool\"") == null);
}

test "stop_answers_soon_while_a_model_call_is_under_way" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    // the wait is the one a real instance has
    const slow = comptime "{\"delay_ms\":7000," ++ model.textReply("late")[1..];
    try f.e.script(1, slow);
    try f.core.startWorker();
    try f.core.handleText("go");
    try waitFile(&f.e, "requests/001.json");
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    try f.core.handleText("/stop");
    try f.rec.waitFor("Stopped. A model call already under way");
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - start < 4 * std.time.ns_per_s);
    // the call ends on its own; its answer is not said
    var waited: u32 = 0;
    while (f.core.busy.load(.acquire) and waited < 10_000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try t.expect(!f.core.busy.load(.acquire));
    try t.expectEqual(0, f.rec.count("late"));
}

test "stopped_task_does_not_restart" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\ndo = Check the price.\n");
    defer f.deinit();
    f.core.stop_wait_ms = 200;
    const slow = comptime "{\"delay_ms\":1000," ++ model.textReply("late")[1..];
    try f.e.script(1, slow);
    try f.e.script(2, model.textReply("again"));
    f.core.tick();
    try waitFile(&f.e, "requests/001.json");
    try f.core.handleText("/stop");
    var waited: u32 = 0;
    while (f.core.bg_active.load(.acquire) > 0 and waited < 5000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    f.core.tick();
    t.io.sleep(.fromMilliseconds(400), .awake) catch {};
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqual(0, f.rec.count("[check]"));
}

test "private_turns_stay_out_of_memory" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleText("/private on");
    try f.e.script(1, model.textReply("noted"));
    f.core.chatTurn("my private diagnosis xyzzy");
    try f.core.handleText("/private off");
    try f.e.script(2, model.textReply("fine"));
    f.core.chatTurn("ok then");
    try t.expectEqual(1, f.core.turns_since_memory);
    try f.e.script(3, model.textReply("- likes plain answers"));
    try f.core.writeMemories();
    const req = try f.e.request(3);
    try t.expect(std.mem.indexOf(u8, req, "xyzzy") == null);
    try t.expect(std.mem.indexOf(u8, req, "ok then") != null);
}

test "the_owner_hears_of_every_memory_the_agent_or_the_writer_saves" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.e.script(1, model.toolReply("tu_1", "remember", "{\"text\":\"The owner's sister is called Ada\"}"));
    try f.e.script(2, model.textReply("Got it."));
    f.core.chatTurn("my sister is called Ada");
    const id = f.core.mem.items.items[0].id;
    try f.rec.waitFor(try std.fmt.allocPrint(a, "Saved to memory: The owner's sister is called Ada (/forget {s})", .{id}));
    try f.e.script(3, model.textReply("- The owner plays chess on Sundays\\n- The owner's sister is called Ada"));
    try f.core.writeMemories();
    try f.rec.waitFor("Saved to memory: The owner plays chess on Sundays (/forget ");
    // what was known already is not said again
    try t.expectEqual(1, f.rec.count("sister is called Ada (/forget"));
}

test "remember_in_private_mode_says_it_is_not_saved" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleText("/private on");
    try f.core.handleText("/remember my door code is 4711");
    try f.rec.waitFor("Not saved: private is on");
    try t.expectEqual(0, f.core.mem.items.items.len);
}

test "a_turn_running_when_private_goes_on_stays_out_of_memory" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const slow = comptime "{\"delay_ms\":800," ++ model.textReply("noted")[1..];
    try f.e.script(1, slow);
    try f.core.startWorker();
    try f.core.handleText("my private plans for tomorrow");
    try waitFile(&f.e, "requests/001.json");
    try f.core.handleText("/private on");
    try f.rec.waitFor("noted");
    var waited: u32 = 0;
    while (f.core.busy.load(.acquire) and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try t.expect(f.core.conv.turns.items[f.core.conv.turns.items.len - 1].private);
    try t.expectEqual(0, f.core.turns_since_memory);
    // so the writer has nothing to read
    try f.core.writeMemories();
    try t.expectEqual(1, f.e.server.modelRequests());
}

test "private_lines_are_hashed_with_the_instance_key" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleText("/private on");
    try f.e.script(1, model.textReply("ok"));
    f.core.chatTurn("my private diagnosis xyzzy");
    const lt = try logText(&f);
    try t.expect(std.mem.indexOf(u8, lt, "xyzzy") == null);
    try t.expect(std.mem.indexOf(u8, lt, "\"text\":{\"bytes\":26,\"hmac\":\"") != null);
    if (builtin.os.tag != .windows) {
        const key_path = try std.fs.path.join(f.e.arena.allocator(), &.{ f.core.paths.state, "log-key" });
        const st = try Io.Dir.cwd().statFile(t.io, key_path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

test "secrets_the_owner_types_are_masked_in_the_log_and_memory" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const key = f.core.secrets.omnigate.?;
    const a = f.e.arena.allocator();
    try f.e.script(1, model.textReply("I will not repeat it."));
    f.core.chatTurn(try std.fmt.allocPrint(a, "my omnigate key is {s}", .{key}));
    try f.core.handleText(try std.fmt.allocPrint(a, "/remember my omnigate key is {s}", .{key}));
    try f.rec.waitFor("Remembered as");
    const lt = try logText(&f);
    try t.expect(std.mem.indexOf(u8, lt, key) == null);
    try t.expect(std.mem.indexOf(u8, lt, "my omnigate key is [secret:omnigate]") != null);
    try t.expectEqualStrings("my omnigate key is [secret:omnigate]", f.core.mem.items.items[0].body);
}

test "memory_writer_reads_only_new_turns_and_knows_what_is_kept" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.textReply("noted"));
    f.core.chatTurn("I paddle a kayak every weekend");
    try f.e.script(2, model.textReply("- The owner paddles a kayak every weekend"));
    try f.core.writeMemories();
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "I paddle a kayak every weekend") != null);
    try f.e.script(3, model.textReply("fine"));
    f.core.chatTurn("my tomatoes are ripening");
    try f.e.script(4, model.textReply("- The owner paddles a kayak every weekend"));
    try f.core.writeMemories();
    const req4 = try f.e.request(4);
    // only the turn since the last run, with what is kept already
    try t.expect(std.mem.indexOf(u8, req4, "my tomatoes are ripening") != null);
    try t.expect(std.mem.indexOf(u8, req4, "I paddle a kayak every weekend") == null);
    try t.expect(std.mem.indexOf(u8, req4, "Already in memory") != null);
    try t.expect(std.mem.indexOf(u8, req4, "The owner paddles a kayak every weekend") != null);
    // the writer repeating an item is not the owner mentioning it
    try t.expectEqual(1, f.core.mem.items.items.len);
    try t.expectEqual(1, f.core.mem.items.items[0].mentions.items.len);
}

test "memory_writer_keeps_the_newest_turns_of_a_long_talk" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const pad = try a.alloc(u8, 1900);
    @memset(pad, 'x');
    for (0..40) |i| {
        try f.e.script(@intCast(i + 1), model.textReply("ok"));
        const mark = if (i == 0) "OLDEST-TURN" else if (i == 39) "NEWEST-TURN" else "middle";
        f.core.chatTurn(try std.fmt.allocPrint(a, "{s} {s}", .{ mark, pad }));
    }
    try f.e.script(41, model.textReply("NONE"));
    try f.core.writeMemories();
    const req = try f.e.request(41);
    try t.expect(std.mem.indexOf(u8, req, "NEWEST-TURN") != null);
    try t.expect(std.mem.indexOf(u8, req, "OLDEST-TURN") == null);
}

test "reload_waits_while_a_message_is_queued" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleText("a message nobody has picked up yet");
    try t.expect(std.mem.startsWith(u8, try f.core.reload(), "Busy"));
}

test "new_clears_the_conversation" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.textReply("one"));
    f.core.chatTurn("first message");
    try f.core.handleText("/new");
    try f.rec.waitFor("New conversation.");
    try f.e.script(2, model.textReply("two"));
    f.core.chatTurn("second message");
    const req = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req, "first message") == null);
}

test "skills_command_lists_saved_skills_and_chat_offers_helpers" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try skills.save(t.io, f.core.paths.skills, "weekly-report", "How to write the weekly report", "Steps.");
    try f.core.handleText("/skills");
    try f.rec.waitFor("weekly-report: How to write the weekly report");
    try f.e.script(1, model.textReply("ok"));
    f.core.chatTurn("hello");
    const req = try f.e.request(1);
    try t.expect(std.mem.indexOf(u8, req, "\"name\":\"delegate\"") != null);
    try t.expect(std.mem.indexOf(u8, req, "\"name\":\"skill\"") != null);
    try t.expect(std.mem.indexOf(u8, req, "weekly-report") != null);
}

test "mcp_servers_start_from_mcp_ini_and_dryrun_switch" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[fake]\ncommand = \"{s}\" --mcp\nmoney = echo\namount = amount\n[broken]\ncommand = /no/such/server\n", .{fake}) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    try f.core.handleText("/status");
    try f.rec.waitFor("MCP: fake (3 tools)");
    try f.rec.waitFor("broken: did not start");
    try f.core.handleText("/dryrun on");
    try f.rec.waitFor("Dry run is on");
    try f.e.script(1, model.textReply("ok"));
    f.core.chatTurn("hello");
    const req = try f.e.request(1);
    try t.expect(std.mem.indexOf(u8, req, "\"name\":\"fake__echo\"") != null);
    try t.expect(std.mem.indexOf(u8, req, "Moves money") != null);
}

test "dryrun_sent_while_a_money_question_waits_stops_the_call" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[fake]\ncommand = \"{s}\" --mcp\nmoney = echo\namount = amount\n", .{fake}) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"order placed\",\"amount\":5}"));
    try f.e.script(2, model.textReply("finished the order"));
    try f.core.startWorker();
    try f.core.handleText("buy");
    try f.rec.waitFor("BUTTONS Allow this?");
    try f.core.handleText("/dryrun on");
    try f.rec.waitFor("Dry run is on");
    try f.press("once");
    try f.rec.waitFor("finished the order");
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "dry run: would call fake/echo") != null);
}

test "an_answer_the_question_does_not_offer_is_not_taken" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[fake]\ncommand = \"{s}\" --mcp\nmoney = echo\namount = amount\n", .{fake}) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    try f.e.script(1, model.toolReply("tu_1", "fake__echo", "{\"text\":\"buy\",\"amount\":5}"));
    try f.e.script(2, model.textReply("answered"));
    try f.core.startWorker();
    try f.core.handleText("buy");
    try f.rec.waitFor("BUTTONS Allow this?");
    // money is never granted for a day: neither "d" nor a "24 h" press
    // (there is no such button) counts
    try t.expect(!f.core.answerPending(.day));
    const b = f.lastButtons();
    try t.expect(b.get("day") == null);
    const once = b.get("once").?;
    f.core.handleCallback(42, b.msg, try std.fmt.allocPrint(a, "{s}:day", .{once[0..std.mem.lastIndexOfScalar(u8, once, ':').?]}));
    t.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try t.expect(f.core.approvalWaiting());
    try t.expect(f.core.answerPending(.deny));
    try f.rec.waitFor("answered");
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "denied by the owner") != null);
}

test "status_says_which_money_tools_have_no_amount_field" {
    var f: Fix = undefined;
    try f.init("[money]\nmax_per_day = 50\n", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[fake]\ncommand = \"{s}\" --mcp\nmoney = echo\n", .{fake}) });
    _ = try f.core.reload();
    try t.expect(std.mem.indexOf(u8, f.core.mcp_warn, "fake: echo has no amount field") != null);
    try f.core.handleText("/status");
    try f.rec.waitFor("fake: echo has no amount field in mcp.ini");
}

test "a_cap_of_0_in_mcp_ini_is_an_error_and_none_lifts_the_cap" {
    var f: Fix = undefined;
    try f.init("[money]\nmax_per_day = 50\n", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    const head = try std.fmt.allocPrint(a, "[fake]\ncommand = \"{s}\" --mcp\nmoney = echo\namount = amount\n", .{fake});
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "{s}max_per_day = 0\n", .{head}) });
    _ = try f.core.reload();
    try t.expectEqual(0, f.core.mcp_servers.items.len);
    // in the start notes and /status: the line, and what to write
    try t.expect(std.mem.startsWith(u8, f.core.mcp_warn, "line 5 has an error: max_per_day = 0 ("));
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "mcp.ini line 5 has an error: max_per_day = 0 (") != null);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_warn, "write none") != null);
    try f.core.handleText("/status");
    try f.rec.waitFor("or remove the line");
    // none: started, and said
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "{s}max_per_day = none\n", .{head}) });
    _ = try f.core.reload();
    try t.expectEqual(1, f.core.mcp_servers.items.len);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_warn, "fake: max_per_day = none: its money calls have no cap per day (config.ini's 50 does not apply)") != null);
    try f.core.handleText("/status");
    try f.rec.waitFor("config.ini's 50 does not apply");
}

test "a_server_whose_money_list_names_a_missing_tool_is_not_started" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[fake]\ncommand = \"{s}\" --mcp\nmoney = echo, place_order\namount = amount\n", .{fake}) });
    _ = try f.core.reload();
    try t.expectEqual(0, f.core.mcp_servers.items.len);
    try t.expectEqual(0, f.core.mcp_tools.len);
    try f.core.handleText("/status");
    try f.rec.waitFor("fake: not started: money = names \"place_order\", which is not one of its tools");
}

test "mcp_start_errors_are_masked_in_the_log" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const key = f.core.secrets.omnigate.?;
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(f.e.arena.allocator(), "[leaky]\ncommand = /bin/sh -c \"echo auth failed for {s} >&2; exit 1\"\n", .{key}) });
    _ = try f.core.reload();
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "leaky: did not start") != null);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, key) == null);
    const log_text = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, f.e.arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, log_text, key) == null);
}

test "logins_command_lists_what_is_stored_and_status_counts_them" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.core.handleText("/logins");
    try f.rec.waitFor("No logins.");
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.logins, .data = "[github-bot]\nsite = github.com\nusername = agent-bot@example.com\n[local]\nsite = localhost\n", .flags = .{ .permissions = util.private_file } });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ f.e.dir, "secrets" }) };
    f.core.store = st;
    try st.put(t.io, "login-github-bot-password", "fake-pass-for-tests");
    try st.put(t.io, "login-github-bot-passkeys", try logins.encode(a, &.{.{ .id = "aWQ=", .rp_id = "github.com", .key = "a2V5" }}));
    try st.put(t.io, "login-local-totp", "JBSWY3DPEHPK3PXP");
    try f.core.handleText("/logins");
    try f.rec.waitFor("github-bot: github.com, username agent-bot@example.com, password yes, TOTP no, passkeys 1");
    try f.rec.waitFor("local: localhost, username (none), password no, TOTP yes, passkeys 0");
    try t.expectEqual(0, f.rec.count("fake-pass-for-tests"));
    try f.core.handleText("/status");
    try f.rec.waitFor("Logins: 2.");
    // the profiles folder is there, private
    if (builtin.os.tag != .windows) {
        const pst = try Io.Dir.cwd().statFile(t.io, f.core.paths.profiles, .{});
        try t.expectEqual(@as(u32, 0o700), @as(u32, @intCast(pst.permissions.toMode() & 0o777)));
        // logins.ini others can change is refused, like rules
        var lf = try Io.Dir.cwd().openFile(t.io, f.core.paths.logins, .{});
        try lf.setPermissions(t.io, .fromMode(0o666));
        lf.close(t.io);
        try t.expect(std.mem.startsWith(u8, try f.core.reload(), "The settings files have an error"));
    }
}

test "mcp_ini_is_guarded_and_watched_like_config_ini" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    // a change to mcp.ini is noticed, like one to config.ini
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = "; no servers yet\n", .flags = .{ .permissions = util.private_file } });
    f.core.last_status_s = 0;
    f.core.tick();
    try f.rec.waitFor("not applied until you send /reload");
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    if (builtin.os.tag == .windows) return;
    // and one that other users can change is refused: it names the commands harness runs
    var mf = try Io.Dir.cwd().openFile(t.io, f.core.paths.mcp, .{});
    try mf.setPermissions(t.io, .fromMode(0o666));
    mf.close(t.io);
    try t.expect(!std.mem.startsWith(u8, try f.core.reload(), "Settings reloaded"));
}

test "settings_errors_name_the_file_and_line" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell ls\nalow shell rm -rf x\n" });
    const r1 = try f.core.reload();
    try t.expect(std.mem.indexOf(u8, r1, "rules line 2") != null);
    try t.expect(std.mem.indexOf(u8, r1, "alow shell rm") != null);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "" });
    // the same words for the command line, which opens nothing
    const old_cfg = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.config, a, .unlimited);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.config, .data = try std.fmt.allocPrint(a, "{s}[limits]\nsteps_per_turn = many\n", .{old_cfg}) });
    const n_lines = std.mem.count(u8, old_cfg, "\n");
    const want = try std.fmt.allocPrint(a, "config.ini line {d}", .{n_lines + 2});
    try t.expect(std.mem.indexOf(u8, try f.core.reload(), want) != null);
    const said = (try settingsProblem(t.io, a, f.core.paths)).?;
    try t.expect(std.mem.indexOf(u8, said, want) != null);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.config, .data = old_cfg });
    try t.expectEqual(null, try settingsProblem(t.io, a, f.core.paths));
    if (builtin.os.tag == .windows) return;
    // a file others can change: which one, and every file that must not be
    var cf = try Io.Dir.cwd().openFile(t.io, f.core.paths.config, .{});
    try cf.setPermissions(t.io, .fromMode(0o666));
    cf.close(t.io);
    const perm = try f.core.reload();
    try t.expect(std.mem.indexOf(u8, perm, f.core.paths.config) != null);
    try t.expect(std.mem.indexOf(u8, perm, "chmod 600") != null);
    try t.expect(std.mem.indexOf(u8, perm, "config.ini, rules, logins.ini and mcp.ini") != null);
}

test "a_rule_refused_at_load_says_why_and_where" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell ls\nallow fetch *.good.com/*\n" });
    const r = try f.core.reload();
    try t.expect(std.mem.indexOf(u8, r, "nothing changed: rules line 2 has an error: allow fetch *.good.com/* (an allow rule for fetch or browse takes an address") != null);
}

test "health_counts_only_harness_run_while_it_holds_the_folder" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    var buf: [256]u8 = undefined;
    const now_s = util.nowSeconds(t.io);
    // `harness chat` holds the folder and ticks: it is not the service
    f.core.role = "chat";
    try f.core.writeStatus();
    const chat = health(t.io, f.core.paths, now_s, &buf);
    try t.expect(!chat.ok);
    try t.expect(std.mem.indexOf(u8, chat.text, "chat") != null);
    f.core.role = "run";
    try f.core.writeStatus();
    try t.expect(health(t.io, f.core.paths, now_s, &buf).ok);
    // ticks that stopped
    try t.expect(!health(t.io, f.core.paths, now_s + 91, &buf).ok);
    // a run that was killed left a recent status and the lock file: nobody holds it
    const home = f.home;
    f.core.close();
    const p = try Paths.init(f.e.arena.allocator(), home);
    const zeros: [64]u8 = @splat('0');
    var tb: [20]u8 = undefined;
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p.status, .data = try std.fmt.allocPrint(f.e.arena.allocator(), "pid 1\nrole run\ntick {s}\nlog {s}\n", .{ util.isoTime(&tb, now_s), &zeros }) });
    try t.expect(!health(t.io, p, now_s, &buf).ok);
    f.core = try Core.open(t.allocator, t.io, home, .{});
}

test "a_signal_stops_what_runs_logs_it_and_lets_go_of_the_folder" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell sleep *\n" });
    _ = try f.core.reload();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"sleep 30\"}"));
    try f.e.script(2, model.textReply("never"));
    try f.core.startWorker();
    try f.core.handleText("sleep a while");
    var waited: u32 = 0;
    while (!f.core.busy.load(.acquire) and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    // what main's watcher does on SIGTERM before it ends the process
    f.core.endBySignal("SIGTERM");
    // the command and its process group are gone: the turn ends at once
    waited = 0;
    while (f.core.busy.load(.acquire) and waited < 5000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try t.expect(!f.core.busy.load(.acquire));
    try t.expectEqual(1, f.e.server.modelRequests());
    // said in the log, then the stop, and the folder is free for the next start
    const lt = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, f.e.arena.allocator(), .unlimited);
    const sig_at = std.mem.indexOf(u8, lt, "\"event\":\"signal\",\"signal\":\"SIGTERM\"") orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOfPos(u8, lt, sig_at, "\"event\":\"stop\"") != null);
    try t.expect(!lockHeld(t.io, f.core.paths));
}

test "mcp_servers_run_in_a_folder_of_their_own_not_the_workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    // the server says where it runs, then fails (its stderr goes to the log)
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = "[where]\ncommand = /bin/sh -c \"pwd >&2; exit 1\"\n" });
    _ = try f.core.reload();
    const lt = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, a, .unlimited);
    const own = try std.fs.path.join(a, &.{ try Io.Dir.cwd().realPathFileAlloc(t.io, f.core.paths.state, a), "mcp", "where" });
    if (std.mem.indexOf(u8, lt, own) == null) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ own, lt });
        return error.TestUnexpectedResult;
    }
    // files the agent writes into the workspace are not the server's
    try t.expect(std.mem.indexOf(u8, lt, f.core.workspace) == null);
    for ([_][]const u8{ own, std.fs.path.dirname(own).? }) |d| {
        const st = try Io.Dir.cwd().statFile(t.io, d, .{});
        try t.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

fn reloadQuietly(c: *Core) void {
    _ = c.reload() catch {};
}

test "mcp_servers_start_together_under_one_deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    f.core.mcp_start_ms = 1500;
    // two that take half a second to come up, one that never answers
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[one]\ncommand = /bin/sh -c \"sleep 0.5; exec '{s}' --mcp\"\n[two]\ncommand = /bin/sh -c \"sleep 0.5; exec '{s}' --mcp\"\n[mute]\ncommand = /bin/sh -c \"exec sleep 30\"\n", .{ fake, fake }) });
    const t0 = Io.Clock.awake.now(t.io).nanoseconds;
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - t0, std.time.ns_per_ms);
    // one after another: 0.5 + 0.5 + 1.5 s; together: the deadline
    try t.expect(took_ms < 2300);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "one (3 tools)") != null);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "two (3 tools)") != null);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "mute: did not start (Timeout)") != null);
    // in mcp.ini's order
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "one").? < std.mem.indexOf(u8, f.core.mcp_note, "two").?);
}

test "reload_holds_no_lock_while_servers_start_and_stop_cuts_it_short" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[slow]\ncommand = /bin/sh -c \"sleep 3; exec '{s}' --mcp\"\n", .{fake}) });
    const t0 = Io.Clock.awake.now(t.io).nanoseconds;
    const th = try std.Thread.spawn(.{}, reloadQuietly, .{f.core});
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    // /stop and the scheduler's tick do not wait for the start
    _ = f.core.stopAll();
    f.core.last_status_s = 0;
    f.core.tick();
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - t0 < 1500 * std.time.ns_per_ms);
    th.join();
    // and the stop ended the start instead of waiting it out
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - t0 < 2800 * std.time.ns_per_ms);
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "slow: did not start (Stopped)") != null);
}

test "a_value_added_while_a_turn_runs_is_masked_in_every_tool_from_then_on" {
    // the command makes the value without spelling it out ($((...)) is POSIX sh)
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell echo *\n" });
    _ = try f.core.reload();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo made-at-signup-Pass-$((9000+271))\"}"));
    try f.e.script(2, model.textReply("ok"));
    var flag: std.atomic.Value(bool) = .init(false);
    var run = f.core.baseRun(&f.core.chat_client, "chat", false, &flag);
    // made after the run began, as web makes a password at a sign-up
    try f.core.masks.add("login-new-password", "made-at-signup-Pass-9271");
    var conv: agent.Conversation = .init(t.allocator);
    defer conv.deinit();
    const res = try agent.turn(&run, &conv, "echo it", false);
    defer agent.freeResult(&run, res);
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "made-at-signup-Pass-9271") == null);
    try t.expect(std.mem.indexOf(u8, req2, "[secret:login-new-password]") != null);
}

test "a_value_added_to_the_mask_list_is_masked_in_the_log_and_memory_too" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    // as web does at a sign-up, after the log and memory were set up
    try f.core.masks.add("login-new-password", "made-at-signup-Pass-5813");
    try f.core.log.write(.config, false, .{ .event = "probe", .detail = "it is made-at-signup-Pass-5813 now" });
    const log_text = try Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.log, t.allocator, .limited(1 << 20));
    defer t.allocator.free(log_text);
    try t.expect(std.mem.indexOf(u8, log_text, "made-at-signup-Pass-5813") == null);
    try t.expect(std.mem.indexOf(u8, log_text, "[secret:login-new-password]") != null);
    {
        f.core.lock.lockUncancelable(t.io);
        defer f.core.lock.unlock(t.io);
        _ = try f.core.mem.add("The sign-up password is made-at-signup-Pass-5813", null, f.core.now());
    }
    for (f.core.mem.items.items) |it| try t.expect(std.mem.indexOf(u8, it.body, "made-at-signup-Pass-5813") == null);
}

test "reload_takes_a_secret_stored_since_start_and_masks_it" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, a);
    const st: store_mod.Store = .{ .dir = try std.fs.path.join(a, &.{ f.e.dir, "secrets" }) };
    f.core.store = st;
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow mcp fresh/echo *\n" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[fresh]\ncommand = \"{s}\" --mcp\nsecret = FAKE_SECRET:fresh-key\n", .{fake}) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "secret \"fresh-key\" is not stored") != null);
    // `harness secret add fresh-key` while harness runs, then /reload
    try st.put(t.io, "fresh-key", "fresh-mcp-value-4711");
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    try t.expect(std.mem.indexOf(u8, f.core.mcp_note, "fresh (3 tools)") != null);
    // the server got it; what it says back is masked like any stored secret
    try f.e.script(1, "{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_m\",\"name\":\"fresh__echo\",\"input\":{\"text\":\"env\"}}],\"stop_reason\":\"tool_use\"}");
    try f.e.script(2, model.textReply("ok"));
    f.core.chatTurn("use it");
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "secret=[secret:fresh-key]") != null);
    try t.expect(std.mem.indexOf(u8, req2, "fresh-mcp-value-4711") == null);
}
