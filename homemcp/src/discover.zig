//! `homemcp discover`: a home file from what a hub knows, with safe
//! defaults. Home Assistant: its areas, devices, entities (with their voice
//! aliases) and states, over its WebSocket API. Zigbee2MQTT: the bridge's
//! device list. Lights, plugs, switches, heating, fans, blinds, scenes and
//! speakers may act within [limits]; locks, alarms, garage doors, valves
//! and scenes that set them are guarded and allowed only the safe way
//! (lock, close, arm); sensors are only seen; cameras, smoke, CO and gas
//! detectors, devices' settings and anything unknown are left out, each
//! named in a comment that says why.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const model = @import("model.zig");
const jv = @import("jv.zig");
const ws = @import("ws.zig");
const mqtt = @import("mqtt.zig");

/// The home file, and a few lines saying what is in it.
pub const Found = struct { text: []const u8, summary: []const u8 };

/// Why something is left out of the file.
pub const Reason = enum {
    camera,
    safety,
    setting,
    hidden,
    unsupported,
    unknown,

    fn header(r: Reason) []const u8 {
        return switch (r) {
            .camera => "cameras: never offered (homemcp has no camera support; what they see is personal)",
            .safety => "smoke, CO and gas detectors: left out; homemcp is not a safety system, so keep their own alarms",
            .setting => "settings and diagnostics of devices (a child lock, a LED, a firmware update): not things to switch",
            .hidden => "hidden in Home Assistant",
            .unsupported => "not supported by Zigbee2MQTT",
            .unknown => "kinds homemcp doesn't know (a light, switch or sensor among them can be added by hand)",
        };
    }

    fn short(r: Reason) []const u8 {
        return switch (r) {
            .camera => "a camera",
            .safety => "a smoke or CO alarm",
            .setting => "a setting",
            .hidden => "hidden",
            .unsupported => "not supported",
            .unknown => "not a kind homemcp knows",
        };
    }
};

/// A device for the file: what it is and what it may do (nothing: only seen).
pub const Act = struct {
    kind: model.Kind,
    allow: []const model.Action = &.{},
    guarded: bool = false,
    modes: []const []const u8 = &.{},
    note: []const u8 = "",
};

pub const Verdict = union(enum) { act: Act, person, left: Reason };

const valve_words = [_][]const u8{ "valve", "water main", "stopcock" };
const opener_words = [_][]const u8{ "garage", "gate", "door", "lock", "alarm", "siren" };
const safety_classes = [_][]const u8{ "smoke", "carbon_monoxide", "gas" };
const binary_classes = [_][]const u8{ "motion", "occupancy", "presence", "door", "garage_door", "window", "opening", "moisture", "vibration", "cold", "heat", "light", "sound", "lock" };
const number_classes = [_][]const u8{ "temperature", "humidity", "illuminance", "power", "energy", "carbon_dioxide", "pm25", "pm10", "pressure", "moisture", "volatile_organic_compounds" };

const valve_note = "a valve, by its name: it may only be switched off (closed)";
const opener_note = "by its name it opens or locks something: nothing is allowed until you add it";

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

fn nameHas(name: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.findIgnoreCase(name, w) != null) return true;
    return false;
}

/// What Home Assistant entity `id` (`name` its friendly name, `dclass` its
/// device class, `st` its state if known) becomes in the file.
pub fn classifyHa(a: Allocator, id: []const u8, name: []const u8, dclass: []const u8, st: ?jv.Value) Verdict {
    const domain = id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
    const attrs = jv.get(st, "attributes");
    const eq = std.mem.eql;
    if (eq(u8, domain, "camera")) return .{ .left = .camera };
    if (eq(u8, domain, "person")) return .person;
    if ((eq(u8, domain, "binary_sensor") or eq(u8, domain, "sensor")) and has(&safety_classes, dclass)) return .{ .left = .safety };
    if (eq(u8, domain, "light")) {
        var allow: std.ArrayList(model.Action) = .empty;
        allow.appendSlice(a, &.{ .on, .off }) catch return .{ .left = .unknown };
        const modes = jv.arr(jv.get(attrs, "supported_color_modes"));
        var dims = modes == null;
        var colour = false;
        var temp = false;
        for (modes orelse &.{}) |m| {
            const x = jv.str(m) orelse continue;
            if (!eq(u8, x, "onoff")) dims = true;
            if (has(&.{ "hs", "xy", "rgb", "rgbw", "rgbww" }, x)) colour = true;
            if (eq(u8, x, "color_temp")) temp = true;
        }
        if (dims) allow.append(a, .brightness) catch {};
        if (colour) allow.append(a, .color) catch {};
        if (temp) allow.append(a, .color_temp) catch {};
        return .{ .act = .{ .kind = .light, .allow = allow.items } };
    }
    if (eq(u8, domain, "switch")) {
        if (nameHas(name, &valve_words)) return .{ .act = .{ .kind = .@"switch", .allow = &.{.off}, .guarded = true, .note = valve_note } };
        if (nameHas(name, &opener_words)) return .{ .act = .{ .kind = .@"switch", .guarded = true, .note = opener_note } };
        return .{ .act = .{ .kind = if (eq(u8, dclass, "outlet")) .plug else .@"switch", .allow = &.{ .on, .off } } };
    }
    if (eq(u8, domain, "fan")) {
        const speed = st == null or jv.get(attrs, "percentage") != null or jv.get(attrs, "percentage_step") != null;
        return .{ .act = .{ .kind = .fan, .allow = if (speed) &.{ .on, .off, .speed } else &.{ .on, .off } } };
    }
    if (eq(u8, domain, "climate")) {
        var modes: std.ArrayList([]const u8) = .empty;
        for (jv.arr(jv.get(attrs, "hvac_modes")) orelse &.{}) |m| {
            const w = model.word(jv.str(m) orelse continue);
            if (!eq(u8, w, "unknown")) modes.append(a, w) catch {};
        }
        return .{ .act = .{ .kind = .climate, .allow = &.{ .temperature, .mode }, .modes = modes.items } };
    }
    if (eq(u8, domain, "cover")) {
        if (has(&.{ "garage", "gate", "door" }, dclass) or nameHas(name, &.{ "garage", "gate" }))
            return .{ .act = .{ .kind = .cover, .allow = &.{.close}, .guarded = true } };
        const pos = st == null or jv.get(attrs, "current_position") != null;
        return .{ .act = .{ .kind = .cover, .allow = if (pos) &.{ .open, .close, .stop, .position } else &.{ .open, .close, .stop } } };
    }
    if (eq(u8, domain, "lock")) return .{ .act = .{ .kind = .lock, .allow = &.{.lock}, .guarded = true } };
    if (eq(u8, domain, "alarm_control_panel")) return .{ .act = .{ .kind = .alarm, .allow = &.{ .arm_home, .arm_away }, .guarded = true } };
    if (eq(u8, domain, "valve")) return .{ .act = .{ .kind = .valve, .allow = &.{.close}, .guarded = true } };
    if (eq(u8, domain, "scene")) return .{ .act = .{ .kind = .scene, .allow = &.{.activate} } };
    if (eq(u8, domain, "media_player")) return .{ .act = .{ .kind = .media, .allow = &.{ .play, .pause, .volume } } };
    if (eq(u8, domain, "binary_sensor") and has(&binary_classes, dclass)) return .{ .act = .{ .kind = .sensor } };
    if (eq(u8, domain, "sensor") and has(&number_classes, dclass)) return .{ .act = .{ .kind = .sensor } };
    return .{ .left = .unknown };
}

