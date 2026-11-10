//! Notes for screens where rows of a list differ only in style. Checkbox
//! lists often mark the selected items by the color of the same glyph, and
//! the focused item by an underline or by not being dim, which plain text
//! doesn't show. Each note is one line and states what differs, nothing more.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vt = @import("vt.zig");
const server = @import("server.zig");

const max_label_col = 64;
const max_label_bytes = 40;
/// Mark notes name the labels of lists up to this long; longer ones give
/// row numbers only.
const max_named_rows = 10;

/// What a row looks like as a list item: marks, then a label.
const Item = struct {
    /// Column of the first letter or digit.
    label_col: usize,
    label_style: vt.Style,
    /// Bit c set: column c, left of the label, is not blank.
    shape: u64,
    /// The last non-blank cell left of the label.
    mark_col: usize,
    mark: u21,
    mark_style: vt.Style,
};

fn isLetterOrDigit(cp: u21) bool {
    return switch (cp) {
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F => true, // Latin
        0x370...0x3FF, 0x400...0x52F => true, // Greek, Cyrillic
        0x5D0...0x5EA, 0x620...0x64A => true, // Hebrew, Arabic
        0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF => true, // CJK
        else => false,
    };
}

fn isBoxDrawing(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

/// The reported attributes; underline color is not one of them.
fn shown(st: vt.Style) vt.Style {
    var x = st;
    x.underline_color = .default;
    return x;
}

fn item(cells: []const vt.Cell) ?Item {
    var shape: u64 = 0;
    var mark_col: ?usize = null;
    for (cells, 0..) |cell, c| {
        if (cell.width == 0 or cell.cp == ' ') continue;
        if (isLetterOrDigit(cell.cp)) {
            const mc = mark_col orelse return null;
            return .{
                .label_col = c,
                .label_style = shown(cell.style),
                .shape = shape,
                .mark_col = mc,
                .mark = cells[mc].cp,
                .mark_style = shown(cells[mc].style),
            };
        }
        if (c >= max_label_col) return null;
        shape |= @as(u64, 1) << @intCast(c);
        mark_col = c;
    }
    return null;
}

fn sameStyle(a: vt.Style, b: vt.Style) bool {
    return std.meta.eql(a, b);
}

/// "underline fg=cyan", or "plain" for the default style.
fn writeStyle(w: *std.Io.Writer, st: vt.Style) !void {
    var attr_buf: [9][]const u8 = undefined;
    var n: usize = 0;
    for (server.styleAttrs(st, &attr_buf)) |a| {
        if (n > 0) try w.writeByte(' ');
        try w.writeAll(a);
        n += 1;
    }
    var buf: [16]u8 = undefined;
    if (server.colorName(&buf, st.fg)) |c| {
        if (n > 0) try w.writeByte(' ');
        try w.print("fg={s}", .{c});
        n += 1;
    }
    if (server.colorName(&buf, st.bg)) |c| {
        if (n > 0) try w.writeByte(' ');
        try w.print("bg={s}", .{c});
        n += 1;
    }
    if (n == 0) try w.writeAll("plain");
}

/// "3-5,8" for rows 3, 4, 5 and 8 (`first` is the row of `members[0]`).
fn writeRows(w: *std.Io.Writer, first: usize, members: []const bool) !void {
    var any = false;
    var i: usize = 0;
    while (i < members.len) {
        if (!members[i]) {
            i += 1;
            continue;
        }
        var j = i;
        while (j + 1 < members.len and members[j + 1]) j += 1;
        if (any) try w.writeByte(',');
        any = true;
        if (j == i) {
            try w.print("{d}", .{first + i});
        } else if (j == i + 1) {
            try w.print("{d},{d}", .{ first + i, first + j });
        } else {
            try w.print("{d}-{d}", .{ first + i, first + j });
        }
        i = j + 1;
    }
}

/// The label's text: cells from the label on that share its style, up to a
/// gap of two blanks.
fn labelText(arena: Allocator, cells: []const vt.Cell, it: Item) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var blanks: usize = 0;
    for (cells[it.label_col..]) |cell| {
        if (cell.width == 0) continue;
        if (cell.cp == ' ') {
            blanks += 1;
            if (blanks == 2) break;
        } else {
            if (!sameStyle(shown(cell.style), it.label_style)) break;
            blanks = 0;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
        if (out.items.len + n > max_label_bytes) break;
        try out.appendSlice(arena, buf[0..n]);
    }
    return std.mem.trimRight(u8, out.items, " ");
}

/// Writes the notes for `rows` (the screen's rows, top to bottom).
/// `focus_notes`: also name a row whose label is styled unlike its
/// neighbours. Callers pass it when the program has hidden the cursor, which
/// is when a program draws its own focus; on ordinary output (logs, diffs)
/// such a row means nothing.
pub fn write(w: *std.Io.Writer, arena: Allocator, rows: []const []const vt.Cell, focus_notes: bool) !void {
    const items = try arena.alloc(?Item, rows.len);
    for (rows, items) |cells, *it| it.* = item(cells);
    try writeMarkNotes(w, arena, rows, items);
    if (focus_notes) try writeFocusNotes(w, arena, rows, items);
}

/// Consecutive rows with the same mark in the same place, styled in two or
/// three ways:
/// `"✔" differs in style: rows 3,4 dim ("ESLint", "Vitest"); row 5 fg=green ("Prettier")`.
fn writeMarkNotes(w: *std.Io.Writer, arena: Allocator, rows: []const []const vt.Cell, items: []const ?Item) !void {
    const max_notes = 2;
    var notes: usize = 0;
    var start: usize = 0;
    while (start < items.len and notes < max_notes) {
        const first = items[start] orelse {
            start += 1;
            continue;
        };
        var end = start + 1;
        while (end < items.len) : (end += 1) {
            const it = items[end] orelse break;
            if (it.mark != first.mark or it.mark_col != first.mark_col or it.label_col != first.label_col) break;
        }
        defer start = end;
        if (end - start < 2 or isBoxDrawing(first.mark)) continue;

        var styles: [3]vt.Style = undefined;
        var n: usize = 0;
        const group = try arena.alloc(u8, end - start);
        var too_many = false;
        for (items[start..end], group) |it, *g| {
            const st = it.?.mark_style;
            for (styles[0..n], 0..) |s, i| {
                if (sameStyle(s, st)) {
                    g.* = @intCast(i);
                    break;
                }
            } else if (n < styles.len) {
                styles[n] = st;
                g.* = @intCast(n);
                n += 1;
            } else {
                too_many = true;
                break;
            }
        }
        if (too_many or n < 2) continue;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(first.mark, &buf) catch continue;
        try w.writeAll("[headterm] ");
        try std.json.Stringify.encodeJsonString(buf[0..len], .{}, w);
        try w.writeAll(" differs in style: ");
        const members = try arena.alloc(bool, end - start);
        for (styles[0..n], 0..) |st, i| {
            for (group, members) |g, *m| m.* = g == i;
            if (i > 0) try w.writeAll("; ");
            const many = std.mem.count(bool, members, &.{true}) > 1;
            try w.writeAll(if (many) "rows " else "row ");
            try writeRows(w, start, members);
            try w.writeByte(' ');
            try writeStyle(w, st);
            if (end - start > max_named_rows) continue;
            var named: usize = 0;
            for (members, start..) |m, r| {
                if (!m) continue;
                try w.writeAll(if (named == 0) " (" else ", ");
                try std.json.Stringify.encodeJsonString(try labelText(arena, rows[r], items[r].?), .{}, w);
                named += 1;
            }
            if (named > 0) try w.writeByte(')');
        }
        try w.writeByte('\n');
        notes += 1;
    }
}

/// Three or more consecutive rows of the same shape where one or two labels
/// have a style of their own:
/// `styled unlike the rows around it: row 4 "ESLint" (underline; others plain)`.
fn writeFocusNotes(w: *std.Io.Writer, arena: Allocator, rows: []const []const vt.Cell, items: []const ?Item) !void {
    const max_shown = 3;
    var shown_n: usize = 0;
    var start: usize = 0;
    while (start < items.len and shown_n < max_shown) {
        const first = items[start] orelse {
            start += 1;
            continue;
        };
        var end = start + 1;
        while (end < items.len) : (end += 1) {
            const it = items[end] orelse break;
            if (it.label_col != first.label_col or it.shape != first.shape) break;
        }
        defer start = end;
        const block = items[start..end];
        if (block.len < 3) continue;

        // How many rows share each row's label style, and the commonest.
        const counts = try arena.alloc(usize, block.len);
        var usual: usize = 0;
        for (block, counts) |a, *n| {
            n.* = 0;
            for (block) |b| {
                if (sameStyle(a.?.label_style, b.?.label_style)) n.* += 1;
            }
        }
        var alone: usize = 0;
        for (counts, 0..) |n, i| {
            if (n > counts[usual]) usual = i;
            if (n == 1) alone += 1;
        }
        if (counts[usual] < 2 or alone == 0 or alone > 2) continue;

        for (block, counts, start..) |it, n, r| {
            if (n != 1 or shown_n == max_shown) continue;
            // A heading above a list ("? Features" over "✔ TypeScript") has
            // the list's shape but not one of its marks.
            if (r == start) {
                for (block) |other| {
                    if (sameStyle(other.?.label_style, block[usual].?.label_style) and other.?.mark == it.?.mark) break;
                } else continue;
            }
            try w.writeAll(if (shown_n == 0) "[headterm] styled unlike the rows around it: " else "; ");
            try w.print("row {d} ", .{r});
            try std.json.Stringify.encodeJsonString(try labelText(arena, rows[r], it.?), .{}, w);
            try w.writeAll(" (");
            try writeStyle(w, it.?.label_style);
            try w.writeAll("; others ");
            try writeStyle(w, block[usual].?.label_style);
            try w.writeByte(')');
            shown_n += 1;
        }
    }
    if (shown_n > 0) try w.writeByte('\n');
}

// ----------------------------------------------------------------------

const testing = std.testing;

fn expectNotes(feed: []const u8, focus_notes: bool, expected: []const u8) !void {
    var t = try vt.Terminal.init(testing.allocator, .{ .cols = 60, .rows = 12 });
    defer t.deinit();
    try t.feed(feed);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try arena.alloc([]const vt.Cell, t.rows);
    for (rows, 0..) |*r, i| r.* = t.rowCells(i);
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&out.writer, arena, rows, focus_notes);
    try testing.expectEqualStrings(expected, out.written());
}

