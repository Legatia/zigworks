//! Masks known secret values in a stream of bytes: the value itself and
//! the forms it most often travels in (base64 at any alignment, hex,
//! percent-encoding). A guard against accidents and echoes, not against a
//! program that sets out to disguise a value it can read.
const std = @import("std");
const Io = std.Io;

pub const Secret = struct {
    name: []const u8,
    value: []const u8,
};

const Pattern = struct {
    bytes: []const u8,
    label: []const u8,
};

/// Shorter base64 cores than this are not masked: too likely to match
/// ordinary text.
const min_core = 12;

pub const Scrubber = struct {
    arena: std.heap.ArenaAllocator,
    /// Longest first.
    patterns: []Pattern,
    pending: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    /// How many values were masked so far.
    hits: usize = 0,

    pub fn init(gpa: std.mem.Allocator, secrets: []const Secret) !Scrubber {
        var s: Scrubber = .{ .arena = .init(gpa), .patterns = &.{}, .gpa = gpa };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        var list: std.ArrayList(Pattern) = .empty;
        for (secrets) |sec| {
            if (sec.value.len == 0) continue;
            const label = try std.fmt.allocPrint(a, "[secret:{s}]", .{sec.name});
            for (try forms(a, sec.value)) |f| {
                if (f.len == 0) continue;
                var dup = false;
                for (list.items) |p| if (std.mem.eql(u8, p.bytes, f)) {
                    dup = true;
                    break;
                };
                if (!dup) try list.append(a, .{ .bytes = f, .label = label });
            }
        }
        std.mem.sort(Pattern, list.items, {}, struct {
            fn lt(_: void, x: Pattern, y: Pattern) bool {
                return x.bytes.len > y.bytes.len;
            }
        }.lt);
        s.patterns = list.items;
        return s;
    }

    pub fn deinit(s: *Scrubber) void {
        s.pending.deinit(s.gpa);
        s.arena.deinit();
    }

    /// Writes what is certainly clean of `chunk` (with what was held back
    /// before); keeps back a tail that could be the start of a value.
    pub fn feed(s: *Scrubber, chunk: []const u8, out: *Io.Writer) !void {
        try s.pending.appendSlice(s.gpa, chunk);
        const used = try s.run(s.pending.items, false, out);
        const rest = s.pending.items.len - used;
        std.mem.copyForwards(u8, s.pending.items[0..rest], s.pending.items[used..]);
        s.pending.shrinkRetainingCapacity(rest);
    }

    /// Writes the held-back tail; call at the end of the stream.
    pub fn finish(s: *Scrubber, out: *Io.Writer) !void {
        _ = try s.run(s.pending.items, true, out);
        s.pending.clearRetainingCapacity();
    }

    /// The whole of `input`, masked. Caller frees.
    pub fn scrubAlloc(s: *Scrubber, gpa: std.mem.Allocator, input: []const u8) ![]u8 {
        var w: Io.Writer.Allocating = .init(gpa);
        errdefer w.deinit();
        _ = try s.run(input, true, &w.writer);
        return w.toOwnedSlice();
    }

    /// Returns how many bytes of `buf` were dealt with.
    fn run(s: *Scrubber, buf: []const u8, last: bool, out: *Io.Writer) !usize {
        var i: usize = 0;
        var clean_from: usize = 0;
        scan: while (i < buf.len) {
            for (s.patterns) |p| {
                const n = @min(p.bytes.len, buf.len - i);
                if (!std.mem.eql(u8, buf[i..][0..n], p.bytes[0..n])) continue;
                if (n == p.bytes.len) {
                    try out.writeAll(buf[clean_from..i]);
                    try out.writeAll(p.label);
                    s.hits += 1;
                    i += n;
                    clean_from = i;
                    continue :scan;
                }
                // runs off the end: maybe a value cut in two
                if (!last) {
                    try out.writeAll(buf[clean_from..i]);
                    return i;
                }
            }
            i += 1;
        }
        try out.writeAll(buf[clean_from..]);
        return buf.len;
    }
};

