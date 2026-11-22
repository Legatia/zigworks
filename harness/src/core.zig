//! The running instance: one data folder, one owner, the conversations
//! (the private chat, its topics, groups, the terminal), the scheduler,
//! and the commands the owner sends. Transport-free: Telegram and the
//! terminal plug in as a `Channel`.
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
const who_mod = @import("who.zig");
const conversations = @import("conversations.zig");
const jv = @import("jv.zig");
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
    written: []const u8,
    conversations: []const u8,

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
            .written = try j(a, &.{ state, "written" }),
            .conversations = try j(a, &.{ state, "conversations" }),
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

/// Where a post goes: a conversation's Telegram chat and topic (thread 0:
/// the chat itself), or the terminal. `name` is the conversation's.
pub const Place = struct {
    name: []const u8 = "main",
    chat: i64 = 0,
    thread: i64 = 0,
};

/// The messages a text went out in: the first one's id and how many.
pub const Sent = struct { first: i64 = 0, count: u32 = 0 };

pub const Channel = struct {
    ctx: *anyopaque,
    /// Sends `text` to `place`, in as many messages as it takes; an error
    /// when it did not get there (error.NotPaired: there is no owner to
    /// send it to yet; error.TopicRefused: Telegram refused the topic).
    send: *const fn (ctx: *anyopaque, place: Place, text: []const u8) anyerror!Sent,
    /// Returns an id for `clear`, or null when buttons can't be shown.
    buttons: *const fn (ctx: *anyopaque, place: Place, text: []const u8, buttons: []const [2][]const u8) ?i64,
    clear: *const fn (ctx: *anyopaque, place: Place, id: i64) void,
    /// Sends to someone other than the owner (an account trying to pair);
    /// null where there is no one else (the terminal).
    send_to: ?*const fn (ctx: *anyopaque, chat_id: i64, text: []const u8) anyerror!void = null,
    /// Sends a file as a document; returns its message id. Null where files
    /// can't be sent.
    document: ?*const fn (ctx: *anyopaque, place: Place, name: []const u8, data: []const u8) anyerror!i64 = null,
    /// Opens a topic called `name` in the private chat `chat`; returns its
    /// thread. Null where there are no topics (the terminal).
    open_topic: ?*const fn (ctx: *anyopaque, chat: i64, name: []const u8) anyerror!i64 = null,
};

/// A Telegram message, with where it came from.
pub const Incoming = struct {
    from: i64,
    chat: i64,
    /// "private", "group" or "supergroup".
    chat_type: []const u8 = "private",
    /// The topic it came from; 0: the chat itself.
    thread: i64 = 0,
    /// The topic's name, when the message says it.
    topic: ?[]const u8 = null,
    text: []const u8,
};

/// One conversation's context: its turns and where its memory writer is.
const Context = struct {
    name: []u8,
    conv: agent.Conversation,
    /// The memory writer has read the turns before this one (counted from
    /// the start, dropped turns included).
    memory_upto: usize = 0,
    turns_since_memory: u32 = 0,
    /// When the owner last wrote in it (its quiet time counts from then).
    last_owner_s: i64 = 0,
    /// When it was last used, by the core's count.
    used: u64 = 0,
    /// /new: a fresh context before its next turn.
    reset: std.atomic.Value(bool) = .init(false),
};

/// Contexts kept at once; a new one past these drops the least used.
const max_contexts = 16;

/// A message waiting for the chat worker, with the conversation it came
/// from.
const Queued = struct {
    conv: []u8,
    text: []u8,
    /// A quick reply: the post it answers, said in its turn's context.
    note: ?[]u8 = null,

    fn deinit(q: Queued, gpa: std.mem.Allocator) void {
        gpa.free(q.conv);
        gpa.free(q.text);
        if (q.note) |n| gpa.free(n);
    }
};

/// A post with quick replies: a press of one of its buttons, in the
/// message they are in, is the owner's message in its conversation, once.
/// Kept in memory only: its token is the start's nonce.
const Quick = struct {
    n: u32,
    conv: []u8,
    labels: [][]u8,
    /// The post's start, said in the turn a press starts.
    excerpt: []u8,
    /// Where its buttons are (null: not yet sent).
    msg: ?i64 = null,
    chat: i64 = 0,
    thread: i64 = 0,
    used: bool = false,

    fn deinit(q: Quick, gpa: std.mem.Allocator) void {
        gpa.free(q.conv);
        for (q.labels) |l| gpa.free(l);
        gpa.free(q.labels);
        gpa.free(q.excerpt);
    }
};

