//! Encodes borrowed or staged pixel rows as PNG.

const std = @import("std");
const zlib = @import("zlib.zig");
const decoder = @import("decoder.zig");
const value = @import("../../value.zig");
const png_format = @import("png_format");
const memory = @import("codec_memory");
const stb = @import("stb.zig");
const simd = @import("simd.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Image = value.Image;

const Filtered = struct { method: png_format.Filter, bytes: []const u8 };

/// Allocation, invalid image or output failures while encoding.
pub const EncodeError = zlib.CompressError || Image.Invalid;

const BorrowedRows = struct {
    image: Image,

    pub const staged = false;

    pub fn isOpaque(self: BorrowedRows) bool {
        return self.image.isOpaque();
    }

    pub fn row(self: BorrowedRows, y: usize, _: []value.Pixel) []const value.Pixel {
        return self.image.row(y);
    }
};

const strip_rows = 8;

const parallel_min_bytes = 6 * 1024 * 1024;

// A smaller strip cuts the worker buffers while still amortizing deflate
// setup and dictionary hand-off across enough rows.
const target_strip_bytes = 256 * 1024;

const max_strip_workers = 4;

const filter_sample_pixels = 6;

const filter_switch_margin = 4;

/// Encodes a valid image. Allocates the compressor and its row buffers.
pub fn write(allocator: Allocator, image: Image, output: *Writer) EncodeError!void {
    if (!image.valid()) return error.InvalidImage;
    return writeRows(allocator, image.size(), BorrowedRows{ .image = image }, output);
}

/// Encodes a PNG from a row source. See writeRowsWithIo for the source contract.
pub fn writeRows(allocator: Allocator, size: value.Size, source: anytype, output: *Writer) EncodeError!void {
    return writeRowsWithIo(null, allocator, size, source, output);
}

/// Encodes PNG rows, optionally using parallel compression. A row source
/// supplies row(y, scratch) returning size.width pixels and isOpaque()
/// reporting whether all pixels have alpha 255. Its comptime staged bool
/// selects serial buffering. A staged source can return scratch or a row
/// to copy immediately. A borrowed source receives empty scratch in serial
/// mode and keeps each row readable through the next source call.
pub fn writeRowsWithIo(io: ?Io, allocator: Allocator, size: value.Size, source: anytype, output: *Writer) EncodeError!void {
    const Source = @TypeOf(source);
    if (!@hasDecl(Source, "row"))
        @compileError("a PNG row source must provide row(y, scratch) returning []const Pixel");
    if (!@hasDecl(Source, "isOpaque"))
        @compileError("a PNG row source must provide isOpaque() returning bool");
    if (!@hasDecl(Source, "staged") or @TypeOf(Source.staged) != bool)
        @compileError("a PNG row source must declare staged as a comptime bool");
    if (size.pixelCount() == null) return error.InvalidImage;
    const rgb_only = source.isOpaque();
    // Valid images have at most max_extent pixels per axis, which fits u32.
    try png_format.writeHeader(zlib.chunk, output, @intCast(size.width), @intCast(size.height), if (rgb_only) .rgb else .rgba);

    const encoded_row_bytes = 1 + size.width * @as(usize, if (rgb_only) 3 else @sizeOf(value.Pixel));
    // The image's size alone picks the encoder, so a sheet's bytes do not
    // depend on the machine or on whether the caller passed an Io.
    if (encoded_row_bytes * size.height >= parallel_min_bytes) {
        // std.Io exposes no CPU count. Without an Io, one worker compresses
        // each strip in turn.
        const workers = if (io != null) @min(max_strip_workers, std.Thread.getCpuCount() catch 1) else 1;
        // One worker gains nothing from handing each strip to a thread.
        try writeStrips(if (workers > 1) io else null, allocator, size, source, output, rgb_only, encoded_row_bytes, workers);
    } else {
        try writeSerial(allocator, size, source, output, rgb_only);
    }
    try zlib.chunk(output, png_format.iend_type, "");
}

fn writeSerial(allocator: Allocator, size: value.Size, source: anytype, output: *Writer, rgb_only: bool) EncodeError!void {
    const row_bytes = size.width * @sizeOf(value.Pixel);
    const staged_rows: usize = if (@TypeOf(source).staged) strip_rows + 1 else 0;
    const buffer_bytes = zlib.chunk_bytes + row_bytes + staged_rows * row_bytes;
    // filterRow writes each filtered row, staging is written row by row before
    // it is read, and zlib reads only output it has written.
    const words = try value.allocUnfilled(u32, allocator, unfilledWords(buffer_bytes));
    defer value.freeUnfilled(u32, allocator, words);
    const buffer = std.mem.sliceAsBytes(words)[0..buffer_bytes];
    const filtered = buffer[zlib.chunk_bytes..][0..row_bytes];
    const staging = std.mem.bytesAsSlice(value.Pixel, buffer[zlib.chunk_bytes + row_bytes ..]);
    var above: []const u8 = &.{};
    var compress: zlib.Deflater = undefined;
    var backing = allocator;
    try compress.init(&backing, output, buffer[0..zlib.chunk_bytes]);
    defer compress.deinit();
    for (0..size.height) |y| {
        const pixels = if (staged_rows == 0) source.row(y, &.{}) else staged: {
            if (y % strip_rows == 0) {
                // One extra slot preserves the previous filtered row while
                // the source supplies the next strip.
                for (y..@min(size.height, y + strip_rows)) |index| {
                    const buffer_row = staging[(index % staged_rows) * size.width ..][0..size.width];
                    const produced = source.row(index, buffer_row);
                    if (produced.ptr != buffer_row.ptr) @memcpy(buffer_row, produced);
                }
            }
            break :staged staging[(y % staged_rows) * size.width ..][0..size.width];
        };
        const row = std.mem.sliceAsBytes(pixels);
        const encoded = filterRow(row, above, filtered, rgb_only);
        try compress.write(&.{@backingInt(encoded.method)});
        try compress.write(encoded.bytes);
        above = row;
    }
    try compress.finish();
}

fn writeStrips(io: ?Io, allocator: Allocator, size: value.Size, source: anytype, output: *Writer, rgb_only: bool, encoded_row_bytes: usize, workers: usize) EncodeError!void {
    const rows_per_strip = @max(1, target_strip_bytes / encoded_row_bytes);
    const strip_bytes = rows_per_strip * encoded_row_bytes;
    const compressed_bytes = zlib.Strip.outputBound(strip_bytes);
    const slot_bytes = zlib.history_bytes + strip_bytes + compressed_bytes;
    const row_bytes = size.width * @sizeOf(value.Pixel);
    // Each slot's output area is written only up to its compressed size, so
    // filled storage would touch pages the strip never reads.
    const buffer_bytes = 3 * row_bytes + workers * slot_bytes;
    const words = try value.allocUnfilled(u32, allocator, unfilledWords(buffer_bytes));
    defer value.freeUnfilled(u32, allocator, words);
    const buffer = std.mem.sliceAsBytes(words)[0..buffer_bytes];
    const rows = std.mem.bytesAsSlice(value.Pixel, buffer[0 .. 2 * row_bytes]);
    const filtered = buffer[2 * row_bytes ..][0..row_bytes];
    const slots = buffer[3 * row_bytes ..];

    var backing = allocator;
    var streams: [max_strip_workers]zlib.Strip = undefined;
    var initialized: usize = 0;
    defer for (streams[0..initialized]) |*stream| stream.deinit();
    for (streams[0..workers]) |*stream| {
        try stream.init(&backing);
        initialized += 1;
    }
    var pending: [max_strip_workers]?Io.Future(zlib.CompressError!zlib.Strip.Result) = @splat(null);
    defer for (pending[0..workers]) |*slot| {
        if (slot.*) |*task| {
            // The primary operation already returned its error. Wait before
            // releasing buffers the other workers may still use.
            _ = task.await(io.?) catch {};
        }
    };

    var stream: zlib.StripStream = .{ .output = output };
    try stream.start();
    var previous: []const u8 = &.{};
    var above: []const u8 = &.{};
    var first: usize = 0;
    var index: usize = 0;
    while (first < size.height) : (index += 1) {
        const slot = index % workers;
        if (pending[slot]) |*task| {
            try stream.write(try task.await(io.?));
            pending[slot] = null;
        }
        const workspace = slots[slot * slot_bytes ..][0..slot_bytes];
        const history = workspace[0..@min(zlib.history_bytes, previous.len)];
        // With several slots, consecutive strips live in different slots, so
        // the previous input stays intact while its worker compresses it.
        // With one slot, that strip is already compressed, and its tail lies
        // past the history region it is copied into.
        @memcpy(history, previous[previous.len - history.len ..]);
        const end = @min(size.height, first + rows_per_strip);
        const input = workspace[zlib.history_bytes..][0 .. (end - first) * encoded_row_bytes];
        for (first..end) |y| {
            const scratch = rows[(y % 2) * size.width ..][0..size.width];
            const produced = source.row(y, scratch);
            // A staged source may return a row it reuses on its next call;
            // the copy keeps it readable as the predictor's row above.
            if (@TypeOf(source).staged and produced.ptr != scratch.ptr) @memcpy(scratch, produced);
            const row = std.mem.sliceAsBytes(if (@TypeOf(source).staged) scratch else produced);
            const encoded = filterRow(row, above, filtered, rgb_only);
            const encoded_row = input[(y - first) * encoded_row_bytes ..][0..encoded_row_bytes];
            encoded_row[0] = @backingInt(encoded.method);
            @memcpy(encoded_row[1..], encoded.bytes);
            above = row;
        }
        const out = workspace[zlib.history_bytes + strip_bytes ..];
        const flush: zlib.Strip.Flush = if (end == size.height) .finish else .sync;
        if (io) |threads| {
            pending[slot] = threads.async(zlib.Strip.compress, .{ &streams[slot], history, input, out, flush });
        } else {
            try stream.write(try zlib.Strip.compress(&streams[slot], history, input, out, flush));
        }
        previous = input;
        first = end;
    }
    for (index -| workers..index) |i| {
        const slot = &pending[i % workers];
        if (slot.*) |*task| {
            try stream.write(try task.await(io.?));
            slot.* = null;
        }
    }
    try stream.finish();
}

fn unfilledWords(bytes: usize) usize {
    return std.math.divCeil(usize, bytes, @sizeOf(u32)) catch unreachable;
}

fn filterRow(row: []const u8, above: []const u8, filtered: []u8, rgb_only: bool) Filtered {
    const pixel = @sizeOf(value.Pixel);
    if (above.len == 0) return .{
        .method = .up,
        .bytes = if (rgb_only) packRgb(false, filtered, row, &.{}) else row,
    };
    if (rgb_only and std.mem.eql(u8, row, above)) {
        const zeros = filtered[0 .. row.len / pixel * 3];
        @memset(zeros, 0);
        return .{ .method = .up, .bytes = zeros };
    }
    const method = if (rgb_only) preferredFilter(row, above) else .up;
    const bytes = switch (method) {
        .sub => sub: {
            filtered[0..3].* = row[0..3].*;
            const encoded = packRgb(true, filtered[3..], row[pixel..], row[0 .. row.len - pixel]);
            break :sub filtered[0 .. 3 + encoded.len];
        },
        .paeth => paeth: {
            filterPaeth(filtered, row, above);
            break :paeth packRgb(false, filtered, filtered, &.{});
        },
        else => up: {
            if (rgb_only) break :up packRgb(true, filtered, row, above);
            filter(filtered, row, above);
            break :up filtered;
        },
    };
    return .{ .method = method, .bytes = bytes };
}

fn packRgb(comptime subtract: bool, bytes: []u8, current: []const u8, predictor: []const u8) []const u8 {
    const lanes = simd.scanline_bytes;
    const Blocks = @Vector(lanes, u8);
    const indices = [_]i32{ 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 15, 15, 15, 15 };
    const picks: @Vector(indices.len, i32) = indices;
    comptime std.debug.assert(@typeInfo(@TypeOf(picks)).vector.len == lanes);
    var i: usize = 0;
    var out: usize = 0;
    while (i + lanes <= current.len) : (i += lanes) {
        // A 12-byte store is split into scalar moves. The whole-vector store
        // stays within the supplied RGBA-sized buffer, and its four surplus
        // bytes are overwritten by the next block or excluded from the result.
        var block = @as(*align(1) const Blocks, @ptrCast(current[i..][0..lanes])).*;
        if (subtract) block -%= @as(*align(1) const Blocks, @ptrCast(predictor[i..][0..lanes])).*;
        @as(*align(1) Blocks, @ptrCast(bytes[out..][0..lanes])).* = @shuffle(u8, block, undefined, picks);
        out += 12;
    }
    while (i < current.len) : (i += 4) {
        const block: @Vector(3, u8) = current[i..][0..3].*;
        bytes[out..][0..3].* = if (subtract) block -% @as(@Vector(3, u8), predictor[i..][0..3].*) else block;
        out += 3;
    }
    return bytes[0..out];
}

fn filter(out: []u8, current: []const u8, predictor: []const u8) void {
    const lanes = simd.byte_lanes;
    const Vector = @Vector(lanes, u8);
    var i: usize = 0;
    while (i + lanes <= out.len) : (i += lanes) {
        const here: Vector = current[i..][0..lanes].*;
        const from: Vector = predictor[i..][0..lanes].*;
        out[i..][0..lanes].* = here -% from;
    }
    for (out[i..], current[i..], predictor[i..]) |*byte, now, from| byte.* = now -% from;
}

fn preferredFilter(row: []const u8, above: []const u8) png_format.Filter {
    // Nonzero residuals interrupt runs. Sample the row and favor Up when
    // choosing another predictor saves only a few of them.
    const pixel = @sizeOf(value.Pixel);
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
            const p = png_format.paeth(left, top, corner);
            up += @intFromBool(px != top);
            sub += @intFromBool(px != left);
            paeth += @intFromBool(px != p);
        }
    }
    if (paeth + paeth / filter_switch_margin < @min(up, sub)) return .paeth;
    if (sub + sub / filter_switch_margin < up) return .sub;
    return .up;
}

