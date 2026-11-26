//! Encoders used only by the fixture generator, through their own translated
//! stb and libwebp headers, which the shipped library does not include.
const std = @import("std");
const stb = @import("stb_write_c");
const webp = @import("webp_encode_c");
const memory = @import("codec_memory");
const uidiff = @import("uidiff");
const cases = @import("fixture_cases");
const Writer = std.Io.Writer;

const Sink = struct {
    writer: *Writer,
    failure: ?Writer.Error = null,
};

/// Encoder, allocation, or output failures.
pub const EncodeError = error{EncodingFailed} || Writer.Error;

const channels = 4;
const jpeg_quality = 100;

/// Encodes one image to the supplied writer. The source is packed RGBA8.
pub fn write(allocator: std.mem.Allocator, format: cases.Format, width: c_int, height: c_int, pixels: []const u8, output: *Writer) EncodeError!void {
    if (width <= 0 or height <= 0) return error.EncodingFailed;
    const stride = std.math.mul(c_int, width, channels) catch return error.EncodingFailed;
    const footprint = std.math.mul(usize, @intCast(stride), @intCast(height)) catch return error.EncodingFailed;
    if (pixels.len != footprint) return error.EncodingFailed;
    var sink: Sink = .{ .writer = output };
    switch (format) {
        .png, .jpg => {
            const ok = if (format == .png)
                stb.stbi_write_png_to_func(emit, &sink, width, height, channels, pixels.ptr, stride)
            else
                stb.stbi_write_jpg_to_func(emit, &sink, width, height, channels, pixels.ptr, jpeg_quality);
            if (sink.failure) |err| return err;
            if (ok == 0) return error.EncodingFailed;
        },
        .webp => {
            memory.begin(allocator, uidiff.max_decode_bytes);
            defer memory.end();
            var encoded: [*c]u8 = null;
            const length = webp.WebPEncodeLosslessRGBA(pixels.ptr, width, height, width * channels, &encoded);
            if (encoded == null) return error.EncodingFailed;
            defer webp.WebPFree(encoded);
            const allocation = memory.allocatedBytes(encoded);
            if (length == 0 or length > allocation.len) return error.EncodingFailed;
            try output.writeAll(allocation[0..length]);
        },
    }
}

fn emit(context: ?*anyopaque, bytes: ?*anyopaque, length: c_int) callconv(.c) void {
    const sink: *Sink = @ptrCast(@alignCast(context orelse return));
    if (sink.failure != null) return;
    const count = std.math.cast(usize, length) orelse {
        sink.failure = error.WriteFailed;
        return;
    };
    if (count == 0) return;
    const address = bytes orelse {
        sink.failure = error.WriteFailed;
        return;
    };
    // stb supplies a readable span of count bytes for the duration of the callback.
    const data = @as([*]const u8, @ptrCast(address))[0..count];
    sink.writer.writeAll(data) catch |err| {
        sink.failure = err;
    };
}

test {
    std.testing.refAllDecls(@This());
}
