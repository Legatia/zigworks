//! Snapshots of workspace folders, and of a sandbox's home (`env:NAME`):
//! the one way harness keeps versions of the workspace. The store is
//! `snapshots/` in the data folder, where no file tool reaches:
//! `objects/ab/<sha256>` holds each content once, and `folders/<key>/<id>`
//! is one snapshot: a JSON header line, then a line a kept file
//! (`sha256 TAB size TAB exec TAB mtime TAB path`, `exec` `x` or `-`,
//! `mtime` in nanoseconds) and a line a skipped one (`- TAB why TAB
//! path`), paths with `\`, tab, CR and LF escaped. `key` is the first 16
//! hex digits of the SHA-256 of the folder's name (`/`, `work/shop`,
//! `env:box`; case folded where volumes ignore it); `id` counts up per
//! folder. One mutex: takes, restores and prunes never overlap.
const std = @import("std");
const builtin = @import("builtin");
const folders = @import("folders.zig");
const log_mod = @import("log.zig");
const rules = @import("rules.zig");
const gate = @import("gate.zig");
const util = @import("util.zig");
const jv = @import("jv.zig");
const masks_mod = @import("masks.zig");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fold = builtin.os.tag == .macos or builtin.os.tag == .windows;
const has_exec = Io.File.Permissions.has_executable_bit;

/// Makes `dst`, a new file, share `src`'s blocks where the file system can
/// (`clonefile` on APFS, `FICLONE` on btrfs and XFS, block cloning on ReFS
/// and Dev Drives); false where it can't, and then the store copies. The
/// store hashes what `dst` holds and names the object by that, so a helper
/// never hashes.
pub const CloneFn = *const fn (io: Io, src: []const u8, dst: []const u8) anyerror!bool;

/// This platform's clone helper, where one is built (the per-file-system
/// helpers plug in here); null: every object is copied.
pub const platform_clone: ?CloneFn = null;

/// A `skip` pattern of the section for `folder` (inside the workspace):
/// it matches an entry in that folder by its name or by its path from it.
pub const Skip = struct { folder: []const u8, pattern: []const u8 };

/// The `skip` patterns that apply to a snapshot of `base` (a folder inside
/// the workspace): those of every section holding it or inside it.
pub fn skipsFor(f: folders.Folders, arena: std.mem.Allocator, base: []const u8) ![]const Skip {
    var out: std.ArrayList(Skip) = .empty;
    for (f.sections) |s| {
        if (s.skip.len == 0) continue;
        if (!folders.inFolder(base, s.folder) and !folders.inFolder(s.folder, base)) continue;
        for (s.skip) |p| try out.append(arena, .{ .folder = s.folder, .pattern = p });
    }
    return out.items;
}

/// What to snapshot.
pub const Source = struct {
    /// What the owner and the log call it: `/`, `work/shop`, `env:NAME`.
    name: []const u8,
    /// Its absolute path.
    path: []const u8,
    /// Its folder inside the workspace ("" for `/` and `env:NAME`), from
    /// which `skip` patterns are read.
    base: []const u8 = "",
    skip: []const Skip = &.{},
};

/// Why a snapshot was taken: before a run's first change of the folder,
/// when that run ended, by the owner (`/snapshot`, `harness snapshot take`,
/// before a restore), or by the agent's `snapshot` tool.
pub const When = enum { before, after, hand, tool };

/// Who took it: the run (its id, label and definition) and what started it.
pub const By = struct { rid: u64 = 0, run: []const u8 = "", agent: []const u8 = "", by: []const u8 = "owner" };

pub const Take = struct {
    when: When,
    label: []const u8 = "",
    by: By = .{},
    /// A folder that isn't there is an error (by hand, the tool), not an
    /// empty snapshot (before and after a run).
    must_exist: bool = false,
};

pub const Taken = struct {
    id: u64 = 0,
    files: usize = 0,
    /// Files added, changed or removed since the folder's last snapshot.
    changed: usize = 0,
    /// Bytes of new objects it stored.
    bytes: u64 = 0,
    /// Why none was taken (the folder is too big).
    refused: ?[]const u8 = null,
};

/// One snapshot as `/snapshots` lists it.
pub const Info = struct {
    id: u64,
    time: i64,
    when: When,
    label: []const u8,
    run: []const u8,
    agent: []const u8,
    by: []const u8,
    files: usize,
    changed: usize,
};

/// What changed from the snapshot before (`before`; null: none) to one.
pub const Changes = struct {
    before: ?u64,
    added: []const []const u8,
    changed: []const []const u8,
    removed: []const []const u8,
};

pub const Failed = struct { path: []const u8, why: []const u8 };

pub const Restored = struct {
    /// The snapshot taken first: restoring it undoes this.
    before_id: u64,
    written: []const []const u8,
    deleted: []const []const u8,
    /// Files that could not be written or deleted, and why.
    failed: []const Failed,
};

pub const Pruned = struct { snapshots: usize = 0, objects: usize = 0 };

const File = struct { path: []const u8, sha: [64]u8, size: u64, exec: bool, mtime: i128 };
const Skipped = struct { path: []const u8, why: []const u8 };
const Header = struct {
    folder: []const u8 = "",
    time: i64 = 0,
    label: []const u8 = "",
    rid: u64 = 0,
    run: []const u8 = "",
    agent: []const u8 = "",
    by: []const u8 = "",
    when: When = .hand,
    files: usize = 0,
    changed: usize = 0,
    bytes: u64 = 0,
};
const Snap = struct { header: Header, files: []const File, skipped: []const Skipped };

/// What `folder` names: `env:NAME`, an environment's home (error.NoSuchEnv
/// when the name can't be one); `/` the workspace; else a folder inside
/// it, read like a file path (error.OutsideWorkspace). Its skip patterns
/// come from `f`.
pub fn sourceFor(arena: std.mem.Allocator, io: Io, s: *const Store, workspace: []const u8, f: ?*const folders.Folders, folder: []const u8) !Source {
    if (std.mem.startsWith(u8, folder, "env:")) {
        const name = folder["env:".len..];
        if (s.env_root.len == 0 or !rules.envName(name)) return error.NoSuchEnv;
        return .{ .name = folder, .path = try std.fs.path.join(arena, &.{ s.env_root, name, "home" }) };
    }
    const rel = if (std.mem.eql(u8, folder, "/")) "" else (gate.confined(arena, io, workspace, folder) catch return error.OutsideWorkspace).rel;
    return .{
        .name = if (rel.len == 0) "/" else rel,
        .path = if (rel.len == 0) workspace else try std.fs.path.join(arena, &.{ workspace, try native(arena, rel) }),
        .base = rel,
        .skip = if (f) |fs| try skipsFor(fs.*, arena, rel) else &.{},
    };
}

