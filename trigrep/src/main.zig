const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const query = @import("query.zig");
const index = @import("index.zig");
const walk = @import("walk.zig");
const search = @import("search.zig");
const engine = @import("engine.zig");
const mcp = @import("mcp.zig");
const watch = @import("watch.zig");
const view = @import("view.zig");
const View = view.View;

pub const version = "0.2.0";

const usage =
    \\trigrep: indexed code search
    \\
    \\Usage:
    \\  trigrep [OPTIONS] PATTERN [PATH]   search; builds the index on first use
    \\  trigrep index [--update] [PATH]    build or rebuild the index; --update only
    \\                                     re-indexes files that changed
    \\  trigrep status [PATH]              show the index and how many files changed
    \\  trigrep watch [PATH]               keep the index fresh; searches skip the full walk
    \\  trigrep mcp                        run as an MCP server on stdin/stdout
    \\
    \\Search options:
    \\  -i, --ignore-case          case-insensitive (ASCII)
    \\  -F, --fixed-strings        treat PATTERN as a literal string
    \\  -w, --word-regexp          match whole words only
    \\  -l, --files-with-matches   print only the paths of matching files
    \\  -c, --count                print path:count for matching files
    \\  -m, --max-count N          stop after N matching lines per file
    \\  -A, -B, -C N               N lines of context after, before, or around matches
    \\  -g, --glob GLOB            only files matching GLOB; !GLOB excludes (repeatable)
    \\  -t, --type TYPE            only files of TYPE, e.g. rust, py, ts (repeatable)
    \\  -T, --type-not TYPE        skip files of TYPE
    \\      --type-list            list the file types
    \\  -o, --only-matching        print only the matched text
    \\      --json                 ripgrep's JSON Lines output
    \\  -e, --regexp PATTERN       the pattern (for patterns starting with -)
    \\      --hidden               include hidden files and directories
    \\      --no-index             scan every file, don't use or build an index
    \\      --trust-index          skip the freshness check (faster; misses edits)
    \\  -j, --threads N            worker threads (default: CPU count)
    \\      --stats                print timings and counts to stderr
    \\  -h, --help                 show this help
    \\  -V, --version              show the version
    \\
    \\Output is path:line:text. Exit status: 0 if something matched, 1 if not, 2 on error.
    \\Indexes live in $TRIGREP_INDEX_DIR, $XDG_CACHE_HOME/trigrep or ~/.cache/trigrep.
    \\
;

const Command = enum { search, index, status, mcp, watch };

