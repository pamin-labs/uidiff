//! The versioned JSON report of a comparison, shared by the CLI and its consumers.
const std = @import("std");
const values = @import("value.zig");

/// Version-one coordinates in device pixels.
pub const Box = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    fn convert(box: ?values.Box) ?Box {
        const b = box orelse return null;
        return .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height };
    }
};

/// Version-one region. An absent side is serialized as null.
pub const Region = struct {
    number: usize,
    kind: values.Kind,
    before: ?Box,
    after: ?Box,
};

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
pub const Report = struct {
    version: u32,
    regions: []const Region,
    width: usize,
    height: usize,
    moves: []const Move = &.{},
};

/// Allocation or writer failures while serializing the response.
pub const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Schema version emitted with each report.
pub const version: u32 = 1;

/// Writes the versioned report and a terminating newline.
pub fn write(allocator: std.mem.Allocator, output: *std.Io.Writer, regions: []const values.Region, canvas: values.Size, moves: []const values.Move) WriteError!void {
    const wire = try allocator.alloc(Region, regions.len);
    defer allocator.free(wire);
    for (wire, regions) |*out, region| {
        out.* = .{ .number = region.number, .kind = region.kind, .before = Box.convert(region.before), .after = Box.convert(region.after) };
    }
    const wire_moves = try allocator.alloc(Move, moves.len);
    defer allocator.free(wire_moves);
    for (wire_moves, moves) |*out, move| out.* = Move.convert(move);
    const report: Report = .{ .version = version, .regions = wire, .width = canvas.width, .height = canvas.height, .moves = wire_moves };
    try std.json.Stringify.value(report, .{}, output);
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

test "writing releases each allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, writeOnce, .{@as([]const values.Region, &.{
        .{ .number = 1, .kind = .changed, .before = values.Box.fromPixels(1, 1, 2, 2), .after = values.Box.fromPixels(1, 2, 2, 2) },
    })});
}

test {
    std.testing.refAllDecls(@This());
}
