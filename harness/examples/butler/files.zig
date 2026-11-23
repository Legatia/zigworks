//! The butler's routines as harness carries them: the files of this
//! folder, built into the binary (harness/src/butler.zig fills them in).
pub const triggers_ini = @embedFile("triggers.ini");
pub const rules = @embedFile("rules");
pub const mcp_ini = @embedFile("mcp.ini");

/// Each routine's workflow, by its name.
pub const workflows = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "goodnight", .text = @embedFile("workflows/goodnight.wf") },
    .{ .name = "leaving", .text = @embedFile("workflows/leaving.wf") },
    .{ .name = "arriving", .text = @embedFile("workflows/arriving.wf") },
    .{ .name = "morning-home", .text = @embedFile("workflows/morning-home.wf") },
    .{ .name = "leak", .text = @embedFile("workflows/leak.wf") },
    .{ .name = "smoke", .text = @embedFile("workflows/smoke.wf") },
    .{ .name = "door-open", .text = @embedFile("workflows/door-open.wf") },
    .{ .name = "doorbell", .text = @embedFile("workflows/doorbell.wf") },
    .{ .name = "away", .text = @embedFile("workflows/away.wf") },
    .{ .name = "car-tomorrow", .text = @embedFile("workflows/car-tomorrow.wf") },
    .{ .name = "warm-car", .text = @embedFile("workflows/warm-car.wf") },
    .{ .name = "bill", .text = @embedFile("workflows/bill.wf") },
    .{ .name = "delivery", .text = @embedFile("workflows/delivery.wf") },
    .{ .name = "flight", .text = @embedFile("workflows/flight.wf") },
    .{ .name = "invitation", .text = @embedFile("workflows/invitation.wf") },
    .{ .name = "trips", .text = @embedFile("workflows/trips.wf") },
};
