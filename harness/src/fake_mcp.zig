//! `harness-fake --mcp`: a small MCP server on stdio for the tests of
//! mcp.zig. Tools: `echo` (returns `text`; "env" returns FAKE_SECRET and
//! HOME; "file:NAME" the file NAME of its folder; "notify:URI" sends
//! notifications/resources/updated for URI first), `fail` (isError),
//! `sleep` (waits `ms` then answers "slept"). Resources: `fake://NAME` is
//! the file NAME of its folder; it takes subscriptions.
//! Before the tools/list reply it sends a notification and a `ping`
//! request, to prove the client skips the one and answers the other.
//! `harness-fake --mcp --home` is homemcp's stand-in instead: `home_state`,
//! `home_set` (the living room light, the hall thermostat), `home_guarded`
//! (the front door, the water main) and `home_wait`, each device's state
//! kept while it runs; the sensors (back_door, sink_leak) and presence
//! read their resources `home://device/NAME` and `home://presence` from
//! the files `device-NAME.json` and `presence.json` of its folder.
//! `harness-fake --mcp --car` is carcloud's: `car_status` (34 %, plugged
//! in, not charging) and `car_command` (charge_start, charge_stop).
//! `--mcp --slack`, `--jira` and `--github` play the work morning's
//! servers: a read each (mentions, issues, notifications, as JSON lists),
//! and Slack's and GitHub's posts, written as lines to `posted.jsonl` in
//! its folder.
//! `--mcp --cal` plays calmcp's reads for the people tests: `cal_event`
//! (`e1`: a dinner with Ola Kowalska, Marek Nowak and the owner; `e2`: a
//! call with Zofia Wójcik) and `cal_agenda` (both).
//! `--mcp --mail` plays mailmcp: `mail_list` and the resources
//! `mail://butler/new` and `mail://mine/new` read the files
//! `list-NAME.json` and `NAME-new.json` of its folder ("[]" without them),
//! `mail_read` the file `read-NAME-UID.json`; `mail_draft` and `mail_send`
//! write their input as a line of `drafts.jsonl` and `sent.jsonl`.
//! `announce` (the voice agent's): what it is asked to say is kept in the
//! file `announced` of its folder, "ROOM: TEXT" or "every speaker: TEXT" a
//! line.
//!
//! `Http` below is the same server over HTTP (Streamable HTTP), part of
//! fake.zig's stand-in, for the tests of mcp_http.zig.
const std = @import("std");
const jv = @import("jv.zig");
const Io = std.Io;

const tools_json =
    \\{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},{"name":"fail","description":"Always fails.","inputSchema":{"type":"object","properties":{}}},{"name":"sleep","description":"Wait ms milliseconds.","inputSchema":{"type":"object","properties":{"ms":{"type":"integer"}},"required":["ms"]}}]}
;

const home_tools_json =
    \\{"tools":[{"name":"home_state","description":"Every device in the home: its state now. Only reads.","inputSchema":{"type":"object","properties":{"device":{"type":"string"}}}},{"name":"home_set","description":"One action on an ordinary device.","inputSchema":{"type":"object","properties":{"device":{"type":"string"},"action":{"type":"string"},"value":{"type":"string"}},"required":["device","action"]}},{"name":"home_guarded","description":"One action on a guarded device: locks.","inputSchema":{"type":"object","properties":{"device":{"type":"string"},"action":{"type":"string"}},"required":["device","action"]}},{"name":"home_wait","description":"Wait until a device's property meets a condition. Only reads.","inputSchema":{"type":"object","properties":{"device":{"type":"string"},"property":{"type":"string"},"condition":{"type":"string"},"value":{"type":"string"},"timeout_s":{"type":"number"}},"required":["device","property"]}},{"name":"announce","description":"Say a short message on the house's speakers.","inputSchema":{"type":"object","properties":{"message":{"type":"string"},"speaker":{"type":"string"},"room":{"type":"string"}},"required":["message"]}}]}
;

const car_tools_json =
    \\{"tools":[{"name":"car_status","description":"Battery, range, charging, plugged in. Only reads.","inputSchema":{"type":"object","properties":{}}},{"name":"car_command","description":"One of the commands the car file allows.","inputSchema":{"type":"object","properties":{"command":{"type":"string"},"percent":{"type":"integer"}},"required":["command"]}}]}
;

/// carcloud's stand-in: a car at 34 %, plugged in, not charging.
const Car = struct {
    charging: bool = false,

    fn call(c: *Car, a: std.mem.Allocator, name: []const u8, args: ?std.json.ObjectMap) ![]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, name, "car_status")) return textResult(a, try std.fmt.allocPrint(a, "battery: 34%\nrange: 150 km\ncharging: {s}\nplugged in: yes\ncharge limit: 80%\nlocked: yes\ndata: from 5 minutes ago", .{if (c.charging) "yes" else "no"}), false);
        if (!eql(u8, name, "car_command")) return textResult(a, "unknown tool", true);
        const cv = (args orelse return textResult(a, "say which command", true)).get("command") orelse return textResult(a, "say which command", true);
        const command = if (cv == .string) cv.string else "";
        if (eql(u8, command, "charge_start")) {
            c.charging = true;
            return textResult(a, "done: charging started, confirmed by the car", false);
        }
        if (eql(u8, command, "charge_stop")) {
            c.charging = false;
            return textResult(a, "done: charging stopped, confirmed by the car", false);
        }
        return textResult(a, try std.fmt.allocPrint(a, "no command called {s}", .{command}), true);
    }
};

