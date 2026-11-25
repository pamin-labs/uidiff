//! Compares validated images and emits numbered regions of change.
const std = @import("std");
const values = @import("../value.zig");
const row_diff = @import("rows.zig");
const columns = @import("columns.zig");
const pixel_ops = @import("pixel.zig");
const yiq = @import("yiq.zig");
const regions = @import("regions.zig");
const sample = @import("test_support.zig");
const Allocator = std.mem.Allocator;
const Image = values.Image;
const Raster = yiq.Raster;
const Box = values.Box;
const Collector = regions.Collector;
const Region = values.Region;
const Pixel = values.Pixel;
const Kind = values.Kind;
const min_region_pixels = regions.min_region_pixels;
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

/// The compared pair and the column span holding every change, in device pixels.
const Scope = struct {
    before: Image,
    after: Image,
    span: columns.Span,
    /// Where to draw a gap with no changed pixels against its background.
    bounds: columns.Span,
    frame: ?columns.Span = null,
    kind: enum { whole, column } = .whole,
};

/// Rows one side has and the other does not.
const Unpaired = struct { side: values.Side, y: usize, count: usize, background: ?[]const Pixel = null, element: bool = false, opposite: ?usize = null };

/// Scratch reused by every band: one mask byte per pixel and the fill's seeds.
const Scratch = struct { mask: []regions.Cell, seeds: []u32 };

const CompareBuffers = struct {
    mask: []regions.Cell = &.{},
    seeds: std.ArrayList(u32) = .empty,
    alignment: row_diff.Workspace = .{},

    fn deinit(self: *CompareBuffers, allocator: Allocator) void {
        self.alignment.deinit(allocator);
        self.seeds.deinit(allocator);
        self.freeMask(allocator);
    }

    fn prepare(self: *CompareBuffers, allocator: Allocator, area: usize) Allocator.Error!Scratch {
        const seed_rows = @max(1, @min(regions.max_fill_seeds, area));
        if (area > self.mask.len) {
            // yiq.mask writes every cell it hands to the grouping pass.
            const fresh = try values.allocUnfilled(regions.Cell, allocator, area);
            self.freeMask(allocator);
            self.mask = fresh;
        }
        try self.seeds.ensureTotalCapacityPrecise(allocator, seed_rows);
        self.seeds.items.len = seed_rows;
        return .{ .mask = self.mask[0..area], .seeds = self.seeds.items };
    }

    fn freeMask(self: *CompareBuffers, allocator: Allocator) void {
        values.freeUnfilled(regions.Cell, allocator, self.mask);
    }
};

/// Space added around each reported box, in CSS pixels.
pub const region_padding = regions.padding.count();
const test_gap = regions.merge_gap.count();
// Scroll tolerance in CSS pixels. A shift this small is not a change.
const scroll_shift = values.CssPx.init(2);
// Short conflicting offsets can come from independent column groups.
const short_shift_rows = 16;
/// Rows on each side of a replacement that may hold part of a split edit.
const replacement_context_rows = 4;
const min_bar_rows = 2;
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
    var collector: Collector = .{
        .boxes = storage,
        .gap_px = gap_px,
        .max_gap_px = max_gap_px,
        .min_pixels = regions.minPixels(before.size(), after.size()),
    };
    var moves: std.ArrayList(values.Move) = .empty;
    defer moves.deinit(allocator);
    if (span.width != 0) {
        const scope: Scope = .{ .before = before, .after = after, .span = span, .bounds = .{ .left = 0, .width = overlap_width } };
        try spanRegions(allocator, &collector, &moves, scope, @intFromFloat(@min(max_gap_px, options.scale.devicePixels(scroll_shift))));
    }
    if (before.width != after.width) {
        const old = before.width > after.width;
        const box = Box.fromPixels(overlap_width, 0, width - overlap_width, if (old) before.height else after.height);
        collector.addOn(if (old) .before else .after, box);
    }
    collector.growGap();
    if (regions.mergeSwap(storage[0..collector.len], moves.items, before, after, options.scale)) |len| {
        collector.len = len;
        moves.clearRetainingCapacity();
    }
    if (collector.len > 1) collector.len = regions.mergeCorners(storage[0..collector.len], before, after, options.scale);
    if (collector.len > 1) collector.len = regions.mergeLogical(storage[0..collector.len], before, after, options.scale, moves.items);
    collector.len = regions.mergeTabSelection(storage[0..collector.len], before, after, options.scale);
    if (moves.items.len == 0) regions.pairCardGrid(storage[0..collector.len], before, after, options.scale);
    if (collector.len == 1 and moves.items.len == 0 and storage.len > 1) {
        if (regions.shadeMarginEdit(storage[0].region, before, after, options.scale)) |mark| {
            // This smaller edit has independent evidence inside the shaded
            // extent. It must bypass the normal nearby-box merger.
            storage[1] = .{ .region = mark, .pixels = storage[0].pixels };
            collector.len = 2;
        }
    }
    const out = try allocator.alloc(values.Region, collector.len);
    errdefer allocator.free(out);
    for (out, storage[0..collector.len]) |*region, box| region.* = box.region;
    if (moves.items.len != 0) moves.shrinkRetainingCapacity(regions.keepMoves(moves.items, out, options.scale, options.scale.devicePixels(scroll_shift)));
    if (out.len == 1 and moves.items.len == 0) regions.classifyOverlay(&out[0], before, after, options.scale);
    regions.finish(out, before.size(), after.size(), options.scale);
    return .{ .regions = out, .moves = try moves.toOwnedSlice(allocator), .width = width, .height = height };
}

