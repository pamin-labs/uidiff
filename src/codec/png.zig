//! Streams PNG decode and encode through bounded zlib buffers.
const std = @import("std");
const builtin = @import("builtin");
const values = @import("../value.zig");
const png_format = @import("png_format.zig");
const stb = @import("stb.zig");
const scanlines = @import("png_scanlines.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const zlib = @import("zlib_c");
const Image = values.Image;

/// Malformed PNG bytes, a decode past the memory budget, or allocation failure.
pub const DecodeError = stb.DecodeError;

/// Probes the dimensions and channel depth.
pub const probe = stb.probe;
/// Releases decoded pixels through their PNG or fallback allocator.
pub const release = stb.release;

/// Allocation, invalid image or output failures.
pub const EncodeError = Allocator.Error || Writer.Error || Image.Invalid;

/// zlib-ng's streaming compressor. Each full output buffer becomes one
/// IDAT chunk, so the encoder needs no room for the whole compressed stream.
const Deflater = struct {
    stream: zlib.zng_stream,
    output: *Writer,
    out: []u8,

    const header_bytes = 16;

    fn init(self: *Deflater, allocator: *Allocator, output: *Writer, out: []u8) EncodeError!void {
        self.* = .{ .stream = std.mem.zeroes(zlib.zng_stream), .output = output, .out = out };
        self.stream.zalloc = zalloc;
        self.stream.zfree = zfree;
        self.stream.@"opaque" = allocator;
        self.stream.next_out = out.ptr;
        self.stream.avail_out = @intCast(out.len);
        switch (zlib.zng_deflateInit2(&self.stream, zlib.UIDIFF_PNG_COMPRESSION_LEVEL, zlib.Z_DEFLATED, window_bits, memory_level, zlib.Z_DEFAULT_STRATEGY)) {
            zlib.Z_OK => {},
            zlib.Z_MEM_ERROR => return error.OutOfMemory,
            else => return error.WriteFailed,
        }
    }

    fn deinit(self: *Deflater) void {
        const status = zlib.zng_deflateEnd(&self.stream);
        // A failing output writer can leave the stream unfinished.
        std.debug.assert(status == zlib.Z_OK or status == zlib.Z_DATA_ERROR);
    }

    fn write(self: *Deflater, bytes: []const u8) EncodeError!void {
        self.stream.next_in = bytes.ptr;
        self.stream.avail_in = @intCast(bytes.len);
        while (self.stream.avail_in != 0) {
            if (zlib.zng_deflate(&self.stream, zlib.Z_NO_FLUSH) != zlib.Z_OK) return error.WriteFailed;
            if (self.stream.avail_out == 0) try self.emit();
        }
    }

    fn finish(self: *Deflater) EncodeError!void {
        self.stream.avail_in = 0;
        while (true) {
            const status = zlib.zng_deflate(&self.stream, zlib.Z_FINISH);
            if (status == zlib.Z_STREAM_END) break;
            if (status != zlib.Z_OK) return error.WriteFailed;
            if (self.stream.avail_out == 0) try self.emit();
        }
        if (self.stream.avail_out != self.out.len) try self.emit();
    }

    fn emit(self: *Deflater) Writer.Error!void {
        try chunk(self.output, "IDAT", self.out[0 .. self.out.len - self.stream.avail_out]);
        self.stream.next_out = self.out.ptr;
        self.stream.avail_out = @intCast(self.out.len);
    }

    fn zalloc(context: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
        const allocator: *const Allocator = @ptrCast(@alignCast(context));
        const bytes = std.math.mul(usize, items, size) catch return null;
        const total = std.math.add(usize, bytes, header_bytes) catch return null;
        const block = if (builtin.mode == .debug)
            (allocator.alignedAlloc(u8, .@"16", total) catch return null).ptr
        else
            allocator.rawAlloc(total, .@"16", @returnAddress()) orelse return null;
        std.mem.writeInt(usize, block[0..@sizeOf(usize)], total, .little);
        return block + header_bytes;
    }

    fn zfree(context: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        const allocator: *const Allocator = @ptrCast(@alignCast(context));
        const data: [*]align(16) u8 = @ptrCast(@alignCast(address orelse return));
        const base: [*]align(16) u8 = @alignCast(data - header_bytes);
        const bytes = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
        if (builtin.mode == .debug) allocator.free(base[0..bytes]) else allocator.rawFree(base[0..bytes], .@"16", @returnAddress());
    }
};

const BorrowedRows = struct {
    image: Image,

    pub fn isOpaque(self: BorrowedRows) bool {
        return self.image.isOpaque();
    }

    pub fn row(self: BorrowedRows, y: usize, _: []values.Pixel) []const values.Pixel {
        return self.image.row(y);
    }
};

/// Up filtering turns stationary areas into runs of zero bytes.
const up_filter = 2;
const sub_filter = 1;
const paeth_filter = 4;
const filter_sample_pixels = 6;
const filter_switch_margin = 4;
/// Compressed bytes per IDAT chunk.
const chunk_bytes = 64 * 1024;
const window_bits = 15;
const memory_level = 8;

/// Recognizes the PNG signature.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, png_format.signature);
}

