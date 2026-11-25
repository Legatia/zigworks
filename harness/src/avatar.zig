//! Avatar packs (`avatars/NAME/`), for the desk: `harness avatar check
//! NAME`, and the head file's layout (README: Avatar packs).
//!
//! A pack is a folder with `avatar.ini` naming its files: `still` (the
//! portrait), optional `closed` (the same portrait with the eyes closed),
//! and, once fitted, `head` (head.bin), `eyes` and `eyemask` (PNG). The
//! desk's avatar.js draws it; its fit.js writes the fitted files.
//!
//! The head file (version 1): 8 bytes of magic "\x89HEAD\r\n\x1a", a u32
//! LE format version, a u32 LE header length L (a multiple of 4), L bytes
//! of JSON (padded with spaces), then the arrays. The JSON's `arrays` maps
//! each name to [TYPE, OFFSET, COUNT]: TYPE f32, i16, u16, u32 or u8;
//! OFFSET from the arrays' start, a multiple of 4; COUNT in values.
const std = @import("std");
const Io = std.Io;

pub const usage = "usage: harness avatar check NAME";

/// The desk serves avatar files up to this size (the spec's 20 MB).
pub const max_file: u64 = 20 << 20;
pub const head_magic = "\x89HEAD\r\n\x1a";
pub const head_version: u32 = 1;

/// The 52 ARKit expression shapes, as the base head (Face Cap) names them.
pub const shape_names = [52][]const u8{ "browInnerUp", "browDown_L", "browDown_R", "browOuterUp_L", "browOuterUp_R", "eyeLookUp_L", "eyeLookUp_R", "eyeLookDown_L", "eyeLookDown_R", "eyeLookIn_L", "eyeLookIn_R", "eyeLookOut_L", "eyeLookOut_R", "eyeBlink_L", "eyeBlink_R", "eyeSquint_L", "eyeSquint_R", "eyeWide_L", "eyeWide_R", "cheekPuff", "cheekSquint_L", "cheekSquint_R", "noseSneer_L", "noseSneer_R", "jawOpen", "jawForward", "jawLeft", "jawRight", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight", "mouthRollUpper", "mouthRollLower", "mouthShrugUpper", "mouthShrugLower", "mouthClose", "mouthSmile_L", "mouthSmile_R", "mouthFrown_L", "mouthFrown_R", "mouthDimple_L", "mouthDimple_R", "mouthUpperUp_L", "mouthUpperUp_R", "mouthLowerDown_L", "mouthLowerDown_R", "mouthPress_L", "mouthPress_R", "mouthStretch_L", "mouthStretch_R", "tongueOut" };

/// avatar.ini's keys, in the order they're listed.
const keys = [_][]const u8{ "still", "closed", "head", "eyes", "eyemask" };

pub const Kind = enum {
    jpeg,
    png,
    head,
    other,

    fn label(k: Kind) []const u8 {
        return switch (k) {
            .jpeg => "JPEG",
            .png => "PNG",
            .head => "head file",
            .other => "unknown",
        };
    }
};

pub const File = struct {
    key: []const u8,
    name: []const u8,
    bytes: u64 = 0,
    kind: Kind = .other,
    width: u32 = 0,
    height: u32 = 0,
};

pub const HeadInfo = struct {
    version: u32,
    vertices: u32,
    shapes: usize,
    image: [2]u32,
    /// the SHA-256 (lowercase hex) of the still it was fitted to, when the
    /// fit knew the still's bytes
    still_sha256: ?[64]u8 = null,
};

pub const Report = struct {
    files: []const File = &.{},
    head: ?HeadInfo = null,
    problems: []const []const u8 = &.{},
    fitted: bool = false,
};

/// Lowercase letters, digits, `-` and `_`, 1 to 64, the first a letter
/// or digit.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

/// A value in avatar.ini: a file in the pack's own folder.
fn plainFile(v: []const u8) bool {
    if (v.len == 0 or v.len > 128 or v[0] == '.') return false;
    for (v) |c| if (c == '/' or c == '\\' or c == ':' or c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn sniff(bytes: []const u8) Kind {
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, head_magic)) return .head;
    return .other;
}

/// A JPEG's or PNG's width and height as shown: a JPEG's Exif orientation
/// of 5–8 (a quarter turn, as phones write) swaps them, as browsers do, so
/// they match what the desk's fit saw.
pub fn imageSize(bytes: []const u8) ?[2]u32 {
    switch (sniff(bytes)) {
        .png => {
            if (bytes.len < 24 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
            return .{ std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big) };
        },
        .jpeg => {
            var turned = false;
            var i: usize = 2;
            while (i + 4 <= bytes.len) {
                if (bytes[i] != 0xff) return null;
                const m = bytes[i + 1];
                if (m == 0xff) {
                    i += 1; // fill
                    continue;
                }
                if (m == 0xd8 or m == 0x01 or (m >= 0xd0 and m <= 0xd7)) {
                    i += 2;
                    continue;
                }
                if (m == 0xd9 or m == 0xda) return null; // no frame before the scan
                const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
                const sof = m >= 0xc0 and m <= 0xcf and m != 0xc4 and m != 0xc8 and m != 0xcc;
                if (m == 0xe1 and len >= 2 and i + 2 + @as(usize, len) <= bytes.len) {
                    if (exifOrientation(bytes[i + 4 .. i + 2 + len])) |o| turned = o >= 5 and o <= 8;
                }
                if (sof) {
                    if (i + 9 > bytes.len) return null;
                    const h = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
                    const w = std.mem.readInt(u16, bytes[i + 7 ..][0..2], .big);
                    return if (turned) .{ h, w } else .{ w, h };
                }
                i += 2 + @as(usize, len);
            }
            return null;
        },
        else => return null,
    }
}

/// The orientation tag (0x0112) of an APP1 segment's Exif block, if any.
fn exifOrientation(seg: []const u8) ?u16 {
    if (seg.len < 14 or !std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) return null;
    const tiff = seg[6..];
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II")) .little else if (std.mem.eql(u8, tiff[0..2], "MM")) .big else return null;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len or tiff.len - ifd < 2) return null;
    const n = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    var e: usize = 0;
    while (e < n) : (e += 1) {
        const at = ifd + 2 + e * 12;
        if (at + 12 > tiff.len) return null;
        if (std.mem.readInt(u16, tiff[at..][0..2], endian) == 0x0112) return std.mem.readInt(u16, tiff[at + 8 ..][0..2], endian);
    }
    return null;
}

const Ini = struct {
    files: [keys.len]?[]const u8 = @splat(null),

    fn get(ini: Ini, key: []const u8) ?[]const u8 {
        for (keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return ini.files[i];
        return null;
    }
};

fn parseIni(a: std.mem.Allocator, text_: []const u8, problems: *std.ArrayList([]const u8)) !Ini {
    var ini: Ini = .{};
    var it = std.mem.splitScalar(u8, text_, '\n');
    var no: usize = 0;
    // the desk writes an [avatar] section; lines before any section count too
    var in_avatar = true;
    while (it.next()) |raw| {
        no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const name = std.mem.trim(u8, std.mem.trimEnd(u8, line[1..], "]"), " \t");
            in_avatar = std.mem.eql(u8, name, "avatar") and line[line.len - 1] == ']';
            if (!in_avatar) try problems.append(a, try std.fmt.allocPrint(a, "avatar.ini line {d}: unknown section {s} (the section is [avatar])", .{ no, line }));
            continue;
        }
        if (!in_avatar) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try problems.append(a, try std.fmt.allocPrint(a, "avatar.ini line {d}: not KEY = FILE", .{no}));
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const slot = for (keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) break i;
        } else {
            try problems.append(a, try std.fmt.allocPrint(a, "avatar.ini line {d}: unknown key {s} (the keys are still, closed, head, eyes, eyemask)", .{ no, key }));
            continue;
        };
        if (ini.files[slot] != null) {
            try problems.append(a, try std.fmt.allocPrint(a, "avatar.ini line {d}: {s} twice", .{ no, key }));
            continue;
        }
        if (!plainFile(val)) {
            try problems.append(a, try std.fmt.allocPrint(a, "avatar.ini line {d}: {s} isn't a file name in the pack's folder", .{ no, val }));
            continue;
        }
        ini.files[slot] = val;
    }
    return ini;
}

