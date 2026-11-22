//! `harness-fake --mcp`: a small MCP server on stdio for the tests of
//! mcp.zig. Tools: `echo` (returns `text`; "env" returns FAKE_SECRET and
//! HOME; "file:NAME" the file NAME of its folder; "notify:URI" sends
//! notifications/resources/updated for URI first), `fail` (isError),
//! `sleep` (waits `ms` then answers "slept"). Resources: `fake://NAME` is
//! the file NAME of its folder; it takes subscriptions.
//! Before the tools/list reply it sends a notification and a `ping`
//! request, to prove the client skips the one and answers the other.
const std = @import("std");
const Io = std.Io;

const tools_json =
    \\{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},{"name":"fail","description":"Always fails.","inputSchema":{"type":"object","properties":{}}},{"name":"sleep","description":"Wait ms milliseconds.","inputSchema":{"type":"object","properties":{"ms":{"type":"integer"}},"required":["ms"]}}]}
;

pub fn run(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) u8 {
    var buf: [1 << 16]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    var pinged = false;
    while (true) {
        const line = (r.interface.takeDelimiter('\n') catch return 1) orelse return 0;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const id = o.get("id");
        const method = if (o.get("method")) |m| (if (m == .string) m.string else "") else {
            // a response: ours to the ping is id "p1"
            if (id) |i| if (i == .string and std.mem.eql(u8, i.string, "p1") and o.get("result") != null) {
                pinged = true;
            };
            continue;
        };
        const idv = id orelse continue; // notifications need no answer
        const id_json = std.json.Stringify.valueAlloc(a, idv, .{}) catch return 1;
        var result: []const u8 = "{}";
        if (std.mem.eql(u8, method, "initialize")) {
            result = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{},\"resources\":{\"subscribe\":true}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}";
        } else if (std.mem.eql(u8, method, "tools/list")) {
            send(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"listing\"}}");
            send(io, "{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}");
            // a stray response with an id nobody asked for
            send(io, "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{\"tools\":[]}}");
            result = tools_json;
        } else if (std.mem.eql(u8, method, "tools/call")) {
            result = call(io, a, v, env, pinged) catch return 1;
        } else if (std.mem.eql(u8, method, "resources/read")) {
            result = resource(io, a, v) orelse {
                send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32002,\"message\":\"no such resource\"}}}}", .{id_json}) catch return 1);
                continue;
            };
        } else if (std.mem.eql(u8, method, "resources/subscribe")) {
            result = "{}";
        } else if (std.mem.eql(u8, method, "ping")) {
            result = "{}";
        } else {
            send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}", .{id_json}) catch return 1);
            continue;
        }
        send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result }) catch return 1);
    }
}

/// A file of its folder (no slashes), as `resources/read` gives it.
fn fileOf(io: Io, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, "..")) return null;
    return Io.Dir.cwd().readFileAlloc(io, name, a, .limited(1 << 20)) catch null;
}

/// `resources/read` of `fake://NAME`: the file NAME of its folder.
fn resource(io: Io, a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    const params = v.object.get("params") orelse return null;
    if (params != .object) return null;
    const uv = params.object.get("uri") orelse return null;
    if (uv != .string or !std.mem.startsWith(u8, uv.string, "fake://")) return null;
    const text = fileOf(io, a, uv.string["fake://".len..]) orelse return null;
    const uri = std.json.Stringify.valueAlloc(a, uv.string, .{}) catch return null;
    const body = std.json.Stringify.valueAlloc(a, text, .{}) catch return null;
    return std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":{s},\"mimeType\":\"text/plain\",\"text\":{s}}}]}}", .{ uri, body }) catch null;
}

fn send(io: Io, line: []const u8) void {
    const out = Io.File.stdout();
    out.writeStreamingAll(io, line) catch {};
    out.writeStreamingAll(io, "\n") catch {};
}

fn textResult(a: std.mem.Allocator, text: []const u8, is_error: bool) ![]const u8 {
    const s = try std.json.Stringify.valueAlloc(a, text, .{});
    return std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{}}}", .{ s, is_error });
}

fn call(io: Io, a: std.mem.Allocator, v: std.json.Value, env: *const std.process.Environ.Map, pinged: bool) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const name = if (name_v == .string) name_v.string else "";
    const args: ?std.json.ObjectMap = if (params.object.get("arguments")) |x| (if (x == .object) x.object else null) else null;
    if (std.mem.eql(u8, name, "echo")) {
        const tv = if (args) |m| m.get("text") else null;
        const text = if (tv) |x| (if (x == .string) x.string else "") else "";
        if (std.mem.eql(u8, text, "env")) {
            const s = try std.fmt.allocPrint(a, "secret={s} home={s} user={s}", .{ env.get("FAKE_SECRET") orelse "", env.get("HOME") orelse "", env.get("USER") orelse "" });
            return textResult(a, s, false);
        }
        if (std.mem.eql(u8, text, "pinged")) return textResult(a, if (pinged) "yes" else "no", false);
        if (std.mem.startsWith(u8, text, "file:")) return textResult(a, fileOf(io, a, text["file:".len..]) orelse "no such file", false);
        if (std.mem.startsWith(u8, text, "notify:")) {
            const uri = try std.json.Stringify.valueAlloc(a, text["notify:".len..], .{});
            send(io, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{{\"uri\":{s}}}}}", .{uri}));
            return textResult(a, "notified", false);
        }
        if (std.mem.eql(u8, text, "mixed")) return "{\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"image\",\"data\":\"AAAA\",\"mimeType\":\"image/png\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///x.txt\",\"text\":\"x\"}},{\"type\":\"text\",\"text\":\"two\"}]}";
        return textResult(a, text, false);
    }
    if (std.mem.eql(u8, name, "fail")) return textResult(a, "it failed", true);
    if (std.mem.eql(u8, name, "sleep")) {
        const mv = if (args) |m| m.get("ms") else null;
        const ms: i64 = if (mv) |x| (if (x == .integer) x.integer else 0) else 0;
        io.sleep(.fromMilliseconds(ms), .awake) catch {};
        return textResult(a, "slept", false);
    }
    return textResult(a, "unknown tool", true);
}
