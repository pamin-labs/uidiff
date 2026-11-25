#ifndef UIDIFF_PNG_STREAM_H
#define UIDIFF_PNG_STREAM_H
#include <stddef.h>
#include <stdint.h>

int uidiff_png_stream_header(const uint8_t *bytes, size_t len);

enum { UIDIFF_PNG_FALLBACK, UIDIFF_PNG_DECODED, UIDIFF_PNG_ALLOC_FAILED };
int uidiff_png_load(const uint8_t *bytes, size_t len, uint32_t width,
                    uint32_t height, uint8_t **result);

#endif
