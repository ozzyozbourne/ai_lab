# Chapter 08: Range scans and cursors

## What you will learn

- How a range scan works: one seek, then steps, then a stop test.
- The **bounds matrix**: each end of a range is unbounded, included or
  excluded, and how each case maps to a lower-bound or upper-bound search
  without ever computing `key + 1`.
- Why a prefix scan is a range scan.
- Two designs for a **cursor**: one follows the leaf links, one keeps the
  root-to-leaf path on a stack and never uses a sibling link.
- What goes wrong when the tree changes between two steps of a cursor, and
  the standard repair: save the key, seek again.

Prerequisites: chapter 07 (B+tree, leaf chain, handles) and chapter 02 (lower
bound and upper bound). The B+tree code is copied unchanged from chapter 07
into `base_*` files; everything new is built on top of it.

## The idea in plain words

A sorted index earns its keep after the lookup: "all orders from March" is
one position found and then a walk in key order. The walk is a **range
scan**; the thing that walks is a **cursor**.

### A range scan is three things

1. **Seek** to the first entry of the range. This is one descent from the
   root, the same descent as `get`.
2. **Step** to the neighbouring entry, again and again.
3. **Stop** at the first entry that is outside the far end of the range.

A forward scan seeks to the lower bound and tests each key against the upper
bound. A backward scan seeks to the *upper* bound, steps to the previous
entry, and tests against the lower bound. Only the far bound is tested per
key; the near bound is settled by the seek, because every step moves away
from it.

### The bounds matrix

Each end of a range can be **unbounded**, **included** (`>=`, `<=`) or
**excluded** (`>`, `<`): nine combinations. They need exactly four kinds of
seek, and those four are the two binary searches of chapter 02 read from
both sides. In a sorted array `keys`, `lowerBound(k)` is the number of keys
`< k` and `upperBound(k)` is the number of keys `<= k`.

| Seek | Meaning | Lands at index |
|------|---------|----------------|
| `ge k` | first key `>= k` | `lowerBound(k)` |
| `gt k` | first key `> k` | `upperBound(k)` |
| `le k` | last key `<= k` | `upperBound(k) - 1` |
| `lt k` | last key `< k` | `lowerBound(k) - 1` |

| Scan | Near bound unbounded | included `k` | excluded `k` | Far-bound test |
|------|----------------------|--------------|--------------|----------------|
| forward | first entry | `ge k` | `gt k` | `key <= hi` or `key < hi` |
| backward | last entry | `le k` | `lt k` | `key >= lo` or `key > lo` |

A forward seek can land one past the last entry of a leaf; the answer is
then the first entry of the next leaf. A backward seek can land before index
0; the answer is the last entry of the previous leaf. So even a seek may
need a "step to the neighbouring leaf", the operation the two cursor designs
do differently.

Do not turn an excluded bound into an included one (`> k` as `>= k + 1`). It
overflows when `k` is the largest key, and byte-string keys have no cheap
"next key". Letting the kind of the bound choose the binary search has no
special cases. An empty or inverted range needs none either: the first
candidate fails the far-bound test, or there is no candidate.

### Prefix scan as a range

Chapter 07 stored duplicates as composite keys, `(user key << 32) | row id`.
"All rows of user key 7" is "all keys whose top 32 bits are 7", and those
keys are contiguous: the range `[7 << 32, 8 << 32)`, from the first key with
the prefix to the first key of the *next* prefix. The trap: the largest
prefix has no next prefix (`0xFFFFFFFF + 1` does not fit), so its upper
bound is unbounded. For byte strings: increment the last byte that is not
`0xFF` and cut the string there; if there is none, no upper bound.

### Two cursor designs

**Leaf-link cursor.** The position is `(leaf handle, index)`. To leave a
leaf, follow its `next` or `prev` link. Internal nodes are touched only
during the seek.