/// homemcp's stand-in: what its devices are now.
const Home = struct {
    io: Io = undefined,
    light_on: bool = false,
    door_locked: bool = true,
    setpoint: u32 = 20,
    valve_open: bool = true,

    /// A sensor's state: the `to` of its resource file, else as at rest.
    fn sensor(h: *Home, a: std.mem.Allocator, device: []const u8) []const u8 {
        const rest: []const u8 = if (std.mem.eql(u8, device, "sink_leak")) "dry" else "closed";
        const text = fileOf(h.io, a, std.fmt.allocPrint(a, "device-{s}.json", .{device}) catch return rest) orelse return rest;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return rest;
        if (v != .object) return rest;
        const to = v.object.get("to") orelse return rest;
        return if (to == .string) to.string else rest;
    }

    /// Each device's line, as homemcp's home_state gives it (shorter).
    fn line(h: *Home, a: std.mem.Allocator, device: []const u8) !?[]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, device, "living_room_light")) return try std.fmt.allocPrint(a, "living_room_light (light): {s}", .{if (h.light_on) "on" else "off"});
        if (eql(u8, device, "front_door")) return try std.fmt.allocPrint(a, "front_door (lock, guarded): {s}", .{if (h.door_locked) "locked" else "unlocked"});
        if (eql(u8, device, "hall_thermostat")) return try std.fmt.allocPrint(a, "hall_thermostat (climate): 20 °C, set to {d} °C, mode heat", .{h.setpoint});
        if (eql(u8, device, "water_main")) return try std.fmt.allocPrint(a, "water_main (valve, guarded): {s}", .{if (h.valve_open) "open" else "closed"});
        if (eql(u8, device, "back_door") or eql(u8, device, "sink_leak")) return try std.fmt.allocPrint(a, "{s} (sensor): {s}", .{ device, h.sensor(a, device) });
        return null;
    }

    const devices = [_][]const u8{ "living_room_light", "front_door", "hall_thermostat", "water_main", "back_door", "sink_leak" };

    /// home_wait with timeout 0: whether `device`'s `property` is `value` now.
    fn wait(h: *Home, a: std.mem.Allocator, device: []const u8, property: []const u8, value: []const u8) ![]const u8 {
        const eql = std.mem.eql;
        const is: []const u8 = if (eql(u8, device, "front_door") and eql(u8, property, "lock"))
            (if (h.door_locked) "locked" else "unlocked")
        else if (eql(u8, property, "open"))
            (if (eql(u8, h.sensor(a, device), "open")) "yes" else "no")
        else
            return textResult(a, "no such property", true);
        if (std.ascii.eqlIgnoreCase(is, value)) return textResult(a, try std.fmt.allocPrint(a, "{s} {s} == {s}: yes, after 0.0 s", .{ device, property, value }), false);
        return textResult(a, try std.fmt.allocPrint(a, "{s} {s} == {s}: not within 0 s (it is {s})", .{ device, property, value, is }), false);
    }

    fn call(h: *Home, io: Io, a: std.mem.Allocator, name: []const u8, args: ?std.json.ObjectMap) ![]const u8 {
        const eql = std.mem.eql;
        const field = struct {
            fn f(m: ?std.json.ObjectMap, key: []const u8) []const u8 {
                const x = (m orelse return "").get(key) orelse return "";
                return if (x == .string) x.string else "";
            }
        }.f;
        const device = field(args, "device");
        const action = field(args, "action");
        if (eql(u8, name, "home_state")) {
            if (device.len > 0) return textResult(a, (try h.line(a, device)) orelse "no such device", device.len > 0 and (try h.line(a, device)) == null);
            var out: std.ArrayList(u8) = .empty;
            for (devices, 0..) |d, i| try out.print(a, "{s}{s}", .{ if (i > 0) "\n" else "", (try h.line(a, d)).? });
            return textResult(a, out.items, false);
        }
        if (eql(u8, name, "home_wait")) return h.wait(a, device, field(args, "property"), field(args, "value"));
        if (eql(u8, name, "announce")) {
            const message = field(args, "message");
            if (message.len == 0) return textResult(a, "say what to announce: message", true);
            const room = field(args, "room");
            const where = if (room.len > 0) room else "every speaker";
            // a house of satellites takes its time
            if (std.mem.indexOf(u8, message, "(slow)") != null) io.sleep(.fromMilliseconds(2500), .awake) catch {};
            const old = Io.Dir.cwd().readFileAlloc(io, "announced", a, .limited(1 << 20)) catch "";
            Io.Dir.cwd().writeFile(io, .{ .sub_path = "announced", .data = try std.fmt.allocPrint(a, "{s}{s}: {s}\n", .{ old, where, message }) }) catch {};
            return textResult(a, if (room.len > 0) try std.fmt.allocPrint(a, "done: said in {s}", .{room}) else "done: said on every speaker", false);
        }
        const guarded = eql(u8, name, "home_guarded");
        if (!guarded and !eql(u8, name, "home_set")) return textResult(a, "unknown tool", true);
        if (eql(u8, device, "living_room_light")) {
            if (guarded) return textResult(a, "living_room_light is not guarded: use home_set", true);
            if (!eql(u8, action, "on") and !eql(u8, action, "off")) return textResult(a, "living_room_light may: on, off", true);
            h.light_on = eql(u8, action, "on");
            return textResult(a, try std.fmt.allocPrint(a, "done: living_room_light is {s}", .{action}), false);
        }
        if (eql(u8, device, "front_door")) {
            if (!guarded) return textResult(a, "front_door is guarded: use home_guarded", true);
            if (!eql(u8, action, "lock") and !eql(u8, action, "unlock")) return textResult(a, "front_door may: lock, unlock", true);
            h.door_locked = eql(u8, action, "lock");
            return textResult(a, try std.fmt.allocPrint(a, "done: front_door is {s}ed", .{action}), false);
        }
        if (eql(u8, device, "hall_thermostat")) {
            if (guarded) return textResult(a, "hall_thermostat is not guarded: use home_set", true);
            if (!eql(u8, action, "temperature")) return textResult(a, "hall_thermostat may: temperature", true);
            const value = field(args, "value");
            const x = std.fmt.parseInt(u32, value, 10) catch return textResult(a, "temperature needs a number", true);
            if (x < 16 or x > 24) return textResult(a, "temperature must be from 16 to 24 °C", true);
            h.setpoint = x;
            return textResult(a, try std.fmt.allocPrint(a, "done: hall_thermostat is heat, set to {d} °C", .{x}), false);
        }
        if (eql(u8, device, "water_main")) {
            if (!guarded) return textResult(a, "water_main is guarded: use home_guarded", true);
            if (!eql(u8, action, "close")) return textResult(a, "water_main may not open; it may: close", true);
            h.valve_open = false;
            return textResult(a, "done: water_main is closed", false);
        }
        return textResult(a, "no such device", true);
    }
};

pub fn run(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) u8 {
    return serve(io, gpa, env, null);
}

/// homemcp's stand-in on stdio.
pub fn runHome(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) u8 {
    var home: Home = .{ .io = io };
    return serveAs(io, gpa, env, .{ .home = &home });
}

/// carcloud's stand-in on stdio.
pub fn runCar(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) u8 {
    var car: Car = .{};
    return serveAs(io, gpa, env, .{ .car = &car });
}

/// What `harness-fake discover URL` prints: the home stand-in's devices as
/// homemcp discover writes a home file (and a plain switch it could not
/// identify).
pub const discovered_home =
    \\; Written by homemcp discover from Home Assistant at http://127.0.0.1:8123.
    \\; Read it through, then: homemcp check FILE
    \\
    \\[home]
    \\name = Test flat
    \\hub = homeassistant
    \\url = http://127.0.0.1:8123
    \\
    \\[limits]
    \\temperature = 16 24
    \\
    \\; Living room
    \\
    \\[device living_room_light]
    \\id = light.living_room
    \\kind = light
    \\room = Living room
    \\allow = on, off
    \\
    \\; Hall
    \\
    \\[device hall_thermostat]
    \\id = climate.hall
    \\kind = climate
    \\room = Hall
    \\allow = temperature
    \\
    \\[device front_door]
    \\id = lock.front_door
    \\kind = lock
    \\room = Hall
    \\allow = lock
    \\
    \\; Kitchen
    \\
    \\[device water_main]
    \\id = valve.water_main
    \\kind = valve
    \\room = Kitchen
    \\allow = close
    \\
    \\[device back_door]
    \\id = binary_sensor.back_door
    \\kind = sensor
    \\room = Kitchen
    \\
    \\[device sink_leak]
    \\id = binary_sensor.sink_leak
    \\kind = sensor
    \\room = Kitchen
    \\
    \\; Garden
    \\
    \\[device garden_switch]
    \\id = switch.garden
    \\kind = switch
    \\room = Garden
    \\allow = on, off
    \\
    \\[people]
    \\anna = person.anna
    \\
    \\; Left out, and why:
    \\; cameras: never offered (homemcp has no camera support; what they see is personal)
    \\;   camera.front_door (Front door camera)
    \\
;

/// The token the discover and check stand-ins take, and the car's secret.
pub const ha_test_token = "ha-test-token-1234";
pub const smartcar_test_secret = "smartcar-test-secret-1";
/// The app password mailmcp's check stand-in takes, for both mailboxes.
pub const mail_test_pass = "mail-test-pass-1";

