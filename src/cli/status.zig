//! The command's exit statuses, shared by the single run and the batch.
const std = @import("std");
const uidiff = @import("uidiff");

/// A comparison's status: the process exit status of a single run, and each
/// batch line's `status` field.
pub const Status = enum(u8) {
    unchanged = 0,
    changed = 1,
    failed = 2,

    /// Whether the comparison found change regions.
    pub fn of(result: uidiff.Comparison) Status {
        return if (result.regions.len == 0) .unchanged else .changed;
    }

    /// The more severe of two statuses, as a batch exits with.
    pub fn worst(self: Status, other: Status) Status {
        return if (@backingInt(other) > @backingInt(self)) other else self;
    }
};

test "the worst status wins" {
    try std.testing.expectEqual(Status.changed, Status.unchanged.worst(.changed));
    try std.testing.expectEqual(Status.failed, Status.failed.worst(.changed));
}

test {
    std.testing.refAllDecls(@This());
}
