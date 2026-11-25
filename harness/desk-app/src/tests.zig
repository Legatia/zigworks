//! Every module whose decisions are tested apart from the window.
test {
    _ = @import("args.zig");
    _ = @import("home.zig");
    _ = @import("deskjson.zig");
}