/// `harness-fake discover URL` and `harness-fake check FILE`, as homemcp
/// and carcloud answer them; 1 with their error line when the token (or
/// secret) is not the tests'.
pub fn programStandIn(io: Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) u8 {
    const out = Io.File.stdout();
    const err = Io.File.stderr();
    if (std.mem.eql(u8, args[0], "discover")) {
        if (!std.mem.eql(u8, env.get("HA_TOKEN") orelse "", ha_test_token)) {
            err.writeStreamingAll(io, "homemcp: discover: the token was refused (HA_TOKEN)\n") catch {};
            return 1;
        }
        out.writeStreamingAll(io, discovered_home) catch return 1;
        err.writeStreamingAll(io, "Found 7 devices in 4 rooms, and 1 person.\n") catch {};
        return 0;
    }
    const text = Io.Dir.cwd().readFileAlloc(io, args[1], a, .limited(1 << 20)) catch {
        err.writeStreamingAll(io, "homemcp: can't read the file\n") catch {};
        return 1;
    };
    if (std.mem.indexOf(u8, text, "imap =") != null) {
        // mailmcp check: each mailbox's secret must be the tests'
        var o: std.ArrayList(u8) = .empty;
        var bad = false;
        for ([_][2][]const u8{ .{ "[butler]", "MAIL_BUTLER" }, .{ "[mine]", "MAIL_MINE" } }) |b| {
            if (std.mem.indexOf(u8, text, b[0]) == null) continue;
            const v = env.get(b[1]) orelse "";
            if (v.len == 0) {
                o.print(a, "{s}: {s} is not set.\n", .{ b[0][1 .. b[0].len - 1], b[1] }) catch return 1;
                bad = true;
            } else if (!std.mem.eql(u8, v, mail_test_pass)) {
                o.print(a, "{s}: imap.example.com refused the login of x.\n", .{b[0][1 .. b[0].len - 1]}) catch return 1;
                bad = true;
            } else if (b[0][1] == 'b') {
                o.appendSlice(a, "butler (butler@example.com, the butler's own: reads, drafts, sends): IMAP ok; INBOX: 1 mails, 1 unread; drafts go in Drafts; new mail pushed (IDLE); SMTP ok (smtp.example.com:465, TLS; nothing sent).\n") catch return 1;
            } else o.appendSlice(a, "mine (me@example.com, yours: read without marking, drafts only): IMAP ok; INBOX: 1204 mails, 12 unread; drafts go in Drafts; new mail pushed (IDLE).\n") catch return 1;
        }
        out.writeStreamingAll(io, o.items) catch return 1;
        return if (bad) 1 else 0;
    }
    if (std.mem.indexOf(u8, text, "[car]") != null) {
        if (!std.mem.eql(u8, env.get("SMARTCAR_CLIENT_SECRET") orelse "", smartcar_test_secret)) {
            err.writeStreamingAll(io, "carcloud: Smartcar refused the credentials (HTTP 401, AUTHENTICATION invalid_client)\n") catch {};
            return 1;
        }
        out.writeStreamingAll(io, "The car:\nbattery: 34%\nrange: 150.2 km\ncharging: no\nplugged in: yes\ncharge limit: 80%\ndata: from 5 minutes ago\ncommands the owner allowed: charge_start, charge_stop, charge_limit\n") catch return 1;
        return 0;
    }
    const token = env.get("HA_TOKEN") orelse "";
    if (token.len == 0) {
        err.writeStreamingAll(io, "homemcp: hub = homeassistant needs HA_TOKEN in the environment\n") catch {};
        return 1;
    }
    if (!std.mem.eql(u8, token, ha_test_token)) {
        err.writeStreamingAll(io, "homemcp: Home Assistant at http://127.0.0.1:8123 refused the token (HA_TOKEN)\n") catch {};
        return 1;
    }
    // a line per device of the file, as check says them
    var o: std.ArrayList(u8) = .empty;
    o.appendSlice(a, "Test flat: 7 devices in 4 rooms. Home Assistant at http://127.0.0.1:8123.\nChanges come in as they happen (Home Assistant's WebSocket API).\n") catch return 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const tl = std.mem.trim(u8, l, " \t\r");
        if (!std.mem.startsWith(u8, tl, "[device ")) continue;
        const name = tl["[device ".len .. tl.len - 1];
        const state: []const u8 = if (std.mem.eql(u8, name, "back_door")) "closed" else if (std.mem.eql(u8, name, "sink_leak")) "dry" else if (std.mem.eql(u8, name, "front_door")) "locked" else "off";
        o.print(a, "  {s} (x.{s}, device): {s}; may: something\n", .{ name, name, state }) catch return 1;
    }
    out.writeStreamingAll(io, o.items) catch return 1;
    return 0;
}

/// Who it plays: the plain test server, or a stand-in.
const Role = union(enum) { plain, home: *Home, car: *Car, slack, jira, github, cal, mail };

/// The work morning's servers (`--mcp --slack|--jira|--github`) on stdio.
pub fn runWork(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, which: []const u8) u8 {
    const role: Role = if (std.mem.eql(u8, which, "--slack")) .slack else if (std.mem.eql(u8, which, "--jira")) .jira else if (std.mem.eql(u8, which, "--github")) .github else if (std.mem.eql(u8, which, "--cal")) .cal else if (std.mem.eql(u8, which, "--mail")) .mail else return 2;
    return serveAs(io, gpa, env, role);
}

const slack_tools_json =
    \\{"tools":[{"name":"search_messages","description":"Search messages.","inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},{"name":"post_message","description":"Post a message, in a thread when thread_ts says.","inputSchema":{"type":"object","properties":{"channel":{"type":"string"},"thread_ts":{"type":"string"},"text":{"type":"string"}},"required":["channel","text"]}}]}
;
const mail_tools_json =
    \\{"tools":[{"name":"mail_list","description":"Mail in a mailbox, newest last, as a JSON list. Only reads.","inputSchema":{"type":"object","properties":{"mailbox":{"type":"string"},"since":{"type":"string"},"unread":{"type":"boolean"},"kind":{"type":"string"},"due_in_days":{"type":"integer"},"day":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"mail_read","description":"One mail. Only reads.","inputSchema":{"type":"object","properties":{"mailbox":{"type":"string"},"uid":{"type":"integer"},"format":{"type":"string"}},"required":["mailbox","uid"]},"annotations":{"readOnlyHint":true}},{"name":"mail_draft","description":"Write a mail into the mailbox's Drafts. Sends nothing.","inputSchema":{"type":"object","properties":{"mailbox":{"type":"string"},"to":{"type":"string"},"subject":{"type":"string"},"text":{"type":"string"},"in_reply_to":{"type":"string"}},"required":["mailbox","to","subject","text"]}},{"name":"mail_send","description":"Send a mail from the butler's own address.","inputSchema":{"type":"object","properties":{"mailbox":{"type":"string"},"to":{"type":"string"},"subject":{"type":"string"},"text":{"type":"string"},"in_reply_to":{"type":"string"},"references":{"type":"string"}},"required":["mailbox","to","subject","text"]}}]}
;

/// mailmcp's stand-in: its files, and what was drafted or sent.
fn mailCall(io: Io, a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const name = if (name_v == .string) name_v.string else "";
    const args = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
    const field = struct {
        fn f(x: std.json.Value, key: []const u8) []const u8 {
            if (x != .object) return "";
            const y = x.object.get(key) orelse return "";
            return if (y == .string) y.string else "";
        }
    }.f;
    const box = field(args, "mailbox");
    const eql = std.mem.eql;
    if (eql(u8, name, "mail_list")) {
        const list = fileOf(io, a, try std.fmt.allocPrint(a, "list-{s}.json", .{box})) orelse fileOf(io, a, try std.fmt.allocPrint(a, "{s}-new.json", .{box})) orelse "[]";
        return textResult(a, list, false);
    }
    if (eql(u8, name, "mail_read")) {
        const uid: i64 = if (args == .object) (if (args.object.get("uid")) |u| (if (u == .integer) u.integer else 0) else 0) else 0;
        const text = fileOf(io, a, try std.fmt.allocPrint(a, "read-{s}-{d}.json", .{ box, uid })) orelse return textResult(a, "no such mail", true);
        return textResult(a, text, false);
    }
    if (eql(u8, name, "mail_draft") or eql(u8, name, "mail_send")) {
        const file = if (eql(u8, name, "mail_draft")) "drafts.jsonl" else "sent.jsonl";
        const line = try std.json.Stringify.valueAlloc(a, args, .{});
        const old = fileOf(io, a, file) orelse "";
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = try std.fmt.allocPrint(a, "{s}{s}\n", .{ old, line }) });
        if (eql(u8, name, "mail_draft")) return textResult(a, try std.fmt.allocPrint(a, "Draft saved in Drafts of {s}: to {s}. Nothing was sent; it waits there to be sent by hand.", .{ box, field(args, "to") }), false);
        return textResult(a, try std.fmt.allocPrint(a, "Sent from {s} to {s}.", .{ box, field(args, "to") }), false);
    }
    return textResult(a, "unknown tool", true);
}

/// `resources/read` of `mail://NAME/new`: the file NAME-new.json.
fn mailResource(io: Io, a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    const params = v.object.get("params") orelse return null;
    if (params != .object) return null;
    const uv = params.object.get("uri") orelse return null;
    if (uv != .string or !std.mem.startsWith(u8, uv.string, "mail://") or !std.mem.endsWith(u8, uv.string, "/new")) return null;
    const box = uv.string["mail://".len .. uv.string.len - "/new".len];
    const text = fileOf(io, a, std.fmt.allocPrint(a, "{s}-new.json", .{box}) catch return null) orelse "[]";
    const uri = std.json.Stringify.valueAlloc(a, uv.string, .{}) catch return null;
    const body = std.json.Stringify.valueAlloc(a, text, .{}) catch return null;
    return std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":{s},\"mimeType\":\"application/json\",\"text\":{s}}}]}}", .{ uri, body }) catch null;
}

const jira_tools_json =
    \\{"tools":[{"name":"search_issues","description":"Issues for a JQL query.","inputSchema":{"type":"object","properties":{"jql":{"type":"string"}},"required":["jql"]}}]}
;
const github_tools_json =
    \\{"tools":[{"name":"list_notifications","description":"Your notifications.","inputSchema":{"type":"object","properties":{"participating":{"type":"boolean"}}}},{"name":"add_issue_comment","description":"Comment on an issue or pull request.","inputSchema":{"type":"object","properties":{"owner":{"type":"string"},"repo":{"type":"string"},"issue_number":{"type":"integer"},"body":{"type":"string"}},"required":["owner","repo","issue_number","body"]}}]}
;

const cal_tools_json =
    \\{"tools":[{"name":"cal_event","description":"One event, with its attendees and place.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},{"name":"cal_agenda","description":"Events between two times.","inputSchema":{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"}}}}]}
