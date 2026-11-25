//! Exercises JPEG header, scan and colour decoding across the fixture profiles.
const std = @import("std");
const uidiff = @import("uidiff");
const fixtures = @import("fixtures");
const testing = std.testing;

const max_fuzz_bytes = 4096;
const max_mutations = 12;
const scratch_bytes = 256 * 1024;
const soi_bytes = 2;
const first_frame = 0xc0;
const last_frame = 0xc2;
const frame_marker_prefix = 0xff;
const segment_length_bytes = @sizeOf(u16);

const encoded_profiles = blk: {
    var encoded: [fixtures.jpeg.profiles.len][]const u8 = undefined;
    for (fixtures.jpeg.profiles, &encoded) |profile, *bytes| bytes.* = profile.encoded();
    break :blk encoded;
};

fn frameFields(bytes: []const u8) struct { start: u16, end: u16 } {
    // These seeds come from the generator and have exactly one SOF.
    var offset: u16 = soi_bytes;
    while (offset + 2 + segment_length_bytes <= bytes.len) {
        if (bytes[offset] != frame_marker_prefix) break;
        const marker = bytes[offset + 1];
        offset += 2;
        const segment_length = std.mem.readInt(u16, bytes[offset..][0..segment_length_bytes], .big);
        if (segment_length < segment_length_bytes or segment_length > bytes.len - offset) break;
        if (marker >= first_frame and marker <= last_frame) return .{ .start = offset, .end = offset + segment_length };
        offset += segment_length;
    }
    @panic("generated JPEG seed has no SOF");
}

fn fuzzJpeg(_: void, smith: *testing.Smith) !void {
    const seed = encoded_profiles[smith.valueRangeAtMost(u8, 0, encoded_profiles.len - 1)];
    const frame = frameFields(seed);
    var bytes: [max_fuzz_bytes]u8 = undefined;
    @memcpy(bytes[0..seed.len], seed);
    const len: usize = if (smith.value(bool)) frame.end + smith.slice(bytes[frame.end..]) else seeded: {
        for (0..smith.valueRangeAtMost(u8, 0, max_mutations)) |_| {
            const offset = if (smith.value(bool))
                smith.valueRangeAtMost(u16, frame.start, frame.end - 1)
            else
                smith.valueRangeAtMost(u16, soi_bytes, @intCast(seed.len - 1));
            bytes[offset] = smith.value(u8);
        }
        break :seeded if (smith.value(bool))
            smith.valueRangeAtMost(u16, soi_bytes, @intCast(seed.len))
        else
            seed.len;
    };

    // Mutated dimensions may be large. Bound the arena used per fuzz case.
    var scratch: [scratch_bytes]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    var decoded = uidiff.decode(fixed.allocator(), bytes[0..len]) catch |err| switch (err) {
        error.InvalidImage, error.ImageTooLarge, error.OutOfMemory => return,
        else => return err,
    };
    defer decoded.deinit();
    try testing.expectEqual(decoded.image.size().pixelCount(), decoded.image.pixels.len);
    try testing.expect(decoded.image.isOpaque());
}

test "fuzz bounded JPEG decoding" {
    const corpus = comptime blk: {
        var seeds: [fixtures.jpeg.profiles.len][]const u8 = undefined;
        for (0..seeds.len) |index| seeds[index] = &.{index};
        break :blk seeds;
    };
    try testing.fuzz({}, fuzzJpeg, .{ .corpus = &corpus });
}

test {
    testing.refAllDecls(@This());
}