fn spanRegions(allocator: Allocator, collector: *Collector, moves: *std.ArrayList(values.Move), scope: Scope, scroll_limit_px: usize) !void {
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
    const local_limit_px: usize = @intFromFloat(@min(collector.max_gap_px, 2 * collector.gap_px));
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
                const local: Scope = .{ .before = before, .after = after, .span = part.span, .bounds = part.span, .frame = part.lane, .kind = .column };
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
fn hasFlatEdge(scope: Scope) bool {
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

fn columnMotion(scope: Scope, keys: []const u64, move: values.Move, scroll_limit_px: usize) bool {
    // A matching edge that remains at its old position gives no evidence
    // that the column moved. Require several content rows at the new offset.
    const before = keys[0..scope.before.height];
    const after = keys[scope.before.height..];
    const minimum: usize = @max(min_column_motion_rows, column_motion_scroll_factor * scroll_limit_px);
    var supported: usize = 0;
    for (0..move.before.height) |i| {
        const old = move.before.y + i;
        const new = move.after.y + i;
        if (before[old] != after[new] or (old < after.len and before[old] == after[old]) or blankBand(scope.before, old, 1, scope.span)) continue;
        supported += 1;
        if (supported == minimum) return true;
    }
    return false;
}

fn gatherColumnMoves(allocator: Allocator, moves: *std.ArrayList(values.Move), scope: Scope, bands: []const row_diff.Band, keys: []const u64, limit: usize) !bool {
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

fn gatherMoves(allocator: Allocator, moves: *std.ArrayList(values.Move), scope: Scope, bands: []const row_diff.Band) !void {
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
        if (blankBand(scope.before, move.before.y, move.before.height, span) and
            blankBand(scope.after, move.after.y, move.after.height, span)) continue;
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

fn alignSpan(allocator: Allocator, scope: Scope, scroll_limit_px: usize, local_limit_px: usize, keys: []u64, bands: []row_diff.Band, filtered: []u64, workspace: *row_diff.Workspace) Allocator.Error!?[]row_diff.Band {
    const old_keys = keys[0..scope.before.height];
    const new_keys = keys[scope.before.height..];
    row_diff.keys(scope.before, scope.span.left, scope.span.width, old_keys);
    row_diff.keys(scope.after, scope.span.left, scope.span.width, new_keys);
    if (scope.kind == .column and (std.mem.allEqual(u64, old_keys, old_keys[0]) or
        std.mem.allEqual(u64, new_keys, new_keys[0]))) return null;
    // A compact change is local motion, even if re-pairing its two edges
    // happens to match a few rows at a different offset.
    const narrow_view = (scope.kind == .column or old_keys.len == new_keys.len) and scope.span.width <= local_limit_px;
    const growing_column = scope.kind == .column and old_keys.len != new_keys.len;
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

fn compareSpan(allocator: Allocator, collector: *Collector, scope: Scope, aligned: ?[]row_diff.Band, buffers: *CompareBuffers) !void {
    const before = scope.before;
    const after = scope.after;
    const left = scope.span.left;
    const width = scope.span.width;
    const overlap = @min(before.height, after.height);
    const changes: []const row_diff.Band = if (aligned) |value| pruneMatched(scope, value) else &.{.{ .before = 0, .after = 0, .removed = overlap, .added = overlap }};

    const extension = @max(before.height, after.height) - overlap;
    var max_rows: usize = if (scope.kind == .column and aligned == null) extension else 0;
    for (changes) |band| max_rows = @max(max_rows, band.removed, band.added);
    // Each band lies within at least one validated image, so its area fits the pixel cap.
    const scratch = try buffers.prepare(allocator, width * max_rows);
    const mask = scratch.mask;
    const seeds = scratch.seeds;

    for (changes) |band| {
        if (band.mode == .spacing) continue;
        const paired = @min(band.removed, band.added);
        if (paired != 0) {
            const moved = band.before != band.after;
            const context: usize = if (moved) yiq.moved_coverage_radius else 0;
            const top = @min(context, band.before, band.after);
            const bottom = @min(context, before.height - band.before - paired, after.height - band.after - paired);
            const rows = paired + top + bottom;
            const a: Raster = .{ .image = before, .left = left, .top = band.before - top, .width = width, .height = rows };
            const b: Raster = .{ .image = after, .left = left, .top = band.after - top, .width = width, .height = rows };
            var grouped = false;
            if (yiq.mask(a, b, top, paired, mask)) {
                const changed = mask[0 .. width * paired];
                if (moved) yiq.clearMovedCoverage(a, b, top, changed);
                const cells: regions.Mask = .{ .cells = changed, .width = width };
                grouped = regions.group(collector, cells, seeds, .{ .left = left, .before_y = band.before, .after_y = band.after }) == .kept;
            }
            if (band.mode == .replacement) compareReplacement(collector, scope, band, if (grouped) .single_row else .unreported);
        }
        unpaired(collector, scope, scratch, .{ .side = .before, .y = band.before + paired, .count = band.removed - paired, .element = band.mode == .element, .opposite = band.after + paired });
        const background = switch (band.mode) {
            .revealed => |row| after.row(row),
            else => null,
        };
        unpaired(collector, scope, scratch, .{ .side = .after, .y = band.after + paired, .count = band.added - paired, .background = background, .element = band.mode == .element });
    }
    if (aligned == null and extension != 0) {
        const old_is_taller = before.height > after.height;
        if (scope.kind == .column) {
            const short = if (old_is_taller) after else before;
            unpaired(collector, scope, scratch, .{
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
fn compareReplacement(collector: *Collector, scope: Scope, band: row_diff.Band, evidence: enum { unreported, single_row }) void {
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
        const before = scope.before.row(first_old + y)[left..][0..width];
        const after = scope.after.row(first_new + y)[left..][0..width];
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
    if (!inside or pixels_changed < collector.min_pixels) return;
    // Edge filtering can leave a thin stroke split into several groups.
    if (evidence == .single_row and max_y - min_y != 1) return;
    collector.add(.{
        .before = Box.fromPixels(left + min_x, first_old + min_y, max_x - min_x, max_y - min_y),
        .after = Box.fromPixels(left + min_x, first_new + min_y, max_x - min_x, max_y - min_y),
    });
}

fn pruneMatched(scope: Scope, bands: []row_diff.Band) []row_diff.Band {
    var len: usize = 0;
    for (bands) |band| {
        if (band.mode == .hash_match and sameBandPixels(scope, band)) continue;
        bands[len] = band;
        len += 1;
    }
    return bands[0..len];
}

fn sameBandPixels(scope: Scope, band: row_diff.Band) bool {
    const left = scope.span.left;
    const width = scope.span.width;
    // Check the actual bytes before dropping the band, including hash collisions.
    for (0..band.removed) |row| {
        const before = scope.before.row(band.before + row)[left..][0..width];
        const after = scope.after.row(band.after + row)[left..][0..width];
        if (!pixel_ops.sameRun(before, after)) return false;
    }
    return true;
}

fn unpaired(collector: *Collector, scope: Scope, scratch: Scratch, rows: Unpaired) void {
    if (rows.count == 0) return;
    const source = if (rows.side == .before) scope.before else scope.after;
    const left = scope.span.left;
    const width = scope.span.width;
    const y = rows.y;
    if (rows.element and rows.background == null) {
        if (columns.enclosingCard(source, scope.span, scope.frame orelse scope.bounds, y, columns.CardSearch.motion(scope.span, rows.count))) |card| {
            const box = Box.fromPixels(card.columns.left, card.top, card.columns.width, card.height);
            collector.addOn(rows.side, box);
            return;
        }
    }
    const a: Raster = .{ .image = source, .left = left, .top = y, .width = width, .height = rows.count };
    var b = a;
    b.background = .margin;
    if (rows.background) |background| {
        // The repeated row may come from a narrower image. Limit only the
        // virtual backdrop's extent, keeping its neighbour loads in bounds.
        b.image.width = @min(source.width, background.len);
        b.image.pixels = source.pixels[0 .. b.image.width * source.height];
        b.background = .{ .row = background };
    } else if (y > 0 and y + rows.count < source.height) {
        const above = source.row(y - 1)[left..][0..width];
        const below = source.row(y + rows.count)[left..][0..width];
        const last = source.row(y + rows.count - 1)[left..][0..width];
        if (pixel_ops.sameRun(above, below) or
            (rows.element and pixel_ops.sameRun(above, last)))
        {
            b.background = .{ .row = source.row(y - 1) };
        }
    }
    const mask = scratch.mask[0 .. width * rows.count];
    const at: regions.Placement = .{
        .left = left,
        .before_y = if (rows.side == .before) y else null,
        .after_y = if (rows.side == .after) y else null,
    };
    if (yiq.mask(a, b, 0, rows.count, mask)) {
        const cells: regions.Mask = .{ .cells = mask, .width = width };
        if (rows.element) {
            if (regions.groupElement(collector, cells, at)) return;
        } else if (regions.group(collector, cells, scratch.seeds, at) != .empty) return;
    }
    if (rows.background != null) return;
    const blank = blankBand(source, y, rows.count, scope.bounds);
    // An empty band that changes layout spans its column.
    const bounds = if (blank) scope.bounds else scope.span;
    if (rows.side == .before) if (rows.opposite) |opposite| {
        // Unchanged columns outside the reported span can contain unrelated
        // paint. Test the same columns that the fallback would report.
        if ((blank or (bounds.width != scope.bounds.width and blankBand(source, y, rows.count, bounds))) and
            unchangedBlank(scope, bounds, y, opposite, rows.count)) return;
    };
    const box = Box.fromPixels(bounds.left, y, bounds.width, rows.count);
    collector.addOn(rows.side, box);
}

fn blankBand(source: Image, first: usize, rows: usize, bounds: columns.Span) bool {
    const head = rowRun(source, first, bounds);
    if (!pixel_ops.sameRun(head[1..], head[0 .. head.len - 1])) return false;
    for (first + 1..first + rows) |y| {
        if (!pixel_ops.sameRun(head, rowRun(source, y, bounds))) return false;
    }
    return true;
}

fn unchangedBlank(scope: Scope, bounds: columns.Span, y: usize, opposite: usize, rows: usize) bool {
    if (opposite >= scope.after.height) return true;
    const expected = rowRun(scope.before, y, bounds);
    var end = y + rows;
    while (end < scope.before.height and pixel_ops.sameRun(rowRun(scope.before, end, bounds), expected)) end += 1;
    if (end == scope.before.height) return trailingMargin(scope.after, bounds, expected, y, opposite, rows);
    if (end == y + rows and fixedLowerEdge(scope, bounds, expected, y, end)) return true;

    var first = y;
    while (first > 0 and pixel_ops.sameRun(rowRun(scope.before, first - 1, bounds), expected)) first -= 1;
    return interiorBlank(scope.after, bounds, expected, first, end, opposite -| (y - first)) or
        fixedUpperBar(scope, bounds, expected, first);
}

fn trailingMargin(after: Image, bounds: columns.Span, paint: []const Pixel, y: usize, opposite: usize, rows: usize) bool {
    return hasEqualRun(paint, after, bounds, y, opposite, rows);
}

fn fixedLowerEdge(scope: Scope, bounds: columns.Span, paint: []const Pixel, y: usize, end: usize) bool {
    return end < scope.after.height and
        pixel_ops.sameRun(rowRun(scope.before, end, bounds), rowRun(scope.after, end, bounds)) and
        hasEqualRun(paint, scope.after, bounds, y, y, end - y);
}

fn interiorBlank(after: Image, bounds: columns.Span, paint: []const Pixel, first: usize, end: usize, opposite: usize) bool {
    // Matching only the unpaired portion could hide space actually removed
    // between two lines of content. Match the whole interior run.
    return hasEqualRun(paint, after, bounds, first, opposite, end - first);
}

fn fixedUpperBar(scope: Scope, bounds: columns.Span, paint: []const Pixel, first: usize) bool {
    if (first < min_bar_rows or first >= scope.after.height or
        !pixel_ops.sameRun(paint, rowRun(scope.after, first, bounds)) or
        !blankBand(scope.before, first - min_bar_rows, min_bar_rows, bounds)) return false;
    // A viewport bar reaches the top. Check its paint at both margins so
    // icons and lettering can interrupt the interior of the bar.
    const left = bounds.left;
    const right = left + bounds.width - 1;
    const bar = scope.before.row(first - 1)[left];
    for (0..first) |y| {
        const a = scope.before.row(y);
        const z = scope.after.row(y);
        if (!pixel_ops.same(a[left], bar) or !pixel_ops.same(a[right], bar) or
            !pixel_ops.same(z[left], bar) or !pixel_ops.same(z[right], bar)) return false;
    }
    return true;
}

fn rowRun(image: Image, y: usize, bounds: columns.Span) []const Pixel {
    return image.row(y)[bounds.left..][0..bounds.width];
}

fn hasEqualRun(expected: []const Pixel, image: Image, bounds: columns.Span, y: usize, opposite: usize, needed: usize) bool {
    const start = @min(y, opposite);
    const end = @min(image.height, @max(y, opposite) + needed);
    var run: usize = 0;
    for (start..end) |row| {
        const paint = rowRun(image, row, bounds);
        run = if (pixel_ops.sameRun(expected, paint)) run + 1 else 0;
        if (run == needed) return true;
    }
    return false;
}

fn expectEditAt(before: sample.Canvas, after: sample.Canvas, x: usize, y: usize, max_box_width: usize) !void {
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    for (result.regions) |region| {
        const box = region.after orelse continue;
        if (box.x <= @as(f64, @floatFromInt(x)) and box.right() > @as(f64, @floatFromInt(x)) and
            box.y <= @as(f64, @floatFromInt(y)) and box.bottom() > @as(f64, @floatFromInt(y)))
        {
            try std.testing.expect(box.width <= @as(f64, @floatFromInt(max_box_width)));
            return;
        }
    }
    return error.MissingEdit;
}

fn comparePair(allocator: Allocator, before: Image, after: Image) !void {
    const result = try compare(allocator, before, after, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(values.Kind.inserted, result.regions[0].kind);
}
fn checkTallInsertion(height: usize, inserted: usize, viewport: enum { fixed, growing }) !void {
    const at = 64;
    const old_height = if (viewport == .fixed) height else height - inserted;
    const old = try std.testing.allocator.alloc(values.Pixel, old_height);
    defer std.testing.allocator.free(old);
    const new = try std.testing.allocator.alloc(values.Pixel, height);
    defer std.testing.allocator.free(new);
    for (old, 0..) |*pixel, row| {
        pixel.* = .{ @intCast(row % 256), @intCast(row / 256), 0, 255 };
    }
    @memcpy(new[0..at], old[0..at]);
    @memset(new[at..][0..inserted], .{ 0, 0, 255, 255 });
    @memcpy(new[at + inserted ..], old[at .. height - inserted]);
    const result = try compare(
        std.testing.allocator,
        .{ .width = 1, .height = old.len, .pixels = old },
        .{ .width = 1, .height = height, .pixels = new },
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(values.Kind.inserted, result.regions[0].kind);
    try std.testing.expectEqual(Box.fromPixels(0, at - region_padding, 1, inserted + 2 * region_padding), result.regions[0].after.?);
}

fn compareCanvases(before: sample.Canvas, after: sample.Canvas, scale: f64) !Comparison {
    return compare(std.testing.allocator, before.view, after.view, .{ .scale = .{ .factor = scale } });
}

fn check(before: sample.Canvas, after: sample.Canvas, scale: f64, expected: []const Region) !void {
    const actual = try compareCanvases(before, after, scale);
    defer actual.deinit(std.testing.allocator);
    try sample.checkRegions(actual.regions, expected);
}

fn checkInsertion(before: sample.Canvas, after: sample.Canvas, expected: Box) !void {
    try check(before, after, 1, &.{.{ .after = expected }});
    try check(after, before, 1, &.{.{ .before = expected }});
}

fn count(before: sample.Canvas, after: sample.Canvas, expected: usize) !void {
    const actual = try compareCanvases(before, after, 1);
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, actual.regions.len);
}

test "card corner edits never align their narrow border columns as moves" {
    const before = try sample.Canvas.init(800, 600);
    defer before.deinit();
    const after = try sample.Canvas.init(800, 600);
    defer after.deinit();
    @memset(before.pixels, .{ 245, 245, 247, 255 });
    @memset(after.pixels, .{ 245, 245, 247, 255 });
    for ([_]usize{ 60, 300 }) |y| {
        sample.strokeRounded(before, y, 4);
        sample.strokeRounded(after, y, 16);
        // A separator can have the same ink as the outline.
        if (y == 300) {
            const edge = before.row(y)[480];
            before.fill(222, y + 99, 536, 2, edge);
            after.fill(222, y + 99, 536, 2, edge);
        }
    }
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for (result.regions) |edit| {
        try std.testing.expectEqual(Kind.changed, edit.kind);
        try std.testing.expectEqual(edit.before, edit.after);
    }
}

test "one line of text joins its changed runs across word space" {
    const before = try sample.Canvas.init(120, 100);
    defer before.deinit();
    const after = try sample.Canvas.init(120, 100);
    defer after.deinit();
    after.fill(12, 35, 14, 16, sample.inkShade(30, 4));
    after.fill(53, 35, 14, 16, sample.inkShade(30, 4));
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 18, 40, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 57, 40, .changed));
}

test "the exposed edges of a sideways card form one changed box" {
    const before = try sample.Canvas.init(150, 120);
    defer before.deinit();
    const after = try sample.Canvas.init(150, 120);
    defer after.deinit();
    before.fill(30, 25, 60, 70, .{ 85, 100, 145, 255 });
    after.fill(50, 25, 60, 70, .{ 85, 100, 145, 255 });
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .before, 36, 50, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 104, 50, .changed));
}

test "an interior blank run is ignored only if the layout retains its length" {
    const before = try sample.Canvas.init(64, 80);
    defer before.deinit();
    const after = try sample.Canvas.init(64, 80);
    defer after.deinit();
    const ink = sample.inkShade(32, 4);
    before.fill(10, 15, 24, 5, ink);
    before.fill(10, 32, 30, 5, ink);
    after.fill(10, 20, 24, 5, ink);
    after.fill(10, 37, 30, 5, ink);
    const span: columns.Span = .{ .left = 0, .width = 64 };
    const scope: Scope = .{ .before = before.view, .after = after.view, .span = span, .bounds = span };
    try std.testing.expect(unchangedBlank(scope, span, 20, 25, 8));
    after.fill(10, 31, 30, 6, ink);
    try std.testing.expect(!unchangedBlank(scope, span, 20, 25, 8));
}

test "blank space above a fixed input bar does not inherit unrelated sidebar paint" {
    const before = try sample.Canvas.init(144, 180);
    defer before.deinit();
    const after = try sample.Canvas.init(144, 180);
    defer after.deinit();
    before.fill(28, 60, 90, 10, sample.inkShade(32, 4));
    after.fill(28, 80, 90, 10, sample.inkShade(32, 4));
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(0, 30, 18, 130, sample.inkShade(96, 4));
        canvas.fill(20, 130, 110, 20, sample.inkShade(190, 4));
        canvas.line(30, 112, 135, 0, 32);
    }
    const scope: Scope = .{ .before = before.view, .after = after.view, .span = .{ .left = 24, .width = 96 }, .bounds = .{ .left = 0, .width = 144 } };
    var boxes: [2]regions.Candidate = undefined;
    var collector: Collector = .{ .boxes = &boxes, .gap_px = 0, .max_gap_px = 144 };
    var mask: [96 * 20]regions.Cell = undefined;
    var seeds: [20]u32 = undefined;
    unpaired(&collector, scope, .{ .mask = &mask, .seeds = &seeds }, .{ .side = .before, .y = 110, .count = 20, .opposite = 130 });
    try std.testing.expectEqual(@as(usize, 0), collector.len);
}

test "short scrolling clips blank space behind the fixed header" {
    const before = try sample.Canvas.init(180, 250);
    defer before.deinit();
    const after = try sample.Canvas.init(180, 250);
    defer after.deinit();
    for (0..5) |i| before.line(10, 165, 44 + i * 30, i, 40);
    after.copyRows(40, before, 43, 223);
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(0, 0, 180, 40, .{ 220, 228, 240, 255 });
        canvas.fill(0, 220, 180, 30, .{ 235, 225, 220, 255 });
        canvas.line(12, 150, 226, 20, 40);
    }
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.regions.len);
    try std.testing.expect(result.moves.len != 0);
}

test "an interior divider does not hide a shortened spacer" {
    const before = try sample.Canvas.init(400, 480);
    defer before.deinit();
    for (0..3) |i| before.line(12, 208, 18 + i * 18, i, 40);
    before.fill(0, 80, 400, 2, sample.inkShade(220, 4));
    for (0..8) |i| before.line(12, 208, 122 + i * 18, 12 + i, 40);
    for ([_]usize{ 20, 30 }) |removed| {
        const after = try sample.Canvas.init(400, 480);
        defer after.deinit();
        after.copyRows(0, before, 0, 82);
        after.copyRows(122 - removed, before, 122, before.view.height);
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.regions.len);
        try std.testing.expectEqual(Kind.removed, result.regions[0].kind);
        try std.testing.expect(result.moves.len != 0);
    }
}

test "a stationary column divider separates two same-line changes" {
    const before = try sample.Canvas.init(280, 100);
    defer before.deinit();
    const after = try sample.Canvas.init(280, 100);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(0, 0, 110, 100, .{ 240, 242, 246, 255 });
        canvas.fill(110, 0, 1, 100, sample.inkShade(205, 4));
    }
    before.fill(92, 28, 11, 16, sample.inkShade(50, 4));
    after.fill(92, 28, 11, 16, sample.inkShade(110, 4));
    before.fill(126, 28, 25, 16, sample.inkShade(40, 4));
    after.fill(126, 28, 25, 16, sample.inkShade(95, 4));
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for (result.regions) |region| try std.testing.expectEqual(Kind.changed, region.kind);
}

test "a blank sidebar group keeps a new mark stationary beside inserted cards" {
    const before = try sample.Canvas.init(600, 500);
    defer before.deinit();
    const after = try sample.Canvas.init(600, 500);
    defer after.deinit();
    const sidebar: Pixel = .{ 235, 238, 245, 255 };
    before.fill(0, 0, 180, 500, sidebar);
    for (0..10) |i_row| before.line(12, 55, 20 + 36 * i_row, 19 + i_row, 40);
    sample.fillCardList(before, null);
    for ([_][2]usize{ .{ 60, 92 }, .{ 130, 122 }, .{ 160, 142 }, .{ 130, 205 }, .{ 160, 390 } }) |position| {
        const mark_x, const mark_y = position;
        @memcpy(after.pixels, before.pixels);
        after.fill(180, 0, 420, 500, @splat(255));
        sample.fillCardList(after, 3);
        after.fill(mark_x, mark_y, 17, 17, .{ 200, 40, 40, 255 });

        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.regions.len);
        try std.testing.expect(sample.hasRegion(result.regions, .before, mark_x + 4, mark_y + 6, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, mark_x + 4, mark_y + 6, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 560, 150, .inserted));
        try std.testing.expectEqual(@as(usize, 1), result.moves.len);
        try std.testing.expectEqual(@as(usize, 40), result.moves[0].after.y - result.moves[0].before.y);
        try std.testing.expect(result.moves[0].x.count() >= 180);
        try std.testing.expect(result.moves[0].width.count() >= 380);
    }
}

test "the closing rule of an inset list hides cards pushed past its edge" {
    const before = try sample.Canvas.init(600, 400);
    defer before.deinit();
    const after = try sample.Canvas.init(600, 400);
    defer after.deinit();
    const border: Pixel = .{ 20, 20, 20, 255 };
    before.fill(179, 49, 242, 1, border);
    before.fill(179, 350, 242, 1, border);
    before.fill(179, 49, 1, 302, border);
    before.fill(420, 49, 1, 302, border);
    for (0..8) |i_row| {
        before.line(12, 145, 12 + 40 * i_row, i_row, 30);
        before.line(450, 575, 12 + 40 * i_row, i_row + 1, 30);
    }
    @memcpy(after.pixels, before.pixels);
    for (0..10) |i_row| {
        const y = 64 + i_row * 30;
        if (i_row < 9) sample.paintCard(before, 190, y, 220, 23, i_row);
        sample.paintCard(after, 190, y, 220, 23, if (i_row == 2) 90 else i_row - @intFromBool(i_row > 2));
    }
    after.copyRows(350, before, 350, 400);
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 385, 137, .inserted));
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 30), result.moves[0].after.y - result.moves[0].before.y);
}

test "an equal unpaired bottom margin does not produce a removal" {
    for ([_]Pixel{ @splat(255), .{ 18, 18, 22, 255 } }) |color| {
        const before = try sample.Canvas.init(64, 40);
        defer before.deinit();
        const after = try sample.Canvas.init(64, 50);
        defer after.deinit();
        @memset(before.pixels, color);
        @memset(after.pixels, .{ 96, 67, 77, 255 });
        after.fill(0, 36, 64, 6, color);
        const scope: Scope = .{
            .before = before.view,
            .after = after.view,
            .span = .{ .left = 0, .width = 64 },
            .bounds = .{ .left = 0, .width = 64 },
        };
        var boxes: [2]regions.Candidate = undefined;
        var collector: Collector = .{ .boxes = &boxes, .gap_px = 0, .max_gap_px = 64 };
        var mask: [64 * 6]regions.Cell = undefined;
        var seeds: [6]u32 = undefined;
        const scratch: Scratch = .{ .mask = &mask, .seeds = &seeds };
        const margin: Unpaired = .{ .side = .before, .y = 34, .count = 6, .opposite = 44 };
        unpaired(&collector, scope, scratch, margin);
        try std.testing.expectEqual(@as(usize, 0), collector.len);
        @memset(after.pixels, .{ 96, 67, 77, 255 });
        unpaired(&collector, scope, scratch, margin);
        try std.testing.expectEqual(@as(usize, 1), collector.len);
    }
}

