//! "Who has what": the one file the business gives, with what its own
//! product knows and the billing provider can't: who is using it, on which
//! plan, with how many seats and how much use this period. CSV with a
//! heading row; the columns are found by name, in any order, and columns
//! it doesn't know are left alone:
//!
//!   customer   the provider's id for the customer (cus_...), or
//!   email      the customer's address there (one of the two is needed)
//!   plan       the plan it has in the product (a name; pay.ini's [plans] says what it costs)
//!   seats      people or units it has
//!   usage      what it used this billing period, in the meter's unit
//!   active     yes or no (default yes): whether it can use the product now
//!
//! An empty cell means "not known", never zero.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Row = struct {
    customer: []const u8 = "",
    email: []const u8 = "",
    plan: []const u8 = "",
    seats: ?i64 = null,
    usage: ?f64 = null,
    active: bool = true,
    /// Its line in the file, from 1 (the heading is line 1).
    line: usize = 0,
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

const Col = enum { customer, email, plan, seats, usage, active };

/// The rows of `text`. On a file that can't be used, `diag` says why and
/// where; nothing is guessed.
pub fn parse(a: Allocator, text_in: []const u8, diag: *Diag) ![]Row {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text = text[3..];
    var lines = Lines{ .text = text };
    const head = (try lines.next(a)) orelse {
        diag.* = .{ .line = 1, .what = "the file is empty: it needs a heading row" };
        return error.BadWho;
    };
    var cols: [64]?Col = @splat(null);
    if (head.len > cols.len) {
        diag.* = .{ .line = 1, .what = "more than 64 columns" };
        return error.BadWho;
    }
    var seen: [6]bool = @splat(false);
    for (head, 0..) |h, i| {
        const name = std.mem.trim(u8, h, " \t");
        var low_buf: [32]u8 = undefined;
        if (name.len > low_buf.len) continue;
        const low = std.ascii.lowerString(low_buf[0..name.len], name);
        const c = std.meta.stringToEnum(Col, low) orelse continue;
        if (seen[@intFromEnum(c)]) {
            diag.* = .{ .line = 1, .what = try std.fmt.allocPrint(a, "two columns are called {s}", .{low}) };
            return error.BadWho;
        }
        seen[@intFromEnum(c)] = true;
        cols[i] = c;
    }
    if (!seen[@intFromEnum(Col.customer)] and !seen[@intFromEnum(Col.email)]) {
        diag.* = .{ .line = 1, .what = "no column called customer or email: one of them says whose row it is" };
        return error.BadWho;
    }
    var out: std.ArrayList(Row) = .empty;
    while (try lines.next(a)) |cells| {
        if (cells.len == 1 and std.mem.trim(u8, cells[0], " \t").len == 0) continue;
        var row: Row = .{ .line = lines.line };
        for (cells, 0..) |cell, i| {
            if (i >= cols.len) break;
            const c = cols[i] orelse continue;
            const v = std.mem.trim(u8, cell, " \t");
            if (v.len == 0) continue;
            switch (c) {
                .customer => row.customer = v,
                .email => row.email = v,
                .plan => row.plan = v,
                .seats => row.seats = std.fmt.parseInt(i64, v, 10) catch {
                    diag.* = .{ .line = lines.line, .what = try std.fmt.allocPrint(a, "seats is \"{s}\": a whole number is expected", .{v}) };
                    return error.BadWho;
                },
                .usage => {
                    const u = std.fmt.parseFloat(f64, v) catch std.math.nan(f64);
                    if (!(u >= 0) or std.math.isInf(u)) {
                        diag.* = .{ .line = lines.line, .what = try std.fmt.allocPrint(a, "usage is \"{s}\": a number, zero or more, is expected", .{v}) };
                        return error.BadWho;
                    }
                    row.usage = u;
                },
                .active => {
                    if (isWord(v, &.{ "yes", "true", "1", "y" })) {
                        row.active = true;
                    } else if (isWord(v, &.{ "no", "false", "0", "n" })) {
                        row.active = false;
                    } else {
                        diag.* = .{ .line = lines.line, .what = try std.fmt.allocPrint(a, "active is \"{s}\": yes or no is expected", .{v}) };
                        return error.BadWho;
                    }
                },
            }
        }
        if (row.customer.len == 0 and row.email.len == 0) {
            diag.* = .{ .line = lines.line, .what = "neither customer nor email is filled in" };
            return error.BadWho;
        }
        if (row.seats) |n| if (n < 0) {
            diag.* = .{ .line = lines.line, .what = "seats is below zero" };
            return error.BadWho;
        };
        try out.append(a, row);
    }
    return out.items;
}