;
const cal_e1 =
    \\{"id":"e1","title":"Dinner","start":"2026-11-27T19:00:00+01:00","end":"2026-11-27T21:00:00+01:00","place":"Bistro","attendees":[{"name":"Ola Kowalska","email":"ola@example.com"},{"name":"Marek Nowak","email":"marek@example.com"},{"name":"Me","email":"owner@example.com","self":true}]}
;
const cal_e2 =
    \\{"id":"e2","title":"Call","start":"2026-11-28T10:00:00+01:00","end":"2026-11-28T10:30:00+01:00","attendees":[{"name":"Zofia Wójcik","email":"zofia@example.com"},{"name":"Me","email":"owner@example.com","self":true}]}
;

/// A work server's call: its read's list, or a post written to posted.jsonl.
fn workCall(io: Io, a: std.mem.Allocator, role: Role, v: std.json.Value) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const name = if (name_v == .string) name_v.string else "";
    const args = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
    const eql = std.mem.eql;
    switch (role) {
        .slack => {
            if (eql(u8, name, "search_messages")) return textResult(a, "[{\"channel\":\"#release\",\"ts\":\"1732350000.000100\",\"user\":\"maria\",\"text\":\"@you can you review the release notes before 11?\"},{\"channel\":\"#random\",\"ts\":\"1732351111.000200\",\"user\":\"tom\",\"text\":\"@you lunch Thursday?\"}]", false);
            if (eql(u8, name, "post_message")) {
                try post(io, a, args);
                const ch = if (args == .object) args.object.get("channel") else null;
                return textResult(a, try std.fmt.allocPrint(a, "ok: posted to {s}", .{if (ch) |c| (if (c == .string) c.string else "?") else "?"}), false);
            }
        },
        .cal => {
            const id = if (args == .object) (if (args.object.get("id")) |x| (if (x == .string) x.string else "") else "") else "";
            if (eql(u8, name, "cal_event")) return textResult(a, if (eql(u8, id, "e2")) cal_e2 else cal_e1, false);
            if (eql(u8, name, "cal_agenda")) return textResult(a, "{\"events\":[" ++ cal_e1 ++ "," ++ cal_e2 ++ "]}", false);
        },
        .jira => if (eql(u8, name, "search_issues")) return textResult(a, "[{\"key\":\"APP-142\",\"summary\":\"Checkout fails on Safari\",\"status\":\"In Progress\",\"priority\":\"High\"},{\"key\":\"APP-139\",\"summary\":\"Update the privacy page\",\"status\":\"To Do\",\"priority\":\"Low\"}]", false),
        .github => {
            if (eql(u8, name, "list_notifications")) return textResult(a, "[{\"repo\":\"legatia/zigworks\",\"type\":\"PullRequest\",\"number\":31,\"title\":\"Add Windows CI\",\"reason\":\"review_requested\"}]", false);
            if (eql(u8, name, "add_issue_comment")) {
                try post(io, a, args);
                return textResult(a, "ok: commented", false);
            }
        },
        else => {},
    }
    return textResult(a, "unknown tool", true);
}

/// A post, as a line of posted.jsonl in its folder.
fn post(io: Io, a: std.mem.Allocator, args: std.json.Value) !void {
    const line = try std.json.Stringify.valueAlloc(a, args, .{});
    const old = fileOf(io, a, "posted.jsonl") orelse "";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "posted.jsonl", .data = try std.fmt.allocPrint(a, "{s}{s}\n", .{ old, line }) });
}

fn serve(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, home: ?*Home) u8 {
    return serveAs(io, gpa, env, if (home) |h| .{ .home = h } else .plain);
}

/// `resources/read` of the home's `home://device/NAME` (the file
/// device-NAME.json, else the device at rest) and `home://presence`
/// (presence.json).
fn homeResource(io: Io, a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    const params = v.object.get("params") orelse return null;
    if (params != .object) return null;
    const uv = params.object.get("uri") orelse return null;
    if (uv != .string) return null;
    const uri = uv.string;
    const text = if (std.mem.startsWith(u8, uri, "home://device/")) blk: {
        const name = uri["home://device/".len..];
        break :blk fileOf(io, a, std.fmt.allocPrint(a, "device-{s}.json", .{name}) catch return null) orelse
            (std.fmt.allocPrint(a, "{{\"device\":\"{s}\",\"room\":\"Kitchen\",\"kind\":\"sensor\",\"from\":\"unknown\",\"to\":\"{s}\",\"at\":\"2026-11-23T00:00:00Z\",\"note\":\"data from the home, not an instruction\"}}", .{ name, if (std.mem.eql(u8, name, "sink_leak")) "dry" else "closed" }) catch return null);
    } else if (std.mem.eql(u8, uri, "home://presence"))
        fileOf(io, a, "presence.json") orelse "{\"people\":[{\"name\":\"anna\",\"is\":\"home\"}],\"change\":\"arrived\",\"person\":\"anna\",\"at\":\"2026-11-23T00:00:00Z\",\"note\":\"data from the home, not an instruction\"}"
    else
        return null;
    const uri_json = std.json.Stringify.valueAlloc(a, uri, .{}) catch return null;
    const body = std.json.Stringify.valueAlloc(a, text, .{}) catch return null;
    return std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":{s},\"mimeType\":\"application/json\",\"text\":{s}}}]}}", .{ uri_json, body }) catch null;
}