/// The store's folder name for `name`: the first 16 hex digits of its
/// SHA-256, case folded where volumes ignore case.
pub fn folderKey(name: []const u8) [16]u8 {
    var h = Sha256.init(.{});
    if (fold) {
        for (name) |c| h.update(&.{std.ascii.toLower(c)});
    } else h.update(name);
    const d = h.finalResult();
    return std.fmt.bytesToHex(d[0..8].*, .lower);
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// `snapshots/` in the data folder.
    dir: []const u8,
    /// `state/env` in the data folder: `env:NAME` is `NAME/home` there (a
    /// sandbox's home, gap 2). "": no environments.
    env_root: []const u8 = "",
    log: ?*log_mod.Log = null,
    /// Stored secrets, masked in labels before they are written.
    masks: ?*masks_mod.List = null,
    clone: ?CloneFn = platform_clone,
    /// `[limits] snapshot_mb`: the objects all snapshots name, at most.
    total_mb: u32 = 5120,
    /// A folder with more files, or more bytes, gets no snapshot.
    max_files: u32 = 20_000,
    max_bytes: u64 = 1 << 30,
    /// Files larger than this are not kept (and named).
    max_file: u64 = 100 << 20,
    mutex: Io.Mutex = .init,
    /// Folders whose last snapshot was refused, and why (for /status).
    refused: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(s: *Store) void {
        var it = s.refused.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.refused.deinit(s.gpa);
    }

    /// Takes a snapshot of `src`: see the file's comment and `Take`.
    pub fn take(s: *Store, arena: std.mem.Allocator, src: Source, opts: Take) !Taken {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.takeLocked(arena, src, opts);
    }

    fn takeLocked(s: *Store, arena: std.mem.Allocator, src: Source, opts: Take) !Taken {
        const time = util.nowSeconds(s.io);
        // the folder itself as it is, never what a link there points to
        if (isLink(s.io, src.path)) return error.LinkOnTheWay;
        const fdir = try s.folderDir(arena, src.name);
        const known = try s.ids(arena, fdir);
        const prev: ?Snap = if (known.len > 0) s.load(arena, fdir, known[known.len - 1]) catch null else null;
        var found = try s.walk(arena, src);
        if (found.missing and opts.must_exist) return error.NoSuchFolder;
        if (found.refused) |why| {
            try s.setRefused(src.name, why);
            s.logLine(.{ .event = "snapshot skipped", .folder = src.name, .why = why });
            return .{ .refused = why };
        }
        var before: std.StringHashMapUnmanaged(File) = .empty;
        if (prev) |p| for (p.files) |pf| try before.put(arena, pf.path, pf);
        // a file whose size and time are as they were is not read again,
        // unless that time is within 2 s of the last snapshot (file systems
        // that keep times to 2 s, or a write in the same moment)
        const window: i128 = if (prev) |p| @as(i128, p.header.time - 2) * std.time.ns_per_s else 0;
        var files: std.ArrayList(File) = .empty;
        var bytes: u64 = 0;
        var changed: usize = 0;
        for (found.files.items) |ff| {
            const old = before.get(ff.path);
            if (old) |pf| if (pf.size == ff.size and pf.mtime == ff.mtime and ff.mtime < window and s.hasObject(arena, pf.sha)) {
                try files.append(arena, .{ .path = ff.path, .sha = pf.sha, .size = ff.size, .exec = ff.exec, .mtime = ff.mtime });
                if (pf.exec != ff.exec) changed += 1;
                continue;
            };
            const abs = try std.fs.path.join(arena, &.{ src.path, try native(arena, ff.path) });
            const stored = s.storeObject(arena, abs) catch |e| switch (e) {
                error.OutOfMemory, error.NoSpaceLeft => return e,
                // gone or unreadable since the walk: not kept, and named
                else => {
                    try found.skipped.append(arena, .{ .path = ff.path, .why = "unreadable" });
                    continue;
                },
            };
            try files.append(arena, .{ .path = ff.path, .sha = stored.sha, .size = stored.size, .exec = ff.exec, .mtime = ff.mtime });
            bytes += stored.new_bytes;
            if (old) |pf| {
                if (!std.mem.eql(u8, &pf.sha, &stored.sha) or pf.exec != ff.exec) changed += 1;
            } else changed += 1;
        }
        if (prev) |p| {
            var now: std.StringHashMapUnmanaged(void) = .empty;
            for (files.items) |nf| try now.put(arena, nf.path, {});
            for (p.files) |pf| if (!now.contains(pf.path)) {
                changed += 1;
            };
        }
        std.mem.sort(File, files.items, {}, struct {
            fn lt(_: void, x: File, y: File) bool {
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        std.mem.sort(Skipped, found.skipped.items, {}, struct {
            fn lt(_: void, x: Skipped, y: Skipped) bool {
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        const id = if (known.len > 0) known[known.len - 1] + 1 else 1;
        // a label is typed by the owner or the model: no secret value in it
        const short = util.cut(opts.label, 200);
        const label = if (s.masks) |m| m.scrubAlloc(arena, short) catch short else short;
        var out: std.ArrayList(u8) = .empty;
        try writeHeader(&out, arena, .{ .folder = src.name, .time = time, .label = label, .rid = opts.by.rid, .run = opts.by.run, .agent = opts.by.agent, .by = opts.by.by, .when = opts.when, .files = files.items.len, .changed = changed, .bytes = bytes });
        for (files.items) |nf| {
            try out.print(arena, "{s}\t{d}\t{s}\t{d}\t", .{ &nf.sha, nf.size, if (nf.exec) "x" else "-", nf.mtime });
            try util.escapeField(&out, arena, nf.path);
            try out.append(arena, '\n');
        }
        for (found.skipped.items) |sk| {
            try out.print(arena, "-\t{s}\t", .{sk.why});
            try util.escapeField(&out, arena, sk.path);
            try out.append(arena, '\n');
        }
        // written whole under another name, then renamed: never half a snapshot
        try Io.Dir.cwd().createDirPath(s.io, fdir);
        const tmp = try std.fmt.allocPrint(arena, "{s}{c}.tmp-{d}", .{ fdir, std.fs.path.sep, id });
        const final = try std.fmt.allocPrint(arena, "{s}{c}{d}", .{ fdir, std.fs.path.sep, id });
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = out.items, .flags = .{ .permissions = util.private_file } });
        try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, s.io);
        s.clearRefused(src.name);
        s.logLine(.{ .event = "snapshot", .folder = src.name, .id = id, .when = opts.when, .label = label, .files = files.items.len, .changed = changed, .bytes = bytes, .rid = opts.by.rid, .agent = opts.by.agent, .by = opts.by.by });
        return .{ .id = id, .files = files.items.len, .changed = changed, .bytes = bytes };
    }

    /// The snapshots of `name`, oldest first.
    pub fn list(s: *Store, arena: std.mem.Allocator, name: []const u8) ![]const Info {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const fdir = try s.folderDir(arena, name);
        const known = try s.ids(arena, fdir);
        var out: std.ArrayList(Info) = .empty;
        for (known) |id| {
            const h = s.header(arena, fdir, id) catch continue;
            try out.append(arena, .{ .id = id, .time = h.time, .when = h.when, .label = h.label, .run = h.run, .agent = h.agent, .by = h.by, .files = h.files, .changed = h.changed });
        }
        return out.items;
    }

    /// The folders that have snapshots, by name.
    pub fn names(s: *Store, arena: std.mem.Allocator) ![]const []const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.ArrayList([]const u8) = .empty;
        const root = try std.fs.path.join(arena, &.{ s.dir, "folders" });
        var d = Io.Dir.cwd().openDir(s.io, root, .{ .iterate = true }) catch return out.items;
        defer d.close(s.io);
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .directory) continue;
            const fdir = try std.fs.path.join(arena, &.{ root, e.name });
            const known = try s.ids(arena, fdir);
            if (known.len == 0) continue;
            const h = s.header(arena, fdir, known[known.len - 1]) catch continue;
            try out.append(arena, h.folder);
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return out.items;
    }

    /// What changed from the snapshot before `id` to `id`.
    pub fn changes(s: *Store, arena: std.mem.Allocator, name: []const u8, id: u64) !Changes {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const fdir = try s.folderDir(arena, name);
        const now = try s.load(arena, fdir, id);
        var before: ?u64 = null;
        for (try s.ids(arena, fdir)) |k| {
            if (k < id) before = k;
        }
        const old: []const File = if (before) |b| (try s.load(arena, fdir, b)).files else &.{};
        var was: std.StringHashMapUnmanaged(File) = .empty;
        for (old) |f| try was.put(arena, f.path, f);
        var is: std.StringHashMapUnmanaged(void) = .empty;
        var added: std.ArrayList([]const u8) = .empty;
        var changed: std.ArrayList([]const u8) = .empty;
        var removed: std.ArrayList([]const u8) = .empty;
        for (now.files) |f| {
            try is.put(arena, f.path, {});
            if (was.get(f.path)) |o| {
                if (!std.mem.eql(u8, &o.sha, &f.sha) or o.exec != f.exec) try changed.append(arena, f.path);
            } else try added.append(arena, f.path);
        }
        for (old) |f| if (!is.contains(f.path)) try removed.append(arena, f.path);
        return .{ .before = before, .added = added.items, .changed = changed.items, .removed = removed.items };
    }

    /// Puts `src` back as at snapshot `id`. It takes a snapshot first, so
    /// it can be undone (none possible: error.CannotUndo); deletes the
    /// files that `id` neither kept nor skipped; writes back each file of
    /// `id` that is missing or differs, in place (an existing file keeps
    /// what it was given, a Windows folder's ACEs too; a new one inherits
    /// them), never through a symbolic link: a link where `id` has a file
    /// is replaced, a file behind a linked folder is named and not
    /// written. A file that can't be written or deleted (held open on
    /// Windows) is named and the rest go on.
    pub fn restore(s: *Store, arena: std.mem.Allocator, src: Source, id: u64, by: By) !Restored {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const fdir = try s.folderDir(arena, src.name);
        const target = try s.load(arena, fdir, id);
        // (takeLocked refuses a folder that is a symbolic link)
        const first = try s.takeLocked(arena, src, .{ .when = .hand, .label = try std.fmt.allocPrint(arena, "before restoring {d}", .{id}), .by = by });
        if (first.refused != null) return error.CannotUndo;
        const now = try s.load(arena, fdir, first.id);
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        for (target.files) |f| try keep.put(arena, f.path, {});
        for (target.skipped) |f| try keep.put(arena, f.path, {});
        var written: std.ArrayList([]const u8) = .empty;
        var deleted: std.ArrayList([]const u8) = .empty;
        var failed: std.ArrayList(Failed) = .empty;
        // what `id` has no place for goes first, so a file can become a folder
        for (now.files) |f| {
            if (keep.contains(f.path)) continue;
            s.deleteBack(arena, src.path, f.path) catch |e| {
                try failed.append(arena, .{ .path = f.path, .why = whyNot(e) });
                continue;
            };
            try deleted.append(arena, f.path);
        }
        var cur: std.StringHashMapUnmanaged(File) = .empty;
        for (now.files) |f| try cur.put(arena, f.path, f);
        for (target.files) |f| {
            if (cur.get(f.path)) |c| if (std.mem.eql(u8, &c.sha, &f.sha) and c.exec == f.exec) continue;
            s.writeBack(arena, src.path, f) catch |e| {
                try failed.append(arena, .{ .path = f.path, .why = whyNot(e) });
                continue;
            };
            try written.append(arena, f.path);
        }
        s.logLine(.{ .event = "restore", .folder = src.name, .id = id, .before_id = first.id, .written = written.items.len, .deleted = deleted.items.len });
        return .{ .before_id = first.id, .written = written.items, .deleted = deleted.items, .failed = failed.items };
    }

    /// Keeps each folder's newest snapshots (its section's `snapshots`,
    /// else 50; `f` null: 50), then drops the oldest while the objects
    /// named exceed `total_mb` (each folder keeps its newest), then deletes
    /// the objects and temporary files nothing names.
    pub fn prune(s: *Store, arena: std.mem.Allocator, f: ?*const folders.Folders) !Pruned {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: Pruned = .{};
        const root = try std.fs.path.join(arena, &.{ s.dir, "folders" });
        const Kept = struct { fdir: []const u8, id: u64, time: i64, newest: bool, files: []const File };
        var kept: std.ArrayList(Kept) = .empty;
        if (Io.Dir.cwd().openDir(s.io, root, .{ .iterate = true })) |d_const| {
            var d = d_const;
            defer d.close(s.io);
            var it = d.iterate();
            while (try it.next(s.io)) |e| {
                if (e.kind != .directory) continue;
                const fdir = try std.fs.path.join(arena, &.{ root, e.name });
                const known = try s.ids(arena, fdir);
                if (known.len == 0) continue;
                const newest = s.header(arena, fdir, known[known.len - 1]) catch continue;
                const n = keepFor(f, newest.folder);
                var first: usize = 0;
                while (known.len - first > n) : (first += 1) {
                    s.deleteSnapshot(arena, fdir, known[first]);
                    out.snapshots += 1;
                }
                for (known[first..]) |id| {
                    const snap = s.load(arena, fdir, id) catch continue;
                    try kept.append(arena, .{ .fdir = fdir, .id = id, .time = snap.header.time, .newest = id == known[known.len - 1], .files = snap.files });
                }
            }
        } else |_| {}
        // the objects the snapshots left name, and how many name each
        const Ref = struct { count: u32, size: u64 };
        var refs: std.StringHashMapUnmanaged(Ref) = .empty;
        var total: u64 = 0;
        // (keys point into the loaded snapshots, which outlive the map)
        for (kept.items) |k| for (k.files) |*file| {
            const gop = try refs.getOrPut(arena, &file.sha);
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
            } else {
                gop.value_ptr.* = .{ .count = 1, .size = file.size };
                total += file.size;
            }
        };
        const cap = @as(u64, s.total_mb) * (1 << 20);
        if (total > cap) {
            std.mem.sort(Kept, kept.items, {}, struct {
                fn lt(_: void, x: Kept, y: Kept) bool {
                    return x.time < y.time or (x.time == y.time and x.id < y.id);
                }
            }.lt);
            for (kept.items) |k| {
                if (total <= cap) break;
                if (k.newest) continue;
                s.deleteSnapshot(arena, k.fdir, k.id);
                out.snapshots += 1;
                for (k.files) |file| if (refs.getPtr(&file.sha)) |r| {
                    r.count -= 1;
                    if (r.count == 0) {
                        total -= r.size;
                        _ = refs.remove(&file.sha);
                    }
                };
            }
        }
        out.objects = try s.deleteUnnamed(arena, &refs);
        if (out.snapshots + out.objects > 0) s.logLine(.{ .event = "prune", .snapshots = out.snapshots, .objects = out.objects });
        return out;
    }

    /// `name: none (why)` lines for the folders whose last snapshot was
    /// refused.
    pub fn note(s: *Store, arena: std.mem.Allocator) ![]const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.ArrayList(u8) = .empty;
        var it = s.refused.iterator();
        while (it.next()) |e| try out.print(arena, "{s}: none ({s})\n", .{ e.key_ptr.*, e.value_ptr.* });
        return out.items;
    }

    fn setRefused(s: *Store, name: []const u8, why: []const u8) !void {
        const w = try s.gpa.dupe(u8, why);
        errdefer s.gpa.free(w);
        if (s.refused.getPtr(name)) |old| {
            s.gpa.free(old.*);
            old.* = w;
            return;
        }
        const k = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(k);
        try s.refused.put(s.gpa, k, w);
    }

    fn clearRefused(s: *Store, name: []const u8) void {
        const kv = s.refused.fetchOrderedRemove(name) orelse return;
        s.gpa.free(kv.key);
        s.gpa.free(kv.value);
    }

    fn logLine(s: *Store, fields: anytype) void {
        if (s.log) |l| l.write(.files, false, fields) catch {};
    }

    fn folderDir(s: *Store, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        const key = folderKey(name);
        return std.fs.path.join(arena, &.{ s.dir, "folders", &key });
    }

    /// The ids of the snapshots in `fdir`, in order.
    fn ids(s: *Store, arena: std.mem.Allocator, fdir: []const u8) ![]u64 {
        var d = Io.Dir.cwd().openDir(s.io, fdir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        defer d.close(s.io);
        var out: std.ArrayList(u64) = .empty;
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file) continue;
            const id = std.fmt.parseInt(u64, e.name, 10) catch continue;
            try out.append(arena, id);
        }
        std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
        return out.items;
    }

    fn snapPath(arena: std.mem.Allocator, fdir: []const u8, id: u64) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}{c}{d}", .{ fdir, std.fs.path.sep, id });
    }

    /// A snapshot's header alone (its first line).
    fn header(s: *Store, arena: std.mem.Allocator, fdir: []const u8, id: u64) !Header {
        var f = Io.Dir.cwd().openFile(s.io, try snapPath(arena, fdir, id), .{}) catch |e| switch (e) {
            error.FileNotFound => return error.NoSuchSnapshot,
            else => return e,
        };
        defer f.close(s.io);
        const buf = try arena.alloc(u8, 8192);
        const n = try f.readPositionalAll(s.io, buf, 0);
        const line = buf[0 .. std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n];
        return parseHeader(arena, line);
    }

    fn load(s: *Store, arena: std.mem.Allocator, fdir: []const u8, id: u64) !Snap {
        const text = Io.Dir.cwd().readFileAlloc(s.io, try snapPath(arena, fdir, id), arena, .limited(256 << 20)) catch |e| switch (e) {
            error.FileNotFound => return error.NoSuchSnapshot,
            else => return e,
        };
        var it = std.mem.splitScalar(u8, text, '\n');
        const head = try parseHeader(arena, it.next() orelse return error.BadSnapshot);
        var files: std.ArrayList(File) = .empty;
        var skipped: std.ArrayList(Skipped) = .empty;
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const first = parts.next().?;
            if (std.mem.eql(u8, first, "-")) {
                const why = parts.next() orelse return error.BadSnapshot;
                try skipped.append(arena, .{ .why = why, .path = try util.unescapeField(arena, parts.rest()) });
                continue;
            }
            if (first.len != 64) return error.BadSnapshot;
            const size = std.fmt.parseInt(u64, parts.next() orelse return error.BadSnapshot, 10) catch return error.BadSnapshot;
            const exec = std.mem.eql(u8, parts.next() orelse return error.BadSnapshot, "x");
            const mtime = std.fmt.parseInt(i128, parts.next() orelse return error.BadSnapshot, 10) catch return error.BadSnapshot;
            const path = try util.unescapeField(arena, parts.next() orelse return error.BadSnapshot);
            try files.append(arena, .{ .path = path, .sha = first[0..64].*, .size = size, .exec = exec, .mtime = mtime });
        }
        return .{ .header = head, .files = files.items, .skipped = skipped.items };
    }

    fn deleteSnapshot(s: *Store, arena: std.mem.Allocator, fdir: []const u8, id: u64) void {
        const p = snapPath(arena, fdir, id) catch return;
        Io.Dir.cwd().deleteFile(s.io, p) catch {};
    }

    fn objectPath(s: *Store, arena: std.mem.Allocator, sha: [64]u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ s.dir, "objects", sha[0..2], &sha });
    }

    fn hasObject(s: *Store, arena: std.mem.Allocator, sha: [64]u8) bool {
        const p = s.objectPath(arena, sha) catch return false;
        _ = Io.Dir.cwd().statFile(s.io, p, .{}) catch return false;
        return true;
    }

    const Stored = struct { sha: [64]u8, size: u64, new_bytes: u64 };

    /// Stores the file at `abs` as an object: cloned where the file system
    /// can, then hashed from the clone; else copied while hashing what is
    /// copied. Either way the name is the hash of what was stored.
    fn storeObject(s: *Store, arena: std.mem.Allocator, abs: []const u8) !Stored {
        const objects = try std.fs.path.join(arena, &.{ s.dir, "objects" });
        try Io.Dir.cwd().createDirPath(s.io, objects);
        var rnd: [8]u8 = undefined;
        s.io.random(&rnd);
        const tmp = try std.fmt.allocPrint(arena, "{s}{c}.tmp-{s}", .{ objects, std.fs.path.sep, &std.fmt.bytesToHex(rnd, .lower) });
        var kept = false;
        defer if (!kept) Io.Dir.cwd().deleteFile(s.io, tmp) catch {};
        const cloned = if (s.clone) |c| c(s.io, abs, tmp) catch false else false;
        const h = if (cloned) try hashFile(s.io, tmp) else try copyHashing(s.io, abs, tmp);
        const dst = try s.objectPath(arena, h.sha);
        if (s.hasObject(arena, h.sha)) return .{ .sha = h.sha, .size = h.size, .new_bytes = 0 };
        try Io.Dir.cwd().createDirPath(s.io, std.fs.path.dirname(dst).?);
        try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), dst, s.io);
        kept = true;
        return .{ .sha = h.sha, .size = h.size, .new_bytes = h.size };
    }

    /// Deletes the objects `refs` does not name, and temporary files.
    fn deleteUnnamed(s: *Store, arena: std.mem.Allocator, refs: anytype) !usize {
        const objects = try std.fs.path.join(arena, &.{ s.dir, "objects" });
        var d = Io.Dir.cwd().openDir(s.io, objects, .{ .iterate = true }) catch return 0;
        defer d.close(s.io);
        var n: usize = 0;
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind == .file) {
                // a take cut off before it renamed its object
                if (std.mem.startsWith(u8, e.name, ".tmp-")) d.deleteFile(s.io, e.name) catch {};
                continue;
            }
            if (e.kind != .directory or e.name.len != 2) continue;
            var sub = d.openDir(s.io, e.name, .{ .iterate = true }) catch continue;
            defer sub.close(s.io);
            var sit = sub.iterate();
            var gone: std.ArrayList([]const u8) = .empty;
            while (try sit.next(s.io)) |o| {
                if (o.kind != .file or refs.contains(o.name)) continue;
                try gone.append(arena, try arena.dupe(u8, o.name));
            }
            for (gone.items) |name| {
                sub.deleteFile(s.io, name) catch continue;
                n += 1;
            }
        }
        return n;
    }

    /// Deletes `rel` under `root`, never through a link on the way.
    fn deleteBack(s: *Store, arena: std.mem.Allocator, root: []const u8, rel: []const u8) !void {
        try s.checkWay(arena, root, rel, false);
        const abs = try std.fs.path.join(arena, &.{ root, try native(arena, rel) });
        const st = try Io.Dir.cwd().statFile(s.io, abs, .{ .follow_symlinks = false });
        if (st.kind != .file) return error.NotAFile;
        try Io.Dir.cwd().deleteFile(s.io, abs);
    }

    /// Writes file `f` of a snapshot back under `root`.
    fn writeBack(s: *Store, arena: std.mem.Allocator, root: []const u8, f: File) !void {
        try s.checkWay(arena, root, f.path, true);
        const abs = try std.fs.path.join(arena, &.{ root, try native(arena, f.path) });
        // a link where the file was is replaced by the file; a folder there
        // only when empty
        if (Io.Dir.cwd().statFile(s.io, abs, .{ .follow_symlinks = false })) |st| switch (st.kind) {
            .file => {},
            .sym_link => try Io.Dir.cwd().deleteFile(s.io, abs),
            .directory => Io.Dir.cwd().deleteDir(s.io, abs) catch return error.FolderInTheWay,
            else => return error.NotAFile,
        } else |e| if (e != error.FileNotFound) return e;
        var in = try Io.Dir.cwd().openFile(s.io, try s.objectPath(arena, f.sha), .{});
        defer in.close(s.io);
        // in place where it exists, so it keeps what it was given
        var out = Io.Dir.cwd().createFile(s.io, abs, .{ .exclusive = true, .read = true }) catch |e| switch (e) {
            error.PathAlreadyExists => try Io.Dir.cwd().openFile(s.io, abs, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }),
            else => return e,
        };
        defer out.close(s.io);
        if ((try out.stat(s.io)).kind != .file) return error.NotAFile;
        try out.setLength(s.io, 0);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const got = try readSome(in, s.io, &buf);
            if (got == 0) break;
            try out.writeStreamingAll(s.io, buf[0..got]);
        }
        if (has_exec) {
            const mode = (try out.stat(s.io)).permissions.toMode();
            const want = if (f.exec) mode | ((mode & 0o444) >> 2) else mode & ~@as(std.posix.mode_t, 0o111);
            if (want != mode) try out.setPermissions(s.io, .fromMode(want));
        }
    }

    /// Every folder from `root` to `rel`'s must be a folder, never a
    /// symbolic link; with `make`, those missing are made.
    fn checkWay(s: *Store, arena: std.mem.Allocator, root: []const u8, rel: []const u8, make: bool) !void {
        const parent = std.fs.path.dirnamePosix(rel) orelse return;
        var at: []const u8 = root;
        var parts = std.mem.splitScalar(u8, parent, '/');
        while (parts.next()) |part| {
            at = try std.fs.path.join(arena, &.{ at, part });
            const st = Io.Dir.cwd().statFile(s.io, at, .{ .follow_symlinks = false }) catch |e| switch (e) {
                error.FileNotFound => {
                    if (!make) return e;
                    // the rest is not there either: made as folders
                    try Io.Dir.cwd().createDirPath(s.io, try std.fs.path.join(arena, &.{ root, try native(arena, parent) }));
                    return;
                },
                else => return e,
            };
            if (st.kind == .sym_link) return error.LinkOnTheWay;
            if (st.kind != .directory) return error.NotAFolder;
        }
    }

    const Found = struct {
        files: std.ArrayList(FoundFile) = .empty,
        skipped: std.ArrayList(Skipped) = .empty,
        refused: ?[]const u8 = null,
        missing: bool = false,
    };
    const FoundFile = struct { path: []const u8, size: u64, mtime: i128, exec: bool };

    /// The files a snapshot of `src` keeps, and those it names as skipped;
    /// links are never followed.
    fn walk(s: *Store, arena: std.mem.Allocator, src: Source) !Found {
        var found: Found = .{};
        var root = Io.Dir.cwd().openDir(s.io, src.path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => {
                found.missing = true;
                return found;
            },
            else => return e,
        };
        defer root.close(s.io);
        var w = try root.walkSelectively(arena);
        defer w.deinit();
        var total: u64 = 0;
        while (true) {
            const entry = (w.next(s.io) catch |e| switch (e) {
                error.OutOfMemory => return e,
                // a folder that can't be read: its entries are not kept
                else => continue,
            }) orelse break;
            const rel = try relOf(arena, entry.path);
            const kind = if (entry.kind != .unknown) entry.kind else (entry.dir.statFile(s.io, entry.basename, .{ .follow_symlinks = false }) catch continue).kind;
            switch (kind) {
                .directory => {
                    if (std.mem.eql(u8, entry.basename, ".git")) {
                        try found.skipped.append(arena, .{ .path = rel, .why = "git" });
                    } else if (try skippedBy(arena, src, rel, entry.basename)) {
                        try found.skipped.append(arena, .{ .path = rel, .why = "skip" });
                    } else w.enter(s.io, entry) catch try found.skipped.append(arena, .{ .path = rel, .why = "unreadable" });
                },
                .sym_link => try found.skipped.append(arena, .{ .path = rel, .why = "link" }),
                .file => {
                    if (try skippedBy(arena, src, rel, entry.basename)) {
                        try found.skipped.append(arena, .{ .path = rel, .why = "skip" });
                        continue;
                    }
                    const st = entry.dir.statFile(s.io, entry.basename, .{ .follow_symlinks = false }) catch continue;
                    if (st.kind != .file) continue;
                    if (st.size > s.max_file) {
                        try found.skipped.append(arena, .{ .path = rel, .why = "big" });
                        continue;
                    }
                    total += st.size;
                    const exec = if (has_exec) st.permissions.toMode() & 0o111 != 0 else false;
                    try found.files.append(arena, .{ .path = rel, .size = st.size, .mtime = st.mtime.nanoseconds, .exec = exec });
                    if (found.files.items.len > s.max_files) {
                        found.refused = try std.fmt.allocPrint(arena, "over {d} files", .{s.max_files});
                        return found;
                    }
                    if (total > s.max_bytes) {
                        found.refused = if (s.max_bytes % (1 << 20) == 0) try std.fmt.allocPrint(arena, "over {d} MiB", .{s.max_bytes >> 20}) else try std.fmt.allocPrint(arena, "over {d} bytes", .{s.max_bytes});
                        return found;
                    }
                },
                else => try found.skipped.append(arena, .{ .path = rel, .why = "other" }),
            }
        }
        return found;
    }
};