/// Decodes the probed dimensions through the scanline or legacy decoder.
pub fn decode(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) stb.DecodeError![]values.Pixel {
    return (try load(allocator, bytes, header, cap))[0 .. header.size.width * header.size.height];
}

/// Recognizes noninterlaced RGB8 and RGBA8 without decoding the image.
pub fn streamingHeader(bytes: []const u8) bool {
    return scanlines.streamingHeader(bytes);
}

/// Runs bounded scanline decoding. Null requests the legacy fallback.
pub fn loadStreaming(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) DecodeError!?[*]values.Pixel {
    return stb.withDecodeBudget(streamPixels, allocator, bytes, header, cap);
}

/// Encodes a valid image. Allocates the compressor's window and one filtered row.
pub fn write(allocator: Allocator, image: Image, output: *Writer) EncodeError!void {
    if (!image.valid()) return error.InvalidImage;
    return writeRows(allocator, image.size(), BorrowedRows{ .image = image }, output);
}

/// Encodes a source that supplies one row at a time. BorrowedRows can return
/// existing pixels. Other sources fill the provided row buffer.
/// Sources may supply isOpaque for RGB output.
pub fn writeRows(allocator: Allocator, size: values.Size, source: anytype, output: *Writer) EncodeError!void {
    if (!@hasDecl(@TypeOf(source), "row"))
        @compileError("a PNG row source must provide row(y, scratch)");
    if (size.pixelCount() == null) return error.InvalidImage;
    try output.writeAll(png_format.signature);
    const rgb_only = if (@hasDecl(@TypeOf(source), "isOpaque")) source.isOpaque() else false;
    const pixel_bytes: usize = if (rgb_only) 3 else @sizeOf(values.Pixel);
    var header: [png_format.header_data_bytes]u8 = undefined;
    // Valid images have at most max_extent pixels per axis, which fits u32.
    std.mem.writeInt(u32, header[0..4], @intCast(size.width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(size.height), .big);
    header[8..13].* = .{ png_format.sample_depth, if (rgb_only) png_format.rgb_color else png_format.rgba_color, 0, 0, 0 };
    try chunk(output, png_format.header_type, &header);

    const row_bytes = size.width * @sizeOf(values.Pixel);
    const staged_rows: usize = if (@TypeOf(source) == BorrowedRows) 0 else 2;
    const buffer = try allocator.alignedAlloc(u8, .@"4", chunk_bytes + row_bytes + staged_rows * row_bytes);
    defer allocator.free(buffer);
    const filtered = buffer[chunk_bytes..][0..row_bytes];
    const staging = std.mem.bytesAsSlice(values.Pixel, buffer[chunk_bytes + row_bytes ..]);
    var above: []const u8 = &.{};
    var compress: Deflater = undefined;
    var backing = allocator;
    try compress.init(&backing, output, buffer[0..chunk_bytes]);
    defer compress.deinit();
    for (0..size.height) |y| {
        const scratch = if (staged_rows == 0) &.{} else staging[(y % 2) * size.width ..][0..size.width];
        const row = std.mem.sliceAsBytes(source.row(y, scratch));
        if (y == 0) {
            try compress.write(&.{up_filter});
            if (rgb_only) {
                @memcpy(filtered, row);
                try compress.write(rgb(filtered));
            } else {
                try compress.write(row);
            }
            above = row;
            continue;
        }
        if (rgb_only and std.mem.eql(u8, row, above)) {
            try compress.write(&.{up_filter});
            const zeros = filtered[0 .. size.width * pixel_bytes];
            @memset(zeros, 0);
            try compress.write(zeros);
            above = row;
            continue;
        }
        const method = if (rgb_only) preferredFilter(row, above) else up_filter;
        try compress.write(&.{method});
        switch (method) {
            sub_filter => {
                const pixel = @sizeOf(values.Pixel);
                filtered[0..pixel].* = row[0..pixel].*;
                filter(filtered[pixel..], row[pixel..], row[0 .. row.len - pixel]);
            },
            paeth_filter => filterPaeth(filtered, row, above),
            else => filter(filtered, row, above),
        }
        above = row;
        try compress.write(if (rgb_only) rgb(filtered) else filtered);
    }
    try compress.finish();
    try chunk(output, "IEND", "");
}

fn rgb(bytes: []u8) []const u8 {
    const Blocks = @Vector(16, u8);
    const picks = @Vector(12, i32){ 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14 };
    var i: usize = 0;
    var out: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        bytes[out..][0..12].* = @shuffle(u8, @as(Blocks, bytes[i..][0..16].*), undefined, picks);
        out += 12;
    }
    while (i < bytes.len) : (i += 4) {
        bytes[out..][0..3].* = bytes[i..][0..3].*;
        out += 3;
    }
    return bytes[0..out];
}

