//! The batch's allocator: keeps freed large blocks for the next comparison,
//! so one batch process stays near the memory of a single run instead of
//! growing as each pair's images and scratch land in fresh pages.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Wraps backing; blocks below `min_bytes` go to it unchanged. Thread safe:
/// the decode worker and the sheet encoder allocate beside the caller.
pub const LargeBlocks = struct {
    io: Io,
    backing: Allocator,
    /// Guards lent and idle.
    mutex: Io.Mutex = .init,
    /// Blocks handed out, found again by address on free.
    lent: [slots]Block = @splat(.{}),
    /// Freed blocks kept for reuse.
    idle: [slots]Block = @splat(.{}),

    const Block = struct { ptr: ?[*]u8 = null, capacity: usize = 0 };

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// Releases the idle blocks. Every lent block must have been freed.
    pub fn deinit(self: *LargeBlocks) void {
        for (self.idle) |block| if (block.ptr) |ptr| self.backing.rawFree(ptr[0..block.capacity], max_alignment, @returnAddress());
        self.* = undefined;
    }

    /// Returns the allocator over self.
    pub fn allocator(self: *LargeBlocks) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn lock(context: *anyopaque) *LargeBlocks {
        // allocator installs self as the vtable context.
        const self: *LargeBlocks = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        return self;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        if (len < min_bytes or alignment.order(max_alignment) == .gt) return self.backing.rawAlloc(len, alignment, ra);
        const slot = find(&self.lent, null) orelse return self.backing.rawAlloc(len, alignment, ra);
        var fit: ?*Block = null;
        var smallest: ?*Block = null;
        for (&self.idle) |*block| {
            if (block.ptr == null) continue;
            if (block.capacity >= len and (fit == null or block.capacity < fit.?.capacity)) fit = block;
            if (smallest == null or block.capacity < smallest.?.capacity) smallest = block;
        }
        if (fit) |block| {
            slot.* = block.*;
            block.* = .{};
            return slot.ptr;
        }
        // ponytail: dropping the smallest idle block on a miss keeps the
        // retained count at most the most blocks one pair held at once; a byte
        // cap would bound mixed sizes more tightly if a caller ever needs it.
        if (smallest) |block| {
            self.backing.rawFree(block.ptr.?[0..block.capacity], max_alignment, ra);
            block.* = .{};
        }
        slot.* = .{ .ptr = self.backing.rawAlloc(len, max_alignment, ra) orelse return null, .capacity = len };
        return slot.ptr;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        if (find(&self.lent, memory.ptr)) |block| return len <= block.capacity;
        return self.backing.rawResize(memory, alignment, len, ra);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        if (find(&self.lent, memory.ptr)) |block| return if (len <= block.capacity) memory.ptr else null;
        return self.backing.rawRemap(memory, alignment, len, ra);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self = lock(context);
        defer self.mutex.unlock(self.io);
        const block = find(&self.lent, memory.ptr) orelse return self.backing.rawFree(memory, alignment, ra);
        const kept = block.*;
        block.* = .{};
        // Kept and lent blocks together never exceed slots: alloc adds a block
        // only when none is idle, so a free idle slot exists here.
        find(&self.idle, null).?.* = kept;
    }

    fn find(table: []Block, ptr: ?[*]u8) ?*Block {
        for (table) |*block| if (block.ptr == ptr) return block;
        return null;
    }
};

/// Large blocks tracked at once; requests beyond them pass to backing.
const slots = 32;
/// Smaller blocks are cheap to get from backing again.
const min_bytes = 256 * 1024;
/// Every kept block is allocated at this alignment so any request up to it fits.
const max_alignment: Alignment = .@"16";

test "a freed large block serves the next request and small ones pass through" {
    var blocks: LargeBlocks = .{ .io = std.testing.io, .backing = std.testing.allocator };
    defer blocks.deinit();
    const allocator = blocks.allocator();
    const first = try allocator.alloc(u8, min_bytes * 2);
    const address = first.ptr;
    allocator.free(first);
    const second = try allocator.alloc(u8, min_bytes + 1);
    try std.testing.expectEqual(address, second.ptr);
    try std.testing.expect(allocator.resize(second, min_bytes * 2));
    try std.testing.expect(!allocator.resize(second, min_bytes * 2 + 1));
    const larger = try allocator.alloc(u8, min_bytes * 4);
    allocator.free(larger);
    allocator.free(second.ptr[0 .. min_bytes * 2]);
    // std.testing.allocator reports a leak if a small block skipped backing.
    const small = try allocator.alloc(u8, 64);
    allocator.free(small);
}

test {
    std.testing.refAllDecls(@This());
}
