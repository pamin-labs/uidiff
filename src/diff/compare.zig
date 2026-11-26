//! Compares validated images and emits numbered regions of change.
const std = @import("std");
const values = @import("../value.zig");
const row_diff = @import("rows.zig");
const columns = @import("columns.zig");
const pixel_ops = @import("pixel.zig");
const yiq = @import("yiq.zig");
const change_mask = @import("mask.zig");
const regions = @import("regions.zig");
const unpaired = @import("unpaired.zig");
const sample = @import("test_support.zig");
const Allocator = std.mem.Allocator;
const Image = values.Image;
const Raster = yiq.Raster;
const Box = values.Box;
const Collector = regions.Collector;
const Pixel = values.Pixel;
/// The most regions a comparison reports; nearby ones merge to fit.
pub const max_regions = regions.max_regions;

const Scale = values.Scale;
const ScaleError = error{InvalidScale};

/// Options that passed Options.check, which alone makes them.
pub const Checked = struct { scale: Scale };

/// Parameters for comparing decoded images.
pub const Options = struct {
    /// Device pixels per CSS pixel.
    scale: Scale = .one,

    /// Rejects a non-positive or non-finite scale, once, before comparison.
    pub fn check(self: Options) ScaleError!Checked {
        if (!self.scale.isValid()) return error.InvalidScale;
        return .{ .scale = self.scale };
    }
};

/// The caller releases the region slice with deinit.
pub const Comparison = struct {
    regions: []const values.Region,
    moves: []const values.Move = &.{},
    /// The larger width of the two inputs, in device pixels.
    width: usize,
    /// The larger height of the two inputs, in device pixels.
    height: usize,

    /// Releases the region slice with the allocator passed to compare.
    pub fn deinit(self: Comparison, allocator: Allocator) void {
        allocator.free(self.regions);
        allocator.free(self.moves);
    }

    /// Returns the combined canvas dimensions.
    pub fn canvas(self: Comparison) values.Size {
        return .{ .width = self.width, .height = self.height };
    }
};

/// Input and scratch-space failures reported by the comparison domain.
pub const CompareError = Allocator.Error || ScaleError || values.Image.Invalid;

/// Scratch reused by every band: one mask byte per pixel and the fill's seeds.
const Scratch = struct { mask: []change_mask.Cell, seeds: []u32 };

const CompareBuffers = struct {
    mask: []change_mask.Cell = &.{},
    seeds: std.ArrayList(u32) = .empty,
    alignment: row_diff.Workspace = .{},

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
        return .{ .mask = self.mask[0..area], .seeds = self.seeds.items };
    }
};

/// Space added around each reported box, in CSS pixels.
pub const region_padding = regions.padding.count();
// Scroll tolerance in CSS pixels. A shift this small is not a change.
/// Maximum displacement treated as a short scroll.
pub const scroll_shift = values.CssPx.init(2);
// Short conflicting offsets can come from independent column groups.
const short_shift_rows = 16;
/// Rows on each side of a replacement that may hold part of a split edit.
const replacement_context_rows = 4;
const min_column_motion_rows = 4;
const column_motion_scroll_factor = 2;

/// Compares packed RGBA8 images. The caller owns the returned comparison.
pub fn compare(allocator: Allocator, before: Image, after: Image, options: Options) CompareError!Comparison {
    return compareChecked(allocator, before, after, try options.check());
}

