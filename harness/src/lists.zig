//! Shared lists (`shopping` by default): a file each in `state/lists/`, a
//! line an item, written whole. The owner and the household's members add
//! and take things off by message ("add milk", "we're out of coffee"),
//! read here by harness itself, never by a model. Who may do what, and
//! where it is said, is harness's (core.zig): this file never posts or logs.
const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_list = "shopping";
pub const max_name = 32;
pub const max_lists = 20;
pub const max_items = 200;
/// One item, at most (bytes).
pub const max_item = 80;

/// The words `/list` takes after it: never a list's name.
const command_words = [_][]const u8{ "add", "rm", "clear", "every", "all" };

/// a-z, 0-9, `-` and `_`, up to 32; not a word `/list` takes.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    for (command_words) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

/// What a message asks of the lists.
pub const Words = union(enum) {
    add: Change,
    /// Said to take off ("remove milk from the list"): answered even when
    /// it isn't there.
    remove: Change,
    /// "got milk", "bought eggs", a bare "remove X": only when X is on a
    /// list; else the message is not about lists.
    got: Change,
    /// A list to read ("" the default, or all when there are several).
    show: []const u8,
};

/// Items, and the list they go to or come from ("": the default).
pub const Change = struct { list: []const u8 = "", items: []const []const u8 = &.{} };

/// Words that make a bare "add X" someone else's (the model's): a
/// reminder, a meeting, a routine, a device are not groceries.
const not_items = [_][]const u8{ "reminder", "meeting", "event", "appointment", "calendar", "alarm", "timer", "routine", "trigger", "task", "workflow", "member", "rule", "note", "contact", "birthday", "file", "folder", "topic", "brief", "light", "lights", "heating" };

/// Read the list: whole messages.
const show_words = [_][]const u8{
    "list",              "lists",              "the list",          "the lists",
    "my list",           "our list",           "show list",         "show the list",
    "show me the list",  "what's on the list", "whats on the list", "what is on the list",
    "what's on my list", "what's on our list", "lista",
    "listę",
    "pokaż listę",
    "co jest na liście",
    "co na liście",
    "lista zakupów",
};

/// Polite words in front: "please add milk", "can you add milk".
const polite = [_][]const u8{ "please ", "pls ", "can you ", "could you ", "would you ", "can you please ", "could you please ", "proszę " };

/// "we're out of X": the list's word for what is gone.
const out_of = [_][]const u8{ "we're out of ", "we are out of ", "we're all out of ", "we are all out of ", "we ran out of ", "we've run out of ", "we have run out of ", "skończył się ", "skończyła się ", "skończyło się ", "skończyły się ", "brakuje " };

/// "got X": taken off when X is on a list.
const got_words = [_][]const u8{ "got ", "bought ", "we got ", "i got ", "we bought ", "i bought ", "remove ", "delete ", "usuń " };

/// What starts a word of an item and goes: "some milk", "the milk".
const articles = [_][]const u8{ "a ", "an ", "some ", "more ", "the ", "any ", "of " };

fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}

/// The text as matched: ASCII lower case, the typographic apostrophe as
/// `'`; `orig` the same with its case (both the same length).
const Text = struct { orig: []const u8, low: []const u8 };

fn normal(a: Allocator, text: []const u8) !Text {
    const orig = try std.mem.replaceOwned(u8, a, text, "\u{2019}", "'");
    const low = try a.dupe(u8, orig);
    for (low) |*ch| ch.* = std.ascii.toLower(ch.*);
    return .{ .orig = orig, .low = low };
}

/// `t` from `from` to `to`.
fn slice(x: Text, from: usize, to: usize) Text {
    return .{ .orig = x.orig[from..to], .low = x.low[from..to] };
}

/// A list's name as written in a message ("the hardware", "big shop"):
/// lower case, spaces as `-`; null when that isn't a name.
fn nameOf(a: Allocator, words: []const u8) !?[]const u8 {
    var w = std.mem.trim(u8, words, " ");
    for ([_][]const u8{ "the", "my", "our" }) |p| {
        if (std.mem.eql(u8, w, p)) return "";
        if (startsWith(w, p) and w.len > p.len and w[p.len] == ' ') w = std.mem.trim(u8, w[p.len..], " ");
    }
    if (w.len == 0) return "";
    const out = try a.dupe(u8, w);
    for (out) |*ch| if (ch.* == ' ') {
        ch.* = '-';
    };
    return if (validName(out)) out else null;
}

/// Where the items end and which list a suffix names ("to the hardware
/// list", "to shopping", "do listy"); null: no list named.
const Suffix = struct { at: usize, list: []const u8 };

fn listSuffix(a: Allocator, low: []const u8, joiners: []const []const u8, known: []const []const u8) !?Suffix {
    for (joiners) |j| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, low, from, j)) |at| : (from = at + 1) {
            const rest = std.mem.trim(u8, low[at + j.len ..], " ");
            // "… the hardware list", "… my list", "… list"
            if (std.mem.endsWith(u8, rest, "list")) {
                const before = std.mem.trim(u8, rest[0 .. rest.len - "list".len], " ");
                if (try nameOf(a, before)) |n| return .{ .at = at, .list = n };
                continue;
            }
            // "… shopping", "… hardware": a list there is
            if (try nameOf(a, rest)) |n| {
                if (std.mem.eql(u8, n, default_list)) return .{ .at = at, .list = n };
                for (known) |k| if (std.mem.eql(u8, k, n)) return .{ .at = at, .list = n };
            }
        }
    }
    return null;
}

