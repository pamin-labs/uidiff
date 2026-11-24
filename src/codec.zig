//! Detects, reads and decodes bounded PNG, JPEG, or WebP inputs, and encodes PNG.
const std = @import("std");
const values = @import("value.zig");
const stb = @import("codec/stb.zig");
const webp = @import("codec/webp.zig");
const png = @import("codec/png.zig");
const memory = @import("codec_memory");
const Allocator = std.mem.Allocator;
const Image = values.Image;
const Pixel = values.Pixel;
const Size = values.Size;
const Io = std.Io;
/// Writes a valid image as PNG.
pub const encodePng = png.write;
/// Encodes PNG from a source that provides rows.
pub const encodePngRows = png.writeRows;
/// Allocation, invalid image or output failures while encoding.
pub const EncodeError = png.EncodeError;
/// The largest encoded input file or byte stream accepted, in bytes.
pub const max_encoded_bytes = values.max_encoded_bytes;

const Codec = enum { stb, webp };

/// Header and borrowed encoded bytes for a validated image.
const Prepared = struct {
    bytes: []const u8,
    size: Size,
    header: union(Codec) { stb: stb.Header, webp: void },
    limit: usize,
    count: usize,
};

// The stb binding exports the allocation hooks stb's C code calls, so it is
// analyzed in every build that links the decoders, decoding or not.
comptime {
    _ = memory;
}

/// An image with decoder-owned pixels, released by deinit.
pub const Decoded = struct {
    image: Image,
    codec: Codec,
    allocator: Allocator,

    /// Releases pixels with the decoder that allocated them.
    pub fn deinit(self: *Decoded) void {
        switch (self.codec) {
            .stb => stb.free(@constCast(self.image.pixels.ptr)),
            .webp => self.allocator.free(self.image.pixels),
        }
        self.* = undefined;
    }
};

/// Malformed, unsupported, or over-limit image inputs.
pub const DecodeError = stb.DecodeError || webp.DecodeError || error{UnsupportedImageFormat};

/// Failures opening or reading an input file.
pub const ReadError = Io.File.OpenError || Io.File.LengthError || Io.File.ReadPositionalError ||
    Allocator.Error || error{ ImageTooLarge, InputChanged };

/// An opened encoded input. The opener owns the handle and closes it.
pub const FileInput = struct {
    file: Io.File,
    length: usize,

    /// Opens a non-directory file and validates its encoded size.
    pub fn open(io: Io, path: []const u8) ReadError!FileInput {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
        errdefer file.close(io);
        return .{ .file = file, .length = try encodedLength(io, file) };
    }

    /// Releases the opened handle after all readers finish.
    pub fn close(self: FileInput, io: Io) void {
        self.file.close(io);
    }

    /// Sniffs the bounded PNG profile without relying on its name.
    pub fn isStreaming(self: FileInput, io: Io) ReadError!bool {
        if (self.length < png_header_bytes or self.length > concurrent_encoded_bytes) return false;
        var prefix: [png_header_bytes]u8 = undefined;
        try readBytes(io, self.file, &prefix);
        return stb.streamingHeader(&prefix);
    }

    /// Decodes any supported profile from this handle. The caller owns the pixels.
    pub fn decode(self: FileInput, io: Io, allocator: Allocator, cap: usize) (ReadError || DecodeError)!Decoded {
        const bytes = try readEncoded(io, allocator, self.file, self.length);
        defer allocator.free(bytes);
        return decodeCapped(allocator, bytes, cap);
    }

    /// Tries the bounded PNG decoder after isStreaming succeeds. Null requests
    /// the ordered fallback. The caller owns any returned pixels.
    pub fn stream(self: FileInput, io: Io, allocator: Allocator, cap: usize) (ReadError || DecodeError)!?Decoded {
        const bytes = try readEncoded(io, allocator, self.file, self.length);
        defer allocator.free(bytes);
        const prepared = try prepare(allocator, bytes, cap);
        const header = switch (prepared.header) {
            .webp => return null,
            .stb => |header| header,
        };
        const pixels = (try stb.loadStreaming(allocator, bytes, header, prepared.limit)) orelse return null;
        return .{
            .image = .{ .width = prepared.size.width, .height = prepared.size.height, .pixels = pixels[0..prepared.count] },
            .codec = .stb,
            .allocator = allocator,
        };
    }
};