test "an aligned blank tail contributes no phantom move" {
    const before = try sample.Canvas.init(64, 32);
    defer before.deinit();
    const after = try sample.Canvas.init(64, 64);
    defer after.deinit();
    const span: columns.Span = .{ .left = 0, .width = 64 };
    const scope: Scope = .{ .before = before.view, .after = after.view, .span = span, .bounds = span };
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

test "replacement regions suppress enclosed and sub-line displacement" {
    const before = try sample.Canvas.init(120, 140);
    defer before.deinit();
    const after = try sample.Canvas.init(120, 140);
    defer after.deinit();
    before.fill(10, 20, 50, 34, sample.inkShade(32, 4));
    after.fill(10, 20, 50, 34, sample.inkShade(72, 4));
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    var moves = [_]values.Move{
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 61, .height = 3 }, .after = .{ .y = 70, .height = 3 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 62, .height = 10 }, .after = .{ .y = 73, .height = 10 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 27, .height = 10 }, .after = .{ .y = 34, .height = 10 }, .x = .init(80), .width = .init(40) },
        .{ .before = .{ .y = 49, .height = 12 }, .after = .{ .y = 50, .height = 12 }, .x = .init(10), .width = .init(50) },
        .{ .before = .{ .y = 4, .height = 125 }, .after = .{ .y = 6, .height = 125 }, .x = .init(10), .width = .init(50) },
    };
    try std.testing.expectEqual(@as(usize, 3), regions.keepMoves(&moves, result.regions, .one, Scale.one.devicePixels(scroll_shift)));
    try std.testing.expectEqual(@as(usize, 62), moves[0].before.y);
    try std.testing.expectEqual(@as(usize, 80), moves[1].x.count());
}

test "growth pairs an edited row head with its displaced body" {
    const before = try sample.Canvas.init(200, 180);
    defer before.deinit();
    const after = try sample.Canvas.init(200, 220);
    defer after.deinit();
    before.fill(10, 70, 22, 29, .{ 95, 125, 180, 255 });
    before.fill(100, 74, 16, 12, sample.inkShade(45, 4));
    before.fill(30, 128, 28, 24, .{ 180, 65, 114, 255 });
    after.copyRows(0, before, 0, 70);
    after.copyRows(110, before, 70, before.view.height);
    after.fill(48, 72, 105, 29, .{ 210, 120, 90, 255 });
    after.fill(100, 114, 16, 12, sample.inkShade(115, 4));
    var old: [180]u64 = undefined;
    var new: [220]u64 = undefined;
    row_diff.keys(before.view, 0, 200, &old);
    row_diff.keys(after.view, 0, 200, &new);
    var bands = [_]row_diff.Band{
        .{ .before = 0, .after = 0, .removed = 70, .added = 70 },
        .{ .before = 70, .after = 70, .removed = 32, .added = 72 },
        .{ .before = 102, .after = 142, .removed = 78, .added = 78 },
    };
    row_diff.refineElements(&old, &new, .{ .scroll = 2, .replacement = 24, .images = .{ before.view, after.view }, .width = 200 }, &bands);
    try std.testing.expectEqual(@as(usize, 0), bands[1].removed);
    try std.testing.expectEqual(@as(usize, 40), bands[1].added);
    try std.testing.expectEqual(@as(usize, 110), bands[2].after);
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

test "a 20,000-row image keeps a 5,000-row insertion near the top" {
    try checkTallInsertion(20_000, 5_000, .growing);
}

test "a fixed-height page aligns a large insertion and corresponding clipping" {
    const inserted = row_diff.max_edits / 4 + 2;
    try checkTallInsertion(3 * inserted, inserted, .fixed);
}

test "one changed block has one padded box" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(10, 12);
    const b = sample.paddedBox(10, 12, sample.block_size, sample.block_size);
    try check(before, after, 1, &.{.{ .before = b, .after = b }});
}

test "two distant blocks are numbered top to bottom" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(40, 40);
    after.block(10, 10);
    const first = sample.paddedBox(10, 10, sample.block_size, sample.block_size);
    const second = sample.paddedBox(40, 40, sample.block_size, sample.block_size);
    try check(before, after, 1, &.{ .{ .before = first, .after = first }, .{ .before = second, .after = second } });
}

test "nearby blocks merge across the allowed gap" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(10, 10);
    after.block(10 + sample.block_size + test_gap, 10);
    const b = sample.paddedBox(10, 10, 2 * sample.block_size + test_gap, sample.block_size);
    try check(before, after, 1, &.{.{ .before = b, .after = b }});
}

test "merging joins a chain of nearby blocks" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    for (0..3) |i| after.block(10 + i * (sample.block_size + test_gap), 10);
    try count(before, after, 1);
}

test "shot scale joins paragraph glyphs but leaves a separate button" {
    const scale = 3;
    const before = try sample.Canvas.init(300, 300);
    defer before.deinit();
    const after = try sample.Canvas.init(300, 300);
    defer after.deinit();
    const size = sample.block_size * scale;
    const start = 10 * scale;
    const step = size + test_gap * scale;
    for (0..2) |row| for (0..4) |column| after.red(start + column * step, start + row * step, size, size, 0);
    after.red(start, start + step + size + 16 * scale, 30 * scale, size, 0);
    const result = try compareCanvases(before, after, scale);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    try std.testing.expectEqual(@as(f64, 3 * step + size + 2 * region_padding * scale), result.regions[0].after.?.width);
    try std.testing.expectEqual(@as(f64, step + size + 2 * region_padding * scale), result.regions[0].after.?.height);
}

test "scattered changes are coalesced to at most eight regions" {
    const spacing = test_gap * 4;
    const side = max_regions + 1;
    const size = (side + 1) * spacing;
    const before = try sample.Canvas.init(size, size);
    defer before.deinit();
    const after = try sample.Canvas.init(size, size);
    defer after.deinit();
    for (1..side + 1) |row| for (1..side + 1) |column| after.block(column * spacing, row * spacing);
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.regions.len > 0 and result.regions.len <= max_regions);
}

test "one-step noise and two-step red variation are ignored" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.pixels[0][0] = 254;
    try count(before, after, 0);
    for (after.pixels) |*pixel| pixel[0] = 253;
    try count(before, after, 0);
}

test "eight-step token colour and grey block or stroke changes are detected" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    before.fill(10, 10, sample.block_size, sample.block_size, .{ 0x63, 0x65, 0x69, 255 });
    after.fill(10, 10, sample.block_size, sample.block_size, .{ 0x5b, 0x5d, 0x61, 255 });
    try count(before, after, 1);
    for ([_]usize{ 6, 2 }) |width| {
        before.fill(10, 10, width, 6, .{ 100, 100, 100, 255 });
        after.fill(10, 10, width, 6, .{ 92, 92, 92, 255 });
        try count(before, after, 1);
        @memset(before.pixels, .{ 255, 255, 255, 255 });
        @memset(after.pixels, .{ 255, 255, 255, 255 });
    }
}

test "one-pixel sideways shift of an anti-aliased sample.diagonal is ignored" {
    const before = try sample.diagonal(0);
    defer before.deinit();
    const after = try sample.diagonal(1);
    defer after.deinit();
    // An eight-step grey change already clears the YIQ threshold.
    for (before.pixels, after.pixels) |old, new| {
        if (@max(old[0], new[0]) - @min(old[0], new[0]) >= 8) break;
    } else return error.NoHighContrastPixels;
    try count(before, after, 0);
}

test "thin aliased diagonals, dotted lines and crosses survive grouping" {
    const before = try sample.Canvas.init(200, 200);
    defer before.deinit();
    for ([_]enum { diagonal, dots, cross }{ .diagonal, .dots, .cross }) |mark| {
        const after = try sample.Canvas.init(200, 200);
        defer after.deinit();
        const box = switch (mark) {
            .diagonal => diagonal: {
                for (50..90) |p| after.row(p)[p] = .{ 0, 0, 0, 255 };
                break :diagonal sample.paddedBox(50, 50, 40, 40);
            },
            .dots => dots: {
                for (0..40) |p| after.row(100)[50 + 2 * p] = .{ 0, 0, 0, 255 };
                break :dots sample.paddedBox(50, 100, 79, 1);
            },
            .cross => cross: {
                for (0..7) |p| {
                    after.row(120 + p)[120 + p] = .{ 220, 0, 0, 255 };
                    after.row(120 + p)[126 - p] = .{ 220, 0, 0, 255 };
                }
                break :cross sample.paddedBox(120, 120, 7, 7);
            },
        };
        try check(before, after, 1, &.{.{ .before = box, .after = box }});
    }
}

test "weak edge recolours need cardinal support before sample.diagonal grouping" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    @memset(before.pixels, sample.inkShade(24, 4));
    @memset(after.pixels, sample.inkShade(24, 4));
    for (16..32) |p| {
        before.row(p)[p] = sample.inkShade(120, 4);
        after.row(p)[p] = sample.inkShade(128, 4);
        before.row(p)[p + 1] = sample.inkShade(240, 4);
        after.row(p)[p + 1] = sample.inkShade(240, 4);
    }
    try count(before, after, 0);

    before.fill(36, 16, 4, 1, sample.inkShade(120, 4));
    after.fill(36, 16, 4, 1, sample.inkShade(128, 4));
    const box = sample.paddedBox(36, 16, 4, 1);
    try check(before, after, 1, &.{.{ .before = box, .after = box }});
}

test "isolated low-amplitude specks stay below the reporting minimum" {
    const side = 240;
    const before = try sample.Canvas.init(side, side);
    defer before.deinit();
    @memset(before.pixels, sample.inkShade(200, 4));
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    const after = try sample.Canvas.init(side, side);
    defer after.deinit();
    for ([_]u8{ 2, 4 }) |amplitude| {
        for ([_]usize{ 3, 6, 10, 14, 24 }) |spacing| {
            @memcpy(after.pixels, before.pixels);
            var y: usize = 0;
            while (y < side) : (y += spacing) {
                var x = rand.uintLessThan(usize, spacing);
                while (x < side) : (x += spacing) {
                    const row = y + rand.uintLessThan(usize, @min(spacing, side - y));
                    after.row(row)[x] = sample.inkShade(200 + amplitude, 4);
                }
            }
            try count(before, after, 0);
        }
    }
}

test "recolouring diags, dots, stems and crosses preserves thin aliased marks" {
    const before = try sample.Canvas.init(200, 200);
    defer before.deinit();
    const after = try sample.Canvas.init(200, 200);
    defer after.deinit();
    for ([_]enum { diagonal, dots, stem, cross, red }{ .diagonal, .dots, .stem, .cross, .red }) |mark| {
        for ([_]u8{ 20, 40, 60, 80, 100 }) |tone| {
            @memset(before.pixels, @splat(255));
            @memset(after.pixels, @splat(255));
            const old: Pixel = if (mark == .red) .{ 220, 0, 0, 255 } else sample.inkShade(0, 4);
            const new: Pixel = if (mark == .red) .{ 220, 70, 0, 255 } else sample.inkShade(tone, 4);
            const points: usize = if (mark == .cross) 7 else 40;
            for (0..points) |i| {
                const pos: [2]usize = switch (mark) {
                    .diagonal, .red, .cross => .{ 50 + i, 50 + i },
                    .dots => .{ 50 + 2 * i, 50 },
                    .stem => .{ 50, 50 + i },
                };
                before.row(pos[1])[pos[0]] = old;
                after.row(pos[1])[pos[0]] = new;
                if (mark == .cross) {
                    before.row(pos[1])[56 - i] = old;
                    after.row(pos[1])[56 - i] = new;
                }
            }
            const result = try compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), result.regions.len);
            try std.testing.expect(sample.hasRegion(result.regions, .after, 50, 50, .changed));
            if (mark == .red) break;
        }
    }
}

test "noise clusters do not reach the minimum by widening the merge gap" {
    const before = try sample.Canvas.init(200, 64);
    defer before.deinit();
    const after = try sample.Canvas.init(200, 64);
    defer after.deinit();
    for (0..10) |i| after.red(6 + i * 20, 20, min_region_pixels - 1, 1, 0);
    try count(before, after, 0);
}

test "high-contrast specks below the minimum are ignored" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.red(10, 10, min_region_pixels - 1, 1, 0);
    try count(before, after, 0);
}

test "substantial changes in each RGBA channel are detected" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    for (0..4) |channel| {
        var color: Pixel = @splat(255);
        color[channel] = 223;
        after.fill(10, 10, sample.block_size, sample.block_size, color);
        try count(before, after, 1);
    }
}

test "taller after images mark added rows and reversal marks removed rows" {
    const before = try sample.Canvas.init(20, 20);
    defer before.deinit();
    const after = try sample.Canvas.init(20, 30);
    defer after.deinit();
    try checkInsertion(before, after, Box.fromPixels(0, 20 - region_padding, 20, 10 + region_padding));
}

test "added columns and changed overlap survive different strides" {
    const before = try sample.Canvas.init(40, 40);
    defer before.deinit();
    const after = try sample.Canvas.init(50, 40);
    defer after.deinit();
    after.block(10, 10);
    const mark = sample.paddedBox(10, 10, sample.block_size, sample.block_size);
    try check(before, after, 1, &.{ .{ .after = Box.fromPixels(40 - region_padding, 0, 10 + region_padding, 40) }, .{ .before = mark, .after = mark } });
}

test "size changes survive the noise minimum and padding clips at canvas edges" {
    const tiny = try sample.Canvas.init(1, 1);
    defer tiny.deinit();
    const tall = try sample.Canvas.init(1, 2);
    defer tall.deinit();
    try check(tiny, tall, 1, &.{.{ .after = Box.fromPixels(0, 0, 1, 2) }});
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(0, 0);
    const mark = Box.fromPixels(0, 0, sample.block_size + region_padding, sample.block_size + region_padding);
    try check(before, after, 1, &.{.{ .before = mark, .after = mark }});
}

test "middle insertions box only new content with and without image growth" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    before.red(10, 8, 18, 4, 0);
    before.red(28, 40, 12, 4, 0);
    for ([_][2]usize{ .{ 0, 2 }, .{ 0, 6 }, .{ 6, 6 } }) |p| {
        const after = try before.insert(24, p[1], p[0]);
        defer after.deinit();
        after.red(15, 24, 20, p[1], 0);
        try checkInsertion(before, after, sample.paddedBox(15, 24, 20, p[1]));
    }
}

test "viewport insertion ignores clipped content and its reversal reports revealed rows" {
    const before = try sample.Canvas.init(80, 120);
    defer before.deinit();
    before.red(4, 0, 60, 10, 0);
    before.red(8, 23, 20, 6, 0);
    before.red(27, 38, 16, 8, 0);
    before.red(22, 78, 31, 8, 0);
    before.red(12, 110, 14, 10, 0);
    for ([_]usize{ 0, 2 }) |scroll| {
        const after = try sample.Canvas.init(80, 120);
        defer after.deinit();
        after.copyRows(0, before, 0, 10);
        after.copyRows(10 + scroll, before, 10, 60);
        after.copyRows(68 + scroll, before, 60, 112 - scroll);
        after.red(58, 10, 10, scroll, 0);
        after.red(34, 60 + scroll, 20, 8, 0);
        const inserted = sample.paddedBox(34, 60 + scroll, 20, 8);
        try check(before, after, 1, &.{.{ .after = inserted }});
        try check(after, before, 1, &.{
            .{ .before = inserted },
            .{ .after = Box.fromPixels(8, 108 - scroll, 22, 12 + scroll) },
        });
    }
}

test "insertion above a fixed footer preserves a narrow edit inside the footer" {
    const before = try sample.Canvas.init(780, 1688);
    defer before.deinit();
    const after = try sample.Canvas.init(780, 1688);
    defer after.deinit();
    before.fill(32, 49, 670, 35, sample.inkShade(80, 4));
    before.fill(100, 190, 130, 11, sample.inkShade(100, 4));
    before.fill(100, 401, 166, 19, sample.inkShade(100, 4));
    before.fill(308, 503, 155, 14, sample.inkShade(100, 4));
    before.fill(100, 600, 486, 122, sample.inkShade(220, 4));
    before.fill(40, 1487, 600, 116, sample.inkShade(230, 4));
    before.fill(660, 1496, 88, 88, sample.inkShade(205, 4));
    before.fill(620, 1614, 100, 26, sample.inkShade(100, 4));
    after.copyRows(0, before, 0, 450);
    after.copyRows(520, before, 450, 1417);
    after.copyRows(1487, before, 1487, 1688);
    after.fill(257, 476, 266, 18, sample.inkShade(90, 4));
    after.fill(660, 1496, 88, 88, sample.inkShade(24, 4));
    const result = try compareCanvases(before, after, 2);
    defer result.deinit(std.testing.allocator);
    const button = Box.fromPixels(652, 1488, 104, 104);
    try sample.checkRegions(result.regions, &.{
        .{ .after = Box.fromPixels(249, 468, 282, 34) },
        .{ .before = button, .after = button },
    });
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    const move = result.moves[0];
    try std.testing.expectEqual(@as(usize, 70), move.after.y - move.before.y);
    try std.testing.expectEqual(@as(usize, 1487), move.after.y + move.after.height);
    try check(after, before, 2, &.{
        .{ .before = Box.fromPixels(249, 468, 282, 34) },
        .{ .before = button, .after = button },
    });
}

