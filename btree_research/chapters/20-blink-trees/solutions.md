# Chapter 20: solutions

Every outcome quoted here was produced by running the chapter's Zig tests
(`zig build test --summary all`, 32 tests) against a scratch copy with the
described change, unless the text says "expected" or "not run". Where a
threaded test is involved the change was run eight times, and the text says
what varied.

## 1. Which keys are missed without right links?

26 and 30. They are the keys step 1 moved into #8, and #8 has no downlink, so
a search that only follows downlinks cannot reach it. The parent #6 still has
the single separator 20, so both keys are routed to #3, where they no longer
are.

25 is found because it stayed in #3: a split never changes where the keys of
the lower half live. The program prints this in section 3
(`keys found: 13 of 13 with right links, 11 of 13 without`), and the test
"the same state with move-right disabled misses exactly the moved keys"
asserts the list `30, 26`.

Note that 30 was inserted long before the split started. Without right links
a split makes old, committed keys disappear, not only the new one.

## 2. `key > high_key` instead of `key >= high_key`

Run with only that change, 8 or 9 of the 32 tests fail. Eight fail in every
run: the output test, "paused between step 1 and step 2"
(`expected 2600, found null`), the paused root split, the paused internal
node, the full node table, both model tests and the stress test with
abandoned splits. The ninth is the stress test with normal splits. It fails
only if some thread reaches the left half of a split with out-of-date
directions and a key equal to the new high key, so it depends on the
interleaving: it failed in 7 of 8 runs.

The first failure explains all of them. In the paused state #3 has high key
26, and 26 itself lives in #8. A search for 26 computes `26 > 26`, which is
false, stays in #3 and does not find the key. The comparison and the meaning
of the high key must agree: here the separator is the first key of the RIGHT
node, so the bound excludes it.

To use Postgres' inclusive rule the split would have to change too (not run;
this is what the Postgres source does, see the README): the high key of the
left node becomes a value that is greater than or equal to every key on the
left and strictly smaller than every key on the right, and the descent in an
internal node goes to the child whose separator is strictly below the search
key. Postgres states the range of a subtree as `Ki < v <= Ki+1`
(`nbtree/README:42-49`).

## 3. Clearing the flag too early

Change, in `insertParent`:

```zig
left.incomplete_split = false;   // moved up: before the allocation
var parent_right: NodeId = .nil;
if (parent.node.len == tree.maxKeys()) {
    parent_right = tree.allocPage(level + 1) catch { ... return .out_of_nodes; };
}
parent.node.internalInsertAt(slot, separator, right_id);
```

One test fails: "a full node table: put fails cleanly, or leaves a legal
incomplete split". `validate` returns `error.MissingDownlink`.

What happened: the parent was full, the table had no node left for the
parent's split, and the function returned without inserting the downlink. The
flag was already clear. The tree now contains a node with no downlink and no
flag: searches still find its keys by moving right, but no writer will ever
finish the split, and if that node splits, step 2 will not find a parent
entry.

All other tests pass, which is the lesson. The mistake is invisible as long
as nothing fails between the two lines. The flag and the downlink have to
change in one indivisible action; in the code that means: no exit between
them. In Postgres both are part of one critical section and one WAL record
(`nbtree/nbtinsert.c:1316-1328`).

## 4. A writer that walks past the flag

Change `if (page.incomplete_split)` in `moveRight` to `if (false and ...)`.

Three tests fail on an assertion and five abort (the same eight in 8 of 8
runs). The assertion failures are the direct effect: in "an insert that meets
the flag finishes the split before its own work", `incompleteSplits()` is
still 1 after `put 27`.

The aborts are the consequence. The demo program and both model tests stop
with

```
panic: B-link tree: downlink of a split node not found
```

"Two paused writers ..." stops on a check inside its own callback: the root
never becomes half split, because `put 31` walked past the flagged leaf
instead of finishing its split. The stress test with abandoned splits aborted
on the assertion `!left.incomplete_split` in `halfSplit` in all eight runs: a
writer was sent to a flagged leaf, did not finish it, filled it and split it
again. With threads, which of the two failures comes first depends on the
interleaving.

In the panic case a writer moved right from a flagged node into its sibling,
which has no downlink, filled it and split it. Step 2 of that split looked for the parent
entry of a node that has none, walked the parent level to its end and found
nothing. This is the failure the Postgres README describes: "if the page
without a downlink gets split again, the insertion algorithm will fail to
find the location in the parent level to insert the downlink"
(`nbtree/README:642-650`).

The rule "finish before you pass" is therefore not tidiness. It maintains the
invariant that a node which can be split always has a downlink.

## 5. A range scan with one latch at a time

The link to the next leaf and the high key must be read under the same latch
as the keys. Then the three values describe one consistent moment: "these are
all keys below `high`, and everything from `high` upwards is reachable from
`right`".

```zig
fn scan(tree: *BLinkTree, io: Io, gpa: Allocator, lo: u64, hi: u64, out: *std.ArrayList(u64)) !void {
    if (lo >= hi) return;
    // Find the leaf for `lo` with the ordinary descent.
    var d = Descent.begin(tree, lo, .follow_right_links);
    var leaf = while (true) switch (d.step(tree, io)) {
        .done => |r| break r.leaf,
        else => {},
    };
    var from = lo; // everything below `from` has been reported
    while (leaf != .nil) {
        const page = tree.lockShared(io, leaf);
        // Reserve before copying so that no error path holds the latch.
        out.ensureUnusedCapacity(gpa, page.node.len) catch |err| {
            tree.unlockShared(io, leaf);
            return err;
        };
        for (page.node.keySlice()) |k| {
            if (k >= from and k < hi) out.appendAssumeCapacity(k);
        }
        const next = page.right;
        const high = page.high_key;
        tree.unlockShared(io, leaf);
        const bound = high orelse break; // rightmost leaf
        if (bound >= hi) break;
        from = bound;
        leaf = next;
    }
}
```

Why it survives splits. After leaving a leaf the scan knows a key `from` (the
leaf's high key) and a handle `next`. `next` was, at the moment of reading,
the node whose range starts at `from`. If `next` splits before the scan
arrives, its lower half stays in `next` and the rest is further right, so
walking right from `next` still visits every key from `from` upwards exactly
once. If the leaf just read splits after the scan left it, nothing is lost
either: the scan already copied all of its keys.

The filter `k >= from` is what makes the argument independent of how the scan
reached a node; with the current code it never rejects a key, because a node's
keys are never below its lower bound.

Tested (single-threaded, added to `tests.zig` in a scratch copy): the scan of
`[6, 26)` on the canonical tree returns `6 7 10 12 15 17 20 25`; after seven
more puts with every split abandoned after step 1, the scan of `[0, 100)`
returns all 19 keys in order; `checkAllAllocationFailures` over the scan
passes, so no error path leaves a latch held or leaks. It was not run against
concurrent writers.

What this scan does not give you is a snapshot: a key inserted behind the
scan's position is not reported, one inserted ahead of it is. Chapter 08
discusses that for cursors in general, and the Postgres README explains why
its scans remember the right link at the time the page was read
(`nbtree/README:88-104`).
