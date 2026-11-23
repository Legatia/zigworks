//! calmcp: the owner's CalDAV calendars as a few named tools for an AI
//! agent, over MCP on stdio.
const std = @import("std");

pub fn main() !void {}

test {
    _ = @import("tz.zig");
    _ = @import("ics.zig");
    _ = @import("rrule.zig");
    _ = @import("agenda.zig");
    _ = @import("xml.zig");
}