/// Checks the pack in `dir`: avatar.ini, each file's type (by its first
/// bytes) and size, and the head's header.
pub fn check(io: Io, a: std.mem.Allocator, dir: []const u8) !Report {
    var problems: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(File) = .empty;
    const d = Io.Dir.cwd();
    const ini_text = d.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "avatar.ini" }), a, .limited(64 << 10)) catch |e| {
        const why = switch (e) {
            error.FileNotFound => "avatar.ini is missing",
            error.StreamTooLong => "avatar.ini is over 64 KB",
            else => try std.fmt.allocPrint(a, "avatar.ini can't be read: {s}", .{@errorName(e)}),
        };
        try problems.append(a, why);
        return .{ .problems = problems.items };
    };
    const ini = try parseIni(a, ini_text, &problems);
    if (ini.get("still") == null) try problems.append(a, "avatar.ini names no still");
    // the fitted files come together
    var named: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "head", "eyes", "eyemask" }) |k| if (ini.get(k) != null) try named.append(a, k);
    if (named.items.len > 0 and named.items.len < 3)
        try problems.append(a, try std.fmt.allocPrint(a, "head, eyes and eyemask go together; avatar.ini names only {s}", .{try std.mem.join(a, " and ", named.items)}));

    var still_size: ?[2]u32 = null;
    var still_sha256: ?[64]u8 = null;
    var head: ?HeadInfo = null;
    for (keys, 0..) |key, slot| {
        const name = ini.files[slot] orelse continue;
        var f: File = .{ .key = key, .name = name };
        const path = try std.fs.path.join(a, &.{ dir, name });
        const st = d.statFile(io, path, .{}) catch |e| {
            try problems.append(a, if (e == error.FileNotFound)
                try std.fmt.allocPrint(a, "{s}: {s} isn't in the pack", .{ key, name })
            else
                try std.fmt.allocPrint(a, "{s}: {s} can't be read: {s}", .{ key, name, @errorName(e) }));
            continue;
        };
        f.bytes = st.size;
        if (st.kind != .file) {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: {s} isn't a file", .{ key, name }));
            continue;
        }
        if (st.size > max_file) {
            try problems.append(a, try std.fmt.allocPrint(a, "{s} is {d:.1} MB; the desk serves files up to 20 MB", .{ name, @as(f64, @floatFromInt(st.size)) / (1 << 20) }));
            try files.append(a, f);
            continue;
        }
        const bytes = d.readFileAlloc(io, path, a, .limited(max_file + 1)) catch |e| {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: {s} can't be read: {s}", .{ key, name, @errorName(e) }));
            continue;
        };
        f.kind = sniff(bytes);
        const image_key = std.mem.eql(u8, key, "still") or std.mem.eql(u8, key, "closed");
        if (std.mem.eql(u8, key, "head")) {
            if (f.kind != .head) {
                try problems.append(a, try std.fmt.allocPrint(a, "{s} is not a head file", .{name}));
            } else {
                var why: []const u8 = "";
                if (readHeader(a, bytes, &why)) |h| {
                    head = h;
                } else |_| try problems.append(a, try renamed(a, why, name));
            }
        } else if (image_key and f.kind != .jpeg and f.kind != .png) {
            try problems.append(a, try std.fmt.allocPrint(a, "{s} is not a JPEG or PNG", .{name}));
        } else if (!image_key and f.kind != .png) {
            try problems.append(a, try std.fmt.allocPrint(a, "{s} is not a PNG", .{name}));
        } else if (imageSize(bytes)) |wh| {
            f.width = wh[0];
            f.height = wh[1];
            if (std.mem.eql(u8, key, "still")) {
                still_size = wh;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                still_sha256 = std.fmt.bytesToHex(digest, .lower);
            }
        } else try problems.append(a, try std.fmt.allocPrint(a, "{s}: the size of {s} can't be read", .{ key, name }));
        try files.append(a, f);
    }
    // the closed photo and the head go with this still
    if (still_size) |ss| {
        for (files.items) |f| if (std.mem.eql(u8, f.key, "closed") and f.width > 0 and (f.width != ss[0] or f.height != ss[1]))
            try problems.append(a, try std.fmt.allocPrint(a, "{s} is {d}x{d}; the still is {d}x{d}", .{ f.name, f.width, f.height, ss[0], ss[1] }));
        if (head) |h| if (h.image[0] != ss[0] or h.image[1] != ss[1]) {
            try problems.append(a, try std.fmt.allocPrint(a, "{s} was fitted to a {d}x{d} photo; the still is {d}x{d}", .{ ini.get("head").?, h.image[0], h.image[1], ss[0], ss[1] }));
        } else if (h.still_sha256) |want| if (still_sha256) |got| if (!std.mem.eql(u8, &want, &got))
            try problems.append(a, try std.fmt.allocPrint(a, "{s} was fitted to another photo (the still's SHA-256 isn't the one it was fitted to)", .{ini.get("head").?}));
    }
    return .{ .files = files.items, .head = head, .problems = problems.items, .fitted = named.items.len == 3 and head != null };
}

