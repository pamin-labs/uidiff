//! Row hashes and linear-space Myers alignment for scrolling and resizing.
const std = @import("std");
const values = @import("../value.zig");
const columns = @import("columns.zig");
const Image = values.Image;
const Allocator = std.mem.Allocator;

/// A pair of row ranges, with any surplus treated as one-sided.
pub const Band = struct {
    before: usize,
    after: usize,
    removed: usize,
    added: usize,
    /// A verified row-hash run, or the background row for revealed content.
    mode: union(enum) { regular, hash_match, replacement, spacing, element, revealed: usize } = .regular,
};
/// Device-pixel limits for identifying small scrolls and replacements.
pub const Limits = struct {
    scroll: usize,
    replacement: usize,
    narrow_edit: bool = false,
    images: ?[2]Image = null,
    left: usize = 0,
    width: usize = 0,
};

const Match = struct {
    before: usize,
    after: usize,
    length: usize = 1,

    fn offset(self: Match) isize {
        return @as(isize, @intCast(self.after)) - @as(isize, @intCast(self.before));
    }
};
const Keys = []const u64;
const Coordinate = struct { x: u32 = 0, y: u32 = 0 };
const Diagonal = struct { x: u32 = missing, middle: Coordinate = .{} };
const SearchResult = struct { edits: usize, middle: Coordinate };
const Problem = struct {
    a: Keys,
    b: Keys,
    prefix: usize,

    fn init(before: Keys, after: Keys) Problem {
        var prefix: usize = 0;
        while (prefix < @min(before.len, after.len) and before[prefix] == after[prefix]) : (prefix += 1) {}
        return .{ .a = before[prefix..], .b = after[prefix..], .prefix = prefix };
    }

    fn distance(self: Problem, budget: usize, frontier: []Diagonal) ?usize {
        const delta = @max(self.a.len, self.b.len) - @min(self.a.len, self.b.len);
        if (@min(self.a.len, self.b.len) == 0) return delta;
        if (delta != 0 and self.oneDirection(null, 0, 0)) return delta;
        return (search(false, self.a, self.b, budget, 0, frontier) orelse return null).edits;
    }

    fn matches(self: Problem, edits: usize, frontier: []Diagonal, out: []Match) ?[]const Match {
        const len = self.prefix + (self.a.len + self.b.len - edits) / 2;
        if (!self.recover(edits, frontier, out[0..len], 0, 0)) return null;
        return out[0..len];
    }

    fn recover(self: Problem, edits: usize, frontier: []Diagonal, out: []Match, old_y: usize, new_y: usize) bool {
        for (out[0..self.prefix], 0..) |*m, row| m.* = .{ .before = old_y + row, .after = new_y + row };
        const tail = out[self.prefix..];
        if (tail.len == 0) return true;
        const a = old_y + self.prefix;
        const b = new_y + self.prefix;
        const delta = @max(self.a.len, self.b.len) - @min(self.a.len, self.b.len);
        if (edits == delta) return self.oneDirection(tail, a, b);

        // Carry the chosen path's middle coordinate on each diagonal. Split at
        // that coordinate, then reuse the same frontier in both halves.
        const half = edits / 2;
        const result = search(true, self.a, self.b, edits, half, frontier) orelse return false;
        const x: usize = result.middle.x;
        const y: usize = result.middle.y;
        // Each edit advances one coordinate, and each equal row advances both.
        const first_len = (x + y - half) / 2;
        return Problem.init(self.a[0..x], self.b[0..y]).recover(half, frontier, tail[0..first_len], a, b) and
            Problem.init(self.a[x..], self.b[y..]).recover(edits - half, frontier, tail[first_len..], a + x, b + y);
    }

    fn oneDirection(self: Problem, out: ?[]Match, old_y: usize, new_y: usize) bool {
        const insertions = self.a.len < self.b.len;
        const short = if (insertions) self.a else self.b;
        const long = if (insertions) self.b else self.a;
        var j: usize = 0;
        for (long, 0..) |key, i| {
            if (j == short.len) break;
            if (key != short[j]) continue;
            if (out) |result| result[j] = .{
                .before = old_y + if (insertions) j else i,
                .after = new_y + if (insertions) i else j,
            };
            j += 1;
        }
        return j == short.len;
    }
};

/// A brief change in displacement that can be compared as a row replacement.
const max_replacement_rows = 64;
const max_panel_shift = 512;
const max_panel_candidates = 8;

// Footer chrome must begin within the last quarter of the image.
const footer_zone_divisor = 4;
// A footer edge should cross at least half the image.
const footer_edge_divisor = 2;
// Narrow paint can extend beyond the length of a normal row replacement.
const narrow_paint_rows = 128;
// A row cluster can contain two separate overpaints with overlapping heights.
const paint_cluster_rows = 2 * narrow_paint_rows;
// A small re-pairing can be caused by repeated rows inside one stroke.
const min_detour_rows = 8;
const detour_scroll_multiplier = 2;
// Require three quarters changed rows for one continuous overpaint.
const paint_density_numerator = 3;
const paint_density_denominator = 4;
// Separate local edits need an exact stationary run between their rows.
const paint_anchor_rows = 8;
const narrow_paint_width_divisor = 2;

// An inset paint stripe that returns to the body within this many rows
// can be an item after a deletion, even close to the bottom of the image.
const max_inset_stripe_rows = 32;

const missing: u32 = std.math.maxInt(u32);
/// The most row insertions plus deletions the alignment searches for. Myers'
/// search costs O((rows + max_edits) * max_edits) time, so this bounds a tall
/// unrelated pair; past it, rows are compared by position.
pub const max_edits = 8192;

/// Hashes each row of the column span. Asserts output.len equals the image
/// height and left + width is at most its width.
pub fn keys(source: Image, left: usize, width: usize, output: []u64) void {
    for (output, 0..) |*key, y| key.* = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(source.row(y)[left..][0..width]));
}

