//! Writes DEFLATE blocks for PNG scanlines.
const std = @import("std");
const huffman = @import("huffman.zig");
const Writer = std.Io.Writer;
const Container = std.compress.flate.Container;
const Code = huffman.Code;

/// A literal or a length-distance pair in the token buffer.
pub const Token = u32;

/// Pixel and optional pane distances in the input byte stream.
pub const Options = struct {
    pixel_bytes: usize = 4,
    pane_distance: usize = 0,
};

const Match = struct { len: usize = 0, distance: usize = 0 };

const Distance = struct { symbol: u5, extra: Code };

// Each length has a five-bit offset from the first length symbol and a
// fixed code of at most thirteen bits. Keep the lookup in one word.
const Run = packed struct(u32) {
    symbol_offset: u5,
    extra_bits: u5,
    extra_len: u3,
    fixed_bits: u13,
    fixed_len: u4,
    unused: u2 = 0,

    fn symbol(self: Run) u9 {
        return first_length_symbol + @as(u9, self.symbol_offset);
    }
};

const Statistics = struct {
    symbols: [literal_count]u16 = @splat(0),
    distances: [distance_count]u16 = @splat(0),
    raw_bytes: usize = 0,
    extra_bits: usize = 0,
    fixed_bits: usize = 0,

    fn init(tokens: []const Token) Statistics {
        var result: Statistics = .{};
        result.symbols[256] = 1;
        for (tokens) |token| {
            if (token < 256) {
                result.symbols[token] += 1;
                result.raw_bytes += 1;
                result.fixed_bits += if (token <= 143) @as(usize, 8) else 9;
            } else {
                const len = token & length_mask;
                const run = runs[len];
                result.symbols[run.symbol()] += 1;
                const distance = distanceCode(token);
                result.distances[distance.symbol] += 1;
                result.raw_bytes += len;
                result.extra_bits += @as(usize, run.extra_len) + distance.extra.len;
                result.fixed_bits += @as(usize, run.fixed_len) + 5 + distance.extra.len;
            }
        }
        return result;
    }
};

const LengthToken = struct { symbol: u5, extra: Code };

const BitWriter = struct {
    output: *Writer,
    bits: u64 = 0,
    have: u6 = 0,

    fn push(self: *BitWriter, code: Code) Writer.Error!void {
        self.bits |= @as(u64, code.bits) << self.have;
        self.have += code.len;
        if (self.have >= 32) {
            try self.output.writeInt(u32, @truncate(self.bits), .little);
            self.bits >>= 32;
            self.have -= 32;
        }
    }

    fn alignBlock(self: *BitWriter) Writer.Error!void {
        // An empty stored block aligns the next block without changing pixels.
        try self.push(.{ .bits = 0, .len = 3 });
        while (self.have != 0) {
            try self.output.writeByte(@truncate(self.bits));
            self.bits >>= 8;
            self.have -|= 8;
        }
        try self.output.writeAll(&.{ 0, 0, 255, 255 });
    }
};