/// The snapshots a folder keeps: its section's `snapshots`, else 50.
fn keepFor(f: ?*const folders.Folders, name: []const u8) usize {
    const fs = f orelse return folders.default_keep;
    const folder = if (std.mem.eql(u8, name, "/")) "" else name;
    for (fs.sections) |s| {
        const n = s.snapshots orelse continue;
        if (n == 0) continue;
        if (if (fold) std.ascii.eqlIgnoreCase(s.folder, folder) else std.mem.eql(u8, s.folder, folder)) return n;
    }
    return folders.default_keep;
}

/// Whether a `skip` pattern matches the entry `rel` (from the snapshot's
/// folder) by its name or by its path from the pattern's section.
fn skippedBy(arena: std.mem.Allocator, src: Source, rel: []const u8, name: []const u8) !bool {
    if (src.skip.len == 0) return false;
    const full = if (src.base.len == 0) rel else try std.fmt.allocPrint(arena, "{s}/{s}", .{ src.base, rel });
    for (src.skip) |sk| {
        if (!folders.inFolder(full, sk.folder) or (sk.folder.len > 0 and full.len <= sk.folder.len)) continue;
        const from = if (sk.folder.len == 0) full else full[sk.folder.len + 1 ..];
        if (rules.globCase(sk.pattern, name, fold) or rules.globCase(sk.pattern, from, fold)) return true;
    }
    return false;
}