fn filter(out: []u8, current: []const u8, predictor: []const u8) void {
    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
    const Vector = @Vector(lanes, u8);
    var i: usize = 0;
    while (i + lanes <= out.len) : (i += lanes) {
        const here: Vector = current[i..][0..lanes].*;
        const from: Vector = predictor[i..][0..lanes].*;
        out[i..][0..lanes].* = here -% from;
    }
    for (out[i..], current[i..], predictor[i..]) |*byte, now, from| byte.* = now -% from;
}

fn preferredFilter(row: []const u8, above: []const u8) u8 {
    // Nonzero residuals interrupt runs. Sample the row and favor Up when
    // choosing another predictor saves only a few of them.
    const pixel = @sizeOf(values.Pixel);
    var up: usize = 0;
    var sub: usize = 0;
    var paeth: usize = 0;
    var x: usize = 2 * pixel;
    while (x + pixel < row.len) : (x += filter_sample_pixels * pixel) {
        const middle = std.mem.readInt(u32, row[x..][0..pixel], .little);
        if (middle == std.mem.readInt(u32, row[x - pixel ..][0..pixel], .little) and
            middle == std.mem.readInt(u32, above[x..][0..pixel], .little)) continue;
        for (0..3) |c| {
            const i = x + c;
            const left: i16 = row[i - pixel];
            const top: i16 = above[i];
            const corner: i16 = above[i - pixel];
            const px: i16 = row[i];
            const p = paethPredictor(left, top, corner);
            up += @intFromBool(px != top);
            sub += @intFromBool(px != left);
            paeth += @intFromBool(px != p);
        }
    }
    if (paeth + paeth / filter_switch_margin < @min(up, sub)) return paeth_filter;
    if (sub + sub / filter_switch_margin < up) return sub_filter;
    return up_filter;
}

