//! The MCP server: JSON-RPC over stdio, the tools, and one loop that reads
//! the buses and the requests together, so a wait never holds up other
//! requests. Every tool only reads; the one that can put a frame on a bus,
//! car_diag, exists only in builds with a diagnostic table (diag.zig).
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");
const can = @import("can.zig");
const dbc = @import("dbc.zig");
const profile = @import("profile.zig");
const store = @import("store.zig");
const diag = @import("diag.zig");

pub const max_wait_s = 300;
const supported_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

pub const Op = enum { changes, eq, ne, gt, lt, ge, le };

const Wait = struct {
    id_json: []u8,
    reading: usize,
    op: Op,
    num: ?f64,
    text: ?[]u8,
    start_raw: ?u64,
    began_ns: i128,
    deadline_ns: i128,
};

const Seen = struct { raw: u64, value: f64, label: ?[]const u8, at_ns: i128 };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    prof: *const profile.Profile,
    buses: []store.Bus,
    taps: []?can.Tap,
    /// per bus: its multiplexed messages, by key
    muxed: []std.AutoHashMapUnmanaged(u32, *const dbc.Message),
    waits: std.ArrayList(Wait) = .empty,
    tools_json: []u8,
    /// replies go to this file descriptor, or (tests) into `captured`
    out_fd: linux.fd_t = 1,
    captured: ?*std.ArrayList(u8) = null,
    now_override: ?i128 = null,
    next_reopen_ns: i128 = 0,
    pending: std.ArrayList(u8) = .empty,
    poller: if (diag.enabled) ?diag.Poller else void = if (diag.enabled) null else {},

    pub fn init(gpa: Allocator, io: Io, prof: *const profile.Profile) !Server {
        const buses = try gpa.alloc(store.Bus, prof.buses.len);
        for (buses) |*b| b.* = .{};
        const taps = try gpa.alloc(?can.Tap, prof.buses.len);
        @memset(taps, null);
        const muxed = try gpa.alloc(std.AutoHashMapUnmanaged(u32, *const dbc.Message), prof.buses.len);
        for (muxed, prof.buses) |*m, b| {
            m.* = .empty;
            for (b.db.messages) |*msg| {
                for (msg.signals) |sig| if (sig.mux == .multiplexer) {
                    try m.put(gpa, msg.key, msg);
                    break;
                };
            }
        }
        return .{ .gpa = gpa, .io = io, .prof = prof, .buses = buses, .taps = taps, .muxed = muxed, .tools_json = try toolsJson(gpa, prof) };
    }

    pub fn deinit(s: *Server) void {
        for (s.waits.items) |w| freeWait(s.gpa, w);
        s.waits.deinit(s.gpa);
        for (s.buses) |*b| b.deinit(s.gpa);
        s.gpa.free(s.buses);
        for (s.taps) |t| if (t) |tap| tap.close();
        s.gpa.free(s.taps);
        for (s.muxed) |*m| m.deinit(s.gpa);
        s.gpa.free(s.muxed);
        s.gpa.free(s.tools_json);
        s.pending.deinit(s.gpa);
        if (diag.enabled) if (s.poller) |*p| p.close();
    }

    pub fn now(s: *const Server) i128 {
        if (s.now_override) |n| return n;
        return Io.Clock.awake.now(s.io).nanoseconds;
    }

    // ---- the buses ----

    /// Opens the interfaces that are not open; a missing one is retried.
    pub fn reopen(s: *Server, now_ns: i128) void {
        if (now_ns < s.next_reopen_ns) return;
        s.next_reopen_ns = now_ns + 2 * std.time.ns_per_s;
        for (s.taps, s.prof.buses, s.buses) |*t, pb, *b| {
            if (t.* != null) continue;
            t.* = can.Tap.open(pb.interface, .{ .fd_frames = pb.fd, .nonblock = true }) catch |e| {
                b.problem = @errorName(e);
                continue;
            };
            b.problem = "";
        }
    }

    pub fn onFrame(s: *Server, bus: usize, f: *const can.Frame, kind: can.Kind, now_ns: i128) !void {
        var page: ?u64 = null;
        if (kind != .err) {
            if (s.muxed[bus].get(store.Bus.keyOf(f))) |msg| {
                for (msg.signals) |*sig| if (sig.mux == .multiplexer) {
                    page = sig.raw(f.payload());
                    break;
                };
            }
        }
        try s.buses[bus].put(s.gpa, f, kind, page, now_ns);
    }

    fn drain(s: *Server, bus: usize, now_ns: i128) !void {
        const tap = s.taps[bus] orelse return;
        var f: can.Frame = undefined;
        var n: usize = 0;
        while (n < 4096) : (n += 1) {
            const kind = tap.readNow(&f) catch |e| {
                // the interface went away: close it, and try again later
                tap.close();
                s.taps[bus] = null;
                s.buses[bus].problem = @errorName(e);
                return;
            } orelse return;
            try s.onFrame(bus, &f, kind, now_ns);
        }
    }

    fn seen(s: *const Server, bus: usize, msg: *const dbc.Message, sig: *const dbc.Signal) ?Seen {
        const page: ?u64 = switch (sig.mux) {
            .muxed => |n| n,
            else => null,
        };
        const slot = s.buses[bus].slots.getPtr(store.slotKey(msg.key, page)) orelse return null;
        const data = slot.data[0..slot.len];
        if (!msg.present(sig, data)) return null;
        const r = sig.raw(data) orelse return null;
        return .{ .raw = r, .value = sig.physical(r), .label = sig.label(r), .at_ns = slot.at_ns };
    }

    fn reading(s: *const Server, i: usize) ?Seen {
        const r = s.prof.readings[i];
        return s.seen(r.bus, r.msg, r.sig);
    }

    // ---- requests ----

    /// Takes bytes from stdin; handles every complete line.
    pub fn feed(s: *Server, bytes: []const u8) !void {
        try s.pending.appendSlice(s.gpa, bytes);
        while (std.mem.indexOfScalar(u8, s.pending.items, '\n')) |nl| {
            const line = try s.gpa.dupe(u8, s.pending.items[0..nl]);
            defer s.gpa.free(line);
            std.mem.copyForwards(u8, s.pending.items, s.pending.items[nl + 1 ..]);
            s.pending.shrinkRetainingCapacity(s.pending.items.len - nl - 1);
            try s.handleLine(line);
        }
        if (s.pending.items.len > 16 << 20) s.pending.clearRetainingCapacity();
    }

    pub fn handleLine(s: *Server, raw: []const u8) !void {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch
            return s.send(a, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error\"}}");
        if (v != .object) return;
        const o = v.object;
        const method = str(o.get("method")) orelse return; // a reply (to nothing we sent): ignore
        const idv = o.get("id") orelse {
            if (std.mem.eql(u8, method, "notifications/cancelled")) s.cancel(a, o.get("params"));
            return;
        };
        const id = try std.json.Stringify.valueAlloc(a, idv, .{});
        if (std.mem.eql(u8, method, "initialize")) {
            const asked = if (o.get("params")) |p| str(objGet(p, "protocolVersion")) else null;
            const version = for (supported_versions) |sv| {
                if (asked != null and std.mem.eql(u8, asked.?, sv)) break sv;
            } else supported_versions[0];
            const instructions = try std.fmt.allocPrint(a, "canmcp reads the CAN bus of {s}. Values come only from frames seen on the bus. None of these tools can drive, unlock or change anything on the car.", .{s.prof.name});
            return s.reply(a, id, try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"canmcp\",\"version\":\"{s}\"}},\"instructions\":{s}}}", .{ version, build_options.version, try jsonStr(a, instructions) }));
        }
        if (std.mem.eql(u8, method, "ping")) return s.reply(a, id, "{}");
        if (std.mem.eql(u8, method, "tools/list")) return s.reply(a, id, s.tools_json);
        if (std.mem.eql(u8, method, "tools/call")) {
            const params = o.get("params") orelse return s.toolText(a, id, "no params", true);
            const name = str(objGet(params, "name")) orelse return s.toolText(a, id, "no tool name", true);
            const args = objGet(params, "arguments");
            if (std.mem.eql(u8, name, "car_readings")) return s.toolText(a, id, try s.readingsText(a), false);
            if (std.mem.eql(u8, name, "bus_status")) return s.toolText(a, id, try s.busText(a), false);
            if (std.mem.eql(u8, name, "car_signals")) return s.signalsTool(a, id, args);
            if (std.mem.eql(u8, name, "car_wait")) return s.waitTool(a, id, args);
            if (diag.enabled and std.mem.eql(u8, name, "car_diag")) return s.diagTool(a, id, args);
            return s.toolText(a, id, try std.fmt.allocPrint(a, "no tool called {s}", .{name}), true);
        }
        return s.send(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id}));
    }

    // ---- tools ----

    fn readingsText(s: *Server, a: Allocator) ![]u8 {
        const t = s.now();
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}:\n", .{s.prof.name}));
        for (s.prof.readings, 0..) |r, i| {
            try out.appendSlice(a, r.name);
            try out.appendSlice(a, ": ");
            if (s.reading(i)) |cur| {
                try out.appendSlice(a, try describe(a, cur, r.unit));
                const age = ageS(t, cur.at_ns);
                if (age >= 2) try out.appendSlice(a, try std.fmt.allocPrint(a, " ({d:.0} s old)", .{age}));
            } else try out.appendSlice(a, "not seen yet");
            try out.append(a, '\n');
        }
        try out.appendSlice(a, try s.busText(a));
        return out.items;
    }

    fn busText(s: *Server, a: Allocator) ![]u8 {
        const t = s.now();
        var out: std.ArrayList(u8) = .empty;
        for (s.prof.buses, s.buses, s.taps) |pb, *b, tap| {
            try out.appendSlice(a, try std.fmt.allocPrint(a, "bus {s} ({s}): ", .{ pb.name, pb.interface }));
            if (tap == null and b.problem.len > 0) {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "not open ({s}), trying again", .{b.problem}));
            } else if (b.last_ns == 0) {
                try out.appendSlice(a, "no frame yet");
            } else {
                const age = ageS(t, b.last_ns);
                if (age * 1000 >= @as(f64, @floatFromInt(s.prof.silent_ms))) {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, "asleep: no frame for {d:.0} s", .{age}));
                } else {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, "awake, {d} frames a second, {d} ids", .{ b.rateAt(t), b.ids() }));
                }
            }
            const errors = b.bus_off + b.error_passive + b.other_errors;
            if (errors > 0) try out.appendSlice(a, try std.fmt.allocPrint(a, "; errors: bus-off {d}, error-passive {d}, other {d}, the last {d:.0} s ago", .{ b.bus_off, b.error_passive, b.other_errors, ageS(t, b.last_error_ns) }));
            try out.append(a, '\n');
        }
        return out.items;
    }

    fn signalsTool(s: *Server, a: Allocator, id: []const u8, args: ?std.json.Value) !void {
        const q = std.mem.trim(u8, str(if (args) |x| objGet(x, "query") else null) orelse "", " ");
        if (q.len == 0) return s.toolText(a, id, "give part of a signal or message name, such as door, speed or temp", true);
        const t = s.now();
        var out: std.ArrayList(u8) = .empty;
        var found: usize = 0;
        const max_lines = 40;
        for (s.prof.buses, 0..) |pb, bi| {
            for (pb.db.messages) |*msg| for (msg.signals) |*sig| {
                const full = try std.fmt.allocPrint(a, "{s}.{s}", .{ msg.name, sig.name });
                if (!containsIgnoreCase(full, q)) continue;
                found += 1;
                if (found > max_lines) continue;
                try out.appendSlice(a, full);
                if (s.seen(bi, msg, sig)) |cur| {
                    try out.appendSlice(a, try std.fmt.allocPrint(a, " = {s} (bus {s}", .{ try describe(a, cur, sig.unit), pb.name }));
                    const age = ageS(t, cur.at_ns);
                    if (age >= 2) try out.appendSlice(a, try std.fmt.allocPrint(a, ", {d:.0} s old", .{age}));
                    try out.appendSlice(a, ")\n");
                } else try out.appendSlice(a, try std.fmt.allocPrint(a, ": not seen (bus {s})\n", .{pb.name}));
            };
        }
        if (found == 0) return s.toolText(a, id, try std.fmt.allocPrint(a, "no signal name contains \"{s}\"", .{q}), false);
        const head = try std.fmt.allocPrint(a, "{d} signal{s} contain \"{s}\"{s}:\n", .{ found, if (found == 1) "" else "s", q, if (found > max_lines) try std.fmt.allocPrint(a, ", the first {d}", .{max_lines}) else "" });
        return s.toolText(a, id, try std.mem.concat(a, u8, &.{ head, out.items }), false);
    }

    fn waitTool(s: *Server, a: Allocator, id: []const u8, args: ?std.json.Value) !void {
        const name = str(if (args) |x| objGet(x, "reading") else null) orelse return s.toolText(a, id, "say which reading: reading = speed, for example", true);
        const ri = s.prof.reading(name) orelse return s.toolText(a, id, try std.fmt.allocPrint(a, "no reading called {s}; there are: {s}", .{ name, try s.readingNames(a) }), true);
        const r = s.prof.readings[ri];
        const op_s = str(if (args) |x| objGet(x, "condition") else null) orelse "changes";
        const op: Op = parseOp(op_s) orelse return s.toolText(a, id, "condition: changes, ==, !=, >, <, >= or <=", true);
        var num: ?f64 = null;
        var text: ?[]const u8 = null;
        if (args) |x| if (objGet(x, "value")) |vv| switch (vv) {
            .integer => |n| num = @floatFromInt(n),
            .float => |f| num = f,
            .number_string => |ns| num = std.fmt.parseFloat(f64, ns) catch null,
            .string => |st| {
                if (std.fmt.parseFloat(f64, st)) |f| num = f else |_| text = st;
            },
            else => {},
        };
        switch (op) {
            .changes => {},
            .eq, .ne => if (num == null and text == null) return s.toolText(a, id, "this condition needs a value", true),
            else => if (num == null) return s.toolText(a, id, "this condition needs a number", true),
        }
        if (text) |txt| {
            const known = for (r.sig.values) |v| {
                if (std.ascii.eqlIgnoreCase(v.label, txt)) break true;
            } else false;
            if (!known) return s.toolText(a, id, try std.fmt.allocPrint(a, "{s} has no value called {s}; it has: {s}", .{ r.name, txt, try labelList(a, r.sig) }), true);
        }
        var secs: f64 = 60;
        if (args) |x| if (objGet(x, "timeout_s")) |tv| switch (tv) {
            .integer => |n| secs = @floatFromInt(n),
            .float => |f| secs = f,
            else => {},
        };
        secs = std.math.clamp(secs, 0, max_wait_s);
        const t = s.now();
        const cur = s.reading(ri);
        var w: Wait = .{
            .id_json = try s.gpa.dupe(u8, id),
            .reading = ri,
            .op = op,
            .num = num,
            .text = if (text) |x| try s.gpa.dupe(u8, x) else null,
            .start_raw = if (cur) |c| c.raw else null,
            .began_ns = t,
            .deadline_ns = t + @as(i128, @intFromFloat(secs * std.time.ns_per_s)),
        };
        if (op != .changes) if (cur) |c| if (holds(&w, c)) {
            defer freeWait(s.gpa, w);
            return s.toolText(a, id, try s.waitDone(a, &w, c, t), false);
        };
        s.waits.append(s.gpa, w) catch |e| {
            freeWait(s.gpa, w);
            return e;
        };
        w = undefined;
    }

    /// Answers the waits that are met or out of time.
    pub fn checkWaits(s: *Server, now_ns: i128) !void {
        var i: usize = s.waits.items.len;
        while (i > 0) {
            i -= 1;
            const w = &s.waits.items[i];
            const cur = s.reading(w.reading);
            const met = if (cur) |c| holds(w, c) else false;
            if (!met and now_ns < w.deadline_ns) continue;
            var arena_state = std.heap.ArenaAllocator.init(s.gpa);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            const text = if (met) try s.waitDone(a, w, cur.?, now_ns) else try s.waitTimedOut(a, w, cur);
            const done = s.waits.orderedRemove(i);
            defer freeWait(s.gpa, done);
            try s.toolText(a, done.id_json, text, false);
        }
    }

    fn waitDone(s: *const Server, a: Allocator, w: *const Wait, cur: Seen, now_ns: i128) ![]u8 {
        const r = s.prof.readings[w.reading];
        const after = ageS(now_ns, w.began_ns);
        if (w.op == .changes) {
            const before = if (w.start_raw) |sr| try describe(a, .{ .raw = sr, .value = r.sig.physical(sr), .label = r.sig.label(sr), .at_ns = 0 }, r.unit) else "not seen";
            return std.fmt.allocPrint(a, "{s} changed after {d:.1} s: {s} -> {s}", .{ r.name, after, before, try describe(a, cur, r.unit) });
        }
        return std.fmt.allocPrint(a, "{s} {s} {s}: yes, after {d:.1} s ({s} is {s})", .{ r.name, opName(w.op), try targetText(a, w), after, r.name, try describe(a, cur, r.unit) });
    }

    fn waitTimedOut(s: *const Server, a: Allocator, w: *const Wait, cur: ?Seen) ![]u8 {
        const r = s.prof.readings[w.reading];
        const secs = @as(f64, @floatFromInt(w.deadline_ns - w.began_ns)) / std.time.ns_per_s;
        const now_text = if (cur) |c| try describe(a, c, r.unit) else "not seen";
        if (w.op == .changes) return std.fmt.allocPrint(a, "{s} did not change within {d:.0} s (it is {s})", .{ r.name, secs, now_text });
        return std.fmt.allocPrint(a, "{s} {s} {s}: not within {d:.0} s ({s} is {s})", .{ r.name, opName(w.op), try targetText(a, w), secs, r.name, now_text });
    }

    fn cancel(s: *Server, a: Allocator, params: ?std.json.Value) void {
        const p = params orelse return;
        const rid = objGet(p, "requestId") orelse return;
        const want = std.json.Stringify.valueAlloc(a, rid, .{}) catch return;
        var i: usize = s.waits.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, s.waits.items[i].id_json, want)) freeWait(s.gpa, s.waits.orderedRemove(i));
        }
    }

    fn diagTool(s: *Server, a: Allocator, id: []const u8, args: ?std.json.Value) !void {
        if (!diag.enabled) return;
        const name = str(if (args) |x| objGet(x, "request") else null) orelse return s.toolText(a, id, "say which request", true);
        const entry = for (diag.table) |e| {
            if (std.mem.eql(u8, e.name, name)) break e;
        } else return s.toolText(a, id, try std.fmt.allocPrint(a, "no request called {s}", .{name}), true);
        if (s.poller == null) {
            const ifname = if (s.prof.diag_interface.len > 0) s.prof.diag_interface else s.prof.buses[0].interface;
            s.poller = diag.Poller.open(ifname, .{ .pad = s.prof.diag_pad }) catch |e|
                return s.toolText(a, id, try std.fmt.allocPrint(a, "can't open {s} for diagnostics: {s}", .{ ifname, @errorName(e) }), true);
        }
        var buf: [4095]u8 = undefined;
        const got = diag.ask(&s.poller.?, name, &buf, 1000) catch |e|
            return s.toolText(a, id, try std.fmt.allocPrint(a, "{s}: {s}", .{ name, @errorName(e) }), true);
        const req_hex = try hex(a, entry.bytes);
        const answer = got orelse return s.toolText(a, id, try std.fmt.allocPrint(a, "{s} ({s} to 0x{X}): no answer within 1 s", .{ name, req_hex, entry.tx_id }), false);
        if (answer.len >= 3 and answer[0] == 0x7f) {
            return s.toolText(a, id, try std.fmt.allocPrint(a, "{s} ({s}): refused, {s} ({s})", .{ name, req_hex, try hex(a, answer), diag.nrcName(answer[2]) }), false);
        }
        const ok = diag.positive(entry.bytes, answer);
        var text = try std.fmt.allocPrint(a, "{s} ({s}): {s}, {d} bytes: {s}", .{ name, req_hex, if (ok) "answered" else "an unexpected answer", answer.len, try hex(a, answer) });
        // the data after the echoed request, as text when it is text
        const data = if (ok and answer.len > entry.bytes.len) answer[entry.bytes.len..] else answer[0..0];
        if (data.len > 0 and printable(data)) text = try std.fmt.allocPrint(a, "{s}\nas text: {s}", .{ text, data });
        return s.toolText(a, id, text, false);
    }

    /// Every reading on one line: `speed=52.32 km/h, gear=DI_GEAR_D, ...`
    /// (`-` for one not seen yet).
    pub fn snapshot(s: *const Server, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s.prof.readings, 0..) |r, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, r.name);
            try out.append(a, '=');
            try out.appendSlice(a, if (s.reading(i)) |cur| try describe(a, cur, r.unit) else "-");
        }
        return out.items;
    }

    fn readingNames(s: *const Server, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s.prof.readings, 0..) |r, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, r.name);
        }
        return out.items;
    }

    // ---- output ----

    fn toolText(s: *Server, a: Allocator, id: []const u8, text: []const u8, is_error: bool) !void {
        return s.reply(a, id, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{}}}", .{ try jsonStr(a, text), is_error }));
    }

    fn reply(s: *Server, a: Allocator, id: []const u8, result: []const u8) !void {
        return s.send(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result }));
    }

    fn send(s: *Server, a: Allocator, line: []const u8) !void {
        _ = a;
        if (s.captured) |c| {
            try c.appendSlice(s.gpa, line);
            try c.append(s.gpa, '\n');
            return;
        }
        try writeAll(s.out_fd, line);
        try writeAll(s.out_fd, "\n");
    }

    fn pollTimeoutMs(s: *const Server, now_ns: i128) i32 {
        var ms: i128 = 1000;
        for (s.waits.items) |w| ms = @min(ms, @divTrunc(w.deadline_ns - now_ns, std.time.ns_per_ms) + 1);
        return @intCast(std.math.clamp(ms, 0, 1000));
    }
};

