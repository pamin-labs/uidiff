//! Vector widths for PNG byte kernels.
const std = @import("std");

/// Fixed block width for RGB packing, expansion, and the unfilter carry shuffle.
pub const scanline_bytes = 16;
/// Native width for independent encoder byte operations.
pub const byte_lanes = std.simd.suggestVectorLength(u8) orelse scanline_bytes;