/// Posts with quick replies kept at once; the oldest goes first.
const max_quick = 32;

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
    /// One masksChanged at a time (see there).
    mask_mutex: Io.Mutex = .init,
    /// Tests: called in masksChanged between taking the list and setting it.
    mask_pause: ?*const fn (c: *Core) void = null,
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
    /// The files the agent wrote since the owner last allowed a shell
    /// command (state/written): a command a rule or grant allows asks first.
    written: agent.Written,

    chan: ?Channel = null,
    owner: ?i64 = null,
    /// The conversations (state/conversations).
    convs: conversations.List,
    /// The bot's username: a command may end in `@` and it (`setBot`).
    bot_name_buf: [64]u8 = undefined,
    bot_name_len: usize = 0,
    /// Whether Telegram topics in private chats are on for the bot.
    topics_on: bool = true,
    /// One topic opened for a post at a time (two runs posting to the same
    /// new name open it once).
    topic_mutex: Io.Mutex = .init,
    /// Names whose topic could not be opened, the owner told once each.
    told_topics: std.ArrayList([]u8) = .empty,
    /// The posts with quick replies, and the last post's number.
    quick_mutex: Io.Mutex = .init,
    quick: std.ArrayList(Quick) = .empty,
    quick_seq: u32 = 0,
    /// /dryrun, /private, /memory auto: runs read them when they use them.
    switches: agent.Switches = .{},

    // the chat
    chat_client: model.Client,
    /// A context per conversation the owner talks in (at most
    /// `max_contexts`); only the chat worker adds and drops them.
    contexts: std.ArrayList(*Context) = .empty,
    /// Held while `contexts` is read or changed.
    ctx_mutex: Io.Mutex = .init,
    /// Counts the contexts' uses (the least used goes first).
    ctx_clock: u64 = 0,
    queue_mutex: Io.Mutex = .init,
    queue: std.ArrayList(Queued) = .empty,
    busy: std.atomic.Value(bool) = .init(false),
    approval: Approval = .{},
    /// Random for each start, in every question's button data: a button
    /// from before a restart never matches, whatever its number.
    approval_nonce: [16]u8 = undefined,
    worker: ?std.Thread = null,
    quitting: std.atomic.Value(bool) = .init(false),

    // background runs
    bg_active: std.atomic.Value(u32) = .init(0),
    state_mutex: Io.Mutex = .init,
    /// "brief:NAME" → local day number it last ran; "task:NAME" → seconds.
    ran: std.StringHashMapUnmanaged(i64) = .empty,
    running: std.StringHashMapUnmanaged(void) = .empty,
    paused: std.StringHashMapUnmanaged(void) = .empty,
    /// Briefs and tasks whose message did not get through, by the same
    /// keys as `ran`: the message, and when it is sent again. Kept in
    /// memory only: after a restart such a brief or task runs again.
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
        c.mask_mutex = .init;
        c.mask_pause = null;
        c.masks.on_change = .{ .ctx = c, .changed = masksChanged };
        c.seen = .init(gpa);
        c.seen.load(io, c.paths.seen) catch {};
        c.written = .init(gpa, io, c.paths.written);
        errdefer c.written.deinit();
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
        c.convs = .init(gpa, io, c.paths.conversations);
        errdefer c.convs.deinit();
        try c.convs.load();
        c.upgradeConversations();
        c.bot_name_len = 0;
        c.topics_on = true;
        c.topic_mutex = .init;
        c.told_topics = .empty;
        c.quick_mutex = .init;
        c.quick = .empty;
        c.quick_seq = 0;
        c.chat_client = try model.Client.init(gpa, io, c.cfg.model.url, secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens);
        c.contexts = .empty;
        c.ctx_mutex = .init;
        c.ctx_clock = 0;
        c.queue_mutex = .init;
        c.queue = .empty;
        c.busy = .init(false);
        c.approval = .{};
        var nonce_raw: [8]u8 = undefined;
        io.random(&nonce_raw);
        c.approval_nonce = std.fmt.bytesToHex(nonce_raw, .lower);
        c.worker = null;
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
        for (c.queue.items) |q| q.deinit(c.gpa);
        c.queue.deinit(c.gpa);
        c.run_flags.deinit(c.gpa);
        c.convs.deinit();
        for (c.told_topics.items) |n| c.gpa.free(n);
        c.told_topics.deinit(c.gpa);
        for (c.quick.items) |q| q.deinit(c.gpa);
        c.quick.deinit(c.gpa);
        for (c.contexts.items) |x| c.freeContext(x);
        c.contexts.deinit(c.gpa);
        c.chat_client.deinit();
        c.seen.deinit();
        c.written.deinit();
        c.mem.deinit();
        c.log.close();
        c.grants.deinit();
        c.masks.deinit();
        if (c.mask_snap.len > 0) c.gpa.free(c.mask_snap);
        freeKeys(c.gpa, &c.ran);
        freeKeys(c.gpa, &c.running);
        freeKeys(c.gpa, &c.paused);
        var kept = c.retry.valueIterator();
        while (kept.next()) |r| r.msg.deinit(c.gpa);
        freeKeys(c.gpa, &c.retry);
        c.releaseFolder();
        c.settings_arena.deinit();
        c.paths_arena.deinit();
        c.gpa.free(c.home_owned);
        c.gpa.destroy(c);
    }

    /// The mask list grew: the log and memory mask with the new list from
    /// now on. The strings belong to the list; only the slice is ours. One
    /// at a time, each taking the list as it is then: of two values added
    /// at once, the one that sets its list last has both, so the log and
    /// memory never end on the older list.
    fn masksChanged(ctx: *anyopaque) void {
        const c: *Core = @ptrCast(@alignCast(ctx));
        c.mask_mutex.lockUncancelable(c.io);
        defer c.mask_mutex.unlock(c.io);
        const snap = c.masks.snapshot(c.gpa) catch return;
        if (c.mask_pause) |p| p(c);
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

    /// A folder from before conversations gets `terminal`, and `main` once
    /// an owner is paired; 0.3's `private on` becomes main's.
    fn upgradeConversations(c: *Core) void {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        const had_main = c.convs.find("main") != null;
        _ = c.convs.ensure(c.owner, c.switches.private.load(.acquire), util.nowSeconds(c.io)) catch {};
        c.mainTookPrivate(had_main);
    }

    /// `main` was just made: the instance-wide private switch of 0.3 is
    /// its own from now on. Under convs.mutex.
    fn mainTookPrivate(c: *Core, had_main: bool) void {
        if (had_main or c.convs.find("main") == null or !c.switches.private.load(.acquire)) return;
        c.switches.private.store(false, .release);
        c.saveSwitches();
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

    /// Says `text` in `main`: the instance's own lines.
    pub fn say(c: *Core, text: []const u8) void {
        c.sayIn("main", text);
    }

    /// Says harness's own line (a command's reply, Queued, an error) in
    /// conversation `conv`.
    pub fn sayIn(c: *Core, conv: []const u8, text: []const u8) void {
        c.deliverIn(conv, text) catch {};
    }

    /// Sends `text` to `main`; an error (logged) when it did not get there.
    /// error.NoChannel: nothing to send it through.
    pub fn deliver(c: *Core, text: []const u8) !void {
        return c.deliverIn("main", text);
    }

    pub fn deliverIn(c: *Core, conv: []const u8, text: []const u8) !void {
        _ = try c.sendText(conv, text);
    }

    /// Where the posts for `conv` go, and the name put in front when that
    /// is not its own place: main for a topic Telegram refused, or a name
    /// harness does not know (where there are topics).
    const Resolved = struct { place: Place, prefix: ?[]const u8 = null };

    fn placeOf(c: *Core, a: std.mem.Allocator, conv: []const u8) !Resolved {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        if (c.convs.find(conv)) |e| {
            if (!e.refused) return .{ .place = .{ .name = try a.dupe(u8, e.name), .chat = e.chat, .thread = e.thread } };
        } else if (std.mem.eql(u8, conv, "main") or std.mem.eql(u8, conv, "terminal")) {
            // main before an owner is paired (Telegram says NotPaired)
            return .{ .place = .{ .name = try a.dupe(u8, conv) } };
        } else if (c.chan) |ch| if (ch.open_topic == null) {
            // no topics here (the terminal): the name says where it was for
            return .{ .place = .{ .name = try a.dupe(u8, conv) } };
        };
        const m = c.convs.find("main") orelse return .{ .place = .{}, .prefix = try a.dupe(u8, conv) };
        return .{ .place = .{ .chat = m.chat, .thread = m.thread }, .prefix = try a.dupe(u8, conv) };
    }

    /// Sends `text` to conversation `conv`; returns the messages it went
    /// out in. A topic Telegram refuses is noted (its posts go to main
    /// from then on, with its name in front) and the text goes there.
    fn sendText(c: *Core, conv: []const u8, text: []const u8) !Sent {
        const ch = c.chan orelse return error.NoChannel;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var r = try c.placeOf(a, conv);
        var again = false;
        while (true) {
            const msg = if (r.prefix) |p| try std.fmt.allocPrint(a, "[{s}] {s}", .{ p, text }) else text;
            if (ch.send(ch.ctx, r.place, msg)) |sent| return sent else |e| {
                if (e == error.TopicRefused and !again) {
                    again = true;
                    c.topicRefused(conv);
                    r = try c.placeOf(a, conv);
                    continue;
                }
                c.log.write(.chat, false, .{ .event = "not delivered", .why = whyUndelivered(e), .bytes = text.len }) catch {};
                return e;
            }
        }
    }

    /// Telegram refused `conv`'s topic: its posts go to main with its name
    /// in front from now on, and the owner is told why, once.
    fn topicRefused(c: *Core, conv: []const u8) void {
        const tell = blk: {
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            const e = c.convs.find(conv) orelse break :blk false;
            e.refused = true;
            defer e.told = true;
            break :blk !e.told;
        };
        c.log.write(.chat, false, .{ .event = "topic refused", .name = conv }) catch {};
        if (!tell) return;
        var buf: [256]u8 = undefined;
        c.say(std.fmt.bufPrint(&buf, "Telegram refused the topic of {s}, so its posts come here with [{s}] in front.", .{ conv, conv }) catch "Telegram refused a topic; its posts come here.");
    }

    /// Notes that a message came from `conv` or a post went to it.
    fn touch(c: *Core, conv: []const u8) void {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        if (c.convs.find(conv)) |e| e.used_s = util.nowSeconds(c.io);
    }

    /// The name of the conversation at `chat` and `thread`, else main.
    fn convAt(c: *Core, buf: *[conversations.max_name]u8, chat: i64, thread: i64) []const u8 {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        const e = c.convs.at(chat, thread) orelse return "main";
        @memcpy(buf[0..e.name.len], e.name);
        return buf[0..e.name.len];
    }

    /// The bot's username (a command may end in `@` and it) and whether
    /// Telegram topics in private chats are on for it: `getMe` at start.
    pub fn setBot(c: *Core, username: []const u8, topics_on: bool) void {
        const n = @min(username.len, c.bot_name_buf.len);
        @memcpy(c.bot_name_buf[0..n], username[0..n]);
        c.bot_name_len = n;
        c.topics_on = topics_on;
    }

    /// A command's word without the `@BOTNAME` Telegram may add.
    fn commandWord(c: *const Core, word: []const u8) []const u8 {
        const at = std.mem.indexOfScalar(u8, word, '@') orelse return word;
        const bot = c.bot_name_buf[0..c.bot_name_len];
        if (bot.len == 0 or std.ascii.eqlIgnoreCase(word[at + 1 ..], bot)) return word[0..at];
        return word;
    }

    pub fn attach(c: *Core, ch: Channel) void {
        c.chan = ch;
        if (c.pending_warning) |w| {
            c.say(w);
            c.pending_warning = null;
        }
    }

    pub fn setOwner(c: *Core, id: i64) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        _ = try c.pairOwner(arena.allocator(), id);
    }

    /// Makes `id` the owner: its private chat is `main` from now on, and
    /// the topics of an account paired before are forgotten (their names
    /// are returned, in `a`).
    fn pairOwner(c: *Core, a: std.mem.Allocator, id: i64) ![]const []const u8 {
        const before = c.owner;
        c.owner = id;
        var buf: [32]u8 = undefined;
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.paths.owner, .data = try std.fmt.bufPrint(&buf, "{d}\n", .{id}) });
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        const now_s = util.nowSeconds(c.io);
        if (c.convs.find("main")) |m| {
            if (before) |old| if (old != id) return c.convs.pair(a, old, id, now_s);
            if (m.chat != id) {
                m.chat = id;
                try c.convs.save();
            }
            return &.{};
        }
        _ = try c.convs.ensure(id, c.switches.private.load(.acquire), now_s);
        c.mainTookPrivate(false);
        return &.{};
    }

    /// A Telegram message in the owner's private chat (`main`).
    pub fn handleMessage(c: *Core, from_id: i64, text: []const u8) !void {
        return c.handleIncoming(.{ .from = from_id, .chat = from_id, .text = text });
    }

    /// A Telegram message. Strangers are dropped, though an attempt to
    /// pair is answered; `/pair CODE` with a code from `harness pair` pairs
    /// the account it comes from, also when another one was paired before.
    /// The owner's private chat is `main`, a topic of it that topic's
    /// conversation (made at its first message); in a group only the
    /// owner's `/conversation add NAME` is read.
    pub fn handleIncoming(c: *Core, m: Incoming) !void {
        const from_id = m.from;
        const text = m.text;
        const is_owner = if (c.owner) |o| o == from_id else false;
        const private_chat = std.mem.eql(u8, m.chat_type, "private");
        if (!is_owner and private_chat and std.mem.startsWith(u8, text, "/pair ")) {
            if (checkPairCode(c.io, c.paths.pair, std.mem.trim(u8, text[6..], " "), c.now())) {
                var arena: std.heap.ArenaAllocator = .init(c.gpa);
                defer arena.deinit();
                const a = arena.allocator();
                const before = c.owner;
                const dropped = try c.pairOwner(a, from_id);
                Io.Dir.cwd().deleteFile(c.io, c.paths.pair) catch {};
                if (before) |old| {
                    // another account: the old one is told, the new one
                    // starts a fresh conversation
                    c.sayTo(old, "This bot is now paired with another account, with a code from harness pair.");
                    c.resetContext("main");
                    for (dropped) |name| c.resetContext(name);
                }
                try c.log.write(.chat, false, .{ .event = "paired", .from = from_id, .before = before, .topics_dropped = dropped.len });
                const hello = "Paired. I answer only you from now on. Send /help for commands.";
                if (dropped.len == 0) c.say(hello) else c.say(try std.fmt.allocPrint(a, "{s}\nThe topics of the account paired before are no longer conversations: {s}.", .{ hello, try std.mem.join(a, ", ", dropped) }));
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
        if (!private_chat) return c.groupMessage(m);
        if (m.thread == 0) return c.handleTextIn("main", text);
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const conv = c.topicConversation(arena.allocator(), m) catch |e| {
            c.say(try std.fmt.allocPrint(arena.allocator(), "A message in a new topic was not taken: harness could not write state/conversations ({s}).", .{@errorName(e)}));
            return;
        };
        return c.handleTextIn(conv, text);
    }

    /// The conversation of topic `m.thread` in the owner's chat: made, and
    /// written down, at its first message, named after the topic.
    fn topicConversation(c: *Core, a: std.mem.Allocator, m: Incoming) ![]const u8 {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        if (c.convs.at(m.chat, m.thread)) |e| return try a.dupe(u8, e.name);
        const name = try c.convs.fromTopic(a, m.topic, m.thread);
        _ = try c.convs.add(.{ .name = name, .chat = m.chat, .thread = m.thread, .created = util.nowSeconds(c.io) });
        try c.log.write(.chat, false, .{ .event = "conversation added", .name = name, .thread = m.thread });
        return name;
    }

    /// A message in a group: only the owner's `/conversation add NAME` is
    /// read there (others read a group: the agent only posts there, each
    /// post asked); anything else is dropped and logged.
    fn groupMessage(c: *Core, m: Incoming) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var words = std.mem.tokenizeAny(u8, std.mem.trim(u8, m.text, " \t\r\n"), " \t");
        const cmd = c.commandWord(words.next() orelse "");
        const op = words.next() orelse "";
        const name = std.mem.trim(u8, words.rest(), " \t");
        if (!std.mem.eql(u8, cmd, "/conversation") or !std.mem.eql(u8, op, "add")) {
            try c.log.write(.chat, false, .{ .event = "dropped", .from = m.from, .chat = m.chat, .why = "a group: only /conversation add is read there" });
            return;
        }
        const reply = blk: {
            if (!conversations.validName(name)) break :blk "Use /conversation add NAME, the name in a-z, 0-9, - and _ (up to 32).";
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            if (c.convs.at(m.chat, m.thread)) |e| break :blk try std.fmt.allocPrint(a, "This chat is the conversation {s} already.", .{e.name});
            if (c.convs.find(name) != null) break :blk "Another conversation has that name; pick another.";
            _ = c.convs.add(.{ .name = name, .chat = m.chat, .thread = m.thread, .audience = .shared, .created = util.nowSeconds(c.io) }) catch |e|
                break :blk try std.fmt.allocPrint(a, "Not added: harness could not write state/conversations ({s}).", .{@errorName(e)});
            try c.log.write(.config, false, .{ .event = "conversation added", .name = name, .chat = m.chat, .audience = "shared" });
            break :blk try std.fmt.allocPrint(a, "Added: the agent may post here as {s}. Each post here is asked first; /conversation rm {s} in your chat with the bot ends it.", .{ name, name });
        };
        const ch = c.chan orelse return;
        _ = ch.send(ch.ctx, .{ .name = name, .chat = m.chat, .thread = m.thread }, reply) catch {};
    }

    /// Sends to an account other than the owner, where the channel can.
    fn sayTo(c: *Core, chat_id: i64, text: []const u8) void {
        const ch = c.chan orelse return;
        const f = ch.send_to orelse return;
        f(ch.ctx, chat_id, text) catch {};
    }

    /// The owner's text in `main`.
    pub fn handleText(c: *Core, text: []const u8) !void {
        return c.handleTextIn("main", text);
    }

    /// The owner's text in conversation `conv`: a command now (its reply
    /// goes there), or a message for the chat queue.
    pub fn handleTextIn(c: *Core, conv: []const u8, text_in: []const u8) !void {
        const text = std.mem.trim(u8, text_in, " \t\r\n");
        if (text.len == 0) return;
        c.touch(conv);
        if (text[0] == '/') {
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            const reply = try c.commandIn(arena.allocator(), conv, text);
            if (reply.len > 0) c.sayIn(conv, reply);
            return;
        }
        return c.queueMessage(conv, text, null);
    }

    /// Queues the owner's message `text` in `conv` for the chat worker
    /// (`note`: the post a quick reply answers).
    fn queueMessage(c: *Core, conv: []const u8, text: []const u8, note: ?[]const u8) !void {
        const conv_owned = try c.gpa.dupe(u8, conv);
        errdefer c.gpa.free(conv_owned);
        const text_owned = try c.gpa.dupe(u8, text);
        errdefer c.gpa.free(text_owned);
        const item: Queued = .{ .conv = conv_owned, .text = text_owned, .note = if (note) |n| try c.gpa.dupe(u8, n) else null };
        const queued_behind = blk: {
            c.queue_mutex.lockUncancelable(c.io);
            defer c.queue_mutex.unlock(c.io);
            c.queue.append(c.gpa, item) catch |e| {
                if (item.note) |n| c.gpa.free(n);
                return e;
            };
            break :blk c.busy.load(.acquire) or c.queue.items.len > 1;
        };
        if (queued_behind) c.sayIn(conv, "Queued; /stop cancels the current turn.");
    }

    /// A button press (`data`, see Approval) in message `message_id`. It
    /// answers the waiting question only if it is one of that question's
    /// buttons: this start's nonce, the question's number, and the message
    /// the question was sent in. Any other press of the owner's is out of
    /// date (from before a restart, or under another question), and the
    /// owner is told so.
    pub fn handleCallback(c: *Core, from_id: i64, message_id: i64, data: []const u8) void {
        c.handleCallbackIn(from_id, from_id, 0, message_id, data);
    }

    /// `handleCallback` for a press in `chat`, topic `thread`.
    pub fn handleCallbackIn(c: *Core, from_id: i64, chat: i64, thread: i64, message_id: i64, data: []const u8) void {
        if (c.owner == null or from_id != c.owner.?) {
            c.log.write(.chat, false, .{ .event = "dropped", .from = from_id, .why = "button from someone else" }) catch {};
            return;
        }
        if (data.len > 0 and data[0] == 'r') {
            if (!c.quickPress(message_id, data)) c.tellOutOfDate(chat, thread, message_id);
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
        if (!current) c.tellOutOfDate(chat, thread, message_id);
    }

    /// A press of a quick reply (`r<post>-<token>:<n>`): once, from the
    /// message its buttons are in, with this start's token; the label is
    /// the owner's message in the post's conversation, and the buttons go.
    /// False when it answers nothing.
    fn quickPress(c: *Core, message_id: i64, data: []const u8) bool {
        const colon = std.mem.lastIndexOfScalar(u8, data, ':') orelse return false;
        const dash = std.mem.indexOfScalar(u8, data[0..colon], '-') orelse return false;
        const n = std.fmt.parseInt(u32, data[1..dash], 10) catch return false;
        const which = std.fmt.parseInt(usize, data[colon + 1 ..], 10) catch return false;
        if (!std.mem.eql(u8, data[dash + 1 .. colon], &c.approval_nonce)) return false;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const got = blk: {
            c.quick_mutex.lockUncancelable(c.io);
            defer c.quick_mutex.unlock(c.io);
            for (c.quick.items) |*q| if (q.n == n) {
                if (q.used or q.msg == null or q.msg.? != message_id or which == 0 or which > q.labels.len) return false;
                q.used = true;
                break :blk .{
                    .conv = a.dupe(u8, q.conv) catch return false,
                    .label = a.dupe(u8, q.labels[which - 1]) catch return false,
                    .excerpt = a.dupe(u8, q.excerpt) catch return false,
                    .place = Place{ .name = "", .chat = q.chat, .thread = q.thread },
                };
            };
            return false;
        };
        if (c.chan) |ch| ch.clear(ch.ctx, got.place, message_id);
        c.log.write(.chat, c.convPrivate(got.conv), .{ .event = "quick reply", .post = n, .text = got.label }) catch {};
        const note = std.fmt.allocPrint(a, "The owner pressed \"{s}\" under your post: \"{s}\"", .{ got.label, got.excerpt }) catch return true;
        c.queueMessage(got.conv, got.label, note) catch {};
        return true;
    }

    /// Notes a post with quick replies; returns its number. The oldest
    /// goes past `max_quick`.
    fn quickPost(c: *Core, conv: []const u8, labels: []const []const u8, text: []const u8) !u32 {
        const owned = try c.gpa.alloc([]u8, labels.len);
        var made: usize = 0;
        errdefer {
            for (owned[0..made]) |l| c.gpa.free(l);
            c.gpa.free(owned);
        }
        for (labels) |l| {
            owned[made] = try c.gpa.dupe(u8, l);
            made += 1;
        }
        const conv_owned = try c.gpa.dupe(u8, conv);
        errdefer c.gpa.free(conv_owned);
        const excerpt = try c.gpa.dupe(u8, util.cut(text, 200));
        errdefer c.gpa.free(excerpt);
        c.quick_mutex.lockUncancelable(c.io);
        defer c.quick_mutex.unlock(c.io);
        if (c.quick.items.len >= max_quick) c.quick.orderedRemove(0).deinit(c.gpa);
        c.quick_seq += 1;
        try c.quick.append(c.gpa, .{ .n = c.quick_seq, .conv = conv_owned, .labels = owned, .excerpt = excerpt });
        return c.quick_seq;
    }

    /// The post `n`'s buttons are in message `msg` at `place`.
    fn quickShown(c: *Core, n: u32, msg: i64, place: Place) void {
        c.quick_mutex.lockUncancelable(c.io);
        defer c.quick_mutex.unlock(c.io);
        for (c.quick.items) |*q| if (q.n == n) {
            q.msg = msg;
            q.chat = place.chat;
            q.thread = place.thread;
        };
    }

    /// Sends a post with quick replies to `conv`: the text in messages of
    /// 4096 bytes, the buttons on the last; the post is noted so a press of
    /// one counts.
    fn sendWithButtons(c: *Core, a: std.mem.Allocator, conv: []const u8, text_in: []const u8, labels: []const []const u8) !Sent {
        const ch = c.chan orelse return error.NoChannel;
        const r = try c.placeOf(a, conv);
        const text = if (r.prefix) |p| try std.fmt.allocPrint(a, "[{s}] {s}", .{ p, text_in }) else text_in;
        const n = try c.quickPost(conv, labels, text_in);
        const bs = try a.alloc([2][]const u8, labels.len);
        for (labels, bs, 1..) |l, *b, i| b.* = .{ l, try std.fmt.allocPrint(a, "r{d}-{s}:{d}", .{ n, &c.approval_nonce, i }) };
        const parts = try questionParts(a, text);
        var sent: Sent = .{};
        for (parts[0 .. parts.len - 1]) |part| {
            const s = try ch.send(ch.ctx, r.place, part);
            if (sent.count == 0) sent.first = s.first;
            sent.count += s.count;
        }
        const id = ch.buttons(ch.ctx, r.place, parts[parts.len - 1], bs) orelse return error.ButtonsNotSent;
        c.quickShown(n, id, r.place);
        if (sent.count == 0) sent.first = id;
        sent.count += 1;
        return sent;
    }

    /// Says where the press came from that it answers nothing.
    fn tellOutOfDate(c: *Core, chat: i64, thread: i64, message_id: i64) void {
        c.log.write(.chat, false, .{ .event = "button out of date", .message = message_id }) catch {};
        var buf: [conversations.max_name]u8 = undefined;
        c.sayIn(c.convAt(&buf, chat, thread), "That button is out of date: it answers nothing.");
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

    /// Who asks: the run's flag and its conversation (its questions go there).
    const ChatAsk = struct { core: *Core, flag: *std.atomic.Value(bool), conv: []const u8 = "main" };

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
        const last = (if (parts.len == 1)
            std.fmt.allocPrint(a, "Allow this?\n{s}", .{what})
        else
            std.fmt.allocPrint(a, "Allow this? ({d}/{d})\n{s}", .{ parts.len, parts.len, parts[parts.len - 1] })) catch return .deny;
        // in the run's conversation (main, with its name, for a topic Telegram refused)
        const where = c.placeOf(a, ca.conv) catch return .deny;
        const text = if (where.prefix) |p| std.fmt.allocPrint(a, "[{s}] {s}", .{ p, last }) catch return .deny else last;
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
        // a part that did not get through: the owner would answer what they
        // did not see, so no buttons go out and nothing is allowed
        for (heads) |h| c.deliverIn(ca.conv, h) catch {
            c.endQuestion();
            c.sayIn(ca.conv, not_sent_note);
            return .unsent;
        };
        const msg = if (allow_day)
            ch.buttons(ch.ctx, where.place, text, &.{ .{ "Allow once", data[0] }, .{ "Allow 24 h", data[1] }, .{ "Deny", data[2] } })
        else
            ch.buttons(ch.ctx, where.place, text, &.{ .{ "Allow once", data[0] }, .{ "Deny", data[2] } });
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
        if (early_elsewhere) |m| c.tellOutOfDate(where.place.chat, where.place.thread, m);
        // no message id: no press can be told to be this question's, so
        // none would count; refused now rather than after approval_seconds
        if (msg == null) {
            c.endQuestion();
            c.log.write(.chat, false, .{ .event = "not delivered", .why = "the question's buttons could not be sent", .bytes = text.len }) catch {};
            c.sayIn(ca.conv, not_sent_note);
            return .unsent;
        }
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
        c.endQuestion();
        if (msg) |m| ch.clear(ch.ctx, where.place, m);
        if (ans == .timeout) c.sayIn(ca.conv, "No answer in time; not allowed.");
        return ans;
    }

    const not_sent_note = "The question could not be sent, so the call is not allowed.";

    /// Nothing is asked any more: a press from now on is out of date.
    fn endQuestion(c: *Core) void {
        c.approval.mutex.lockUncancelable(c.io);
        defer c.approval.mutex.unlock(c.io);
        c.approval.waiting = false;
        c.approval.msg = null;
        c.approval.shown = false;
        c.approval.early = null;
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

    fn popQueue(c: *Core) ?Queued {
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
            if (c.popQueue()) |item| {
                defer item.deinit(c.gpa);
                c.chatTurnNoted(item.conv, item.text, item.note);
                c.busy.store(false, .release);
                continue;
            }
            // a conversation quiet for memory_quiet_s: its writer reads what is new
            if (c.quietContext()) |x| if (c.claimIdle()) {
                c.writeMemoriesOf(x) catch |e| c.log.write(.memory, false, .{ .event = "writer failed", .why = @errorName(e) }) catch {};
                x.turns_since_memory = 0;
                c.busy.store(false, .release);
            };
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
            .written = &c.written,
        };
    }

    /// A run started by `who`: a chat turn by the owner, a task or brief
    /// by its schedule (`schedule:NAME`), both of the definition main.
    /// Nobody can answer a run a schedule, trigger or workflow started.
    fn runAs(c: *Core, client: *model.Client, label: []const u8, who: who_mod.Who, flag: *std.atomic.Value(bool)) agent.Run {
        var run = c.baseRun(client, label, who.unattended(), flag);
        run.who = who;
        return run;
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
        /// The start of every server ends by this (awake clock, ns),
        /// spawning included.
        deadline_ns: i128 = 0,
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
                .deadline_ns = st.deadline_ns,
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
            st.deadline_ns = deadline;
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
        // together: one grace for all, not one each
        mcp.stopAll(servers.items);
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

    /// A chat turn in `main`.
    fn chatTurn(c: *Core, text: []const u8) void {
        c.chatTurnIn("main", text);
    }

    /// The owner's message `text` in conversation `conv`: one turn, its
    /// questions and its answer there.
    fn chatTurnIn(c: *Core, conv: []const u8, text: []const u8) void {
        c.chatTurnNoted(conv, text, null);
    }

    /// `chatTurnIn`; `note` (the post a quick reply answers) goes in the
    /// turn's context block.
    fn chatTurnNoted(c: *Core, conv: []const u8, text: []const u8, note: ?[]const u8) void {
        const x = c.contextFor(conv) catch |e| {
            var buf: [128]u8 = undefined;
            c.sayIn(conv, std.fmt.bufPrint(&buf, "Something went wrong: {s}", .{@errorName(e)}) catch "Something went wrong.");
            return;
        };
        if (x.reset.swap(false, .acq_rel)) {
            x.conv.deinit();
            x.conv = .init(c.gpa);
            x.memory_upto = 0;
            x.turns_since_memory = 0;
        }
        x.last_owner_s = c.now();
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        var ask: ChatAsk = .{ .core = c, .flag = &flag, .conv = conv };
        var run = c.runIn(&c.chat_client, "chat", .{}, conv, &flag);
        run.context_note = c.contextNote(arena.allocator(), conv) catch "";
        if (note) |n| run.context_note = std.fmt.allocPrint(arena.allocator(), "{s}\n{s}", .{ run.context_note, n }) catch run.context_note;
        run.asker = .{ .ctx = &ask, .ask = askOwner };
        var notify: Notify = .{ .core = c, .conv = conv };
        run.notice = .{ .ctx = &notify, .say = Notify.say };
        var out: RunOut = .{ .core = c };
        run.outbox = out.outbox();
        const res = agent.turn(&run, &x.conv, text, true) catch |e| {
            var buf: [128]u8 = undefined;
            c.sayIn(conv, std.fmt.bufPrint(&buf, "Something went wrong: {s}", .{@errorName(e)}) catch "Something went wrong.");
            return;
        };
        defer agent.freeResult(&run, res);
        // /private switched on while the turn ran: it stays out of memory
        // and summaries too
        const private = run.isPrivate();
        if (private) if (x.conv.turns.getLastOrNull()) |tn| {
            tn.private = true;
        };
        // the reply went out with a final send; a limit or an error is
        // said in harness's words, never with working text; else the
        // model's last text is the reply, through the same path as a send
        if (!res.stopped and !res.replied) {
            if (res.ended_by) |why| c.sayIn(conv, why) else c.implicitReply(&run, arena.allocator(), conv, res.text);
        }
        if (!private) x.turns_since_memory += 1;
    }

    /// The model stopped on its own without a final `send`: its last text is
    /// posted as the reply (the gate decides it like a send); one the gate
    /// stops is said.
    fn implicitReply(c: *Core, run: *agent.Run, a: std.mem.Allocator, conv: []const u8, text: []const u8) void {
        if (text.len == 0) return c.sayIn(conv, "The model gave an empty answer.");
        const got = agent.postReply(run, a, text) catch |e| {
            c.sayIn(conv, std.fmt.allocPrint(a, "The answer was not posted: {s}.", .{@errorName(e)}) catch "The answer was not posted.");
            return;
        };
        if (got.refused) |why| c.sayIn(conv, std.fmt.allocPrint(a, "The answer was not posted: {s}.", .{why}) catch "The answer was not posted.");
    }

    /// A run's way to post (its `agent.Outbox`): the conversations, and the
    /// name of what started it in front of its posts when that was not the
    /// owner.
    const RunOut = struct {
        core: *Core,
        /// "[btc-watch] " for a run the owner did not start; "" otherwise.
        tag: []const u8 = "",
        /// A task's or brief's: what its reply needs and how it went.
        sched: ?*Sched = null,

        fn outbox(o: *RunOut) agent.Outbox {
            return .{ .ctx = o, .find = find, .names = names, .post = post };
        }

        fn find(ctx: *anyopaque, a: std.mem.Allocator, name: []const u8) ?agent.Target {
            const o: *RunOut = @ptrCast(@alignCast(ctx));
            const c = o.core;
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            const e = c.convs.find(name) orelse return null;
            if (!c.reachable(e)) return null;
            return .{ .name = a.dupe(u8, e.name) catch return null, .shared = e.audience == .shared, .private = e.isPrivate() };
        }

        fn names(ctx: *anyopaque, a: std.mem.Allocator) []const []const u8 {
            const o: *RunOut = @ptrCast(@alignCast(ctx));
            const c = o.core;
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            var out: std.ArrayList([]const u8) = .empty;
            for (c.convs.items.items) |e| if (c.reachable(e)) out.append(a, a.dupe(u8, e.name) catch continue) catch {};
            return out.items;
        }

        fn post(ctx: *anyopaque, a: std.mem.Allocator, p: *const agent.Post) agent.Delivery {
            const o: *RunOut = @ptrCast(@alignCast(ctx));
            return o.core.postOut(a, o, p);
        }
    };

    /// A task's or brief's reply: what the run skipped is added to it,
    /// NOTHING (with nothing skipped) posts nothing, and one that did not
    /// get through is kept to be sent again as it was.
    const Sched = struct {
        skipped: ?*agent.Skipped = null,
        keep: ?*?Undelivered = null,
        /// A brief's links, seen once it is delivered.
        links: []const []const u8 = &.{},
        /// How the reply went, and why when it did not.
        outcome: enum { none, sent, kept, failed, silent, held } = .none,
        why: []const u8 = "",
    };

    /// A task's or brief's reply as it is posted: its tag in front, what it
    /// skipped after it; null for NOTHING with nothing skipped.
    fn shapeReply(c: *Core, a: std.mem.Allocator, o: *const RunOut, sc: *const Sched, text: []const u8) ?[]const u8 {
        const note = if (sc.skipped) |s| s.text(c.io, a) catch "" else "";
        const silent = std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n."), "NOTHING");
        if (silent and note.len == 0) return null;
        if (silent) return std.fmt.allocPrint(a, "{s}{s}", .{ o.tag, note }) catch null;
        return std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ o.tag, text, if (note.len > 0) "\n\n" else "", note }) catch null;
    }

    /// A post to a name that is no conversation yet (a task's or brief's
    /// `to`) opens that topic in the owner's chat first. One that can't be
    /// opened goes to main with its name in front; the owner is told why,
    /// once.
    fn ensureTopic(c: *Core, a: std.mem.Allocator, name: []const u8) void {
        if (conversations.isFixed(name)) return;
        const ch = c.chan orelse return;
        // the terminal: printed with the name
        const open_fn = ch.open_topic orelse return;
        c.topic_mutex.lockUncancelable(c.io);
        defer c.topic_mutex.unlock(c.io);
        {
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            if (c.convs.find(name) != null) return;
        }
        const owner = c.owner orelse return;
        const why: []const u8 = blk: {
            if (!c.topics_on) break :blk "topics are off for the bot; switch on topics in private chats in @BotFather";
            const thread = open_fn(ch.ctx, owner, name) catch |e| break :blk std.fmt.allocPrint(a, "Telegram said {s}", .{@errorName(e)}) catch "Telegram refused";
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            _ = c.convs.add(.{ .name = name, .chat = owner, .thread = thread, .created = util.nowSeconds(c.io) }) catch |e|
                break :blk std.fmt.allocPrint(a, "state/conversations could not be written ({s})", .{@errorName(e)}) catch "it could not be kept";
            c.log.write(.config, false, .{ .event = "conversation added", .name = name, .thread = thread, .why = "a post to it" }) catch {};
            return;
        };
        for (c.told_topics.items) |n| if (std.mem.eql(u8, n, name)) return;
        c.told_topics.append(c.gpa, c.gpa.dupe(u8, name) catch return) catch {};
        c.log.write(.chat, false, .{ .event = "topic not opened", .name = name, .why = why }) catch {};
        c.say(std.fmt.allocPrint(a, "The topic {s} could not be opened ({s}), so its posts come here with [{s}] in front.", .{ name, why, name }) catch "A topic could not be opened; its posts come here.");
    }

    /// Whether a run can post to `e` through the attached channel (the
    /// terminal is not reached from Telegram). Under convs.mutex.
    fn reachable(c: *const Core, e: *const conversations.Entry) bool {
        const telegram = if (c.chan) |ch| ch.open_topic != null else false;
        return !(telegram and e.channel == .terminal);
    }

    /// A run's post, past the gate: to its conversation's place, with the
    /// run's tag in front, its files as documents, within the
    /// conversation's hourly limit.
    fn postOut(c: *Core, a: std.mem.Allocator, o: *RunOut, p: *const agent.Post) agent.Delivery {
        // a task's or brief's reply: what it skipped added, NOTHING silent
        const sc: ?*Sched = if (p.final) o.sched else null;
        const d = c.postShaped(a, o, sc, p);
        if (sc) |x| {
            x.outcome = switch (d.status) {
                .sent => .sent,
                .kept => .kept,
                .held => .held,
                .silent => .silent,
                .failed => .failed,
            };
            x.why = d.why;
        }
        return d;
    }

    fn postShaped(c: *Core, a: std.mem.Allocator, o: *RunOut, sc: ?*Sched, p: *const agent.Post) agent.Delivery {
        const text = if (sc) |x|
            c.shapeReply(a, o, x, p.text) orelse return .{ .status = .silent }
        else if (o.tag.len > 0) std.fmt.allocPrint(a, "{s}{s}", .{ o.tag, p.text }) catch p.text else p.text;
        c.ensureTopic(a, p.to);
        if (c.overHourly(a, p.to)) |why| return .{ .status = .held, .why = why };
        const sending = if (p.buttons.len > 0) c.sendWithButtons(a, p.to, text, p.buttons) else c.sendText(p.to, text);
        const sent = sending catch |e| {
            // kept to be sent again as it is: nothing runs again for it
            if (sc) |x| if (worthRetry(e)) if (x.keep) |k| if (Undelivered.of(c.gpa, p.to, text, x.links)) |u| {
                if (k.*) |old| old.deinit(c.gpa);
                k.* = u;
                return .{ .status = .kept, .why = whyUndelivered(e) };
            } else |_| {};
            return .{ .status = .failed, .why = whyUndelivered(e) };
        };
        c.touch(p.to);
        var d: agent.Delivery = .{ .status = .sent, .message = sent.first, .parts = sent.count };
        for (p.files) |f| {
            c.sendFile(a, p.to, f) catch |e| {
                d.status = .failed;
                d.why = std.fmt.allocPrint(a, "{s} was not delivered ({s})", .{ f.name, whyUndelivered(e) }) catch "a file was not delivered";
                return d;
            };
            d.files += 1;
        }
        return d;
    }

    /// Sends a file of a post to conversation `conv`'s place, as a document.
    fn sendFile(c: *Core, a: std.mem.Allocator, conv: []const u8, f: agent.Attachment) !void {
        const ch = c.chan orelse return error.NoChannel;
        const doc = ch.document orelse return error.NoFiles;
        const r = try c.placeOf(a, conv);
        _ = try doc(ch.ctx, r.place, f.name, f.data);
    }

    /// Why a post to `conv` is not sent now: it would be over
    /// `sends_per_hour` (counted per conversation, all runs and replies);
    /// main hears of it once an hour. Null: it may go, and is counted.
    fn overHourly(c: *Core, a: std.mem.Allocator, conv: []const u8) ?[]const u8 {
        const now_s = util.nowSeconds(c.io);
        const limit = c.cfg.limits.sends_per_hour;
        const tell: ?u32 = blk: {
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            // a name harness does not know counts against main, where it goes
            const e = c.convs.find(conv) orelse c.convs.find("main") orelse return null;
            var i: usize = 0;
            while (i < e.posts.items.len) {
                if (now_s - e.posts.items[i] >= 3600) _ = e.posts.orderedRemove(i) else i += 1;
            }
            if (e.posts.items.len < limit) {
                e.posts.append(c.gpa, now_s) catch {};
                return null;
            }
            e.held += 1;
            if (e.told_held_s != 0 and now_s - e.told_held_s < 3600) break :blk null;
            const n = e.held;
            e.held = 0;
            e.told_held_s = now_s;
            break :blk n;
        };
        if (tell) |n| {
            c.log.write(.chat, false, .{ .event = "posts held", .name = conv, .count = n }) catch {};
            c.say(std.fmt.allocPrint(a, "Posts to {s} are over {d} an hour: {d} not sent. /session shows them.", .{ conv, limit, n }) catch "Posts are over the hourly limit; /session shows them.");
        }
        return std.fmt.allocPrint(a, "posts to {s} are over {d} an hour", .{ conv, limit }) catch "over the hourly limit";
    }

    /// The context of conversation `name`: the one kept, or a new one. A
    /// new one past `max_contexts` drops the least used, after its memory
    /// writer has read it; when that conversation comes back, its model is
    /// told turns were dropped. The chat worker's.
    fn contextFor(c: *Core, name: []const u8) !*Context {
        c.ctx_clock += 1;
        if (c.contextOf(name)) |x| {
            x.used = c.ctx_clock;
            return x;
        }
        if (c.contexts.items.len >= max_contexts) c.dropLeastUsed();
        const x = try c.gpa.create(Context);
        errdefer c.gpa.destroy(x);
        x.* = .{ .name = try c.gpa.dupe(u8, name), .conv = .init(c.gpa), .used = c.ctx_clock };
        errdefer c.gpa.free(x.name);
        {
            // the turns its context had before it made room for others
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            if (c.convs.find(name)) |e| {
                x.conv.dropped = e.dropped_turns;
                x.conv.lost = e.dropped_turns;
                x.memory_upto = e.dropped_turns;
            }
        }
        c.ctx_mutex.lockUncancelable(c.io);
        defer c.ctx_mutex.unlock(c.io);
        try c.contexts.append(c.gpa, x);
        return x;
    }

    /// The context kept for conversation `name`, if any.
    pub fn contextOf(c: *Core, name: []const u8) ?*Context {
        c.ctx_mutex.lockUncancelable(c.io);
        defer c.ctx_mutex.unlock(c.io);
        for (c.contexts.items) |x| if (std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    /// /new: conversation `name` starts fresh at its next turn.
    fn resetContext(c: *Core, name: []const u8) void {
        if (c.contextOf(name)) |x| x.reset.store(true, .release);
    }

    /// Drops the least used context, its new turns read by the memory
    /// writer first (not a private conversation's).
    fn dropLeastUsed(c: *Core) void {
        var least: usize = 0;
        for (c.contexts.items, 0..) |x, i| if (x.used < c.contexts.items[least].used) {
            least = i;
        };
        const x = c.contexts.items[least];
        if (x.turns_since_memory > 0 and !c.convPrivate(x.name))
            c.writeMemoriesOf(x) catch |e| c.log.write(.memory, false, .{ .event = "writer failed", .why = @errorName(e) }) catch {};
        const turns = x.conv.dropped + x.conv.turns.items.len;
        {
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            if (c.convs.find(x.name)) |e| e.dropped_turns = turns;
        }
        c.log.write(.chat, false, .{ .event = "context dropped", .name = x.name, .turns = turns }) catch {};
        {
            c.ctx_mutex.lockUncancelable(c.io);
            defer c.ctx_mutex.unlock(c.io);
            _ = c.contexts.orderedRemove(least);
        }
        c.freeContext(x);
    }

    fn freeContext(c: *Core, x: *Context) void {
        x.conv.deinit();
        c.gpa.free(x.name);
        c.gpa.destroy(x);
    }

    /// A context whose conversation was quiet for `memory_quiet_s` with
    /// turns its writer has not read (not a private one's).
    fn quietContext(c: *Core) ?*Context {
        const now_s = c.now();
        c.ctx_mutex.lockUncancelable(c.io);
        const found = for (c.contexts.items) |x| {
            if (x.turns_since_memory > 0 and x.last_owner_s > 0 and now_s - x.last_owner_s >= c.memory_quiet_s) break x;
        } else null;
        c.ctx_mutex.unlock(c.io);
        const x = found orelse return null;
        return if (c.convPrivate(x.name)) null else x;
    }

    /// Whether conversation `name` is private now (before an owner is
    /// paired, 0.3's instance-wide switch).
    fn convPrivate(c: *Core, name: []const u8) bool {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        if (c.convs.find(name)) |e| return e.isPrivate();
        return c.switches.private.load(.acquire);
    }

    /// A run of `who` reporting to conversation `conv`: its lines name it,
    /// and it is private while that conversation is.
    fn runIn(c: *Core, client: *model.Client, label: []const u8, who: who_mod.Who, conv: []const u8, flag: *std.atomic.Value(bool)) agent.Run {
        var run = c.runAs(client, label, who, flag);
        run.conversation = conv;
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        if (c.convs.find(conv)) |e| {
            run.conv_private = &e.private;
            run.private = run.private or e.isPrivate();
        }
        return run;
    }

    /// What the per-turn context block says of the conversations: this
    /// one and where it is, and the others the agent can post to.
    fn contextNote(c: *Core, a: std.mem.Allocator, conv: []const u8) ![]const u8 {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        var out: std.ArrayList(u8) = .empty;
        if (c.convs.find(conv)) |e|
            try out.print(a, "Conversation: {s} ({s}).", .{ conv, e.where() })
        else
            try out.print(a, "Conversation: {s} (a Telegram topic opened at the first post).", .{conv});
        var others: usize = 0;
        for (c.convs.items.items) |e| {
            if (std.mem.eql(u8, e.name, conv) or !c.reachable(e)) continue;
            try out.print(a, "{s}{s}", .{ if (others == 0) " Others: " else ", ", e.name });
            others += 1;
        }
        if (others > 0) try out.append(a, '.');
        return out.items;
    }

    /// Where a run's memory notices go: its conversation.
    const Notify = struct {
        core: *Core,
        conv: []const u8,

        fn say(ctx: *anyopaque, text: []const u8) void {
            const n: *Notify = @ptrCast(@alignCast(ctx));
            n.core.sayIn(n.conv, text);
        }
    };

    const memory_prompt =
        \\From the conversation below, list at most 5 lasting facts about the owner or their wishes that would help in later conversations: preferences, standing instructions, projects, people. One per line, each starting with "- ". Leave out passing details, anything already obvious, and anything already in memory. If there is nothing worth keeping, answer NONE.
    ;
    /// Most of the conversation one writer call reads; the newest turns are
    /// kept.
    const memory_transcript_max = 60_000;
    /// Most of the memory items it is shown, so it does not repeat them.
    const memory_known_max = 8_000;

    /// The quiet-time writer for every context with turns it has not read.
    fn writeMemories(c: *Core) !void {
        c.ctx_mutex.lockUncancelable(c.io);
        const list = try c.gpa.dupe(*Context, c.contexts.items);
        c.ctx_mutex.unlock(c.io);
        defer c.gpa.free(list);
        for (list) |x| try c.writeMemoriesOf(x);
    }

    /// The quiet-time writer: one model call over the turns of context `x`
    /// since its last run (not private ones), which picks up to 5 lasting
    /// facts; what it saves is said in that conversation.
    fn writeMemoriesOf(c: *Core, x: *Context) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const turns = x.conv.turns.items;
        const first_new = x.memory_upto -| x.conv.dropped;
        // newest first, so a long talk keeps its latest part
        var parts: std.ArrayList([]const u8) = .empty;
        var size: usize = 0;
        var i = turns.len;
        while (i > first_new) {
            i -= 1;
            const tn = turns[i];
            if (tn.private) continue;
            var one: std.ArrayList(u8) = .empty;
            for (tn.messages.items) |m| for (m.blocks) |b| switch (b) {
                .text => |said| if (!std.mem.startsWith(u8, said, agent.context_mark)) try one.print(a, "{s}: {s}\n", .{ if (m.role == .user) "Owner" else "Agent", util.cut(said, 2000) }),
                // what it posted is the agent's words
                .tool_use => |u| if (agent.sentText(a, u.name, u.input_json)) |said| try one.print(a, "Agent: {s}\n", .{util.cut(said, 2000)}),
                .tool_result => {},
            };
            if (size + one.items.len > memory_transcript_max) break;
            size += one.items.len;
            try parts.append(a, one.items);
        }
        const upto = x.conv.dropped + turns.len;
        if (parts.items.len == 0) {
            x.memory_upto = upto;
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
        x.memory_upto = upto;
        try c.log.write(.model, false, .{ .run = "memory writer", .result = "ok", .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens });
        const out = try reply.text(a);
        var it = std.mem.splitScalar(u8, out, '\n');
        var n: usize = 0;
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, l, "- ") or n >= 5) continue;
            // switched on while the writer's call ran
            if (c.convPrivate(x.name)) break;
            n += 1;
            // the owner sees what goes into every later prompt: the note is
            // made under the lock and sent after it, as a send can wait on
            // the network while every run needs the lock
            const note = note: {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                const res = c.mem.addFrom(l[2..], null, c.now(), .other) catch break :note null;
                try c.log.write(.memory, false, .{ .event = if (res.merged) "known" else "add", .id = res.id, .by = "memory writer" });
                if (res.merged) break :note null;
                const item = c.mem.find(res.id) orelse break :note null;
                break :note try memory.savedNote(a, item.id, item.body);
            };
            if (note) |text| c.sayIn(x.name, text);
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
            for (c.queue.items) |q| q.deinit(c.gpa);
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
        // messages that did not get through go again when their wait is over
        c.resendDue(now_s);
        const today = c.localDay(now_s);
        const minutes = c.localMinutes(now_s);
        for (c.briefs) |b| {
            if (minutes < b.at_minutes) continue;
            const key = keyFor("brief", b.name);
            if ((c.getRan(key.slice()) orelse -1) >= today) continue;
            if (c.waitsToBeSent(key.slice())) continue;
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
            if (c.waitsToBeSent(key.slice())) continue;
            _ = c.startBackground(.{ .task = tk }, key.slice(), now_s);
        }
    }

    /// Whether `key`'s last message did not get through: until it has, the
    /// brief or task does not run again (`resendDue` sends it).
    fn waitsToBeSent(c: *Core, key: []const u8) bool {
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        return c.retry.contains(key);
    }

    /// Starts sending again each kept message whose wait is over.
    fn resendDue(c: *Core, now_s: i64) void {
        var due: [16]Key = undefined;
        var n: usize = 0;
        {
            c.state_mutex.lockUncancelable(c.io);
            defer c.state_mutex.unlock(c.io);
            var it = c.retry.iterator();
            while (it.next()) |e| {
                if (n == due.len) break;
                if (now_s < e.value_ptr.at or c.running.contains(e.key_ptr.*)) continue;
                const k = e.key_ptr.*;
                due[n] = .{};
                if (k.len > due[n].buf.len) continue;
                @memcpy(due[n].buf[0..k.len], k);
                due[n].len = k.len;
                n += 1;
            }
        }
        for (due[0..n]) |*k| _ = c.startBackground(.resend, k.slice(), now_s);
    }

    /// A message kept for `key` (it did not get through): from now on it is
    /// what goes, after a wait of 5 minutes, then 10, 20, … 2 hours. A
    /// message kept before for the key is replaced. Under state_mutex.
    fn keepUndelivered(c: *Core, key: []const u8, msg: Undelivered, ran: i64, now_s: i64) void {
        var tries: u32 = 1;
        if (c.retry.getPtr(key)) |old| {
            tries = old.tries + 1;
            old.msg.deinit(c.gpa);
            old.msg = .{ .text = &.{} };
        }
        putKey(c.gpa, &c.retry, key, Retry{ .at = now_s + retryWait(tries), .tries = tries, .msg = msg, .ran = ran }) catch msg.deinit(c.gpa);
    }

    /// Drops the message kept for `key`, if any. Under state_mutex.
    fn dropUndelivered(c: *Core, key: []const u8) void {
        if (c.retry.fetchRemove(key)) |kv| {
            kv.value.msg.deinit(c.gpa);
            c.gpa.free(kv.key);
        }
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

    /// A brief or task to run, or a message of one to send again (the
    /// key's, in `retry`).
    const Job = union(enum) { brief: config.Brief, task: config.Task, resend };

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
        if (job == .resend) return c.resend(key);
        // a run that failed or was stopped still counts for its slot, so
        // the scheduler does not start it again right away
        var kept: ?Undelivered = null;
        const outcome: Outcome = switch (job) {
            .brief => |b| c.runBriefKeeping(b, &kept) catch .done,
            .task => |tk| c.runTaskKeeping(tk, &kept) catch .done,
            .resend => unreachable,
        };
        // the day it was due, though it may have ended after midnight
        const v: i64 = switch (job) {
            .brief => c.localDay(due_s),
            .task => due_s,
            .resend => unreachable,
        };
        const now_s = c.now();
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        if (outcome == .undelivered) if (kept) |msg| {
            // not counted as run until its message is delivered
            c.keepUndelivered(key, msg, v, now_s);
            return;
        };
        // a message kept from before is not sent after this one
        c.dropUndelivered(key);
        putKey(c.gpa, &c.ran, key, v) catch {};
        c.saveRan();
    }

    /// Sends again the message kept for `key`. Delivered, the brief or task
    /// counts as run when it was due, and a brief's links as seen.
    fn resend(c: *Core, key: []const u8) void {
        // the entry stays while it is sent; only this key's run (which
        // `running` keeps from starting) changes or drops it
        const r = blk: {
            c.state_mutex.lockUncancelable(c.io);
            defer c.state_mutex.unlock(c.io);
            break :blk c.retry.get(key) orelse return;
        };
        const kp = keyParts(key);
        c.deliverIn(if (r.msg.conv.len > 0) r.msg.conv else "main", r.msg.text) catch |e| {
            c.log.write(kp.kind, false, .{ .name = kp.name, .event = "not delivered", .why = whyUndelivered(e), .tries = r.tries + 1 }) catch {};
            c.state_mutex.lockUncancelable(c.io);
            defer c.state_mutex.unlock(c.io);
            if (worthRetry(e)) {
                if (c.retry.getPtr(key)) |p| {
                    p.tries += 1;
                    p.at = c.now() + retryWait(p.tries);
                }
                return;
            }
            c.dropUndelivered(key);
            putKey(c.gpa, &c.ran, key, r.ran) catch {};
            c.saveRan();
            return;
        };
        c.log.write(kp.kind, false, .{ .name = kp.name, .event = "sent", .tries = r.tries + 1 }) catch {};
        c.markSeen(r.msg.links) catch {};
        c.state_mutex.lockUncancelable(c.io);
        defer c.state_mutex.unlock(c.io);
        c.dropUndelivered(key);
        putKey(c.gpa, &c.ran, key, r.ran) catch {};
        c.saveRan();
    }

    /// The links of a delivered brief count as seen from now.
    fn markSeen(c: *Core, links: []const []const u8) !void {
        if (links.len == 0) return;
        c.seen_mutex.lockUncancelable(c.io);
        defer c.seen_mutex.unlock(c.io);
        const now_s = c.now();
        for (links) |l| try c.seen.add(l, now_s);
        c.seen.prune(now_s);
        c.seen.save(c.io, c.paths.seen) catch {};
    }

    /// How a brief or task run ended, for the scheduler.
    pub const Outcome = enum {
        /// Done, failed or stopped: it waits for its next time.
        done,
        /// Its message did not get through: it is sent again a little later.
        undelivered,
    };

    /// A message that did not get through, kept to be sent again as it is,
    /// to its conversation.
    pub const Undelivered = struct {
        text: []u8,
        /// A brief's links: seen once it is delivered.
        links: [][]u8 = &.{},
        conv: []u8 = &.{},

        fn of(gpa: std.mem.Allocator, conv: []const u8, text: []const u8, links: []const []const u8) !Undelivered {
            const out_links = try gpa.alloc([]u8, links.len);
            var n: usize = 0;
            errdefer {
                for (out_links[0..n]) |l| gpa.free(l);
                gpa.free(out_links);
            }
            for (links) |l| {
                out_links[n] = try gpa.dupe(u8, l);
                n += 1;
            }
            const conv_owned = try gpa.dupe(u8, conv);
            errdefer gpa.free(conv_owned);
            return .{ .text = try gpa.dupe(u8, text), .links = out_links, .conv = conv_owned };
        }

        fn deinit(u: Undelivered, gpa: std.mem.Allocator) void {
            for (u.links) |l| gpa.free(l);
            gpa.free(u.links);
            gpa.free(u.text);
            gpa.free(u.conv);
        }
    };

    /// Collects, writes and sends a brief. Its items count as seen only
    /// once it got through.
    pub fn runBrief(c: *Core, b: config.Brief) !Outcome {
        return c.runBriefKeeping(b, null);
    }

    /// runBrief; a brief that did not get through is kept in `keep` (when
    /// given), to be sent again as it was written.
    fn runBriefKeeping(c: *Core, b: config.Brief, keep: ?*?Undelivered) !Outcome {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client = try model.Client.init(c.gpa, c.io, c.cfg.model.url, c.secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens);
        defer client.deinit();
        const label = try std.fmt.allocPrint(a, "brief {s}", .{b.name});
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        var run = c.runIn(&client, label, .{ .by = try std.fmt.allocPrint(a, "schedule:{s}", .{b.name}) }, b.to, &flag);
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
        // posted to its `to` the way a reply is: through the gate, with its
        // name in front; kept when it did not get through
        var sched: Sched = .{ .keep = keep, .links = w.links };
        var out: RunOut = .{ .core = c, .tag = try std.fmt.allocPrint(a, "[{s}] ", .{b.name}), .sched = &sched };
        run.outbox = out.outbox();
        const got = try agent.postReply(&run, a, w.text);
        if (got.refused) |why| {
            try c.log.write(.brief, false, .{ .name = b.name, .event = "not posted", .why = why });
            c.say(try std.fmt.allocPrint(a, "The brief {s} was not posted: {s}.", .{ b.name, why }));
            return .done;
        }
        switch (sched.outcome) {
            .sent => {
                try c.markSeen(w.links);
                return .done;
            },
            .kept => {
                try c.log.write(.brief, false, .{ .name = b.name, .event = "not delivered", .why = sched.why });
                return .undelivered;
            },
            else => {
                try c.log.write(.brief, false, .{ .name = b.name, .event = "not delivered", .why = sched.why });
                return .done;
            },
        }
    }

    /// Runs a scheduled task once.
    pub fn runTask(c: *Core, tk: config.Task) !Outcome {
        return c.runTaskKeeping(tk, null);
    }

    /// runTask; an answer that did not get through is kept in `keep` (when
    /// given), to be sent again as it is: the task does not run again for it.
    fn runTaskKeeping(c: *Core, tk: config.Task, keep: ?*?Undelivered) !Outcome {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client = try model.Client.init(c.gpa, c.io, c.cfg.model.url, c.secrets.omnigate orelse "", c.cfg.model.model, c.cfg.model.max_tokens);
        defer client.deinit();
        const label = try std.fmt.allocPrint(a, "task {s}", .{tk.name});
        var flag: std.atomic.Value(bool) = .init(false);
        c.register(&flag);
        defer c.unregister(&flag);
        var run = c.runIn(&client, label, .{ .by = try std.fmt.allocPrint(a, "schedule:{s}", .{tk.name}) }, tk.to, &flag);
        run.extra_instructions = try std.fmt.allocPrint(a, "This is the scheduled task \"{s}\". If there is nothing worth telling the owner this time, answer exactly NOTHING.", .{tk.name});
        var skipped: agent.Skipped = .init(c.gpa);
        defer skipped.deinit();
        run.skipped = &skipped;
        var notify: Notify = .{ .core = c, .conv = tk.to };
        run.notice = .{ .ctx = &notify, .say = Notify.say };
        // it posts to its `to` with its name in front, like its reply
        var sched: Sched = .{ .skipped = &skipped, .keep = keep };
        var out: RunOut = .{ .core = c, .tag = try std.fmt.allocPrint(a, "[{s}] ", .{tk.name}), .sched = &sched };
        run.outbox = out.outbox();
        run.context_note = c.contextNote(a, tk.to) catch "";
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
        if (!res.replied) {
            if (res.ended_by) |why| {
                // a limit or an error: harness's line, with what it skipped
                const note = try skipped.text(c.io, a);
                return c.taskMessage(tk, keep, try std.fmt.allocPrint(a, "[{s}] {s}{s}{s}", .{ tk.name, why, if (note.len > 0) "\n\n" else "", note }));
            }
            // NOTHING, with nothing skipped: no post at all
            if (c.shapeReply(a, &out, &sched, res.text) == null) {
                try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = "the answer was NOTHING" });
                return .done;
            }
            const got = try agent.postReply(&run, a, res.text);
            if (got.refused) |why| {
                try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = why });
                c.say(try std.fmt.allocPrint(a, "The answer of task {s} was not posted: {s}.", .{ tk.name, why }));
                return .done;
            }
        }
        // how its reply went, a final send's or harness's post of its text
        switch (sched.outcome) {
            .sent => try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = true }),
            .silent => try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = "the answer was NOTHING" }),
            else => try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = sched.why }),
        }
        return if (sched.outcome == .kept) .undelivered else .done;
    }

    /// Harness's own line for a task (a limit, an error, with what it
    /// skipped): to its conversation (main when others read that); kept to
    /// be sent again when it did not get through.
    fn taskMessage(c: *Core, tk: config.Task, keep: ?*?Undelivered, msg: []const u8) !Outcome {
        const where = if (c.isShared(tk.to)) "main" else tk.to;
        c.deliverIn(where, msg) catch |e| {
            try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = false, .why = whyUndelivered(e) });
            if (!worthRetry(e)) return .done;
            if (keep) |k| k.* = try .of(c.gpa, where, msg, &.{});
            return .undelivered;
        };
        try c.log.write(.task, false, .{ .name = tk.name, .event = "done", .sent = true });
        return .done;
    }

    /// Whether others read conversation `name` (a group).
    fn isShared(c: *Core, name: []const u8) bool {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        const e = c.convs.find(name) orelse return false;
        return e.audience == .shared;
    }

    // ---- commands ----

    const help_text =
        \\Commands
        \\/stop: stop everything running now
        \\/new: start fresh in this conversation (memory stays)
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
        \\/private on|off: in this conversation, no memories written while on
        \\/skills: list saved skills, /skill rm NAME
        \\/logins: the agent's own logins
        \\/dryrun on|off: money tools are not called while on
        \\/reload: apply changed settings files
        \\/conversations: where you and the agent talk
        \\/conversation new NAME: open a topic for a subject
        \\/conversation rename OLD NEW, /conversation rm NAME
        \\/conversation add NAME: sent in a group, the agent may post there
    ;

    /// A command sent in `main` (or from the command line).
    pub fn command(c: *Core, a: std.mem.Allocator, text: []const u8) ![]const u8 {
        return c.commandIn(a, "main", text);
    }

    /// A command sent in conversation `conv`; returns its reply.
    fn commandIn(c: *Core, a: std.mem.Allocator, conv: []const u8, text: []const u8) ![]const u8 {
        var words = std.mem.tokenizeAny(u8, text, " \t");
        const cmd = c.commandWord(words.next() orelse return "");
        const rest = std.mem.trim(u8, words.rest(), " \t");
        try c.log.write(.chat, c.convPrivate(conv), .{ .event = "command", .command = cmd, .args = rest });
        const eql = std.mem.eql;
        if (eql(u8, cmd, "/help") or eql(u8, cmd, "/start")) return help_text;
        if (eql(u8, cmd, "/pair")) return "Already paired.";
        if (eql(u8, cmd, "/stop")) return c.stopAll();
        if (eql(u8, cmd, "/new")) {
            c.resetContext(conv);
            return "New conversation.";
        }
        if (eql(u8, cmd, "/reload")) return c.reload();
        if (eql(u8, cmd, "/status")) {
            return std.fmt.allocPrint(a, "Chat: {s}. Background runs: {d}. Queued: {d}.\nAutomatic recall: {s}. Private: {s}. Dry run: {s}.\nBrowser: {s}. Logins: {d}.{s}{s}", .{
                if (c.busy.load(.acquire)) "working" else "idle", c.bg_active.load(.acquire), c.queue.items.len,
                onOff(c.switches.auto_recall.load(.acquire)), onOff(c.convPrivate(conv)),
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
            {
                c.convs.mutex.lockUncancelable(c.io);
                defer c.convs.mutex.unlock(c.io);
                if (c.convs.find(conv)) |e| {
                    e.private.store(v, .release);
                    c.convs.save() catch |err| return std.fmt.allocPrint(a, "Private is {s} until harness stops: state/conversations could not be written ({s}).", .{ onOff(v), @errorName(err) });
                } else {
                    // no main before an owner is paired: the instance's switch
                    c.switches.private.store(v, .release);
                    c.saveSwitches();
                }
            }
            try c.log.write(.config, false, .{ .event = "private", .name = conv, .on = v });
            return if (v) "Private here: nothing from this conversation is written to memory, and the log keeps only sizes and hashes of what is said in it." else "Private is off here.";
        }
        if (eql(u8, cmd, "/remember")) {
            if (rest.len == 0) return "Use /remember TEXT.";
            if (c.convPrivate(conv)) return "Not saved: private is on, so nothing is written to memory. Send /private off first.";
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
        if (eql(u8, cmd, "/conversations")) return c.conversationsText(a);
        if (eql(u8, cmd, "/conversation")) return c.conversationCommand(a, conv, rest);
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

    /// A line per conversation: its name, where it is, private, last used.
    fn conversationsText(c: *Core, a: std.mem.Allocator) ![]const u8 {
        c.convs.mutex.lockUncancelable(c.io);
        defer c.convs.mutex.unlock(c.io);
        var out: std.ArrayList(u8) = .empty;
        for (c.convs.items.items) |e| {
            try out.print(a, "{s}: {s}, private {s}, ", .{ e.name, e.where(), onOff(e.isPrivate()) });
            if (e.used_s == 0) try out.appendSlice(a, "not used since harness started\n") else {
                var tb: [20]u8 = undefined;
                try out.print(a, "last used {s}\n", .{util.isoTime(&tb, e.used_s)});
            }
        }
        return out.items;
    }

    const conversation_usage = "Use /conversation new NAME, /conversation rename OLD NEW or /conversation rm NAME (/conversation add NAME is sent in a group).";
    const name_rule = "A conversation's name uses a-z, 0-9, - and _ (up to 32), and is not new, rename, rm or add.";

    /// `/conversation new|rename|rm|add`, sent in `from`.
    fn conversationCommand(c: *Core, a: std.mem.Allocator, from: []const u8, rest: []const u8) ![]const u8 {
        _ = from;
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        const op = words.next() orelse return conversation_usage;
        const x = words.next() orelse "";
        const y = words.next() orelse "";
        if (words.next() != null) return conversation_usage;
        const eql = std.mem.eql;
        if (eql(u8, op, "add")) return "Send /conversation add NAME in the group the agent may post in (add the bot to the group first).";
        if (eql(u8, op, "new")) {
            if (x.len == 0 or y.len > 0) return conversation_usage;
            if (!conversations.validName(x)) return name_rule;
            return c.openTopic(a, x);
        }
        if (eql(u8, op, "rename")) {
            if (x.len == 0 or y.len == 0) return conversation_usage;
            if (conversations.isFixed(x)) return "main and terminal keep their names.";
            if (!conversations.validName(y)) return name_rule;
            {
                c.convs.mutex.lockUncancelable(c.io);
                defer c.convs.mutex.unlock(c.io);
                c.convs.rename(x, y) catch |e| return switch (e) {
                    error.NotFound => "No conversation with that name.",
                    error.Taken => "Another conversation has that name.",
                    else => std.fmt.allocPrint(a, "Not renamed: harness could not write state/conversations ({s}).", .{@errorName(e)}),
                };
            }
            try c.log.write(.config, false, .{ .event = "conversation renamed", .name = x, .to = y });
            return std.fmt.allocPrint(a, "Renamed {s} to {s}.", .{ x, y });
        }
        if (eql(u8, op, "rm")) {
            if (x.len == 0 or y.len > 0) return conversation_usage;
            if (conversations.isFixed(x)) return "main and terminal stay.";
            {
                c.convs.mutex.lockUncancelable(c.io);
                defer c.convs.mutex.unlock(c.io);
                c.convs.remove(x) catch |e| return switch (e) {
                    error.NotFound => "No conversation with that name.",
                    else => std.fmt.allocPrint(a, "Not removed: harness could not write state/conversations ({s}).", .{@errorName(e)}),
                };
            }
            try c.log.write(.config, false, .{ .event = "conversation removed", .name = x });
            return std.fmt.allocPrint(a, "Forgot {s}: the agent no longer posts there. A topic stays in Telegram; a message in it makes it a conversation again.", .{x});
        }
        return conversation_usage;
    }

    /// Opens topic `name` in the owner's chat with the bot and keeps it as
    /// a conversation; returns what to tell the owner.
    fn openTopic(c: *Core, a: std.mem.Allocator, name: []const u8) ![]const u8 {
        const owner = c.owner orelse return "Pair an account first (harness pair).";
        const ch = c.chan orelse return "There is no chat to open a topic in.";
        const open_fn = ch.open_topic orelse return "Topics are Telegram's: send /conversation new there.";
        if (!c.topics_on) return "Topics are off for this bot: switch on topics in private chats in @BotFather (Bot API 9.3), then send /conversation new again.";
        {
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            if (c.convs.find(name) != null) return "A conversation has that name already.";
        }
        const thread = open_fn(ch.ctx, owner, name) catch |e|
            return std.fmt.allocPrint(a, "Telegram did not open the topic ({s}). Are topics in private chats on for the bot in @BotFather?", .{@errorName(e)});
        {
            c.convs.mutex.lockUncancelable(c.io);
            defer c.convs.mutex.unlock(c.io);
            _ = c.convs.add(.{ .name = name, .chat = owner, .thread = thread, .created = util.nowSeconds(c.io) }) catch |e|
                return std.fmt.allocPrint(a, "The topic is open, but harness could not keep it ({s}).", .{@errorName(e)});
        }
        try c.log.write(.config, false, .{ .event = "conversation added", .name = name, .thread = thread });
        return std.fmt.allocPrint(a, "Opened the topic {s}: write there to talk about it.", .{name});
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

/// A brief's or task's message that did not get through: sent again as it
/// was written when `at` comes, so nothing runs again for it.
const Retry = struct {
    at: i64,
    tries: u32,
    /// Owned by the core.
    msg: Core.Undelivered,
    /// What `ran` gets for the key once the message is delivered.
    ran: i64,
};

/// How long a message that did not get through waits before it is sent
/// again, after `tries` attempts: 5 minutes, then 10, 20, … 2 hours.
fn retryWait(tries: u32) i64 {
    return @min(@as(i64, 5 * 60) << @intCast(@min(@max(tries, 1) - 1, 8)), 2 * 3600);
}

/// The log kind and the name in a key of `ran` ("task:NAME", "brief:NAME",
/// "brief-now:NAME").
fn keyParts(key: []const u8) struct { kind: log_mod.Kind, name: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse key.len;
    return .{ .kind = if (std.mem.startsWith(u8, key, "task:")) .task else .brief, .name = key[@min(colon + 1, key.len)..] };
}

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
    /// Where each of `lines` went.
    where: std.ArrayList(Where) = .empty,
    next_id: i64 = 0,
    /// The id the next message without buttons gets (apart from theirs).
    next_text: i64 = 100_000,
    /// The thread the next topic opened gets, less one.
    next_thread: i64 = 5000,
    /// While set, Telegram opens no topic.
    topics_fail: bool = false,
    /// While set, a send to a topic is refused (Telegram lost the topic).
    threads_fail: bool = false,
    /// The messages whose buttons were taken off.
    cleared: std.ArrayList(i64) = .empty,
    /// While set, sends fail with it and nothing is recorded.
    fail: ?anyerror = null,
    /// While set, a message with buttons is not sent: no message id.
    buttons_fail: bool = false,
    /// A lock no send may be made under: one made while it is held is
    /// recorded with "[lock held] " in front.
    probe: ?*Io.Mutex = null,
    /// The last question's buttons and the message they are in.
    last: Buttons = .{},
    /// Called once buttons are recorded, before their message id is
    /// returned: an owner who presses before harness knows the message.
    early: ?Early = null,

    const Early = struct { ctx: *anyopaque, press: *const fn (ctx: *anyopaque, b: *const Buttons) void };

    const Where = struct { name: []u8, chat: i64, thread: i64 };

    const Buttons = struct {
        msg: i64 = 0,
        n: usize = 0,
        buf: [4][64]u8 = undefined,
        len: [4]usize = @splat(0),

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
        for (r.where.items) |w| t.allocator.free(w.name);
        r.where.deinit(t.allocator);
        r.cleared.deinit(t.allocator);
    }

    fn channel(r: *Recorder) Channel {
        return .{ .ctx = r, .send = send, .buttons = buttons, .clear = clear, .send_to = sendTo, .document = document, .open_topic = openTopic };
    }

    /// Notes a line and where it went (under the mutex).
    fn note(r: *Recorder, place: Place, line: []u8) !void {
        try r.lines.append(t.allocator, line);
        try r.where.append(t.allocator, .{ .name = try t.allocator.dupe(u8, place.name), .chat = place.chat, .thread = place.thread });
    }

    fn document(ctx: *anyopaque, place: Place, name: []const u8, data: []const u8) anyerror!i64 {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        if (r.fail) |e| return e;
        try r.note(place, try std.fmt.allocPrint(t.allocator, "DOC {s} ({d} bytes)", .{ name, data.len }));
        r.next_text += 1;
        return r.next_text;
    }

    fn openTopic(ctx: *anyopaque, chat: i64, name: []const u8) anyerror!i64 {
        _ = chat;
        _ = name;
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        if (r.topics_fail) return error.TelegramRefused;
        r.next_thread += 1;
        return r.next_thread;
    }

    /// Where the first line containing `needle` went.
    fn whereOf(r: *Recorder, needle: []const u8) ?Where {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        for (r.lines.items, r.where.items) |l, w| if (std.mem.indexOf(u8, l, needle) != null) return w;
        return null;
    }

    /// The lines containing `needle` that went to conversation `conv`.
    fn countIn(r: *Recorder, conv: []const u8, needle: []const u8) usize {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        var n: usize = 0;
        for (r.lines.items, r.where.items) |l, w| if (std.mem.eql(u8, w.name, conv) and std.mem.indexOf(u8, l, needle) != null) {
            n += 1;
        };
        return n;
    }

    /// Waits until a line containing `needle` went to `conv`.
    fn waitIn(r: *Recorder, conv: []const u8, needle: []const u8) !void {
        var waited: u32 = 0;
        while (waited < 8000) : (waited += 20) {
            if (r.countIn(conv, needle) > 0) return;
            t.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        std.debug.print("waited for {s} in {s}; got:\n", .{ needle, conv });
        for (r.lines.items, r.where.items) |l, w| std.debug.print("  [{s} {d}/{d}] {s}\n", .{ w.name, w.chat, w.thread, l });
        return error.TestTimedOut;
    }

    fn sendTo(ctx: *anyopaque, chat_id: i64, text: []const u8) anyerror!void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        try r.note(.{ .name = "(another account)", .chat = chat_id }, try std.fmt.allocPrint(t.allocator, "TO {d}: {s}", .{ chat_id, text }));
    }

    fn setFail(r: *Recorder, e: ?anyerror) void {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        r.fail = e;
    }

    fn send(ctx: *anyopaque, place: Place, text: []const u8) anyerror!Sent {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        if (r.fail) |e| return e;
        if (r.threads_fail and place.thread != 0) return error.TopicRefused;
        const held = if (r.probe) |m| blk: {
            if (!m.tryLock()) break :blk true;
            m.unlock(t.io);
            break :blk false;
        } else false;
        try r.note(place, try std.fmt.allocPrint(t.allocator, "{s}{s}", .{ if (held) "[lock held] " else "", text }));
        r.next_text += 1;
        return .{ .first = r.next_text, .count = 1 };
    }

    fn buttons(ctx: *anyopaque, place: Place, text: []const u8, bs: []const [2][]const u8) ?i64 {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const shown = blk: {
            r.mutex.lockUncancelable(t.io);
            defer r.mutex.unlock(t.io);
            if (r.buttons_fail) return null;
            const line = std.fmt.allocPrint(t.allocator, "BUTTONS {s} [{s}]", .{ text, bs[0][1] }) catch return null;
            r.note(place, line) catch {};
            r.next_id += 1;
            r.last = .{ .msg = r.next_id, .n = @min(bs.len, 4) };
            for (bs[0..r.last.n], 0..) |b, i| {
                r.last.len[i] = @min(b[1].len, 64);
                @memcpy(r.last.buf[i][0..r.last.len[i]], b[1][0..r.last.len[i]]);
            }
            break :blk r.last;
        };
        if (r.early) |e| e.press(e.ctx, &shown);
        return shown.msg;
    }

    fn clear(ctx: *anyopaque, place: Place, id: i64) void {
        _ = place;
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        r.cleared.append(t.allocator, id) catch {};
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

/// The text of state/conversations.
fn conversationsText(f: *Fix) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(t.io, f.core.paths.conversations, f.e.arena.allocator(), .unlimited);
}

/// A message from the owner in topic `thread` of their chat with the bot.
fn inTopic(thread: i64, topic: ?[]const u8, text: []const u8) Incoming {
    return .{ .from = 42, .chat = 42, .thread = thread, .topic = topic, .text = text };
}

test "a_reply_goes_to_the_conversation_the_message_came_from" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.textReply("Three flats match."));
    try f.core.startWorker();
    try f.core.handleIncoming(inTopic(5012, "House search", "find flats"));
    try f.rec.waitFor("Three flats match.");
    const w = f.rec.whereOf("Three flats match.").?;
    try t.expectEqualStrings("house-search", w.name);
    try t.expectEqual(42, w.chat);
    try t.expectEqual(5012, w.thread);
    try t.expectEqual(0, f.rec.countIn("main", "Three flats"));
    // a command's reply goes where the command came from
    try f.core.handleIncoming(inTopic(5012, null, "/memory"));
    try f.rec.waitIn("house-search", "No memories");
}

test "a_new_topic_is_a_conversation_named_after_it_before_its_turn_starts" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    // no worker: nothing has run when it is written down
    try f.core.handleIncoming(inTopic(5012, "House search", "find flats"));
    const text = try conversationsText(&f);
    try t.expect(std.mem.indexOf(u8, text, "{\"name\":\"house-search\",\"channel\":\"telegram\",\"chat\":42,\"thread\":5012,\"audience\":\"own\",\"private\":false,") != null);
    try t.expectEqual(1, f.core.queue.items.len);
    try t.expectEqualStrings("house-search", f.core.queue.items[0].conv);
    // another topic of the same name, and one whose name is not known
    try f.core.handleIncoming(inTopic(5013, "House search", "and this one"));
    try f.core.handleIncoming(inTopic(5014, null, "and here"));
    const after = try conversationsText(&f);
    try t.expect(std.mem.indexOf(u8, after, "\"name\":\"house-search-2\",\"channel\":\"telegram\",\"chat\":42,\"thread\":5013") != null);
    try t.expect(std.mem.indexOf(u8, after, "\"name\":\"topic-5014\",\"channel\":\"telegram\",\"chat\":42,\"thread\":5014") != null);
    // a later message in the first topic is the same conversation
    try f.core.handleIncoming(inTopic(5012, null, "more"));
    try t.expectEqualStrings("house-search", f.core.queue.items[3].conv);
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"event\":\"conversation added\",\"name\":\"house-search\"") != null);
}

