//! Reconstructs bounded RGB8 and RGBA8 PNG scanlines with zlib-ng.
const std = @import("std");
const builtin = @import("builtin");
const values = @import("../../value.zig");
const format = @import("../png_format.zig");
const memory = @import("codec_memory");
const zlib = @import("zlib_c");

const Filter = enum(u8) { none, sub, up, average, paeth };
const Range = struct { first: usize, end: usize };
const Pixel = @Vector(4, u8);
const Wide = @Vector(4, i16);
const Block = @Vector(vector_bytes, u8);
const BlockBytes = [vector_bytes]u8;
const Words = @Vector(vector_bytes / @sizeOf(u32), u32);

const Paeth = struct {
    left: Pixel,
    upper_left: Pixel,

    fn pixels(self: *Paeth, dst: []values.Pixel, src: []const values.Pixel, above: []const values.Pixel) void {
        for (dst, src, above) |*out, raw, up| {
            const left = widen(self.left);
            const upper = widen(up);
            const diagonal = widen(self.upper_left);
            const low = @min(left, upper);
            const high = @max(left, upper);
            const threshold = @as(Wide, @splat(3)) * diagonal - (left + upper);
            const middle = @select(i16, high <= threshold, low, diagonal);
            const prediction = @select(i16, threshold <= low, high, middle);
            // Paeth selects one of the three input bytes.
            const delta: Pixel = @intCast(prediction);
            self.left = @as(Pixel, raw) +% delta;
            self.upper_left = up;
            out.* = self.left;
        }
    }
};

const Rows = struct {
    pixels: []u8,
    partial: []u8,
    expanded: []u8,
    stride: usize,
    used: usize = 0,
    written: usize = 0,

    fn consume(self: *Rows, output: []const u8) bool {
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
        const rgb = self.expanded.len != 0;
        const dst = self.pixels[self.written..][0..self.stride];
        const above = if (self.written == 0) null else self.pixels[self.written - self.stride ..][0..self.stride];
        const residue = if (rgb) expanded: {
            const expanded = self.expanded[0..self.stride];
            expandRgb(expanded, raw[1..]);
            break :expanded expanded;
        } else raw[1..][0..self.stride];
        unfilter(dst, residue, above, filter);
        if (rgb) setOpaque(dst);
        self.written += self.stride;
        return true;
    }
};

const channels = @sizeOf(values.Pixel);
const rgb_channels = 3;
const vector_bytes = 16;
const block_bytes = vector_bytes;
const rgb_block_bytes = block_bytes / channels * rgb_channels;
const chunk_overhead = 3 * @sizeOf(u32);
const chunk_prefix = 2 * @sizeOf(u32);
// The larger span amortizes dictionary updates on Apple silicon.
const inflate_bytes = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) 64 * 1024 else 32 * 1024;

/// Recognizes the noninterlaced RGB8 and RGBA8 profiles.
pub fn streamingHeader(bytes: []const u8) bool {
    if (bytes.len < format.header_bytes or !std.mem.startsWith(u8, bytes, format.header_prefix)) return false;
    const profile = bytes[format.profile_offset..][0..5];
    return profile[0] == format.sample_depth and (profile[1] == format.rgb_color or profile[1] == format.rgba_color) and
        profile[2] == 0 and profile[3] == 0 and profile[4] == 0;
}

