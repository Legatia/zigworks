//! DBC files: messages, their signals and value tables, and turning a
//! frame's bytes into a signal's value. Enough of the format for opendbc's
//! files: BO_, SG_ (Intel and Motorola byte order, signed, simple
//! multiplexing), VAL_, and opendbc's `CM_ "IMPORT other.dbc";`. Other
//! lines (comments, attributes, nodes) are skipped.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Set in a message's key when its id is 29 bits.
pub const extended_bit: u32 = 0x8000_0000;

pub const Value = struct { raw: i64, label: []const u8 };

pub const Mux = union(enum) { plain, multiplexer, muxed: u32 };

pub const Signal = struct {
    name: []const u8,
    /// Intel: the least significant bit; Motorola: the most significant,
    /// both in DBC numbering (byte * 8 + bit, bit 0 the lowest).
    start: u16,
    len: u16,
    intel: bool,
    signed: bool,
    factor: f64,
    offset: f64,
    unit: []const u8,
    mux: Mux = .plain,
    values: []const Value = &.{},

    /// The bits as an unsigned number; null when the frame is too short.
    pub fn raw(sig: *const Signal, data: []const u8) ?u64 {
        if (sig.len == 0 or sig.len > 64) return null;
        var v: u64 = 0;
        if (sig.intel) {
            if ((@as(usize, sig.start) + sig.len - 1) / 8 >= data.len) return null;
            var i: u16 = 0;
            while (i < sig.len) : (i += 1) {
                const bit = sig.start + i;
                const b: u64 = (data[bit / 8] >> @intCast(bit % 8)) & 1;
                v |= b << @intCast(i);
            }
        } else {
            // from the most significant bit down: within a byte towards bit
            // 0, then on to bit 7 of the next byte
            var pos: usize = sig.start;
            var i: u16 = 0;
            while (i < sig.len) : (i += 1) {
                if (pos / 8 >= data.len) return null;
                const b: u64 = (data[pos / 8] >> @intCast(pos % 8)) & 1;
                v = (v << 1) | b;
                pos = if (pos % 8 == 0) pos + 15 else pos - 1;
            }
        }
        return v;
    }

    /// The raw bits as a signed number when the signal is signed.
    pub fn int(sig: *const Signal, raw_bits: u64) i64 {
        if (!sig.signed or sig.len == 64) return @bitCast(raw_bits);
        const top = @as(u64, 1) << @intCast(sig.len - 1);
        if (raw_bits & top == 0) return @intCast(raw_bits);
        return @as(i64, @intCast(raw_bits)) - (@as(i64, 1) << @intCast(sig.len));
    }

    pub fn physical(sig: *const Signal, raw_bits: u64) f64 {
        return @as(f64, @floatFromInt(sig.int(raw_bits))) * sig.factor + sig.offset;
    }

    /// The value table's name for a raw value, if it has one.
    pub fn label(sig: *const Signal, raw_bits: u64) ?[]const u8 {
        const n = sig.int(raw_bits);
        for (sig.values) |v| if (v.raw == n) return v.label;
        return null;
    }
};