test "pairing_another_account_moves_main_and_drops_the_old_topics" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.core.handleIncoming(inTopic(5012, "House search", "find flats"));
    var buf: [8]u8 = undefined;
    const code = try newPairCode(t.io, f.core.paths, f.core.now(), &buf);
    try f.core.handleMessage(77, try std.fmt.allocPrint(a, "/pair {s}", .{code}));
    try f.rec.waitFor("TO 42: This bot is now paired with another account");
    try f.rec.waitFor("The topics of the account paired before are no longer conversations: house-search.");
    // said in the new account's chat
    try t.expectEqual(77, f.rec.whereOf("no longer conversations").?.chat);
    {
        f.core.convs.mutex.lockUncancelable(t.io);
        defer f.core.convs.mutex.unlock(t.io);
        try t.expectEqual(77, f.core.convs.find("main").?.chat);
        try t.expectEqual(null, f.core.convs.find("house-search"));
    }
    const text = try conversationsText(&f);
    try t.expect(std.mem.indexOf(u8, text, "house-search") == null);
    try t.expect(std.mem.indexOf(u8, text, "{\"name\":\"main\",\"channel\":\"telegram\",\"chat\":77,") != null);
}

test "conversation_commands_open_rename_and_forget" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.core.handleText("/conversation new trading");
    try f.rec.waitFor("Opened the topic trading");
    {
        f.core.convs.mutex.lockUncancelable(t.io);
        defer f.core.convs.mutex.unlock(t.io);
        const e = f.core.convs.find("trading").?;
        try t.expectEqual(5001, e.thread);
        try t.expectEqual(42, e.chat);
    }
    try f.core.handleText("/conversations");
    try f.rec.waitFor("trading: Telegram topic, private off");
    try f.rec.waitFor("main: Telegram chat, private off");
    try f.rec.waitFor("terminal: terminal");
    try f.core.handleText("/conversation new Bad");
    try f.rec.waitFor("a-z, 0-9");
    try f.core.handleText("/conversation rename trading markets");
    try f.rec.waitFor("Renamed trading to markets.");
    try f.core.handleText("/conversation rename main home");
    try f.rec.waitFor("main and terminal keep their names");
    try f.core.handleText("/conversation rm markets");
    try f.rec.waitFor("Forgot markets");
    try f.core.handleText("/conversation rm terminal");
    try f.rec.waitFor("main and terminal stay");
    const text = try conversationsText(&f);
    try t.expect(std.mem.indexOf(u8, text, "markets") == null);
    try t.expect(std.mem.indexOf(u8, text, "trading") == null);
    // without topics for the bot: how to switch them on
    f.core.topics_on = false;
    try f.core.handleText("/conversation new flats");
    try f.rec.waitFor("switch on topics in private chats in @BotFather");
}

