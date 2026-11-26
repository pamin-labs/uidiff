//! SIMD color comparison and anti-aliasing detection over validated image bands.
// YIQ and anti-aliasing logic adapted from Pixelmatch.
// ISC License
//
// Copyright (c) 2025, Mapbox
//
// Permission to use, copy, modify, and/or distribute this software for any purpose
// with or without fee is hereby granted, provided that the above copyright notice
// and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
// FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
// OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
// TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
// THIS SOFTWARE.

const std = @import("std");
const values = @import("../value.zig");
const pixel = @import("pixel.zig");
const change_mask = @import("mask.zig");
const Image = values.Image;
const Pixel = values.Pixel;
const lanes = pixel.lanes;
const same = pixel.same;

/// A strided crop or a virtual backdrop over an image.
pub const Raster = struct {
    image: Image,
    left: usize,
    top: usize,
    width: usize,
    height: usize,
    background: Background = .none,

    /// Supplies regular pixels, a row margin, or a repeated row.
    pub const Background = union(enum) { none, margin, row: []const Pixel };
};

const SampledRaster = struct {
    image: Image,
    left: usize,
    top: usize,
    width: usize,
    height: usize,
    pixels: []const Pixel,
    stride: usize,
    x_mask: usize,
    offset: usize,
    row_len: usize,
    real: bool,

    fn init(raster: Raster) SampledRaster {
        const stride, const pixels, const x_mask, const offset, const row_len = switch (raster.background) {
            .none => .{ raster.image.width, raster.image.pixels, std.math.maxInt(usize), @as(usize, 0), raster.width },
            .margin => .{ raster.image.width, raster.image.pixels, @as(usize, 0), raster.left, @as(usize, 1) },
            .row => |row_| .{ @as(usize, 0), row_, std.math.maxInt(usize), @as(usize, 0), raster.width },
        };
        return .{
            .image = raster.image,
            .left = raster.left,
            .top = raster.top,
            .width = raster.width,
            .height = raster.height,
            .pixels = pixels,
            .stride = stride,
            .x_mask = x_mask,
            .offset = offset,
            .row_len = row_len,
            .real = raster.background == .none,
        };
    }

    inline fn row(self: SampledRaster, y: usize) []const Pixel {
        // The crop fits the source image or the selected repeated row.

        return self.pixels[self.index(self.left, self.top + y)..][0..self.row_len];
    }

    inline fn at(self: SampledRaster, x: usize, y: usize) Pixel {
        return self.sample(self.left + x, self.top + y);
    }

    inline fn sample(self: SampledRaster, x: usize, y: usize) Pixel {
        // All neighbour lookups are clamped to the source extent.

        return self.pixels[self.index(x, y)];
    }

    inline fn index(self: SampledRaster, x: usize, y: usize) usize {
        // Validated coordinates keep the affine index within the selected
        // plane. A zero stride or mask repeats its row or column.
        return y * self.stride + (x & self.x_mask) + self.offset;
    }
};

const Point = struct { x: usize, y: usize };
const EdgePolicy = enum { normal, stationary };
const LaneBits = @Int(.unsigned, lanes);
const PixelBlock = [lanes]Pixel;
const MaskBlock = [lanes]change_mask.Cell;
const ColorLanes = @Vector(lanes, f32);

const threshold = 0.01;
const max_delta = 35215 * threshold * threshold;
/// Neighboring samples that can establish the shared palette of a moved edge.
pub const moved_coverage_radius = 6;
const coverage_divisor = 3;
const faint_speck_delta = 4;
const blend_rounding = 2;
const min_recoloured_stroke = 9;

/// Writes one byte per pixel for the requested rows and reports whether any changed.
pub fn mask(before: Raster, after: Raster, top: usize, rows: usize, out: []change_mask.Cell) bool {
    const a = SampledRaster.init(before);
    const b = SampledRaster.init(after);
    var found = false;
    const policy: EdgePolicy = if (a.top == b.top and a.real and b.real) .stationary else .normal;
    for (top..top + rows) |y| {
        const old = a.row(y);
        const new = b.row(y);
        const output = out[(y - top) * a.width ..][0..a.width];
        // Aligned bands are usually unchanged across the entire row.
        if (old.len == new.len and pixel.sameRun(old, new)) {
            @memset(output, .clear);
            continue;
        }
        const end = output.len - output.len % lanes;
        const old_blocks = std.mem.bytesAsSlice(PixelBlock, std.mem.sliceAsBytes(old[0..end]));
        const mask_blocks = std.mem.bytesAsSlice(MaskBlock, std.mem.sliceAsBytes(output[0..end]));
        if (new.len == 1) {
            if (maskBackdrop(a, b, old, new, old_blocks, mask_blocks, y, policy)) found = true;
        } else {
            const new_blocks = std.mem.bytesAsSlice(PixelBlock, std.mem.sliceAsBytes(new[0..end]));
            for (old_blocks, new_blocks, mask_blocks, 0..) |*old_block, *new_block, *cells, block| {
                const x = block * lanes;
                const pa = pixel.load(old_block);
                const pb = pixel.load(new_block);
                const equal = pa == pb;
                if (@reduce(.And, equal)) {
                    cells.* = @splat(.clear);
                    continue;
                }

                if (changedBlock(a, b, old, new, pa, pb, equal, x, y, policy, cells)) found = true;
            }
        }
        for (output[end..], end..) |*cell, x| {
            cell.* = scalarChange(a, b, x, y, policy);
            found = found or cell.* != .clear;
        }
    }
    return found;
}

