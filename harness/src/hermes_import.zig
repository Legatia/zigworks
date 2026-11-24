//! `harness import hermes`: what of a Hermes setup maps onto harness, as a
//! plan the owner reads first (Will import, Needs you, Not imported); then
//! the harness files it changes, copied beforehand, written whole, and a
//! report. An import narrows what harness may do, never widens it: deny
//! patterns come in as deny rules, "always" approvals only as commented
//! suggestions, and no key or token is ever copied: each one is a
//! `harness secret add NAME` line for the owner to run.
const std = @import("std");
const builtin = @import("builtin");
const hermes = @import("hermes.zig");
const config = @import("config.zig");
const triggers = @import("triggers.zig");
const mcp = @import("mcp.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const skills = @import("skills.zig");
const skillsrc = @import("skillsrc.zig");
const zones = @import("zones.zig");
const scrub = @import("scrub.zig");
const util = @import("util.zig");
const model = @import("model.zig");
const Io = std.Io;

pub const Group = enum { will, needs, not };
pub const Line = struct { group: Group, text: []const u8 };

pub const NewMemory = struct { body: []const u8, pinned: bool = false, from: []const u8 };
pub const NewSkill = struct {
    name: []const u8,
    /// Where it was in Hermes (under skills/).
    rel: []const u8,
    files: []const skillsrc.File,
    hash: [64]u8,
    /// `skills/.sources`'s source: `OWNER/REPO/PATH` for a GitHub hub
    /// install, else `hermes` (nothing to update from).
    source: []const u8,
};
pub const TaskFile = struct { name: []const u8, text: []const u8 };
pub const SecretLine = struct { name: []const u8, where: []const u8 };

pub const Plan = struct {
    lines: std.ArrayList(Line) = .empty,
    memory: std.ArrayList(NewMemory) = .empty,
    /// When every new memory item's one mention is: 60 days before the import.
    mention_s: i64 = 0,
    skills: std.ArrayList(NewSkill) = .empty,
    /// Appended to tasks.ini ("" for nothing).
    tasks: std.ArrayList(u8) = .empty,
    task_names: std.ArrayList([]const u8) = .empty,
    task_files: std.ArrayList(TaskFile) = .empty,
    mcp: std.ArrayList(u8) = .empty,
    server_names: std.ArrayList([]const u8) = .empty,
    rules: std.ArrayList(u8) = .empty,
    rule_count: usize = 0,
    task_count: usize = 0,
    task_commented: usize = 0,
    server_count: usize = 0,
    server_commented: usize = 0,
    provider_count: usize = 0,
    model_set: bool = false,
    /// state/imports/hermes-TIME/rules.suggested ("" for none).
    suggested: std.ArrayList(u8) = .empty,
    /// config.ini as it will be, when it changes.
    config_ini: ?[]const u8 = null,
    secrets: std.ArrayList(SecretLine) = .empty,

    pub fn has(p: *const Plan, group: Group, needle: []const u8) bool {
        for (p.lines.items) |l| if (l.group == group and std.mem.indexOf(u8, l.text, needle) != null) return true;
        return false;
    }
};

/// A skill installed in harness: its name and its hash now.
pub const Installed = struct { name: []const u8, hash: []const u8 };

/// harness's side, as it is before the import.
pub const Harness = struct {
    config_text: []const u8 = "",
    tasks_text: []const u8 = "",
    triggers_text: []const u8 = "",
    briefs_text: []const u8 = "",
    mcp_text: []const u8 = "",
    rules_text: []const u8 = "",
    /// tasks.ini's tasks, their do_file read.
    tasks: []const config.Task = &.{},
    memory: ?*memory.Store = null,
    skills: []const Installed = &.{},
    /// harness's stored secrets: masked too.
    stored: []const scrub.Secret = &.{},
};

pub const Opts = struct {
    now_s: i64,
    zone_dirs: []const []const u8 = &zones.default_dirs,
    /// `--bundled`: Hermes's own skills come over too.
    bundled: bool = false,
    /// The TZ environment variable, for a Hermes home with no timezone.
    local_zone: []const u8 = "",
    /// Where this import's copies, suggestions and report go (as the plan names it).
    import_dir: []const u8 = "state/imports/hermes-TIME",
};

/// Imported memory is dated this many days back.
pub const back_days = 60;

/// A memory item is at most this long; a longer entry is split.
const memory_cap = 2000;

/// Makes the plan: what of `s` maps onto harness as `h` is now. Reads
/// the skills' files; writes nothing.
pub fn makePlan(io: Io, a: std.mem.Allocator, s: hermes.Setup, h: Harness, o: Opts) !Plan {
    var p: Plan = .{ .mention_s = o.now_s - back_days * 86400 };
    var all: std.ArrayList(scrub.Secret) = .empty;
    try all.appendSlice(a, s.secrets);
    try all.appendSlice(a, h.stored);
    const cfg = config.parse(a, h.config_text) catch config.Config{};
    var c: Ctx = .{ .io = io, .a = a, .s = s, .h = h, .o = o, .p = &p, .sc = try scrub.Scrubber.init(a, all.items), .cfg = cfg };
    try c.planMemory();
    try c.planSoul();
    try c.planSkills();
    try c.planJobs();
    try c.planServers();
    try c.planRules();
    try c.planAllowlist();
    try c.planModel();
    try c.planTelegram();
    try c.planRest();
    for (p.secrets.items) |sl| try c.line(.needs, "harness secret add {s}    ({s})", .{ sl.name, sl.where });
    return p;
}

const Ctx = struct {
    io: Io,
    a: std.mem.Allocator,
    s: hermes.Setup,
    h: Harness,
    o: Opts,
    p: *Plan,
    sc: scrub.Scrubber,
    cfg: config.Config,
    /// .env names a part that comes over uses.
    used_env: std.StringHashMapUnmanaged(void) = .empty,
    /// Each secret name given, and what it holds (`env:VAR`, a config path).
    secret_ids: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Hermes's skill names → harness's, for the jobs' "Use the skills" lines.
    skill_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The MCP servers' excluded tools, as deny lines.
    mcp_denies: std.ArrayList([]const u8) = .empty,
    every_note: bool = false,
    at_note: bool = false,
    tasks_any: bool = false,

    fn line(c: *Ctx, g: Group, comptime fmt: []const u8, args: anytype) !void {
        try c.p.lines.append(c.a, .{ .group = g, .text = try c.mask(try std.fmt.allocPrint(c.a, fmt, args)) });
    }

    /// `text` with every Hermes and harness secret value masked.
    fn mask(c: *Ctx, text: []const u8) ![]const u8 {
        return c.sc.scrubAlloc(c.a, text);
    }

    /// A text on one line, cut at 160 bytes.
    fn shown(c: *Ctx, text: []const u8) ![]const u8 {
        const one = try std.mem.replaceOwned(u8, c.a, text, "\n", " ");
        const cut = util.cut(one, 160);
        return if (cut.len < one.len) std.fmt.allocPrint(c.a, "{s}…", .{cut}) else cut;
    }

    // ---- memory and SOUL.md ----

    fn planMemory(c: *Ctx) !void {
        for (c.s.memory) |e| {
            const from = if (e.file == .memory) "MEMORY.md" else "USER.md";
            for (try splitParts(c.a, try c.mask(e.text), memory_cap)) |part| {
                if (c.h.memory) |store| if (try store.repeatOf(c.a, part)) |it| {
                    try c.line(.not, "memory: {s} ({s}): already in memory as {s}", .{ try c.shown(part), from, it.id });
                    continue;
                };
                try c.p.memory.append(c.a, .{ .body = part, .from = from });
                try c.line(.will, "memory: {s} ({s})", .{ try c.shown(part), from });
            }
        }
    }

    fn planSoul(c: *Ctx) !void {
        const raw = c.s.soul orelse return;
        const norm = try std.mem.replaceOwned(u8, c.a, raw, "\r\n", "\n");
        const text = std.mem.trim(u8, std.mem.trimStart(u8, norm, "\xEF\xBB\xBF"), " \t\r\n");
        if (text.len == 0) return;
        if (hermes.isStockSoul(raw)) return c.line(.not, "SOUL.md: Hermes's own text, never edited", .{});
        const body = try c.mask(try std.fmt.allocPrint(c.a, "How to talk with me: {s}", .{text}));
        if (body.len > memory_cap)
            return c.line(.not, "SOUL.md: {s} bytes, over memory's 2,000: to keep it, make it agents/main.md by hand (that file replaces harness's built-in instructions)", .{try thousands(c.a, text.len)});
        if (c.h.memory) |store| if (try store.repeatOf(c.a, body)) |it| return c.line(.not, "SOUL.md: already in memory as {s}", .{it.id});
        try c.p.memory.append(c.a, .{ .body = body, .pinned = true, .from = "SOUL.md" });
        try c.line(.will, "memory, pinned: {s} (SOUL.md)", .{try c.shown(body)});
    }

    // ---- skills ----

    fn planSkills(c: *Ctx) !void {
        var bundled: std.ArrayList([]const u8) = .empty;
        var planned: std.StringHashMapUnmanaged(void) = .empty;
        for (c.s.skills) |sk| {
            if (sk.bundled) |b| if (!b.edited and !c.o.bundled) {
                try bundled.append(c.a, sk.name);
                continue;
            };
            if (sk.disabled) {
                try c.line(.not, "skill {s} ({s}): disabled in Hermes; harness has no off switch for a skill", .{ sk.name, sk.rel });
                continue;
            }
            const name = harnessName(c.a, sk.name) orelse {
                try c.line(.not, "skill {s} ({s}): its name can't be made a harness name (a-z, 0-9 and single -, up to 64)", .{ sk.name, sk.rel });
                continue;
            };
            if (try c.skillTooBig(sk, name)) continue;
            var files: std.ArrayList(skillsrc.File) = .empty;
            for (sk.files) |fi| {
                const path = try std.fs.path.join(c.a, &.{ sk.folder, fi.rel });
                const data = Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(skills.max_file + 1)) catch |e| {
                    try c.line(.not, "skill {s} ({s}): {s} can't be read ({s})", .{ name, sk.rel, fi.rel, @errorName(e) });
                    break;
                };
                try files.append(c.a, .{ .rel = fi.rel, .data = data, .exec = fi.exec });
            } else {
                try c.planSkill(sk, name, files.items, &planned);
            }
        }
        if (bundled.items.len > 0)
            try c.line(.not, "Hermes's own skills, never edited ({d}): {s} (harness import hermes --bundled brings them)", .{ bundled.items.len, try std.mem.join(c.a, ", ", bundled.items) });
    }

    /// Whether a skill is over harness's limits (said in the plan with its sizes).
    fn skillTooBig(c: *Ctx, sk: hermes.SkillDir, name: []const u8) !bool {
        for (sk.files) |f| if (f.link) {
            try c.line(.not, "skill {s} ({s}): {s} is a link; harness copies none", .{ name, sk.rel, f.rel });
            return true;
        };
        if (sk.skill_md_bytes > skills.max_body) {
            try c.line(.not, "skill {s} ({s}): SKILL.md is {s} bytes; harness takes at most 65,536", .{ name, sk.rel, try thousands(c.a, sk.skill_md_bytes) });
            return true;
        }
        for (sk.files) |f| if (f.size > skills.max_file) {
            try c.line(.not, "skill {s} ({s}): {s} is {s} bytes; harness takes at most 262,144 a file", .{ name, sk.rel, f.rel, try thousands(c.a, f.size) });
            return true;
        };
        if (sk.files.len > skillsrc.max_files or sk.bytes > skillsrc.max_total) {
            try c.line(.not, "skill {s} ({s}): {d} files, {s} bytes; harness takes at most 300 files and 10 MB a skill", .{ name, sk.rel, sk.files.len, try thousands(c.a, sk.bytes) });
            return true;
        }
        return false;
    }

    fn planSkill(c: *Ctx, sk: hermes.SkillDir, name: []const u8, files: []skillsrc.File, planned: *std.StringHashMapUnmanaged(void)) !void {
        var md_index: ?usize = null;
        for (files, 0..) |f, i| if (std.mem.eql(u8, f.rel, "SKILL.md")) {
            md_index = i;
        };
        const mi = md_index orelse return c.line(.not, "skill {s} ({s}): it has no SKILL.md", .{ name, sk.rel });
        const header = skills.readHeader(c.a, files[mi].data) catch
            return c.line(.not, "skill {s} ({s}): its SKILL.md has no frontmatter harness reads", .{ name, sk.rel });
        var desc: []const u8 = "";
        var fm_name: []const u8 = "";
        var hermes_fields: std.ArrayList([]const u8) = .empty;
        for (header.fields) |f| {
            if (f.nested or f.key.len == 0) continue;
            if (std.mem.eql(u8, f.key, "description")) desc = f.value;
            if (std.mem.eql(u8, f.key, "name")) fm_name = f.value;
            const standard = for ([_][]const u8{ "name", "description", "license", "compatibility", "metadata", "allowed-tools" }) |k| {
                if (std.mem.eql(u8, k, f.key)) break true;
            } else false;
            if (!standard) try hermes_fields.append(c.a, f.key);
        }
        if (desc.len == 0 or desc.len > skills.max_description)
            return c.line(.not, "skill {s} ({s}): its SKILL.md has no description of at most 1,024 characters; harness needs one", .{ name, sk.rel });
        if (!std.mem.eql(u8, fm_name, name)) files[mi].data = try renameSkill(c.a, files[mi].data, name);
        const hash = try skillsrc.hashFiles(c.a, files);
        for (c.h.skills) |ins| if (std.mem.eql(u8, ins.name, name)) {
            if (std.mem.eql(u8, ins.hash, &hash)) return c.line(.not, "skill {s} ({s}): already there", .{ name, sk.rel });
            return c.line(.not, "skill {s} ({s}): a skill {s} is in harness already", .{ name, sk.rel, name });
        };
        if (planned.contains(name)) return c.line(.not, "skill {s} ({s}): its name becomes {s}, which another Hermes skill takes", .{ sk.name, sk.rel, name });
        try planned.put(c.a, name, {});
        var notes: std.ArrayList([]const u8) = .empty;
        if (!std.mem.eql(u8, name, sk.name)) try notes.append(c.a, try std.fmt.allocPrint(c.a, "renamed from {s}", .{sk.name}));
        if (hermes_fields.items.len > 0) try notes.append(c.a, try std.fmt.allocPrint(c.a, "Hermes's fields kept in it: {s}", .{try std.mem.join(c.a, ", ", hermes_fields.items)}));
        if (sk.bundled) |b| try notes.append(c.a, if (b.edited) "one of Hermes's own, edited" else "one of Hermes's own");
        var source: []const u8 = "hermes";
        if (sk.hub) |hub| {
            if (std.mem.eql(u8, hub.source, "github") and githubId(hub.identifier)) {
                source = hub.identifier;
                try notes.append(c.a, try std.fmt.allocPrint(c.a, "from {s}; harness skill update works on it", .{hub.identifier}));
            } else try notes.append(c.a, try std.fmt.allocPrint(c.a, "from {s}; harness can't update it", .{hub.source}));
        }
        try c.skill_names.put(c.a, sk.name, name);
        try c.p.skills.append(c.a, .{ .name = name, .rel = sk.rel, .files = files, .hash = hash, .source = source });
        if (notes.items.len == 0) return c.line(.will, "skill {s} ({s})", .{ name, sk.rel });
        try c.line(.will, "skill {s} ({s}): {s}", .{ name, sk.rel, try std.mem.join(c.a, "; ", notes.items) });
    }

    // ---- cron jobs ----

    fn planJobs(c: *Ctx) !void {
        if (c.s.jobs_problem) |why| try c.line(.not, "scheduled jobs: {s}", .{why});
        var taken: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ c.h.tasks_text, c.h.triggers_text, c.h.briefs_text }) |text| try headers(c.a, text, &taken);
        for (c.s.jobs) |j| try c.planJob(j, &taken);
        if (!c.tasks_any) return;
        try c.line(.needs, "Imported tasks run with harness's rules: in a run nobody watches every question is a refusal, so a job that worked in Hermes because a command was always allowed there is refused here until you add a rule.", .{});
        if (c.every_note) try c.line(.needs, "Tasks at every N h: harness's every isn't aligned to the clock hour and varies by up to 10%.", .{});
        if (c.at_note) try c.line(.needs, "Times: harness's utc_offset ({s}) doesn't follow daylight saving; check the imported times when the clocks change.", .{try fmtOffset(c.a, c.cfg.chat.utc_offset)});
    }

    fn planJob(c: *Ctx, j: hermes.Job, taken: *std.ArrayList([]const u8)) !void {
        const jname = if (j.name.len > 0) j.name else j.id;
        const base = sanitize(c.a, jname);
        if (j.script.len > 0 or j.no_agent)
            return c.line(.not, "task {s} (Hermes job {s}): runs a script ({s}) unattended; set it up as a trigger by hand", .{ base, jname, if (j.script.len > 0) j.script else "no agent" });
        const prompt = std.mem.trim(u8, try std.mem.replaceOwned(u8, c.a, j.prompt, "\r\n", "\n"), " \t\r\n");
        if (prompt.len == 0) return c.line(.not, "task {s} (Hermes job {s}): it has no prompt", .{ base, jname });
        // when
        var sched_lines: []const u8 = "";
        var sched_text: []const u8 = "";
        var conv: []const u8 = "";
        switch (j.schedule.kind) {
            .interval => {
                const m = j.schedule.minutes orelse return c.line(.not, "task {s} (Hermes job {s}): its interval has no minutes", .{ base, jname });
                if (m < 5) return c.line(.not, "task {s} (Hermes job {s}): every {d}m; harness's every is at least 5m", .{ base, jname, m });
                const every = try everyText(c.a, m);
                sched_lines = try std.fmt.allocPrint(c.a, "every = {s}\n", .{every});
                sched_text = try std.fmt.allocPrint(c.a, "every {s}", .{every});
            },
            .cron => {
                if (cronAt(j.schedule.expr)) |at| {
                    var r: Shifted = .{ .minutes = at.minutes, .days = at.days };
                    const zone = if (j.timezone.len > 0) j.timezone else if (c.s.config.timezone.len > 0) c.s.config.timezone else c.o.local_zone;
                    const zone_name = if (zone.len > 0) zone else "this computer's zone";
                    if (zones.offsetAt(c.io, c.a, c.o.zone_dirs, zone, c.o.now_s)) |off| {
                        if (off != c.cfg.chat.utc_offset) {
                            r = shift(at.minutes, at.days, off, c.cfg.chat.utc_offset);
                            conv = try std.fmt.allocPrint(c.a, " ({s}{s} in {s}, {s} today, is {s}{s} at harness's {s})", .{ try clock(c.a, at.minutes), try daysSuffix(c.a, at.days), zone_name, try fmtOffset(c.a, off), try clock(c.a, r.minutes), try daysSuffix(c.a, r.days), try fmtOffset(c.a, c.cfg.chat.utc_offset) });
                        }
                    } else conv = try std.fmt.allocPrint(c.a, " (as Hermes had it: {s} can't be read here; check the time)", .{zone_name});
                    c.at_note = true;
                    const days = try dayList(c.a, r.days);
                    sched_lines = if (r.days == 0x7f) try std.fmt.allocPrint(c.a, "at = {s}\n", .{try clock(c.a, r.minutes)}) else try std.fmt.allocPrint(c.a, "at = {s}\ndays = {s}\n", .{ try clock(c.a, r.minutes), days });
                    sched_text = try std.fmt.allocPrint(c.a, "at {s}{s}{s}", .{ try clock(c.a, r.minutes), if (r.days == 0x7f) "" else " ", if (r.days == 0x7f) "" else days });
                } else if (cronEveryHours(j.schedule.expr)) |n| {
                    sched_lines = try std.fmt.allocPrint(c.a, "every = {d}h\n", .{n});
                    sched_text = try std.fmt.allocPrint(c.a, "every {d}h", .{n});
                    c.every_note = true;
                } else return c.line(.not, "task {s} (Hermes job {s}): cron {s} isn't a time on days or every N hours", .{ base, jname, j.schedule.expr });
            },
            .once => return c.line(.not, "task {s} (Hermes job {s}): runs once ({s}); harness's tasks repeat", .{ base, jname, j.schedule.run_at }),
            .other => return c.line(.not, "task {s} (Hermes job {s}): a schedule harness can't read ({s})", .{ base, jname, j.schedule.display }),
        }
        // what it does: its skills first
        var instr = try c.mask(prompt);
        var notes: std.ArrayList([]const u8) = .empty;
        if (j.skills.len > 0) {
            var names: std.ArrayList([]const u8) = .empty;
            var missing: std.ArrayList([]const u8) = .empty;
            for (j.skills) |sn| {
                if (c.skill_names.get(sn)) |hn| try names.append(c.a, hn) else {
                    try names.append(c.a, harnessName(c.a, sn) orelse sn);
                    try missing.append(c.a, sn);
                }
            }
            const prefix = try std.fmt.allocPrint(c.a, "Use the skill{s} {s}.", .{ if (names.items.len > 1) "s" else "", try andList(c.a, names.items) });
            instr = try std.fmt.allocPrint(c.a, "{s}{s}{s}", .{ prefix, if (fitsOneLine(instr)) " " else "\n\n", instr });
            if (missing.items.len > 0) try notes.append(c.a, try std.fmt.allocPrint(c.a, "its skill{s} {s} {s} imported", .{ if (missing.items.len > 1) "s" else "", try andList(c.a, missing.items), if (missing.items.len > 1) "aren't" else "isn't" }));
        }
        // where its answer goes
        const d = delivery(j.deliver_text);
        var commented: ?[]const u8 = null;
        if (!d.main) commented = if (d.local) "local in Hermes: its answer was saved, not sent; harness sends a task's answer" else try std.fmt.allocPrint(c.a, "delivered to {s}, which harness doesn't reach", .{d.where});
        if (!j.enabled) commented = "paused in Hermes";
        // what doesn't come over
        var kept_not: std.ArrayList([]const u8) = .empty;
        if (j.repeat_times) |n| try kept_not.append(c.a, try std.fmt.allocPrint(c.a, "repeat ({d} more runs)", .{@max(0, n - j.repeat_done)}));
        if (j.model.len > 0) try kept_not.append(c.a, try std.fmt.allocPrint(c.a, "model {s}", .{j.model}));
        if (j.provider.len > 0) try kept_not.append(c.a, try std.fmt.allocPrint(c.a, "provider {s}", .{j.provider}));
        if (j.base_url.len > 0) try kept_not.append(c.a, "base_url");
        if (j.workdir.len > 0) try kept_not.append(c.a, "workdir");
        const name = try sectionNameIn(c.a, taken.items, jname);
        if (j.toolsets) try kept_not.append(c.a, try std.fmt.allocPrint(c.a, "toolsets (add deny rules under [schedule:{s}])", .{name}));
        for (j.others) |o| try kept_not.append(c.a, o);
        if (kept_not.items.len > 0) try notes.insert(c.a, 0, try std.fmt.allocPrint(c.a, "not kept: {s}", .{try std.mem.join(c.a, ", ", kept_not.items)}));
        if (d.main and d.chat.len > 0) try notes.append(c.a, try std.fmt.allocPrint(c.a, "the chat {s}{s}{s} aren't kept: it posts to your main conversation", .{ d.chat, if (d.thread.len > 0) " and thread " else "", d.thread }));
        // the same name and instructions there already: nothing twice
        for (c.h.tasks) |tk| {
            const same_name = std.mem.eql(u8, tk.name, base) or (std.mem.startsWith(u8, tk.name, base) and std.mem.startsWith(u8, tk.name[base.len..], "-hermes"));
            if (same_name and std.mem.eql(u8, tk.do, instr)) return c.line(.not, "task {s} (Hermes job {s}): already there", .{ tk.name, jname });
        }
        var sec: std.ArrayList(u8) = .empty;
        try sec.print(c.a, "[{s}]\n{s}", .{ name, sched_lines });
        if (fitsOneLine(instr)) {
            try sec.print(c.a, "do = {s}\n", .{instr});
        } else {
            const file = try std.fmt.allocPrint(c.a, "{s}.md", .{name});
            try sec.print(c.a, "do_file = {s}\n", .{file});
            try c.p.task_files.append(c.a, .{ .name = file, .text = instr });
        }
        const body = if (commented != null) try commentOut(c.a, sec.items) else sec.items;
        if (commented != null and std.mem.indexOf(u8, c.h.tasks_text, body) != null) return c.line(.not, "task {s} (Hermes job {s}): already there", .{ name, jname });
        try c.p.tasks.print(c.a, "\n; from Hermes job {s}: {s}{s}\n{s}", .{ j.id, try c.shown(jname), if (commented) |why| try std.fmt.allocPrint(c.a, " (commented out: {s})", .{why}) else "", body });
        try taken.append(c.a, name);
        try c.p.task_names.append(c.a, name);
        c.p.task_count += 1;
        if (commented != null) c.p.task_commented += 1;
        c.tasks_any = true;
        var text: std.ArrayList(u8) = .empty;
        try text.print(c.a, "task {s}: {s}{s}", .{ name, sched_text, conv });
        if (commented) |why| try text.print(c.a, " (commented out: {s})", .{why});
        for (notes.items) |n| try text.print(c.a, "; {s}", .{n});
        try text.print(c.a, " (Hermes job {s})", .{jname});
        try c.line(.will, "{s}", .{text.items});
    }

    // ---- MCP servers ----

    fn planServers(c: *Ctx) !void {
        const existing = mcp.parseConfig(c.a, c.h.mcp_text) catch &.{};
        var names: std.ArrayList([]const u8) = .empty;
        try headers(c.a, c.h.mcp_text, &names);
        for (c.s.config.mcp) |m| try c.planServer(m, existing, &names);
    }

    fn planServer(c: *Ctx, m: hermes.Mcp, existing: []const mcp.ServerConfig, names: *std.ArrayList([]const u8)) !void {
        const name = mcpName(c.a, m.name) orelse return c.line(.not, "server {s}: its name can't be made an mcp.ini name", .{m.name});
        for (names.items) |n| if (std.mem.eql(u8, n, name)) {
            for (existing) |e| if (std.mem.eql(u8, e.name, name) and ((m.url.len > 0 and std.mem.eql(u8, e.url, m.url)) or (m.url.len == 0 and e.command.len > 0 and std.mem.eql(u8, e.command, (try quoteArgs(c.a, m.command, m.args)) orelse ""))))
                return c.line(.not, "server {s}: already there", .{name});
            return c.line(.not, "server {s}: a server {s} is in mcp.ini already", .{ name, name });
        };
        if (m.problem) |why| return c.line(.not, "server {s}: {s}", .{ name, why });
        var sec: std.ArrayList(u8) = .empty;
        var commented: ?[]const u8 = null;
        var secrets_line: std.ArrayList(u8) = .empty;
        var needs: std.ArrayList([]const u8) = .empty;
        try sec.print(c.a, "[{s}]\n", .{name});
        if (m.url.len > 0) {
            if (std.ascii.eqlIgnoreCase(m.transport, "sse")) return c.line(.not, "server {s}: it speaks SSE; harness speaks Streamable HTTP only", .{name});
            try sec.print(c.a, "url = {s}\n", .{m.url});
            for (m.headers) |hd| {
                if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) {
                    const v = std.mem.trim(u8, hd.value, " ");
                    if (!std.ascii.startsWithIgnoreCase(v, "bearer ")) {
                        commented = "its Authorization header isn't a bearer token";
                        continue;
                    }
                    const tok = std.mem.trim(u8, v["bearer ".len..], " ");
                    const sname = if (hermes.envRef(tok)) |ref|
                        try c.secretFor(try std.fmt.allocPrint(c.a, "env:{s}", .{ref}), ref, name, try c.envWhere(ref))
                    else
                        try c.secretFor(try std.fmt.allocPrint(c.a, "lit:{s}.authorization", .{m.name}), try std.fmt.allocPrint(c.a, "{s}-token", .{name}), name, try std.fmt.allocPrint(c.a, "the bearer token in mcp_servers.{s}.headers.Authorization in Hermes's config.yaml", .{m.name}));
                    try sec.print(c.a, "token = {s}\n", .{sname});
                } else if (hermes.looksSecret(hd.name, hd.value) or isEnvValue(c.s, hd.value)) {
                    commented = try std.fmt.allocPrint(c.a, "it needs header {s}, a secret, and mcp.ini has no secret header", .{hd.name});
                } else if (!fitsOneLine(hd.value)) {
                    commented = try std.fmt.allocPrint(c.a, "its header {s} can't be written in mcp.ini", .{hd.name});
                } else try sec.print(c.a, "header = {s}: {s}\n", .{ hd.name, hd.value });
            }
            if (m.auth.len > 0) {
                if (!std.ascii.eqlIgnoreCase(m.auth, "oauth")) return c.line(.not, "server {s}: auth {s} isn't one harness has", .{ name, m.auth });
                try sec.appendSlice(c.a, "login = oauth\n");
                try needs.append(c.a, try std.fmt.allocPrint(c.a, "harness mcp login {s}    (server {s} signs in with oauth)", .{ name, name }));
            }
        } else if (m.command.len > 0) {
            if (try quoteArgs(c.a, m.command, m.args)) |cmd| {
                try sec.print(c.a, "command = {s}\n", .{cmd});
            } else {
                commented = "an argument can't be written in mcp.ini (a \", ; or # in it, or a new line)";
                try sec.print(c.a, "command = {s}\n", .{m.command});
            }
            var plain: std.ArrayList(u8) = .empty;
            for (m.env) |e| {
                const ref = hermes.envRefIn(e.value);
                const env_name = envNameOf(c.s, e.value);
                if (ref != null or env_name != null or hermes.looksSecret(e.name, e.value) or mcp.secretLike(e.name)) {
                    const sname = if (ref) |r| blk: {
                        if (hermes.envRef(e.value) == null) try needs.append(c.a, try std.fmt.allocPrint(c.a, "{s}: env {s} is built from ${{{s}}}; store its whole value", .{ name, e.name, r }));
                        break :blk try c.secretFor(try std.fmt.allocPrint(c.a, "env:{s}", .{r}), r, name, try c.envWhere(r));
                    } else if (env_name) |en|
                        try c.secretFor(try std.fmt.allocPrint(c.a, "env:{s}", .{en}), en, name, try c.envWhere(en))
                    else
                        try c.secretFor(try std.fmt.allocPrint(c.a, "lit:{s}.env.{s}", .{ m.name, e.name }), e.name, name, try std.fmt.allocPrint(c.a, "the value at mcp_servers.{s}.env.{s} in Hermes's config.yaml", .{ m.name, e.name }));
                    try secrets_line.print(c.a, "{s}{s}:{s}", .{ if (secrets_line.items.len > 0) ", " else "", e.name, sname });
                } else if (!fitsOneLine(e.value)) {
                    commented = try std.fmt.allocPrint(c.a, "env {s}'s value can't be written in mcp.ini", .{e.name});
                } else try plain.print(c.a, "env = {s}={s}\n", .{ e.name, e.value });
            }
            if (secrets_line.items.len > 0) try sec.print(c.a, "secret = {s}\n", .{secrets_line.items});
            try sec.appendSlice(c.a, plain.items);
        } else return c.line(.not, "server {s}: it has neither a command nor a url", .{name});
        if (!m.enabled) commented = "disabled in Hermes";
        // it reads as mcp.ini, or it comes over commented out with the reason
        if (commented == null) _ = mcp.parseConfig(c.a, sec.items) catch |e| {
            commented = mcp.configReason(e) orelse "it doesn't read as mcp.ini";
        };
        for (m.exclude) |g| try c.mcp_denies.append(c.a, try std.fmt.allocPrint(c.a, "deny mcp {s}/{s} *", .{ name, narrowGlob(c.a, g) catch g }));
        if (m.include) |inc| try needs.append(c.a, try std.fmt.allocPrint(c.a, "{s}: Hermes offered only its tools {s}; harness offers all of them: add a deny rule for each other one (deny mcp {s}/TOOL *)", .{ name, try std.mem.join(c.a, ", ", inc), name }));
        const body = if (commented != null) try commentOut(c.a, sec.items) else sec.items;
        if (commented != null and std.mem.indexOf(u8, c.h.mcp_text, body) != null) return c.line(.not, "server {s}: already there", .{name});
        try c.p.mcp.print(c.a, "\n; from Hermes: mcp_servers.{s}{s}\n{s}", .{ m.name, if (commented) |why| try std.fmt.allocPrint(c.a, " (commented out: {s})", .{why}) else "", body });
        try names.append(c.a, name);
        try c.p.server_names.append(c.a, name);
        c.p.server_count += 1;
        if (commented) |why| {
            c.p.server_commented += 1;
            try c.line(.will, "server {s} (commented out: {s})", .{ name, why });
        } else try c.line(.will, "server {s}: {s}", .{ name, if (m.url.len > 0) m.url else m.command });
        for (needs.items) |n| try c.line(.needs, "{s}", .{n});
    }

    /// The stored secret's name for a value (`id` says which), given once;
    /// `want` names it, the server's name in front when another value took it.
    fn secretFor(c: *Ctx, id: []const u8, want: []const u8, server: []const u8, where: []const u8) ![]const u8 {
        var name = secretName(c.a, want);
        if (c.secret_ids.get(name)) |other| {
            if (std.mem.eql(u8, other, id)) return name;
            name = secretName(c.a, try std.fmt.allocPrint(c.a, "{s}-{s}", .{ server, want }));
            if (c.secret_ids.get(name)) |o2| if (std.mem.eql(u8, o2, id)) return name;
        }
        try c.secret_ids.put(c.a, name, id);
        try c.p.secrets.append(c.a, .{ .name = name, .where = where });
        return name;
    }

    /// Where the owner finds the value of a variable Hermes reads.
    fn envWhere(c: *Ctx, name: []const u8) ![]const u8 {
        try c.used_env.put(c.a, name, {});
        for (c.s.env) |e| if (std.mem.eql(u8, e.name, name)) return std.fmt.allocPrint(c.a, "the value of {s} in Hermes's .env", .{name});
        return std.fmt.allocPrint(c.a, "{s}, which Hermes takes from its environment (it isn't in its .env)", .{name});
    }

    // ---- rules ----

    fn planRules(c: *Ctx) !void {
        var block: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        var lines: std.ArrayList(struct { line: []const u8, from: []const u8 }) = .empty;
        for (c.s.config.deny) |pat| {
            const p = std.mem.trim(u8, pat, " \t");
            if (p.len == 0) continue;
            if (std.mem.indexOfAny(u8, p, "\r\n") != null) {
                try c.line(.not, "deny rule {s}: it can't be written on one line", .{p});
                continue;
            }
            try lines.append(c.a, .{ .line = try std.fmt.allocPrint(c.a, "deny shell {s}", .{try narrowGlob(c.a, p)}), .from = p });
        }
        for (c.mcp_denies.items) |l| try lines.append(c.a, .{ .line = l, .from = l["deny mcp ".len..] });
        for (lines.items) |l| {
            if (hasLine(c.h.rules_text, l.line)) {
                try c.line(.not, "deny rule {s}: already there", .{l.from});
                continue;
            }
            try block.print(c.a, "{s}\n", .{l.line});
            try c.line(.will, "deny rule: {s}", .{l.line["deny ".len..]});
            count += 1;
        }
        if (count == 0) return;
        if (c.s.config.deny.len > 0) try c.line(.will, "deny rules: Hermes's were matched case-insensitively in Hermes; harness matches them as written, and ? and [...] became *, which denies more", .{});
        c.p.rule_count = count;
        try c.p.rules.print(c.a, "\n[all]\n# from Hermes: approvals.deny and the tools its MCP servers left out\n{s}", .{block.items});
        _ = rules.parse(c.a, c.p.rules.items) catch {
            c.p.rules = .empty;
            c.p.rule_count = 0;
            try c.line(.not, "deny rules: they don't read as harness's rules", .{});
        };
    }

    fn planAllowlist(c: *Ctx) !void {
        if (c.s.config.allowlist.len == 0) return;
        var commands: std.ArrayList([]const u8) = .empty;
        var patterns: std.ArrayList([]const u8) = .empty;
        for (c.s.config.allowlist) |raw| {
            const e = std.mem.trim(u8, raw, " \t");
            if (e.len == 0 or std.mem.indexOfAny(u8, e, "\r\n") != null) continue;
            const named = for (hermes.pattern_names) |n| {
                if (std.mem.eql(u8, n, e)) break true;
            } else std.mem.indexOfScalar(u8, e, '\\') != null;
            try (if (named) &patterns else &commands).append(c.a, e);
        }
        var s = &c.p.suggested;
        try s.appendSlice(c.a, "# Hermes always allowed these (command_allowlist). harness asks for every\n# shell command unless a rule allows it. None of this is active: to allow\n# a command, copy its line into rules without the #. harness's patterns\n# know only * (any text): Hermes's ? and [...] became *.\n");
        for (commands.items) |cmd| try s.print(c.a, "# allow shell {s}\n", .{try c.mask(try narrowGlob(c.a, cmd))});
        if (patterns.items.len > 0) {
            try s.appendSlice(c.a, "#\n# Kinds of command Hermes always allowed; harness has no rule for a kind:\n");
            for (patterns.items) |pn| try s.print(c.a, "#   {s}\n", .{pn});
            try c.line(.needs, "Hermes always allowed: {s}. harness asks for every shell command unless a rule allows it.", .{try std.mem.join(c.a, ", ", patterns.items)});
        }
        if (commands.items.len > 0) try c.line(.needs, "Commands Hermes always allowed are in {s}/rules.suggested as commented allow lines: yours to copy into rules.", .{c.o.import_dir});
    }

    // ---- the model and providers ----

    fn planModel(c: *Ctx) !void {
        var text: []const u8 = c.h.config_text;
        var mapped: std.ArrayList(struct { hermes: []const u8, name: []const u8 }) = .empty;
        for (c.s.config.providers) |pv| {
            if (!pv.enabled) {
                try c.line(.not, "provider {s}: disabled in Hermes", .{pv.name});
                continue;
            }
            const pname = providerName(c.a, pv.name) orelse {
                try c.line(.not, "provider {s}: its name can't be made a provider name for config.ini", .{pv.name});
                continue;
            };
            const api = apiOf(pv.api_mode) orelse {
                try c.line(.not, "provider {s}: it speaks {s}; harness speaks the OpenAI and Anthropic formats", .{ pv.name, pv.api_mode });
                continue;
            };
            if (!model.validUrl(pv.base_url) or std.mem.indexOf(u8, pv.base_url, "${") != null) {
                try c.line(.not, "provider {s}: its url ({s}) isn't one harness can use", .{ pv.name, pv.base_url });
                continue;
            }
            var there: ?[]const u8 = null;
            for (c.cfg.providers) |hp| if (std.mem.eql(u8, hp.name, pname)) {
                there = if (hp.url != null and std.mem.eql(u8, hp.url.?, pv.base_url)) "already there" else "a provider of that name is in config.ini already";
            };
            if (there) |why| {
                try c.line(.not, "provider {s}: {s}", .{ pname, why });
                continue;
            }
            const has_key = pv.api_key.len > 0 or pv.key_env.len > 0;
            if (has_key) {
                const where = if (pv.key_env.len > 0)
                    try c.envWhere(pv.key_env)
                else if (hermes.envRef(pv.api_key)) |ref|
                    try c.envWhere(ref)
                else
                    try std.fmt.allocPrint(c.a, "the api_key of provider {s} in Hermes's config.yaml", .{pv.name});
                _ = try c.secretFor(try std.fmt.allocPrint(c.a, "provider:{s}", .{pname}), pname, pname, where);
            }
            text = try std.fmt.allocPrint(c.a, "{s}{s}\n[provider {s}]\napi = {s}\nurl = {s}\n{s}", .{ text, if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "", pname, api, pv.base_url, if (has_key) try std.fmt.allocPrint(c.a, "key = {s}\n", .{pname}) else "auth = none\n" });
            try c.line(.will, "provider {s}: {s} at {s}", .{ pname, api, pv.base_url });
            c.p.provider_count += 1;
            try mapped.append(c.a, .{ .hermes = pv.name, .name = pname });
        }
        const m = c.s.config.model;
        if (m.name.len > 0 or m.provider.len > 0) model: {
            if (m.provider.len == 0) {
                try c.line(.not, "model {s}: it names no provider; set [model] in config.ini by hand", .{m.name});
                break :model;
            }
            var prov: []const u8 = "";
            var key_line: ?struct { id: []const u8, where: []const u8 } = null;
            if (model.isPreset(m.provider) and !std.mem.eql(u8, m.provider, "omnigate")) {
                prov = m.provider;
                const var_name = try std.ascii.allocUpperString(c.a, try std.fmt.allocPrint(c.a, "{s}_API_KEY", .{m.provider}));
                const in_env = for (c.s.env) |e| {
                    if (std.mem.eql(u8, e.name, var_name)) break true;
                } else false;
                key_line = .{ .id = try std.fmt.allocPrint(c.a, "preset:{s}", .{prov}), .where = if (in_env) try c.envWhere(var_name) else try std.fmt.allocPrint(c.a, "your {s} key", .{prov}) };
            } else for (mapped.items) |mp| {
                if (std.mem.eql(u8, mp.hermes, m.provider)) prov = mp.name;
            }
            if (prov.len == 0) {
                try c.line(.not, "model {s}: {s}: harness has no preset or provider section for {s}; set [model] in config.ini by hand", .{ m.provider, m.name, m.provider });
                break :model;
            }
            const set = !std.mem.eql(u8, c.cfg.model.provider, "omnigate") or c.cfg.model.url.len > 0;
            const value = if (std.mem.indexOfScalar(u8, m.name, ':') != null) try std.fmt.allocPrint(c.a, "{s}:{s}", .{ prov, m.name }) else m.name;
            if (set) {
                if (std.mem.eql(u8, c.cfg.model.provider, prov) and std.mem.eql(u8, c.cfg.model.model, value)) {
                    try c.line(.not, "model {s}: {s}: already there", .{ m.provider, m.name });
                } else try c.line(.not, "model {s}: {s}: harness has its provider set ({s}); not changed. To use it: [model] provider = {s}, model = {s}", .{ m.provider, m.name, c.cfg.model.provider, prov, value });
                break :model;
            }
            if (key_line) |k| _ = try c.secretFor(k.id, prov, prov, k.where);
            text = try setIni(c.a, text, "model", "provider", prov);
            text = try setIni(c.a, text, "model", "model", value);
            c.p.model_set = true;
            try c.line(.will, "the model: {s} at {s}", .{ m.name, prov });
            if (std.mem.eql(u8, c.cfg.model.memory_model, "claude-haiku") or std.mem.eql(u8, c.cfg.model.worker_model, "claude-haiku"))
                try c.line(.needs, "[model] memory_model and worker_model in config.ini name omnigate's claude-haiku: set them to models {s} has.", .{prov});
        }
        if (std.mem.eql(u8, text, c.h.config_text)) return;
        _ = config.parse(c.a, text) catch |e| {
            try c.line(.not, "config.ini changes: they don't read ({s}); add the model and providers by hand", .{config.reason(e) orelse @errorName(e)});
            return;
        };
        c.p.config_ini = text;
    }

    fn planTelegram(c: *Ctx) !void {
        var token = false;
        for (c.s.env) |e| if (std.mem.startsWith(u8, e.name, "TELEGRAM_")) {
            try c.used_env.put(c.a, e.name, {});
            if (std.mem.eql(u8, e.name, "TELEGRAM_BOT_TOKEN")) token = true;
        };
        if (token) try c.line(.needs, "Telegram: one bot can't be read by two agents at once, so Hermes's bot isn't moved. Make a new bot for harness with @BotFather, or stop Hermes's gateway first; then harness secret add telegram, and pair with /pair as usual.", .{});
    }

    fn planRest(c: *Ctx) !void {
        for (c.s.config.problems) |pr| try c.line(.not, "config.yaml near line {d} ({s}): couldn't read it; add it by hand", .{ pr.line, pr.key });
        if (c.s.config.external_dirs.len > 0)
            try c.line(.not, "skills in other folders Hermes read: {s} (harness reads its own skills/ alone: copy any you want with harness skill add FOLDER)", .{try std.mem.join(c.a, ", ", c.s.config.external_dirs)});
        for (c.s.config.skill_config) |kv| try c.line(.not, "skill settings (skills.config): {s} = {s}; harness has no store for these", .{ kv.name, kv.value });
        for (c.s.others) |o| {
            if (std.mem.eql(u8, o.rel, "config.yaml")) {
                try c.line(.not, "{s}: not brought over", .{o.what});
            } else try c.line(.not, "{s}: {s} stays in Hermes", .{ o.what, try std.fs.path.join(c.a, &.{ c.s.home.dir, o.rel }) });
        }
        // other profiles
        const pdir = try std.fs.path.join(c.a, &.{ c.s.home.root, "profiles" });
        if (Io.Dir.cwd().openDir(c.io, pdir, .{ .iterate = true })) |d_| {
            var d = d_;
            defer d.close(c.io);
            var it = d.iterate();
            var others: std.ArrayList([]const u8) = .empty;
            while (try it.next(c.io)) |e| {
                if (e.kind != .directory or e.name[0] == '.' or std.mem.eql(u8, e.name, c.s.home.profile)) continue;
                try others.append(c.a, try c.a.dupe(u8, e.name));
            }
            if (!std.mem.eql(u8, c.s.home.profile, "default")) try others.insert(c.a, 0, "default");
            if (others.items.len > 0) try c.line(.not, "other Hermes profiles: {s} (harness import hermes --profile NAME)", .{try std.mem.join(c.a, ", ", others.items)});
        } else |_| {}
        var unused: std.ArrayList([]const u8) = .empty;
        for (c.s.env) |e| if (!c.used_env.contains(e.name)) try unused.append(c.a, e.name);
        if (unused.items.len > 0) try c.line(.not, ".env keys nothing here uses: {s} (their values stay in Hermes)", .{try std.mem.join(c.a, ", ", unused.items)});
    }
};

