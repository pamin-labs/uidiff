//! Regenerates the small procedural JPEG profiles with the pinned encoder.
const std = @import("std");
const jpeg = @import("jpeg.zig");
const jpeg_encode_c = @import("jpeg_encode_c");
const Io = std.Io;

const GenerateError = std.process.Args.ToSliceError || Io.Dir.OpenError ||
    Io.Dir.WriteFileError || error{ InvalidArguments, EncodeFailed };
const quality = 87;
const max_components = 4;

/// Writes the JPEG profiles into the output directory passed by the build.
pub fn main(init: std.process.Init) GenerateError!void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    const directory = try Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer directory.close(init.io);
    for (jpeg.profiles) |profile| try generate(init.io, directory, profile);
}

fn generate(io: Io, directory: Io.Dir, profile: jpeg.Profile) GenerateError!void {
    var encoder = std.mem.zeroes(jpeg_encode_c.jpeg_compress_struct);
    var errors: jpeg_encode_c.jpeg_error_mgr = undefined;
    // The encoder's default handler exits this build tool on a fatal error.
    encoder.err = jpeg_encode_c.jpeg_std_error(&errors);
    jpeg_encode_c.jpeg_CreateCompress(&encoder, jpeg_encode_c.JPEG_LIB_VERSION, @sizeOf(jpeg_encode_c.jpeg_compress_struct));
    defer jpeg_encode_c.jpeg_destroy_compress(&encoder);
    var encoded: [*c]u8 = null;
    var length: c_ulong = 0;
    jpeg_encode_c.jpeg_mem_dest(&encoder, &encoded, &length);
    defer jpeg_encode_c.free(encoded);

    encoder.image_width = jpeg.width;
    encoder.image_height = jpeg.height;
    const input: jpeg_encode_c.J_COLOR_SPACE, const color: jpeg_encode_c.J_COLOR_SPACE, const components: c_int = switch (profile.encoding.color) {
        .gray => .{ jpeg_encode_c.JCS_GRAYSCALE, jpeg_encode_c.JCS_GRAYSCALE, 1 },
        .ycbcr => .{ jpeg_encode_c.JCS_RGB, jpeg_encode_c.JCS_YCbCr, 3 },
        .cmyk => .{ jpeg_encode_c.JCS_CMYK, jpeg_encode_c.JCS_CMYK, 4 },
        .ycck => .{ jpeg_encode_c.JCS_CMYK, jpeg_encode_c.JCS_YCCK, 4 },
    };
    encoder.input_components = components;
    encoder.in_color_space = input;
    jpeg_encode_c.jpeg_set_defaults(&encoder);
    jpeg_encode_c.jpeg_set_colorspace(&encoder, color);
    encoder.dct_method = jpeg_encode_c.JDCT_ISLOW;
    if (profile.encoding.color == .ycbcr) encoder.comp_info[0].v_samp_factor = profile.encoding.vertical_samples;
    jpeg_encode_c.jpeg_set_quality(&encoder, quality, jpeg_encode_c.TRUE);
    if (profile.encoding.progressive) jpeg_encode_c.jpeg_simple_progression(&encoder);
    jpeg_encode_c.jpeg_start_compress(&encoder, jpeg_encode_c.TRUE);
    while (encoder.next_scanline < jpeg.height) {
        const y = encoder.next_scanline;
        var samples: [jpeg.width * max_components]u8 = undefined;
        const count: usize = @intCast(components);
        for (0..jpeg.width) |x| {
            for (0..count) |channel| {
                const channel_value = 17 * x + 23 * y + 61 * channel + x * y * (1 + channel);
                // The fixture pattern repeats modulo the sample depth.
                samples[x * count + channel] = @intCast(channel_value & std.math.maxInt(u8));
            }
        }
        var row: jpeg_encode_c.JSAMPROW = &samples;
        if (jpeg_encode_c.jpeg_write_scanlines(&encoder, &row, 1) != 1) return error.EncodeFailed;
    }
    jpeg_encode_c.jpeg_finish_compress(&encoder);
    if (encoded == null or length == 0) return error.EncodeFailed;
    // jpeg_mem_dest returns the readable encoded span after finish_compress.
    try directory.writeFile(io, .{ .sub_path = profile.file, .data = encoded[0..length] });
}

test {
    std.testing.refAllDecls(@This());
}
