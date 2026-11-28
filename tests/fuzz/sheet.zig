//! Fuzzes label layout and sheet rendering with arbitrary regions, then the
//! PNG round trip of the sheet.
const std = @import("std");
const uidiff = @import("uidiff");
const fuzz = @import("uidiff_testing").fuzz;
const testing = std.testing;
const Region = uidiff.Region;

const max_regions = 2;

fn fuzzSheet(_: void, smith: *testing.Smith) !void {
    var before_pixels: fuzz.Storage = undefined;
    var after_pixels: fuzz.Storage = undefined;
    const before = fuzz.image(smith, &before_pixels);
    const after = fuzz.image(smith, &after_pixels);
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
    const canvas = (uidiff.Pair{ .before = before, .after = after }).canvas();
    const comparison: uidiff.Comparison = .{ .regions = regions, .width = canvas.width, .height = canvas.height };
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try uidiff.encodeSheet(testing.io, testing.allocator, .{ .before = before, .after = after }, comparison.regions, comparison.moves, &encoded.writer);
    var decoded = try uidiff.decode(testing.allocator, encoded.written(), uidiff.max_decode_bytes);
    defer decoded.deinit();
    try testing.expect(decoded.image.valid());
}

/// A whole-pixel box inside the image, the only boxes Region.check accepts.
fn box(smith: *testing.Smith, size: uidiff.Size) uidiff.Box {
    const x = smith.valueRangeAtMost(u16, 0, @intCast(size.width - 1));
    const y = smith.valueRangeAtMost(u16, 0, @intCast(size.height - 1));
    const width = smith.valueRangeAtMost(u16, 1, @intCast(size.width - x));
    const height = smith.valueRangeAtMost(u16, 1, @intCast(size.height - y));
    return .fromPixels(x, y, width, height);
}

test "fuzz annotated sheets and their PNG round trip" {
    try testing.fuzz({}, fuzzSheet, .{});
}

test {
    std.testing.refAllDecls(@This());
}
