//! Regression scenarios for the comparison sheet.

// Keep the public module's C allocation hooks when the scenario filter is empty.
comptime {
    _ = @import("uidiff");
}

test {
    _ = @import("sheet/badges.zig");
}