test "a fixed footer hides clipped cards with either palette" {
    for ([_][4]u8{ .{ 18, 32, 26, 57 }, .{ 246, 255, 255, 222 } }) |palette| {
        const before = try sample.Canvas.init(240, 320);
        defer before.deinit();
        const after = try sample.Canvas.init(240, 320);
        defer after.deinit();
        @memset(before.pixels, sample.inkShade(palette[0], 4));
        before.fill(0, 0, 240, 32, sample.inkShade(palette[2], 4));
        before.fill(0, 31, 240, 2, sample.inkShade(palette[3], 4));
        for (0..5) |i_card| {
            const y = 40 + 47 * i_card;
            before.fill(44, y, 140 - 8 * i_card, 37, sample.inkShade(palette[1], 4));
            before.line(52, 169, y + 7, i_card, 110);
        }
        before.fill(0, 270, 240, 50, sample.inkShade(palette[2], 4));
        before.fill(0, 270, 240, 2, sample.inkShade(palette[3], 4));
        before.line(16, 210, 292, 77, 140);
        after.copyRows(0, before, 0, 134);
        after.copyRows(181, before, 134, 223);
        after.copyRows(270, before, 270, 320);
        after.fill(0, 134, 240, 47, sample.inkShade(palette[0], 4));
        after.fill(44, 134, 140, 37, sample.inkShade(palette[1], 4));
        after.line(52, 169, 141, 22, 110);

        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.regions.len);
        try std.testing.expectEqual(Kind.inserted, result.regions[0].kind);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 82, 135, .inserted));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 82, 169, .inserted));
    }
}

test "repeated row tops align at the inserted row and keep its columns together" {
    const before = try sample.Canvas.init(260, 240);
    defer before.deinit();
    for (0..4) |i_row| {
        const y = 10 + 48 * i_row;
        before.fill(8, y, 28, 34, sample.inkShade(80, 4));
        before.fill(76, y, 100, 12, sample.inkShade(220, 4));
        before.line(77, 169, y + 12, i_row, 40);
        before.fill(224, y + 12, 12, 12, sample.inkShade(60 + @as(u8, @intCast(21 * i_row)), 4));
    }
    const after = try before.insert(58, 48, 48);
    defer after.deinit();
    after.copyRows(58, before, 58, 70);
    after.fill(8, 70, 28, 22, sample.inkShade(80, 4));
    after.line(76, 156, 70, 123, 40);
    after.fill(224, 70, 12, 12, sample.inkShade(123, 4));

    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try sample.checkRegions(result.regions, &.{.{ .after = sample.paddedBox(8, 58, 228, 34) }});
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 48), result.moves[0].after.y - result.moves[0].before.y);
}

test "exact panel shifts outrank repeated stationary paint" {
    const before = try sample.Canvas.init(320, 320);
    defer before.deinit();
    const after = try sample.Canvas.init(320, 320);
    defer after.deinit();
    const paint = sample.inkShade(40, 4);
    before.fill(80, 40, 176, 240, paint);
    before.fill(81, 242, 174, 38, sample.inkShade(55, 4));
    before.fill(92, 251, 15, 7, sample.inkShade(190, 4));
    before.fill(100, 67, 23, 5, sample.inkShade(180, 4));
    before.fill(94, 110, 100, 4, sample.inkShade(155, 4));
    for (110..114) |y| before.fill(104 + y % 3, y, 8, 1, sample.inkShade(210, 4));
    @memcpy(after.pixels, before.pixels);
    after.fill(80, 110, 176, 26, paint);
    after.fill(100, 110, 94, 4, sample.inkShade(130, 4));
    after.copyColumns(before, 80, 256, 110, 216, 136);

    const result = try compareCanvases(before, after, 2);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 150, 112, .inserted));
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 26), result.moves[0].after.y - result.moves[0].before.y);
    try std.testing.expect(result.moves[0].width.count() < before.view.width);
}

test "an inserted row precedes the moved recolour in an ambiguous alignment" {
    const before = try sample.Canvas.init(120, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(120, 160);
    defer after.deinit();
    before.fill(30, 24, 70, 56, .{ 180, 180, 184, 255 });
    after.fill(40, 24, 50, 10, .{ 112, 141, 168, 255 });
    after.fill(30, 44, 70, 56, .{ 64, 124, 202, 255 });
    before.line(26, 112, 91, 4, 35);
    after.copyRows(110, before, 90, 130);
    var old_keys: [160]u64 = undefined;
    var new_keys: [160]u64 = undefined;
    row_diff.keys(before.view, 0, 120, &old_keys);
    row_diff.keys(after.view, 0, 120, &new_keys);
    // The recolour changes its row hashes. The initial alignment consumes
    // part of its old silhouette as a positional edit, then catches up.
    var bands = [_]row_diff.Band{
        .{ .before = 20, .after = 20, .removed = 62, .added = 16 },
        .{ .before = 90, .after = 40, .removed = 0, .added = 70 },
        .{ .before = 90, .after = 110, .removed = 12, .added = 12 },
    };
    row_diff.refineElements(&old_keys, &new_keys, .{
        .scroll = 4,
        .replacement = 48,
        .images = .{ before.view, after.view },
        .width = 120,
    }, &bands);
    try std.testing.expectEqual(@as(usize, 0), bands[0].removed);
    try std.testing.expectEqual(@as(usize, 20), bands[0].added);
    try std.testing.expectEqual(@as(usize, 20), bands[1].before);
    try std.testing.expectEqual(@as(usize, 40), bands[1].after);
    try std.testing.expectEqual(@as(usize, 70), bands[1].removed);
    try std.testing.expectEqual(@as(usize, 70), bands[1].added);
}

test "subpixel glyph coverage changes preserve borders and pale recolours" {
    const before = try sample.Canvas.init(70, 56);
    defer before.deinit();
    const after = try sample.Canvas.init(70, 56);
    defer after.deinit();
    const background: Pixel = .{ 24, 26, 29, 255 };
    @memset(before.pixels, background);
    @memset(after.pixels, background);
    before.coverageGlyph(0);
    after.coverageGlyph(1);
    try check(before, after, 2, &.{});

    before.fill(4, 43, 14, 1, sample.inkShade(180, 4));
    after.fill(4, 43, 14, 2, sample.inkShade(180, 4));
    before.fill(52, 43, 10, 8, .{ 235, 236, 233, 255 });
    after.fill(52, 43, 10, 8, .{ 232, 231, 228, 255 });
    const result = try compareCanvases(before, after, 2);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 8, 44, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 56, 47, .changed));
}

test "stationary backdrop above a footer does not extend a mixed edit" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    const after = try sample.Canvas.init(240, 400);
    defer after.deinit();
    before.line(12, 209, 40, 27, 50);
    before.fill(34, 116, 158, 72, .{ 208, 210, 223, 255 });
    before.line(18, 187, 223, 65, 90);
    before.line(23, 210, 258, 70, 60);
    before.line(18, 197, 281, 73, 45);
    before.line(28, 216, 295, 55, 40);
    before.fill(0, 340, 240, 60, sample.inkShade(203, 4));
    before.line(12, 224, 370, 90, 60);
    after.copyRows(0, before, 0, 96);
    after.copyRows(136, before, 96, 280);
    after.copyRows(320, before, 320, 400);
    after.fill(76, 100, 112, 24, .{ 205, 119, 36, 255 });
    after.fill(34, 156, 158, 72, .{ 83, 113, 161, 255 });

    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 140, 110, .inserted));
    try std.testing.expect(!sample.hasRegion(result.regions, .after, 100, 325, null));
    for (result.regions) |region| if (region.after) |box| {
        try std.testing.expect(box.bottom() <= 320 + region_padding);
    };
}

test "an inserted row against repeated background is one-sided" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.init(64, 65);
    defer after.deinit();
    after.red(0, 24, 20, 1, 0);
    try check(before, after, 1, &.{.{ .after = Box.fromPixels(0, 24 - region_padding, 20 + region_padding, 1 + 2 * region_padding) }});
}

test "two-pixel vertical shift boxes the edited word and any revealed content" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    before.red(8, 0, 10, 4, 0);
    before.red(18, 20, 14, 4, 0);
    before.red(40, 40, 13, 4, 0);
    before.red(30, 60, 11, 4, 0);
    after.copyRows(2, before, 0, 62);
    after.red(32, 22, 3, 4, 0);
    const old = sample.paddedBox(32, 20, 3, 4);
    const new = sample.paddedBox(32, 22, 3, 4);
    try check(before, after, 1, &.{.{ .before = old, .after = new }});
    try check(after, before, 1, &.{
        .{ .before = new, .after = old },
        .{ .after = Box.fromPixels(26, 58, 19, 6) },
    });
}

test "blank rows change layout with and without image growth" {
    const before = try sample.Canvas.init(80, 120);
    defer before.deinit();
    before.red(8, 10, 24, 7, 0);
    before.red(20, 48, 28, 6, 0);
    before.red(12, 84, 18, 7, 0);
    for ([_]usize{ 0, 12 }) |growth| {
        const after = try before.insert(48, 12, growth);
        defer after.deinit();
        try checkInsertion(before, after, Box.fromPixels(0, 48 - region_padding, 80, 12 + 2 * region_padding));
    }
}

test "solid eight-row band between distinct backgrounds gets a full-width box" {
    const before = try sample.Canvas.init(80, 120);
    defer before.deinit();
    before.red(0, 0, 80, 40, 235);
    before.red(0, 40, 80, 80, 55);
    before.red(11, 68, 21, 7, 0);
    const after = try before.insert(40, 8, 8);
    defer after.deinit();
    after.red(0, 40, 80, 8, 130);
    try check(before, after, 1, &.{.{ .after = Box.fromPixels(0, 40 - region_padding, 80, 8 + 2 * region_padding) }});
}

test "small CSS dividers above and below stationary headers count as scroll" {
    const before = try sample.Canvas.init(80, 120);
    defer before.deinit();
    before.red(4, 0, 60, 10, 0);
    before.red(12, 35, 27, 6, 0);
    before.red(20, 72, 36, 9, 0);
    for ([_][3]usize{ .{ 0, 1, 1 }, .{ 10, 2, 2 } }) |p| {
        const rows = p[1] * p[2];
        const after = try before.insert(p[0], rows, 0);
        defer after.deinit();
        after.red(0, p[0], 80, rows, 140);
        try check(before, after, @floatFromInt(p[2]), &.{});
        try check(after, before, @floatFromInt(p[2]), &.{});
    }
}

test "large viewport insertion still aligns" {
    const before = try sample.Canvas.init(60, 1400);
    defer before.deinit();
    sample.paintBands(before, 0, 60);
    const after = try before.insert(100, 560, 0);
    defer after.deinit();
    after.red(5, 100, 40, 560, 90);
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.inserted, result.regions[0].kind);
    const found = result.regions[0].after.?;
    try std.testing.expect(found.y <= 100 and found.y + found.height >= 660 and found.height < 560 + 4 * region_padding);
}

test "stationary sidebar with a small colour difference does not prevent a 606-pixel column shift" {
    const height = 1400;
    const at = 80;
    const shift = 606;
    const before = try sample.Canvas.init(100, height);
    defer before.deinit();
    const after = try sample.Canvas.init(100, height);
    defer after.deinit();
    for (0..height) |y| before.red(2, y, 10, 1, @intCast((y * 7) % 250));
    sample.paintBands(before, 30, 70);
    @memcpy(after.pixels, before.pixels);
    for (0..height) |y| after.row(y)[2][1] = 254;
    for (at..height) |y| {
        if (y < at + shift) {
            @memset(after.row(y)[20..], .{ 255, 255, 255, 255 });
        } else @memcpy(after.row(y)[20..], before.row(y - shift)[20..]);
    }
    after.red(35, 90, 40, 40, 90);
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.inserted, result.regions[0].kind);
    const box = result.regions[0].after.?;
    try std.testing.expect(box.x >= 20 and box.y >= at - region_padding and box.bottom() <= at + shift + region_padding);
}

test "unrelated tall shots beyond the budget compare by position" {
    const before = try sample.Canvas.init(80, 6000);
    defer before.deinit();
    const after = try sample.Canvas.init(80, 6000);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }, [_]usize{ 3, 12 }, [_]usize{ 100, 102 }) |shot, x, y| {
        shot.red(x, 0, 4, y, 0);
        shot.red(55, y, 10, 6, 0);
        shot.red(x, y + 6, 4, 6000 - y - 6, 0);
    }
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    const marker = sample.paddedBox(55, 100, 10, 8);
    for (result.regions) |region| {
        if (std.meta.eql(@as(?Box, marker), region.before) and std.meta.eql(@as(?Box, marker), region.after)) break;
    } else return error.MissingMarker;
}

test "wider viewport aligns rows and shows only the added strip" {
    const before = try sample.Canvas.init(70, 90);
    defer before.deinit();
    const after = try sample.Canvas.init(80, 90);
    defer after.deinit();
    before.red(8, 0, 15, 4, 0);
    before.red(18, 30, 22, 6, 0);
    before.red(14, 62, 10, 5, 0);
    for (0..88) |y| @memcpy(after.row(y + 2)[0..70], before.row(y));
    try checkInsertion(before, after, Box.fromPixels(70 - region_padding, 0, 10 + region_padding, 90));
}

test "deleting viewport rows boxes the removed and revealed content" {
    const before = try sample.Canvas.init(80, 120);
    defer before.deinit();
    const after = try sample.Canvas.init(80, 120);
    defer after.deinit();
    before.red(5, 10, 31, 6, 0);
    before.red(14, 44, 25, 8, 0);
    before.red(30, 71, 18, 5, 0);
    after.copyRows(0, before, 0, 44);
    after.copyRows(44, before, 52, 120);
    after.red(8, 112, 17, 8, 0);
    try check(before, after, 1, &.{
        .{ .before = sample.paddedBox(14, 44, 25, 8) },
        .{ .after = Box.fromPixels(4, 108, 25, 12) },
    });
}

test "an insertion stays separate from a nearby recolour" {
    const before = try sample.Canvas.init(80, 104);
    defer before.deinit();
    before.red(8, 0, 20, 6, 0);
    before.red(20, 34, 4, 4, 0);
    before.red(58, 41, 13, 4, 0);
    before.red(33, 70, 25, 8, 0);
    const after = try before.insert(46, 6, 6);
    defer after.deinit();
    after.red(24, 34, 4, 4, 0);
    after.red(23, 46, 10, 6, 0);
    try check(before, after, 1, &.{
        .{ .before = sample.paddedBox(24, 34, 4, 4), .after = sample.paddedBox(24, 34, 4, 4) },
        .{ .after = sample.paddedBox(23, 46, 10, 6) },
    });
}

test "a banner added or removed at the top of a fixed viewport is boxed" {
    const before = try sample.Canvas.init(80, 120);
    defer before.deinit();
    before.red(4, 0, 60, 10, 0);
    before.red(12, 35, 27, 6, 0);
    before.red(20, 72, 36, 9, 0);
    before.red(8, 104, 30, 8, 0);
    const banner = 40;
    const after = try sample.Canvas.init(80, 120);
    defer after.deinit();
    after.copyRows(banner, before, 0, 120 - banner);
    after.fill(0, 0, 80, banner, .{ 130, 130, 130, 255 });
    after.red(10, 12, 30, 6, 0);
    const banner_box = sample.paddedBox(10, 12, 30, 6);
    try check(before, after, 1, &.{.{ .after = banner_box }});
    try check(after, before, 1, &.{
        .{ .before = banner_box },
        .{ .after = sample.paddedBox(20, 80, 36, 1) },
        .{ .after = sample.paddedBox(8, 104, 30, 8) },
    });
}

