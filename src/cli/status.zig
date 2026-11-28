//! The command's exit statuses.
const std = @import("std");
const uidiff = @import("uidiff");

/// A comparison's status, the process exit status of a run.
pub const Status = enum(u8) {
    unchanged = 0,
    changed = 1,
    failed = 2,

    /// Whether the comparison found change regions.
    pub fn of(result: uidiff.Comparison) Status {
        return if (result.regions.len == 0) .unchanged else .changed;
    }
};

test {
    std.testing.refAllDecls(@This());
}