fn isWord(v: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.eqlIgnoreCase(v, w)) return true;
    return false;
}

/// CSV lines: commas, cells in double quotes (a quote inside is doubled, a
/// line end inside is kept), CRLF or LF.
const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    line: usize = 0,
    next_line: usize = 1,

    fn next(l: *Lines, a: Allocator) !?[][]const u8 {
        if (l.pos >= l.text.len) return null;
        l.line = l.next_line;
        var cells: std.ArrayList([]const u8) = .empty;
        var cell: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (l.pos < l.text.len) {
            const ch = l.text[l.pos];
            l.pos += 1;
            if (quoted) {
                if (ch == '"') {
                    if (l.pos < l.text.len and l.text[l.pos] == '"') {
                        try cell.append(a, '"');
                        l.pos += 1;
                    } else quoted = false;
                } else {
                    if (ch == '\n') l.next_line += 1;
                    try cell.append(a, ch);
                }
                continue;
            }
            switch (ch) {
                '"' => quoted = true,
                ',' => {
                    try cells.append(a, cell.items);
                    cell = .empty;
                },
                '\r' => {},
                '\n' => {
                    l.next_line += 1;
                    try cells.append(a, cell.items);
                    return cells.items;
                },
                else => try cell.append(a, ch),
            }
        }
        try cells.append(a, cell.items);
        return cells.items;
    }
};

const t = std.testing;

test "the_columns_are_found_by_name_and_an_empty_cell_is_not_zero" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const rows = try parse(a, "\xef\xbb\xbfNotes,Seats,customer,PLAN,usage,active,email\r\n\"big, old one\",12,cus_1,team,,yes,\r\n,,,pro,1530.5,no,ola@example.com\n\n,3,cus_3,,,,\n", &d);
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqualStrings("cus_1", rows[0].customer);
    try t.expectEqualStrings("team", rows[0].plan);
    try t.expectEqual(@as(?i64, 12), rows[0].seats);
    try t.expect(rows[0].usage == null and rows[0].active);
    try t.expectEqual(@as(usize, 2), rows[0].line);
    try t.expectEqualStrings("ola@example.com", rows[1].email);
    try t.expect(rows[1].seats == null and !rows[1].active);
    try t.expectEqual(@as(?f64, 1530.5), rows[1].usage);
    try t.expectEqual(@as(usize, 5), rows[2].line);
    try t.expectEqual(@as(?i64, 3), rows[2].seats);
}

test "a_file_that_cant_be_used_says_where_and_why" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    try t.expectError(error.BadWho, parse(a, "", &d));
    try t.expectError(error.BadWho, parse(a, "plan,seats\npro,2\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "customer or email") != null);
    try t.expectError(error.BadWho, parse(a, "customer,seats\ncus_1,many\n", &d));
    try t.expectEqual(@as(usize, 2), d.line);
    try t.expectError(error.BadWho, parse(a, "customer,usage\ncus_1,-4\n", &d));
    try t.expectError(error.BadWho, parse(a, "customer,active\ncus_1,maybe\n", &d));
    try t.expectError(error.BadWho, parse(a, "customer,plan\n,pro\n", &d));
    try t.expectError(error.BadWho, parse(a, "customer,customer\ncus_1,cus_2\n", &d));
    // a quoted cell may hold a comma, a quote and a line end
    const rows = try parse(a, "customer,plan\ncus_1,\"the \"\"big\"\"\nplan, yearly\"\ncus_2,pro\n", &d);
    try t.expectEqualStrings("the \"big\"\nplan, yearly", rows[0].plan);
    try t.expectEqual(@as(usize, 4), rows[1].line);
}