test "a whole-image change smaller than the noise minimum is reported" {
    const white: Image = .{ .width = 1, .height = 1, .pixels = &.{@splat(255)} };
    const black: Image = .{ .width = 1, .height = 1, .pixels = &.{.{ 0, 0, 0, 255 }} };
    const result = try compare(std.testing.allocator, white, black, .{});
    defer result.deinit(std.testing.allocator);
    try sample.checkRegions(result.regions, &.{.{ .before = Box.fromPixels(0, 0, 1, 1), .after = Box.fromPixels(0, 0, 1, 1) }});
}

test "a tall image against its reverse stops at the edit budget" {
    const height = values.max_extent;
    const old = try std.testing.allocator.alloc(Pixel, height);
    defer std.testing.allocator.free(old);
    const new = try std.testing.allocator.alloc(Pixel, height);
    defer std.testing.allocator.free(new);
    for (old, 0..) |*pixel, row| pixel.* = .{ @intCast(row % 256), @intCast(row / 256 % 256), 0, 255 };
    for (new, 0..) |*pixel, row| pixel.* = old[height - 1 - row];
    const result = try compare(std.testing.allocator, .{ .width = 1, .height = height, .pixels = old }, .{ .width = 1, .height = height, .pixels = new }, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.regions.len > 0);
}

test "fractional device scale is applied to box padding" {
    const before = try sample.Canvas.square();
    defer before.deinit();
    const after = try sample.Canvas.square();
    defer after.deinit();
    after.block(20, 24);
    const expected = Box.fromPixels(9, 13, 24, 24);
    try check(before, after, 2.625, &.{.{ .before = expected, .after = expected }});
}

test {
    inline for (.{ row_diff, columns, yiq, regions }) |module| std.testing.refAllDecls(module);
}

test "stroke edits survive row movement, neighbouring dark text and a wider crop" {
    const width = 240;
    const height = 400;
    const first = 40;
    const moved = 30;
    const dark_y = 6 + 14 * 14;
    const light_y = 13 + 14 * 14;
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    before.text(8, 232, 13, 50, 190);
    const dark_x = for (before.row(dark_y + 4)[8..], 8..) |pixel, x| {
        if (pixel[0] <= 100) break x;
    } else return error.MissingStroke;
    const light_x = for (before.row(light_y + 4)[8..], 8..) |pixel, x| {
        if (pixel[0] <= 230) break x;
    } else return error.MissingStroke;

    for ([_]bool{ false, true }) |wider_crop| {
        const after = try before.insert(0, 0, 0);
        defer after.deinit();
        after.fill(dark_x + 2, dark_y, 1, 9, sample.inkShade(30, 4));
        if (wider_crop) {
            after.fill(0, 2, 2, 2, sample.inkShade(0, 4));
            after.fill(236, 2, 2, 2, sample.inkShade(0, 4));
        }
        try expectEditAt(before, after, dark_x + 2, dark_y + 4, 20);
    }

    for ([_]enum { dark_widen, light_shift, light_widen }{ .dark_widen, .light_shift, .light_widen }) |edit_kind| {
        const after = try before.insert(first, moved, moved);
        defer after.deinit();
        after.fill(10, 44, 200, 20, .{ 200, 220, 240, 255 });
        const y = light_y + moved;
        switch (edit_kind) {
            .dark_widen => after.fill(dark_x + 2, dark_y + moved, 1, 9, sample.inkShade(30, 4)),
            .light_widen => after.fill(light_x + 3, y, 1, 9, sample.inkShade(190, 4)),
            .light_shift => for (y..y + 9) |row| {
                const pixels = after.row(row);
                std.mem.copyBackwards(Pixel, pixels[light_x + 1 ..][0..5], pixels[light_x..][0..5]);
                pixels[light_x] = @splat(255);
            },
        }
        if (edit_kind == .dark_widen) {
            try expectEditAt(before, after, dark_x + 2, dark_y + moved + 4, 20);
        } else {
            const x = light_x + @as(usize, if (edit_kind == .light_shift) 2 else 3);
            try expectEditAt(before, after, x, y + 4, 20);
        }
    }
}

test "small icon motion stays local in a textured viewport" {
    const width = 240;
    const height = 300;
    const color: Pixel = .{ 200, 40, 40, 255 };
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    before.fill(100, 140, 20, 20, color);
    for (2..4) |shift| {
        const after = try sample.Canvas.init(width, height);
        defer after.deinit();
        after.text(8, 232, 6, 0, 30);
        after.fill(100, 140 + shift, 20, 20, color);
        try expectEditAt(before, after, 110, 159 + shift, 20 + 2 * region_padding);
    }
}

test "a growing main column aligns beside a static sidebar" {
    const width = 320;
    const height = 400;
    const inserted = 60;
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    before.text(4, 56, 6, 100, 30);
    before.text(96, 316, 6, 0, 30);
    const after = try sample.Canvas.init(width, height + inserted);
    defer after.deinit();
    after.copyColumns(before, 0, 60, 0, height, 0);
    after.copyColumns(before, 96, width, 0, 40, 0);
    after.copyColumns(before, 96, width, 40, height, 40 + inserted);
    after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
    try check(before, after, 1, &.{.{ .after = sample.paddedBox(100, 44, 200, 50) }});
}

test "growing and shrinking columns keep their insertion and independent edits" {
    const width = 320;
    const height = 400;
    const inserted = 60;
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    before.text(4, 56, 6, 100, 30);
    before.text(96, 316, 6, 0, 30);
    const cases = [_]struct { x: usize, y: usize, width: usize, height: usize, kind: Kind, tone: u8 = 30 }{
        .{ .x = 200, .y = 300, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 20, .y = 300, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 20, .y = 430, .width = 20, .height = 8, .kind = .inserted },
        .{ .x = 0, .y = 400, .width = 60, .height = 60, .kind = .inserted, .tone = 230 },
        .{ .x = 30, .y = 399, .width = 2, .height = 61, .kind = .changed, .tone = 120 },
        .{ .x = 150, .y = 20, .width = 3, .height = 6, .kind = .inserted },
        .{ .x = 150, .y = 150, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 250, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 300, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 380, .width = 3, .height = 6, .kind = .changed },
        .{ .x = 150, .y = 440, .width = 3, .height = 6, .kind = .changed },
    };
    for (cases) |edit| {
        const after = try sample.Canvas.init(width, height + inserted);
        defer after.deinit();
        after.copyColumns(before, 0, 60, 0, height, 0);
        after.copyColumns(before, 96, width, 0, 40, 0);
        after.copyColumns(before, 96, width, 40, height, 40 + inserted);
        after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
        after.fill(edit.x, edit.y, edit.width, edit.height, sample.inkShade(edit.tone, 4));
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 50, .inserted));
        try std.testing.expect(sample.hasRegion(result.regions, .after, edit.x + edit.width / 2, edit.y + edit.height / 2, edit.kind));
        if (edit.y != 20) try std.testing.expectEqual(@as(usize, 2), result.regions.len);
        if (edit.x == 200) {
            const reverse = try compareCanvases(after, before, 1);
            defer reverse.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), reverse.regions.len);
            try std.testing.expect(sample.hasRegion(reverse.regions, .before, 120, 50, .removed));
            try std.testing.expect(sample.hasRegion(reverse.regions, .before, 201, 302, .changed));
        }
    }
}

test "edited moved lines still report narrow changes when matching nearby strokes" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    const sizes = [_][2]usize{ .{ 3, 6 }, .{ 1, 1 }, .{ 2, 2 }, .{ 6, 2 }, .{ 12, 9 }, .{ 3, 20 }, .{ 3, 30 } };
    for ([_]usize{ 0, 60 }) |growth| {
        const base = try before.insert(40, 60, growth);
        defer base.deinit();
        base.fill(10, 44, 200, 50, .{ 200, 220, 240, 255 });
        const after = try sample.Canvas.init(base.view.width, base.view.height);
        defer after.deinit();
        @memcpy(after.pixels, base.pixels);
        const limit: usize = if (growth == 0) 380 else 440;
        for (sizes) |size| {
            var y: usize = 110;
            while (y + size[1] < limit) : (y += 3) {
                const tone = sample.inkShade(30, 4);
                var hits: usize = 0;
                for (y..y + size[1]) |row| {
                    for (base.row(row)[150..][0..size[0]]) |pixel| hits += @intFromBool(!std.meta.eql(pixel, tone));
                }
                if (hits < min_region_pixels) continue;
                after.fill(150, y, size[0], size[1], tone);
                const result = try compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                const banner_kind: ?Kind = if (size[0] == 3 and size[1] == 6) .inserted else null;
                try std.testing.expect(sample.hasRegion(result.regions, .after, 30, 50, banner_kind));
                var seen = false;
                for (y..y + size[1]) |row| {
                    for (150..150 + size[0]) |x| {
                        if (!std.meta.eql(base.row(row)[x], tone) and sample.hasRegion(result.regions, .after, x, row, null)) seen = true;
                    }
                }
                try std.testing.expect(seen);
                for (result.regions) |region| {
                    if (region.after) |box| {
                        if (box.y < 100 and box.height >= 50) continue;
                    }
                    if (region.before) |box| try std.testing.expect(box.width <= @as(f64, @floatFromInt(size[0] + 60)));
                    if (region.after) |box| try std.testing.expect(box.width <= @as(f64, @floatFromInt(size[0] + 60)));
                }
                if (y == 374 and size[0] == 3 and size[1] == 6) try std.testing.expect(sample.hasRegion(result.regions, .after, 151, y + 2, .changed));
                after.copyColumns(base, 150, 150 + size[0], y, y + size[1], y);
            }
        }
    }
    const after = try before.insert(40, 60, 60);
    defer after.deinit();
    after.fill(10, 44, 200, 50, .{ 200, 220, 240, 255 });
    after.fill(29, 110, 3, 6, sample.inkShade(30, 4));
    const edit = try compareCanvases(before, after, 1);
    defer edit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), edit.regions.len);
    try std.testing.expect(sample.hasRegion(edit.regions, .after, 30, 112, .changed));
}

test "both moving columns preserve a two-sided edit in each" {
    const height = 400;
    const before = try sample.Canvas.init(320, height);
    defer before.deinit();
    before.text(4, 56, 6, 100, 30);
    before.text(96, 316, 6, 0, 30);
    const after = try sample.Canvas.init(320, height);
    defer after.deinit();
    after.copyColumns(before, 0, 60, 0, 30, 0);
    after.copyColumns(before, 0, 60, 30, height - 20, 50);
    after.copyColumns(before, 96, 320, 0, 40, 0);
    after.copyColumns(before, 96, 320, 40, height - 60, 100);
    after.fill(4, 32, 50, 16, .{ 220, 200, 240, 255 });
    after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
    after.fill(28, 302, 3, 6, sample.inkShade(30, 4));
    after.fill(200, 250, 3, 6, sample.inkShade(30, 4));
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 29, 304, .changed));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 201, 252, .changed));
}

test "thickened or recoloured underlines on moved text stay local" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    before.fill(40, 250, 120, 1, sample.inkShade(30, 4));
    before.fill(40, 300, 120, 1, sample.inkShade(200, 4));
    for ([_]usize{ 0, 281, 331, 330 }, [_]u8{ 0, 30, 200, 230 }) |y, tone| {
        const after = try before.insert(40, 30, 30);
        defer after.deinit();
        after.fill(10, 44, 200, 20, .{ 200, 220, 240, 255 });
        if (y != 0) after.fill(40, y, 120, 1, sample.inkShade(tone, 4));
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        if (y == 0) {
            try std.testing.expectEqual(@as(usize, 1), result.regions.len);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 2), result.regions.len);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 40, y, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 159, y, .changed));
        for (result.regions) |region| {
            if (region.before) |box| try std.testing.expect(box.width <= 120 + 2 * region_padding);
        }
    }
}

test "thicker strokes through repeating text survive temporary row shifts" {
    const base = try sample.Canvas.init(240, 400);
    defer base.deinit();
    base.text(8, 232, 6, 0, 30);
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    const after = try sample.Canvas.init(240, 400);
    defer after.deinit();
    for ([_]u8{ 30, 120, 200 }) |tone| {
        for (1..3) |extra| {
            for (100..380) |y| {
                @memcpy(before.pixels, base.pixels);
                before.fill(20, y, 200, 1, sample.inkShade(tone, 4));
                @memcpy(after.pixels, before.pixels);
                after.fill(20, y + 1, 200, extra, sample.inkShade(tone, 4));
                const result = try compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                if (result.regions.len == 0) {
                    std.debug.print("Missed tone {d} thickened by {d} at row {d}\n", .{ tone, extra, y });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "a light stem edit stays visible beside touching dark text" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    var line: usize = 20;
    while (line + 9 < before.view.height) : (line += 28) {
        before.fill(100, line, 2, 9, sample.inkShade(30, 4));
        before.fill(103, line, 2, 9, sample.inkShade(190, 4));
    }
    const target = 20 + 28 * 6;
    for ([_]enum { control, widened, right, left, unmoved }{ .control, .widened, .right, .left, .unmoved }) |edit| {
        const shift: usize = if (edit == .unmoved) 0 else 30;
        const after = try before.insert(10, shift, shift);
        defer after.deinit();
        if (shift != 0) after.fill(10, 12, 200, 20, .{ 200, 220, 240, 255 });
        const y = target + shift;
        switch (edit) {
            .control => {
                const result = try compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                try std.testing.expectEqual(@as(usize, 1), result.regions.len);
                try std.testing.expect(sample.hasRegion(result.regions, .after, 110, 22, .inserted));
                continue;
            },
            .widened, .unmoved => after.fill(105, y, 1, 9, sample.inkShade(190, 4)),
            .right => {
                after.fill(103, y, 1, 9, @splat(255));
                after.fill(105, y, 1, 9, sample.inkShade(190, 4));
            },
            .left => {
                after.fill(102, y, 1, 9, sample.inkShade(190, 4));
                after.fill(104, y, 1, 9, @splat(255));
            },
        }
        const x: usize = switch (edit) {
            .right => 104,
            .left => 103,
            else => 105,
        };
        try expectEditAt(before, after, x, y + 4, 24);
    }
}

test "sparse marks and real extensions survive independent column alignment" {
    const height = 400;
    const before = try sample.Canvas.init(320, height);
    defer before.deinit();
    before.text(4, 56, 6, 100, 30);
    before.text(96, 316, 6, 0, 30);
    const after = try sample.Canvas.init(320, height + 60);
    defer after.deinit();
    after.copyColumns(before, 0, 60, 0, height, 0);
    after.copyColumns(before, 96, 320, 0, 40, 0);
    after.copyColumns(before, 96, 320, 40, height, 100);
    after.fill(100, 44, 200, 50, .{ 200, 220, 240, 255 });
    for ([_][4]usize{
        .{ 20, 430, 2, 2 }, .{ 20, 430, 1, 4 }, .{ 20, 430, 4, 1 },
        .{ 20, 450, 1, 1 }, .{ 5, 455, 30, 1 }, .{ 20, 430, 10, 10 },
    }, 0..) |m, i| {
        const tone: u8 = if (i == 5) 240 else 30;
        after.fill(m[0], m[1], m[2], m[3], sample.inkShade(tone, 4));
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 50, .inserted));
        try std.testing.expectEqual(m[2] * m[3] >= min_region_pixels, sample.hasRegion(result.regions, .after, m[0], m[1], .inserted));
        const reverse = try compareCanvases(after, before, 1);
        defer reverse.deinit(std.testing.allocator);
        try std.testing.expectEqual(m[2] * m[3] >= min_region_pixels, sample.hasRegion(reverse.regions, .before, m[0], m[1], .removed));
        after.fill(m[0], m[1], m[2], m[3], @splat(255));
    }
}

test "independently aligned columns retain clipped text and different strides" {
    const full = try sample.Canvas.init(320, 480);
    defer full.deinit();
    full.text(4, 56, 6, 100, 30);
    full.text(96, 296, 6, 0, 30);
    for ([_]usize{ 300, 320 }, [_]usize{ 400, 403 }) |width, height| {
        const before = try sample.Canvas.init(width, height);
        defer before.deinit();
        before.copyColumns(full, 0, width, 0, height, 0);
        const after = try sample.Canvas.init(320, height + 60);
        defer after.deinit();
        after.copyColumns(full, 0, 60, 0, if (width == 300) height else height + 60, 0);
        after.copyColumns(before, 96, width, 0, 40, 0);
        after.copyColumns(before, 96, width, 40, height, 100);
        after.fill(100, 44, 180, 50, .{ 200, 220, 240, 255 });
        const x: usize = if (width == 300) 20 else 30;
        const y: usize = if (width == 300) 440 else 300;
        after.fill(x, y, if (width == 300) 6 else 3, 6, sample.inkShade(30, 4));
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 50, .inserted));
        try std.testing.expect(sample.hasRegion(result.regions, .after, x + 2, y + 2, null));
        if (width == 320) {
            try std.testing.expectEqual(@as(usize, 3), result.regions.len);
            try std.testing.expect(sample.hasRegion(result.regions, .after, 30, 440, .inserted));
            try std.testing.expect(sample.hasRegion(result.regions, .after, x + 2, y + 2, .changed));
            for (result.regions) |region| {
                if (region.kind != .changed) continue;
                try std.testing.expect(region.after.?.width <= 3 + 2 * region_padding);
            }
        }
    }
}