fn writeHeader(out: *std.ArrayList(u8), arena: std.mem.Allocator, h: Header) !void {
    try out.appendSlice(arena, "{\"folder\":");
    try util.jsonString(out, arena, h.folder);
    try out.print(arena, ",\"time\":{d},\"label\":", .{h.time});
    try util.jsonString(out, arena, h.label);
    try out.print(arena, ",\"rid\":{d},\"run\":", .{h.rid});
    try util.jsonString(out, arena, h.run);
    try out.appendSlice(arena, ",\"agent\":");
    try util.jsonString(out, arena, h.agent);
    try out.appendSlice(arena, ",\"by\":");
    try util.jsonString(out, arena, h.by);
    try out.print(arena, ",\"when\":\"{s}\",\"files\":{d},\"changed\":{d},\"bytes\":{d}}}\n", .{ @tagName(h.when), h.files, h.changed, h.bytes });
}

fn parseHeader(arena: std.mem.Allocator, line: []const u8) !Header {
    const v = jv.parse(arena, line) orelse return error.BadSnapshot;
    const num = struct {
        fn of(x: ?jv.Value) u64 {
            const n = jv.int(x) orelse return 0;
            return if (n > 0) @intCast(n) else 0;
        }
    }.of;
    return .{
        .folder = jv.str(jv.get(v, "folder")) orelse return error.BadSnapshot,
        .time = jv.int(jv.get(v, "time")) orelse 0,
        .label = jv.str(jv.get(v, "label")) orelse "",
        .rid = num(jv.get(v, "rid")),
        .run = jv.str(jv.get(v, "run")) orelse "",
        .agent = jv.str(jv.get(v, "agent")) orelse "",
        .by = jv.str(jv.get(v, "by")) orelse "",
        .when = std.meta.stringToEnum(When, jv.str(jv.get(v, "when")) orelse "") orelse .hand,
        .files = @intCast(num(jv.get(v, "files"))),
        .changed = @intCast(num(jv.get(v, "changed"))),
        .bytes = num(jv.get(v, "bytes")),
    };
}