/// The Polish suffixes: "do listy", "do zakupów", "z listy".
const pl_suffixes = [_][]const u8{ " do listy zakupów", " do listy", " do zakupów", " z listy zakupów", " z listy" };

fn plSuffix(low: []const u8) ?usize {
    for (pl_suffixes) |sfx| if (std.mem.endsWith(u8, low, sfx)) return low.len - sfx.len;
    return null;
}

/// The items of `x`: split at commas and "and" ("i", "oraz"), each
/// trimmed, an article in front taken off, one line, at most `max_item`.
fn itemsOf(a: Allocator, x: Text) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var start: usize = 0;
    const seps = [_][]const u8{ ", ", ",", " and ", " & ", " i ", " oraz ", " + " };
    while (i <= x.low.len) {
        var sep_len: usize = 0;
        if (i < x.low.len) for (seps) |sp| if (startsWith(x.low[i..], sp)) {
            sep_len = sp.len;
            break;
        };
        if (i == x.low.len or sep_len > 0) {
            const item = try cleanItem(a, slice(x, start, i));
            if (item.len > 0) try out.append(a, item);
            if (i == x.low.len) break;
            i += sep_len;
            start = i;
            continue;
        }
        i += 1;
    }
    return out.items;
}

fn cleanItem(a: Allocator, x_in: Text) ![]const u8 {
    var x = x_in;
    while (true) {
        const tl = std.mem.trim(u8, x.low, " \t\"'");
        const lead = std.mem.indexOf(u8, x.low, tl) orelse 0;
        x = slice(x, lead, lead + tl.len);
        var again = false;
        for (articles) |art| if (startsWith(x.low, art) and x.low.len > art.len) {
            x = slice(x, art.len, x.low.len);
            again = true;
            break;
        };
        if (!again) break;
    }
    return clean(a, x.orig);
}

/// An item as kept: one line, spaces collapsed, no `#` in front, at most
/// `max_item` bytes.
fn clean(a: Allocator, item: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var space = false;
    for (item) |ch| {
        const sp = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
        if (sp) {
            space = o.items.len > 0;
            continue;
        }
        if (space) try o.append(a, ' ');
        space = false;
        try o.append(a, ch);
    }
    var s = std.mem.trim(u8, o.items, " .!;:");
    while (s.len > 0 and s[0] == '#') s = std.mem.trimStart(u8, s[1..], " ");
    return util.cut(s, max_item);
}

/// Whether `items` (the text a bare "add" took) may be a list's: short, no
/// time, no "to", none of the words of other things.
fn plainItems(low: []const u8) bool {
    if (low.len == 0 or low.len > 60) return false;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, low, ' ');
    while (it.next()) |w| {
        n += 1;
        if (std.mem.eql(u8, w, "to")) return false;
        const word = std.mem.trim(u8, w, ",.!;:");
        for (not_items) |x| if (std.mem.eql(u8, word, x)) return false;
    }
    if (n > 6) return false;
    // a time: 9:30
    for (low, 0..) |ch, i| if (ch == ':' and i > 0 and i + 1 < low.len and std.ascii.isDigit(low[i - 1]) and std.ascii.isDigit(low[i + 1])) return false;
    return true;
}

