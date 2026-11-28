//! Reconstructs bounded noninterlaced 8-bit PNG scanlines with zlib-ng.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("../../value.zig");
const format = @import("png_format");
const memory = @import("codec_memory");
const zlib = @import("zlib.zig");
const simd = @import("simd.zig");

const Filter = format.Filter;
const scanline_bytes = simd.scanline_bytes;
const ByteSpan = struct { start: usize, length: usize };
const Block = @Vector(scanline_bytes, u8);
const BlockBytes = [scanline_bytes]u8;

/// Colour types accepted by the noninterlaced 8-bit decoder.
pub const Profile = enum(u8) {
    gray = @backingInt(format.Colour.gray),
    rgb = @backingInt(format.Colour.rgb),
    indexed = @backingInt(format.Colour.indexed),
    rgba = @backingInt(format.Colour.rgba),

    pub fn samplesPerPixel(self: Profile) usize {
        return switch (self) {
            .gray, .indexed => 1,
            .rgb => rgb_channels,
            .rgba => channels,
        };
    }
};

const Chunks = struct {
    idat: ByteSpan,
    palette: []const value.Pixel,
};

const Samples = struct {
    current: []u8,
    previous: []u8,
    colour: union(enum) { gray, indexed: []const value.Pixel },

    fn expand(self: *const Samples, dst: []u8) bool {
        const pixels = std.mem.bytesAsSlice(value.Pixel, dst);
        switch (self.colour) {
            .gray => for (pixels, self.current) |*out, gray| {
                out.* = .{ gray, gray, gray, 255 };
            },
            .indexed => |palette| for (pixels, self.current) |*out, index| {
                if (index >= palette.len) return false;
                out.* = palette[index];
            },
        }
        return true;
    }
};

const Expansion = union(enum) { rgba, rgb: []u8, samples: Samples };

const Rows = struct {
    pixels: []u8,
    partial: []u8,
    expansion: Expansion,
    stride: usize,
    used: usize = 0,
    written: usize = 0,

    pub fn complete(self: *const Rows) bool {
        return self.written == self.pixels.len and self.used == 0;
    }

    pub fn consume(self: *Rows, output: []const u8) bool {
        var raw = output;
        while (raw.len != 0) {
            if (self.used == 0 and raw.len >= self.partial.len) {
                if (!self.write(raw[0..self.partial.len])) return false;
                raw = raw[self.partial.len..];
                continue;
            }
            const take = @min(raw.len, self.partial.len - self.used);
            @memcpy(self.partial[self.used..][0..take], raw[0..take]);
            self.used += take;
            raw = raw[take..];
            if (self.used == self.partial.len) {
                if (!self.write(self.partial)) return false;
                self.used = 0;
            }
        }
        return true;
    }

    fn write(self: *Rows, raw: []const u8) bool {
        if (self.written == self.pixels.len) return false;
        const filter = std.enums.fromInt(Filter, raw[0]) orelse return false;
        const dst = self.pixels[self.written..][0..self.stride];
        const above = if (self.written == 0) null else self.pixels[self.written - self.stride ..][0..self.stride];
        const residue = raw[1..];
        switch (self.expansion) {
            .rgba => unfilter(channels, dst, residue, above, filter),
            .rgb => |expanded| {
                expandRgb(expanded, residue);
                unfilter(channels, dst, expanded, above, filter);
                setOpaque(dst);
            },
            .samples => |*samples| {
                unfilter(1, samples.current, residue, if (above == null) null else samples.previous, filter);
                if (!samples.expand(dst)) return false;
                std.mem.swap([]u8, &samples.current, &samples.previous);
            },
        }
        self.written += self.stride;
        return true;
    }
};

const channels = @sizeOf(value.Pixel);
const rgb_channels = 3;
const rgb_block_bytes = scanline_bytes / channels * rgb_channels;
// The larger span amortizes dictionary updates on Apple silicon.
const inflate_bytes = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) 64 * 1024 else 32 * 1024;

/// Recognizes a noninterlaced 8-bit profile from its IHDR fields.
pub fn streamingProfile(bytes: []const u8) ?Profile {
    if (bytes.len < format.header_bytes or !std.mem.startsWith(u8, bytes, format.header_prefix)) return null;
    const depth, const colour, const compression, const filtering, const interlace = bytes[format.profile_offset..][0..5].*;
    if (depth != format.sample_depth or compression != 0 or filtering != 0 or interlace != 0) return null;
    return std.enums.fromInt(Profile, colour);
}