pub const Message = struct {
    key: u32,
    name: []const u8,
    size: u16,
    signals: []Signal,

    pub fn signal(m: *const Message, name: []const u8) ?*const Signal {
        for (m.signals) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// Whether `sig` is in this frame: a multiplexed signal only when the
    /// multiplexer holds its number.
    pub fn present(m: *const Message, sig: *const Signal, data: []const u8) bool {
        const want = switch (sig.mux) {
            .muxed => |n| n,
            else => return true,
        };
        for (m.signals) |*s| if (s.mux == .multiplexer) {
            const r = s.raw(data) orelse return false;
            return r == want;
        };
        return false;
    }
};

pub const Db = struct {
    messages: []Message,

    pub fn byKey(db: *const Db, key: u32) ?*const Message {
        for (db.messages) |*m| if (m.key == key) return m;
        return null;
    }

    pub fn byName(db: *const Db, name: []const u8) ?*const Message {
        for (db.messages) |*m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    pub fn signalCount(db: *const Db) usize {
        var n: usize = 0;
        for (db.messages) |m| n += m.signals.len;
        return n;
    }
};

/// What went wrong, for the person who wrote the file.
pub const Diag = struct {
    path: []const u8 = "",
    line: usize = 0,
    what: []const u8 = "",
};

/// Reads a DBC file, and the files it IMPORTs (from its own directory).
pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Db {
    var p: Parser = .{ .a = a, .io = io, .diag = diag };
    try p.file(path, 0);
    return p.finish();
}

/// Parses DBC text; IMPORT lines are refused (there is no directory).
pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Db {
    var p: Parser = .{ .a = a, .io = undefined, .diag = diag };
    try p.text(text, null, 0);
    return p.finish();
}

/// IMPORT makes file() and text() call each other: their errors are spelled out.
const ParseError = error{ BadDbc, OutOfMemory };

const PendingValues = struct { key: u32, signal: []const u8, values: []const Value };

const Parser = struct {
    a: Allocator,
    io: Io,
    diag: *Diag,
    messages: std.ArrayList(Message) = .empty,
    signals: std.ArrayList(Signal) = .empty, // the current message's
    current: ?usize = null,
    vals: std.ArrayList(PendingValues) = .empty,

    fn file(p: *Parser, path: []const u8, depth: u8) ParseError!void {
        if (depth > 4) return p.fail(path, 0, "IMPORTs nested too deep");
        const data = Io.Dir.cwd().readFileAlloc(p.io, path, p.a, .unlimited) catch |e| {
            p.diag.* = .{ .path = path, .what = @errorName(e) };
            return error.BadDbc;
        };
        try p.text(data, path, depth);
    }

    fn fail(p: *Parser, path: []const u8, line: usize, what: []const u8) error{BadDbc} {
        p.diag.* = .{ .path = path, .line = line, .what = what };
        return error.BadDbc;
    }

    fn text(p: *Parser, data: []const u8, path: ?[]const u8, depth: u8) ParseError!void {
        const where = path orelse "(text)";
        var in_string = false;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw_line| {
            n += 1;
            const line = std.mem.trim(u8, raw_line, " \t\r");
            const quotes = std.mem.count(u8, line, "\"");
            if (in_string) {
                if (quotes % 2 == 1) in_string = false;
                continue;
            }
            if (std.mem.startsWith(u8, line, "CM_ \"IMPORT ")) {
                const rest = line["CM_ \"IMPORT ".len..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse return p.fail(where, n, "bad IMPORT");
                const dir = std.fs.path.dirname(path orelse return p.fail(where, n, "IMPORT without a file")) orelse ".";
                try p.endMessage();
                try p.file(try std.fs.path.join(p.a, &.{ dir, rest[0..end] }), depth + 1);
                continue;
            }
            if (std.mem.startsWith(u8, line, "BO_ ")) {
                try p.endMessage();
                p.message(line) catch return p.fail(where, n, "bad BO_ line");
            } else if (std.mem.startsWith(u8, line, "SG_ ")) {
                if (p.current == null) return p.fail(where, n, "SG_ outside a message");
                p.signal(line) catch return p.fail(where, n, "bad SG_ line");
            } else if (std.mem.startsWith(u8, line, "VAL_ ")) {
                try p.endMessage();
                p.valueTable(line) catch return p.fail(where, n, "bad VAL_ line");
            } else {
                if (line.len > 0 and !std.mem.startsWith(u8, line, "SG_")) try p.endMessage();
                // a comment or attribute string can run over several lines
                if (quotes % 2 == 1) in_string = true;
            }
        }
        try p.endMessage();
    }

    fn endMessage(p: *Parser) !void {
        const i = p.current orelse return;
        p.messages.items[i].signals = try p.signals.toOwnedSlice(p.a);
        p.current = null;
    }

    fn message(p: *Parser, line: []const u8) !void {
        var c: Cursor = .{ .s = line };
        _ = c.word(); // BO_
        const id = try std.fmt.parseInt(u64, c.word() orelse return error.Bad, 10);
        const name = c.word() orelse return error.Bad;
        if (!c.expect(':')) return error.Bad;
        const size = try std.fmt.parseInt(u16, c.word() orelse return error.Bad, 10);
        // opendbc's and Vector's placeholder for signals without a message
        if (id == 0xC000_0000) return;
        const key: u32 = if (id & 0x8000_0000 != 0) @as(u32, @intCast(id & 0x1fff_ffff)) | extended_bit else @intCast(id & 0x1fff_ffff);
        try p.messages.append(p.a, .{ .key = key, .name = try p.a.dupe(u8, name), .size = size, .signals = &.{} });
        p.current = p.messages.items.len - 1;
    }

    fn signal(p: *Parser, line: []const u8) !void {
        var c: Cursor = .{ .s = line };
        _ = c.word(); // SG_
        const name = c.word() orelse return error.Bad;
        var mux: Mux = .plain;
        c.ws();
        if (c.peek() != ':') {
            const m = c.word() orelse return error.Bad;
            if (std.mem.eql(u8, m, "M")) {
                mux = .multiplexer;
            } else if (m.len >= 2 and m[0] == 'm') {
                const digits = std.mem.trimEnd(u8, m[1..], "M");
                mux = .{ .muxed = try std.fmt.parseInt(u32, digits, 10) };
            } else return error.Bad;
        }
        if (!c.expect(':')) return error.Bad;
        const start = try std.fmt.parseInt(u16, c.word() orelse return error.Bad, 10);
        if (!c.expect('|')) return error.Bad;
        const len = try std.fmt.parseInt(u16, c.word() orelse return error.Bad, 10);
        if (!c.expect('@')) return error.Bad;
        const order = c.word() orelse return error.Bad;
        if (order.len != 2 or (order[0] != '0' and order[0] != '1') or (order[1] != '+' and order[1] != '-')) return error.Bad;
        if (!c.expect('(')) return error.Bad;
        const factor = try std.fmt.parseFloat(f64, c.word() orelse return error.Bad);
        if (!c.expect(',')) return error.Bad;
        const offset = try std.fmt.parseFloat(f64, c.word() orelse return error.Bad);
        if (!c.expect(')')) return error.Bad;
        if (!c.expect('[')) return error.Bad;
        _ = c.until(']') orelse return error.Bad;
        const unit = c.quoted() orelse "";
        if (len == 0 or len > 64) return error.Bad;
        try p.signals.append(p.a, .{
            .name = try p.a.dupe(u8, name),
            .start = start,
            .len = len,
            .intel = order[0] == '1',
            .signed = order[1] == '-',
            .factor = factor,
            .offset = offset,
            .unit = try p.a.dupe(u8, unit),
            .mux = mux,
        });
    }

    fn valueTable(p: *Parser, line: []const u8) !void {
        var c: Cursor = .{ .s = line };
        _ = c.word(); // VAL_
        const id = try std.fmt.parseInt(u64, c.word() orelse return error.Bad, 10);
        const sig = c.word() orelse return error.Bad;
        var values: std.ArrayList(Value) = .empty;
        while (true) {
            c.ws();
            if (c.peek() == ';' or c.peek() == 0) break;
            const n = try std.fmt.parseInt(i64, c.word() orelse return error.Bad, 10);
            const lab = c.quoted() orelse return error.Bad;
            try values.append(p.a, .{ .raw = n, .label = try p.a.dupe(u8, lab) });
        }
        const key: u32 = if (id & 0x8000_0000 != 0) @as(u32, @intCast(id & 0x1fff_ffff)) | extended_bit else @intCast(id & 0x1fff_ffff);
        try p.vals.append(p.a, .{ .key = key, .signal = try p.a.dupe(u8, sig), .values = values.items });
    }

    fn finish(p: *Parser) !Db {
        const db: Db = .{ .messages = p.messages.items };
        for (p.vals.items) |v| {
            const m = db.byKey(v.key) orelse continue;
            for (m.signals) |*s| if (std.mem.eql(u8, s.name, v.signal)) {
                s.values = v.values;
            };
        }
        return db;
    }
};

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(c: *Cursor) void {
        while (c.i < c.s.len and (c.s[c.i] == ' ' or c.s[c.i] == '\t')) c.i += 1;
    }

    fn peek(c: *Cursor) u8 {
        return if (c.i < c.s.len) c.s[c.i] else 0;
    }

    fn word(c: *Cursor) ?[]const u8 {
        c.ws();
        const b = c.i;
        while (c.i < c.s.len and !delim(c.s[c.i])) c.i += 1;
        return if (c.i > b) c.s[b..c.i] else null;
    }

    fn expect(c: *Cursor, ch: u8) bool {
        c.ws();
        if (c.peek() != ch) return false;
        c.i += 1;
        return true;
    }

    fn until(c: *Cursor, ch: u8) ?[]const u8 {
        const b = c.i;
        while (c.i < c.s.len and c.s[c.i] != ch) c.i += 1;
        if (c.i >= c.s.len) return null;
        defer c.i += 1;
        return c.s[b..c.i];
    }

    fn quoted(c: *Cursor) ?[]const u8 {
        if (!c.expect('"')) return null;
        return c.until('"');
    }

    fn delim(ch: u8) bool {
        return switch (ch) {
            ' ', '\t', ':', '|', '@', '(', ')', ',', '[', ']', '"', ';' => true,
            else => false,
        };
    }
};

const t = std.testing;

const sample =
    \\VERSION ""
    \\BU_: A B
    \\BO_ 599 DI_speed: 8 A
    \\ SG_ DI_vehicleSpeed : 12|12@1+ (0.08,-40) [-40|285] "kph"  B
    \\ SG_ DI_uiSpeed : 24|9@1+ (1,0) [0|510] ""  B
    \\BO_ 580 SPEED: 5 A
    \\ SG_ speed : 31|16@0+ (0.01,0) [0|655.35] "km/h" B
    \\ SG_ nibble : 3|12@0+ (1,0) [0|4095] "" B
    \\ SG_ blink : 25|2@0+ (1,0) [0|3] "" B
    \\BO_ 300 MUXED: 8 A
    \\ SG_ page M : 0|2@1+ (1,0) [0|3] "" B
    \\ SG_ temp m1 : 8|8@1- (0.5,0) [-64|63.5] "C" B
    \\ SG_ volts m2 : 8|16@1+ (0.001,0) [0|65.535] "V" B
    \\BO_ 2365583360 EXT: 8 A
    \\ SG_ x : 0|8@1+ (1,0) [0|255] "" B
    \\BO_ 160 BIG: 32 A
    \\ SG_ far : 200|12@1+ (1,0) [0|4095] "" B
    \\CM_ SG_ 599 DI_vehicleSpeed "a comment
    \\ that runs on
    \\BO_ 999 NOT_A_MESSAGE: 8 A";
    \\BA_DEF_ BO_ "GenMsgCycleTime" INT 0 65535;
    \\VAL_ 580 blink 0 "off" 1 "left" 2 "right" ;
    \\VAL_ 300 page 1 "temperature" 2 "voltage" ;
;

test "messages, signals, comments over several lines, value tables" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const db = try parse(arena.allocator(), sample, &diag);
    try t.expectEqual(5, db.messages.len);
    try t.expect(db.byName("NOT_A_MESSAGE") == null);
    const m = db.byName("DI_speed").?;
    try t.expectEqual(599, m.key);
    try t.expectEqual(2, m.signals.len);
    const s = m.signal("DI_vehicleSpeed").?;
    try t.expect(s.intel and !s.signed);
    try t.expectEqual(0.08, s.factor);
    try t.expectEqual(-40, s.offset);
    try t.expectEqualStrings("kph", s.unit);
    try t.expectEqualStrings("right", db.byName("SPEED").?.signal("blink").?.label(2).?);
    const ext = db.byName("EXT").?;
    try t.expectEqual(0x0CFFF000 | extended_bit, ext.key);
}

test "Intel: low bit first, across bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const db = try parse(arena.allocator(), sample, &diag);
    const s = db.byName("DI_speed").?.signal("DI_vehicleSpeed").?;
    // bits 12..23: low nibble of the value in byte 1's high nibble, the rest in byte 2
    const data = [_]u8{ 0x00, 0x00, 0x5A, 0, 0, 0, 0, 0 };
    try t.expectEqual(0x5A0, s.raw(&data).?);
    try t.expectApproxEqAbs(@as(f64, 75.2), s.physical(0x5A0), 1e-9);
    const far = db.byName("BIG").?.signal("far").?;
    var big: [32]u8 = @splat(0);
    big[25] = 0xCD; // bits 200..207
    big[26] = 0x0B; // bits 208..211
    try t.expectEqual(0xBCD, far.raw(&big).?);
    try t.expect(far.raw(big[0..20]) == null); // too short
}