/// readHeader's lines say "head.bin"; a pack may call it otherwise.
fn renamed(a: std.mem.Allocator, why: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "head.bin")) return why;
    return std.mem.replaceOwned(u8, a, why, "head.bin", name);
}

const Ty = struct { name: []const u8, size: u32 };
const types = [_]Ty{ .{ .name = "f32", .size = 4 }, .{ .name = "i16", .size = 2 }, .{ .name = "u16", .size = 2 }, .{ .name = "u32", .size = 4 }, .{ .name = "u8", .size = 1 } };

const Arr = struct { ty: []const u8, off: usize, count: usize };

fn fail(why: *[]const u8, comptime fmt: []const u8, args: anytype, a: std.mem.Allocator) error{ BadHead, OutOfMemory } {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.BadHead;
}

fn num(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn whole(v: std.json.Value, max: f64) ?u32 {
    const x = num(v) orelse return null;
    if (x < 1 or x > max or @floor(x) != x) return null;
    return @intFromFloat(x);
}

/// A list of `n` numbers, or (with `inner`) of `n` lists of `inner` numbers.
fn points(v: ?std.json.Value, n: usize, inner: usize) bool {
    const arr = switch (v orelse return false) {
        .array => |x| x.items,
        else => return false,
    };
    if (arr.len != n) return false;
    for (arr) |e| {
        if (inner == 0) {
            if (num(e) == null) return false;
        } else if (!points(e, inner, 0)) return false;
    }
    return true;
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

/// The head file's header and arrays: everything the desk relies on before
/// it draws (README: Avatar packs). `why` says what's wrong, naming the file
/// head.bin.
pub fn readHeader(a: std.mem.Allocator, bytes: []const u8, why: *[]const u8) !HeadInfo {
    if (!std.mem.startsWith(u8, bytes, head_magic)) return fail(why, "head.bin is not a head file", .{}, a);
    if (bytes.len < 16) return fail(why, "head.bin's header runs past the end of the file", .{}, a);
    const version = std.mem.readInt(u32, bytes[8..12], .little);
    if (version > head_version) return fail(why, "head.bin is format version {d}, made by a newer harness; this one reads version {d}", .{ version, head_version }, a);
    if (version == 0) return fail(why, "head.bin's format version is 0", .{}, a);
    const hlen = std.mem.readInt(u32, bytes[12..16], .little);
    if (hlen % 4 != 0 or hlen > bytes.len - 16) return fail(why, "head.bin's header runs past the end of the file", .{}, a);
    const data = bytes[16 + hlen ..];
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes[16 .. 16 + hlen], .{}) catch
        return fail(why, "head.bin's header isn't JSON", .{}, a);
    const kind = switch (field(root, "kind") orelse .null) {
        .string => |s| s,
        else => "",
    };
    if (std.mem.eql(u8, kind, "base")) return fail(why, "head.bin is the base head, not a fitted one", .{}, a);
    if (!std.mem.eql(u8, kind, "head")) return fail(why, "head.bin's kind is \"{s}\", not \"head\"", .{kind}, a);
    const n = whole(field(root, "vertices") orelse .null, 1 << 24) orelse return fail(why, "head.bin's header has no vertex count", .{}, a);
    var image: [2]u32 = undefined;
    const img = field(root, "image") orelse .null;
    if (!points(img, 2, 0)) return fail(why, "head.bin's header has no image size", .{}, a);
    for (img.array.items, 0..) |v, i| image[i] = whole(v, 1 << 16) orelse return fail(why, "head.bin's header has no image size", .{}, a);

    // the shapes: the 52, each once
    const shapes = switch (field(root, "shapes") orelse .null) {
        .array => |x| x.items,
        else => return fail(why, "head.bin's header has no shapes", .{}, a),
    };
    var seen: [shape_names.len]bool = @splat(false);
    for (shapes) |s| {
        const sn = switch (s) {
            .string => |x| x,
            else => return fail(why, "head.bin's shapes aren't names", .{}, a),
        };
        const k = for (shape_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, sn)) break i;
        } else return fail(why, "head.bin has an unknown shape {s}", .{sn}, a);
        if (seen[k]) return fail(why, "head.bin names shape {s} twice", .{sn}, a);
        seen[k] = true;
    }
    for (seen, 0..) |ok, i| if (!ok) return fail(why, "head.bin has no shape {s}", .{shape_names[i]}, a);
    if (!points(field(root, "shapeScale"), shapes.len, 2)) return fail(why, "head.bin's header has no shapeScale of {d} pairs", .{shapes.len}, a);

    // what the desk's shaders take in fixed numbers
    const Need = struct { path: []const u8, v: ?std.json.Value, n: usize, inner: usize };
    const eyes = field(root, "eyes") orelse .null;
    const eye_list = switch (eyes) {
        .array => |x| x.items,
        else => &[_]std.json.Value{},
    };
    if (eye_list.len != 2) return fail(why, "head.bin's header has no eyes (two)", .{}, a);
    const mouth = field(root, "mouth") orelse .null;
    const face = field(root, "face") orelse .null;
    const needs = [_]Need{
        .{ .path = "eyes[0].outline", .v = field(eye_list[0], "outline"), .n = 16, .inner = 2 },
        .{ .path = "eyes[1].outline", .v = field(eye_list[1], "outline"), .n = 16, .inner = 2 },
        .{ .path = "eyes[0].center", .v = field(eye_list[0], "center"), .n = 2, .inner = 0 },
        .{ .path = "eyes[1].center", .v = field(eye_list[1], "center"), .n = 2, .inner = 0 },
        .{ .path = "eyes[0].iris", .v = field(eye_list[0], "iris"), .n = 3, .inner = 0 },
        .{ .path = "eyes[1].iris", .v = field(eye_list[1], "iris"), .n = 3, .inner = 0 },
        .{ .path = "eyes[0].lid", .v = field(eye_list[0], "lid"), .n = 3, .inner = 0 },
        .{ .path = "eyes[1].lid", .v = field(eye_list[1], "lid"), .n = 3, .inner = 0 },
        .{ .path = "mouth.inner", .v = field(mouth, "inner"), .n = 20, .inner = 2 },
        .{ .path = "mouth.outer", .v = field(mouth, "outer"), .n = 20, .inner = 2 },
        .{ .path = "mouth.center", .v = field(mouth, "center"), .n = 2, .inner = 0 },
        .{ .path = "mouth.left", .v = field(mouth, "left"), .n = 2, .inner = 0 },
        .{ .path = "mouth.right", .v = field(mouth, "right"), .n = 2, .inner = 0 },
        .{ .path = "mouth.jaw", .v = field(mouth, "jaw"), .n = 3, .inner = 0 },
        .{ .path = "face.chin", .v = field(face, "chin"), .n = 2, .inner = 0 },
        .{ .path = "face.forehead", .v = field(face, "forehead"), .n = 2, .inner = 0 },
        .{ .path = "face.left", .v = field(face, "left"), .n = 2, .inner = 0 },
        .{ .path = "face.right", .v = field(face, "right"), .n = 2, .inner = 0 },
        .{ .path = "eyeCrop", .v = field(root, "eyeCrop"), .n = 4, .inner = 0 },
    };
    for (needs) |x| if (!points(x.v, x.n, x.inner)) {
        const what = if (x.inner == 2) "points" else "numbers";
        return fail(why, "head.bin's header has no {s} of {d} {s}", .{ x.path, x.n, what }, a);
    };
    if (num(field(eye_list[0], "width") orelse .null) == null or num(field(eye_list[1], "width") orelse .null) == null)
        return fail(why, "head.bin's header has no eye widths", .{}, a);

    // the arrays: each inside the file, on a boundary, of a known type
    const list = switch (field(root, "arrays") orelse .null) {
        .object => |o| o,
        else => return fail(why, "head.bin's header has no arrays", .{}, a),
    };
    var it = list.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const arr = describe(e.value_ptr.*) orelse return fail(why, "head.bin's array {s} isn't [TYPE, OFFSET, COUNT]", .{name}, a);
        const ty = typeOf(arr.ty) orelse return fail(why, "head.bin's array {s} has an unknown type {s}", .{ name, arr.ty }, a);
        if (arr.off % 4 != 0) return fail(why, "head.bin's array {s} isn't on a 4-byte boundary", .{name}, a);
        if (arr.off > data.len or arr.count > (data.len - arr.off) / ty.size) return fail(why, "head.bin's array {s} runs past the end of the file", .{name}, a);
    }
    const Want = struct { name: []const u8, tys: []const []const u8, count: usize };
    var wants: std.ArrayList(Want) = .empty;
    try wants.appendSlice(a, &.{
        .{ .name = "head.pos", .tys = &.{"f32"}, .count = 3 * n },
        .{ .name = "head.nrm", .tys = &.{"f32"}, .count = 3 * n },
        .{ .name = "head.uv", .tys = &.{"f32"}, .count = 2 * n },
        .{ .name = "head.uvC", .tys = &.{"f32"}, .count = 2 * n },
    });
    for (shape_names) |s| {
        try wants.append(a, .{ .name = try std.fmt.allocPrint(a, "shape.{s}.pos", .{s}), .tys = &.{"i16"}, .count = 3 * n });
        try wants.append(a, .{ .name = try std.fmt.allocPrint(a, "shape.{s}.nrm", .{s}), .tys = &.{"i16"}, .count = 3 * n });
    }
    for (wants.items) |w| {
        const arr = describe(list.get(w.name) orelse return fail(why, "head.bin has no array {s}", .{w.name}, a)).?;
        if (!std.mem.eql(u8, arr.ty, w.tys[0])) return fail(why, "head.bin's array {s} is {s}; it should be {s}", .{ w.name, arr.ty, w.tys[0] }, a);
        if (arr.count != w.count) {
            const per: usize = w.count / n;
            return fail(why, "head.bin's array {s} has {d} values; {d} vertices need {d}", .{ w.name, arr.count, n, per * n }, a);
        }
    }
    // the triangles: whole, and pointing at vertices that are there
    const teeth = describe(list.get("teeth.pos") orelse return fail(why, "head.bin has no array teeth.pos", .{}, a)).?;
    if (!std.mem.eql(u8, teeth.ty, "f32") or teeth.count == 0 or teeth.count % 3 != 0) return fail(why, "head.bin's array teeth.pos isn't f32 points", .{}, a);
    for ([_][2]usize{ .{ 0, n }, .{ 1, teeth.count / 3 } }) |pair| {
        const iname = if (pair[0] == 0) "head.idx" else "teeth.idx";
        const arr = describe(list.get(iname) orelse return fail(why, "head.bin has no array {s}", .{iname}, a)).?;
        if (arr.count == 0 or arr.count % 3 != 0) return fail(why, "head.bin's array {s} isn't whole triangles", .{iname}, a);
        const is16 = std.mem.eql(u8, arr.ty, "u16");
        if (!is16 and !std.mem.eql(u8, arr.ty, "u32")) return fail(why, "head.bin's array {s} is {s}; it should be u16 or u32", .{ iname, arr.ty }, a);
        const raw = data[arr.off..];
        for (0..arr.count) |i| {
            const v: usize = if (is16) std.mem.readInt(u16, raw[i * 2 ..][0..2], .little) else std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
            if (v >= pair[1]) return fail(why, "head.bin's array {s} points past its {d} vertices", .{ iname, pair[1] }, a);
        }
    }
    // the still it was fitted to, when the fit knew its bytes
    var still_sha256: ?[64]u8 = null;
    if (field(root, "still")) |st| {
        const hex = switch (field(st, "sha256") orelse .null) {
            .string => |x| x,
            else => "",
        };
        if (hex.len != 64) return fail(why, "head.bin's header has no still.sha256 of 64 hex digits", .{}, a);
        var h: [64]u8 = undefined;
        for (hex, 0..) |ch, i| {
            if (!std.ascii.isHex(ch)) return fail(why, "head.bin's header has no still.sha256 of 64 hex digits", .{}, a);
            h[i] = std.ascii.toLower(ch);
        }
        still_sha256 = h;
    }
    return .{ .version = version, .vertices = n, .shapes = shapes.len, .image = image, .still_sha256 = still_sha256 };
}

