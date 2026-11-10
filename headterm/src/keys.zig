//! Translates `send` arguments into the bytes a terminal would produce.
//!
//! An argument of the form `<Name>` is a key; anything else is literal text.
//! Key names are case-insensitive and may carry modifiers: `C-` (Ctrl),
//! `M-` or `A-` (Meta/Alt), `S-` (Shift), e.g. `<C-c>`, `<M-x>`, `<S-Tab>`,
//! `<C-Left>`. `<lt>` sends a literal `<`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{UnknownKey} || Allocator.Error;

pub const Mods = struct {
    ctrl: bool = false,
    meta: bool = false,
    shift: bool = false,

    fn any(m: Mods) bool {
        return m.ctrl or m.meta or m.shift;
    }

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    fn param(m: Mods) u8 {
        return 1 + @as(u8, @intFromBool(m.shift)) + 2 * @as(u8, @intFromBool(m.meta)) + 4 * @as(u8, @intFromBool(m.ctrl));
    }
};

/// Returns true if `arg` looks like a key (`<...>`), whether or not the name
/// is known.
pub fn isKeySyntax(arg: []const u8) bool {
    return arg.len >= 3 and arg[0] == '<' and arg[arg.len - 1] == '>' and
        std.mem.indexOfAny(u8, arg[1 .. arg.len - 1], " <>") == null;
}

/// Appends the encoding of one `send` argument to `out`.
pub fn encodeArg(gpa: Allocator, out: *std.ArrayList(u8), arg: []const u8, app_cursor: bool) Error!void {
    if (!isKeySyntax(arg)) return out.appendSlice(gpa, arg);
    return encodeKey(gpa, out, arg[1 .. arg.len - 1], app_cursor);
}

const Cursor = struct { name: []const u8, final: u8 };
const cursor_keys = [_]Cursor{
    .{ .name = "up", .final = 'A' },
    .{ .name = "down", .final = 'B' },
    .{ .name = "right", .final = 'C' },
    .{ .name = "left", .final = 'D' },
    .{ .name = "home", .final = 'H' },
    .{ .name = "end", .final = 'F' },
};

const Tilde = struct { name: []const u8, code: u8 };
const tilde_keys = [_]Tilde{
    .{ .name = "insert", .code = 2 },   .{ .name = "ins", .code = 2 },
    .{ .name = "delete", .code = 3 },   .{ .name = "del", .code = 3 },
    .{ .name = "pageup", .code = 5 },   .{ .name = "pgup", .code = 5 },
    .{ .name = "pagedown", .code = 6 }, .{ .name = "pgdn", .code = 6 },
    .{ .name = "f5", .code = 15 },      .{ .name = "f6", .code = 17 },
    .{ .name = "f7", .code = 18 },      .{ .name = "f8", .code = 19 },
    .{ .name = "f9", .code = 20 },      .{ .name = "f10", .code = 21 },
    .{ .name = "f11", .code = 23 },     .{ .name = "f12", .code = 24 },
};

const Simple = struct { name: []const u8, byte: u8 };
const simple_keys = [_]Simple{
    .{ .name = "enter", .byte = '\r' },
    .{ .name = "return", .byte = '\r' },
    .{ .name = "cr", .byte = '\r' },
    .{ .name = "tab", .byte = '\t' },
    .{ .name = "esc", .byte = 0x1b },
    .{ .name = "escape", .byte = 0x1b },
    .{ .name = "backspace", .byte = 0x7f },
    .{ .name = "bs", .byte = 0x7f },
    .{ .name = "space", .byte = ' ' },
    .{ .name = "lt", .byte = '<' },
    .{ .name = "gt", .byte = '>' },
    .{ .name = "nul", .byte = 0 },
};

