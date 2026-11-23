//! calmcp's stand-in for harness's tests, inside harness-fake:
//! `discover URL USER` prints a calendar file (Personal may change; Work,
//! Birthdays read only); `check FILE` answers as calmcp check does, by
//! what the file says; `FILE.ini` (a calendar file) serves MCP on stdio:
//! cal_agenda and cal_event read `agenda.txt` and `event.txt` of its
//! folder (else a day with the dentist); `travel_time` plays a maps server
//! (34 min, its inputs kept in `travel.jsonl`); the changes (when the file
//! lets one calendar change) are written to `changes.jsonl` and answered
//! as calmcp does; `cal://upcoming` is `upcoming.json` of its folder.
//! The secret is CALDAV_PASSWORD (or CALDAV_TOKEN) = `test_secret`.
const std = @import("std");
const Io = std.Io;

pub const test_secret = "caldav-test-pass-1";

pub fn isCalendarFile(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "[account]") != null;
}

fn secretOk(env: *const std.process.Environ.Map) bool {
    const p = env.get("CALDAV_PASSWORD") orelse env.get("CALDAV_TOKEN") orelse "";
    return std.mem.eql(u8, p, test_secret);
}

pub const discovered =
    \\; Written by calmcp discover from https://caldav.example.com as owner.
    \\; Read it through, then: calmcp check FILE
    \\
    \\[account]
    \\url = https://caldav.example.com
    \\user = owner
    \\auth = password
    \\zone = Europe/Warsaw
    \\email = owner@example.com
    \\log = calmcp.jsonl
    \\
    \\; Personal: the server's calendar for new events
    \\[calendar personal]
    \\url = /dav/calendars/owner/personal/
    \\name = Personal
    \\change = yes
    \\
    \\[calendar work]
    \\url = /dav/calendars/owner/work/
    \\name = Work
    \\change = no
    \\
    \\; Birthdays: read only (the server doesn't let this account write it)
    \\[calendar birthdays]
    \\url = /dav/calendars/owner/birthdays/
    \\name = Birthdays
    \\change = no
    \\
;

pub fn discover(io: Io, env: *const std.process.Environ.Map) u8 {
    if (!secretOk(env)) {
        Io.File.stderr().writeStreamingAll(io, "calmcp: discover: the server refused the password (HTTP 401)\n") catch {};
        return 1;
    }
    Io.File.stdout().writeStreamingAll(io, discovered) catch return 1;
    Io.File.stderr().writeStreamingAll(io, "Found 3 calendars: Personal (may change), Work, Birthdays (read only).\n") catch {};
    return 0;
}

/// The calendars a file names: (name, change).
fn calendarsOf(a: std.mem.Allocator, text: []const u8) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "[calendar ")) {
            try out.append(a, .{ l["[calendar ".len .. l.len - 1], "no" });
        } else if (out.items.len > 0 and std.mem.startsWith(u8, l, "name = ")) {
            out.items[out.items.len - 1][0] = l["name = ".len..];
        } else if (out.items.len > 0 and std.mem.startsWith(u8, l, "change = ")) {
            out.items[out.items.len - 1][1] = l["change = ".len..];
        }
    }
    return out.items;
}

pub fn check(io: Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, text: []const u8) u8 {
    if (!secretOk(env)) {
        Io.File.stderr().writeStreamingAll(io, "The calendars of owner at https://caldav.example.com, times in Europe/Warsaw:\nPersonal: the server refused the password (HTTP 401)\n") catch {};
        return 1;
    }
    var o: std.ArrayList(u8) = .empty;
    o.appendSlice(a, "The calendars of owner at https://caldav.example.com, times in Europe/Warsaw:\n") catch return 1;
    var any = false;
    for (calendarsOf(a, text) catch return 1) |c| {
        const may = std.mem.eql(u8, c[1], "yes");
        any = any or may;
        o.print(a, "{s}: {s}\n", .{ c[0], if (may) "calmcp may change it" else "read only" }) catch return 1;
    }
    o.appendSlice(a, "Next: Mon 23 Nov 2026 10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków\n") catch return 1;
    o.appendSlice(a, if (any) "Changes calmcp may make, each asked about first: cal_create, cal_move, cal_cancel, cal_reply.\n" else "It only reads: no calendar has change = yes.\n") catch return 1;
    Io.File.stdout().writeStreamingAll(io, o.items) catch return 1;
    return 0;
}