const probe_prefix_bytes = 4096;
// Keep the extra encoded buffer cheap for comparisons that load two files.
const concurrent_encoded_bytes = 1024 * 1024;
const png_header_bytes = 29;

/// Checks the encoded size, image dimensions and decode budget before
/// allocating pixels. The caller owns the result.
pub fn decode(allocator: Allocator, bytes: []const u8) DecodeError!Decoded {
    return decodeCapped(allocator, bytes, values.max_decode_bytes);
}

/// Decodes bytes with a caller-supplied cap no higher than the default.
pub fn decodeCapped(allocator: Allocator, bytes: []const u8, cap: usize) DecodeError!Decoded {
    return decodePrepared(allocator, try prepare(allocator, bytes, cap));
}

/// Reads a file of at most max_encoded_bytes and decodes it. The caller owns the result.
pub fn decodeFile(io: Io, allocator: Allocator, path: []const u8) (ReadError || DecodeError)!Decoded {
    return decodeFileCapped(io, allocator, path, values.max_decode_bytes);
}

/// Reads an input file and decodes it with a caller-supplied cap.
pub fn decodeFileCapped(io: Io, allocator: Allocator, path: []const u8, cap: usize) (ReadError || DecodeError)!Decoded {
    const input = try FileInput.open(io, path);
    defer input.close(io);
    return input.decode(io, allocator, cap);
}

/// Reads the dimensions of a bounded encoded file without decoding pixels.
pub fn probeFile(io: Io, allocator: Allocator, path: []const u8, cap: usize) (ReadError || DecodeError)!Size {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const length = try encodedLength(io, file);
    var prefix: [probe_prefix_bytes]u8 = undefined;
    const header = prefix[0..@min(length, prefix.len)];
    try readBytes(io, file, header);
    if (prepare(allocator, header, cap)) |prepared| {
        return prepared.size;
    } else |err| {
        // JPEG metadata and WebP chunks can put dimensions past the prefix.
        if (err != error.InvalidImage or header.len == length) return err;
    }
    const bytes = try readEncoded(io, allocator, file, length);
    defer allocator.free(bytes);
    return (try prepare(allocator, bytes, cap)).size;
}

/// Reads a file of at most max_encoded_bytes. The caller owns the returned bytes.
pub fn readFile(io: Io, allocator: Allocator, path: []const u8) ReadError![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    return readEncoded(io, allocator, file, try encodedLength(io, file));
}

/// Validates the header and records its dimensions before allocating pixels.
fn prepare(allocator: Allocator, bytes: []const u8, cap: usize) DecodeError!Prepared {
    if (bytes.len > max_encoded_bytes) return error.ImageTooLarge;
    const codec = detect(bytes) orelse return error.UnsupportedImageFormat;
    const limit = @min(cap, values.max_decode_bytes);
    const header: @FieldType(Prepared, "header") = switch (codec) {
        .stb => .{ .stb = try stb.probe(allocator, bytes, limit) },
        .webp => .webp,
    };
    const size = switch (header) {
        .stb => |info| info.size,
        .webp => try webp.probe(bytes),
    };
    return .{ .bytes = bytes, .size = size, .header = header, .limit = limit, .count = try pixelCount(size) };
}

/// Decodes a prepared image. The caller owns the decoded pixels.
fn decodePrepared(allocator: Allocator, prepared: Prepared) DecodeError!Decoded {
    const pixels = switch (prepared.header) {
        .stb => |header| (try stb.load(allocator, prepared.bytes, header, prepared.limit))[0..prepared.count],
        .webp => try webp.load(allocator, prepared.bytes, prepared.size, prepared.limit),
    };
    return .{
        .image = .{ .width = prepared.size.width, .height = prepared.size.height, .pixels = pixels },
        .codec = std.meta.activeTag(prepared.header),
        .allocator = allocator,
    };
}

fn encodedLength(io: Io, file: Io.File) ReadError!usize {
    const length = try file.length(io);
    if (length > max_encoded_bytes) return error.ImageTooLarge;
    return @intCast(length);
}

fn readEncoded(io: Io, allocator: Allocator, file: Io.File, length: usize) ReadError![]u8 {
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    try readBytes(io, file, bytes);
    return bytes;
}

fn readBytes(io: Io, file: Io.File, bytes: []u8) ReadError!void {
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InputChanged;
}