test "the same mark in two styles, and a label styled on its own" {
    // enquirer's multiselect: every row has a check mark; green means
    // selected, and the focused label is underlined.
    const screen = "\x1b[36m?\x1b[m \x1b[1mFeatures\x1b[m\r\n" ++
        "\x1b[2;90m\xe2\x9c\x94\x1b[m TypeScript\r\n" ++
        "\x1b[2;90m\xe2\x9c\x94\x1b[m \x1b[4;36mESLint\x1b[m\r\n" ++
        "\x1b[32m\xe2\x9c\x94\x1b[m Vitest\r\n" ++
        "\x1b[32m\xe2\x9c\x94\x1b[m Prettier\r\n" ++
        "\x1b[2;90m\xe2\x9c\x94\x1b[m Playwright";
    try expectNotes(screen, true,
        \\[headterm] "✔" differs in style: rows 1,2,5 dim fg=bright-black ("TypeScript", "ESLint", "Playwright"); rows 3,4 fg=green ("Vitest", "Prettier")
        \\[headterm] styled unlike the rows around it: row 2 "ESLint" (underline fg=cyan; others plain)
        \\
    );
    try expectNotes(screen, false,
        \\[headterm] "✔" differs in style: rows 1,2,5 dim fg=bright-black ("TypeScript", "ESLint", "Playwright"); rows 3,4 fg=green ("Vitest", "Prettier")
        \\
    );
}