/// Removes local redistributions of coverage from aligned moved rows.
/// Retains the full extent of a uniform stroke recolour with a flagged pixel.
pub fn clearMovedCoverage(before: Raster, after: Raster, top: usize, cells: []change_mask.Cell) void {
    const a = SampledRaster.init(before);
    const b = SampledRaster.init(after);
    var start: usize = 0;
    while (change_mask.nextCell(cells, start, .changed)) |index| {
        const x = index % a.width;
        const y = top + index / a.width;
        start = index + 1;
        if (redistributedCoverage(a, b, x, y)) {
            cells[index] = .clear;
        } else if (recolouredStroke(a.row(y), b.row(y), x)) |stroke| {
            // A uniform colour change along an aliased stroke can be
            // interrupted in the mask where it crosses nearby glyphs.
            const row_start = index - x;
            @memset(cells[row_start + stroke[0] .. row_start + stroke[1]], .changed);
            start = row_start + stroke[1];
        }
    }
}

/// Reports whether two pixels differ beyond the colour threshold.
pub inline fn aboveThreshold(a: Pixel, b: Pixel, byte_offset: usize) bool {
    if (same(a, b)) return false;
    return aboveColourThreshold(a, b, byte_offset);
}

noinline fn aboveColourThreshold(a: Pixel, b: Pixel, byte_offset: usize) bool {
    const d = delta(a, b, byte_offset);
    return yiq(f64, d[0], d[1], d[2]) > max_delta;
}

noinline fn maskBackdrop(a: SampledRaster, b: SampledRaster, old: []const Pixel, new: []const Pixel, before: []const PixelBlock, out: []MaskBlock, y: usize, policy: EdgePolicy) bool {
    const fill: @Vector(lanes, u32) = @splat(@bitCast(new[0]));
    var found = false;
    for (before, out, 0..) |*row, *cells, block| {
        const packed_pixels = pixel.load(row);
        const equal = packed_pixels == fill;
        if (@reduce(.And, equal)) {
            cells.* = @splat(.clear);
        } else if (changedBlock(a, b, old, new, packed_pixels, fill, equal, block * lanes, y, policy, cells)) found = true;
    }
    return found;
}

noinline fn changedBlock(a: SampledRaster, b: SampledRaster, old: []const Pixel, new: []const Pixel, pa: @Vector(lanes, u32), pb: @Vector(lanes, u32), equal: @Vector(lanes, bool), x: usize, y: usize, policy: EdgePolicy, cells: *MaskBlock) bool {
    const fully_opaque = (channelInt(lanes, pa, 3) & channelInt(lanes, pb, 3)) == @as(@Vector(lanes, u32), @splat(255));
    if (@reduce(.And, selectBool(lanes, equal, fully_opaque))) {
        const r = channel(lanes, pa, 0) - channel(lanes, pb, 0);
        const g = channel(lanes, pa, 1) - channel(lanes, pb, 1);
        const blue = channel(lanes, pa, 2) - channel(lanes, pb, 2);
        const candidates = yiq(ColorLanes, r, g, blue) > constant(ColorLanes, max_delta);
        if (@reduce(.And, candidates) and flatBlock(a, old, pa, x, y) and flatBlock(b, new, pb, x, y)) {
            cells.* = @splat(.changed);
            return true;
        }
        return writeChangedLanes(a, b, x, y, policy, markChange, laneBits(candidates), cells);
    } else {
        const different = @select(bool, equal, @as(@Vector(lanes, bool), @splat(false)), @as(@Vector(lanes, bool), @splat(true)));
        return writeChangedLanes(a, b, x, y, policy, scalarChange, laneBits(different), cells);
    }
}