/// Whether `value` is the value of a variable in Hermes's .env.
fn isEnvValue(s: hermes.Setup, value: []const u8) bool {
    return envNameOf(s, value) != null;
}

/// The .env variable holding `value` (8 characters or more), if one does.
fn envNameOf(s: hermes.Setup, value: []const u8) ?[]const u8 {
    if (value.len < 8) return null;
    for (s.env) |e| if (std.mem.eql(u8, e.value, value)) return e.name;
    return null;
}

/// harness's API for a Hermes api_mode: openai (chat completions, the
/// default) or anthropic; null for the others.
fn apiOf(mode: []const u8) ?[]const u8 {
    const m = std.mem.trim(u8, mode, " ");
    if (m.len == 0) return "openai";
    for ([_][]const u8{ "chat_completions", "openai", "openai_chat", "openai-chat", "chat-completions", "chatcompletions" }) |x| if (std.ascii.eqlIgnoreCase(m, x)) return "openai";
    for ([_][]const u8{ "anthropic_messages", "anthropic", "anthropic-messages", "messages" }) |x| if (std.ascii.eqlIgnoreCase(m, x)) return "anthropic";
    return null;
}

/// `OWNER/REPO[/PATH]`, as a GitHub hub install names its skill.
fn githubId(id: []const u8) bool {
    var it = std.mem.splitScalar(u8, id, '/');
    var n: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
        n += 1;
    }
    return n >= 2;
}

