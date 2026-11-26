//! Fuzzes the comparison with small RGBA pairs, half of them sharing shifted rows.
const std = @import("std");
const uidiff = @import("uidiff");
const fuzz = @import("uidiff_testing").fuzz;
const testing = std.testing;

/// Scales are drawn as quarters from 1/4 to 4.
const max_scale_quarters = 16;

fn fuzzCompare(_: void, smith: *testing.Smith) !void {
    var before_pixels: fuzz.Storage = undefined;
    var after_pixels: fuzz.Storage = undefined;
    const before = fuzz.image(smith, &before_pixels);
    const after = fuzz.image(smith, &after_pixels);
    if (smith.value(bool)) {
        const shift = smith.valueRangeAtMost(u8, 0, fuzz.extent);
        const shared_width = @min(before.width, after.width);
        for (shift..@max(shift, @min(after.height, before.height + shift))) |y| {
            const start = y * after.width;
            @memcpy(after_pixels[start..][0..shared_width], before.pixels[(y - shift) * before.width ..][0..shared_width]);
        }
    }
    const scale: f64 = @as(f64, @floatFromInt(smith.valueRangeAtMost(u8, 1, max_scale_quarters))) / 4;
    const result = try uidiff.compare(testing.allocator, before, after, .{ .scale = .{ .factor = scale } });
    defer result.deinit(testing.allocator);
    try testing.expect(result.regions.len <= uidiff.max_regions);
    try testing.expectEqual(@max(before.width, after.width), result.width);
    try testing.expectEqual(@max(before.height, after.height), result.height);
    for (result.regions, 1..) |region, number| {
        try testing.expectEqual(number, region.number);
        try testing.expect(region.before != null or region.after != null);
        if (region.before) |box| try checkBounds(box, before.size());
        if (region.after) |box| try checkBounds(box, after.size());
    }
}

fn checkBounds(box: uidiff.Box, size: uidiff.Size) !void {
    try testing.expect(box.x >= 0 and box.y >= 0 and box.width > 0 and box.height > 0);
    try testing.expect(box.right() <= @as(f64, @floatFromInt(size.width)));
    try testing.expect(box.bottom() <= @as(f64, @floatFromInt(size.height)));
}

test "fuzz small RGBA screenshot pairs" {
    try testing.fuzz({}, fuzzCompare, .{});
}

test {
    std.testing.refAllDecls(@This());
}