fn laneBits(mask_: @Vector(lanes, bool)) LaneBits {
    const bits: LaneBits = @bitCast(mask_);
    return if (@import("builtin").target.cpu.arch.endian() == .little) bits else @bitReverse(bits);
}

// Keep the sparse walk out of the hot mask and share it between classifiers.
noinline fn writeChangedLanes(a: SampledRaster, b: SampledRaster, x: usize, y: usize, policy: EdgePolicy, classify: *const @TypeOf(markChange), bits: LaneBits, output: *[lanes]change_mask.Cell) bool {
    @branchHint(.cold);
    output.* = @splat(.clear);
    var remaining = bits;
    var changed = false;
    while (remaining != 0) {
        const lane = @ctz(remaining);
        remaining &= remaining - 1;
        const cell = classify(a, b, x + lane, y, policy);
        output[lane] = cell;
        changed = changed or cell != .clear;
    }
    return changed;
}

fn recolouredStroke(old: []const Pixel, new: []const Pixel, x: usize) ?[2]usize {
    const before = old[x];
    const after = new[x];
    if (before[3] != 255 or after[3] != 255 or channelDelta(before, after) <= faint_speck_delta) return null;
    var left = x;
    while (left > 0 and same(old[left - 1], before) and same(new[left - 1], after)) left -= 1;
    var right = x + 1;
    while (right < old.len and same(old[right], before) and same(new[right], after)) right += 1;
    return if (right - left >= min_recoloured_stroke) .{ left, right } else null;
}

// Three equal neighbours rule out anti-aliasing. Check all lanes together
// in the interior of solid fills and leave crop edges to the full check.
inline fn flatBlock(raster: SampledRaster, row: []const Pixel, center: @Vector(lanes, u32), x: usize, y: usize) bool {
    if (x == 0 or x + lanes == raster.width) return false;
    if (row.len != 1 and
        (!@reduce(.And, center == pixel.load(row[x - 1 ..][0..lanes])) or
            !@reduce(.And, center == pixel.load(row[x + 1 ..][0..lanes])))) return false;
    return (y > 0 and sameBlock(center, raster.row(y - 1), x)) or
        (y + 1 < raster.height and sameBlock(center, raster.row(y + 1), x));
}

inline fn sameBlock(center: @Vector(lanes, u32), row: []const Pixel, x: usize) bool {
    const sample: @Vector(lanes, u32) = if (row.len == 1) @splat(@bitCast(row[0])) else pixel.load(row[x..][0..lanes]);
    return @reduce(.And, center == sample);
}

fn redistributedCoverage(a: SampledRaster, b: SampledRaster, x: usize, y: usize) bool {
    const old = a.at(x, y);
    const new = b.at(x, y);
    if (old[3] != 255 or new[3] != 255) return false;

    const highest_delta = channelDelta(old, new);
    if (highest_delta * coverage_divisor > @max(edgeContrast(a, x, y), edgeContrast(b, x, y)) or
        !coverageEdge(a, x, y, old) or !coverageEdge(b, x, y, new)) return false;

    const x0 = x -| moved_coverage_radius;
    const y0 = y -| moved_coverage_radius;
    const x1 = @min(x + moved_coverage_radius + 1, a.width);
    const y1 = @min(y + moved_coverage_radius + 1, a.height);
    var dark: Pixel = undefined;
    var light: Pixel = undefined;
    var min: i32 = 3 * 255 + 1;
    var max: i32 = -1;
    var gained: i32 = 0;
    var lost: i32 = 0;
    for (y0..y1) |ny| {
        const ar = a.row(ny);
        const br = b.row(ny);
        for (ar[x0..x1], br[x0..x1]) |p, q| {
            if (p[3] != 255 or q[3] != 255) continue;
            if (!same(p, q)) {
                const difference = brightness(q) - brightness(p);
                gained += @max(0, difference);
                lost -= @min(0, difference);
            } else {
                const level = brightness(p);
                if (level < min) {
                    min = level;
                    dark = p;
                }
                if (level > max) {
                    max = level;
                    light = p;
                }
            }
        }
    }

    // A changed fill or stroke weight produces a net gain or loss of ink.
    // A coverage change near an edge largely redistributes it.
    if (max <= min or @min(gained, lost) * 3 < @max(gained, lost)) return false;
    var channel_index: usize = 0;
    var contrast: i32 = 0;
    inline for (0..3) |c| {
        const span = @as(i32, light[c]) - dark[c];
        if (span > contrast) {
            contrast = span;
            channel_index = c;
        }
    }
    if (highest_delta * coverage_divisor > contrast) return false;
    return coverageBlend(old, dark, light, channel_index, contrast) and coverageBlend(new, dark, light, channel_index, contrast);
}

