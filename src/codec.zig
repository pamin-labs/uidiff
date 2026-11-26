//! Detects, reads and decodes bounded PNG, JPEG, or WebP inputs, and encodes PNG.
const std = @import("std");
const value = @import("value.zig");
const webp = @import("codec/webp.zig");
const jpeg = @import("codec/jpeg.zig");
const png = @import("codec/png.zig");
const memory = @import("codec_memory");
const Allocator = std.mem.Allocator;
const Image = value.Image;
const Pixel = value.Pixel;
const Size = value.Size;
const Io = std.Io;

/// Writes a valid image as PNG.
pub const encodePng = png.write;
/// Encodes PNG from a source that provides rows.
pub const encodePngRows = png.writeRows;
/// Encodes PNG rows, with optional I/O concurrency for compression.
pub const encodePngRowsWithIo = png.writeRowsWithIo;
/// Allocation, invalid image or output failures while encoding.
pub const EncodeError = png.EncodeError;
/// The largest encoded input file or byte stream accepted, in bytes.
pub const max_encoded_bytes = value.max_encoded_bytes;

const Format = std.meta.FieldEnum(@TypeOf(formats));

// The memory module exports the allocation hooks the C codecs call, so it is
// analyzed in every build that links the decoders, decoding or not.
comptime {
    _ = memory;
    for (@typeInfo(@TypeOf(formats)).@"struct".field_names) |name| {
        const format = @field(formats, name);
        for (.{ "matches", "probe", "decode", "release" }) |decl| {
            if (!@hasDecl(format, decl)) @compileError(name ++ " codec must declare " ++ decl);
        }
    }
}

/// An image with decoder-owned pixels, released by deinit.
pub const Decoded = struct {
    image: Image,
    format: Format,
    allocator: Allocator,

    /// Releases pixels with the decoder that allocated them.
    pub fn deinit(self: *Decoded) void {
        switch (self.format) {
            inline else => |format| @field(formats, @tagName(format)).release(self.allocator, self.image.pixels),
        }
        self.* = undefined;
    }
};

/// Malformed, unsupported, or over-limit image inputs.
pub const DecodeError = errors: {
    var result: type = error{UnsupportedImageFormat};
    for (@typeInfo(@TypeOf(formats)).@"struct".field_names) |name| {
        result = result || @field(formats, name).DecodeError;
    }
    break :errors result;
};

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

    /// Decodes any supported profile from this handle. The caller owns the pixels.
    pub fn decode(self: FileInput, io: Io, allocator: Allocator, cap: usize) (ReadError || DecodeError)!Decoded {
        const bytes = try readEncoded(io, allocator, self.file, self.length);
        defer value.freeUnfilled(u8, allocator, bytes);
        return decodeCapped(allocator, bytes, cap);
    }
};

const formats = .{ .png = png, .jpeg = jpeg, .webp = webp };

const probe_prefix_bytes = 4096;

/// Checks the encoded size, image dimensions and decode budget before
/// allocating pixels. The caller owns the result.
pub fn decode(allocator: Allocator, bytes: []const u8) DecodeError!Decoded {
    return decodeCapped(allocator, bytes, value.max_decode_bytes);
}

/// Decodes bytes with a caller-supplied cap no higher than the default.
pub fn decodeCapped(allocator: Allocator, bytes: []const u8, cap: usize) DecodeError!Decoded {
    if (bytes.len > max_encoded_bytes) return error.ImageTooLarge;
    inline for (@typeInfo(@TypeOf(formats)).@"struct".field_names) |name| {
        const format = @field(formats, name);
        if (format.matches(bytes)) {
            const tag: Format = @field(Format, name);
            const probed = try probeFormat(format.probe, allocator, bytes, cap);
            const pixels = try format.decode(allocator, bytes, probed.header, probed.limit);
            return owned(probed.header.size, pixels, allocator, tag);
        }
    }
    return error.UnsupportedImageFormat;
}

/// Reads a file of at most max_encoded_bytes and decodes it. The caller owns the result.
pub fn decodeFile(io: Io, allocator: Allocator, path: []const u8) (ReadError || DecodeError)!Decoded {
    return decodeFileCapped(io, allocator, path, value.max_decode_bytes);
}

