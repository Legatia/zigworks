//! What apps say about themselves over the accessibility bus (AT-SPI):
//! their buttons, fields and menus by role and name, with where each one
//! is. Read from the command line, not by the desktop's own process, so a
//! slow app can't hold the desktop up.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dbus = @import("dbus.zig");

pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

/// Bits of AT-SPI's state set.
pub const State = struct {
    pub const checked: u6 = 4;
    pub const editable: u6 = 7;
    pub const enabled: u6 = 8;
    pub const expanded: u6 = 10;
    pub const focused: u6 = 12;
    pub const selected: u6 = 23;
    pub const sensitive: u6 = 24;
    pub const showing: u6 = 25;
    pub const visible: u6 = 30;
};

pub const Node = struct {
    bus: []const u8,
    path: []const u8,
    role: []const u8,
    name: []const u8,
    /// What a text field holds.
    text: []const u8 = "",
    /// Relative to the window the node is in; `has_rect` false if the app
    /// did not say.
    rect: Rect = .{},
    has_rect: bool = false,
    states: u64 = 0,
    depth: u32,
    /// The index of the top node (a window) this one is under.
    top: usize,
    /// Whether it can be acted on without the pointer.
    actions: bool = false,

    pub fn is(n: Node, bit: u6) bool {
        return n.states & (@as(u64, 1) << bit) != 0;
    }

    /// On screen: the app says so, and says where. (GTK calls the pages of
    /// a notebook that are not open showing, but gives them no place.)
    pub fn shown(n: Node) bool {
        return n.is(State.showing) and n.is(State.visible) and n.has_rect;
    }
};

const iface_accessible = "org.a11y.atspi.Accessible";
const registry = "org.a11y.atspi.Registry";
const root_path = "/org/a11y/atspi/accessible/root";

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    /// Nodes were left out: the limit was reached.
    cut: bool = false,

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
    }
};

const Walk = struct {
    conn: *dbus.Conn,
    tree: *Tree,
    max: usize,
    /// Whether to ask text fields what they hold.
    texts: bool,
};

fn property(w: *Walk, bus: []const u8, path: []const u8, name: []const u8) []const u8 {
    const gpa = w.conn.gpa;
    var args: dbus.Writer = .{ .gpa = gpa };
    defer args.deinit();
    args.string(iface_accessible) catch return "";
    args.string(name) catch return "";
    const rep = w.conn.call(bus, path, "org.freedesktop.DBus.Properties", "Get", "ss", args.bytes.items) catch return "";
    defer rep.deinit(gpa);
    var r = rep.reader();
    const sig = r.signature() catch return "";
    if (!std.mem.eql(u8, sig, "s")) return "";
    return w.tree.arena.allocator().dupe(u8, r.string() catch return "") catch "";
}

fn children(w: *Walk, bus: []const u8, path: []const u8) []const [2][]const u8 {
    const gpa = w.conn.gpa;
    const arena = w.tree.arena.allocator();
    const rep = w.conn.call(bus, path, iface_accessible, "GetChildren", "", "") catch return &.{};
    defer rep.deinit(gpa);
    var r = rep.reader();
    const end = r.array(8) catch return &.{};
    var list: std.ArrayList([2][]const u8) = .empty;
    while (r.pos < end) {
        r.structure();
        const child_bus = arena.dupe(u8, r.string() catch break) catch break;
        const child_path = arena.dupe(u8, r.string() catch break) catch break;
        list.append(arena, .{ child_bus, child_path }) catch break;
    }
    return list.items;
}

