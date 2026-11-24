/* Streams ordinary RGB8 and RGBA8 PNG scanlines through a bounded DEFLATE dictionary.
   The stb_image binding handles all other PNG profiles. */
#include "stb.h"
#include <stdbool.h>
#include <string.h>
#include "zlib-ng.h"

/* A larger output span amortizes dictionary updates on Apple silicon. */
#if defined(__APPLE__) && defined(__aarch64__)
#define INFLATE_CHUNK_BYTES (64 * 1024)
#define UIDIFF_RGB8_STREAM 1
#else
#define INFLATE_CHUNK_BYTES (32 * 1024)
#define UIDIFF_RGB8_STREAM 0
#endif

void *uidiff_stbi_malloc(size_t size);
void uidiff_stbi_free(void *block);

typedef struct {
    uint8_t *next;
    uint8_t *partial;
    size_t stride;
#if UIDIFF_RGB8_STREAM
    size_t input_stride;
    uint8_t *expanded;
#endif
    size_t used;
    uint32_t remaining;
    const uint8_t *above;
} png_rows;

static size_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

int uidiff_png_stream_header(const uint8_t *data, size_t len) {
    static const uint8_t header[] = {0x89, 'P', 'N', 'G', 13, 10, 26, 10,
                                     0, 0, 0, 13, 'I', 'H', 'D', 'R'};
    return len >= 29 && memcmp(data, header, sizeof(header)) == 0 &&
           data[24] == 8 && (data[25] == 6 || (UIDIFF_RGB8_STREAM && data[25] == 2)) && data[26] == 0 &&
           data[27] == 0 && data[28] == 0;
}

/* Find the contiguous IDAT chunks without copying them. Defer other
   profiles to stb, including colour and animation extensions. */
static bool idat_range(const uint8_t *data, size_t len, size_t *first, size_t *end) {
    if (len < 33 || !uidiff_png_stream_header(data, len)) return false;
    *first = 0;
    *end = 0;
    for (size_t pos = 33; len - pos >= 12;) {
        const uint8_t *chunk = data + pos;
        const size_t size = be32(chunk);
        if (size > len - pos - 12) return false;
        const size_t next = pos + size + 12;
        if (memcmp(chunk + 4, "IDAT", 4) == 0) {
            if (*first == 0) *first = pos;
            else if (*end != pos) return false;
            *end = next;
        } else if (memcmp(chunk + 4, "IEND", 4) == 0) {
            return *first != 0 && size == 0;
        } else if ((chunk[4] & 32) == 0 || memcmp(chunk + 4, "tRNS", 4) == 0 ||
                   memcmp(chunk + 4, "acTL", 4) == 0) {
            return false;
        }
        pos = next;
    }
    return false;
}

typedef uint8_t rgba8 __attribute__((vector_size(4)));
typedef int16_t rgba16 __attribute__((vector_size(8)));
typedef uint8_t rgba_block __attribute__((vector_size(16)));

static rgba8 load_rgba(const uint8_t *p) {
    rgba8 pixel;
    memcpy(&pixel, p, sizeof(pixel));
    return pixel;
}

static void store_rgba(uint8_t *p, rgba8 pixel) {
    memcpy(p, &pixel, sizeof(pixel));
}

static rgba_block load_block(const uint8_t *p) {
    rgba_block pixels;
    memcpy(&pixels, p, sizeof(pixels));
    return pixels;
}

static rgba_block repeat_pixel(rgba8 pixel) {
    return __builtin_shufflevector(pixel, pixel, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3);
}

static rgba8 add_sub_block(uint8_t *dst, const uint8_t *src, rgba8 left) {
    const rgba_block zero = {0};
    rgba_block values = load_block(src);
    values += __builtin_shufflevector(zero, values, 0, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27);
    values += __builtin_shufflevector(zero, values, 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23);
    values += repeat_pixel(left);
    memcpy(dst, &values, sizeof(values));
    return __builtin_shufflevector(values, values, 12, 13, 14, 15);
}

static rgba16 widen(rgba8 pixel) {
    return __builtin_convertvector(pixel, rgba16);
}

static rgba8 narrow(rgba16 pixel) {
    return __builtin_convertvector(pixel, rgba8);
}

static rgba16 select_rgba(rgba16 mask, rgba16 yes, rgba16 no) {
    return (mask & yes) | (~mask & no);
}

