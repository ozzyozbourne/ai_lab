# Chapter 16: Bulk loading

## What you will learn

- How to build a B+tree from sorted input from the bottom up, without a single split
  and without a single search.
- Why the loader needs only one open page per tree level, however large the input is.
- What a fill factor is for, and what it costs and buys once inserts start arriving.
- How the cost compares with inserting the same keys one at a time, in counted pages.

Prerequisites: B+trees with a leaf chain (chapter 07), splitting (chapter 04), and the
fill-factor idea from the split side (chapter 14). Chapter 15 explained that real engines
are relaxed about minimum occupancy; that comes back here.

## The idea in plain words

Inserting keys one at a time treats every key as a surprise. Each insert walks from the
root to a leaf, and whenever a leaf is full it is split, half of it is moved, and the
parent is changed. If the keys happen to arrive in ascending order the result is
especially poor: every split leaves behind a half-full left page that will never receive
another key.

When you have all the keys up front and they are sorted, nothing is a surprise. You
know that the first few keys belong in the first leaf, the next few in the second leaf,
and so on. So:

1. Fill a leaf with keys until it reaches its target. Start the next leaf.
2. Every time a leaf is finished, hand one pair `(first key of that leaf, id of that
   leaf)` to the level above. The level above is filled in exactly the same way: it is
   a page collecting pairs.
3. Every time a page on that level is finished, hand one pair to the level above it.
4. When the input ends, finish the open page on each level from the bottom up. The
   level that ends with a single page holds the root.

The tree grows upward only when it needs to: level 1 comes into existence when the
second leaf appears, level 2 when the second level-1 page appears. At any moment the
loader holds one open page per level and nothing else. All pages to the left are done
and will never be touched again.

The *fill factor* is the target in step 1, as a percentage of the page's capacity.
Filling to 100% gives the smallest tree, and that is the right choice for data that
will never change. For a tree that will keep receiving inserts it is the wrong choice:
every leaf is full, so the first insert into any leaf splits it, and because the
interior pages are full too, the split can cascade upward. Leaving some room in each
page delays that.

### Two details that make it work

Uniform pairs. A leaf holds `(key, value)` pairs. An interior page holds
`(key, child)` pairs, where the key is the smallest key that can be under that child.
The first key of an interior page is not needed for searching, because everything
smaller than the second key goes to the first child anyway. We keep it in the page and
simply ignore it when searching. That makes both kinds of page a plain list of pairs,
and it means the pair an interior page hands upward is just its own first pair's key
together with its own id. PostgreSQL calls this ignored first key "minus infinity".

The last page of each level. Our tree promises the textbook minimum occupancy (order
M: at least ceil(M/2) - 1 keys in a leaf, at least ceil(M/2) children in an interior
page). Filling left to right gives no such guarantee for the last page of a level: it
gets whatever is left over. So the loader keeps the most recently filled page of each
level *pending*: it is complete and has an id, but it is not written until the page
after it is known to be big enough. When the input ends, the pending page and the open
page of a level are the only two that might need adjusting, and neither has been
written, so they can share their pairs evenly, or be combined into one page if together
they are too few for two. Every page is still written exactly once.

## A worked example by hand

Keys 1 to 13, order M = 4, fill 100%. A leaf holds 3 keys; an interior page holds 4
children (minimum 2).

| Event | Level 0 | Level 1 | Level 2 | Written |
|---|---|---|---|---|
| keys 1, 2, 3 | open `[1 2 3]` | | | |
| key 4 arrives | `[1 2 3]` becomes page A, pending; open `[4]` | | | |
| key 7 arrives | `[4 5 6]` becomes B; A is linked to B and written | open `(1,A)` | | A |
| key 10 arrives | `[7 8 9]` becomes C; B written | open `(1,A) (4,B)` | | B |
| key 13 arrives | `[10 11 12]` becomes D; C written | open `(1,A) (4,B) (7,C)` | | C |
| end of input, level 0 | open `[13]` has 1 key, which is the leaf minimum: it becomes E. D and E are written | `(10,D)` fills the open page; `(13,E)` then closes it as page P and opens `(13,E)` | | D, E |
| level 1 | | open page has 1 child, below the minimum of 2. P and the open page share 5 children as 3 + 2: P = `A B C`, Q = `D E`. Both written | | open `(1,P) (10,Q)` | P, Q |
| level 2 | | | only page on its level: the root R | R |

