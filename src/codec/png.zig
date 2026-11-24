//! Writes PNG images with a bounded zlib stream.
const std = @import("std");
const values = @import("../value.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const deflate = @import("deflate.zig");
const Image = values.Image;

/// Allocation, invalid image or output failures.
pub const EncodeError = Allocator.Error || Writer.Error || Image.Invalid;

/// Emits each buffer of compressed bytes as one IDAT chunk, so the encoder
/// needs no room for the whole compressed stream.
const Chunks = struct {
    output: *Writer,
    writer: Writer,

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Chunks = @fieldParentPtr("writer", w);
        const buffered = w.buffered();
        if (buffered.len != 0) {
            try chunk(self.output, "IDAT", buffered);
            w.end = 0;
            return 0;
        }
        for (data[0 .. data.len - 1]) |bytes| if (bytes.len != 0) {
            try chunk(self.output, "IDAT", bytes);
            return bytes.len;
        };
        const last = data[data.len - 1];
        if (last.len == 0 or splat == 0) return 0;
        try chunk(self.output, "IDAT", last);
        return last.len;
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

const signature = "\x89PNG\r\n\x1a\n";
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

/// Encodes a valid image. Allocates the compressor's window and one filtered row.
pub fn write(allocator: Allocator, image: Image, output: *Writer) EncodeError!void {
    if (!image.valid()) return error.InvalidImage;
    return writeRows(allocator, image.size(), BorrowedRows{ .image = image }, output);
}

/// Encodes a source that supplies one row at a time. BorrowedRows can return
/// existing pixels. Other sources fill the provided row buffer.
/// Sources may supply isOpaque for RGB output and paneWidth for matching panels.
pub fn writeRows(allocator: Allocator, size: values.Size, source: anytype, output: *Writer) EncodeError!void {
    if (size.pixelCount() == null) return error.InvalidImage;
    try output.writeAll(signature);
    const rgb_only = if (@hasDecl(@TypeOf(source), "isOpaque")) source.isOpaque() else false;
    const pixel_bytes: usize = if (rgb_only) 3 else @sizeOf(values.Pixel);
    var header: [13]u8 = undefined;
    // Valid images have at most max_extent pixels per axis, which fits u32.
    std.mem.writeInt(u32, header[0..4], @intCast(size.width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(size.height), .big);
    header[8..13].* = .{ bit_depth, if (rgb_only) rgb_color else rgba_color, 0, 0, 0 };
    try chunk(output, "IHDR", &header);

    const row_bytes = size.width * @sizeOf(values.Pixel);
    const end_blocks = chunk_bytes + row_bytes + deflate.block_bytes + deflate.max_tokens * @sizeOf(deflate.Token);
    const staged_rows: usize = if (@TypeOf(source) == BorrowedRows) 0 else 2;
    const buffer = try allocator.alignedAlloc(u8, .@"4", end_blocks + staged_rows * row_bytes);
    defer allocator.free(buffer);
    const filtered = buffer[chunk_bytes..][0..row_bytes];
    const blocks = buffer[chunk_bytes + row_bytes .. end_blocks];
    var chunks: Chunks = .{ .output = output, .writer = .{
        .buffer = buffer[0..chunk_bytes],
        .vtable = &.{ .drain = Chunks.drain },
    } };
    const staging = std.mem.bytesAsSlice(values.Pixel, buffer[end_blocks..]);
    var above: []const u8 = &.{};
    const token_bytes: []align(4) u8 = @alignCast(blocks[deflate.block_bytes..]);
    const tokens = std.mem.bytesAsSlice(deflate.Token, token_bytes);
    const pane_distance = if (@hasDecl(@TypeOf(source), "paneWidth")) source.paneWidth() * pixel_bytes else 0;
    var compress = try deflate.Stream.initWithOptions(&chunks.writer, blocks[0..deflate.block_bytes], tokens, .{
        .pixel_bytes = pixel_bytes,
        .pane_distance = pane_distance,
    });
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
    try chunks.writer.flush();
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
            const a = @abs(top - corner);
            const b = @abs(left - corner);
            const d = @abs(top + left - corner - corner);
            const p = if (a <= @min(b, d)) left else if (b <= d) top else corner;
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
        const da = @abs(b - c);
        const db = @abs(a - c);
        const dc = @abs(a + b - c - c);
        const predictor = if (da <= @min(db, dc)) a else if (db <= dc) b else c;
        out[i] = current[i] -% @as(u8, @intCast(predictor));
    }
}

fn chunk(output: *Writer, comptime kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try output.writeInt(u32, std.math.cast(u32, data.len) orelse return error.WriteFailed, .big);
    try output.writeAll(kind);
    try output.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try output.writeInt(u32, crc.final(), .big);
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
    try std.testing.expect(std.mem.startsWith(u8, out.written(), signature));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "IEND\xae\x42\x60\x82"));
}

test "encoding releases each allocation on failure" {
    const pixels: [4 * 4]values.Pixel = @splat(.{ 1, 2, 3, 255 });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeOnce, .{Image{ .width = 4, .height = 4, .pixels = &pixels }});
}

test {
    std.testing.refAllDecls(@This());
}
