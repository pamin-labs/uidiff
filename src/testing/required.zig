//! Fails a filtered gate runner that selected none of the tests it names.
const std = @import("std");
const builtin = @import("builtin");
const filter = @import("required_test_options").filter;

test "required test selection" {
    if (filter.len == 0) return;
    for (builtin.test_functions) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".test.required test selection")) continue;
        if (std.mem.indexOf(u8, entry.name, filter) != null) return;
    }
    return error.NoSelectedTests;
}