/// Decodes a validated size into codec-budget-owned pixels, or returns null
/// if the legacy decoder should try.
pub fn decode(bytes: []const u8, size: value.Size) memory.Error!?[]value.Pixel {
    const profile = streamingProfile(bytes) orelse return null;
    var palette: [256]value.Pixel = undefined;
    // Outlining keeps the chunk walk out of the file decoder. On Zig 0.17.1
    // it measured smaller on aarch64-linux-musl and aarch64-windows than
    // automatic inlining. Re-measure on a Zig upgrade.
    const chunks = @call(if (builtin.cpu.arch == .aarch64) .never_inline else .auto, collectChunks, .{ bytes, profile, &palette }) orelse return null;
    const width = size.width;
    const height = size.height;
    if (width != format.readU32(bytes, format.dimensions_offset) or height != format.readU32(bytes, format.dimensions_offset + @sizeOf(u32))) return null;
    const count = width * height;
    const stride = width * channels;
    const input_bytes = width * profile.samplesPerPixel() + 1;
    const expansion_bytes = switch (profile) {
        .gray, .indexed => 2 * width,
        .rgb => stride,
        .rgba => 0,
    };
    // Inflate writes the whole accepted pixel buffer. Scratch is consumed only
    // through rows written by inflate, the split-row copy or the unfilter.
    const pixels = memory.allocBytes(count * channels) orelse return memory.failure();
    var keep = false;
    defer if (!keep) memory.uidiff_codec_free(pixels.ptr);
    const scratch = memory.allocBytes(inflate_bytes + input_bytes + expansion_bytes) orelse return memory.failure();
    defer memory.uidiff_codec_free(scratch.ptr);
    const expansion = scratch[inflate_bytes + input_bytes ..];
    var rows: Rows = .{
        .pixels = pixels,
        .partial = scratch[inflate_bytes..][0..input_bytes],
        .expansion = switch (profile) {
            .rgba => .rgba,
            .rgb => .{ .rgb = expansion },
            .gray, .indexed => .{ .samples = .{
                .current = expansion[0..width],
                .previous = expansion[width..],
                .colour = if (profile == .gray) .gray else .{ .indexed = chunks.palette },
            } },
        },
        .stride = stride,
    };
    if (!try zlib.inflateRows(bytes[chunks.idat.start..][0..chunks.idat.length], inflate_bytes, scratch[0..inflate_bytes], &rows)) return null;
    keep = true;
    return std.mem.bytesAsSlice(value.Pixel, pixels);
}

fn collectChunks(bytes: []const u8, profile: Profile, palette: *[256]value.Pixel) ?Chunks {
    if (format.header_end > bytes.len) return null;
    var chunks: format.Chunks = .{ .remaining = bytes[format.header_end..] };
    var range: ?ByteSpan = null;
    var palette_len: usize = 0;
    var has_alpha = false;
    var start = format.header_end;
    while (chunks.next()) |chunk| {
        // Each successful iterator step advances within the original bytes.
        const end = bytes.len -% chunks.remaining.len;
        const size = chunk.data.len;
        const kind = chunk.kind;
        switch (@as(u32, @bitCast(kind))) {
            @as(u32, @bitCast(@as([4]u8, format.idat_type.*))) => {
                if (profile == .indexed and palette_len == 0) return null;
                if (range) |prior| {
                    if (prior.start + prior.length != start) return null;
                    range = .{ .start = prior.start, .length = end - prior.start };
                } else range = .{ .start = start, .length = end - start };
            },
            @as(u32, @bitCast(@as([4]u8, format.iend_type.*))) => {
                if (size != 0) return null;
                return .{ .idat = range orelse return null, .palette = palette[0..palette_len] };
            },
            @as(u32, @bitCast(@as([4]u8, format.plte_type.*))) => {
                if (profile != .indexed or range != null or palette_len != 0) return null;
                if (size == 0 or size % rgb_channels != 0 or size > palette.len * rgb_channels) return null;
                const data = chunk.data;
                palette_len = @divExact(size, rgb_channels);
                for (palette[0..palette_len], std.mem.bytesAsSlice([rgb_channels]u8, data)) |*pixel, rgb| {
                    pixel.* = rgb ++ [1]u8{255};
                }
            },
            @as(u32, @bitCast(@as([4]u8, format.trns_type.*))) => {
                if (profile != .indexed or range != null or has_alpha or palette_len == 0 or size > palette_len) return null;
                const data = chunk.data;
                for (palette[0..size], data) |*pixel, alpha| pixel[3] = alpha;
                has_alpha = true;
            },
            @as(u32, @bitCast(@as([4]u8, "acTL".*))) => return null,
            else => if (kind[0] & 32 == 0) return null,
        }
        start = end;
    }
    return null;
}

