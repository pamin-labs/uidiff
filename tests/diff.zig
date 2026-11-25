//! Cross-module regression scenarios for the comparison pipeline.

test {
    _ = @import("diff/grouping.zig");
    _ = @import("diff/pixel_evidence.zig");
    _ = @import("diff/viewport.zig");
    _ = @import("diff/row_motion.zig");
    _ = @import("diff/column_motion.zig");
    _ = @import("diff/moved_edits.zig");
    _ = @import("diff/overlays.zig");
    _ = @import("diff/reflow.zig");
}
