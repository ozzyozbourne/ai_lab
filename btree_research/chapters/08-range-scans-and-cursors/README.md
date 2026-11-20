# Chapter 08: Range scans and cursors

## What you will learn

- How a range scan works: one seek, then steps, then a stop test.
- The **bounds matrix**: each end of a range is unbounded, included or
  excluded, and how each case maps to a lower-bound or upper-bound search
  without ever computing `key + 1`.
- Why a prefix scan is a range scan.
- Two designs for a **cursor** (a position that can step forward and
  backward): one that follows the leaf links, and one that keeps the
  root-to-leaf path on a stack and never uses a sibling link.
- What goes wrong when the tree changes between two steps of a cursor, and
  the standard repair: save the key, seek again.

Prerequisites: chapter 07 (B+tree, leaf chain, handles) and chapter 02 (lower
bound and upper bound). The B+tree code is copied unchanged from chapter 07
into `base_*` files; everything new is built on top of it.

## The idea in plain words

A sorted index is useful mostly because of what comes *after* a lookup. "All
orders from March" or "the 20 rows after this one" are answered by finding
one position and then walking in key order. That walk is a **range scan**,
and the thing that does the walking is a **cursor**.

### A range scan is three things

1. **Seek** to the first entry of the range. This is one descent from the
   root, the same descent as `get`.
2. **Step** to the neighbouring entry, again and again.
3. **Stop** at the first entry that is outside the far end of the range.

A forward scan seeks to the lower bound and tests each key against the upper
bound. A backward scan is the mirror image: it seeks to the *upper* bound,
steps to the previous entry, and tests against the lower bound. Only the far
bound is tested per key. The near bound is settled by the seek and stays
settled, because every step moves away from it.

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

Two things can happen at the edge of a leaf. A forward seek can land one
past the last entry of the leaf; the answer is then the first entry of the
next leaf. A backward seek can land before index 0; the answer is the last
entry of the previous leaf. So even a seek may need one "step to the
neighbouring leaf", which is the operation the two cursor designs do
differently.

It is tempting to turn an excluded bound into an included one: `> k` is
`>= k + 1`. Do not. It overflows when `k` is the largest key, and for keys
that are byte strings there is no cheap "next key" at all. Letting the kind
of the bound choose between the two binary searches has no special cases.
An empty or inverted range needs no special case either: the first candidate
fails the far-bound test, or there is no candidate.

### Prefix scan as a range

Chapter 07 stored duplicates as composite keys, `(user key << 32) | row id`.
"All rows of user key 7" means "all keys whose top 32 bits are 7". Those keys
are contiguous, so this is the range from the first key with the prefix
(included) to the first key of the *next* prefix (excluded):
`[7 << 32, 8 << 32)`. The one trap: the largest prefix has no next prefix
(`0xFFFFFFFF + 1` does not fit), so its upper bound is unbounded. For byte
strings the rule is the same: increment the last byte that is not `0xFF` and
cut the string there; if every byte is `0xFF`, there is no upper bound.

### Two cursor designs

**Leaf-link cursor.** The position is `(leaf handle, index)`. To leave a
leaf, follow its `next` or `prev` link. Internal nodes are touched only
during the seek. This is the reason chapter 07 chained the leaves.

**Stack cursor.** The position is the whole path: for every internal node
from the root down, a frame `(node, which child I took)`, then the leaf and
an index. To leave a leaf going right, look at the top frame. If that node
has a child to the right of the one taken, move the frame to it and descend
along the left edge to a leaf, pushing frames. Otherwise pop the frame and
ask the node above. If the stack runs empty, the scan is past the last leaf.

Both designs return exactly the same entries. They differ in cost and in
what they demand from the tree:

| | Leaf-link cursor | Stack cursor |
|---|---|---|
| Size of a position | 2 words | 2 words + one frame per level |
| Moves to cross a leaf boundary | 1 | at least 2 (up, down); more across subtrees |
| Needs sibling links in the tree | yes | no |
| Cost paid by insert and delete | 4 link updates per leaf split, 2 per merge | none |

The last row is why real engines choose differently. Sibling links make
scans cheap and splits more expensive, and on disk a split must also write
the neighbour's page. A tree whose nodes are never modified in place
(chapter 23) cannot keep sibling links at all.

### When the tree changes under the cursor

A cursor often outlives one call: a query returns a row, the caller does
something, and asks for the next row. If that something is an insert or a
delete in the same tree, the cursor's position may no longer mean what it
meant. Entries shift inside a leaf, a split moves half of them to a new
node, a merge frees a node, and a freed handle is reused for an unrelated
node. A stale `(leaf, index)` then points at a different entry, or at no
entry.

