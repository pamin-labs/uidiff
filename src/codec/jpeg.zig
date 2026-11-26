//! Probes JPEG frames and runs the bounded 8-bit libjpeg-turbo decoder.
const std = @import("std");
const c = @import("jpeg_c");
const memory = @import("codec_memory");
const decoded_size = @import("dimensions.zig");
const values = @import("../value.zig");
const Allocator = std.mem.Allocator;
const Pixel = values.Pixel;
const Size = values.Size;
const Header = decoded_size.Header;

/// Malformed input or a refusal from the codec memory budget.
pub const DecodeError = memory.Error;

const Decode = struct {
    bytes: []const u8,
    length: c_ulong,
    size: Size,
    count: usize,
    pixels: ?[]Pixel = null,
};

// The scan-limit cases send one bit plane of one zero coefficient per scan.
const ProgressiveFixture = struct {
    const scan_bytes = 11;
    const most_significant_bit = 13;
    const bit_planes = most_significant_bit + 1;
    const coefficient_count = 64;

    /// Sends one bit plane of one zero coefficient per scan, always in a 1×1 frame.
    fn generate(comptime header: []const u8, comptime eoi: []const u8, comptime scans: usize) [header.len + scans * scan_bytes + eoi.len]u8 {
        comptime std.debug.assert(scans <= coefficient_count * bit_planes);
        var bytes: [header.len + scans * scan_bytes + eoi.len]u8 = undefined;
        @memcpy(bytes[0..header.len], header);
        for (0..scans) |index| {
            const coefficient: u8 = @intCast(index / bit_planes);
            const low: u8 = @intCast(most_significant_bit - index % bit_planes);
            const high = if (low == most_significant_bit) 0 else low + 1;
            const start = header.len + index * scan_bytes;
            // The only Huffman symbol (or DC refinement bit) is zero; pad with ones.
            bytes[start..][0..scan_bytes].* = .{ 0xff, 0xda, 0, 8, 1, 1, 0, coefficient, coefficient, high << 4 | low, 0x7f };
        }
        @memcpy(bytes[bytes.len - eoi.len ..], eoi);
        return bytes;
    }
};

// Limit progressive scans to keep bounded-memory decoding bounded in work.
const max_scans = 500;
const coverage_rounding_bias = 128;
const coverage_bits = 8;
const soi = "\xff\xd8";
const marker_prefix = 0xff;
const first_scan = 0xda;
const end_of_image = 0xd9;
const baseline_frame = 0xc0;
const extended_frame = 0xc1;
const progressive_frame = 0xc2;
const lossless_frame = 0xc3;
const differential_frame_first = 0xc5;
const differential_frame_last = 0xc7;
const arithmetic_frame_first = 0xc9;
const arithmetic_frame_last = 0xcb;
const differential_arithmetic_frame_first = 0xcd;
const differential_arithmetic_frame_last = 0xcf;
const sample_precision = 8;
const precision_offset = @sizeOf(u16);
const height_offset = precision_offset + @sizeOf(u8);
const width_offset = height_offset + @sizeOf(u16);
const minimum_frame_length = width_offset + @sizeOf(u16) + @sizeOf(u8);

/// Recognizes the JPEG start-of-image marker.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, soi);
}

/// Reads dimensions without starting entropy decode or allocating the image.
pub fn probe(_: Allocator, bytes: []const u8, cap: usize) DecodeError!Header {
    if (!matches(bytes)) return error.InvalidImage;
    var offset: usize = soi.len;
    while (offset < bytes.len and bytes[offset] == marker_prefix) {
        while (offset < bytes.len and bytes[offset] == marker_prefix) offset += 1;
        if (bytes.len - offset < 1 + @sizeOf(u16)) break;
        const marker = bytes[offset];
        offset += 1;
        if (marker == first_scan or marker == end_of_image) break;
        const len = std.mem.readInt(u16, bytes[offset..][0..2], .big);
        if (len < @sizeOf(u16) or len > bytes.len - offset) break;
        switch (marker) {
            baseline_frame, extended_frame, progressive_frame => {
                // The trimmed C decoder has no dispatch for wider samples.
                if (len < minimum_frame_length or bytes[offset + precision_offset] != sample_precision) return error.InvalidImage;
                const height: usize = std.mem.readInt(u16, bytes[offset + height_offset ..][0..@sizeOf(u16)], .big);
                const width: usize = std.mem.readInt(u16, bytes[offset + width_offset ..][0..@sizeOf(u16)], .big);
                if (width == 0 or height == 0) return error.InvalidImage;
                if (width * height > cap / @sizeOf(Pixel)) return error.ImageTooLarge;
                return .{ .size = .{ .width = width, .height = height } };
            },
            lossless_frame,
            differential_frame_first...differential_frame_last,
            arithmetic_frame_first...arithmetic_frame_last,
            differential_arithmetic_frame_first...differential_arithmetic_frame_last,
            => return error.InvalidImage,
            else => offset += len,
        }
    }
    return error.InvalidImage;
}