/// `lines` with `line` as one of them (trimmed).
fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), line)) return true;
    return false;
}

/// The `[NAME]` headers of an INI text, added to `out`.
fn headers(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > 2 and l[0] == '[' and l[l.len - 1] == ']') try out.append(a, std.mem.trim(u8, l[1 .. l.len - 1], " \t"));
    }
}

/// Every line of `text` behind "; ".
fn commentOut(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| try out.print(a, "; {s}\n", .{l});
    return out.items;
}

/// A glob with Hermes's `?` and `[...]` made `*`: matching more, which for
/// a deny only denies more.
fn narrowGlob(a: std.mem.Allocator, g: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < g.len) : (i += 1) {
        if (g[i] == '?') {
            try out.append(a, '*');
        } else if (g[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, g, i + 1, ']')) |close| {
                try out.append(a, '*');
                i = close;
            } else try out.append(a, '[');
        } else try out.append(a, g[i]);
    }
    return out.items;
}

/// The command line mcp.ini's `command =` takes: each part quoted when it
/// has a space; null when one can't be written (a `"`, a new line, or a
/// `;` or `#` that mcp.ini would read as a comment).
fn quoteArgs(a: std.mem.Allocator, command: []const u8, args: []const []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(a, command);
    try parts.appendSlice(a, args);
    for (parts.items, 0..) |part, i| {
        if (std.mem.indexOfAny(u8, part, "\"\r\n") != null) return null;
        if (i > 0) try out.append(a, ' ');
        if (part.len == 0 or std.mem.indexOfAny(u8, part, " \t") != null) {
            try out.print(a, "\"{s}\"", .{part});
        } else try out.appendSlice(a, part);
    }
    if (config.stripComment(out.items).len != out.items.len) return null;
    if (out.items.len == 0) return null;
    return out.items;
}