/// The list words in `text`, null when it isn't about lists; `known`: the
/// lists there are (a list named without "list" must be one of them).
pub fn read(a: Allocator, text: []const u8, known: []const []const u8) !?Words {
    var x = try normal(a, std.mem.trim(u8, text, " \t\r\n"));
    var question = false;
    while (x.low.len > 0 and std.mem.indexOfScalar(u8, ".!?", x.low[x.low.len - 1]) != null) {
        if (x.low[x.low.len - 1] == '?') question = true;
        x = slice(x, 0, x.low.len - 1);
    }
    for (polite) |p| if (startsWith(x.low, p)) {
        x = slice(x, p.len, x.low.len);
    };
    for ([_][]const u8{ " please", ", please", " proszę" }) |p| if (std.mem.endsWith(u8, x.low, p)) {
        x = slice(x, 0, x.low.len - p.len);
    };
    x = slice(x, 0, std.mem.trimEnd(u8, x.low, " ").len);
    if (x.low.len == 0) return null;
    // reading a list
    for (show_words) |w| if (std.mem.eql(u8, x.low, w)) return .{ .show = "" };
    if (std.mem.endsWith(u8, x.low, " list")) {
        var head = x.low[0 .. x.low.len - " list".len];
        for ([_][]const u8{ "what's on the ", "whats on the ", "what is on the ", "show the ", "show me the ", "show ", "the " }) |p| if (startsWith(head, p)) {
            head = head[p.len..];
            break;
        };
        if (try nameOf(a, head)) |n| if (n.len > 0) {
            if (std.mem.eql(u8, n, default_list)) return .{ .show = n };
            for (known) |k| if (std.mem.eql(u8, k, n)) return .{ .show = n };
        };
    }
    // adding: "add X [to the … list]", "dodaj X [do listy]", "put X on the … list"
    for ([_][]const u8{ "add ", "dodaj " }) |verb| if (startsWith(x.low, verb)) {
        const body = slice(x, verb.len, x.low.len);
        if (plSuffix(body.low)) |end| return .{ .add = .{ .items = try itemsOf(a, slice(body, 0, end)) } };
        if (try listSuffix(a, body.low, &.{" to "}, known)) |sf| {
            const items = try itemsOf(a, slice(body, 0, sf.at));
            if (items.len == 0) return null;
            return .{ .add = .{ .list = sf.list, .items = items } };
        }
        if (question or !plainItems(body.low)) return null;
        const items = try itemsOf(a, body);
        if (items.len == 0) return null;
        return .{ .add = .{ .items = items } };
    };
    if (startsWith(x.low, "put ")) {
        const body = slice(x, "put ".len, x.low.len);
        if (try listSuffix(a, body.low, &.{" on "}, known)) |sf| {
            const items = try itemsOf(a, slice(body, 0, sf.at));
            if (items.len > 0) return .{ .add = .{ .list = sf.list, .items = items } };
        }
        return null;
    }
    for (out_of) |p| if (startsWith(x.low, p)) {
        const body = slice(x, p.len, x.low.len);
        if (question or body.low.len > 60) return null;
        const items = try itemsOf(a, body);
        if (items.len == 0) return null;
        return .{ .add = .{ .items = items } };
    };
    // taking off: "remove X from the … list", "take X off [the list]",
    // "cross X off", "usuń X z listy"
    for ([_][]const u8{ "remove ", "delete ", "usuń " }) |verb| if (startsWith(x.low, verb)) {
        const body = slice(x, verb.len, x.low.len);
        if (plSuffix(body.low)) |end| return .{ .remove = .{ .items = try itemsOf(a, slice(body, 0, end)) } };
        if (try listSuffix(a, body.low, &.{" from "}, known)) |sf| {
            const items = try itemsOf(a, slice(body, 0, sf.at));
            if (items.len > 0) return .{ .remove = .{ .list = sf.list, .items = items } };
        }
    };
    for ([_][]const u8{ "take ", "cross " }) |verb| if (startsWith(x.low, verb)) {
        const body = slice(x, verb.len, x.low.len);
        if (try listSuffix(a, body.low, &.{" off "}, known)) |sf| {
            const items = try itemsOf(a, slice(body, 0, sf.at));
            if (items.len > 0) return .{ .remove = .{ .list = sf.list, .items = items } };
        }
        if (std.mem.endsWith(u8, body.low, " off")) {
            const items = try itemsOf(a, slice(body, 0, body.low.len - " off".len));
            if (items.len > 0) return .{ .remove = .{ .items = items } };
        }
        return null;
    };
    if (question) return null;
    for (got_words) |p| if (startsWith(x.low, p)) {
        const body = slice(x, p.len, x.low.len);
        if (body.low.len > 60) return null;
        const items = try itemsOf(a, body);
        if (items.len == 0) return null;
        return .{ .got = .{ .items = items } };
    };
    return null;
}

/// The lists: `state/lists/NAME`, one item a line. Each call takes the
/// mutex.
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dir: []const u8,
    mutex: Io.Mutex = .init,

    pub fn init(gpa: Allocator, io: Io, dir: []const u8) Store {
        return .{ .gpa = gpa, .io = io, .dir = dir };
    }

    fn path(s: *Store, a: Allocator, name: []const u8) ![]const u8 {
        if (!validName(name)) return error.BadName;
        return std.fs.path.join(a, &.{ s.dir, name });
    }

    fn readItems(s: *Store, a: Allocator, name: []const u8) ![]const []const u8 {
        const p = try s.path(a, name);
        const text = Io.Dir.cwd().readFileAlloc(s.io, p, a, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0 or l[0] == '#') continue;
            try out.append(a, l);
        }
        return out.items;
    }

    fn writeItems(s: *Store, a: Allocator, name: []const u8, list: []const []const u8) !void {
        try Io.Dir.cwd().createDirPath(s.io, s.dir);
        var o: std.ArrayList(u8) = .empty;
        try o.print(a, "# The {s} list: one thing a line (harness reads it as it is).\n", .{name});
        for (list) |x| try o.print(a, "{s}\n", .{x});
        try util.writeReplace(s.io, try s.path(a, name), o.items);
    }

    fn exists(s: *Store, a: Allocator, name: []const u8) bool {
        const p = s.path(a, name) catch return false;
        _ = Io.Dir.cwd().statFile(s.io, p, .{}) catch return false;
        return true;
    }

    /// The items of list `name` (none when it has no file).
    pub fn items(s: *Store, a: Allocator, name: []const u8) ![]const []const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.readItems(a, name);
    }

    fn listNames(s: *Store, a: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var d = Io.Dir.cwd().openDir(s.io, s.dir, .{ .iterate = true }) catch return out.items;
        defer d.close(s.io);
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file or !validName(e.name)) continue;
            try out.append(a, try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                const dx = std.mem.eql(u8, x, default_list);
                const dy = std.mem.eql(u8, y, default_list);
                if (dx != dy) return dx;
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        return out.items;
    }

    /// The lists with a file, the default first, then by name.
    pub fn names(s: *Store, a: Allocator) ![]const []const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.listNames(a);
    }

    pub const Added = struct { added: []const []const u8 = &.{}, already: []const []const u8 = &.{}, before: usize = 0, count: usize = 0, full: bool = false };

    /// Adds `new` to list `name` (made when it has no file); an item there
    /// already (case aside) is not added again.
    pub fn add(s: *Store, a: Allocator, name: []const u8, new: []const []const u8) !Added {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        _ = try s.path(a, name);
        if (!s.exists(a, name) and (try s.listNames(a)).len >= max_lists) return error.TooManyLists;
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(a, try s.readItems(a, name));
        var got: Added = .{ .before = list.items.len };
        var added: std.ArrayList([]const u8) = .empty;
        var already: std.ArrayList([]const u8) = .empty;
        for (new) |raw| {
            const item = try clean(a, raw);
            if (item.len == 0) continue;
            const there = for (list.items) |x| {
                if (std.ascii.eqlIgnoreCase(x, item)) break x;
            } else null;
            if (there) |x| {
                try already.append(a, x);
                continue;
            }
            if (list.items.len >= max_items) {
                got.full = true;
                continue;
            }
            try list.append(a, item);
            try added.append(a, item);
        }
        if (added.items.len > 0 or !s.exists(a, name)) try s.writeItems(a, name, list.items);
        got.added = added.items;
        got.already = already.items;
        got.count = list.items.len;
        return got;
    }

    pub const Removed = struct { removed: []const []const u8 = &.{}, missing: []const []const u8 = &.{}, count: usize = 0 };

    /// Takes `which` off list `name` (case aside).
    pub fn remove(s: *Store, a: Allocator, name: []const u8, which: []const []const u8) !Removed {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(a, try s.readItems(a, name));
        var removed: std.ArrayList([]const u8) = .empty;
        var missing: std.ArrayList([]const u8) = .empty;
        for (which) |w| {
            const i = for (list.items, 0..) |x, k| {
                if (std.ascii.eqlIgnoreCase(x, w)) break k;
            } else {
                try missing.append(a, w);
                continue;
            };
            try removed.append(a, list.orderedRemove(i));
        }
        if (removed.items.len > 0) try s.writeItems(a, name, list.items);
        return .{ .removed = removed.items, .missing = missing.items, .count = list.items.len };
    }

    /// Empties list `name`; how many it had.
    pub fn clear(s: *Store, a: Allocator, name: []const u8) !usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const list = try s.readItems(a, name);
        if (list.len > 0) try s.writeItems(a, name, &.{});
        return list.len;
    }

    /// Whether list `name` holds `item` (case aside).
    pub fn has(s: *Store, a: Allocator, name: []const u8, item: []const u8) !bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (try s.readItems(a, name)) |x| if (std.ascii.eqlIgnoreCase(x, item)) return true;
        return false;
    }
};