One thing survives all of that: the **key** of the entry the cursor was on.
"The first key greater than 12" has a definite answer in any tree. So the
cursor keeps two things, a physical position and the key, and follows one
rule:

> Before using the physical position, check that the tree has not changed
> since it was computed. If it has, throw the position away and seek again
> by the saved key.

To detect the change, the tree here carries a counter, `version`, that goes
up on every insert and delete. The cursor stores the version it saw. This
rule is independent of the cursor design, and in the code it is written once
for both.

The result is a precise guarantee. A scan returns every entry that was in
the range for the whole scan exactly once and in order. An entry inserted or
deleted during the scan is returned if and only if the scan had not passed
its key yet.

## A worked example by hand

The canonical keys (10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, order 4) give
the tree of chapter 07:

```
level 0: #7[15]
level 1: #2[6 10] #6[20]
leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)
```

**Scan `[6, 17)` forward.** The lower bound is included, so seek `ge 6`. At
`#7`, 6 < 15: child 0. At `#2`, 6 equals the separator 6 and a key equal to a
separator goes right: child 1, leaf `#4`. `lowerBound(6)` in `(6 7)` is 0.
Return 6, 7. Next leaf `#1`: return 10, 12. Next leaf `#5`: return 15; then
17 fails `key < 17`, stop. Result: 6 7 10 12 15.

**Scan `(6, 17]` backward.** The upper bound is included, so seek `le 17`. At
`#7`, 17 >= 15: child 1. At `#6`, 17 < 20: child 0, leaf `#5`.
`upperBound(17)` in `(15 17)` is 2, so the cursor lands on index 1. Return
17, 15, then 12, 10 from `#1`, then 7 from `#4`; then 6 fails `key > 6`,
stop. Result: 17 15 12 10 7.

**The same forward steps with the stack cursor.** After the seek the stack
is `(#7, child 0) (#2, child 1)` and the leaf is `#4`.

- 7 to 10: leaf `#4` is exhausted. Top frame `#2` took child 1 of 0..2, so
  there is a child to the right: the frame becomes `(#2, child 2)`, descend
  to leaf `#1`. Two moves (up to `#2`, down to `#1`).
- 12 to 15: leaf `#1` is exhausted. Top frame `#2` took its last child: pop.
  Frame `#7` took child 0 of 0..1: it becomes `(#7, child 1)`. Descend: push
  `(#6, child 0)`, reach leaf `#5`. Four moves (up to `#2`, up to `#7`, down
  to `#6`, down to `#5`), where the link cursor needs one.

**A split under the cursor.** Both cursors seek `ge 10` and step once: they
are on 12, at leaf `#1`, index 1. Now insert 11, 13, 14. Leaf `#1` becomes
`(10 11 12 13)`, overflows and splits into `#1(10 11)` and a new leaf
`#8(12 13)`, which then also receives 14:

```
level 1: #2[6 10 12] #6[20]
leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #8(12 13 14) <-> #5(15 17) <-> #3(20 25 30)
```

The old position, leaf `#1` index 1, now holds 11. A cursor that trusted it
would step to "index 2", find the leaf exhausted, follow the link to `#8`
and return 12 a second time. The real cursor sees that the version changed
(12 inserts before, 15 now), drops the position and seeks `gt 12`: it lands
on 13 at `#8`, index 1.

## Code walk-through

Both languages have the same files, names, tests and output.

| File | Contents |
|------|----------|
| `base_*` | the chapter 07 B+tree, copied unchanged (only import paths renamed) |
| `tree` | `Tree`: the B+tree plus `version`; `get`, `put`, `delete`, `validate`, `range` |
| `bounds` | `Bound`, `aboveLower`, `belowUpper`, `contains`, `prefixRange` |
| `cursor` | `Seek`, `landing`, and `Cursor(Position)`: the save-key and re-seek rule |
| `link_cursor` | `LinkPosition`: leaf + index, follows sibling links |
| `stack_cursor` | `StackPosition`: path of frames, no sibling links |
| `scan` | `Scan`: range scan in either direction over any cursor |
| `model` | seeded model run against the oracle from `common/` |
| `tests`, `main` | tests and the demo program |

### Zig

**Tree** (`tree.zig`). `Tree` wraps the base `BPlusTree` and adds one field.
`put` increments `version` only if a new entry was created and `delete` only
if one was removed. An overwrite moves nothing, so a cursor standing on that
entry stays valid and simply reads the new value. If `put` fails with
`error.OutOfMemory`, the base tree is unchanged and so is `version`.