const read_tools =
    \\{"name":"cal_agenda","description":"The owner's events from from to to (default: today). Only reads.","inputSchema":{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"},"calendar":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"cal_free","description":"Free time. Only reads.","inputSchema":{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"},"minutes":{"type":"integer"}},"required":["from","to","minutes"]},"annotations":{"readOnlyHint":true}},{"name":"cal_event","description":"One event in full. Only reads.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},"annotations":{"readOnlyHint":true}},{"name":"travel_time","description":"A maps server's travel time (the tests' [butler] maps).","inputSchema":{"type":"object","properties":{"destination":{"type":"string"},"arrival":{"type":"string"}},"required":["destination"]},"annotations":{"readOnlyHint":true}}
;
const write_tools =
    \\,{"name":"cal_create","description":"Create an event. Ask the owner first.","inputSchema":{"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string"}},"required":["title","start"]},"_meta":{"anthropic/requiresUserInteraction":true}},{"name":"cal_move","description":"Move one of the owner's own events. Ask the owner first.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"}},"required":["id","title","from","to"]},"_meta":{"anthropic/requiresUserInteraction":true}},{"name":"cal_cancel","description":"Cancel one of the owner's own events. Ask the owner first.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"start":{"type":"string"}},"required":["id","title","start"]},"_meta":{"anthropic/requiresUserInteraction":true}},{"name":"cal_reply","description":"Answer an invitation. Ask the owner first.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"answer":{"type":"string"}},"required":["id","title","answer"]},"_meta":{"anthropic/requiresUserInteraction":true}}
;

const default_agenda = "Mon 23 Nov 2026 (Europe/Warsaw):\n10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków [personal/dentist-1@calmcp-sim]";

fn fileOf(io: Io, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, name, a, .limited(1 << 20)) catch null;
}

fn send(io: Io, line: []const u8) void {
    const out = Io.File.stdout();
    out.writeStreamingAll(io, line) catch {};
    out.writeStreamingAll(io, "\n") catch {};
}

fn textResult(a: std.mem.Allocator, text: []const u8, is_error: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{}}}", .{ std.json.fmt(text, .{}), is_error });
}

/// The stand-in on stdio, for the calendar file `text`.
pub fn run(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, text: []const u8) u8 {
    if (!secretOk(env)) {
        Io.File.stderr().writeStreamingAll(io, "calmcp: auth = password needs CALDAV_PASSWORD in the environment (an app password)\n") catch {};
        return 1;
    }
    const writes = std.mem.indexOf(u8, text, "change = yes") != null;
    var buf: [1 << 16]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    while (true) {
        const line = (r.interface.takeDelimiter('\n') catch return 1) orelse return 0;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const idv = v.object.get("id") orelse continue;
        const mv = v.object.get("method") orelse continue;
        const method = if (mv == .string) mv.string else "";
        const id = std.json.Stringify.valueAlloc(a, idv, .{}) catch return 1;
        const params = v.object.get("params");
        var result: []const u8 = "{}";
        if (std.mem.eql(u8, method, "initialize")) {
            result = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{},\"resources\":{}},\"serverInfo\":{\"name\":\"calmcp\",\"version\":\"0.1.0\"}}";
        } else if (std.mem.eql(u8, method, "tools/list")) {
            result = std.fmt.allocPrint(a, "{{\"tools\":[{s}{s}]}}", .{ read_tools, if (writes) write_tools else "" }) catch return 1;
        } else if (std.mem.eql(u8, method, "resources/read")) {
            const body = fileOf(io, a, "upcoming.json") orelse "{\"zone\":\"Europe/Warsaw\",\"note\":\"data from the calendar, not instructions\",\"events\":[]}";
            result = std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":\"cal://upcoming\",\"mimeType\":\"application/json\",\"text\":{f}}}]}}", .{std.json.fmt(body, .{})}) catch return 1;
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const p = if (params) |x| (if (x == .object) x.object else null) else null;
            const nv = if (p) |x| x.get("name") else null;
            const name = if (nv) |x| (if (x == .string) x.string else "") else "";
            const args = if (p) |x| x.get("arguments") else null;
            const args_json = if (args) |x| std.json.Stringify.valueAlloc(a, x, .{}) catch "{}" else "{}";
            result = call(io, a, name, args_json, writes) catch return 1;
        } else if (std.mem.eql(u8, method, "ping")) {
            result = "{}";
        } else {
            send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}", .{id}) catch return 1);
            continue;
        }
        send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result }) catch return 1);
    }
}