// ---- what is said ----

/// "Shopping" for `shopping`.
pub fn title(a: Allocator, name: []const u8) ![]const u8 {
    const out = try a.dupe(u8, name);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn capital(a: Allocator, s: []const u8) ![]const u8 {
    return title(a, s);
}

/// "milk", "milk and eggs", "milk, eggs and coffee".
pub fn andList(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", parts[0 .. parts.len - 1]), parts[parts.len - 1] });
}

fn itemsWord(n: usize) []const u8 {
    return if (n == 1) "item" else "items";
}

/// What an add says: "Added milk to shopping (5 items)."
pub fn addedText(a: Allocator, name: []const u8, got: Store.Added) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    if (got.added.len > 0) {
        try o.print(a, "Added {s} to {s}", .{ try andList(a, got.added), name });
        if (got.already.len > 0) try o.print(a, "; {s} {s} on it already", .{ try andList(a, got.already), if (got.already.len == 1) "was" else "were" });
    } else if (got.already.len > 0) {
        try o.print(a, "{s} {s} on {s} already", .{ try capital(a, try andList(a, got.already)), if (got.already.len == 1) "is" else "are", name });
    } else try o.print(a, "Nothing added to {s}", .{name});
    try o.print(a, " ({d} {s}).", .{ got.count, itemsWord(got.count) });
    if (got.full) try o.print(a, " The list is full ({d} items): take something off first.", .{max_items});
    return o.items;
}

/// What a take-off says: "Took milk off shopping (4 left)."
pub fn removedText(a: Allocator, name: []const u8, got: Store.Removed) ![]const u8 {
    if (got.removed.len == 0) return std.fmt.allocPrint(a, "{s} {s} on {s}.", .{ try capital(a, try andList(a, got.missing)), if (got.missing.len == 1) "isn't" else "aren't", name });
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "Took {s} off {s}", .{ try andList(a, got.removed), name });
    if (got.count == 0) try o.appendSlice(a, "; it's empty now") else try o.print(a, " ({d} left)", .{got.count});
    if (got.missing.len > 0) try o.print(a, "; {s} {s} on it", .{ try andList(a, got.missing), if (got.missing.len == 1) "wasn't" else "weren't" });
    try o.append(a, '.');
    return o.items;
}

/// A list as read: "Shopping (3): milk, eggs, coffee." or "Shopping is empty."
pub fn showText(a: Allocator, name: []const u8, list: []const []const u8) ![]const u8 {
    if (list.len == 0) return std.fmt.allocPrint(a, "{s} is empty.", .{try title(a, name)});
    return std.fmt.allocPrint(a, "{s} ({d}): {s}.", .{ try title(a, name), list.len, try std.mem.join(a, ", ", list) });
}

// ---- state/errands: shops, weekly posts, what was said, open orders ----

/// A shop the owner set up (`/setup reorder`): its MCP server, its quote
/// and order tools, the list it orders from, when.
pub const Shop = struct {
    shop: []const u8 = "",
    quote: []const u8 = "",
    order: []const u8 = "",
    list: []const u8 = default_list,
    /// Proposed when the list reaches this many items (0: not by size).
    size: u32 = 10,
    /// And at this weekly time (`day` -1: none).
    day: i8 = -1,
    at: i32 = 0,
    /// The list was under `size` since the last proposal: reaching it
    /// proposes again.
    low: bool = true,
};

