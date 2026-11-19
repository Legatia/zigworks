//! A recording of a desktop: a directory with every line of the log, every
//! input in a form that can be sent again, a picture whenever the desktop
//! changed, and a page to look at them.
//!
//!   meta.txt     size of the desktop, when it started
//!   events.txt   the log, line by line as it was written
//!   inputs.txt   "MS <tab> command" per input, for `headdesk replay`
//!   frames.txt   "N MS HASH X,Y,WxH" per picture
//!   frames/      000001.png ...
//!   index.html   written when the recording stops
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const png = @import("png.zig");
const Server = @import("server.zig").Server;
const Rect = @import("server.zig").Rect;

const Frame = struct { ms: u64, hash: u64, rect: Rect };

pub const Recorder = struct {
    gpa: Allocator,
    dir: []u8,
    /// The least time between two pictures.
    interval_ms: u64,
    start_ms: u64,
    events_fd: sys.fd_t,
    inputs_fd: sys.fd_t,
    frames_fd: sys.fd_t,
    /// The log line to write next (its number).
    next_line: u64,
    last_changes: u64,
    last_frame_ms: u64 = 0,
    last_hash: u64 = 0,
    frames: std.ArrayList(Frame) = .empty,
    lines: std.ArrayList([]u8) = .empty,
    inputs: u32 = 0,

    pub fn start(gpa: Allocator, dir: []const u8, fps: u32, srv: *Server) !*Recorder {
        var buf: [1024]u8 = undefined;
        try sys.mkdir(try std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0));
        try sys.mkdir(try std.fmt.bufPrintSentinel(&buf, "{s}/frames", .{dir}, 0));
        const events = try sys.create(try std.fmt.bufPrintSentinel(&buf, "{s}/events.txt", .{dir}, 0));
        errdefer sys.close(events);
        const inputs = try sys.create(try std.fmt.bufPrintSentinel(&buf, "{s}/inputs.txt", .{dir}, 0));
        errdefer sys.close(inputs);
        const frames = try sys.create(try std.fmt.bufPrintSentinel(&buf, "{s}/frames.txt", .{dir}, 0));
        errdefer sys.close(frames);
        const meta = try sys.create(try std.fmt.bufPrintSentinel(&buf, "{s}/meta.txt", .{dir}, 0));
        sys.writeAll(meta, try std.fmt.bufPrint(&buf, "size {d}x{d}\nstarted {d}\n", .{ srv.width, srv.height, sys.wallMicros() / 1000 })) catch {};
        sys.close(meta);
        const rec = try gpa.create(Recorder);
        const now = sys.nowMs();
        rec.* = .{
            .gpa = gpa,
            .dir = try gpa.dupe(u8, dir),
            .interval_ms = 1000 / @as(u64, @max(1, @min(fps, 60))),
            .start_ms = now,
            .events_fd = events,
            .inputs_fd = inputs,
            .frames_fd = frames,
            .next_line = srv.log_base + srv.log.items.len + 1,
            .last_changes = srv.changes,
        };
        srv.note("recording to {s}", .{dir});
        // the desktop as it is when the recording starts
        rec.capture(srv, .{ .x = 0, .y = 0, .w = srv.width, .h = srv.height });
        return rec;
    }

    /// Writes what the log gained and, if the desktop changed and the last
    /// picture is old enough, a picture.
    pub fn tick(rec: *Recorder, srv: *Server) void {
        while (rec.next_line <= srv.log_base + srv.log.items.len) : (rec.next_line += 1) {
            if (rec.next_line <= srv.log_base) continue; // dropped before it was written
            const line = srv.log.items[rec.next_line - srv.log_base - 1];
            sys.writeAll(rec.events_fd, line) catch {};
            sys.writeAll(rec.events_fd, "\n") catch {};
            if (rec.lines.items.len < 50000) {
                if (rec.gpa.dupe(u8, line)) |copy| rec.lines.append(rec.gpa, copy) catch rec.gpa.free(copy) else |_| {}
            }
        }
        if (srv.changes != rec.last_changes and sys.nowMs() - rec.last_frame_ms >= rec.interval_ms) {
            rec.last_changes = srv.changes;
            rec.capture(srv, srv.changed_recorded);
        }
    }

    fn capture(rec: *Recorder, srv: *Server, rect: Rect) void {
        const pixels = srv.render(rec.gpa) catch return;
        defer rec.gpa.free(pixels);
        srv.changed_recorded = .{};
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels));
        rec.last_frame_ms = sys.nowMs();
        // drawn again, but the same picture
        if (rec.frames.items.len > 0 and hash == rec.last_hash) return;
        rec.last_hash = hash;
        const n = rec.frames.items.len + 1;
        var buf: [1100]u8 = undefined;
        const file = png.encode(rec.gpa, pixels, @intCast(srv.width), @intCast(srv.height)) catch return;
        defer rec.gpa.free(file);
        const path = std.fmt.bufPrintSentinel(&buf, "{s}/frames/{d:0>6}.png", .{ rec.dir, n }, 0) catch return;
        const fd = sys.create(path) catch return;
        sys.writeAll(fd, file) catch {};
        sys.close(fd);
        const ms = rec.last_frame_ms - rec.start_ms;
        rec.frames.append(rec.gpa, .{ .ms = ms, .hash = hash, .rect = rect }) catch return;
        sys.writeAll(rec.frames_fd, std.fmt.bufPrint(&buf, "{d} {d} {x:0>16} {d},{d},{d}x{d}\n", .{ n, ms, hash, rect.x, rect.y, rect.w, rect.h }) catch return) catch {};
    }

    /// Notes one input, as the command line it came in as.
    pub fn input(rec: *Recorder, line: []const u8) void {
        var buf: [32]u8 = undefined;
        sys.writeAll(rec.inputs_fd, std.fmt.bufPrint(&buf, "{d}\t", .{sys.nowMs() - rec.start_ms}) catch return) catch {};
        sys.writeAll(rec.inputs_fd, line) catch {};
        sys.writeAll(rec.inputs_fd, "\n") catch {};
        rec.inputs += 1;
    }

    pub const Totals = struct { pictures: usize, inputs: u32 };

    /// The last picture, the page, and the files closed. Frees `rec`.
    pub fn stop(rec: *Recorder, srv: *Server) Totals {
        defer rec.gpa.destroy(rec);
        rec.capture(srv, srv.changed_recorded);
        srv.note("recording stopped: {d} pictures, {d} inputs", .{ rec.frames.items.len, rec.inputs });
        rec.tick(srv);
        rec.writePage(srv) catch {};
        sys.close(rec.events_fd);
        sys.close(rec.inputs_fd);
        sys.close(rec.frames_fd);
        for (rec.lines.items) |l| rec.gpa.free(l);
        rec.lines.deinit(rec.gpa);
        const totals: Totals = .{ .pictures = rec.frames.items.len, .inputs = rec.inputs };
        rec.frames.deinit(rec.gpa);
        rec.gpa.free(rec.dir);
        return totals;
    }

    /// index.html: the pictures in order, each with the log lines up to it.
    fn writePage(rec: *Recorder, srv: *Server) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(rec.gpa);
        try out.print(rec.gpa,
            \\<!doctype html>
            \\<html lang="en"><head><meta charset="utf-8">
            \\<meta name="viewport" content="width=device-width, initial-scale=1">
            \\<title>headdesk recording</title>
            \\<style>
            \\:root {{ color-scheme: light dark; font: 15px/1.45 system-ui, sans-serif; }}
            \\body {{ margin: 0 auto; padding: 16px; max-width: {d}px; }}
            \\h1 {{ font-size: 1.2rem; margin: 0 0 4px; }}
            \\p {{ margin: 0 0 12px; }}
            \\img {{ display: block; max-width: 100%; height: auto; border: 1px solid #8884; }}
            \\.bar {{ display: flex; gap: 8px; align-items: center; margin: 10px 0; flex-wrap: wrap; }}
            \\input[type=range] {{ flex: 1; min-width: 160px; }}
            \\button {{ font: inherit; padding: 4px 12px; }}
            \\pre {{ font: 12.5px/1.5 ui-monospace, monospace; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 40vh; overflow: auto; border: 1px solid #8884; padding: 8px; margin: 0; }}
            \\.in {{ font-weight: 600; }}
            \\</style></head><body>
            \\<h1>headdesk recording</h1>
            \\<p>{d} pictures, {d} inputs, desktop {d}x{d}. The log below runs up to the picture shown; inputs are bold.</p>
            \\<img id="pic" alt="The desktop at the chosen moment" width="{d}" height="{d}">
            \\<div class="bar">
            \\<button id="prev" type="button">Previous</button>
            \\<button id="next" type="button">Next</button>
            \\<input id="pos" type="range" min="1" max="{d}" value="1" aria-label="Picture number">
            \\<output id="where" for="pos"></output>
            \\</div>
            \\<pre id="log" aria-live="off"></pre>
            \\<script>
            \\const frames = [
        , .{ @max(480, srv.width + 32), rec.frames.items.len, rec.inputs, srv.width, srv.height, srv.width, srv.height, @max(1, rec.frames.items.len) });
        for (rec.frames.items) |f| try out.print(rec.gpa, "{d},", .{f.ms});
        try out.appendSlice(rec.gpa, "];\nconst lines = [\n");
        for (rec.lines.items) |l| {
            // "SEQ MSms text"
            var it = std.mem.splitScalar(u8, l, ' ');
            _ = it.next();
            const ms_text = it.next() orelse continue;
            const ms = std.fmt.parseInt(u64, std.mem.trimEnd(u8, ms_text, "ms"), 10) catch 0;
            try out.print(rec.gpa, "[{d},\"", .{ms -| (rec.start_ms - srv.start_ms)});
            for (l) |ch| switch (ch) {
                '"' => try out.appendSlice(rec.gpa, "\\\""),
                '\\' => try out.appendSlice(rec.gpa, "\\\\"),
                '<' => try out.appendSlice(rec.gpa, "\\u003c"),
                0...0x1f => try out.append(rec.gpa, ' '),
                else => try out.append(rec.gpa, ch),
            };
            try out.appendSlice(rec.gpa, "\"],\n");
        }
        try out.appendSlice(rec.gpa,
            \\];
            \\const pic = document.getElementById('pic'), pos = document.getElementById('pos');
            \\const where = document.getElementById('where'), log = document.getElementById('log');
            \\const isInput = /^\d+ \d+ms (pointer to|button |key |type |scroll )/;
            \\function show(n) {
            \\  n = Math.max(1, Math.min(frames.length, n));
            \\  pos.value = n;
            \\  pic.src = 'frames/' + String(n).padStart(6, '0') + '.png';
            \\  where.textContent = n + ' of ' + frames.length + ', at ' + (frames[n - 1] / 1000).toFixed(2) + ' s';
            \\  log.textContent = '';
            \\  for (const [ms, text] of lines) {
            \\    if (ms > frames[n - 1]) break;
            \\    const row = document.createElement('div');
            \\    row.textContent = text;
            \\    if (isInput.test(text)) row.className = 'in';
            \\    log.append(row);
            \\  }
            \\  log.scrollTop = log.scrollHeight;
            \\}
            \\pos.addEventListener('input', () => show(Number(pos.value)));
            \\document.getElementById('prev').addEventListener('click', () => show(Number(pos.value) - 1));
            \\document.getElementById('next').addEventListener('click', () => show(Number(pos.value) + 1));
            \\if (frames.length) show(1);
            \\</script></body></html>
            \\
        );
        var buf: [1100]u8 = undefined;
        const fd = try sys.create(try std.fmt.bufPrintSentinel(&buf, "{s}/index.html", .{rec.dir}, 0));
        defer sys.close(fd);
        try sys.writeAll(fd, out.items);
    }
};
