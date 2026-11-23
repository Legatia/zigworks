// The research's sketch with one change, `const c = @import("c")` (the
// module build.zig makes from can_headers.h) instead of @cImport, and the
// line breaks zig fmt gives it.
const std = @import("std");
const c = @import("c");

comptime {
    std.debug.assert(@sizeOf(c.struct_can_frame) == 16);
    std.debug.assert(@sizeOf(c.struct_canfd_frame) == 72);
}

/// RX-only tap socket. The tap binary contains no write path at all.
pub fn openTap(ifname: [*:0]const u8, filters: []const c.struct_can_filter) !c_int {
    const fd = c.socket(c.PF_CAN, c.SOCK_RAW, c.CAN_RAW);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var addr = std.mem.zeroes(c.struct_sockaddr_can);
    addr.can_family = c.AF_CAN;
    addr.can_ifindex = @intCast(c.if_nametoindex(ifname));
    if (addr.can_ifindex == 0) return error.NoSuchInterface;

    if (c.setsockopt(fd, c.SOL_CAN_RAW, c.CAN_RAW_FILTER, filters.ptr, @intCast(filters.len * @sizeOf(c.struct_can_filter))) != 0) return error.Filter;
    // Also request error frames (CAN_RAW_ERR_FILTER) to detect bus-off / error-passive.
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_can)) != 0) return error.Bind;
    return fd;
}

pub fn main() !void {
    const filters = [_]c.struct_can_filter{.{ .can_id = 0x261, .can_mask = c.CAN_SFF_MASK }};
    const fd = try openTap("vcan0", &filters);
    _ = c.close(fd);
    std.debug.print("sketch: opened and closed a tap on vcan0\n", .{});
}