test "swapped and repeated lines remain visible between shifted anchors" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    for ([_]bool{ true, false }) |swap| {
        const after = try before.insert(40, 30, 30);
        defer after.deinit();
        after.fill(10, 44, 200, 20, .{ 200, 220, 240, 255 });
        after.copyRows(232, before, if (swap) 216 else 34, if (swap) 225 else 43);
        if (swap) after.copyRows(246, before, 202, 211);
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 236, null));
        if (swap) try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 250, null));
    }
}

test "repeated table rows keep recoloured or deleted cells after a shift" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    var y: usize = 0;
    while (y + 20 <= before.view.height) : (y += 20) {
        before.fill(10, y + 2, 220, 1, sample.inkShade(220, 4));
        before.fill(20, y + 8, 40, 6, sample.inkShade(90, 4));
        before.fill(120, y + 8, 40, 6, sample.inkShade(90, 4));
    }
    for ([_]usize{ 0, 40 }) |growth| {
        const after = try before.insert(60, 40, growth);
        defer after.deinit();
        after.fill(10, 64, 200, 30, .{ 200, 220, 240, 255 });
        for ([_]Pixel{ .{ 90, 90, 160, 255 }, @splat(255) }) |color| {
            after.fill(120, 248, 40, 6, color);
            const result = try compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(sample.hasRegion(result.regions, .after, 140, 250, .changed));
            if (growth == 0) {
                try std.testing.expectEqual(@as(usize, 0), result.moves.len);
                try std.testing.expectEqual(@as(usize, 2), result.regions.len);
                for (result.regions) |region| {
                    try std.testing.expectEqual(Kind.changed, region.kind);
                    try std.testing.expectEqual(region.before, region.after);
                }
            }
        }
    }
}

test "anchor boundaries and translucent edits remain visible on moved rows" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 6, 0, 30);
    for ([_]usize{ 99, 100, 101, 113, 114, 115 }) |y| {
        const after = try before.insert(40, 60, 60);
        defer after.deinit();
        after.fill(10, 44, 200, 50, .{ 200, 220, 240, 255 });
        after.fill(60, y, 3, 3, sample.inkShade(30, 4));
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, .after, 61, y + 1, null));
    }

    const transparent = try sample.Canvas.init(200, 300);
    defer transparent.deinit();
    @memset(transparent.pixels, .{ 255, 255, 255, 0 });
    transparent.text(8, 192, 6, 0, 30);
    const after = try transparent.insert(40, 30, 30);
    defer after.deinit();
    after.fill(0, 40, 200, 30, .{ 255, 255, 255, 0 });
    after.fill(10, 44, 180, 20, .{ 200, 220, 240, 255 });
    after.fill(100, 200, 4, 4, .{ 255, 0, 0, 120 });
    const result = try compareCanvases(transparent, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 101, 201, null));
}

test "fixed footers with internal edits clip shifted content" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 50, 0, 30);
    before.fill(0, 0, 240, 40, .{ 40, 40, 70, 255 });
    before.line(10, 200, 15, 77, 240);
    before.fill(0, 350, 240, 50, .{ 60, 60, 60, 255 });
    before.fill(170, 360, 50, 30, .{ 0, 120, 220, 255 });

    for ([_]usize{ 41, 150, 300 }) |y| {
        const after = try sample.Canvas.init(240, 400);
        defer after.deinit();
        after.copyRows(0, before, 0, y);
        after.copyRows(y + 30, before, y, 320);
        after.copyRows(350, before, 350, 400);
        after.fill(10, y + 4, 220, 22, .{ 200, 220, 240, 255 });
        for ([_]?usize{ null, 352, 365, 385 }) |edit| {
            if (edit) |row| after.fill(30, row, 10, 10, .{ 255, 200, 0, 255 });
            const result = try compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, if (edit == null) 1 else 2), result.regions.len);
            try std.testing.expect(sample.hasRegion(result.regions, .after, 50, y + 10, .inserted));
            try std.testing.expectEqual(@as(usize, 1), result.moves.len);
            const move = result.moves[0];
            try std.testing.expectEqual(@as(usize, 30), move.after.y - move.before.y);
            try std.testing.expectEqual(@as(usize, 350), move.after.y + move.after.height);
            if (edit) |row| {
                const expected = Box.fromPixels(26, row - 4, 18, 18);
                try std.testing.expectEqual(expected, result.regions[1].before.?);
                try std.testing.expectEqual(expected, result.regions[1].after.?);
                after.fill(30, row, 10, 10, .{ 60, 60, 60, 255 });
            }
        }
        after.fill(5, 10, 10, 10, .{ 255, 200, 0, 255 });
        const header_edit = try compareCanvases(before, after, 1);
        defer header_edit.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), header_edit.regions.len);
        try std.testing.expectEqual(@as(usize, 1), header_edit.moves.len);
        try std.testing.expect(sample.hasRegion(header_edit.regions, .after, 8, 12, .changed));
        after.fill(5, 10, 10, 10, .{ 40, 40, 70, 255 });
        const reverse = try compareCanvases(after, before, 1);
        defer reverse.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), reverse.regions.len);
        try std.testing.expect(sample.hasRegion(reverse.regions, .before, 50, y + 10, .removed));
        try std.testing.expectEqual(@as(usize, 1), reverse.moves.len);
        try std.testing.expectEqual(@as(usize, 30), reverse.moves[0].before.y - reverse.moves[0].after.y);
    }
}

test "one or two displacements in a fixed thread get distinct move ranges" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    before.text(8, 232, 50, 0, 30);
    before.fill(0, 0, 240, 40, sample.inkShade(45, 4));
    before.fill(0, 350, 240, 50, sample.inkShade(60, 4));
    const after = try sample.Canvas.init(240, 400);
    defer after.deinit();
    for ([_]bool{ false, true }) |remove| {
        @memset(after.pixels, sample.inkShade(255, 4));
        after.copyRows(0, before, 0, 100);
        after.copyRows(120, before, 100, if (remove) 244 else 230);
        after.fill(10, 104, 220, 12, .{ 200, 220, 240, 255 });
        if (remove) {
            after.copyRows(264, before, 286, 350);
        } else {
            after.fill(10, 254, 220, 12, .{ 240, 220, 200, 255 });
            after.copyRows(270, before, 230, 310);
        }
        after.copyRows(350, before, 350, 400);
        const found = try compareCanvases(before, after, 1);
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), found.regions.len);
        try std.testing.expectEqual(@as(usize, 2), found.moves.len);
        try std.testing.expectEqual(@as(usize, 20), found.moves[0].after.y - found.moves[0].before.y);
        if (remove) {
            try std.testing.expect(sample.hasRegion(found.regions, .before, 50, 255, .removed));
            try std.testing.expectEqual(@as(usize, 22), found.moves[1].before.y - found.moves[1].after.y);
        } else {
            try std.testing.expect(sample.hasRegion(found.regions, .after, 50, 260, .inserted));
            try std.testing.expectEqual(@as(usize, 40), found.moves[1].after.y - found.moves[1].before.y);
        }
    }
}

test "a moved main column describes its own x span beside a fixed sidebar" {
    const before = try sample.Canvas.init(320, 400);
    defer before.deinit();
    before.text(4, 56, 50, 100, 30);
    before.text(96, 316, 50, 0, 30);
    before.fill(0, 0, 320, 40, sample.inkShade(45, 4));
    before.fill(0, 350, 320, 50, sample.inkShade(60, 4));
    const after = try sample.Canvas.init(320, 400);
    defer after.deinit();
    @memcpy(after.pixels, before.pixels);
    after.fill(96, 40, 224, 310, sample.inkShade(255, 4));
    after.copyColumns(before, 96, 320, 40, 120, 40);
    after.copyColumns(before, 96, 320, 120, 310, 160);
    after.fill(100, 124, 200, 32, .{ 200, 220, 240, 255 });
    for (0..2) |pass| {
        if (pass == 1) after.fill(20, 200, 3, 6, sample.inkShade(30, 4));
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(pass + 1, result.regions.len);
        try std.testing.expectEqual(@as(usize, 1), result.moves.len);
        try std.testing.expectEqual(@as(usize, 96), result.moves[0].x.count());
        try std.testing.expectEqual(@as(usize, 217), result.moves[0].width.count());
        try std.testing.expectEqual(@as(usize, 40), result.moves[0].after.y - result.moves[0].before.y);
    }
}

test "overpainting repeated lines does not create a row movement" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    var y: usize = 10;
    while (y + 9 < before.view.height) : (y += 18) before.line(8, 232, y, 4, 30);
    const after = try sample.Canvas.init(240, 400);
    defer after.deinit();
    for ([_]usize{ 8, 20, 41 }) |height| {
        for ([_]usize{ 50, 120 }) |width| {
            for (0..32) |step| {
                const top = 20 + step * 10;
                @memcpy(after.pixels, before.pixels);
                after.fill(52, top, width, height, .{ 185, 25, 40, 255 });
                const result = try compareCanvases(before, after, 1);
                defer result.deinit(std.testing.allocator);
                errdefer std.debug.print("overpaint y={d} width={d} height={d}\n", .{ top, width, height });
                try std.testing.expectEqual(@as(usize, 1), result.regions.len);
                try std.testing.expectEqual(Kind.changed, result.regions[0].kind);
                try std.testing.expectEqual(@as(usize, 0), result.moves.len);
            }
        }
    }
}

test "distant overpaints on repeated lines stay positional" {
    const width = 1200;
    const height = 800;
    const before = try sample.Canvas.init(width, height);
    defer before.deinit();
    const after = try sample.Canvas.init(width, height);
    defer after.deinit();
    var y: usize = 10;
    while (y + 9 <= height) : (y += 40) {
        before.line(10, 175, y, y / 40, 30);
        before.line(610, 775, y, y / 40, 30);
    }
    const paint: Pixel = .{ 235, 20, 30, 255 };
    for ([_]usize{ 20, 50, 100 }) |size| {
        y = 120;
        while (y <= 700) : (y += 23) {
            @memcpy(after.pixels, before.pixels);
            after.fill(50, 50, 41, 41, paint);
            after.fill(width - 100, height - 100, 91, 91, paint);
            after.fill(width / 2, y, size, size, paint);
            const result = try compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 3), result.regions.len);
            try std.testing.expectEqual(@as(usize, 0), result.moves.len);
            for (result.regions) |region| {
                try std.testing.expectEqual(Kind.changed, region.kind);
                try std.testing.expectEqual(region.before, region.after);
            }
        }
    }
}

test "an inset item after a deletion is not a footer" {
    const before = try sample.Canvas.init(240, 400);
    defer before.deinit();
    const after = try sample.Canvas.init(240, 400);
    defer after.deinit();
    const clipped = try sample.Canvas.init(240, 400);
    defer clipped.deinit();
    var y: usize = 0;
    for (0..22) |item| {
        if (y + 26 > before.view.height) break;
        if (item % 7 == 3) {
            before.fill(8, y, 225, 23, .{ 60, 145, 180, 255 });
            y += 26;
        } else {
            before.line(8, 110 + item % 5 * 9, y + 2, item * 3 + 1, 30);
            y += 18;
        }
    }
    const insertion = 116;
    const deletion = 304;
    const shift = 18;
    after.copyRows(0, before, 0, before.view.height);
    after.copyRows(insertion + shift, before, insertion, deletion);
    after.fill(8, insertion, 225, 15, .{ 40, 200, 40, 255 });
    clipped.copyRows(0, after, 0, insertion + shift);
    clipped.copyRows(insertion + shift, before, insertion, before.view.height - shift);
    try std.testing.expect(!pixel_ops.sameRun(after.pixels, clipped.pixels));
    for ([_]bool{ false, true }) |reverse| {
        const result = try compareCanvases(if (reverse) after else before, if (reverse) before else after, 1);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(sample.hasRegion(result.regions, if (reverse) .after else .before, 32, deletion + 6, if (reverse) .inserted else .removed));
    }
}

test "an exact periodic repeat chooses the stationary reading" {
    const before = try sample.Canvas.init(200, 400);
    defer before.deinit();
    const after = try sample.Canvas.init(200, 400);
    defer after.deinit();
    var y: usize = 6;
    while (y + 9 <= before.view.height) : (y += 14) before.line(8, 192, y, 3, 30);
    after.copyRows(0, before, 28, 400);
    y = 370;
    while (y + 9 <= after.view.height) : (y += 14) after.line(8, 192, y, 3, 30);
    after.fill(28, 176, 3, 6, sample.inkShade(30, 4));

    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 29, 178, .changed));
    for (result.regions) |region| {
        try std.testing.expectEqual(Kind.changed, region.kind);
        try std.testing.expectEqual(region.before, region.after);
    }
}

test "balanced insertion and deletion detect every visible loss in both directions" {
    for ([_]usize{ 400, 400, 520 }, [_]bool{ true, false, false }) |height, chrome| {
        const before = try sample.Canvas.init(240, height);
        defer before.deinit();
        const after = try sample.Canvas.init(240, height);
        defer after.deinit();
        const clipped = try sample.Canvas.init(240, height);
        defer clipped.deinit();
        sample.auditPage(before, chrome, null, null, 0);
        for ([_]usize{ 1, 3, 6 }) |insert_at| {
            for (1..4) |rows_count| {
                sample.auditPage(clipped, chrome, insert_at, null, rows_count);
                for (insert_at + 1..20) |delete_at| {
                    const y = (if (chrome) @as(usize, 44) else 8) + 18 * delete_at;
                    if (y + 18 * rows_count > height - (if (chrome) @as(usize, 50) else 0)) continue;
                    sample.auditPage(after, chrome, insert_at, delete_at, rows_count);
                    const observable = !pixel_ops.sameRun(after.pixels, clipped.pixels);
                    for ([_]bool{ false, true }) |reverse| {
                        const result = try compareCanvases(if (reverse) after else before, if (reverse) before else after, 1);
                        defer result.deinit(std.testing.allocator);
                        if (!observable) continue; // The two possible edits produce the same captured pixels.
                        errdefer std.debug.print("height={d}, chrome={}, insert={d}, delete={d}, rows_count={d}, reverse={}\n", .{ height, chrome, insert_at, delete_at, rows_count, reverse });
                        const kind: Kind = if (reverse) .inserted else .removed;
                        const side: values.Side = if (reverse) .after else .before;
                        var visible = false;
                        for (result.regions) |r| {
                            if (r.kind != kind) continue;
                            const box = r.boxOn(side).?;
                            if (box.y < @as(f64, @floatFromInt(y + 18 * rows_count)) and box.bottom() > @as(f64, @floatFromInt(y))) visible = true;
                        }
                        errdefer std.debug.print("regions {any}, moves {any}\n", .{ result.regions, result.moves });
                        try std.testing.expect(visible);
                    }
                }
            }
        }
    }
}

