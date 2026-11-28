//! Fuzzes the decoders with mutated fixture images and raw bytes.
const std = @import("std");
const uidiff = @import("uidiff");
const fixtures = @import("fixtures");
const testing = std.testing;
const Format = fixtures.Format;

const formats = std.meta.tags(Format);
/// The seed index past the last format means raw bytes.
const raw = seed_count;
const max_mutations = 8;

// Noninterlaced 3-by-3 images whose filtered rows reach the sample decoder.
const gray8 =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
    "\x00\x00\x00\x03\x00\x00\x00\x03\x08\x00\x00\x00\x00\x73\x43\xea" ++
    "\x63\x00\x00\x00\x14\x49\x44\x41\x54\x78\x9c\x63\x10\x39\x91\xc2" ++
    "\xa8\xfa\x9f\x93\x85\x9d\x5b\x12\x00\x13\xc2\x02\x9e\xbb\x2c\x0d" ++
    "\x88\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const indexed8 =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
    "\x00\x00\x00\x03\x00\x00\x00\x03\x08\x03\x00\x00\x00\x61\xf6\x45" ++
    "\x8d\x00\x00\x00\x09\x50\x4c\x54\x45\xd2\x16\x3e\x0b\x9a\x5d\x5c" ++
    "\x2d\xb4\xba\x8c\x84\x7f\x00\x00\x00\x02\x74\x52\x4e\x53\x00\xbb" ++
    "\x2a\x20\xa7\x3c\x00\x00\x00\x14\x49\x44\x41\x54\x78\x9c\x63\x60" ++
    "\x62\x60\x64\x64\x64\x60\x64\x61\x60\xfc\x0f\x00\x01\x50\x01\x0b" ++
    "\x71\xc8\xbf\x05\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const extra_seeds = [_][]const u8{ gray8, indexed8 };
const seed_count = formats.len + extra_seeds.len;

fn fuzzDecode(seeds: [seed_count][]const u8, smith: *testing.Smith) !void {
    var encoded: [fixtures.max_sample_bytes]u8 = undefined;
    const pick = smith.valueRangeAtMost(u8, 0, raw);
    const length = if (pick == raw) smith.slice(&encoded) else mutate(smith, &encoded, seeds[pick]);
    var image = uidiff.decode(testing.allocator, encoded[0..length], uidiff.max_decode_bytes) catch |err| switch (err) {
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
    var seeds: [seed_count][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (seeds[0..loaded]) |bytes| testing.allocator.free(bytes);
    inline for (formats, 0..) |format, i| {
        seeds[i] = try fixtures.readSample(format);
        loaded += 1;
    }
    @memcpy(seeds[loaded..], &extra_seeds);
    comptime var corpus: []const []const u8 = &.{};
    // Smith reads choices as little-endian u64s. Missing subsequent choices
    // leave each selected image intact for its first decode.
    inline for (0..raw + 1) |i| {
        const choice = comptime std.mem.toBytes(std.mem.nativeToLittle(u64, i));
        corpus = corpus ++ .{&choice};
    }
    try testing.fuzz(seeds, fuzzDecode, .{ .corpus = corpus });
}

test {
    std.testing.refAllDecls(@This());
}