// Measure contrast across the edge on the sample's own row. A nearby
// darker stroke must not lend its contrast to a lighter stroke.
fn edgeContrast(a: SampledRaster, x: usize, y: usize) i32 {
    const cx = a.left + x;
    const cy = a.top + y;
    const middle = a.sample(cx, cy);
    var min = middle;
    var max = middle;
    for (cx -| 2..@min(cx + 3, a.image.width)) |nx| {
        const sample = a.sample(nx, cy);
        inline for (0..3) |c| {
            min[c] = @min(min[c], sample[c]);
            max[c] = @max(max[c], sample[c]);
        }
    }
    var contrast: i32 = 0;
    inline for (0..3) |c| contrast = @max(contrast, @as(i32, max[c]) - min[c]);
    return contrast;
}

fn coverageEdge(raster: SampledRaster, x: usize, y: usize, center: Pixel) bool {
    for (y -| 1..@min(y + 2, raster.height)) |ny| {
        for (raster.row(ny)[x -| 1..@min(x + 2, raster.width)]) |pixel_value| {
            if (!same(center, pixel_value)) return true;
        }
    }
    return false;
}

fn channelDelta(a: Pixel, b: Pixel) i32 {
    var delta_max: i32 = 0;
    inline for (0..3) |c| delta_max = @max(delta_max, @as(i32, @intCast(@abs(@as(i32, a[c]) - b[c]))));
    return delta_max;
}

fn brightness(p: Pixel) i32 {
    return @as(i32, p[0]) + p[1] + p[2];
}

fn coverageBlend(sample: Pixel, dark: Pixel, light: Pixel, channel_index: usize, contrast: i32) bool {
    const level = @as(i32, sample[channel_index]) - dark[channel_index];
    if (level < -blend_rounding or level > contrast + blend_rounding) return false;
    inline for (0..3) |c| {
        const actual = (@as(i32, sample[c]) - dark[c]) * contrast;
        const expected = (@as(i32, light[c]) - dark[c]) * level;
        if (@abs(actual - expected) > blend_rounding * contrast) return false;
    }
    return true;
}

fn selectBool(comptime n: usize, a: @Vector(n, bool), b: @Vector(n, bool)) @Vector(n, bool) {
    return @select(bool, a, @as(@Vector(n, bool), @splat(true)), b);
}

fn channelInt(comptime n: usize, pixels: @Vector(n, u32), comptime index: usize) @Vector(n, u32) {
    const shift: u5 = if (@import("builtin").target.cpu.arch.endian() == .little) index * 8 else (3 - index) * 8;
    return (pixels >> @as(@Vector(n, u5), @splat(shift))) & @as(@Vector(n, u32), @splat(255));
}

fn channel(comptime n: usize, pixels: @Vector(n, u32), comptime index: usize) @Vector(n, f32) {
    return @floatFromInt(channelInt(n, pixels, index));
}

fn scalarChange(a: SampledRaster, b: SampledRaster, x: usize, y: usize, policy: EdgePolicy) change_mask.Cell {
    // The mask loop bounds x and y to both rasters and their validated pixel count.

    const byte_offset = ((a.top + y) * a.image.width + a.left + x) * @sizeOf(Pixel);
    if (!aboveThreshold(a.at(x, y), b.at(x, y), byte_offset)) return .clear;
    return markChange(a, b, x, y, policy);
}

fn markChange(a: SampledRaster, b: SampledRaster, x: usize, y: usize, policy: EdgePolicy) change_mask.Cell {
    if (!realChange(a, b, x, y)) return .clear;
    if (policy == .stationary) {
        const old = a.at(x, y);
        const new = b.at(x, y);
        if (old[3] == 255 and new[3] == 255) {
            const delta_max = channelDelta(old, new);
            // Isolated changes at the edge of the colour threshold are
            // speck noise even on a flat field.
            if (delta_max <= faint_speck_delta) return .needs_support;
            const difference = delta_max * coverage_divisor;
            if (difference <= 255 and difference <= @max(edgeContrast(a, x, y), edgeContrast(b, x, y))) {
                if (stationaryCoverage(a, b, x, y)) return .clear;
                if (betweenNeighbours(a, x, y, old) and betweenNeighbours(b, x, y, new)) return .needs_support;
            }
        }
    }
    return .changed;
}