const Args = struct {
    command: Command = .search,
    pattern: ?[]const u8 = null,
    path: ?[]const u8 = null,
    opts: regex.Options = .{},
    mode: search.Mode = .lines,
    max_count: ?usize = null,
    context: search.Context = .{},
    update: bool = false,
    globs: std.ArrayList([]const u8) = .empty,
    types: std.ArrayList([]const u8) = .empty,
    types_not: std.ArrayList([]const u8) = .empty,
    json: bool = false,
    only_matching: bool = false,
    hidden: bool = false,
    no_index: bool = false,
    trust_index: bool = false,
    threads: ?usize = null,
    stats: bool = false,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("trigrep: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseArgs(arena: Allocator, argv: []const []const u8) !Args {
    var a = Args{};
    var positionals: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    var only_positional = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (only_positional or arg.len < 2 or arg[0] != '-') {
            try positionals.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_positional = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            var name = arg[2..];
            var inline_value: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
                inline_value = name[eq + 1 ..];
                name = name[0..eq];
            }
            const value = struct {
                fn get(argv_: []const []const u8, i_: *usize, inline_: ?[]const u8, n: []const u8) []const u8 {
                    if (inline_) |v| return v;
                    i_.* += 1;
                    if (i_.* >= argv_.len) fail("--{s} needs a value", .{n});
                    return argv_[i_.*];
                }
            }.get;
            if (std.mem.eql(u8, name, "ignore-case")) a.opts.ignore_case = true
            else if (std.mem.eql(u8, name, "fixed-strings")) a.opts.fixed_string = true
            else if (std.mem.eql(u8, name, "word-regexp")) a.opts.word = true
            else if (std.mem.eql(u8, name, "files-with-matches")) a.mode = .files_with_matches
            else if (std.mem.eql(u8, name, "count")) a.mode = .count
            else if (std.mem.eql(u8, name, "max-count")) a.max_count = std.fmt.parseInt(usize, value(argv, &i, inline_value, name), 10) catch fail("bad --max-count", .{})
            else if (std.mem.eql(u8, name, "glob")) try a.globs.append(arena, value(argv, &i, inline_value, name))
            else if (std.mem.eql(u8, name, "context")) {
                const n = std.fmt.parseInt(usize, value(argv, &i, inline_value, name), 10) catch fail("bad --context", .{});
                a.context = .{ .before = n, .after = n };
            } else if (std.mem.eql(u8, name, "after-context")) a.context.after = std.fmt.parseInt(usize, value(argv, &i, inline_value, name), 10) catch fail("bad --after-context", .{})
            else if (std.mem.eql(u8, name, "before-context")) a.context.before = std.fmt.parseInt(usize, value(argv, &i, inline_value, name), 10) catch fail("bad --before-context", .{})
            else if (std.mem.eql(u8, name, "update")) a.update = true
            else if (std.mem.eql(u8, name, "type")) try a.types.append(arena, value(argv, &i, inline_value, name))
            else if (std.mem.eql(u8, name, "type-not")) try a.types_not.append(arena, value(argv, &i, inline_value, name))
            else if (std.mem.eql(u8, name, "json")) a.json = true
            else if (std.mem.eql(u8, name, "only-matching")) a.only_matching = true
            else if (std.mem.eql(u8, name, "type-list")) {
                const types = @import("types.zig");
                var buf: [8192]u8 = undefined;
                var w = std.fs.File.stdout().writerStreaming(&buf);
                for (types.all) |t| {
                    w.interface.print("{s}: ", .{t.name}) catch {};
                    for (t.globs, 0..) |g, k| w.interface.print("{s}{s}", .{ if (k > 0) ", " else "", g }) catch {};
                    w.interface.writeAll("\n") catch {};
                }
                w.interface.flush() catch {};
                std.process.exit(0);
            }
            else if (std.mem.eql(u8, name, "regexp")) a.pattern = value(argv, &i, inline_value, name)
            else if (std.mem.eql(u8, name, "hidden")) a.hidden = true
            else if (std.mem.eql(u8, name, "no-index")) a.no_index = true
            else if (std.mem.eql(u8, name, "trust-index")) a.trust_index = true
            else if (std.mem.eql(u8, name, "threads")) a.threads = std.fmt.parseInt(usize, value(argv, &i, inline_value, name), 10) catch fail("bad --threads", .{})
            else if (std.mem.eql(u8, name, "stats")) a.stats = true
            else if (std.mem.eql(u8, name, "help")) {
                std.fs.File.stdout().writeAll(usage) catch {};
                std.process.exit(0);
            } else if (std.mem.eql(u8, name, "version")) {
                std.fs.File.stdout().writeAll("trigrep " ++ version ++ "\n") catch {};
                std.process.exit(0);
            }
            // Accepted for ripgrep compatibility; output already looks like this.
            else if (std.mem.eql(u8, name, "line-number") or std.mem.eql(u8, name, "no-heading") or
                std.mem.eql(u8, name, "with-filename") or std.mem.eql(u8, name, "color") or
                std.mem.eql(u8, name, "no-ignore-messages")) {}
            else fail("unknown option --{s}", .{name});
            continue;
        }
        // Short options, possibly bundled (-il). Value options take the rest or the next arg.
        var k: usize = 1;
        while (k < arg.len) : (k += 1) {
            const c = arg[k];
            const takes_value = c == 'm' or c == 'g' or c == 'e' or c == 'j' or c == 'A' or c == 'B' or c == 'C' or c == 't' or c == 'T';
            var v: []const u8 = "";
            if (takes_value) {
                if (k + 1 < arg.len) {
                    v = arg[k + 1 ..];
                } else {
                    i += 1;
                    if (i >= argv.len) fail("-{c} needs a value", .{c});
                    v = argv[i];
                }
            }
            switch (c) {
                'i' => a.opts.ignore_case = true,
                'F' => a.opts.fixed_string = true,
                'w' => a.opts.word = true,
                'l' => a.mode = .files_with_matches,
                'c' => a.mode = .count,
                'm' => a.max_count = std.fmt.parseInt(usize, v, 10) catch fail("bad -m value", .{}),
                'g' => try a.globs.append(arena, v),
                'e' => a.pattern = v,
                'j' => a.threads = std.fmt.parseInt(usize, v, 10) catch fail("bad -j value", .{}),
                't' => try a.types.append(arena, v),
                'T' => try a.types_not.append(arena, v),
                'o' => a.only_matching = true,
                'A' => a.context.after = std.fmt.parseInt(usize, v, 10) catch fail("bad -A value", .{}),
                'B' => a.context.before = std.fmt.parseInt(usize, v, 10) catch fail("bad -B value", .{}),
                'C' => {
                    const n = std.fmt.parseInt(usize, v, 10) catch fail("bad -C value", .{});
                    a.context = .{ .before = n, .after = n };
                },
                'h' => {
                    std.fs.File.stdout().writeAll(usage) catch {};
                    std.process.exit(0);
                },
                'V' => {
                    std.fs.File.stdout().writeAll("trigrep " ++ version ++ "\n") catch {};
                    std.process.exit(0);
                },
                'n', 'H' => {},
                else => fail("unknown option -{c}", .{c}),
            }
            if (takes_value) break;
        }
    }

    var pos = positionals.items;
    if (pos.len > 0 and a.pattern == null) {
        if (std.mem.eql(u8, pos[0], "index")) {
            a.command = .index;
            pos = pos[1..];
        } else if (std.mem.eql(u8, pos[0], "status")) {
            a.command = .status;
            pos = pos[1..];
        } else if (std.mem.eql(u8, pos[0], "mcp")) {
            a.command = .mcp;
            pos = pos[1..];
        } else if (std.mem.eql(u8, pos[0], "watch")) {
            a.command = .watch;
            pos = pos[1..];
        }
    }
    if (a.command == .search and a.pattern == null) {
        if (pos.len == 0) {
            std.fs.File.stderr().writeAll(usage) catch {};
            std.process.exit(2);
        }
        a.pattern = pos[0];
        pos = pos[1..];
    }
    if (pos.len > 1) fail("only one PATH is supported", .{});
    if (pos.len == 1) a.path = pos[0];
    return a;
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try std.process.argsAlloc(arena);
    const a = try parseArgs(arena, argv);
    var diag = engine.Diag{};

    switch (a.command) {
        .mcp => return mcp.serve(gpa),
        .watch => return watchMain(gpa, arena, a),
        .index => {
            const target = engine.resolve(arena, a.path, &diag) catch fail("{s}", .{diag.message});
            if (a.update) {
                const found = (try engine.findIndex(arena, target)) orelse fail("no index covers {s}; run `trigrep index` first", .{target});
                var v = View.open(arena, found.path) catch |err| fail("can't read index: {s}; run `trigrep index`", .{@errorName(err)});
                defer v.close();
                const entries = try walk.walk(arena, found.root, .{});
                const changed = try engine.diffIndex(arena, &v, entries);
                const u = engine.updateDelta(gpa, arena, found.root, found.path, &v, changed, a.threads) catch |err| fail("update failed: {s}", .{@errorName(err)});
                std.debug.print("trigrep: {s}\n", .{try engine.describeUpdate(arena, u)});
                return;
            }
            const b = engine.buildIndex(gpa, arena, target, a.threads) catch |err| fail("indexing failed: {s}", .{@errorName(err)});
            std.debug.print("trigrep: {s}\n", .{try engine.describeBuild(arena, target, b)});
            return;
        },
        .status => {
            const target = engine.resolve(arena, a.path, &diag) catch fail("{s}", .{diag.message});
            const st = (try engine.status(arena, target)) orelse {
                std.debug.print("trigrep: no index covers {s}; run `trigrep index`\n", .{target});
                std.process.exit(1);
            };
            try std.fs.File.stdout().writeAll(try engine.describeStatus(arena, st));
            return;
        },
        .search => {},
    }

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&out_buf);
    const out = &stdout.interface;
    const req = engine.Request{
        .pattern = a.pattern.?,
        .path = a.path,
        .opts = a.opts,
        .mode = a.mode,
        .max_count = a.max_count,
        .context = a.context,
        .globs = a.globs.items,
        .types = a.types.items,
        .types_not = a.types_not.items,
        .format = if (a.json) .json else .text,
        .only_matching = a.only_matching,
        .hidden = a.hidden,
        .no_index = a.no_index,
        .trust_index = a.trust_index,
        .threads = a.threads,
        .watch = if (watch.supported) .{ .ptr = undefined, .changes = daemonChanges, .seeded = daemonSeeded, .rebased = daemonRebased, .auto_update = false } else null,
    };
    const outcome = engine.run(gpa, arena, req, out, &diag) catch |err| {
        out.flush() catch {};
        if (err == error.Failed) fail("{s}", .{diag.message});
        fail("{s}", .{@errorName(err)});
    };
    out.flush() catch {};
    if (outcome.built_index) |b| std.debug.print("trigrep: {s}\n", .{b});
    if (outcome.updated_index) |u| std.debug.print("trigrep: {s}\n", .{u});
    if (outcome.note) |n| std.debug.print("trigrep: {s}\n", .{n});
    if (a.stats) std.debug.print("trigrep: {s}\n", .{outcome.stats});
    std.process.exit(if (outcome.totals.lines_matched > 0) 0 else 1);
}

