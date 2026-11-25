//! Exercises the bounded libjpeg-turbo bridge with preserved frame dimensions.
const std = @import("std");
const uidiff = @import("uidiff");
const fixtures = @import("fixtures");
const testing = std.testing;

const Seed = struct { bytes: []const u8, frame_end: usize };

const max_encoded_bytes = 4096;
const max_mutations = 12;
const blank = fixtures.find(.identical);
const frame_marker = "\xff\xc0";

fn fuzzJpeg(seed: Seed, smith: *testing.Smith) !void {
    var bytes: [max_encoded_bytes]u8 = undefined;
    @memcpy(bytes[0..seed.frame_end], seed.bytes[0..seed.frame_end]);
    // A complete frame keeps the public probe on the JPEG path while the
    // scan parameters and entropy bytes can vary.
    const len: usize = if (smith.value(bool)) seeded: {
        @memcpy(bytes[seed.frame_end..seed.bytes.len], seed.bytes[seed.frame_end..]);
        for (0..smith.valueRangeAtMost(u8, 0, max_mutations)) |_| {
            const offset = smith.valueRangeAtMost(u16, @intCast(seed.frame_end), @intCast(seed.bytes.len - 1));
            bytes[offset] = smith.value(u8);
        }
        break :seeded if (smith.value(bool))
            smith.valueRangeAtMost(u16, @intCast(seed.frame_end), @intCast(seed.bytes.len))
        else
            seed.bytes.len;
    } else seed.frame_end + smith.slice(bytes[seed.frame_end..]);
    var decoded = uidiff.decode(testing.allocator, bytes[0..len]) catch |err| switch (err) {
        error.InvalidImage, error.ImageTooLarge => return,
        else => return err,
    };
    defer decoded.deinit();
    const expected: uidiff.Size = .{ .width = blank.width * fixtures.scale, .height = blank.height * fixtures.scale };
    try testing.expectEqual(expected, decoded.image.size());
    try testing.expect(decoded.image.isOpaque());
}

test "fuzz bounded JPEG decoding" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, blank.path(.before, .jpg), testing.allocator, .limited(max_encoded_bytes));
    defer testing.allocator.free(bytes);
    const marker = std.mem.indexOf(u8, bytes, frame_marker) orelse return error.TestUnexpectedResult;
    const length_at = marker + frame_marker.len;
    if (bytes.len - length_at < @sizeOf(u16)) return error.TestUnexpectedResult;
    const frame_end = length_at + std.mem.readInt(u16, bytes[length_at..][0..2], .big);
    if (frame_end >= bytes.len) return error.TestUnexpectedResult;
    try testing.fuzz(Seed{ .bytes = bytes, .frame_end = frame_end }, fuzzJpeg, .{});
}

test {
    testing.refAllDecls(@This());
}
