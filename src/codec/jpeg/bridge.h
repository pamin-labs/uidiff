#ifndef UIDIFF_JPEG_H
#define UIDIFF_JPEG_H
#include <stddef.h>
#include <stdio.h>
#include "jpeglib.h"

typedef int (*uidiff_jpeg_run)(j_decompress_ptr decoder, void *context);

int uidiff_jpeg_guard(j_decompress_ptr decoder, uidiff_jpeg_run run, void *context);
void uidiff_jpeg_fail(j_common_ptr decoder);
#endif