fn daemonChanges(_: *anyopaque, arena: Allocator, _: []const u8, index_path: []const u8, build_id: u64, hidden: bool) ?watch.Changes {
    if (hidden) return null;
    const sock = watch.socketPath(arena, index_path) catch return null;
    return watch.query(arena, sock, build_id);
}

fn daemonSeeded(_: *anyopaque, _: []const u8, _: u64, _: bool, _: []const []const u8) u64 {
    return 0; // The daemon re-seeds itself.
}

fn daemonRebased(_: *anyopaque, _: []const u8, _: u64, _: u64) void {}

fn readBuildId(path: []const u8) ?u64 {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return view.stateId(fba.allocator(), path);
}

fn reseed(gpa: Allocator, w: *watch.Watcher, root: []const u8, index_path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    w.beginSeed();
    var v = try View.open(arena, index_path);
    defer v.close();
    const entries = try walk.walk(arena, root, .{});
    const changed = try engine.diffIndex(arena, &v, entries);
    _ = w.seed(v.state_id, changed);
    std.debug.print("trigrep: tracking {d} files, {d} changed since indexing\n", .{ entries.len, changed.len });
}

fn updateFromWatcher(gpa: Allocator, w: *watch.Watcher, root: []const u8, index_path: []const u8, threads: ?usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var v = try View.open(arena, index_path);
    defer v.close();
    const ch = try w.changes(arena, v.state_id);
    if (ch.full) return; // the main loop re-seeds first
    var changed: std.ArrayList([]const u8) = .empty;
    try changed.appendSlice(arena, ch.files);
    for (ch.dirs) |d| {
        for (try walk.walk(arena, root, .{ .prefix = d })) |e| try changed.append(arena, e.path);
        var id: u32 = 0;
        while (id < v.file_count) : (id += 1) {
            const pth = v.file(id).path;
            if (v.live(id) and pth.len > d.len and std.mem.startsWith(u8, pth, d) and pth[d.len] == '/')
                try changed.append(arena, try arena.dupe(u8, pth));
        }
    }
    const u = try engine.updateDelta(gpa, arena, root, index_path, &v, changed.items, threads);
    w.rebased(ch.seq, u.state_id);
    std.debug.print("trigrep: {d} changes; {s}\n", .{ changed.items.len, try engine.describeUpdate(arena, u) });
}