test "a_group_is_read_only_for_conversation_add" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    f.core.setBot("harness_test_bot", true);
    const group: Incoming = .{ .from = 42, .chat = -1001234567890, .chat_type = "supergroup", .text = "hello group" };
    try f.core.handleIncoming(group);
    try t.expectEqual(0, f.core.queue.items.len);
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"event\":\"dropped\",\"from\":42,\"chat\":-1001234567890") != null);
    // a stranger's /conversation add is dropped too
    var stranger = group;
    stranger.from = 7;
    stranger.text = "/conversation add evil";
    try f.core.handleIncoming(stranger);
    var add = group;
    add.text = "/conversation@harness_test_bot add family";
    try f.core.handleIncoming(add);
    try f.rec.waitFor("Added: the agent may post here as family.");
    try t.expectEqual(-1001234567890, f.rec.whereOf("Added: the agent").?.chat);
    {
        f.core.convs.mutex.lockUncancelable(t.io);
        defer f.core.convs.mutex.unlock(t.io);
        try t.expectEqual(.shared, f.core.convs.find("family").?.audience);
        try t.expectEqual(null, f.core.convs.find("evil"));
    }
    try t.expectEqual(0, f.core.queue.items.len);
}

/// A topic of the owner's chat known as conversation `name`.
fn addTopic(f: *Fix, name: []const u8, thread: i64) !void {
    f.core.convs.mutex.lockUncancelable(t.io);
    defer f.core.convs.mutex.unlock(t.io);
    _ = try f.core.convs.add(.{ .name = name, .chat = 42, .thread = thread });
}