fn filterPaeth(out: []u8, current: []const u8, above: []const u8) void {
    const half = simd.byte_lanes / 2;
    const Bytes = @Vector(half, u8);
    const Wide = @Vector(half, i16);
    const pixel = @sizeOf(value.Pixel);
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
        out[i] = current[i] -% @as(u8, @intCast(png_format.paeth(a, b, c)));
    }
}

test "an encoded image starts with the PNG signature and ends with IEND" {
    const pixels = [_]value.Pixel{ .{ 1, 2, 3, 255 }, .{ 4, 5, 6, 128 } };
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, .{ .width = 2, .height = 1, .pixels = &pixels }, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), png_format.signature));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), png_format.iend_type ++ "\xae\x42\x60\x82"));
}

test "each emitted chunk carries the PNG checksum" {
    const allocator = std.testing.allocator;
    const pixels = [_]value.Pixel{ .{ 32, 22, 8, 255 }, .{ 44, 27, 12, 70 } };
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    try write(allocator, .{ .width = 2, .height = 1, .pixels = &pixels }, &out.writer);
    var chunks: png_format.Chunks = .{ .remaining = out.written()[png_format.signature.len..] };
    while (chunks.nextChecksums()) |checksums| {
        try std.testing.expectEqual(checksums.computed, checksums.stored);
    }
    try std.testing.expectEqual(0, chunks.remaining.len);
}