const Dynamic = struct {
    literals: [literal_count]Code,
    distances: [distance_count]Code,
    lengths: [19]Code,
    header: [literal_count + distance_count]LengthToken,
    header_len: usize,
    hlit: usize,
    hdist: usize,
    hclen: usize,
    bits: usize,

    fn prepare(self: *Dynamic, stats: *const Statistics) void {
        huffman.assign(literal_count, &stats.symbols, &self.literals, 15);
        huffman.assign(distance_count, &stats.distances, &self.distances, 15);
        self.hlit = usedCodes(&self.literals, first_length_symbol);
        self.hdist = usedCodes(&self.distances, 1);

        var widths: [literal_count + distance_count]u5 = undefined;
        for (self.literals[0..self.hlit], widths[0..self.hlit]) |code, *width| width.* = code.len;
        for (self.distances[0..self.hdist], widths[self.hlit..][0..self.hdist]) |code, *width| width.* = code.len;
        var counts: [19]u16 = @splat(0);
        self.header_len = 0;
        const input = widths[0 .. self.hlit + self.hdist];
        var i: usize = 0;
        while (i < input.len) {
            const len = input[i];
            var end = i + 1;
            while (end < input.len and input[end] == len) : (end += 1) {}
            if (len == 0) {
                while (end - i >= 11) {
                    const n = @min(138, end - i);
                    self.addLength(&counts, 18, .{ .bits = @intCast(n - 11), .len = 7 });
                    i += n;
                }
                if (end - i >= 3) {
                    self.addLength(&counts, 17, .{ .bits = @intCast(end - i - 3), .len = 3 });
                    i = end;
                }
            } else {
                self.addLength(&counts, len, .{});
                i += 1;
                while (end - i >= 3) {
                    const n = @min(6, end - i);
                    self.addLength(&counts, 16, .{ .bits = @intCast(n - 3), .len = 2 });
                    i += n;
                }
            }
            while (i < end) : (i += 1) self.addLength(&counts, len, .{});
        }
        huffman.assign(19, &counts, &self.lengths, 7);
        self.hclen = length_order.len;
        while (self.hclen > 4 and self.lengths[length_order[self.hclen - 1]].len == 0) self.hclen -= 1;

        self.bits = 14 + 3 * self.hclen + stats.extra_bits;
        for (self.header[0..self.header_len]) |token| self.bits += @as(usize, self.lengths[token.symbol].len) + token.extra.len;
        for (stats.symbols, self.literals) |freq, code| self.bits += @as(usize, freq) * code.len;
        for (stats.distances, self.distances) |freq, code| self.bits += @as(usize, freq) * code.len;
    }

    fn addLength(self: *Dynamic, counts: *[19]u16, symbol: u5, extra: Code) void {
        self.header[self.header_len] = .{ .symbol = symbol, .extra = extra };
        self.header_len += 1;
        counts[symbol] += 1;
    }

    fn write(self: *const Dynamic, bits: *BitWriter, tokens: []const Token) Writer.Error!void {
        try bits.push(.{ .bits = @intCast(self.hlit - first_length_symbol), .len = 5 });
        try bits.push(.{ .bits = @intCast(self.hdist - 1), .len = 5 });
        try bits.push(.{ .bits = @intCast(self.hclen - 4), .len = 4 });
        for (length_order[0..self.hclen]) |symbol| try bits.push(.{ .bits = self.lengths[symbol].len, .len = 3 });
        for (self.header[0..self.header_len]) |token| {
            const code = self.lengths[token.symbol];
            try bits.push(.{ .bits = code.bits | (token.extra.bits << code.len), .len = code.len + token.extra.len });
        }
        for (tokens) |token| {
            if (token < 256) {
                try bits.push(self.literals[token]);
            } else {
                const run = runs[token & length_mask];
                const code = self.literals[run.symbol()];
                const distance = distanceCode(token);
                const dist_code = self.distances[distance.symbol];
                const prefix_len = code.len + run.extra_len;
                try bits.push(.{
                    .bits = code.bits | (@as(u32, run.extra_bits) << code.len),
                    .len = prefix_len,
                });
                try bits.push(.{
                    .bits = dist_code.bits | (distance.extra.bits << dist_code.len),
                    .len = dist_code.len + distance.extra.len,
                });
            }
        }
        try bits.push(self.literals[256]);
    }
};

