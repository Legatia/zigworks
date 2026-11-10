//! Translates `send` arguments into the bytes a terminal would produce.
//!
//! An argument of the form `<Name>` is a key; anything else is literal text.
//! Key names are case-insensitive and may carry modifiers: `C-` (Ctrl),
//! `M-` or `A-` (Meta/Alt), `S-` (Shift), e.g. `<C-c>`, `<M-x>`, `<S-Tab>`,
//! `<C-Left>`. `<lt>` sends a literal `<`. A whole argument spelled exactly
//! like a key name (`Enter`, `Down`, `C-c`) is that key too.
//!
//! Mouse events are `<Click row,col>`, `<RightClick row,col>`,
//! `<MiddleClick row,col>`, `<Drag r1,c1 r2,c2>`, `<ScrollUp row,col>` and
//! `<ScrollDown row,col>` with 0-based screen coordinates, optionally with
//! modifiers (`<S-Click 1,2>`, `<C-M-ScrollUp 0,0>`). They are only accepted
//! when the program has turned on mouse reporting.

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
    const sp = std.mem.indexOfScalar(u8, inner, ' ') orelse return true;
    // Only mouse events have a space: "<Click 3,4>".
    return mouseEvent(splitMods(inner[0..sp]).name) != null;
}

/// Key names accepted without brackets when they are a whole argument, as
/// agents often write them (`send Down Enter`). Exact spelling only, so text
/// like "enter the name" or "up" is still typed as text.
const bare_names = [_][]const u8{
    "Enter",    "Return", "Tab",    "Esc",   "Escape", "Backspace", "Space",
    "Up",       "Down",   "Left",   "Right", "Home",   "End",       "PageUp",
    "PageDown", "Delete", "Insert", "F1",    "F2",     "F3",        "F4",
    "F5",       "F6",     "F7",     "F8",    "F9",     "F10",       "F11",
    "F12",
};

