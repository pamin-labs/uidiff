/* The libjpeg error callback and its jump target both stay in C. */
#include "jpeg.h"
#include <limits.h>
#include <setjmp.h>
#include <stdio.h>
#include "jpeglib.h"

enum { channels = 4, opaque_alpha = UINT8_MAX };

struct decode_error {
    struct jpeg_error_mgr manager;
    jmp_buf jump;
};

static void count_warning(j_common_ptr decoder, int level) {
    if (level < 0) ++decoder->err->num_warnings;
}

static void reset_errors(j_common_ptr decoder) {
    decoder->err->num_warnings = 0;
    decoder->err->msg_code = 0;
}

static void fail(j_common_ptr decoder) {
    struct decode_error *error = (struct decode_error *)decoder->err;
    longjmp(error->jump, 1);
}

static unsigned multiply_coverage(unsigned a, unsigned b) {
    const unsigned partial = a * b + 128;
    return (partial + (partial >> 8)) >> 8;
}

static void cmyk_to_rgba(uint8_t *row, uint32_t width, int inverted) {
    for (uint32_t x = 0; x < width; ++x, row += channels) {
        const unsigned black = inverted ? row[3] : opaque_alpha - row[3];
        for (unsigned c = 0; c < channels - 1; ++c) {
            const unsigned ink = inverted ? row[c] : opaque_alpha - row[c];
            row[c] = (uint8_t)multiply_coverage(ink, black);
        }
        row[3] = opaque_alpha;
    }
}

static int decode_rows(struct jpeg_decompress_struct *decoder, const uint8_t *bytes,
                       unsigned long len, uint32_t width, uint32_t height,
                       uint8_t *pixels, struct decode_error *error) {
    error->manager = (struct jpeg_error_mgr){
        .error_exit = fail,
        .emit_message = count_warning,
        .reset_error_mgr = reset_errors,
    };
    decoder->err = &error->manager;
    if (setjmp(error->jump)) return 0;

    jpeg_create_decompress(decoder);
    jpeg_mem_src(decoder, bytes, len);
    if (jpeg_read_header(decoder, TRUE) != JPEG_HEADER_OK ||
        decoder->data_precision != BITS_IN_JSAMPLE ||
        decoder->image_width != width || decoder->image_height != height) return 0;
    const int cmyk = decoder->jpeg_color_space == JCS_CMYK ||
                     decoder->jpeg_color_space == JCS_YCCK;
    decoder->out_color_space = cmyk ? JCS_CMYK : JCS_EXT_RGBA;
    decoder->dct_method = JDCT_ISLOW;
    decoder->do_fancy_upsampling = TRUE;
    if (!jpeg_start_decompress(decoder) || decoder->output_components != channels ||
        decoder->output_width != width || decoder->output_height != height) return 0;

    const size_t stride = (size_t)width * channels;
    while (decoder->output_scanline < height) {
        JSAMPROW row = pixels + decoder->output_scanline * stride;
        if (jpeg_read_scanlines(decoder, &row, 1) != 1) return 0;
        if (cmyk) cmyk_to_rgba(row, width, decoder->saw_Adobe_marker);
    }
    return jpeg_finish_decompress(decoder);
}

uint8_t *uidiff_jpeg_decode(const uint8_t *bytes, size_t len,
                           uint32_t width, uint32_t height) {
    if (!width || !height || len > ULONG_MAX || width > SIZE_MAX / channels ||
        height > SIZE_MAX / (channels * (size_t)width)) return NULL;

    /* The scanline decoder writes every byte before a successful return. */
    uint8_t *pixels = uidiff_codec_malloc((size_t)width * height * channels);
    if (pixels == NULL) return NULL;
    /* Keep this object outside the setjmp frame so cleanup can read it. */
    struct jpeg_decompress_struct decoder = {0};
    struct decode_error error;
    const int decoded = decode_rows(&decoder, bytes, (unsigned long)len, width, height, pixels, &error);
    jpeg_destroy_decompress(&decoder);
    if (decoded) return pixels;
    uidiff_codec_free(pixels);
    return NULL;
}