fn filterPaeth(out: []u8, current: []const u8, above: []const u8) void {
    const half = (std.simd.suggestVectorLength(u8) orelse 16) / 2;
    const Bytes = @Vector(half, u8);
    const Wide = @Vector(half, i16);
    const pixel = @sizeOf(values.Pixel);
    for (out[0..pixel], current[0..pixel], above[0..pixel]) |*dst, a, b| dst.* = a -% b;
    var i: usize = pixel;
    while (i + half <= out.len) : (i += half) {
        const left = i - pixel;
        const a: Wide = @as(Bytes, current[left..][0..half].*);
        const b: Wide = @as(Bytes, above[i..][0..half].*);
        const c: Wide = @as(Bytes, above[left..][0..half].*);
        const da = @abs(b - c);
        const db = @abs(a - c);
        const dc = @abs(a + b - c - c);
        const predictor = @select(i16, da <= @min(db, dc), a, @select(i16, db <= dc, b, c));
        out[i..][0..half].* = @as(Bytes, current[i..][0..half].*) -% @as(Bytes, @intCast(predictor));
    }
    while (i < out.len) : (i += 1) {
        const a: i16 = current[i - pixel];
        const b: i16 = above[i];
        const c: i16 = above[i - pixel];
        out[i] = current[i] -% @as(u8, @intCast(paethPredictor(a, b, c)));
    }
}

fn paethPredictor(a: i16, b: i16, c: i16) i16 {
    const left = @abs(b - c);
    const top = @abs(a - c);
    const corner = @abs(a + b - c - c);
    return if (left <= @min(top, corner)) a else if (top <= corner) b else c;
}

fn chunk(output: *Writer, comptime kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try output.writeInt(u32, std.math.cast(u32, data.len) orelse return error.WriteFailed, .big);
    try output.writeAll(kind);
    try output.writeAll(data);
    const checksum = if (zlib.UIDIFF_ZLIB_CRC != 0) acceleratedChecksum(kind, data) else portableChecksum(kind, data);
    try output.writeInt(u32, checksum, .big);
}

fn acceleratedChecksum(kind: *const [4]u8, data: []const u8) u32 {
    const tag_crc = zlib.zng_crc32_z(0, kind, kind.len);
    return zlib.zng_crc32_z(tag_crc, data.ptr, data.len);
}

fn portableChecksum(kind: *const [4]u8, data: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    return crc.final();
}

fn load(allocator: Allocator, bytes: []const u8, header: stb.Header, cap: usize) DecodeError![*]values.Pixel {
    return stb.withDecodeBudget(loadPixels, allocator, bytes, header, cap);
}

fn loadPixels(bytes: []const u8, size: values.Size) DecodeError![*]values.Pixel {
    if (try streamPixels(bytes, size)) |pixels| return pixels;
    return stb.loadStb(bytes, size);
}

fn streamPixels(bytes: []const u8, dimensions: values.Size) DecodeError!?[*]values.Pixel {
    return scanlines.decode(bytes, dimensions);
}