/// A list posted each week.
pub const Post = struct { list: []const u8 = "", day: i8 = 0, at: i32 = 0 };

/// Something said once (a key), and when.
pub const Said = struct { key: []const u8 = "", at: i64 = 0 };

/// An order proposed, waiting for the owner's tap on item `item`: the
/// exact call it makes (`arg`, "SERVER/TOOL {input}" as the gate reads it).
pub const Order = struct {
    item: u64 = 0,
    shop: []const u8 = "",
    list: []const u8 = default_list,
    arg: []const u8 = "",
    /// The items it orders (taken off the list once it went through).
    items: []const []const u8 = &.{},
    /// "64.20 PLN", for the lines after.
    total: []const u8 = "",
};

pub const State = struct {
    shops: []const Shop = &.{},
    posts: []const Post = &.{},
    said: []const Said = &.{},
    orders: []const Order = &.{},
};

/// `state/errands` as written; damaged: an error (the caller starts empty).
pub fn parseState(a: Allocator, text: []const u8) !State {
    const t0 = if (std.mem.indexOf(u8, text, "\r\n") == null) text else try std.mem.replaceOwned(u8, a, text, "\r\n", "\n");
    return std.json.parseFromSliceLeaky(State, a, t0, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// `st` as written, what was said over 14 days before `now_s` left out.
pub fn stateText(a: Allocator, st: State, now_s: i64) ![]const u8 {
    var said: std.ArrayList(Said) = .empty;
    for (st.said) |x| if (now_s - x.at < 14 * 86400) try said.append(a, x);
    var kept = st;
    kept.said = said.items;
    return std.json.Stringify.valueAlloc(a, kept, .{});
}

// ---- weekly times ----

/// A weekly time: `day` 0 Monday … 6 Sunday, 7 every day; `at` minutes.
pub const Weekly = struct { day: i8, at: i32 };

const day_words = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
const day_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

/// "sat 09:00", "saturday 9:00", "day 18:30" (every day).
pub fn parseWeekly(text: []const u8) ?Weekly {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    const d = it.next() orelse return null;
    const tm = it.next() orelse return null;
    if (it.next() != null) return null;
    var low_buf: [16]u8 = undefined;
    if (d.len < 3 or d.len > low_buf.len) return null;
    const low = std.ascii.lowerString(&low_buf, d);
    const day: i8 = if (std.mem.eql(u8, low, "day") or std.mem.eql(u8, low, "daily")) 7 else blk: {
        for (day_words, 0..) |w, i| if (std.mem.startsWith(u8, low, w) and std.ascii.startsWithIgnoreCase(day_names[i], low)) break :blk @intCast(i);
        return null;
    };
    const colon = std.mem.indexOfScalar(u8, tm, ':') orelse return null;
    const h = std.fmt.parseInt(i32, tm[0..colon], 10) catch return null;
    const m = std.fmt.parseInt(i32, tm[colon + 1 ..], 10) catch return null;
    if (h < 0 or h > 23 or m < 0 or m > 59 or tm.len - colon != 3) return null;
    return .{ .day = day, .at = h * 60 + m };
}

/// "every Saturday at 09:00", "every day at 18:30".
pub fn weeklyText(a: Allocator, w: Weekly) ![]const u8 {
    const h: u32 = @intCast(@divFloor(w.at, 60));
    const m: u32 = @intCast(@mod(w.at, 60));
    if (w.day == 7) return std.fmt.allocPrint(a, "every day at {d:0>2}:{d:0>2}", .{ h, m });
    return std.fmt.allocPrint(a, "every {s} at {d:0>2}:{d:0>2}", .{ day_names[@intCast(w.day)], h, m });
}

/// Whether `w` is due on local day `day` (since 1970-01-01) at `minute`.
pub fn weeklyDue(w: Weekly, day: i64, minute: i64) bool {
    if (w.day < 0) return false;
    if (w.day != 7 and util.weekday(day) != @as(u3, @intCast(w.day))) return false;
    return minute >= w.at;
}

// ---- a planned shop in the calendar ----

const shop_words = [_][]const u8{ "shop", "shopping", "groceries", "grocery", "supermarket", "market", "zakupy", "sklep", "biedronka", "lidl", "auchan", "carrefour", "kaufland" };

/// The list an event titled `title` is a shop for: the one its title
/// names (a list's or a shop's name; a shop's list is its own), else the
/// default when the title has a shop word; null: not a shop.
pub fn shopEvent(a: Allocator, title_text: []const u8, known: []const []const u8, shops: []const []const u8) ?[]const u8 {
    const low = a.dupe(u8, title_text) catch return null;
    for (low) |*ch| ch.* = std.ascii.toLower(ch.*);
    var it = std.mem.tokenizeAny(u8, low, " \t,.:;!?()-/");
    var shop = false;
    while (it.next()) |w| {
        for (known) |k| if (!std.mem.eql(u8, k, default_list) and std.mem.eql(u8, w, k)) return k;
        for (shops) |s| if (std.mem.eql(u8, w, s)) {
            shop = true;
        };
        for (shop_words) |s| if (std.mem.eql(u8, w, s)) {
            shop = true;
        };
    }
    return if (shop) default_list else null;
}

// ---- a shop's quote and order ----

/// What a shop's quote tool answers (JSON): each item's product and price,
/// the total, what it hasn't got, the delivery.
pub const Quote = struct {
    total: f64 = 0,
    currency: []const u8 = "",
    lines: []const Line = &.{},
    missing: []const []const u8 = &.{},
    delivery: []const u8 = "",

    pub const Line = struct { item: []const u8 = "", product: []const u8 = "", price: ?f64 = null };
};

/// The quote tool's answer: its JSON object (text around it ignored).
pub fn parseQuote(a: Allocator, text: []const u8) !Quote {
    const from = std.mem.indexOfScalar(u8, text, '{') orelse return error.NotAQuote;
    const to = std.mem.lastIndexOfScalar(u8, text, '}') orelse return error.NotAQuote;
    if (to < from) return error.NotAQuote;
    const q = std.json.parseFromSliceLeaky(Quote, a, text[from .. to + 1], .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.NotAQuote;
    if (!(q.total >= 0) or std.math.isInf(q.total)) return error.NotAQuote;
    return q;
}

/// "64.20 PLN" ("64.20" with no currency).
pub fn amountText(a: Allocator, x: f64, currency: []const u8) ![]const u8 {
    if (currency.len == 0) return std.fmt.allocPrint(a, "{d:.2}", .{x});
    return std.fmt.allocPrint(a, "{d:.2} {s}", .{ x, currency });
}

/// What an order takes from `list`: the items the quote priced (as the
/// list has them), and those it didn't.
pub const Plan = struct { order: []const []const u8, lines: []const Quote.Line, missing: []const []const u8 };

pub fn planOrder(a: Allocator, q: Quote, list: []const []const u8) !Plan {
    var order: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList(Quote.Line) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    for (list) |item| {
        const line = for (q.lines) |l| {
            if (std.ascii.eqlIgnoreCase(l.item, item)) break l;
        } else null;
        if (line) |l| {
            try order.append(a, item);
            try lines.append(a, l);
        } else try missing.append(a, item);
    }
    return .{ .order = order.items, .lines = lines.items, .missing = missing.items };
}

/// The quote tool's input: `{"items":[…]}`.
pub fn quoteInput(a: Allocator, items: []const []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .items = items }, .{});
}

/// The order tool's input: the items and, in `field`, the total (a
/// ceiling the shop holds to, and what the money caps check).
pub fn orderInput(a: Allocator, items: []const []const u8, field: []const u8, total: f64) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"items\":");
    try o.appendSlice(a, try std.json.Stringify.valueAlloc(a, items, .{}));
    try o.append(a, ',');
    try util.jsonString(&o, a, field);
    try o.print(a, ":{d:.2}}}", .{total});
    return o.items;
}