fn visit(w: *Walk, bus: []const u8, path: []const u8, depth: u32, top: ?usize) void {
    if (w.tree.nodes.items.len >= w.max or depth > 60) {
        w.tree.cut = true;
        return;
    }
    const gpa = w.conn.gpa;
    const arena = w.tree.arena.allocator();
    const index = w.tree.nodes.items.len;
    var node: Node = .{ .bus = bus, .path = path, .role = "", .name = "", .depth = depth, .top = top orelse index };

    if (w.conn.call(bus, path, iface_accessible, "GetRoleName", "", "")) |rep| {
        defer rep.deinit(gpa);
        var r = rep.reader();
        node.role = arena.dupe(u8, r.string() catch "") catch "";
    } else |_| return; // gone, or not an accessible object
    node.name = property(w, bus, path, "Name");
    // Ask only for what the object says it has: an app need not take a
    // question about an interface it does not offer well.
    var has_component = false;
    var has_text = false;
    var has_action = false;
    if (w.conn.call(bus, path, iface_accessible, "GetInterfaces", "", "")) |rep| {
        defer rep.deinit(gpa);
        var r = rep.reader();
        const end = r.array(4) catch 0;
        while (r.pos < end) {
            const iface = r.string() catch break;
            if (std.mem.eql(u8, iface, "org.a11y.atspi.Component")) has_component = true;
            if (std.mem.eql(u8, iface, "org.a11y.atspi.Text")) has_text = true;
            if (std.mem.eql(u8, iface, "org.a11y.atspi.Action")) has_action = true;
        }
    } else |_| {}
    if (w.conn.call(bus, path, iface_accessible, "GetState", "", "")) |rep| {
        defer rep.deinit(gpa);
        var r = rep.reader();
        if (r.array(4)) |_| {
            const lo = r.uint() catch 0;
            const hi = r.uint() catch 0;
            node.states = (@as(u64, hi) << 32) | lo;
        } else |_| {}
    } else |_| {}
    if (has_component) {
        var args: dbus.Writer = .{ .gpa = gpa };
        defer args.deinit();
        args.u32_(1) catch {}; // relative to the window
        if (w.conn.call(bus, path, "org.a11y.atspi.Component", "GetExtents", "u", args.bytes.items)) |rep| {
            defer rep.deinit(gpa);
            var r = rep.reader();
            r.structure();
            node.rect = .{ .x = r.int() catch 0, .y = r.int() catch 0, .w = r.int() catch 0, .h = r.int() catch 0 };
            node.has_rect = node.rect.w > 0 and node.rect.h > 0;
        } else |_| {}
    }
    if (has_text and w.texts) {
        var args: dbus.Writer = .{ .gpa = gpa };
        defer args.deinit();
        args.i32_(0) catch {};
        args.i32_(-1) catch {};
        if (w.conn.call(bus, path, "org.a11y.atspi.Text", "GetText", "ii", args.bytes.items)) |rep| {
            defer rep.deinit(gpa);
            var r = rep.reader();
            node.text = cleanText(arena, r.string() catch "", node.name);
        } else |_| {}
    }
    node.actions = has_action;
    w.tree.nodes.append(arena, node) catch return;
    for (children(w, bus, path)) |child| {
        // depth 0 is the bus's root, 1 an app, 2 a window of it
        visit(w, child[0], child[1], depth + 1, if (depth >= 2) node.top else null);
    }
}

/// Everything every app on the bus says, depth first: apps at depth 1,
/// their windows at 2. At most `max` nodes.
pub fn read(gpa: Allocator, conn: *dbus.Conn, max: usize, texts: bool) Tree {
    var tree: Tree = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    var w: Walk = .{ .conn = conn, .tree = &tree, .max = max, .texts = texts };
    for (children(&w, registry, root_path)) |app| visit(&w, app[0], app[1], 1, null);
    return tree;
}

/// What a text interface holds, as worth showing: without the marks that
/// stand for things embedded in the text (U+FFFC), cut to 200 bytes, and
/// nothing at all if that is only the name again.
fn cleanText(arena: Allocator, text: []const u8, name: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len and out.items.len < 200) {
        if (std.mem.startsWith(u8, text[i..], "\xef\xbf\xbc")) {
            i += 3;
            continue;
        }
        out.append(arena, text[i]) catch return "";
        i += 1;
    }
    // not in the middle of a character
    while (out.items.len > 0 and out.items[out.items.len - 1] & 0xc0 == 0x80 and i < text.len) _ = out.pop();
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, name)) return "";
    return trimmed;
}

