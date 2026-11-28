//! Bounded linear-space Myers search over row hashes.

const std = @import("std");
const band = @import("band.zig");

const Coordinate = struct { x: u32 = 0, y: u32 = 0 };

/// One diagonal of the linear-space edit frontier.
pub const Diagonal = struct { x: u32 = missing, middle: Coordinate = .{} };

const SearchResult = struct { edits: usize, middle: Coordinate };

/// A pair of key sequences with their common prefix removed.
pub const Problem = struct {
    a: band.Keys,
    b: band.Keys,
    prefix: usize,

    /// Removes the common prefix before starting alignment.
    pub fn init(before: band.Keys, after: band.Keys) Problem {
        var prefix: usize = 0;
        while (prefix < @min(before.len, after.len) and before[prefix] == after[prefix]) : (prefix += 1) {}
        return .{ .a = before[prefix..], .b = after[prefix..], .prefix = prefix };
    }

    /// Returns the minimum bounded edit distance.
    pub fn distance(self: Problem, budget: usize, frontier: []Diagonal) ?usize {
        const delta = @max(self.a.len, self.b.len) - @min(self.a.len, self.b.len);
        if (@min(self.a.len, self.b.len) == 0) return delta;
        if (delta != 0 and self.oneDirection(null, 0, 0)) return delta;
        return (search(false, self.a, self.b, budget, 0, frontier) orelse return null).edits;
    }

    /// Writes the exact row matches for a known edit distance.
    pub fn matches(self: Problem, edits: usize, frontier: []Diagonal, out: []band.Match) ?[]const band.Match {
        const len = self.prefix + (self.a.len + self.b.len - edits) / 2;
        if (!self.recover(edits, frontier, out[0..len], 0, 0)) return null;
        return out[0..len];
    }

    fn recover(self: Problem, edits: usize, frontier: []Diagonal, out: []band.Match, old_y: usize, new_y: usize) bool {
        for (out[0..self.prefix], 0..) |*m, row| m.* = .{ .before = old_y + row, .after = new_y + row };
        const tail = out[self.prefix..];
        if (tail.len == 0) return true;
        const a = old_y + self.prefix;
        const b = new_y + self.prefix;
        const delta = @max(self.a.len, self.b.len) - @min(self.a.len, self.b.len);
        if (edits == delta) return self.oneDirection(tail, a, b);

        // Carry the chosen path's middle coordinate on each diagonal. Split at
        // that coordinate, then reuse the frontier. Each half has at most
        // ceil(edits / 2) edits, and one edit always takes the base case.
        std.debug.assert(edits <= max_edits);
        const half = edits / 2;
        const result = search(true, self.a, self.b, edits, half, frontier) orelse return false;
        const x: usize = result.middle.x;
        const y: usize = result.middle.y;
        // Each edit advances one coordinate, and each equal row advances both.
        const first_len = (x + y - half) / 2;
        return Problem.init(self.a[0..x], self.b[0..y]).recover(half, frontier, tail[0..first_len], a, b) and
            Problem.init(self.a[x..], self.b[y..]).recover(edits - half, frontier, tail[first_len..], a + x, b + y);
    }

    fn oneDirection(self: Problem, out: ?[]band.Match, old_y: usize, new_y: usize) bool {
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

const missing: u32 = std.math.maxInt(u32);

/// The most row insertions plus deletions the alignment searches for. Myers'
/// search costs O((rows + max_edits) * max_edits) time, so this bounds a tall
/// unrelated pair; past it, rows are compared by position.
const max_edits = 8192;

// The initial call and at most 13 splits fit in 14 recovery frames.
const max_recovery_frames = 14;
comptime {
    std.debug.assert(max_edits <= 1 << (max_recovery_frames - 1));
}

/// Caps the edits a caller's rows could need at `max_edits`.
pub fn editBudget(rows: usize) usize {
    return @min(max_edits, rows);
}

/// Returns the frontier length a search of `edits` edits uses.
pub fn frontierLen(edits: usize) usize {
    return 2 * edits + 3;
}

fn search(comptime track_middle: bool, a: band.Keys, b: band.Keys, budget: usize, half: usize, frontier: []Diagonal) ?SearchResult {
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

test "linear frontier recovers shortest matches through repeated rows" {
    const rows = 5;
    var frontier: [frontierLen(rows)]Diagonal = undefined;
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
            var output: [rows]band.Match = undefined;
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

test {
    std.testing.refAllDecls(@This());
}
