//! Light colours: a few names and #rrggbb, Zigbee2MQTT's CIE xy and Home
//! Assistant's hue and saturation, and whether two colours look alike (a
//! bulb never shows exactly the colour it was sent).
const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Named = struct { name: []const u8, rgb: Rgb };

/// The names an agent may use, and the ones a colour is described by.
pub const names = [_]Named{
    .{ .name = "red", .rgb = .{ .r = 255, .g = 0, .b = 0 } },
    .{ .name = "orange", .rgb = .{ .r = 255, .g = 128, .b = 0 } },
    .{ .name = "yellow", .rgb = .{ .r = 255, .g = 255, .b = 0 } },
    .{ .name = "green", .rgb = .{ .r = 0, .g = 255, .b = 0 } },
    .{ .name = "cyan", .rgb = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "blue", .rgb = .{ .r = 0, .g = 0, .b = 255 } },
    .{ .name = "purple", .rgb = .{ .r = 128, .g = 0, .b = 255 } },
    .{ .name = "magenta", .rgb = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "pink", .rgb = .{ .r = 255, .g = 96, .b = 192 } },
    .{ .name = "white", .rgb = .{ .r = 255, .g = 255, .b = 255 } },
};

/// "red", "Orange", "#ff8800", "#f80": null when it is none of these.
pub fn parse(s_raw: []const u8) ?Rgb {
    const s = std.mem.trim(u8, s_raw, " ");
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n.name)) return n.rgb;
    if (std.ascii.eqlIgnoreCase(s, "violet")) return parse("purple");
    if (std.ascii.eqlIgnoreCase(s, "turquoise")) return parse("cyan");
    if (s.len == 7 and s[0] == '#') {
        return .{
            .r = std.fmt.parseInt(u8, s[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, s[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, s[5..7], 16) catch return null,
        };
    }
    if (s.len == 4 and s[0] == '#') {
        var out: [3]u8 = undefined;
        for (s[1..], &out) |ch, *o| {
            const v = std.fmt.charToDigit(ch, 16) catch return null;
            o.* = v * 17;
        }
        return .{ .r = out[0], .g = out[1], .b = out[2] };
    }
    return null;
}

/// "#rrggbb"
pub fn hex(buf: *[7]u8, c: Rgb) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
}

const Hsv = struct { h: f64, s: f64, v: f64 };

fn hsv(c: Rgb) Hsv {
    const r = @as(f64, @floatFromInt(c.r)) / 255.0;
    const g = @as(f64, @floatFromInt(c.g)) / 255.0;
    const b = @as(f64, @floatFromInt(c.b)) / 255.0;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const d = max - min;
    var h: f64 = 0;
    if (d > 1e-9) {
        if (max == r) {
            h = 60 * @mod((g - b) / d, 6);
        } else if (max == g) {
            h = 60 * ((b - r) / d + 2);
        } else h = 60 * ((r - g) / d + 4);
    }
    return .{ .h = h, .s = if (max > 1e-9) d / max else 0, .v = max };
}

fn hueGap(a: f64, b: f64) f64 {
    const d = @abs(a - b);
    return @min(d, 360 - d);
}

/// Whether two colours look alike: both near white, or hues within 20°
/// and saturations within a third. Brightness is the light's own setting.
pub fn close(a: Rgb, b: Rgb) bool {
    const x = hsv(a);
    const y = hsv(b);
    const white = 0.2;
    if (x.s < white or y.s < white) return x.s < white and y.s < white;
    return hueGap(x.h, y.h) <= 20 and @abs(x.s - y.s) <= 0.35;
}

/// The name of the colour `c` looks like, if any.
pub fn nameOf(c: Rgb) ?[]const u8 {
    const x = hsv(c);
    var best: ?[]const u8 = null;
    var gap: f64 = 1000;
    for (names) |n| {
        if (!close(c, n.rgb)) continue;
        const y = hsv(n.rgb);
        const g = hueGap(x.h, y.h) + 100 * @abs(x.s - y.s);
        if (g < gap) {
            gap = g;
            best = n.name;
        }
    }
    return best;
}

fn gammaOut(v: f64) f64 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) 12.92 * c else 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
}