fn encodeOnce(allocator: Allocator, image: Image) !void {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(allocator, image, &out.writer) catch |err| switch (err) {
        // The allocating writer reports its own allocation failure as a write failure.
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
}

fn writeTestPng(allocator: Allocator, out: *Writer, size: values.Size, color: u8, filtered_rows: []const u8) EncodeError!void {
    try out.writeAll(png_format.signature);
    var header: [png_format.header_data_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], @intCast(size.width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(size.height), .big);
    header[8] = png_format.sample_depth;
    header[9] = color;
    try chunk(out, png_format.header_type, &header);
    var staging: [chunk_bytes]u8 = undefined;
    var backing = allocator;
    var deflater: Deflater = undefined;
    try deflater.init(&backing, out, &staging);
    defer deflater.deinit();
    try deflater.write(filtered_rows);
    try deflater.finish();
    try chunk(out, "IEND", "");
}

fn checkTestFilters(comptime channels: usize, color: u8, filters: []const u8) !void {
    const allocator = std.testing.allocator;
    const width = 7;
    const row_bytes = width * channels;
    const size: values.Size = .{ .width = width, .height = filters.len };
    var pixels: [3 * width]values.Pixel = undefined;
    for (pixels[0 .. width * filters.len], 0..) |*pixel, i| {
        pixel.* = .{ @intCast(7 + 11 * i), @intCast(101 - 3 * i), @intCast(2 + i * 7), if (channels == 3) 255 else @intCast(254 - 5 * i) };
    }
    var raw: [3 * row_bytes]u8 = undefined;
    for (pixels[0 .. width * filters.len], 0..) |pixel, i| @memcpy(raw[i * channels ..][0..channels], pixel[0..channels]);
    var filtered: [3 * (1 + row_bytes)]u8 = undefined;
    for (filters, 0..) |filter_byte, y| {
        const row = filtered[y * (1 + row_bytes) ..][0 .. 1 + row_bytes];
        row[0] = filter_byte;
        for (row[1..], 0..) |*out, x| {
            const at = y * row_bytes + x;
            const left = if (x >= channels) raw[at - channels] else 0;
            const above = if (y > 0) raw[at - row_bytes] else 0;
            const diagonal = if (x >= channels and y > 0) raw[at - row_bytes - channels] else 0;
            const predicted: u8 = switch (filter_byte) {
                sub_filter => left,
                up_filter => above,
                3 => @intCast((@as(u16, left) + above) / 2),
                paeth_filter => referencePaeth(left, above, diagonal),
                else => 0,
            };
            out.* = raw[at] -% predicted;
        }
    }

    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeTestPng(allocator, &output.writer, size, color, filtered[0 .. filters.len * (1 + row_bytes)]);
    const header = try probe(allocator, output.written(), values.max_decode_bytes);
    for (filters) |filter_byte| if (filter_byte > paeth_filter) {
        try std.testing.expectEqual(@as(?[*]values.Pixel, null), try loadStreaming(allocator, output.written(), header, values.max_decode_bytes));
        try std.testing.expectError(error.InvalidImage, load(allocator, output.written(), header, values.max_decode_bytes));
        return;
    };
    const found = try load(allocator, output.written(), header, values.max_decode_bytes);
    defer stb.free(found);
    const legacy = try stb.loadLegacy(allocator, output.written(), header, values.max_decode_bytes);
    defer stb.release(allocator, legacy);
    try std.testing.expectEqualSlices(values.Pixel, pixels[0 .. width * filters.len], legacy);
    try std.testing.expectEqualSlices(values.Pixel, legacy, found[0..legacy.len]);
}

fn referencePaeth(left: u8, above: u8, diagonal: u8) u8 {
    const estimate = @as(i16, left) + above - diagonal;
    const a = @abs(estimate - left);
    const b = @abs(estimate - above);
    const c = @abs(estimate - diagonal);
    if (a <= b and a <= c) return left;
    if (b <= c) return above;
    return diagonal;
}

fn firstTestIdat(png: []const u8) []const u8 {
    const header_end = png_format.header_bytes + @sizeOf(u32);
    const idat = png[header_end..];
    std.debug.assert(std.mem.eql(u8, idat[4..8], "IDAT"));
    return idat[8..][0..std.mem.readInt(u32, idat[0..4], .big)];
}

fn splitTestIdat(out: *Writer, png: []const u8, data: []const u8, at: usize) EncodeError!void {
    const header_end = png_format.header_bytes + @sizeOf(u32);
    try out.writeAll(png[0..header_end]);
    try chunk(out, "IDAT", data[0..at]);
    try chunk(out, "IDAT", "");
    try chunk(out, "IDAT", data[at..]);
    try chunk(out, "IEND", "");
}

fn fuzzStreamingRows(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const filter_variants = paeth_filter + 2; // Five filters and the first invalid byte.
    const seed = smith.valueRangeAtMost(u8, 0, 4 * filter_variants - 1);
    const max_width = 24;
    const max_height = 8;
    const width = smith.valueRangeAtMost(u8, 1, max_width);
    const height = smith.valueRangeAtMost(u8, 1, max_height);
    const size: values.Size = .{ .width = width, .height = height };
    const color: u8 = if (seed % 2 == 0) png_format.rgb_color else png_format.rgba_color;
    const channels: usize = if (color == png_format.rgb_color) 3 else 4;
    var rows: [max_height * (1 + max_width * 4)]u8 = undefined;
    const valid = rows[0 .. size.height * (1 + size.width * channels)];
    const length = if (smith.value(bool)) smith.slice(valid) else complete: {
        for (0..size.height) |y| {
            const at = y * (1 + size.width * channels);
            valid[at] = if (y == 0) (seed / 2) % filter_variants else smith.valueRangeAtMost(u8, 0, filter_variants - 1);
            for (valid[at + 1 ..][0 .. size.width * channels]) |*value| value.* = smith.value(u8);
        }
        break :complete valid.len;
    };
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeTestPng(allocator, &output.writer, size, color, valid[0..length]);
    var split: Writer.Allocating = .init(allocator);
    defer split.deinit();
    const bytes = if (seed >= 2 * filter_variants) split_bytes: {
        const payload = firstTestIdat(output.written());
        const offset = smith.valueRangeAtMost(u16, 0, @intCast(payload.len));
        try splitTestIdat(&split.writer, output.written(), payload, offset);
        break :split_bytes split.written();
    } else output.written();
    const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
    const found = try loadStreaming(allocator, bytes, header, values.max_decode_bytes) orelse return;
    defer stb.free(found);
    const legacy = try stb.loadLegacy(allocator, bytes, header, values.max_decode_bytes);
    defer stb.release(allocator, legacy);
    try std.testing.expectEqualSlices(values.Pixel, legacy, found[0..legacy.len]);
}

test "an encoded image starts with the PNG signature and ends with IEND" {
    const pixels = [_]values.Pixel{ .{ 1, 2, 3, 255 }, .{ 4, 5, 6, 128 } };
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, .{ .width = 2, .height = 1, .pixels = &pixels }, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), png_format.signature));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "IEND\xae\x42\x60\x82"));
}

