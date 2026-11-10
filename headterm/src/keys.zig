//! Translates `send` arguments into the bytes a terminal would produce.
//!
//! An argument of the form `<Name>` is a key; anything else is literal text.
//! Key names are case-insensitive and may carry modifiers: `C-` (Ctrl),
//! `M-` or `A-` (Meta/Alt), `S-` (Shift), e.g. `<C-c>`, `<M-x>`, `<S-Tab>`,
//! `<C-Left>`. `<lt>` sends a literal `<`.
//!
//! Mouse events are `<Click row,col>`, `<RightClick row,col>`,
//! `<MiddleClick row,col>`, `<ScrollUp row,col>` and `<ScrollDown row,col>`
//! with 0-based screen coordinates. They are only accepted when the program
//! has turned on mouse reporting.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ UnknownKey, MouseNotEnabled, BadMousePosition } || Allocator.Error;

/// Terminal state that changes what keys send.
pub const Context = struct {
    /// DECCKM: arrows send ESC O x instead of ESC [ x.
    app_cursor: bool = false,
    /// Mouse tracking mode the program enabled: 0 (off), 9, 1000, 1002, 1003.
    mouse_tracking: u16 = 0,
    /// Mode 1006: SGR mouse encoding.
    mouse_sgr: bool = false,
    /// Screen size, to reject mouse positions outside it.
    rows: usize = std.math.maxInt(usize),
    cols: usize = std.math.maxInt(usize),
};

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
    if (arg.len < 3 or arg[0] != '<' or arg[arg.len - 1] != '>') return false;
    const inner = arg[1 .. arg.len - 1];
    if (std.mem.indexOfAny(u8, inner, "<>") != null) return false;
    if (std.mem.indexOfScalar(u8, inner, ' ') == null) return true;
    // Only mouse events have a space: "<Click 3,4>".
    return mouseButton(inner[0..std.mem.indexOfScalar(u8, inner, ' ').?]) != null;
}

/// Appends the encoding of one `send` argument to `out`.
pub fn encodeArg(gpa: Allocator, out: *std.ArrayList(u8), arg: []const u8, ctx: Context) Error!void {
    if (!isKeySyntax(arg)) return out.appendSlice(gpa, arg);
    const inner = arg[1 .. arg.len - 1];
    if (std.mem.indexOfScalar(u8, inner, ' ')) |sp| return encodeMouse(gpa, out, inner[0..sp], inner[sp + 1 ..], ctx);
    return encodeKey(gpa, out, inner, ctx.app_cursor);
}

const Mouse = struct { button: u8, release: bool };

fn mouseButton(name: []const u8) ?Mouse {
    const names = [_]struct { []const u8, Mouse }{
        .{ "click", .{ .button = 0, .release = true } },
        .{ "middleclick", .{ .button = 1, .release = true } },
        .{ "rightclick", .{ .button = 2, .release = true } },
        .{ "scrollup", .{ .button = 64, .release = false } },
        .{ "scrolldown", .{ .button = 65, .release = false } },
    };
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    for (names) |n| {
        if (std.mem.eql(u8, lower, n[0])) return n[1];
    }
    return null;
}

fn encodeMouse(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, pos: []const u8, ctx: Context) Error!void {
    const m = mouseButton(name) orelse return error.UnknownKey;
    const comma = std.mem.indexOfScalar(u8, pos, ',') orelse return error.BadMousePosition;
    const row = std.fmt.parseInt(usize, std.mem.trim(u8, pos[0..comma], " "), 10) catch return error.BadMousePosition;
    const col = std.fmt.parseInt(usize, std.mem.trim(u8, pos[comma + 1 ..], " "), 10) catch return error.BadMousePosition;
    if (ctx.mouse_tracking == 0) return error.MouseNotEnabled;
    if (row >= ctx.rows or col >= ctx.cols) return error.BadMousePosition;
    // Terminal mouse coordinates are 1-based, column first.
    const x = col + 1;
    const y = row + 1;
    if (ctx.mouse_sgr) {
        try out.print(gpa, "\x1b[<{d};{d};{d}M", .{ m.button, x, y });
        if (m.release) try out.print(gpa, "\x1b[<{d};{d};{d}m", .{ m.button, x, y });
        return;
    }
    // Legacy encoding: each value + 32 in one byte, so at most 223.
    if (x > 223 or y > 223) return error.BadMousePosition;
    try out.appendSlice(gpa, &.{ 0x1b, '[', 'M', 32 + m.button, @intCast(32 + x), @intCast(32 + y) });
    // X10 mode (9) reports presses only; release is button code 3.
    if (m.release and ctx.mouse_tracking != 9) {
        try out.appendSlice(gpa, &.{ 0x1b, '[', 'M', 32 + 3, @intCast(32 + x), @intCast(32 + y) });
    }
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
    return expectEncodedCtx(arg, .{ .app_cursor = app_cursor }, expected);
}

fn expectEncodedCtx(arg: []const u8, ctx: Context, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try encodeArg(testing.allocator, &out, arg, ctx);
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
    try testing.expectError(error.UnknownKey, encodeArg(testing.allocator, &out, "<Foo>", .{}));
    try testing.expectError(error.UnknownKey, encodeArg(testing.allocator, &out, "<C-é>", .{}));
}

test "mouse events need mouse reporting and use the program's encoding" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.MouseNotEnabled, encodeArg(testing.allocator, &out, "<Click 2,5>", .{}));

    const sgr: Context = .{ .mouse_tracking = 1000, .mouse_sgr = true, .rows = 24, .cols = 80 };
    try expectEncodedCtx("<Click 2,5>", sgr, "\x1b[<0;6;3M\x1b[<0;6;3m");
    try expectEncodedCtx("<click 0, 0>", sgr, "\x1b[<0;1;1M\x1b[<0;1;1m");
    try expectEncodedCtx("<RightClick 1,1>", sgr, "\x1b[<2;2;2M\x1b[<2;2;2m");
    try expectEncodedCtx("<ScrollUp 10,20>", sgr, "\x1b[<64;21;11M");
    try expectEncodedCtx("<ScrollDown 10,20>", sgr, "\x1b[<65;21;11M");
    try testing.expectError(error.BadMousePosition, encodeArg(testing.allocator, &out, "<Click 24,0>", sgr));
    try testing.expectError(error.BadMousePosition, encodeArg(testing.allocator, &out, "<Click 3>", sgr));

    const x11: Context = .{ .mouse_tracking = 1000, .rows = 300, .cols = 300 };
    try expectEncodedCtx("<Click 2,5>", x11, "\x1b[M\x20\x26\x23\x1b[M\x23\x26\x23");
    try expectEncodedCtx("<ScrollUp 0,0>", x11, "\x1b[M\x60\x21\x21");
    try testing.expectError(error.BadMousePosition, encodeArg(testing.allocator, &out, "<Click 0,250>", x11));
    // X10 mode reports presses only.
    try expectEncodedCtx("<Click 0,0>", .{ .mouse_tracking = 9 }, "\x1b[M\x20\x21\x21");

    // Text that only looks like a key stays text.
    try expectEncodedCtx("<hello world>", .{}, "<hello world>");
}