/// A walked entry's path with `/` between the parts.
fn relOf(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, p);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// A stored path (`/` between parts) as this system writes paths.
fn native(arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
    if (std.fs.path.sep == '/') return rel;
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '/', std.fs.path.sep);
    return out;
}

fn isLink(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// Why a file could not be put back, in words for the owner.
fn whyNot(e: anyerror) []const u8 {
    return switch (e) {
        error.LinkOnTheWay => "a symbolic link on the way",
        error.NotAFolder => "a file is where a folder should be",
        error.FolderInTheWay => "a folder is in the way",
        error.NotAFile => "not a file",
        error.AccessDenied, error.PermissionDenied, error.FileBusy => "in use or not allowed",
        else => @errorName(e),
    };
}

/// Reads what comes next of `f` into `buf`; 0 at its end.
fn readSome(f: Io.File, io: Io, buf: []u8) !usize {
    return f.readStreaming(io, &.{buf}) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => e,
    };
}

const Hashed = struct { sha: [64]u8, size: u64 };

fn hashFile(io: Io, path: []const u8) !Hashed {
    var f = try Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false, .allow_directory = false });
    defer f.close(io);
    var h = Sha256.init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const got = try readSome(f, io, &buf);
        if (got == 0) break;
        h.update(buf[0..got]);
        size += got;
    }
    return .{ .sha = std.fmt.bytesToHex(h.finalResult(), .lower), .size = size };
}