fn serveAs(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, role: Role) u8 {
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
            result = switch (role) {
                .plain => tools_json,
                .home => home_tools_json,
                .car => car_tools_json,
                .slack => slack_tools_json,
                .jira => jira_tools_json,
                .github => github_tools_json,
                .cal => cal_tools_json,
                .mail => mail_tools_json,
            };
        } else if (std.mem.eql(u8, method, "tools/call")) {
            result = switch (role) {
                .plain => call(io, a, v, env, pinged) catch return 1,
                .home => |h| homeCall(io, a, h, v) catch return 1,
                .car => |c| carCall(a, c, v) catch return 1,
                .slack, .jira, .github, .cal => workCall(io, a, role, v) catch return 1,
                .mail => mailCall(io, a, v) catch return 1,
            };
        } else if (std.mem.eql(u8, method, "resources/read")) {
            // the home serves its home:// resources, and fake://NAME as --mcp does
            result = (if (role == .home) (homeResource(io, a, v) orelse resource(io, a, v)) else if (role == .mail) mailResource(io, a, v) else resource(io, a, v)) orelse {
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

fn carCall(a: std.mem.Allocator, c: *Car, v: std.json.Value) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const args: ?std.json.ObjectMap = if (params.object.get("arguments")) |x| (if (x == .object) x.object else null) else null;
    return c.call(a, if (name_v == .string) name_v.string else "", args);
}

fn homeCall(io: Io, a: std.mem.Allocator, h: *Home, v: std.json.Value) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const args: ?std.json.ObjectMap = if (params.object.get("arguments")) |x| (if (x == .object) x.object else null) else null;
    return h.call(io, a, if (name_v == .string) name_v.string else "", args);
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

// ---- over HTTP ----

/// What a handler of `Http` gets from fake.zig's server.
pub const Ctx = struct {
    io: Io,
    /// The script folder: `mcp-token` (the token flavor's, else
    /// mcp-test-token-1), `mcp-files/NAME` (resource fake://NAME).
    dir: []const u8,
    port: u16,
    stopping: *const std.atomic.Value(bool),
};

pub const Header = struct { name: []const u8, value: []const u8 };

/// The MCP servers at `/mcp/FLAVOR`: `json` (answers are JSON), `sse`
/// (answers are event streams with a notification and a `ping` first),
/// `old` (MCP 2025-03-26), `future` (a version harness doesn't speak),
/// `token` (wants `Authorization: Bearer` with the token; a wrong one is
/// refused and said back), `nostream` (no GET stream: 405), `getless`
/// (GET answered 404, as by a server with a POST route only), `signin`
/// (wants a token of the authorization server below; its 401 names its
/// metadata) and `signin-hidden` (the same, its 401 names nothing); others
/// 404. The authorization server (issuer `/auth`) serves its protected
/// resource metadata, its RFC 8414 metadata (or, `setOpenIdOnly`, OpenID
/// discovery's), registration, `/auth/authorize` (sends the browser back
/// at once with a code, the state and iss) and `/auth/token` (checks the
/// code's PKCE S256 verifier; a refresh gives new tokens and ends the
/// old ones).
/// The same tools and resources as on stdio; `echo` "notify:URI" says URI
/// changed on the session's GET stream, "auth" says the Authorization it
/// got, "pinged" whether the session answered a ping. A session is
/// needed after initialize (none: 400; unknown or ended: 404) with the
/// version it started with; DELETE ends it. Tests steer it through the
/// methods below.
pub const Http = struct {
    /// Set by fake.zig's server when it starts.
    io: Io = undefined,
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,
    initializes: std.atomic.Value(u32) = .init(0),
    deleted: std.atomic.Value(u32) = .init(0),
    /// GET streams opened (200), and GETs refused (405).
    streams: std.atomic.Value(u32) = .init(0),
    refused_gets: std.atomic.Value(u32) = .init(0),
    /// Every request with a session is answered 404.
    end_always: std.atomic.Value(bool) = .init(false),
    /// GETs answered 404 (`getless`).
    missed_gets: std.atomic.Value(u32) = .init(0),
    /// The next POST is read, then its connection ended with no answer.
    drop_next: std.atomic.Value(bool) = .init(false),
    /// The next POST is answered, then its connection ended.
    close_after_next: std.atomic.Value(bool) = .init(false),
    /// New sessions get ids of 1500 characters.
    long_sessions: std.atomic.Value(bool) = .init(false),
    /// The token endpoint answers after this long (ms).
    token_delay_ms: i64 = 0,
    /// Bumped: every open GET stream ends.
    drop_epoch: std.atomic.Value(u32) = .init(0),
    /// The next POSTs' failure (under `mutex`).
    fail: Fail = .{},

    // the authorization server (under `mutex`)
    registered: std.atomic.Value(u32) = .init(0),
    refreshes: std.atomic.Value(u32) = .init(0),
    /// Codes exchanged with their verifier checked.
    pkce_ok: std.atomic.Value(u32) = .init(0),
    expires_in: i64 = 3600,
    openid_only: bool = false,
    clients: std.ArrayList(Client) = .empty,
    codes: std.ArrayList(Code) = .empty,
    tokens: std.ArrayList(Tok) = .empty,
    /// The last /auth/authorize query, as it came.
    last_authorize: std.ArrayList(u8) = .empty,

    const Client = struct { id: []u8, redirect: []u8 };
    const Code = struct { code: []u8, client: []u8, redirect: []u8, challenge: []u8, resource: []u8, scope: []u8, used: bool = false };
    const Tok = struct { access: []u8, refresh: []u8, scope: []u8, access_ok: bool = true, refresh_ok: bool = true };

    const gpa = std.heap.page_allocator;

    pub const Fail = struct {
        status: u16 = 0,
        count: u32 = 1,
        /// Only requests of this method ("": any).
        method: []const u8 = "",
        retry_after: ?u32 = null,
        location: []const u8 = "",
        /// The message says the Authorization the request carried.
        echo_auth: bool = false,
    };

    const Session = struct {
        id_buf: [1600]u8 = undefined,
        id_len: usize = 0,
        version: []const u8,
        ended: bool = false,
        pinged: bool = false,
        next_event: u32 = 0,
        /// Notifications for the GET stream (gpa).
        queue: std.ArrayList([]u8) = .empty,
        subscribed: std.ArrayList([]u8) = .empty,

        fn id(s: *const Session) []const u8 {
            return s.id_buf[0..s.id_len];
        }
    };

    pub fn deinit(h: *Http) void {
        for (h.sessions.items) |s| {
            for (s.queue.items) |q| gpa.free(q);
            s.queue.deinit(gpa);
            for (s.subscribed.items) |u| gpa.free(u);
            s.subscribed.deinit(gpa);
            gpa.destroy(s);
        }
        h.sessions.deinit(gpa);
        for (h.clients.items) |x| {
            gpa.free(x.id);
            gpa.free(x.redirect);
        }
        h.clients.deinit(gpa);
        for (h.codes.items) |x| for ([_][]u8{ x.code, x.client, x.redirect, x.challenge, x.resource, x.scope }) |y| gpa.free(y);
        h.codes.deinit(gpa);
        for (h.tokens.items) |x| for ([_][]u8{ x.access, x.refresh, x.scope }) |y| gpa.free(y);
        h.tokens.deinit(gpa);
        h.last_authorize.deinit(gpa);
    }

    /// The server forgets every session: the next request with one gets 404.
    pub fn endSessions(h: *Http) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.sessions.items) |s| s.ended = true;
    }

    /// Every open GET stream ends.
    pub fn dropStreams(h: *Http) void {
        _ = h.drop_epoch.fetchAdd(1, .acq_rel);
    }

    /// The next POST's connection ends once it is read, with no answer.
    pub fn dropNext(h: *Http) void {
        h.drop_next.store(true, .release);
    }

    /// The next POST's connection ends once it is answered.
    pub fn closeAfterNext(h: *Http) void {
        h.close_after_next.store(true, .release);
    }

    /// The token endpoint answers after `ms`.
    pub fn setTokenDelay(h: *Http, ms: i64) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.token_delay_ms = ms;
    }

    /// The next `f.count` POSTs (of `f.method`) answer `f.status`.
    pub fn failNext(h: *Http, f: Fail) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.fail = f;
    }

    /// The tokens issued from now on expire in `seconds`.
    pub fn setExpiresIn(h: *Http, seconds: i64) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.expires_in = seconds;
    }

    /// Only OpenID discovery's metadata (no RFC 8414 document).
    pub fn setOpenIdOnly(h: *Http, on: bool) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.openid_only = on;
    }

    /// Every access token issued so far is refused (401).
    pub fn expireTokens(h: *Http) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.tokens.items) |*x| x.access_ok = false;
    }

    /// Every refresh token issued so far is refused.
    pub fn revokeRefresh(h: *Http) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.tokens.items) |*x| x.refresh_ok = false;
    }

    /// The last /auth/authorize query (in `a`).
    pub fn lastAuthorize(h: *Http, a: std.mem.Allocator) ![]const u8 {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return a.dupe(u8, h.last_authorize.items);
    }

    fn validAccess(h: *Http, io: Io, token: []const u8) bool {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.tokens.items) |x| if (x.access_ok and std.mem.eql(u8, x.access, token)) return true;
        return false;
    }

    /// How many sessions subscribed to `uri`.
    pub fn subscribedIn(h: *Http, uri: []const u8) u32 {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        var n: u32 = 0;
        for (h.sessions.items) |s| for (s.subscribed.items) |u| {
            if (std.mem.eql(u8, u, uri)) n += 1;
        };
        return n;
    }

    /// `/mcp/…`, and for sign-ins `/.well-known/…` and `/auth/…`.
    pub fn handle(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, method: std.http.Method, target: []const u8, hs: []const Header, body: []const u8) !void {
        const route = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        if (std.mem.startsWith(u8, route, "/.well-known/") or std.mem.startsWith(u8, route, "/auth/")) return h.authServer(c, a, req, method, target, route, body);
        if (!std.mem.startsWith(u8, route, "/mcp/")) return json(req, .not_found, "{}");
        const flavor = route["/mcp/".len..];
        const known = [_][]const u8{ "json", "sse", "old", "future", "token", "nostream", "getless", "signin", "signin-hidden" };
        for (known) |k| {
            if (std.mem.eql(u8, k, flavor)) break;
        } else return json(req, .not_found, "{\"error\":\"no such server\"}");
        if (std.mem.eql(u8, flavor, "token")) {
            const want = if (Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(a, &.{ c.dir, "mcp-token" }), a, .limited(4096))) |x| std.mem.trim(u8, x, " \r\n\t") else |_| "mcp-test-token-1";
            const got = header(hs, "authorization") orelse "";
            if (!std.mem.startsWith(u8, got, "Bearer ") or !std.mem.eql(u8, got["Bearer ".len..], want))
                return req.respond(try std.fmt.allocPrint(a, "{{\"error\":\"invalid_token\",\"error_description\":{f}}}", .{std.json.fmt(try std.fmt.allocPrint(a, "{s} is not a token here", .{got}), .{})}), .{ .status = .unauthorized, .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "www-authenticate", .value = "Bearer error=\"invalid_token\"" },
                } });
        }
        if (std.mem.startsWith(u8, flavor, "signin")) {
            const got = header(hs, "authorization") orelse "";
            if (!std.mem.startsWith(u8, got, "Bearer ") or !h.validAccess(c.io, got["Bearer ".len..])) {
                const www = if (std.mem.eql(u8, flavor, "signin"))
                    try std.fmt.allocPrint(a, "Bearer resource_metadata=\"http://127.0.0.1:{d}/.well-known/oauth-protected-resource/mcp/signin\"", .{c.port})
                else
                    "Bearer error=\"invalid_token\"";
                return req.respond("{\"error\":\"invalid_token\"}", .{ .status = .unauthorized, .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "www-authenticate", .value = www },
                } });
            }
        }
        return switch (method) {
            .POST => {
                // read, then ended with no answer
                if (h.drop_next.swap(false, .acq_rel)) return error.Dropped;
                try h.post(c, a, req, flavor, hs, body);
                // answered, then ended
                if (h.close_after_next.swap(false, .acq_rel)) return error.Closing;
            },
            .GET => h.stream(c, a, req, flavor, hs),
            .DELETE => h.delete(c, req, hs),
            else => json(req, .method_not_allowed, "{}"),
        };
    }

    fn authServer(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, method: std.http.Method, target: []const u8, route: []const u8, body: []const u8) !void {
        return authServerImpl(h, c, a, req, method, target, route, body);
    }

    fn issue(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, scope: []const u8, expires: i64) !void {
        return issueImpl(h, c, a, req, scope, expires);
    }

    fn takeFail(h: *Http, io: Io, method: []const u8) ?Fail {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        if (h.fail.status == 0 or h.fail.count == 0) return null;
        if (h.fail.method.len > 0 and !std.mem.eql(u8, h.fail.method, method)) return null;
        const f = h.fail;
        h.fail.count -= 1;
        if (h.fail.count == 0) h.fail = .{};
        return f;
    }

    /// The session a request names, if the server still has it.
    fn find(h: *Http, io: Io, hs: []const Header) ?*Session {
        const sid = header(hs, "mcp-session-id") orelse return null;
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        if (h.end_always.load(.acquire)) return null;
        for (h.sessions.items) |s| if (!s.ended and std.mem.eql(u8, s.id(), sid)) return s;
        return null;
    }

    fn post(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, flavor: []const u8, hs: []const Header, body: []const u8) !void {
        if (h.takeFail(c.io, jv.str(jv.get(jv.parse(a, body), "method")) orelse "")) |f| {
            const msg = if (f.echo_auth) try std.fmt.allocPrint(a, "forbidden for {s}", .{header(hs, "authorization") orelse ""}) else "scripted failure";
            const out = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32000,\"message\":{f}}}}}", .{std.json.fmt(msg, .{})});
            var extra: [3]std.http.Header = undefined;
            var n: usize = 0;
            extra[n] = .{ .name = "content-type", .value = "application/json" };
            n += 1;
            var rb: [16]u8 = undefined;
            if (f.retry_after) |r| {
                extra[n] = .{ .name = "retry-after", .value = try std.fmt.bufPrint(&rb, "{d}", .{r}) };
                n += 1;
            }
            if (f.location.len > 0) {
                extra[n] = .{ .name = "location", .value = f.location };
                n += 1;
            }
            return req.respond(out, .{ .status = @enumFromInt(f.status), .extra_headers = extra[0..n] });
        }
        const v = jv.parse(a, body) orelse return json(req, .bad_request, "{\"error\":\"not JSON\"}");
        const method = jv.str(jv.get(v, "method"));
        const idv: ?std.json.Value = if (v == .object) v.object.get("id") else null;
        if (method != null and std.mem.eql(u8, method.?, "initialize")) {
            const version: []const u8 = if (std.mem.eql(u8, flavor, "old")) "2025-03-26" else if (std.mem.eql(u8, flavor, "future")) "2099-01-01" else "2025-06-18";
            const s = try gpa.create(Session);
            s.* = .{ .version = version };
            var raw: [8]u8 = undefined;
            c.io.random(&raw);
            const sid = try std.fmt.bufPrint(&s.id_buf, "s-{x}", .{raw});
            s.id_len = sid.len;
            if (h.long_sessions.load(.acquire)) {
                @memset(s.id_buf[s.id_len..1500], 'j');
                s.id_len = 1500;
            }
            {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                try h.sessions.append(gpa, s);
            }
            _ = h.initializes.fetchAdd(1, .acq_rel);
            const result = try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{\"subscribe\":true}}}},\"serverInfo\":{{\"name\":\"fake-http\",\"version\":\"1\"}}}}", .{version});
            return answer(req, a, flavor, try reply(a, idv, result), s.id());
        }
        if (header(hs, "mcp-session-id") == null) return json(req, .bad_request, "{\"error\":\"no session\"}");
        const s = h.find(c.io, hs) orelse return json(req, .not_found, "{\"error\":\"no such session\"}");
        if (!std.mem.eql(u8, header(hs, "mcp-protocol-version") orelse "", s.version)) return json(req, .bad_request, "{\"error\":\"MCP-Protocol-Version is not the session's\"}");
        if (method == null) {
            // a response: ours to the ping is "p1"
            if (idv) |i| if (i == .string and std.mem.eql(u8, i.string, "p1") and jv.get(v, "result") != null) {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                s.pinged = true;
            };
            return req.respond("", .{ .status = .accepted });
        }
        // a notification needs no answer
        if (idv == null) return req.respond("", .{ .status = .accepted });
        const m = method.?;
        if (std.mem.eql(u8, m, "tools/list")) return answer(req, a, flavor, try reply(a, idv, tools_json), null);
        if (std.mem.eql(u8, m, "ping")) return answer(req, a, flavor, try reply(a, idv, "{}"), null);
        if (std.mem.eql(u8, m, "resources/subscribe")) {
            const uri = jv.str(jv.at(v, &.{ "params", "uri" })) orelse "";
            {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                try s.subscribed.append(gpa, try gpa.dupe(u8, uri));
            }
            return answer(req, a, flavor, try reply(a, idv, "{}"), null);
        }
        if (std.mem.eql(u8, m, "resources/read")) {
            const uri = jv.str(jv.at(v, &.{ "params", "uri" })) orelse "";
            const name = if (std.mem.startsWith(u8, uri, "fake://")) uri["fake://".len..] else "";
            const text = if (name.len > 0 and std.mem.indexOfAny(u8, name, "/\\") == null and !std.mem.eql(u8, name, ".."))
                Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(a, &.{ c.dir, "mcp-files", name }), a, .limited(1 << 20)) catch null
            else
                null;
            const t = text orelse return answer(req, a, flavor, try errorReply(a, idv, -32002, "no such resource"), null);
            return answer(req, a, flavor, try reply(a, idv, try std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":{f},\"mimeType\":\"text/plain\",\"text\":{f}}}]}}", .{ std.json.fmt(uri, .{}), std.json.fmt(t, .{}) })), null);
        }
        if (std.mem.eql(u8, m, "tools/call")) {
            const name = jv.str(jv.at(v, &.{ "params", "name" })) orelse "";
            const text = jv.str(jv.at(v, &.{ "params", "arguments", "text" })) orelse "";
            if (std.mem.eql(u8, name, "echo") and std.mem.startsWith(u8, text, "notify:")) {
                const note = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{{\"uri\":{f}}}}}", .{std.json.fmt(text["notify:".len..], .{})});
                h.mutex.lockUncancelable(c.io);
                s.queue.append(gpa, note) catch gpa.free(note);
                h.mutex.unlock(c.io);
                return answer(req, a, flavor, try reply(a, idv, try textResult(a, "notified", false)), null);
            }
            if (std.mem.eql(u8, name, "echo") and std.mem.eql(u8, text, "auth")) return answer(req, a, flavor, try reply(a, idv, try textResult(a, header(hs, "authorization") orelse "none", false)), null);
            // an error that says back the Authorization it got
            if (std.mem.eql(u8, name, "echo") and std.mem.eql(u8, text, "error-auth")) return answer(req, a, flavor, try errorReply(a, idv, -32000, try std.fmt.allocPrint(a, "bad token: {s}", .{header(hs, "authorization") orelse "none"})), null);
            if (std.mem.eql(u8, name, "sleep")) {
                // by the clock, and ended by the stand-in's stop
                const ms = jv.int(jv.at(v, &.{ "params", "arguments", "ms" })) orelse 0;
                const until = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
                while (Io.Clock.awake.now(c.io).nanoseconds < until and !c.stopping.load(.acquire)) c.io.sleep(.fromMilliseconds(20), .awake) catch {};
                return answer(req, a, flavor, try reply(a, idv, try textResult(a, "slept", false)), null);
            }
            const pinged = blk: {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                break :blk s.pinged;
            };
            var env = std.process.Environ.Map.init(a);
            const result = try call(c.io, a, v, &env, pinged);
            return answer(req, a, flavor, try reply(a, idv, result), null);
        }
        return answer(req, a, flavor, try errorReply(a, idv, -32601, "no such method"), null);
    }

    /// The GET stream of a session: what `notify:` queued, as it comes.
    fn stream(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, flavor: []const u8, hs: []const Header) !void {
        _ = a;
        if (std.mem.eql(u8, flavor, "nostream")) {
            _ = h.refused_gets.fetchAdd(1, .acq_rel);
            return json(req, .method_not_allowed, "{}");
        }
        if (std.mem.eql(u8, flavor, "getless")) {
            _ = h.missed_gets.fetchAdd(1, .acq_rel);
            return json(req, .not_found, "{\"error\":\"Cannot GET /mcp/getless\"}");
        }
        const s = h.find(c.io, hs) orelse return json(req, .not_found, "{\"error\":\"no such session\"}");
        if (std.mem.indexOf(u8, header(hs, "accept") orelse "", "text/event-stream") == null) return json(req, .not_acceptable, "{}");
        const epoch = h.drop_epoch.load(.acquire);
        var buf: [4096]u8 = undefined;
        var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } });
        try bw.writer.writeAll(": stream open\n\n");
        try bw.writer.flush();
        try bw.flush();
        _ = h.streams.fetchAdd(1, .acq_rel);
        while (!c.stopping.load(.acquire) and h.drop_epoch.load(.acquire) == epoch) {
            const item: ?[]u8, const n: u32, const ended = blk: {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                if (s.ended or h.end_always.load(.acquire)) break :blk .{ null, 0, true };
                if (s.queue.items.len == 0) break :blk .{ null, 0, false };
                s.next_event += 1;
                break :blk .{ s.queue.orderedRemove(0), s.next_event, false };
            };
            if (ended) break;
            if (item) |x| {
                defer gpa.free(x);
                try bw.writer.print("id: {d}\ndata: {s}\n\n", .{ n, x });
                try bw.writer.flush();
                try bw.flush();
                continue;
            }
            c.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        bw.end() catch {};
    }

    fn delete(h: *Http, c: Ctx, req: *std.http.Server.Request, hs: []const Header) !void {
        const s = h.find(c.io, hs) orelse return json(req, .not_found, "{}");
        {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            s.ended = true;
        }
        _ = h.deleted.fetchAdd(1, .acq_rel);
        return json(req, .ok, "{}");
    }
};