/// Matches a compact insertion when the rest of the column shifts exactly.
pub fn compactInsertion(before: Keys, after: Keys, limit: usize, bands: []Band) ?[]Band {
    if (before.len != after.len) return null;
    const problem = Problem.init(before, after);
    if (problem.a.len < 2) return null;
    const aligned = clippedInsertion(problem, limit, bands) orelse return null;
    const gap = aligned[1];
    if (std.mem.allEqual(u64, after[gap.after .. gap.after + gap.added], after[after.len - 1])) return null;
    return aligned;
}

/// Aligns rows into caller-owned bands, or returns null for positional comparison.
pub fn matchBands(allocator: Allocator, before: Keys, after: Keys, limits: Limits, bands: []Band, filtered: []u64) Allocator.Error!?[]Band {
    const limit = limits.scroll;
    const replacement_limit = @min(max_replacement_rows, limits.replacement);
    const main = Problem.init(before, after);
    if (@min(main.a.len, main.b.len) == 0) return null;
    const viewport = before.len == after.len;
    if (viewport and main.prefix != 0) {
        if (positionalPaintBands(before, after, main.prefix, limits, bands)) |paint| return paint;
    }
    if (viewport and main.prefix != 0 and limits.images != null) {
        if (panelInsertion(before, after, main.prefix, limits, bands)) |aligned| return aligned;
        var reversed = limits;
        reversed.images = .{ limits.images.?[1], limits.images.?[0] };
        if (panelInsertion(after, before, main.prefix, reversed, bands)) |aligned| {
            for (aligned) |*band| {
                std.mem.swap(usize, &band.before, &band.after);
                std.mem.swap(usize, &band.removed, &band.added);
            }
            return aligned;
        }
    }
    const positional = if (viewport)
        localEditCost(before, after, main.prefix, limits)
    else
        null;
    if (viewport and positional == null and main.prefix != 0) {
        if (clippedInsertion(main, limit, bands)) |aligned| return aligned;
    }
    const overlap = @min(before.len, after.len);
    const raw = try allocator.alloc(Match, overlap);
    defer allocator.free(raw);
    // Both key slices come from validated image heights, which fit u32.
    const budget: usize = @min(max_edits, @max(before.len, after.len));
    var counts: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer counts.deinit(allocator);
    try counts.ensureTotalCapacity(allocator, @intCast(@max(before.len, after.len)));
    const old_background = background(&counts, before);
    var shared: usize = 0;
    for (after) |row| {
        const count = counts.getPtr(row) orelse continue;
        if (count.* == 0) continue;
        count.* -= 1;
        shared += 1;
    }
    if (before.len + after.len - 2 * shared > budget) return null;
    counts.clearRetainingCapacity();
    const new_background = background(&counts, after);

    const frontier_budget: usize = @min(max_edits, before.len + after.len);
    const frontier = try allocator.alloc(Diagonal, 2 * frontier_budget + 3);
    defer allocator.free(frontier);
    const distance = main.distance(budget, frontier) orelse return null;
    // A local edit's two-sided cost competes with a motion path plus the
    // penalty for leaving the alignment and returning to it.
    if (positional) |edit| {
        // A local overwrite still has same-position ink below it. A change
        // reaching the end of the column can be an insertion and clipping.
        for (before[edit.end..], after[edit.end..], edit.end..) |old, new, y| {
            if (old == new and isContent(old, old_background, new_background)) {
                if (limits.images) |images| {
                    if (y >= before.len - before.len / footer_zone_divisor and flatPaint(images[0], y, y + 1, 0, images[0].width)) break;
                }
                if (edit.cost <= distance + 2 * edit.limit) return null;
                break;
            }
        }
    }
    const equal = main.matches(distance, frontier, raw) orelse return null;
    const content = try allocator.alloc(Match, equal.len);
    defer allocator.free(content);

    var content_rows: usize = 0;
    const interior = equal.len != 0 and (equal[equal.len - 1].before != equal.len - 1 or equal[equal.len - 1].after != equal.len - 1);
    var count: usize = 0;
    for (equal) |m| {
        if (!isContent(before[m.before], old_background, new_background)) continue;
        content_rows += 1;
        extend(content, &count, m);
    }

    var first_offset = if (count > 0) content[0].offset() else 0;
    if (viewport and first_offset != 0 and @abs(first_offset) <= limit) {
        const skip = @abs(first_offset);
        const old_start = if (first_offset < 0) skip else 0;
        const new_start = if (first_offset > 0) skip else 0;
        const rows = overlap - skip;
        var explained: usize = 0;
        var ambiguous = false;
        for (before[old_start..][0..rows], after[new_start..][0..rows]) |old, new| {
            if (old != new or !isContent(old, old_background, new_background)) continue;
            explained += 1;
            if (!ambiguous) ambiguous = (counts.get(old) orelse 0) > 1;
        }

        // A short, mostly repeated shift can win Myers' row count by matching
        // background at the expense of content. Check the content-only path
        // before using the shortcut to compare everything at that offset.
        const alternative = if (ambiguous)
            alignContent(before, after, old_background, new_background, @max(content_rows, explained), frontier, raw, filtered)
        else
            null;
        if (alternative) |matches| {
            count = 0;
            for (matches) |m| extend(content, &count, m);
            first_offset = content[0].offset();
        } else if (count == 1 and explained >= content_rows) {
            var len: usize = 0;
            append(bands, &len, .{ .before = old_start, .after = new_start, .removed = rows, .added = rows });
            if (first_offset < 0) reveal(bands, &len, after, before.len, rows, new_background);
            return bands[0..len];
        }
    }
    for (content[0..count]) |m| {
        if (m.offset() != 0) break;
    } else if (viewport or !interior or equal.len != overlap) return null;

    if (viewport and !hasDisplacedContent(content[0..count], before, after)) return null;

    var footer = count;
    if (viewport and count >= 2) {
        footer = footerStart(content[0..count], before, after, old_background, new_background, limits);
        if (footer < count) {
            // Footer edits can break the stationary run into several matches.
            // Compare the entire footer by position, including those edits.
            content[footer].length = before.len - content[footer].before;
            count = footer + 1;
        }

        const after_end = if (footer == count) after.len else content[footer].after;
        const kept = visibleAnchors(content[0..footer], before, after, after_end, limit);
        if (kept < footer) {
            if (footer < count) {
                content[kept] = content[footer];
                count = kept + 1;
            } else {
                count = kept;
            }
            footer = kept;
        }
    }
    var len: usize = 0;
    var old_y: usize = 0;
    var new_y: usize = 0;
    var i: usize = 0;
    while (i <= count) : (i += 1) {
        if (i != 0 and i + 1 < count and (old_y != new_y or viewport) and
            shortDetour(content[i], old_y, new_y, limit))
        {
            if (replacementEnd(content[i + 1 .. count], old_y, new_y, replacement_limit)) |skip| {
                const next = content[i + 1 + skip];
                const length = next.before - old_y;
                append(bands, &len, .{ .before = old_y, .after = new_y, .removed = length, .added = length, .mode = .replacement });
                old_y = next.before;
                new_y = next.after;
                i += skip;
                continue;
            }
        }
        const end = i == count;
        const m = if (end) Match{ .before = before.len, .after = after.len, .length = 0 } else content[i];
        const removed = m.before - old_y;
        const added = m.after - new_y;
        const paired = @min(removed, added);
        const shift = @max(removed, added) - paired;
        const under_header = i == 1 and first_offset == 0 and shift <= limit and
            (paired < shift or !std.mem.eql(u64, before[old_y..][0..shift], after[new_y..][0..shift]));
        // A leading scroll remains in the displacement until the viewport
        // ends. A later insertion can add to that displacement.
        const leading = viewport and (i == 0 and shift <= limit or under_header) and
            scrollPersists(content[0..footer], i);
        if (removed == added) {
            append(bands, &len, .{
                .before = old_y,
                .after = new_y,
                .removed = removed,
                .added = added,
                .mode = if (i != 0 and !end and (old_y != new_y or viewport) and removed <= replacement_limit) .replacement else .regular,
            });
        } else if (viewport and (leading or end or i == footer)) {
            var visible = paired;
            if (!leading and old_y < new_y and !hasVisibleStripe(before, old_background, limits, old_y, paired)) {
                // Some stationary footer rows share the body's backdrop.
                // They remain stationary even when the first anchor is lower.
                var edge = m.after;
                while (edge > new_y and before[edge - 1] == after[edge - 1]) edge -= 1;
                visible = @min(visible, edge - new_y);
            }
            append(bands, &len, .{
                .before = if (leading) m.before - paired else old_y,
                .after = if (leading) m.after - paired else new_y,
                .removed = visible,
                .added = visible,
            });
            if ((end or i == footer) and added > paired) {
                reveal(bands, &len, after[0..m.after], old_y + paired, new_y + paired, new_background);
            }
        } else {
            const first_band = len;
            const problem = Problem.init(before[old_y..m.before], after[new_y..m.after]);
            const edits = problem.distance(@min(max_edits, problem.a.len + problem.b.len), frontier);
            const gap = if (edits) |found| problem.matches(found, frontier, raw) orelse &.{} else &.{};
            for (gap) |row| {
                const a = m.before - removed + row.before;
                const b = m.after - added + row.after;
                append(bands, &len, .{ .before = old_y, .after = new_y, .removed = a - old_y, .added = b - new_y });
                old_y = a + 1;
                new_y = b + 1;
            }
            append(bands, &len, .{ .before = old_y, .after = new_y, .removed = m.before - old_y, .added = m.after - new_y });
            if (shift != 0) {
                const inserted = added > removed;
                markSpacing(bands[first_band..len], if (inserted) after else before, if (inserted) new_background else old_background, inserted);
            }
        }
        // Same-offset matches span any edits between their first and last row.
        append(bands, &len, .{ .before = m.before, .after = m.after, .removed = m.length, .added = m.length });
        old_y = m.before + m.length;
        new_y = m.after + m.length;
    }
    return bands[0..len];
}