/// A stored secret's name for `want`: lower case, a-z, 0-9, `-` and `_`,
/// starting with a letter or digit, at most 64.
fn secretName(a: std.mem.Allocator, want: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (want) |ch| {
        const l = std.ascii.toLower(ch);
        const ok = std.ascii.isLower(l) or std.ascii.isDigit(l) or l == '-' or l == '_';
        if (!ok and out.items.len == 0) continue;
        out.append(a, if (ok) l else '-') catch return "hermes";
    }
    var s = std.mem.trimStart(u8, out.items, "-_");
    if (s.len > 64) s = s[0..64];
    return if (s.len == 0) "hermes" else s;
}

/// A name for config.ini's `[provider NAME]`: a-z, 0-9, `-`, `_`, up to 32.
fn providerName(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const s = secretName(a, raw);
    const n = if (s.len > 32) s[0..32] else s;
    return if (model.validName(n) and !std.mem.eql(u8, n, "hermes-unused")) n else null;
}

/// A name for mcp.ini: a-z, 0-9, `-` and `_`, up to 32, no `__`.
fn mcpName(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |ch| {
        const l = std.ascii.toLower(ch);
        const c = if (std.ascii.isLower(l) or std.ascii.isDigit(l) or l == '-' or l == '_') l else '-';
        if (c == '_' and out.items.len > 0 and out.items[out.items.len - 1] == '_') continue;
        out.append(a, c) catch return null;
    }
    const n = if (out.items.len > 32) out.items[0..32] else out.items;
    return if (mcp.validName(n)) n else null;
}

/// A Hermes skill's name as harness takes it: lower case, `.` and `_` as
/// `-`, runs of `-` as one, none at the ends; null when that is still no
/// skill name (skills.zig).
pub fn harnessName(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |ch| {
        var c = std.ascii.toLower(ch);
        if (c == '.' or c == '_') c = '-';
        if (c == '-' and (out.items.len == 0 or out.items[out.items.len - 1] == '-')) continue;
        out.append(a, c) catch return null;
    }
    const n = std.mem.trimEnd(u8, out.items, "-");
    return if (skills.validName(n)) n else null;
}

/// SKILL.md with its frontmatter's `name` set to `name` (added after the
/// first fence when there is none); line ends kept.
fn renameSkill(a: std.mem.Allocator, md: []const u8, name: []const u8) ![]const u8 {
    const crlf = std.mem.indexOf(u8, md, "\r\n") != null;
    const nl: []const u8 = if (crlf) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, md, '\n');
    var n: usize = 0;
    var done = false;
    var in_header = false;
    while (it.next()) |raw| {
        n += 1;
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (n > 1) try out.append(a, '\n');
        if (n == 1) {
            in_header = true;
            try out.appendSlice(a, raw);
            continue;
        }
        if (in_header and std.mem.eql(u8, std.mem.trimEnd(u8, l, " \t"), "---")) {
            in_header = false;
            if (!done) {
                try out.print(a, "name: {s}{s}", .{ name, nl });
                done = true;
            }
            try out.appendSlice(a, raw);
            continue;
        }
        if (in_header and !done and std.mem.startsWith(u8, l, "name:")) {
            try out.print(a, "name: {s}{s}", .{ name, if (crlf) "\r" else "" });
            done = true;
            continue;
        }
        try out.appendSlice(a, raw);
    }
    return out.items;
}

/// config.ini with `key = value` in `[sect]`: the value replaced where the
/// key is (its comment kept), else a line at the section's end, else a
/// new section at the end of the file.
fn setIni(a: std.mem.Allocator, text: []const u8, sect: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, l);
    var in_sect = false;
    var last_key: ?usize = null;
    var header: ?usize = null;
    for (lines.items, 0..) |raw, i| {
        const l = std.mem.trim(u8, config.stripComment(raw), " \t\r");
        if (l.len > 1 and l[0] == '[' and l[l.len - 1] == ']') {
            if (in_sect) break;
            in_sect = std.mem.eql(u8, std.mem.trim(u8, l[1 .. l.len - 1], " \t"), sect);
            if (in_sect) header = i;
            continue;
        }
        if (!in_sect or l.len == 0) continue;
        last_key = i;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " \t"), key)) continue;
        // keep what follows the value: spaces up to its comment, and the comment
        const val_start = std.mem.indexOfScalar(u8, raw, '=').? + 1;
        const comment_at = config.stripComment(raw).len;
        const tail = raw[comment_at..];
        const old_val = std.mem.trim(u8, raw[val_start..comment_at], " \t\r");
        const pad = if (tail.len > 0) blk: {
            const want = (comment_at - val_start);
            const have = value.len + 1;
            break :blk if (want > have) want - have else 1;
        } else 0;
        _ = old_val;
        var nl: std.ArrayList(u8) = .empty;
        try nl.print(a, "{s}= {s}", .{ raw[0 .. val_start - 1], value });
        if (tail.len > 0) {
            try nl.appendNTimes(a, ' ', pad);
            try nl.appendSlice(a, tail);
        } else if (std.mem.endsWith(u8, raw, "\r")) try nl.append(a, '\r');
        lines.items[i] = nl.items;
        return std.mem.join(a, "\n", lines.items);
    }
    const new_line = try std.fmt.allocPrint(a, "{s} = {s}", .{ key, value });
    if (header) |h| {
        try lines.insert(a, (last_key orelse h) + 1, new_line);
        return std.mem.join(a, "\n", lines.items);
    }
    return std.fmt.allocPrint(a, "{s}{s}\n[{s}]\n{s}\n", .{ text, if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "", sect, new_line });
}

/// Whether `text` can be a `do =` line or an mcp.ini value as it is: one
/// line, no ` ;` or ` #` (which start a comment), no space at either end.
pub fn fitsOneLine(text: []const u8) bool {
    if (text.len == 0 or std.mem.indexOfAny(u8, text, "\r\n") != null) return false;
    if (std.mem.trim(u8, text, " \t").len != text.len) return false;
    return config.stripComment(text).len == text.len;
}

/// A time and days moved from one offset to another (minutes east): the
/// days move with it when it crosses midnight.
pub const Shifted = struct { minutes: i32, days: u7 };

pub fn shift(minutes: i32, days: u7, from_off: i32, to_off: i32) Shifted {
    var m = minutes - from_off + to_off;
    var by: i32 = 0;
    while (m < 0) {
        m += 1440;
        by -= 1;
    }
    while (m >= 1440) {
        m -= 1440;
        by += 1;
    }
    var out: u7 = 0;
    for (0..7) |i| if (days & (@as(u7, 1) << @intCast(i)) != 0) {
        const to: u3 = @intCast(@mod(@as(i32, @intCast(i)) + by, 7));
        out |= @as(u7, 1) << to;
    };
    return .{ .minutes = m, .days = out };
}

/// Where a job's answer went: to the main conversation (origin, the home
/// channels, Telegram, `all`), or somewhere harness doesn't reach.
pub const Delivery = struct {
    main: bool,
    /// `telegram:CHAT[:THREAD]`'s chat and thread, which aren't kept.
    chat: []const u8 = "",
    thread: []const u8 = "",
    /// Only local (or nothing): Hermes saved the answer without sending it.
    local: bool = false,
    /// As written.
    where: []const u8 = "",
};

pub fn delivery(d: ?[]const u8) Delivery {
    const text = d orelse return .{ .main = false, .local = true, .where = "local" };
    var out: Delivery = .{ .main = false, .local = true, .where = text };
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0 or std.mem.eql(u8, item, "local")) continue;
        if (std.mem.eql(u8, item, "origin") or std.mem.eql(u8, item, "telegram") or std.mem.eql(u8, item, "all")) {
            out.main = true;
        } else if (std.mem.startsWith(u8, item, "telegram:")) {
            out.main = true;
            var parts = std.mem.splitScalar(u8, item["telegram:".len..], ':');
            out.chat = parts.next() orelse "";
            out.thread = parts.next() orelse "";
        } else out.local = false;
    }
    if (out.main) out.local = false;
    return out;
}

/// A job's name as a tasks.ini section's: lower case, other characters
/// as `-`, runs of `-` as one.
fn sanitize(a: std.mem.Allocator, raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |ch| {
        const l = std.ascii.toLower(ch);
        const c = if (std.ascii.isLower(l) or std.ascii.isDigit(l) or l == '_') l else '-';
        if (c == '-' and (out.items.len == 0 or out.items[out.items.len - 1] == '-')) continue;
        out.append(a, c) catch return "hermes-job";
    }
    var n = std.mem.trim(u8, out.items, "-_");
    if (n.len > 50) n = std.mem.trimEnd(u8, n[0..50], "-_");
    return if (triggers.validName(n)) n else "hermes-job";
}

/// `raw` made a section name none of `taken` has: `-hermes`, then a number.
pub fn sectionName(a: std.mem.Allocator, taken: []const []const u8, raw: []const u8) []const u8 {
    return sectionNameIn(a, taken, raw) catch "hermes-job";
}

fn sectionNameIn(a: std.mem.Allocator, taken: []const []const u8, raw: []const u8) ![]const u8 {
    const base = sanitize(a, raw);
    if (!inList(taken, base)) return base;
    const h = try std.fmt.allocPrint(a, "{s}-hermes", .{base});
    if (!inList(taken, h)) return h;
    var n: usize = 2;
    while (true) : (n += 1) {
        const x = try std.fmt.allocPrint(a, "{s}-hermes-{d}", .{ base, n });
        if (!inList(taken, x)) return x;
    }
}