/// Returns codec-budget-owned pixels, or null if the legacy decoder should try.
pub fn decode(bytes: []const u8, size: values.Size) memory.Error!?[]values.Pixel {
    const range = idatRange(bytes) orelse return null;
    const width = size.width;
    const height = size.height;
    if (width != be32(bytes, format.dimensions_offset) or height != be32(bytes, format.dimensions_offset + @sizeOf(u32))) return null;
    const count = size.pixelCount() orelse return null;
    const stride = width * channels;
    const rgb = bytes[format.color_offset] == format.rgb_color;
    const input_bytes = width * (if (rgb) @as(usize, rgb_channels) else channels) + 1;
    const scratch_bytes = inflate_bytes + input_bytes + (if (rgb) stride else 0);
    // Inflate writes the whole accepted pixel buffer. Scratch is consumed only
    // through bytes written by inflate or by the split-row copy.
    const pixels = memory.allocBytes(count * channels) orelse return memory.failure();
    var keep = false;
    defer if (!keep) memory.uidiff_codec_free(pixels.ptr);
    const scratch = memory.allocBytes(scratch_bytes) orelse return memory.failure();
    defer memory.uidiff_codec_free(scratch.ptr);
    var rows: Rows = .{
        .pixels = pixels,
        .partial = scratch[inflate_bytes..][0..input_bytes],
        .expanded = scratch[inflate_bytes + input_bytes .. scratch_bytes],
        .stride = stride,
    };
    if (!try inflateRows(bytes, range, scratch[0..inflate_bytes], &rows)) return null;
    keep = true;
    return std.mem.bytesAsSlice(values.Pixel, pixels);
}

fn idatRange(bytes: []const u8) ?Range {
    if (!streamingHeader(bytes)) return null;
    var pos: usize = format.header_bytes + @sizeOf(u32);
    if (pos > bytes.len) return null;
    var range: ?Range = null;
    while (bytes.len - pos >= chunk_overhead) {
        const size = be32(bytes, pos);
        if (size > bytes.len - pos - chunk_overhead) return null;
        const next = pos + size + chunk_overhead;
        const kind = bytes[pos + @sizeOf(u32) ..][0..4].*;
        switch (@as(u32, @bitCast(kind))) {
            @as(u32, @bitCast(@as([4]u8, "IDAT".*))) => {
                if (range) |prior| {
                    if (prior.end != pos) return null;
                    range = .{ .first = prior.first, .end = next };
                } else range = .{ .first = pos, .end = next };
            },
            @as(u32, @bitCast(@as([4]u8, "IEND".*))) => return if (size == 0) range else null,
            @as(u32, @bitCast(@as([4]u8, "tRNS".*))), @as(u32, @bitCast(@as([4]u8, "acTL".*))) => return null,
            else => if (kind[0] & 32 == 0) return null,
        }
        pos = next;
    }
    return null;
}

fn be32(bytes: []const u8, pos: usize) usize {
    return std.mem.readInt(u32, bytes[pos..][0..@sizeOf(u32)], .big);
}

fn inflateRows(bytes: []const u8, range: Range, output: *[inflate_bytes]u8, rows: *Rows) memory.Error!bool {
    // Match the legacy checksum policy, leaving unusual header/trailer splits
    // to that decoder. The zlib header bounds the raw dictionary to 32 KiB.
    if (be32(bytes, range.first) < 2) return false;
    const cmf, const flg = bytes[range.first + chunk_prefix ..][0..2].*;
    if (cmf & 15 != zlib.Z_DEFLATED or cmf >> 4 > 7 or flg & 32 != 0 or (@as(u16, cmf) * 256 + flg) % 31 != 0) return false;
    var stream: zlib.zng_stream = std.mem.zeroes(zlib.zng_stream);
    stream.zalloc = zalloc;
    stream.zfree = zfree;
    switch (zlib.zng_inflateInit2(&stream, -(@as(c_int, cmf >> 4) + 8))) {
        zlib.Z_OK => {},
        zlib.Z_MEM_ERROR => return memory.failure(),
        else => return false,
    }
    const success = consumeIdats(bytes, range, output, rows, &stream);
    const closed = zlib.zng_inflateEnd(&stream) == zlib.Z_OK;
    return (try success) and closed;
}