test "exchanging separated cards preserves the removed card height" {
    const before = try sample.Canvas.init(240, 520);
    defer before.deinit();
    const after = try sample.Canvas.init(240, 520);
    defer after.deinit();
    sample.auditPage(before, false, null, null, 0);
    const old_y = 8 + 10 * 18;
    const new_y = 8 + 18;
    before.fill(8, old_y, 220, 30, .{ 220, 30, 30, 255 });
    after.copyRows(0, before, 0, new_y);
    after.fill(8, new_y, 220, 30, .{ 30, 70, 230, 255 });
    after.copyRows(new_y + 30, before, new_y, old_y);
    after.copyRows(old_y + 30, before, old_y + 30, 520);
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    try std.testing.expect(sample.hasRegion(result.regions, .after, 60, new_y + 15, .inserted));
    try std.testing.expect(sample.hasRegion(result.regions, .before, 60, old_y + 15, .removed));
    for (result.regions) |r| if (r.kind == .removed) {
        try std.testing.expectEqual(@as(f64, 38), r.before.?.height);
    };
}

test "a compact insertion at the end of a narrow column retains its shift" {
    const before = try sample.Canvas.init(400, 600);
    defer before.deinit();
    before.fill(140, 20, 250, 520, sample.inkShade(235, 4));
    for (0..20) |i| before.fill(20, 10 + 18 * i, 18, if (i == 19) 4 else 7, sample.inkShade(@intCast(20 + i), 4));
    const after = try sample.Canvas.init(400, 600);
    defer after.deinit();
    @memcpy(after.pixels, before.pixels);
    const row = 10 + 19 * 18;
    after.copyColumns(before, 20, 38, row, 580, row + 20);
    after.fill(20, row, 18, 20, .{ 200, 220, 240, 255 });
    const found = try compareCanvases(before, after, 1);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), found.regions.len);
    try std.testing.expectEqual(Kind.inserted, found.regions[0].kind);
    try std.testing.expect(found.moves.len != 0);
    try std.testing.expectEqual(@as(usize, 20), found.moves[0].after.y - found.moves[0].before.y);
}

test "overpainting repetitive wide pages stays positional" {
    for ([_]usize{ 1000, 3000, 10000 }, [_]usize{ 800, 1200, 4000 }) |width, height| {
        const before = try sample.Canvas.init(width, height);
        defer before.deinit();
        const after = try sample.Canvas.init(width, height);
        defer after.deinit();
        var y: usize = 10;
        while (y + 10 < height) : (y += 40) {
            var x: usize = 10;
            while (x + 120 < width) : (x += 600) before.line(x, x + 120, y, y / 40, 30);
        }
        @memcpy(after.pixels, before.pixels);
        after.fill(width / 2, height / 2, 100, 100, .{ 255, 0, 0, 255 });
        const found = try compareCanvases(before, after, 1);
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), found.regions.len);
        try std.testing.expectEqual(@as(usize, 0), found.moves.len);
        try std.testing.expectEqual(found.regions[0].before.?, found.regions[0].after.?);
        try std.testing.expectEqual(@as(f64, 108), found.regions[0].after.?.width);
    }
}

test "solid overpaints of repeated lines stay two-sided across column widths" {
    for ([_]usize{ 600, 2000 }) |height| {
        const before = try sample.Canvas.init(400, height);
        defer before.deinit();
        const after = try sample.Canvas.init(400, height);
        defer after.deinit();
        var y: usize = 10;
        while (y + 10 < height) : (y += 18) before.line(10, 170, y, y / 18, 30);
        for ([_][2]usize{ .{ 50, 121 }, .{ 10, 191 }, .{ 10, 231 }, .{ 0, 400 } }) |span| {
            y = 40;
            while (y < height - 80) : (y += 37) {
                for ([_]usize{ 8, 20, 41 }) |h| {
                    @memcpy(after.pixels, before.pixels);
                    after.fill(span[0], y, span[1] - span[0], h, .{ 255, 0, 0, 255 });
                    const found = try compareCanvases(before, after, 1);
                    defer found.deinit(std.testing.allocator);
                    try std.testing.expectEqual(@as(usize, 1), found.regions.len);
                    try std.testing.expectEqual(@as(usize, 0), found.moves.len);
                    try std.testing.expectEqual(found.regions[0].before.?, found.regions[0].after.?);
                }
            }
        }
    }
}

test "one changed pixel is reported consistently in small rasters" {
    for ([_][2]usize{ .{ 1, 1 }, .{ 3, 2 }, .{ 10, 5 }, .{ 30, 30 }, .{ 1, 200 }, .{ 200, 1 } }) |size| {
        const before = try sample.Canvas.init(size[0], size[1]);
        defer before.deinit();
        const after = try sample.Canvas.init(size[0], size[1]);
        defer after.deinit();
        after.fill(size[0] - 1, size[1] - 1, 1, 1, .{ 255, 0, 0, 255 });
        const found = try compareCanvases(before, after, 1);
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), found.regions.len);
        try std.testing.expectEqual(Kind.changed, found.regions[0].kind);
    }
}

test "fixed chrome stays stationary across heights and button edits" {
    for ([_]usize{ 20, 50, 80 }) |footer_height| {
        const footer = 400 - footer_height;
        const before = try sample.Canvas.init(240, 400);
        defer before.deinit();
        const after = try sample.Canvas.init(240, 400);
        defer after.deinit();
        before.text(8, 58, 44, 0, 30);
        before.fill(0, 0, 240, 41, .{ 220, 220, 235, 255 });
        before.fill(0, footer, 240, footer_height, .{ 235, 225, 220, 255 });
        const button_h = @min(21, footer_height - 10);
        before.fill(20, footer + 10, 61, button_h, .{ 50, 50, 200, 255 });
        for ([_]usize{ 2, 16 }) |at| {
            if (at == 16 and footer_height != 50) continue;
            const y = 44 + at * 18;
            after.copyRows(0, before, 0, y);
            after.fill(0, y, 240, @min(30, footer - y), sample.inkShade(255, 4));
            if (y + 30 < footer) after.copyRows(y + 30, before, y, footer - 30);
            after.copyRows(footer, before, footer, 400);
            after.fill(8, y, 225, @min(27, footer - y), .{ 60, 140, 90, 255 });
            const inserted = try compareCanvases(before, after, 1);
            defer inserted.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), inserted.regions.len);
            try std.testing.expect(sample.hasRegion(inserted.regions, .after, 100, y + 3, if (at == 2) .inserted else null));
            if (at == 2 and footer_height == 50) {
                after.fill(20, footer + 10, 61, button_h, .{ 235, 225, 220, 255 });
                after.fill(120, footer + 10, 61, button_h, .{ 50, 50, 200, 255 });
                const moved = try compareCanvases(before, after, 1);
                defer moved.deinit(std.testing.allocator);
                try std.testing.expect(sample.hasRegion(moved.regions, .after, 130, footer + 15, .changed));
                try std.testing.expect(sample.hasRegion(moved.regions, .before, 25, footer + 15, .changed));
            }
        }
    }
}

test "many spaced edits still obey the region cap on a dark page" {
    const before = try sample.Canvas.init(1200, 2000);
    defer before.deinit();
    const after = try sample.Canvas.init(1200, 2000);
    defer after.deinit();
    @memset(before.pixels, .{ 18, 18, 22, 255 });
    before.text(10, 180, 10, 5, 220);
    @memcpy(after.pixels, before.pixels);
    for (0..42) |i| {
        after.fill(60 + i % 6 * 190, 60 + i / 6 * 250, 11, 11, .{ 240, 240, 240, 255 });
    }
    const found = try compareCanvases(before, after, 1);
    defer found.deinit(std.testing.allocator);
    try std.testing.expect(found.regions.len <= max_regions);
    try std.testing.expectEqual(@as(usize, 0), found.moves.len);
    for (0..42) |i| try std.testing.expect(sample.hasRegion(found.regions, .after, 65 + i % 6 * 190, 65 + i / 6 * 250, .changed));
}

test "a compact outline joins edits to its label and value without spanning cards" {
    const before = try sample.Canvas.init(480, 164);
    defer before.deinit();
    const after = try sample.Canvas.init(480, 164);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }) |canvas| {
        for ([_]usize{ 20, 254 }) |left| {
            canvas.fill(left, 20, 198, 112, sample.inkShade(120, 4));
            canvas.fill(left + 2, 22, 194, 108, sample.inkShade(240, 4));
        }
    }
    for ([_]usize{ 52, 286 }) |left| {
        before.fill(left, 44, 40, 12, sample.inkShade(64, 4));
        after.fill(left, 44, 56, 12, sample.inkShade(72, 4));
        before.fill(left, 70, 68, 22, sample.inkShade(64, 4));
        after.fill(left, 70, 82, 22, sample.inkShade(72, 4));
    }
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for ([_]usize{ 52, 286 }) |left| {
        try std.testing.expect(sample.hasRegion(result.regions, .after, left, 46, .changed));
        try std.testing.expect(sample.hasRegion(result.regions, .after, left, 90, .changed));
    }
    const label = Box.fromPixels(52, 44, 56, 12);
    const value = Box.fromPixels(52, 70, 82, 22);
    var candidates = [_]regions.Candidate{
        .{ .region = .{ .before = label, .after = label }, .pixels = 4 },
        .{ .region = .{ .before = value, .after = value }, .pixels = 4 },
    };
    var moves = [_]values.Move{.{
        .before = .{ .y = 56, .height = 32 },
        .after = .{ .y = 74, .height = 32 },
        .x = .init(160),
        .width = .init(24),
    }};
    const len = regions.mergeLogical(&candidates, before.view, after.view, .one, &moves);
    var edits: [candidates.len]values.Region = undefined;
    for (edits[0..len], candidates[0..len]) |*edit, candidate| edit.* = candidate.region;
    try std.testing.expectEqual(@as(usize, 1), regions.keepMoves(&moves, edits[0..len], .one, Scale.one.devicePixels(scroll_shift)));
}

test "a clipped list shifts by one row without reporting the obscured tail" {
    const before = try sample.Canvas.init(368, 390);
    defer before.deinit();
    const after = try sample.Canvas.init(368, 390);
    defer after.deinit();
    // Lower rounded corners shorten the visible closing rule.
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(16, 40, 336, 224, sample.inkShade(120, 4));
        canvas.fill(18, 42, 332, 218, sample.inkShade(240, 4));
        canvas.fill(16, 260, 14, 4, sample.inkShade(255, 4));
        canvas.fill(338, 260, 14, 4, sample.inkShade(255, 4));
        for (1..15) |rise| {
            const x = 30 - rise;
            canvas.fill(x, 260 - rise, 1, 1, sample.inkShade(120, 4));
            canvas.fill(367 - x, 260 - rise, 1, 1, sample.inkShade(120, 4));
        }
    }
    for (0..4) |row| {
        before.fill(36, 70 + 48 * row, 30 + 16 * row, if (row == 3) 46 else 16, sample.inkShade(40, 4));
        before.fill(256, 70 + 48 * row, 30 + 10 * row, if (row == 3) 46 else 16, sample.inkShade(64, 4));
    }
    after.copyRows(70, before, 70, 86);
    for (166..260) |y| @memcpy(after.pixels[y * 368 + 34 ..][0..302], before.view.row(y - 48)[34..][0..302]);
    after.fill(36, 118, 90, 18, sample.inkShade(80, 4));
    after.fill(256, 118, 64, 18, sample.inkShade(38, 4));
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.inserted, result.regions[0].kind);
    try std.testing.expectEqual(@as(usize, 1), result.moves.len);
    try std.testing.expectEqual(@as(usize, 48), result.moves[0].shift());
}

test "a dimmed viewport with a new opaque center pane is an inserted overlay" {
    const before = try sample.Canvas.init(192, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(192, 160);
    defer after.deinit();
    before.fill(0, 0, 50, 160, sample.inkShade(192, 4));
    before.fill(50, 0, 142, 42, sample.inkShade(220, 4));
    for (before.pixels, after.pixels) |ink, *shade| {
        shade.* = .{ ink[0] / 2, ink[1] / 2, ink[2] / 2, 255 };
    }
    const dimmed = try compareCanvases(before, after, 1);
    defer dimmed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.changed, dimmed.regions[0].kind);
    after.fill(52, 52, 88, 56, sample.inkShade(216, 4));
    const shown = try compareCanvases(before, after, 1);
    defer shown.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), shown.regions.len);
    try std.testing.expectEqual(Kind.inserted, shown.regions[0].kind);
    const hidden = try compareCanvases(after, before, 1);
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hidden.regions.len);
    try std.testing.expectEqual(Kind.removed, hidden.regions[0].kind);
}

test "a colored edit next to a floating panel remains visible on both sides" {
    const before = try sample.Canvas.init(256, 144);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 144);
    defer after.deinit();
    before.line(54, 160, 62, 1, 64);
    after.fill(22, 50, 196, 46, sample.inkShade(220, 4));
    after.fill(28, 54, 184, 32, sample.inkShade(36, 4));
    after.fill(22, 50, 18, 4, .{ 168, 31, 48, 255 });
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasSeparateMark(result.regions, 26, 52, 100, 70));
}

test "audit: a gray label turning black beside a toast remains two-sided" {
    const before = try sample.Canvas.init(256, 144);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 144);
    defer after.deinit();
    before.fill(28, 88, 18, 5, .{ 136, 136, 136, 255 });
    after.fill(22, 50, 196, 46, .{ 220, 220, 220, 255 });
    after.fill(28, 54, 184, 32, .{ 36, 36, 36, 255 });
    after.fill(28, 88, 18, 5, .{ 0, 0, 0, 255 });
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasSeparateMark(result.regions, 34, 90, 110, 75));
}

test "round 25 audit: a darkened gray label cannot set its own shadow transmission" {
    const before = try sample.Canvas.init(256, 144);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 144);
    defer after.deinit();
    before.fill(28, 88, 18, 5, .{ 136, 136, 136, 255 });
    after.fill(22, 50, 196, 46, .{ 230, 230, 230, 255 });
    after.fill(28, 54, 184, 32, .{ 36, 36, 36, 255 });
    after.fill(28, 88, 18, 5, .{ 115, 115, 115, 255 });
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasSeparateMark(result.regions, 34, 90, 110, 75));
}

test "round 25 audit: narrow, edge-touching and gradient panels retain the old side" {
    const before = try sample.Canvas.init(300, 164);
    defer before.deinit();
    const after = try sample.Canvas.init(300, 164);
    defer after.deinit();
    const background: values.Pixel = .{ 240, 240, 240, 255 };
    for ([_]enum { narrow, edge, gradient }{ .narrow, .edge, .gradient }) |profile| {
        @memset(before.pixels, background);
        @memset(after.pixels, background);
        after.fill(18, 48, 264, 72, .{ 225, 225, 225, 255 });
        after.fill(30, 54, 240, 56, .{ 52, 32, 62, 255 });
        switch (profile) {
            .narrow => before.fill(70, 57, 100, 45, .{ 70, 110, 90, 255 }),
            .edge => before.fill(18, 57, 260, 45, .{ 255, 255, 255, 255 }),
            .gradient => for (0..176) |x| {
                before.fill(60 + x, 57, 1, 45, .{ @intCast(40 + x), 110, 90, 255 });
            },
        }
        before.fill(42, 111, 18, 5, .{ 136, 136, 136, 255 });
        after.fill(42, 111, 18, 5, .{ 115, 115, 115, 255 });
        const result = try compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        const prior_x: usize = if (profile == .edge) 20 else 90;
        try std.testing.expect(sample.hasRegion(result.regions, .before, prior_x, 80, null));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 80, null));
        try std.testing.expect(sample.hasSeparateMark(result.regions, 48, 113, 120, 80));
    }
}