fn pixelCount(size: Size) DecodeError!usize {
    return size.pixelCount() orelse if (size.width == 0 or size.height == 0) error.InvalidImage else error.ImageTooLarge;
}

fn detect(bytes: []const u8) ?Codec {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") or std.mem.startsWith(u8, bytes, "\xff\xd8")) return .stb;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return null;
}

fn readOnce(allocator: Allocator, dir: Io.Dir, name: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try dir.realPathFile(std.testing.io, name, &path_buffer);
    allocator.free(try readFile(std.testing.io, allocator, path_buffer[0..length]));
}

test "invalid PNG input fails instead of looking unchanged" {
    try std.testing.expectError(error.UnsupportedImageFormat, decode(std.testing.allocator, "not a PNG"));
    try std.testing.expectError(error.InvalidImage, decode(std.testing.allocator, "\x89PNG\r\n\x1a\n"));
}

test "an encoded PNG decodes to the same pixels" {
    const pixels = [_]Pixel{ .{ 1, 2, 3, 255 }, .{ 4, 5, 6, 128 }, .{ 7, 8, 9, 0 }, .{ 250, 251, 252, 253 } };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encodePng(std.testing.allocator, .{ .width = 2, .height = 2, .pixels = &pixels }, &out.writer);
    var decoded = try decode(std.testing.allocator, out.written());
    defer decoded.deinit();
    try std.testing.expectEqualSlices(Pixel, &pixels, decoded.image.pixels);
}

test "incompressible PNG rows round trip without expansion beyond stored blocks" {
    const width = 137;
    const height = 89;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, width * height);
    defer allocator.free(pixels);
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(std.mem.sliceAsBytes(pixels));
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try encodePng(allocator, .{ .width = width, .height = height, .pixels = pixels }, &output.writer);
    const raw_bytes = width * height * @sizeOf(Pixel);
    try std.testing.expect(output.written().len <= raw_bytes + height + 128);
    var decoded = try decode(allocator, output.written());
    defer decoded.deinit();
    try std.testing.expectEqualSlices(Pixel, pixels, decoded.image.pixels);
}

test "streaming PNG matches procedural RGBA across dictionary wraps" {
    const width = 193;
    const height = 257;
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(Pixel, width * height);
    defer allocator.free(pixels);
    for (pixels, 0..) |*pixel, i| {
        const x = i % width;
        const y = i / width;
        pixel.* = .{ @intCast(x), @intCast(y % 256), @intCast((x + y / 2) % 256), @intCast(i % 256) };
    }
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try encodePng(allocator, .{ .width = width, .height = height, .pixels = pixels }, &output.writer);
    const prepared = try prepare(allocator, output.written(), values.max_decode_bytes);
    const streamed = (try stb.loadStreaming(allocator, prepared.bytes, prepared.header.stb, prepared.limit)) orelse return error.TestUnexpectedResult;
    defer stb.free(streamed);
    try std.testing.expectEqualSlices(Pixel, pixels, streamed[0..prepared.count]);
}

test "header preflight handles JPEG metadata beyond its initial read" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const metadata_len = probe_prefix_bytes + 128;
    const frame = "\xff\xc0\x00\x0b\x08\x00\x01\x00\x02\x01\x01\x11\x00";
    var bytes: [6 + metadata_len + frame.len]u8 = @splat(0);
    bytes[0..4].* = "\xff\xd8\xff\xe1".*;
    std.mem.writeInt(u16, bytes[4..6], metadata_len + 2, .big);
    bytes[6 + metadata_len ..][0..frame.len].* = frame.*;
    try tmp.dir.writeFile(io, .{ .sub_path = "header.jpg", .data = &bytes });
    const path = try tmp.dir.realPathFileAlloc(io, "header.jpg", allocator);
    defer allocator.free(path);
    try std.testing.expectEqual(Size{ .width = 2, .height = 1 }, try probeFile(io, allocator, path, values.max_decode_bytes));
}

test "reading a file releases each allocation on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.png", .data = "\x89PNG\r\n\x1a\n" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readOnce, .{ tmp.dir, "input.png" });
}

test {
    std.testing.refAllDecls(stb);
    std.testing.refAllDecls(webp);
    std.testing.refAllDecls(png);
    std.testing.refAllDecls(memory);
}

test {
    std.testing.refAllDecls(@This());
}