/// Copies `src` to the new file `dst`, hashing what it copies.
fn copyHashing(io: Io, src: []const u8, dst: []const u8) !Hashed {
    var in = try Io.Dir.cwd().openFile(io, src, .{ .follow_symlinks = false, .allow_directory = false });
    defer in.close(io);
    if ((try in.stat(io)).kind != .file) return error.NotAFile;
    var out = try Io.Dir.cwd().createFile(io, dst, .{ .truncate = true, .permissions = util.private_file });
    defer out.close(io);
    var h = Sha256.init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const got = try readSome(in, io, &buf);
        if (got == 0) break;
        h.update(buf[0..got]);
        try out.writeStreamingAll(io, buf[0..got]);
        size += got;
    }
    return .{ .sha = std.fmt.bytesToHex(h.finalResult(), .lower), .size = size };
}

// ---- tests ----

const t = std.testing;
const posix = builtin.os.tag != .windows;

const Fx = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    src: []const u8,
    log: log_mod.Log,
    store: Store,

    fn init(f: *Fx) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        const a = f.arena.allocator();
        try f.tmp.dir.createDirPath(t.io, "src");
        f.root = try f.tmp.dir.realPathFileAlloc(t.io, ".", a);
        f.src = try std.fs.path.join(a, &.{ f.root, "src" });
        f.log = try log_mod.Log.open(t.allocator, t.io, try std.fs.path.join(a, &.{ f.root, "actions.jsonl" }));
        f.store = .{ .gpa = t.allocator, .io = t.io, .dir = try std.fs.path.join(a, &.{ f.root, "store" }), .log = &f.log };
    }

    fn deinit(f: *Fx) void {
        f.store.deinit();
        f.log.close();
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn source(f: *Fx) Source {
        return .{ .name = "src", .path = f.src };
    }

    fn put(f: *Fx, sub: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(f.arena.allocator(), &.{ "src", sub });
        if (std.fs.path.dirname(p)) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = data });
    }

    fn get(f: *Fx, sub: []const u8) ![]const u8 {
        return f.tmp.dir.readFileAlloc(t.io, try std.fs.path.join(f.arena.allocator(), &.{ "src", sub }), f.arena.allocator(), .unlimited);
    }

    fn gone(f: *Fx, sub: []const u8) bool {
        _ = f.tmp.dir.statFile(t.io, sub, .{ .follow_symlinks = false }) catch |e| return e == error.FileNotFound;
        return false;
    }

    fn take(f: *Fx, label: []const u8) !Taken {
        return f.store.take(f.arena.allocator(), f.source(), .{ .when = .hand, .label = label });
    }

    /// How many objects the store holds.
    fn objects(f: *Fx) !usize {
        var dir = f.tmp.dir.openDir(t.io, "store/objects", .{ .iterate = true }) catch return 0;
        defer dir.close(t.io);
        var n: usize = 0;
        var w = try dir.walk(f.arena.allocator());
        defer w.deinit();
        while (try w.next(t.io)) |e| {
            if (e.kind == .file and e.depth() == 2) n += 1;
        }
        return n;
    }

    fn logText(f: *Fx) ![]const u8 {
        return f.tmp.dir.readFileAlloc(t.io, "actions.jsonl", f.arena.allocator(), .unlimited);
    }

    fn snapText(f: *Fx, name: []const u8, id: u64) ![]const u8 {
        const a = f.arena.allocator();
        const key = folderKey(name);
        return f.tmp.dir.readFileAlloc(t.io, try std.fmt.allocPrint(a, "store/folders/{s}/{d}", .{ &key, id }), a, .unlimited);
    }
};

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} names, got:", .{want.len});
        for (got) |g| std.debug.print(" {s}", .{g});
        std.debug.print("\n", .{});
    }
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ part, text });
        return error.TestExpectedPart;
    }
}