/// Serves MCP on stdin and stdout until stdin closes.
pub fn run(gpa: Allocator, io: Io, prof: *const profile.Profile) !void {
    var s = try Server.init(gpa, io, prof);
    defer s.deinit();
    s.reopen(s.now());
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        var fds: [1 + 16]linux.pollfd = undefined;
        var which: [16]usize = undefined;
        fds[0] = .{ .fd = 0, .events = linux.POLL.IN };
        var n: usize = 1;
        for (s.taps, 0..) |maybe, i| if (maybe) |tap| if (n < fds.len) {
            fds[n] = .{ .fd = tap.fd, .events = linux.POLL.IN };
            which[n - 1] = i;
            n += 1;
        };
        const rc = linux.poll(&fds, n, s.pollTimeoutMs(s.now()));
        if (linux.errno(rc) == .INTR) continue;
        const t = s.now();
        for (fds[1..n], 0..) |pfd, j| if (pfd.revents != 0) try s.drain(which[j], t);
        if (fds[0].revents != 0) {
            const got = linux.read(0, &chunk, chunk.len);
            switch (linux.errno(got)) {
                .SUCCESS => if (got == 0) return else try s.feed(chunk[0..got]),
                .INTR, .AGAIN => {},
                else => return,
            }
        }
        for (s.buses) |*b| b.tick(t);
        s.reopen(t);
        try s.checkWaits(t);
    }
}

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(n)) {
            .SUCCESS => rest = rest[n..],
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        }
    }
}