/// A zlib stream using dynamic, fixed, or stored blocks.
pub const Stream = struct {
    output: *Writer,
    input: []u8,
    tokens: []Token,
    options: Options,
    used: usize = 0,
    prefix: usize = 0,
    // Distances use modular subtraction. Any slot that aliases an older
    // position still has to pass the byte comparison within the live window.
    position_base: u16 = 0,
    table: [1 << bucket_bits]u16 = @splat(0),
    count: usize = 0,
    adler: Container.Hasher = .init(.zlib),

    /// Starts the stream with size-bounded input and token scratch buffers.
    pub fn init(output: *Writer, input: []u8, tokens: []Token) Writer.Error!Stream {
        return initWithOptions(output, input, tokens, .{});
    }

    /// Starts a stream with an optional same-row distance between sheet panels.
    pub fn initWithOptions(output: *Writer, input: []u8, tokens: []Token, options: Options) Writer.Error!Stream {
        std.debug.assert(input.len == block_bytes and tokens.len == max_tokens);
        std.debug.assert(options.pixel_bytes == 3 or options.pixel_bytes == 4);
        try output.writeAll(Container.zlib.header());
        return .{ .output = output, .input = input, .tokens = tokens, .options = options };
    }

    /// Buffers bytes for the run tokenizer.
    pub fn write(self: *Stream, bytes: []const u8) Writer.Error!void {
        var tail = bytes;
        while (tail.len != 0) {
            const len = @min(tail.len, self.input.len - self.used);
            @memcpy(self.input[self.used..][0..len], tail[0..len]);
            self.used += len;
            tail = tail[len..];
            if (self.used == self.input.len) try self.tokenize();
        }
    }

    /// Finishes the stream and writes its uncompressed-data checksum.
    pub fn finish(self: *Stream) Writer.Error!void {
        if (self.used > self.prefix) try self.tokenize();
        if (self.count != 0) try self.emit(self.input[0..self.used]);
        try self.output.writeAll(&.{ 1, 0, 0, 255, 255 });
        try self.adler.writeFooter(self.output);
    }

    fn tokenize(self: *Stream) Writer.Error!void {
        const pixel_bytes = self.options.pixel_bytes;
        const bytes = self.input[0..self.used];
        self.adler.update(bytes[self.prefix..]);
        var i = self.prefix;
        var cached: ?Match = null;
        while (i < bytes.len) {
            if (self.count == self.tokens.len) {
                try self.emit(bytes[0..i]);
            }
            const match = cached orelse self.findMatch(bytes, i);
            cached = null;
            if (match.len >= 3) {
                if (match.len < max_length and match.len < bytes.len - i - 1 and self.count + 1 < self.tokens.len) {
                    const next = self.findMatch(bytes, i + 1);
                    if (next.len > match.len) {
                        self.push(bytes[i]);
                        i += 1;
                        cached = next;
                        continue;
                    }
                }
                const first = i;
                // Full-length tokens from a byte or pixel run can be batched
                // because a farther candidate cannot beat that length.
                const batch = match.len >= max_length and (match.distance == 1 or match.distance == pixel_bytes);
                const end_match = i + if (batch)
                    (match.len / max_length) * max_length
                else
                    @min(match.len, max_length);
                self.matchRun(&i, end_match, match.distance);
                // A periodic run repeats the same keys. Seed its tail,
                // sample other long matches, and index short ones densely.
                const stride: usize = if (batch or i - first <= dense_match_bytes) 1 else hash_stride;
                var seed = if (batch) i - 2 * pixel_bytes else first + @max(2, stride);
                const end = @min(i, bytes.len -| (min_match - 1));
                while (seed < end) : (seed += stride) {
                    self.table[hashWord(bytes, seed)] = self.position_base +% @as(u16, @truncate(seed));
                }
            } else {
                self.push(bytes[i]);
                i += 1;
            }
        }
        // Future matches need only the deflate window. Keeping the longer
        // stored-block span also lets that fallback write original bytes.
        const prefix = @min(bytes.len, retained_bytes);
        std.mem.copyForwards(u8, self.input[0..prefix], bytes[bytes.len - prefix ..]);
        self.position_base +%= @truncate(bytes.len - prefix);
        self.prefix = prefix;
        self.used = prefix;
    }

    fn findMatch(self: *Stream, bytes: []const u8, i: usize) Match {
        const pixel_bytes = self.options.pixel_bytes;
        const remaining = bytes.len - i;
        const history = @min(i, window);
        var best: Match = .{};
        if (history > 0 and remaining >= 3 and bytes[i - 1] == bytes[i] and
            bytes[i] == bytes[i + 1] and bytes[i] == bytes[i + 2])
        {
            best = .{ .len = runEnd(bytes, i + 3, bytes[i]) - i, .distance = 1 };
        }
        if (history >= pixel_bytes and remaining >= min_pixel_run) {
            considerMatch(bytes, i, pixel_bytes, bytes.len, min_pixel_run, &best);
        }
        if (remaining >= min_match) {
            const match_end = @min(bytes.len, i + max_length);
            const bucket = hashWord(bytes, i);
            const absolute = self.position_base +% @as(u16, @truncate(i));
            const distance = absolute -% self.table[bucket];
            self.table[bucket] = absolute;
            if (self.options.pane_distance > pixel_bytes and self.options.pane_distance <= history) {
                considerMatch(bytes, i, self.options.pane_distance, match_end, min_match, &best);
            }
            if (distance > 0 and distance <= history and distance != self.options.pane_distance) {
                considerMatch(bytes, i, distance, match_end, min_match, &best);
            }
        }
        return best;
    }

    fn matchRun(self: *Stream, index: *usize, end: usize, distance: usize) void {
        while (end - index.* >= 3 and self.count != self.tokens.len) {
            const len = @min(max_length, end - index.*);
            self.push(@as(Token, @intCast(len)) | match_flag | (@as(Token, @intCast(distance - 1)) << distance_shift));
            index.* += len;
        }
        // Any last one or two bytes are emitted by the outer tokenizer.
    }

    fn push(self: *Stream, token: Token) void {
        self.tokens[self.count] = token;
        self.count += 1;
    }

    fn emit(self: *Stream, history: []const u8) Writer.Error!void {
        const tokens = self.tokens[0..self.count];
        const stats = Statistics.init(tokens);
        const fixed_size = blockSize(stats.fixed_bits + 7);
        // A block with too many bytes for one stored block always compresses
        // smaller with fixed codes at this token limit.
        const stored_size = if (stats.raw_bytes <= std.math.maxInt(u16)) stats.raw_bytes + 5 else std.math.maxInt(usize);
        var dynamic: Dynamic = undefined;
        dynamic.prepare(&stats);
        if (blockSize(dynamic.bits) < @min(fixed_size, stored_size)) {
            var bits: BitWriter = .{ .output = self.output };
            try bits.push(.{ .bits = 0b100, .len = 3 });
            try dynamic.write(&bits, tokens);
            try bits.alignBlock();
        } else if (fixed_size < stored_size) {
            var bits: BitWriter = .{ .output = self.output };
            try bits.push(.{ .bits = 0b010, .len = 3 });
            for (tokens) |token| {
                if (token < 256) {
                    try bits.push(fixed(@intCast(token)));
                } else {
                    const run = runs[token & length_mask];
                    const distance = distanceCode(token);
                    try bits.push(.{ .bits = run.fixed_bits, .len = run.fixed_len });
                    try bits.push(.{
                        .bits = @as(u32, @bitReverse(distance.symbol)) | (distance.extra.bits << 5),
                        .len = 5 + distance.extra.len,
                    });
                }
            }
            try bits.push(fixed(256));
            try bits.alignBlock();
        } else {
            try writeStored(self.output, history[history.len - stats.raw_bytes ..]);
        }
        self.count = 0;
    }
};

