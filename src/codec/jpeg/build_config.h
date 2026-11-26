/* The generated header shims select public or internal libjpeg config. */
#if defined(UIDIFF_JPEG_PUBLIC_CONFIG)
#ifndef UIDIFF_JCONFIG_H
#define UIDIFF_JCONFIG_H
#define JPEG_LIB_VERSION 62
#define MEM_SRCDST_SUPPORTED 1
#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE 8
#endif
#ifdef _WIN32
#ifndef __RPCNDR_H__
typedef unsigned char boolean;
#endif
#define HAVE_BOOLEAN
#if !defined(_BASETSD_H_) && !defined(_BASETSD_H)
typedef short INT16;
typedef signed int INT32;
#endif
#define XMD_H
#endif
#endif
#elif defined(UIDIFF_JPEG_INTERNAL_CONFIG)
#ifndef UIDIFF_JCONFIGINT_H
#define UIDIFF_JCONFIGINT_H
#define BUILD "uidiff"
#define HIDDEN __attribute__((visibility("hidden")))
#define INLINE __inline__
#define THREAD_LOCAL __thread
#define PACKAGE_NAME "libjpeg-turbo"
#define VERSION UIDIFF_JPEG_VERSION
#define SIZEOF_SIZE_T __SIZEOF_SIZE_T__
#if __SIZEOF_LONG__ == __SIZEOF_SIZE_T__
#define HAVE_BUILTIN_CTZL
#endif
#define FALLTHROUGH __attribute__((fallthrough));
#ifdef UIDIFF_JPEG_NEON
#define SIMD_ARCHITECTURE ARM64
#define WITH_SIMD 1
#else
#define SIMD_ARCHITECTURE NONE
#endif
#endif
#else
/* Force-included by the trimmed decoder, which never requests these modes. */
#define JPEG_INTERNALS
#include "jinclude.h"
#include "jpeglib.h"

#undef DCT_IFAST_SUPPORTED
#undef DCT_FLOAT_SUPPORTED
#undef D_LOSSLESS_SUPPORTED
#undef SAVE_MARKERS_SUPPORTED
#undef IDCT_SCALING_SUPPORTED
#undef UPSAMPLE_MERGING_SUPPORTED
#undef QUANT_1PASS_SUPPORTED
#undef QUANT_2PASS_SUPPORTED
#endif