fn consumeIdats(bytes: []const u8, range: Range, output: *[inflate_bytes]u8, rows: *Rows, stream: *zlib.zng_stream) memory.Error!bool {
    var pos = range.first;
    while (pos < range.end) {
        const available = be32(bytes, pos);
        const src = bytes[pos + chunk_prefix ..][0..available];
        const head: usize = if (pos == range.first) 2 else 0;
        pos += available + chunk_overhead;
        const tail: usize = if (pos == range.end) 4 else 0;
        if (available < head + tail) return false;
        stream.next_in = src[head..].ptr;
        // The chunk length originates in a validated u32 PNG length.
        stream.avail_in = @intCast(available - head - tail);
        while (true) {
            stream.next_out = output;
            stream.avail_out = inflate_bytes;
            const status = zlib.zng_inflate(stream, zlib.Z_NO_FLUSH);
            switch (status) {
                zlib.Z_OK, zlib.Z_STREAM_END, zlib.Z_BUF_ERROR => {},
                zlib.Z_MEM_ERROR => return memory.failure(),
                else => return false,
            }
            if (!rows.consume(output[0 .. inflate_bytes - stream.avail_out])) return false;
            if (status == zlib.Z_STREAM_END) return rows.written == rows.pixels.len and rows.used == 0;
            if (stream.avail_out != 0 and stream.avail_in == 0) break;
            if (status == zlib.Z_BUF_ERROR) return false;
        }
    }
    return false;
}

fn zalloc(_: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    return memory.uidiff_codec_malloc(std.math.mul(usize, items, size) catch return null);
}

fn zfree(_: ?*anyopaque, block: ?*anyopaque) callconv(.c) void {
    memory.uidiff_codec_free(block);
}

fn unfilter(dst: []u8, src: []const u8, above: ?[]const u8, filter: Filter) void {
    switch (filter) {
        .none => @memcpy(dst, src),
        .sub => sub(dst, src),
        .up => if (above) |up| addUp(dst, src, up) else @memcpy(dst, src),
        .average => average(dst, src, above),
        .paeth => if (above) |up| paeth(dst, src, up) else sub(dst, src),
    }
}

fn sub(dst: []u8, src: []const u8) void {
    const end = dst.len - dst.len % block_bytes;
    var carry: Block = @splat(0);
    for (blocks(dst[0..end]), blocks(src[0..end])) |*out, *raw| {
        carry = prefixAdd(out, raw, carry);
    }
    var left = firstPixel(carry);
    for (std.mem.bytesAsSlice(values.Pixel, dst[end..]), std.mem.bytesAsSlice(values.Pixel, src[end..])) |*out, raw| {
        left +%= raw;
        out.* = left;
    }
}

fn addUp(dst: []u8, src: []const u8, up: []const u8) void {
    const end = dst.len - dst.len % block_bytes;
    for (blocks(dst[0..end]), blocks(src[0..end]), blocks(up[0..end])) |*out, raw, prev| {
        out.* = @as(Block, raw) +% prev;
    }
    for (dst[end..], src[end..], up[end..]) |*out, raw, prev| out.* = raw +% prev;
}

fn average(dst: []u8, src: []const u8, above: ?[]const u8) void {
    const pixels = std.mem.bytesAsSlice(values.Pixel, dst);
    const residuals = std.mem.bytesAsSlice(values.Pixel, src);
    var left: Pixel = @splat(0);
    if (above) |prev| {
        for (pixels, residuals, std.mem.bytesAsSlice(values.Pixel, prev)) |*out, raw, up| {
            left = averagePixel(left, up, raw);
            out.* = left;
        }
    } else {
        for (pixels, residuals) |*out, raw| {
            left = averagePixel(left, @splat(0), raw);
            out.* = left;
        }
    }
}

fn averagePixel(left: Pixel, up: Pixel, raw: Pixel) Pixel {
    const prediction = (widen(left) + widen(up)) >> @splat(1);
    return raw +% @as(Pixel, @intCast(prediction));
}

