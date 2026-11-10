//! MCP server over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout. Exposes
//! trigrep_search, trigrep_index and trigrep_status. Nothing but protocol messages is
//! ever written to stdout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine.zig");
const search = @import("search.zig");
const watch = @import("watch.zig");
const version = @import("main.zig").version;

const Value = std.json.Value;

const known_versions = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25" };
const default_version = "2025-06-18";
const default_max_results = 200;

const search_schema =
    \\{"type":"object","properties":{
    \\"pattern":{"type":"string","description":"Regex (ripgrep syntax: classes, \\b, \\w, alternation, repetition; no lookaround or backreferences). Use fixed_strings for literal text."},
    \\"path":{"type":"string","description":"Directory or file to search. Default: the server's working directory."},
    \\"ignore_case":{"type":"boolean"},
    \\"fixed_strings":{"type":"boolean","description":"Treat pattern as literal text."},
    \\"word":{"type":"boolean","description":"Whole words only."},
    \\"glob":{"type":"array","items":{"type":"string"},"description":"Only paths matching these globs, e.g. [\"*.ts\", \"!*.test.ts\"]."},
    \\"output":{"type":"string","enum":["lines","files","count"],"description":"lines: path:line:text (default); files: matching paths; count: path:count."},
    \\"max_results":{"type":"integer","description":"Stop after this many output lines (default 200)."},
    \\"max_per_file":{"type":"integer","description":"At most this many matching lines per file."}
    \\},"required":["pattern"]}
;

const path_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory. Default: the server's working directory."}}}
;

const tools_json = "{\"tools\":[" ++
    "{\"name\":\"trigrep_search\",\"description\":\"Search file contents by regex, ripgrep-style, using a trigram index: much faster than grep or rg on large repos, and results always include edits made since indexing. Returns path:line:text lines. The first search in a repo builds the index (seconds on very large repos). Respects .gitignore; skips hidden and binary files.\",\"inputSchema\":" ++ oneLine(search_schema) ++ "}," ++
    "{\"name\":\"trigrep_index\",\"description\":\"Rebuild the search index for a directory, e.g. after switching branches or a large pull. Optional: searches stay correct without it, they just slow down when many files changed.\",\"inputSchema\":" ++ oneLine(path_schema) ++ "}," ++
    "{\"name\":\"trigrep_status\",\"description\":\"Show which index covers a directory and how many files changed since it was built.\",\"inputSchema\":" ++ oneLine(path_schema) ++ "}" ++
    "]}";

/// Messages are newline-delimited, so the schemas written above across lines must not
/// contain raw newlines.
fn oneLine(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var buf: [text.len]u8 = undefined;
        var n: usize = 0;
        for (text) |c| {
            if (c != '\n') {
                buf[n] = c;
                n += 1;
            }
        }
        const final = buf[0..n].*;
        return &final;
    }
}

/// Watchers started by this server, one per searched root. The first search of a root
/// walks the tree and seeds its watcher; later searches only re-check what changed.
pub const Registry = struct {
    gpa: Allocator,
    watchers: std.StringHashMapUnmanaged(*watch.Watcher) = .empty,

    pub fn deinit(r: *Registry) void {
        var it = r.watchers.valueIterator();
        while (it.next()) |w| w.*.destroy();
        r.watchers.deinit(r.gpa);
    }

    pub fn hook(r: *Registry) engine.WatchHook {
        return .{ .ptr = r, .changes = changes, .seeded = seeded };
    }

    fn get(r: *Registry, root: []const u8) ?*watch.Watcher {
        return r.watchers.get(root);
    }

    fn changes(ptr: *anyopaque, arena: Allocator, root: []const u8, _: []const u8, build_id: u64, hidden: bool) ?watch.Changes {
        if (!watch.supported or hidden) return null;
        const r: *Registry = @ptrCast(@alignCast(ptr));
        const w = r.watchers.get(root) orelse blk: {
            const nw = watch.Watcher.create(r.gpa, root, false) catch return null;
            r.watchers.put(r.gpa, nw.root, nw) catch {
                nw.destroy();
                return null;
            };
            break :blk nw;
        };
        const ch = w.changes(arena, build_id) catch return null;
        if (ch.full) w.beginSeed();
        return ch;
    }

    fn seeded(ptr: *anyopaque, root: []const u8, build_id: u64, hidden: bool, changed: []const []const u8) void {
        if (hidden) return;
        const r: *Registry = @ptrCast(@alignCast(ptr));
        if (r.watchers.get(root)) |w| w.seed(build_id, changed);
    }
};

const RpcError = struct { code: i32, message: []const u8 };