/// Places a one-sided element at the best boundary among equivalent row matches.
pub fn refineElements(before: Keys, after: Keys, limits: Limits, bands: []Band) void {
    const images = limits.images orelse return;
    if (bands.len < 2) return;
    recoverGrowingEdits(limits, bands);
    refineMixedPaths(limits, bands);
    for (bands[0 .. bands.len - 1], bands[1..]) |*band, next| {
        if (band.mode != .regular or @min(band.removed, band.added) != 0) continue;
        const inserted = band.added != 0;
        const count = @max(band.removed, band.added);
        if (count <= 2 * limits.scroll or @min(next.removed, next.added) < count / 2) continue;
        if (next.before != band.before + band.removed or next.after != band.after + band.added) continue;
        const short = if (inserted) before else after;
        const long = if (inserted) after else before;
        const image = images[@intFromBool(inserted)];
        const original = if (inserted) band.after else band.before;
        const aligned = if (inserted) band.before else band.after;
        var distance: usize = 0;
        const max_distance = @min(aligned, original, count, max_panel_shift);
        while (distance < max_distance) : (distance += 1) {
            const key = short[aligned - distance - 1];
            const y = original - distance - 1;
            if (key != long[y] or key != long[y + count]) break;
        }
        const best = compactElement(image, original - distance, original, count, limits);
        band.before -= original - best;
        band.after -= original - best;
        band.mode = .element;
    }
}

// Growth fixes the net offset. A locally edited head of the moved list can
// be paired against the new row instead, because it lost its exact row hashes.
fn recoverGrowingEdits(limits: Limits, bands: []Band) void {
    const images = limits.images orelse return;
    const growth = images[1].height -| images[0].height;
    if (growth <= limits.scroll) return;
    for (bands[0 .. bands.len - 1], 0..) |*band, index| {
        const next = &bands[index + 1];
        const count = band.removed;
        if (count == 0 or count > growth or band.added != count + growth or band.mode != .regular) continue;
        if (next.before != band.before + count or next.after != band.after + band.added or
            next.removed != next.added or next.removed < growth) continue;
        if (!prefersGrowthOffset(images, limits, band.*, growth)) continue;
        next.* = .{ .before = band.before, .after = band.after + growth, .removed = next.removed + count, .added = next.added + count };
        band.removed = 0;
        band.added = growth;
    }
}

