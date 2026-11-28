//! Detects insertions followed by exact shifted rows and viewport clipping.

const std = @import("std");
const band = @import("band.zig");
const search = @import("search.zig");
const columns = @import("../columns.zig");

const min_panel_evidence = 4;

/// Maximum row displacement examined for a clipped or compact panel.
pub const max_panel_shift = 512;

const max_panel_candidates = 8;

/// Matches a compact insertion when the rest of the column shifts exactly.
pub fn compactInsertion(before: band.Keys, after: band.Keys, limit: usize, bands: []band.Band) ?[]band.Band {
    if (before.len != after.len) return null;
    const problem = search.Problem.init(before, after);
    if (problem.a.len < 2) return null;
    const aligned = clippedInsertion(problem, limit, bands) orelse return null;
    const gap = aligned[1];
    if (std.mem.allEqual(u64, after[gap.after .. gap.after + gap.added], after[after.len - 1])) return null;
    return aligned;
}

/// Detects a shifted list whose tail is clipped by a stationary panel.
// Some panels contain long stretches of repeated paint. Their exact moving
// rows can account for fewer edits than the stationary background in Myers.
pub fn panelInsertion(before: band.Keys, after: band.Keys, first: usize, limits: band.Limits, bands: []band.Band) ?[]band.Band {
    const sample = limits.sample orelse return null;
    const image = sample.pair.before;
    const last = band.changedEnd(before, after, first, before.len);
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
        if (edge < last or length < shift or edge == after.len) continue;

        // A fixed closing rule explains displaced content falling behind
        // the frame. Without that rule, require the lost tail to be paint.
        const inset: columns.Span = sample.columns;
        const closed_panel = edge == last and columns.closesRoundedPanel(image, inset, edge, shift);
        if (!closed_panel) {
            if (length < 2 * shift or before[edge - shift - 1] != before[edge - shift] or
                !columns.blankBand(image, edge - shift, shift, sample.columns)) continue;
        }
        var moved_rows: usize = 0;
        for (before[first..][0..length], before[start..edge]) |old, stationary| {
            moved_rows += @intFromBool(old != stationary);
            if (moved_rows >= min_panel_evidence) break;
        }
        if (moved_rows < min_panel_evidence) continue;
        bands[0] = .{ .before = 0, .after = 0, .removed = first, .added = first, .mode = .hash_match };
        bands[1] = .{ .before = first, .after = first, .removed = 0, .added = shift, .mode = if (closed_panel) .element else .regular };
        bands[2] = .{ .before = first, .after = start, .removed = length, .added = length, .mode = .hash_match };
        bands[3] = .{ .before = edge, .after = edge, .removed = after.len - edge, .added = after.len - edge, .mode = .hash_match };
        return bands[0..4];
    }
    return null;
}

/// Aligns an inserted band followed by a byte-exact shifted tail.
// A single insertion followed by an exact shifted tail needs no Myers
// frontier. Use the first distinct row as the candidate shift's anchor.
pub fn clippedInsertion(problem: search.Problem, limit: usize, bands: []band.Band) ?[]band.Band {
    const old = problem.a;
    const new = problem.b;
    const marker = for (old[1..], 1..) |key, y| {
        if (key != old[0]) break y;
    } else return null;
    const at = std.mem.indexOfScalarPos(u64, new, marker + 1, old[marker]) orelse return null;
    const shift = at - marker;
    const budget = search.editBudget(old.len + problem.prefix);
    if (shift <= limit or shift > budget / 2 or !std.mem.eql(u64, old[0 .. old.len - shift], new[shift..])) return null;
    const prefix = problem.prefix;
    bands[0] = .{ .before = 0, .after = 0, .removed = prefix, .added = prefix, .mode = .hash_match };
    bands[1] = .{ .before = prefix, .after = prefix, .removed = 0, .added = shift };
    bands[2] = .{ .before = prefix, .after = prefix + shift, .removed = old.len - shift, .added = old.len - shift, .mode = .hash_match };
    return bands[0..3];
}

test {
    std.testing.refAllDecls(@This());
}