test "encoding releases each allocation on failure" {
    const encode = struct {
        fn once(allocator: Allocator, image: Image) !void {
            var out: Writer.Allocating = .init(allocator);
            defer out.deinit();
            write(allocator, image, &out.writer) catch |err| switch (err) {
                // The allocating writer reports its own allocation failure as a write failure.
                error.WriteFailed => return error.OutOfMemory,
                else => |other| return other,
            };
        }
    };
    const pixels: [4 * 4]value.Pixel = @splat(.{ 1, 2, 3, 255 });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encode.once, .{Image{ .width = 4, .height = 4, .pixels = &pixels }});
}

test "staged PNG rows preserve the predictor across two strip boundaries and a tail" {
    const Source = struct {
        image: Image,

        pub const staged = true;

        pub fn isOpaque(self: @This()) bool {
            return self.image.isOpaque();
        }

        pub fn row(self: @This(), y: usize, scratch: []value.Pixel) []const value.Pixel {
            const pixels = self.image.row(y);
            if (y % 2 == 1) return pixels;
            @memcpy(scratch, pixels);
            return scratch;
        }
    };

    const allocator = std.testing.allocator;
    const width = 17;
    const height = 2 * strip_rows + 3;
    var pixels: [width * height]value.Pixel = undefined;
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
        const header = try stb.probe(allocator, streamed.written(), value.max_decode_bytes);
        const decoded = try decoder.decode(allocator, streamed.written(), header, value.max_decode_bytes);
        defer memory.freeBlock(@constCast(decoded.ptr));
        try std.testing.expectEqualSlices(value.Pixel, image.pixels, decoded);
    }
}