/// The whole order, as the owner is asked: the shop, the total and the
/// delivery, a line per item, and what wasn't found.
pub fn proposal(a: Allocator, shop: []const u8, q: Quote, plan: Plan) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "Order from {s}: {s}", .{ try title(a, shop), try amountText(a, q.total, q.currency) });
    if (q.delivery.len > 0) try o.print(a, ", delivery {s}", .{util.cut(q.delivery, 80)});
    try o.append(a, '.');
    for (plan.order, plan.lines) |item, l| {
        try o.print(a, "\n- {s}", .{item});
        const product = util.cut(std.mem.trim(u8, l.product, " \t\r\n"), 80);
        if (product.len > 0 and !std.ascii.eqlIgnoreCase(product, item)) try o.print(a, ": {s}", .{product});
        if (l.price) |p| try o.print(a, ", {d:.2}", .{p});
    }
    if (plan.missing.len > 0) try o.print(a, "\nNot found: {s} (stays on the list).", .{try andList(a, plan.missing)});
    return o.items;
}

/// Whether a tool's name says it prices a basket.
pub fn quoteName(tool: []const u8) bool {
    for ([_][]const u8{ "quote", "price", "basket", "cart" }) |w| if (std.ascii.findIgnoreCase(tool, w) != null) return true;
    return false;
}

// ---- tests ----

const t = std.testing;

fn expectAdd(got: ?Words, list: []const u8, want: []const []const u8) !void {
    const w = got orelse return error.NotRead;
    if (w != .add) return error.NotAnAdd;
    try t.expectEqualStrings(list, w.add.list);
    try t.expectEqual(want.len, w.add.items.len);
    for (want, w.add.items) |x, y| try t.expectEqualStrings(x, y);
}