**Stack cursor.** The position is the whole path: for every internal node
from the root down, a frame `(node, which child I took)`, then the leaf and
an index. To leave a leaf going right, look at the top frame. If that node
has a child further right, move the frame to it and descend along the left
edge, pushing frames. Otherwise pop the frame and ask the node above. An
empty stack means the scan is past the last leaf.

Both designs return exactly the same entries. They differ in cost and in
what they demand from the tree:

| | Leaf-link cursor | Stack cursor |
|---|---|---|
| Size of a position | 2 words | 2 words + one frame per level |
| Moves to cross a leaf boundary | 1 | at least 2 (up, down); more across subtrees |
| Needs sibling links in the tree | yes | no |
| Cost paid by insert and delete | 4 link updates per leaf split, 2 per merge | none |

The last row is why real engines choose differently: sibling links make
scans cheap and splits more expensive, and on disk a split must also write
the neighbour's page.

### When the tree changes under the cursor

A cursor often outlives one call: a query returns a row, the caller inserts
or deletes in the same tree, then asks for the next row. Meanwhile entries
shift inside a leaf, a split moves half of them to a new node, a merge frees
a node, and a freed handle is reused for an unrelated node. A stale
`(leaf, index)` then points at a different entry, or at none.

One thing survives all of that: the **key** of the entry the cursor was on.
"The first key greater than 12" has a definite answer in any tree. So the
cursor keeps two things, a physical position and the key, and follows one
rule:

> Before using the physical position, check that the tree has not changed
> since it was computed. If it has, throw the position away and seek again
> by the saved key.

To detect the change, the tree here carries a counter, `version`, that goes
up on every insert and delete, and the cursor stores the version it saw. The
rule does not depend on the cursor design; the code has it once for both.

The guarantee: a scan returns every entry that was in the range for the
whole scan exactly once and in order. An entry inserted during the scan is
returned if and only if the scan had not passed its key yet; an entry
deleted during the scan is not returned unless the scan had already passed
it.

## A worked example by hand

The canonical keys (10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, order 4) give
the tree of chapter 07:

```
level 0: #7[15]
level 1: #2[6 10] #6[20]
leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)
```

**Scan `[6, 17)` forward.** Seek `ge 6`. At `#7`, 6 < 15: child 0. At `#2`, 6
equals the separator 6 and goes right: child 1, leaf `#4`. `lowerBound(6)`
in `(6 7)` is 0. Return 6, 7; next leaf `#1`: 10, 12; next leaf `#5`: 15;
then 17 fails `key < 17`. Result: 6 7 10 12 15.

**Scan `(6, 17]` backward.** Seek `le 17`: at `#7` child 1, at `#6` child 0,
leaf `#5`. `upperBound(17)` in `(15 17)` is 2: index 1. Return 17, 15, then
12, 10, then 7; 6 fails `key > 6`. Result: 17 15 12 10 7.

**The forward scan with the stack cursor.** After the seek the stack is
`(#7, child 0) (#2, child 1)`.

- 7 to 10: top frame `#2` took child 1 of 0..2, so it becomes
  `(#2, child 2)`; descend to leaf `#1`. Two moves.
- 12 to 15: `#2` took its last child: pop. `#7` took child 0 of 0..1: it
  becomes `(#7, child 1)`; push `(#6, child 0)`, reach leaf `#5`. Four moves
  (up, up, down, down), where the link cursor needs one.

**A split under the cursor.** Both cursors seek `ge 10` and step once: they
are on 12, at leaf `#1`, index 1. Now insert 11, 13, 14. Leaf `#1` overflows
and splits:

```
level 1: #2[6 10 12] #6[20]
leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #8(12 13 14) <-> #5(15 17) <-> #3(20 25 30)
```

The old position, leaf `#1` index 1, now holds 11. A cursor that trusted it
would step to "index 2", find the leaf exhausted, follow the link to `#8`
and return 12 a second time. The real cursor sees that the version changed
(12 before, 15 now), drops the position and seeks `gt 12`: it lands on 13 at
`#8`, index 1.