test "sheets below the parallel threshold use the serial encoder" {
    const allocator = std.testing.allocator;
    const width = 1025;
    const height = 1027;
    const pixels = try allocator.alloc(value.Pixel, width * height);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, i| {
        pixel.* = .{ @intCast(i % 179), @intCast(i / width % 227), @intCast(i % 211), 255 };
    }
    const image: Image = .{ .width = width, .height = height, .pixels = pixels };
    const Source = struct {
        image: Image,

        pub const staged = true;

        pub fn isOpaque(_: @This()) bool {
            return true;
        }

        pub fn row(self: @This(), y: usize, _: []value.Pixel) []const value.Pixel {
            return self.image.row(y);
        }
    };
    var streamed: Writer.Allocating = .init(allocator);
    defer streamed.deinit();
    var serial: Writer.Allocating = .init(allocator);
    defer serial.deinit();
    try writeRowsWithIo(std.testing.io, allocator, image.size(), Source{ .image = image }, &streamed.writer);
    try write(allocator, image, &serial.writer);
    try std.testing.expectEqualSlices(u8, serial.written(), streamed.written());
}

test "a sheet above the strip threshold has the same bytes with or without an Io" {
    const allocator = std.testing.allocator;
    const width = 1291;
    const height = 1633;
    const pixels = try allocator.alloc(value.Pixel, width * height);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, i| pixel.* = .{ @intCast(i % 251), @intCast(i / width % 199), @intCast(i % 149), 255 };
    const image: Image = .{ .width = width, .height = height, .pixels = pixels };
    var outputs: [2]Writer.Allocating = .{ .init(allocator), .init(allocator) };
    defer for (&outputs) |*output| output.deinit();
    try writeRowsWithIo(std.testing.io, allocator, image.size(), BorrowedRows{ .image = image }, &outputs[0].writer);
    try writeRowsWithIo(null, allocator, image.size(), BorrowedRows{ .image = image }, &outputs[1].writer);
    try std.testing.expectEqualSlices(u8, outputs[0].written(), outputs[1].written());
}

