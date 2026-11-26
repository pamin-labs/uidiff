//! Fuzzes label layout and sheet rendering with arbitrary regions, then the
//! PNG round trip of the sheet.
const std = @import("std");
const uidiff = @import("uidiff");
const rgba = uidiff.testing.fuzz;
const testing = std.testing;
const Region = uidiff.Region;

const max_regions = 2;

fn fuzzSheet(_: void, smith: *testing.Smith) !void {
    var before_pixels: rgba.Storage = undefined;
    var after_pixels: rgba.Storage = undefined;
    const before = rgba.image(smith, &before_pixels);
    const after = rgba.image(smith, &after_pixels);
    var storage: [max_regions]Region = undefined;
    const regions = storage[0..smith.valueRangeAtMost(u8, 0, max_regions)];
    for (regions, 1..) |*region, number| {
        const sides = smith.valueRangeAtMost(u8, 1, 3);
        region.* = .{
            .number = number,
            .before = if (sides & 1 != 0) box(smith, before.size()) else null,
            .after = if (sides & 2 != 0) box(smith, after.size()) else null,
        };
    }
    const comparison: uidiff.Comparison = .{
        .regions = regions,
        .width = @max(before.width, after.width),
        .height = @max(before.height, after.height),
    };
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try uidiff.encodeComparisonSheet(testing.allocator, before, after, comparison, &encoded.writer);
    var decoded = try uidiff.decode(testing.allocator, encoded.written());
    defer decoded.deinit();
    try testing.expect(decoded.image.valid());
}

/// A box inside the image, edges in whole and half pixels.
fn box(smith: *testing.Smith, size: uidiff.Size) uidiff.Box {
    const halves_x = smith.valueRangeAtMost(u16, 0, @intCast(2 * size.width - 1));
    const halves_y = smith.valueRangeAtMost(u16, 0, @intCast(2 * size.height - 1));
    const halves_w = smith.valueRangeAtMost(u16, 1, @intCast(2 * size.width - halves_x));
    const halves_h = smith.valueRangeAtMost(u16, 1, @intCast(2 * size.height - halves_y));
    return .{ .x = half(halves_x), .y = half(halves_y), .width = half(halves_w), .height = half(halves_h) };
}

fn half(n: u16) f64 {
    return @as(f64, @floatFromInt(n)) / 2;
}

test "fuzz annotated sheets and their PNG round trip" {
    try testing.fuzz({}, fuzzSheet, .{});
}

test {
    std.testing.refAllDecls(@This());
}