fn toolsJson(gpa: Allocator, prof: *const profile.Profile) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var names: std.ArrayList(u8) = .empty;
    for (prof.readings, 0..) |r, i| {
        if (i > 0) try names.append(a, ',');
        try names.appendSlice(a, try jsonStr(a, r.name));
    }
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, "{\"tools\":[");
    try list.appendSlice(a,
        \\{"name":"car_readings","description":"The car's named readings (such as speed, gear, doors and indicators), decoded from its CAN bus just now, and whether each bus is awake. Read-only: nothing is sent to the car.","inputSchema":{"type":"object","properties":{}}},
        \\{"name":"bus_status","description":"For each CAN bus: frames a second, ids seen, how long since the last frame (a silent bus means the car is asleep), and error counts. Read-only.","inputSchema":{"type":"object","properties":{}}},
        \\{"name":"car_signals","description":"Find signals by part of their name (such as door, speed or temp) among everything the car's DBC files define, with the current value of each one seen on the bus. Read-only.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"part of a signal or message name"}},"required":["query"]}},
    );
    try list.appendSlice(a, try std.fmt.allocPrint(a,
        \\{{"name":"car_wait","description":"Wait until a reading changes or meets a condition (such as speed > 30), for at most timeout_s seconds (default 60, at most {d}). Read-only.","inputSchema":{{"type":"object","properties":{{"reading":{{"type":"string","enum":[{s}]}},"condition":{{"type":"string","enum":["changes","==","!=",">","<",">=","<="]}},"value":{{"type":"string","description":"a number, or a value's name such as DI_GEAR_P"}},"timeout_s":{{"type":"number"}}}},"required":["reading"]}}}}
    , .{ server_max_wait, names.items }));
    if (diag.enabled) {
        var reqs: std.ArrayList(u8) = .empty;
        var about: std.ArrayList(u8) = .empty;
        for (diag.table, 0..) |e, i| {
            if (i > 0) {
                try reqs.append(a, ',');
                try about.appendSlice(a, "; ");
            }
            try reqs.appendSlice(a, try jsonStr(a, e.name));
            try about.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ e.name, e.about }));
        }
        const desc = try std.fmt.allocPrint(a, "Sends one fixed, read-only diagnostic request compiled into this program to the car and returns the answer. This is the one tool that puts a frame on the bus. Requests: {s}.", .{about.items});
        try list.appendSlice(a, try std.fmt.allocPrint(a,
            \\,{{"name":"car_diag","description":{s},"inputSchema":{{"type":"object","properties":{{"request":{{"type":"string","enum":[{s}]}}}},"required":["request"]}}}}
        , .{ try jsonStr(a, desc), reqs.items }));
    }
    try list.appendSlice(a, "]}");
    // one message is one line: the multi-line literals above must not leave newlines
    var flat = try gpa.alloc(u8, list.items.len - std.mem.count(u8, list.items, "\n"));
    var j: usize = 0;
    for (list.items) |ch| if (ch != '\n') {
        flat[j] = ch;
        j += 1;
    };
    return flat;
}