test "a failing writer stops parallel strips and releases every buffer" {
    const allocator = std.testing.allocator;
    const width = 1291;
    const height = 1633;
    const pixels = try allocator.alloc(value.Pixel, width * height);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, i| pixel.* = .{ @intCast(i % 251), @intCast(i / width % 199), @intCast(i % 149), 101 };
    const image: Image = .{ .width = width, .height = height, .pixels = pixels };
    // Room for the header and part of the first strip only.
    var buffer: [64 * 1024]u8 = undefined;
    var output: Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, writeRowsWithIo(std.testing.io, allocator, image.size(), BorrowedRows{ .image = image }, &output));
}

test "overlapped strip compression reconstructs RGBA and RGB rows across worker reuse" {
    const allocator = std.testing.allocator;
    const width = 1291;
    const height = 1633;
    const pixels = try allocator.alloc(value.Pixel, width * height);
    defer allocator.free(pixels);
    const image: Image = .{ .width = width, .height = height, .pixels = pixels };
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    for ([_]u8{ 255, 101 }) |alpha| {
        for (pixels, 0..) |*pixel, i| {
            pixel.* = .{ @intCast(i % 251), @intCast(i / width % 199), @intCast(i % 149), alpha };
        }
        output.clearRetainingCapacity();
        try writeRowsWithIo(std.testing.io, allocator, image.size(), BorrowedRows{ .image = image }, &output.writer);
        const header = try stb.probe(allocator, output.written(), value.max_decode_bytes);
        const decoded = try decoder.decode(allocator, output.written(), header, value.max_decode_bytes);
        defer memory.freeBlock(@constCast(decoded.ptr));
        try std.testing.expectEqualSlices(value.Pixel, pixels, decoded);
    }
}

test "strips copy a staged row that its source reuses" {
    const Source = struct {
        image: Image,
        reused: []value.Pixel,

        pub const staged = true;

        pub fn isOpaque(_: @This()) bool {
            return false;
        }

        pub fn row(self: @This(), y: usize, _: []value.Pixel) []const value.Pixel {
            @memcpy(self.reused, self.image.row(y));
            return self.reused;
        }
    };
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 7;
    var pixels: [width * height]value.Pixel = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = .{ @intCast(i * 7), @intCast(i * 5), @intCast(i), 200 };
    var reused: [width]value.Pixel = undefined;
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    try png_format.writeHeader(zlib.chunk, &out.writer, width, height, .rgba);
    try writeStrips(null, allocator, image.size(), Source{ .image = image, .reused = &reused }, &out.writer, false, 1 + width * @sizeOf(value.Pixel), 1);
    try zlib.chunk(&out.writer, png_format.iend_type, "");
    const header = try stb.probe(allocator, out.written(), value.max_decode_bytes);
    const decoded = try decoder.decode(allocator, out.written(), header, value.max_decode_bytes);
    defer memory.freeBlock(@constCast(decoded.ptr));
    try std.testing.expectEqualSlices(value.Pixel, image.pixels, decoded);
}

test {
    std.testing.refAllDecls(@This());
}