/// One thing the hub has, and what becomes of it.
const Item = struct {
    id: []const u8,
    /// as people call it (the friendly name)
    label: []const u8,
    verdict: Verdict,
    room: []const u8 = "",
    aliases: []const []const u8 = &.{},
    /// its name in the file
    name: []const u8 = "",
};

/// Home Assistant at `url`, read over its WebSocket API with `token`.
pub fn fromHomeAssistant(a: Allocator, io: Io, url: []const u8, token: []const u8) !Found {
    const c = try ws.Conn.open(a, io, url, "/api/websocket", 10_000);
    defer c.close();
    {
        const hello = jv.parse(a, (try c.next(10_000)) orelse return error.NoAnswer) orelse return error.NotHomeAssistant;
        if (!std.mem.eql(u8, jv.str(jv.get(hello, "type")) orelse "", "auth_required")) return error.NotHomeAssistant;
        try c.send(try std.fmt.allocPrint(a, "{{\"type\":\"auth\",\"access_token\":{f}}}", .{std.json.fmt(token, .{})}));
        const ok = jv.parse(a, (try c.next(10_000)) orelse return error.NoAnswer) orelse return error.NotHomeAssistant;
        const ty = jv.str(jv.get(ok, "type")) orelse "";
        if (std.mem.eql(u8, ty, "auth_invalid")) return error.Unauthorized;
        if (!std.mem.eql(u8, ty, "auth_ok")) return error.NotHomeAssistant;
    }
    const asks = [_][]const u8{ "get_config", "config/area_registry/list", "config/device_registry/list", "config/entity_registry/list", "get_states" };
    for (asks, 1..) |kind, id| try c.send(try std.fmt.allocPrint(a, "{{\"id\":{d},\"type\":\"{s}\"}}", .{ id, kind }));
    var answers: [asks.len]?jv.Value = @splat(null);
    try collect(a, c, &answers, 1, 30_000);
    const states = jv.arr(answers[4]) orelse return error.NoStates;
    var found = try readHa(a, url, answers[0], answers[1], answers[2], answers[3], states, null);
    // the names people gave them in Home Assistant's voice settings
    var ids: std.ArrayList(u8) = .empty;
    try ids.append(a, '[');
    for (found.items, 0..) |it, i| {
        if (i > 0) try ids.append(a, ',');
        try ids.print(a, "{f}", .{std.json.fmt(it.id, .{})});
    }
    try ids.append(a, ']');
    try c.send(try std.fmt.allocPrint(a, "{{\"id\":6,\"type\":\"config/entity_registry/get_entries\",\"entity_ids\":{s}}}", .{ids.items}));
    var entries: [1]?jv.Value = @splat(null);
    collect(a, c, &entries, 6, 10_000) catch {};
    if (entries[0]) |e| found = try readHa(a, url, answers[0], answers[1], answers[2], answers[3], states, e);
    return render(a, &found);
}

