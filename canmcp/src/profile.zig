//! A profile: which buses to read, with which DBC files, and the named
//! readings an agent sees. An INI file:
//!
//!   [car]
//!   name = Tesla Model 3 (party bus)
//!   silent_seconds = 5          ; a bus quiet this long counts as asleep
//!
//!   [bus party]
//!   interface = vcan0           ; the SocketCAN interface
//!   log = can0                  ; its name in candump logs (default: interface)
//!   dbc = /opt/cansim/dbc/tesla_model3_party.dbc   ; relative: to this file
//!   fd = off                    ; on: CAN FD frames too
//!
//!   [reading speed]
//!   signal = party DI_speed.DI_vehicleSpeed
//!   unit = km/h                 ; instead of the DBC's
//!   note = from the drive inverter
//!
//!   [diag]                      ; only for builds with diagnostic reads
//!   interface = vcan0
//!   pad = aa                    ; pad requests to 8 bytes with this byte
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dbc = @import("dbc.zig");
const ini = @import("ini.zig");

pub const Bus = struct {
    name: []const u8,
    interface: []const u8,
    log: []const u8,
    dbc_path: []const u8,
    fd: bool,
    db: *const dbc.Db,
};

pub const Reading = struct {
    name: []const u8,
    bus: usize,
    msg: *const dbc.Message,
    sig: *const dbc.Signal,
    unit: []const u8,
    note: []const u8,
};

pub const Profile = struct {
    name: []const u8 = "a car",
    silent_ms: u32 = 5000,
    buses: []Bus,
    readings: []Reading,
    diag_interface: []const u8 = "",
    diag_pad: ?u8 = null,

    pub fn reading(p: *const Profile, name: []const u8) ?usize {
        for (p.readings, 0..) |r, i| if (std.ascii.eqlIgnoreCase(r.name, name)) return i;
        return null;
    }
};

/// What is wrong with the profile, for the person who wrote it.
pub const Diag = struct {
    line: usize = 0,
    what: []const u8 = "",
};

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Profile {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| {
        diag.* = .{ .what = try std.fmt.allocPrint(a, "can't read {s}: {s}", .{ path, @errorName(e) }) };
        return error.BadProfile;
    };
    return fromText(a, io, text, std.fs.path.dirname(path) orelse ".", diag);
}

const PendingBus = struct { name: []const u8, interface: []const u8 = "", log: []const u8 = "", dbc: []const u8 = "", fd: bool = false, line: usize };
const PendingReading = struct { name: []const u8, signal: []const u8 = "", unit: ?[]const u8 = null, note: []const u8 = "", line: usize };