test "audit: growing or replacing a toast retains the old panel" {
    const before = try sample.Canvas.init(300, 180);
    defer before.deinit();
    const after = try sample.Canvas.init(300, 180);
    defer after.deinit();
    before.fill(42, 59, 216, 48, .{ 40, 82, 46, 255 });
    before.line(60, 180, 76, 1, 218);
    // Preserve the backdrop at the old panel's extent until it is covered.
    after.fill(18, 48, 264, 86, .{ 230, 230, 230, 255 });
    after.fill(30, 54, 240, 72, .{ 122, 36, 45, 255 });
    after.line(60, 190, 76, 2, 218);
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasRegion(result.regions, .before, 48, 88, null));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 48, 88, null));
}

test "reciprocal row moves are grouped only when both rows exchange intact" {
    const before = try sample.Canvas.init(256, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 160);
    defer after.deinit();
    const upper = 40;
    const pitch = 40;
    before.line(22, 212, upper + 10, 4, 60);
    before.line(22, 212, upper + pitch + 10, 9, 60);
    after.copyRows(upper, before, upper + pitch, upper + pitch * 2);
    after.copyRows(upper + pitch, before, upper, upper + pitch);
    const removed = Box.fromPixels(18, upper + 6, 200, 18);
    const inserted = Box.fromPixels(18, upper + pitch + 6, 200, 18);
    const candidates = [_]regions.Candidate{
        .{ .region = .{ .before = removed }, .pixels = 8 },
        .{ .region = .{ .after = inserted }, .pixels = 8 },
    };
    const move: values.Move = .{
        .before = .{ .y = upper + pitch, .height = pitch },
        .after = .{ .y = upper, .height = pitch },
        .x = .init(18),
        .width = .init(200),
    };
    var copy = candidates;
    try std.testing.expectEqual(@as(?usize, 1), regions.mergeSwap(&copy, &.{move}, before.view, after.view, .one));
    try std.testing.expect(copy[0].region.before != null and copy[0].region.after != null);
    after.fill(22, upper + pitch + 11, 7, 7, .{ 180, 18, 36, 255 });
    copy = candidates;
    try std.testing.expectEqual(@as(?usize, null), regions.mergeSwap(&copy, &.{move}, before.view, after.view, .one));
    try std.testing.expectEqualDeep(candidates, copy);
}

test "separate table cell edits stay separate unless both rows exchange intact" {
    const before = try sample.Canvas.init(256, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 160);
    defer after.deinit();
    const upper = 40;
    const pitch = 40;
    const left = 24;
    const right = 140;
    for ([_]usize{ left, right }) |x| {
        before.fill(x, upper, 30, 16, sample.inkShade(44, 4));
        before.fill(x, upper + pitch, 30, 16, sample.inkShade(126, 4));
    }
    after.copyRows(upper, before, upper + pitch, upper + pitch * 2);
    after.copyRows(upper + pitch, before, upper, upper + pitch);
    const table = try compareCanvases(before, after, 1);
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.regions.len);
    try std.testing.expect(sample.hasRegion(table.regions, .after, left + 1, upper + 1, .changed));
    try std.testing.expect(sample.hasRegion(table.regions, .after, right + 1, upper + pitch + 1, .changed));
    after.fill(right, upper + pitch, 30, 16, sample.inkShade(172, 4));
    const independent = try compareCanvases(before, after, 1);
    defer independent.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), independent.regions.len);
    try std.testing.expect(sample.hasRegion(independent.regions, .after, right + 1, upper + pitch + 1, .changed));
}

test "audit: a count edit between the exchanged rows remains a separate change" {
    const before = try sample.Canvas.init(256, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 160);
    defer after.deinit();
    before.line(24, 160, 40, 1, 62);
    before.line(94, 145, 80, 3, 62);
    before.line(24, 160, 120, 7, 62);
    after.copyRows(40, before, 120, 134);
    after.copyRows(120, before, 40, 54);
    after.line(94, 145, 80, 4, 62);
    const boxes = [_]Box{
        Box.fromPixels(24, 40, 136, 14),
        Box.fromPixels(94, 80, 51, 14),
        Box.fromPixels(24, 120, 136, 14),
    };
    var candidates: [boxes.len]regions.Candidate = undefined;
    for (boxes, &candidates) |box, *candidate| candidate.* = .{
        .region = .{ .before = box, .after = box },
        .pixels = 8,
    };
    const original = candidates;
    try std.testing.expectEqual(@as(?usize, null), regions.mergeSwap(&candidates, &.{}, before.view, after.view, .one));
    try std.testing.expectEqualDeep(original, candidates);
}

test "a tab transfer groups its indicator and reciprocal label colors" {
    const before = try sample.Canvas.init(256, 120);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 120);
    defer after.deinit();
    const active = sample.inkShade(32, 4);
    const idle = sample.inkShade(112, 4);
    const indicator = .{ 92, 38, 211, 255 };
    before.fill(32, 24, 68, 9, active);
    before.fill(108, 24, 78, 9, idle);
    before.fill(24, 47, 65, 3, indicator);
    after.fill(32, 24, 68, 9, idle);
    after.fill(108, 24, 78, 9, active);
    after.fill(108, 47, 82, 3, indicator);
    const transfer = try compareCanvases(before, after, 1);
    defer transfer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), transfer.regions.len);
    try std.testing.expect(sample.hasRegion(transfer.regions, .before, 25, 48, .changed));
    try std.testing.expect(sample.hasRegion(transfer.regions, .after, 185, 48, .changed));

    // Rename the right-hand label at the same time as moving the indicator.
    after.fill(108, 24, 78, 9, .{ 255, 255, 255, 255 });
    after.line(108, 186, 24, 7, 48);
    const separate = try compareCanvases(before, after, 1);
    defer separate.deinit(std.testing.allocator);
    try std.testing.expect(separate.regions.len > 1);
    try std.testing.expect(sample.hasRegion(separate.regions, .before, 110, 25, .changed));
    try std.testing.expect(sample.hasRegion(separate.regions, .after, 110, 25, .changed));
}

test "four corners follow a continuous outline even when its straight edges differ in color" {
    const before = try sample.Canvas.init(250, 150);
    defer before.deinit();
    const after = try sample.Canvas.init(250, 150);
    defer after.deinit();
    const boxes = [_]Box{
        Box.fromPixels(32, 26, 14, 14),
        Box.fromPixels(202, 26, 14, 14),
        Box.fromPixels(32, 116, 14, 14),
        Box.fromPixels(202, 116, 14, 14),
    };
    var edits: [boxes.len]regions.Candidate = undefined;
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(32, 28, 184, 3, .{ 60, 90, 150, 255 });
        canvas.fill(32, 124, 184, 3, .{ 120, 90, 62, 255 });
        for ([_]usize{ 32, 214 }) |x| {
            canvas.fill(x, 28, 2, 12, .{ 60, 90, 150, 255 });
            canvas.fill(x, 116, 2, 11, .{ 120, 90, 62, 255 });
        }
        canvas.fill(35, 40, 4, 76, sample.inkShade(75, 4));
        canvas.fill(210, 40, 4, 76, sample.inkShade(75, 4));
    }
    for (boxes, &edits) |box, *edit| {
        const x: usize = @intFromFloat(box.x);
        const y: usize = @intFromFloat(box.y);
        before.fill(x + 2, y + 3, 8, 6, sample.inkShade(80, 4));
        after.fill(x + 3, y + 4, 6, 4, sample.inkShade(80, 4));
        edit.* = .{ .region = .{ .before = box, .after = box }, .pixels = 8 };
    }
    var candidates = edits;
    try std.testing.expectEqual(@as(usize, 1), regions.mergeCorners(&candidates, before.view, after.view, .one));
    for ([_]sample.Canvas{ before, after }) |canvas| canvas.fill(104, 20, 16, 115, sample.inkShade(255, 4));
    candidates = edits;
    try std.testing.expectEqual(edits.len, regions.mergeCorners(&candidates, before.view, after.view, .one));
    try std.testing.expectEqualDeep(edits, candidates);
}

test "viewport clipped corners join only across a continuous straight edge" {
    const before = try sample.Canvas.init(250, 64);
    defer before.deinit();
    const after = try sample.Canvas.init(250, 64);
    defer after.deinit();
    const a = Box.fromPixels(32, 45, 14, 19);
    const b = Box.fromPixels(202, 45, 14, 19);
    const edits = [_]regions.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    for ([_]sample.Canvas{ before, after }, [_]usize{ 8, 4 }) |canvas, shape| {
        canvas.fill(32, 48, 184, 5, sample.inkShade(88, 4));
        canvas.fill(32, 48, 2, 12, sample.inkShade(88, 4));
        canvas.fill(214, 48, 2, 12, sample.inkShade(88, 4));
        canvas.fill(34, 55, shape, 9, sample.inkShade(68, 4));
        canvas.fill(205, 55, shape, 9, sample.inkShade(68, 4));
    }
    var candidates = edits;
    try std.testing.expectEqual(@as(usize, 1), regions.mergeCorners(&candidates, before.view, after.view, .one));
    for ([_]sample.Canvas{ before, after }) |canvas| canvas.fill(116, 44, 18, 20, sample.inkShade(255, 4));
    candidates = edits;
    try std.testing.expectEqual(edits.len, regions.mergeCorners(&candidates, before.view, after.view, .one));
    try std.testing.expectEqualDeep(edits, candidates);
}

test "audit: unrelated bottom-clipped labels on one footer stay separate" {
    const before = try sample.Canvas.init(280, 90);
    defer before.deinit();
    const after = try sample.Canvas.init(280, 90);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }, [_]usize{ 3, 4 }) |canvas, seed| {
        canvas.fill(0, 73, 280, 17, .{ 37, 40, 49, 255 });
        canvas.line(24, 70, 80, seed, 190);
        canvas.line(204, 250, 80, seed + 6, 190);
    }
    const a = Box.fromPixels(24, 73, 46, 17);
    const b = Box.fromPixels(204, 73, 46, 17);
    const edits = [_]regions.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    var candidates = edits;
    try std.testing.expectEqual(edits.len, regions.mergeCorners(&candidates, before.view, after.view, .one));
    try std.testing.expectEqualDeep(edits, candidates);
}

test "round 25 audit: glyph stems below a divider do not close the corners" {
    const before = try sample.Canvas.init(280, 90);
    defer before.deinit();
    const after = try sample.Canvas.init(280, 90);
    defer after.deinit();
    const ink: values.Pixel = .{ 51, 51, 51, 255 };
    for ([_]sample.Canvas{ before, after }) |canvas| {
        canvas.fill(24, 73, 226, 1, ink);
        canvas.fill(26, 80, 2, 5, ink);
        canvas.fill(247, 80, 2, 5, ink);
    }
    after.fill(29, 82, 6, 5, ink);
    after.fill(239, 82, 6, 5, ink);
    const a = Box.fromPixels(24, 73, 46, 17);
    const b = Box.fromPixels(204, 73, 46, 17);
    var edits = [_]regions.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    try std.testing.expectEqual(edits.len, regions.mergeCorners(&edits, before.view, after.view, .one));
}

test "corner rail reach follows logical scale at double density" {
    const image = try sample.Canvas.init(2700, 54);
    defer image.deinit();
    const ink = sample.inkShade(63, 4);
    image.fill(22, 39, 2592, 2, ink);
    image.fill(22, 39, 1, 13, ink);
    image.fill(2613, 39, 1, 13, ink);
    const a = Box.fromPixels(20, 36, 16, 18);
    const b = Box.fromPixels(2600, 36, 16, 18);
    var edits = [_]regions.Candidate{
        .{ .region = .{ .before = a, .after = a }, .pixels = 8 },
        .{ .region = .{ .before = b, .after = b }, .pixels = 8 },
    };
    try std.testing.expectEqual(edits.len, regions.mergeCorners(&edits, image.view, image.view, .one));
    try std.testing.expectEqual(@as(usize, 1), regions.mergeCorners(&edits, image.view, image.view, Scale.parse("2").?));
}

test "a card grid pairs translated cards across the gutter only when their pixels agree" {
    const before = try sample.Canvas.init(340, 130);
    defer before.deinit();
    const after = try sample.Canvas.init(340, 130);
    defer after.deinit();
    const x = 24;
    const pitch = 100;
    const top = 30;
    const height = 64;
    const width = 80;
    for ([_]u8{ 105, 155, 205 }, 0..) |ink, slot| {
        before.fill(x + pitch * slot, top, width, height, sample.inkShade(ink, 4));
        if (slot > 0) after.fill(x + pitch * (slot - 1), top, width, height, sample.inkShade(ink, 4));
    }
    const shifted = try compareCanvases(before, after, 1);
    defer shifted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), shifted.regions.len);
    try std.testing.expect(sample.hasRegion(shifted.regions, .before, x + 1, top + 1, .removed));
    try std.testing.expectEqual(@as(f64, @floatFromInt(pitch)), shifted.regions[1].before.?.x - shifted.regions[1].after.?.x);
    try std.testing.expectEqual(@as(f64, @floatFromInt(pitch)), shifted.regions[2].before.?.x - shifted.regions[2].after.?.x);

    const inserted = try compareCanvases(after, before, 1);
    defer inserted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), inserted.regions.len);
    try std.testing.expect(sample.hasRegion(inserted.regions, .after, x + 1, top + 1, .inserted));
    for (inserted.regions) |edit| {
        if (edit.kind == .changed)
            try std.testing.expectEqual(@as(f64, @floatFromInt(pitch)), edit.after.?.x - edit.before.?.x);
    }

    after.fill(x + 10, top + 11, 12, 8, .{ 230, 59, 110, 255 });
    const edited = try compareCanvases(before, after, 1);
    defer edited.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasRegion(edited.regions, .before, x + 11, top + 12, .changed));
    try std.testing.expect(sample.hasRegion(edited.regions, .after, x + 11, top + 12, .changed));
}

test "a modal does not hide a changed page behind its scrim" {
    const before = try sample.Canvas.init(192, 160);
    defer before.deinit();
    const after = try sample.Canvas.init(192, 160);
    defer after.deinit();
    before.fill(0, 0, 50, 160, sample.inkShade(192, 4));
    before.fill(50, 0, 142, 42, sample.inkShade(220, 4));
    for (before.pixels, after.pixels) |ink, *shade| {
        shade.* = .{ ink[0] / 2, ink[1] / 2, ink[2] / 2, 255 };
    }
    after.fill(52, 52, 88, 56, sample.inkShade(216, 4));
    after.fill(12, 20, 24, 16, sample.inkShade(58, 4));
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.changed, result.regions[0].kind);
    try std.testing.expect(result.regions[0].before != null);
}

test "redrawn status pills in stationary rows cannot borrow each other's offset" {
    const before = try sample.Canvas.init(360, 230);
    defer before.deinit();
    const after = try sample.Canvas.init(360, 230);
    defer after.deinit();
    for ([_]sample.Canvas{ before, after }) |canvas| {
        for (0..4) |i| canvas.line(18, 220, 28 + 48 * i, i, 48);
    }
    const a: values.Pixel = .{ 160, 190, 230, 255 };
    const b: values.Pixel = .{ 242, 150, 120, 255 };
    const c: values.Pixel = .{ 146, 210, 145, 255 };
    for ([_]usize{ 64, 112 }, [_]values.Pixel{ a, b }, [_]values.Pixel{ c, a }) |y, old, new| {
        before.fill(245, y, 70, 24, old);
        after.fill(245, y, 70, 24, new);
        before.fill(255, y + 9, 18, 5, sample.inkShade(60, 4));
        after.fill(255, y + 9, 18, 5, sample.inkShade(60, 4));
    }
    const result = try compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    for (result.regions) |region| try std.testing.expectEqual(Kind.changed, region.kind);
    try std.testing.expectEqual(@as(usize, 0), result.moves.len);
}

test {
    std.testing.refAllDecls(@This());
}