const ToolResult = struct { text: []const u8, is_error: bool = false };

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolean(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn int(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const v = obj.get(key) orelse return null;
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else null;
}

fn toolSearch(gpa: Allocator, arena: Allocator, reg: ?*Registry, args: std.json.ObjectMap) !ToolResult {
    const pattern = str(args, "pattern") orelse return .{ .text = "missing argument: pattern", .is_error = true };
    var globs: std.ArrayList([]const u8) = .empty;
    if (args.get("glob")) |g| switch (g) {
        .array => |arr| for (arr.items) |it| {
            if (it == .string) try globs.append(arena, it.string);
        },
        .string => |s| try globs.append(arena, s),
        else => {},
    };
    const mode: search.Mode = if (str(args, "output")) |o|
        (if (std.mem.eql(u8, o, "files")) .files_with_matches else if (std.mem.eql(u8, o, "count")) .count else .lines)
    else
        .lines;
    const limit = int(args, "max_results") orelse default_max_results;
    const req = engine.Request{
        .pattern = pattern,
        .path = str(args, "path"),
        .opts = .{ .ignore_case = boolean(args, "ignore_case"), .fixed_string = boolean(args, "fixed_strings"), .word = boolean(args, "word") },
        .mode = mode,
        .max_count = int(args, "max_per_file"),
        .globs = globs.items,
        .limit = limit,
        .watch = if (reg) |r| r.hook() else null,
    };
    var aw = std.Io.Writer.Allocating.init(arena);
    var diag = engine.Diag{};
    const outcome = engine.run(gpa, arena, req, &aw.writer, &diag) catch |err| {
        return .{ .text = if (err == error.Failed) diag.message else @errorName(err), .is_error = true };
    };
    const w = &aw.writer;
    if (outcome.totals.lines_written == 0) try w.writeAll("No matches.\n");
    if (outcome.totals.truncated)
        try w.print("[stopped at {d} lines; narrow the pattern, add a glob or path, or raise max_results]\n", .{limit});
    if (outcome.built_index) |b| try w.print("[{s}]\n", .{b});
    if (outcome.note) |n| try w.print("[{s}]\n", .{n});
    return .{ .text = aw.written() };
}

fn toolIndex(gpa: Allocator, arena: Allocator, reg: ?*Registry, args: std.json.ObjectMap) !ToolResult {
    var diag = engine.Diag{};
    const target = engine.resolve(arena, str(args, "path"), &diag) catch return .{ .text = diag.message, .is_error = true };
    const w = if (reg) |r| r.get(target) else null;
    const at = if (w) |x| x.mark() else 0;
    const b = engine.buildIndex(gpa, arena, target, null) catch |err|
        return .{ .text = try std.fmt.allocPrint(arena, "indexing failed: {s}", .{@errorName(err)}), .is_error = true };
    // Changes the rebuild saw are in the new index; keep only what happened after it began.
    if (w) |x| x.rebased(at, b.stats.build_id);
    return .{ .text = try engine.describeBuild(arena, target, b) };
}

fn toolStatus(arena: Allocator, args: std.json.ObjectMap) !ToolResult {
    var diag = engine.Diag{};
    const target = engine.resolve(arena, str(args, "path"), &diag) catch return .{ .text = diag.message, .is_error = true };
    const st = (try engine.status(arena, target)) orelse
        return .{ .text = try std.fmt.allocPrint(arena, "No index covers {s} yet; the first trigrep_search there builds one.", .{target}) };
    return .{ .text = try engine.describeStatus(arena, st) };
}

fn writeResponse(w: *std.Io.Writer, id: Value, result_json: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}");
}

fn writeError(w: *std.Io.Writer, id: Value, e: RpcError) !void {
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = e.code, .message = e.message },
    }, .{}, w);
}

/// Handles one JSON-RPC message and writes the reply (if any) to `w`. Returns false
/// when the message was a notification (nothing written).
pub fn handle(gpa: Allocator, arena: Allocator, reg: ?*Registry, line: []const u8, w: *std.Io.Writer) !bool {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch {
        try writeError(w, .null, .{ .code = -32700, .message = "parse error" });
        return true;
    };
    if (parsed != .object) {
        try writeError(w, .null, .{ .code = -32600, .message = "invalid request" });
        return true;
    }
    const msg = parsed.object;
    const id = msg.get("id") orelse return false; // notification: no reply
    const method = str(msg, "method") orelse {
        try writeError(w, id, .{ .code = -32600, .message = "invalid request" });
        return true;
    };
    const params: std.json.ObjectMap = if (msg.get("params")) |p| (if (p == .object) p.object else .init(arena)) else .init(arena);

    if (std.mem.eql(u8, method, "initialize")) {
        var proto: []const u8 = default_version;
        if (str(params, "protocolVersion")) |v| for (known_versions) |k| {
            if (std.mem.eql(u8, v, k)) proto = k;
        };
        const result = try std.fmt.allocPrint(arena,
            \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"trigrep","version":"{s}"}},"instructions":"trigrep_search is a fast, index-backed replacement for grep/rg over the repository; prefer it for content searches."}}
        , .{ proto, version });
        try writeResponse(w, id, result);
    } else if (std.mem.eql(u8, method, "ping")) {
        try writeResponse(w, id, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeResponse(w, id, tools_json);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const name = str(params, "name") orelse {
            try writeError(w, id, .{ .code = -32602, .message = "missing tool name" });
            return true;
        };
        const args: std.json.ObjectMap = if (params.get("arguments")) |a| (if (a == .object) a.object else .init(arena)) else .init(arena);
        const result: ToolResult = if (std.mem.eql(u8, name, "trigrep_search"))
            try toolSearch(gpa, arena, reg, args)
        else if (std.mem.eql(u8, name, "trigrep_index"))
            try toolIndex(gpa, arena, reg, args)
        else if (std.mem.eql(u8, name, "trigrep_status"))
            try toolStatus(arena, args)
        else {
            try writeError(w, id, .{ .code = -32602, .message = "unknown tool" });
            return true;
        };
        var aw = std.Io.Writer.Allocating.init(arena);
        try std.json.Stringify.value(.{
            .content = .{.{ .type = "text", .text = result.text }},
            .isError = result.is_error,
        }, .{}, &aw.writer);
        try writeResponse(w, id, aw.written());
    } else {
        try writeError(w, id, .{ .code = -32601, .message = "method not found" });
    }
    return true;
}

