//! Height calculator: how many levels does a tree of order M need for n keys?
//!
//! Height here means the number of nodes on a path from the root to a leaf,
//! which is the number of page reads for one lookup. An empty tree has
//! height 0, a single node has height 1.
//!
//! The two formulas are textbook results (Knuth, The Art of Computer
//! Programming vol. 3, section 6.2.4); chapter 03 proves the upper bound.
const std = @import("std");

/// Fewest levels that can hold `n` keys when every node is completely full.
/// A full tree of order m and height h holds m^h - 1 keys, so this is the
/// smallest h with m^h - 1 >= n. For m = 2 it is the height of a perfectly
/// balanced binary search tree.
pub fn minHeight(n: u64, m: u64) u32 {
    std.debug.assert(m >= 2);
    var h: u32 = 0;
    var capacity_plus_one: u128 = 1; // m^h; u128 so that 2^64 does not overflow
    while (capacity_plus_one - 1 < n) {
        capacity_plus_one *= m;
        h += 1;
    }
    return h;
}

/// Most levels a B-tree of order m can need for `n` keys: every node as
/// empty as the rules allow. The root may hold a single key (2 children);
/// every other node has at least ceil(m/2) children. Such a tree of height
/// h holds 2 * ceil(m/2)^(h-1) - 1 keys, so this is the largest h for which
/// that number is <= n.
pub fn maxHeight(n: u64, m: u64) u32 {
    std.debug.assert(m >= 3); // for m = 2 the minimum fan-out is 1: no bound
    if (n == 0) return 0;
    const min_children: u128 = (m + 1) / 2; // ceil(m/2)
    var h: u32 = 1;
    var power: u128 = 1; // min_children^(h-1)
    // Can a tree one level taller still be built from n keys?
    while (2 * power * min_children - 1 <= n) {
        power *= min_children;
        h += 1;
    }
    return h;
}

/// Largest order M whose node fits in one page, for fixed-size keys, values
/// and child pointers: (M-1) entries and M pointers, nothing else. Real page
/// formats also spend bytes on a header and per-entry slots (chapter 10).
pub fn orderForPage(page_bytes: u64, entry_bytes: u64, pointer_bytes: u64) u64 {
    // (M-1) * entry + M * pointer <= page   =>   M <= (page + entry) / (entry + pointer)
    return (page_bytes + entry_bytes) / (entry_bytes + pointer_bytes);
}

const testing = std.testing;

test "minHeight" {
    try testing.expectEqual(0, minHeight(0, 4));
    try testing.expectEqual(1, minHeight(1, 4));
    try testing.expectEqual(1, minHeight(3, 4));
    try testing.expectEqual(2, minHeight(4, 4));
    try testing.expectEqual(2, minHeight(15, 4));
    try testing.expectEqual(3, minHeight(16, 4));
    try testing.expectEqual(10, minHeight(1000, 2)); // 2^10 - 1 = 1023
    try testing.expectEqual(20, minHeight(1_000_000, 2));
    try testing.expectEqual(3, minHeight(1_000_000, 171));
    try testing.expectEqual(64, minHeight(std.math.maxInt(u64), 2));
}

test "maxHeight" {
    try testing.expectEqual(0, maxHeight(0, 4));
    try testing.expectEqual(1, maxHeight(1, 4));
    try testing.expectEqual(1, maxHeight(2, 4));
    try testing.expectEqual(2, maxHeight(3, 4)); // root with 1 key, two leaves with 1 key
    try testing.expectEqual(2, maxHeight(6, 4));
    try testing.expectEqual(3, maxHeight(7, 4)); // 2 * 2^2 - 1
    try testing.expectEqual(3, maxHeight(1_000_000, 171)); // height 4 needs 2 * 86^3 - 1 = 1272111 keys
    try testing.expectEqual(4, maxHeight(1_272_111, 171));
    _ = maxHeight(std.math.maxInt(u64), 3); // must not overflow
}

test "minHeight never exceeds maxHeight" {
    for (0..2000) |n| {
        for ([_]u64{ 3, 4, 5, 8, 171 }) |m| {
            try testing.expect(minHeight(n, m) <= maxHeight(n, m));
        }
    }
}

test "orderForPage" {
    // 16-byte entries, 8-byte pointers, 4096-byte page:
    // 170 entries (2720 bytes) + 171 pointers (1368 bytes) = 4088 <= 4096.
    try testing.expectEqual(171, orderForPage(4096, 16, 8));
    try testing.expectEqual(4, orderForPage(80, 16, 8)); // 3 entries + 4 pointers = 80 bytes
    try testing.expectEqual(3, orderForPage(79, 16, 8));
}