fn paeth(dst: []u8, src: []const u8, above: []const u8) void {
    const first_up: Pixel = above[0..channels].*;
    const first_raw: Pixel = src[0..channels].*;
    var predictor: Paeth = .{ .left = first_up +% first_raw, .upper_left = first_up };
    dst[0..channels].* = predictor.left;

    var out = dst[channels..];
    var raw = src[channels..];
    var up = above[channels..];
    while (out.len != 0) {
        const corner = repeatPixel(predictor.upper_left);
        if (out.len >= vector_bytes and @reduce(.And, @as(Block, up[0..vector_bytes].*) == corner)) {
            // Over a flat row above, Paeth predicts the left pixel: keep the
            // carry in a vector for the whole run.
            var carry = repeatPixel(predictor.left);
            var i: usize = 0;
            while (true) {
                carry = prefixAdd(out[i..][0..vector_bytes], raw[i..][0..vector_bytes], carry);
                i += vector_bytes;
                if (out.len - i < vector_bytes or !@reduce(.And, @as(Block, up[i..][0..vector_bytes].*) == corner)) break;
            }
            predictor.left = firstPixel(carry);
            out = out[i..];
            raw = raw[i..];
            up = up[i..];
            continue;
        }
        predictor.pixels(std.mem.bytesAsSlice(values.Pixel, out[0..channels]), std.mem.bytesAsSlice(values.Pixel, raw[0..channels]), std.mem.bytesAsSlice(values.Pixel, up[0..channels]));
        out = out[channels..];
        raw = raw[channels..];
        up = up[channels..];
    }
}

fn blocks(bytes: anytype) @TypeOf(std.mem.bytesAsSlice(BlockBytes, bytes)) {
    return std.mem.bytesAsSlice(BlockBytes, bytes);
}

fn widen(pixel: Pixel) Wide {
    return @intCast(pixel);
}

fn repeatPixel(pixel: Pixel) Block {
    return @bitCast(@as(Words, @splat(@bitCast(pixel))));
}

fn firstPixel(block: Block) Pixel {
    return @bitCast(@as(Words, @bitCast(block))[0]);
}

fn prefixAdd(dst: *BlockBytes, src: *const BlockBytes, carry: Block) Block {
    const zero: Block = @splat(0);
    var v: Block = src.*;
    v +%= @shuffle(u8, zero, v, @Vector(16, i32){ 0, 1, 2, 3, -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12 });
    v +%= @shuffle(u8, zero, v, @Vector(16, i32){ 0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8 });
    v +%= carry;
    dst.* = v;
    return @bitCast(@as(Words, @splat(@as(Words, @bitCast(v))[3])));
}

fn expandRgb(dst: []u8, src: []const u8) void {
    const end = src.len - src.len % rgb_block_bytes;
    const rgb_end = end / rgb_channels * channels;
    const zero: @Vector(4, u8) = @splat(0);
    for (blocks(dst[0..rgb_end]), std.mem.bytesAsSlice([rgb_block_bytes]u8, src[0..end])) |*out, raw| {
        const rgb: @Vector(rgb_block_bytes, u8) = raw;
        out.* = @shuffle(u8, rgb, zero, @Vector(16, i32){
            0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8, -1, 9, 10, 11, -1,
        });
    }
    for (std.mem.bytesAsSlice(values.Pixel, dst[rgb_end..]), std.mem.bytesAsSlice([rgb_channels]u8, src[end..])) |*out, raw| {
        out.* = raw ++ [1]u8{0};
    }
}

fn setOpaque(dst: []u8) void {
    const alpha = repeatPixel(.{ 0, 0, 0, 255 });
    const end = dst.len - dst.len % block_bytes;
    for (blocks(dst[0..end])) |*out| out.* = @as(Block, out.*) | alpha;
    for (std.mem.bytesAsSlice(values.Pixel, dst[end..])) |*out| out[3] = 255;
}

test {
    std.testing.refAllDecls(@This());
}
