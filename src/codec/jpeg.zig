//! JPEG recognition and decoding through the bounded stb adapter.
const std = @import("std");
const stb = @import("stb.zig");

/// Probes dimensions before allocating the decoded image.
pub const probe = stb.probe;
/// Decodes the probed image and borrows the caller's allocator.
pub const decode = stb.loadLegacy;
/// Releases the decoded pixels through the matching backend.
pub const release = stb.release;

/// Recognizes the JPEG start-of-image marker.
pub fn matches(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, "\xff\xd8");
}

test {
    std.testing.refAllDecls(@This());
}