test "list_words_are_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const known = [_][]const u8{ "shopping", "hardware" };
    try expectAdd(try read(a, "add milk", &known), "", &.{"milk"});
    try expectAdd(try read(a, "Add milk.", &known), "", &.{"milk"});
    try expectAdd(try read(a, "please add some oat milk and eggs to the list", &known), "", &.{ "oat milk", "eggs" });
    try expectAdd(try read(a, "add milk, eggs, coffee beans to the shopping list", &known), "shopping", &.{ "milk", "eggs", "coffee beans" });
    try expectAdd(try read(a, "add nails to the hardware list", &known), "hardware", &.{"nails"});
    try expectAdd(try read(a, "add nails to hardware", &known), "hardware", &.{"nails"});
    try expectAdd(try read(a, "add screws to the diy list", &known), "diy", &.{"screws"});
    try expectAdd(try read(a, "put bananas on the list", &known), "", &.{"bananas"});
    try expectAdd(try read(a, "We're out of coffee", &known), "", &.{"coffee"});
    try expectAdd(try read(a, "we are out of coffee!", &known), "", &.{"coffee"});
    try expectAdd(try read(a, "we\u{2019}re all out of dish soap", &known), "", &.{"dish soap"});
    try expectAdd(try read(a, "dodaj mleko i jajka", &known), "", &.{ "mleko", "jajka" });
    // taking off
    const rm = (try read(a, "remove milk from the list", &known)).?;
    try t.expect(rm == .remove);
    try t.expectEqualStrings("milk", rm.remove.items[0]);
    const off = (try read(a, "take eggs off the hardware list", &known)).?;
    try t.expectEqualStrings("hardware", off.remove.list);
    try t.expectEqualStrings("eggs", off.remove.items[0]);
    const got = (try read(a, "got the milk", &known)).?;
    try t.expect(got == .got);
    try t.expectEqualStrings("milk", got.got.items[0]);
    try t.expect((try read(a, "bought eggs and butter", &known)).? == .got);
    try t.expect((try read(a, "remove milk", &known)).? == .got);
    // reading
    try t.expectEqualStrings("", (try read(a, "list", &known)).?.show);
    try t.expectEqualStrings("", (try read(a, "What's on the list?", &known)).?.show);
    try t.expectEqualStrings("shopping", (try read(a, "shopping list", &known)).?.show);
    try t.expectEqualStrings("hardware", (try read(a, "what's on the hardware list", &known)).?.show);
    try t.expectEqualStrings("", (try read(a, "lista zakupów", &known)).?.show);
    // not about lists
    for ([_][]const u8{ "hello", "what's the weather", "list the files in notes", "goodnight", "add", "out of office tomorrow" }) |x| {
        if (try read(a, x, &known)) |w| {
            std.debug.print("read {s} as {s}\n", .{ x, @tagName(w) });
            return error.TestUnexpectedResult;
        }
    }
}

test "a_bare_add_is_guarded" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "add a reminder for 9:30",
        "add Tomek to the meeting",
        "add a meeting with Ola tomorrow",
        "add the kitchen light to goodnight",
        "can you add a trigger for the back door?",
        "add 9:30 dentist",
        "add a birthday for Ola",
        "add one two three four five six seven",
    }) |x| {
        if (try read(a, x, &.{"shopping"})) |w| {
            std.debug.print("read {s} as {s}\n", .{ x, @tagName(w) });
            return error.TestUnexpectedResult;
        }
    }
    // a list named, though: it counts
    try expectAdd(try read(a, "add a reminder card to the list", &.{"shopping"}), "", &.{"reminder card"});
    try expectAdd(try read(a, "add 2 l milk", &.{"shopping"}), "", &.{"2 l milk"});
}

test "list_files_round_trip_and_read_crlf" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var s: Store = .init(t.allocator, t.io, dir);
    const got = try s.add(a, "shopping", &.{ "milk", "eggs" });
    try t.expectEqual(2, got.count);
    try t.expectEqual(0, got.before);
    try t.expectEqualStrings("Added milk and eggs to shopping (2 items).", try addedText(a, "shopping", got));
    try t.expectEqualStrings("Shopping (2): milk, eggs.", try showText(a, "shopping", try s.items(a, "shopping")));
    // the owner's own edit, with Windows line ends and a comment
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shopping", .data = "# the shopping list\r\nmilk\r\neggs\r\n\r\ncoffee\r\n" });
    const list = try s.items(a, "shopping");
    try t.expectEqual(3, list.len);
    try t.expectEqualStrings("coffee", list[2]);
    const r = try s.remove(a, "shopping", &.{ "Eggs", "tea" });
    try t.expectEqualStrings("eggs", r.removed[0]);
    try t.expectEqualStrings("tea", r.missing[0]);
    try t.expectEqualStrings("Took eggs off shopping (2 left); tea wasn't on it.", try removedText(a, "shopping", r));
    try t.expect(try s.has(a, "shopping", "MILK"));
    _ = try s.add(a, "hardware", &.{"nails"});
    const ns = try s.names(a);
    try t.expectEqual(2, ns.len);
    try t.expectEqualStrings("shopping", ns[0]);
    try t.expectEqualStrings("hardware", ns[1]);
    try t.expectEqual(2, try s.clear(a, "shopping"));
    try t.expectEqualStrings("Shopping is empty.", try showText(a, "shopping", try s.items(a, "shopping")));
    // names that would leave the folder are refused
    for ([_][]const u8{ "", "../x", "a/b", "Shop", "every", "clear", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }) |n| try t.expect(!validName(n));
    try t.expect(validName("diy-2"));
    try t.expectError(error.BadName, s.add(a, "../x", &.{"y"}));
}

test "items_are_kept_once" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var s: Store = .init(t.allocator, t.io, dir);
    _ = try s.add(a, "shopping", &.{"milk"});
    const got = try s.add(a, "shopping", &.{ "Milk", "bread" });
    try t.expectEqual(1, got.added.len);
    try t.expectEqual(1, got.already.len);
    try t.expectEqual(1, got.before);
    try t.expectEqual(2, got.count);
    try t.expectEqualStrings("Added bread to shopping; milk was on it already (2 items).", try addedText(a, "shopping", got));
    const again = try s.add(a, "shopping", &.{"milk"});
    try t.expectEqualStrings("Milk is on shopping already (2 items).", try addedText(a, "shopping", again));
    // an item is one line: line breaks go, and it is cut at 80 bytes
    const long_buf: [100]u8 = @splat('x');
    const long: []const u8 = &long_buf;
    _ = try s.add(a, "shopping", &.{ "jam\nbutter", long });
    const list = try s.items(a, "shopping");
    try t.expectEqualStrings("jam butter", list[2]);
    try t.expectEqual(max_item, list[3].len);
}