## Code walk-through

Both languages have the same files, names, tests and output.

Files, in both `zig/src` and `rust/src`: `base_*` (the chapter 07 B+tree,
copied unchanged apart from import paths), `tree`, `bounds`, `cursor`,
`link_cursor`, `stack_cursor`, `scan`, `model` (the seeded run against the
oracle from `common/`), `tests` and `main`.

### Zig

**Tree** (`tree.zig`). `Tree` wraps the base `BPlusTree` and adds `version`.
`put` increments it only if a new entry was created, `delete` only if one
was removed. An overwrite moves nothing, so a cursor on that entry stays
valid and reads the new value. A `put` that fails with `error.OutOfMemory`
changes neither the tree nor `version`.

**Bounds** (`bounds.zig`). `Bound` is `union(enum) { unbounded, included:
u64, excluded: u64 }`. `contains(lo, hi, key)` is the definition of a range;
the tests compare every scan against it.

**Cursor** (`cursor.zig`). `landing(keys, target)` is the first table of this
chapter as a `switch`. It returns `.forward = i` (entry `i`, or the first
entry of the next leaf if `i` is the leaf's length) or `.backward = n`
(entry `n-1`, or the last entry of the previous leaf if `n` is 0).
`Cursor(comptime Position: type)` holds the state `before_first`,
`after_last` or `on: key`, the version it saw, and counters. Its invariant:
if the state is `on(k)` and the versions match, the position is on the entry
with key `k`; otherwise the position is garbage. `next` is short:

```zig
.on => |key| {
    if (self.version != tree.version) {
        self.stats.reseeks += 1;
        return self.seek(tree, .{ .gt = key });
    }
    if (self.pos.next(&tree.base, &self.stats)) |found| { ... }
```

`prev` mirrors it with `.lt`. `entry` re-seeks with `.ge` and returns null if
the key is gone; the cursor stays "on" that key, so a later `next` or `prev`
continues from the gap.

**Link cursor** (`link_cursor.zig`). `settleForward(start)` returns entry
`start` of the current leaf or follows `next`; `settleBackward(count)` does
the same with `prev`. Seeking to the first or last entry uses
`tree.first_leaf` / `tree.last_leaf` without a descent.

**Stack cursor** (`stack_cursor.zig`). `descend` pushes a frame per internal
node; `stepLeaf` is the pop / step / push loop. The frames live in a slice
of `max_depth = 32` entries allocated once in `StackPosition.init` (the
bound follows from 32-bit handles). Nothing here reads `prev`, `next`,
`first_leaf` or `last_leaf`: a test cuts every leaf link, after which the
stack cursor still answers every scan and the link cursor cannot leave its
leaf.

**Scan** (`scan.zig`). `Scan(C)` stores the tree pointer, a cursor, the
bounds and a direction. `next` seeks on the first call, steps afterwards,
and tests the far bound. `collect(gpa)` materialises the rest into a slice.
`tree.range(lo, hi)` and `tree.rangeBackward(lo, hi)` return a
`Scan(LinkCursor)`.

### Rust

The structure is the same. The differences:

- **`Bound` comes from the standard library.** `std::ops::Bound<u64>` has the
  same three cases, and `RangeBounds` adds range syntax: `tree.range(6..17)`,
  `tree.range(..=17)`. An excluded lower bound is written as a pair,
  `(Excluded(6), Included(17))`. Unlike `BTreeMap::range`, an inverted range
  does not panic here; it is empty, as in Zig.
- **A trait instead of duck typing.** Zig's `Cursor(comptime Position: type)`
  accepts any type with the right functions. Rust names the interface:
  `trait Position`, and `Cursor<P: Position>`.
- **Cursors do not borrow the tree.** Every cursor method takes `&Tree`. A
  cursor holding `&Tree` could not exist across a `put`, which needs
  `&mut Tree`. Zig cursors take the tree per call too, to keep the versions
  alike.
- **Two scan types.** `Scan<P>` borrows nothing, so `scan.next(&tree)` can be
  interleaved with `tree.delete(..)`. `ScanIter<'a, P>` (from `tree.range`)
  borrows the tree and implements `Iterator`; while it lives the compiler
  rejects every change to the tree. Zig has one `Scan` type for both uses.
- **The stack is a `Vec<Frame>`** with capacity `MAX_DEPTH`. `with_buffer` /
  `into_buffer` hand the allocation from one scan to the next, and
  `collect_into(&tree, &mut out)` reuses a result vector: the Rust form of
  resetting an arena while keeping its capacity.
- **Failure model.** A `Vec` aborts when memory runs out, so there is no test
  for a failing cursor allocation. The insert path uses chapter 07's node
  budget: `Tree::with_node_budget(4, 8)` makes `put` return
  `Err(OutOfNodes)`, and the test checks that `version` did not move.

### Output

Both programs print exactly [expected_output.txt](expected_output.txt); a
test in each language checks it.

```
== 1. The tree: canonical keys, order M = 4 ==
height 3, 12 keys, 8 nodes
  level 0: #7[15]
  level 1: #2[6 10] #6[20]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)

== 2. Bounds matrix: every combination for the bounds 6 and 17 ==
(-inf, +inf) : 1 3 5 6 7 10 12 15 17 20 25 30
(-inf, 17]   : 1 3 5 6 7 10 12 15 17
(-inf, 17)   : 1 3 5 6 7 10 12 15
[6, +inf)    : 6 7 10 12 15 17 20 25 30
[6, 17]      : 6 7 10 12 15 17
[6, 17)      : 6 7 10 12 15
(6, +inf)    : 7 10 12 15 17 20 25 30
(6, 17]      : 7 10 12 15 17
(6, 17)      : 7 10 12 15
edge cases:
[12, 12]     : 12   <- one key
(12, 15)     : (nothing)   <- neighbours, both excluded
[13, 14]     : (nothing)   <- both bounds in one gap
[17, 6]      : (nothing)   <- inverted
[12, 12)     : (nothing)   <- half open, same key
(-inf, 0)    : (nothing)   <- below the smallest u64
(18446744073709551615, +inf) : (nothing)   <- above the largest u64, no overflow

== 3. Backward: seek to the upper bound, step with prev ==
(-inf, +inf) : 30 25 20 17 15 12 10 7 6 5 3 1
[6, 17)      : 15 12 10 7 6
(6, 17]      : 17 15 12 10 7
[13, +inf)   : 30 25 20 17 15

== 4. Two cursor designs, one result ==
scan [5, 20] forward; "#0[2]" = leaf #0, entry 2; "#7.0" = in node #7, down child 0
key  link cursor  stack cursor
5    #0[2]        #7.0 #2.0 -> #0[2]
6    #4[0]        #7.0 #2.1 -> #4[0]
7    #4[1]        #7.0 #2.1 -> #4[1]
10   #1[0]        #7.0 #2.2 -> #1[0]
12   #1[1]        #7.0 #2.2 -> #1[1]
15   #5[0]        #7.1 #6.0 -> #5[0]
17   #5[1]        #7.1 #6.0 -> #5[1]
20   #3[0]        #7.1 #6.1 -> #3[0]
node visits (every move of a cursor to another node):
[5, 20]      forward  :  8 entries, link  7, stack 13
[5, 20]      backward :  8 entries, link  7, stack 13
(-inf, +inf) forward  : 12 entries, link  5, stack 15
[12, 12]     forward  :  1 entries, link  4, stack  7

== 5. Prefix scan as a range: key = (user key << 32) | row id ==
user key 7: range [30064771072, 34359738368), row ids: 1 3 5 7
user key 3: range [12884901888, 17179869184), row ids: 2 6
user key 8: range [34359738368, 38654705664), row ids: (nothing)
user key 4294967295: range [18446744069414584320, +inf), row ids: 8 9

== 6. The tree changes under the cursor ==
both cursors: seek >= 10, next. link on 12 at #1[1], stack on 12 at #7.0 #2.2 -> #1[1]
put 11, 13, 14: leaf #1 fills up and splits
  height 3, 15 keys, 9 nodes
  level 0: #7[15]
  level 1: #2[6 10 12] #6[20]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #8(12 13 14) <-> #5(15 17) <-> #3(20 25 30)
  the old position #1[1] now holds 11; stepping from it would return 12 a second time
  link  next -> 13 (re-seek: first key > 12), now at #8[1]
  stack next -> 13 (re-seek: first key > 12), now at #7.0 #2.3 -> #8[1]
delete 13 (the entry under both cursors), 14, 15, 17: 1 borrow, 0 merges
  height 3, 11 keys, 9 nodes
  level 0: #7[15]
  level 1: #2[6 10 12] #6[25]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #8(12) <-> #5(20) <-> #3(25 30)
  link  entry -> none (deleted), next -> 20, prev -> 12
  stack entry -> none (deleted), prev -> 12, next -> 20
  link on 12=1200; put 12=1212 (overwrite); entry -> 12=1212, re-seeks caused: 0
  re-seeks so far: link 3, stack 3
delete every even key while scanning the whole tree forward:
  link  returned: 1 3 5 6 7 10 12 15 17 20 25 30 | re-seeks 5 | left: 1 3 5 7 15 17 25
  stack returned: 1 3 5 6 7 10 12 15 17 20 25 30 | re-seeks 5 | left: 1 3 5 7 15 17 25

== 7. Model run: 20000 random operations, two long-lived cursors stepping in between ==
M=3  keys=324 height=8 scans=1974 cursor steps=17465 re-seeks=4166 | node visits: link=55417 stack=88885 | mismatches=0
M=4  keys=324 height=6 scans=1974 cursor steps=17465 re-seeks=4166 | node visits: link=42269 stack=64805 | mismatches=0
M=16 keys=324 height=3 scans=1974 cursor steps=17465 re-seeks=4166 | node visits: link=19746 stack=25076 | mismatches=0
```

Things to notice:

- Section 4: `#7.0 #2.1` means "in node #7 the path goes down child 0, in
  node #2 child 1". For `[5, 20]` the link cursor makes 7 moves (3 for the
  descent, 4 leaf hops) and the stack cursor 13 (3, then 2, 2, 4 and 2 for
  the four leaf boundaries). The full scan starts at `first_leaf` without a
  descent: 1 + 4 moves.
