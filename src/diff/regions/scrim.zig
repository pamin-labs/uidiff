//! Models colour transmission through a translucent scrim.

const std = @import("std");
const value = @import("../../value.zig");

/// An affine dimming model for opaque pixels.
pub const Scrim = struct {
    transmission: f32,
    base: @Vector(3, f32),

    /// Measures the largest channel difference from the predicted shade.
    pub fn residual(self: Scrim, before: value.Pixel, after: value.Pixel) f32 {
        return @reduce(.Max, @abs(tone(after) - self.predict(before)));
    }

    /// Reports whether the pixel matches the predicted shade within rounding.
    pub noinline fn matches(self: Scrim, before: value.Pixel, after: value.Pixel) bool {
        return before[3] == 255 and after[3] == 255 and self.residual(before, after) <= scrim_rounding;
    }

    /// Reports whether a pixel matches additional shadow on the predicted shade.
    pub noinline fn shadow(self: Scrim, before: value.Pixel, after: value.Pixel) bool {
        if (before[3] != 255 or after[3] != 255) return false;
        const predicted = self.predict(before);
        const actual = tone(after);
        const total = @reduce(.Add, predicted);
        if (total <= 0) return false;
        const transmission = @reduce(.Add, actual) / total;
        return transmission >= scrim_min_shadow_transmission and transmission < 1 and
            @reduce(.Max, @abs(actual - predicted * @as(@Vector(3, f32), @splat(transmission)))) <= scrim_rounding;
    }

    fn predict(self: Scrim, before: value.Pixel) @Vector(3, f32) {
        return tone(before) * @as(@Vector(3, f32), @splat(self.transmission)) + self.base;
    }
};

/// Maximum channel deviation accepted by the dimming model.
pub const scrim_rounding = 2.0;

/// Lower transmission bound for a shadow over the dimmed background.
pub const scrim_min_shadow_transmission = 0.82;

/// Returns the sum of absolute channel differences.
pub fn toneDistance(a: value.Pixel, b: value.Pixel) f32 {
    return @reduce(.Add, @abs(tone(a) - tone(b)));
}

/// Converts the RGB channels to a vector for colour comparisons.
pub fn tone(p: value.Pixel) @Vector(3, f32) {
    return @floatFromInt(@as(@Vector(3, u8), p[0..3].*));
}

test {
    std.testing.refAllDecls(@This());
}
