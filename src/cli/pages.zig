//! The CLI's allocator: on Linux and macOS large blocks get mappings of their
//! own. On Linux they are huge-page-aligned anonymous mappings advised for
//! transparent huge pages, which cuts the page faults of decoded pixels and
//! comparison buffers. On macOS they come from the page allocator, which
//! returns their pages when freed instead of fragmenting malloc's regions.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Wraps backing; blocks below `mapped_bytes`, and every block where
/// `mapping` is none, go to it unchanged.
pub const Mapped = struct {
    const linux = std.os.linux;

    backing: Allocator,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// Returns the allocator over self.
    pub fn allocator(self: *Mapped) Allocator {
        if (mapping == .none) return self.backing;
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Mapped = @ptrCast(@alignCast(context));
        if (len < mapped_bytes) return self.backing.rawAlloc(len, alignment, ra);
        if (onPages(alignment)) return std.heap.page_allocator.rawAlloc(len, alignment, ra);
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
        if (onPages(alignment)) return std.heap.page_allocator.rawFree(memory, alignment, ra);
        _ = linux.munmap(memory.ptr, std.mem.alignForward(usize, memory.len, std.heap.pageSize()));
    }
};

/// A test's backing: counts the blocks of at least `mapped_bytes` that reach it.
const LargeCount = struct {
    backing: Allocator,
    large: usize = 0,

    fn allocator(self: *LargeCount) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *LargeCount = @ptrCast(@alignCast(context));
        if (len >= mapped_bytes) self.large += 1;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self: *LargeCount = @ptrCast(@alignCast(context));
        if (len >= mapped_bytes) self.large += 1;
        return self.backing.rawResize(memory, alignment, len, ra);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *LargeCount = @ptrCast(@alignCast(context));
        if (len >= mapped_bytes) self.large += 1;
        return self.backing.rawRemap(memory, alignment, len, ra);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *LargeCount = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ra);
    }
};

/// How large blocks are mapped on this OS. Only the measured OSes map them;
/// Windows and the rest leave every block to backing, whose heap maps large
/// blocks itself.
const mapping: enum { huge_pages, pages, none } = switch (builtin.os.tag) {
    .linux => .huge_pages,
    .macos => .pages,
    else => .none,
};
const huge_page_bytes = 2 * 1024 * 1024;
/// Blocks at least this large get their own mapping. On macOS 1 MiB measured
/// lowest: from 256 KiB, a single phone sheet peaked 0.3 MiB higher than with
/// malloc.
const mapped_bytes = switch (mapping) {
    .huge_pages => huge_page_bytes,
    .pages, .none => 1024 * 1024,
};

/// Whether a mapped block of this alignment comes from the page allocator:
/// always on macOS, and on Linux when a huge page cannot satisfy it.
fn onPages(alignment: Alignment) bool {
    return mapping == .pages or alignment.toByteUnits() > huge_page_bytes;
}

test "large blocks get their own mapping and small blocks use backing" {
    if (mapping == .none) return error.SkipZigTest;
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

test "a block grown across the threshold, or aligned past a huge page, never reaches backing" {
    if (mapping == .none) return error.SkipZigTest;
    var count: LargeCount = .{ .backing = std.testing.allocator };
    var pages: Mapped = .{ .backing = count.allocator() };
    const allocator = pages.allocator();
    const small = try allocator.alloc(u8, 64);
    @memset(small, 0x5a);
    const grown = try allocator.realloc(small, mapped_bytes);
    try std.testing.expectEqual(@as(u8, 0x5a), grown[63]);
    allocator.free(grown);
    const wide = try allocator.alignedAlloc(u8, .fromByteUnits(2 * huge_page_bytes), mapped_bytes);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(wide.ptr), 2 * huge_page_bytes));
    allocator.free(wide);
    try std.testing.expectEqual(@as(usize, 0), count.large);
}