- Section 6 is the worked example, then deletes under the cursor, an
  overwrite (no re-seek), and a scan that deletes every even key it returns:
  five deletes, five re-seeks, all twelve keys returned once.
- Section 7: per order, 1974 range scans and 17465 cursor steps are compared
  with the oracle. Both designs re-seek equally often, because the rule is
  shared code. The node-visit columns are counts of moves between in-memory
  nodes, not timings, and say nothing about the write-side cost of
  maintaining links.

## In real databases

**Postgres: leaf links, one page at a time.** An index scan descends once
and then moves along the leaf level through the sibling links. It does not
keep a position inside a shared page. Instead it "always searches a leaf
page to identify all the matching items at once, copying their heap tuple
IDs into backend-local storage", and "the scan must remember the page's
right-link at the time it was scanned, since that is the page to move right
to; if we move right to the current right-link then we'd re-scan any items
moved by a page split" (`postgres/src/backend/access/nbtree/README:88-104`).
The saved position, `BTScanPosData`, holds `currPage`, `prevPage` and
`nextPage` (`postgres/src/include/access/nbtree.h:962-970`), and stepping to
the next page reads `so->currPos.nextPage` or `prevPage`
(`postgres/src/backend/access/nbtree/nbtsearch.c:1715-1719`). That is a
different answer to the stale-position problem: copy what you need while you
hold the page, and rely on the rule (same passage) that items never move
across existing page boundaries except to the right by a split.

