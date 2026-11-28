//! Extracts and verifies the foreground anchors of an alignment.

const std = @import("std");
const band = @import("band.zig");
const search = @import("search.zig");

/// Checks whether at least one anchor contains distinct moved content.
pub fn hasDisplacedContent(anchors: []const band.Match, before: band.Keys, after: band.Keys) bool {
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

/// Returns how many anchors remain visible after viewport clipping.
// Once a run fixes the insertion's displacement, rows below the old
// viewport edge cannot anchor its remaining visible tail. A repeat there
// would otherwise pull the alignment back down and turn clipping into removal.
pub fn visibleAnchors(content: []const band.Match, before: band.Keys, after: band.Keys, after_end: usize, limit: usize) usize {
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

/// Appends a matching row, extending the preceding run when contiguous.
pub fn extend(content: []band.Match, count: *usize, m: band.Match) void {
    if (count.* > 0 and content[count.* - 1].offset() == m.offset()) {
        content[count.* - 1].length = m.before - content[count.* - 1].before + 1;
    } else {
        content[count.*] = m;
        count.* += 1;
    }
}

/// Aligns the foreground keys and restores their original row indices.
pub fn alignContent(before: band.Keys, after: band.Keys, old_background: ?u64, new_background: ?u64, explained: usize, frontier: []search.Diagonal, raw: []band.Match, filtered: []u64) ?[]const band.Match {
    const old_keys = selectContent(before, old_background, new_background, filtered[0..before.len]);
    const new_keys = selectContent(after, old_background, new_background, filtered[before.len..]);
    if (@min(old_keys.len, new_keys.len) <= explained) return null;

    const problem = search.Problem.init(old_keys, new_keys);
    const edits = problem.distance(search.editBudget(@max(old_keys.len, new_keys.len)), frontier) orelse return null;
    if ((old_keys.len + new_keys.len - edits) / 2 <= explained) return null;
    const matches = problem.matches(edits, frontier, raw) orelse return null;
    restoreRows(before, old_background, new_background, raw[0..matches.len], .before);
    restoreRows(after, old_background, new_background, raw[0..matches.len], .after);
    return matches;
}

/// Reports whether a row key differs from both images’ background keys.
pub fn isContent(key: u64, old_background: ?u64, new_background: ?u64) bool {
    return key != old_background and key != new_background;
}

/// Finds the most frequent row key in the supplied image.
pub fn background(counts: *std.AutoHashMapUnmanaged(u64, usize), rows: band.Keys) ?u64 {
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

fn selectContent(input: band.Keys, old_background: ?u64, new_background: ?u64, output: []u64) band.Keys {
    var len: usize = 0;
    for (input) |key| {
        if (!isContent(key, old_background, new_background)) continue;
        output[len] = key;
        len += 1;
    }
    return output[0..len];
}

fn restoreRows(input: band.Keys, old_background: ?u64, new_background: ?u64, matches: []band.Match, comptime field: enum { before, after }) void {
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

test {
    std.testing.refAllDecls(@This());
}
