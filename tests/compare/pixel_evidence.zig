//! End-to-end pixel evidence for noise, edges, colour and alpha.

const std = @import("std");
const uidiff = @import("uidiff");
const uidiff_testing = @import("uidiff_testing");
const expect = uidiff_testing.expect;
const canvas = uidiff_testing.canvas;
const compare = uidiff.compare;
const Box = uidiff.Box;
const Image = uidiff.Image;
const Pixel = uidiff.Pixel;
const Kind = uidiff.Kind;
const min_region_pixels = canvas.block_size * canvas.block_size;

fn coverageGlyph(image: canvas.Canvas, phase: i32) void {
    const samples = 8;
    const area = samples * samples;
    // Coordinates use half a sample so each point is at a cell centre.
    for (14..34) |y| {
        for (25..44) |x| {
            var covered: u32 = 0;
            for (0..samples) |sy| {
                const dy = @as(i32, @intCast(2 * (y * samples + sy) + 1)) - 24 * 16;
                for (0..samples) |sx| {
                    const dx = @as(i32, @intCast(2 * (x * samples + sx) + 1)) - 34 * 16 - 2 * phase;
                    const stem = @abs(8 * dx + 3 * dy) < 64 and @abs(dy) < 144;
                    const bar = @abs(dy - 4 * 16) <= 10 and @abs(dx) < 112;
                    covered += @intFromBool(stem or bar);
                }
            }
            var pixel: Pixel = .{ 24, 26, 29, 255 };
            for (pixel[0..3]) |*channel| channel.* += @intCast(((180 - @as(u32, channel.*)) * covered + area / 2) / area);
            image.row(y)[x] = pixel;
        }
    }
}

test "one-step noise and two-step red variation are ignored" {
    const before = try canvas.Canvas.square();
    defer before.deinit();
    const after = try canvas.Canvas.square();
    defer after.deinit();
    after.pixels[0][0] = 254;
    try expect.count(before, after, 0);
    for (after.pixels) |*pixel| pixel[0] = 253;
    try expect.count(before, after, 0);
}

test "eight-step token colour and grey block or stroke changes are detected" {
    const before = try canvas.Canvas.square();
    defer before.deinit();
    const after = try canvas.Canvas.square();
    defer after.deinit();
    before.fill(10, 10, canvas.block_size, canvas.block_size, .{ 0x63, 0x65, 0x69, 255 });
    after.fill(10, 10, canvas.block_size, canvas.block_size, .{ 0x5b, 0x5d, 0x61, 255 });
    try expect.count(before, after, 1);
    for ([_]usize{ 6, 2 }) |width| {
        before.fill(10, 10, width, 6, .{ 100, 100, 100, 255 });
        after.fill(10, 10, width, 6, .{ 92, 92, 92, 255 });
        try expect.count(before, after, 1);
        @memset(before.pixels, canvas.white);
        @memset(after.pixels, canvas.white);
    }
}

test "one-pixel sideways shift of an anti-aliased sample.diagonal is ignored" {
    const before = try canvas.diagonal(0);
    defer before.deinit();
    const after = try canvas.diagonal(1);
    defer after.deinit();
    // An eight-step grey change already clears the YIQ threshold.
    for (before.pixels, after.pixels) |old, new| {
        if (@max(old[0], new[0]) - @min(old[0], new[0]) >= 8) break;
    } else return error.NoHighContrastPixels;
    try expect.count(before, after, 0);
}

