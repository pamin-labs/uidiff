//! Fuzzes the decoders with mutated fixture images and raw bytes.
const std = @import("std");
const uidiff = @import("uidiff");
const fixtures = @import("fixtures");
const testing = std.testing;
const Format = fixtures.Format;

const formats = std.meta.tags(Format);
const blank = fixtures.find(.identical);
/// The blank fixture's files are small; seeds and inputs fit this buffer.
const max_sample_bytes = 4096;
/// The seed index past the last format means raw bytes.
const raw = std.meta.tags(Format).len;
const max_mutations = 8;

fn fuzzDecode(seeds: [formats.len][]const u8, smith: *testing.Smith) !void {
    var encoded: [max_sample_bytes]u8 = undefined;
    const pick = smith.valueRangeAtMost(u8, 0, raw);
    const length = if (pick == raw) smith.slice(&encoded) else mutate(smith, &encoded, seeds[pick]);
    var image = uidiff.decode(testing.allocator, encoded[0..length]) catch |err| switch (err) {
        error.InvalidImage, error.UnsupportedImageFormat, error.ImageTooLarge => return,
        error.OutOfMemory => return err,
    };
    defer image.deinit();
    try testing.expect(image.image.valid());
}

fn mutate(smith: *testing.Smith, encoded: []u8, base: []const u8) u32 {
    @memcpy(encoded[0..base.len], base);
    for (0..smith.valueRangeAtMost(u8, 0, max_mutations)) |_| {
        const offset = smith.valueRangeAtMost(u16, 0, @intCast(base.len - 1));
        encoded[offset] = smith.value(u8);
    }
    return if (smith.value(bool)) smith.valueRangeAtMost(u16, 0, @intCast(base.len)) else @intCast(base.len);
}

test "fuzz encoded screenshots" {
    var seeds: [formats.len][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (seeds[0..loaded]) |bytes| testing.allocator.free(bytes);
    inline for (formats, 0..) |format, i| {
        seeds[i] = try std.Io.Dir.cwd().readFileAlloc(testing.io, blank.path(.before, format), testing.allocator, .limited(max_sample_bytes));
        loaded += 1;
    }
    comptime var corpus: []const []const u8 = &.{};
    inline for (0..raw + 1) |i| corpus = corpus ++ .{&[_]u8{i}};
    try testing.fuzz(seeds, fuzzDecode, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