The bound decides the seek there as well: for `>=` the insertion scan key
gets `nextkey = false`, for `>` it gets `nextkey = true`
(`nbtsearch.c:1486-1502`). With no usable bound the scan starts at the
leftmost or rightmost page (`_bt_endpoint`, `nbtsearch.c:2211`).

Backward scans are harder in Postgres, because another backend may split the
left sibling while the scan moves to it; the README's move-left algorithm
follows the left link and then moves right until a page's right link points
back to the page it came from (`README:330-345`). Chapter 20 returns to this.

**Turso (SQLite format): a page stack.** There are no sibling links on disk
(chapter 07), so the cursor holds the path: `struct PageStack` with an array
of `BTCURSOR_MAX_DEPTH + 1` pages and a cell index per level
(`turso/core/storage/btree.rs:8989-9000`); the limit is 20 levels and a tree
that looks deeper is treated as corrupt (`btree.rs:155-157`).
`get_next_record` (`btree.rs:1759`) advances on the current page or moves up
and down the stack. In index trees interior cells hold real entries, so the
cursor also visits the divider cell when it comes back up from a child
(`btree.rs:1875-1878`); our B+tree has no such case.

Turso's answer to a changing tree is the one implemented here. A cursor has
a validity state; `RequireSeek` means "Cursor may be pointing to a
non-existent location/cell. This can happen after balancing operations"
(`btree.rs:600-610`). `save_context` stores the key and sets that state
(`btree.rs:6521-6531`); `restore_context` seeks to the saved key again
(`btree.rs:6562-6620`). If the saved row is gone, the seek lands on the next
greater one and `skip_advance` makes the following `next()` return it rather
than step past it, mirroring SQLite's `CURSOR_SKIPNEXT` according to the
comment (`btree.rs:6603-6611`). Our `Cursor` gets the same effect by
re-seeking with `gt`. Turso saves explicitly when it knows a change is
coming; our version counter detects the change afterwards. The counter is
this chapter's simplification, not taken from either engine.

