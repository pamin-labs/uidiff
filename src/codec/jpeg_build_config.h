/* Disable optional libjpeg modes that the uidiff bridge never requests. */
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
