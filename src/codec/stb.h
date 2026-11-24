/* The translated interface for stb_image and the PNG fast path. */
#include <stdint.h>
#include <stddef.h>
#include "stb_image.h"

int uidiff_png_stream_header(const uint8_t *bytes, size_t len);

enum { UIDIFF_PNG_FALLBACK, UIDIFF_PNG_DECODED, UIDIFF_PNG_ALLOC_FAILED };
int uidiff_png_load(const uint8_t *bytes, size_t len, uint32_t width,
                    uint32_t height, uint8_t **result);