/// The authorization server's routes (see `Http`).
fn authServerImpl(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, method: std.http.Method, target: []const u8, route: []const u8, body: []const u8) !void {
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{c.port});
    const issuer = try std.fmt.allocPrint(a, "{s}/auth", .{base});
    const prm = "/.well-known/oauth-protected-resource/mcp/";
    if (method == .GET and std.mem.startsWith(u8, route, prm)) {
        const flavor = route[prm.len..];
        if (!std.mem.eql(u8, flavor, "signin") and !std.mem.eql(u8, flavor, "signin-hidden")) return json(req, .not_found, "{}");
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"resource\":\"{s}/mcp/{s}\",\"authorization_servers\":[\"{s}\"],\"scopes_supported\":[\"mcp.read\",\"mcp.write\"],\"bearer_methods_supported\":[\"header\"]}}", .{ base, flavor, issuer }));
    }
    const openid_only = blk: {
        h.mutex.lockUncancelable(c.io);
        defer h.mutex.unlock(c.io);
        break :blk h.openid_only;
    };
    const metadata = try std.fmt.allocPrint(a, "{{\"issuer\":\"{s}\",\"authorization_endpoint\":\"{s}/authorize\",\"token_endpoint\":\"{s}/token\",\"registration_endpoint\":\"{s}/register\",\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"],\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\"]}}", .{ issuer, issuer, issuer, issuer });
    if (method == .GET and std.mem.eql(u8, route, "/.well-known/oauth-authorization-server/auth")) return if (openid_only) json(req, .not_found, "{}") else json(req, .ok, metadata);
    if (method == .GET and std.mem.eql(u8, route, "/auth/.well-known/openid-configuration")) return if (openid_only) json(req, .ok, metadata) else json(req, .not_found, "{}");
    if (method == .POST and std.mem.eql(u8, route, "/auth/register")) {
        const v = jv.parse(a, body) orelse return json(req, .bad_request, "{\"error\":\"invalid_client_metadata\"}");
        const redirect = jv.str(jv.at(v, &.{ "redirect_uris", "0" })) orelse return json(req, .bad_request, "{\"error\":\"invalid_redirect_uri\"}");
        const id = blk: {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            const id = try std.fmt.allocPrint(Http.gpa, "client-{d}", .{h.clients.items.len + 1});
            try h.clients.append(Http.gpa, .{ .id = id, .redirect = try Http.gpa.dupe(u8, redirect) });
            break :blk try a.dupe(u8, id);
        };
        _ = h.registered.fetchAdd(1, .acq_rel);
        return req.respond(try std.fmt.allocPrint(a, "{{\"client_id\":\"{s}\",\"redirect_uris\":[{f}],\"token_endpoint_auth_method\":\"none\",\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"]}}", .{ id, std.json.fmt(redirect, .{}) }), .{ .status = .created, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }
    if (method == .GET and std.mem.eql(u8, route, "/auth/authorize")) {
        const query = target[@min(route.len + 1, target.len)..];
        {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            h.last_authorize.clearRetainingCapacity();
            try h.last_authorize.appendSlice(Http.gpa, query);
        }
        const client = try param(a, query, "client_id") orelse "";
        const redirect = try param(a, query, "redirect_uri") orelse "";
        const challenge = try param(a, query, "code_challenge") orelse "";
        const state = try param(a, query, "state") orelse "";
        const res_uri = try param(a, query, "resource") orelse "";
        const scope = try param(a, query, "scope") orelse "";
        const why: ?[]const u8 = blk: {
            if (!std.mem.eql(u8, try param(a, query, "response_type") orelse "", "code")) break :blk "response_type is not code";
            if (!std.mem.eql(u8, try param(a, query, "code_challenge_method") orelse "", "S256") or challenge.len != 43) break :blk "no S256 code challenge";
            if (state.len == 0) break :blk "no state";
            if (!std.mem.startsWith(u8, res_uri, base) or !std.mem.startsWith(u8, res_uri[base.len..], "/mcp/signin")) break :blk "not a resource of this server";
            const known = known: {
                if (std.mem.eql(u8, client, "fixed-client")) break :known std.mem.startsWith(u8, redirect, "http://127.0.0.1:") and std.mem.endsWith(u8, redirect, "/callback");
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                for (h.clients.items) |cl| if (std.mem.eql(u8, cl.id, client)) break :known std.mem.eql(u8, cl.redirect, redirect);
                break :known false;
            };
            if (!known) break :blk "unknown client or redirect_uri";
            break :blk null;
        };
        if (why) |w| return req.respond(try std.fmt.allocPrint(a, "bad request: {s}\n", .{w}), .{ .status = .bad_request, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
        var raw: [6]u8 = undefined;
        c.io.random(&raw);
        const code = try std.fmt.allocPrint(Http.gpa, "code-{x}", .{raw});
        {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            try h.codes.append(Http.gpa, .{ .code = code, .client = try Http.gpa.dupe(u8, client), .redirect = try Http.gpa.dupe(u8, redirect), .challenge = try Http.gpa.dupe(u8, challenge), .resource = try Http.gpa.dupe(u8, res_uri), .scope = try Http.gpa.dupe(u8, scope) });
        }
        const location = try std.fmt.allocPrint(a, "{s}?code={s}&state={s}&iss={s}", .{ redirect, code, try escape(a, state), try escape(a, issuer) });
        return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = location }} });
    }
    if (method == .POST and std.mem.eql(u8, route, "/auth/token")) {
        const delay = blk: {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            break :blk h.token_delay_ms;
        };
        const until = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, delay) * std.time.ns_per_ms;
        while (Io.Clock.awake.now(c.io).nanoseconds < until and !c.stopping.load(.acquire)) c.io.sleep(.fromMilliseconds(20), .awake) catch {};
        const grant = try param(a, body, "grant_type") orelse "";
        const expires = blk: {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            break :blk h.expires_in;
        };
        if (std.mem.eql(u8, grant, "authorization_code")) {
            const code = try param(a, body, "code") orelse "";
            const verifier = try param(a, body, "code_verifier") orelse "";
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
            var want: [43]u8 = undefined;
            _ = std.base64.url_safe_no_pad.Encoder.encode(&want, &digest);
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            for (h.codes.items) |*cd| {
                if (cd.used or !std.mem.eql(u8, cd.code, code)) continue;
                cd.used = true;
                if (!std.mem.eql(u8, try param(a, body, "client_id") orelse "", cd.client)) return grantError(req, "client_id is not the code's");
                if (!std.mem.eql(u8, try param(a, body, "redirect_uri") orelse "", cd.redirect)) return grantError(req, "redirect_uri is not the code's");
                if (!std.mem.eql(u8, try param(a, body, "resource") orelse "", cd.resource)) return grantError(req, "resource is not the code's");
                if (!std.mem.eql(u8, &want, cd.challenge)) return grantError(req, "PKCE check failed");
                _ = h.pkce_ok.fetchAdd(1, .acq_rel);
                return h.issue(c, a, req, cd.scope, expires);
            }
            return grantError(req, "unknown or used code");
        }
        if (std.mem.eql(u8, grant, "refresh_token")) {
            const refresh = try param(a, body, "refresh_token") orelse "";
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            for (h.tokens.items) |*x| {
                if (!x.refresh_ok or !std.mem.eql(u8, x.refresh, refresh)) continue;
                x.refresh_ok = false;
                x.access_ok = false;
                _ = h.refreshes.fetchAdd(1, .acq_rel);
                return h.issue(c, a, req, x.scope, expires);
            }
            return grantError(req, "unknown refresh token");
        }
        return req.respond("{\"error\":\"unsupported_grant_type\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }
    return json(req, .not_found, "{}");
}