Eight pages, eight writes, no page read, no split. The program prints the result with
interior pages shown by their separators (the keys after the ignored first one):

```
bulk load, fill 100%:
  level 2: (10)
  level 1: (4 7) (13)
  level 0: [1 2 3] [4 5 6] [7 8 9] [10 11 12] [13]
  pages 8, page writes 8, splits 0
one-by-one insert, ascending:
  level 2: (7)
  level 1: (3 5) (9 11)
  level 0: [1 2] [3 4] [5 6] [7 8] [9 10] [11 12 13]
  pages 9, page writes 25, splits 6
```

The second tree is what thirteen ascending `put` calls produce: every full leaf was
split 2 + 2, and the left halves stayed at two keys forever.

## Code walk-through

Three source files per language matter, with the same names and the same tests. (The
others: `prng` and `ops` copied from `common/`, `main`, and `lib.rs` in Rust.)

| File | Contents |
|---|---|
| `bptree` | The compact B+tree: fixed-capacity nodes in one array, `get`, `put`, `range`, `validate`, and the counters |
| `bulk` | The loader |
| `report` | The fixed scenario that `run` prints |

### The tree (`zig/src/bptree.zig`)

A `Node` is a fixed-size struct with two arrays, `keys` and `slots`, and a length. In a
leaf, `slots[i]` is the value of `keys[i]`. In an interior node, `slots[i]` is a child
id and `keys[0]` is the ignored key. Nodes live in `tree.nodes` and are named by
index; the index plays the role of a page id.

`stats.page_writes` counts how many times a node would have to be written back if every
operation were flushed when it ends. A `put` that splits nothing counts 1. A split
counts 2 (both halves), then the parent is charged in the same way, and a new root
counts 1. `stats.page_reads` counts the nodes `put` visits on the way down.

`put` is written so that it cannot fail halfway. It descends and records the path,
counts how many nodes at the bottom of the path are full, reserves that many new nodes
(plus one if the root will split), and only then changes anything:

```zig
if (needed == depth + 1) needed += 1; // root splits too
try self.nodes.ensureUnusedCapacity(self.gpa, needed);
```

`validate` checks six invariants: key order inside nodes, separator bounds, occupancy,
equal leaf depth, the leaf chain, and the entry count. `range(lo, hi)` is half-open
(`lo <= key < hi`), so it can never return the key `maxInt(u64)`; `get` can. There is
no `delete` in this chapter's tree; chapters 05, 07 and 15 cover it.

### The loader (`zig/src/bulk.zig`)

The state is one `Level` per tree level:

```zig
const Level = struct {
    arena: std.heap.ArenaAllocator, // owns buf
    buf: []Pair = &.{},             // the open page
    len: usize = 0,
    pending: u32 = nil,             // filled, has an id, not yet written
    sealed: usize = 0,              // pages already written on this level
};
```

The whole algorithm is `addPair`, which runs on every level:

```zig
fn addPair(self: *BulkLoader, level: usize, pair: Pair) Allocator.Error!void {
    if (level == self.n_levels) { ... start the level, allocate its buffer ... }
    if (self.levels[level].len == self.target(level)) try self.closeOpenPage(level);
    const lv = &self.levels[level];
    lv.buf[lv.len] = pair;
    lv.len += 1;
}
```

`closeOpenPage` copies the buffer into a new node, makes that node the pending page,
and seals the previous pending page. `seal` counts the write and calls `addPair` one
level up with `(node.keys[0], id)`. So the recursion goes upward, and its depth is the
height of the tree.

Notice when a page is closed: not when it becomes full, but when it is full *and
another pair arrives*. That guarantees a closed page always has a right neighbour,
which is what lets a leaf's `next` link be filled in before the leaf is written.

`finish` walks the levels bottom to top (the loop is `closeRightEdge`). On each level
it first repairs the tail (share or combine the pending and the open page if the open
page is under the minimum), then either declares the single remaining page the root,
or seals what is left, which feeds the level above.

