//! The versioned JSON report of a comparison, shared by the CLI and its consumers.
const std = @import("std");
const value = @import("value.zig");

/// Version-one coordinates in device pixels.
pub const Box = struct {
    /// Left edge in source device pixels.
    x: f64,
    /// Top edge in source device pixels.
    y: f64,
    /// Horizontal extent in source device pixels.
    width: f64,
    /// Vertical extent in source device pixels.
    height: f64,
};

/// Version-one region. An absent side is serialized as null.
pub const Region = struct {
    /// One-based region number in reading order.
    number: usize,
    /// Classification of the region.
    kind: value.Kind,
    /// Box on the before image, or null when absent on that side.
    before: ?Box,
    /// Box on the after image, or null when absent on that side.
    after: ?Box,
};

/// Version-one row start and length in source device pixels.
pub const RowRange = struct {
    /// First row of the range in source device pixels.
    y: usize,
    /// Number of rows in the half-open range.
    height: usize,
};

/// Version-one alignment record in source device pixels.
pub const Move = struct {
    /// Aligned rows on the before image.
    before: RowRange,
    /// Aligned rows on the after image.
    after: RowRange,
    /// Left edge of the source columns shared by both sides.
    x: usize,
    /// Number of source columns in the block.
    width: usize,

    /// Converts a comparison's move to its wire form.
    pub fn convert(move: value.Move) Move {
        return .{
            .before = .{ .y = move.before.y, .height = move.before.height },
            .after = .{ .y = move.after.y, .height = move.after.height },
            .x = move.x,
            .width = move.width,
        };
    }
};

/// Versioned response envelope with the combined canvas dimensions.
pub const Report = struct {
    /// Version of the wire schema.
    version: u32,
    /// Numbered regions in reading order.
    regions: []const Region,
    /// Larger source width, in device pixels.
    width: usize,
    /// Larger source height, in device pixels.
    height: usize,
    /// Aligned blocks detected at different vertical positions.
    moves: []const Move = &.{},
};

/// Report failures, including a coordinate outside the whole-pixel domain.
pub const PixelWriteError = std.Io.Writer.Error || error{InvalidRegionBox};

const PixelBox = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    fn validate(box: ?value.Box) error{InvalidRegionBox}!void {
        const b = box orelse return;
        const geometry: @Vector(4, f64) = .{ b.x, b.y, b.width, b.height };
        if (!@reduce(.And, geometry >= @as(@Vector(4, f64), @splat(0))) or
            !@reduce(.And, geometry <= @as(@Vector(4, f64), @splat(value.max_extent))) or
            !@reduce(.And, @floor(geometry) == geometry)) return error.InvalidRegionBox;
    }

    fn fromValidated(box: ?value.Box) ?PixelBox {
        const b = box orelse return null;
        return .{ .x = @intFromFloat(b.x), .y = @intFromFloat(b.y), .width = @intFromFloat(b.width), .height = @intFromFloat(b.height) };
    }
};

const PixelRegion = struct { number: usize, kind: value.Kind, before: ?PixelBox, after: ?PixelBox };

/// Schema version emitted with each report.
pub const version: u32 = 1;

/// Writes a comparison's rounded boxes without linking float formatting.
pub fn writeWholePixels(output: *std.Io.Writer, regions: []const value.Region, canvas: value.Size, moves: []const value.Move) PixelWriteError!void {
    // Keep invalid geometry from producing a partial report.
    for (regions) |region| {
        try PixelBox.validate(region.before);
        try PixelBox.validate(region.after);
    }
    var json: std.json.Stringify = .{ .writer = output };
    try json.beginObject();
    inline for (comptime std.meta.tags(std.meta.FieldEnum(Report))) |field| {
        try json.objectField(@tagName(field));
        switch (field) {
            .version => try json.write(version),
            .width => try json.write(canvas.width),
            .height => try json.write(canvas.height),
            .regions => {
                try json.beginArray();
                for (regions) |region| try json.write(PixelRegion{
                    .number = region.number,
                    .kind = region.kind(),
                    .before = PixelBox.fromValidated(region.before),
                    .after = PixelBox.fromValidated(region.after),
                });
                try json.endArray();
            },
            .moves => {
                try json.beginArray();
                for (moves) |move| try json.write(Move.convert(move));
                try json.endArray();
            },
        }
    }
    try json.endObject();
    try output.writeByte('\n');
}

test "version one writes inserted geometry and a null before box" {
    const allocator = std.testing.allocator;
    const after = value.Box.fromPixels(11, 20, 28, 14);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeWholePixels(&output.writer, &.{.{ .number = 1, .after = after }}, .{ .width = 64, .height = 64 }, &.{});
    const parsed = try std.json.parseFromSlice(Report, allocator, output.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(version, parsed.value.version);
    try std.testing.expectEqual(@as(usize, 64), parsed.value.width);
    try std.testing.expectEqual(@as(usize, 64), parsed.value.height);
    try std.testing.expectEqualSlices(Region, &.{
        .{ .number = 1, .kind = .inserted, .before = null, .after = .{ .x = 11, .y = 20, .width = 28, .height = 14 } },
    }, parsed.value.regions);
}

test "whole-pixel reports reject fractional geometry before writing" {
    const allocator = std.testing.allocator;
    var rounded: std.Io.Writer.Allocating = .init(allocator);
    defer rounded.deinit();
    var box = value.Box.fromPixels(15, 28, 41, 6);
    box.x += 0.5;
    const edits = [_]value.Region{.{ .number = 1, .after = box }};
    const canvas: value.Size = .{ .width = 90, .height = 60 };
    try std.testing.expectError(error.InvalidRegionBox, writeWholePixels(&rounded.writer, &edits, canvas, &.{}));
    try std.testing.expectEqual(@as(usize, 0), rounded.written().len);
}

test {
    std.testing.refAllDecls(@This());
}
