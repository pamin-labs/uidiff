//! Aligns changed columns and compares their paired and unpaired rows.
const std = @import("std");
const values = @import("../value.zig");
const columns = @import("columns.zig");
const change_mask = @import("mask.zig");
const motion = @import("motion.zig");
const pixel = @import("pixel.zig");
const regions = @import("regions.zig");
const rows = @import("rows.zig");
const unpaired = @import("unpaired.zig");
const yiq = @import("yiq.zig");
const Allocator = std.mem.Allocator;
const Box = values.Box;
const Collector = regions.Collector;
const Image = values.Image;
const Pixel = values.Pixel;
const Raster = yiq.Raster;

const Scratch = change_mask.Scratch;

const CompareBuffers = struct {
    mask: []change_mask.Cell = &.{},
    seeds: std.ArrayList(u32) = .empty,
    alignment: rows.Workspace = .{},

    fn deinit(self: *CompareBuffers, allocator: Allocator) void {
        self.alignment.deinit(allocator);
        self.seeds.deinit(allocator);
        values.freeUnfilled(change_mask.Cell, allocator, self.mask);
    }

    fn prepare(self: *CompareBuffers, allocator: Allocator, area: usize) Allocator.Error!Scratch {
        const seed_rows = @max(1, @min(regions.max_fill_seeds, area));
        if (area > self.mask.len) {
            // Remapping lets the allocator reuse the storage. If it cannot,
            // release the old mask first because yiq.mask overwrites every cell.
            self.mask = allocator.remap(self.mask, area) orelse grow: {
                values.freeUnfilled(change_mask.Cell, allocator, self.mask);
                self.mask = &.{};
                break :grow try values.allocUnfilled(change_mask.Cell, allocator, area);
            };
        }
        try self.seeds.ensureTotalCapacityPrecise(allocator, seed_rows);
        self.seeds.items.len = seed_rows;
        return .{ .cells = self.mask[0..area], .seeds = self.seeds.items };
    }
};

// Short conflicting offsets can come from independent column groups.
const short_shift_rows = 16;
/// Rows on each side of a replacement that may hold part of a split edit.
const replacement_context_rows = 4;

/// Collects changed bands and moves across the changed columns.
pub fn collect(allocator: Allocator, collector: *Collector, moves: *std.ArrayList(values.Move), scope: columns.Scope, scroll_limit_px: usize) Allocator.Error!void {
    const before = scope.before;
    const after = scope.after;
    const row_count = before.height + after.height;
    const storage = try allocator.alloc(u64, 2 * row_count);
    defer allocator.free(storage);
    const keys = storage[0..row_count];
    const filtered = storage[row_count..];
    const bands = try allocator.alloc(rows.Band, row_count + 1);
    defer allocator.free(bands);

    var buffers: CompareBuffers = .{};
    defer buffers.deinit(allocator);
    const local_limit_px: usize = collector.localLimit();
    var aligned = try alignSpan(allocator, scope, scroll_limit_px, local_limit_px, keys, bands, filtered, &buffers.alignment);
    const ambiguous = if (aligned) |whole| mixedShifts(whole) else true;
    if (scope.span.width > columns.min_gutter and (ambiguous or hasFlatEdge(scope))) {
        const stationary = try allocator.alloc(bool, scope.span.width);
        defer allocator.free(stationary);
        var parts = columns.partition(before, after, scope.span, stationary);
        if (parts.next()) |first| if (first.span.width != scope.span.width and
            (ambiguous or hasFlatColumn(before, after, first, parts)))
        {
            if (before.height == after.height and !hasWideColumn(first, parts, local_limit_px)) {
                buffers.alignment.deinit(allocator);
                return compareSpan(allocator, collector, scope, null, &buffers);
            }
            const preserved = if (aligned) |global| try allocator.dupe(rows.Band, global) else &.{};
            defer allocator.free(preserved);
            const empty = collector.*;
            var has_movement = false;
            var part = first;
            while (true) {
                const local: columns.Scope = .{ .before = before, .after = after, .span = part.span, .bounds = part.span, .frame = part.lane };
                // A strip as narrow as the replacement gap may be only the
                // edge of a card. Give it the same positional comparison as
                // a stationary group unless the whole span explains a move.
                const local_bands = if (part.span.width <= local_limit_px)
                    null
                else
                    try alignSpan(allocator, local, scroll_limit_px, local_limit_px, keys, bands, filtered, &buffers.alignment);
                const column_moved = if (local_bands) |alignment|
                    try motion.gatherColumnMoves(allocator, moves, local, alignment, keys, scroll_limit_px)
                else
                    false;
                has_movement = has_movement or column_moved;
                try compareSpan(allocator, collector, local, if (column_moved) local_bands else null, &buffers);
                part = parts.next() orelse break;
            }
            if (has_movement) return;
            collector.* = empty;
            moves.clearRetainingCapacity();
            if (aligned != null) {
                @memcpy(bands[0..preserved.len], preserved);
                aligned = bands[0..preserved.len];
            }
        };
    }
    buffers.alignment.deinit(allocator);
    if (aligned) |alignment| try motion.gatherMoves(allocator, moves, scope, alignment);
    try compareSpan(allocator, collector, scope, aligned, &buffers);
}