test "new_resets_only_its_conversation" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try addTopic(&f, "house-search", 5012);
    try f.e.script(1, model.textReply("one"));
    try f.e.script(2, model.textReply("two"));
    try f.e.script(3, model.textReply("three"));
    try f.e.script(4, model.textReply("four"));
    f.core.chatTurn("first in main");
    f.core.chatTurnIn("house-search", "first in the topic");
    try f.core.handleTextIn("house-search", "/new");
    try f.rec.waitIn("house-search", "New conversation.");
    f.core.chatTurnIn("house-search", "second in the topic");
    f.core.chatTurn("second in main");
    const req3 = try f.e.request(3);
    try t.expect(std.mem.indexOf(u8, req3, "first in the topic") == null);
    try t.expect(std.mem.indexOf(u8, req3, "first in main") == null);
    const req4 = try f.e.request(4);
    try t.expect(std.mem.indexOf(u8, req4, "first in main") != null);
    try t.expect(std.mem.indexOf(u8, req4, "the topic") == null);
}

test "the_17th_context_drops_the_least_used_after_its_memories_are_written" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    var n: u32 = 0;
    for (0..17) |i| {
        const name = try std.fmt.allocPrint(a, "t{d}", .{i});
        try addTopic(&f, name, 5000 + @as(i64, @intCast(i)));
        n += 1;
        // the 17th turn first has the writer read the least used context
        if (i == 16) {
            try f.e.script(n, model.textReply("NONE"));
            n += 1;
        }
        try f.e.script(n, model.textReply("ok"));
        f.core.chatTurnIn(name, try std.fmt.allocPrint(a, "message-{d:0>2} about kayaks", .{i}));
    }
    const writer = try f.e.request(17);
    try t.expect(std.mem.indexOf(u8, writer, "lasting facts") != null);
    try t.expect(std.mem.indexOf(u8, writer, "message-00 about kayaks") != null);
    try t.expect(std.mem.indexOf(u8, writer, "message-01") == null);
    try t.expectEqual(16, f.core.contexts.items.len);
    try t.expectEqual(null, f.core.contextOf("t0"));
    // t0 comes back (t1 makes room, read by the writer first) and its
    // model is told turns were dropped
    try f.e.script(19, model.textReply("NONE"));
    try f.e.script(20, model.textReply("welcome back"));
    f.core.chatTurnIn("t0", "back again");
    try t.expect(std.mem.indexOf(u8, try f.e.request(19), "message-01 about kayaks") != null);
    const back = try f.e.request(20);
    try t.expect(std.mem.indexOf(u8, back, "1 earlier turns of this conversation were dropped") != null);
    try t.expect(std.mem.indexOf(u8, back, "message-00") == null);
}

