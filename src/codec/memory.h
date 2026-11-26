#ifndef UIDIFF_CODEC_MEMORY_H
#define UIDIFF_CODEC_MEMORY_H
#include <stddef.h>

void *uidiff_codec_malloc(size_t size);
void *uidiff_codec_calloc(size_t count, size_t size);
void *uidiff_codec_realloc(void *block, size_t size);
void uidiff_codec_free(void *block);

#endif
