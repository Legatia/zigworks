//! harness: a personal agent you talk to in Telegram or the terminal.
const std = @import("std");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) u8 {
    _ = init;
    return 0;
}

test {
    _ = @import("config.zig");
    _ = @import("http.zig");
    _ = @import("jv.zig");
    _ = @import("sock.zig");
    _ = @import("store.zig");
    _ = @import("scrub.zig");
}