/// Compares packed RGBA8 images with options already checked. The caller
/// owns the returned comparison.
pub fn compareChecked(allocator: Allocator, before: Image, after: Image, options: Checked) CompareError!Comparison {
    if (!before.valid() or !after.valid()) return error.InvalidImage;
    const width = @max(before.width, after.width);
    const height = @max(before.height, after.height);
    const max_gap_px: f64 = @floatFromInt(@max(width, height));
    const gap_px = @min(options.scale.devicePixels(regions.merge_gap), max_gap_px);
    const overlap_width = @min(before.width, after.width);
    const span = columns.span(before, after, overlap_width);
    if (span.width == 0 and before.width == after.width) {
        return .{ .regions = &.{}, .width = width, .height = height };
    }
    // The integer gap and scroll tolerance are clamped to validated image dimensions.
    const capacity = if (span.width == 0) 1 else Collector.capacity(before.size(), after.size(), @intFromFloat(gap_px));
    const storage = try allocator.alloc(regions.Candidate, capacity);
    defer allocator.free(storage);
    var collector = Collector.init(storage, before.size(), after.size(), gap_px, max_gap_px);
    var moves: std.ArrayList(values.Move) = .empty;
    defer moves.deinit(allocator);
    if (span.width != 0) {
        const scope: columns.Scope = .{ .before = before, .after = after, .span = span, .bounds = .{ .left = 0, .width = overlap_width } };
        try spanRegions(allocator, &collector, &moves, scope, @intFromFloat(@min(max_gap_px, options.scale.devicePixels(scroll_shift))));
    }
    if (before.width != after.width) {
        const old = before.width > after.width;
        const box = Box.fromPixels(overlap_width, 0, width - overlap_width, if (old) before.height else after.height);
        collector.addOn(if (old) .before else .after, box);
    }
    const out = try regions.resolve(allocator, &collector, &moves, before, after, options.scale, options.scale.devicePixels(scroll_shift));
    errdefer allocator.free(out);
    return .{ .regions = out, .moves = try moves.toOwnedSlice(allocator), .width = width, .height = height };
}

fn spanRegions(allocator: Allocator, collector: *Collector, moves: *std.ArrayList(values.Move), scope: columns.Scope, scroll_limit_px: usize) !void {
    const before = scope.before;
    const after = scope.after;
    const row_count = before.height + after.height;
    const storage = try allocator.alloc(u64, 2 * row_count);
    defer allocator.free(storage);
    const keys = storage[0..row_count];
    const filtered = storage[row_count..];
    const bands = try allocator.alloc(row_diff.Band, row_count + 1);
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
            const preserved = if (aligned) |global| try allocator.dupe(row_diff.Band, global) else &.{};
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
                    try gatherColumnMoves(allocator, moves, local, alignment, keys, scroll_limit_px)
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
    if (aligned) |alignment| try gatherMoves(allocator, moves, scope, alignment);
    try compareSpan(allocator, collector, scope, aligned, &buffers);
}

fn mixedShifts(bands: []const row_diff.Band) bool {
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

fn columnMotion(scope: columns.Scope, keys: []const u64, move: values.Move, scroll_limit_px: usize) bool {
    // A matching edge that remains at its old position gives no evidence
    // that the column moved. Require several content rows at the new offset.
    const before = keys[0..scope.before.height];
    const after = keys[scope.before.height..];
    const minimum: usize = @max(min_column_motion_rows, column_motion_scroll_factor * scroll_limit_px);
    var supported: usize = 0;
    for (0..move.before.height) |i| {
        const old = move.before.y + i;
        const new = move.after.y + i;
        if (before[old] != after[new] or (old < after.len and before[old] == after[old]) or unpaired.blankBand(scope.before, old, 1, scope.span)) continue;
        supported += 1;
        if (supported == minimum) return true;
    }
    return false;
}

fn gatherColumnMoves(allocator: Allocator, moves: *std.ArrayList(values.Move), scope: columns.Scope, bands: []const row_diff.Band, keys: []const u64, limit: usize) !bool {
    const first = moves.items.len;
    try gatherMoves(allocator, moves, scope, bands);
    var kept = first;
    for (moves.items[first..]) |move| {
        if (move.shift() <= limit or !columnMotion(scope, keys, move, limit)) continue;
        moves.items[kept] = move;
        kept += 1;
    }
    moves.items.len = kept;
    return kept != first;
}

fn gatherMoves(allocator: Allocator, moves: *std.ArrayList(values.Move), scope: columns.Scope, bands: []const row_diff.Band) !void {
    const span = scope.span;
    const first = moves.items.len;
    var previous: ?usize = null;
    for (bands, 0..) |band, i| {
        var height = @min(band.removed, band.added);
        if (height == 0 or band.before == band.after) {
            previous = null;
            continue;
        }
        if (i + 1 < bands.len) {
            const next = bands[i + 1];
            height += @min(next.before -| (band.before + band.removed), next.after -| (band.after + band.added));
        }
        if (previous) |index| {
            const move = &moves.items[index];
            if (move.before.y + move.before.height == band.before and move.after.y + move.after.height == band.after) {
                move.before.height += height;
                move.after.height += height;
                continue;
            }
        }
        previous = moves.items.len;
        try moves.append(allocator, .{
            .before = .{ .y = band.before, .height = height },
            .after = .{ .y = band.after, .height = height },
            .x = .init(span.left),
            .width = .init(span.width),
        });
    }
    var kept = first;
    for (moves.items[first..]) |move| {
        if (unpaired.blankBand(scope.before, move.before.y, move.before.height, span) and
            unpaired.blankBand(scope.after, move.after.y, move.after.height, span)) continue;
        var full = move;
        const pitch = move.shift();
        if (columns.enclosingCard(scope.before, span, scope.frame orelse scope.bounds, move.before.y, columns.CardSearch.motion(span, pitch))) |card| {
            full.x = .init(card.columns.left);
            full.width = .init(card.columns.width);
        }
        moves.items[kept] = full;
        kept += 1;
    }
    moves.items.len = kept;
}

fn alignSpan(allocator: Allocator, scope: columns.Scope, scroll_limit_px: usize, local_limit_px: usize, keys: []u64, bands: []row_diff.Band, filtered: []u64, workspace: *row_diff.Workspace) Allocator.Error!?[]row_diff.Band {
    const old_keys = keys[0..scope.before.height];
    const new_keys = keys[scope.before.height..];
    row_diff.keys(scope.before, scope.span.left, scope.span.width, old_keys);
    row_diff.keys(scope.after, scope.span.left, scope.span.width, new_keys);
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
        if (end - first <= local_limit_px) return row_diff.compactInsertion(old_keys, new_keys, scroll_limit_px, bands);
    }
    const limits: row_diff.Limits = .{
        .scroll = scroll_limit_px,
        .replacement = 2 * local_limit_px,
        // Unchanged columns on the same rows are additional evidence of a
        // local overwrite, especially when repeating lines can match at a pitch.
        .narrow_edit = scope.span.width <= @min(scope.before.width, scope.after.width) / 2,
        .images = .{ scope.before, scope.after },
        .left = scope.span.left,
        .width = scope.span.width,
    };
    const aligned = try row_diff.matchBands(allocator, old_keys, new_keys, limits, bands, filtered, workspace) orelse return null;
    row_diff.refineElements(old_keys, new_keys, limits, aligned);
    return aligned;
}

