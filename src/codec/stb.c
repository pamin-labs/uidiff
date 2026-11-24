/* Compile only the in-memory PNG and JPEG paths used by the binding, and
   route every allocation through the binding's Zig allocator. */
#include <stddef.h>
#ifndef STBI_MAX_DIMENSIONS
#error "build.zig defines STBI_MAX_DIMENSIONS from max_extent in src/value/image.zig"
#endif
void *uidiff_stbi_malloc(size_t size);
void *uidiff_stbi_realloc(void *block, size_t size);
void uidiff_stbi_free(void *block);
#define STBI_MALLOC(size) uidiff_stbi_malloc(size)
#define STBI_REALLOC(block, size) uidiff_stbi_realloc(block, size)
#define STBI_FREE(block) uidiff_stbi_free(block)
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_FAILURE_STRINGS
#include "stb_image.h"
