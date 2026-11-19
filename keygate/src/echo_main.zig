//! A stand-in service for the smoke tests: answers every request with what
//! it received, including the credential, so the tests can see that the
//! gateway sent the real value and that the caller got it masked.
const std = @import("std");
const sock = @import("sock.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const l = try sock.Listener.open(0);
    var pbuf: [16]u8 = undefined;
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&pbuf, "{d}\n", .{l.port}));
    while (true) {
        const conn = l.accept() catch continue;
        defer sock.closeHandle(conn);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var sk: sock.Socket = undefined;
        sk.init(io, conn, &rbuf, &wbuf, 5000);
        var server = std.http.Server.init(&sk.reader, &sk.writer);
        var req = server.receiveHead() catch continue;
        if (std.mem.eql(u8, req.head.target, "/quit")) {
            req.respond("bye\n", .{ .keep_alive = false }) catch {};
            return;
        }
        var out: [8192]u8 = undefined;
        var w: Io.Writer = .fixed(&out);
        w.print("{s} {s}\n", .{ @tagName(req.head.method), req.head.target }) catch {};
        var it = req.iterateHeaders();
        while (it.next()) |h| w.print("{s}: {s}\n", .{ h.name, h.value }) catch {};
        req.respond(w.buffered(), .{ .keep_alive = false }) catch {};
    }
}