test "each emitted chunk carries the PNG checksum" {
    const allocator = std.testing.allocator;
    const pixels = [_]values.Pixel{ .{ 32, 22, 8, 255 }, .{ 44, 27, 12, 70 } };
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    try write(allocator, .{ .width = 2, .height = 1, .pixels = &pixels }, &out.writer);
    var chunks = out.written()[png_format.signature.len..];
    while (chunks.len != 0) {
        const length = std.mem.readInt(u32, chunks[0..4], .big);
        const tag_and_data = chunks[4..][0 .. 4 + length];
        const stored = std.mem.readInt(u32, chunks[8 + length ..][0..4], .big);
        try std.testing.expectEqual(std.hash.Crc32.hash(tag_and_data), stored);
        chunks = chunks[12 + length ..];
    }
}

test "encoding releases each allocation on failure" {
    const pixels: [4 * 4]values.Pixel = @splat(.{ 1, 2, 3, 255 });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeOnce, .{Image{ .width = 4, .height = 4, .pixels = &pixels }});
}

test "PNG filters preserve RGB8 and RGBA8 across streaming and fallback" {
    for ([_][]const u8{ &.{ 3, 3, 0 }, &.{ 1, 2, 4 }, &.{ 4, 1, 2 }, &.{ 3, 0, 5 } }) |filters| {
        try checkTestFilters(3, png_format.rgb_color, filters);
        try checkTestFilters(4, png_format.rgba_color, filters);
    }
}

