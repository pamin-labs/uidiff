//! End-to-end overlay classification and preservation of nearby edits.

const std = @import("std");
const uidiff = @import("uidiff");
const sample = uidiff.testing;
const Kind = uidiff.Kind;

fn dimmedPage() !struct { sample.Canvas, sample.Canvas } {
    const before = try sample.Canvas.init(192, 160);
    errdefer before.deinit();
    const after = try sample.Canvas.init(192, 160);
    before.fill(0, 0, 50, 160, sample.inkShade(192, 4));
    before.fill(50, 0, 142, 42, sample.inkShade(220, 4));
    for (before.pixels, after.pixels) |ink, *shade| {
        shade.* = .{ ink[0] / 2, ink[1] / 2, ink[2] / 2, 255 };
    }
    return .{ before, after };
}

test "a dimmed viewport with a new opaque center pane is an inserted overlay" {
    const before, const after = try dimmedPage();
    defer before.deinit();
    defer after.deinit();
    const dimmed = try sample.compareCanvases(before, after, 1);
    defer dimmed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.changed, dimmed.regions[0].kind);
    after.fill(52, 52, 88, 56, sample.inkShade(216, 4));
    const shown = try sample.compareCanvases(before, after, 1);
    defer shown.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), shown.regions.len);
    try std.testing.expectEqual(Kind.inserted, shown.regions[0].kind);
    const hidden = try sample.compareCanvases(after, before, 1);
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hidden.regions.len);
    try std.testing.expectEqual(Kind.removed, hidden.regions[0].kind);
}

test "a colored edit next to a floating panel remains visible on both sides" {
    const before = try sample.Canvas.init(256, 144);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 144);
    defer after.deinit();
    before.line(54, 160, 62, 1, 64);
    after.fill(22, 50, 196, 46, sample.inkShade(220, 4));
    after.fill(28, 54, 184, 32, sample.inkShade(36, 4));
    after.fill(22, 50, 18, 4, .{ 168, 31, 48, 255 });
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasSeparateMark(result.regions, 26, 52, 100, 70));
}

test "audit: a gray label turning black beside a toast remains two-sided" {
    const before = try sample.Canvas.init(256, 144);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 144);
    defer after.deinit();
    before.fill(28, 88, 18, 5, .{ 136, 136, 136, 255 });
    after.fill(22, 50, 196, 46, .{ 220, 220, 220, 255 });
    after.fill(28, 54, 184, 32, .{ 36, 36, 36, 255 });
    after.fill(28, 88, 18, 5, .{ 0, 0, 0, 255 });
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasSeparateMark(result.regions, 34, 90, 110, 75));
}

test "round 25 audit: a darkened gray label cannot set its own shadow transmission" {
    const before = try sample.Canvas.init(256, 144);
    defer before.deinit();
    const after = try sample.Canvas.init(256, 144);
    defer after.deinit();
    before.fill(28, 88, 18, 5, .{ 136, 136, 136, 255 });
    after.fill(22, 50, 196, 46, .{ 230, 230, 230, 255 });
    after.fill(28, 54, 184, 32, .{ 36, 36, 36, 255 });
    after.fill(28, 88, 18, 5, .{ 115, 115, 115, 255 });
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasSeparateMark(result.regions, 34, 90, 110, 75));
}

test "round 25 audit: narrow, edge-touching and gradient panels retain the old side" {
    const before = try sample.Canvas.init(300, 164);
    defer before.deinit();
    const after = try sample.Canvas.init(300, 164);
    defer after.deinit();
    const background: uidiff.Pixel = .{ 240, 240, 240, 255 };
    for ([_]enum { narrow, edge, gradient }{ .narrow, .edge, .gradient }) |profile| {
        @memset(before.pixels, background);
        @memset(after.pixels, background);
        after.fill(18, 48, 264, 72, .{ 225, 225, 225, 255 });
        after.fill(30, 54, 240, 56, .{ 52, 32, 62, 255 });
        switch (profile) {
            .narrow => before.fill(70, 57, 100, 45, .{ 70, 110, 90, 255 }),
            .edge => before.fill(18, 57, 260, 45, sample.white),
            .gradient => for (0..176) |x| {
                before.fill(60 + x, 57, 1, 45, .{ @intCast(40 + x), 110, 90, 255 });
            },
        }
        before.fill(42, 111, 18, 5, .{ 136, 136, 136, 255 });
        after.fill(42, 111, 18, 5, .{ 115, 115, 115, 255 });
        const result = try sample.compareCanvases(before, after, 1);
        defer result.deinit(std.testing.allocator);
        const prior_x: usize = if (profile == .edge) 20 else 90;
        try std.testing.expect(sample.hasRegion(result.regions, .before, prior_x, 80, null));
        try std.testing.expect(sample.hasRegion(result.regions, .after, 120, 80, null));
        try std.testing.expect(sample.hasSeparateMark(result.regions, 48, 113, 120, 80));
    }
}

test "audit: growing or replacing a toast retains the old panel" {
    const before = try sample.Canvas.init(300, 180);
    defer before.deinit();
    const after = try sample.Canvas.init(300, 180);
    defer after.deinit();
    before.fill(42, 59, 216, 48, .{ 40, 82, 46, 255 });
    before.line(60, 180, 76, 1, 218);
    // Preserve the backdrop at the old panel's extent until it is covered.
    after.fill(18, 48, 264, 86, .{ 230, 230, 230, 255 });
    after.fill(30, 54, 240, 72, .{ 122, 36, 45, 255 });
    after.line(60, 190, 76, 2, 218);
    before.fill(42, 128, 18, 4, .{ 136, 136, 136, 255 });
    after.fill(42, 128, 18, 4, .{ 115, 115, 115, 255 });
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sample.hasRegion(result.regions, .before, 48, 88, null));
    try std.testing.expect(sample.hasRegion(result.regions, .after, 48, 88, null));
    try std.testing.expect(sample.hasSeparateMark(result.regions, 48, 129, 120, 88));
}

test "a modal does not hide a changed page behind its scrim" {
    const before, const after = try dimmedPage();
    defer before.deinit();
    defer after.deinit();
    after.fill(52, 52, 88, 56, sample.inkShade(216, 4));
    after.fill(12, 20, 24, 16, sample.inkShade(58, 4));
    const result = try sample.compareCanvases(before, after, 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.regions.len);
    try std.testing.expectEqual(Kind.changed, result.regions[0].kind);
    try std.testing.expect(result.regions[0].before != null);
}