fn inList(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

const At = struct { minutes: i32, days: u7 };

/// `M H * * DOW` (a time on days), M and H plain numbers.
fn cronAt(expr: []const u8) ?At {
    var f: [6][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |x| {
        if (n == 6) return null;
        f[n] = x;
        n += 1;
    }
    if (n != 5) return null;
    const m = std.fmt.parseInt(u8, f[0], 10) catch return null;
    const h = std.fmt.parseInt(u8, f[1], 10) catch return null;
    if (m > 59 or h > 23) return null;
    if (!std.mem.eql(u8, f[2], "*") or !std.mem.eql(u8, f[3], "*")) return null;
    return .{ .minutes = @as(i32, h) * 60 + m, .days = cronDays(f[4]) orelse return null };
}

/// `0 */N * * *`: every N hours, 1 to 23.
fn cronEveryHours(expr: []const u8) ?u8 {
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    const f0 = it.next() orelse return null;
    const f1 = it.next() orelse return null;
    for (0..3) |_| if (!std.mem.eql(u8, it.next() orelse return null, "*")) return null;
    if (it.next() != null or !std.mem.eql(u8, f0, "0") or !std.mem.startsWith(u8, f1, "*/")) return null;
    const n = std.fmt.parseInt(u8, f1[2..], 10) catch return null;
    return if (n >= 1 and n <= 23) n else null;
}

/// A cron day-of-week field (0 or 7 Sunday, names, ranges, lists) as
/// harness's days (bit 0 Monday … bit 6 Sunday); null for steps and the rest.
fn cronDays(field: []const u8) ?u7 {
    if (std.mem.eql(u8, field, "*") or std.mem.eql(u8, field, "?")) return 0x7f;
    var out: u7 = 0;
    var it = std.mem.splitScalar(u8, field, ',');
    while (it.next()) |item| {
        if (std.mem.indexOfScalar(u8, item, '/') != null) return null;
        const dash = std.mem.indexOfScalar(u8, item, '-');
        const lo = cronDay(if (dash) |d| item[0..d] else item) orelse return null;
        const hi = if (dash) |d| cronDay(item[d + 1 ..]) orelse return null else lo;
        if (hi < lo and !(hi == 0 and dash != null)) return null;
        const top: u8 = if (hi == 0 and lo > 0) 7 else hi;
        var d = lo;
        while (d <= top) : (d += 1) out |= @as(u7, 1) << @intCast((d + 6) % 7);
    }
    return out;
}

fn cronDay(s: []const u8) ?u8 {
    const names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
    for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(s, n)) return @intCast(i);
    const n = std.fmt.parseInt(u8, s, 10) catch return null;
    return if (n <= 7) n else null;
}

fn dayList(a: std.mem.Allocator, days: u7) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (config.day_names, 0..) |n, i| if (days & (@as(u7, 1) << @intCast(i)) != 0) try parts.append(a, n);
    return std.mem.join(a, ",", parts.items);
}

/// " mon,tue" for days that are not every day; "" for every day.
fn daysSuffix(a: std.mem.Allocator, days: u7) ![]const u8 {
    if (days == 0x7f) return "";
    return std.fmt.allocPrint(a, " {s}", .{try dayList(a, days)});
}

fn clock(a: std.mem.Allocator, minutes: i32) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(@divTrunc(minutes, 60))), @as(u32, @intCast(@mod(minutes, 60))) });
}

fn fmtOffset(a: std.mem.Allocator, off: i32) ![]const u8 {
    const abs: u32 = @intCast(if (off < 0) -off else off);
    return std.fmt.allocPrint(a, "{s}{d:0>2}:{d:0>2}", .{ if (off < 0) "-" else "+", abs / 60, abs % 60 });
}

fn everyText(a: std.mem.Allocator, minutes: i64) ![]const u8 {
    if (@mod(minutes, 60) == 0) return std.fmt.allocPrint(a, "{d}h", .{@divTrunc(minutes, 60)});
    return std.fmt.allocPrint(a, "{d}m", .{minutes});
}

/// "a", "a and b", "a, b and c".
fn andList(a: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    if (items.len == 0) return "";
    if (items.len == 1) return items[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", items[0 .. items.len - 1]), items[items.len - 1] });
}

/// 12345 → "12,345".
fn thousands(a: std.mem.Allocator, n: u64) ![]const u8 {
    const digits = try std.fmt.allocPrint(a, "{d}", .{n});
    var out: std.ArrayList(u8) = .empty;
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(a, ',');
        try out.append(a, d);
    }
    return out.items;
}

/// A text cut into parts of at most `max` bytes: at paragraph breaks (a
/// blank line), else at line breaks, else at spaces, else anywhere but
/// inside a UTF-8 character; nothing is left out (the breaks between
/// parts are the only bytes dropped).
pub fn splitParts(a: std.mem.Allocator, text: []const u8, max: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try splitAt(a, text, max, 0, &out);
    return out.items;
}

const seps = [_][]const u8{ "\n\n", "\n", " " };

fn splitAt(a: std.mem.Allocator, text: []const u8, max: usize, level: usize, out: *std.ArrayList([]const u8)) !void {
    if (text.len <= max) return out.append(a, text);
    if (level == seps.len) {
        // no break left: at `max`, never inside a character
        var i: usize = 0;
        while (i < text.len) {
            var end = @min(i + max, text.len);
            while (end < text.len and end > i and (text[end] & 0xC0) == 0x80) end -= 1;
            try out.append(a, text[i..end]);
            i = end;
        }
        return;
    }
    const sep = seps[level];
    var start: usize = 0;
    var cur_end: usize = 0;
    var have = false;
    var it = std.mem.splitSequence(u8, text, sep);
    while (it.next()) |piece| {
        const p_start = @intFromPtr(piece.ptr) - @intFromPtr(text.ptr);
        const p_end = p_start + piece.len;
        if (!have) {
            start = p_start;
            cur_end = p_end;
            have = true;
            continue;
        }
        if (p_end - start <= max) {
            cur_end = p_end;
            continue;
        }
        try splitAt(a, text[start..cur_end], max, level + 1, out);
        start = p_start;
        cur_end = p_end;
    }
    if (have) try splitAt(a, text[start..cur_end], max, level + 1, out);
}

/// The plan as the owner reads it: where the Hermes home is, then Will
/// import (counts, then a line each), Needs you, Not imported.
pub fn planText(a: std.mem.Allocator, s: hermes.Setup, p: *const Plan) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Hermes at {s} (profile {s}).\n", .{ s.home.dir, s.home.profile });
    try out.appendSlice(a, "\nWill import\n");
    var counts: std.ArrayList([]const u8) = .empty;
    var pinned: usize = 0;
    for (p.memory.items) |m| if (m.pinned) {
        pinned += 1;
    };
    if (p.memory.items.len > 0) try counts.append(a, try std.fmt.allocPrint(a, "{d} memory item{s}{s}", .{ p.memory.items.len, if (p.memory.items.len == 1) "" else "s", if (pinned > 0) try std.fmt.allocPrint(a, " ({d} pinned)", .{pinned}) else "" }));
    if (p.skills.items.len > 0) try counts.append(a, try std.fmt.allocPrint(a, "{d} skill{s}", .{ p.skills.items.len, if (p.skills.items.len == 1) "" else "s" }));
    if (p.task_count > 0) try counts.append(a, try std.fmt.allocPrint(a, "{d} task{s}{s}", .{ p.task_count, if (p.task_count == 1) "" else "s", if (p.task_commented > 0) try std.fmt.allocPrint(a, " ({d} commented out)", .{p.task_commented}) else "" }));
    if (p.server_count > 0) try counts.append(a, try std.fmt.allocPrint(a, "{d} MCP server{s}{s}", .{ p.server_count, if (p.server_count == 1) "" else "s", if (p.server_commented > 0) try std.fmt.allocPrint(a, " ({d} commented out)", .{p.server_commented}) else "" }));
    if (p.rule_count > 0) try counts.append(a, try std.fmt.allocPrint(a, "{d} deny rule{s}", .{ p.rule_count, if (p.rule_count == 1) "" else "s" }));
    if (p.model_set) try counts.append(a, "the model");
    if (p.provider_count > 0) try counts.append(a, try std.fmt.allocPrint(a, "{d} provider{s}", .{ p.provider_count, if (p.provider_count == 1) "" else "s" }));
    if (counts.items.len == 0) try out.appendSlice(a, "  Nothing.\n") else try out.print(a, "  {s}\n", .{try std.mem.join(a, ", ", counts.items)});
    for (p.lines.items) |l| if (l.group == .will) try out.print(a, "  {s}\n", .{l.text});
    try out.appendSlice(a, "\nNeeds you\n");
    var any = false;
    // the secret lines first: they are the steps
    for ([_]bool{ true, false }) |secret_first| for (p.lines.items) |l| if (l.group == .needs and std.mem.startsWith(u8, l.text, "harness secret add") == secret_first) {
        try out.print(a, "  {s}\n", .{l.text});
        any = true;
    };
    if (!any) try out.appendSlice(a, "  Nothing.\n");
    try out.appendSlice(a, "\nNot imported\n");
    any = false;
    for (p.lines.items) |l| if (l.group == .not) {
        try out.print(a, "  {s}\n", .{l.text});
        any = true;
    };
    if (!any) try out.appendSlice(a, "  Nothing.\n");
    return out.items;
}

// ---- the command ----

/// The terminal: where the plan is printed, and the question asked
/// (`ask` null: there is no terminal to ask at).
pub const Term = struct {
    ctx: ?*anyopaque,
    print: *const fn (ctx: ?*anyopaque, text: []const u8) void,
    ask: ?*const fn (ctx: ?*anyopaque, question: []const u8) ?[]const u8 = null,
};

pub const Args = struct {
    from: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    dry_run: bool = false,
    yes: bool = false,
    bundled: bool = false,
};

pub const Run = struct {
    io: Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    /// harness's data folder.
    home: []const u8,
    env: *const std.process.Environ.Map,
    term: Term,
    now_s: i64,
    zone_dirs: []const []const u8 = &zones.default_dirs,
    /// harness's stored secrets: masked too.
    stored: []const scrub.Secret = &.{},
};

/// `harness import hermes`: finds and reads the Hermes home, prints the
/// plan, asks (or takes `--yes`), then writes it. 0: done, a dry run, or
/// the owner said no; 1: refused (no Hermes, harness running, …); 2: no
/// terminal to ask at and no `--yes`.
pub fn runImport(r: Run, args: Args) !u8 {
    const a = r.a;
    const core = @import("core.zig");
    const paths = try core.Paths.init(a, r.home);
    if (Io.Dir.cwd().statFile(r.io, paths.config, .{})) |_| {} else |_| {
        say(r, try std.fmt.allocPrint(a, "No data folder at {s}; run: harness init\n", .{r.home}));
        return 1;
    }
    const home = hermes.locate(r.io, a, r.env, args.from, args.profile) catch |e| {
        say(r, switch (e) {
            error.NoHermes => if (args.from) |d| try std.fmt.allocPrint(a, "No Hermes setup at {s}.\n", .{d}) else "No Hermes setup found (HERMES_HOME, or ~/.hermes; or say where: --from DIR).\n",
            error.NoProfile => if (args.profile) |p| try std.fmt.allocPrint(a, "No Hermes profile {s} (its folder is profiles/{s}).\n", .{ p, p }) else "Hermes's active_profile names a profile that isn't in profiles/; say which: --profile NAME (default is the main one).\n",
            else => try std.fmt.allocPrint(a, "Can't read the Hermes setup: {s}\n", .{@errorName(e)}),
        });
        return 1;
    };
    // a real import holds the folder, as undo does: not while harness runs
    var lock: ?Io.File = null;
    defer if (lock) |f| f.close(r.io);
    if (!args.dry_run) {
        lock = core.takeLock(r.io, paths) catch |e| {
            if (e == error.AlreadyRunning) {
                say(r, try std.fmt.allocPrint(a, "harness is running on {s}; stop it first, then import (harness import hermes --dry-run works while it runs).\n", .{r.home}));
                return 1;
            }
            return e;
        };
    }
    const s = try hermes.read(r.io, a, home);
    var store = try memory.Store.load(r.gpa, r.io, paths.memory);
    defer store.deinit();
    store.secrets = r.stored;
    const h = try loadHarness(r.io, a, paths, &store, r.stored);
    var tb: [20]u8 = undefined;
    const iso = util.isoTime(&tb, r.now_s);
    const stamp = try std.fmt.allocPrint(a, "hermes-{s}{s}{s}-{s}{s}{s}", .{ iso[0..4], iso[5..7], iso[8..10], iso[11..13], iso[14..16], iso[17..19] });
    const import_rel = try std.fmt.allocPrint(a, "state/imports/{s}", .{stamp});
    const p = try makePlan(r.io, a, s, h, .{ .now_s = r.now_s, .zone_dirs = r.zone_dirs, .bundled = args.bundled, .local_zone = r.env.get("TZ") orelse "", .import_dir = import_rel });
    const text = try planText(a, s, &p);
    say(r, text);
    if (!writesAnything(&p)) {
        say(r, if (p.suggested.items.len > 0) "\nNothing new to import (the commands Hermes always allowed are in an earlier import's rules.suggested).\n" else "\nNothing new to import.\n");
        return 0;
    }
    if (args.dry_run) {
        say(r, "\nA dry run: nothing written.\n");
        return 0;
    }
    if (!args.yes) {
        const ask = r.term.ask orelse {
            say(r, "\nNot a terminal: add --yes to import.\n");
            return 2;
        };
        const answer = ask(r.term.ctx, "\nImport? [y/N] ") orelse "";
        const w = std.mem.trim(u8, answer, " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(w, "y") or std.ascii.eqlIgnoreCase(w, "yes"))) {
            say(r, "Nothing imported.\n");
            return 0;
        }
    }
    const dir = try std.fs.path.join(a, &.{ paths.state, "imports", stamp });
    const report = try apply(r, paths, dir, &p, &store, text, iso);
    say(r, try std.fmt.allocPrint(a, "\nImported. The report, with how to undo it: {s}\n", .{report}));
    return 0;
}

fn say(r: Run, text: []const u8) void {
    r.term.print(r.term.ctx, text);
}

/// Whether the plan changes anything in harness (the suggestions file
/// alone is no change: it comes with an import, never makes one).
fn writesAnything(p: *const Plan) bool {
    return p.memory.items.len > 0 or p.skills.items.len > 0 or p.tasks.items.len > 0 or p.mcp.items.len > 0 or p.rules.items.len > 0 or p.config_ini != null;
}

/// harness's side as it is now: its settings, its tasks (do_file read),
/// its memory and its skills with their hashes.
pub fn loadHarness(io: Io, a: std.mem.Allocator, paths: @import("core.zig").Paths, store: *memory.Store, stored: []const scrub.Secret) !Harness {
    const read = struct {
        fn f(i: Io, al: std.mem.Allocator, p: []const u8) []const u8 {
            return Io.Dir.cwd().readFileAlloc(i, p, al, .limited(1 << 20)) catch "";
        }
    }.f;
    var h: Harness = .{
        .config_text = read(io, a, paths.config),
        .tasks_text = read(io, a, paths.tasks),
        .triggers_text = read(io, a, paths.triggers),
        .briefs_text = read(io, a, paths.briefs),
        .mcp_text = read(io, a, paths.mcp),
        .rules_text = read(io, a, paths.rules),
        .memory = store,
        .stored = stored,
    };
    if (config.parseTasks(a, h.tasks_text)) |tasks| {
        _ = @import("taskfiles.zig").resolve(io, a, paths.tasks_dir, tasks) catch null;
        h.tasks = tasks;
    } else |_| {}
    var installed: std.ArrayList(Installed) = .empty;
    for (try skills.list(a, io, paths.skills)) |sk| {
        const hash = skillsrc.hashFolder(io, a, try std.fs.path.join(a, &.{ paths.skills, sk.name })) catch continue;
        try installed.append(a, .{ .name = sk.name, .hash = try a.dupe(u8, &hash) });
    }
    // a folder harness can't list (no frontmatter) still takes its name
    if (Io.Dir.cwd().openDir(io, paths.skills, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory or e.name[0] == '.') continue;
            for (installed.items) |ins| {
                if (std.mem.eql(u8, ins.name, e.name)) break;
            } else try installed.append(a, .{ .name = try a.dupe(u8, e.name), .hash = "" });
        }
    } else |_| {}
    h.skills = installed.items;
    return h;
}

