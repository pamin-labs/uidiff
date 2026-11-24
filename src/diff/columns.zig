//! Finds the shared column span affected by a comparison.
const std = @import("std");
const values = @import("../value.zig");
const pixel = @import("pixel.zig");
const Image = values.Image;
const Pixel = values.Pixel;
const lanes = pixel.lanes;

/// A run of columns in device pixels.
pub const Span = struct { left: usize, width: usize };

/// A changed span and the columns available up to the middle of its gutters.
pub const Group = struct { span: Span, lane: Span };

/// A card outline enclosing an edited row.
pub const Card = struct { columns: Span, top: usize, height: usize };

const Edge = struct { left: usize, right: usize, color: Pixel };

/// Splits the changed interval at strips that are stationary for its full height.
pub const Partition = struct {
    left: usize,
    stationary: []const bool,
    start: usize = 0,
    lane_start: usize = 0,
    extent: usize,

    /// Returns the next changed span between stationary gutters.
    pub fn next(self: *Partition) ?Group {
        const start = std.mem.indexOfScalarPos(bool, self.stationary, self.start, false) orelse return null;
        const first = if (start - self.start >= min_gutter) start else self.start;
        self.start = start;
        while (std.mem.indexOfScalarPos(bool, self.stationary, self.start, true)) |at| {
            const end = std.mem.indexOfScalarPos(bool, self.stationary, at + 1, false) orelse self.stationary.len;
            self.start = end;
            if (end - at >= min_gutter or end == self.stationary.len) {
                const lane_end = if (end == self.stationary.len) self.extent else self.left + at + (end - at) / 2;
                return self.take(first, at, lane_end);
            }
        }
        self.start = self.stationary.len;
        return self.take(first, self.start, self.extent);
    }

    fn take(self: *Partition, first: usize, end: usize, lane_end: usize) Group {
        const lane = Span{ .left = self.lane_start, .width = lane_end - self.lane_start };
        self.lane_start = lane_end;
        return .{ .span = .{ .left = self.left + first, .width = end - first }, .lane = lane };
    }
};

/// The narrowest stationary strip that can separate independently moving columns.
pub const min_gutter = 16;
const max_card_search = 192;
const min_card_height = 12;
// A periodic check avoids scanning the rest of a solid full-width comparison.
const gutter_check_rows = 32;

/// Finds the shared-width interval containing every changed column.
/// Assumes both images are valid and width is at most the narrower one.
pub fn span(before: Image, after: Image, width: usize) Span {
    if (before.height != after.height) return .{ .left = 0, .width = width };
    return spanRows(before, after, .{ .left = 0, .width = width }, 0, before.height);
}

/// Finds stationary gutters across common rows and any unchanged extension.
pub fn partition(before: Image, after: Image, bounds: Span, stationary: []bool) Partition {
    @memset(stationary, true);
    const common = @min(before.height, after.height);
    for (0..common) |y| {
        markChanged(stationary, before.row(y)[bounds.left..][0..bounds.width], after.row(y)[bounds.left..][0..bounds.width]);
        if ((y + 1) % gutter_check_rows == 0 and !hasGutter(stationary)) {
            return .{ .left = bounds.left, .stationary = &.{}, .extent = bounds.left + bounds.width };
        }
    }
    const tall = if (before.height > after.height) before else after;
    const edge = tall.row(common - 1)[bounds.left..][0..bounds.width];
    for (common..tall.height) |y| {
        // A column with new content in the extension is still compared.
        markChanged(stationary, edge, tall.row(y)[bounds.left..][0..bounds.width]);
    }
    return .{ .left = bounds.left, .stationary = stationary, .extent = @min(before.width, after.width) };
}

/// Reports whether the span has the same horizontal paint on every row.
pub fn sameRows(image: Image, bounds: Span) bool {
    const first = image.rowBytes(0, bounds.left, bounds.width);
    for (1..image.height) |y| {
        const row = image.rowBytes(y, bounds.left, bounds.width);
        if (!std.mem.eql(u8, first, row)) return false;
    }
    return true;
}

/// Finds changed columns within a shared, validated rectangle.
pub fn spanRows(before: Image, after: Image, bounds: Span, top: usize, bottom: usize) Span {
    const width = bounds.width;
    var left = width;
    var right: usize = 0;
    for (top..bottom) |y| {
        if (left == 0 and right == width) break;
        const a = before.row(y)[bounds.left..][0..width];
        const b = after.row(y)[bounds.left..][0..width];
        var x: usize = 0;
        while (x + lanes <= left and equalBlock(a[x..][0..lanes], b[x..][0..lanes])) x += lanes;
        while (x < left) : (x += 1) {
            if (!pixel.same(a[x], b[x])) {
                left = x;
                right = @max(right, x + 1);
                break;
            }
        }
        if (right == 0) continue;
        x = width;
        while (x - right >= lanes and equalBlock(a[x - lanes ..][0..lanes], b[x - lanes ..][0..lanes])) x -= lanes;
        while (x > right) {
            x -= 1;
            if (!pixel.same(a[x], b[x])) {
                right = x + 1;
                break;
            }
        }
    }
    return .{ .left = if (right == 0) 0 else bounds.left + left, .width = right -| left };
}