A loader is used once. `finish` closes it: a second `finish`, or an `add` after it,
returns `error.LoaderClosed`. Running out of memory closes it too. `put` can promise
"unchanged on failure" because it reserves before it writes; the loader cannot,
because earlier pages are already sealed when an allocation fails. So a failed load
is abandoned as a whole: the tree is emptied and the loader refuses further calls.
`error.NotSorted` is different: the key is rejected and nothing has changed.

`fillTarget(cap, min, percent)` is `floor(cap * percent / 100)` clamped to
`[min, cap]`. With tiny pages the rounding is coarse: 90% of 15 keys is 13 keys, which
is 86%. A fill factor below 50% behaves like 50%, because a page under the minimum
would break the tree's invariant.

### Rust (`rust/src/*.rs`) and the differences

The port is line for line where the languages allow it. The differences:

| | Zig | Rust |
|---|---|---|
| Per-level buffer | slice from a per-level `ArenaAllocator`, `reset(.retain_capacity)` after each page | `Vec<Pair>`, `clear()` after each page (keeps the allocation) |
| Levels | fixed array of `max_height` levels, because an arena should not be moved while in use | `Vec<Level>`; moving a `Vec` is harmless |
| Running out of memory | `error.OutOfMemory` from the allocator, tested with `FailingAllocator` and `checkAllAllocationFailures` | a node budget (`Tree::with_budget`) returning `Err(Error::OutOfNodes)` |
| `put` reservation | `ensureUnusedCapacity(needed)` | compare `needed` with the remaining budget |
| Borrowing the tree | the loader holds `*Tree`; nothing stops you from using the tree mid-load | the loader holds `&mut Tree`; the compiler forbids touching the tree until the loader is gone |
| Using a finished loader | `error.LoaderClosed` at run time, from a `closed` flag | does not compile: `finish(self)` consumes the loader (a `compile_fail` doc test checks it). The flag remains for a load abandoned by `OutOfNodes` |
| Tail sharing | `copyBackwards` to shift the buffer, then copy | `Vec::splice(0..0, ..)` |
| Crate layout | one module rooted at `main.zig` | `lib.rs` plus a small `main.rs`, so that public items unused by `main` are not dead code |

### What the programs print

Both programs print exactly `expected_output.txt`. After the hand example come two
experiments with 10,000 keys and order 16 (15 keys per leaf):

```
== 2. Building n = 10000 keys, order M = 16 ==
method                 height  leaves  inner  pages  leaf fill  page writes  page reads  splits
bulk load 100%              4     667     46    713        99%          713           0       0
bulk load 90% / 70%         4     770     77    847        86%          847           0       0
insert, ascending           4    1250    155   1405        53%        12802       38631    1401
insert, shuffled            4     941     92   1033        70%        12058       37884    1029

== 3. 1000 random inserts after the bulk load ==
leaf / inner fill  pages before  splits  page writes  pages after
 100% / 100%              713     566         2132         1279
  90% /  70%              847     112         1224          959
  70% /  70%             1100       2         1004         1102
```

How to read experiment 2:

- The bulk loader writes each page once and reads nothing. Its write count *is* its
  page count.
- The leaf-fill column is rounded down. The 100% load shows 99% because the last of
  its 667 leaves holds 10 keys, not 15: 10,000 / (667 × 15) = 99.95%.
- Ascending inserts end at 53% leaf fill and about twice the pages of the packed tree.
  Random-order inserts end at 70%, the usual steady state for 50/50 splits.
- The page-write column for the insert rows is a write-through count: one flush per
  operation. A buffer pool would absorb many of those writes, because the same hot
  pages are dirtied again and again before they are flushed. What a buffer pool cannot
  remove is the 38,631 page visits, the 1,401 splits, and the larger tree that results.
  Treat the write column as "pages dirtied", an upper bound on physical writes.

Experiment 3 is the argument for a fill factor below 100%. Its 1000 keys are random,
all different, and none of them is in the tree yet. The packed tree is smallest
on the day it is built, and then more than half of the first thousand inserts split a
page; it ends up larger than the tree that started at 90% / 70%. The tree loaded at
70% absorbs the same inserts with two splits.