fn stationaryCoverage(a: SampledRaster, b: SampledRaster, x: usize, y: usize) bool {
    const old_x = a.left + x;
    const old_y = a.top + y;
    const left = old_x -| moved_coverage_radius;
    const top = old_y -| moved_coverage_radius;
    const width = @min(old_x + moved_coverage_radius + 1, a.image.width, b.image.width) - left;
    const height = @min(old_y + moved_coverage_radius + 1, a.image.height, b.image.height) - top;
    const before = SampledRaster.init(.{ .image = a.image, .left = left, .top = top, .width = width, .height = height });
    const after = SampledRaster.init(.{ .image = b.image, .left = left, .top = top, .width = width, .height = height });
    return redistributedCoverage(before, after, old_x - left, old_y - top);
}

fn betweenNeighbours(a: SampledRaster, x: usize, y: usize, color: Pixel) bool {
    const cx = a.left + x;
    const cy = a.top + y;
    const lightness = brightness(color);
    var darker = false;
    var lighter = false;
    for (cy -| 1..@min(cy + 2, a.image.height)) |ny| {
        for (cx -| 1..@min(cx + 2, a.image.width)) |nx| {
            const neighbour = a.sample(nx, ny);
            if (neighbour[3] != 255) continue;
            const level = brightness(neighbour);
            darker = darker or level < lightness;
            lighter = lighter or level > lightness;
            if (darker and lighter) return true;
        }
    }
    return false;
}

fn realChange(a: SampledRaster, b: SampledRaster, x: usize, y: usize) bool {
    if (!antialiased(a, b, x, y) and !antialiased(b, a, x, y)) return true;
    const contrast = @max(edgeContrast(a, x, y), edgeContrast(b, x, y));
    if (channelDelta(a.at(x, y), b.at(x, y)) * coverage_divisor <= contrast) return false;
    // Preserve solid stroke edits that touch an anti-aliased edge.
    if (straightStroke(a, x, y) and straightStroke(b, x, y)) return true;
    if (!a.real or !b.real) return false;
    return solidPatch(a, b, x, y, contrast) or solidPatch(b, a, x, y, contrast);
}

fn solidPatch(a: SampledRaster, b: SampledRaster, x: usize, y: usize, contrast: i32) bool {
    const color = a.at(x, y);
    if (color[3] != 255) return false;
    const left: usize = if (@min(a.left, b.left) + x != 0) 1 else 0;
    const above: usize = if (@min(a.top, b.top) + y != 0) 1 else 0;
    const right = @intFromBool(x + 1 < @min(a.image.width - a.left, b.image.width - b.left));
    const below = @intFromBool(y + 1 < @min(a.image.height - a.top, b.image.height - b.top));
    for (0..above + below) |dy| {
        for (0..left + right) |dx| {
            const ax = a.left + x + dx - left;
            const ay = a.top + y + dy - above;
            const bx = b.left + x + dx - left;
            const by = b.top + y + dy - above;
            if (changedPatch(a, b, ax, ay, bx, by, color, contrast)) return true;
        }
    }
    return false;
}

fn changedPatch(a: SampledRaster, b: SampledRaster, ax: usize, ay: usize, bx: usize, by: usize, color: Pixel, contrast: i32) bool {
    for (0..2) |dy| {
        for (0..2) |dx| {
            if (!same(a.sample(ax + dx, ay + dy), color) or
                channelDelta(color, b.sample(bx + dx, by + dy)) * coverage_divisor <= contrast) return false;
        }
    }
    return true;
}

fn straightStroke(a: SampledRaster, x: usize, y: usize) bool {
    const cx = a.left + x;
    const cy = a.top + y;
    if (cy == 0 or cy + 1 == a.image.height) return false;
    const p = a.sample(cx, cy);
    return p[3] == 255 and (same(p, a.sample(cx, cy - 1)) or same(p, a.sample(cx, cy + 1)));
}

fn delta(a: Pixel, b: Pixel, index: usize) [3]f64 {
    // RGBA8 channel products fit i32 and the validated crop byte index fits i64.
    var d: [3]f64 = undefined;
    if (a[3] == 255 and b[3] == 255) {
        inline for (0..3) |i| d[i] = @floatFromInt(@as(i32, a[i]) - b[i]);
    } else {
        // Pixelmatch blends transparent samples over this checkerboard.
        // The crop byte offset is bounded by the RGBA8 pixel cap and fits both conversions.
        const k: f64 = @floatFromInt(index);
        const green: i64 = @intFromFloat(k / 1.618033988749895);
        const blue: i64 = @intFromFloat(k / 2.618033988749895);
        const back = [3]i32{ 48, 48 + 159 * @as(i32, @intCast(green & 1)), 48 + 159 * @as(i32, @intCast(blue & 1)) };
        const da = @as(i32, a[3]) - b[3];
        inline for (0..3) |i| {
            const diff = @as(i32, a[i]) * a[3] - @as(i32, b[i]) * b[3] - back[i] * da;
            d[i] = @as(f64, @floatFromInt(diff)) / 255;
        }
    }
    return d;
}