fn encodeKey(gpa: Allocator, out: *std.ArrayList(u8), spec: []const u8, app_cursor: bool) Error!void {
    var mods: Mods = .{};
    var name = spec;
    // Strip modifier prefixes; a trailing single character is the key, so
    // "<C-->" is Ctrl+'-' and "<M-C-x>" is Meta+Ctrl+x.
    while (name.len > 2 and name[1] == '-') {
        switch (std.ascii.toLower(name[0])) {
            'c' => mods.ctrl = true,
            'm', 'a' => mods.meta = true,
            's' => mods.shift = true,
            else => break,
        }
        name = name[2..];
    }

    var lower_buf: [16]u8 = undefined;
    if (name.len > lower_buf.len) return error.UnknownKey;
    const lower = std.ascii.lowerString(&lower_buf, name);

    if (name.len == 1) {
        var c = name[0];
        if (mods.shift) c = std.ascii.toUpper(c);
        if (mods.ctrl) c = ctrlByte(c) orelse return error.UnknownKey;
        if (mods.meta) try out.append(gpa, 0x1b);
        return out.append(gpa, c);
    }

    for (cursor_keys) |k| {
        if (!std.mem.eql(u8, lower, k.name)) continue;
        if (mods.any()) return out.print(gpa, "\x1b[1;{d}{c}", .{ mods.param(), k.final });
        return out.appendSlice(gpa, &.{ 0x1b, if (app_cursor) 'O' else '[', k.final });
    }

    for (tilde_keys) |k| {
        if (!std.mem.eql(u8, lower, k.name)) continue;
        if (mods.any()) return out.print(gpa, "\x1b[{d};{d}~", .{ k.code, mods.param() });
        return out.print(gpa, "\x1b[{d}~", .{k.code});
    }

    // F1-F4 use SS3 P..S.
    if (lower.len == 2 and lower[0] == 'f' and lower[1] >= '1' and lower[1] <= '4') {
        const final = "PQRS"[lower[1] - '1'];
        if (mods.any()) return out.print(gpa, "\x1b[1;{d}{c}", .{ mods.param(), final });
        return out.appendSlice(gpa, &.{ 0x1b, 'O', final });
    }

    for (simple_keys) |k| {
        if (!std.mem.eql(u8, lower, k.name)) continue;
        if (k.byte == '\t' and mods.shift) return out.appendSlice(gpa, "\x1b[Z");
        var byte = k.byte;
        if (mods.ctrl) {
            byte = switch (byte) {
                ' ' => 0,
                0x7f => 0x08,
                else => ctrlByte(byte) orelse byte,
            };
        }
        if (mods.meta) try out.append(gpa, 0x1b);
        return out.append(gpa, byte);
    }

    return error.UnknownKey;
}

fn ctrlByte(c: u8) ?u8 {
    return switch (c) {
        'a'...'z' => c - 'a' + 1,
        '@', 'A'...'Z', '[', '\\', ']', '^', '_' => c & 0x1f,
        ' ', '2' => 0,
        '3'...'7' => c - '3' + 0x1b,
        '8', '?' => 0x7f,
        else => null,
    };
}

// ======================================================================
// Tests

const testing = std.testing;

fn expectEncoded(arg: []const u8, app_cursor: bool, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try encodeArg(testing.allocator, &out, arg, app_cursor);
    try testing.expectEqualStrings(expected, out.items);
}

test "literal text passes through" {
    try expectEncoded("hello world", false, "hello world");
    try expectEncoded("<", false, "<");
    try expectEncoded("a <b> c", false, "a <b> c");
    try expectEncoded("<>", false, "<>");
}

test "named keys" {
    try expectEncoded("<Enter>", false, "\r");
    try expectEncoded("<tab>", false, "\t");
    try expectEncoded("<Esc>", false, "\x1b");
    try expectEncoded("<Backspace>", false, "\x7f");
    try expectEncoded("<Delete>", false, "\x1b[3~");
    try expectEncoded("<PageUp>", false, "\x1b[5~");
    try expectEncoded("<PageDown>", false, "\x1b[6~");
    try expectEncoded("<F1>", false, "\x1bOP");
    try expectEncoded("<F4>", false, "\x1bOS");
    try expectEncoded("<F5>", false, "\x1b[15~");
    try expectEncoded("<F12>", false, "\x1b[24~");
    try expectEncoded("<lt>", false, "<");
}

test "cursor keys respect DECCKM" {
    try expectEncoded("<Up>", false, "\x1b[A");
    try expectEncoded("<Up>", true, "\x1bOA");
    try expectEncoded("<Left>", true, "\x1bOD");
    try expectEncoded("<Home>", false, "\x1b[H");
    try expectEncoded("<End>", true, "\x1bOF");
    // Modified cursor keys always use the CSI form.
    try expectEncoded("<C-Right>", true, "\x1b[1;5C");
    try expectEncoded("<S-Up>", false, "\x1b[1;2A");
}

test "control and meta" {
    try expectEncoded("<C-c>", false, "\x03");
    try expectEncoded("<C-C>", false, "\x03");
    try expectEncoded("<C-a>", false, "\x01");
    try expectEncoded("<C-[>", false, "\x1b");
    try expectEncoded("<C-@>", false, "\x00");
    try expectEncoded("<C-Space>", false, "\x00");
    try expectEncoded("<M-x>", false, "\x1bx");
    try expectEncoded("<A-x>", false, "\x1bx");
    try expectEncoded("<M-C-x>", false, "\x1b\x18");
    try expectEncoded("<M-Enter>", false, "\x1b\r");
    try expectEncoded("<S-Tab>", false, "\x1b[Z");
    try expectEncoded("<C-Delete>", false, "\x1b[3;5~");
    try expectEncoded("<M-->", false, "\x1b-");
}

test "unknown keys are rejected" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.UnknownKey, encodeArg(testing.allocator, &out, "<Foo>", false));
    try testing.expectError(error.UnknownKey, encodeArg(testing.allocator, &out, "<C-é>", false));
}
