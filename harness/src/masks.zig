//! The values masked in what tools return and in the log: the stored
//! secrets read at start, and values that appear while harness runs (a
//! secret fetched for an MCP server on /reload, a password made at a
//! sign-up). One list per instance, behind a lock; a scrubber takes a copy
//! of it when it starts, so a value added now is masked from the next tool
//! call on, in every run.
const std = @import("std");
const scrub = @import("scrub.zig");
const Io = std.Io;

pub const List = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    /// Names and values. Nothing is freed before deinit, so the strings of
    /// a snapshot live as long as the list.
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(scrub.Secret) = .empty,
    /// Told after a value is added (outside the lock): the log and memory
    /// keep their own copy of the list and take the new one.
    on_change: ?Hook = null,

    pub const Hook = struct {
        ctx: *anyopaque,
        changed: *const fn (ctx: *anyopaque) void,
    };

    pub fn init(gpa: std.mem.Allocator, io: Io) List {
        return .{ .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(l: *List) void {
        for (l.items.items) |x| std.crypto.secureZero(u8, @constCast(x.value));
        l.arena.deinit();
    }

    /// Adds a value under a name (both copied). An empty value, or one
    /// already there, is not added.
    pub fn add(l: *List, name: []const u8, value: []const u8) !void {
        if (value.len == 0) return;
        {
            l.mutex.lockUncancelable(l.io);
            defer l.mutex.unlock(l.io);
            for (l.items.items) |x| if (std.mem.eql(u8, x.value, value)) return;
            const a = l.arena.allocator();
            const v = try a.dupe(u8, value);
            try l.items.append(a, .{ .name = try a.dupe(u8, name), .value = v });
        }
        if (l.on_change) |h| h.changed(h.ctx);
    }

    /// The values now, in a slice of `a` (the strings stay the list's).
    pub fn snapshot(l: *List, a: std.mem.Allocator) ![]const scrub.Secret {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        return a.dupe(scrub.Secret, l.items.items);
    }

    pub fn count(l: *List) usize {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        return l.items.items.len;
    }

    /// `text` with every value masked as `[secret:NAME]`; caller frees.
    pub fn scrubAlloc(l: *List, gpa: std.mem.Allocator, text: []const u8) ![]u8 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var s = try scrub.Scrubber.init(arena.allocator(), try l.snapshot(arena.allocator()));
        return s.scrubAlloc(gpa, text);
    }
};

const t = std.testing;

test "the_mask_list_keeps_values_once_and_masks_what_it_holds_now" {
    var l: List = .init(t.allocator, t.io);
    defer l.deinit();
    try l.add("omnigate", "og-key-for-tests-1");
    try l.add("again", "og-key-for-tests-1");
    try l.add("empty", "");
    try t.expectEqual(1, l.count());
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const before = try l.snapshot(arena.allocator());
    try l.add("login-new-password", "made-Pass-7351!x");
    // a copy taken before does not change; the list does
    try t.expectEqual(1, before.len);
    const got = try l.scrubAlloc(t.allocator, "key og-key-for-tests-1, password made-Pass-7351!x");
    defer t.allocator.free(got);
    try t.expectEqualStrings("key [secret:omnigate], password [secret:login-new-password]", got);
}