/// New tokens (under `mutex`).
fn issueImpl(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, scope: []const u8, expires: i64) !void {
    var raw: [6]u8 = undefined;
    c.io.random(&raw);
    const n = h.tokens.items.len + 1;
    const access = try std.fmt.allocPrint(Http.gpa, "fake-access-{d}-{x}", .{ n, raw });
    const refresh = try std.fmt.allocPrint(Http.gpa, "fake-refresh-{d}-{x}", .{ n, raw });
    try h.tokens.append(Http.gpa, .{ .access = access, .refresh = refresh, .scope = try Http.gpa.dupe(u8, scope) });
    return json(req, .ok, try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":{d},\"refresh_token\":\"{s}\",\"scope\":{f}}}", .{ access, expires, refresh, std.json.fmt(scope, .{}) }));
}

fn grantError(req: *std.http.Server.Request, why: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"invalid_grant\",\"error_description\":\"{s}\"}}", .{why}) catch "{\"error\":\"invalid_grant\"}";
    return req.respond(body, .{ .status = .bad_request, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

/// A form's or query's parameter, decoded; null when absent.
fn param(a: std.mem.Allocator, form: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, form, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '+') {
                try out.append(a, ' ');
            } else if (raw[i] == '%' and i + 2 < raw.len and std.ascii.isHex(raw[i + 1]) and std.ascii.isHex(raw[i + 2])) {
                try out.append(a, (std.fmt.charToDigit(raw[i + 1], 16) catch 0) * 16 + (std.fmt.charToDigit(raw[i + 2], 16) catch 0));
                i += 2;
            } else try out.append(a, raw[i]);
        }
        return out.items;
    }
    return null;
}

