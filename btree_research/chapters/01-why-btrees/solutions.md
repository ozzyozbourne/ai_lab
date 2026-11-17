# Chapter 01: solutions

Back to the [chapter](README.md).

## 1. Best and worst BST for the canonical keys

Ascending order (1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30) gives a chain: 1 is the
root, every node has only a right child, height 12.

The smallest possible height for 12 keys is 4, because a binary tree of height 3 holds
at most 2^3 - 1 = 7 keys and one of height 4 holds up to 15 (`minHeight(12, 2)` is 4).
To reach it, always insert the middle key of a range before the keys on either side of
it. One such order:

```
10, 5, 17, 3, 6, 12, 25, 1, 7, 15, 20, 30
```

```
            10
        /        \
       5          17
     /   \      /    \
    3     6    12     25
   /       \     \   /  \
  1         7    15 20   30
```

The lesson: the same keys give height 4 or height 12 depending only on the order in
which they arrive. An index cannot ask its users to insert in a friendly order, so the
structure has to rebalance itself.

## 2. Height for a Postgres-like page

8152 usable bytes / 20 bytes per entry = 407 entries per page, so the order is M = 408
(407 keys, 408 children). This ignores that internal pages also need downlinks in
their entries; for a single integer key the research notes derive the same 20 bytes for
both, so the estimate holds.

| Keys | `minHeight(n, 408)` | `maxHeight(n, 408)` |
|---|---|---|
| 10^6 | 3 | 3 |
| 10^9 | 4 | 4 |
| 10^12 | 5 | 6 |

Check by hand: 408^2 = 166,464 is less than 10^6 and 408^3 is about 67.9 million, so
three full levels are needed and enough for a million keys. For the worst case every
node has ceil(408 / 2) = 204 children and the root has 2: a tree of height 4 then needs
at least 2 * 204^3 - 1, about 17 million keys, so a million keys cannot be 4 levels
deep.

The gap between best and worst case is at most one level here. Every node except the
root is at least half full, so the worst case can only add a level or two, never
multiply the height.

## 3. Page reads for a range query

Sorted array. Find the start with the binary search, then walk forward:

```zig
pub fn rangeTraced(self: *const SortedArrayMap, lo: u64, hi: u64, trace: *cost.Trace) []const Entry {
    const start = self.lowerBound(lo, trace);
    var end = start;
    while (end < self.len and self.entries[end].key < hi) : (end += 1) {
        trace.comparisons += 1;
    }
    // The walk reads every page from the one holding `start` to the one holding `end - 1`.
    // `Trace.seen` has only 64 slots, so count this run directly instead of calling touch().
    if (start < end) {
        const first_page = start / cost.entries_per_page;
        const last_page = (end - 1) / cost.entries_per_page;
        trace.page_reads += last_page - first_page; // first_page was already read by the search
    }
    return self.entries[start..end];
}
```

For 1,000 consecutive keys out of 100,000: at most 9 page reads to find the start, and
1,000 entries span 4 or 5 pages (1000 / 256 = 3.9, plus one if the range starts in the
middle of a page), the first of which the search has already read. About 13 page reads
in total. This sketch is not part of the tested code.

BST. An in-order walk visits every node in the range, plus the nodes on the path to the
first one. With one page per node that is at least 1,000 page reads. In `rangeNode`,
add one page read per node visited (every call with a non-null node).

The sorted array wins by two orders of magnitude, because neighbouring keys are stored
next to each other. This is the reason chapter 07 moves all values into the leaves and
chains the leaves together: it gives a tree the range behaviour of an array.

## 4. The best one-level structure

Worst-case work for an insert that splits a chunk: about B entry moves in the chunk
plus n / B slot moves in the directory. The sum B + n / B is smallest when the two
terms are equal, B = sqrt(n).

For n = 10^9: B is about 31,623 entries per chunk, the directory has about 31,623
slots, and the worst case is about 63,000 moves. Two problems remain. A chunk of
31,623 entries of 16 bytes is about 124 pages, so "one chunk" is no longer one page
read. And the cost still grows with n: a hundred times more keys means ten times more
work per insert.

A tree of order 171 over the same keys has height 5 in both the best and the worst
case (section 5 of the program output). An insert shifts at most 170 entries inside one leaf
page. If that leaf splits, a separator is inserted into the parent, which shifts at most
170 entries there, and so on up: at most about 170 moves per level, 850 in total, and
each level is one page. A hundred times more keys adds one level.

Generalising the trick "put a directory on the directory" k times gives chunk size
n^(1/k); choosing the chunk size as a constant (one page) and letting k grow instead is
exactly what a B-tree does.

## 5. Binary search inside the wide node

Prediction: the page-read columns do not change at all, because the search visits the
same nodes in the same order; only the work inside each node changes. The comparison
columns drop sharply. A node with 170 separators needs about log2(171), roughly 8,
comparisons instead of an average of about 85, so with 3 levels the average should fall
from 160.45 to somewhere near 3 * 8 = 24, close to the 17.68 of the plain binary search
(these two figures are estimates, not program output).

The change, in `wide.zig`: an interior node's separators are not contiguous in the
slice (child `i` sits between separator `i - 1` and separator `i`), so compute the index
of separator `j` directly instead of walking:

```zig
// index of separator j (0 <= j < children - 1) in a node covering sorted[lo..hi]
fn separatorIndex(lo: usize, base: usize, extra: usize, j: usize) usize {
    // children 0..j come first: j + 1 children, of which min(j + 1, extra) have one extra key,
    // plus the j separators before this one.
    return lo + (j + 1) * base + @min(j + 1, extra) + j;
}
```

and binary search over `j` for the first separator whose key is not smaller than the
target. The existing test `finds every key and nothing else, for many sizes and orders`
checks the result, including that the deepest lookup still equals `minHeight(n, m)`.

What this shows: a B-tree does not reduce the number of comparisons compared with one
big binary search. It does the same comparisons in a different order, arranged so that
consecutive comparisons look at bytes that are stored together.
