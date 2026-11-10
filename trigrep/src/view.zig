//! A base index plus an optional delta, presented as one set of files.
//!
//! File ids run over the base first, then the delta. Base files that the delta
//! replaces (changed or deleted) and the delta's tombstones are not `live`: they are
//! never candidates and must be skipped when iterating.

const std = @import("std");
const Allocator = std.mem.Allocator;
const index = @import("index.zig");
const Query = @import("query.zig").Query;

pub const View = struct {
    base: index.Index,
    delta: ?index.Index = null,
    superseded: std.DynamicBitSetUnmanaged = .{},
    /// Identifies exactly this state: the delta's build id, or the base's.
    state_id: u64,
    base_files: u32,
    file_count: u32,
    root: []const u8,

    pub fn open(arena: Allocator, path: []const u8) !View {
        var base = try index.Index.open(path);
        errdefer base.close();
        if (base.base_id != 0) return error.BadIndex;
        var v = View{
            .base = base,
            .state_id = base.build_id,
            .base_files = base.file_count,
            .file_count = base.file_count,
            .root = base.root,
        };
        const dp = try index.deltaPath(arena, path);
        var d = index.Index.open(dp) catch return v;
        if (d.base_id != base.build_id or !std.mem.eql(u8, d.root, base.root)) {
            d.close();
            return v;
        }
        var paths = std.StringHashMapUnmanaged(void){};
        try paths.ensureTotalCapacity(arena, d.file_count);
        var i: u32 = 0;
        while (i < d.file_count) : (i += 1) paths.putAssumeCapacity(d.file(i).path, {});
        v.superseded = try std.DynamicBitSetUnmanaged.initEmpty(arena, base.file_count);
        i = 0;
        while (i < base.file_count) : (i += 1) {
            if (paths.contains(base.file(i).path)) v.superseded.set(i);
        }
        v.delta = d;
        v.state_id = d.build_id;
        v.file_count = base.file_count + d.file_count;
        return v;
    }

    pub fn close(v: *View) void {
        if (v.delta) |*d| d.close();
        v.base.close();
    }

    pub fn file(v: *const View, id: u32) index.FileRec {
        if (id < v.base_files) return v.base.file(id);
        return v.delta.?.file(id - v.base_files);
    }

    /// False for base files the delta replaced and for the delta's tombstones.
    pub fn live(v: *const View, id: u32) bool {
        if (id < v.base_files) return v.delta == null or !v.superseded.isSet(id);
        return v.delta.?.file(id - v.base_files).size != index.tombstone;
    }

    /// Candidate ids for `q`, live ones only; null means every live file.
    pub fn candidates(v: *const View, arena: Allocator, q: Query) !?[]const u32 {
        const b = try v.base.candidates(arena, q);
        const d = v.delta orelse return b;
        const dc = try d.candidates(arena, q);
        if (b == null and dc == null) return null;
        var out: std.ArrayList(u32) = .empty;
        if (b) |ids| {
            for (ids) |id| {
                if (v.live(id)) try out.append(arena, id);
            }
        } else {
            var id: u32 = 0;
            while (id < v.base_files) : (id += 1) {
                if (v.live(id)) try out.append(arena, id);
            }
        }
        if (dc) |ids| {
            for (ids) |id| try out.append(arena, v.base_files + id);
        } else {
            var id: u32 = v.base_files;
            while (id < v.file_count) : (id += 1) {
                if (v.live(id)) try out.append(arena, id);
            }
        }
        return out.items;
    }

    pub fn liveCount(v: *const View) u32 {
        if (v.delta == null) return v.file_count;
        var n: u32 = 0;
        var id: u32 = 0;
        while (id < v.file_count) : (id += 1) n += @intFromBool(v.live(id));
        return n;
    }
};

/// The state id of the index at `path` without mapping it: the delta's build id if a
/// valid delta exists, else the base's. Null if there is no usable index.
pub fn stateId(arena: Allocator, path: []const u8) ?u64 {
    const base = readHeader(path) orelse return null;
    if (base.base_id != 0) return null;
    const dp = index.deltaPath(arena, path) catch return base.build_id;
    if (readHeader(dp)) |d| {
        if (d.base_id == base.build_id) return d.build_id;
    }
    return base.build_id;
}

const Header = struct { build_id: u64, base_id: u64 };

fn readHeader(path: []const u8) ?Header {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var head: [88]u8 = undefined;
    const n = f.readAll(&head) catch return null;
    if (n < head.len or !std.mem.eql(u8, head[0..8], index.magic)) return null;
    if (std.mem.readInt(u32, head[8..12], .little) != index.format_version) return null;
    return .{
        .build_id = std.mem.readInt(u64, head[72..80], .little),
        .base_id = std.mem.readInt(u64, head[80..88], .little),
    };
}
