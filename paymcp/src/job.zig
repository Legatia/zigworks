//! One reading: the business's own file (when the pay file names one), the
//! billing provider, and the audit over both.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const stripe = @import("stripe.zig");
const audit = @import("audit.zig");
const who = @import("who.zig");

pub const Reading = struct {
    data: audit.Data = .{},
    findings: []const audit.Finding = &.{},
    /// When it was read (seconds).
    now: i64 = 0,
    /// Whether the pay file names the business's own file.
    who_given: bool = false,
    /// GETs it took.
    requests: u32 = 0,
};

/// error.Failed with `why` set when the business's file can't be read or
/// the provider didn't answer; everything lives in `a`.
pub fn read(a: Allocator, io: Io, cfg: *const config.Config, client: *stripe.Client, now: i64, why: *[]const u8) !Reading {
    var rows: []const who.Row = &.{};
    if (cfg.who_path.len > 0) {
        const text = Io.Dir.cwd().readFileAlloc(io, cfg.who_path, a, .limited(64 << 20)) catch |e| {
            why.* = try std.fmt.allocPrint(a, "can't read the business's file {s}: {s}", .{ cfg.who_path, @errorName(e) });
            return error.Failed;
        };
        var d: who.Diag = .{};
        rows = who.parse(a, text, &d) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            why.* = if (d.line > 0)
                try std.fmt.allocPrint(a, "{s} line {d}: {s}", .{ cfg.who_path, d.line, d.what })
            else
                try std.fmt.allocPrint(a, "{s}: {s}", .{ cfg.who_path, d.what });
            return error.Failed;
        };
    }
    const before = client.requests;
    const data = client.load(a, cfg, rows, now) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        why.* = try a.dupe(u8, client.why);
        return error.Failed;
    };
    return .{
        .data = data,
        .findings = try audit.run(a, data, cfg.rules, now),
        .now = now,
        .who_given = cfg.who_path.len > 0,
        .requests = client.requests - before,
    };
}