**DuckDB: the ART iterator.** DuckDB has no B-tree. Its ART index has no
sibling links, and its iterator is a stack cursor over a radix tree: `Next`
steps the top of the stack to the next child, pops when a node is exhausted,
and descends to the minimum of the new child
(`duckdb/src/execution/index/art/iterator.cpp:329-345`). See chapter 28.

**Milvus: the same bounds table on a sorted array.** The sorted scalar index
picks `lo_inc ? lower_bound : upper_bound` for the start and `hi_inc ?
upper_bound : lower_bound` for the end
(`milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:637-642`),
which is `landing`. Its `PrefixRange` increments the last byte of the prefix
that is not the maximum, and falls back to "the end" when there is none
(`SortedIndexReader.cpp:364-379`).

**Sidebar: skip scan.** An index on `(x, y)` is sorted by `x` first, so
`WHERE y = 4` is not one range. Postgres 18 can run it as one small range
per distinct `x`: the qual "now becomes "WHERE x = ANY('{every possible x
value}') and y = 4"", though it "behaves like a full scan when there's many
distinct "x" values"
(`postgres/src/backend/access/nbtree/nbtpreprocesskeys.c:130-137`). That is
a sequence of seeks, each followed by a short scan. Not implemented here.

Textbook, not verified in these sources: the name "Halloween problem" (see
Pitfalls).

## Allocator notes

Iteration does not allocate. A link cursor is two words. A stack cursor needs
room for its frames, and a caller who wants the results as a slice needs
room for those. Both live exactly as long as one scan, which is what an
**arena** is for.

