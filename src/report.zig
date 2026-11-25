//! The versioned JSON report of a comparison, shared by the CLI and its consumers.
const std = @import("std");
const values = @import("value.zig");

/// Version-one coordinates in device pixels.
pub const Box = Wire(f64).Bounds;

/// Version-one region. An absent side is serialized as null.
pub const Region = Wire(f64).Change;

/// Version-one row start and length in source device pixels.
pub const RowRange = struct { y: usize, height: usize };

/// Version-one alignment record in source device pixels.
pub const Move = struct {
    before: RowRange,
    after: RowRange,
    x: usize,
    width: usize,

    fn convert(move: values.Move) Move {
        return .{
            .before = .{ .y = move.before.y, .height = move.before.height },
            .after = .{ .y = move.after.y, .height = move.after.height },
            .x = move.x.count(),
            .width = move.width.count(),
        };
    }
};

/// Versioned response envelope with the combined canvas dimensions.
pub const Report = Wire(f64).Envelope;

/// Allocation or writer failures while serializing the response.
pub const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Report failures, including a coordinate outside the whole-pixel domain.
pub const PixelWriteError = WriteError || Wire(usize).CoordinateError;

/// Schema version emitted with each report.
pub const version: u32 = 1;

/// Writes the versioned report and a terminating newline.
pub fn write(_: std.mem.Allocator, output: *std.Io.Writer, regions: []const values.Region, canvas: values.Size, moves: []const values.Move) WriteError!void {
    return writeWith(f64, output, regions, canvas, moves);
}

/// Writes a comparison's rounded boxes without linking float formatting.
pub fn writeWholePixels(_: std.mem.Allocator, output: *std.Io.Writer, regions: []const values.Region, canvas: values.Size, moves: []const values.Move) PixelWriteError!void {
    return writeWith(usize, output, regions, canvas, moves);
}

fn Wire(comptime Coordinate: type) type {
    return struct {
        const CoordinateError = if (Coordinate == f64) error{} else error{InvalidRegionBox};
        const Bounds = struct { x: Coordinate, y: Coordinate, width: Coordinate, height: Coordinate };
        const Change = struct { number: usize, kind: values.Kind, before: ?Bounds, after: ?Bounds };
        const Envelope = struct { version: u32, regions: []const Change, width: usize, height: usize, moves: []const Move = &.{} };

        fn validate(box: ?values.Box) CoordinateError!void {
            const b = box orelse return;
            const geometry: @Vector(4, f64) = .{ b.x, b.y, b.width, b.height };
            if (!@reduce(.And, geometry >= @as(@Vector(4, f64), @splat(0))) or
                !@reduce(.And, geometry <= @as(@Vector(4, f64), @splat(values.max_extent))) or
                !@reduce(.And, @floor(geometry) == geometry)) return error.InvalidRegionBox;
        }

        fn convert(box: ?values.Box) ?Bounds {
            const b = box orelse return null;
            return .{ .x = coordinate(b.x), .y = coordinate(b.y), .width = coordinate(b.width), .height = coordinate(b.height) };
        }

        fn coordinate(value: f64) Coordinate {
            return if (Coordinate == f64) value else @intFromFloat(value);
        }
    };
}

fn writeWith(comptime Coordinate: type, output: *std.Io.Writer, regions: []const values.Region, canvas: values.Size, moves: []const values.Move) (WriteError || Wire(Coordinate).CoordinateError)!void {
    const Format = Wire(Coordinate);
    if (Coordinate != f64) {
        // Keep invalid geometry from producing a partial report.
        for (regions) |region| {
            try Format.validate(region.before);
            try Format.validate(region.after);
        }
    }
    var json: std.json.Stringify = .{ .writer = output };
    try json.beginObject();
    inline for (comptime std.meta.tags(std.meta.FieldEnum(Format.Envelope))) |field| {
        try json.objectField(@tagName(field));
        switch (field) {
            .version => try json.write(version),
            .width => try json.write(canvas.width),
            .height => try json.write(canvas.height),
            .regions => {
                try json.beginArray();
                for (regions) |region| try json.write(Format.Change{
                    .number = region.number,
                    .kind = region.kind,
                    .before = Format.convert(region.before),
                    .after = Format.convert(region.after),
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

fn writeOnce(allocator: std.mem.Allocator, regions: []const values.Region) !void {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    write(allocator, &output.writer, regions, .{ .width = 8, .height = 8 }, &.{.{ .before = .{ .y = 1, .height = 2 }, .after = .{ .y = 2, .height = 2 }, .x = .init(0), .width = .init(8) }}) catch |err| switch (err) {
        // The allocating writer reports its own allocation failure as a write failure.
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
}

test "version one writes inserted geometry and a null before box" {
    const allocator = std.testing.allocator;
    const after = values.Box.fromPixels(11, 20, 28, 14);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try write(allocator, &output.writer, &.{.{ .number = 1, .kind = .inserted, .after = after }}, .{ .width = 64, .height = 64 }, &.{});
    const parsed = try std.json.parseFromSlice(Report, allocator, output.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(version, parsed.value.version);
    try std.testing.expectEqual(@as(usize, 64), parsed.value.width);
    try std.testing.expectEqual(@as(usize, 64), parsed.value.height);
    try std.testing.expectEqualSlices(Region, &.{
        .{ .number = 1, .kind = .inserted, .before = null, .after = .{ .x = 11, .y = 20, .width = 28, .height = 14 } },
    }, parsed.value.regions);
}

test "whole-pixel reports retain the version-one geometry" {
    const allocator = std.testing.allocator;
    var rounded: std.Io.Writer.Allocating = .init(allocator);
    defer rounded.deinit();
    var general: std.Io.Writer.Allocating = .init(allocator);
    defer general.deinit();
    const box = values.Box.fromPixels(15, 28, 41, 6);
    const edits = [_]values.Region{.{ .number = 1, .kind = .changed, .before = box, .after = box }};
    const canvas: values.Size = .{ .width = 90, .height = 60 };
    try writeWholePixels(allocator, &rounded.writer, &edits, canvas, &.{});
    try write(allocator, &general.writer, &edits, canvas, &.{});
    const a = try std.json.parseFromSlice(Report, allocator, rounded.written(), .{ .ignore_unknown_fields = true });
    defer a.deinit();
    const b = try std.json.parseFromSlice(Report, allocator, general.written(), .{ .ignore_unknown_fields = true });
    defer b.deinit();
    try std.testing.expectEqualDeep(b.value, a.value);

    var fractional = edits;
    fractional[0].after.?.x += 0.5;
    const written = rounded.written().len;
    try std.testing.expectError(error.InvalidRegionBox, writeWholePixels(allocator, &rounded.writer, &fractional, canvas, &.{}));
    try std.testing.expectEqual(written, rounded.written().len);
}

test "writing releases each allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, writeOnce, .{@as([]const values.Region, &.{
        .{ .number = 1, .kind = .changed, .before = values.Box.fromPixels(1, 1, 2, 2), .after = values.Box.fromPixels(1, 2, 2, 2) },
    })});
}

test {
    std.testing.refAllDecls(@This());
}