/// Results of requests `first`, `first + 1` ... into `out` (null where one
/// failed), within `ms`.
fn collect(a: Allocator, c: *ws.Conn, out: []?jv.Value, first: i64, ms: u32) !void {
    var got: usize = 0;
    var waited: u32 = 0;
    while (got < out.len) {
        if (waited >= ms) return error.NoAnswer;
        const msg = (try c.next(250)) orelse {
            waited += 250;
            continue;
        };
        const v = jv.parse(a, msg) orelse continue;
        const id = jv.int(jv.get(v, "id")) orelse continue;
        if (id < first or id >= first + @as(i64, @intCast(out.len))) continue;
        if (!std.mem.eql(u8, jv.str(jv.get(v, "type")) orelse "", "result")) continue;
        const i: usize = @intCast(id - first);
        out[i] = if (jv.boolean(jv.get(v, "success")) orelse false) (jv.get(v, "result") orelse jv.Value{ .null = {} }) else null;
        got += 1;
    }
}

const Read = struct {
    hub: config.Hub,
    /// Home Assistant's url, or the broker's host:port
    where: []const u8,
    /// Zigbee2MQTT's base topic
    base: []const u8 = "",
    home_name: []const u8,
    items: []Item,
    /// Home Assistant didn't say where its areas are.
    no_areas: bool = false,
};

fn readHa(a: Allocator, url: []const u8, cfg_v: ?jv.Value, areas_v: ?jv.Value, devices_v: ?jv.Value, entities_v: ?jv.Value, states: []const jv.Value, entries_v: ?jv.Value) !Read {
    var items: std.ArrayList(Item) = .empty;
    const no_areas = areas_v == null or entities_v == null;
    for (states) |st| {
        const id = jv.str(jv.get(st, "entity_id")) orelse continue;
        if (std.mem.indexOfScalar(u8, id, '.') == null) continue;
        const attrs = jv.get(st, "attributes");
        const label = try iniValue(a, jv.str(jv.get(attrs, "friendly_name")) orelse id);
        const entry = findBy(entities_v, "entity_id", id);
        var verdict: Verdict = undefined;
        if (entry != null and jv.str(jv.get(entry, "entity_category")) != null) {
            verdict = .{ .left = .setting };
        } else if (entry != null and jv.str(jv.get(entry, "hidden_by")) != null) {
            verdict = .{ .left = .hidden };
        } else verdict = classifyHa(a, id, label, jv.str(jv.get(attrs, "device_class")) orelse "", st);
        // a scene that sets something guarded is guarded too
        if (verdict == .act and verdict.act.kind == .scene) for (jv.arr(jv.get(attrs, "entity_id")) orelse &.{}) |m| {
            const member = jv.str(m) orelse continue;
            if (!guardedIn(a, states, member)) continue;
            verdict.act.guarded = true;
            verdict.act.note = try std.fmt.allocPrint(a, "it also sets {s}, so it is asked about every time", .{try iniValue(a, member)});
            break;
        };
        // its room: its own area, else its device's
        var area = jv.str(jv.get(entry, "area_id"));
        if (area == null) if (jv.str(jv.get(entry, "device_id"))) |dev| {
            area = jv.str(jv.get(findBy(devices_v, "id", dev), "area_id"));
        };
        const room = if (area) |ar| try iniValue(a, jv.str(jv.get(findBy(areas_v, "area_id", ar), "name")) orelse "") else "";
        var aliases: std.ArrayList([]const u8) = .empty;
        try aliases.append(a, label);
        if (entries_v) |ev| if (ev == .object) if (ev.object.get(id)) |e| for (jv.arr(jv.get(e, "aliases")) orelse &.{}) |al| {
            const x = try iniValue(a, jv.str(al) orelse continue);
            if (x.len > 0) try aliases.append(a, x);
        };
        try items.append(a, .{ .id = id, .label = label, .verdict = verdict, .room = room, .aliases = aliases.items });
    }
    try nameAll(a, items.items);
    return .{
        .hub = .homeassistant,
        .where = url,
        .home_name = try iniValue(a, jv.str(jv.get(cfg_v, "location_name")) orelse "Home"),
        .items = items.items,
        .no_areas = no_areas,
    };
}

/// Whether entity `id` is one homemcp guards (as the hub does when a scene
/// runs): a lock, an alarm panel, a valve, a garage door, gate or door, or a
/// switch whose name says it is one.
fn guardedIn(a: Allocator, states: []const jv.Value, id: []const u8) bool {
    const st = for (states) |x| {
        if (std.mem.eql(u8, jv.str(jv.get(x, "entity_id")) orelse "", id)) break x;
    } else null;
    const name = jv.str(jv.at(st, &.{ "attributes", "friendly_name" })) orelse id;
    const v = classifyHa(a, id, name, jv.str(jv.at(st, &.{ "attributes", "device_class" })) orelse "", st);
    return v == .act and v.act.guarded;
}

/// The element of list `v` whose `key` is `value`.
fn findBy(v: ?jv.Value, key: []const u8, value: []const u8) ?jv.Value {
    for (jv.arr(v) orelse &.{}) |x| if (std.mem.eql(u8, jv.str(jv.get(x, key)) orelse "", value)) return x;
    return null;
}