- **What allocates.** `StackPosition.init(scratch)` (32 frames) and
  `Scan.collect(gpa)` (the result slice). No other cursor or scan function
  takes an allocator, so `seek`, `next` and `prev` cannot fail.
- **Reuse.** The demo and the model run call `arena.reset(.retain_capacity)`
  after each scan. A test counts requests to the backing allocator: after
  the first scan, 100 further scans make none.
- **Allocation failure.** `StackPosition.init` on a failing allocator returns
  `error.OutOfMemory`. `collect` runs under
  `std.testing.checkAllAllocationFailures`, with and without an arena. A
  failing `put` is tested to leave `version` and both cursors untouched.
- **What would go wrong with others.** A general-purpose allocator needs a
  matching `free` for frames and results on every exit path. Growing the
  frame stack on demand would make `next` fallible, because a re-seek after
  the tree grew taller might need a deeper stack; allocating the proven
  maximum once avoids that.
- **The trap.** Resetting the arena while a stack cursor is still in use
  leaves it with a dangling slice. Turso embeds a fixed array in the cursor
  instead, at the price of a larger cursor.

Rust: `Vec<Frame>` with reserved capacity, passed from scan to scan, and
`Vec::clear` on the result vector. A test checks that addresses and
capacities stay the same across 100 scans.

## Pitfalls

- **Rewriting `> k` as `>= k + 1`.** Overflows at the largest key and is
  impossible for strings. Choose the binary search by the kind of the bound.
- **Forgetting that a seek can land outside the leaf.** `gt 12` in leaf
  `(10 12)` is index 2: the answer is in the next leaf. `lt 6` reaches leaf
  `(6 7)` because 6 is a separator, and the answer is in the previous leaf.
- **Using a position after the tree changed.** The worked example returns 12
  twice. A freed leaf's handle may be reused, which in this arena is not a
  crash, only a wrong answer.
- **Inserting ahead of your own scan.** A forward scan that inserts `key + 1`
  for every key it returns never ends: each insert lands just ahead of the
  cursor and is returned next. This is known as the Halloween problem
  (textbook). The re-seek rule makes the behaviour well defined; it does not
  make it finite.
- **Expecting a snapshot.** A re-seeking cursor sees the tree as it is now.
  Frozen views are chapters 23 and 24.
- **Resetting the scratch arena under a live stack cursor.** See above.

## Exercises

1. (easy) By hand, on the canonical tree: which seek starts the scan
   `(7, 20]` backward, where does it land, and what does the scan return?
2. (easy) Section 4 of the output says that `[5, 20]` forward costs the link
   cursor 7 node visits and the stack cursor 13. Account for every one of
   them using the trace table above it.
3. (medium) Write `certainlyEmpty(lo, hi)`, which decides without looking at
   the tree whether no `u64` can be inside the range. Which of its cases
   would be wrong for byte-string keys?
4. (medium) The demo deletes every even key during a full forward scan and
   reports 5 re-seeks. Predict the number of re-seeks when the scan deletes
   every odd key instead, and when it deletes every key. Then predict what
   happens if the scan inserts `key + 1` after every key it returns.
5. (hard) Design the Postgres-style alternative to re-seeking for the link
   cursor: when the cursor arrives in a leaf, copy the entries that are in
   range and the leaf's `next` handle into the cursor, and return entries
   from the copy. Which inserts and deletes does such a scan see or miss,
   compared with the guarantee stated in this chapter? What in this
   chapter's tree breaks the idea?

Solutions are in [solutions.md](solutions.md).

## Links

- Previous: [chapter 07, B+trees](../07-bplus-trees/README.md)
- Next: [chapter 09, pages and the buffer pool](../09-pages-and-the-buffer-pool/README.md)
- Visualization: [viz/index.html](viz/index.html) (a range scan with either
  cursor design; a cursor surviving a split, and what happens without the
  re-seek)