/// Writes the plan: the copies first, then each file whole, the memory
/// items, the skills, the log line and the report (its path returned).
fn apply(r: Run, paths: @import("core.zig").Paths, dir: []const u8, p: *const Plan, store: *memory.Store, plan_text: []const u8, iso: []const u8) ![]const u8 {
    const a = r.a;
    const cwd = Io.Dir.cwd();
    const before = try std.fs.path.join(a, &.{ dir, "before" });
    try cwd.createDirPath(r.io, before);
    var undo: std.ArrayList(u8) = .empty;
    // every harness file it changes, copied as it was
    const Change = struct { path: []const u8, name: []const u8, add: []const u8, whole: ?[]const u8 = null };
    const changes = [_]Change{
        .{ .path = paths.tasks, .name = "tasks.ini", .add = p.tasks.items },
        .{ .path = paths.mcp, .name = "mcp.ini", .add = p.mcp.items },
        .{ .path = paths.rules, .name = "rules", .add = p.rules.items },
        .{ .path = paths.config, .name = "config.ini", .add = "", .whole = p.config_ini },
    };
    for (changes) |ch| {
        if (ch.add.len == 0 and ch.whole == null) continue;
        if (cwd.readFileAlloc(r.io, ch.path, a, .limited(1 << 20))) |old| {
            try util.writeReplace(r.io, try std.fs.path.join(a, &.{ before, ch.name }), old);
            try undo.print(a, "- {s}: put back {s}{s}before{s}{s}\n", .{ ch.name, dir, std.fs.path.sep_str, std.fs.path.sep_str, ch.name });
        } else |_| try undo.print(a, "- {s} didn't exist before: remove it\n", .{ch.name});
    }
    for (changes) |ch| {
        if (ch.whole) |w| {
            try util.writeReplace(r.io, ch.path, w);
        } else if (ch.add.len > 0) {
            const old = cwd.readFileAlloc(r.io, ch.path, a, .limited(1 << 20)) catch "";
            try util.writeReplace(r.io, ch.path, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ old, if (old.len > 0 and old[old.len - 1] != '\n') "\n" else "", ch.add }));
        }
    }
    // tasks' own files, in the guarded tasks/ folder
    if (p.task_files.items.len > 0) {
        _ = try cwd.createDirPathStatus(r.io, paths.tasks_dir, @import("agents.zig").private_dir);
        for (p.task_files.items) |tf| {
            try util.writeReplace(r.io, try std.fs.path.join(a, &.{ paths.tasks_dir, tf.name }), tf.text);
            try undo.print(a, "- remove tasks{s}{s}\n", .{ std.fs.path.sep_str, tf.name });
        }
    }
    if (p.suggested.items.len > 0) try util.writeReplace(r.io, try std.fs.path.join(a, &.{ dir, "rules.suggested" }), p.suggested.items);
    // memory: the agent's words, dated back; SOUL.md pinned
    var ids: std.ArrayList([]const u8) = .empty;
    for (p.memory.items) |m| {
        const res = store.addFrom(m.body, null, p.mention_s, .other) catch |e| switch (e) {
            error.EmptyMemory => continue,
            else => return e,
        };
        if (res.merged) continue;
        if (m.pinned) _ = try store.setPinned(res.id, true);
        try ids.append(a, try a.dupe(u8, res.id));
        try undo.print(a, "- harness memory forget {s}\n", .{res.id});
    }
    // skills, each with its source line
    var skill_names: std.ArrayList([]const u8) = .empty;
    for (p.skills.items) |sk| {
        skillsrc.install(r.io, a, paths.skills, sk.name, sk.files) catch |e| switch (e) {
            error.Exists => continue,
            else => return e,
        };
        try skillsrc.putSource(r.io, a, paths.skills, .{ .name = sk.name, .source = sk.source, .pin = "-", .hash = &sk.hash, .time = iso });
        try skill_names.append(a, sk.name);
        try undo.print(a, "- harness skill rm {s}\n", .{sk.name});
    }
    // the log: what kind of things and how many, no values
    var log = try @import("log.zig").Log.open(r.gpa, r.io, paths.log);
    defer log.close();
    try log.setSecrets(r.stored);
    try log.write(.config, false, .{ .event = "import", .from = "hermes", .memory = ids.items.len, .skills = skill_names.items.len, .tasks = p.task_names.items.len, .servers = p.server_names.items.len, .rules = p.rule_count, .config = p.config_ini != null });
    // the report
    var rep: std.ArrayList(u8) = .empty;
    try rep.print(a, "# Imported from Hermes, {s}\n\n```\n{s}```\n\n", .{ iso, plan_text });
    try rep.print(a, "New memory items: {s}\n", .{if (ids.items.len > 0) try std.mem.join(a, ", ", ids.items) else "none"});
    try rep.print(a, "New skills: {s}\n", .{if (skill_names.items.len > 0) try std.mem.join(a, ", ", skill_names.items) else "none"});
    try rep.print(a, "New tasks: {s}\n", .{if (p.task_names.items.len > 0) try std.mem.join(a, ", ", p.task_names.items) else "none"});
    try rep.print(a, "New MCP servers: {s}\n\n", .{if (p.server_names.items.len > 0) try std.mem.join(a, ", ", p.server_names.items) else "none"});
    try rep.print(a, "## To undo it\n\nWith harness stopped:\n\n{s}", .{undo.items});
    const report = try std.fs.path.join(a, &.{ dir, "report.md" });
    try util.writeReplace(r.io, report, rep.items);
    return report;
}

/// What `harness init` says when there is a Hermes setup to import, or null.
pub fn noticeFor(io: Io, a: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    const home = hermes.locate(io, a, env, null, null) catch |e| switch (e) {
        error.NoProfile => blk: {
            const root = env.get("HERMES_HOME") orelse hermes.defaultRoot(a, env, builtin.os.tag) orelse return null;
            break :blk hermes.Home{ .root = root, .dir = root, .profile = "default" };
        },
        else => return null,
    };
    for ([_][]const u8{ "config.yaml", "memories", "SOUL.md", "cron", "skills" }) |n| {
        const p = std.fs.path.join(a, &.{ home.dir, n }) catch return null;
        if (Io.Dir.cwd().statFile(io, p, .{})) |_| {
            return std.fmt.allocPrint(a, "Hermes is set up at {s}. To see what would come over: harness import hermes --dry-run", .{home.root}) catch null;
        } else |_| {}
    }
    return null;
}

/// `import hermes [--from DIR] [--profile NAME] [--dry-run] [--yes] [--bundled]`; null when the words don't read.
pub fn parseArgs(rest: []const []const u8) ?Args {
    if (rest.len == 0 or !std.mem.eql(u8, rest[0], "hermes")) return null;
    var out: Args = .{};
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const w = rest[i];
        if (std.mem.eql(u8, w, "--dry-run")) {
            out.dry_run = true;
        } else if (std.mem.eql(u8, w, "--yes")) {
            out.yes = true;
        } else if (std.mem.eql(u8, w, "--bundled")) {
            out.bundled = true;
        } else if (std.mem.eql(u8, w, "--from") or std.mem.eql(u8, w, "--profile")) {
            i += 1;
            if (i >= rest.len or rest[i].len == 0 or rest[i][0] == '-') return null;
            if (std.mem.eql(u8, w, "--from")) {
                if (out.from != null) return null;
                out.from = rest[i];
            } else {
                if (out.profile != null) return null;
                out.profile = rest[i];
            }
        } else return null;
    }
    return out;
}

// ---- tests ----

const t = std.testing;

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

/// 2026-11-24 12:00 UTC.
fn testNow() i64 {
    return util.daysFromCivil(2026, 11, 24) * 86400 + 12 * 3600;
}

const harness_config = "[chat]\nutc_offset = +01:00\n";

/// The full fixture home, zone files for its zones, an empty memory.
pub const Tf = struct {
    f: hermes.Fixture,
    zones: []const u8,
    store: memory.Store,

    pub fn init(tf: *Tf, crlf: bool) !void {
        try tf.f.init();
        try tf.f.full(crlf);
        const a = tf.f.a();
        for ([_][2][]const u8{ .{ "Europe/Warsaw", "CET-1CEST,M3.5.0,M10.5.0/3" }, .{ "Asia/Tokyo", "JST-9" }, .{ "Test/Plus2", "<+02>-2" } }) |z| {
            const p = try std.fs.path.join(a, &.{ "zoneinfo", z[0] });
            try tf.f.tmp.dir.createDirPath(t.io, std.fs.path.dirname(p).?);
            try tf.f.tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = try zones.tzif(a, &.{}, &.{.{ .off = 3600, .dst = false }}, z[1]) });
        }
        tf.zones = try std.fs.path.join(a, &.{ tf.f.base, "zoneinfo" });
        tf.store = try memory.Store.load(t.allocator, t.io, try std.fs.path.join(a, &.{ tf.f.base, "harness-memory" }));
    }

    pub fn deinit(tf: *Tf) void {
        tf.store.deinit();
        tf.f.deinit();
    }

    pub fn setup(tf: *Tf) !hermes.Setup {
        return hermes.read(t.io, tf.f.a(), .{ .root = tf.f.root, .dir = tf.f.root, .profile = "default" });
    }

    pub fn plan(tf: *Tf, h: Harness, bundled: bool) !Plan {
        var hh = h;
        if (hh.config_text.len == 0) hh.config_text = harness_config;
        hh.memory = &tf.store;
        return makePlan(t.io, tf.f.a(), try tf.setup(), hh, .{ .now_s = testNow(), .zone_dirs = &.{tf.zones}, .bundled = bundled });
    }
};

fn section(text: []const u8, header: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, header) orelse return "";
    const rest = text[at..];
    const end = std.mem.indexOf(u8, rest[header.len..], "\n[") orelse std.mem.indexOf(u8, rest[header.len..], "\n; [") orelse rest.len - header.len;
    return rest[0 .. header.len + end];
}

test "entries_become_items_dated_60_days_back" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    try t.expectEqual(6, p.memory.items.len);
    try t.expectEqualStrings("Owner's server is at home.example.com.", p.memory.items[0].body);
    try t.expectEqualStrings("MEMORY.md", p.memory.items[0].from);
    try t.expect(contains(p.memory.items[2].body, "[secret:OPENROUTER_API_KEY]"));
    try t.expect(!contains(p.memory.items[2].body, "sk-fixture"));
    try t.expectEqualStrings("Lives in Kraków.", p.memory.items[3].body);
    try t.expectEqualStrings("USER.md", p.memory.items[3].from);
    try t.expectEqual(testNow() - back_days * 86400, p.mention_s);
    try t.expect(p.has(.will, "memory: Lives in Kraków. (USER.md)"));
}

test "a_long_entry_is_split_at_paragraphs_never_cut" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const para = struct {
        fn make(al: std.mem.Allocator, c: u8, n: usize) ![]u8 {
            const b = try al.alloc(u8, n);
            for (b, 0..) |*x, i| x.* = if (i % 50 == 49) ' ' else c;
            return b;
        }
    }.make;
    // three paragraphs of 1,500 bytes: one each
    const text = try std.mem.join(a, "\n\n", &.{ try para(a, 'a', 1500), try para(a, 'b', 1500), try para(a, 'c', 1500) });
    const parts = try splitParts(a, text, 2000);
    try t.expectEqual(3, parts.len);
    try t.expectEqualStrings(text, try std.mem.join(a, "\n\n", parts));
    // small paragraphs go together
    const small = try std.mem.join(a, "\n\n", &.{ try para(a, 'a', 600), try para(a, 'b', 600), try para(a, 'c', 1500) });
    const two = try splitParts(a, small, 2000);
    try t.expectEqual(2, two.len);
    try t.expectEqualStrings(small, try std.mem.join(a, "\n\n", two));
    // one paragraph over the cap: at its line breaks, then at spaces; nothing lost
    var lines: std.ArrayList(u8) = .empty;
    for (0..45) |_| {
        try lines.appendSlice(a, try para(a, 'x', 99));
        try lines.append(a, '\n');
    }
    const long = std.mem.trimEnd(u8, lines.items, "\n");
    const lp = try splitParts(a, long, 2000);
    for (lp) |x| try t.expect(x.len <= 2000);
    try t.expectEqualStrings(long, try std.mem.join(a, "\n", lp));
    const word = try a.alloc(u8, 4100);
    @memset(word, 'w');
    const wp = try splitParts(a, word, 2000);
    try t.expectEqual(3, wp.len);
    try t.expectEqualStrings(word, try std.mem.concat(a, u8, wp));
    // never inside a UTF-8 character
    const ls = try std.mem.concat(a, u8, &.{ try a.dupe(u8, word[0..1999]), "ł", "abc" });
    for (try splitParts(a, ls, 2000)) |x| try t.expect(std.unicode.utf8ValidateSlice(x));
}

test "entries_already_in_memory_are_already_there" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const kept = try tf.store.add("The owner lives in Kraków", null, testNow() - 86400);
    const p = try tf.plan(.{}, false);
    try t.expectEqual(5, p.memory.items.len);
    for (p.memory.items) |m| try t.expect(!contains(m.body, "Lives in Kraków"));
    try t.expect(p.has(.not, try std.fmt.allocPrint(tf.f.a(), "memory: Lives in Kraków. (USER.md): already in memory as {s}", .{kept.id})));
}

test "a_stock_soul_is_skipped_an_edited_one_pinned_a_long_one_listed" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    var p = try tf.plan(.{}, false);
    const soul = p.memory.items[p.memory.items.len - 1];
    try t.expect(soul.pinned);
    try t.expectEqualStrings("How to talk with me: Speak plainly. Use metric units.", soul.body);
    try t.expect(p.has(.will, "memory, pinned: How to talk with me: Speak plainly. Use metric units. (SOUL.md)"));
    try tf.f.put("SOUL.md", hermes.stock_soul ++ "\n");
    p = try tf.plan(.{}, false);
    for (p.memory.items) |m| try t.expect(!m.pinned);
    try t.expect(p.has(.not, "SOUL.md: Hermes's own text, never edited"));
    const big = try tf.f.a().alloc(u8, 2500);
    @memset(big, 'p');
    try tf.f.put("SOUL.md", big);
    p = try tf.plan(.{}, false);
    for (p.memory.items) |m| try t.expect(!m.pinned);
    try t.expect(p.has(.not, "SOUL.md: 2,500 bytes, over memory's 2,000: to keep it, make it agents/main.md by hand (that file replaces harness's built-in instructions)"));
}