test "every_line_of_a_run_carries_its_rid_and_conversation" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell echo *\n" });
    _ = try f.core.reload();
    try addTopic(&f, "house-search", 5012);
    try addTopic(&f, "trading", 5013);
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo hi\"}"));
    try f.e.script(2, model.textReply("done"));
    f.core.chatTurnIn("house-search", "say hi");
    // the model knows where it is and where else it can post
    try t.expect(std.mem.indexOf(u8, try f.e.request(1), "Conversation: house-search (Telegram topic). Others: main, trading.") != null);
    const a = f.e.arena.allocator();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try logText(&f), "\n"), '\n');
    var rid: ?i64 = null;
    var n: usize = 0;
    while (lines.next()) |l| {
        const v = jv.parse(a, l).?;
        if (jv.get(v, "run") == null) continue;
        n += 1;
        if (rid == null) rid = jv.int(jv.get(v, "rid")).?;
        try t.expectEqual(rid.?, jv.int(jv.get(v, "rid")).?);
        try t.expectEqualStrings("house-search", jv.str(jv.get(v, "conversation")).?);
    }
    try t.expect(n >= 6);
}

/// The model's reply: `blocks` (JSON content blocks) and a stop reason.
fn replyOf(f: *Fix, blocks: []const u8, stop: []const u8) ![]const u8 {
    return std.fmt.allocPrint(f.e.arena.allocator(), "{{\"content\":[{s}],\"stop_reason\":\"{s}\"}}", .{ blocks, stop });
}

/// The log lines of kind `send`, in order.
fn sendLines(f: *Fix) ![]const []const u8 {
    const a = f.e.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, try logText(f), '\n');
    while (lines.next()) |l| if (std.mem.indexOf(u8, l, "\"kind\":\"send\"") != null) try out.append(a, l);
    return out.items;
}

test "send_final_posts_once_and_ends_the_turn_without_another_model_call" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, try replyOf(&f,
        \\{"type":"text","text":"Here you go."},{"type":"tool_use","id":"tu_1","name":"send","input":{"text":"Three flats match.","final":true}},{"type":"tool_use","id":"tu_2","name":"recall","input":{"query":"after"}}
    , "tool_use"));
    try f.e.script(2, model.textReply("You are welcome."));
    f.core.chatTurn("find flats");
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqual(1, f.rec.count("Three flats match."));
    // working text is never posted, and the call after the final send never ran
    try t.expectEqual(0, f.rec.count("Here you go."));
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"tool\":\"recall\",\"event\":\"not run: the turn ended with the final send\"") != null);
    const sends = try sendLines(&f);
    try t.expectEqual(1, sends.len);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"to\":\"main\",\"event\":\"sent\"") != null);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"final\":true,\"implicit\":false,\"delivered\":true") != null);
    // the next turn's message joins the results in one user message, results first
    f.core.chatTurn("thanks");
    const a = f.e.arena.allocator();
    const msgs = jv.arr(jv.at(jv.parse(a, try f.e.request(2)), &.{ "body", "messages" })).?;
    for (msgs[1..], msgs[0 .. msgs.len - 1]) |m, prev| try t.expect(!std.mem.eql(u8, jv.str(jv.get(m, "role")).?, jv.str(jv.get(prev, "role")).?));
    const last = jv.arr(jv.get(msgs[msgs.len - 1], "content")).?;
    try t.expectEqualStrings("tool_result", jv.str(jv.get(last[0], "type")).?);
    try t.expectEqualStrings("tu_1", jv.str(jv.get(last[0], "tool_use_id")).?);
    try t.expect(std.mem.startsWith(u8, jv.str(jv.get(last[0], "content")).?, "posted to main"));
    try t.expectEqualStrings("tu_2", jv.str(jv.get(last[1], "tool_use_id")).?);
    try t.expect(std.mem.startsWith(u8, jv.str(jv.get(last[1], "content")).?, "not run: the turn ended with your final send"));
    try t.expectEqualStrings("thanks", jv.str(jv.get(last[last.len - 1], "text")).?);
    try t.expectEqual(1, f.rec.count("You are welcome."));
}

test "a_turn_that_stops_without_send_posts_its_last_text_once" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.textReply("Plain answer."));
    f.core.chatTurn("hello");
    try t.expectEqual(1, f.rec.count("Plain answer."));
    const sends = try sendLines(&f);
    try t.expectEqual(1, sends.len);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"to\":\"main\",\"event\":\"sent\"") != null);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"Plain answer.\"") != null);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"final\":true,\"implicit\":true,\"delivered\":true") != null);
    // the model is told to use send; the fallback is not mentioned
    const req = try f.e.request(1);
    try t.expect(std.mem.indexOf(u8, req, "The owner sees only what you post with send.") != null);
    try t.expect(std.mem.indexOf(u8, req, "\"name\":\"send\"") != null);
}

test "a_note_mid_turn_does_not_take_the_replys_place" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, try replyOf(&f,
        \\{"type":"text","text":"working on it"},{"type":"tool_use","id":"tu_1","name":"send","input":{"text":"Looking at three sites now."}}
    , "tool_use"));
    try f.e.script(2, model.textReply("Found two flats."));
    f.core.chatTurn("find flats");
    try t.expectEqual(2, f.e.server.modelRequests());
    try t.expectEqual(1, f.rec.count("Looking at three sites now."));
    try t.expectEqual(1, f.rec.count("Found two flats."));
    try t.expectEqual(0, f.rec.count("working on it"));
    const sends = try sendLines(&f);
    try t.expectEqual(2, sends.len);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"final\":false,\"implicit\":false") != null);
    try t.expect(std.mem.indexOf(u8, sends[1], "\"final\":true,\"implicit\":true") != null);
}

