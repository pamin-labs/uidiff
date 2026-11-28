//! Allocates storage that its owner will fully initialize.
const std = @import("std");

/// Allocates storage for non-zero-sized elements that the caller initializes.
pub fn allocUnfilled(comptime T: type, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]T {
    if (@sizeOf(T) == 0) @compileError("unfilled storage requires non-zero-sized elements");
    const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.OutOfMemory;
    if (size == 0) return &.{};
    const ptr = allocator.rawAlloc(size, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    // rawAlloc guarantees this alignment for the whole byte span.
    const aligned: [*]align(@alignOf(T)) u8 = @alignCast(ptr);
    return std.mem.bytesAsSlice(T, aligned[0..size]);
}

/// Returns count elements of unfilled storage, replacing a shorter block
/// without copying: callers write every element before reading it.
pub fn reserveUnfilled(comptime T: type, allocator: std.mem.Allocator, storage: *[]T, count: usize) std.mem.Allocator.Error![]T {
    if (storage.len < count) {
        freeUnfilled(T, allocator, storage.*);
        storage.* = &.{};
        storage.* = try allocUnfilled(T, allocator, count);
    }
    return storage.*[0..count];
}

/// Releases storage obtained from allocUnfilled without refilling it.
pub fn freeUnfilled(comptime T: type, allocator: std.mem.Allocator, data: []const T) void {
    if (data.len == 0) return;
    allocator.rawFree(@constCast(std.mem.sliceAsBytes(data)), .of(T), @returnAddress());
}

test "unfilled storage handles empty slices and preserves element alignment" {
    const allocator = std.testing.allocator;
    const empty = try allocUnfilled(u32, allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    freeUnfilled(u32, allocator, empty);
    const words = try allocUnfilled(u32, allocator, 2);
    defer freeUnfilled(u32, allocator, words);
    words[0] = 37;
    words[1] = 42;
    try std.testing.expectEqualSlices(u32, &.{ 37, 42 }, words);
}