/// Names for the file: from what people call each one, else its id; each
/// used once. Aliases that say the name again, or that name two of them,
/// are dropped.
fn nameAll(a: Allocator, items: []Item) !void {
    var taken: std.ArrayList([]const u8) = .empty;
    for (items) |*it| {
        if (it.verdict == .left) continue;
        var base = try slug(a, it.label);
        if (base.len == 0) base = try slug(a, it.id[(std.mem.indexOfScalar(u8, it.id, '.') orelse 0) + 1 ..]);
        if (base.len == 0) base = "device";
        var name = base;
        var n: usize = 2;
        while (has(taken.items, name)) : (n += 1) name = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, n });
        try taken.append(a, name);
        it.name = name;
    }
    // aliases are weighed against everyone's as they came, then kept
    var nb: [128]u8 = undefined;
    var ob: [128]u8 = undefined;
    const kept = try a.alloc([]const []const u8, items.len);
    for (items, kept) |it, *k| {
        k.* = &.{};
        if (it.verdict != .act) continue;
        var keep: std.ArrayList([]const u8) = .empty;
        for (it.aliases) |al| {
            const mine = config.normalize(&nb, al) orelse continue;
            if (mine.len == 0) continue;
            var clash = false;
            for (items) |other| {
                if (other.verdict != .act) continue;
                // its own name again, or another's
                if (eqlOpt(config.normalize(&ob, other.name), mine)) clash = true;
                if (other.id.ptr == it.id.ptr) continue;
                for (other.aliases) |oal| {
                    if (eqlOpt(config.normalize(&ob, oal), mine)) clash = true;
                }
            }
            for (keep.items) |x| {
                if (eqlOpt(config.normalize(&ob, x), mine)) clash = true;
            }
            if (!clash) try keep.append(a, al);
        }
        k.* = keep.items;
    }
    for (items, kept) |*it, k| it.aliases = k;
}

fn eqlOpt(x: ?[]const u8, y: []const u8) bool {
    return if (x) |v| std.mem.eql(u8, v, y) else false;
}

/// Zigbee2MQTT's device list (bridge/devices), from the broker at
/// `where` with base topic `base`.
pub fn fromZigbee2mqtt(a: Allocator, where: []const u8, base: []const u8, devices: jv.Value) !Found {
    var items: std.ArrayList(Item) = .empty;
    for (jv.arr(devices) orelse return error.NotADeviceList) |d| {
        if (std.mem.eql(u8, jv.str(jv.get(d, "type")) orelse "", "Coordinator")) continue;
        const name = jv.str(jv.get(d, "friendly_name")) orelse continue;
        const label = try iniValue(a, name);
        // what isn't plain can't be the id the file names it by
        if (!std.mem.eql(u8, label, name)) continue;
        const def = jv.get(d, "definition");
        const verdict: Verdict = if (def == null or (jv.boolean(jv.get(d, "supported")) orelse true) == false)
            .{ .left = .unsupported }
        else
            classifyZ2m(a, name, jv.str(jv.get(def, "description")) orelse "", jv.arr(jv.get(def, "exposes")) orelse &.{});
        try items.append(a, .{ .id = name, .label = label, .verdict = verdict, .aliases = try a.dupe([]const u8, &.{label}) });
    }
    try nameAll(a, items.items);
    return render(a, &.{ .hub = .zigbee2mqtt, .where = where, .base = base, .home_name = "Home", .items = items.items });
}

/// What a Zigbee2MQTT device becomes, from what it exposes; Zigbee2MQTT has
/// no device classes, so a name (or description) saying valve or garage
/// counts.
fn classifyZ2m(a: Allocator, name: []const u8, description: []const u8, exposes: []const jv.Value) Verdict {
    const eq = std.mem.eql;
    var names: std.ArrayList([]const u8) = .empty;
    for (exposes) |e| {
        if (jv.str(jv.get(e, "name"))) |n| names.append(a, n) catch {};
        if (jv.str(jv.get(e, "property"))) |n| names.append(a, n) catch {};
        for (jv.arr(jv.get(e, "features")) orelse &.{}) |f| {
            if (jv.str(jv.get(f, "name"))) |n| names.append(a, n) catch {};
            if (jv.str(jv.get(f, "property"))) |n| names.append(a, n) catch {};
        }
    }
    const said = for ([_][]const u8{ name, description }) |x| {
        if (nameHas(x, &valve_words)) break true;
    } else false;
    for (exposes) |e| {
        const ty = jv.str(jv.get(e, "type")) orelse continue;
        if (eq(u8, ty, "light")) {
            var allow: std.ArrayList(model.Action) = .empty;
            allow.appendSlice(a, &.{ .on, .off }) catch {};
            if (has(names.items, "brightness")) allow.append(a, .brightness) catch {};
            if (has(names.items, "color_xy") or has(names.items, "color_hs")) allow.append(a, .color) catch {};
            if (has(names.items, "color_temp")) allow.append(a, .color_temp) catch {};
            return .{ .act = .{ .kind = .light, .allow = allow.items } };
        }
        if (eq(u8, ty, "switch")) {
            if (said) return .{ .act = .{ .kind = .valve, .allow = &.{.close}, .guarded = true } };
            if (nameHas(name, &opener_words)) return .{ .act = .{ .kind = .@"switch", .guarded = true, .note = opener_note } };
            return .{ .act = .{ .kind = if (has(names.items, "power")) .plug else .@"switch", .allow = &.{ .on, .off } } };
        }
        if (eq(u8, ty, "fan")) return .{ .act = .{ .kind = .fan, .allow = if (has(names.items, "fan_mode")) &.{ .on, .off, .speed } else &.{ .on, .off } } };
        if (eq(u8, ty, "climate")) {
            var modes: std.ArrayList([]const u8) = .empty;
            for (jv.arr(jv.get(e, "features")) orelse &.{}) |f| {
                if (!eq(u8, jv.str(jv.get(f, "property")) orelse "", "system_mode")) continue;
                for (jv.arr(jv.get(f, "values")) orelse &.{}) |m| {
                    const w = model.word(jv.str(m) orelse continue);
                    if (!eq(u8, w, "unknown")) modes.append(a, w) catch {};
                }
            }
            return .{ .act = .{ .kind = .climate, .allow = &.{ .temperature, .mode }, .modes = modes.items } };
        }
        if (eq(u8, ty, "cover")) {
            if (nameHas(name, &.{ "garage", "gate" }) or nameHas(description, &.{ "garage", "gate" })) return .{ .act = .{ .kind = .cover, .allow = &.{.close}, .guarded = true } };
            return .{ .act = .{ .kind = .cover, .allow = if (has(names.items, "position")) &.{ .open, .close, .stop, .position } else &.{ .open, .close, .stop } } };
        }
        if (eq(u8, ty, "lock")) return .{ .act = .{ .kind = .lock, .allow = &.{.lock}, .guarded = true } };
    }
    for (safety_classes) |x| if (has(names.items, x)) return .{ .left = .safety };
    for ([_][]const u8{ "occupancy", "presence", "contact", "water_leak", "temperature", "humidity", "illuminance", "pressure", "vibration" }) |x| if (has(names.items, x)) return .{ .act = .{ .kind = .sensor } };
    return .{ .left = .unknown };
}