pub fn serve(gpa: Allocator) !void {
    const in_buf = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(in_buf);
    var reader = std.fs.File.stdin().readerStreaming(in_buf);
    const r = &reader.interface;
    var out_buf: [1 << 16]u8 = undefined;
    var writer = std.fs.File.stdout().writerStreaming(&out_buf);
    const w = &writer.interface;
    var reg = Registry{ .gpa = gpa };
    defer reg.deinit();

    while (true) {
        const raw = r.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            error.StreamTooLong => {
                // Skip the rest of an oversized line and report it.
                _ = r.discardDelimiterInclusive('\n') catch return;
                try writeError(w, .null, .{ .code = -32700, .message = "message too long" });
                try w.writeByte('\n');
                try w.flush();
                continue;
            },
            else => return err,
        };
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const replied = handle(gpa, arena_state.allocator(), &reg, line, w) catch |err| blk: {
            std.debug.print("trigrep mcp: {s}\n", .{@errorName(err)});
            break :blk false;
        };
        if (replied) {
            try w.writeByte('\n');
            try w.flush();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests

fn call(line: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    _ = try handle(gpa, arena.allocator(), null, line, &aw.writer);
    return gpa.dupe(u8, aw.written());
}

test "initialize echoes a known protocol version" {
    const gpa = std.testing.allocator;
    const a = try call(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    );
    defer gpa.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "\"capabilities\":{\"tools\":{}}") != null);
    const b = try call(
        \\{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"1999-01-01"}}
    );
    defer gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"protocolVersion\":\"" ++ default_version ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"id\":\"x\"") != null);
}

test "notifications get no reply; errors are JSON-RPC errors" {
    const gpa = std.testing.allocator;
    const a = try call(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer gpa.free(a);
    try std.testing.expectEqualStrings("", a);
    const b = try call("{not json");
    defer gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "-32700") != null);
    const c = try call(
        \\{"jsonrpc":"2.0","id":2,"method":"nope"}
    );
    defer gpa.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "-32601") != null);
}

test "tools/list is valid JSON with three tools" {
    const gpa = std.testing.allocator;
    const a = try call(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
    );
    defer gpa.free(a);
    const parsed = try std.json.parseFromSlice(Value, gpa, a, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOfScalar(u8, a, '\n') == null);
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 3), tools.items.len);
    for (tools.items) |t| try std.testing.expect(t.object.get("inputSchema").? == .object);
}

test "search tool output, truncation and a bad pattern as a tool error" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "one needle\ntwo\nneedle three \"quoted\"\n" });
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Scan without an index: an index would be written to the user's cache dir.
    var args = std.json.ObjectMap.init(arena.allocator());
    try args.put("pattern", .{ .string = "needle" });
    try args.put("path", .{ .string = root });
    try args.put("max_results", .{ .integer = 1 });
    const res = try toolSearchNoIndex(gpa, arena.allocator(), args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "/a.txt:1:one needle\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "[stopped at 1 lines") != null);

    try args.put("pattern", .{ .string = "(" });
    const bad = try toolSearchNoIndex(gpa, arena.allocator(), args);
    try std.testing.expect(bad.is_error);
    try std.testing.expectEqualStrings("invalid pattern", bad.text);
}

/// toolSearch, but scanning without an index so tests don't write to the cache dir.
fn toolSearchNoIndex(gpa: Allocator, arena: Allocator, args: std.json.ObjectMap) !ToolResult {
    var aw = std.Io.Writer.Allocating.init(arena);
    var diag = engine.Diag{};
    const outcome = engine.run(gpa, arena, .{
        .pattern = str(args, "pattern").?,
        .path = str(args, "path"),
        .no_index = true,
        .limit = int(args, "max_results"),
    }, &aw.writer, &diag) catch |err| return .{ .text = if (err == error.Failed) diag.message else @errorName(err), .is_error = true };
    if (outcome.totals.truncated) try aw.writer.print("[stopped at {d} lines]\n", .{int(args, "max_results").?});
    return .{ .text = aw.written() };
}