fn prefersGrowthOffset(images: [2]Image, limits: Limits, band: Band, growth: usize) bool {
    var positional: usize = 0;
    var shifted: usize = 0;
    const column_step = @max(1, limits.width / 96);
    const row_step = @max(1, band.removed / 64);
    var row: usize = 0;
    while (row < band.removed) : (row += row_step) {
        const old = images[0].row(band.before + row);
        const same = images[1].row(band.after + row);
        const moved = images[1].row(band.after + growth + row);
        var x = limits.left;
        while (x < limits.left + limits.width) : (x += column_step) {
            positional += @intFromBool(!std.meta.eql(old[x], same[x]));
            shifted += @intFromBool(!std.meta.eql(old[x], moved[x]));
        }
    }
    return positional >= 16 and 4 * shifted <= 3 * positional;
}

fn hasDisplacedContent(anchors: []const Match, before: Keys, after: Keys) bool {
    for (anchors) |anchor| {
        if (anchor.offset() == 0) continue;
        var left_source = false;
        var reached_destination = false;
        for (0..anchor.length) |offset| {
            const old = anchor.before + offset;
            const new = anchor.after + offset;
            if (before[old] != after[new]) continue;
            // A repeat left in place is equally good evidence for a local
            // edit. The two ends of a moved solid run can differ on
            // different rows when their ranges overlap.
            left_source = left_source or before[old] != after[old];
            reached_destination = reached_destination or before[new] != after[new];
            if (left_source and reached_destination) return true;
        }
    }
    return false;
}

// Equivalent repeated rows can match at several boundaries. Prefer the
// smallest enclosure that covers the changed content.
fn compactElement(image: Image, first: usize, last: usize, count: usize, limits: Limits) usize {
    if (first == last) return last;
    var best = last;
    var best_top = image.height;
    var best_height = count + 1;
    var top = first;
    var end = first;
    var bottom_ink = first;
    for (first..last + 1) |y| {
        const bottom = y + count;
        while (end < bottom) : (end += 1) {
            if (!flatPaint(image, end, end + 1, limits.left, limits.width)) bottom_ink = end + 1;
        }
        top = @max(y, top);
        while (top < bottom_ink and flatPaint(image, top, top + 1, limits.left, limits.width)) : (top += 1) {}
        if (bottom_ink <= top) continue;
        const height = bottom_ink - top;
        if (height < best_height or (height == best_height and top <= best_top)) {
            best = y;
            best_top = top;
            best_height = height;
        }
    }
    return best;
}

// An opposite one-sided gap can be the tail of a recoloured element
// that lost its row anchors. Only repack it when the following match
// supports the final displacement and the foreground silhouette agrees.
fn refineMixedPaths(limits: Limits, bands: []Band) void {
    if (bands.len < 3) return;
    for (0..bands.len - 2) |i| {
        const first = bands[i];
        const second = bands[i + 1];
        const next = bands[i + 2];
        if (first.mode != .regular or second.mode != .regular or @min(first.removed, first.added) < 4) continue;
        if (second.before != next.before -| second.removed or second.after != next.after -| second.added) continue;
        if (@min(next.removed, next.added) < 4) continue;
        const gap: Band = .{
            .before = first.before,
            .after = first.after,
            .removed = next.before - first.before,
            .added = next.after - first.after,
        };
        const inserted = gap.added > gap.removed;
        if (inserted) {
            if (first.removed <= first.added or second.removed != 0) continue;
        } else if (first.added <= first.removed or second.added != 0) continue;
        if (!shapeKeepsOffset(limits, gap)) continue;

        const paired = @min(gap.removed, gap.added);
        const removed = gap.removed - paired;
        const added = gap.added - paired;
        bands[i] = .{ .before = gap.before, .after = gap.after, .removed = removed, .added = added };
        bands[i + 1] = .{ .before = gap.before + removed, .after = gap.after + added, .removed = paired, .added = paired };
    }
}

// A recoloured element can lose all of its row hashes. Prefer the offset
// that preserves its foreground silhouette when the surrounding hashes
// already establish a shift.
fn shapeKeepsOffset(limits: Limits, gap: Band) bool {
    const images = limits.images orelse return false;
    if (@min(gap.before, gap.after) == 0) return false;
    const count = @min(gap.removed, gap.added);
    const shift = @max(gap.removed, gap.added) - count;
    if (shift <= limits.scroll or count < 32) return false;
    const inserted = gap.added > gap.removed;
    const short = images[@intFromBool(!inserted)];
    const long = images[@intFromBool(inserted)];
    const short_y = if (inserted) gap.before else gap.after;
    const long_y = if (inserted) gap.after else gap.before;
    const backdrop = short.row(short_y - 1)[limits.left..][0..limits.width];
    const opposite = long.row(long_y - 1)[limits.left..][0..limits.width];
    if (!std.mem.eql(u8, std.mem.sliceAsBytes(backdrop), std.mem.sliceAsBytes(opposite))) return false;

    const x_step = @max(1, limits.width / 64);
    const y_step = @max(1, count / 64);
    var positional: usize = 0;
    var displaced: usize = 0;
    var foreground: usize = 0;
    var y: usize = 0;
    while (y < count) : (y += y_step) {
        const old = short.row(short_y + y)[limits.left..][0..limits.width];
        const same = long.row(long_y + y)[limits.left..][0..limits.width];
        const moved = long.row(long_y + shift + y)[limits.left..][0..limits.width];
        var x: usize = 0;
        while (x < limits.width) : (x += x_step) {
            const ink = !std.meta.eql(old[x], backdrop[x]);
            const same_ink = !std.meta.eql(same[x], backdrop[x]);
            const moved_ink = !std.meta.eql(moved[x], backdrop[x]);
            foreground += @intFromBool(ink);
            positional += @intFromBool(ink != same_ink);
            displaced += @intFromBool(ink != moved_ink);
        }
    }
    return foreground >= 16 and positional >= 16 and displaced == 0;
}