test "Motorola: high bit first, then bit 7 of the next byte" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const db = try parse(arena.allocator(), sample, &diag);
    const m = db.byName("SPEED").?;
    // ICSim: kph * 100, big-endian in bytes 3 and 4
    const data = [_]u8{ 0xAB, 0xCD, 0, 0x13, 0x88 };
    try t.expectEqual(5000, m.signal("speed").?.raw(&data).?);
    try t.expectApproxEqAbs(@as(f64, 50), m.signal("speed").?.physical(5000), 1e-9);
    // 12 bits from byte 0 bit 3: byte 0's low nibble, then all of byte 1
    try t.expectEqual(0xBCD, m.signal("nibble").?.raw(&data).?);
    // 2 bits from byte 3 bit 1: byte 3's two low bits
    const blink = [_]u8{ 0, 0, 0, 0b10, 0 };
    try t.expectEqual(2, m.signal("blink").?.raw(&blink).?);
}

test "signed values and multiplexed signals" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const db = try parse(arena.allocator(), sample, &diag);
    const m = db.byName("MUXED").?;
    const temp = m.signal("temp").?;
    const volts = m.signal("volts").?;
    const page1 = [_]u8{ 1, 0xFC, 0, 0, 0, 0, 0, 0 };
    try t.expect(m.present(temp, &page1));
    try t.expect(!m.present(volts, &page1));
    try t.expectApproxEqAbs(@as(f64, -2), temp.physical(temp.raw(&page1).?), 1e-9);
    const page2 = [_]u8{ 2, 0x10, 0x27, 0, 0, 0, 0, 0 };
    try t.expect(m.present(volts, &page2));
    try t.expectApproxEqAbs(@as(f64, 10), volts.physical(volts.raw(&page2).?), 1e-9);
    try t.expectEqualStrings("voltage", m.signal("page").?.label(2).?);
}

test "a broken line says where" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try t.expectError(error.BadDbc, parse(arena.allocator(), "BO_ 1 A: 8 X\n SG_ s : 0|8@2+ (1,0) [0|1] \"\" X\n", &diag));
    try t.expectEqual(2, diag.line);
    try t.expectEqualStrings("bad SG_ line", diag.what);
}
