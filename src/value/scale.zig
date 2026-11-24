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
    /// separators, exponents, signs, special values, and numbers past f64's
    /// range. Options.check still refuses zero.
    pub fn parse(text: []const u8) ?Scale {
        const point = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
        if (!digits(text[0..point])) return null;
        if (point != text.len and !digits(text[point + 1 ..])) return null;
        const scale = std.fmt.parseFloat(f64, text) catch return null;
        return if (std.math.isFinite(scale)) .{ .factor = scale } else null;
    }
};

fn digits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "scale is parsed strictly as a finite decimal number" {
    for ([_][]const u8{ "1", "2", "1.125", "0.5", "0" }) |text| {
        try std.testing.expectEqual(try std.fmt.parseFloat(f64, text), Scale.parse(text).?.factor);
    }
    const huge: [400]u8 = @splat('9');
    for ([_][]const u8{ "1_0", "0x10", "1e2", "nan", "inf", "-1", "+1", ".5", "1.", "", " 1", "1.2.3", &huge }) |text| {
        try std.testing.expectEqual(@as(?Scale, null), Scale.parse(text));
    }
}

test {
    std.testing.refAllDecls(Scale);
}