const server_max_wait = max_wait_s;

fn freeWait(gpa: Allocator, w: Wait) void {
    gpa.free(w.id_json);
    if (w.text) |x| gpa.free(x);
}

fn holds(w: *const Wait, cur: Seen) bool {
    return switch (w.op) {
        .changes => w.start_raw == null or cur.raw != w.start_raw.?,
        .eq, .ne => blk: {
            const same = if (w.text) |txt|
                (if (cur.label) |l| std.ascii.eqlIgnoreCase(l, txt) else false)
            else
                @abs(cur.value - w.num.?) <= 1e-9 * @max(1.0, @abs(cur.value));
            break :blk if (w.op == .eq) same else !same;
        },
        .gt => cur.value > w.num.?,
        .lt => cur.value < w.num.?,
        .ge => cur.value >= w.num.?,
        .le => cur.value <= w.num.?,
    };
}

fn parseOp(s: []const u8) ?Op {
    const table = .{ .{ "changes", Op.changes }, .{ "==", Op.eq }, .{ "=", Op.eq }, .{ "!=", Op.ne }, .{ ">", Op.gt }, .{ "<", Op.lt }, .{ ">=", Op.ge }, .{ "<=", Op.le } };
    inline for (table) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return null;
}

fn opName(op: Op) []const u8 {
    return switch (op) {
        .changes => "changes",
        .eq => "==",
        .ne => "!=",
        .gt => ">",
        .lt => "<",
        .ge => ">=",
        .le => "<=",
    };
}