fn positionalPaintBands(before: Keys, after: Keys, first: usize, limits: Limits, bands: []Band) ?[]Band {
    const images = limits.images orelse return null;
    const max_rows = @max(paint_cluster_rows, limits.replacement);
    const bounds: columns.Span = .{ .left = limits.left, .width = limits.width };
    const max_width = @min(images[0].width, images[1].width) / narrow_paint_width_divisor;
    var len: usize = 0;
    var start = first;
    var interrupted_ink = false;
    while (start < before.len) {
        var end = start + 1;
        var stable: usize = 0;
        while (end < before.len and stable < paint_anchor_rows) : (end += 1) {
            stable = if (before[end] == after[end]) stable + 1 else 0;
            if (end - stable - start >= max_rows) return null;
        }
        const bottom = end - stable;
        if (bottom == before.len) return null;
        const span = columns.spanRows(images[0], images[1], bounds, start, bottom);
        if (span.width == 0 or span.width > max_width) return null;
        const old_flat = flatPaint(images[0], start, bottom, span.left, span.width);
        const new_flat = flatPaint(images[1], start, bottom, span.left, span.width);
        // Two distant overpaints can overlap vertically. In that case the
        // bounding rectangle includes paint and untouched space between them.
        if (!old_flat and !new_flat and !flatChanges(images, span, start, bottom)) return null;
        interrupted_ink = interrupted_ink or !(old_flat and new_flat);
        append(bands, &len, .{ .before = start, .after = start, .removed = bottom - start, .added = bottom - start });
        start = end + (std.mem.indexOfDiff(u64, before[end..], after[end..]) orelse break);
    }
    return if (len > 1 and interrupted_ink) bands[0..len] else null;
}

fn flatChanges(images: [2]Image, span: columns.Span, top: usize, bottom: usize) bool {
    var colors: ?[2]values.Pixel = null;
    var old_flat = true;
    var new_flat = true;
    for (top..bottom) |y| {
        const before = images[0].row(y)[span.left..][0..span.width];
        const after = images[1].row(y)[span.left..][0..span.width];
        for (before, after) |old, new| {
            if (std.meta.eql(old, new)) continue;
            if (colors == null) colors = .{ old, new };
            old_flat = old_flat and std.meta.eql(old, colors.?[0]);
            new_flat = new_flat and std.meta.eql(new, colors.?[1]);
            if (!old_flat and !new_flat) return false;
        }
    }
    return colors != null;
}

fn shortDetour(next: Match, old_y: usize, new_y: usize, limit: usize) bool {
    const removed = next.before - old_y;
    const added = next.after - new_y;
    const displacement = @max(removed, added) - @min(removed, added);
    // A returned displacement can still be a real insertion and deletion.
    // Fold only shifts small enough to be alternate matches for one stroke.
    return displacement != 0 and (old_y != new_y or displacement <= @max(min_detour_rows, detour_scroll_multiplier * limit));
}

fn localEditCost(before: Keys, after: Keys, first: usize, limits: Limits) ?struct { cost: usize, end: usize, limit: usize } {
    if (first == 0) return null;
    const limit = if (limits.narrow_edit) @max(narrow_paint_rows, limits.replacement) else limits.replacement;
    var end = before.len;
    while (end > first and before[end - 1] == after[end - 1]) end -= 1;
    if (end == before.len or end - first > limit) return null;
    var replaced: usize = 0;
    for (before[first..end], after[first..end]) |old, new| replaced += @intFromBool(old != new);
    // Separated edits are weaker evidence for one overpaint. In particular,
    // a short insertion can move a distant line while leaving the rows in
    // between equal at their original positions.
    if (paint_density_denominator * replaced < paint_density_numerator * (end - first)) return null;
    if (!limits.narrow_edit) {
        const images = limits.images orelse return null;
        if (!flatPaint(images[0], first, end, limits.left, limits.width) and !flatPaint(images[1], first, end, limits.left, limits.width)) return null;
    }
    return .{ .cost = 2 * replaced, .end = end, .limit = limit };
}

fn flatPaint(image: Image, first: usize, end: usize, left: usize, width: usize) bool {
    const first_row = std.mem.sliceAsBytes(image.row(first)[left..][0..width]);
    const pixel_bytes = @sizeOf(values.Pixel);
    if (!std.mem.eql(u8, first_row[pixel_bytes..], first_row[0 .. first_row.len - pixel_bytes])) return false;
    for (first + 1..end) |y| {
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(image.row(y)[left..][0..width]), first_row)) return false;
    }
    return true;
}

fn footerStart(matches_: []const Match, before: Keys, after: Keys, old_background: ?u64, new_background: ?u64, limits: Limits) usize {
    const last = for (0..matches_.len) |i| {
        const index = matches_.len - 1 - i;
        if (matches_[index].offset() == 0) break index;
    } else return matches_.len;
    if (!stationaryFooter(before, after, matches_[last].before, old_background, new_background, limits.scroll)) return matches_.len;

    var first = last;
    var next = last;
    while (next > 0) {
        next -= 1;
        const anchor = matches_[next];
        if (anchor.offset() != 0) continue;
        const start = anchor.before + anchor.length;
        const end = matches_[first].before;
        if (end - start > limits.replacement) break;
        first = next;
    }
    // A return to offset zero can be a deletion in the body. Require
    // separate viewport chrome at the boundary before clipping any rows.
    const images = limits.images orelse return matches_.len;
    const start = matches_[first].before;
    if (first == 0 or start < before.len - before.len / footer_zone_divisor) return matches_.len;
    const image = images[0];
    // Chrome begins at a shared horizontal edge. Compare the paint on
    // either side of that edge instead of assuming a single backdrop.
    const shared_width = @min(image.width, images[1].width);
    var edge: usize = 0;
    for (image.row(start - 1)[0..shared_width], image.row(start)[0..shared_width], images[1].row(start - 1)[0..shared_width], images[1].row(start)[0..shared_width]) |above, below, new_above, new_below| {
        edge += @intFromBool(!std.meta.eql(above, below) and !std.meta.eql(new_above, new_below));
    }
    if (limits.width != 0 and columns.closesPanel(image, .{ .left = limits.left, .width = limits.width }, start)) return first;
    if (insetStripe(before, old_background, image, start)) return matches_.len;
    if (footer_edge_divisor * edge >= shared_width) return first;
    // Clipping can put paint from the moving pane immediately above the
    // fixed edge on one side. Compare the footer with the body's backdrop.
    const background_y = std.mem.indexOfScalar(u64, before, old_background orelse return matches_.len) orelse return matches_.len;
    var changed: usize = 0;
    for (image.row(start), image.row(background_y)) |chrome, body| {
        changed += @intFromBool(!std.meta.eql(chrome, body));
    }
    return if (changed >= image.width / footer_edge_divisor) first else matches_.len;
}

