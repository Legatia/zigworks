//! WAV (RIFF WAVE) reading and writing. Reads PCM 8/16/24/32-bit and
//! 32/64-bit float, plain or WAVE_FORMAT_EXTENSIBLE; writes 16- or 24-bit PCM.
const std = @import("std");
const Audio = @import("audio.zig").Audio;

pub const Error = error{ NotWav, UnsupportedWav, UnsupportedLayout, BadWav };

pub const min_rate = 1000;
pub const max_rate = 768_000;
pub const max_channels = 64;

pub const Format = struct { bits: u16, float: bool };
pub const Decoded = struct { audio: Audio, format: Format };

pub fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE");
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (!isWav(bytes)) return error.NotWav;
    var pos: usize = 12;
    var fmt: ?struct { tag: u16, channels: u16, rate: u32, block: u16, bits: u16 } = null;
    var data: ?[]const u8 = null;
    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const size: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        // A size past the end (streamed files write 0xFFFFFFFF) means "the rest".
        const body = bytes[body_start..@min(bytes.len, body_start +| size)];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.BadWav;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            if (tag == 0xFFFE) {
                if (body.len < 26) return error.BadWav;
                tag = std.mem.readInt(u16, body[24..26], .little); // sub-format GUID starts with the tag
            }
            fmt = .{
                .tag = tag,
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .rate = std.mem.readInt(u32, body[4..8], .little),
                .block = std.mem.readInt(u16, body[12..14], .little),
                .bits = std.mem.readInt(u16, body[14..16], .little),
            };
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
            if (fmt != null) break;
        }
        pos = body_start +| size;
        pos +|= size & 1; // chunks are padded to even sizes
    }
    const f = fmt orelse return error.BadWav;
    const d = data orelse return error.BadWav;
    if (f.channels == 0 or f.rate == 0) return error.BadWav;
    // Rates and channel counts no recording has (and the analysis can't use).
    if (f.rate < min_rate or f.rate > max_rate or f.channels > max_channels) return error.UnsupportedLayout;
    const float = switch (f.tag) {
        1 => false,
        3 => true,
        else => return error.UnsupportedWav,
    };
    const bytes_per = f.bits / 8;
    const ok_bits = if (float) (f.bits == 32 or f.bits == 64) else (f.bits == 8 or f.bits == 16 or f.bits == 24 or f.bits == 32);
    if (!ok_bits or f.bits % 8 != 0 or @as(u32, f.block) < @as(u32, bytes_per) * f.channels) return error.UnsupportedWav;

    const n_frames = d.len / f.block;
    const out = try alloc.alloc(f32, n_frames * f.channels);
    errdefer alloc.free(out);
    for (0..n_frames) |i| {
        const fr = d[i * f.block ..];
        for (0..f.channels) |c| {
            const p = fr[c * bytes_per ..];
            out[i * f.channels + c] = switch (f.bits) {
                8 => (@as(f32, @floatFromInt(p[0])) - 128.0) / 128.0,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, p[0..2], .little))) / 32768.0,
                24 => @as(f32, @floatFromInt(std.mem.readInt(i24, p[0..3], .little))) / 8388608.0,
                32 => if (float)
                    @bitCast(std.mem.readInt(u32, p[0..4], .little))
                else
                    @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, p[0..4], .little))) / 2147483648.0),
                64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, p[0..8], .little)))),
                else => unreachable,
            };
        }
    }
    return .{ .audio = .{ .rate = f.rate, .channels = f.channels, .samples = out }, .format = .{ .bits = f.bits, .float = float } };
}

/// The file as WAV bytes, PCM with `bits` 16 or 24. Samples are clamped to full scale.
pub fn encode(alloc: std.mem.Allocator, a: Audio, bits: u16) ![]u8 {
    std.debug.assert(bits == 16 or bits == 24);
    const bytes_per: u32 = bits / 8;
    // a RIFF file stops at 4 GB
    if (a.samples.len * bytes_per + 44 > std.math.maxInt(u32)) return error.FileTooBig;
    const data_len: u32 = @intCast(a.samples.len * bytes_per);
    const out = try alloc.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], a.channels, .little);
    std.mem.writeInt(u32, out[24..28], a.rate, .little);
    std.mem.writeInt(u32, out[28..32], a.rate * a.channels * bytes_per, .little);
    std.mem.writeInt(u16, out[32..34], @intCast(a.channels * bytes_per), .little);
    std.mem.writeInt(u16, out[34..36], bits, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    var p: usize = 44;
    // The same scale as decoding (x / 32768), so samples read from a file of
    // this bit depth and left alone are written back exactly.
    for (a.samples) |x| {
        if (bits == 16) {
            std.mem.writeInt(i16, out[p..][0..2], @intFromFloat(std.math.clamp(@round(@as(f64, x) * 32768.0), -32768.0, 32767.0)), .little);
        } else {
            std.mem.writeInt(i24, out[p..][0..3], @intFromFloat(std.math.clamp(@round(@as(f64, x) * 8388608.0), -8388608.0, 8388607.0)), .little);
        }
        p += bytes_per;
    }
    return out;
}