fn targetText(a: Allocator, w: *const Wait) ![]const u8 {
    if (w.text) |x| return x;
    var buf: [64]u8 = undefined;
    return a.dupe(u8, number(&buf, w.num.?));
}

fn describe(a: Allocator, cur: Seen, unit: []const u8) ![]u8 {
    if (cur.label) |l| return a.dupe(u8, l);
    var buf: [64]u8 = undefined;
    const n = number(&buf, cur.value);
    if (unit.len == 0) return a.dupe(u8, n);
    return std.fmt.allocPrint(a, "{s} {s}", .{ n, unit });
}

/// A number without needless decimals: 50, 52.32, 0.125.
pub fn number(buf: []u8, v: f64) []const u8 {
    if (@abs(v - @round(v)) < 1e-9 and @abs(v) < 1e15) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(@round(v)))}) catch "?";
    const s = std.fmt.bufPrint(buf, "{d:.3}", .{v}) catch return "?";
    var e = s.len;
    while (e > 0 and s[e - 1] == '0') e -= 1;
    if (e > 0 and s[e - 1] == '.') e -= 1;
    return s[0..e];
}

fn labelList(a: Allocator, sig: *const dbc.Signal) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (sig.values, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, v.label);
    }
    if (sig.values.len == 0) try out.appendSlice(a, "no named values");
    return out.items;
}