fn hasVisibleStripe(keys_: Keys, background_key: ?u64, limits: Limits, start: usize, count: usize) bool {
    const image = (limits.images orelse return false)[0];
    const background_row = background_key orelse return false;
    for (keys_[start..][0..count], start..) |key, y| {
        if (key != background_row) return insetStripe(keys_, background_row, image, y);
    }
    return false;
}

fn insetStripe(keys_: Keys, background_key: ?u64, image: Image, start: usize) bool {
    const background_y = std.mem.indexOfScalar(u64, keys_, background_key orelse return false) orelse return false;
    const body = image.row(background_y);
    const stripe = image.row(start);
    if (!std.meta.eql(stripe[0], body[0]) or !std.meta.eql(stripe[image.width - 1], body[image.width - 1])) return false;
    const end = @min(keys_.len, start + max_inset_stripe_rows + 1);
    for (keys_[start + 1 .. end]) |key| {
        if (key != keys_[start]) return key == background_key.?;
    }
    return false;
}

fn stationaryFooter(before: Keys, after: Keys, start: usize, old_background: ?u64, new_background: ?u64, limit: usize) bool {
    if (std.mem.eql(u64, before[start..], after[start..])) return true;
    // A button or label can change inside an otherwise fixed footer.
    // Require a stationary run of content beyond its last changed row.
    var matched: usize = 0;
    var y = before.len;
    while (y > start) {
        y -= 1;
        if (before[y] != after[y]) break;
        if (isContent(before[y], old_background, new_background)) matched += 1;
    }
    return matched > 2 * limit;
}

fn markSpacing(bands: []Band, keys_: Keys, background_key: ?u64, inserted: bool) void {
    const key = background_key orelse return;
    var content = false;
    for (bands) |band| {
        const paired = @min(band.removed, band.added);
        const size = if (inserted) band.added else band.removed;
        const y = if (inserted) band.after else band.before;
        if (size > paired and !std.mem.allEqual(u64, keys_[y + paired .. y + size], key)) {
            content = true;
            break;
        }
    }
    if (!content) return;
    for (bands) |*band| {
        const size = if (inserted) band.added else band.removed;
        const other = if (inserted) band.removed else band.added;
        const y = if (inserted) band.after else band.before;
        if (other == 0 and size != 0 and std.mem.allEqual(u64, keys_[y .. y + size], key)) band.mode = .spacing;
    }
}

fn scrollPersists(anchors: []const Match, first: usize) bool {
    if (first >= anchors.len) return false;
    const shift = anchors[first].offset();
    for (anchors[first + 1 ..]) |anchor| {
        const offset = anchor.offset();
        if (if (shift > 0) offset < shift else offset > shift) return false;
    }
    return true;
}

// Some panels contain long stretches of repeated paint. Their exact moving
// rows can account for fewer edits than the stationary background in Myers.
fn panelInsertion(before: Keys, after: Keys, first: usize, limits: Limits, bands: []Band) ?[]Band {
    const image = (limits.images orelse return null)[0];
    var last = before.len;
    while (last > first and before[last - 1] == after[last - 1]) last -= 1;
    if (last == before.len) return null;
    const end = @min(last, first + max_panel_shift + 1);
    var candidate = first + limits.scroll + 1;
    for (0..max_panel_candidates) |_| {
        if (candidate >= end) return null;
        const start = std.mem.indexOfScalarPos(u64, after[0..end], candidate, before[first]) orelse return null;
        candidate = start + 1;
        const shift = start - first;
        const available = after.len - start;
        const length = std.mem.indexOfDiff(u64, before[first..][0..available], after[start..]) orelse available;
        const edge = start + length;
        if (edge < last or length < 2 * shift or edge == after.len) continue;

        // The unobserved tail must be flat paint. A body deletion can
        // also restore offset zero, but can remove meaningful old rows.
        if (before[edge - shift - 1] != before[edge - shift] or
            !flatPaint(image, edge - shift, edge, limits.left, limits.width)) continue;
        var moved_rows: usize = 0;
        for (before[first..][0..length], before[start..edge]) |old, stationary| {
            moved_rows += @intFromBool(old != stationary);
            if (moved_rows >= 4) break;
        }
        if (moved_rows < 4) continue;
        bands[0] = .{ .before = 0, .after = 0, .removed = first, .added = first, .mode = .hash_match };
        bands[1] = .{ .before = first, .after = first, .removed = 0, .added = shift };
        bands[2] = .{ .before = first, .after = start, .removed = length, .added = length, .mode = .hash_match };
        bands[3] = .{ .before = edge, .after = edge, .removed = after.len - edge, .added = after.len - edge, .mode = .hash_match };
        return bands[0..4];
    }
    return null;
}