fn mixedShifts(bands: []const rows.Band) bool {
    var shift: ?isize = null;
    var brief = false;
    var different = false;
    for (bands) |band| {
        const length = @min(band.removed, band.added);
        if (length == 0 or band.before == band.after) continue;
        const offset = @as(isize, @intCast(band.after)) - @as(isize, @intCast(band.before));
        if (shift == null) shift = offset;
        different = different or offset != shift.?;
        brief = brief or length < short_shift_rows;
        if (brief and different) return true;
    }
    return false;
}

// A blank flank can contain a position-only edit even when the main content
// has one convincing displacement. Probe those columns before scanning gutters.
fn hasFlatEdge(scope: columns.Scope) bool {
    const left: columns.Span = .{ .left = scope.span.left, .width = 1 };
    const right: columns.Span = .{ .left = scope.span.left + scope.span.width - 1, .width = 1 };
    return columns.sameRows(scope.before, left) or columns.sameRows(scope.after, left) or
        columns.sameRows(scope.before, right) or columns.sameRows(scope.after, right);
}

// A group with the same row throughout one image supplies no evidence of
// motion. It must not take its displacement from adjacent content.
fn hasFlatColumn(before: Image, after: Image, first: columns.Group, trailing: columns.Partition) bool {
    var group = first;
    var rest = trailing;
    while (true) {
        if (columns.sameRows(before, group.span) or columns.sameRows(after, group.span)) return true;
        group = rest.next() orelse return false;
    }
}

fn hasWideColumn(first: columns.Group, tail: columns.Partition, limit: usize) bool {
    var group = first;
    var rest = tail;
    while (group.span.width <= limit) group = rest.next() orelse return false;
    return true;
}

fn alignSpan(allocator: Allocator, scope: columns.Scope, scroll_limit_px: usize, local_limit_px: usize, keys: []u64, bands: []rows.Band, filtered: []u64, workspace: *rows.Workspace) Allocator.Error!?[]rows.Band {
    const old_keys = keys[0..scope.before.height];
    const new_keys = keys[scope.before.height..];
    rows.keys(scope.before, scope.span.left, scope.span.width, old_keys);
    rows.keys(scope.after, scope.span.left, scope.span.width, new_keys);
    if (scope.frame != null and (std.mem.allEqual(u64, old_keys, old_keys[0]) or
        std.mem.allEqual(u64, new_keys, new_keys[0]))) return null;
    // A compact change is local motion, even if re-pairing its two edges
    // happens to match a few rows at a different offset.
    const narrow_view = (scope.frame != null or old_keys.len == new_keys.len) and scope.span.width <= local_limit_px;
    const growing_column = scope.frame != null and old_keys.len != new_keys.len;
    if (narrow_view or growing_column) {
        var end = @min(old_keys.len, new_keys.len);
        const first = std.mem.indexOfDiff(u64, old_keys[0..end], new_keys[0..end]) orelse return null;
        while (end > first and old_keys[end - 1] == new_keys[end - 1]) end -= 1;
        if (end - first <= local_limit_px) return rows.compactInsertion(old_keys, new_keys, scroll_limit_px, bands);
    }
    const limits: rows.Limits = .{
        .scroll = scroll_limit_px,
        .replacement = 2 * local_limit_px,
        // Unchanged columns on the same rows are additional evidence of a
        // local overwrite, especially when repeating lines can match at a pitch.
        .narrow_edit = scope.span.width <= @min(scope.before.width, scope.after.width) / 2,
        .images = .{ scope.before, scope.after },
        .left = scope.span.left,
        .width = scope.span.width,
    };
    const aligned = try rows.matchBands(allocator, old_keys, new_keys, limits, bands, filtered, workspace) orelse return null;
    rows.refineElements(old_keys, new_keys, limits, aligned);
    return aligned;
}

