//! Streams zlib compression into checksummed PNG chunks.

const std = @import("std");
const builtin = @import("builtin");
const values = @import("../../value.zig");
const memory = @import("codec_memory");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const zlib = @import("zlib_c");
const Image = values.Image;

/// Allocation, invalid image or output failures.
pub const EncodeError = Allocator.Error || Writer.Error || Image.Invalid;

/// zlib-ng's streaming compressor. Each full output buffer becomes one
/// IDAT chunk, so the encoder needs no room for the whole compressed stream.
pub const Deflater = struct {
    stream: zlib.zng_stream,
    output: *Writer,
    out: []u8,

    /// Initializes zlib to write into the supplied chunk buffer.
    pub fn init(self: *Deflater, allocator: *Allocator, output: *Writer, out: []u8) EncodeError!void {
        self.* = .{ .stream = std.mem.zeroes(zlib.zng_stream), .output = output, .out = out };
        self.stream.zalloc = zalloc;
        self.stream.zfree = zfree;
        self.stream.@"opaque" = allocator;
        self.stream.next_out = out.ptr;
        self.stream.avail_out = @intCast(out.len);
        switch (zlib.zng_deflateInit2(&self.stream, zlib.UIDIFF_PNG_COMPRESSION_LEVEL, zlib.Z_DEFLATED, window_bits, memory_level, zlib.Z_DEFAULT_STRATEGY)) {
            zlib.Z_OK => {},
            zlib.Z_MEM_ERROR => return error.OutOfMemory,
            else => return error.WriteFailed,
        }
    }

    /// Releases the zlib compressor.
    pub fn deinit(self: *Deflater) void {
        const status = zlib.zng_deflateEnd(&self.stream);
        // A failing output writer can leave the stream unfinished.
        std.debug.assert(status == zlib.Z_OK or status == zlib.Z_DATA_ERROR);
    }

    /// Feeds more bytes into the compressed stream.
    pub fn write(self: *Deflater, bytes: []const u8) EncodeError!void {
        self.stream.next_in = bytes.ptr;
        self.stream.avail_in = @intCast(bytes.len);
        while (self.stream.avail_in != 0) {
            if (zlib.zng_deflate(&self.stream, zlib.Z_NO_FLUSH) != zlib.Z_OK) return error.WriteFailed;
            if (self.stream.avail_out == 0) try self.emit();
        }
    }

    /// Finishes the stream and writes any remaining image data.
    pub fn finish(self: *Deflater) EncodeError!void {
        self.stream.avail_in = 0;
        while (true) {
            const status = zlib.zng_deflate(&self.stream, zlib.Z_FINISH);
            if (status == zlib.Z_STREAM_END) break;
            if (status != zlib.Z_OK) return error.WriteFailed;
            if (self.stream.avail_out == 0) try self.emit();
        }
        if (self.stream.avail_out != self.out.len) try self.emit();
    }

    fn emit(self: *Deflater) Writer.Error!void {
        try chunk(self.output, "IDAT", self.out[0 .. self.out.len - self.stream.avail_out]);
        self.stream.next_out = self.out.ptr;
        self.stream.avail_out = @intCast(self.out.len);
    }

    fn zalloc(context: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
        const allocator: *const Allocator = @ptrCast(@alignCast(context));
        const bytes = std.math.mul(usize, items, size) catch return null;
        const block = memory.allocBlock(allocator.*, bytes) orelse return null;
        if (builtin.mode == .debug) @memset(block, undefined);
        return block.ptr;
    }

    fn zfree(_: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        memory.freeBlock(address);
    }
};

/// Compressed bytes per IDAT chunk.
pub const chunk_bytes = 64 * 1024;

const window_bits = 15;

const memory_level = 8;

/// Writes one framed PNG chunk and its checksum.
pub fn chunk(output: *Writer, comptime kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try output.writeInt(u32, std.math.cast(u32, data.len) orelse return error.WriteFailed, .big);
    try output.writeAll(kind);
    try output.writeAll(data);
    const checksum = if (zlib.UIDIFF_ZLIB_CRC != 0) acceleratedChecksum(kind, data) else portableChecksum(kind, data);
    try output.writeInt(u32, checksum, .big);
}

fn acceleratedChecksum(kind: *const [4]u8, data: []const u8) u32 {
    const tag_crc = zlib.zng_crc32_z(0, kind, kind.len);
    return zlib.zng_crc32_z(tag_crc, data.ptr, data.len);
}

fn portableChecksum(kind: *const [4]u8, data: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    return crc.final();
}

test {
    std.testing.refAllDecls(@This());
}