test "a plain label among dim ones, behind a border" {
    // clack: the focused label is the one that is not dim.
    try expectNotes("\x1b[36m\xe2\x94\x82\x1b[m  \x1b[2m\xe2\x97\xbb TypeScript\x1b[m\r\n" ++
        "\x1b[36m\xe2\x94\x82\x1b[m  \x1b[36m\xe2\x97\xbb\x1b[m ESLint\r\n" ++
        "\x1b[36m\xe2\x94\x82\x1b[m  \x1b[2m\xe2\x97\xbb Tailwind\x1b[m\r\n" ++
        "\x1b[36m\xe2\x94\x82\x1b[m  \x1b[32m\xe2\x97\xbc\x1b[m \x1b[2mVitest\x1b[m", true,
        \\[headterm] "◻" differs in style: rows 0,2 dim ("TypeScript", "Tailwind"); row 1 fg=cyan ("ESLint")
        \\[headterm] styled unlike the rows around it: row 1 "ESLint" (plain; others dim)
        \\
    );
}

test "no notes for plain lists, different marks, or many styles" {
    // Marks that differ already say what is selected.
    try expectNotes("( ) one\r\n(*) two\r\n( ) three", true, "");
    // Rows without a mark left of the label are not list items.
    try expectNotes("one\r\n\x1b[1mtwo\x1b[m\r\nthree", true, "");
    // Two rows don't show which style is the unusual one.
    try expectNotes("- one\r\n- \x1b[1mtwo\x1b[m", true, "");
    // Every row in its own color is decoration.
    try expectNotes("\x1b[31m*\x1b[m a\r\n\x1b[32m*\x1b[m b\r\n\x1b[33m*\x1b[m c\r\n\x1b[34m*\x1b[m d", true, "");
    // A heading over a list isn't the focused item.
    try expectNotes("? \x1b[1mPick\x1b[m\r\n- one\r\n- two\r\n- three", true, "");
    // Three labels with a style of their own: not a focus.
    try expectNotes("- \x1b[31ma\x1b[m\r\n- \x1b[32mb\x1b[m\r\n- \x1b[33mc\x1b[m\r\n- d\r\n- e", true, "");
}

test "a long list gets row numbers only" {
    var feed: std.ArrayList(u8) = .empty;
    defer feed.deinit(testing.allocator);
    for (0..11) |i| {
        if (i > 0) try feed.appendSlice(testing.allocator, "\r\n");
        try feed.appendSlice(testing.allocator, if (i == 4) "\x1b[32m*\x1b[m item" else "\x1b[2m*\x1b[m item");
    }
    try expectNotes(feed.items, false,
        \\[headterm] "*" differs in style: rows 0-3,5-10 dim; row 4 fg=green
        \\
    );
}

test "row lists" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeRows(&out.writer, 3, &.{ true, true, true, false, true, false, true, true });
    try testing.expectEqualStrings("3-5,7,9,10", out.written());
}