fn describe(v: std.json.Value) ?Arr {
    const items = switch (v) {
        .array => |x| x.items,
        else => return null,
    };
    if (items.len != 3) return null;
    const ty = switch (items[0]) {
        .string => |s| s,
        else => return null,
    };
    const off = num(items[1]) orelse return null;
    const count = num(items[2]) orelse return null;
    if (off < 0 or count < 0 or @floor(off) != off or @floor(count) != count or off > 1 << 32 or count > 1 << 32) return null;
    return .{ .ty = ty, .off = @intFromFloat(off), .count = @intFromFloat(count) };
}

fn typeOf(name: []const u8) ?Ty {
    for (types) |ty| if (std.mem.eql(u8, ty.name, name)) return ty;
    return null;
}

fn sizeText(a: std.mem.Allocator, n: u64) ![]const u8 {
    if (n < 1024) return std.fmt.allocPrint(a, "{d} bytes", .{n});
    if (n < 1 << 20) return std.fmt.allocPrint(a, "{d} KB", .{(n + 512) / 1024});
    return std.fmt.allocPrint(a, "{d:.1} MB", .{@as(f64, @floatFromInt(n)) / (1 << 20)});
}

/// What `harness avatar check NAME` prints.
pub fn text(a: std.mem.Allocator, name: []const u8, dir: []const u8, r: Report) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Avatar {s} ({s}):\n", .{ name, dir });
    for (r.files) |f| {
        try out.print(a, "  {s}", .{f.key});
        try out.appendNTimes(a, ' ', 9 -| f.key.len);
        try out.print(a, "{s}", .{f.name});
        try out.appendNTimes(a, ' ', @max(2, 13 -| f.name.len));
        if (f.kind == .head) {
            if (r.head) |h| {
                try out.print(a, "head file version {d}: {d} vertices, {d} shapes, fitted to {d}x{d}; {s}\n", .{ h.version, h.vertices, h.shapes, h.image[0], h.image[1], try sizeText(a, f.bytes) });
                continue;
            }
        }
        if (f.width > 0) try out.print(a, "{s} {d}x{d}, {s}\n", .{ f.kind.label(), f.width, f.height, try sizeText(a, f.bytes) }) else try out.print(a, "{s}, {s}\n", .{ f.kind.label(), try sizeText(a, f.bytes) });
    }
    if (r.problems.len > 0) {
        try out.appendSlice(a, "Problems:\n");
        for (r.problems) |p| try out.print(a, "  - {s}\n", .{p});
    } else if (r.fitted) {
        try out.appendSlice(a, "Good.\n");
    } else {
        try out.appendSlice(a, "Good. Not fitted yet: the desk shows the still and offers to fit it.\n");
    }
    return out.items;
}