/// Does what a click would, without the pointer: the node's first action.
pub fn press(conn: *dbus.Conn, node: Node) bool {
    var args: dbus.Writer = .{ .gpa = conn.gpa };
    defer args.deinit();
    args.i32_(0) catch return false;
    const rep = conn.call(node.bus, node.path, "org.a11y.atspi.Action", "DoAction", "i", args.bytes.items) catch return false;
    defer rep.deinit(conn.gpa);
    var r = rep.reader();
    return (r.uint() catch 0) != 0;
}

/// Puts `text` into an editable field, whatever the keyboard layout.
pub fn setText(conn: *dbus.Conn, node: Node, text: []const u8) bool {
    var args: dbus.Writer = .{ .gpa = conn.gpa };
    defer args.deinit();
    args.string(text) catch return false;
    const rep = conn.call(node.bus, node.path, "org.a11y.atspi.EditableText", "SetTextContents", "s", args.bytes.items) catch return false;
    defer rep.deinit(conn.gpa);
    var r = rep.reader();
    return (r.uint() catch 0) != 0;
}

/// Roles that only hold other things: left out of listings when unnamed.
pub fn isContainer(role: []const u8) bool {
    const plain = [_][]const u8{ "panel", "filler", "group", "generic", "section", "grouping", "scroll pane", "viewport", "layered pane", "split pane", "redundant object", "unknown", "", "box" };
    for (plain) |p| {
        if (std.mem.eql(u8, role, p)) return true;
    }
    return false;
}

/// How well a name fits what was asked for; lower is better.
pub const Fit = enum(u8) { same = 0, same_but_case = 1, holds = 2, none = 3 };

pub fn fit(name: []const u8, wanted: []const u8) Fit {
    if (wanted.len == 0) return .none;
    if (std.mem.eql(u8, name, wanted)) return .same;
    if (std.ascii.eqlIgnoreCase(name, wanted)) return .same_but_case;
    var i: usize = 0;
    while (i + wanted.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + wanted.len], wanted)) return .holds;
    }
    return .none;
}

/// The index of the node `i` is directly in, if any.
pub fn parentOf(nodes: []const Node, i: usize) ?usize {
    const d = nodes[i].depth;
    if (d <= 1) return null;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (nodes[j].depth == d - 1) return j;
        if (nodes[j].depth < d - 1) return null;
    }
    return null;
}

test "a name fits exactly, but for case, in part, or not" {
    try std.testing.expectEqual(Fit.same, fit("Save", "Save"));
    try std.testing.expectEqual(Fit.same_but_case, fit("Save", "SAVE"));
    try std.testing.expectEqual(Fit.holds, fit("Save As...", "save"));
    try std.testing.expectEqual(Fit.none, fit("Open", "save"));
    try std.testing.expectEqual(Fit.none, fit("Open", ""));
}

test "text worth showing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", cleanText(a, "\xef\xbf\xbc\xef\xbf\xbc", "x"));
    try std.testing.expectEqualStrings("", cleanText(a, "Close", "Close"));
    try std.testing.expectEqualStrings("hello", cleanText(a, " hello\xef\xbf\xbc\n", "field"));
}

test "the node a node is in" {
    const n = [_]Node{
        .{ .bus = "", .path = "", .role = "", .name = "app", .depth = 1, .top = 0 },
        .{ .bus = "", .path = "", .role = "", .name = "win", .depth = 2, .top = 1 },
        .{ .bus = "", .path = "", .role = "", .name = "a", .depth = 3, .top = 1 },
        .{ .bus = "", .path = "", .role = "", .name = "a1", .depth = 4, .top = 1 },
        .{ .bus = "", .path = "", .role = "", .name = "b", .depth = 3, .top = 1 },
    };
    try std.testing.expectEqual(@as(?usize, null), parentOf(&n, 0));
    try std.testing.expectEqual(@as(?usize, 1), parentOf(&n, 2));
    try std.testing.expectEqual(@as(?usize, 2), parentOf(&n, 3));
    try std.testing.expectEqual(@as(?usize, 1), parentOf(&n, 4));
}

test "containers are told from things" {
    try std.testing.expect(isContainer("panel"));
    try std.testing.expect(isContainer(""));
    try std.testing.expect(!isContainer("push button"));
}