// A single insertion followed by an exact shifted tail needs no Myers
// frontier. Use the first distinct row as the candidate shift's anchor.
fn clippedInsertion(problem: Problem, limit: usize, bands: []Band) ?[]Band {
    const old = problem.a;
    const new = problem.b;
    const marker = for (old[1..], 1..) |key, y| {
        if (key != old[0]) break y;
    } else return null;
    const at = std.mem.indexOfScalarPos(u64, new, marker + 1, old[marker]) orelse return null;
    const shift = at - marker;
    const budget = @min(max_edits, old.len + problem.prefix);
    if (shift <= limit or shift > budget / 2 or !std.mem.eql(u64, old[0 .. old.len - shift], new[shift..])) return null;
    const prefix = problem.prefix;
    bands[0] = .{ .before = 0, .after = 0, .removed = prefix, .added = prefix, .mode = .hash_match };
    bands[1] = .{ .before = prefix, .after = prefix, .removed = 0, .added = shift };
    bands[2] = .{ .before = prefix, .after = prefix + shift, .removed = old.len - shift, .added = old.len - shift, .mode = .hash_match };
    return bands[0..3];
}

// A brief detour through repeated rows can change the alignment's offset
// more than once. Compare the covered rows together if the shift resumes.
fn replacementEnd(anchors: []const Match, old_y: usize, new_y: usize, limit: usize) ?usize {
    for (anchors, 0..) |anchor, i| {
        const removed = anchor.before - old_y;
        const added = anchor.after - new_y;
        if (@max(removed, added) > limit) break;
        if (removed == added) return i;
    }
    return null;
}

// Once a run fixes the insertion's displacement, rows below the old
// viewport edge cannot anchor its remaining visible tail. A repeat there
// would otherwise pull the alignment back down and turn clipping into removal.
fn visibleAnchors(content: []const Match, before: Keys, after: Keys, after_end: usize, limit: usize) usize {
    if (content.len < 2) return content.len;
    for (content[0 .. content.len - 1], content[1..], 1..) |m, next, kept| {
        if (m.after <= m.before) continue;
        const shift = m.after - m.before;
        if (shift <= limit or next.before < after_end - shift) continue;
        if (next.offset() == 0) {
            // A stationary tail can establish that a deletion cancelled
            // the shift before the edge. A repeat already explained by
            // the shifted alignment is not new evidence.
            var different: usize = 0;
            for (next.after..next.after + next.length) |y| {
                different += @intFromBool(before[y - shift] != after[y]);
                if (different > limit) break;
            }
            if (different > limit) continue;
        }
        return kept;
    }
    return content.len;
}

fn extend(content: []Match, count: *usize, m: Match) void {
    if (count.* > 0 and content[count.* - 1].offset() == m.offset()) {
        content[count.* - 1].length = m.before - content[count.* - 1].before + 1;
    } else {
        content[count.*] = m;
        count.* += 1;
    }
}

fn alignContent(before: Keys, after: Keys, old_background: ?u64, new_background: ?u64, explained: usize, frontier: []Diagonal, raw: []Match, filtered: []u64) ?[]const Match {
    const old_keys = selectContent(before, old_background, new_background, filtered[0..before.len]);
    const new_keys = selectContent(after, old_background, new_background, filtered[before.len..]);
    if (@min(old_keys.len, new_keys.len) <= explained) return null;

    const problem = Problem.init(old_keys, new_keys);
    const edits = problem.distance(@min(max_edits, @max(old_keys.len, new_keys.len)), frontier) orelse return null;
    if ((old_keys.len + new_keys.len - edits) / 2 <= explained) return null;
    const matches = problem.matches(edits, frontier, raw) orelse return null;
    restoreRows(before, old_background, new_background, raw[0..matches.len], .before);
    restoreRows(after, old_background, new_background, raw[0..matches.len], .after);
    return matches;
}

fn selectContent(input: Keys, old_background: ?u64, new_background: ?u64, output: []u64) Keys {
    var len: usize = 0;
    for (input) |key| {
        if (!isContent(key, old_background, new_background)) continue;
        output[len] = key;
        len += 1;
    }
    return output[0..len];
}

fn restoreRows(input: Keys, old_background: ?u64, new_background: ?u64, matches: []Match, comptime field: enum { before, after }) void {
    var selected: usize = 0;
    var next: usize = 0;
    for (input, 0..) |key, row| {
        if (next == matches.len) break;
        if (!isContent(key, old_background, new_background)) continue;
        if (@field(matches[next], @tagName(field)) == selected) {
            @field(matches[next], @tagName(field)) = row;
            next += 1;
        }
        selected += 1;
    }
}

fn isContent(key: u64, old_background: ?u64, new_background: ?u64) bool {
    return key != old_background and key != new_background;
}

fn reveal(bands: []Band, len: *usize, after: Keys, before_end: usize, start: usize, key: ?u64) void {
    append(bands, len, .{
        .before = before_end,
        .after = start,
        .removed = 0,
        .added = after.len - start,
        .mode = .{ .revealed = if (key) |background_key| std.mem.indexOfScalar(u64, after[0..start], background_key) orelse start -| 1 else start -| 1 },
    });
}

fn append(bands: []Band, len: *usize, band: Band) void {
    if (band.removed == 0 and band.added == 0) return;
    // Each nonempty band consumes at least one distinct row across the two inputs.
    bands[len.*] = band;
    len.* += 1;
}

fn background(counts: *std.AutoHashMapUnmanaged(u64, usize), rows: Keys) ?u64 {
    var key: ?u64 = null;
    var best: usize = 1;
    for (rows) |row| {
        const entry = counts.getOrPutAssumeCapacity(row);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        if (entry.value_ptr.* > best) {
            best = entry.value_ptr.*;
            key = row;
        }
    }
    return key;
}

