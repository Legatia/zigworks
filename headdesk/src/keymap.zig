//! The one keyboard layout headdesk has (US), as the table keys are looked
//! up in and as the XKB text that is handed to apps.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { one, two, alpha };

pub const Key = struct {
    /// Linux input event code; the XKB keycode is this plus 8.
    code: u8,
    /// The name on the command line, lower case.
    name: []const u8,
    /// XKB keysym names without and with Shift.
    lo: []const u8,
    hi: []const u8 = "",
    /// The characters it types without and with Shift (0: none).
    ch: u8 = 0,
    ch_shift: u8 = 0,

    pub fn kind(k: Key) Kind {
        if (k.hi.len == 0) return .one;
        return if (k.ch >= 'a' and k.ch <= 'z') .alpha else .two;
    }
};

fn letter(code: u8, c: u8) Key {
    const lower = [1]u8{c};
    const upper = [1]u8{c - 32};
    return .{ .code = code, .name = &lower, .lo = &lower, .hi = &upper, .ch = c, .ch_shift = c - 32 };
}

fn sym(code: u8, name: []const u8, lo: []const u8, hi: []const u8, ch: u8, ch_shift: u8) Key {
    return .{ .code = code, .name = name, .lo = lo, .hi = hi, .ch = ch, .ch_shift = ch_shift };
}

fn plain(code: u8, name: []const u8, keysym: []const u8) Key {
    return .{ .code = code, .name = name, .lo = keysym };
}

pub const keys = [_]Key{
    plain(1, "escape", "Escape"),
    sym(2, "1", "1", "exclam", '1', '!'),
    sym(3, "2", "2", "at", '2', '@'),
    sym(4, "3", "3", "numbersign", '3', '#'),
    sym(5, "4", "4", "dollar", '4', '$'),
    sym(6, "5", "5", "percent", '5', '%'),
    sym(7, "6", "6", "asciicircum", '6', '^'),
    sym(8, "7", "7", "ampersand", '7', '&'),
    sym(9, "8", "8", "asterisk", '8', '*'),
    sym(10, "9", "9", "parenleft", '9', '('),
    sym(11, "0", "0", "parenright", '0', ')'),
    sym(12, "minus", "minus", "underscore", '-', '_'),
    sym(13, "equal", "equal", "plus", '=', '+'),
    plain(14, "backspace", "BackSpace"),
    .{ .code = 15, .name = "tab", .lo = "Tab", .hi = "ISO_Left_Tab", .ch = '\t' },
    letter(16, 'q'),
    letter(17, 'w'),
    letter(18, 'e'),
    letter(19, 'r'),
    letter(20, 't'),
    letter(21, 'y'),
    letter(22, 'u'),
    letter(23, 'i'),
    letter(24, 'o'),
    letter(25, 'p'),
    sym(26, "bracketleft", "bracketleft", "braceleft", '[', '{'),
    sym(27, "bracketright", "bracketright", "braceright", ']', '}'),
    .{ .code = 28, .name = "enter", .lo = "Return", .ch = '\n' },
    plain(29, "ctrl", "Control_L"),
    letter(30, 'a'),
    letter(31, 's'),
    letter(32, 'd'),
    letter(33, 'f'),
    letter(34, 'g'),
    letter(35, 'h'),
    letter(36, 'j'),
    letter(37, 'k'),
    letter(38, 'l'),
    sym(39, "semicolon", "semicolon", "colon", ';', ':'),
    sym(40, "apostrophe", "apostrophe", "quotedbl", '\'', '"'),
    sym(41, "grave", "grave", "asciitilde", '`', '~'),
    plain(42, "shift", "Shift_L"),
    sym(43, "backslash", "backslash", "bar", '\\', '|'),
    letter(44, 'z'),
    letter(45, 'x'),
    letter(46, 'c'),
    letter(47, 'v'),
    letter(48, 'b'),
    letter(49, 'n'),
    letter(50, 'm'),
    sym(51, "comma", "comma", "less", ',', '<'),
    sym(52, "period", "period", "greater", '.', '>'),
    sym(53, "slash", "slash", "question", '/', '?'),
    plain(54, "shift_r", "Shift_R"),
    plain(56, "alt", "Alt_L"),
    .{ .code = 57, .name = "space", .lo = "space", .ch = ' ' },
    plain(58, "capslock", "Caps_Lock"),
    plain(59, "f1", "F1"),
    plain(60, "f2", "F2"),
    plain(61, "f3", "F3"),
    plain(62, "f4", "F4"),
    plain(63, "f5", "F5"),
    plain(64, "f6", "F6"),
    plain(65, "f7", "F7"),
    plain(66, "f8", "F8"),
    plain(67, "f9", "F9"),
    plain(68, "f10", "F10"),
    plain(87, "f11", "F11"),
    plain(88, "f12", "F12"),
    plain(97, "ctrl_r", "Control_R"),
    plain(100, "alt_r", "Alt_R"),
    plain(102, "home", "Home"),
    plain(103, "up", "Up"),
    plain(104, "pageup", "Prior"),
    plain(105, "left", "Left"),
    plain(106, "right", "Right"),
    plain(107, "end", "End"),
    plain(108, "down", "Down"),
    plain(109, "pagedown", "Next"),
    plain(110, "insert", "Insert"),
    plain(111, "delete", "Delete"),
    plain(125, "super", "Super_L"),
    plain(127, "menu", "Menu"),
};