fn constant(comptime T: type, comptime k: f64) T {
    // The opaque-vector threshold is checked exhaustively against f64.
    return switch (@typeInfo(T)) {
        .vector => |v| @splat(@as(v.child, @floatCast(k))),
        .float => @floatCast(k),
        else => @compileError("YIQ requires a scalar or vector floating-point type"),
    };
}

fn luminance(comptime T: type, r: T, g: T, b: T) T {
    return r * constant(T, 0.29889531) + g * constant(T, 0.58662247) + b * constant(T, 0.11448223);
}

fn yiq(comptime T: type, r: T, g: T, b: T) T {
    const y = luminance(T, r, g, b);
    const i = r * constant(T, 0.59597799) - g * constant(T, 0.27417610) - b * constant(T, 0.32180189);
    const q = r * constant(T, 0.21147017) - g * constant(T, 0.52261711) + b * constant(T, 0.31114694);
    return constant(T, 0.5053) * y * y + constant(T, 0.299) * i * i + constant(T, 0.1957) * q * q;
}

// The neighborhood check exits as soon as it rules out anti-aliasing.
fn antialiased(a: SampledRaster, b: SampledRaster, x: usize, y: usize) bool {
    const cx = a.left + x;
    const cy = a.top + y;
    const p = a.sample(cx, cy);
    const x0 = cx -| 1;
    const y0 = cy -| 1;
    const x2 = @min(cx + 1, a.image.width - 1);
    const y2 = @min(cy + 1, a.image.height - 1);
    // Three matching neighbours already rule out anti-aliasing. Check the
    // centre row first, which is usually flat inside filled components.
    if (x0 != cx and x2 != cx and same(p, a.sample(x0, cy)) and same(p, a.sample(x2, cy)) and
        ((y0 != cy and same(p, a.sample(cx, y0))) or (y2 != cy and same(p, a.sample(cx, y2))))) return false;
    const k = (cy * a.image.width + cx) * 4;
    var zeroes: usize = @intFromBool(cx == x0 or cx == x2 or cy == y0 or cy == y2);
    var min: f64 = 0;
    var max: f64 = 0;
    var dark: Point = undefined;
    var light: Point = undefined;
    for (x0..x2 + 1) |nx| {
        for (y0..y2 + 1) |ny| {
            if (nx == cx and ny == cy) continue;
            const q = a.sample(nx, ny);
            const d = if (same(p, q)) 0 else lumaDelta(p, q, k);
            if (d == 0) {
                zeroes += 1;
                if (zeroes > 2) return false;
            } else if (d < min) {
                min = d;
                dark = .{ .x = nx, .y = ny };
            } else if (d > max) {
                max = d;
                light = .{ .x = nx, .y = ny };
            }
        }
    }
    if (min == 0 or max == 0) return false;
    return hasSiblings(a, b, dark, y) or hasSiblings(a, b, light, y);
}

fn hasSiblings(a: SampledRaster, b: SampledRaster, p: Point, y: usize) bool {
    // The extremum is at most one row from the centre in the first image.
    const row = b.top + y + 1;
    const offset = a.top + y + 1 - p.y;
    if (row < offset or row - offset >= b.image.height or p.x >= b.image.width) return false;
    const mapped_y = row - offset;
    return siblings(a, p) and siblings(b, .{ .x = p.x, .y = mapped_y });
}

fn lumaDelta(a: Pixel, b: Pixel, index: usize) f64 {
    const d = delta(a, b, index);
    return luminance(f64, d[0], d[1], d[2]);
}

fn siblings(a: SampledRaster, p: Point) bool {
    const color = a.sample(p.x, p.y);
    const x0 = p.x -| 1;
    const y0 = p.y -| 1;
    const x1 = @min(p.x + 2, a.image.width);
    const y1 = @min(p.y + 2, a.image.height);
    const width = x1 - x0;
    const repeated = a.x_mask == 0;
    const row_len = if (repeated) 1 else width;
    const weight = if (repeated) width else 1;
    // At an image edge, one missing neighbour counts as a match. Include
    // the centre in the scan and use one more than the neighbour threshold.
    const required: usize = if (width == 3 and y1 - y0 == 3) 4 else 3;
    var count: usize = 0;
    for (y0..y1) |y| {
        const row = a.pixels[a.index(x0, y)..][0..row_len];
        for (row) |sample| {
            count += @intFromBool(same(color, sample));
        }
        if (count * weight >= required) return true;
    }
    return false;
}