fn unfilter(comptime lanes: usize, dst: []u8, src: []const u8, above: ?[]const u8, filter: Filter) void {
    switch (filter) {
        .none => @memcpy(dst, src),
        .sub => sub(lanes, dst, src),
        .up => if (above) |up| addUp(dst, src, up) else @memcpy(dst, src),
        .average => average(lanes, dst, src, above),
        .paeth => if (above) |up| paeth(lanes, dst, src, up) else sub(lanes, dst, src),
    }
}

fn sub(comptime lanes: usize, dst: []u8, src: []const u8) void {
    const end = dst.len - dst.len % scanline_bytes;
    var carry: Block = @splat(0);
    for (blocks(dst[0..end]), blocks(src[0..end])) |*out, *raw| {
        carry = prefixAdd(lanes, out, raw, carry);
    }
    var left: @Vector(lanes, u8) = @as(BlockBytes, carry)[0..lanes].*;
    for (std.mem.bytesAsSlice([lanes]u8, dst[end..]), std.mem.bytesAsSlice([lanes]u8, src[end..])) |*out, raw| {
        left +%= raw;
        out.* = left;
    }
}

fn addUp(dst: []u8, src: []const u8, up: []const u8) void {
    const end = dst.len - dst.len % scanline_bytes;
    for (blocks(dst[0..end]), blocks(src[0..end]), blocks(up[0..end])) |*out, raw, prev| {
        out.* = @as(Block, raw) +% prev;
    }
    for (dst[end..], src[end..], up[end..]) |*out, raw, prev| out.* = raw +% prev;
}

fn average(comptime lanes: usize, dst: []u8, src: []const u8, above: ?[]const u8) void {
    const pixels = std.mem.bytesAsSlice([lanes]u8, dst);
    const residuals = std.mem.bytesAsSlice([lanes]u8, src);
    var left: @Vector(lanes, u8) = @splat(0);
    if (above) |prev| {
        for (pixels, residuals, std.mem.bytesAsSlice([lanes]u8, prev)) |*out, raw, up| {
            left = averagePixel(lanes, left, up, raw);
            out.* = left;
        }
    } else {
        for (pixels, residuals) |*out, raw| {
            left = averagePixel(lanes, left, @splat(0), raw);
            out.* = left;
        }
    }
}

fn averagePixel(comptime lanes: usize, left: @Vector(lanes, u8), up: @Vector(lanes, u8), raw: @Vector(lanes, u8)) @Vector(lanes, u8) {
    const wide_left: @Vector(lanes, i16) = @intCast(left);
    const wide_up: @Vector(lanes, i16) = @intCast(up);
    return raw +% @as(@Vector(lanes, u8), @intCast((wide_left + wide_up) >> @splat(1)));
}

fn paethPixel(comptime lanes: usize, lhs: @Vector(lanes, u8), up: @Vector(lanes, u8), upper_left: @Vector(lanes, u8)) @Vector(lanes, u8) {
    const Wide = @Vector(lanes, i16);
    const left: Wide = @intCast(lhs);
    const upper: Wide = @intCast(up);
    const diagonal: Wide = @intCast(upper_left);
    const low = @min(left, upper);
    const high = @max(left, upper);
    const threshold = @as(Wide, @splat(3)) * diagonal - (left + upper);
    const middle = @select(i16, high <= threshold, low, diagonal);
    const prediction = @select(i16, threshold <= low, high, middle);
    // Paeth selects one of the three input bytes.
    return @intCast(prediction);
}

