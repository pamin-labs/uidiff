//! The CLI's allocator: large blocks get mappings of their own, which return
//! their pages when freed instead of fragmenting malloc's regions. On Linux
//! they are huge-page-aligned anonymous mappings advised for transparent huge
//! pages, which cuts the page faults of decoded pixels and comparison buffers.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Wraps backing; blocks below `mapped_bytes` go to it unchanged.
pub const Mapped = struct {
    const linux = std.os.linux;

    backing: Allocator,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// Returns the allocator over self.
    pub fn allocator(self: *Mapped) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Mapped = @ptrCast(@alignCast(context));
        if (len < mapped_bytes) return self.backing.rawAlloc(len, alignment, ra);
        if (builtin.os.tag != .linux) return std.heap.page_allocator.rawAlloc(len, alignment, ra);
        // An aligned start needs one huge page of slack, trimmed off below.
        // A len this close to the address space limit fails in mmap anyway.
        const mapped = std.mem.alignForward(usize, len, std.heap.pageSize());
        const raw = linux.mmap(null, mapped + huge_page_bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        // musl and glibc malloc map blocks this large too, so falling back to
        // backing would fail the same way.
        if (linux.errno(raw) != .SUCCESS) return null;
        const start = std.mem.alignForward(usize, raw, huge_page_bytes);
        if (start != raw) _ = linux.munmap(@ptrFromInt(raw), start - raw);
        const tail = raw + mapped + huge_page_bytes - (start + mapped);
        if (tail != 0) _ = linux.munmap(@ptrFromInt(start + mapped), tail);
        // Only whole huge pages are advised, so a short tail stays on small
        // pages instead of faulting in another huge page. Advice only: a kernel
        // without transparent huge pages keeps small pages throughout.
        _ = linux.madvise(@ptrFromInt(start), std.mem.alignBackward(usize, len, huge_page_bytes), linux.MADV.HUGEPAGE);
        return @ptrFromInt(start);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self: *Mapped = @ptrCast(@alignCast(context));
        if (memory.len < mapped_bytes) return len < mapped_bytes and self.backing.rawResize(memory, alignment, len, ra);
        return false;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Mapped = @ptrCast(@alignCast(context));
        if (memory.len < mapped_bytes and len < mapped_bytes) return self.backing.rawRemap(memory, alignment, len, ra);
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *Mapped = @ptrCast(@alignCast(context));
        if (memory.len < mapped_bytes) return self.backing.rawFree(memory, alignment, ra);
        if (builtin.os.tag != .linux) return std.heap.page_allocator.rawFree(memory, alignment, ra);
        _ = linux.munmap(memory.ptr, std.mem.alignForward(usize, memory.len, std.heap.pageSize()));
    }
};

const huge_page_bytes = 2 * 1024 * 1024;
/// Blocks at least this large get their own mapping. Elsewhere than Linux,
/// 1 MiB measured lowest: from 256 KiB, a single phone sheet peaked 0.3 MiB
/// higher than with malloc.
const mapped_bytes = if (builtin.os.tag == .linux) huge_page_bytes else 1024 * 1024;

test "large blocks get their own mapping and small blocks use backing" {
    var pages: Mapped = .{ .backing = std.testing.allocator };
    const allocator = pages.allocator();
    const large = try allocator.alloc(u8, huge_page_bytes + 32);
    @memset(large, 0x5a);
    if (builtin.os.tag == .linux) try std.testing.expect(std.mem.isAligned(@intFromPtr(large.ptr), huge_page_bytes));
    const grown = try allocator.realloc(large, 2 * huge_page_bytes);
    try std.testing.expectEqual(@as(u8, 0x5a), grown[huge_page_bytes + 31]);
    allocator.free(grown);
    // std.testing.allocator reports a leak if a small block skipped backing.
    const small = try allocator.alloc(u8, 64);
    allocator.free(small);
}