test "RGB8 accepts every legal IDAT split and refuses a truncated DEFLATE body" {
    const allocator = std.testing.allocator;
    const size: values.Size = .{ .width = 1, .height = 1 };
    const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
    var encoded: Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try writeTestPng(allocator, &encoded.writer, size, png_format.rgb_color, &.{ 0, 23, 57, 91 });
    const payload = firstTestIdat(encoded.written());

    var rebuilt: Writer.Allocating = .init(allocator);
    defer rebuilt.deinit();
    for (0..payload.len + 1) |at| {
        rebuilt.clearRetainingCapacity();
        try splitTestIdat(&rebuilt.writer, encoded.written(), payload, at);
        const found = try load(allocator, rebuilt.written(), header, values.max_decode_bytes);
        defer stb.free(found);
        try std.testing.expectEqual(values.Pixel{ 23, 57, 91, 255 }, found[0]);
    }
    rebuilt.clearRetainingCapacity();
    try splitTestIdat(&rebuilt.writer, encoded.written(), payload[0..3], 1);
    try std.testing.expectError(error.InvalidImage, load(allocator, rebuilt.written(), header, values.max_decode_bytes));
    try std.testing.expectError(error.ImageTooLarge, load(allocator, encoded.written(), header, @sizeOf(values.Pixel)));
}

test "RGB8 preserves legacy checksum tolerance" {
    const allocator = std.testing.allocator;
    const size: values.Size = .{ .width = 1, .height = 1 };
    const header: stb.Header = .{ .size = size, .sample_bytes = 1 };
    var encoded: Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try writeTestPng(allocator, &encoded.writer, size, png_format.rgb_color, &.{ 0, 23, 57, 91 });
    const idat = png_format.header_bytes + @sizeOf(u32);
    const len = firstTestIdat(encoded.written()).len;
    const changed = try allocator.dupe(u8, encoded.written());
    defer allocator.free(changed);
    // Alter both the zlib checksum payload and the following PNG CRC.
    changed[idat + 8 + len - 1] ^= 1;
    changed[idat + 8 + len] ^= 1;
    const found = try load(allocator, changed, header, values.max_decode_bytes);
    defer stb.free(found);
    try std.testing.expectEqual(values.Pixel{ 23, 57, 91, 255 }, found[0]);
}

test "RGB8 transparent colour keys use the legacy decoder" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0, 23, 57, 91 };
    var png: Writer.Allocating = .init(allocator);
    defer png.deinit();
    try writeTestPng(allocator, &png.writer, .{ .width = 1, .height = 1 }, png_format.rgb_color, &raw);

    var keyed: Writer.Allocating = .init(allocator);
    defer keyed.deinit();
    const header_end = png_format.header_bytes + @sizeOf(u32); // IHDR checksum.
    try keyed.writer.writeAll(png.written()[0..header_end]);
    try chunk(&keyed.writer, "tRNS", &.{ 0, raw[1], 0, raw[2], 0, raw[3] });
    try keyed.writer.writeAll(png.written()[header_end..]);

    const header = try probe(allocator, keyed.written(), values.max_decode_bytes);
    try std.testing.expectEqual(@as(?[*]values.Pixel, null), try loadStreaming(allocator, keyed.written(), header, values.max_decode_bytes));
    const pixels = try load(allocator, keyed.written(), header, values.max_decode_bytes);
    defer stb.free(pixels);
    try std.testing.expectEqual(values.Pixel{ raw[1], raw[2], raw[3], 0 }, pixels[0]);
}

