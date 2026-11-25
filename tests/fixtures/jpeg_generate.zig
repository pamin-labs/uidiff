//! Regenerates the small procedural JPEG profiles with the pinned encoder.
const std = @import("std");
const fixtures = @import("jpeg.zig");
const jpeg = @import("jpeg_encode_c");
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
    for (fixtures.profiles) |profile| try generate(init.io, directory, profile);
}

fn generate(io: Io, directory: Io.Dir, profile: fixtures.Profile) GenerateError!void {
    var encoder = std.mem.zeroes(jpeg.jpeg_compress_struct);
    var errors: jpeg.jpeg_error_mgr = undefined;
    // The encoder's default handler exits this build tool on a fatal error.
    encoder.err = jpeg.jpeg_std_error(&errors);
    jpeg.jpeg_CreateCompress(&encoder, jpeg.JPEG_LIB_VERSION, @sizeOf(jpeg.jpeg_compress_struct));
    defer jpeg.jpeg_destroy_compress(&encoder);
    var encoded: [*c]u8 = null;
    var length: c_ulong = 0;
    jpeg.jpeg_mem_dest(&encoder, &encoded, &length);
    defer jpeg.free(encoded);

    encoder.image_width = fixtures.width;
    encoder.image_height = fixtures.height;
    const input: jpeg.J_COLOR_SPACE, const color: jpeg.J_COLOR_SPACE, const components: c_int = switch (profile.encoding.color) {
        .gray => .{ jpeg.JCS_GRAYSCALE, jpeg.JCS_GRAYSCALE, 1 },
        .ycbcr => .{ jpeg.JCS_RGB, jpeg.JCS_YCbCr, 3 },
        .cmyk => .{ jpeg.JCS_CMYK, jpeg.JCS_CMYK, 4 },
        .ycck => .{ jpeg.JCS_CMYK, jpeg.JCS_YCCK, 4 },
    };
    encoder.input_components = components;
    encoder.in_color_space = input;
    jpeg.jpeg_set_defaults(&encoder);
    jpeg.jpeg_set_colorspace(&encoder, color);
    encoder.dct_method = jpeg.JDCT_ISLOW;
    if (profile.encoding.color == .ycbcr) encoder.comp_info[0].v_samp_factor = profile.encoding.vertical_samples;
    jpeg.jpeg_set_quality(&encoder, quality, jpeg.TRUE);
    if (profile.encoding.progressive) jpeg.jpeg_simple_progression(&encoder);
    jpeg.jpeg_start_compress(&encoder, jpeg.TRUE);
    while (encoder.next_scanline < fixtures.height) {
        const y = encoder.next_scanline;
        var samples: [fixtures.width * max_components]u8 = undefined;
        const count: usize = @intCast(components);
        for (0..fixtures.width) |x| {
            for (0..count) |channel| {
                const channel_value = 17 * x + 23 * y + 61 * channel + x * y * (1 + channel);
                // The fixture pattern repeats modulo the sample depth.
                samples[x * count + channel] = @truncate(channel_value);
            }
        }
        var row: jpeg.JSAMPROW = &samples;
        if (jpeg.jpeg_write_scanlines(&encoder, &row, 1) != 1) return error.EncodeFailed;
    }
    jpeg.jpeg_finish_compress(&encoder);
    if (encoded == null or length == 0) return error.EncodeFailed;
    try directory.writeFile(io, .{ .sub_path = profile.file, .data = encoded[0..length] });
}

test {
    std.testing.refAllDecls(@This());
}
