//! Streams zlib compression into checksummed PNG chunks.

const std = @import("std");
const builtin = @import("builtin");
const values = @import("../../value.zig");
const memory = @import("codec_memory");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const zlib = @import("zlib_c");
const Image = values.Image;

/// The uncompressed history carried into the next raw deflate strip.
pub const history_bytes = std.compress.flate.history_len;

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
        self.* = .{ .stream = undefined, .output = output, .out = out };
        try initStream(&self.stream, allocator, window_bits);
        self.stream.next_out = out.ptr;
        self.stream.avail_out = @intCast(out.len);
    }

    /// Releases the zlib compressor.
    pub fn deinit(self: *Deflater) void {
        endStream(&self.stream);
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
};

/// One reusable compressor for byte-aligned strips of a shared zlib stream.
pub const Strip = struct {
    stream: zlib.zng_stream,

    pub const Flush = enum { sync, finish };

    pub const Result = struct {
        bytes: []const u8,
        adler: u32,
        input_len: usize,
    };

    pub fn init(self: *Strip, allocator: *Allocator) EncodeError!void {
        try initStream(&self.stream, allocator, -window_bits);
    }

    pub fn deinit(self: *Strip) void {
        endStream(&self.stream);
    }

    pub fn outputBound(input_len: usize) usize {
        // The upstream bound is for Z_FINISH. Z_SYNC_FLUSH ends with an
        // empty stored block and its byte-alignment padding.
        return zlib.zng_deflateBound(null, @intCast(input_len)) + 6;
    }

    pub fn compress(self: *Strip, history: []const u8, input: []const u8, out: []u8, flush: Flush) EncodeError!Result {
        const stream = &self.stream;
        if (zlib.zng_deflateReset(stream) != zlib.Z_OK) return error.WriteFailed;
        if (history.len != 0 and zlib.zng_deflateSetDictionary(stream, history.ptr, @intCast(history.len)) != zlib.Z_OK) return error.WriteFailed;
        stream.next_in = input.ptr;
        stream.avail_in = @intCast(input.len);
        stream.next_out = out.ptr;
        stream.avail_out = @intCast(out.len);
        const status = zlib.zng_deflate(stream, if (flush == .finish) zlib.Z_FINISH else zlib.Z_SYNC_FLUSH);
        if (status != (if (flush == .finish) zlib.Z_STREAM_END else zlib.Z_OK) or stream.avail_in != 0 or stream.avail_out == 0) return error.WriteFailed;
        return .{
            .bytes = out[0 .. out.len - stream.avail_out],
            .adler = zlib.zng_adler32_z(1, input.ptr, input.len),
            .input_len = input.len,
        };
    }
};

/// Writes the zlib header, raw strips, and combined checksum into IDAT chunks.
pub const StripStream = struct {
    output: *Writer,
    adler: u32 = 1,

    pub fn start(self: StripStream) Writer.Error!void {
        try chunk(self.output, "IDAT", std.compress.flate.Container.zlib.header());
    }

    pub fn write(self: *StripStream, strip: Strip.Result) Writer.Error!void {
        self.adler = zlib.zng_adler32_combine(self.adler, strip.adler, @intCast(strip.input_len));
        try chunk(self.output, "IDAT", strip.bytes);
    }

    pub fn finish(self: StripStream) Writer.Error!void {
        var footer: [4]u8 = undefined;
        std.mem.writeInt(u32, &footer, self.adler, .big);
        try chunk(self.output, "IDAT", &footer);
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

fn initStream(stream: *zlib.zng_stream, allocator: *Allocator, window: c_int) EncodeError!void {
    stream.* = std.mem.zeroes(zlib.zng_stream);
    stream.zalloc = zalloc;
    stream.zfree = zfree;
    stream.@"opaque" = allocator;
    switch (zlib.zng_deflateInit2(stream, zlib.UIDIFF_PNG_COMPRESSION_LEVEL, zlib.Z_DEFLATED, window, memory_level, zlib.Z_DEFAULT_STRATEGY)) {
        zlib.Z_OK => {},
        zlib.Z_MEM_ERROR => return error.OutOfMemory,
        else => return error.WriteFailed,
    }
}

fn endStream(stream: *zlib.zng_stream) void {
    const status = zlib.zng_deflateEnd(stream);
    // A failing output writer or a sync-flushed strip leaves the stream unfinished.
    std.debug.assert(status == zlib.Z_OK or status == zlib.Z_DATA_ERROR);
}

fn zalloc(context: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    // initStream supplies a pointer to an allocator that outlives the stream.
    const allocator: *const Allocator = @ptrCast(@alignCast(context));
    const bytes = std.math.mul(usize, items, size) catch return null;
    const block = memory.allocBlock(allocator.*, bytes) orelse return null;
    if (builtin.mode == .debug) @memset(block, undefined);
    return block.ptr;
}

fn zfree(
    _: ?*anyopaque,
    address: ?*anyopaque,
) callconv(.c) void {
    memory.freeBlock(address);
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

test "strip checksums describe the uncompressed bytes in stream order" {
    const first = "the first strip contains repeated input";
    const second = "repeated input in the second strip";
    var backing = std.testing.allocator;
    var strip: Strip = undefined;
    try strip.init(&backing);
    defer strip.deinit();
    var compressed: [512]u8 = undefined;
    var chunks: Writer.Allocating = .init(backing);
    defer chunks.deinit();
    var stream: StripStream = .{ .output = &chunks.writer };
    try stream.start();
    try stream.write(try strip.compress(&.{}, first, &compressed, .sync));
    try stream.write(try strip.compress(first, second, &compressed, .finish));
    try stream.finish();
    try std.testing.expectEqual(std.hash.Adler32.hash(first ++ second), stream.adler);
    const footer = chunks.written()[chunks.written().len - 8 ..][0..4];
    try std.testing.expectEqual(stream.adler, std.mem.readInt(u32, footer, .big));
}

test {
    std.testing.refAllDecls(@This());
}