/// Decodes RGBA8 under the caller's memory cap. The caller releases the result.
pub fn decode(allocator: Allocator, bytes: []const u8, header: Header, cap: usize) DecodeError![]Pixel {
    const count = header.size.pixelCount() orelse return error.ImageTooLarge;
    const length = std.math.cast(c_ulong, bytes.len) orelse return error.ImageTooLarge;
    memory.begin(allocator, @min(cap, values.max_decode_bytes));
    defer memory.end();
    var run: Decode = .{ .bytes = bytes, .length = length, .size = header.size, .count = count };
    var decoder = std.mem.zeroes(c.jpeg_decompress_struct);
    if (c.uidiff_jpeg_guard(&decoder, decodeRows, &run) == 0) {
        if (run.pixels) |pixels| memory.uidiff_codec_free(pixels.ptr);
        return memory.failure();
    }
    return run.pixels orelse error.InvalidImage;
}

/// Releases the decoded block through the allocator recorded when it was created.
pub fn release(_: Allocator, pixels: []const Pixel) void {
    memory.uidiff_codec_free(@constCast(pixels.ptr));
}

fn decodeRows(pointer: c.j_decompress_ptr, context: ?*anyopaque) callconv(.c) c_int {
    // Only the guard calls this callback, with a live decoder and caller-owned
    // Decode. A libjpeg error may jump out, so the callback owns no cleanup.
    const run: *Decode = @ptrCast(@alignCast(context));
    const decoder: *c.jpeg_decompress_struct = pointer;
    c.jpeg_CreateDecompress(decoder, c.JPEG_LIB_VERSION, @sizeOf(c.jpeg_decompress_struct));
    c.jpeg_mem_src(decoder, run.bytes.ptr, run.length);
    if (c.jpeg_read_header(decoder, c.TRUE) != c.JPEG_HEADER_OK or
        decoder.data_precision != sample_precision or
        decoder.image_width != run.size.width or decoder.image_height != run.size.height) return 0;

    var progress = std.mem.zeroes(c.jpeg_progress_mgr);
    progress.progress_monitor = limitScans;
    if (c.jpeg_has_multiple_scans(decoder) != 0) decoder.progress = &progress;
    const cmyk = decoder.jpeg_color_space == c.JCS_CMYK or decoder.jpeg_color_space == c.JCS_YCCK;
    decoder.out_color_space = if (cmyk) c.JCS_CMYK else c.JCS_EXT_RGBA;
    decoder.dct_method = c.JDCT_ISLOW;
    decoder.do_fancy_upsampling = c.TRUE;
    if (c.jpeg_start_decompress(decoder) == 0 or decoder.output_components != @sizeOf(Pixel) or
        decoder.output_width != run.size.width or decoder.output_height != run.size.height) return 0;
    // Unbuffered startup consumes all input scans of a multi-scan image.
    decoder.progress = null;

    // libjpeg initializes every scanline before successful completion.
    const bytes = memory.allocBytes(run.count * @sizeOf(Pixel)) orelse return 0;
    const pixels = std.mem.bytesAsSlice(Pixel, bytes);
    run.pixels = pixels;
    while (decoder.output_scanline < run.size.height) {
        const row = pixels[@as(usize, decoder.output_scanline) * run.size.width ..][0..run.size.width];
        var samples: c.JSAMPROW = std.mem.sliceAsBytes(row).ptr;
        if (c.jpeg_read_scanlines(decoder, &samples, 1) != 1) return 0;
        if (cmyk) convertCmyk(row, decoder.saw_Adobe_marker != 0);
    }
    return @intFromBool(c.jpeg_finish_decompress(decoder) != 0);
}

fn limitScans(common: c.j_common_ptr) callconv(.c) void {
    // This monitor is installed exclusively on the decompressor.
    const decoder: c.j_decompress_ptr = @ptrCast(@alignCast(common));
    if (decoder.*.input_scan_number > max_scans) c.uidiff_jpeg_fail(common);
}

