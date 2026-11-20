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

The gap between best and worst case is at most one level here, and that is typical for
wide nodes: every node except the root is at least half full, so the worst-case height
is about log base M/2 of n instead of log base M of n, a factor of
log(M) / log(M/2). For M = 408 that factor is 1.13. It is not a law for every M: for
M = 4 the factor is 2, and the program's own table (section 5) shows 20 levels in the
best case and 39 in the worst for 10^12 keys.

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
    // The binary search has already read some of them: its last probes land at or just
    // above `start`, often on the following pages too. A page counts once, so count only
    // the walked pages the search has not seen. `Trace.seen` has only 64 slots, so they
    // are counted without being stored; do not call touch() on this trace afterwards.
    if (start < end) {
        const searched = trace.seen[0..trace.page_reads];
        var page = start / cost.entries_per_page;
        const last_page = (end - 1) / cost.entries_per_page;
        while (page <= last_page) : (page += 1) {
            if (std.mem.indexOfScalar(u64, searched, page) == null) trace.page_reads += 1;
        }
    }
    return self.entries[start..end];
}
```

The tempting shortcut `trace.page_reads += last_page - first_page` ("the search has
already read the first page") counts too much: it gives 11 to 13 pages where the
distinct count is 9 to 13.

Measured with this function in a scratch copy of the Zig code (it is not part of the
chapter's tested code), over all 99,001 ranges of 1,000 consecutive keys out of 100,000,
and checked against a brute-force set of the pages touched: the search alone reads 8 or
9 pages, the 1,000 entries span 4 or 5 pages (1000 / 256 = 3.9, plus one if the range
starts in the middle of a page), and together they touch 9 to 13 different pages, 10.95
on average. 11 is the most common count.

BST. An in-order walk visits every node in the range, plus the nodes on the path to the
first one. With one page per node that is at least 1,000 page reads. In `range`, add
one page read for every node the inner loop looks at. Measured the same way on the tree
of the race (100,000 keys in random insert order), for 14,143 ranges of 1,000
consecutive keys: 1,008 to 1,037 nodes, 1,021 on average.

The sorted array wins by a factor of about 90, because neighbouring keys are stored
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
columns drop sharply. A full node with 170 keys needs about log2(171), roughly 8,
comparisons instead of an average of about 85. The three levels are not equally full,
though: for 100,000 keys the root of the stand-in tree has only 3 separators, the
middle level 146 per node, and the leaves 169 or 170 keys. That gives about 2 + 8 + 8
comparisons plus one equality check per node, so the average should fall from 160.45
to about 20, close to the 17.68 of the plain binary search.

Checked by making the change in a scratch copy of the Zig program: the race row becomes

```
wide nodes, M = 171             19.51       21     2.99        3
```

so the page reads are unchanged and the comparisons fall by a factor of eight.

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
target, followed by one equality check; do the same in the leaf. The existing test
`finds every key and nothing else, for many sizes and orders` checks the result,
including that the deepest lookup still equals `minHeight(n, m)`.

Expect two red tests after the change, 36 of 38 passing. Both pin comparison counts of
the linear scan, and no page-read figure changes anywhere:

- `a node gets only as many children as it needs` expects 1 comparison for a key found
  in a one-separator root; the binary search needs 2 (one to place the key, one to
  check for equality).
- `run prints exactly expected_output.txt` fails on the race row above and on the last
  line of the hand example, which becomes `get(17): 6 comparisons, 2 page reads`. In a
  node of three keys a binary search plus equality check can cost more than a scan; the
  README's worked example keeps describing the scan.

Update those expectations if you keep the change; the Rust port has the same two tests
(`a_node_gets_only_as_many_children_as_it_needs`, `run_prints_exactly_expected_output_txt`).

What this shows: a B-tree does not reduce the number of comparisons compared with one
big binary search. It does the same comparisons in a different order, arranged so that
consecutive comparisons look at bytes that are stored together.