fn compareSpan(allocator: Allocator, collector: *Collector, scope: columns.Scope, aligned: ?[]rows.Band, buffers: *CompareBuffers) !void {
    const before = scope.before;
    const after = scope.after;
    const left = scope.span.left;
    const width = scope.span.width;
    const overlap = @min(before.height, after.height);
    const changes: []const rows.Band = if (aligned) |value| pruneMatched(scope, value) else &.{.{ .before = 0, .after = 0, .removed = overlap, .added = overlap }};

    const extension = @max(before.height, after.height) - overlap;
    var max_rows: usize = if (scope.frame != null and aligned == null) extension else 0;
    for (changes) |band| max_rows = @max(max_rows, band.removed, band.added);
    // Each band lies within at least one validated image, so its area fits the pixel cap.
    const scratch = try buffers.prepare(allocator, width * max_rows);
    const mask = scratch.cells;
    const seeds = scratch.seeds;

    for (changes) |band| {
        if (band.mode == .spacing) continue;
        const paired = @min(band.removed, band.added);
        var grouped = false;
        if (paired != 0) {
            const moved = band.before != band.after;
            const context: usize = if (moved) yiq.moved_coverage_radius else 0;
            const top = @min(context, band.before, band.after);
            const bottom = @min(context, before.height - band.before - paired, after.height - band.after - paired);
            const raster_rows = paired + top + bottom;
            const a: Raster = .{ .image = before, .left = left, .top = band.before - top, .width = width, .height = raster_rows };
            const b: Raster = .{ .image = after, .left = left, .top = band.after - top, .width = width, .height = raster_rows };
            if (yiq.mask(a, b, top, paired, mask)) {
                const changed = mask[0 .. width * paired];
                if (moved) yiq.clearMovedCoverage(a, b, top, changed);
                const cells: change_mask.Mask = .{ .cells = changed, .width = width };
                grouped = regions.group(collector, cells, seeds, .{ .left = left, .rows = .{ .paired = .{ .before = band.before, .after = band.after } } }) == .kept;
            }
            if (band.mode == .replacement) compareReplacement(collector, scope, band, if (grouped) .single_row else .unreported);
        }
        const old_tail = band.before + paired;
        const new_tail = band.after + paired;
        unpaired.collect(collector, scope, scratch, .{
            .side = .before,
            .y = old_tail,
            .count = band.removed - paired,
            .element = band.mode == .element,
            .opposite = new_tail,
            .background = if (band.mode == .regular and grouped and band.removed > paired)
                unpaired.sharedBackdrop(scope, band.before + band.removed, new_tail)
            else
                null,
        });
        const background = switch (band.mode) {
            .revealed => |row| after.row(row),
            .regular => if (grouped and band.added > paired)
                unpaired.sharedBackdrop(scope, old_tail, band.after + band.added)
            else
                null,
            else => null,
        };
        unpaired.collect(collector, scope, scratch, .{ .side = .after, .y = new_tail, .count = band.added - paired, .background = background, .element = band.mode == .element });
    }
    if (aligned == null and extension != 0) {
        const old_is_taller = before.height > after.height;
        if (scope.frame != null) {
            const short = if (old_is_taller) after else before;
            unpaired.collect(collector, scope, scratch, .{
                .side = if (old_is_taller) .before else .after,
                .y = overlap,
                .count = extension,
                .background = short.row(overlap - 1),
            });
        } else {
            const box = Box.fromPixels(scope.bounds.left, overlap, scope.bounds.width, extension);
            collector.addOn(if (old_is_taller) .before else .after, box);
        }
    }
}

// Edge filtering can hide pieces of a replacement stroke. Recover the
// raw threshold bounds when no component survives or when the edit is
// confined to one row.
fn compareReplacement(collector: *Collector, scope: columns.Scope, band: rows.Band, evidence: enum { unreported, single_row }) void {
    const left = scope.span.left;
    const width = scope.span.width;
    // Equal-displacement anchors can include edited rows alongside the
    // replacement. Include enough context to recover a split component.
    const top = @min(replacement_context_rows, band.before, band.after);
    const bottom = @min(replacement_context_rows, scope.before.height - band.before - band.removed, scope.after.height - band.after - band.added);
    const first_old = band.before - top;
    const first_new = band.after - top;
    const height = top + band.removed + bottom;
    var min_x = width;
    var max_x: usize = 0;
    var min_y = height;
    var max_y: usize = 0;
    var pixels_changed: usize = 0;
    var inside = false;
    for (0..height) |y| {
        const before = scope.before.rowSegment(first_old + y, left, width);
        const after = scope.after.rowSegment(first_new + y, left, width);
        if (pixel.sameRun(before, after)) continue;
        const offset = ((first_old + y) * scope.before.width + left) * @sizeOf(Pixel);
        for (before, after, 0..) |old, new, x| {
            if (!yiq.aboveThreshold(old, new, offset + x * @sizeOf(Pixel))) continue;
            inside = inside or (y >= top and y < top + band.removed);
            pixels_changed += 1;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x + 1);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y + 1);
        }
    }
    if (!inside or !collector.supports(pixels_changed)) return;
    // Edge filtering can leave a thin stroke split into several groups.
    if (evidence == .single_row and max_y - min_y != 1) return;
    collector.add(.{
        .before = Box.fromPixels(left + min_x, first_old + min_y, max_x - min_x, max_y - min_y),
        .after = Box.fromPixels(left + min_x, first_new + min_y, max_x - min_x, max_y - min_y),
    });
}