/// Returns true if `arg` is a key name without brackets: `Enter`, `Down`,
/// `S-Tab`, `C-Left`, or Ctrl/Meta with one character (`C-c`, `M-x`).
pub fn isBareKey(arg: []const u8) bool {
    var name = arg;
    var mods = false;
    while (name.len > 2 and name[1] == '-' and std.mem.indexOfScalar(u8, "CMSA", name[0]) != null) {
        mods = true;
        name = name[2..];
    }
    if (mods and name.len == 1) return (arg[0] == 'C' or arg[0] == 'M') and name[0] > 0x20 and name[0] < 0x7f;
    for (bare_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Appends the encoding of one `send` argument to `out`.
pub fn encodeArg(gpa: Allocator, out: *std.ArrayList(u8), arg: []const u8, ctx: Context) Error!void {
    if (isBareKey(arg)) return encodeKey(gpa, out, arg, ctx.app_cursor);
    if (!isKeySyntax(arg)) return out.appendSlice(gpa, arg);
    const inner = arg[1 .. arg.len - 1];
    if (std.mem.indexOfScalar(u8, inner, ' ')) |sp| return encodeMouse(gpa, out, inner[0..sp], inner[sp + 1 ..], ctx);
    return encodeKey(gpa, out, inner, ctx.app_cursor);
}

const MouseKind = enum { click, drag, scroll };
const MouseEvent = struct { button: u8, kind: MouseKind };

fn mouseEvent(name: []const u8) ?MouseEvent {
    const names = [_]struct { []const u8, MouseEvent }{
        .{ "click", .{ .button = 0, .kind = .click } },
        .{ "middleclick", .{ .button = 1, .kind = .click } },
        .{ "rightclick", .{ .button = 2, .kind = .click } },
        .{ "drag", .{ .button = 0, .kind = .drag } },
        .{ "scrollup", .{ .button = 64, .kind = .scroll } },
        .{ "scrolldown", .{ .button = 65, .kind = .scroll } },
    };
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    for (names) |n| {
        if (std.mem.eql(u8, lower, n[0])) return n[1];
    }
    return null;
}

/// Splits "C-S-Click" into xterm's modifier bits (Shift 4, Meta 8, Ctrl 16)
/// and "Click".
fn splitMods(spec: []const u8) struct { bits: u8, name: []const u8 } {
    var bits: u8 = 0;
    var name = spec;
    while (name.len > 2 and name[1] == '-') {
        switch (std.ascii.toLower(name[0])) {
            's' => bits |= 4,
            'm', 'a' => bits |= 8,
            'c' => bits |= 16,
            else => break,
        }
        name = name[2..];
    }
    return .{ .bits = bits, .name = name };
}

const Pos = struct { row: usize, col: usize };

fn parsePos(text: []const u8) Error!Pos {
    const t = std.mem.trim(u8, text, " ");
    const comma = std.mem.indexOfScalar(u8, t, ',') orelse return error.BadMousePosition;
    return .{
        .row = std.fmt.parseInt(usize, std.mem.trim(u8, t[0..comma], " "), 10) catch return error.BadMousePosition,
        .col = std.fmt.parseInt(usize, std.mem.trim(u8, t[comma + 1 ..], " "), 10) catch return error.BadMousePosition,
    };
}

fn encodeMouse(gpa: Allocator, out: *std.ArrayList(u8), head: []const u8, rest: []const u8, ctx: Context) Error!void {
    const mods = splitMods(head);
    const ev = mouseEvent(mods.name) orelse return error.UnknownKey;
    var from: Pos = undefined;
    var to: Pos = undefined;
    if (ev.kind == .drag) {
        // "<Drag r1,c1 r2,c2>"
        const t = std.mem.trim(u8, rest, " ");
        const sp = std.mem.lastIndexOfScalar(u8, t, ' ') orelse return error.BadMousePosition;
        from = try parsePos(t[0..sp]);
        to = try parsePos(t[sp + 1 ..]);
    } else {
        from = try parsePos(rest);
        to = from;
    }
    if (ctx.mouse_tracking == 0) return error.MouseNotEnabled;
    for ([_]Pos{ from, to }) |p| {
        if (p.row >= ctx.rows or p.col >= ctx.cols) return error.BadMousePosition;
    }

    const code = ev.button | mods.bits;
    try mouseReport(gpa, out, ctx, code, from, false);
    switch (ev.kind) {
        .scroll => {},
        .click => try mouseReport(gpa, out, ctx, code, from, true),
        .drag => {
            // Motion is only reported in button-event (1002) and any-event
            // (1003) modes; it has bit 32 set.
            if (ctx.mouse_tracking == 1002 or ctx.mouse_tracking == 1003) {
                const dr = @as(isize, @intCast(to.row)) - @as(isize, @intCast(from.row));
                const dc = @as(isize, @intCast(to.col)) - @as(isize, @intCast(from.col));
                const steps: isize = @min(@max(@abs(dr), @abs(dc)), 40);
                var last = from;
                var i: isize = 1;
                while (i <= steps) : (i += 1) {
                    const p: Pos = .{
                        .row = @intCast(@as(isize, @intCast(from.row)) + @divTrunc(dr * i, steps)),
                        .col = @intCast(@as(isize, @intCast(from.col)) + @divTrunc(dc * i, steps)),
                    };
                    if (p.row == last.row and p.col == last.col) continue;
                    try mouseReport(gpa, out, ctx, code | 32, p, false);
                    last = p;
                }
            }
            try mouseReport(gpa, out, ctx, code, to, true);
        },
    }
}

/// One mouse report. Coordinates on the wire are 1-based, column first.
fn mouseReport(gpa: Allocator, out: *std.ArrayList(u8), ctx: Context, code: u8, p: Pos, release: bool) Error!void {
    const x = p.col + 1;
    const y = p.row + 1;
    if (ctx.mouse_sgr) {
        return out.print(gpa, "\x1b[<{d};{d};{d}{c}", .{ code, x, y, @as(u8, if (release) 'm' else 'M') });
    }
    // X10 mode (9) reports presses only.
    if (release and ctx.mouse_tracking == 9) return;
    // Legacy encoding: each value + 32 in one byte, so at most 223. A
    // release is button 3, keeping the modifier bits.
    if (x > 223 or y > 223) return error.BadMousePosition;
    const b = if (release) (code & ~@as(u8, 3)) | 3 else code;
    try out.appendSlice(gpa, &.{ 0x1b, '[', 'M', 32 + b, @intCast(32 + x), @intCast(32 + y) });
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

test "bare key names" {
    try expectEncoded("Enter", false, "\r");
    try expectEncoded("Down", false, "\x1b[B");
    try expectEncoded("Down", true, "\x1bOB");
    try expectEncoded("C-c", false, "\x03");
    try expectEncoded("S-Tab", false, "\x1b[Z");
    try expectEncoded("F5", false, "\x1b[15~");
    // Anything else is text.
    try expectEncoded("enter", false, "enter");
    try expectEncoded("up", false, "up");
    try expectEncoded("correct horse", false, "correct horse");
    try expectEncoded("A-1", false, "A-1");
    try expectEncoded("C-", false, "C-");
    try expectEncoded("Y", false, "Y");
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

test "mouse drag and modifiers" {
    const sgr1002: Context = .{ .mouse_tracking = 1002, .mouse_sgr = true, .rows = 24, .cols = 80 };
    try expectEncodedCtx("<Drag 1,1 1,4>", sgr1002, "\x1b[<0;2;2M\x1b[<32;3;2M\x1b[<32;4;2M\x1b[<32;5;2M\x1b[<0;5;2m");
    try expectEncodedCtx("<Drag 0,0 2,1>", sgr1002, "\x1b[<0;1;1M\x1b[<32;1;2M\x1b[<32;2;3M\x1b[<0;2;3m");
    // Mode 1000 reports no motion: press and release only.
    const sgr1000: Context = .{ .mouse_tracking = 1000, .mouse_sgr = true, .rows = 24, .cols = 80 };
    try expectEncodedCtx("<Drag 1,1 1,4>", sgr1000, "\x1b[<0;2;2M\x1b[<0;5;2m");
    try expectEncodedCtx("<S-Click 0,0>", sgr1000, "\x1b[<4;1;1M\x1b[<4;1;1m");
    try expectEncodedCtx("<C-Click 0,0>", sgr1000, "\x1b[<16;1;1M\x1b[<16;1;1m");
    try expectEncodedCtx("<M-RightClick 0,0>", sgr1000, "\x1b[<10;1;1M\x1b[<10;1;1m");
    try expectEncodedCtx("<C-ScrollUp 3,3>", sgr1000, "\x1b[<80;4;4M");
    // Legacy encoding keeps the modifier bits on release (button 3).
    const x11: Context = .{ .mouse_tracking = 1002, .rows = 24, .cols = 80 };
    try expectEncodedCtx("<M-Click 0,0>", x11, "\x1b[M\x28\x21\x21\x1b[M\x2b\x21\x21");
    try expectEncodedCtx("<Drag 0,0 0,1>", x11, "\x1b[M\x20\x21\x21\x1b[M\x40\x22\x21\x1b[M\x23\x22\x21");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.BadMousePosition, encodeArg(testing.allocator, &out, "<Drag 1,1>", sgr1002));
    try testing.expectError(error.BadMousePosition, encodeArg(testing.allocator, &out, "<Drag 1,1 99,1>", sgr1002));
    try testing.expect(isKeySyntax("<C-S-Click 1,2>"));
    try testing.expect(!isKeySyntax("<C-Hello 1,2>"));
}
