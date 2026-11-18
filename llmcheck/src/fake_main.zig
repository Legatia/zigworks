//! llmcheck-fake: a stand-in for a model server, to try llmcheck against
//! without a model. It answers with made-up words, the same way every time,
//! and can be told to misbehave in the ways llmcheck looks for.

const std = @import("std");
const fake = @import("fake.zig");

const usage_text =
    \\llmcheck-fake - a stand-in for a model server, to try llmcheck against
    \\
    \\Usage:
    \\  llmcheck-fake [--port N] [--fault NAME]... [--key K] [--delay MS] [--context N]
    \\
    \\Listens on 127.0.0.1, prints "listening port=N" and serves until stopped.
    \\
    \\  --port N      the port (default: a free one)
    \\  --fault NAME  misbehave; can be given several times. Names:
    \\                drops_grammar tool_in_content truncate_context ignore_max_tokens
    \\                ignore_stop ignore_seed nondeterministic hang no_done no_usage
    \\                no_logprobs weights_differ template_differs
    \\  --key K       refuse requests without this API key
    \\  --delay MS    time per generated token (default 0)
    \\  --context N   tokens the model takes in (default 512)
    \\
;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;

    var faults: fake.Faults = .{};
    var port: u16 = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const name: []const u8 = argv[i];
        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "help")) {
            stdout.writeStreamingAll(io, usage_text) catch {};
            return 0;
        }
        const known = [_][]const u8{ "--port", "--fault", "--key", "--delay", "--context" };
        const takes_value = for (known) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else false;
        if (!takes_value) return wrong("no option '{s}'", .{name});
        if (i + 1 >= argv.len) return wrong("{s} needs a value", .{name});
        i += 1;
        const value: []const u8 = argv[i];
        if (std.mem.eql(u8, name, "--fault")) {
            if (!faults.set(value)) return wrong("no fault '{s}'", .{value});
        } else if (std.mem.eql(u8, name, "--key")) {
            faults.key = value;
        } else {
            const n = std.fmt.parseInt(u32, value, 10) catch
                return wrong("{s} needs a whole number, not '{s}'", .{ name, value });
            if (std.mem.eql(u8, name, "--port")) {
                port = std.math.cast(u16, n) orelse return wrong("--port is at most 65535", .{});
            } else if (std.mem.eql(u8, name, "--delay")) {
                faults.token_delay_ms = n;
            } else {
                faults.context = n;
            }
        }
    }

    const server = fake.Server.start(io, faults, port) catch |e| {
        std.debug.print("llmcheck-fake: cannot listen on port {d}: {s}\n", .{ port, @errorName(e) });
        return 4;
    };
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "listening port={d}\n", .{server.port}) catch return 4;
    stdout.writeStreamingAll(io, line) catch {};
    while (true) io.sleep(.fromSeconds(1), .awake) catch {};
}

fn wrong(comptime fmt: []const u8, a: anytype) u8 {
    std.debug.print("llmcheck-fake: " ++ fmt ++ "\nSee `llmcheck-fake --help`.\n", a);
    return 2;
}