fn search(comptime track_middle: bool, a: Keys, b: Keys, budget: usize, half: usize, frontier: []Diagonal) ?SearchResult {
    const center = frontier.len / 2;
    frontier[center] = .{ .x = 0 };
    for (1..budget + 1) |d| {
        const start = center - d;
        const end = center + d;
        var index = start;
        while (index <= end) : (index += 2) {
            const k = @as(isize, @intCast(index)) - @as(isize, @intCast(center));
            const insert_x = if (index < end) frontier[index + 1].x else missing;
            const remove_x = if (index > start) frontier[index - 1].x else missing;
            const insert_y = @as(i64, insert_x) - k;
            const remove_y = @as(i64, remove_x) + 1 - k;
            const can_insert = insert_x != missing and insert_y > 0 and insert_y <= b.len;
            const can_remove = remove_x < a.len and remove_y >= 0 and remove_y <= b.len;
            const insertion = can_insert and (!can_remove or remove_x < insert_x);
            if (!insertion and !can_remove) {
                frontier[index].x = missing;
                continue;
            }
            var x: usize = if (insertion) insert_x else @as(usize, remove_x) + 1;
            var y: usize = @intCast(if (insertion) insert_y else remove_y);
            while (x < a.len and y < b.len and a[x] == b[y]) {
                x += 1;
                y += 1;
            }
            // Only path recovery needs to remember an ancestor.
            const middle: Coordinate = if (!track_middle or d < half) .{} else if (d == half)
                .{ .x = @intCast(x), .y = @intCast(y) }
            else
                frontier[if (insertion) index + 1 else index - 1].middle;
            if (x == a.len and y == b.len) return .{ .edits = d, .middle = middle };
            frontier[index].x = @intCast(x);
            if (track_middle and d >= half) frontier[index].middle = middle;
        }
    }
    return null;
}

test "a gap can replace every row without losing surrounding anchors" {
    const before = [_]u64{ 1, 2, 10, 3, 4, 5, 6, 7, 8 };
    const replacements = [_][]const u64{ &.{ 20, 21, 22, 11 }, &.{ 20, 21, 22 }, &.{11} };
    var after: [before.len + 3]u64 = undefined;
    var bands: [2 * after.len + 1]Band = undefined;
    var filtered: [2 * after.len]u64 = undefined;
    for (replacements) |new_rows| {
        const size = before.len + new_rows.len - 1;
        @memcpy(after[0..2], before[0..2]);
        @memcpy(after[2..][0..new_rows.len], new_rows);
        @memcpy(after[2 + new_rows.len .. size], before[3..]);
        const result = try matchBands(std.testing.allocator, &before, after[0..size], .{ .scroll = 2, .replacement = 48 }, &bands, &filtered);
        if (new_rows.len == 1) {
            try std.testing.expect(result == null); // Equal-height positional replacement.
            continue;
        }
        const actual = result orelse return error.ExpectedAlignment;
        const expected = [_]Band{
            .{ .before = 0, .after = 0, .removed = 2, .added = 2 },
            .{ .before = 2, .after = 2, .removed = 1, .added = new_rows.len },
            .{ .before = 3, .after = 2 + new_rows.len, .removed = 6, .added = 6 },
        };
        try std.testing.expectEqualDeep(@as([]const Band, &expected), @as([]const Band, actual));
    }
}

test "linear frontier recovers shortest matches through repeated rows" {
    const rows = 5;
    var frontier: [2 * rows + 3]Diagonal = undefined;
    for (0..1 << rows) |old_bits| {
        for (0..1 << rows) |new_bits| {
            var before: [rows]u64 = undefined;
            var after: [rows]u64 = undefined;
            for (0..rows) |i| {
                before[i] = (old_bits >> @intCast(i)) & 1;
                after[i] = (new_bits >> @intCast(i)) & 1;
            }
            var lcs: [rows + 1][rows + 1]usize = @splat(@splat(0));
            for (before, 1..) |left, x| {
                for (after, 1..) |right, y| {
                    lcs[x][y] = if (left == right) lcs[x - 1][y - 1] + 1 else @max(lcs[x - 1][y], lcs[x][y - 1]);
                }
            }
            const edits = 2 * (rows - lcs[rows][rows]);
            const problem = Problem.init(&before, &after);
            try std.testing.expectEqual(if (edits <= rows) @as(?usize, edits) else null, problem.distance(rows, &frontier));
            if (edits > rows) continue;
            var output: [rows]Match = undefined;
            const matches = problem.matches(edits, &frontier, &output) orelse return error.NoMatches;
            try std.testing.expectEqual(lcs[rows][rows], matches.len);
            for (matches, 0..) |match, i| {
                try std.testing.expectEqual(before[match.before], after[match.after]);
                if (i > 0) {
                    try std.testing.expect(matches[i - 1].before < match.before);
                    try std.testing.expect(matches[i - 1].after < match.after);
                }
            }
        }
    }
}

test "a two-row alias does not hide a thirty-row scroll through periodic content" {
    const height = 140;
    const period = 28;
    const scroll = 30;
    var page: [height + scroll]u64 = @splat(0);
    for (0..page.len) |y| {
        if (y % period == 0) page[y] = 1;
    }
    for ([_]usize{ 46, 67, 89, 98, 110 }, 2..) |y, marker| page[y] = marker;
    const before = page[0..height];
    const after = page[scroll..];
    var storage: [2 * height + 1]Band = undefined;
    var filtered: [2 * height]u64 = undefined;
    const bands = (try matchBands(std.testing.allocator, before, after, .{ .scroll = 2, .replacement = 48 }, &storage, &filtered)) orelse return error.NoAlignment;
    for (bands) |band| {
        if (band.before == 46 and band.after == 16 and @min(band.removed, band.added) > 0) break;
    } else return error.AnchorMisaligned;
    const revealed = bands[bands.len - 1];
    try std.testing.expectEqual(@as(usize, 0), revealed.removed);
    try std.testing.expectEqual(@as(usize, height), revealed.after + revealed.added);
    try std.testing.expect(revealed.after <= height - scroll);
}

test "row hashes use the validated stride on one-pixel and final cropped rows" {
    const one = [_]values.Pixel{.{ 21, 22, 23, 255 }};
    var key: [1]u64 = undefined;
    keys(.{ .width = 1, .height = 1, .pixels = &one }, 0, 1, &key);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&one)), key[0]);
    var data: [10]values.Pixel = undefined;
    for (&data, 0..) |*pixel, i| pixel.* = .{ @intCast(i), 0, 0, 255 };
    var hashes: [2]u64 = undefined;
    keys(.{ .width = 5, .height = 2, .pixels = &data }, 2, 3, &hashes);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(data[7..])), hashes[1]);
    try std.testing.expect(hashes[0] != hashes[1]);
}

test {
    std.testing.refAllDecls(@This());
}