fn convertCmyk(row: []Pixel, inverted: bool) void {
    const Bytes = @Vector(@sizeOf(Pixel), u8);
    const Words = @Vector(@sizeOf(Pixel), u32);
    for (row) |*pixel| {
        const samples: Bytes = pixel.*;
        const ink: Words = @intCast(if (inverted) samples else ~samples);
        // Widen before arithmetic so every intermediate fits in a lane.
        const partial = ink * @as(Words, @splat(ink[3])) + @as(Words, @splat(coverage_rounding_bias));
        const rounded = (partial + (partial >> @splat(coverage_bits))) >> @splat(coverage_bits);
        const rgb: Bytes = @intCast(rounded);
        pixel.* = @shuffle(u8, rgb, @as(Bytes, @splat(255)), @Vector(4, i32){ 0, 1, 2, -1 });
    }
}

fn checkGray(allocator: Allocator, encoded: []const u8) !void {
    const header = try probe(allocator, encoded, values.max_decode_bytes);
    const pixels = try decode(allocator, encoded, header, values.max_decode_bytes);
    defer release(allocator, pixels);
    try std.testing.expectEqualSlices(values.Pixel, &.{.{ 128, 128, 128, 255 }}, pixels);
}

test "8-bit grayscale decodes to opaque RGBA and releases partial allocations" {
    const jpeg = @import("../testing/jpeg.zig");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkGray, .{@as([]const u8, &jpeg.gray)});
}

test "only complete 8-bit Huffman frame headers are accepted" {
    var header = "\xff\xd8\xff\xc2\x00\x0b\x08\x00\x01\x00\x02\x01\x01\x11\x00".*;
    const allocator = std.testing.allocator;
    const output_bytes = 2 * @sizeOf(Pixel);
    try std.testing.expectEqual(Size{ .width = 2, .height = 1 }, (try probe(allocator, &header, output_bytes)).size);
    try std.testing.expectError(error.ImageTooLarge, probe(allocator, &header, output_bytes - 1));
    try std.testing.expectError(error.InvalidImage, probe(allocator, header[0 .. header.len - 1], output_bytes));
    header[6] = 12;
    try std.testing.expectError(error.InvalidImage, probe(allocator, &header, output_bytes));
    header[6] = sample_precision;
    const supported = header;
    for ([_]u8{ 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf }) |marker| {
        header[3] = marker;
        try std.testing.expectError(error.InvalidImage, probe(allocator, &(header ++ supported[2..].*), output_bytes));
    }
}

test "JPEG warnings reject truncated sequential and progressive streams" {
    const jpeg = @import("../testing/jpeg.zig");
    const allocator = std.testing.allocator;
    const progressive = ProgressiveFixture.generate(&jpeg.frame(.progressive), &jpeg.eoi, 2);
    for ([_][]const u8{ &jpeg.gray, &progressive }) |complete| {
        const bytes = complete[0 .. complete.len - jpeg.eoi.len];
        const header = try probe(allocator, bytes, values.max_decode_bytes);
        try std.testing.expectError(error.InvalidImage, decode(allocator, bytes, header, values.max_decode_bytes));
        try checkGray(allocator, &jpeg.gray);
    }
}

test "JPEG progressive scan limit accepts the boundary and rejects the next scan" {
    const jpeg = @import("../testing/jpeg.zig");
    const allocator = std.testing.allocator;
    const at_limit = ProgressiveFixture.generate(&jpeg.frame(.progressive), &jpeg.eoi, max_scans);
    const header = try probe(allocator, &at_limit, values.max_decode_bytes);
    const pixels = try decode(allocator, &at_limit, header, values.max_decode_bytes);
    defer release(allocator, pixels);
    try std.testing.expectEqual(@as(usize, 1), pixels.len);

    const past_limit = ProgressiveFixture.generate(&jpeg.frame(.progressive), &jpeg.eoi, max_scans + 1);
    try std.testing.expectError(error.InvalidImage, decode(allocator, &past_limit, header, values.max_decode_bytes));
}

test "JPEG rejects header mismatch before allocating output" {
    const jpeg = @import("../testing/jpeg.zig");
    var scratch: [64 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const header: Header = .{ .size = .{ .width = 512, .height = 512 } };
    try std.testing.expectError(error.InvalidImage, decode(fixed.allocator(), &jpeg.gray, header, values.max_decode_bytes));
}

test {
    std.testing.refAllDecls(@This());
}