// ---- tests ----

const t = std.testing;

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("\n--- expected to find:\n{s}\n--- in:\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

fn problemsText(a: std.mem.Allocator, r: Report) ![]const u8 {
    return std.mem.join(a, "\n", r.problems);
}

/// A JPEG's first segments: enough for its type and size.
fn jpeg(a: std.mem.Allocator, w: u16, h: u16, sof: u8, app1: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00");
    if (app1) {
        // an Exif block before the frame, as phones write
        try out.appendSlice(a, "\xff\xe1\x00\x0aExif\x00\x00MM");
    }
    try out.appendSlice(a, &.{ 0xff, 0xdb, 0x00, 0x03, 0x00 }); // a (short) table
    try out.appendSlice(a, &.{ 0xff, sof, 0x00, 0x11, 0x08, @intCast(h >> 8), @intCast(h & 0xff), @intCast(w >> 8), @intCast(w & 0xff), 0x03 });
    try out.appendNTimes(a, 0, 9);
    try out.appendSlice(a, "\xff\xd9");
    return out.items;
}

fn png(a: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, w, .big);
    try out.appendSlice(a, &be);
    std.mem.writeInt(u32, &be, h, .big);
    try out.appendSlice(a, &be);
    try out.appendSlice(a, "\x08\x06\x00\x00\x00\x00\x00\x00\x00");
    try out.appendSlice(a, "\x00\x00\x00\x00IEND\xae\x42\x60\x82");
    return out.items;
}

/// A made-up head: three vertices, one triangle, the 52 shapes (no Face
/// Cap data), with knobs that break it one way at a time.
const TestHead = struct {
    version: u32 = 1,
    kind: []const u8 = "head",
    image: [2]u32 = .{ 64, 32 },
    skip_shape: ?usize = null,
    dup_shape: bool = false,
    uv_count: ?u32 = null,
    bad_index: bool = false,
    misalign: bool = false,
    past_end: bool = false,
    outline_points: u32 = 16,
    /// the still's SHA-256 (hex) the head says it was fitted to
    still_sha256: ?[]const u8 = null,
};

const test_shapes = shape_names;