test "thin aliased diagonals, dotted lines and crosses survive grouping" {
    const before = try canvas.Canvas.init(200, 200);
    defer before.deinit();
    for ([_]enum { diagonal, dots, cross }{ .diagonal, .dots, .cross }) |mark| {
        const after = try canvas.Canvas.init(200, 200);
        defer after.deinit();
        const box = switch (mark) {
            .diagonal => diagonal: {
                for (50..90) |p| after.row(p)[p] = .{ 0, 0, 0, 255 };
                break :diagonal expect.paddedBox(50, 50, 40, 40);
            },
            .dots => dots: {
                for (0..40) |p| after.row(100)[50 + 2 * p] = .{ 0, 0, 0, 255 };
                break :dots expect.paddedBox(50, 100, 79, 1);
            },
            .cross => cross: {
                for (0..7) |p| {
                    after.row(120 + p)[120 + p] = .{ 220, 0, 0, 255 };
                    after.row(120 + p)[126 - p] = .{ 220, 0, 0, 255 };
                }
                break :cross expect.paddedBox(120, 120, 7, 7);
            },
        };
        try expect.check(before, after, 1, &.{.{ .before = box, .after = box }});
    }
}

test "weak edge recolours need cardinal support before sample.diagonal grouping" {
    const before = try canvas.Canvas.square();
    defer before.deinit();
    const after = try canvas.Canvas.square();
    defer after.deinit();
    @memset(before.pixels, canvas.inkShade(24, 4));
    @memset(after.pixels, canvas.inkShade(24, 4));
    for (16..32) |p| {
        before.row(p)[p] = canvas.inkShade(120, 4);
        after.row(p)[p] = canvas.inkShade(128, 4);
        before.row(p)[p + 1] = canvas.inkShade(240, 4);
        after.row(p)[p + 1] = canvas.inkShade(240, 4);
    }
    try expect.count(before, after, 0);

    before.fill(36, 16, 4, 1, canvas.inkShade(120, 4));
    after.fill(36, 16, 4, 1, canvas.inkShade(128, 4));
    const box = expect.paddedBox(36, 16, 4, 1);
    try expect.check(before, after, 1, &.{.{ .before = box, .after = box }});
}

test "isolated low-amplitude specks stay below the reporting minimum" {
    const side = 240;
    const before = try canvas.Canvas.init(side, side);
    defer before.deinit();
    @memset(before.pixels, canvas.inkShade(200, 4));
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = prng.random();
    const after = try canvas.Canvas.init(side, side);
    defer after.deinit();
    for ([_]u8{ 2, 4 }) |amplitude| {
        for ([_]usize{ 3, 6, 10, 14, 24 }) |spacing| {
            @memcpy(after.pixels, before.pixels);
            var y: usize = 0;
            while (y < side) : (y += spacing) {
                var x = rand.uintLessThan(usize, spacing);
                while (x < side) : (x += spacing) {
                    const row = y + rand.uintLessThan(usize, @min(spacing, side - y));
                    after.row(row)[x] = canvas.inkShade(200 + amplitude, 4);
                }
            }
            try expect.count(before, after, 0);
        }
    }
}

test "recolouring diags, dots, stems and crosses preserves thin aliased marks" {
    const before = try canvas.Canvas.init(200, 200);
    defer before.deinit();
    const after = try canvas.Canvas.init(200, 200);
    defer after.deinit();
    for ([_]enum { diagonal, dots, stem, cross, red }{ .diagonal, .dots, .stem, .cross, .red }) |mark| {
        for ([_]u8{ 20, 40, 60, 80, 100 }) |tone| {
            @memset(before.pixels, canvas.white);
            @memset(after.pixels, canvas.white);
            const old: Pixel = if (mark == .red) .{ 220, 0, 0, 255 } else canvas.inkShade(0, 4);
            const new: Pixel = if (mark == .red) .{ 220, 70, 0, 255 } else canvas.inkShade(tone, 4);
            const points: usize = if (mark == .cross) 7 else 40;
            for (0..points) |i| {
                const pos: [2]usize = switch (mark) {
                    .diagonal, .red, .cross => .{ 50 + i, 50 + i },
                    .dots => .{ 50 + 2 * i, 50 },
                    .stem => .{ 50, 50 + i },
                };
                before.row(pos[1])[pos[0]] = old;
                after.row(pos[1])[pos[0]] = new;
                if (mark == .cross) {
                    before.row(pos[1])[56 - i] = old;
                    after.row(pos[1])[56 - i] = new;
                }
            }
            const result = try expect.compareCanvases(before, after, 1);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), result.regions.len);
            try std.testing.expect(expect.hasRegion(result.regions, .after, 50, 50, .changed));
            if (mark == .red) break;
        }
    }
}