const min_match = 4;
const window = 32 * 1024;
const retained_bytes = std.math.maxInt(u16);
const min_pixel_run = 8;
const match_flag = 1 << 9;
const length_mask = match_flag - 1;
const distance_shift = 10;
const bucket_bits = 15;
const hash_stride = 4;
const dense_match_bytes = 32;
const max_length = 258;
const first_length_symbol = 257;
const literal_count = 286;
const distance_count = 30;
const length_order = [_]u5{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
const lengths = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const runs: [max_length + 1]Run = table: {
    var codes: [max_length + 1]Run = undefined;
    @setEvalBranchQuota(10000);
    for (3..codes.len) |n| {
        var index: usize = 0;
        while (index + 1 < lengths.len and n >= lengths[index + 1]) : (index += 1) {}
        const code = fixed(@intCast(first_length_symbol + index));
        const extra: Code = .{
            .bits = @intCast(n - lengths[index]),
            .len = if (index < 8 or index == lengths.len - 1) 0 else @intCast(index / 4 - 1),
        };
        codes[n] = .{
            .symbol_offset = @intCast(index),
            .extra_bits = @intCast(extra.bits),
            .extra_len = @intCast(extra.len),
            .fixed_bits = @intCast(code.bits | (extra.bits << code.len)),
            .fixed_len = @intCast(code.len + extra.len),
        };
    }
    break :table codes;
};

/// Raw input bytes fed to the tokenizer at once.
pub const block_bytes = 192 * 1024;
/// Tokens per block, including literals or matches but excluding the terminator.
pub const max_tokens = 16 * 1024;

fn blockSize(bits: usize) usize {
    return (bits + 3 + 3 + 7) / 8 + 4;
}

fn usedCodes(codes: []const Code, minimum: usize) usize {
    var end = codes.len;
    while (end > minimum and codes[end - 1].len == 0) end -= 1;
    return end;
}

fn distanceCode(token: Token) Distance {
    const offset = token >> distance_shift;
    if (offset < 4) return .{ .symbol = @intCast(offset), .extra = .{} };
    const shift: u5 = @intCast(std.math.log2_int(Token, offset) - 1);
    const prefix = (offset >> shift) & 1;
    return .{
        .symbol = @intCast(2 * @as(u32, shift + 1) + prefix),
        .extra = .{ .bits = offset & ((@as(u32, 1) << shift) - 1), .len = shift },
    };
}

inline fn hashWord(bytes: []const u8, i: usize) usize {
    const word = std.mem.readInt(u32, bytes[i..][0..min_match], .little);
    return (word *% 0x9e3779b1) >> (32 - bucket_bits);
}

inline fn considerMatch(bytes: []const u8, i: usize, distance: usize, match_end: usize, minimum: usize, best: *Match) void {
    if (best.distance == distance) return;
    const best_len = @min(max_length, best.len);
    const reach = @max(minimum, best_len + @as(usize, @intFromBool(distance >= best.distance)));
    if (reach > @min(max_length, bytes.len - i)) return;
    // If the candidate cannot beat the current match, skip its SIMD scan.
    if (bytes[i + reach - 1] != bytes[i - distance + reach - 1]) return;
    if (std.mem.readInt(u32, bytes[i..][0..min_match], .little) !=
        std.mem.readInt(u32, bytes[i - distance ..][0..min_match], .little)) return;
    const len = matchingEnd(bytes[0..match_end], i + min_match, distance) - i;
    if (len >= reach) best.* = .{ .len = len, .distance = distance };
}

fn fixed(symbol: u9) Code {
    if (symbol <= 143) return .{ .bits = @bitReverse(@as(u8, @intCast(symbol + 48))), .len = 8 };
    if (symbol <= 255) return .{ .bits = @bitReverse(symbol + 256), .len = 9 };
    if (symbol <= 279) return .{ .bits = @bitReverse(@as(u7, @intCast(symbol - 256))), .len = 7 };
    return .{ .bits = @bitReverse(@as(u8, @intCast(symbol - 88))), .len = 8 };
}

fn writeStored(output: *Writer, bytes: []const u8) Writer.Error!void {
    const len: u16 = @intCast(bytes.len);
    try output.writeByte(0);
    try output.writeInt(u16, len, .little);
    try output.writeInt(u16, ~len, .little);
    try output.writeAll(bytes);
}

fn runEnd(bytes: []const u8, start: usize, tone: u8) usize {
    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
    const pattern: @Vector(lanes, u8) = @splat(tone);
    var i = start;
    while (i + lanes <= bytes.len) : (i += lanes) {
        if (!@reduce(.And, pattern == @as(@Vector(lanes, u8), bytes[i..][0..lanes].*))) break;
    }
    while (i < bytes.len and bytes[i] == tone) : (i += 1) {}
    return i;
}

fn matchingEnd(bytes: []const u8, start: usize, distance: usize) usize {
    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
    const Vector = @Vector(lanes, u8);
    var i = start;
    while (i + lanes <= bytes.len) : (i += lanes) {
        const now: Vector = bytes[i..][0..lanes].*;
        const old: Vector = bytes[i - distance ..][0..lanes].*;
        if (!@reduce(.And, now == old)) break;
    }
    while (i < bytes.len and bytes[i] == bytes[i - distance]) : (i += 1) {}
    return i;
}

test "dynamic and stored blocks round trip through the standard inflater" {
    const allocator = std.testing.allocator;
    const random_bytes = max_tokens;
    const bytes = try allocator.alloc(u8, 3 * block_bytes);
    defer allocator.free(bytes);
    const scratch = try allocator.alloc(u8, block_bytes);
    defer allocator.free(scratch);
    const tokens = try allocator.alloc(Token, max_tokens);
    defer allocator.free(tokens);

    var rng = std.Random.DefaultPrng.init(std.testing.random_seed);
    rng.random().bytes(bytes[0..random_bytes]);
    for (bytes[random_bytes..], 0..) |*byte, i| byte.* = @as(u8, @intCast(i % 4)) * 19;
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var compressed = try Stream.init(&out.writer, scratch, tokens);
    try compressed.write(bytes);
    try compressed.finish();
    const encoded = out.written();
    try std.testing.expectEqual(@as(u8, 0), encoded[2] & 7);
    // The random prefix can change token counts and therefore stored block
    // boundaries. Walk the emitted LEN fields to find the compressed run.
    const stored_header_bytes = 5;
    var cursor: usize = 2;
    while (cursor + stored_header_bytes <= encoded.len and encoded[cursor] & 6 == 0) {
        const length = std.mem.readInt(u16, encoded[cursor + 1 ..][0..2], .little);
        cursor += stored_header_bytes + @as(usize, length);
    }
    try std.testing.expect(cursor < encoded.len);
    try std.testing.expectEqual(@as(u8, 4), encoded[cursor] & 6);

    var input: std.Io.Reader = .fixed(encoded);
    var inflated: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var decoded: Writer.Allocating = .init(allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(bytes.len, try inflated.reader.streamRemaining(&decoded.writer));
    try std.testing.expectEqualSlices(u8, bytes, decoded.written());

    // The inflater exposes the footer. Check it against the decoded data.
    var checksum: std.hash.Adler32 = .{};
    checksum.update(decoded.written());
    try std.testing.expectEqual(checksum.adler, inflated.container_metadata.zlib.adler);
}

test "short runs use fixed codes when a dynamic header costs more" {
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u8, block_bytes);
    defer allocator.free(scratch);
    const tokens = try allocator.alloc(Token, max_tokens);
    defer allocator.free(tokens);
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var compressed = try Stream.init(&out.writer, scratch, tokens);
    const run = "abcdefghijklmn" ++ "xxxxxxxxxxxxxxxx";
    try compressed.write(run);
    try compressed.finish();
    try std.testing.expectEqual(@as(u8, 2), out.written()[2] & 7);
    var input: std.Io.Reader = .fixed(out.written());
    var inflated: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var decoded: Writer.Allocating = .init(allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(run.len, try inflated.reader.streamRemaining(&decoded.writer));
    try std.testing.expectEqualStrings(run, decoded.written());
}

test "chunked input round trips across tokenizer boundaries" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 2 * block_bytes + 1);
    defer allocator.free(bytes);
    var rng = std.Random.DefaultPrng.init(std.testing.random_seed);
    rng.random().bytes(bytes[0..block_bytes]);
    for (bytes[block_bytes..], 0..) |*byte, i| byte.* = @intCast((i % 4) * 7);

    const scratch = try allocator.alloc(u8, block_bytes);
    defer allocator.free(scratch);
    const tokens = try allocator.alloc(Token, max_tokens);
    defer allocator.free(tokens);
    for ([_]usize{ 0, 1, 258, 259, block_bytes - 1, block_bytes, block_bytes + 1, bytes.len }) |len| {
        var encoded: Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        var compressed = try Stream.init(&encoded.writer, scratch, tokens);
        var rest = bytes[0..len];
        while (rest.len != 0) {
            const chunk = @min(rest.len, 1 + rng.random().uintLessThan(usize, block_bytes));
            try compressed.write(rest[0..chunk]);
            rest = rest[chunk..];
        }
        try compressed.finish();

        var input: std.Io.Reader = .fixed(encoded.written());
        var inflated: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
        var decoded: Writer.Allocating = .init(allocator);
        defer decoded.deinit();
        try std.testing.expectEqual(len, try inflated.reader.streamRemaining(&decoded.writer));
        try std.testing.expectEqualSlices(u8, bytes[0..len], decoded.written());
    }
}