/// The home file and the summary.
fn render(a: Allocator, r: *const Read) !Found {
    var o: std.ArrayList(u8) = .empty;
    if (r.hub == .homeassistant) {
        try o.print(a, "; Written by homemcp discover from Home Assistant at {s}.\n", .{r.where});
    } else try o.print(a, "; Written by homemcp discover from Zigbee2MQTT's device list (broker {s}).\n", .{r.where});
    try o.appendSlice(a,
        \\; Read it through, then: homemcp check FILE
        \\;
        \\; Lights, plugs, switches, heating, fans, blinds, scenes and speakers may
        \\; act when asked, within [limits]. Locks, alarms, garage doors, valves and
        \\; scenes that set them answer only to home_guarded, which is asked about
        \\; every time, and only the safe way: lock, close, arm. Sensors are only
        \\; seen. A plug may power a heater or a kettle: for those, make it allow = off.
        \\
    );
    if (r.hub == .zigbee2mqtt) try o.appendSlice(a, "; Zigbee2MQTT has no rooms: add room = lines.\n");
    if (r.no_areas) try o.appendSlice(a, "; Home Assistant didn't share its areas with this token: no rooms.\n");
    try o.print(a, "\n[home]\nname = {s}\n", .{r.home_name});
    if (r.hub == .homeassistant) {
        try o.print(a, "hub = homeassistant\nurl = {s}\n", .{r.where});
    } else try o.print(a, "hub = zigbee2mqtt\nmqtt = {s}\nbase = {s}\n", .{ r.where, r.base });
    try o.appendSlice(a, "\n[limits]\ntemperature = 16 24\nbrightness = 1 100\nposition = 0 100\ncolor_temp = 2200 6500\nvolume = 0 60\nspeed = 1 100\n");
    // devices, room by room
    var rooms: std.ArrayList([]const u8) = .empty;
    var roomless = false;
    for (r.items) |it| {
        if (it.verdict != .act) continue;
        if (it.room.len == 0) {
            roomless = true;
        } else if (!has(rooms.items, it.room)) try rooms.append(a, it.room);
    }
    for (rooms.items) |room| {
        try o.print(a, "\n; {s}\n", .{room});
        for (r.items) |it| if (it.verdict == .act and std.mem.eql(u8, it.room, room)) try writeDevice(a, &o, it);
    }
    if (roomless) {
        if (rooms.items.len > 0) try o.appendSlice(a, "\n; No room\n");
        for (r.items) |it| if (it.verdict == .act and it.room.len == 0) try writeDevice(a, &o, it);
    }
    var people: usize = 0;
    for (r.items) |it| if (it.verdict == .person) {
        if (people == 0) try o.appendSlice(a, "\n[people]                       ; who is home\n");
        try o.print(a, "{s} = {s}\n", .{ it.name, it.id });
        people += 1;
    };
    // what is left out, and why
    var any_left = false;
    for (std.enums.values(Reason)) |why| {
        var first = true;
        for (r.items) |it| if (it.verdict == .left and it.verdict.left == why) {
            if (!any_left) try o.appendSlice(a, "\n; Left out, and why:\n");
            any_left = true;
            if (first) try o.print(a, "; {s}\n", .{why.header()});
            first = false;
            if (r.hub == .homeassistant) try o.print(a, ";   {s} ({s})\n", .{ it.id, it.label }) else try o.print(a, ";   {s}\n", .{it.label});
        };
    }
    // the summary
    var sm: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (r.items) |it| if (it.verdict == .act) {
        n += 1;
    };
    try sm.print(a, "Found {d} device{s}", .{ n, if (n == 1) "" else "s" });
    if (rooms.items.len > 0) try sm.print(a, " in {d} room{s}", .{ rooms.items.len, if (rooms.items.len == 1) "" else "s" });
    if (people > 0) try sm.print(a, ", and {d} {s}", .{ people, if (people == 1) "person" else "people" });
    try sm.appendSlice(a, ".\n");
    try listLine(a, &sm, r.items, "May act when asked: ", .acts);
    try listLine(a, &sm, r.items, "Guarded, asked every time: ", .guarded);
    try listLine(a, &sm, r.items, "Only seen: ", .seen);
    try listLine(a, &sm, r.items, "Left out: ", .left);
    if (r.hub == .zigbee2mqtt) try sm.appendSlice(a, "Zigbee2MQTT has no rooms: add room = lines.\n");
    if (r.no_areas) try sm.appendSlice(a, "Home Assistant didn't share its areas with this token: no rooms.\n");
    try sm.appendSlice(a, "A plug may power a heater or a kettle: for those, make it allow = off. Then: homemcp check FILE\n");
    return .{ .text = o.items, .summary = sm.items };
}