fn testHead(a: std.mem.Allocator, o: TestHead) ![]u8 {
    const n: u32 = 3;
    const TArr = struct { name: []const u8, ty: []const u8, count: u32, size: u32 };
    var arrs: std.ArrayList(TArr) = .empty;
    try arrs.append(a, .{ .name = "head.pos", .ty = "f32", .count = 3 * n, .size = 4 });
    try arrs.append(a, .{ .name = "head.nrm", .ty = "f32", .count = 3 * n, .size = 4 });
    try arrs.append(a, .{ .name = "head.uv", .ty = "f32", .count = o.uv_count orelse 2 * n, .size = 4 });
    try arrs.append(a, .{ .name = "head.uvC", .ty = "f32", .count = 2 * n, .size = 4 });
    try arrs.append(a, .{ .name = "head.idx", .ty = "u16", .count = 3, .size = 2 });
    var names: std.ArrayList([]const u8) = .empty;
    for (test_shapes, 0..) |s, i| {
        if (o.skip_shape == i) continue;
        try names.append(a, s);
    }
    // the arrays stay one per shape; only the list names one twice
    const array_names = try a.dupe([]const u8, names.items);
    if (o.dup_shape) names.items[1] = names.items[0];
    for (array_names) |s| {
        try arrs.append(a, .{ .name = try std.fmt.allocPrint(a, "shape.{s}.pos", .{s}), .ty = "i16", .count = 3 * n, .size = 2 });
        try arrs.append(a, .{ .name = try std.fmt.allocPrint(a, "shape.{s}.nrm", .{s}), .ty = "i16", .count = 3 * n, .size = 2 });
    }
    try arrs.append(a, .{ .name = "teeth.pos", .ty = "f32", .count = 9, .size = 4 });
    try arrs.append(a, .{ .name = "teeth.idx", .ty = "u16", .count = 3, .size = 2 });

    var data: std.ArrayList(u8) = .empty;
    var desc: std.ArrayList(u8) = .empty;
    for (arrs.items, 0..) |x, i| {
        while (data.items.len % 4 != 0) try data.append(a, 0);
        var off: usize = data.items.len;
        if (o.misalign and i == 0) {
            try data.appendNTimes(a, 0, 2);
            off += 2;
        }
        if (std.mem.eql(u8, x.name, "head.idx") or std.mem.eql(u8, x.name, "teeth.idx")) {
            const last: u16 = if (o.bad_index and std.mem.eql(u8, x.name, "head.idx")) 3 else 2;
            for ([_]u16{ 0, 1, last }) |v| {
                var le: [2]u8 = undefined;
                std.mem.writeInt(u16, &le, v, .little);
                try data.appendSlice(a, &le);
            }
        } else try data.appendNTimes(a, 0, x.count * x.size);
        const count = if (o.past_end and i == arrs.items.len - 1) x.count + 1000 else x.count;
        try desc.print(a, "{s}\"{s}\":[\"{s}\",{d},{d}]", .{ if (i == 0) "" else ",", x.name, x.ty, off, count });
    }
    var shapes_json: std.ArrayList(u8) = .empty;
    var scale_json: std.ArrayList(u8) = .empty;
    for (names.items, 0..) |s, i| {
        try shapes_json.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else ",", s });
        try scale_json.print(a, "{s}[1.5,0.25]", .{if (i == 0) "" else ","});
    }
    var outline: std.ArrayList(u8) = .empty;
    for (0..o.outline_points) |i| try outline.print(a, "{s}[{d},10]", .{ if (i == 0) "" else ",", i });
    var lip: std.ArrayList(u8) = .empty;
    for (0..20) |i| try lip.print(a, "{s}[{d},20]", .{ if (i == 0) "" else ",", i });
    const eye = try std.fmt.allocPrint(a, "{{\"center\":[20,10],\"width\":8,\"outline\":[{s}],\"iris\":[20,10,2],\"catchlight\":null,\"lid\":[200,160,140]}}", .{outline.items});
    const header = try std.fmt.allocPrint(a,
        \\{{"kind":"{s}","vertices":{d},"image":[{d},{d}],"shapes":[{s}],"shapeScale":[{s}],
        \\"face":{{"noseTip":[32,14],"chin":[32,28],"forehead":[32,2],"left":[20,12],"right":[44,12]}},
        \\"mouth":{{"center":[32,20],"left":[26,20],"right":[38,20],"inner":[{s}],"outer":[{s}],"jaw":[0,-3,-2]}},
        \\"eyes":[{s},{s}],"eyeCrop":[10,4,44,12],"photo":{{}}{s},"arrays":{{{s}}}}}
    , .{ o.kind, n, o.image[0], o.image[1], shapes_json.items, scale_json.items, lip.items, lip.items, eye, eye, if (o.still_sha256) |h| try std.fmt.allocPrint(a, ",\"still\":{{\"bytes\":1,\"sha256\":\"{s}\"}}", .{h}) else "", desc.items });
    var hdr: std.ArrayList(u8) = .empty;
    try hdr.appendSlice(a, header);
    while (hdr.items.len % 4 != 0) try hdr.append(a, ' ');
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\x89HEAD\r\n\x1a");
    var le: [4]u8 = undefined;
    std.mem.writeInt(u32, &le, o.version, .little);
    try out.appendSlice(a, &le);
    std.mem.writeInt(u32, &le, @intCast(hdr.items.len), .little);
    try out.appendSlice(a, &le);
    try out.appendSlice(a, hdr.items);
    try out.appendSlice(a, data.items);
    return out.items;
}

/// A pack folder in a temporary directory.
const Pack = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8 = "",

    fn init(p: *Pack) !void {
        p.tmp = t.tmpDir(.{});
        p.arena = .init(t.allocator);
        p.dir = try p.tmp.dir.realPathFileAlloc(t.io, ".", p.arena.allocator());
    }

    fn deinit(p: *Pack) void {
        p.arena.deinit();
        p.tmp.cleanup();
    }

    fn a(p: *Pack) std.mem.Allocator {
        return p.arena.allocator();
    }

    fn put(p: *Pack, name: []const u8, data: []const u8) !void {
        try p.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = data });
    }

    /// A fitted pack: a JPEG still and closed photo of 64x32, PNG eyes and mask, a head.
    fn fitted(p: *Pack) !void {
        // as the desk page's upload writes it
        try p.put("avatar.ini", "# a test pack\n[avatar]\nstill = still.jpg\nclosed = closed.jpg\nhead = head.bin\neyes = eyes.png\neyemask = eyemask.png\n");
        try p.put("still.jpg", try jpeg(p.a(), 64, 32, 0xc0, false));
        try p.put("closed.jpg", try jpeg(p.a(), 64, 32, 0xc0, true));
        try p.put("head.bin", try testHead(p.a(), .{}));
        try p.put("eyes.png", try png(p.a(), 20, 10));
        try p.put("eyemask.png", try png(p.a(), 16, 8));
    }

    fn check(p: *Pack) !Report {
        return @import("avatar.zig").check(t.io, p.a(), p.dir);
    }
};

test "a_good_pack_passes_with_its_files_types_and_sizes" {
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.fitted();
    const r = try p.check();
    try t.expectEqualStrings("", try problemsText(p.a(), r));
    try t.expect(r.fitted);
    try t.expectEqual(5, r.files.len);
    const out = try text(p.a(), "test", "avatars/test", r);
    try expectHas(out, "still    still.jpg    JPEG 64x32");
    try expectHas(out, "closed   closed.jpg   JPEG 64x32");
    try expectHas(out, "head     head.bin     head file version 1: 3 vertices, 52 shapes, fitted to 64x32");
    try expectHas(out, "eyes     eyes.png     PNG 20x10");
    try expectHas(out, "eyemask  eyemask.png  PNG 16x8");
    try expectHas(out, " bytes");
    try expectHas(out, "Good.");
}

test "a_pack_with_only_a_still_is_good_and_unfitted" {
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.put("avatar.ini", "still = me.png\n");
    try p.put("me.png", try png(p.a(), 300, 400));
    const r = try p.check();
    try t.expectEqualStrings("", try problemsText(p.a(), r));
    try t.expect(!r.fitted);
    try t.expectEqual(null, r.head);
    try expectHas(try text(p.a(), "me", "avatars/me", r), "Not fitted yet");
}