test "skills_are_flattened_renamed_and_filtered" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    var p = try tf.plan(.{ .skills = &.{.{ .name = "claw", .hash = "different" }} }, false);
    var names: std.ArrayList([]const u8) = .empty;
    for (p.skills.items) |sk| try names.append(tf.f.a(), sk.name);
    try t.expectEqualStrings("deploy-helper-v2,pdf-tools,edited-bundle", try std.mem.join(tf.f.a(), ",", names.items));
    const deploy = p.skills.items[0];
    try t.expectEqualStrings("hermes", deploy.source);
    for (deploy.files) |fl| if (std.mem.eql(u8, fl.rel, "SKILL.md")) try t.expect(contains(fl.data, "name: deploy-helper-v2\n"));
    try t.expect(p.has(.will, "skill deploy-helper-v2 (devops/deploy.helper_v2): renamed from deploy.helper_v2; Hermes's fields kept in it: platforms, required_environment_variables"));
    try t.expectEqualStrings("anthropics/skills/skills/pdf", p.skills.items[1].source);
    try t.expect(p.has(.will, "skill pdf-tools (docs/pdf-tools): from anthropics/skills/skills/pdf; harness skill update works on it"));
    try t.expect(p.has(.not, "skill claw (claw): a skill claw is in harness already"));
    try t.expect(p.has(.not, "skill noisy (noisy): disabled in Hermes; harness has no off switch for a skill"));
    try t.expect(p.has(.not, "skill big (big): SKILL.md is "));
    try t.expect(p.has(.not, "Hermes's own skills, never edited (1): arxiv (harness import hermes --bundled brings them)"));
    // the same skill already there; --bundled brings Hermes's own
    const claw_hash = blk: {
        const s = try tf.setup();
        for (s.skills) |sk| if (std.mem.eql(u8, sk.name, "claw")) break :blk try skillsrc.hashFolder(t.io, tf.f.a(), sk.folder);
        unreachable;
    };
    p = try tf.plan(.{ .skills = &.{.{ .name = "claw", .hash = &claw_hash }} }, true);
    try t.expect(p.has(.not, "skill claw (claw): already there"));
    try t.expect(p.has(.will, "skill arxiv (research/arxiv): one of Hermes's own"));
    // from a hub that isn't GitHub: no source to update from
    p = try tf.plan(.{}, false);
    try t.expect(p.has(.will, "skill claw (claw): from clawhub; harness can't update it"));
}

test "every_schedule_form_maps_or_says_why" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    const tasks = p.tasks.items;
    try t.expect(contains(tasks, "[morning-brief]\nat = 07:00\ndays = mon,tue,wed,thu,fri\ndo = Use the skill arxiv. Summarise my unread mail and the weather.\n"));
    try t.expect(p.has(.will, "task morning-brief: at 07:00 mon,tue,wed,thu,fri"));
    try t.expect(p.has(.will, "Morning brief"));
    try t.expect(p.has(.not, "task fast (Hermes job fast): every 2m; harness's every is at least 5m"));
    try t.expect(p.has(.not, "task once (Hermes job once): runs once (2026-12-01T09:00:00+01:00); harness's tasks repeat"));
    try t.expect(contains(tasks, "; [queue]\n; every = 4h\n; do = Look at the queue\n"));
    try t.expect(p.has(.will, "task queue: every 4h (commented out: paused in Hermes)"));
    try t.expect(p.has(.needs, "harness's every isn't aligned to the clock hour and varies by up to 10%"));
    try t.expect(p.has(.not, "task odd (Hermes job odd): cron */15 9-17 * * * isn't a time on days or every N hours"));
    try t.expect(p.has(.not, "task backup (Hermes job backup): runs a script (backup.sh) unattended; set it up as a trigger by hand"));
    try t.expect(contains(tasks, "; [saver]\n"));
    try t.expect(p.has(.will, "task saver: every 1h (commented out: local in Hermes: its answer was saved, not sent; harness sends a task's answer)"));
    try t.expect(contains(tasks, "; [discord-only]\n"));
    try t.expect(p.has(.will, "commented out: delivered to discord, which harness doesn't reach"));
    // what doesn't come over, named
    try t.expect(p.has(.will, "task poll: every 30m; not kept: repeat (10 more runs), model gpt-5; the chat -100123 and thread 17 aren't kept: it posts to your main conversation"));
    try t.expect(p.has(.will, "not kept: workdir, toolsets (add deny rules under [schedule:weekly]), context_from"));
    try t.expect(p.has(.needs, "Imported tasks run with harness's rules"));
}

test "a_prompt_tasks_ini_would_cut_goes_to_its_own_file" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    try t.expect(contains(p.tasks.items, "[poll]\nevery = 30m\ndo_file = poll.md\n"));
    try t.expect(contains(p.tasks.items, "do_file = weekly.md\n"));
    var found: usize = 0;
    for (p.task_files.items) |tf2| {
        if (std.mem.eql(u8, tf2.name, "poll.md")) {
            try t.expectEqualStrings("Check the build ; report failures #ci", tf2.text);
            found += 1;
        }
        if (std.mem.eql(u8, tf2.name, "weekly.md")) {
            try t.expectEqualStrings("Line one\nLine two", tf2.text);
            found += 1;
        }
    }
    try t.expectEqual(2, found);
    for ([_][]const u8{ "plain line", "two words" }) |ok| try t.expect(fitsOneLine(ok));
    for ([_][]const u8{ "a ;b", "a #b", "a\tb ;", "two\nlines", " lead", "trail ", ";start", "#start", "" }) |bad| try t.expect(!fitsOneLine(bad));
}

test "a_converted_time_moves_its_days" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    // Monday 00:30 in Tokyo (+09:00) is Sunday 16:30 at +01:00
    const p = try tf.plan(.{}, false);
    try t.expect(contains(p.tasks.items, "[weekly]\nat = 16:30\ndays = sun\n"));
    try t.expect(p.has(.will, "task weekly: at 16:30 sun (00:30 mon in Asia/Tokyo, +09:00 today, is 16:30 sun at harness's +01:00)"));
    try t.expect(p.has(.needs, "harness's utc_offset (+01:00) doesn't follow daylight saving"));
    // the other way: 23:30 at +00:00 is 00:30 the next day at +01:00
    try t.expectEqual(Shifted{ .minutes = 30, .days = 0b0000010 }, shift(23 * 60 + 30, 0b0000001, 0, 60));
    try t.expectEqual(Shifted{ .minutes = 22 * 60 + 30, .days = 0b1000000 }, shift(30, 0b0000001, 120, 0));
    try t.expectEqual(Shifted{ .minutes = 9 * 60, .days = 0x7f }, shift(9 * 60, 0x7f, 60, 60));
}

test "deliveries_main_or_commented" {
    for ([_][]const u8{ "origin", "telegram", "telegram:-100:3", "all", "local,origin", "discord, telegram" }) |d| try t.expect(delivery(d).main);
    try t.expect(!delivery(null).main);
    try t.expect(!delivery("local").main);
    try t.expect(!delivery("").main);
    try t.expect(!delivery("bot-chat").main);
    try t.expect(!delivery("room:abc").main);
    try t.expect(!delivery("slack,discord").main);
    try t.expectEqualStrings("-100", delivery("telegram:-100:3").chat);
    try t.expectEqualStrings("3", delivery("telegram:-100:3").thread);
}

test "a_task_name_taken_gets_hermes" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    var p = try tf.plan(.{ .tasks_text = "[poll]\nevery = 1h\ndo = Something else.\n", .tasks = &.{.{ .name = "poll", .do = "Something else." }}, .triggers_text = "[morning-brief]\nat = 08:00\nsay = hi\n" }, false);
    try t.expect(contains(p.tasks.items, "[poll-hermes]\nevery = 30m\ndo_file = poll-hermes.md\n"));
    try t.expect(contains(p.tasks.items, "[morning-brief-hermes]\n"));
    // run again: the same name and prompt are already there
    p = try tf.plan(.{ .tasks_text = "[poll]\nevery = 30m\ndo_file = poll.md\n", .tasks = &.{.{ .name = "poll", .do = "Check the build ; report failures #ci", .do_file = "poll.md" }} }, false);
    try t.expect(!contains(p.tasks.items, "[poll"));
    try t.expect(p.has(.not, "task poll (Hermes job poll): already there"));
    const a = tf.f.a();
    try t.expectEqualStrings("brief-2", sectionName(a, &.{"brief"}, "brief-2"));
    try t.expectEqualStrings("brief-hermes-2", sectionName(a, &.{ "brief", "brief-hermes" }, "Brief"));
    try t.expectEqualStrings("poranny-przegl-d", sectionName(a, &.{}, "Poranny przegląd"));
    try t.expectEqualStrings("hermes-job", sectionName(a, &.{}, "!!!"));
}

test "every_mcp_server_shape_maps" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{ .mcp_text = "[sleepy]\ncommand = other\n" }, false);
    const m = p.mcp.items;
    try t.expect(contains(m, "[github]\ncommand = npx -y @modelcontextprotocol/server-github\nsecret = GITHUB_PERSONAL_ACCESS_TOKEN:github_token\nenv = LOG_LEVEL=info\n"));
    try t.expect(contains(m, "[files]\ncommand = /opt/mcp/files --root \"/home/me/My Documents\"\nsecret = FILES_SECRET:files_secret\n"));
    try t.expect(contains(m, "[linear]\nurl = https://mcp.linear.app/mcp\ntoken = linear_api_key\nheader = X-Workspace: acme\n"));
    try t.expect(contains(m, "[notion]\nurl = https://mcp.notion.com/mcp\nlogin = oauth\n"));
    try t.expect(contains(m, "; [weather]\n; url = https://weather.example.com/mcp\n"));
    try t.expect(!contains(m, "sk-fixture-weather"));
    try t.expect(p.has(.will, "server weather (commented out: it needs header X-API-Key, a secret, and mcp.ini has no secret header)"));
    try t.expect(p.has(.not, "server old-sse: it speaks SSE; harness speaks Streamable HTTP only"));
    try t.expect(p.has(.needs, "picky: Hermes offered only its tools read_*, search; harness offers all of them"));
    try t.expect(p.has(.not, "server sleepy: a server sleepy is in mcp.ini already"));
    try t.expect(p.has(.needs, "harness mcp login notion"));
    try t.expect(p.has(.needs, "harness secret add github_token"));
    try t.expect(p.has(.needs, "the value of GITHUB_TOKEN in Hermes's .env"));
    try t.expect(p.has(.needs, "harness secret add files_secret"));
    try t.expect(p.has(.needs, "mcp_servers.files.env.FILES_SECRET in Hermes's config.yaml"));
    try t.expect(p.has(.needs, "harness secret add linear_api_key"));
    // every section reads as mcp.ini
    _ = try mcp.parseConfig(tf.f.a(), m);
    // excluded tools: deny rules, the globs only narrowing
    try t.expect(contains(p.rules.items, "deny mcp github/delete_repository *\n"));
    try t.expect(contains(p.rules.items, "deny mcp github/*_admin_* *\n"));
}

test "deny_patterns_narrow_only" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{ .rules_text = "deny shell git push --force*\n" }, false);
    const r = p.rules.items;
    try t.expect(std.mem.startsWith(u8, r, "\n[all]\n# from Hermes"));
    try t.expect(contains(r, "deny shell rm -rf /*\n"));
    try t.expect(!contains(r, "git push --force"));
    try t.expect(contains(r, "deny shell curl *ttp*\n"));
    try t.expect(contains(r, "deny shell shutdown **\n"));
    try t.expect(p.has(.will, "matched case-insensitively in Hermes; harness matches them as written"));
    try t.expect(p.has(.not, "deny rule git push --force*: already there"));
    _ = try rules.parse(tf.f.a(), r);
}

test "the_allowlist_is_only_suggested" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    try t.expect(contains(p.suggested.items, "# allow shell git status*\n"));
    try t.expect(!contains(p.rules.items, "allow"));
    try t.expect(p.has(.needs, "Hermes always allowed: recursive delete. harness asks for every shell command unless a rule allows it."));
    try t.expect(p.has(.needs, "rules.suggested"));
    // every line of it is a comment
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, p.suggested.items, "\n"), '\n');
    while (it.next()) |l| try t.expect(l.len == 0 or l[0] == '#');
}

test "providers_map_to_presets_and_sections" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    const c = p.config_ini.?;
    try t.expect(contains(c, "[model]\nprovider = openrouter\nmodel = anthropic/claude-sonnet-4\n"));
    try t.expect(contains(c, "[provider local-llm]\napi = openai\nurl = http://localhost:8080/v1\nkey = local-llm\n"));
    try t.expect(contains(c, "[provider work-gw]\napi = anthropic\nurl = https://gw.example.com/anthropic\nkey = work-gw\n"));
    try t.expect(p.has(.not, "provider codex: it speaks codex_responses; harness speaks the OpenAI and Anthropic formats"));
    try t.expect(p.has(.needs, "harness secret add openrouter"));
    try t.expect(p.has(.needs, "the value of OPENROUTER_API_KEY in Hermes's .env"));
    try t.expect(p.has(.needs, "harness secret add local-llm"));
    try t.expect(p.has(.needs, "harness secret add work-gw"));
    try t.expect(p.has(.needs, "memory_model and worker_model"));
    _ = try config.parse(tf.f.a(), c);
    try t.expect(!contains(c, "sk-fixture"));
}

test "the_model_is_kept_when_harness_has_a_provider" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{ .config_text = "[model]\nprovider = anthropic\nmodel = claude-opus\n[chat]\nutc_offset = +01:00\n" }, false);
    try t.expect(p.has(.not, "model openrouter: anthropic/claude-sonnet-4: harness has its provider set (anthropic); not changed"));
    if (p.config_ini) |c| try t.expect(contains(c, "provider = anthropic\nmodel = claude-opus\n"));
}

test "telegram_is_explained_not_moved" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    try t.expect(p.has(.needs, "Telegram: one bot can't be read by two agents at once"));
    for (p.secrets.items) |sl| try t.expect(!std.mem.eql(u8, sl.name, "telegram"));
}

test "external_dirs_and_skill_config_are_listed" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    try t.expect(p.has(.not, "skills in other folders Hermes read: ~/.agents/skills"));
    try t.expect(p.has(.not, "skill settings (skills.config): wiki.path = ~/wiki"));
}