const Group = enum { acts, guarded, seen, left };

fn listLine(a: Allocator, o: *std.ArrayList(u8), items: []const Item, label: []const u8, g: Group) !void {
    var n: usize = 0;
    for (items) |it| {
        const in = switch (g) {
            .acts => it.verdict == .act and !it.verdict.act.guarded and it.verdict.act.allow.len > 0,
            .guarded => it.verdict == .act and it.verdict.act.guarded,
            .seen => it.verdict == .act and !it.verdict.act.guarded and it.verdict.act.allow.len == 0,
            .left => it.verdict == .left,
        };
        if (!in) continue;
        n += 1;
        if (n > 8) continue;
        try o.appendSlice(a, if (n == 1) label else ", ");
        try o.appendSlice(a, it.label);
        switch (g) {
            .guarded => {
                try o.appendSlice(a, " (");
                for (it.verdict.act.allow, 0..) |x, j| try o.print(a, "{s}{s}", .{ if (j > 0) ", " else "", @tagName(x) });
                if (it.verdict.act.allow.len == 0) try o.appendSlice(a, "nothing yet");
                try o.appendSlice(a, ")");
            },
            .left => try o.print(a, " ({s})", .{it.verdict.left.short()}),
            else => {},
        }
    }
    if (n > 8) try o.print(a, " and {d} more (see the file)", .{n - 8});
    if (n > 0) try o.appendSlice(a, ".\n");
}

fn writeDevice(a: Allocator, o: *std.ArrayList(u8), it: Item) !void {
    const act = it.verdict.act;
    try o.print(a, "\n[device {s}]\nid = {s}\nkind = {s}\n", .{ it.name, it.id, @tagName(act.kind) });
    if (it.room.len > 0) try o.print(a, "room = {s}\n", .{it.room});
    if (it.aliases.len > 0) {
        try o.appendSlice(a, "alias = ");
        for (it.aliases, 0..) |al, i| try o.print(a, "{s}{s}", .{ if (i > 0) ", " else "", al });
        try o.append(a, '\n');
    }
    if (act.allow.len > 0) {
        try o.appendSlice(a, "allow = ");
        for (act.allow, 0..) |x, i| try o.print(a, "{s}{s}", .{ if (i > 0) ", " else "", @tagName(x) });
        try o.append(a, '\n');
    }
    // locks, alarms and valves are guarded anyway; others are said
    if (act.guarded and !act.kind.alwaysGuarded()) try o.appendSlice(a, "guarded = yes\n");
    if (act.modes.len > 0) {
        try o.appendSlice(a, "modes = ");
        for (act.modes, 0..) |m, i| try o.print(a, "{s}{s}", .{ if (i > 0) ", " else "", m });
        try o.append(a, '\n');
    }
    if (act.note.len > 0) try o.print(a, "note = {s}\n", .{act.note});
}

/// A name as the file wants it: lowercase ASCII letters, digits and _,
/// accented letters as their plain ones; "" when that leaves too little.
pub fn slug(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return "").iterator();
    var gap = false;
    var letters: usize = 0;
    while (it.nextCodepoint()) |cp| {
        const plain: []const u8 = if (cp < 0x80) blk: {
            const ch: u8 = @intCast(cp);
            break :blk if (std.ascii.isAlphanumeric(ch)) &.{std.ascii.toLower(ch)} else "";
        } else latin(cp);
        if (plain.len == 0) {
            gap = true;
            continue;
        }
        if (gap and o.items.len > 0) try o.append(a, '_');
        gap = false;
        try o.appendSlice(a, plain);
        letters += plain.len;
    }
    if (letters < 2) return "";
    return o.items;
}

/// A letter with an accent as its plain one ("" for others).
fn latin(cp: u21) []const u8 {
    return switch (cp) {
        0xE0...0xE5, 0xC0...0xC5, 0x100...0x105 => "a",
        0xE6, 0xC6 => "ae",
        0xE7, 0xC7, 0x106...0x10D => "c",
        0x10E...0x111 => "d",
        0xE8...0xEB, 0xC8...0xCB, 0x112...0x11B => "e",
        0xEC...0xEF, 0xCC...0xCF => "i",
        0x139...0x142 => "l",
        0xF1, 0xD1, 0x143...0x148 => "n",
        0xF2...0xF6, 0xF8, 0xD2...0xD6, 0xD8, 0x14C...0x151 => "o",
        0x152, 0x153 => "oe",
        0x154...0x159 => "r",
        0x15A...0x161 => "s",
        0xDF => "ss",
        0x162...0x165 => "t",
        0xF9...0xFC, 0xD9...0xDC, 0x168...0x171 => "u",
        0xFD, 0xFF, 0xDD => "y",
        0x179...0x17E => "z",
        else => "",
    };
}

