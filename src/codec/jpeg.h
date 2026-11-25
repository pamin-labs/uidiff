#ifndef UIDIFF_JPEG_H
#define UIDIFF_JPEG_H
#include <stddef.h>
#include <stdint.h>
#include "codec_memory.h"

/* The scan limit used by libjpeg-turbo's fuzzer. */
#define UIDIFF_JPEG_MAX_SCANS 500

/* Returns an RGBA image owned by the active codec-memory allocation scope. */
uint8_t *uidiff_jpeg_decode(const uint8_t *bytes, size_t len,
                           uint32_t width, uint32_t height);

#endif