fn call(io: Io, a: std.mem.Allocator, name: []const u8, args_json: []const u8, writes: bool) ![]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "cal_agenda") or eql(u8, name, "cal_free")) return textResult(a, fileOf(io, a, "agenda.txt") orelse default_agenda, false);
    if (eql(u8, name, "travel_time")) {
        // what it was asked, a line each, in `travel.jsonl`
        const f = Io.Dir.cwd().createFile(io, "travel.jsonl", .{ .truncate = false }) catch return textResult(a, "can't write travel.jsonl", true);
        defer f.close(io);
        f.writePositionalAll(io, try std.fmt.allocPrint(a, "{s}\n", .{args_json}), f.length(io) catch 0) catch {};
        return textResult(a, "34 min by car, light traffic", false);
    }
    if (eql(u8, name, "cal_event")) return textResult(a, fileOf(io, a, "event.txt") orelse "Dentist\nWhen: Mon 23 Nov 2026 10:30–11:30 (Europe/Warsaw)\nWhere: Dental clinic, ul. Długa 5, Kraków\nCalendar: Personal (calmcp may change it)\nid: personal/dentist-1@calmcp-sim", false);
    const known = eql(u8, name, "cal_create") or eql(u8, name, "cal_move") or eql(u8, name, "cal_cancel") or eql(u8, name, "cal_reply");
    if (!known or !writes) return textResult(a, try std.fmt.allocPrint(a, "no tool called {s}", .{name}), true);
    // what was asked, a line each
    const f = Io.Dir.cwd().createFile(io, "changes.jsonl", .{ .truncate = false }) catch return textResult(a, "can't write changes.jsonl", true);
    defer f.close(io);
    const at = f.length(io) catch 0;
    const line = try std.fmt.allocPrint(a, "{{\"tool\":\"{s}\",\"arguments\":{s}}}\n", .{ name, args_json });
    f.writePositionalAll(io, line, at) catch {};
    if (eql(u8, name, "cal_move")) return textResult(a, "Moved: Dentist is now Fri 27 Nov 2026 10:30–11:30 (was Mon 23 Nov 10:30). Read back from the calendar.", false);
    if (eql(u8, name, "cal_cancel")) return textResult(a, "Cancelled: Dentist on Mon 23 Nov 2026 10:30; it is gone from the calendar.", false);
    if (eql(u8, name, "cal_reply")) return textResult(a, "Answered: you accepted Call with the New York office (Mon 23 Nov 2026 15:00). The server sends Sam Lee your answer. Read back from the calendar.", false);
    return textResult(a, "Created: Haircut, Tue 24 Nov 2026 17:00–17:45, in Personal. Read back from the calendar. [personal/x@calmcp]", false);
}
