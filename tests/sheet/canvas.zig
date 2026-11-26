//! Scenario coverage for canvas in a comparison sheet.
const std = @import("std");
const uidiff = @import("uidiff");
const sheet = uidiff.testing.sheet;
const Rect = sheet.Rect;
const Pixel = uidiff.Pixel;

test "badge digits preserve native bold bitmap coverage" {
    const page = sheet.page;
    const ui = sheet.Layout.init(.{ .width = 900, .height = 12 }, .{ .width = 900, .height = 12 });
    const diameter = sheet.overviewDiameter(ui);
    const bounds: Rect = .{ .x = 0, .y = 0, .w = diameter, .h = diameter };
    const storage = try std.testing.allocator.alloc(Pixel, diameter);
    defer std.testing.allocator.free(storage);
    const base = sheet.tint(.changed);
    for ("0123456789") |digit| {
        const g = sheet.glyph(.bold, digit);
        const x = (diameter - g[3]) / 2;
        const y = (diameter - g[4]) / 2;
        for (0..g[4]) |gy| {
            @memset(storage, page);
            sheet.badge(.{ .pixels = storage, .y = y + gy }, bounds, .changed, &.{digit}, ui);
            for (0..g[3]) |gx| {
                const sample = gy * g[3] + gx;
                const packed_ = g[5 + sample / 2];
                const alpha: u16 = if (sample % 2 == 0) packed_ & 15 else packed_ >> 4;
                for (0..3) |channel| {
                    const expected: u8 = @intCast((@as(u16, base[channel]) * (15 - alpha) + 255 * alpha + 7) / 15);
                    try std.testing.expectEqual(expected, storage[x + gx][channel]);
                }
            }
        }
    }
}