## In real databases

PostgreSQL, `CREATE INDEX` on a B-tree (`src/backend/access/nbtree/nbtsort.c`). This
chapter's loader is a simplification of it.

- The file header describes the algorithm in one paragraph: load leaf pages in order;
  "Whenever we fill a page at one level, we add a link to it to its parent level
  (starting a new parent level if necessary)"; at the end, "When we have only one page
  on a level, it must be the root" (`nbtsort.c:8-15`).
- One `BTPageState` per level holds the page being built, its block number, its low
  key, and a pointer to the parent level's state (`nbtsort.c:235-245`). That is our
  `Level`.
- `_bt_buildadd` is our `addPair`: when the page is full it links the old page into
  the parent with a recursive `_bt_buildadd` on `btps_next`, creating that level if it
  does not exist (`nbtsort.c:952-962`).
- Fill targets: "It is not wise to pack the pages entirely full, since then *any*
  insertion would cause a split (and not only of the leaf page; the need for a split
  would cascade right up the tree)". Leaves are packed to the index's fill factor,
  default 90%, and upper pages always to 70% (`nbtsort.c:17-24`, thresholds set in
  `_bt_pagestate` at `nbtsort.c:668-671`, constants in
  `src/include/access/nbtree.h:200-202`). A page is full when its free space drops
  below the threshold, measured in bytes, not in a key count
  (`nbtsort.c:858-859`).
- Postgres does not hold a page back. `_bt_uppershutdown` adds each level's last page
  to its parent and writes it as it is (`nbtsort.c:1066-1132`); there is no evening
  out of the last two pages, because Postgres does not enforce a minimum occupancy
  (chapter 15). The only floor is in `_bt_buildadd`: a page must hold at least two
  items before a new one is started, whatever the fill factor says
  (`nbtsort.c:849-853`).
- When a page fills, Postgres moves its last item to the new page and keeps a copy as
  the old page's high key, which is also the new page's low key
  (`nbtsort.c:880-893`, `:966-969`). High keys are the subject of chapters 17 and 20;
  our pages have none.
- Pages built this way bypass the buffer cache: "We use the bulk smgr loading facility
  to bypass the buffer cache and WAL-log the pages efficiently" (`nbtsort.c:26-27`).

TigerBeetle. An LSM table is the limiting case: it is built once, left to right, and
never modified, so it is packed full and has exactly two levels: "Index block (exactly
1)" and value blocks (`src/lsm/table.zig:41-44`). The `Builder` (`table.zig:243`)
finishes one value block at a time; `value_block_finish` appends one entry to the
index block and asserts that the new block's first key is greater than the previous
block's largest key (`table.zig:373-377`). There is no fill factor because there are
no later inserts into a table.

DuckDB. The same idea applied to a different tree. When the keys of a `CREATE INDEX`
chunk are sorted, `ARTBuilder::Build` constructs the radix tree for that chunk without
descending from the root for each key: it treats the chunk as a sorted slice and
partitions it by the next key byte (`src/execution/index/art/art_builder.cpp:10-89`).
The chunk's tree is then merged into the thread's tree
(`src/execution/index/art/art_index.cpp:111-128`). If the keys are not sorted, the
sink falls back to one insert per key (`art_index.cpp:94-109`). Chapter 28 covers the
ART itself.

Textbook material, not checked against any source here: the 69% average fill for random
inserts with 50/50 splits (our measured 70% agrees), and the minimum-occupancy rule the
tail repair exists to satisfy.

## Allocator notes

The row for this chapter asks for one arena per tree level with
`reset(.retain_capacity)`.

- Choice. Each level owns a `std.heap.ArenaAllocator` whose only tenant is the buffer
  of the open page. When the page is copied into the tree, the arena is reset with
  `.retain_capacity` and the next buffer is allocated from it. The reset keeps the
  memory, so after the first page of a level the loader never asks the backing
  allocator for anything again. The test "loader memory does not grow with the input"
  checks, for orders 4 and 32, that each level's arena holds exactly as many bytes
  after 200,000 keys as after 2,000: one buffer plus the arena's bookkeeping.
