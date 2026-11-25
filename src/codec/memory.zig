//! Charges C codec allocations to the active decode and remembers their owner.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Malformed input or an allocation refused by the decoder budget.
pub const Error = Allocator.Error || error{ InvalidImage, ImageTooLarge };

/// Prefix of every block handed to a decoder: the allocator that owns it and its
/// length, so free and realloc need no context from the C side.
const Prefix = extern struct {
    context: *anyopaque,
    vtable: *const Allocator.VTable,
    len: usize,
    base: [*]u8,
    payload: [0]u8 align(16),

    fn owner(self: Prefix) Allocator {
        return .{ .ptr = self.context, .vtable = self.vtable };
    }
};

/// Why an allocation in the running call was refused.
const Refusal = enum { none, exhausted, over_budget };

const block_alignment = Alignment.of(Prefix);
const prefix_size = @sizeOf(Prefix);
comptime {
    std.debug.assert(@offsetOf(Prefix, "payload") == prefix_size);
}
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

/// Allocates an unfilled block charged to the active codec budget.
pub fn allocBytes(len: usize) ?[]u8 {
    const allocator = current orelse return null;
    if (len > remaining or len > std.math.maxInt(usize) - prefix_size) {
        _ = refuse(.over_budget);
        return null;
    }
    const bytes = allocBlock(allocator, len) orelse {
        _ = refuse(.exhausted);
        return null;
    };
    remaining -= len;
    return bytes;
}

/// Allocates an unfilled ABI block outside the decode budget.
pub fn allocBlock(allocator: Allocator, len: usize) ?[]u8 {
    const total = std.math.add(usize, prefix_size, len) catch return null;
    const base = allocator.rawAlloc(total, block_alignment, @returnAddress()) orelse return null;
    const block = base[0..total];
    initPrefix(block, allocator, len);
    return block[prefix_size..];
}

/// Recovers the bounded payload of a pointer returned by the codec hooks.
pub fn allocatedBytes(data: *anyopaque) []u8 {
    return blockOf(data).block[prefix_size..];
}

/// Releases a block created by allocBlock outside the decode budget.
pub fn freeBlock(data: ?*anyopaque) void {
    const found = blockOf(data orelse return);
    found.prefix.owner().rawFree(found.block, block_alignment, @returnAddress());
}

/// Gives C codecs the payload address while keeping its length in the prefix.
pub export fn uidiff_codec_malloc(len: usize) callconv(.c) ?*anyopaque {
    const bytes = allocBytes(len) orelse return null;
    return bytes.ptr;
}

export fn uidiff_codec_realloc(data: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
    const old = data orelse return uidiff_codec_malloc(len);
    const found = blockOf(old);
    if (len > found.prefix.len and len - found.prefix.len > remaining) return refuse(.over_budget);
    const total = std.math.add(usize, prefix_size, len) catch return refuse(.over_budget);
    const allocator = found.prefix.owner();
    // Grows in place when the allocator can, as libc realloc would.
    const block = allocator.rawRemap(found.block, block_alignment, total, @returnAddress()) orelse moved: {
        const fresh = allocator.rawAlloc(total, block_alignment, @returnAddress()) orelse return refuse(.exhausted);
        const kept = @min(len, found.prefix.len);
        @memcpy(fresh[0..total][prefix_size..][0..kept], found.block[prefix_size..][0..kept]);
        allocator.rawFree(found.block, block_alignment, @returnAddress());
        break :moved fresh;
    };
    remaining = if (len > found.prefix.len) remaining - (len - found.prefix.len) else remaining +| (found.prefix.len - len);
    const allocation = block[0..total];
    initPrefix(allocation, allocator, len);
    return allocation[prefix_size..].ptr;
}

/// Releases a block allocated by the codec budget.
pub export fn uidiff_codec_free(data: ?*anyopaque) callconv(.c) void {
    const found = blockOf(data orelse return);
    // A buffer freed after its call, such as returned pixels, credits a budget
    // that the next call resets.
    remaining +|= found.prefix.len;
    found.prefix.owner().rawFree(found.block, block_alignment, @returnAddress());
}

// libwebp uses the same hooks for decoder scratch and fixture encoder
// allocations. Both callers install a budget before invoking the codec.
export fn uidiff_codec_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const len = std.math.mul(usize, count, size) catch return refuse(.over_budget);
    const block = allocBytes(len) orelse return null;
    @memset(block, 0);
    return block.ptr;
}

fn refuse(reason: Refusal) ?*anyopaque {
    if (refusal == .none) refusal = reason;
    return null;
}

fn initPrefix(block: []u8, allocator: Allocator, len: usize) void {
    std.mem.bytesAsValue(Prefix, block[0..prefix_size]).* = .{
        .context = allocator.ptr,
        .vtable = allocator.vtable,
        .len = len,
        .base = block.ptr,
        .payload = .{},
    };
}

fn blockOf(data: *anyopaque) struct { prefix: Prefix, block: []u8 } {
    // C returns an address supplied by allocBlock. Its aligned payload is
    // the trailing member of the prefix, which records the full extent.
    const payload: *align(@alignOf(Prefix)) [0]u8 = @ptrCast(@alignCast(data));
    const header: *Prefix = @fieldParentPtr("payload", payload);
    const prefix = header.*;
    return .{ .prefix = prefix, .block = prefix.base[0 .. prefix_size + prefix.len] };
}

test "codec blocks retain their owning allocator and restore the decode budget" {
    // Refusing every remap makes realloc move the block to a fresh one.
    var moving: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    begin(moving.allocator(), 64);
    defer current = null;
    const block = allocBytes(3) orelse return error.OutOfMemory;
    @memcpy(block, "abc");
    const grown = allocatedBytes(uidiff_codec_realloc(block.ptr, 64) orelse return error.OutOfMemory);
    try std.testing.expectEqualStrings("abc", grown[0..3]);
    try std.testing.expectEqual(@as(usize, 0), remaining);
    try std.testing.expectEqual(@as(?*anyopaque, null), uidiff_codec_realloc(grown.ptr, 65));
    try std.testing.expectEqual(error.ImageTooLarge, failure());
    uidiff_codec_free(grown.ptr);
    uidiff_codec_free(null);
    try std.testing.expectEqual(@as(usize, 64), remaining);
}

test "encoder ABI blocks preserve an active decoder budget" {
    const allocator = std.testing.allocator;
    begin(allocator, 3);
    defer end();
    const scratch = allocBlock(allocator, 64) orelse return error.OutOfMemory;
    defer freeBlock(scratch.ptr);
    const decoded = allocBytes(3) orelse return error.OutOfMemory;
    defer uidiff_codec_free(decoded.ptr);
    try std.testing.expectEqual(scratch.len, allocatedBytes(scratch.ptr).len);
    try std.testing.expectEqual(@as(usize, 0), remaining);
    try std.testing.expect(allocBytes(1) == null);
    try std.testing.expectEqual(error.ImageTooLarge, failure());
}

test {
    std.testing.refAllDecls(@This());
}