test "weekly_times_read_and_fall_due" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sat = parseWeekly("sat 09:00").?;
    try t.expectEqual(5, sat.day);
    try t.expectEqual(540, sat.at);
    try t.expectEqual(5, parseWeekly("Saturday 9:00").?.day);
    try t.expectEqual(7, parseWeekly("day 18:30").?.day);
    for ([_][]const u8{ "", "sat", "sat 25:00", "sat 9", "sa 09:00", "satx 09:00", "sat 09:00 x", "sat 09:5" }) |x| try t.expect(parseWeekly(x) == null);
    try t.expectEqualStrings("every Saturday at 09:00", try weeklyText(a, sat));
    try t.expectEqualStrings("every day at 18:30", try weeklyText(a, parseWeekly("daily 18:30").?));
    // 2026-11-28 is a Saturday
    const d = util.daysFromCivil(2026, 11, 28);
    try t.expect(!weeklyDue(sat, d, 539));
    try t.expect(weeklyDue(sat, d, 540));
    try t.expect(!weeklyDue(sat, d - 1, 600));
    try t.expect(weeklyDue(.{ .day = 7, .at = 60 }, d - 1, 61));
}

test "a_shop_in_the_calendar" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const known = [_][]const u8{ "shopping", "hardware" };
    try t.expectEqualStrings("shopping", shopEvent(a, "Groceries", &known, &.{}).?);
    try t.expectEqualStrings("shopping", shopEvent(a, "Zakupy w Lidl", &known, &.{}).?);
    try t.expectEqualStrings("shopping", shopEvent(a, "Frisco delivery", &known, &.{"frisco"}).?);
    try t.expectEqualStrings("hardware", shopEvent(a, "Hardware store run", &known, &.{}).?);
    try t.expect(shopEvent(a, "Dentist", &known, &.{}) == null);
    try t.expect(shopEvent(a, "Workshop on Zig", &known, &.{}) == null);
}

test "the_errands_file_round_trips" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1_800_000_000;
    const st: State = .{
        .shops = &.{.{ .shop = "frisco", .quote = "shop_quote", .order = "shop_order", .size = 8, .day = 5, .at = 540 }},
        .posts = &.{.{ .list = "shopping", .day = 5, .at = 540 }},
        .said = &.{ .{ .key = "post shopping 1", .at = now - 86400 }, .{ .key = "old", .at = now - 15 * 86400 } },
        .orders = &.{.{ .item = 12, .shop = "frisco", .arg = "frisco/shop_order {\"items\":[\"milk\"],\"total\":5}", .items = &.{"milk"}, .total = "5.00 PLN" }},
    };
    const text = try stateText(a, st, now);
    const back = try parseState(a, try std.mem.replaceOwned(u8, a, text, "\n", "\r\n"));
    try t.expectEqual(1, back.shops.len);
    try t.expectEqualStrings("frisco", back.shops[0].shop);
    try t.expectEqual(8, back.shops[0].size);
    try t.expectEqual(1, back.posts.len);
    // what was said over 14 days ago goes
    try t.expectEqual(1, back.said.len);
    try t.expectEqualStrings("post shopping 1", back.said[0].key);
    try t.expectEqual(12, back.orders[0].item);
    try t.expectEqualStrings("milk", back.orders[0].items[0]);
    try t.expectError(error.SyntaxError, parseState(a, "{not json"));
}

test "a_quote_reads_and_is_proposed_in_full" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try parseQuote(a, "Priced:\n{\"total\": 64.2, \"currency\": \"PLN\", \"lines\": [{\"item\": \"Milk\", \"product\": \"Mleko 2% 1 l\", \"price\": 4.2}, {\"item\": \"coffee beans\", \"product\": \"Lavazza Oro 1 kg\", \"price\": 52}, {\"item\": \"eggs\", \"product\": \"eggs\", \"price\": 8}], \"missing\": [\"oat milk\"], \"delivery\": \"Sat 28 Nov, 10:00–12:00\", \"extra\": 1}");
    const plan = try planOrder(a, q, &.{ "milk", "oat milk", "coffee beans", "eggs" });
    try t.expectEqual(3, plan.order.len);
    try t.expectEqualStrings("oat milk", plan.missing[0]);
    try t.expectEqualStrings(
        \\Order from Frisco: 64.20 PLN, delivery Sat 28 Nov, 10:00–12:00.
        \\- milk: Mleko 2% 1 l, 4.20
        \\- coffee beans: Lavazza Oro 1 kg, 52.00
        \\- eggs, 8.00
        \\Not found: oat milk (stays on the list).
    , try proposal(a, "frisco", q, plan));
    try t.expectEqualStrings("{\"items\":[\"milk\",\"coffee beans\",\"eggs\"],\"total\":64.20}", try orderInput(a, plan.order, "total", q.total));
    try t.expectEqualStrings("{\"items\":[\"milk\",\"eggs\"]}", try quoteInput(a, &.{ "milk", "eggs" }));
    try t.expectEqualStrings("64.20", try amountText(a, 64.2, ""));
    try t.expectError(error.NotAQuote, parseQuote(a, "sorry, no"));
    try t.expectError(error.NotAQuote, parseQuote(a, "{\"total\": -1}"));
    try t.expect(quoteName("shop_quote") and quoteName("price_basket") and quoteName("CartTotal"));
    try t.expect(!quoteName("shop_order"));
}
