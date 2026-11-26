//! Cross-module regression scenarios for the comparison pipeline.

// Keep the public module's C allocation hooks when the scenario filter is empty.
comptime {
    _ = @import("uidiff");
}

test {
    _ = @import("compare/grouping.zig");
    _ = @import("compare/pixel_evidence.zig");
    _ = @import("compare/viewport.zig");
    _ = @import("compare/row_motion.zig");
    _ = @import("compare/column_motion.zig");
    _ = @import("compare/moved_edits.zig");
    _ = @import("compare/overlays.zig");
    _ = @import("compare/reflow.zig");
    _ = @import("compare/logical.zig");
    _ = @import("compare/moves.zig");
}