/// Text from a hub as an INI value or comment: one line, no comment
/// marks, at most 80 bytes.
pub fn iniValue(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var space = true;
    for (s) |ch| {
        const c = if (ch < 0x20 or ch == 0x7f or ch == ';' or ch == '#' or ch == ',') ' ' else ch;
        if (c == ' ') {
            if (space) continue;
            space = true;
        } else space = false;
        try o.append(a, c);
    }
    var out = std.mem.trimEnd(u8, o.items, " ");
    if (out.len > 80) {
        var cut: usize = 80;
        while (cut > 0 and out[cut] & 0xC0 == 0x80) cut -= 1;
        out = std.mem.trimEnd(u8, out[0..cut], " ");
    }
    return out;
}

/// Zigbee2MQTT through the broker at `host`:`port`: its device list.
pub fn fromBroker(a: Allocator, io: Io, host: []const u8, port: u16, base: []const u8, user: ?[]const u8, pass: ?[]const u8) !Found {
    const c = try a.create(mqtt.Client);
    var rnd: [4]u8 = undefined;
    io.randomSecure(&rnd) catch {};
    const id = try std.fmt.allocPrint(a, "homemcp-discover-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    try c.connect(a, io, host, port, id, user, pass, 30);
    defer c.close();
    const topic = try std.fmt.allocPrint(a, "{s}/bridge/devices", .{base});
    try c.subscribe(topic);
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 250) {
        const m = (try c.next(250)) orelse continue;
        if (!std.mem.eql(u8, m.topic, topic)) continue;
        const v = jv.parse(a, try a.dupe(u8, m.payload)) orelse return error.NotADeviceList;
        c.bye();
        return fromZigbee2mqtt(a, try std.fmt.allocPrint(a, "{s}:{d}", .{ host, port }), base, v);
    }
    c.bye();
    return error.NoDeviceList;
}

const t = std.testing;

fn deviceIn(c: *const config.Config, id: []const u8) ?*const config.Device {
    for (c.devices) |*d| if (std.mem.eql(u8, d.id, id)) return d;
    return null;
}

fn allows(d: *const config.Device, want: []const model.Action) bool {
    if (d.allow.len != want.len) return false;
    for (want) |w| if (!d.allows(w)) return false;
    return true;
}

test "discover_writes_safe_defaults" {
    const sim = try @import("sim.zig").HaSim.start(std.heap.page_allocator, t.io, 0, "sim-token");
    defer sim.stop();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{sim.port});
    const found = try fromHomeAssistant(a, t.io, url, "sim-token");
    var d: config.Diag = .{};
    const c = config.parse(a, found.text, &d) catch |e| {
        std.debug.print("line {d}: {s}\n{s}\n", .{ d.line, d.what, found.text });
        return e;
    };
    try t.expectEqual(.homeassistant, c.hub);
    try t.expectEqualStrings(url, c.url);
    try t.expectEqualStrings("The flat (made up by homemcp-sim)", c.name);
    // lights, plugs, heating, fans, speakers may act; rooms and names from Home Assistant
    const light = deviceIn(&c, "light.living_room").?;
    try t.expectEqualStrings("living_room_light", light.name);
    try t.expectEqualStrings("Living room", light.room);
    try t.expect(!light.guarded and allows(light, &.{ .on, .off, .brightness }));
    try t.expectEqual(0, c.device("the big light").?);
    const lamp = deviceIn(&c, "light.bedroom_lamp").?;
    try t.expect(allows(lamp, &.{ .on, .off, .brightness, .color, .color_temp }));
    try t.expect(allows(deviceIn(&c, "switch.kettle").?, &.{ .on, .off }));
    try t.expectEqual(.plug, deviceIn(&c, "switch.kettle").?.kind);
    const th = deviceIn(&c, "climate.hall").?;
    try t.expect(allows(th, &.{ .temperature, .mode }));
    try t.expectEqual(3, th.modes.len);
    try t.expect(allows(deviceIn(&c, "fan.ceiling_fan").?, &.{ .on, .off, .speed }));
    try t.expect(allows(deviceIn(&c, "media_player.kitchen_speaker").?, &.{ .play, .pause, .volume }));
    // locks, garage doors and valves: guarded, and only the safe way
    const lock = deviceIn(&c, "lock.front_door").?;
    try t.expect(lock.guarded and allows(lock, &.{.lock}));
    const garage = deviceIn(&c, "cover.garage_door").?;
    try t.expect(garage.guarded and allows(garage, &.{.close}));
    const valve = deviceIn(&c, "valve.water_main").?;
    try t.expect(valve.guarded and allows(valve, &.{.close}));
    // a scene that locks the front door is guarded; one that doesn't isn't
    try t.expect(deviceIn(&c, "scene.leaving").?.guarded);
    try t.expect(!deviceIn(&c, "scene.evening").?.guarded);
    // sensors are only seen
    try t.expectEqual(0, deviceIn(&c, "binary_sensor.back_door").?.allow.len);
    try t.expectEqual(0, deviceIn(&c, "sensor.living_room_temperature").?.allow.len);
    try t.expectEqual(0, deviceIn(&c, "binary_sensor.sink_leak").?.allow.len);
    // never offered: cameras, smoke alarms; nor a device's settings, nor what homemcp doesn't know
    for ([_][]const u8{ "camera.front_door", "binary_sensor.kitchen_smoke", "switch.kettle_child_lock", "sun.sun" }) |id|
        try t.expect(deviceIn(&c, id) == null);
    // ... each named in a comment that says why
    try t.expect(std.mem.indexOf(u8, found.text, "; cameras: never offered") != null);
    try t.expect(std.mem.indexOf(u8, found.text, ";   camera.front_door (Front door camera)") != null);
    try t.expect(std.mem.indexOf(u8, found.text, ";   binary_sensor.kitchen_smoke (Kitchen smoke alarm)") != null);
    try t.expect(std.mem.indexOf(u8, found.text, ";   switch.kettle_child_lock (Kettle child lock)") != null);
    try t.expect(std.mem.indexOf(u8, found.text, ";   sun.sun (Sun)") != null);
    // people
    try t.expectEqual(2, c.people.len);
    try t.expectEqualStrings("person.anna", c.people[0].id);
    // a summary in plain words
    try t.expect(std.mem.startsWith(u8, found.summary, "Found 15 devices in 5 rooms, and 2 people.\n"));
    try t.expect(std.mem.indexOf(u8, found.summary, "Left out: Front door camera (a camera), Kitchen smoke alarm (a smoke or CO alarm)") != null);
}