- Lifetime. A level's arena lives from the first pair that reaches that level until
  `loader.deinit()`. The tree's nodes are *not* in these arenas: they belong to the
  tree (allocated from `gpa` through `tree.nodes`) and outlive the loader. The split
  is deliberate: scratch memory dies with the loader, results do not.
- Why per level and not one arena. Levels finish pages at different times. A leaf
  page closes about every 15 keys, a level-1 page every few hundred. One shared arena
  could only be reset when every level is between pages, which never happens.
- What goes wrong with other choices. Allocating each buffer from `gpa` and freeing
  it works but costs an allocator round trip per page. A single arena that is never
  reset grows with the number of pages, which defeats the point that loader memory is
  O(height). Putting the *tree's nodes* into the loader's arenas would free the tree
  when the loader is deinitialised.
- A trap: `ArenaAllocator.reset` invalidates everything allocated from the arena. The
  loader copies the buffer into the node before the reset, never after.
- Failure paths. Tests use `std.testing.allocator`, so a leak fails the test.
  `checkAllAllocationFailures` runs a whole bulk load once per allocation point with
  that allocation failing and checks that nothing leaks. A second test fails every
  node allocation in turn and checks that the tree is left empty and valid and that
  the loader is closed. `put` is tested with
  `FailingAllocator`: after a failed `put` the tree still validates and still holds
  everything inserted before.

Rust has no arena here: the per-level `Vec<Pair>` with `clear()` is the same
"keep the block, forget the contents" idea, and `Vec<Node>` with `u32` indices is the
typed arena for the nodes.

## Pitfalls

- Closing a page as soon as it is full. Then the last page on a level may be closed
  without a right neighbour ever appearing, and an empty open page is left behind.
  Close on "full and one more pair arrives".
- Sending the wrong key upward. The key that goes to the parent is the page's *low*
  key (its first pair's key), not its last key and not the key that caused the close.
  After the tail repair moves pairs between the last two pages, the low key of the
  last page has changed; sealing after the repair gets this right automatically.
- Forgetting the single-child case. With a full interior level followed by one more
  child, a naive loader produces an interior page with one child and no separator.
  The hand example above is exactly this case.
- Trusting the input. The loader cannot check sortedness later, and an unsorted input
  produces a tree in which searches silently miss keys. `add` rejects any key that is
  not greater than the previous one (`error.NotSorted`).
- Retrying after a failure. An `add` that returned `error.OutOfMemory` cannot be
  repeated: the load is gone and the loader answers `error.LoaderClosed`. Start again
  with a new loader.
- Loading at 100% and then inserting. See experiment 3.
- Comparing the write counts as if they were physical writes. They are pages dirtied
  per operation; see the note under experiment 2.
- Bulk loading into a non-empty tree. This loader builds a new tree. Merging sorted
  input into an existing tree is a different algorithm (DuckDB's structural merge is
  one answer; an LSM, chapter 27, is another).

## Exercises

1. (Easy) Load keys 1 to 10 with M = 4 at 100% by hand, as in the table above. How many
   pages are written, and what are the root's separators? Check with a test.
2. (Easy) With M = 16 and leaf fill 90%, the report shows 86% leaf fill. Explain the
   number, and say which fill factors between 50% and 100% give distinct trees.
3. (Medium) Write `Tree.minPagesFor(n)`: the smallest number of pages a tree of order M
   can use for n keys. Verify that a 100% bulk load reaches it for n = 10,000, M = 16.
4. (Medium) Make the loader behave like Postgres: write a page as soon as it is closed
   and do not repair the tail. What has to change in `validate` for the resulting
   trees to pass, and which searches still work?
5. (Hard) Implement the "rightmost split" policy from chapter 14 in `put` (when the
   overflowing leaf is the last leaf and the new key is the largest, leave the left
   page full and start a new page with one key) and add it to experiment 2. How close
   does ascending insert get to the bulk loader in pages, writes and reads?

Solutions are in [solutions.md](solutions.md).

## Links

- Previous: [chapter 15, redistribution and merge policies](../15-redistribution-and-merge-policies/README.md)
- Next: [chapter 17, key compression and deduplication](../17-key-compression-and-deduplication/README.md)
- Visualization: [viz/index.html](viz/index.html)
