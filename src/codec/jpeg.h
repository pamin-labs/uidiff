#ifndef UIDIFF_JPEG_H
#define UIDIFF_JPEG_H
#include <stddef.h>
#include <stdint.h>

/* Returns an RGBA image owned by the active codec-memory allocation scope. */
uint8_t *uidiff_jpeg_decode(const uint8_t *bytes, size_t len,
                           uint32_t width, uint32_t height);
void *uidiff_codec_malloc(size_t bytes);
void uidiff_codec_free(void *pixels);

#endif