/// Writes `a` to `path` as WAV (replacing it).
pub fn write(alloc: std.mem.Allocator, path: []const u8, a: Audio, bits: u16) !void {
    const bytes = try encode(alloc, a, bits);
    defer alloc.free(bytes);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

// ---- tests ----

const testing = std.testing;

test "wav_16bit_roundtrip" {
    var s = [_]f32{ 0, 0.5, -0.5, 1, -1, 0.25 };
    const a = Audio{ .rate = 22050, .channels = 2, .samples = &s };
    const bytes = try encode(testing.allocator, a, 16);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 44 + 12), bytes.len);
    var d = try decode(testing.allocator, bytes);
    defer d.audio.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 22050), d.audio.rate);
    try testing.expectEqual(@as(u16, 2), d.audio.channels);
    try testing.expectEqual(Format{ .bits = 16, .float = false }, d.format);
    for (s, d.audio.samples) |want, got| try testing.expectApproxEqAbs(want, got, 1.0 / 16000.0);
}

test "pcm_read_and_written_back_is_unchanged" {
    var pcm: [8]u8 = undefined;
    const vals = [_]i16{ 32767, -32768, 1, -1 };
    for (vals, 0..) |v, i| std.mem.writeInt(i16, pcm[i * 2 ..][0..2], v, .little);
    var buf: [56 + 8]u8 = undefined;
    const p = header(&buf, 1, 1, 8000, 16, 8);
    @memcpy(buf[p..][0..8], &pcm);
    var d = try decode(testing.allocator, &buf);
    defer d.audio.deinit(testing.allocator);
    const again = try encode(testing.allocator, d.audio, 16);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, &pcm, again[44..]);
}

test "wav_24bit_roundtrip" {
    var s = [_]f32{ 0.123456, -0.654321, 0.999 };
    const bytes = try encode(testing.allocator, .{ .rate = 48000, .channels = 1, .samples = &s }, 24);
    defer testing.allocator.free(bytes);
    var d = try decode(testing.allocator, bytes);
    defer d.audio.deinit(testing.allocator);
    for (s, d.audio.samples) |want, got| try testing.expectApproxEqAbs(want, got, 1e-6);
}

fn header(buf: []u8, tag: u16, channels: u16, rate: u32, bits: u16, data_len: u32) usize {
    const block: u16 = @truncate(@as(u32, channels) * (bits / 8)); // as a broken header might say
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 0xFFFFFFFF, .little);
    @memcpy(buf[8..12], "WAVE");
    // an unknown chunk with an odd size first (padded)
    @memcpy(buf[12..16], "LIST");
    std.mem.writeInt(u32, buf[16..20], 3, .little);
    @memset(buf[20..24], 0);
    @memcpy(buf[24..28], "fmt ");
    std.mem.writeInt(u32, buf[28..32], 16, .little);
    std.mem.writeInt(u16, buf[32..34], tag, .little);
    std.mem.writeInt(u16, buf[34..36], channels, .little);
    std.mem.writeInt(u32, buf[36..40], rate, .little);
    std.mem.writeInt(u32, buf[40..44], rate *% block, .little);
    std.mem.writeInt(u16, buf[44..46], block, .little);
    std.mem.writeInt(u16, buf[46..48], bits, .little);
    @memcpy(buf[48..52], "data");
    std.mem.writeInt(u32, buf[52..56], data_len, .little);
    return 56;
}

test "wav_float_with_padded_chunk_and_streamed_size" {
    var buf: [56 + 8]u8 = undefined;
    const p = header(&buf, 3, 1, 16000, 32, 0xFFFFFFFF);
    std.mem.writeInt(u32, buf[p..][0..4], @bitCast(@as(f32, 0.75)), .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], @bitCast(@as(f32, -0.25)), .little);
    var d = try decode(testing.allocator, &buf);
    defer d.audio.deinit(testing.allocator);
    try testing.expectEqualSlices(f32, &.{ 0.75, -0.25 }, d.audio.samples);
    try testing.expect(d.format.float);
}

test "wav_8bit_is_unsigned" {
    var buf: [56 + 3]u8 = undefined;
    const p = header(&buf, 1, 1, 8000, 8, 3);
    buf[p] = 128;
    buf[p + 1] = 255;
    buf[p + 2] = 0;
    var d = try decode(testing.allocator, &buf);
    defer d.audio.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 0), d.audio.samples[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 127.0 / 128.0), d.audio.samples[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), d.audio.samples[2], 1e-6);
}

test "impossible_rates_and_channel_counts_are_refused" {
    var buf: [56]u8 = undefined;
    _ = header(&buf, 1, 1, 50, 16, 0);
    try testing.expectError(error.UnsupportedLayout, decode(testing.allocator, &buf));
    _ = header(&buf, 1, 2, 0xF0000000, 16, 0);
    try testing.expectError(error.UnsupportedLayout, decode(testing.allocator, &buf));
    _ = header(&buf, 1, 100, 8000, 16, 0);
    try testing.expectError(error.UnsupportedLayout, decode(testing.allocator, &buf));
    // 20000 channels of 32-bit: 80000 bytes a frame overflows 16 bits
    _ = header(&buf, 1, 20000, 8000, 32, 0);
    try testing.expectError(error.UnsupportedLayout, decode(testing.allocator, &buf));
}

test "wav_rejects_other_files_and_codecs" {
    try testing.expectError(error.NotWav, decode(testing.allocator, "ID3\x03 not a wav file"));
    var buf: [56]u8 = undefined;
    _ = header(&buf, 2, 1, 8000, 4, 0); // ADPCM
    try testing.expectError(error.UnsupportedWav, decode(testing.allocator, &buf));
    try testing.expectError(error.BadWav, decode(testing.allocator, buf[0..30]));
}
