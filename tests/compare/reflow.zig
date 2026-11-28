//! End-to-end recognition of row, tab and card reflow.

const std = @import("std");
const uidiff_testing = @import("uidiff_testing");
const expect = uidiff_testing.expect;
const canvas = uidiff_testing.canvas;

test "separate table cell edits stay separate unless both rows exchange intact" {
    const pair = try canvas.RowExchange.init();
    defer pair.deinit();
    const before, const after = .{ pair.before, pair.after };
    const upper, const pitch = .{ canvas.RowExchange.upper, canvas.RowExchange.pitch };
    const left = 24;
    const right = 140;
    for ([_]usize{ left, right }) |x| {
        before.fill(x, upper, 30, 16, canvas.inkShade(44, 4));
        before.fill(x, upper + pitch, 30, 16, canvas.inkShade(126, 4));
    }
    pair.exchange();
    const table = try expect.compareCanvases(before, after, 1);
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.regions.len);
    try std.testing.expect(expect.hasRegion(table.regions, .after, left + 1, upper + 1, .changed));
    try std.testing.expect(expect.hasRegion(table.regions, .after, right + 1, upper + pitch + 1, .changed));
    after.fill(right, upper + pitch, 30, 16, canvas.inkShade(172, 4));
    const independent = try expect.compareCanvases(before, after, 1);
    defer independent.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), independent.regions.len);
    try std.testing.expect(expect.hasRegion(independent.regions, .after, right + 1, upper + pitch + 1, .changed));
}

test "a tab transfer groups its indicator and reciprocal label colors" {
    const before = try canvas.Canvas.init(256, 120);
    defer before.deinit();
    const after = try canvas.Canvas.init(256, 120);
    defer after.deinit();
    const active = canvas.inkShade(32, 4);
    const idle = canvas.inkShade(112, 4);
    const indicator = .{ 92, 38, 211, 255 };
    before.fill(32, 24, 68, 9, active);
    before.fill(108, 24, 78, 9, idle);
    before.fill(24, 47, 65, 3, indicator);
    after.fill(32, 24, 68, 9, idle);
    after.fill(108, 24, 78, 9, active);
    after.fill(108, 47, 82, 3, indicator);
    const transfer = try expect.compareCanvases(before, after, 1);
    defer transfer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), transfer.regions.len);
    try std.testing.expect(expect.hasRegion(transfer.regions, .before, 25, 48, .changed));
    try std.testing.expect(expect.hasRegion(transfer.regions, .after, 185, 48, .changed));

    // Rename the right-hand label at the same time as moving the indicator.
    after.fill(108, 24, 78, 9, canvas.white);
    after.line(108, 186, 24, 7, 48);
    const separate = try expect.compareCanvases(before, after, 1);
    defer separate.deinit(std.testing.allocator);
    try std.testing.expect(separate.regions.len > 1);
    try std.testing.expect(expect.hasRegion(separate.regions, .before, 110, 25, .changed));
    try std.testing.expect(expect.hasRegion(separate.regions, .after, 110, 25, .changed));
}

test "a card grid pairs translated cards across the gutter only when their pixels agree" {
    const before = try canvas.Canvas.init(340, 130);
    defer before.deinit();
    const after = try canvas.Canvas.init(340, 130);
    defer after.deinit();
    const x = 24;
    const pitch = 100;
    const top = 30;
    const height = 64;
    const width = 80;
    for ([_]u8{ 105, 155, 205 }, 0..) |ink, slot| {
        before.fill(x + pitch * slot, top, width, height, canvas.inkShade(ink, 4));
        if (slot > 0) after.fill(x + pitch * (slot - 1), top, width, height, canvas.inkShade(ink, 4));
    }
    const shifted = try expect.compareCanvases(before, after, 1);
    defer shifted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), shifted.regions.len);
    try std.testing.expect(expect.hasRegion(shifted.regions, .before, x + 1, top + 1, .removed));
    try std.testing.expectEqual(@as(f64, @floatFromInt(pitch)), shifted.regions[1].before.?.x - shifted.regions[1].after.?.x);
    try std.testing.expectEqual(@as(f64, @floatFromInt(pitch)), shifted.regions[2].before.?.x - shifted.regions[2].after.?.x);

    const inserted = try expect.compareCanvases(after, before, 1);
    defer inserted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), inserted.regions.len);
    try std.testing.expect(expect.hasRegion(inserted.regions, .after, x + 1, top + 1, .inserted));
    for (inserted.regions) |edit| {
        if (edit.kind() == .changed)
            try std.testing.expectEqual(@as(f64, @floatFromInt(pitch)), edit.after.?.x - edit.before.?.x);
    }

    after.fill(x + 10, top + 11, 12, 8, .{ 230, 59, 110, 255 });
    const edited = try expect.compareCanvases(before, after, 1);
    defer edited.deinit(std.testing.allocator);
    try std.testing.expect(expect.hasRegion(edited.regions, .before, x + 11, top + 12, .changed));
    try std.testing.expect(expect.hasRegion(edited.regions, .after, x + 11, top + 12, .changed));
}
