//! Checks the visible badge raster through the public sheet renderer.
const std = @import("std");
const uidiff = @import("uidiff");
const canvas = @import("uidiff_testing").canvas;
const Pixel = uidiff.Pixel;
const Image = uidiff.Image;
const Region = uidiff.Region;

test "the halo and color stroke leave the changed pixels uncovered" {
    const allocator = std.testing.allocator;
    const source: Pixel = .{ 17, 31, 61, 255 };
    const pixels: [160 * 100]Pixel = @splat(source);
    const image: Image = .{ .width = 160, .height = 100, .pixels = &pixels };
    const changed: Region = .{ .number = 1, .kind = .changed, .before = .fromPixels(80, 48, 30, 30) };
    const sheet = try uidiff.renderComparisonSheet(allocator, .{ .before = image, .after = image }, &.{changed}, &.{});
    defer sheet.deinit(allocator);

    // Screen-space samples capture the original halo and its protected interior.
    const line = sheet.image().row(434);
    const x = 368;
    try std.testing.expectEqual(source, line[x]);
    try std.testing.expectEqual(source, line[x - 1]);
    try std.testing.expectEqual(Pixel{ 234, 148, 0, 255 }, line[x - 3]);
    try std.testing.expectEqual(canvas.white, line[x - 4]);
    try std.testing.expectEqual(source, line[x - 6]);
}

test "top corner badges stay above the pane and clear of the caption" {
    const allocator = std.testing.allocator;
    const background: Pixel = .{ 244, 244, 245, 255 };
    const pixels: [80 * 80]Pixel = @splat(background);
    const image: Image = .{ .width = 80, .height = 80, .pixels = &pixels };
    const insert: Region = .{ .number = 1, .kind = .inserted, .after = .fromPixels(0, 0, 4, 4) };
    const sheet = try uidiff.renderComparisonSheet(allocator, .{ .before = image, .after = image }, &.{insert}, &.{});
    defer sheet.deinit(allocator);

    const view = sheet.image();
    try std.testing.expectEqual(background, view.row(174)[453]);
    try std.testing.expectEqual(canvas.white, view.row(152)[383]);
    try std.testing.expectEqual(Pixel{ 22, 163, 74, 255 }, view.row(152)[388]);
}

test "thin wide strips and crops draw full badges above their pixels" {
    const allocator = std.testing.allocator;
    const pixels: [900 * 12]Pixel = @splat(.{ 244, 244, 245, 255 });
    const image: Image = .{ .width = 900, .height = 12, .pixels = &pixels };
    const region: Region = .{ .number = 1, .kind = .changed, .after = .fromPixels(400, 0, 12, 12) };
    const sheet = try uidiff.renderComparisonSheet(allocator, .{ .before = image, .after = image }, &.{region}, &.{});
    defer sheet.deinit(allocator);

    const view = sheet.image();
    for ([_]struct { x: usize, top: usize, bottom: usize }{
        .{ .x = 1086, .top = 235, .bottom = 277 },
        .{ .x = 1515, .top = 369, .bottom = 427 },
    }) |badge| {
        try std.testing.expectEqual(canvas.white, view.row(badge.top)[badge.x]);
        try std.testing.expectEqual(canvas.white, view.row(badge.bottom)[badge.x]);
    }
}
