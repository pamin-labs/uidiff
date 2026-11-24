//! Writes PNG images with a bounded zlib stream.
const std = @import("std");
const values = @import("../value.zig");
const png_format = @import("png_format.zig");
const stb = @import("stb.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const zlib = @import("zlib_c");
const Image = values.Image;

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
        const block = allocator.alignedAlloc(u8, .@"16", total) catch return null;
        std.mem.writeInt(usize, block[0..@sizeOf(usize)], block.len, .little);
        return block.ptr + header_bytes;
    }

    fn zfree(context: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        const allocator: *const Allocator = @ptrCast(@alignCast(context));
        const data: [*]align(16) u8 = @ptrCast(@alignCast(address orelse return));
        const base: [*]align(16) u8 = @alignCast(data - header_bytes);
        allocator.free(base[0..std.mem.readInt(usize, base[0..@sizeOf(usize)], .little)]);
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

const bit_depth = 8;
const rgb_color = 2;
const rgba_color = 6;
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
    return (try stb.load(allocator, bytes, header, cap))[0 .. header.size.width * header.size.height];
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
    header[8..13].* = .{ bit_depth, if (rgb_only) rgb_color else rgba_color, 0, 0, 0 };
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

fn encodeOnce(allocator: Allocator, image: Image) !void {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(allocator, image, &out.writer) catch |err| switch (err) {
        // The allocating writer reports its own allocation failure as a write failure.
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
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

test {
    std.testing.refAllDecls(@This());
}