test "files_are_checked_by_their_magic_bytes" {
    {
        var p: Pack = undefined;
        try p.init();
        defer p.deinit();
        try p.fitted();
        try p.put("head.bin", "hello, not a head");
        try expectHas(try problemsText(p.a(), try p.check()), "head.bin is not a head file");
    }
    {
        // a PNG named .jpg is a PNG, and fine
        var p: Pack = undefined;
        try p.init();
        defer p.deinit();
        try p.fitted();
        try p.put("still.jpg", try png(p.a(), 64, 32));
        const r = try p.check();
        try t.expectEqualStrings("", try problemsText(p.a(), r));
        try expectHas(try text(p.a(), "test", "avatars/test", r), "still.jpg    PNG 64x32");
    }
    {
        var p: Pack = undefined;
        try p.init();
        defer p.deinit();
        try p.put("avatar.ini", "still = still.gif\n");
        try p.put("still.gif", "GIF89a\x40\x00\x20\x00");
        try expectHas(try problemsText(p.a(), try p.check()), "still.gif is not a JPEG or PNG");
    }
    {
        var p: Pack = undefined;
        try p.init();
        defer p.deinit();
        try p.fitted();
        try p.put("eyes.png", try jpeg(p.a(), 20, 10, 0xc0, false));
        try expectHas(try problemsText(p.a(), try p.check()), "eyes.png is not a PNG");
    }
}

test "avatar_ini_problems_are_named" {
    const Case = struct { ini: ?[]const u8, says: []const u8 };
    const cases = [_]Case{
        .{ .ini = null, .says = "avatar.ini is missing" },
        .{ .ini = "closed = still.jpg\n", .says = "avatar.ini names no still" },
        .{ .ini = "still = still.jpg\nmood = happy\n", .says = "avatar.ini line 2: unknown key mood" },
        .{ .ini = "still = ../still.jpg\n", .says = "avatar.ini line 1: ../still.jpg isn't a file name in the pack's folder" },
        .{ .ini = "still = still.jpg\nhead = head.bin\n", .says = "head, eyes and eyemask go together; avatar.ini names only head" },
        .{ .ini = "still = gone.jpg\n", .says = "still: gone.jpg isn't in the pack" },
        .{ .ini = "still = still.jpg\nstill = still.jpg\n", .says = "avatar.ini line 2: still twice" },
        .{ .ini = "a line with no equals sign\nstill = still.jpg\n", .says = "avatar.ini line 1: not KEY = FILE" },
        .{ .ini = "[avatar]\nstill = still.jpg\n[colours]\nhair = black\n", .says = "avatar.ini line 3: unknown section [colours]" },
        .{ .ini = "[other]\nstill = still.jpg\n", .says = "avatar.ini names no still" },
    };
    for (cases) |c| {
        var p: Pack = undefined;
        try p.init();
        defer p.deinit();
        try p.put("still.jpg", try jpeg(p.a(), 64, 32, 0xc0, false));
        try p.put("head.bin", try testHead(p.a(), .{}));
        if (c.ini) |ini| try p.put("avatar.ini", ini);
        try expectHas(try problemsText(p.a(), try p.check()), c.says);
    }
    // comments, blank lines, spaces and \r\n are fine
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.put("still.jpg", try jpeg(p.a(), 64, 32, 0xc0, false));
    try p.put("avatar.ini", "# me\r\n[avatar]\r\n\r\n  still   =   still.jpg  \r\n; old style comment\r\n");
    try t.expectEqualStrings("", try problemsText(p.a(), try p.check()));
}

fn headWhy(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var why: []const u8 = "";
    if (readHeader(a, bytes, &why)) |_| return "" else |_| return why;
}

test "the_head_header_is_checked" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const good = try readHeader(a, try testHead(a, .{}), &why);
    try t.expectEqual(1, good.version);
    try t.expectEqual(3, good.vertices);
    try t.expectEqual(52, good.shapes);
    try t.expectEqual([2]u32{ 64, 32 }, good.image);

    var bad_magic = try testHead(a, .{});
    bad_magic[1] = 'X';
    try expectHas(try headWhy(a, bad_magic), "head.bin is not a head file");
    try expectHas(try headWhy(a, try testHead(a, .{ .version = 2 })), "head.bin is format version 2, made by a newer harness; this one reads version 1");
    try expectHas(try headWhy(a, (try testHead(a, .{}))[0..40]), "head.bin's header runs past the end of the file");
    try expectHas(try headWhy(a, try testHead(a, .{ .skip_shape = 37 })), "head.bin has no shape mouthSmile_L");
    try expectHas(try headWhy(a, try testHead(a, .{ .dup_shape = true })), "head.bin names shape browInnerUp twice");
    try expectHas(try headWhy(a, try testHead(a, .{ .uv_count = 9 })), "head.bin's array head.uv has 9 values; 3 vertices need 6");
    try expectHas(try headWhy(a, try testHead(a, .{ .past_end = true })), "head.bin's array teeth.idx runs past the end of the file");
    try expectHas(try headWhy(a, try testHead(a, .{ .misalign = true })), "head.bin's array head.pos isn't on a 4-byte boundary");
    try expectHas(try headWhy(a, try testHead(a, .{ .bad_index = true })), "head.bin's array head.idx points past its 3 vertices");
    try expectHas(try headWhy(a, try testHead(a, .{ .kind = "base" })), "head.bin is the base head, not a fitted one");
    try expectHas(try headWhy(a, try testHead(a, .{ .outline_points = 15 })), "head.bin's header has no eyes[0].outline of 16 points");
}

test "a_head_fitted_to_another_photo_is_a_problem" {
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.fitted();
    try p.put("still.jpg", try jpeg(p.a(), 80, 32, 0xc0, false));
    try p.put("closed.jpg", try jpeg(p.a(), 80, 32, 0xc0, false));
    try expectHas(try problemsText(p.a(), try p.check()), "head.bin was fitted to a 64x32 photo; the still is 80x32");
    // and a closed photo of another size
    try p.put("still.jpg", try jpeg(p.a(), 64, 32, 0xc0, false));
    try expectHas(try problemsText(p.a(), try p.check()), "closed.jpg is 80x32; the still is 64x32");
}