test "a_snapshot_keeps_each_content_once_and_unchanged_files_are_not_stored_again" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put("a.txt", "x");
    try f.put("b/c.txt", "x");
    try f.put("d.sh", "#!/bin/sh\n");
    if (posix) try f.tmp.dir.setFilePermissions(t.io, "src/d.sh", .fromMode(0o755), .{});
    const one = try f.take("first");
    try t.expectEqual(1, one.id);
    try t.expectEqual(3, one.files);
    // "x" once, and the script
    try t.expectEqual(2, try f.objects());
    const two = try f.take("");
    try t.expectEqual(2, two.id);
    try t.expectEqual(0, two.changed);
    try t.expectEqual(0, two.bytes);
    try t.expectEqual(2, try f.objects());
    const infos = try f.store.list(a, "src");
    try t.expectEqual(2, infos.len);
    try t.expectEqual(1, infos[0].id);
    try t.expectEqualStrings("first", infos[0].label);
    try t.expectEqual(.hand, infos[0].when);
    try t.expectEqual(3, infos[0].files);
    try t.expectEqual(2, infos[1].id);
    // a line a file: sha256, size, exec, mtime, path
    var lines = std.mem.splitScalar(u8, try f.snapText("src", 1), '\n');
    try t.expect(std.mem.startsWith(u8, lines.next().?, "{\"folder\":\"src\""));
    var paths: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        try t.expectEqual(64, parts.next().?.len);
        _ = try std.fmt.parseInt(u64, parts.next().?, 10);
        const exec = parts.next().?;
        _ = try std.fmt.parseInt(i128, parts.next().?, 10);
        const path = parts.next().?;
        try paths.append(a, path);
        if (posix) try t.expectEqualStrings(if (std.mem.eql(u8, path, "d.sh")) "x" else "-", exec);
    }
    try expectNames(&.{ "a.txt", "b/c.txt", "d.sh" }, paths.items);
    try expectHas(try f.logText(), "\"kind\":\"files\",\"event\":\"snapshot\",\"folder\":\"src\",\"id\":1,\"when\":\"hand\",\"label\":\"first\",\"files\":3,\"changed\":3");
}

/// Sets a file's modification time through an open handle: std sets it by
/// path only on POSIX (on Windows that is a TODO panic in std).
fn setModified(dir: Io.Dir, path: []const u8, when: Io.Timestamp) !void {
    var file = try dir.openFile(t.io, path, .{ .mode = .read_write });
    defer file.close(t.io);
    try file.setTimestamps(t.io, .{ .modify_timestamp = .{ .new = when } });
}

test "the_2_s_rule" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.put("n.txt", "old");
    _ = try f.take("");
    // rewritten at once with the same size and time: within 2 s of the
    // snapshot, so it is read again
    const st = try f.tmp.dir.statFile(t.io, "src/n.txt", .{});
    try f.put("n.txt", "new");
    try setModified(f.tmp.dir, "src/n.txt", st.mtime);
    try t.expectEqual(1, (try f.take("")).changed);
    // an older file whose content changes keeping its size and time is
    // not read again
    const old: Io.Timestamp = .{ .nanoseconds = st.mtime.nanoseconds - 100 * std.time.ns_per_s };
    try setModified(f.tmp.dir, "src/n.txt", old);
    try t.expectEqual(0, (try f.take("")).changed);
    try f.put("n.txt", "xyz");
    try setModified(f.tmp.dir, "src/n.txt", old);
    try t.expectEqual(0, (try f.take("")).changed);
}

test "skipped_files_are_named_and_a_huge_folder_gets_none" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put(".git/config", "[core]");
    try f.put("node_modules/m.js", "x");
    try f.put("logs/a.log", "log");
    if (posix) try f.tmp.dir.symLink(t.io, "keep.txt", "src/l", .{});
    try f.put("big.bin", "0123456789");
    try f.put("keep.txt", "k");
    f.store.max_file = 8;
    const src: Source = .{ .name = "src", .path = f.src, .skip = &.{ .{ .folder = "", .pattern = "node_modules" }, .{ .folder = "", .pattern = "*.log" } } };
    const one = try f.store.take(a, src, .{ .when = .hand });
    try t.expectEqual(1, one.files);
    const text = try f.snapText("src", 1);
    for ([_][]const u8{ "-\tgit\t.git\n", "-\tskip\tnode_modules\n", "-\tskip\tlogs/a.log\n", "-\tbig\tbig.bin\n" }) |line| try expectHas(text, line);
    if (posix) try expectHas(text, "-\tlink\tl\n");
    // over the limit: none, and /status says why
    f.store.max_files = 1;
    try f.put("more.txt", "m");
    const huge = try f.store.take(a, src, .{ .when = .hand });
    try t.expectEqualStrings("over 1 files", huge.refused.?);
    try t.expectEqual(1, (try f.store.list(a, "src")).len);
    try t.expectEqualStrings("src: none (over 1 files)\n", try f.store.note(a));
    try expectHas(try f.logText(), "\"event\":\"snapshot skipped\",\"folder\":\"src\",\"why\":\"over 1 files\"");
    f.store.max_files = 20_000;
    _ = try f.store.take(a, src, .{ .when = .hand });
    try t.expectEqualStrings("", try f.store.note(a));
}

