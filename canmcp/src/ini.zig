//! A small INI reader: `[section]` or `[section name]`, `key = value`,
//! comments after `;` or `#` at the start of a line or after a space.
const std = @import("std");

pub const Entry = struct {
    section: []const u8,
    name: []const u8,
    key: []const u8,
    value: []const u8,
    line: usize,
};

/// The entries in order. On a malformed line, `bad_line` says which.
pub fn parse(a: std.mem.Allocator, text: []const u8, bad_line: *usize) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var section: []const u8 = "";
    var name: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') {
                bad_line.* = n;
                return error.BadIni;
            }
            const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.indexOfAny(u8, inner, " \t")) |sp| {
                section = inner[0..sp];
                name = std.mem.trim(u8, inner[sp + 1 ..], " \t");
            } else {
                section = inner;
                name = "";
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            bad_line.* = n;
            return error.BadIni;
        };
        try out.append(a, .{
            .section = section,
            .name = name,
            .key = std.mem.trim(u8, line[0..eq], " \t"),
            .value = std.mem.trim(u8, line[eq + 1 ..], " \t"),
            .line = n,
        });
    }
    return out.items;
}

fn stripComment(s: []const u8) []const u8 {
    for (s, 0..) |ch, i| {
        if ((ch == ';' or ch == '#') and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) return s[0..i];
    }
    return s;
}

test "sections with names, values, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    const e = try parse(arena.allocator(), "; top\n[car]\nname = A car ; trailing\n[bus party]\ndbc=x#y.dbc\n", &bad);
    try std.testing.expectEqual(2, e.len);
    try std.testing.expectEqualStrings("A car", e[0].value);
    try std.testing.expectEqualStrings("bus", e[1].section);
    try std.testing.expectEqualStrings("party", e[1].name);
    try std.testing.expectEqualStrings("x#y.dbc", e[1].value);
    try std.testing.expectError(error.BadIni, parse(arena.allocator(), "[car]\nno equals here\n", &bad));
    try std.testing.expectEqual(2, bad);
}
