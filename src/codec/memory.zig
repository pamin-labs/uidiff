//! Charges C codec allocations to the active decode and remembers their owner.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Malformed input or an allocation refused by the decoder budget.
pub const Error = Allocator.Error || error{ InvalidImage, ImageTooLarge };

/// Prefix of every block handed to a decoder: the allocator that owns it and its
/// length, so free and realloc need no context from the C side.
const Prefix = struct { allocator: Allocator, len: usize };

/// Why an allocation in the running call was refused.
const Refusal = enum { none, exhausted, over_budget };

const block_alignment: Alignment = .@"16";
const prefix_size = std.mem.alignForward(usize, @sizeOf(Prefix), block_alignment.toByteUnits());
/// The allocator in use during a decoder call on this thread. The allocation
/// hooks take no context, so the binding sets it
/// around each call and clears it after; free and realloc read the block's own
/// prefix instead.
threadlocal var current: ?Allocator = null;
/// Bytes the running call may still allocate.
threadlocal var remaining: usize = 0;
/// Set when an allocation for the running call was refused, so a null result
/// from a decoder is reported as that refusal rather than as a malformed image.
threadlocal var refusal: Refusal = .none;

/// Installs the allocator and byte budget for a decoder call on this thread.
pub fn begin(allocator: Allocator, limit: usize) void {
    current = allocator;
    remaining = limit;
    refusal = .none;
}

/// Clears the active allocator after a decoder call.
pub fn end() void {
    current = null;
}

/// Maps the last decoder refusal to the library error.
pub fn failure() Error {
    return switch (refusal) {
        .none => error.InvalidImage,
        .exhausted => error.OutOfMemory,
        .over_budget => error.ImageTooLarge,
    };
}

// stb's allocation hooks, which stb.c names in STBI_MALLOC, STBI_REALLOC and
// STBI_FREE.
export fn uidiff_stbi_malloc(len: usize) callconv(.c) ?*anyopaque {
    return allocate(current orelse return null, len);
}

export fn uidiff_stbi_realloc(data: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
    const old = data orelse return uidiff_stbi_malloc(len);
    const found = blockOf(old);
    if (len > found.prefix.len and len - found.prefix.len > remaining) return refuse(.over_budget);
    const total = std.math.add(usize, prefix_size, len) catch return refuse(.over_budget);
    const allocator = found.prefix.allocator;
    // Grows in place when the allocator can, as libc realloc would.
    const block = allocator.rawRemap(found.block, block_alignment, total, @returnAddress()) orelse moved: {
        const fresh = allocator.rawAlloc(total, block_alignment, @returnAddress()) orelse return refuse(.exhausted);
        const kept = @min(len, found.prefix.len);
        @memcpy(fresh[prefix_size..][0..kept], found.block[prefix_size..][0..kept]);
        allocator.rawFree(found.block, block_alignment, @returnAddress());
        break :moved fresh;
    };
    remaining = if (len > found.prefix.len) remaining - (len - found.prefix.len) else remaining +| (found.prefix.len - len);
    prefixOf(block).* = .{ .allocator = allocator, .len = len };
    return block + prefix_size;
}

export fn uidiff_stbi_free(data: ?*anyopaque) callconv(.c) void {
    const found = blockOf(data orelse return);
    // A buffer freed after its call, such as returned pixels, credits a budget
    // that the next call resets.
    remaining +|= found.prefix.len;
    found.prefix.allocator.rawFree(found.block, block_alignment, @returnAddress());
}

// libwebp uses the same hooks for decoder scratch and fixture encoder
// allocations. Both callers install a budget before invoking the codec.
export fn uidiff_webp_malloc(len: usize) callconv(.c) ?*anyopaque {
    return allocate(current orelse return null, len);
}

export fn uidiff_webp_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const len = std.math.mul(usize, count, size) catch return refuse(.over_budget);
    const block: [*]u8 = @ptrCast(uidiff_webp_malloc(len) orelse return null);
    @memset(block[0..len], 0);
    return block;
}

export fn uidiff_webp_free(data: ?*anyopaque) callconv(.c) void {
    uidiff_stbi_free(data);
}

fn refuse(reason: Refusal) ?*anyopaque {
    if (refusal == .none) refusal = reason;
    return null;
}

// The hooks use the allocator's raw calls, which skip the safe mode's fill of
// new and freed memory with 0xaa. That is a safety opt-out: a read of memory
// stb never wrote would see stale bytes instead of 0xaa. stb writes each
// output byte before reading it back, the checked test and fuzz builds run
// the decoders under UBSan, and the fill touched every page of a buffer a
// malformed image never reaches. Measured with `zig build bench`, safe mode,
// median of 7 rotated runs on an Apple M-series laptop, fill against raw:
// decode 1.544 -> 1.263 ms phone-light (-18%) and 4.049 -> 3.244 ms
// desktop-light (-20%), with peak RSS unchanged. The test "blocks handed to
// stb are freed through the allocator that made them" runs the raw paths
// under the leak-checking allocator.
fn allocate(allocator: Allocator, len: usize) ?*anyopaque {
    if (current != null and len > remaining) return refuse(.over_budget);
    const total = std.math.add(usize, prefix_size, len) catch return refuse(.over_budget);
    const block = allocator.rawAlloc(total, block_alignment, @returnAddress()) orelse return refuse(.exhausted);
    if (current != null) remaining -= len;
    prefixOf(block).* = .{ .allocator = allocator, .len = len };
    return block + prefix_size;
}

fn prefixOf(block: [*]u8) *align(1) Prefix {
    return std.mem.bytesAsValue(Prefix, block[0..@sizeOf(Prefix)]);
}

fn blockOf(data: *anyopaque) struct { prefix: Prefix, block: []u8 } {
    // Every pointer a codec passes back came from allocate, prefix_size bytes into a block.
    const start = @as([*]u8, @ptrCast(data)) - prefix_size;
    const prefix = prefixOf(start).*;
    return .{ .prefix = prefix, .block = start[0 .. prefix_size + prefix.len] };
}

test "blocks handed to stb are freed through the allocator that made them" {
    // Refusing every remap makes realloc move the block to a fresh one.
    var moving: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    begin(moving.allocator(), 64);
    defer current = null;
    const block: [*]u8 = @ptrCast(uidiff_stbi_malloc(3) orelse return error.OutOfMemory);
    @memcpy(block[0..3], "abc");
    const grown: [*]u8 = @ptrCast(uidiff_stbi_realloc(block, 64) orelse return error.OutOfMemory);
    try std.testing.expectEqualStrings("abc", grown[0..3]);
    try std.testing.expectEqual(@as(usize, 0), remaining);
    try std.testing.expectEqual(@as(?*anyopaque, null), uidiff_stbi_realloc(grown, 65));
    try std.testing.expectEqual(error.ImageTooLarge, failure());
    uidiff_stbi_free(grown);
    uidiff_stbi_free(null);
    try std.testing.expectEqual(@as(usize, 64), remaining);
}

test {
    std.testing.refAllDecls(@This());
}