fn gammaIn(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

/// CIE 1931 xy (as Zigbee2MQTT reports a colour) to sRGB at full brightness.
pub fn fromXy(x: f64, y: f64) Rgb {
    if (y <= 1e-6) return .{ .r = 0, .g = 0, .b = 0 };
    const X = x / y;
    const Z = (1 - x - y) / y;
    var r = 3.2406 * X - 1.5372 - 0.4986 * Z;
    var g = -0.9689 * X + 1.8758 + 0.0415 * Z;
    var b = 0.0557 * X - 0.2040 + 1.0570 * Z;
    r = @max(r, 0);
    g = @max(g, 0);
    b = @max(b, 0);
    const m = @max(r, @max(g, b));
    if (m <= 1e-9) return .{ .r = 0, .g = 0, .b = 0 };
    return .{ .r = byte(gammaOut(r / m)), .g = byte(gammaOut(g / m)), .b = byte(gammaOut(b / m)) };
}

pub const Xy = struct { x: f64, y: f64 };

/// sRGB to CIE 1931 xy (what a Zigbee bulb is sent and reports).
pub fn toXy(c: Rgb) Xy {
    const r = gammaIn(@as(f64, @floatFromInt(c.r)) / 255.0);
    const g = gammaIn(@as(f64, @floatFromInt(c.g)) / 255.0);
    const b = gammaIn(@as(f64, @floatFromInt(c.b)) / 255.0);
    const X = 0.4124 * r + 0.3576 * g + 0.1805 * b;
    const Y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const Z = 0.0193 * r + 0.1192 * g + 0.9505 * b;
    const sum = X + Y + Z;
    if (sum <= 1e-9) return .{ .x = 0.3127, .y = 0.3290 };
    return .{ .x = X / sum, .y = Y / sum };
}

/// Hue (degrees) and saturation (%), as Home Assistant's hs_color, at full
/// brightness.
pub fn fromHs(h: f64, s_pct: f64) Rgb {
    const s = std.math.clamp(s_pct / 100, 0, 1);
    const hh = @mod(h, 360) / 60;
    const i: u32 = @intFromFloat(@floor(hh));
    const f = hh - @floor(hh);
    const p = 1 - s;
    const q = 1 - s * f;
    const u = 1 - s * (1 - f);
    const rgb: [3]f64 = switch (i) {
        0 => .{ 1, u, p },
        1 => .{ q, 1, p },
        2 => .{ p, 1, u },
        3 => .{ p, q, 1 },
        4 => .{ u, p, 1 },
        else => .{ 1, p, q },
    };
    return .{ .r = byte(rgb[0]), .g = byte(rgb[1]), .b = byte(rgb[2]) };
}

/// Hue (degrees) and saturation (%) of `c`.
pub fn toHs(c: Rgb) [2]f64 {
    const x = hsv(c);
    return .{ @round(x.h * 10) / 10, @round(x.s * 1000) / 10 };
}

fn byte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

const t = std.testing;

test "colour names, hex, and what looks alike" {
    try t.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, parse("Orange").?);
    try t.expectEqual(Rgb{ .r = 255, .g = 136, .b = 0 }, parse("#ff8800").?);
    try t.expectEqual(Rgb{ .r = 255, .g = 136, .b = 0 }, parse("#f80").?);
    try t.expect(parse("warm white") == null);
    try t.expect(parse("#ff88zz") == null);
    var b: [7]u8 = undefined;
    try t.expectEqualStrings("#ff8800", hex(&b, parse("#FF8800").?));
    try t.expect(close(parse("red").?, parse("#ff1000").?));
    try t.expect(!close(parse("red").?, parse("orange").?));
    try t.expect(close(parse("white").?, .{ .r = 255, .g = 240, .b = 230 }));
    try t.expect(!close(parse("white").?, parse("pink").?));
    try t.expectEqualStrings("orange", nameOf(.{ .r = 255, .g = 119, .b = 0 }).?);
    try t.expect(nameOf(.{ .r = 255, .g = 200, .b = 150 }) == null);
}

test "xy and hue-saturation come back as the colour that was sent" {
    for (names) |n| {
        if (std.mem.eql(u8, n.name, "white")) continue;
        const xy = toXy(n.rgb);
        try t.expect(close(n.rgb, fromXy(xy.x, xy.y)));
        const hs = toHs(n.rgb);
        try t.expect(close(n.rgb, fromHs(hs[0], hs[1])));
    }
}
