//! harness-fake: stand-ins for omnigate, the Telegram Bot API, feeds and
//! search, for the tests.
const std = @import("std");

pub fn main(init: std.process.Init) u8 {
    _ = init;
    return 0;
}
