//! Encodes borrowed pixel rows and composed sheet strips as PNG.

const std = @import("std");
const deflate = @import("deflate.zig");
const decoder = @import("decoder.zig");
const values = @import("../../value.zig");
const png_format = @import("../png_format.zig");
const stb = @import("../stb.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Image = values.Image;

const BorrowedRows = struct {
    image: Image,

    pub fn isOpaque(self: BorrowedRows) bool {
        return self.image.isOpaque();
    }

    pub fn row(self: BorrowedRows, y: usize, _: []values.Pixel) []const values.Pixel {
        return self.image.row(y);
    }
};

const sheet_strip_rows = 8;

const filter_sample_pixels = 6;

const filter_switch_margin = 4;

/// Encodes a valid image. Allocates the compressor's window and one filtered row.
pub fn write(allocator: Allocator, image: Image, output: *Writer) deflate.EncodeError!void {
    if (!image.valid()) return error.InvalidImage;
    return writeRows(allocator, image.size(), BorrowedRows{ .image = image }, output);
}

/// Encodes a source that supplies one row at a time. BorrowedRows can return
/// existing pixels. Other sources are consumed in strips and can fill the
/// provided row buffer or lend a row to copy into the strip.
/// Sources may supply isOpaque for RGB output.
pub fn writeRows(allocator: Allocator, size: values.Size, source: anytype, output: *Writer) deflate.EncodeError!void {
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
    try deflate.chunk(output, png_format.header_type, &header);

    const row_bytes = size.width * @sizeOf(values.Pixel);
    const staged_rows: usize = if (@TypeOf(source) == BorrowedRows) 0 else sheet_strip_rows + 1;
    const buffer = try allocator.alignedAlloc(u8, .@"4", deflate.chunk_bytes + row_bytes + staged_rows * row_bytes);
    defer allocator.free(buffer);
    const filtered = buffer[deflate.chunk_bytes..][0..row_bytes];
    const staging = std.mem.bytesAsSlice(values.Pixel, buffer[deflate.chunk_bytes + row_bytes ..]);
    var above: []const u8 = &.{};
    var compress: deflate.Deflater = undefined;
    var backing = allocator;
    try compress.init(&backing, output, buffer[0..deflate.chunk_bytes]);
    defer compress.deinit();
    for (0..size.height) |y| {
        const pixels = if (staged_rows == 0) source.row(y, &.{}) else staged: {
            if (y % sheet_strip_rows == 0) {
                // One extra slot preserves the previous filtered row while
                // the next strip is composed.
                for (y..@min(size.height, y + sheet_strip_rows)) |index| {
                    const buffer_row = staging[(index % staged_rows) * size.width ..][0..size.width];
                    const produced = source.row(index, buffer_row);
                    if (produced.ptr != buffer_row.ptr) @memcpy(buffer_row, produced);
                }
            }
            break :staged staging[(y % staged_rows) * size.width ..][0..size.width];
        };
        const row = std.mem.sliceAsBytes(pixels);
        if (y == 0) {
            try compress.write(&.{png_format.up_filter});
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
            try compress.write(&.{png_format.up_filter});
            const zeros = filtered[0 .. size.width * pixel_bytes];
            @memset(zeros, 0);
            try compress.write(zeros);
            above = row;
            continue;
        }
        const method = if (rgb_only) preferredFilter(row, above) else png_format.up_filter;
        try compress.write(&.{method});
        switch (method) {
            png_format.sub_filter => {
                const pixel = @sizeOf(values.Pixel);
                filtered[0..pixel].* = row[0..pixel].*;
                filter(filtered[pixel..], row[pixel..], row[0 .. row.len - pixel]);
            },
            png_format.paeth_filter => filterPaeth(filtered, row, above),
            else => filter(filtered, row, above),
        }
        above = row;
        try compress.write(if (rgb_only) rgb(filtered) else filtered);
    }
    try compress.finish();
    try deflate.chunk(output, "IEND", "");
}

fn rgb(bytes: []u8) []const u8 {
    const Blocks = @Vector(16, u8);
    const picks = @Vector(16, i32){ 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 15, 15, 15, 15 };
    var i: usize = 0;
    var out: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        // Whole-vector load and store: the 12-byte array store is split into
        // scalar moves. The four extra bytes are overwritten by the next block.
        const block = @as(*align(1) const Blocks, @ptrCast(bytes[i..][0..16])).*;
        @as(*align(1) Blocks, @ptrCast(bytes[out..][0..16])).* = @shuffle(u8, block, undefined, picks);
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
    if (paeth + paeth / filter_switch_margin < @min(up, sub)) return png_format.paeth_filter;
    if (sub + sub / filter_switch_margin < up) return png_format.sub_filter;
    return png_format.up_filter;
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

test "staged PNG rows preserve the predictor across two strip boundaries and a tail" {
    const Source = struct {
        image: Image,

        pub fn isOpaque(self: @This()) bool {
            return self.image.isOpaque();
        }

        pub fn row(self: @This(), y: usize, scratch: []values.Pixel) []const values.Pixel {
            const pixels = self.image.row(y);
            if (y % 2 == 1) return pixels;
            @memcpy(scratch, pixels);
            return scratch;
        }
    };

    const allocator = std.testing.allocator;
    const width = 17;
    const height = 2 * sheet_strip_rows + 3;
    var pixels: [width * height]values.Pixel = undefined;
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    for ([_]u8{ 255, 101 }) |alpha| {
        for (&pixels, 0..) |*pixel, i| {
            const x = i % width;
            const y = i / width;
            pixel.* = .{ @intCast(3 * x + y), @intCast(y * 7), @intCast(x * 7), alpha };
        }
        var streamed: Writer.Allocating = .init(allocator);
        defer streamed.deinit();
        var borrowed: Writer.Allocating = .init(allocator);
        defer borrowed.deinit();
        try writeRows(allocator, image.size(), Source{ .image = image }, &streamed.writer);
        try write(allocator, image, &borrowed.writer);
        try std.testing.expectEqualSlices(u8, borrowed.written(), streamed.written());
        const header = try stb.probe(allocator, streamed.written(), values.max_decode_bytes);
        const decoded = try decoder.decode(allocator, streamed.written(), header, values.max_decode_bytes);
        defer stb.release(allocator, decoded);
        try std.testing.expectEqualSlices(values.Pixel, image.pixels, decoded);
    }
}

test {
    std.testing.refAllDecls(@This());
}