fn pruneMatched(scope: columns.Scope, bands: []rows.Band) []rows.Band {
    var len: usize = 0;
    for (bands) |band| {
        if (band.mode == .hash_match and sameBandPixels(scope, band)) continue;
        bands[len] = band;
        len += 1;
    }
    return bands[0..len];
}

fn sameBandPixels(scope: columns.Scope, band: rows.Band) bool {
    const left = scope.span.left;
    const width = scope.span.width;
    // Check the actual bytes before dropping the band, including hash collisions.
    for (0..band.removed) |row| {
        const before = scope.before.rowSegment(band.before + row, left, width);
        const after = scope.after.rowSegment(band.after + row, left, width);
        if (!pixel.sameRun(before, after)) return false;
    }
    return true;
}

test "mask growth avoids having both sizes live on a remapping allocator" {
    const small_area = 11;
    const large_area = 31;
    var storage: [512]u8 align(@alignOf(u32)) = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var counting: std.testing.FailingAllocator = .init(fixed.allocator(), .{});
    const allocator = counting.allocator();
    var buffers: CompareBuffers = .{};
    {
        defer buffers.deinit(allocator);
        // Reserve the seeds first so the mask is eligible for in-place growth.
        try buffers.seeds.ensureTotalCapacityPrecise(allocator, large_area);
        const small = try buffers.prepare(allocator, small_area);
        @memset(small.cells, .clear);
        const large = try buffers.prepare(allocator, large_area);
        try std.testing.expectEqual(large_area, large.cells.len);
        try std.testing.expectEqual(@as(usize, 0), counting.freed_bytes);
        // No frees occurred, so total allocated bytes is the peak live count.
        const peak = large_area * (@sizeOf(u32) + @sizeOf(change_mask.Cell));
        try std.testing.expectEqual(peak, counting.allocated_bytes);
    }
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}

test "mask growth releases the old mask if remapping and allocation fail" {
    const small_area = 11;
    const large_area = 31;
    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 2,
        .resize_fail_index = 0,
    });
    const allocator = counting.allocator();
    var buffers: CompareBuffers = .{};
    defer buffers.deinit(allocator);
    _ = try buffers.prepare(allocator, small_area);
    try std.testing.expectError(error.OutOfMemory, buffers.prepare(allocator, large_area));
    try std.testing.expectEqual(@as(usize, 0), buffers.mask.len);
    try std.testing.expectEqual(small_area * @sizeOf(change_mask.Cell), counting.freed_bytes);
}

test "a taller button excludes unchanged card borders on unpaired rows" {
    const allocator = std.testing.allocator;
    const width = 360;
    const height = 280;
    const canvas = @import("uidiff_test_canvas").Painters(values.Image);
    const before = try canvas.Canvas.init(width, height);
    defer before.deinit();
    const after = try canvas.Canvas.init(width, height);
    defer after.deinit();
    const border = canvas.inkShade(170, 4);
    const button: Pixel = .{ 37, 99, 235, 255 };
    for ([_]canvas.Canvas{ before, after }, [_]usize{ 0, 14 }) |image, growth| {
        image.fill(24, 20, 2, 146 + growth, border);
        image.fill(320, 20, 2, 146 + growth, border);
        image.fill(24, 20, 298, 2, border);
        image.fill(24, 164 + growth, 298, 2, border);
        image.line(48, 222, 48, 2, 28);
        image.fill(48, 107, 100 + growth, 26 + growth, button);
        image.line(60, 126, 114 + growth / 2, 4, 255);
        image.line(40, 305, 199 + growth, 5, 28);
        image.line(40, 300, 220 + growth, 6, 28);
    }
    const span: columns.Span = .{ .left = 24, .width = 298 };
    const scope: columns.Scope = .{ .before = before.view, .after = after.view, .span = span, .bounds = span };
    var storage: [regions.max_regions]regions.Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap_px = 4, .max_gap_px = 20 };
    var buffers: CompareBuffers = .{};
    defer buffers.deinit(allocator);
    var bands = [_]rows.Band{.{ .before = 107, .after = 107, .removed = 26, .added = 40 }};
    try compareSpan(allocator, &collector, scope, &bands, &buffers);
    const retained = collector.retain();
    try std.testing.expectEqual(@as(usize, 1), retained.count);
    const region = retained.buffer[0].region;
    const old = region.before.?;
    const new = region.after.?;
    try std.testing.expect(new.bottom() > old.bottom());
    try std.testing.expect(new.x > 25 and new.right() < 320);
    try std.testing.expect(new.right() >= 162);
}

test {
    std.testing.refAllDecls(@This());
}
