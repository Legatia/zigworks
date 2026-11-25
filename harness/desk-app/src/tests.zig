//! Every module whose decisions are tested apart from the window.
test {
    _ = @import("args.zig");
    _ = @import("home.zig");
    _ = @import("deskjson.zig");
    _ = @import("entry.zig");
    _ = @import("alive.zig");
    _ = @import("policy.zig");
    _ = @import("bridge.zig");
    _ = @import("controller.zig");
    _ = @import("commands.zig");
    _ = @import("pages.zig");
    _ = @import("icon.zig");
    _ = @import("plist.zig");
}