test "working_text_is_never_posted" {
    var f: Fix = undefined;
    try f.init("[limits]\nsteps_per_turn = 1\n", "", "");
    defer f.deinit();
    // text and a tool call, then the step limit
    try f.e.script(1, model.toolReply("tu_1", "recall", "{\"query\":\"flats\"}"));
    f.core.chatTurn("look it up");
    try t.expectEqual(0, f.rec.count("Let me check."));
    try t.expectEqual(1, f.rec.count("Step limit reached for this turn."));
    try t.expectEqual(0, (try sendLines(&f)).len);
}

test "helpers_never_get_send" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "delegate", "{\"tasks\":[{\"task\":\"post it\",\"tools\":[\"send\",\"recall\"]}]}"));
    try f.e.script(2, model.toolReply("h1", "send", "{\"text\":\"from a helper\",\"final\":true}"));
    try f.e.script(3, model.textReply("helper done"));
    try f.e.script(4, model.textReply("All done."));
    f.core.chatTurn("split it");
    try t.expect(std.mem.indexOf(u8, try f.e.request(1), "\"name\":\"send\"") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "\"name\":\"send\"") == null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(3), "this tool is not available here") != null);
    try t.expectEqual(0, f.rec.count("from a helper"));
    try t.expectEqual(1, f.rec.count("All done."));
}

test "a_rule_that_stops_the_reply_is_said_in_main" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "deny send main\n" });
    _ = try f.core.reload();
    try f.e.script(1, model.textReply("You will not see this."));
    f.core.chatTurn("hello");
    try t.expectEqual(0, f.rec.count("You will not see this."));
    try f.rec.waitIn("main", "The answer was not posted: rule on line 1.");
    const sends = try sendLines(&f);
    try t.expectEqual(1, sends.len);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"event\":\"refused\"") != null);
}

/// A group the owner registered, known as conversation `name`.
fn addGroup(f: *Fix, name: []const u8, chat: i64) !void {
    f.core.convs.mutex.lockUncancelable(t.io);
    defer f.core.convs.mutex.unlock(t.io);
    _ = try f.core.convs.add(.{ .name = name, .chat = chat, .audience = .shared });
}

test "send_to_another_conversation_is_allowed_and_logged" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try addTopic(&f, "trading", 5013);
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"to\":\"trading\",\"text\":\"BTC is up 4%.\"}"));
    try f.e.script(2, model.textReply("Told trading."));
    f.core.chatTurn("tell trading");
    try t.expectEqual(1, f.rec.countIn("trading", "BTC is up 4%."));
    try t.expectEqual(5013, f.rec.whereOf("BTC is up 4%.").?.thread);
    try t.expectEqual(1, f.rec.countIn("main", "Told trading."));
    try t.expectEqual(0, f.rec.count("BUTTONS"));
    const sends = try sendLines(&f);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"conversation\":\"main\",\"run\":\"chat\",\"to\":\"trading\",\"event\":\"sent\"") != null);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"delivered\":true") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "posted to trading (1 message)") != null);
}

test "send_to_an_unknown_conversation_names_the_known_ones" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try addTopic(&f, "trading", 5013);
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"to\":\"nowhere\",\"text\":\"lost words\"}"));
    try f.e.script(2, model.textReply("ok"));
    f.core.chatTurn("post it");
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "refused: there is no conversation called nowhere; they are: main, trading") != null);
    try t.expectEqual(0, f.rec.count("lost words"));
    // every send is logged, a refused one too
    const sends = try sendLines(&f);
    try t.expect(std.mem.indexOf(u8, sends[0], "\"to\":\"nowhere\",\"event\":\"refused\"") != null);
}

test "send_to_a_shared_conversation_asks_every_time_without_24h_and_is_denied_unattended" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try addGroup(&f, "family", -1001234567890);
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"to\":\"family\",\"text\":\"Dinner at 7.\"}"));
    try f.e.script(2, model.toolReply("tu_2", "send", "{\"to\":\"family\",\"text\":\"Bring salad.\"}"));
    try f.e.script(3, model.textReply("asked twice"));
    try f.core.startWorker();
    try f.core.handleText("tell the family");
    // the whole post is shown, in main, with no Allow 24 h
    try f.rec.waitIn("main", "BUTTONS Allow this?\nsend: family, 12 bytes:\nDinner at 7.");
    try t.expect(f.lastButtons().get("day") == null);
    try f.press("once");
    try f.rec.waitIn("family", "Dinner at 7.");
    // asked again: an answer covers one post
    try f.rec.waitIn("main", "BUTTONS Allow this?\nsend: family, 12 bytes:\nBring salad.");
    try t.expect(f.lastButtons().get("day") == null);
    try f.press("deny");
    try f.rec.waitFor("asked twice");
    try t.expectEqual(0, f.rec.countIn("family", "Bring salad."));
    try t.expectEqual(0, f.core.grants.items.items.len);
    // a run nobody watches is refused, and says what it skipped
    var flag: std.atomic.Value(bool) = .init(false);
    var run = f.core.runIn(&f.core.chat_client, "task fam", .{ .by = "schedule:fam" }, "main", &flag);
    var out: Core.RunOut = .{ .core = f.core, .tag = "[fam] " };
    run.outbox = out.outbox();
    var skipped: agent.Skipped = .init(t.allocator);
    defer skipped.deinit();
    run.skipped = &skipped;
    var conv: agent.Conversation = .init(t.allocator);
    defer conv.deinit();
    try f.e.script(4, model.toolReply("tu_3", "send", "{\"to\":\"family\",\"text\":\"Unasked.\"}"));
    try f.e.script(5, model.textReply("NOTHING"));
    const res = try agent.turn(&run, &conv, "Tell the family.", false);
    defer agent.freeResult(&run, res);
    try t.expect(std.mem.indexOf(u8, try f.e.request(5), "refused by the gate: no one to ask in a scheduled run") != null);
    try t.expect(std.mem.indexOf(u8, try skipped.text(t.io, f.e.arena.allocator()), "send: family") != null);
    try t.expectEqual(0, f.rec.count("Unasked."));
}

test "the_11th_send_of_a_run_is_refused" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    var blocks: std.ArrayList(u8) = .empty;
    for (1..12) |i| try blocks.print(a, "{s}{{\"type\":\"tool_use\",\"id\":\"tu_{d}\",\"name\":\"send\",\"input\":{{\"text\":\"note-{d:0>2}\"}}}}", .{ if (i > 1) "," else "", i, i });
    try f.e.script(1, try replyOf(&f, blocks.items, "tool_use"));
    try f.e.script(2, model.textReply("done"));
    f.core.chatTurn("post a lot");
    try t.expectEqual(10, f.rec.count("note-"));
    try t.expectEqual(0, f.rec.count("note-11"));
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "refused: this run has posted 10 times, the most one run may (sends_per_run)") != null);
}

test "posts_over_the_hourly_limit_are_not_sent_and_main_is_told_once" {
    var f: Fix = undefined;
    try f.init("[limits]\nsends_per_hour = 2\n", "", "");
    defer f.deinit();
    try addTopic(&f, "trading", 5013);
    const a = f.e.arena.allocator();
    var blocks: std.ArrayList(u8) = .empty;
    for (1..5) |i| try blocks.print(a, "{s}{{\"type\":\"tool_use\",\"id\":\"tu_{d}\",\"name\":\"send\",\"input\":{{\"to\":\"trading\",\"text\":\"tick-{d}\"}}}}", .{ if (i > 1) "," else "", i, i });
    try f.e.script(1, try replyOf(&f, blocks.items, "tool_use"));
    try f.e.script(2, model.textReply("done"));
    f.core.chatTurn("watch the market");
    try t.expectEqual(2, f.rec.countIn("trading", "tick-"));
    try t.expectEqual(1, f.rec.countIn("main", "Posts to trading are over 2 an hour: 1 not sent. /session shows them."));
    try t.expectEqual(1, f.rec.count("are over 2 an hour"));
    const sends = try sendLines(&f);
    try t.expectEqual(5, sends.len);
    for (sends[2..4]) |l| {
        try t.expect(std.mem.indexOf(u8, l, "\"event\":\"held\"") != null);
        try t.expect(std.mem.indexOf(u8, l, "\"delivered\":false") != null);
    }
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "not sent: posts to trading are over 2 an hour") != null);
}

test "private_is_per_conversation_and_covers_sends_into_it" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try addTopic(&f, "diary", 5014);
    try f.core.handleTextIn("diary", "/private on");
    try f.rec.waitIn("diary", "Private here");
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"to\":\"diary\",\"text\":\"secret-entry-words\"}"));
    try f.e.script(2, model.textReply("noted in your diary"));
    f.core.chatTurn("write in my diary");
    try f.e.script(3, model.textReply("a private reply"));
    f.core.chatTurnIn("diary", "my private thoughts xyzzy");
    const lt = try logText(&f);
    // main is not private: its turn reads; a post into the diary does not
    try t.expect(std.mem.indexOf(u8, lt, "\"text\":\"write in my diary\"") != null);
    try t.expect(std.mem.indexOf(u8, lt, "\"text\":\"noted in your diary\"") != null);
    try t.expect(std.mem.indexOf(u8, lt, "secret-entry-words") == null);
    try t.expect(std.mem.indexOf(u8, lt, "\"to\":\"diary\",\"event\":\"sent\"") != null);
    // the diary's own turn is private, its reply too
    try t.expect(std.mem.indexOf(u8, lt, "xyzzy") == null);
    try t.expect(std.mem.indexOf(u8, lt, "a private reply") == null);
    try t.expectEqual(1, f.core.contextOf("main").?.turns_since_memory);
    try t.expectEqual(0, f.core.contextOf("diary").?.turns_since_memory);
    try t.expect(std.mem.indexOf(u8, try conversationsText(&f), "\"name\":\"diary\",\"channel\":\"telegram\",\"chat\":42,\"thread\":5014,\"audience\":\"own\",\"private\":true") != null);
}

test "an_attachment_outside_the_workspace_or_holding_a_stored_secret_is_refused" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const ws = f.core.workspace;
    const a = f.e.arena.allocator();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ ws, "flats.csv" }), .data = "street,rooms\n" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ ws, "leak.txt" }), .data = "the key is og-key-for-tests\n" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ ws, ".env" }), .data = "A=1\n" });
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"text\":\"the settings\",\"files\":[\"../config.ini\"]}"));
    try f.e.script(2, model.toolReply("tu_2", "send", "{\"text\":\"a leak\",\"files\":[\"leak.txt\"]}"));
    try f.e.script(3, model.toolReply("tu_3", "send", "{\"text\":\"env\",\"files\":[\".env\"]}"));
    try f.e.script(4, model.toolReply("tu_4", "send", "{\"text\":\"Here is the list.\",\"files\":[\"flats.csv\"],\"final\":true}"));
    try f.core.startWorker();
    try f.core.handleText("send me the files");
    // a name starting with "." is asked, as write_file is
    try f.rec.waitFor("BUTTONS Allow this?\nsend: main, 3 bytes:\nenv\nfiles: .env");
    try f.press("deny");
    try f.rec.waitFor("DOC flats.csv (13 bytes)");
    try f.rec.waitIn("main", "Here is the list.");
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), "refused: ../config.ini is outside the workspace") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(3), "refused: leak.txt holds a stored secret (omnigate)") != null);
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "refused by the gate: denied by the owner") != null);
    try t.expectEqual(0, f.rec.count("a leak"));
    try t.expectEqual(0, f.rec.count("the settings"));
    try t.expect(std.mem.indexOf(u8, try logText(&f), "og-key-for-tests") == null);
    const sends = try sendLines(&f);
    try t.expect(std.mem.indexOf(u8, sends[sends.len - 1], "\"files\":\"flats.csv\"") != null);
}

test "a_refused_topic_posts_to_main_with_its_name_in_front" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try addTopic(&f, "trading", 5013);
    f.rec.threads_fail = true;
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"to\":\"trading\",\"text\":\"BTC is up.\"}"));
    try f.e.script(2, model.toolReply("tu_2", "send", "{\"to\":\"trading\",\"text\":\"ETH too.\"}"));
    try f.e.script(3, model.textReply("ok"));
    f.core.chatTurn("tell trading");
    try t.expectEqual(1, f.rec.countIn("main", "[trading] BTC is up."));
    try t.expectEqual(1, f.rec.countIn("main", "[trading] ETH too."));
    try t.expectEqual(1, f.rec.count("Telegram refused the topic of trading"));
}

test "a_task_posts_to_its_conversation_with_its_name_in_front" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\nto = house-search\ndo = Check the flats.\n");
    defer f.deinit();
    const a = f.e.arena.allocator();
    // house-search is no conversation yet: its topic opens at the first post
    try f.e.script(1, model.textReply("Two new flats."));
    f.core.tick();
    try f.rec.waitIn("house-search", "[check] Two new flats.");
    try t.expectEqual(5001, f.rec.whereOf("[check] Two new flats.").?.thread);
    waitIdle(f.core);
    try t.expect(std.mem.indexOf(u8, try conversationsText(&f), "\"name\":\"house-search\",\"channel\":\"telegram\",\"chat\":42,\"thread\":5001") != null);
    try t.expectEqual(0, f.rec.countIn("main", "Two new flats."));
    // the task could post with send too; its run is logged in its conversation
    try t.expect(std.mem.indexOf(u8, try f.e.request(1), "\"name\":\"send\"") != null);
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"conversation\":\"house-search\",\"run\":\"task check\",\"by\":\"schedule:check\"") != null);
    // a brief with `to` posts there the same way
    try addTopic(&f, "news", 5020);
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/z.xml", .data = "<rss><channel><item><title>New thing</title><link>https://z.org/1</link></item></channel></rss>" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.briefs, .data = try std.fmt.allocPrint(a, "[morning]\nat = 00:00\nto = news\ntopic = Zig | {s}/page/z.xml\n", .{try f.e.url()}) });
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    try f.e.script(2, model.textReply("Zig: New thing (https://z.org/1)"));
    f.core.tick();
    try f.rec.waitIn("news", "[morning] Zig: New thing (https://z.org/1)");
    waitIdle(f.core);
    try t.expect(f.core.seen.has("https://z.org/1"));
    try t.expectEqual(0, f.rec.countIn("main", "New thing"));
}

test "a_task_whose_topic_can_not_open_posts_to_main_with_its_name" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\nto = flats\ndo = Check the flats.\n");
    defer f.deinit();
    f.rec.topics_fail = true;
    try f.e.script(1, model.textReply("Nothing new on the market."));
    f.core.tick();
    try f.rec.waitIn("main", "[flats] [check] Nothing new on the market.");
    waitIdle(f.core);
    try t.expectEqual(1, f.rec.count("could not be opened"));
}

test "a_quick_reply_counts_once_and_not_after_a_restart" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "send", "{\"text\":\"Three flats match.\",\"buttons\":[\"Book viewings\",\"Not now\"],\"final\":true}"));
    try f.e.script(2, model.textReply("Booking them."));
    try f.core.startWorker();
    try f.core.handleText("find flats");
    try f.rec.waitFor("BUTTONS Three flats match. [r");
    const b = f.lastButtons();
    try t.expectEqual(2, b.n);
    // the label is the owner's message there, in a turn that names the post
    f.core.handleCallback(42, b.msg, b.get("1").?);
    try f.rec.waitFor("Booking them.");
    const req2 = try f.e.request(2);
    try t.expect(std.mem.indexOf(u8, req2, "{\"type\":\"text\",\"text\":\"Book viewings\"") != null);
    try t.expect(std.mem.indexOf(u8, req2, "The owner pressed \\\"Book viewings\\\" under your post: \\\"Three flats match.\\\"") != null);
    {
        f.rec.mutex.lockUncancelable(t.io);
        defer f.rec.mutex.unlock(t.io);
        try t.expect(std.mem.indexOfScalar(i64, f.rec.cleared.items, b.msg) != null);
    }
    // counted once: the other button answers nothing now
    f.core.handleCallback(42, b.msg, b.get("2").?);
    try f.rec.waitFor(out_of_date);
    // from another message, nothing either
    try restart(&f);
    f.core.handleCallback(42, b.msg, b.get("1").?);
    try t.expectEqual(2, f.rec.count(out_of_date));
    try t.expectEqual(2, f.e.server.modelRequests());
    // quick replies only where only the owner reads
    try addGroup(&f, "family", -1001234567890);
    try f.e.script(3, model.toolReply("tu_2", "send", "{\"to\":\"family\",\"text\":\"Pick one\",\"buttons\":[\"A\"]}"));
    try f.e.script(4, model.textReply("ok"));
    f.core.chatTurn("ask the family");
    try t.expect(std.mem.indexOf(u8, try f.e.request(4), "refused: quick replies are only for conversations only you read") != null);
}