/// Finds a card around a text-width alignment by requiring matching top and
/// bottom rules plus the two sides between them.
pub fn enclosingCard(image: Image, ink: Span, lane: Span, y: usize, pitch: usize) ?Card {
    if (ink.width * 2 >= lane.width or pitch < min_card_height) return null;
    const reach = @min(pitch, max_card_search);
    for (0..reach + 1) |distance| {
        if (distance > y) break;
        const top = y - distance;
        const center = ink.left + ink.width / 2;
        if (top + 1 >= image.height or pixel.same(image.row(top)[center], image.row(top + 1)[center])) continue;
        const edge = horizontalEdge(image, top, ink, lane, 2 * ink.width) orelse continue;
        const lower_limit = @min(image.height, top + reach + 1);
        for (@max(y, top + min_card_height)..@max(@max(y, top + min_card_height), lower_limit)) |bottom| {
            if (!pixel.same(image.row(bottom)[center], edge.color) or
                pixel.same(image.row(bottom - 1)[center], edge.color)) continue;
            const lower = horizontalEdge(image, bottom, ink, lane, 2 * ink.width) orelse continue;
            if (edge.left != lower.left or edge.right != lower.right or !pixel.same(edge.color, lower.color)) continue;
            const middle = top + (bottom - top) / 2;
            const box = outlineSides(image, middle, edge, lane) orelse continue;
            return .{ .columns = box, .top = top, .height = bottom - top + 1 };
        }
    }
    return null;
}

/// Recognizes the closing rule of a bordered sub-panel rather than a new
/// colored item. Its two edges continue vertically above the rule.
pub fn closesPanel(image: Image, ink: Span, y: usize) bool {
    if (y < 2 or ink.width == image.width) return false;
    const lane: Span = .{ .left = 0, .width = image.width };
    const edge = horizontalEdge(image, y, ink, lane, ink.width) orelse return false;
    if (edge.left >= ink.left or edge.right <= ink.left + ink.width) return false;
    const above = image.row(y - 1);
    const previous = image.row(y - 2);
    const left = edge.left;
    const right = edge.right - 1;
    return pixel.same(above[left], edge.color) and pixel.same(above[right], edge.color) and
        pixel.same(previous[left], edge.color) and pixel.same(previous[right], edge.color) and
        !pixel.same(above[ink.left + ink.width / 2], edge.color);
}

fn horizontalEdge(image: Image, y: usize, ink: Span, lane: Span, minimum: usize) ?Edge {
    const row = image.row(y);
    const center = ink.left + ink.width / 2;
    const color = row[center];
    const limit = lane.left + lane.width;
    if (pixel.same(row[lane.left], color) and pixel.same(row[limit - 1], color)) return null;
    var left = center;
    while (left > lane.left and pixel.same(row[left - 1], color)) left -= 1;
    var right = center + 1;
    while (right < limit and pixel.same(row[right], color)) right += 1;
    if (left > ink.left or right < ink.left + ink.width or right - left < minimum or
        left == lane.left or right == limit) return null;
    return .{ .left = left, .right = right, .color = color };
}

fn outlineSides(image: Image, middle: usize, edge: Edge, lane: Span) ?Span {
    const row = image.row(middle);
    const other = image.row(middle + 1);
    if (pixel.same(row[edge.left + (edge.right - edge.left) / 2], edge.color)) return null;
    const left_limit = @max(lane.left, edge.left -| min_gutter);
    const right_limit = @min(lane.left + lane.width, edge.right + min_gutter);
    const left = for (left_limit..edge.left + 1) |x| {
        if (pixel.same(row[x], edge.color) and pixel.same(other[x], edge.color)) break x;
    } else return null;
    const right = for (0..right_limit - edge.right + 1) |dx| {
        const x = right_limit - 1 - dx;
        if (pixel.same(row[x], edge.color) and pixel.same(other[x], edge.color)) break x + 1;
    } else return null;
    return .{ .left = left, .width = right - left };
}

fn markChanged(stationary: []bool, before: []const Pixel, after: []const Pixel) void {
    if (std.mem.eql(u8, std.mem.sliceAsBytes(before), std.mem.sliceAsBytes(after))) return;
    for (stationary, before, after) |*stable, old, new| stable.* = stable.* and pixel.same(old, new);
}

fn hasGutter(stationary: []const bool) bool {
    var x: usize = 0;
    while (x + min_gutter <= stationary.len) {
        const changed = std.mem.findScalarLast(bool, stationary[x..][0..min_gutter], false) orelse return true;
        x += changed + 1;
    }
    return false;
}

fn equalBlock(a: *const [lanes]Pixel, b: *const [lanes]Pixel) bool {
    return @reduce(.And, pixel.load(a) == pixel.load(b));
}

test "the last row includes both changed edges around a vector tail" {
    const white: Pixel = @splat(255);
    const old: [2 * (lanes + 1)]Pixel = @splat(white);
    var new = old;
    new[lanes + 1][0] = 0;
    new[new.len - 1][3] = 128;
    const found = span(.{ .width = lanes + 1, .height = 2, .pixels = &old }, .{ .width = lanes + 1, .height = 2, .pixels = &new }, lanes + 1);
    try std.testing.expectEqual(@as(usize, 0), found.left);
    try std.testing.expectEqual(@as(usize, lanes + 1), found.width);
}

test {
    std.testing.refAllDecls(@This());
}