test "noise clusters do not reach the minimum by widening the merge gap" {
    const before = try canvas.Canvas.init(200, 64);
    defer before.deinit();
    const after = try canvas.Canvas.init(200, 64);
    defer after.deinit();
    for (0..10) |i| after.red(6 + i * 20, 20, min_region_pixels - 1, 1, 0);
    try expect.count(before, after, 0);
}

test "high-contrast specks below the minimum are ignored" {
    const before = try canvas.Canvas.square();
    defer before.deinit();
    const after = try canvas.Canvas.square();
    defer after.deinit();
    after.red(10, 10, min_region_pixels - 1, 1, 0);
    try expect.count(before, after, 0);
}

test "substantial changes in each RGBA channel are detected" {
    const before = try canvas.Canvas.square();
    defer before.deinit();
    const after = try canvas.Canvas.square();
    defer after.deinit();
    for (0..4) |channel| {
        var color: Pixel = canvas.white;
        color[channel] = 223;
        after.fill(10, 10, canvas.block_size, canvas.block_size, color);
        try expect.count(before, after, 1);
    }
}

test "subpixel glyph coverage changes preserve borders and pale recolours" {
    const before = try canvas.Canvas.init(70, 56);
    defer before.deinit();
    const after = try canvas.Canvas.init(70, 56);
    defer after.deinit();
    const background: Pixel = .{ 24, 26, 29, 255 };
    @memset(before.pixels, background);
    @memset(after.pixels, background);
    coverageGlyph(before, 0);
    coverageGlyph(after, 1);
    try expect.check(before, after, 2, &.{});

    before.fill(4, 43, 14, 1, canvas.inkShade(180, 4));
    after.fill(4, 43, 14, 2, canvas.inkShade(180, 4));
    before.fill(52, 43, 10, 8, .{ 235, 236, 233, 255 });
    after.fill(52, 43, 10, 8, .{ 232, 231, 228, 255 });
    const result = try expect.compareCanvases(before, after, 2);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.regions.len);
    try std.testing.expect(expect.hasRegion(result.regions, .after, 8, 44, .changed));
    try std.testing.expect(expect.hasRegion(result.regions, .after, 56, 47, .changed));
}

test "a whole-image change smaller than the noise minimum is reported" {
    const white: Image = .{ .width = 1, .height = 1, .pixels = &.{canvas.white} };
    const black: Image = .{ .width = 1, .height = 1, .pixels = &.{.{ 0, 0, 0, 255 }} };
    const result = try compare(std.testing.allocator, white, black, .{});
    defer result.deinit(std.testing.allocator);
    try expect.checkRegions(result.regions, &.{.{ .before = Box.fromPixels(0, 0, 1, 1), .after = Box.fromPixels(0, 0, 1, 1) }});
}

test "one changed pixel is reported consistently in small rasters" {
    for ([_][2]usize{ .{ 1, 1 }, .{ 3, 2 }, .{ 10, 5 }, .{ 30, 30 }, .{ 1, 200 }, .{ 200, 1 } }) |size| {
        const before = try canvas.Canvas.init(size[0], size[1]);
        defer before.deinit();
        const after = try canvas.Canvas.init(size[0], size[1]);
        defer after.deinit();
        after.fill(size[0] - 1, size[1] - 1, 1, 1, .{ 255, 0, 0, 255 });
        const found = try expect.compareCanvases(before, after, 1);
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), found.regions.len);
        try std.testing.expectEqual(Kind.changed, found.regions[0].kind);
    }
}
