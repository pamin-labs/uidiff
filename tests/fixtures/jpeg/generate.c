/* Regenerates the small JPEG profile fixtures. See README.md. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>

enum { width = UIDIFF_FIXTURE_WIDTH, height = UIDIFF_FIXTURE_HEIGHT, quality = 87 };

struct profile {
    J_COLOR_SPACE color;
    int vertical_sampling;
    int progressive;
};

static void generate(const struct profile *profile, FILE *file) {
    struct jpeg_compress_struct encoder;
    struct jpeg_error_mgr error;
    encoder.err = jpeg_std_error(&error);
    jpeg_create_compress(&encoder);
    jpeg_stdio_dest(&encoder, file);
    encoder.image_width = width;
    encoder.image_height = height;
    encoder.input_components = profile->color == JCS_GRAYSCALE ? 1 :
                               profile->color == JCS_YCbCr ? 3 : 4;
    encoder.in_color_space = encoder.input_components == 4 ? JCS_CMYK :
                             encoder.input_components == 3 ? JCS_RGB : JCS_GRAYSCALE;
    jpeg_set_defaults(&encoder);
    jpeg_set_colorspace(&encoder, profile->color);
    encoder.dct_method = JDCT_ISLOW;
    if (profile->color == JCS_YCbCr)
        encoder.comp_info[0].v_samp_factor = profile->vertical_sampling;
    jpeg_set_quality(&encoder, quality, TRUE);
    if (profile->progressive) jpeg_simple_progression(&encoder);
    jpeg_start_compress(&encoder, TRUE);
    while (encoder.next_scanline < height) {
        unsigned y = encoder.next_scanline;
        JSAMPLE samples[width * 4];
        JSAMPROW row = samples;
        for (unsigned x = 0; x < width; ++x) {
            for (unsigned c = 0; c < (unsigned)encoder.input_components; ++c)
                *row++ = (JSAMPLE)((17 * x + 23 * y + 61 * c + x * y * (1 + c)) & 255);
        }
        row = samples;
        if (jpeg_write_scanlines(&encoder, &row, 1) != 1) exit(EXIT_FAILURE);
    }
    jpeg_finish_compress(&encoder);
    jpeg_destroy_compress(&encoder);
}

int main(int argc, char **argv) {
    const struct profile profiles[] = {
        { JCS_YCbCr, 2, 0 },
        { JCS_YCbCr, 1, 0 },
        { JCS_YCbCr, 2, 1 },
        { JCS_GRAYSCALE, 1, 0 },
        { JCS_CMYK, 1, 0 },
        { JCS_YCCK, 1, 0 },
    };
    const size_t count = sizeof profiles / sizeof *profiles;
    if (argc != (int)count + 2) return EXIT_FAILURE;
    for (size_t i = 0; i < count; ++i) {
        const char *name = argv[i + 2];
        const size_t capacity = strlen(argv[1]) + strlen(name) + sizeof "/";
        char *path = malloc(capacity);
        if (!path) return EXIT_FAILURE;
        const int len = snprintf(path, capacity, "%s/%s", argv[1], name);
        FILE *file = len >= 0 && (size_t)len < capacity ? fopen(path, "wb") : NULL;
        free(path);
        if (!file) return EXIT_FAILURE;
        generate(&profiles[i], file);
        if (fclose(file)) return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
