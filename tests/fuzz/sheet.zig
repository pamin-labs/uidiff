//! Fuzzes label layout and sheet rendering with arbitrary regions, then the
//! PNG round trip of the sheet; and that a flawed region or move is refused
//! by both the sheet and the report before either writes a byte.
const std = @import("std");
const uidiff = @import("uidiff");
const fuzz = @import("uidiff_testing").fuzz;
const testing = std.testing;
const Region = uidiff.Region;
const Move = uidiff.Move;

/// What makes the fuzzed input invalid, if anything.
const Flaw = enum { none, fractional, outside, empty, still_move };

const max_regions = 2;

fn fuzzSheet(_: void, smith: *testing.Smith) !void {
    var before_pixels: fuzz.Storage = undefined;
    var after_pixels: fuzz.Storage = undefined;
    const before = fuzz.image(smith, &before_pixels);
    const after = fuzz.image(smith, &after_pixels);
    const pair: uidiff.Pair = .{ .before = before, .after = after };
    var storage: [max_regions]Region = undefined;
    var regions: []Region = storage[0..smith.valueRangeAtMost(u8, 0, max_regions)];
    for (regions, 1..) |*region, number| {
        const sides = smith.valueRangeAtMost(u8, 1, 3);
        region.* = .{
            .number = number,
            .before = if (sides & 1 != 0) box(smith, before.size()) else null,
            .after = if (sides & 2 != 0) box(smith, after.size()) else null,
        };
    }
    const flaw = smith.value(Flaw);
    var moves: []const Move = &.{};
    const canvas = pair.canvas();
    switch (flaw) {
        .none => {},
        .fractional, .outside, .empty => {
            // The report checks against the canvas, so a box outside it is
            // outside its image for both writers.
            var flawed = box(smith, after.size());
            switch (flaw) {
                .fractional => flawed.x += 0.5,
                .outside => flawed.x = @floatFromInt(canvas.width),
                .empty => flawed.width = 0,
                .none, .still_move => unreachable,
            }
            storage[0] = .{ .number = 1, .after = flawed };
            regions = storage[0..@max(regions.len, 1)];
        },
        .still_move => moves = &.{.{ .before = .{ .y = 0, .height = 1 }, .after = .{ .y = 0, .height = 1 }, .x = 0, .width = 1 }},
    }
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    const sheet = uidiff.encodeSheet(testing.io, testing.allocator, pair, regions, moves, &encoded.writer);
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    const written = uidiff.report.write(regions, canvas, moves, &report.writer);
    if (flaw != .none) {
        const expected = if (flaw == .still_move) error.InvalidMove else error.InvalidRegionBox;
        try testing.expectError(expected, sheet);
        try testing.expectError(expected, written);
        try testing.expectEqual(@as(usize, 0), encoded.written().len);
        try testing.expectEqual(@as(usize, 0), report.written().len);
        return;
    }
    try sheet;
    try written;
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

test "fuzz annotated sheets, their PNG round trip and refused flaws" {
    try testing.fuzz({}, fuzzSheet, .{});
}

test {
    std.testing.refAllDecls(@This());
}