fn compareSpan(allocator: Allocator, collector: *Collector, scope: columns.Scope, aligned: ?[]row_diff.Band, buffers: *CompareBuffers) !void {
    const before = scope.before;
    const after = scope.after;
    const left = scope.span.left;
    const width = scope.span.width;
    const overlap = @min(before.height, after.height);
    const changes: []const row_diff.Band = if (aligned) |value| pruneMatched(scope, value) else &.{.{ .before = 0, .after = 0, .removed = overlap, .added = overlap }};

    const extension = @max(before.height, after.height) - overlap;
    var max_rows: usize = if (scope.frame != null and aligned == null) extension else 0;
    for (changes) |band| max_rows = @max(max_rows, band.removed, band.added);
    // Each band lies within at least one validated image, so its area fits the pixel cap.
    const scratch = try buffers.prepare(allocator, width * max_rows);
    const mask = scratch.mask;
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
            const rows = paired + top + bottom;
            const a: Raster = .{ .image = before, .left = left, .top = band.before - top, .width = width, .height = rows };
            const b: Raster = .{ .image = after, .left = left, .top = band.after - top, .width = width, .height = rows };
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
        unpaired.collect(collector, scope, scratch.mask, scratch.seeds, .{
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
        unpaired.collect(collector, scope, scratch.mask, scratch.seeds, .{ .side = .after, .y = new_tail, .count = band.added - paired, .background = background, .element = band.mode == .element });
    }
    if (aligned == null and extension != 0) {
        const old_is_taller = before.height > after.height;
        if (scope.frame != null) {
            const short = if (old_is_taller) after else before;
            unpaired.collect(collector, scope, scratch.mask, scratch.seeds, .{
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
fn compareReplacement(collector: *Collector, scope: columns.Scope, band: row_diff.Band, evidence: enum { unreported, single_row }) void {
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
        if (pixel_ops.sameRun(before, after)) continue;
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

fn pruneMatched(scope: columns.Scope, bands: []row_diff.Band) []row_diff.Band {
    var len: usize = 0;
    for (bands) |band| {
        if (band.mode == .hash_match and sameBandPixels(scope, band)) continue;
        bands[len] = band;
        len += 1;
    }
    return bands[0..len];
}

fn sameBandPixels(scope: columns.Scope, band: row_diff.Band) bool {
    const left = scope.span.left;
    const width = scope.span.width;
    // Check the actual bytes before dropping the band, including hash collisions.
    for (0..band.removed) |row| {
        const before = scope.before.rowSegment(band.before + row, left, width);
        const after = scope.after.rowSegment(band.after + row, left, width);
        if (!pixel_ops.sameRun(before, after)) return false;
    }
    return true;
}

fn comparePair(allocator: Allocator, before: Image, after: Image) !void {
    const result = try compare(allocator, before, after, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(values.Kind.inserted, result.regions[0].kind);
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
        @memset(small.mask, .clear);
        const large = try buffers.prepare(allocator, large_area);
        try std.testing.expectEqual(large_area, large.mask.len);
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
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    const after = try sample.Canvas.init(width, height);
    defer after.deinit();
    const border = sample.inkShade(170, 4);
    const button: Pixel = .{ 37, 99, 235, 255 };
    for ([_]sample.Canvas{ before, after }, [_]usize{ 0, 14 }) |canvas, growth| {
        canvas.fill(24, 20, 2, 146 + growth, border);
        canvas.fill(320, 20, 2, 146 + growth, border);
        canvas.fill(24, 20, 298, 2, border);
        canvas.fill(24, 164 + growth, 298, 2, border);
        canvas.line(48, 222, 48, 2, 28);
        canvas.fill(48, 107, 100 + growth, 26 + growth, button);
        canvas.line(60, 126, 114 + growth / 2, 4, 255);
        canvas.line(40, 305, 199 + growth, 5, 28);
        canvas.line(40, 300, 220 + growth, 6, 28);
    }
    const span: columns.Span = .{ .left = 24, .width = 298 };
    const scope: columns.Scope = .{ .before = before.view, .after = after.view, .span = span, .bounds = span };
    var storage: [regions.max_regions]regions.Candidate = undefined;
    var collector: Collector = .{ .boxes = &storage, .gap_px = 4, .max_gap_px = 20 };
    var buffers: CompareBuffers = .{};
    defer buffers.deinit(allocator);
    var bands = [_]row_diff.Band{.{ .before = 107, .after = 107, .removed = 26, .added = 40 }};
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

test "an aligned blank tail contributes no phantom move" {
    const before = try sample.Canvas.init(64, 32);
    defer before.deinit();
    const after = try sample.Canvas.init(64, 64);
    defer after.deinit();
    const span: columns.Span = .{ .left = 0, .width = 64 };
    const scope: columns.Scope = .{ .before = before.view, .after = after.view, .span = span, .bounds = span };
    const band: row_diff.Band = .{ .before = 26, .after = 58, .removed = 6, .added = 6 };
    var moves: std.ArrayList(values.Move) = .empty;
    defer moves.deinit(std.testing.allocator);
    try gatherMoves(std.testing.allocator, &moves, scope, &.{band});
    try std.testing.expectEqual(@as(usize, 0), moves.items.len);
    before.fill(3, 28, 8, 2, sample.inkShade(70, 4));
    after.fill(3, 60, 8, 2, sample.inkShade(70, 4));
    try gatherMoves(std.testing.allocator, &moves, scope, &.{band});
    try std.testing.expectEqual(@as(usize, 1), moves.items.len);
}

test "invalid borrowed shapes and non-finite scales fail at the comparison boundary" {
    const one: Image = .{ .width = 1, .height = 1, .pixels = &.{@splat(255)} };
    const wrong: Image = .{ .width = std.math.maxInt(usize), .height = 2, .pixels = one.pixels };
    try std.testing.expectError(error.InvalidImage, compare(std.testing.allocator, wrong, one, .{}));
    try std.testing.expectError(error.InvalidScale, compare(std.testing.allocator, one, one, .{ .scale = .{ .factor = std.math.nan(f64) } }));
}

test "comparison releases each allocation on failure" {
    const old = [_]values.Pixel{ .{ 0, 0, 0, 255 }, .{ 10, 0, 0, 255 }, .{ 20, 0, 0, 255 }, .{ 30, 0, 0, 255 } };
    const new = old[0..2].* ++ [_]values.Pixel{.{ 64, 0, 0, 255 }} ++ old[2..].*;
    const before = Image{ .width = 1, .height = old.len, .pixels = &old };
    const after = Image{ .width = 1, .height = new.len, .pixels = &new };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, comparePair, .{ before, after });
}

test {
    std.testing.refAllDecls(@This());
}
