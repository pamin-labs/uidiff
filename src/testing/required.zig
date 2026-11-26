//! Verifies that a required build filter selected a test.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("required_test_options");

/// Fails if the required filter selected only the guard itself.
pub fn check() error{NoSelectedTests}!void {
    const filter = options.filter;
    if (filter.len == 0) return;
    for (builtin.test_functions) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".test.required test selection")) continue;
        if (std.mem.indexOf(u8, entry.name, filter) != null) return;
    }
    return error.NoSelectedTests;
}