/// The value and its usual encodings.
fn forms(a: std.mem.Allocator, v: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, v);
    // hex
    const hex_lower = try a.alloc(u8, v.len * 2);
    const hex_upper = try a.alloc(u8, v.len * 2);
    for (v, 0..) |c, i| {
        hex_lower[2 * i] = "0123456789abcdef"[c >> 4];
        hex_lower[2 * i + 1] = "0123456789abcdef"[c & 15];
        hex_upper[2 * i] = "0123456789ABCDEF"[c >> 4];
        hex_upper[2 * i + 1] = "0123456789ABCDEF"[c & 15];
    }
    try out.append(a, hex_lower);
    try out.append(a, hex_upper);
    // percent-encoding of everything outside the unreserved set
    var pct: std.ArrayList(u8) = .empty;
    var pct_lower: std.ArrayList(u8) = .empty;
    for (v) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try pct.append(a, c);
            try pct_lower.append(a, c);
        } else {
            try pct.print(a, "%{X:0>2}", .{c});
            try pct_lower.print(a, "%{x:0>2}", .{c});
        }
    }
    try out.append(a, pct.items);
    try out.append(a, pct_lower.items);
    // application/x-www-form-urlencoded: `*-._` stay, space is `+`
    var form: std.ArrayList(u8) = .empty;
    var form_lower: std.ArrayList(u8) = .empty;
    for (v) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '*' or c == '-' or c == '.' or c == '_') {
            try form.append(a, c);
            try form_lower.append(a, c);
        } else if (c == ' ') {
            try form.append(a, '+');
            try form_lower.append(a, '+');
        } else {
            try form.print(a, "%{X:0>2}", .{c});
            try form_lower.print(a, "%{x:0>2}", .{c});
        }
    }
    try out.append(a, form.items);
    try out.append(a, form_lower.items);
    // base64, standard and url-safe, at each of the three alignments a
    // value can have inside a longer encoded text ("user:" ++ value)
    for ([_]std.base64.Base64Encoder{ std.base64.standard_no_pad.Encoder, std.base64.url_safe_no_pad.Encoder }) |enc| {
        for (0..3) |k| {
            const raw = try a.alloc(u8, k + v.len);
            @memset(raw[0..k], 0);
            @memcpy(raw[k..], v);
            const full = try a.alloc(u8, enc.calcSize(raw.len));
            _ = enc.encode(full, raw);
            // characters made only of the value's bits
            const skip = (k * 8 + 5) / 6;
            const keep_end = ((k + v.len) * 8) / 6;
            if (keep_end > skip and keep_end - skip >= min_core) try out.append(a, full[skip..keep_end]);
        }
    }
    return out.items;
}

const t = std.testing;

fn scrubOnce(secrets: []const Secret, input: []const u8) ![]u8 {
    var s = try Scrubber.init(t.allocator, secrets);
    defer s.deinit();
    return s.scrubAlloc(t.allocator, input);
}

const key: Secret = .{ .name = "gh", .value = "ghp_Abc123DEF456ghi789+/=" };

test "masks the plain value" {
    const got = try scrubOnce(&.{key}, "token=ghp_Abc123DEF456ghi789+/= end");
    defer t.allocator.free(got);
    try t.expectEqualStrings("token=[secret:gh] end", got);
}

test "masks hex and percent-encoded forms" {
    const hex = "6768705f416263313233444546343536676869373839" ++ "2b2f3d";
    const got = try scrubOnce(&.{key}, "h=" ++ hex ++ " p=ghp_Abc123DEF456ghi789%2B%2F%3D q=ghp_Abc123DEF456ghi789%2b%2f%3d");
    defer t.allocator.free(got);
    try t.expectEqualStrings("h=[secret:gh] p=[secret:gh] q=[secret:gh]", got);
}

test "masks base64 at every alignment, as in a Basic header" {
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ "", "u:", "us:", "use:" }) |pre| {
        var raw: [64]u8 = undefined;
        const r = raw[0 .. pre.len + key.value.len];
        @memcpy(r[0..pre.len], pre);
        @memcpy(r[pre.len..], key.value);
        const enc = std.base64.standard.Encoder.encode(&buf, r);
        const got = try scrubOnce(&.{key}, enc);
        defer t.allocator.free(got);
        try t.expect(std.mem.indexOf(u8, got, "[secret:gh]") != null);
        // what is left can't give the value back
        try t.expect(got.len < enc.len);
    }
}

test "leaves other text alone" {
    const got = try scrubOnce(&.{key}, "nothing secret here, ghp_ only a prefix");
    defer t.allocator.free(got);
    try t.expectEqualStrings("nothing secret here, ghp_ only a prefix", got);
}

test "a value cut across two chunks is still masked" {
    var s = try Scrubber.init(t.allocator, &.{key});
    defer s.deinit();
    var w: Io.Writer.Allocating = .init(t.allocator);
    defer w.deinit();
    const text = "a ghp_Abc123DEF456ghi789+/= b";
    for (text) |c| try s.feed(&.{c}, &w.writer);
    try s.finish(&w.writer);
    try t.expectEqualStrings("a [secret:gh] b", w.written());
    try t.expectEqual(1, s.hits);
}

test "a held-back tail that was not a value comes out at the end" {
    var s = try Scrubber.init(t.allocator, &.{key});
    defer s.deinit();
    var w: Io.Writer.Allocating = .init(t.allocator);
    defer w.deinit();
    try s.feed("x ghp_Abc", &w.writer);
    try t.expectEqualStrings("x ", w.written());
    try s.finish(&w.writer);
    try t.expectEqualStrings("x ghp_Abc", w.written());
}

test "masks the form-urlencoded form" {
    const v: Secret = .{ .name = "pw", .value = "a b*c!d~e-Q" };
    const got = try scrubOnce(&.{v}, "user=x&pw=a+b*c%21d%7Ee-Q&n=1 lower=a+b*c%21d%7ee-Q");
    defer t.allocator.free(got);
    try t.expectEqualStrings("user=x&pw=[secret:pw]&n=1 lower=[secret:pw]", got);
}