static void unfilter_paeth(uint8_t *dst, const uint8_t *src,
                          const uint8_t *above, size_t size) {
    rgba16 upper_left = widen(load_rgba(above));
    rgba16 left = (widen(load_rgba(src)) + upper_left) & 255;
    store_rgba(dst, narrow(left));
    size_t i = 4;
    while (i < size) {
        // On a flat run in the preceding row Paeth predicts the left
        // pixel, which allows four output pixels per vector prefix sum.
        if (size - i >= 16) {
            const rgba_block up_block = load_block(above + i);
            const rgba_block same = (rgba_block)(up_block == repeat_pixel(narrow(upper_left)));
            if (__builtin_reduce_and(same) == 255) {
                left = widen(add_sub_block(dst + i, src + i, narrow(left)));
                i += 16;
                continue;
            }
        }
        const rgba16 up = widen(load_rgba(above + i));
        const rgba16 low = __builtin_elementwise_min(left, up);
        const rgba16 high = __builtin_elementwise_max(left, up);
        const rgba16 threshold = 3 * upper_left - (left + up);
        const rgba16 middle = select_rgba(high <= threshold, low, upper_left);
        const rgba16 predictor = select_rgba(threshold <= low, high, middle);
        left = (widen(load_rgba(src + i)) + predictor) & 255;
        store_rgba(dst + i, narrow(left));
        upper_left = up;
        i += 4;
    }
}

static bool unfilter(png_rows *rows, const uint8_t *raw) {
    if (rows->remaining == 0 || raw[0] > 4) return false;
    unsigned filter = raw[0];
    /* Input is a complete validated row in inflate scratch. Destination
       is the next output row, disjoint from scratch and the prior row. */
    const uint8_t *src = raw + 1;
    uint8_t *dst = rows->next;
    const uint8_t *above = rows->above;
    const size_t size = rows->stride;
    const size_t channels = 4;

    if (!above && filter == 2) filter = 0;
    if (!above && filter == 4) filter = 1;
    switch (filter) {
        case 0:
            memcpy(dst, src, size);
            break;
        case 1: {
            rgba8 left = {0};
            size_t i = 0;
            for (; size - i >= 16; i += 16) left = add_sub_block(dst + i, src + i, left);
            for (; i < size; i += channels) {
                left += load_rgba(src + i);
                store_rgba(dst + i, left);
            }
            break;
        }
        case 2: {
            size_t i = 0;
            for (; size - i >= sizeof(rgba_block); i += sizeof(rgba_block)) {
                const rgba_block sum = load_block(src + i) + load_block(above + i);
                memcpy(dst + i, &sum, sizeof(sum));
            }
            for (; i < size; ++i) dst[i] = (uint8_t)(src[i] + above[i]);
            break;
        }
        case 3: {
            const uint8_t zero[sizeof(rgba8)] = {0};
            const uint8_t *up = above ? above : zero;
            const size_t step = above ? sizeof(rgba8) : 0;
            rgba8 left = {0};
            for (size_t i = 0; i < size; i += sizeof(rgba8)) {
                const rgba16 predictor = (widen(left) + widen(load_rgba(up))) >> 1;
                left = load_rgba(src + i) + narrow(predictor);
                store_rgba(dst + i, left);
                up += step;
            }
            break;
        }
        case 4:
            unfilter_paeth(dst, src, above, size);
            break;
    }
#if UIDIFF_RGB8_STREAM
    if (rows->expanded) {
        const rgba_block alpha = {0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255};
        size_t i = 0;
        for (; size - i >= sizeof(alpha); i += sizeof(alpha)) {
            const rgba_block opaque = load_block(dst + i) | alpha;
            memcpy(dst + i, &opaque, sizeof(opaque));
        }
        for (i += 3; i < size; i += sizeof(rgba8)) dst[i] = 255;
    }
#endif
    rows->above = dst;
    rows->next += size;
    --rows->remaining;
    return true;
}

#if UIDIFF_RGB8_STREAM
/* Insert a spare alpha byte so both profiles share the four-channel filters.
   A PNG predictor never combines channels, so only RGB is retained. */
static const uint8_t *expand_rgb(png_rows *rows, const uint8_t *raw) {
    if (!rows->expanded) return raw;
    if (raw[0] > 4) return raw; /* unfilter reads only the invalid filter byte. */
    const size_t pixels = rows->stride / sizeof(rgba8);
    const uint8_t *src = raw + 1;
    uint8_t *dst = rows->expanded + 1;
    const rgba_block zeros = {0};
    size_t pixel = 0;
    for (; pixels - pixel >= 6; pixel += 4, src += 12, dst += sizeof(rgba_block)) {
        const rgba_block rgb = load_block(src);
        const rgba_block rgba = __builtin_shufflevector(rgb, zeros, 0, 1, 2, 16, 3, 4, 5, 16, 6, 7, 8, 16, 9, 10, 11, 16);
        memcpy(dst, &rgba, sizeof(rgba));
    }
    for (; pixel < pixels; ++pixel, src += 3, dst += sizeof(rgba8)) {
        const rgba8 value = {src[0], src[1], src[2], 0};
        store_rgba(dst, value);
    }
    rows->expanded[0] = raw[0];
    return rows->expanded;
}
#else
#define expand_rgb(rows, raw) (raw)
#endif