fn watchMain(gpa: Allocator, arena: Allocator, a: Args) !void {
    if (!watch.supported) fail("watch is only supported on macOS and Linux", .{});
    var diag = engine.Diag{};
    const target = engine.resolve(arena, a.path, &diag) catch fail("{s}", .{diag.message});
    var found = try engine.findIndex(arena, target);
    if (found == null or readBuildId(found.?.path) == null) {
        const r = if (found) |f| f.root else ((try engine.gitRoot(arena, target)) orelse target);
        const b = engine.buildIndex(gpa, arena, r, a.threads) catch |err| fail("indexing failed: {s}", .{@errorName(err)});
        std.debug.print("trigrep: {s}\n", .{try engine.describeBuild(arena, r, b)});
        found = .{ .root = r, .path = b.path };
    }
    const root = found.?.root;
    const index_path = found.?.path;
    const w = try watch.Watcher.create(gpa, root, false);
    if (w.failed) fail("can't watch {s}", .{root});
    const sock = try watch.socketPath(arena, index_path);
    watch.ensureSocketDir(sock) catch |err| fail("socket directory for {s}: {s}", .{ sock, @errorName(err) });
    _ = try std.Thread.spawn(.{}, watch.serve, .{ w, sock });
    std.debug.print("trigrep: watching {s} (socket {s}); Ctrl-C stops\n", .{ root, sock });

    var quiet_since = std.time.milliTimestamp();
    var last_count: usize = 0;
    while (true) {
        const p = w.pending();
        const current = readBuildId(index_path);
        if (p.needs_seed or current == null or current.? != w.base_id) {
            if (current == null) {
                const b = engine.buildIndex(gpa, arena, root, a.threads) catch |err| fail("indexing failed: {s}", .{@errorName(err)});
                std.debug.print("trigrep: {s}\n", .{try engine.describeBuild(arena, root, b)});
            }
            reseed(gpa, w, root, index_path) catch |err| std.debug.print("trigrep: re-seed failed: {s}\n", .{@errorName(err)});
        } else {
            if (p.count != last_count) quiet_since = std.time.milliTimestamp();
            last_count = p.count;
            // Enough changes and a quiet second (e.g. after a branch switch): fold them
            // into the index delta (or rebuild, if the delta would get too big).
            if (p.count >= engine.auto_update_threshold and std.time.milliTimestamp() - quiet_since > 1000) {
                updateFromWatcher(gpa, w, root, index_path, a.threads) catch |err|
                    std.debug.print("trigrep: index update failed: {s}\n", .{@errorName(err)});
            }
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

test {
    _ = regex;
    _ = query;
    _ = index;
    _ = walk;
    _ = search;
    _ = engine;
    _ = mcp;
    _ = @import("watch.zig");
    _ = view;
    _ = @import("glob.zig");
}