/// Modifier bits as apps get them (the fixed XKB order).
pub const Mods = struct {
    pub const shift: u32 = 1;
    pub const ctrl: u32 = 4;
    pub const alt: u32 = 8;
    pub const super: u32 = 64;
};

pub const Modifier = struct { name: []const u8, mask: u32, code: u8 };

pub const modifiers = [_]Modifier{
    .{ .name = "shift", .mask = Mods.shift, .code = 42 },
    .{ .name = "ctrl", .mask = Mods.ctrl, .code = 29 },
    .{ .name = "control", .mask = Mods.ctrl, .code = 29 },
    .{ .name = "alt", .mask = Mods.alt, .code = 56 },
    .{ .name = "super", .mask = Mods.super, .code = 125 },
    .{ .name = "meta", .mask = Mods.super, .code = 125 },
};

/// The key called `name` (case does not matter; "return" and "esc" are
/// also known).
pub fn byName(name: []const u8) ?Key {
    var buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    const wanted: []const u8 = if (std.mem.eql(u8, lower, "return")) "enter" else if (std.mem.eql(u8, lower, "esc")) "escape" else if (std.mem.eql(u8, lower, "del")) "delete" else if (std.mem.eql(u8, lower, "pgup")) "pageup" else if (std.mem.eql(u8, lower, "pgdn")) "pagedown" else lower;
    for (keys) |k| {
        if (std.mem.eql(u8, k.name, wanted)) return k;
    }
    return null;
}

pub const Typed = struct { code: u8, shift: bool };

/// The key (and whether Shift is held) that types the ASCII character `c`.
pub fn forChar(c: u8) ?Typed {
    for (keys) |k| {
        if (k.ch != 0 and k.ch == c) return .{ .code = k.code, .shift = false };
        if (k.ch_shift != 0 and k.ch_shift == c) return .{ .code = k.code, .shift = true };
    }
    return null;
}

pub const Combo = struct { mods: u32, mod_codes: [4]u8, mod_count: usize, key: Key };

/// "ctrl+shift+t", "Return", "alt+f4".
pub fn parseCombo(spec: []const u8) ?Combo {
    var combo: Combo = .{ .mods = 0, .mod_codes = undefined, .mod_count = 0, .key = undefined };
    var it = std.mem.splitScalar(u8, spec, '+');
    var last: ?[]const u8 = null;
    while (it.next()) |part| {
        if (last) |name| {
            var buf: [16]u8 = undefined;
            if (name.len == 0 or name.len > buf.len) return null;
            const lower = std.ascii.lowerString(&buf, name);
            const m = for (modifiers) |m| {
                if (std.mem.eql(u8, m.name, lower)) break m;
            } else return null;
            if (combo.mods & m.mask == 0) {
                if (combo.mod_count == combo.mod_codes.len) return null;
                combo.mod_codes[combo.mod_count] = m.code;
                combo.mod_count += 1;
            }
            combo.mods |= m.mask;
        }
        last = part;
    }
    // "ctrl++" and a lone "+": the key is plus
    const name = last orelse return null;
    if (name.len == 0) return null;
    if (byName(name)) |k| {
        combo.key = k;
        return combo;
    }
    if (name.len == 1) {
        const t = forChar(name[0]) orelse return null;
        for (keys) |k| {
            if (k.code == t.code) combo.key = k;
        }
        if (t.shift and combo.mods & Mods.shift == 0) {
            combo.mod_codes[combo.mod_count] = 42;
            combo.mod_count += 1;
            combo.mods |= Mods.shift;
        }
        return combo;
    }
    return null;
}