**Bounds** (`bounds.zig`). `Bound` is `union(enum) { unbounded, included:
u64, excluded: u64 }`. `contains(lo, hi, key)` is the definition of a range
and is what the tests compare every scan against. `prefixRange(prefix,
bits)` returns the two bounds described above.

**Cursor** (`cursor.zig`). `landing(keys, target)` is the first table of this
chapter as a `switch`: it returns `.forward = i` (the answer is entry `i`, or
the first entry of the next leaf if `i` is the leaf's length) or
`.backward = n` (the answer is entry `n-1`, or the last entry of the previous
leaf if `n` is 0). `Cursor(comptime Position: type)` holds the logical state
`before_first`, `after_last` or `on: key`, the version it saw, and counters.
Its invariant is stated in the source: if the state is `on(k)` and the
versions match, the position is on the entry with key `k`; otherwise the
position is garbage and must not be read. `next` is short:

```zig
.on => |key| {
    if (self.version != tree.version) {
        self.stats.reseeks += 1;
        return self.seek(tree, .{ .gt = key });
    }
    if (self.pos.next(&tree.base, &self.stats)) |found| { ... }
```

`prev` is the mirror image with `.lt`. `entry` re-seeks with `.ge` and
returns null if the key is gone; the cursor then stays "on" that key, so a
later `next` or `prev` continues from the gap.

**Link cursor** (`link_cursor.zig`). `settleForward(start)` returns entry
`start` of the current leaf or follows `next` once (a loop, in case a leaf is
empty). `settleBackward(count)` does the same with `prev`. Seeking to the
first or last entry uses `tree.first_leaf` and `tree.last_leaf` and needs no
descent.

**Stack cursor** (`stack_cursor.zig`). `descend` pushes a frame per internal
node. `stepLeaf` is the pop / step / push loop from the plain-words section.
The frames live in a slice of `max_depth = 32` entries allocated once in
`StackPosition.init`; the comment derives the bound from the 32-bit handles.
Nothing in this file reads `prev`, `next`, `first_leaf` or `last_leaf`. A
test cuts every leaf link and clears both chain ends: the stack cursor still
returns every scan correctly, and the link cursor cannot leave its leaf.

**Scan** (`scan.zig`). `Scan(C)` stores the tree pointer, a cursor, the two
bounds and a direction. `next` seeks on the first call, steps afterwards,
and tests the far bound. `collect(gpa)` materialises the rest of the scan
into a slice. `tree.range(lo, hi)` and `tree.rangeBackward(lo, hi)` return a
`Scan(LinkCursor)`.

### Rust

The structure is the same. The differences:

- **`Bound` comes from the standard library.** `std::ops::Bound<u64>` has the
  same three cases, and `RangeBounds` gives range syntax on top:
  `tree.range(6..17)`, `tree.range(..=17)`, `tree.range(..)`. An excluded
  lower bound has no syntax and is written as a pair,
  `(Excluded(6), Included(17))`. Unlike `BTreeMap::range`, an inverted range
  does not panic here; it is empty, as in Zig.
- **A trait instead of duck typing.** Zig's `Cursor(comptime Position: type)`
  accepts any type with the right functions and fails at compile time
  otherwise. Rust names the interface: `trait Position`, and `Cursor<P:
  Position>`.
- **Cursors do not borrow the tree.** Every cursor method takes `&Tree`. A
  cursor holding `&Tree` could not exist across a `put`, because `put` needs
  `&mut Tree`; and existing across changes is the purpose of this chapter.
  Zig cursors take the tree per call too, to keep the two versions alike.
- **Two scan types.** `Scan<P>` borrows nothing: `scan.next(&tree)` can be
  interleaved with `tree.delete(..)`. `ScanIter<'a, P>` (returned by
  `tree.range`) borrows the tree and implements `Iterator`; while it is
  alive the compiler rejects every change to the tree. In Zig one `Scan`
  type covers both uses, and nothing stops a caller from misusing a raw
  position.
- **The stack is a `Vec`.** `StackPosition` owns a `Vec<Frame>` with capacity
  `MAX_DEPTH`. `with_buffer` / `into_buffer` hand that allocation from one
  scan to the next, and `collect_into(&tree, &mut out)` reuses a result
  vector. That is the Rust form of resetting an arena while keeping its
  capacity.
- **Failure model.** A `Vec` aborts when memory runs out, so there is no test
  for a failing cursor allocation. The insert path is covered by the node
  budget of chapter 07: `Tree::with_node_budget(4, 8)` makes `put` return
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

- Section 2: the nine lines differ only at the two bound keys, 6 and 17.
- Section 4: `#7.0 #2.1` means "in node #7 the path goes down child 0, in
  node #2 child 1". The stack changes whenever the leaf changes. For
  `[5, 20]` the link cursor makes 7 moves (3 for the descent, 4 leaf hops)
  and the stack cursor 13 (3 for the descent, then 2, 2, 4 and 2 for the
  four leaf boundaries). For the full scan the link cursor starts at
  `first_leaf` without a descent: 1 + 4 moves.
- Section 6 is the worked example, followed by deletes under the cursor
  (`entry` reports that the entry is gone, `next` and `prev` continue from
  its key), an overwrite (no re-seek), and a scan that deletes every even
  key it returns: five deletes, five re-seeks, all twelve keys returned once.
- Section 7: the model run compares 1974 range scans and 17465 cursor steps
  per order with the oracle. Both designs re-seek equally often, because the
  rule is shared code. The node-visit columns show the price of having no
  sibling links; it shrinks as nodes get wider, because fewer steps cross a
  leaf boundary. These are counts of moves between in-memory nodes, not
  timings, and say nothing about the write-side cost of maintaining links.

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
different answer to the stale-position problem than the one in this chapter:
copy what you need while you hold the page, instead of re-seeking by key. It
relies on a property stated in the same README passage: items are never
moved across pre-existing page boundaries, except to the right by a split.

The bound decides the seek there as well: for `>=` the insertion scan key
gets `nextkey = false`, for `>` it gets `nextkey = true`
(`nbtsearch.c:1486-1502`). With no usable bound the scan starts at the
leftmost or rightmost page (`_bt_endpoint`, `nbtsearch.c:2211`).

Backward scans are harder in Postgres than here, because other backends may
split the left sibling while the scan is moving to it. The README gives the
move-left algorithm: follow the left link, and if that page's right link
does not point back to the page you came from, move right until one does
(`README:330-345`). Chapter 20 returns to this.

**Turso (SQLite format): a page stack.** There are no sibling links on disk
(chapter 07), so the cursor holds the path: `struct PageStack` with an array
of `BTCURSOR_MAX_DEPTH + 1` pages and a cell index per level
(`turso/core/storage/btree.rs:8989-9000`); `BTCURSOR_MAX_DEPTH` is 20 and a
tree that looks deeper is treated as corrupt (`btree.rs:155-157`).
`get_next_record` (`btree.rs:1759`) advances on the current page or moves up
and down the stack. Index trees add a twist that our B+tree does not have:
interior cells hold real entries, so the cursor must visit the divider cell
when it comes back up from a child (`btree.rs:1875-1878`).

Turso's answer to a changing tree is the one implemented here. A cursor has
a validity state; `RequireSeek` means "Cursor may be pointing to a
non-existent location/cell. This can happen after balancing operations"
(`btree.rs:600-610`). `save_context` stores the key and sets that state
(`btree.rs:6521-6531`); `restore_context` seeks to the saved key again
(`btree.rs:6562-6620`). If the saved row is gone, the seek lands on the next
greater one and `skip_advance` makes the following `next()` return it rather
than step past it; the comment says this mirrors SQLite's
`CURSOR_SKIPNEXT` (`btree.rs:6603-6611`). After a delete that rebalanced,
the same flag keeps a delete loop from skipping a row (`btree.rs:7411-7417`).
Our `Cursor` gets the same effect by re-seeking with `gt` on the saved key.
Turso saves explicitly, when it knows a change is coming; our version
counter detects the change afterwards. The counter is this chapter's
simplification, not something taken from either engine.

**DuckDB: the ART iterator.** DuckDB has no B-tree. Its ART index has no
sibling links either, and its iterator is a stack cursor over a radix tree:
`Next` increments the byte at the top of the stack, asks the node for the
next child, pops when the node is exhausted, and descends to the minimum of
the new child (`duckdb/src/execution/index/art/iterator.cpp:329-345`).
Chapter 28 covers ART.

**Milvus: the same bounds table on a sorted array.** The sorted scalar index
handles inclusive and exclusive bounds exactly as `landing` does: `lo_inc ?
lower_bound : upper_bound` for the start and `hi_inc ? upper_bound :
lower_bound` for the end
(`milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:637-642`).
Its `PrefixRange` computes the successor of a string prefix by incrementing
the last byte that is not the maximum and truncating, and falls back to "the
end" when there is none (`SortedIndexReader.cpp:364-379`). Milvus's in-memory
key-value store does a prefix scan the other way, as "seek to the prefix,
iterate, stop at the first key without the prefix"
(`milvus/internal/kv/mem/mem_kv.go:297-307`). Both forms return the same
keys; the range form has the advantage that the stop test is the ordinary
far-bound test.

**Sidebar: skip scan.** An index on `(x, y)` is sorted by `x` first, so
`WHERE y = 4` is not one range. Postgres can still use the index by treating
the query as one small range per distinct `x`: "Prior to Postgres 18, a qual
like "WHERE y = 4" always resulted in a full scan. This qual now becomes
"WHERE x = ANY('{every possible x value}') and y = 4"", with the caveat that
it "behaves like a full scan when there's many distinct "x" values"
(`postgres/src/backend/access/nbtree/nbtpreprocesskeys.c:130-137`). In the
terms of this chapter: a sequence of seeks, each followed by a short scan,
where the next seek key is derived from the last key seen. Not implemented
here.

Textbook, not verified in these sources: the name "Halloween problem" for a
scan that sees its own inserts (see Pitfalls).

## Allocator notes

Iteration does not allocate. A link cursor is two words on the caller's
stack. A stack cursor needs room for its frames, and a caller who wants the
results as a slice needs room for them. Both have the lifetime of one scan,
which is what an **arena** is for.

- **Why an arena.** Everything a scan allocates is freed together when the
  scan is over, and nothing is freed earlier. An `ArenaAllocator` turns that
  into one `reset` and needs no bookkeeping per object.
- **Which allocator backs it.** Any allocator; the tests use
  `std.testing.allocator`. `StackPosition.init(scratch)` allocates the frame
  slice (32 frames) and `Scan.collect(gpa)` the result slice. No other
  function of the cursor or scan code takes an allocator, so nothing else
  can fail with `OutOfMemory`; `seek`, `next` and `prev` return plain
  optionals.
- **Lifetime and reuse.** The demo and the model run call
  `arena.reset(.retain_capacity)` after each scan. A test wraps the backing
  allocator in a counter and shows that after the first scan, 100 further
  scans request nothing from it.
- **Allocation failure.** `StackPosition.init` on a failing allocator returns
  `error.OutOfMemory`. `collect` is run under
  `std.testing.checkAllAllocationFailures`, with and without an arena, to
  show that it frees its partial result. A failing `put` is tested to leave
  `version` and both cursors untouched.
- **What would go wrong with others.** With a general-purpose allocator every
  scan would need a matching `free` for the frames and for the results on
  every exit path. With a `FixedBufferAllocator` the frames would fit, but
  `collect` would fail on large results. Growing the frame stack on demand
  would make `next` fallible, because a re-seek after the tree grew taller
  might need a deeper stack; allocating the proven maximum once avoids that.
- **The trap.** A stack cursor's frames belong to the arena. Resetting the
  arena while the cursor is still in use leaves it with a dangling slice.
  Turso avoids the question by embedding a fixed array in the cursor; that
  is the obvious alternative, at the price of a larger cursor.

Rust: `Vec<Frame>` with reserved capacity, passed from scan to scan with
`with_buffer` / `into_buffer`, and `Vec::clear` on the result vector. A test
checks that addresses and capacities stay the same across 100 scans.

## Pitfalls

- **Rewriting `> k` as `>= k + 1`.** Overflows at the largest key and is
  impossible for strings. Choose the binary search by the kind of the bound.
- **Testing the wrong bound.** A backward scan seeks with the upper bound and
  stops on the lower bound. Testing both bounds per key hides the mistake
  until a seek is wrong.
- **Forgetting that a seek can land outside the leaf.** `gt 12` in leaf
  `(10 12)` is index 2: the answer is in the next leaf. `lt 6` reaches leaf
  `(6 7)` because 6 is a separator, and the answer is in the previous leaf.
- **Using a position after the tree changed.** The worked example returns 12
  twice. After a merge the leaf may have been freed and its handle reused,
  which in this arena is not even a crash, only a wrong answer.
- **Comparing versions of different trees.** A version is only meaningful for
  the tree the cursor was positioned in; passing another tree to `next` is a
  bug that the version check does not catch.
- **Inserting ahead of your own scan.** A forward scan that inserts `key + 1`
  for every key it returns never ends: each insert lands just ahead of the
  cursor and is returned next. This is known as the Halloween problem
  (textbook). The re-seek rule makes the behaviour well defined; it does not
  make it finite.
- **Expecting a snapshot.** A cursor that re-seeks sees the tree as it is now.
  Giving a scan a frozen view is the job of copy-on-write (chapter 23) or
  versioned rows (chapter 24).
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
