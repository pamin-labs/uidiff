//! Compares validated images and emits numbered regions of change.
const std = @import("std");
const value = @import("value.zig");
const columns = @import("diff/columns.zig");
const rows = @import("diff/rows.zig");
const regions = @import("diff/regions.zig");
const span = @import("diff/span.zig");
const Allocator = std.mem.Allocator;
const Box = value.Box;
const Collector = regions.Collector;
const Image = value.Image;
const Scale = value.Scale;

/// The most regions a comparison reports; nearby ones merge to fit.
pub const max_regions = regions.max_regions;

const ScaleError = error{InvalidScale};

/// The validated scale consumed by compareChecked.
pub const Checked = struct { scale: Scale };

/// Parameters for comparing decoded images.
pub const Options = struct {
    /// Device pixels per CSS pixel.
    scale: Scale = .one,
};

/// Owns the returned regions and moves.
pub const Comparison = struct {
    /// Numbered regions in reading order.
    regions: []const value.Region,
    /// Aligned blocks detected at different vertical positions.
    moves: []const value.Move = &.{},
    /// The larger width of the two inputs, in device pixels.
    width: usize,
    /// The larger height of the two inputs, in device pixels.
    height: usize,

    /// Releases the regions and moves with the allocator passed to compare or compareFiles.
    pub fn deinit(self: Comparison, allocator: Allocator) void {
        allocator.free(self.regions);
        allocator.free(self.moves);
    }

    /// Returns the combined canvas dimensions.
    pub fn canvas(self: Comparison) value.Size {
        return .{ .width = self.width, .height = self.height };
    }
};

/// Input and scratch-space failures reported by the comparison domain.
pub const CompareError = Allocator.Error || ScaleError || value.Image.Invalid;

/// Space added around each reported box, in CSS pixels.
pub const region_padding = regions.padding.count();

/// Rejects a non-positive or non-finite scale before comparison.
pub fn checkOptions(options: Options) ScaleError!Checked {
    if (!options.scale.isValid()) return error.InvalidScale;
    return .{ .scale = options.scale };
}

/// Compares packed RGBA8 images. The caller owns the returned comparison.
pub fn compare(allocator: Allocator, before: Image, after: Image, options: Options) CompareError!Comparison {
    return compareChecked(allocator, before, after, try checkOptions(options));
}

/// Compares packed RGBA8 images with options already checked. The caller
/// owns the returned comparison.
pub fn compareChecked(allocator: Allocator, before: Image, after: Image, options: Checked) CompareError!Comparison {
    if (!before.valid() or !after.valid()) return error.InvalidImage;
    const pair: value.Pair = .{ .before = before, .after = after };
    const combined = pair.canvas();
    const width = combined.width;
    const height = combined.height;
    const max_gap_px: f64 = @floatFromInt(@max(width, height));
    const gap_px = @min(options.scale.devicePixels(regions.merge_gap), max_gap_px);
    const overlap_width = @min(before.width, after.width);
    const changed = columns.span(pair, overlap_width);
    if (changed.width == 0 and before.width == after.width) {
        return .{ .regions = &.{}, .width = width, .height = height };
    }
    // The integer gap and scroll tolerance are clamped to validated image dimensions.
    const capacity = if (changed.width == 0) 1 else Collector.capacity(before.size(), after.size(), @intFromFloat(gap_px));
    // The collector reads only the boxes it has stored.
    const storage = try value.allocUnfilled(regions.Candidate, allocator, capacity);
    defer value.freeUnfilled(regions.Candidate, allocator, storage);
    var collector = Collector.init(storage, before.size(), after.size(), gap_px, max_gap_px);
    var moves: std.ArrayList(value.Move) = .empty;
    defer moves.deinit(allocator);
    if (changed.width != 0) {
        const scope: columns.Scope = .{ .pair = pair, .span = changed, .bounds = .{ .left = 0, .width = overlap_width } };
        try span.collect(allocator, &collector, &moves, scope, @intFromFloat(@min(max_gap_px, options.scale.devicePixels(regions.scroll_shift))));
    }
    if (before.width != after.width) {
        const old = before.width > after.width;
        const box = Box.fromPixels(overlap_width, 0, width - overlap_width, if (old) before.height else after.height);
        collector.addOn(if (old) .before else .after, box);
    }
    const out = try regions.resolve(allocator, &collector, &moves, pair, options.scale, options.scale.devicePixels(regions.scroll_shift));
    errdefer allocator.free(out);
    return .{ .regions = out, .moves = try moves.toOwnedSlice(allocator), .width = width, .height = height };
}

test "invalid borrowed shapes and non-finite scales fail at the comparison boundary" {
    const one: Image = .{ .width = 1, .height = 1, .pixels = &.{@splat(255)} };
    const wrong: Image = .{ .width = std.math.maxInt(usize), .height = 2, .pixels = one.pixels };
    try std.testing.expectError(error.InvalidImage, compare(std.testing.allocator, wrong, one, .{}));
    try std.testing.expectError(error.InvalidScale, compare(std.testing.allocator, one, one, .{ .scale = .{ .factor = std.math.nan(f64) } }));
}

test "comparison releases each allocation on failure" {
    const fixture = struct {
        fn comparePair(allocator: Allocator, before: Image, after: Image) !void {
            const result = try compare(allocator, before, after, .{});
            defer result.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 1), result.regions.len);
            try std.testing.expectEqual(value.Kind.inserted, result.regions[0].kind());
        }
    };
    const old = [_]value.Pixel{ .{ 0, 0, 0, 255 }, .{ 10, 0, 0, 255 }, .{ 20, 0, 0, 255 }, .{ 30, 0, 0, 255 } };
    const new = old[0..2].* ++ [_]value.Pixel{.{ 64, 0, 0, 255 }} ++ old[2..].*;
    const before = Image{ .width = 1, .height = old.len, .pixels = &old };
    const after = Image{ .width = 1, .height = new.len, .pixels = &new };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture.comparePair, .{ before, after });
}

test {
    const canvas = @import("uidiff_test_canvas");
    std.testing.refAllDecls(canvas.Painters(Image));
}

test {
    std.testing.refAllDecls(@This());
}