static bool consume_rows(png_rows *rows, const uint8_t *raw, size_t len) {
#if UIDIFF_RGB8_STREAM
    const size_t row_size = rows->input_stride + 1;
#else
    const size_t row_size = rows->stride + 1;
#endif
    while (len != 0) {
        if (rows->used == 0 && len >= row_size) {
            if (!unfilter(rows, expand_rgb(rows, raw))) return false;
            raw += row_size;
            len -= row_size;
            continue;
        }
        const size_t take = len < row_size - rows->used ? len : row_size - rows->used;
        memcpy(rows->partial + rows->used, raw, take);
        rows->used += take;
        if (rows->used == row_size) {
            if (!unfilter(rows, expand_rgb(rows, rows->partial))) return false;
            rows->used = 0;
        }
        raw += take;
        len -= take;
    }
    return true;
}

static void *zalloc(void *opaque, unsigned int items, unsigned int size) {
    (void)opaque;
    if (size != 0 && items > SIZE_MAX / size) return NULL;
    return uidiff_stbi_malloc((size_t)items * size);
}

static void zfree(void *opaque, void *block) {
    (void)opaque;
    uidiff_stbi_free(block);
}

static bool inflate_rows(const uint8_t *data, size_t first, size_t end,
                         uint8_t *chunk, png_rows *rows, bool *alloc_failed) {
    // Match stb's checksum policy. Leave unusual chunk splits to stb,
    // and validate the zlib header before passing the raw payload to zlib-ng.
    if (be32(data + first) < 2) return false;
    const uint8_t cmf = data[first + 8];
    const uint8_t flg = data[first + 9];
    if ((cmf & 15) != 8 || (cmf >> 4) > 7 || (flg & 32) != 0 ||
        ((unsigned)cmf * 256 + flg) % 31 != 0) return false;
    zng_stream z;
    memset(&z, 0, sizeof(z));
    z.zalloc = zalloc;
    z.zfree = zfree;
    const int window = -(int)((cmf >> 4) + 8);
    const int init = zng_inflateInit2(&z, window);
    if (init != Z_OK) {
        *alloc_failed = init == Z_MEM_ERROR;
        return false;
    }
    bool ok = false;
    for (size_t pos = first; pos < end;) {
        size_t available = be32(data + pos);
        const uint8_t *src = data + pos + 8;
        const size_t header = pos == first ? 2 : 0;
        pos += available + 12;
        const size_t trailer = pos == end ? 4 : 0;
        if (available < header + trailer) goto done;
        z.next_in = src + header;
        z.avail_in = (uint32_t)(available - header - trailer);
        for (;;) {
            z.next_out = chunk;
            z.avail_out = INFLATE_CHUNK_BYTES;
            const int status = zng_inflate(&z, Z_NO_FLUSH);
            if (status == Z_MEM_ERROR) *alloc_failed = true;
            if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) goto done;
            if (!consume_rows(rows, chunk, INFLATE_CHUNK_BYTES - z.avail_out)) goto done;
            if (status == Z_STREAM_END) {
                ok = rows->remaining == 0 && rows->used == 0;
                goto done;
            }
            if (z.avail_out != 0 && z.avail_in == 0) break;
            if (status == Z_BUF_ERROR) goto done;
        }
    }
done:
    return zng_inflateEnd(&z) == Z_OK && ok;
}

int uidiff_png_load(const uint8_t *data, size_t len, uint32_t width,
                    uint32_t height, uint8_t **result) {
    size_t first, end;
    if (!idat_range(data, len, &first, &end) || width != be32(data + 16) ||
        height != be32(data + 20) || width == 0 || height == 0 ||
        width > (SIZE_MAX - INFLATE_CHUNK_BYTES - 2) / 8 ||
        height > SIZE_MAX / (4 * (size_t)width)) return UIDIFF_PNG_FALLBACK;

    const size_t stride = 4 * (size_t)width;
    uint8_t *pixels = uidiff_stbi_malloc(stride * height);
    if (!pixels) return UIDIFF_PNG_ALLOC_FAILED;
#if UIDIFF_RGB8_STREAM
    const bool rgb = data[25] == 2;
    const size_t input_stride = rgb ? 3 * (size_t)width : stride;
    const size_t extra = rgb ? stride + 1 : 0;
    uint8_t *scratch = uidiff_stbi_malloc(INFLATE_CHUNK_BYTES + input_stride + 1 + extra);
#else
    uint8_t *scratch = uidiff_stbi_malloc(INFLATE_CHUNK_BYTES + stride + 1);
#endif
    if (!scratch) {
        uidiff_stbi_free(pixels);
        return UIDIFF_PNG_ALLOC_FAILED;
    }
    png_rows rows = {pixels, scratch + INFLATE_CHUNK_BYTES, stride,
#if UIDIFF_RGB8_STREAM
                     input_stride, rgb ? scratch + INFLATE_CHUNK_BYTES + input_stride + 1 : NULL,
#endif
                     0, height, NULL};
    bool alloc_failed = false;
    const bool ok = inflate_rows(data, first, end, scratch, &rows, &alloc_failed);
    uidiff_stbi_free(scratch);
    if (!ok) {
        uidiff_stbi_free(pixels);
        return alloc_failed ? UIDIFF_PNG_ALLOC_FAILED : UIDIFF_PNG_FALLBACK;
    }
    *result = pixels;
    return UIDIFF_PNG_DECODED;
}
