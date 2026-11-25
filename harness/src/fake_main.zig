//! harness-fake: stand-ins for omnigate, the Telegram Bot API, feeds and
//! search, for the end-to-end tests. `harness-fake --dir DIR [--port N]`
//! prints `port N` and serves until killed. `harness-fake --mcp` is an MCP
//! server on stdio instead (see fake_mcp.zig; `--mcp --home` is homemcp's
//! stand-in, `--mcp --car` carcloud's (`--tesla` with a Tesla), `--mcp --slack|--jira|--github`
//! the work morning's). `harness-fake discover URL`, `check FILE` and
//! `FILE.ini` answer as homemcp and carcloud do, for /setup (and as calmcp
//! does for a calendar file: fake_cal.zig). `harness-fake --desk HOME TEXT` is the desk app and
//! its page, over HTTP. `harness-fake --browse URL` is the owner's browser for a
//! sign-in: it opens URL, follows its redirect to 127.0.0.1, and prints the
//! page's status and text. `harness-fake --ha URL TOKEN BODY` is Home
//! Assistant's llama.cpp integration: it POSTs BODY to URL with TOKEN as
//! its API key and prints the answer's status and body. `harness-fake
//! inject DIR ORIGIN STORE` writes the prompt-injection demo's pages and
//! calls into DIR from the catalog (inject.zig).
const std = @import("std");
const fake = @import("fake.zig");
const fake_mcp = @import("fake_mcp.zig");
const fake_cal = @import("fake_cal.zig");
const fake_shop = @import("fake_shop.zig");
const proc = @import("proc.zig");
const inject = @import("inject.zig");

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    var dir: ?[]const u8 = null;
    var port: u16 = 0;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--mcp")) return fake_mcp.run(io, init.gpa, init.environ_map);
    // the unit tests' sandboxes: harness's own launcher (proc.zig)
    if (args.len == 2 and std.mem.eql(u8, args[1], "--" ++ proc.launch_arg)) return proc.sandboxLaunch(init.arena.allocator(), init.environ_map);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mcp") and std.mem.eql(u8, args[2], "--home")) return fake_mcp.runHome(io, init.gpa, init.environ_map);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mcp") and std.mem.eql(u8, args[2], "--car")) return fake_mcp.runCar(io, init.gpa, init.environ_map);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mcp") and std.mem.eql(u8, args[2], "--tesla")) return fake_mcp.runTesla(io, init.gpa, init.environ_map);
    // a shop's server, for the reorders (fake_shop.zig)
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mcp") and std.mem.eql(u8, args[2], "--shop")) return fake_shop.run(io, init.gpa);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mcp")) return fake_mcp.runWork(io, init.gpa, init.environ_map, args[2]);
    // calmcp's, for /setup calendar: discover URL USER, check FILE (a calendar file)
    if (args.len == 4 and std.mem.eql(u8, args[1], "discover")) return fake_cal.discover(io, init.environ_map);
    if (args.len == 3 and std.mem.eql(u8, args[1], "check")) {
        const text = std.Io.Dir.cwd().readFileAlloc(io, args[2], init.arena.allocator(), .limited(1 << 20)) catch "";
        if (fake_cal.isCalendarFile(text)) return fake_cal.check(io, init.arena.allocator(), init.environ_map, text);
    }
    // homemcp's and carcloud's commands, for /setup: discover URL, check FILE
    if (args.len == 3 and (std.mem.eql(u8, args[1], "discover") or std.mem.eql(u8, args[1], "check"))) return fake_mcp.programStandIn(io, init.arena.allocator(), init.environ_map, args[1..]);
    // as mcp.ini starts them: homemcp HOME.ini or carcloud CAR.ini
    if (args.len == 2 and std.mem.endsWith(u8, args[1], ".ini")) {
        const text = std.Io.Dir.cwd().readFileAlloc(io, args[1], init.arena.allocator(), .limited(1 << 20)) catch "";
        if (std.mem.indexOf(u8, text, "[car]") != null) return fake_mcp.runCar(io, init.gpa, init.environ_map);
        if (std.mem.indexOf(u8, text, "imap =") != null) return fake_mcp.runWork(io, init.gpa, init.environ_map, "--mail");
        if (fake_cal.isCalendarFile(text)) return fake_cal.run(io, init.gpa, init.environ_map, text);
        return fake_mcp.runHome(io, init.gpa, init.environ_map);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "--browse")) {
        const page = fake.browse(io, init.arena.allocator(), args[2], .{}) catch |e| {
            std.debug.print("harness-fake: {s}\n", .{@errorName(e)});
            return 1;
        };
        const out = std.fmt.allocPrint(init.arena.allocator(), "{d}\n{s}\n", .{ page.status, page.body }) catch return 1;
        std.Io.File.stdout().writeStreamingAll(io, out) catch return 1;
        return if (page.status == 200) 0 else 1;
    }
    // the desk app and its page, over HTTP: harness-fake --desk HOME TEXT
    if (args.len == 4 and std.mem.eql(u8, args[1], "--desk")) {
        fake.deskClient(io, init.arena.allocator(), args[2], args[3]) catch |e| {
            std.debug.print("harness-fake: {s}\n", .{@errorName(e)});
            return 1;
        };
        return 0;
    }
    // the injection demo's pages and calls, from the catalog
    if (args.len == 5 and std.mem.eql(u8, args[1], "inject")) {
        inject.writeDemo(io, init.arena.allocator(), args[2], args[3], args[4]) catch |e| {
            std.debug.print("harness-fake: {s}\n", .{@errorName(e)});
            return 1;
        };
        return 0;
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "--ha")) {
        const page = fake.sayAsHomeAssistant(io, init.arena.allocator(), args[2], args[3], args[4]) catch |e| {
            std.debug.print("harness-fake: {s}\n", .{@errorName(e)});
            return 1;
        };
        const out = std.fmt.allocPrint(init.arena.allocator(), "{d}\n{s}\n", .{ page.status, page.body }) catch return 1;
        std.Io.File.stdout().writeStreamingAll(io, out) catch return 1;
        return 0;
    }
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch return 2;
        } else return 2;
    }
    const s = fake.Server.start(io, dir orelse return 2, port) catch |e| {
        std.debug.print("harness-fake: {s}\n", .{@errorName(e)});
        return 1;
    };
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "port {d}\n", .{s.port}) catch return 1;
    std.Io.File.stdout().writeStreamingAll(io, line) catch return 1;
    while (true) io.sleep(.fromSeconds(3600), .awake) catch return 0;
}