test "RGB8 streaming leaves grayscale, indexed, wide and interlaced PNGs to stb" {
    const allocator = std.testing.allocator;
    const size: values.Size = .{ .width = 1, .height = 1 };
    const profiles = [_]struct {
        color: u8,
        depth: u8 = png_format.sample_depth,
        interlace: u8 = 0,
        raw: []const u8,
        palette: ?[]const u8 = null,
        expected: values.Pixel,
    }{
        .{ .color = 0, .raw = &.{ 0, 37 }, .expected = .{ 37, 37, 37, 255 } },
        .{ .color = 4, .raw = &.{ 0, 37, 99 }, .expected = .{ 37, 37, 37, 99 } },
        .{ .color = 3, .depth = 1, .raw = &.{ 0, 0 }, .palette = &.{ 11, 22, 33 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .color = png_format.rgb_color, .depth = 16, .raw = &.{ 0, 11, 0, 22, 0, 33, 0 }, .expected = .{ 11, 22, 33, 255 } },
        .{ .color = png_format.rgba_color, .interlace = 1, .raw = &.{ 0, 11, 22, 33, 44 }, .expected = .{ 11, 22, 33, 44 } },
    };
    for (profiles) |profile| {
        var encoded: Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        try writeTestPng(allocator, &encoded.writer, size, profile.color, profile.raw);

        const checksum_start = png_format.signature.len + @sizeOf(u32);
        const header_end = png_format.header_bytes + @sizeOf(u32);
        var header = encoded.written()[0..header_end].*;
        header[png_format.profile_offset] = profile.depth;
        header[png_format.header_bytes - 1] = profile.interlace;
        std.mem.writeInt(u32, header[png_format.header_bytes..][0..4], std.hash.Crc32.hash(header[checksum_start..png_format.header_bytes]), .big);
        try std.testing.expect(!streamingHeader(&header));

        var patched: Writer.Allocating = .init(allocator);
        defer patched.deinit();
        try patched.writer.writeAll(&header);
        if (profile.palette) |palette| try chunk(&patched.writer, "PLTE", palette);
        try patched.writer.writeAll(encoded.written()[header_end..]);

        const metadata = try probe(allocator, patched.written(), values.max_decode_bytes);
        try std.testing.expectEqual(@as(?[*]values.Pixel, null), try loadStreaming(allocator, patched.written(), metadata, values.max_decode_bytes));
        const pixels = try load(allocator, patched.written(), metadata, values.max_decode_bytes);
        defer stb.free(pixels);
        try std.testing.expectEqual(profile.expected, pixels[0]);
    }
}

test "the streaming probe agrees with the PNG header layout" {
    var header: [png_format.header_bytes]u8 = @splat(0);
    @memcpy(header[0..png_format.header_prefix.len], png_format.header_prefix);
    const offset = png_format.dimensions_offset;
    std.mem.writeInt(u32, header[offset..][0..4], 253, .big);
    std.mem.writeInt(u32, header[offset + 4 ..][0..4], 58, .big);
    const profile = header[offset + 2 * @sizeOf(u32) ..];
    const depth, const colour, const interlace = .{ 0, 1, 4 };
    profile[depth] = 8;
    profile[colour] = png_format.rgba_color;
    try std.testing.expect(streamingHeader(&header));
    try std.testing.expect(!streamingHeader(header[0 .. header.len - 1]));
    profile[colour] = png_format.rgb_color;
    try std.testing.expect(streamingHeader(&header));
    profile[depth] = 16;
    try std.testing.expect(!streamingHeader(&header));
    profile[depth] = 8;
    profile[interlace] = 1;
    try std.testing.expect(!streamingHeader(&header));
    profile[interlace] = 0;
    profile[colour] = 3;
    try std.testing.expect(!streamingHeader(&header));
    profile[colour] = png_format.rgba_color;
    for (0..png_format.header_prefix.len) |i| {
        header[i] ^= 1;
        try std.testing.expect(!streamingHeader(&header));
        header[i] ^= 1;
    }
}

test "fuzz streaming PNG reconstruction" {
    comptime var corpus: []const []const u8 = &.{};
    inline for (0..4 * (paeth_filter + 2)) |seed| corpus = corpus ++ .{&[_]u8{seed}};
    try std.testing.fuzz({}, fuzzStreamingRows, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
