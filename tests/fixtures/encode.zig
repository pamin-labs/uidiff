//! Encoders used only by the fixture generator, through their own translated
//! stb and libwebp headers, which the shipped library does not include.
const std = @import("std");
const stb = @import("stb_write_c");
const webp = @import("webp_encode_c");
const memory = @import("codec_memory");
const uidiff = @import("uidiff");
const cases = @import("cases.zig");
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
    var sink: Sink = .{ .writer = output };
    switch (format) {
        .png, .jpg => {
            const ok = if (format == .png)
                stb.stbi_write_png_to_func(emit, &sink, width, height, channels, pixels.ptr, width * channels)
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
            if (length == 0) return error.EncodingFailed;
            try output.writeAll(encoded[0..length]);
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
    const data: [*]const u8 = @ptrCast(bytes orelse return);
    sink.writer.writeAll(data[0..count]) catch |err| {
        sink.failure = err;
    };
}

test {
    std.testing.refAllDecls(@This());
}
