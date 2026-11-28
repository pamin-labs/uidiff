//! Conversion between CSS lengths and device pixels.
const std = @import("std");

/// A whole CSS-pixel length.
pub const CssPx = enum(usize) {
    _,

    /// Wraps a CSS-pixel length.
    pub fn init(count_: usize) CssPx {
        return @fromBackingInt(@intCast(count_));
    }

    /// Returns the underlying CSS-pixel length.
    pub fn count(self: CssPx) usize {
        return @backingInt(self);
    }
};

/// Device pixels per CSS pixel.
pub const Scale = struct {
    /// Device pixels per CSS pixel. A usable factor is finite and positive.
    factor: f64,

    /// One device pixel per CSS pixel.
    pub const one: Scale = .{ .factor = 1 };

    /// Whether the factor is usable as a pixel scale.
    pub fn isValid(self: Scale) bool {
        return std.math.isFinite(self.factor) and self.factor > 0;
    }

    /// Converts a CSS length to device pixels.
    pub fn devicePixels(self: Scale, css_pixels: CssPx) f64 {
        return @as(f64, @floatFromInt(css_pixels.count())) * self.factor;
    }

    /// Parses a device scale written as plain decimal digits with an optional
    /// fraction ("2", "1.25"). Returns null for anything else: hexadecimal, digit
    /// separators, exponents, signs, special values, zero, and scales too
    /// long to parse exactly, so every parsed scale is valid.
    ///
    /// Exact means at most 15 digits after leading zeros and at most 22
    /// fraction digits once trailing zeros are dropped: both the digits and
    /// the power of ten are then exact in f64, so one division rounds
    /// correctly (Clinger's fast path).
    pub fn parse(text: []const u8) ?Scale {
        const point = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
        if (!digits(text[0..point])) return null;
        const fraction = if (point == text.len) "" else text[point + 1 ..];
        if (point != text.len and !digits(fraction)) return null;
        const kept = std.mem.trimEnd(u8, fraction, "0");
        if (kept.len > max_fraction_digits) return null;
        var mantissa: u64 = 0;
        var significant: usize = 0;
        for ([_][]const u8{ text[0..point], kept }) |part| for (part) |c| {
            if (mantissa == 0 and c == '0') continue;
            significant += 1;
            if (significant > max_significant_digits) return null;
            mantissa = mantissa * 10 + (c - '0');
        };
        const scale: Scale = .{ .factor = @as(f64, @floatFromInt(mantissa)) / powers_of_ten[kept.len] };
        return if (scale.isValid()) scale else null;
    }
};

const max_significant_digits = 15;
const max_fraction_digits = 22;
const powers_of_ten = powers: {
    var table: [max_fraction_digits + 1]f64 = undefined;
    var power: f64 = 1;
    for (&table) |*entry| {
        entry.* = power;
        power *= 10;
    }
    break :powers table;
};

fn digits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "scale is parsed strictly as a positive finite decimal number" {
    for ([_][]const u8{ "1", "2", "1.125", "0.5" }) |text| {
        try std.testing.expectEqual(try std.fmt.parseFloat(f64, text), Scale.parse(text).?.factor);
    }
    for ([_][]const u8{ "123456789012345", "0.0000000000000000000001", "1.50000000000000000000000000" }) |text| {
        try std.testing.expectEqual(try std.fmt.parseFloat(f64, text), Scale.parse(text).?.factor);
    }
    const huge: [400]u8 = @splat('9');
    for ([_][]const u8{ "0", "00.000", "1_0", "0x10", "1e2", "nan", "inf", "-1", "+1", ".5", "1.", "", " 1", "1.2.3", &huge }) |text| {
        try std.testing.expectEqual(@as(?Scale, null), Scale.parse(text));
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "scale parsing matches parseFloat on random accepted inputs" {
    var prng: std.Random.DefaultPrng = .init(0x5ca1e);
    const random = prng.random();
    var buffer: [48]u8 = undefined;
    for (0..200_000) |_| {
        const whole = random.uintAtMost(usize, 16);
        const fraction = random.uintAtMost(usize, 24);
        var len: usize = 0;
        for (0..@max(whole, 1)) |_| {
            buffer[len] = '0' + random.uintLessThan(u8, 10);
            len += 1;
        }
        if (fraction != 0) {
            buffer[len] = '.';
            len += 1;
            for (0..fraction) |_| {
                buffer[len] = '0' + random.uintLessThan(u8, 10);
                len += 1;
            }
        }
        const text = buffer[0..len];
        if (Scale.parse(text)) |scale| try std.testing.expectEqual(try std.fmt.parseFloat(f64, text), scale.factor);
    }
}