/// Reads an input file and decodes it with a caller-supplied cap.
pub fn decodeFileCapped(io: Io, allocator: Allocator, path: []const u8, cap: usize) (ReadError || DecodeError)!Decoded {
    const input = try FileInput.open(io, path);
    defer input.close(io);
    return input.decode(io, allocator, cap);
}

/// Reads the dimensions of a bounded encoded file without decoding pixels.
pub fn probeFile(io: Io, allocator: Allocator, path: []const u8, cap: usize) (ReadError || DecodeError)!Size {
    const input = try FileInput.open(io, path);
    defer input.close(io);
    const length = input.length;
    var prefix: [probe_prefix_bytes]u8 = undefined;
    const header = prefix[0..@min(length, prefix.len)];
    try readBytes(io, input.file, header);
    if (probeSize(allocator, header, cap)) |size| {
        return size;
    } else |err| {
        // JPEG metadata and WebP chunks can put dimensions past the prefix.
        if (err != error.InvalidImage or header.len == length) return err;
    }
    const bytes = try readEncoded(io, allocator, input.file, length);
    defer value.freeUnfilled(u8, allocator, bytes);
    return probeSize(allocator, bytes, cap);
}

/// Reads a file of at most max_encoded_bytes. The caller owns the returned bytes.
pub fn readFile(io: Io, allocator: Allocator, path: []const u8) ReadError![]u8 {
    const input = try FileInput.open(io, path);
    defer input.close(io);
    return readEncoded(io, allocator, input.file, input.length);
}

fn Probed(comptime probe: anytype) type {
    const Header = @typeInfo(@typeInfo(@TypeOf(probe)).@"fn".return_type.?).error_union.payload;
    return struct { header: Header, limit: usize };
}

fn probeSize(allocator: Allocator, bytes: []const u8, cap: usize) DecodeError!Size {
    inline for (@typeInfo(@TypeOf(formats)).@"struct".field_names) |name| {
        if (@field(formats, name).matches(bytes)) {
            return (try probeFormat(@field(formats, name).probe, allocator, bytes, cap)).header.size;
        }
    }
    return error.UnsupportedImageFormat;
}

noinline fn probeFormat(comptime probe: anytype, allocator: Allocator, bytes: []const u8, cap: usize) DecodeError!Probed(probe) {
    const limit = @min(cap, value.max_decode_bytes);
    const header = try probe(allocator, bytes, limit);
    _ = try pixelCount(header.size);
    return .{ .header = header, .limit = limit };
}

fn owned(size: Size, pixels: []const Pixel, allocator: Allocator, format: Format) Decoded {
    return .{
        .image = .{ .width = size.width, .height = size.height, .pixels = pixels },
        .format = format,
        .allocator = allocator,
    };
}

fn encodedLength(io: Io, file: Io.File) ReadError!usize {
    const length = try file.length(io);
    if (length > max_encoded_bytes) return error.ImageTooLarge;
    return @intCast(length);
}

fn readEncoded(io: Io, allocator: Allocator, file: Io.File, length: usize) ReadError![]u8 {
    // A successful positional read initializes the entire buffer before it escapes.
    const bytes = try value.allocUnfilled(u8, allocator, length);
    errdefer value.freeUnfilled(u8, allocator, bytes);
    try readBytes(io, file, bytes);
    return bytes;
}

fn readBytes(io: Io, file: Io.File, bytes: []u8) ReadError!void {
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InputChanged;
}

fn pixelCount(size: Size) DecodeError!usize {
    return size.pixelCount() orelse if (size.width == 0 or size.height == 0) error.InvalidImage else error.ImageTooLarge;
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
    try std.testing.expectEqual(Size{ .width = 2, .height = 1 }, try probeFile(io, allocator, path, value.max_decode_bytes));
}

test "reading a file releases each allocation on failure" {
    const Check = struct {
        fn readOnce(allocator: Allocator, dir: Io.Dir, name: []const u8) !void {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try dir.realPathFile(std.testing.io, name, &path_buffer);
            allocator.free(try readFile(std.testing.io, allocator, path_buffer[0..length]));
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.png", .data = "\x89PNG\r\n\x1a\n" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.readOnce, .{ tmp.dir, "input.png" });
}

test {
    std.testing.refAllDecls(jpeg);
    std.testing.refAllDecls(webp);
    std.testing.refAllDecls(png);
    std.testing.refAllDecls(memory);
}

test {
    std.testing.refAllDecls(@This());
}