test "mask handles one pixel and a vector tail on the last cropped row" {
    const white: Pixel = @splat(255);
    const black: Pixel = .{ 0, 0, 0, 255 };
    const before: [2 * (lanes + 1)]Pixel = @splat(white);
    var after = before;
    after[lanes + 1] = black;
    after[after.len - 1] = .{ 0, 0, 0, 128 };
    var output: [lanes + 1]change_mask.Cell = undefined;
    const left: Raster = .{ .image = .{ .width = lanes + 1, .height = 2, .pixels = &before }, .left = 0, .top = 0, .width = lanes + 1, .height = 2 };
    var right = left;
    right.image.pixels = &after;
    try std.testing.expect(mask(left, right, 1, 1, &output));
    // The first pixel and the vector tail changed; every pixel between did not.
    var expected: [lanes + 1]change_mask.Cell = @splat(.clear);
    expected[0] = .changed;
    expected[lanes] = .changed;
    try std.testing.expectEqualSlices(change_mask.Cell, &expected, &output);
    const a: Raster = .{ .image = .{ .width = 1, .height = 1, .pixels = &.{white} }, .left = 0, .top = 0, .width = 1, .height = 1 };
    var b = a;
    b.image.pixels = &.{black};
    try std.testing.expect(mask(a, b, 0, 1, output[0..1]));
    try std.testing.expectEqual(change_mask.Cell.changed, output[0]);
}

test "moved coverage clears a balanced edge redraw and keeps a stroke weight edit" {
    const width = 13;
    const height = 8;
    const y = height / 2;
    const edge_x = 5;
    const left = y * width + edge_x;
    const right = left + 2;
    const background: Pixel = .{ 244, 244, 244, 255 };
    const ink: Pixel = .{ 64, 64, 64, 255 };
    const lower: Pixel = .{ 124, 124, 124, 255 };
    const higher: Pixel = .{ 164, 164, 164, 255 };
    var old: [width * height]Pixel = @splat(background);
    for (0..height) |row| old[row * width + edge_x ..][0..3].* = .{ lower, ink, higher };
    const a: Raster = .{ .image = .{ .width = width, .height = height, .pixels = &old }, .left = 0, .top = 0, .width = width, .height = height };
    for ([_]Pixel{ lower, higher }, [_]change_mask.Cell{ .clear, .changed }) |right_edge, expected| {
        var new = old;
        for (0..height) |row| new[row * width + edge_x ..][0..3].* = .{ higher, ink, right_edge };
        var b = a;
        b.image.pixels = &new;
        var cells: [width * height]change_mask.Cell = @splat(.clear);
        cells[left] = .changed;
        cells[right] = if (same(higher, right_edge)) .clear else .changed;
        clearMovedCoverage(a, b, 0, &cells);
        try std.testing.expectEqual(expected, cells[left]);
        try std.testing.expectEqual(change_mask.Cell.clear, cells[right]);
    }
}

test "opaque RGB delta cube has identical f32 and f64 thresholds" {
    const largest: i32 = std.math.maxInt(u8);
    const count = 2 * largest + 1;
    const test_lanes = 8;
    const Deltas = @Vector(test_lanes, i32);
    const Single = @Vector(test_lanes, f32);
    const Double = @Vector(test_lanes, f64);
    for (0..count) |red| {
        const r: Deltas = @splat(@as(i32, @intCast(red)) - largest);
        for (0..count) |green| {
            const g: Deltas = @splat(@as(i32, @intCast(green)) - largest);
            var start: i32 = -largest;
            while (start <= largest) : (start += test_lanes) {
                const b = @min(@as(Deltas, @splat(start)) + std.simd.iota(i32, test_lanes), @as(Deltas, @splat(largest)));
                const single = yiq(Single, @floatFromInt(r), @floatFromInt(g), @floatFromInt(b)) > constant(Single, max_delta);
                const double = yiq(Double, @floatFromInt(r), @floatFromInt(g), @floatFromInt(b)) > constant(Double, max_delta);
                if (!@reduce(.And, single == double)) return error.TestUnexpectedResult;
            }
        }
    }
}