fn ageS(now_ns: i128, then_ns: i128) f64 {
    return @as(f64, @floatFromInt(@max(0, now_ns - then_ns))) / std.time.ns_per_s;
}

fn hex(a: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes, 0..) |b, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, &std.fmt.bytesToHex(&[_]u8{b}, .upper));
    }
    return out.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

fn printable(bytes: []const u8) bool {
    for (bytes) |b| if (b < 0x20 or b > 0x7e) return false;
    return true;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}

fn jsonStr(a: Allocator, s: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, s, .{});
}

// ---- tests ----

const T = std.testing;

const icsim_dbc =
    \\BO_ 580 SPEED: 5 CONTROLS
    \\ SG_ speed : 31|16@0+ (0.01,0) [0|655.35] "km/h" ICSIM
    \\BO_ 392 INDICATORS: 4 CONTROLS
    \\ SG_ left : 0|1@1+ (1,0) [0|1] "" ICSIM
    \\ SG_ right : 1|1@1+ (1,0) [0|1] "" ICSIM
    \\BO_ 411 DOORS: 3 CONTROLS
    \\ SG_ door1_locked : 16|1@1+ (1,0) [0|1] "" ICSIM
    \\ SG_ door2_locked : 17|1@1+ (1,0) [0|1] "" ICSIM
    \\VAL_ 392 left 0 "off" 1 "on" ;
    \\VAL_ 411 door1_locked 0 "unlocked" 1 "locked" ;