fn paeth(comptime lanes: usize, dst: []u8, src: []const u8, above: []const u8) void {
    const Sample = @Vector(lanes, u8);
    var upper_left: Sample = above[0..lanes].*;
    var left = upper_left +% @as(Sample, src[0..lanes].*);
    dst[0..lanes].* = left;

    var out = dst[lanes..];
    var raw = src[lanes..];
    var up = above[lanes..];
    while (out.len != 0) {
        const corner = repeatSample(lanes, upper_left);
        if (out.len >= scanline_bytes and @reduce(.And, @as(Block, up[0..scanline_bytes].*) == corner)) {
            // Over a flat row above, Paeth predicts the left sample: keep the
            // carry in a vector for the whole run.
            var carry = repeatSample(lanes, left);
            var i: usize = 0;
            while (true) {
                carry = prefixAdd(lanes, out[i..][0..scanline_bytes], raw[i..][0..scanline_bytes], carry);
                i += scanline_bytes;
                if (out.len - i < scanline_bytes or !@reduce(.And, @as(Block, up[i..][0..scanline_bytes].*) == corner)) break;
            }
            left = @as(BlockBytes, carry)[0..lanes].*;
            out = out[i..];
            raw = raw[i..];
            up = up[i..];
            continue;
        }
        const upper: Sample = up[0..lanes].*;
        left = @as(Sample, raw[0..lanes].*) +% paethPixel(lanes, left, upper, upper_left);
        upper_left = upper;
        out[0..lanes].* = left;
        out = out[lanes..];
        raw = raw[lanes..];
        up = up[lanes..];
    }
}

fn blocks(bytes: anytype) @TypeOf(std.mem.bytesAsSlice(BlockBytes, bytes)) {
    return std.mem.bytesAsSlice(BlockBytes, bytes);
}

fn repeatSample(comptime lanes: usize, sample: @Vector(lanes, u8)) Block {
    const mask = comptime mask: {
        var indices: [scanline_bytes]i32 = undefined;
        for (&indices, 0..) |*index, i| index.* = @intCast(i % lanes);
        break :mask indices;
    };
    return @shuffle(u8, sample, undefined, mask);
}

fn prefixAdd(comptime lanes: usize, dst: *BlockBytes, src: *const BlockBytes, carry: Block) Block {
    const zero: Block = @splat(0);
    var v: Block = src.*;
    comptime var shift = lanes;
    inline while (shift < scanline_bytes) : (shift *= 2) {
        const mask = comptime mask: {
            var indices: [scanline_bytes]i32 = undefined;
            for (&indices, 0..) |*index, i| index.* = if (i < shift) @intCast(i) else -1 - @as(i32, @intCast(i - shift));
            break :mask indices;
        };
        v +%= @shuffle(u8, zero, v, mask);
    }
    v +%= carry;
    dst.* = v;
    return repeatSample(lanes, @as(BlockBytes, v)[scanline_bytes - lanes ..][0..lanes].*);
}

fn expandRgb(dst: []u8, src: []const u8) void {
    const end = src.len - src.len % rgb_block_bytes;
    const rgb_end = end / rgb_channels * channels;
    const zero: @Vector(4, u8) = @splat(0);
    for (blocks(dst[0..rgb_end]), std.mem.bytesAsSlice([rgb_block_bytes]u8, src[0..end])) |*out, raw| {
        const rgb: @Vector(rgb_block_bytes, u8) = raw;
        out.* = @shuffle(u8, rgb, zero, @Vector(scanline_bytes, i32){
            0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8, -1, 9, 10, 11, -1,
        });
    }
    for (std.mem.bytesAsSlice(value.Pixel, dst[rgb_end..]), std.mem.bytesAsSlice([rgb_channels]u8, src[end..])) |*out, raw| {
        out.* = raw ++ [1]u8{0};
    }
}

fn setOpaque(dst: []u8) void {
    const alpha = repeatSample(channels, .{ 0, 0, 0, 255 });
    const end = dst.len - dst.len % scanline_bytes;
    for (blocks(dst[0..end])) |*out| out.* = @as(Block, out.*) | alpha;
    for (std.mem.bytesAsSlice(value.Pixel, dst[end..])) |*out| out[3] = 255;
}

test {
    std.testing.refAllDecls(@This());
}
