//! Canonical, low-bit-first Huffman codes for deflate blocks.
const std = @import("std");

/// A reversed canonical code ready to write to a deflate bit stream.
pub const Code = struct { bits: u32 = 0, len: u5 = 0 };

const Node = struct { weight: u32, parent: u16 = 0, symbol: u16 = 0 };

/// Builds a complete canonical tree, limiting lengths to the deflate bound.
pub fn assign(comptime n: usize, weights: *const [n]u16, output: *[n]Code, limit: u5) void {
    std.debug.assert(limit <= 15 and n <= @as(usize, 1) << limit);
    var nodes: [2 * n - 1]Node = undefined;
    var leaves: usize = 0;
    output.* = @splat(.{});
    for (weights, 0..) |weight, symbol| {
        if (weight == 0) continue;
        nodes[leaves] = .{ .weight = weight, .symbol = @intCast(symbol) };
        leaves += 1;
    }
    if (leaves == 0) {
        nodes[0] = .{ .weight = 1, .symbol = 0 };
        leaves = 1;
    }
    if (leaves == 1) {
        nodes[1] = .{ .weight = 1, .symbol = if (nodes[0].symbol == 0) 1 else 0 };
        leaves += 1;
    }
    std.mem.sortUnstable(Node, nodes[0..leaves], {}, less);
    var leaf: usize = 0;
    var branch = leaves;
    var end = leaves;
    while (end < 2 * leaves - 1) : (end += 1) {
        const left = take(nodes[0..end], leaves, &leaf, &branch);
        const right = take(nodes[0..end], leaves, &leaf, &branch);
        nodes[left].parent = @intCast(end);
        nodes[right].parent = @intCast(end);
        nodes[end] = .{ .weight = nodes[left].weight + nodes[right].weight };
    }

    var depths: [2 * n - 1]u16 = undefined;
    depths[end - 1] = 0;
    var population: [16]u16 = @splat(0);
    var overflow = false;
    var cursor = end - 1;
    while (cursor != 0) {
        cursor -= 1;
        const depth = depths[nodes[cursor].parent] + 1;
        depths[cursor] = depth;
        if (cursor >= leaves) continue;
        overflow = overflow or depth > limit;
        const capped = @min(depth, limit);
        output[nodes[cursor].symbol].len = @intCast(capped);
        population[capped] += 1;
    }

    if (overflow) limitLengths(nodes[0..leaves], &population, output, limit);

    var next: [16]u16 = @splat(0);
    for (1..16) |depth| next[depth] = (next[depth - 1] + population[depth - 1]) << 1;
    for (output) |*code| {
        if (code.len == 0) continue;
        const bits = &next[code.len];
        code.bits = @bitReverse(bits.*) >> @as(u4, @intCast(16 - code.len));
        bits.* += 1;
    }
}

// Capping the leaves can overfill the code space. Split a shorter code
// and remove one code at the limit, freeing one slot while keeping the
// same number of leaves. The shortest lengths go to the largest weights.
noinline fn limitLengths(leaves: []const Node, population: *[16]u16, output: []Code, limit: u5) void {
    var slots: usize = 0;
    for (1..@as(usize, limit) + 1) |bits| {
        slots += @as(usize, population[bits]) << @intCast(limit - bits);
    }
    const capacity = @as(usize, 1) << limit;
    while (slots > capacity) : (slots -= 1) {
        var bits = limit - 1;
        while (population[bits] == 0) : (bits -= 1) {}
        population[bits] -= 1;
        population[bits + 1] += 2;
        population[limit] -= 1;
    }
    var bits = limit;
    var assigned: usize = 0;
    while (bits > 0) : (bits -= 1) {
        for (0..population[bits]) |_| {
            output[leaves[assigned].symbol].len = bits;
            assigned += 1;
        }
    }
}

fn take(nodes: []const Node, leaves: usize, leaf: *usize, branch: *usize) usize {
    const index = if (branch.* == nodes.len or (leaf.* < leaves and nodes[leaf.*].weight <= nodes[branch.*].weight)) leaf else branch;
    defer index.* += 1;
    return index.*;
}

fn less(_: void, a: Node, b: Node) bool {
    return a.weight < b.weight or (a.weight == b.weight and a.symbol < b.symbol);
}

test "skewed weights get a complete tree within the deflate limit" {
    var weights: [19]u16 = undefined;
    weights[0] = 1;
    weights[1] = 1;
    for (2..weights.len) |i| weights[i] = weights[i - 1] + weights[i - 2];

    for ([_]u5{ 7, 15 }) |limit| {
        var codes: [weights.len]Code = undefined;
        assign(weights.len, &weights, &codes, limit);
        var slots: usize = 0;
        for (codes) |code| {
            try std.testing.expect(code.len > 0 and code.len <= limit);
            slots += @as(usize, 1) << @intCast(limit - code.len);
        }
        try std.testing.expectEqual(@as(usize, 1) << limit, slots);
    }
}

test {
    std.testing.refAllDecls(@This());
}