test "other_hermes_parts_are_named_with_their_paths" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const p = try tf.plan(.{}, false);
    try t.expect(p.has(.not, try std.fmt.allocPrint(tf.f.a(), "conversations: {s} stays in Hermes", .{tf.f.path("state.db")})));
    try t.expect(p.has(.not, "external memory, honcho"));
    try t.expect(p.has(.not, ".env keys nothing here uses: API_SERVER_URL"));
}

test "the_plan_has_three_groups_in_order" {
    var tf: Tf = undefined;
    try tf.init(false);
    defer tf.deinit();
    const s = try tf.setup();
    var hh: Harness = .{ .config_text = harness_config, .memory = &tf.store };
    _ = &hh;
    const p = try makePlan(t.io, tf.f.a(), s, hh, .{ .now_s = testNow(), .zone_dirs = &.{tf.zones} });
    const text = try planText(tf.f.a(), s, &p);
    const will = std.mem.indexOf(u8, text, "\nWill import\n").?;
    const needs = std.mem.indexOf(u8, text, "\nNeeds you\n").?;
    const not = std.mem.indexOf(u8, text, "\nNot imported\n").?;
    try t.expect(will < needs and needs < not);
    try t.expect(contains(text, "6 memory items (1 pinned), 4 skills, 6 tasks (3 commented out), 7 MCP servers (2 commented out), 6 deny rules, the model"));
    for (hermes.Fixture.secrets) |v| try t.expect(!contains(text, v));
}

// ---- writing it: tests ----

/// What the command says and is answered, for the tests.
const Talk = struct {
    out: std.ArrayList(u8) = .empty,
    answer: ?[]const u8 = null,
    a: std.mem.Allocator,

    fn print(ctx: ?*anyopaque, text: []const u8) void {
        const tk: *Talk = @ptrCast(@alignCast(ctx.?));
        tk.out.appendSlice(tk.a, text) catch {};
    }

    fn ask(ctx: ?*anyopaque, question: []const u8) ?[]const u8 {
        const tk: *Talk = @ptrCast(@alignCast(ctx.?));
        tk.out.appendSlice(tk.a, question) catch {};
        return tk.answer;
    }

    fn term(tk: *Talk) Term {
        return .{ .ctx = tk, .print = print, .ask = if (tk.answer != null) ask else null };
    }
};

/// A harness home beside the fixture's Hermes home, and a run in it.
const Rx = struct {
    tf: Tf,
    home: []const u8,
    env: std.process.Environ.Map,
    talk: Talk,

    fn init(rx: *Rx, crlf: bool) !void {
        try rx.tf.init(crlf);
        const a = rx.tf.f.a();
        rx.home = try std.fs.path.join(a, &.{ rx.tf.f.base, "harness" });
        try @import("core.zig").initHome(t.io, a, rx.home);
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ rx.home, "config.ini" }), .data = harness_config });
        rx.env = std.process.Environ.Map.init(a);
        rx.talk = .{ .a = a };
    }

    fn deinit(rx: *Rx) void {
        rx.tf.deinit();
    }

    fn run(rx: *Rx, args: Args) !u8 {
        var x = args;
        if (x.from == null) x.from = rx.tf.f.root;
        return runImport(.{ .io = t.io, .gpa = t.allocator, .a = rx.tf.f.a(), .home = rx.home, .env = &rx.env, .term = rx.talk.term(), .now_s = testNow(), .zone_dirs = &.{rx.tf.zones} }, x);
    }

    fn file(rx: *Rx, rel: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(rx.tf.f.a(), &.{ rx.home, rel }), rx.tf.f.a(), .unlimited);
    }

    fn exists(rx: *Rx, rel: []const u8) bool {
        _ = Io.Dir.cwd().statFile(t.io, std.fs.path.join(rx.tf.f.a(), &.{ rx.home, rel }) catch return false, .{}) catch return false;
        return true;
    }

    /// The import's own folder (state/imports/hermes-…).
    fn importDir(rx: *Rx) ![]const u8 {
        const p = try std.fs.path.join(rx.tf.f.a(), &.{ rx.home, "state", "imports" });
        var d = try Io.Dir.cwd().openDir(t.io, p, .{ .iterate = true });
        defer d.close(t.io);
        var it = d.iterate();
        while (try it.next(t.io)) |e| if (std.mem.startsWith(u8, e.name, "hermes-")) return std.fs.path.join(rx.tf.f.a(), &.{ "state", "imports", try rx.tf.f.a().dupe(u8, e.name) });
        return error.FileNotFound;
    }

    fn memoryCount(rx: *Rx) !usize {
        var s = try memory.Store.load(t.allocator, t.io, try std.fs.path.join(rx.tf.f.a(), &.{ rx.home, "memory" }));
        defer s.deinit();
        return s.items.items.len;
    }
};

/// Every file under `dir`, read whole into one text (to look for values in).
fn allText(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var d = try Io.Dir.cwd().openDir(t.io, dir, .{ .iterate = true });
    defer d.close(t.io);
    var w = try d.walk(a);
    defer w.deinit();
    while (try w.next(t.io)) |e| {
        if (e.kind != .file) continue;
        const data = d.readFileAlloc(t.io, e.path, a, .unlimited) catch continue;
        try out.appendSlice(a, data);
    }
    return out.items;
}

test "import_writes_what_maps_and_leaves_a_report" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    const before_tasks = try rx.file("tasks.ini");
    try t.expectEqual(0, try rx.run(.{ .yes = true }));
    try t.expect(contains(rx.talk.out.items, "Will import"));
    const tasks = try rx.file("tasks.ini");
    try t.expect(std.mem.startsWith(u8, tasks, before_tasks));
    try t.expect(contains(tasks, "[morning-brief]\nat = 07:00\n"));
    try t.expectEqualStrings("Check the build ; report failures #ci", try rx.file("tasks" ++ std.fs.path.sep_str ++ "poll.md"));
    _ = try config.parseTasks(rx.tf.f.a(), tasks);
    try t.expect(contains(try rx.file("mcp.ini"), "[github]\n"));
    try t.expect(contains(try rx.file("rules"), "deny shell rm -rf /*\n"));
    try t.expect(contains(try rx.file("config.ini"), "provider = openrouter\n"));
    try t.expect(contains(try rx.file("skills" ++ std.fs.path.sep_str ++ "deploy-helper-v2" ++ std.fs.path.sep_str ++ "SKILL.md"), "name: deploy-helper-v2\n"));
    try t.expect(rx.exists("skills" ++ std.fs.path.sep_str ++ "deploy-helper-v2" ++ std.fs.path.sep_str ++ "scripts" ++ std.fs.path.sep_str ++ "run.sh"));
    const sources = try rx.file("skills" ++ std.fs.path.sep_str ++ ".sources");
    try t.expect(contains(sources, "pdf-tools\tanthropics/skills/skills/pdf\t-\t"));
    try t.expect(contains(sources, "deploy-helper-v2\thermes\t-\t"));
    try t.expectEqual(6, try rx.memoryCount());
    // the copies taken first, the suggestions, the report
    const dir = try rx.importDir();
    for ([_][]const u8{ "tasks.ini", "rules", "config.ini" }) |n| {
        try t.expect(rx.exists(try std.fs.path.join(rx.tf.f.a(), &.{ dir, "before", n })));
    }
    try t.expect(contains(try rx.file(try std.fs.path.join(rx.tf.f.a(), &.{ dir, "rules.suggested" })), "# allow shell git status*"));
    const report = try rx.file(try std.fs.path.join(rx.tf.f.a(), &.{ dir, "report.md" }));
    try t.expect(contains(report, "harness memory forget "));
    try t.expect(contains(report, "harness skill rm deploy-helper-v2"));
    try t.expect(contains(report, "mcp.ini didn't exist before: remove it"));
    try t.expect(contains(rx.talk.out.items, "report.md"));
    // tasks/ is guarded like workflows/; harness reads what was written
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, try std.fs.path.join(rx.tf.f.a(), &.{ rx.home, "tasks" }), .{});
        try t.expectEqual(0, st.permissions.toMode() & 0o077);
    }
    const core_mod = @import("core.zig");
    try t.expect(try core_mod.settingsProblem(t.io, rx.tf.f.a(), try core_mod.Paths.init(rx.tf.f.a(), rx.home)) == null);
    // the log says it, counts only
    try t.expect(contains(try rx.file("log" ++ std.fs.path.sep_str ++ "actions.jsonl"), "\"event\":\"import\""));
}

test "running_it_again_adds_nothing_twice" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    try t.expectEqual(0, try rx.run(.{ .yes = true }));
    const tasks = try rx.file("tasks.ini");
    const mcp_text = try rx.file("mcp.ini");
    const rules_text = try rx.file("rules");
    const count = try rx.memoryCount();
    rx.talk.out = .empty;
    try t.expectEqual(0, try rx.run(.{ .yes = true }));
    try t.expect(contains(rx.talk.out.items, "Nothing new to import"));
    // and no folder for an import that didn't happen
    var d = try Io.Dir.cwd().openDir(t.io, try std.fs.path.join(rx.tf.f.a(), &.{ rx.home, "state", "imports" }), .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(t.io)) |_| n += 1;
    try t.expectEqual(1, n);
    try t.expectEqualStrings(tasks, try rx.file("tasks.ini"));
    try t.expectEqualStrings(mcp_text, try rx.file("mcp.ini"));
    try t.expectEqualStrings(rules_text, try rx.file("rules"));
    try t.expectEqual(count, try rx.memoryCount());
}

test "the_import_refuses_while_harness_runs_but_dry_run_works" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    const core_mod = @import("core.zig");
    const held = try core_mod.takeLock(t.io, try core_mod.Paths.init(rx.tf.f.a(), rx.home));
    defer held.close(t.io);
    try t.expectEqual(1, try rx.run(.{ .yes = true }));
    try t.expect(contains(rx.talk.out.items, "harness is running on"));
    try t.expect(contains(rx.talk.out.items, "stop it first"));
    rx.talk.out = .empty;
    try t.expectEqual(0, try rx.run(.{ .dry_run = true }));
    try t.expect(contains(rx.talk.out.items, "Will import"));
    try t.expect(!rx.exists("mcp.ini"));
}

test "without_a_terminal_or_yes_it_exits_2" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    try t.expectEqual(2, try rx.run(.{}));
    try t.expect(contains(rx.talk.out.items, "add --yes"));
    try t.expect(!rx.exists("mcp.ini"));
    try t.expectEqual(0, try rx.memoryCount());
}

test "a_terminal_answer_of_no_writes_nothing" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    rx.talk.answer = "n";
    try t.expectEqual(0, try rx.run(.{}));
    try t.expect(contains(rx.talk.out.items, "Import? [y/N] "));
    try t.expect(contains(rx.talk.out.items, "Nothing imported."));
    try t.expect(!rx.exists("mcp.ini"));
    rx.talk.answer = "y";
    try t.expectEqual(0, try rx.run(.{}));
    try t.expect(rx.exists("mcp.ini"));
}

test "fifty_imported_entries_leave_the_owners_top_items" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    const a = rx.tf.f.a();
    var entries: std.ArrayList(u8) = .empty;
    for (0..50) |i| try entries.print(a, "{s}Fact number {d}: the {s} {d} likes item{d}zz.", .{ if (i > 0) "\n§\n" else "", i, "neighbour", i * 7, i });
    try rx.tf.f.put("memories/MEMORY.md", entries.items);
    // SOUL.md would be pinned, in front of everything by design
    try rx.tf.f.put("SOUL.md", "");
    // the owner's own items, mentioned in the last days
    var store = try memory.Store.load(t.allocator, t.io, try std.fs.path.join(a, &.{ rx.home, "memory" }));
    const now = testNow();
    const owner = [_][]const u8{ "Dentist on Thursday at 14:00", "The boiler code is behind the door", "Anna's birthday is in March", "Prefers trains to planes", "The car is due for service" };
    for (owner, 0..) |o, i| {
        const r = try store.add(o, null, now - @as(i64, @intCast(i + 1)) * 86400);
        try store.mention(store.find(r.id).?, now - 3600);
    }
    const before = try store.levels(a, now, 20);
    var order_before: std.ArrayList([]const u8) = .empty;
    for (before) |r| try order_before.append(a, try a.dupe(u8, r.item.id));
    store.deinit();
    try t.expectEqual(0, try rx.run(.{ .yes = true }));
    var after_store = try memory.Store.load(t.allocator, t.io, try std.fs.path.join(a, &.{ rx.home, "memory" }));
    defer after_store.deinit();
    const after = try after_store.levels(a, now, 20);
    // the owner's five are still the first five, in the same order, all top
    for (order_before.items, 0..) |id, i| {
        try t.expectEqualStrings(id, after[i].item.id);
        try t.expect(after[i].level == .top);
    }
    try t.expect(after.len >= 55);
}

test "a_profile_and_windows_line_endings_import" {
    var rx: Rx = undefined;
    try rx.init(false);
    defer rx.deinit();
    // the root's own setup is the default profile; the active one is work
    try rx.tf.f.put("active_profile", "work\r\n");
    try rx.tf.f.putCrlf("profiles/work/memories/MEMORY.md", "Works at the harbour.\n§\nBoss is Ewa.\n");
    try rx.tf.f.putCrlf("profiles/work/cron/jobs.json", "{\"jobs\": [{\"id\": \"w1\", \"name\": \"Shift\", \"prompt\": \"Check the rota\", \"schedule\": {\"kind\": \"cron\", \"expr\": \"0 6 * * 1-5\"}, \"deliver\": \"origin\"}]}\n");
    try rx.tf.f.putCrlf("profiles/work/config.yaml", "timezone: Test/Plus2\napprovals:\n  deny:\n    - \"rm -rf *\"\n");
    try t.expectEqual(0, try rx.run(.{ .yes = true }));
    try t.expect(contains(rx.talk.out.items, "(profile work)"));
    try t.expect(contains(rx.talk.out.items, "other Hermes profiles: default"));
    try t.expectEqual(2, try rx.memoryCount());
    // 06:00 at +02:00 is 05:00 at +01:00
    try t.expect(contains(try rx.file("tasks.ini"), "[shift]\nat = 05:00\ndays = mon,tue,wed,thu,fri\ndo = Check the rota\n"));
    try t.expect(!contains(try allText(rx.tf.f.a(), try std.fs.path.join(rx.tf.f.a(), &.{ rx.home, "memory" })), "\r"));
    try t.expect(contains(try rx.file("rules"), "deny shell rm -rf *\n"));
}

test "no_secret_value_reaches_any_file_output_or_log" {
    var rx: Rx = undefined;
    try rx.init(true);
    defer rx.deinit();
    try t.expectEqual(0, try rx.run(.{ .dry_run = true }));
    try t.expectEqual(0, try rx.run(.{ .yes = true }));
    const everything = try allText(rx.tf.f.a(), rx.home);
    for (hermes.Fixture.secrets) |v| {
        if (contains(everything, v) or contains(rx.talk.out.items, v)) {
            std.debug.print("found {s}\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
    // the memory entry that held one says where it was
    try t.expect(contains(everything, "[secret:OPENROUTER_API_KEY]"));
}