test "names say what a device's kind doesn't: valves and garage doors on a plain switch" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valve = classifyHa(a, "switch.tap", "Garden water valve", "", null);
    try t.expect(valve == .act and valve.act.guarded and valve.act.allow.len == 1 and valve.act.allow[0] == .off);
    const opener = classifyHa(a, "switch.opener", "Garage door opener", "", null);
    try t.expect(opener == .act and opener.act.guarded and opener.act.allow.len == 0);
    const gate = classifyHa(a, "cover.drive", "Drive", "gate", null);
    try t.expect(gate == .act and gate.act.guarded and gate.act.allow[0] == .close);
    const blind = classifyHa(a, "cover.blind", "Blind", "blind", null);
    try t.expect(blind == .act and !blind.act.guarded and blind.act.allow.len >= 3);
    try t.expectEqual(Reason.safety, classifyHa(a, "sensor.co", "Hall CO", "carbon_monoxide", null).left);
    try t.expectEqual(Reason.safety, classifyHa(a, "binary_sensor.gas", "Gas", "gas", null).left);
    try t.expectEqual(Reason.unknown, classifyHa(a, "automation.morning", "Morning", "", null).left);
    try t.expectEqual(Reason.unknown, classifyHa(a, "sensor.status", "Washer status", "", null).left);
    // names as files want them: ASCII, letters, digits and _
    try t.expectEqualStrings("kuche_licht", try slug(a, "Küche Licht"));
    try t.expectEqualStrings("swiatlo_w_salonie", try slug(a, "Światło w salonie"));
    try t.expectEqualStrings("hall_light_2", try slug(a, "  Hall light (2) "));
    // a friendly name can't carry lines into the file
    try t.expectEqualStrings("Lamp allow = unlock", iniValue(a, "Lamp\nallow = unlock") catch unreachable);
    try t.expectEqualStrings("Lamp desk", iniValue(a, "Lamp ; desk") catch unreachable);
}

test "Zigbee2MQTT's device list, with the same defaults" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sim = @import("sim.zig");
    var home: sim.Home = .{ .io = t.io };
    const list = try sim.bridgeDevices(a, &home);
    const found = try fromZigbee2mqtt(a, "127.0.0.1:1883", "zigbee2mqtt", jv.parse(a, list).?);
    var d: config.Diag = .{};
    const c = config.parse(a, found.text, &d) catch |e| {
        std.debug.print("line {d}: {s}\n{s}\n", .{ d.line, d.what, found.text });
        return e;
    };
    try t.expectEqual(.zigbee2mqtt, c.hub);
    try t.expect(allows(deviceIn(&c, "Living room light").?, &.{ .on, .off, .brightness }));
    try t.expect(allows(deviceIn(&c, "Bedroom lamp").?, &.{ .on, .off, .brightness, .color, .color_temp }));
    try t.expectEqual(.plug, deviceIn(&c, "Kettle plug").?.kind);
    try t.expect(allows(deviceIn(&c, "Ceiling fan").?, &.{ .on, .off, .speed }));
    const th = deviceIn(&c, "Hall thermostat").?;
    try t.expect(allows(th, &.{ .temperature, .mode }) and th.modes.len == 3);
    try t.expect(deviceIn(&c, "Front door").?.guarded and allows(deviceIn(&c, "Front door").?, &.{.lock}));
    // Zigbee2MQTT has no device classes: the names say garage door and valve
    try t.expect(deviceIn(&c, "Garage door").?.guarded and allows(deviceIn(&c, "Garage door").?, &.{.close}));
    const valve = deviceIn(&c, "Water main").?;
    try t.expect(valve.kind == .valve and valve.guarded and allows(valve, &.{.close}));
    try t.expectEqual(0, deviceIn(&c, "Back door").?.allow.len);
    try t.expect(deviceIn(&c, "Kitchen smoke alarm") == null);
    try t.expect(deviceIn(&c, "Coordinator") == null);
    try t.expect(std.mem.indexOf(u8, found.text, ";   Kitchen smoke alarm") != null);
    try t.expect(std.mem.indexOf(u8, found.text, "; not supported by Zigbee2MQTT\n;   0x00124b0000000099\n") != null);
    try t.expect(std.mem.indexOf(u8, found.summary, "Zigbee2MQTT has no rooms") != null);
}