test "jpeg_and_png_sizes_are_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual([2]u32{ 640, 480 }, imageSize(try jpeg(a, 640, 480, 0xc0, true)).?);
    try t.expectEqual([2]u32{ 2720, 1536 }, imageSize(try jpeg(a, 2720, 1536, 0xc2, false)).?);
    try t.expectEqual([2]u32{ 564, 236 }, imageSize(try png(a, 564, 236)).?);
    try t.expectEqual(null, imageSize("\xff\xd8\xff\xd9"));
    try t.expectEqual(null, imageSize("GIF89a"));
}

test "files_over_20_mb_are_a_problem" {
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.put("avatar.ini", "still = still.jpg\n");
    try p.put("still.jpg", try jpeg(p.a(), 64, 32, 0xc0, false));
    var f = try p.tmp.dir.openFile(t.io, "still.jpg", .{ .mode = .read_write });
    try f.setLength(t.io, 21 << 20);
    f.close(t.io);
    try expectHas(try problemsText(p.a(), try p.check()), "still.jpg is 21.0 MB; the desk serves files up to 20 MB");
}

test "avatar_names_are_plain" {
    try t.expect(validName("butler"));
    try t.expect(validName("me-2"));
    try t.expect(validName("my_face"));
    try t.expect(!validName(""));
    try t.expect(!validName("-x"));
    try t.expect(!validName("Butler"));
    try t.expect(!validName("../x"));
    var long: [65]u8 = undefined;
    @memset(&long, 'a');
    try t.expect(!validName(&long));
    try t.expect(validName(long[0..64]));
}

test "the_js_packer_and_this_reader_agree" {
    // made by the desk's fit.js from a made-up 3x3 base head
    // (node tools/test-avatar.mjs --write-fixture)
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const h = readHeader(arena.allocator(), @embedFile("testdata/avatar/tiny-head.bin"), &why) catch |e| {
        std.debug.print("\n{s}\n", .{why});
        return e;
    };
    try t.expectEqual(1, h.version);
    try t.expectEqual(9, h.vertices);
    try t.expectEqual(52, h.shapes);
    try t.expectEqual([2]u32{ 128, 96 }, h.image);
}

/// A JPEG with an Exif orientation tag (big- or little-endian), as phones write.
fn jpegTurned(a: std.mem.Allocator, w: u16, h: u16, orientation: u16, little: bool) ![]u8 {
    var tiff: std.ArrayList(u8) = .empty;
    const put16 = struct {
        fn f(l: *std.ArrayList(u8), al: std.mem.Allocator, v: u16, le: bool) !void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, if (le) .little else .big);
            try l.appendSlice(al, &b);
        }
    }.f;
    const put32 = struct {
        fn f(l: *std.ArrayList(u8), al: std.mem.Allocator, v: u32, le: bool) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, if (le) .little else .big);
            try l.appendSlice(al, &b);
        }
    }.f;
    try tiff.appendSlice(a, if (little) "II" else "MM");
    try put16(&tiff, a, 42, little);
    try put32(&tiff, a, 8, little);
    try put16(&tiff, a, 2, little); // two entries: something else, then the orientation
    try put16(&tiff, a, 0x010f, little); // Make, ASCII, 4 bytes inline
    try put16(&tiff, a, 2, little);
    try put32(&tiff, a, 4, little);
    try tiff.appendSlice(a, "Foo\x00");
    try put16(&tiff, a, 0x0112, little);
    try put16(&tiff, a, 3, little);
    try put32(&tiff, a, 1, little);
    try put16(&tiff, a, orientation, little);
    try put16(&tiff, a, 0, little);
    try put32(&tiff, a, 0, little);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\xff\xd8\xff\xe1");
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(2 + 6 + tiff.items.len), .big);
    try out.appendSlice(a, &len);
    try out.appendSlice(a, "Exif\x00\x00");
    try out.appendSlice(a, tiff.items);
    const rest = try jpeg(a, w, h, 0xc0, false);
    try out.appendSlice(a, rest[2..]);
    return out.items;
}

test "phone_photos_are_sized_as_shown" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // stored 32 wide and 64 tall, shown turned a quarter (orientation 6 or 8): 64x32
    try t.expectEqual([2]u32{ 64, 32 }, imageSize(try jpegTurned(a, 32, 64, 6, false)).?);
    try t.expectEqual([2]u32{ 64, 32 }, imageSize(try jpegTurned(a, 32, 64, 8, true)).?);
    // upright or upside down (1, 3): as stored
    try t.expectEqual([2]u32{ 32, 64 }, imageSize(try jpegTurned(a, 32, 64, 1, true)).?);
    try t.expectEqual([2]u32{ 32, 64 }, imageSize(try jpegTurned(a, 32, 64, 3, false)).?);
    // a pack whose head was fitted to the photo as shown is good
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.fitted();
    try p.put("still.jpg", try jpegTurned(p.a(), 32, 64, 6, false));
    try p.put("closed.jpg", try jpegTurned(p.a(), 32, 64, 6, true));
    try t.expectEqualStrings("", try problemsText(p.a(), try p.check()));
}

test "a_segment_of_the_largest_length_is_skipped" {
    // libjpeg writes ICC profile chunks at exactly 65535 bytes
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\xff\xd8\xff\xe2\xff\xff");
    try out.appendNTimes(a, 0, 0xffff - 2);
    const rest = try jpeg(a, 640, 480, 0xc0, false);
    try out.appendSlice(a, rest[2..]);
    try t.expectEqual([2]u32{ 640, 480 }, imageSize(out.items).?);
}

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.allocPrint(a, "{x}", .{&d});
}

test "a_head_fitted_to_another_photo_of_the_same_size_is_a_problem" {
    var p: Pack = undefined;
    try p.init();
    defer p.deinit();
    try p.fitted();
    const fitted_to = try jpeg(p.a(), 64, 32, 0xc0, true); // same size, other bytes
    try p.put("head.bin", try testHead(p.a(), .{ .still_sha256 = try sha256Hex(p.a(), fitted_to) }));
    try expectHas(try problemsText(p.a(), try p.check()), "head.bin was fitted to another photo (the still's SHA-256 isn't the one it was fitted to)");
    // the still it was fitted to: good
    try p.put("still.jpg", fitted_to);
    try t.expectEqualStrings("", try problemsText(p.a(), try p.check()));
    // a header whose fingerprint isn't one
    try p.put("head.bin", try testHead(p.a(), .{ .still_sha256 = "abc" }));
    try expectHas(try problemsText(p.a(), try p.check()), "head.bin's header has no still.sha256 of 64 hex digits");
}