test "prepared sampling preserves cropped, repeated-column and repeated-row coordinates" {
    const pixels = [_]Pixel{
        .{ 11, 0, 0, 255 }, .{ 22, 0, 0, 255 }, .{ 33, 0, 0, 255 },
        .{ 44, 0, 0, 255 }, .{ 55, 0, 0, 255 }, .{ 66, 0, 0, 255 },
    };
    var raster: Raster = .{
        .image = .{ .width = 3, .height = 2, .pixels = &pixels },
        .left = 1,
        .top = 0,
        .width = 2,
        .height = 2,
    };
    const cropped = SampledRaster.init(raster);
    try std.testing.expectEqualSlices(Pixel, pixels[4..6], cropped.row(1));
    try std.testing.expectEqual(pixels[5], cropped.at(1, 1));

    raster.background = .margin;
    const margin = SampledRaster.init(raster);
    try std.testing.expectEqualSlices(Pixel, pixels[4..5], margin.row(1));
    try std.testing.expectEqual(pixels[4], margin.at(1, 1));

    raster.background = .{ .row = pixels[0..3] };
    const repeated = SampledRaster.init(raster);
    try std.testing.expectEqualSlices(Pixel, pixels[1..3], repeated.row(1));
    try std.testing.expectEqual(pixels[2], repeated.at(1, 1));
}

test "repeated rows and repeated columns agree across vector blocks and the tail" {
    const width = 2 * lanes + 1;
    const height = 2;
    const white: Pixel = @splat(255);
    const ink: Pixel = .{ 0, 0, 0, 255 };
    const faded: Pixel = .{ 0, 0, 0, 128 };
    var pixels: [width * height]Pixel = @splat(white);
    @memset(pixels[0..lanes], ink);
    pixels[pixels.len - 1] = faded;
    const backdrop: [width * height]Pixel = @splat(white);
    const a: Raster = .{
        .image = .{ .width = width, .height = height, .pixels = &pixels },
        .left = 0,
        .top = 0,
        .width = width,
        .height = height,
    };
    var b = a;
    b.image.pixels = &backdrop;
    b.background = .{ .row = backdrop[0..width] };
    var rows: [pixels.len]change_mask.Cell = undefined;
    try std.testing.expect(mask(a, b, 0, height, &rows));
    b.background = .margin;
    var columns: [pixels.len]change_mask.Cell = undefined;
    try std.testing.expect(mask(a, b, 0, height, &columns));
    try std.testing.expectEqualSlices(change_mask.Cell, &rows, &columns);
}

test "sibling count includes a clipped edge and repeats virtual backdrop columns" {
    const white: Pixel = @splat(255);
    const ink: Pixel = .{ 0, 0, 0, 255 };
    const width = 3;
    var pixels: [width * width]Pixel = @splat(white);
    var raster: Raster = .{
        .image = .{ .width = width, .height = width, .pixels = &pixels },
        .left = 0,
        .top = 0,
        .width = width,
        .height = width,
    };
    const center: Point = .{ .x = 1, .y = 1 };
    pixels[0] = ink;
    pixels[2] = ink;
    pixels[4] = ink;
    try std.testing.expect(!siblings(SampledRaster.init(raster), center));
    try std.testing.expect(!siblings(SampledRaster.init(raster), .{ .x = 0, .y = 0 }));
    pixels[3] = ink;
    try std.testing.expect(siblings(SampledRaster.init(raster), center));
    try std.testing.expect(siblings(SampledRaster.init(raster), .{ .x = 0, .y = 0 }));

    raster.background = .margin;
    pixels[0] = white;
    try std.testing.expect(!siblings(SampledRaster.init(raster), center));
    pixels[0] = ink;
    try std.testing.expect(siblings(SampledRaster.init(raster), center));
}

test "antialiasing retains the first equally bright extremum" {
    const width = 5;
    const black: Pixel = .{ 0, 0, 0, 255 };
    var pixels: [width * width]Pixel = undefined;
    for (&pixels, 0..) |*sample, index| {
        const level: u8 = @intCast(40 + index * 4);
        sample.* = .{ level, level, level, 255 };
    }
    pixels[width + 1] = black;
    pixels[width + 3] = black;
    pixels[3 * width + 2] = @splat(255);
    for (0..3) |y| pixels[y * width + width - 1] = black;
    const raster = SampledRaster.init(.{
        .image = .{ .width = width, .height = width, .pixels = &pixels },
        .left = 0,
        .top = 0,
        .width = width,
        .height = width,
    });
    try std.testing.expect(!antialiased(raster, raster, 2, 2));
    for (0..width) |y| std.mem.reverse(Pixel, pixels[y * width ..][0..width]);
    try std.testing.expect(antialiased(raster, raster, 2, 2));
}

test {
    std.testing.refAllDecls(@This());
}