fn escape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') try out.append(a, ch) else try out.print(a, "%{X:0>2}", .{ch});
    }
    return out.items;
}

/// A header's value (the first of that name, any case).
pub fn header(hs: []const Header, name: []const u8) ?[]const u8 {
    for (hs) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
    return null;
}

fn reply(a: std.mem.Allocator, idv: ?std.json.Value, result: []const u8) ![]const u8 {
    const id_json = if (idv) |i| try std.json.Stringify.valueAlloc(a, i, .{}) else "null";
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result });
}

fn errorReply(a: std.mem.Allocator, idv: ?std.json.Value, code: i32, msg: []const u8) ![]const u8 {
    const id_json = if (idv) |i| try std.json.Stringify.valueAlloc(a, i, .{}) else "null";
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{ id_json, code, std.json.fmt(msg, .{}) });
}

/// A response as JSON, or (flavor sse) as an event stream: a notification
/// and a ping of the server's own first, the response in two data lines.
fn answer(req: *std.http.Server.Request, a: std.mem.Allocator, flavor: []const u8, msg: []const u8, session: ?[]const u8) !void {
    _ = a;
    var extra: [2]std.http.Header = undefined;
    var n: usize = 0;
    if (session) |sid| {
        extra[n] = .{ .name = "mcp-session-id", .value = sid };
        n += 1;
    }
    if (!std.mem.eql(u8, flavor, "sse")) {
        extra[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
        return req.respond(msg, .{ .extra_headers = extra[0..n] });
    }
    extra[n] = .{ .name = "content-type", .value = "text/event-stream" };
    n += 1;
    var buf: [4096]u8 = undefined;
    var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = extra[0..n] } });
    try bw.writer.writeAll("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"working\"}}\n\n");
    try bw.writer.writeAll("data: {\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}\n\n");
    try bw.writer.flush();
    try bw.flush();
    try bw.writer.print("id: 1\ndata: {{\ndata: {s}\n\n", .{msg[1..]});
    try bw.end();
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}