test "a_bad_rules_line_names_its_section_or_environment" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const section = (try parseProblem(a, "rules", "allow shell ls\n[agnet:coder]\nallow shell make\n", rules.parse)).?;
    try t.expect(std.mem.startsWith(u8, section, "rules line 2 has an error: [agnet:coder] (a section is [all] or a who"));
    const env = (try parseProblem(a, "rules", "allow fetch@box https://a.com/*\n", rules.parse)).?;
    try t.expect(std.mem.startsWith(u8, env, "rules line 1 has an error: allow fetch@box https://a.com/* (only shell takes an environment"));
}

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

const not_sent = "the question could not be sent to the owner";

test "a_question_with_a_part_that_did_not_arrive_is_refused_without_buttons" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    const a = f.e.arena.allocator();
    const ys = try a.alloc(u8, 6000);
    @memset(ys, 'y');
    try f.e.script(1, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"shell\",\"input\":{{\"command\":\"echo {s} end-of-it\"}}}}],\"stop_reason\":\"tool_use\"}}", .{ys}));
    try f.e.script(2, model.textReply("not run"));
    // the first part does not get through: no buttons go under the rest
    f.rec.setFail(error.ConnectionClosed);
    try f.core.startWorker();
    try f.core.handleText("run the long one");
    try waitFile(&f.e, "requests/002.json");
    try t.expectEqual(0, f.rec.count("BUTTONS"));
    try t.expect(!f.core.approvalWaiting());
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), not_sent) != null);
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"decision\":\"deny\",\"why\":\"" ++ not_sent ++ "\"") != null);
}

test "a_question_whose_buttons_could_not_be_sent_is_refused_at_once" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"echo unasked\"}"));
    try f.e.script(2, model.textReply("not run"));
    f.rec.buttons_fail = true;
    try f.core.startWorker();
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    try f.core.handleText("run it");
    // not approval_seconds (10 minutes) of waiting for an answer that can't come
    try f.rec.waitFor("not run");
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - start < 3 * std.time.ns_per_s);
    try t.expectEqual(0, f.rec.count("BUTTONS"));
    try f.rec.waitFor("The question could not be sent, so the call is not allowed.");
    try t.expect(std.mem.indexOf(u8, try f.e.request(2), not_sent) != null);
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

/// How many page and feed requests the stand-in has answered.
fn pageRequests(f: *Fix) usize {
    const text = f.e.tmp.dir.readFileAlloc(t.io, "page-requests.jsonl", f.e.arena.allocator(), .unlimited) catch return 0;
    return std.mem.count(u8, text, "\n");
}

test "an_undelivered_brief_is_sent_again_as_written_and_marked_seen_once_it_arrives" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try dueBrief(&f, "<item><title>New thing</title><link>https://z.org/1</link></item>");
    try f.e.script(1, model.textReply("Zig: New thing (https://z.org/1)"));
    f.rec.setFail(error.ConnectionClosed);
    f.core.tick();
    waitIdle(f.core);
    try t.expectEqual(1, f.e.server.modelRequests());
    const fetched = pageRequests(&f);
    try t.expect(fetched > 0);
    try t.expect(!f.core.seen.has("https://z.org/1"));
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"event\":\"not delivered\"") != null);
    // not again at once
    f.core.tick();
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    waitIdle(f.core);
    try t.expectEqual(1, f.e.server.modelRequests());
    // a while later the brief as it was written is sent: nothing is
    // fetched or written again
    f.rec.setFail(null);
    try f.e.script(2, model.textReply("Zig: New thing, written again (https://z.org/1)"));
    f.core.fixed_now = util.nowSeconds(t.io) + 15 * 60;
    f.core.tick();
    try f.rec.waitFor("Zig: New thing (https://z.org/1)");
    waitIdle(f.core);
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqual(fetched, pageRequests(&f));
    try t.expect(f.core.seen.has("https://z.org/1"));
    // it counts for the day it was due: not collected again today
    f.core.tick();
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    waitIdle(f.core);
    try t.expectEqual(1, f.e.server.modelRequests());
    try t.expectEqual(1, f.rec.count("New thing"));
}

test "an_undelivered_task_answer_is_sent_again_without_running_the_task_again" {
    var f: Fix = undefined;
    try f.init("", "", "[check]\nevery = 5m\ndo = Check the price.\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"prices.txt\",\"content\":\"up 4%\"}"));
    try f.e.script(2, model.textReply("Price moved 4%."));
    try f.e.script(3, model.toolReply("tu_2", "write_file", "{\"path\":\"prices.txt\",\"content\":\"run again\"}"));
    try f.e.script(4, model.textReply("Price moved again."));
    const t0 = util.nowSeconds(t.io);
    f.rec.setFail(error.ConnectionClosed);
    f.core.tick();
    waitIdle(f.core);
    try t.expectEqual(2, f.e.server.modelRequests());
    // after 5 minutes it is sent again; it fails again, so the next try
    // waits 10 minutes
    f.core.fixed_now = t0 + 6 * 60;
    f.core.tick();
    waitIdle(f.core);
    try t.expect(std.mem.indexOf(u8, try logText(&f), "\"name\":\"check\",\"event\":\"not delivered\",\"why\":\"ConnectionClosed\",\"tries\":2") != null);
    f.rec.setFail(null);
    f.core.fixed_now = t0 + 12 * 60;
    f.core.tick();
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    waitIdle(f.core);
    try t.expectEqual(0, f.rec.count("[check]"));
    // Telegram is back: once the wait is over the answer is sent as it
    // was written, and the task's tools do not run a second time
    f.core.fixed_now = t0 + 17 * 60;
    f.core.tick();
    try f.rec.waitFor("[check] Price moved 4%.");
    waitIdle(f.core);
    try t.expectEqual(2, f.e.server.modelRequests());
    const lt = try logText(&f);
    try t.expectEqual(1, std.mem.count(u8, lt, "\"tool\":\"write_file\",\"arg\""));
    try t.expect(std.mem.indexOf(u8, lt, "\"event\":\"sent\",\"tries\":3") != null);
    try t.expectEqual(0, f.rec.count("again"));
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

test "after_the_agent_writes_a_file_a_command_a_rule_allows_is_asked_once" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell echo *\n" });
    _ = try f.core.reload();
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"pkg/__init__.py\",\"content\":\"import os\"}"));
    try f.e.script(2, model.textReply("written"));
    try f.core.startWorker();
    try f.core.handleText("write the package");
    try f.rec.waitFor("written");
    // a later turn, after a restart even: the rule would let the command
    // run, but what the agent wrote could change what it does
    try restart(&f);
    try f.e.script(3, model.toolReply("tu_2", "shell", "{\"command\":\"echo run-it\"}"));
    try f.e.script(4, model.textReply("ran it"));
    try f.e.script(5, model.toolReply("tu_3", "shell", "{\"command\":\"echo run-it-again\"}"));
    try f.e.script(6, model.textReply("and again"));
    try f.core.startWorker();
    try f.core.handleText("run it");
    try f.rec.waitFor("BUTTONS Allow this?\nshell: echo run-it\nFiles the agent wrote in the workspace since you last allowed a command: pkg/__init__.py [");
    try f.press("once");
    try f.rec.waitFor("ran it");
    // allowed once: the next one the rule allows runs unasked
    try f.core.handleText("again");
    try f.rec.waitFor("and again");
    try t.expectEqual(1, f.rec.count("BUTTONS"));
}

test "chat_turns_are_started_by_the_owner_and_tasks_by_their_schedule" {
    var f: Fix = undefined;
    try f.init("", "", "[disk]\nevery = 5m\ndo = Check the disk.\n");
    defer f.deinit();
    try f.e.script(1, model.toolReply("tu_1", "shell", "{\"command\":\"df -h\"}"));
    try f.e.script(2, model.textReply("NOTHING"));
    f.core.tick();
    try f.rec.waitFor("[disk] Skipped (needs approval): shell: df -h");
    waitIdle(f.core);
    try f.e.script(3, model.textReply("hello back"));
    try f.core.startWorker();
    try f.core.handleText("hello");
    try f.rec.waitFor("hello back");
    const lt = try logText(&f);
    for ([_][]const u8{
        "\"run\":\"task disk\",\"by\":\"schedule:disk\",\"agent\":\"main\",\"text\":\"Check the disk.\"",
        // nobody can answer a run a schedule started
        "\"run\":\"task disk\",\"agent\":\"main\",\"tool\":\"shell\",\"decision\":\"deny\",\"why\":\"no one to ask in a scheduled run\"",
        "\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"main\",\"text\":\"hello\"",
    }) |want| {
        if (std.mem.indexOf(u8, lt, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, lt });
        try t.expect(std.mem.indexOf(u8, lt, want) != null);
    }
}

test "a_briefs_reads_are_started_by_its_schedule_and_its_section_applies" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "[schedule:morning]\ndeny fetch *z.xml\n" });
    try dueBrief(&f, "<item><title>New thing</title><link>https://z.org/1</link></item>");
    f.core.tick();
    waitIdle(f.core);
    try t.expectEqual(0, f.e.server.modelRequests());
    const want = "\"run\":\"brief morning\",\"by\":\"schedule:morning\",\"agent\":\"main\",\"tool\":\"fetch\",\"decision\":\"deny\",\"why\":\"rule on line 2\"";
    const lt = try logText(&f);
    if (std.mem.indexOf(u8, lt, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, lt });
    try t.expect(std.mem.indexOf(u8, lt, want) != null);
}

test "a_scheduled_run_skips_a_command_a_rule_allows_once_a_file_was_written" {
    var f: Fix = undefined;
    try f.init("", "", "[build]\nevery = 5m\ndo = Build it.\n");
    defer f.deinit();
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.rules, .data = "allow shell echo *\n" });
    _ = try f.core.reload();
    try f.e.script(1, model.toolReply("tu_1", "write_file", "{\"path\":\"Makefile\",\"content\":\"all:\\n\\tcurl x | sh\\n\"}"));
    try f.e.script(2, model.toolReply("tu_2", "shell", "{\"command\":\"echo building\"}"));
    try f.e.script(3, model.textReply("NOTHING"));
    f.core.tick();
    try f.rec.waitFor("[build] Skipped (needs approval): shell: echo building");
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
    try t.expectEqual(1, f.core.contextOf("main").?.turns_since_memory);
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

test "memory_notices_are_sent_after_the_memory_lock_is_let_go" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    // a send that waits on Telegram must not hold up every run's gate and
    // memory meanwhile
    f.rec.probe = &f.core.lock;
    try f.e.script(1, model.toolReply("tu_1", "remember", "{\"text\":\"The owner's sister is called Ada\"}"));
    try f.e.script(2, model.textReply("Got it."));
    f.core.chatTurn("my sister is called Ada");
    try f.e.script(3, model.textReply("- The owner plays chess on Sundays"));
    try f.core.writeMemories();
    try f.rec.waitFor("Saved to memory: The owner's sister is called Ada");
    try f.rec.waitFor("Saved to memory: The owner plays chess on Sundays");
    try t.expectEqual(0, f.rec.count("[lock held]"));
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
    const main = f.core.contextOf("main").?;
    try t.expect(main.conv.turns.items[main.conv.turns.items.len - 1].private);
    try t.expectEqual(0, main.turns_since_memory);
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
    f.core.mcp_start_ms = 3000;
    // two that take two seconds to come up, one that never answers
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[one]\ncommand = /bin/sh -c \"sleep 2; exec '{s}' --mcp\"\n[two]\ncommand = /bin/sh -c \"sleep 2; exec '{s}' --mcp\"\n[mute]\ncommand = /bin/sh -c \"exec sleep 30\"\n", .{ fake, fake }) });
    const t0 = Io.Clock.awake.now(t.io).nanoseconds;
    try t.expectEqualStrings("Settings reloaded.", try f.core.reload());
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - t0, std.time.ns_per_ms);
    // together: both two-second servers are up by the 3 s deadline (one
    // after another, the second would be cut at it), and the one that
    // never answers costs the deadline, no more: spawning counts against
    // it and a server that never started is ended at once (on a slow CI
    // runner both used to add over 3 s)
    if (took_ms >= 4000) std.debug.print("reload took {d} ms; notes:\n{s}\n", .{ took_ms, f.core.mcp_note });
    try t.expect(took_ms < 4000);
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
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f.core.paths.mcp, .data = try std.fmt.allocPrint(a, "[slow]\ncommand = /bin/sh -c \"sleep 8; exec '{s}' --mcp\"\n", .{fake}) });
    const t0 = Io.Clock.awake.now(t.io).nanoseconds;
    const th = try std.Thread.spawn(.{}, reloadQuietly, .{f.core});
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    // /stop and the scheduler's tick do not wait for the start (8 s)
    _ = f.core.stopAll();
    f.core.last_status_s = 0;
    f.core.tick();
    const t1 = Io.Clock.awake.now(t.io).nanoseconds - t0;
    if (t1 >= 1500 * std.time.ns_per_ms) std.debug.print("stop and tick took {d} ms\n", .{@divFloor(t1, std.time.ns_per_ms)});
    try t.expect(t1 < 1500 * std.time.ns_per_ms);
    th.join();
    // and the stop ended the start instead of waiting it out (8 s): a
    // server that never started is ended at once
    const t2 = Io.Clock.awake.now(t.io).nanoseconds - t0;
    if (t2 >= 2800 * std.time.ns_per_ms) std.debug.print("reload ended after {d} ms\n", .{@divFloor(t2, std.time.ns_per_ms)});
    try t.expect(t2 < 2800 * std.time.ns_per_ms);
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

/// Holds the first masksChanged between taking the list and setting it,
/// until `go`, so a second value can be added meanwhile.
const MaskRace = struct {
    var held: std.atomic.Value(bool) = .init(false);
    var go: std.atomic.Value(bool) = .init(false);
    var first: std.atomic.Value(bool) = .init(true);

    fn pause(_: *Core) void {
        if (!first.swap(false, .acq_rel)) return;
        held.store(true, .release);
        while (!go.load(.acquire)) t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }

    fn add(c: *Core, name: []const u8, value: []const u8) void {
        c.masks.add(name, value) catch {};
    }
};

test "two_values_added_at_once_are_both_masked_in_the_log_and_memory" {
    var f: Fix = undefined;
    try f.init("", "", "");
    defer f.deinit();
    f.core.mask_pause = MaskRace.pause;
    // one sign-up's password is added and its list taken, then held there
    const one = try std.Thread.spawn(.{}, MaskRace.add, .{ f.core, "login-one-password", "made-at-signup-One-1111" });
    var waited: u32 = 0;
    while (!MaskRace.held.load(.acquire) and waited < 5000) : (waited += 5) t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    try t.expect(MaskRace.held.load(.acquire));
    // another's is added meanwhile
    const two = try std.Thread.spawn(.{}, MaskRace.add, .{ f.core, "login-two-password", "made-at-signup-Two-2222" });
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    MaskRace.go.store(true, .release);
    one.join();
    two.join();
    f.core.mask_pause = null;
    // the log and memory end with the list that has both
    try f.core.log.write(.config, false, .{ .event = "probe", .detail = "made-at-signup-One-1111 and made-at-signup-Two-2222" });
    const lt = try logText(&f);
    try t.expect(std.mem.indexOf(u8, lt, "made-at-signup-Two-2222") == null);
    try t.expect(std.mem.indexOf(u8, lt, "made-at-signup-One-1111") == null);
    {
        f.core.lock.lockUncancelable(t.io);
        defer f.core.lock.unlock(t.io);
        _ = try f.core.mem.add("The passwords are made-at-signup-One-1111 and made-at-signup-Two-2222", null, f.core.now());
    }
    for (f.core.mem.items.items) |it| try t.expect(std.mem.indexOf(u8, it.body, "made-at-signup-Two-2222") == null);
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