;

const Fx = struct {
    arena: std.heap.ArenaAllocator,
    db: dbc.Db,
    prof: profile.Profile,
    out: std.ArrayList(u8),
    s: Server,

    fn init(f: *Fx) !void {
        f.arena = std.heap.ArenaAllocator.init(T.allocator);
        const a = f.arena.allocator();
        var d: dbc.Diag = .{};
        f.db = try dbc.parse(a, icsim_dbc, &d);
        const buses = try a.alloc(profile.Bus, 1);
        buses[0] = .{ .name = "can", .interface = "vcan0", .log = "can0", .dbc_path = "icsim.dbc", .fd = false, .db = &f.db };
        const speed = f.db.byName("SPEED").?;
        const ind = f.db.byName("INDICATORS").?;
        const doors = f.db.byName("DOORS").?;
        const readings = try a.dupe(profile.Reading, &.{
            .{ .name = "speed", .bus = 0, .msg = speed, .sig = speed.signal("speed").?, .unit = "km/h", .note = "" },
            .{ .name = "left_indicator", .bus = 0, .msg = ind, .sig = ind.signal("left").?, .unit = "", .note = "" },
            .{ .name = "door1_locked", .bus = 0, .msg = doors, .sig = doors.signal("door1_locked").?, .unit = "", .note = "" },
        });
        f.prof = .{ .name = "ICSim", .buses = buses, .readings = readings };
        f.out = .empty;
        f.s = try Server.init(T.allocator, T.io, &f.prof);
        f.s.captured = &f.out;
        f.s.now_override = 1_000 * std.time.ns_per_s;
    }

    fn deinit(f: *Fx) void {
        f.s.deinit();
        f.out.deinit(T.allocator);
        f.arena.deinit();
    }

    fn line(f: *Fx, l: []const u8) !void {
        try f.s.handleLine(l);
    }

    fn frame(f: *Fx, id: u32, bytes: []const u8) !void {
        var fr: can.Frame = .{ .id = id, .len = @intCast(bytes.len) };
        @memcpy(fr.data[0..bytes.len], bytes);
        try f.s.onFrame(0, &fr, .classic, f.s.now());
    }

    fn took(f: *Fx) []u8 {
        const r = T.allocator.dupe(u8, f.out.items) catch unreachable;
        f.out.clearRetainingCapacity();
        return r;
    }
};

test "initialize answers the client's protocol version; tools list the readings" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{}}}");
    const init_out = f.took();
    defer T.allocator.free(init_out);
    try T.expect(std.mem.indexOf(u8, init_out, "\"protocolVersion\":\"2025-03-26\"") != null);
    try f.line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try T.expectEqual(0, f.out.items.len);
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const list = f.took();
    defer T.allocator.free(list);
    try T.expect(std.mem.indexOf(u8, list, "\"car_readings\"") != null);
    try T.expect(std.mem.indexOf(u8, list, "\"enum\":[\"speed\",\"left_indicator\",\"door1_locked\"]") != null);
    try T.expect((std.mem.indexOf(u8, list, "car_diag") != null) == diag.enabled);
    // one message, one line
    try T.expectEqual(1, std.mem.count(u8, list, "\n"));
    try T.expect(list[list.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, T.allocator, list, .{});
    parsed.deinit();
}

test "readings: not seen, then decoded with units and names" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"car_readings\",\"arguments\":{}}}");
    const before = f.took();
    defer T.allocator.free(before);
    try T.expect(std.mem.indexOf(u8, before, "speed: not seen yet") != null);
    try f.frame(580, &.{ 0, 0, 0, 0x13, 0x88 });
    try f.frame(392, &.{ 1, 0, 0, 0 });
    try f.frame(411, &.{ 0, 0, 0x01 });
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"car_readings\"}}");
    const after = f.took();
    defer T.allocator.free(after);
    try T.expect(std.mem.indexOf(u8, after, "speed: 50 km/h") != null);
    try T.expect(std.mem.indexOf(u8, after, "left_indicator: on") != null);
    try T.expect(std.mem.indexOf(u8, after, "door1_locked: locked") != null);
    try T.expect(std.mem.indexOf(u8, after, "\"isError\":false") != null);
}