test "old_snapshots_and_their_objects_are_deleted" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const fs = try folders.parse(a, "[src]\nsnapshots = 2\n");
    for ([_][]const u8{ "one", "two", "three" }) |c| {
        try f.put("a.txt", c);
        _ = try f.take("");
    }
    try t.expectEqual(3, try f.objects());
    // a temporary file left by a take that was cut off
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "store/objects/.tmp-0011223344556677", .data = "x" });
    const p = try f.store.prune(a, &fs);
    try t.expectEqual(1, p.snapshots);
    try t.expectEqual(1, p.objects);
    const left = try f.store.list(a, "src");
    try t.expectEqual(2, left.len);
    try t.expectEqual(2, left[0].id);
    try t.expectEqual(2, try f.objects());
    try t.expect(f.gone("store/objects/.tmp-0011223344556677"));
    try expectHas(try f.logText(), "\"event\":\"prune\",\"snapshots\":1,\"objects\":1");
    // over the cap the oldest go, but a folder keeps its newest
    f.store.total_mb = 0;
    try t.expectEqual(1, (try f.store.prune(a, &fs)).snapshots);
    const last = try f.store.list(a, "src");
    try t.expectEqual(1, last.len);
    try t.expectEqual(3, last[0].id);
}

test "restore_puts_back_deletes_added_files_and_can_be_undone" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const src: Source = .{ .name = "src", .path = f.src, .skip = &.{.{ .folder = "", .pattern = "*.log" }} };
    try f.put("a", "1");
    try f.put("b", "2");
    _ = try f.store.take(a, src, .{ .when = .hand });
    try f.put("a", "9");
    try f.tmp.dir.deleteFile(t.io, "src/b");
    try f.put("c", "3");
    try f.put("logs/x.log", "kept");
    const r = try f.store.restore(a, src, 1, .{});
    try t.expectEqual(2, r.before_id);
    try expectNames(&.{ "a", "b" }, r.written);
    try expectNames(&.{"c"}, r.deleted);
    try t.expectEqual(0, r.failed.len);
    try t.expectEqualStrings("1", try f.get("a"));
    try t.expectEqualStrings("2", try f.get("b"));
    try t.expect(f.gone("src/c"));
    try t.expectEqualStrings("kept", try f.get("logs/x.log"));
    // and undone
    const u = try f.store.restore(a, src, 2, .{});
    try t.expectEqual(3, u.before_id);
    try t.expectEqualStrings("9", try f.get("a"));
    try t.expectEqualStrings("3", try f.get("c"));
    try t.expect(f.gone("src/b"));
    try expectHas(try f.logText(), "\"event\":\"restore\",\"folder\":\"src\",\"id\":1,\"before_id\":2,\"written\":2,\"deleted\":1");
    try t.expectError(error.NoSuchSnapshot, f.store.restore(a, src, 99, .{}));
}

test "restore_never_writes_through_a_symbolic_link" {
    if (!posix) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put("d/f", "1");
    try f.put("g", "file");
    _ = try f.take("");
    // d becomes a link to a folder outside; g a link to a file outside
    try f.tmp.dir.createDirPath(t.io, "outside");
    try f.tmp.dir.deleteTree(t.io, "src/d");
    try f.tmp.dir.symLink(t.io, "../outside", "src/d", .{ .is_directory = true });
    try f.tmp.dir.deleteFile(t.io, "src/g");
    try f.tmp.dir.symLink(t.io, "../outside/g-target", "src/g", .{});
    const r = try f.store.restore(a, f.source(), 1, .{});
    try t.expect(f.gone("outside/f"));
    try t.expect(f.gone("outside/g-target"));
    try t.expectEqual(1, r.failed.len);
    try t.expectEqualStrings("d/f", r.failed[0].path);
    try t.expectEqualStrings("a symbolic link on the way", r.failed[0].why);
    // the link where the snapshot had a file is replaced by the file
    try t.expectEqual(.file, (try f.tmp.dir.statFile(t.io, "src/g", .{ .follow_symlinks = false })).kind);
    try t.expectEqualStrings("file", try f.get("g"));
}

test "a_folder_that_is_a_symbolic_link_is_neither_snapshotted_nor_restored" {
    if (!posix) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put("a", "1");
    _ = try f.take("");
    try f.tmp.dir.createDirPath(t.io, "elsewhere");
    try f.tmp.dir.deleteTree(t.io, "src");
    try f.tmp.dir.symLink(t.io, "elsewhere", "src", .{ .is_directory = true });
    try t.expectError(error.LinkOnTheWay, f.take(""));
    try t.expectError(error.LinkOnTheWay, f.store.restore(a, f.source(), 1, .{}));
    try t.expect(f.gone("elsewhere/a"));
}

var clones: std.atomic.Value(u32) = .init(0);

/// A stand-in clone helper: copies, and counts.
fn cloneCopy(io: Io, src: []const u8, dst: []const u8) anyerror!bool {
    _ = clones.fetchAdd(1, .monotonic);
    try Io.Dir.cwd().copyFile(src, Io.Dir.cwd(), dst, io, .{});
    return true;
}

/// A file system that can't clone.
fn cloneNever(io: Io, src: []const u8, dst: []const u8) anyerror!bool {
    _ = io;
    _ = src;
    _ = dst;
    return false;
}

test "objects_are_cloned_where_the_file_system_can" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    clones.store(0, .monotonic);
    f.store.clone = cloneCopy;
    try f.put("a", "alpha");
    try f.put("b", "beta");
    _ = try f.take("");
    try t.expectEqual(2, clones.load(.monotonic));
    try t.expectEqual(2, try f.objects());
    // a file read again is cloned again; its object is kept once
    try f.put("a", "gamma!");
    _ = try f.take("");
    try t.expect(clones.load(.monotonic) >= 3);
    try t.expectEqual(3, try f.objects());
    // where it can't, a plain copy
    f.store.clone = cloneNever;
    const before = clones.load(.monotonic);
    try f.put("b", "delta!!");
    _ = try f.take("");
    try t.expectEqual(before, clones.load(.monotonic));
    try t.expectEqual(4, try f.objects());
    _ = try f.store.restore(a, f.source(), 1, .{});
    try t.expectEqualStrings("alpha", try f.get("a"));
    try t.expectEqualStrings("beta", try f.get("b"));
    _ = try f.store.restore(a, f.source(), 3, .{});
    try t.expectEqualStrings("gamma!", try f.get("a"));
    try t.expectEqualStrings("delta!!", try f.get("b"));
}

test "changes_lists_added_changed_and_removed" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put("a", "1");
    try f.put("b", "2");
    _ = try f.take("");
    try f.put("a", "10");
    try f.tmp.dir.deleteFile(t.io, "src/b");
    try f.put("c", "3");
    _ = try f.take("");
    const c2 = try f.store.changes(a, "src", 2);
    try t.expectEqual(1, c2.before.?);
    try expectNames(&.{"c"}, c2.added);
    try expectNames(&.{"a"}, c2.changed);
    try expectNames(&.{"b"}, c2.removed);
    const c1 = try f.store.changes(a, "src", 1);
    try t.expectEqual(null, c1.before);
    try expectNames(&.{ "a", "b" }, c1.added);
    try t.expectError(error.NoSuchSnapshot, f.store.changes(a, "src", 7));
}