pub fn fromText(a: Allocator, io: Io, text: []const u8, base_dir: []const u8, diag: *Diag) !Profile {
    var bad: usize = 0;
    const entries = ini.parse(a, text, &bad) catch {
        diag.* = .{ .line = bad, .what = "not a key = value line or [section]" };
        return error.BadProfile;
    };
    var p: Profile = .{ .buses = &.{}, .readings = &.{} };
    var buses: std.ArrayList(PendingBus) = .empty;
    var readings: std.ArrayList(PendingReading) = .empty;
    for (entries) |e| {
        const k = e.key;
        if (std.mem.eql(u8, e.section, "car")) {
            if (eql(k, "name")) {
                p.name = e.value;
            } else if (eql(k, "silent_seconds")) {
                const s = std.fmt.parseFloat(f64, e.value) catch return fail(diag, e.line, "silent_seconds: not a number");
                if (s < 0.1 or s > 3600) return fail(diag, e.line, "silent_seconds: 0.1 to 3600");
                p.silent_ms = @intFromFloat(s * 1000);
            } else return unknown(a, diag, e);
        } else if (std.mem.eql(u8, e.section, "bus")) {
            if (e.name.len == 0) return fail(diag, e.line, "[bus] needs a name: [bus party]");
            const b = try pendingFor(PendingBus, a, &buses, e);
            if (eql(k, "interface")) {
                b.interface = e.value;
            } else if (eql(k, "log")) {
                b.log = e.value;
            } else if (eql(k, "dbc")) {
                b.dbc = e.value;
            } else if (eql(k, "fd")) {
                b.fd = onOff(e.value) orelse return fail(diag, e.line, "fd: on or off");
            } else return unknown(a, diag, e);
        } else if (std.mem.eql(u8, e.section, "reading")) {
            if (e.name.len == 0) return fail(diag, e.line, "[reading] needs a name: [reading speed]");
            const r = try pendingFor(PendingReading, a, &readings, e);
            if (eql(k, "signal")) {
                r.signal = e.value;
            } else if (eql(k, "unit")) {
                r.unit = e.value;
            } else if (eql(k, "note")) {
                r.note = e.value;
            } else return unknown(a, diag, e);
        } else if (std.mem.eql(u8, e.section, "diag")) {
            if (eql(k, "interface")) {
                p.diag_interface = e.value;
            } else if (eql(k, "pad")) {
                p.diag_pad = std.fmt.parseInt(u8, e.value, 16) catch return fail(diag, e.line, "pad: a byte in hex, such as aa");
            } else return unknown(a, diag, e);
        } else {
            return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown section [{s}]", .{e.section}));
        }
    }
    if (buses.items.len == 0) return fail(diag, 0, "no [bus NAME] section");

    // DBC files, each read once even when buses share one
    var loaded: std.StringHashMapUnmanaged(*const dbc.Db) = .empty;
    var out_buses: std.ArrayList(Bus) = .empty;
    for (buses.items) |b| {
        if (b.interface.len == 0) return fail(diag, b.line, try std.fmt.allocPrint(a, "[bus {s}] has no interface", .{b.name}));
        if (b.dbc.len == 0) return fail(diag, b.line, try std.fmt.allocPrint(a, "[bus {s}] has no dbc", .{b.name}));
        const path = if (std.fs.path.isAbsolute(b.dbc)) b.dbc else try std.fs.path.join(a, &.{ base_dir, b.dbc });
        const db = loaded.get(path) orelse blk: {
            var dd: dbc.Diag = .{};
            const db = try a.create(dbc.Db);
            db.* = dbc.load(a, io, path, &dd) catch {
                return fail(diag, b.line, try std.fmt.allocPrint(a, "{s}{s}{s}: {s}", .{ dd.path, if (dd.line > 0) " line " else "", if (dd.line > 0) try std.fmt.allocPrint(a, "{d}", .{dd.line}) else "", dd.what }));
            };
            try loaded.put(a, path, db);
            break :blk db;
        };
        try out_buses.append(a, .{ .name = b.name, .interface = b.interface, .log = if (b.log.len > 0) b.log else b.interface, .dbc_path = path, .fd = b.fd, .db = db });
    }
    p.buses = out_buses.items;

    var out_readings: std.ArrayList(Reading) = .empty;
    for (readings.items) |r| {
        // "BUS MESSAGE.SIGNAL"
        const spec = std.mem.trim(u8, r.signal, " \t");
        const sp = std.mem.indexOfAny(u8, spec, " \t") orelse return fail(diag, r.line, try std.fmt.allocPrint(a, "[reading {s}]: signal = BUS MESSAGE.SIGNAL", .{r.name}));
        const bus_name = spec[0..sp];
        const ms = std.mem.trim(u8, spec[sp + 1 ..], " \t");
        const dot = std.mem.indexOfScalar(u8, ms, '.') orelse return fail(diag, r.line, try std.fmt.allocPrint(a, "[reading {s}]: signal = BUS MESSAGE.SIGNAL", .{r.name}));
        const bi = for (p.buses, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, bus_name)) break i;
        } else return fail(diag, r.line, try std.fmt.allocPrint(a, "[reading {s}]: no bus called {s}", .{ r.name, bus_name }));
        const msg = p.buses[bi].db.byName(ms[0..dot]) orelse return fail(diag, r.line, try std.fmt.allocPrint(a, "[reading {s}]: {s} has no message {s}", .{ r.name, std.fs.path.basename(p.buses[bi].dbc_path), ms[0..dot] }));
        const sig = msg.signal(ms[dot + 1 ..]) orelse return fail(diag, r.line, try std.fmt.allocPrint(a, "[reading {s}]: {s} has no signal {s}", .{ r.name, ms[0..dot], ms[dot + 1 ..] }));
        try out_readings.append(a, .{ .name = r.name, .bus = bi, .msg = msg, .sig = sig, .unit = r.unit orelse sig.unit, .note = r.note });
    }
    p.readings = out_readings.items;
    return p;
}

fn pendingFor(comptime T: type, a: Allocator, list: *std.ArrayList(T), e: ini.Entry) !*T {
    for (list.items) |*x| if (std.mem.eql(u8, x.name, e.name)) return x;
    try list.append(a, .{ .name = e.name, .line = e.line });
    return &list.items[list.items.len - 1];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn onOff(v: []const u8) ?bool {
    if (eql(v, "on") or eql(v, "yes") or eql(v, "true")) return true;
    if (eql(v, "off") or eql(v, "no") or eql(v, "false")) return false;
    return null;
}

fn fail(diag: *Diag, line: usize, what: []const u8) error{BadProfile} {
    diag.* = .{ .line = line, .what = what };
    return error.BadProfile;
}

fn unknown(a: Allocator, diag: *Diag, e: ini.Entry) error{ BadProfile, OutOfMemory } {
    return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s} in [{s}{s}{s}]", .{ e.key, e.section, if (e.name.len > 0) " " else "", e.name }));
}