/// The layout as XKB text, with a closing zero, as wl_keyboard.keymap wants.
pub fn text(gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line: [160]u8 = undefined;
    try out.appendSlice(gpa, "xkb_keymap {\nxkb_keycodes \"headdesk\" {\nminimum = 8;\nmaximum = 255;\n");
    for (keys) |k| try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "<E{d:0>3}> = {d};\n", .{ k.code, @as(u32, k.code) + 8 }));
    try out.appendSlice(gpa,
        \\};
        \\xkb_types "headdesk" {
        \\type "ONE_LEVEL" { modifiers = none; level_name[Level1] = "Any"; };
        \\type "TWO_LEVEL" { modifiers = Shift; map[Shift] = Level2; level_name[Level1] = "Base"; level_name[Level2] = "Shift"; };
        \\type "ALPHABETIC" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2; level_name[Level1] = "Base"; level_name[Level2] = "Caps"; };
        \\};
        \\xkb_compatibility "headdesk" {
        \\interpret Any+AnyOf(all) { action = SetMods(modifiers=modMapMods,clearLocks); };
        \\};
        \\xkb_symbols "headdesk" {
        \\name[Group1] = "English (US)";
        \\
    );
    for (keys) |k| {
        const row = switch (k.kind()) {
            .one => try std.fmt.bufPrint(&line, "key <E{d:0>3}> {{ type = \"ONE_LEVEL\", symbols[Group1] = [ {s} ] }};\n", .{ k.code, k.lo }),
            .two => try std.fmt.bufPrint(&line, "key <E{d:0>3}> {{ type = \"TWO_LEVEL\", symbols[Group1] = [ {s}, {s} ] }};\n", .{ k.code, k.lo, k.hi }),
            .alpha => try std.fmt.bufPrint(&line, "key <E{d:0>3}> {{ type = \"ALPHABETIC\", symbols[Group1] = [ {s}, {s} ] }};\n", .{ k.code, k.lo, k.hi }),
        };
        try out.appendSlice(gpa, row);
    }
    try out.appendSlice(gpa,
        \\modifier_map Shift { <E042>, <E054> };
        \\modifier_map Lock { <E058> };
        \\modifier_map Control { <E029>, <E097> };
        \\modifier_map Mod1 { <E056>, <E100> };
        \\modifier_map Mod4 { <E125> };
        \\};
        \\};
        \\
    );
    try out.append(gpa, 0);
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "keys are found by name and by the character they type" {
    try testing.expectEqual(@as(u8, 28), byName("Return").?.code);
    try testing.expectEqual(@as(u8, 1), byName("esc").?.code);
    try testing.expectEqual(@as(u8, 30), byName("a").?.code);
    try testing.expectEqual(@as(?Key, null), byName("nosuchkey"));
    try testing.expectEqual(Typed{ .code = 30, .shift = true }, forChar('A').?);
    try testing.expectEqual(Typed{ .code = 53, .shift = true }, forChar('?').?);
    try testing.expectEqual(Typed{ .code = 57, .shift = false }, forChar(' ').?);
    try testing.expectEqual(@as(?Typed, null), forChar(200));
}

test "combinations name their modifiers" {
    const c = parseCombo("ctrl+shift+t").?;
    try testing.expectEqual(Mods.ctrl | Mods.shift, c.mods);
    try testing.expectEqual(@as(usize, 2), c.mod_count);
    try testing.expectEqual(@as(u8, 20), c.key.code);
    try testing.expectEqual(@as(u8, 62), parseCombo("alt+F4").?.key.code);
    // a character that needs Shift brings it along
    const q = parseCombo("?").?;
    try testing.expectEqual(Mods.shift, q.mods);
    try testing.expectEqual(@as(?Combo, null), parseCombo("hyper+x"));
    try testing.expectEqual(@as(?Combo, null), parseCombo(""));
}

test "the layout text names every key once and ends with a zero" {
    const t = try text(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(u8, 0), t[t.len - 1]);
    try testing.expect(std.mem.find(u8, t, "<E030> = 38;") != null);
    try testing.expect(std.mem.find(u8, t, "key <E030> { type = \"ALPHABETIC\", symbols[Group1] = [ a, A ] };") != null);
    try testing.expect(std.mem.find(u8, t, "key <E028> { type = \"ONE_LEVEL\", symbols[Group1] = [ Return ] };") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, t, "<E057> ="));
    for (keys, 0..) |a, i| {
        for (keys[i + 1 ..]) |b| try testing.expect(a.code != b.code);
    }
}