test "pane matches span the token and input buffer boundaries" {
    const allocator = std.testing.allocator;
    const distance = window - 1024;
    const data = try allocator.alloc(u8, 3 * block_bytes + 1);
    defer allocator.free(data);
    var rng = std.Random.DefaultPrng.init(std.testing.random_seed);
    rng.random().bytes(data[0..distance]);
    for (data[distance..], 0..) |*byte, i| byte.* = data[i % distance];
    const scratch = try allocator.alloc(u8, block_bytes);
    defer allocator.free(scratch);
    const tokens = try allocator.alloc(Token, max_tokens);
    defer allocator.free(tokens);
    var encoded: Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    var stream = try Stream.initWithOptions(&encoded.writer, scratch, tokens, .{ .pane_distance = distance });
    try stream.write(data);
    try stream.finish();
    try std.testing.expect(encoded.written().len < data.len / 4);

    var input: std.Io.Reader = .fixed(encoded.written());
    var inflated: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var decoded: Writer.Allocating = .init(allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(data.len, try inflated.reader.streamRemaining(&decoded.writer));
    try std.testing.expectEqualSlices(u8, data, decoded.written());
}

test "packed length entries preserve their decoded run and fixed prefix" {
    for (lengths[0]..runs.len) |length| {
        const run = runs[length];
        try std.testing.expectEqual(length, lengths[run.symbol_offset] + @as(usize, run.extra_bits));
        const prefix = fixed(run.symbol());
        try std.testing.expectEqual(prefix.len + @as(u5, run.extra_len), @as(u5, run.fixed_len));
        try std.testing.expectEqual(prefix.bits | (@as(u32, run.extra_bits) << prefix.len), @as(u32, run.fixed_bits));
    }
}

test {
    std.testing.refAllDecls(@This());
}