test "signals: found by part of a name" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.frame(411, &.{ 0, 0, 0x02 });
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"car_signals\",\"arguments\":{\"query\":\"DOOR\"}}}");
    const out = f.took();
    defer T.allocator.free(out);
    try T.expect(std.mem.indexOf(u8, out, "2 signals contain") != null);
    try T.expect(std.mem.indexOf(u8, out, "DOORS.door2_locked = 1") != null);
}

test "wait: met at once, met later, out of time, cancelled" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.frame(580, &.{ 0, 0, 0, 0x13, 0x88 }); // 50 km/h
    // already true: answered at once
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"car_wait\",\"arguments\":{\"reading\":\"speed\",\"condition\":\">\",\"value\":\"30\"}}}");
    const now_met = f.took();
    defer T.allocator.free(now_met);
    try T.expect(std.mem.indexOf(u8, now_met, "speed > 30: yes") != null);
    // later: speed over 60
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"car_wait\",\"arguments\":{\"reading\":\"speed\",\"condition\":\">=\",\"value\":60,\"timeout_s\":10}}}");
    try T.expectEqual(0, f.out.items.len);
    f.s.now_override.? += 2 * std.time.ns_per_s;
    try f.frame(580, &.{ 0, 0, 0, 0x17, 0x70 }); // 60 km/h
    try f.s.checkWaits(f.s.now());
    const later = f.took();
    defer T.allocator.free(later);
    try T.expect(std.mem.indexOf(u8, later, "\"id\":7") != null);
    try T.expect(std.mem.indexOf(u8, later, "after 2.0 s (speed is 60 km/h)") != null);
    // a change that does not come
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":\"w8\",\"method\":\"tools/call\",\"params\":{\"name\":\"car_wait\",\"arguments\":{\"reading\":\"door1_locked\",\"timeout_s\":5}}}");
    f.s.now_override.? += 6 * std.time.ns_per_s;
    try f.s.checkWaits(f.s.now());
    const late = f.took();
    defer T.allocator.free(late);
    try T.expect(std.mem.indexOf(u8, late, "\"id\":\"w8\"") != null);
    try T.expect(std.mem.indexOf(u8, late, "door1_locked did not change within 5 s (it is not seen)") != null);
    // cancelled: no answer at all
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"car_wait\",\"arguments\":{\"reading\":\"left_indicator\",\"condition\":\"==\",\"value\":\"on\"}}}");
    try f.line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":9}}");
    try T.expectEqual(0, f.s.waits.items.len);
    try f.frame(392, &.{ 1, 0, 0, 0 });
    try f.s.checkWaits(f.s.now());
    try T.expectEqual(0, f.out.items.len);
}

test "wait: a value name the signal does not have, or no such reading" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"car_wait\",\"arguments\":{\"reading\":\"left_indicator\",\"condition\":\"==\",\"value\":\"blinking\"}}}");
    const bad = f.took();
    defer T.allocator.free(bad);
    try T.expect(std.mem.indexOf(u8, bad, "has no value called blinking; it has: off, on") != null);
    try T.expect(std.mem.indexOf(u8, bad, "\"isError\":true") != null);
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"car_wait\",\"arguments\":{\"reading\":\"rpm\"}}}");
    const none = f.took();
    defer T.allocator.free(none);
    try T.expect(std.mem.indexOf(u8, none, "no reading called rpm; there are: speed, left_indicator, door1_locked") != null);
}

test "bus status: no frame, awake with a rate, asleep" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"bus_status\"}}");
    const first = f.took();
    defer T.allocator.free(first);
    try T.expect(std.mem.indexOf(u8, first, "bus can (vcan0): no frame yet") != null);
    f.s.buses[0].tick(f.s.now());
    for (0..100) |_| try f.frame(580, &.{ 0, 0, 0, 1, 0 });
    f.s.now_override.? += std.time.ns_per_s;
    f.s.buses[0].tick(f.s.now());
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"bus_status\"}}");
    const awake = f.took();
    defer T.allocator.free(awake);
    try T.expect(std.mem.indexOf(u8, awake, "awake, 100 frames a second, 1 ids") != null);
    f.s.now_override.? += 30 * std.time.ns_per_s;
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"bus_status\"}}");
    const asleep = f.took();
    defer T.allocator.free(asleep);
    try T.expect(std.mem.indexOf(u8, asleep, "asleep: no frame for 31 s") != null);
}

test "unknown tools and methods" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"car_unlock\"}}");
    const tool = f.took();
    defer T.allocator.free(tool);
    try T.expect(std.mem.indexOf(u8, tool, "no tool called car_unlock") != null);
    try f.line("{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"resources/list\"}");
    const m = f.took();
    defer T.allocator.free(m);
    try T.expect(std.mem.indexOf(u8, m, "-32601") != null);
    try f.line("not json");
    const pe = f.took();
    defer T.allocator.free(pe);
    try T.expect(std.mem.indexOf(u8, pe, "-32700") != null);
}

test "numbers without needless decimals" {
    var buf: [64]u8 = undefined;
    try T.expectEqualStrings("50", number(&buf, 50));
    try T.expectEqualStrings("52.32", number(&buf, 52.32));
    try T.expectEqualStrings("-0.5", number(&buf, -0.5));
}
