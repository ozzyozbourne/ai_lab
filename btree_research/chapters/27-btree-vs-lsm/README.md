# Chapter 27: B-tree vs LSM-tree

## What you will learn

- How a log-structured merge tree (LSM-tree) works: memtable, sorted runs,
  levels, compaction, k-way merge and tombstones.
- What write, read and space amplification are, and how to measure them by
  counting blocks instead of timing anything.
- Why a B+tree pays for a write at once and an LSM-tree pays later, in bulk,
  and what that does to reads and to space.
- What the growth factor of an LSM-tree trades.
- Where B-epsilon (buffered) trees sit between the two designs.

Prerequisites: chapter 07 (the B+tree whose code is reused here) and chapter 09
(pages and blocks). Chapter 16 (bulk loading) helps: a sorted run is a
bulk-loaded tree. Chapter 26 explains the arena used by the memtable.

## The idea in plain words

A B+tree keeps one sorted copy of the data and changes it in place. To insert
a key it finds the one leaf where the key belongs, changes it, and writes that
whole block back. One small change costs one block write, at a position on the
device decided by the key.

An LSM-tree refuses to change anything in place.

1. A write goes into the **memtable**, a sorted structure in RAM. Nothing is
   read from the device and nothing is written to it.
2. When the memtable is full it is **flushed**: written out once, in key order,
   as an immutable **sorted run**. The memtable starts again empty.
3. Runs pile up, so they are organised in **levels**. Level 0 collects flushed
   runs. Each deeper level holds one larger run. When a level is full, it is
   merged into the next one: **compaction**. Each level may hold `growth`
   times as much as the level above; that number is the **growth factor**.
4. A **delete** cannot remove a key from an immutable run. It writes a
   **tombstone**: an entry that says "this key is gone". A tombstone hides
   every older version of the key below it.
5. A **point lookup** searches the newest place first (memtable, then level 0
   from the newest run to the oldest, then level 1, 2, ...) and stops at the
   first place that knows the key, whether it finds a value or a tombstone.
6. A **range scan** cannot stop early. The next key in order may be in any
   place, so it merges all of them.

Merging several sorted inputs into one sorted output is a **k-way merge**.
Compaction is a k-way merge whose output is written as a new run; a range scan
is one that stops at the end of the range. When the same key appears in
several inputs, only the newest version is kept. That is the moment an
overwrite or a delete finally frees space.

The three costs have names:

| | Definition used in this chapter | B+tree | LSM-tree |
|---|---|---|---|
| Write amplification | entry slots written to the device per entry the user wrote | high: a whole block per entry | lower: entries travel in full blocks, but each is rewritten once or more per level |
| Read amplification | blocks read per point lookup | the height of the tree | for every run that might hold the key, the height of that run's own index plus one data block |
| Space amplification | blocks in use divided by the data blocks the live keys would fill if packed tightly | leaves are partly empty | old versions and tombstones wait for compaction; a compaction needs input and output at once |

A B+tree organises at write time. An LSM-tree postpones the work and does it
in batches.

## A worked example by hand

Both programs start with this trace. The B+tree has order M = 4, so a leaf
block holds 3 entries. The LSM-tree uses data blocks of 3 slots too, index
blocks of 4 first-keys, a memtable of 4 keys, 2 runs in level 0 and growth
factor 2. `r` and `w` are the blocks one operation read and wrote. Every block
counts, index blocks included; the next section says what is left out.

```
put 10      | btree r=0 w=1 | lsm r= 0 w= 0 |
put 20      | btree r=1 w=1 | lsm r= 0 w= 0 |
put 5       | btree r=1 w=1 | lsm r= 0 w= 0 |
put 6       | btree r=1 w=3 | lsm r= 0 w= 0 | btree: leaf split. btree: new root.
put 12      | btree r=2 w=1 | lsm r= 0 w= 3 | lsm: flush.
put 30      | btree r=2 w=3 | lsm r= 0 w= 0 | btree: leaf split.
put 7       | btree r=2 w=1 | lsm r= 0 w= 0 |
put 17      | btree r=2 w=1 | lsm r= 0 w= 0 |
put 3       | btree r=3 w=4 | lsm r= 6 w= 7 | btree: leaf split. lsm: flush. lsm: compact level 0 into level 1.
```

LSM column: the first four puts cost nothing. `put 12` finds the memtable
full, so the four keys `5 6 10 20` are flushed first: two data blocks (`5 6
10` and `20`) and one index block, three writes. Then 12 goes into the empty
memtable. `put 3` triggers the second flush (`7 12 17 30`, three more writes).
Level 0 now holds two runs, its limit, so they are compacted: all six blocks
are read, and the eight keys are written as the level-1 run, three data blocks
and one index block. That one operation read 6 and wrote 3 + 4 = 7 blocks.
Eight earlier writes had cost nothing; this is their bill. Until their flush,
those writes existed only in RAM.

B+tree column: every put reads the path to its leaf and writes at least that
leaf before it returns. `put 3` splits a leaf and dirties four blocks: both
halves, the parent, and the right-hand neighbour, whose back link changes.

The rest of the trace shows reads and deletes:

```
get 15      | btree r=3 w=0 | lsm r= 0 w= 0 | = 1500
get 12      | btree r=3 w=0 | lsm r= 2 w= 0 | = 1200
get 13      | btree r=3 w=0 | lsm r= 2 w= 0 | = none
delete 15   | btree r=3 w=1 | lsm r= 0 w= 3 | lsm: flush.
...
put 14      | btree r=3 w=1 | lsm r=10 w=11 | lsm: flush. lsm: compact level 0 into level 1.
get 15      | btree r=3 w=0 | lsm r= 3 w= 0 | = none
scan [5,14) | btree r=6 w=0 | lsm r= 6 w= 0 | = 5 6 7 10 11 12 13
```

`get 15` is free for the LSM-tree because 15 is still in the memtable. `get 13`
costs two blocks and finds nothing: 13 lies inside the key range of the level-1
run, so its index block and one data block are read in vain. `delete 15`
writes a tombstone without looking for the key. The last compaction merges
`(1 3 15 25)`, `(11 13 ~15 20')` and level 1; it drops the old 15, the old 20
and, because nothing lies below level 1, the tombstone itself:

```
lsm compaction dropped 2 stale version(s) and 1 tombstone(s)
```

The new level-1 run has 13 slots in 5 data blocks. One index block holds 4
first-keys, so it needs 2 index blocks and a root block above those: 8 blocks,
and the compaction wrote 3 + 8 = 11. From now on a lookup in that run reads 3
blocks (root, index, data), which is what the last `get 15` pays. A run is a
small static tree, and it grows taller as it grows.

## The counting model, and what it leaves out

Both structures live on a **counted block device** (`device.zig`,
`device.rs`). It holds no bytes. It counts blocks read, blocks written and
blocks allocated. Only counts are printed, never timings.

One rule for both structures:

- **Every block an operation looks at is read, and every block it changed is
  written before it returns**, once at most per operation.
- **That includes every index block.** A B+tree lookup reads one node per
  level. A run's index is a tree as well (first keys of the data blocks, first
  keys of those index blocks, and so on up to one root block), and a lookup in
  a run reads one block per index level plus the data block. A scan or a
  compaction reads each index block it passes under once.
- **Same block size.** A data block holds M - 1 entries and an index block M
  first-keys, like a leaf and an internal node.
- **Free, in RAM, for both:** the B+tree's root handle; the LSM-tree's
  memtable and, per run, its smallest key, largest key and root block.

What this leaves out. Read every number below with these four limits:

1. **No cache.** Real engines keep the upper levels of a B+tree, and the
   index blocks of runs, in a buffer pool (chapter 09). The tables split
   *index* from *data* blocks: "data blocks per get" is the cost if every
   index block of either structure were cached.
2. **No write-ahead log, and so not the same durability.** A B+tree `put` is
   on the device when it returns. An LSM `put` is in RAM only until the next
   flush: a crash loses up to 60 acknowledged writes in the benchmark
   configuration. Part of the LSM-tree's low write cost is that weaker
   promise. The row "+ 1 log block per LSM write" equalises it in the crudest
   way, as if each write appended to a log and wrote the log's last block at
   once (no group commit). It is computed from the counts, not run.
3. **The B+tree's writes are an upper bound.** With a log and a buffer pool
   (chapter 21; textbook, not modelled) a B+tree postpones page writes too: a
   hot page changed many times is written once per checkpoint.
4. **Simplified LSM.** Whole levels are merged in one operation, and there is
   no bloom filter.

The ratios, rounded to two decimals:

- write amplification = blocks written by puts and deletes x 15 slots /
  number of puts and deletes;
- read amplification = blocks read by gets / number of gets;
- space amplification = blocks on the device / `ceil(live keys / 15)`, the
  data blocks the live keys would fill if packed. "At the peak" divides the
  largest block count of the run by the keys live at that moment.

## Code walk-through

### Zig

`base_*.zig` is the B+tree of chapter 07. Every change is marked `ch27:`.
The tree gets a `dev: Device` field and four hooks:

```zig
pub fn touch(self: *BPlusTree, id: NodeId) void {
    const kind: device.Kind = if (self.nodes.get(id).isLeaf()) .data else .index;
    self.dev.pin(id.index(), kind);
}
pub fn dirty(self: *BPlusTree, id: NodeId) void {
    self.dev.markDirty(id.index());
}
```

`touch` is called wherever the algorithms look at a node, `dirty` wherever they
change one, and `allocNode` / `freeNode` replace the arena calls. Each
operation ends with `dev.endOp()`, which writes each dirty block once. `get`
takes `*BPlusTree`, not `*const`, because a read changes the counters.

`memtable.zig` is a skip list (textbook) whose nodes come from an arena; see
"Allocator notes". A tombstone is a node with `value == null`.

`run.zig` holds `Run`, an immutable sorted array of slots, `Geometry`, which
says how many data and index blocks a run of n slots has (`indexHeight`,
`indexBlocks`), and `Builder`, which writes a run a block at a time. The
builder's only allocation is made in `init`, sized for the worst case, so a
merge that has started cannot fail.

`merge.zig` is the k-way merge. Inputs are added newest first, so an input's
number is its age. A binary min-heap orders the inputs by (current key, age);
`next` returns the top slot and skips every older version of the same key,
counting them in `shadowed`. The cursors and the heap are fixed arrays inside
the `Merger`; a merge allocates nothing. Each cursor charges the device as it
enters a new data block, and for each index block it newly moves under.

`lsm.zig` ties these together. All device writes of the LSM-tree happen in
`maintain`, which runs before each `put` or `delete`:

```zig
fn maintain(self: *Lsm, gpa: Allocator) Allocator.Error!void {
    while (self.pendingCompaction()) |n| try self.compact(gpa, n);
    if (self.mem.count < self.cfg.memtable_entries) return;
    try self.flush(gpa);
    while (self.pendingCompaction()) |n| try self.compact(gpa, n);
}
```

`compact` decides whether tombstones may be dropped (`deepestLevel() <= from +
1`: nothing older lies below the output), merges, and only then frees the
inputs. `put` returns nothing, unlike the B+tree's: finding the old value
would cost a read, and not reading is the point.

`validate` checks that every run is sorted with correct min/max keys, that
level 0 and the memtable are within their limits, that no compaction is
pending, and that the device's block count equals the blocks of all runs.
`bench.zig` applies one operation stream to both structures and the oracle and
records the counter difference around each operation.

### Rust

The Rust crate has the same files, names, tests and output. The differences:

- **Memtable.** Safe std Rust has no arena allocator. The skip list uses two
  `Vec`s as bump arenas: `nodes`, indexed by `u32`, and `towers`, which holds
  every node's links back to back. `reset` is two `clear()` calls.
- **Allocation failure.** Zig tests inject failures into the allocator. Rust
  gives the B+tree a node budget (`OutOfNodes`) and the LSM-tree a
  `slot_budget` checked by `Builder::new` (`OutOfMemory`).
- **Borrows.** `Lsm::get` cannot call a `&mut self` method while iterating
  over the runs, so `probe` is a free function taking `&mut Device` and
  `&mut Stats`. `LeafWalker` borrows the tree mutably, because stepping to
  the next leaf counts a read.

### What the programs measure

Three seeded workloads run on a B+tree of order 16 and an LSM-tree with
15-slot blocks, a memtable of 60 keys, 4 runs in level 0 and growth factor 4.
The insert-heavy one (90% puts of mostly new keys), with the limits the
program prints under every table:

```
                                              B+tree       LSM
write operations (put + delete)                10824     10824
  blocks written                               14032      6053
  blocks written per write                      1.30      0.56
  WRITE AMPLIFICATION (slots per entry)        19.45      8.39
    same, + 1 log block per LSM write          19.45     23.39
  blocks read per write                         3.90      0.49
  most blocks written by one write                 8      1115
point lookups (get)                              947       947
  READ AMPLIFICATION (blocks per get)           3.81      9.42
    index blocks per get                        2.81      5.91
    data blocks per get                         1.00      3.51
short scans                                      229       229
  entries returned per scan                    11.09     11.09
  blocks read per scan                          4.92      9.97
blocks on the device at the end                 1107       767
  data blocks if the live keys were packed       719       719
  SPACE AMPLIFICATION (at the end)              1.54      1.07
most blocks on the device at any moment         1107      1367
  live keys at that moment                     10770      9556
  data blocks if those were packed               718       638
  SPACE AMPLIFICATION (at the peak)             1.54      2.14
...
Limits of these numbers (ratios are rounded to two decimals):
  * No cache. Each operation reads every block it looks at from the device, index
    levels included, in both structures. "data blocks per get" is what is left if
    every index block of either structure is held in RAM.
  * No write-ahead log, and so NOT the same durability. A B+tree write is on the
    device when it returns. An LSM write is in RAM only until the next flush: up to 60
    writes are lost in a crash. The "+ 1 log block" row is computed, not run: it adds
    one block per LSM write, the price of the same promise without group commit.
  * A B+tree with a log and a buffer pool writes a hot page once for many updates,
    so its write column is an upper bound.
```

Reading it:

- **Writes.** The B+tree writes 1.30 blocks per write (a leaf, plus splits)
  and reads 3.90 first. The LSM-tree writes 0.56 blocks per write, all of it
  in flushes and compactions: 8.39 slots per entry against 19.45.
- **That gap is partly a weaker promise.** With one log block per write the
  LSM-tree is at 23.39, above the B+tree. Real engines land in between: with
  group commit many writes share one log block, and a B+tree with a log
  writes less too (limit 3). Neither is modelled.
- **The spike.** The largest single write cost the B+tree 8 blocks and the
  LSM-tree 1115, because this model merges a whole level in one operation.
- **Reads.** The LSM-tree reads about two and a half times as many blocks per
  lookup (9.42 against 3.81). Each run it probes is a tree of its own; the
  level-3 run costs 4 blocks per probe, as much as the whole B+tree. With every index block
  cached the B+tree would read 1.00 block per get and the LSM-tree 3.51.
- **Wasted probes.** The program also prints `3322 runs probed, 3316 of those
  without finding the key`: a min/max check cannot tell that a key inside the
  range is missing. A **bloom filter** per run answers "certainly not here"
  from a few bits per key in RAM and removes most of these probes. This
  chapter's code has none.
- **Space.** The B+tree's leaves are partly empty (1.54). The LSM-tree's runs
  are packed (1.07 at the end), but a compaction needs its inputs and its
  output at once: at its peak the device held 1367 blocks for 9556 live keys,
  2.14 times their packed size.

The update-heavy workload (overwrites and deletes over 4000 keys) shows the
other side of space: the LSM-tree ends at 1.35 and peaks at 2.50, and
compaction dropped 7409 stale versions and 1401 tombstones along the way. All
three workloads report 0 answers that differ from the oracle. The full output
is in `expected_output.txt`.

The last table varies the growth factor (LSM-tree only; same rule, same
limits):

```
growth    levels       write amp  blocks per get blocks per scan   peak blocks
2              5            8.11           10.80           11.48           825
4              3            8.39            9.42            9.97          1367
8              2            9.80            8.57            9.15          1534
16             2           11.28            8.20            8.76          1164
```

A larger growth factor means fewer levels to search and more rewriting inside
each level.

## B-epsilon trees: the midpoint

This section is textbook material (the trade-off is usually credited to
Brodal and Fagerberg and the name B-epsilon tree to Bender and others; quoted
from memory, the papers were not opened for this guide). None of the guide's code bases contains
one, and there is no Zig or Rust code for it here; the second visualization
page has a small JavaScript model.

A B-epsilon tree is a B-tree in which every internal node also holds a
**buffer** of pending changes, called messages. An insert or delete becomes a
message in the root's buffer. When a buffer is full, the messages for one
child are moved down together into that child's buffer, or applied if the
child is a leaf. A lookup walks one root-to-leaf path as in a B-tree and
checks the buffer of each node on the way; the newest message for the key
wins.

The name comes from how a node of B slots is divided: about B^epsilon slots
for pivots and the rest for the buffer. With epsilon = 1 the node is all
pivots, which is a B-tree. With a small epsilon the node is nearly all buffer:
batches are large, the fan-out is small and the tree is taller. Textbook
bounds: an insert costs about (log_B N) / (epsilon * B^(1 - epsilon)) block
transfers amortised, and a lookup about (log_B N) / epsilon.

It is a midpoint: it batches writes like an LSM-tree and keeps one path per
lookup like a B-tree.

The page's model has one node with four leaves. In a scratch run of that model
(5000 puts of uniformly random keys from 0 to 99), the block I/O per message
was 2.41 with a buffer of 2, 1.46 with 4, 0.82 with 8 and 0.44 with 16. A
B+tree with the same root in RAM uses 2. With a buffer of 2 the batches are
too small to pay for the extra write of the node.

## In real databases

**TigerBeetle** stores all its state in a forest of LSM-trees and has no
B-tree (see `research/tigerbeetle.md`, section 0).

- *Why an LSM.* The architecture document says it is "particularly good at
  writes and TigerBeetle's workload is write-heavy"
  (`tigerbeetle/docs/ARCHITECTURE.md:384-387`).
- *Growth factor and levels.* The defaults are 7 levels and growth factor 8
  (`tigerbeetle/src/config.zig:162-163`). The comment on the constant states
  the trade-off measured above: a higher growth factor "increases write
  amplification ... but decreases read amplification", and 8 is chosen "rather
  than the more typical growth factor of 10"
  (`tigerbeetle/src/constants.zig:611-615`). Level i may hold
  `growth_factor^(i+1)` tables (`tigerbeetle/src/lsm/tree.zig:656-661`), and
  the limits are asserted with their reasons: growth factor at most 16, "Limit
  excessive write amplification", and at most 10 levels, "Limit excessive read
  amplification" (`tigerbeetle/src/lsm/tree.zig:641-644`).
- *Tables, not whole levels.* A level is a set of tables; a table is one index
  block plus value blocks (`tigerbeetle/src/lsm/table.zig:41-44`). A run in
  this chapter is a whole level, so its index needs several levels. A
  compaction takes one table from level A and at most `lsm_growth_factor`
  overlapping tables from level B
  (`tigerbeetle/src/lsm/compaction.zig:55-61`). Merging a whole level at once,
  as here, is simpler and produces the 1115-block spike.
- *Compaction pacing.* Compaction is scheduled by commit number, in "bars" of
  `lsm_compaction_ops` beats (32 by default,
  `tigerbeetle/src/config.zig:164`), with the invariant "At the end of every
  beat, there is space in mutable table for the next beat"
  (`tigerbeetle/docs/internals/lsm.md:44-61`). The work is spread over the
  operations instead of landing on one.
- *Move table.* If the chosen table overlaps nothing in the next level, only
  its metadata changes (`tigerbeetle/docs/internals/lsm.md:111-120`). This
  chapter's LSM-tree has no such shortcut.
- *Lookups and scans.* A lookup finds at most one table per level
  (`tigerbeetle/src/lsm/manifest.zig:428-432`). The research notes found no
  bloom filter in `src/lsm/`, only a TODO
  (`tigerbeetle/src/lsm/scan_tree.zig:831-833`). Range scans use a k-way
  merge built as a loser tree (`tigerbeetle/src/lsm/k_way_merge.zig:1-5`);
  this chapter uses a binary heap.

**Milvus** looks similar and is not an LSM-tree
(`research/milvus_faiss.md`, section 9). Data is written to growing segments
that are sealed into immutable ones; deletes are recorded separately and
applied when compaction rewrites segments
(`milvus/internal/compaction/entity_filter.go:89-99`). But the segment levels
are not sorted key levels: `L0` is "contains delta data", `L1` a "normal
segment" and `L2` a "segment with extra data distribution info"
(`milvus/pkg/proto/data_coord.proto:27-32`). There is no key order across
segments: finding a primary key means asking every segment's statistics, a
bloom filter plus `MinPK` and `MaxPK`
(`milvus/internal/storage/pk_statistics.go:32-34`). Milvus shares the
ingredients (immutable runs, tombstones, compaction, per-run min/max and
filters) without the levelled key structure.

## Allocator notes

**Memtable: an arena, reset on flush.** A memtable only grows, one small node
per new key, and then all nodes die together at the flush. `Memtable` owns a
`std.heap.ArenaAllocator`; `put` allocates the node and its tower from it and
`reset` calls `arena.reset(.retain_capacity)`, so the next memtable reuses the
same memory (a test checks that the capacity does not grow). A failed `put`
needs no cleanup: a half-made node stays in the arena as dead bytes until the
next reset. With a general-purpose allocator every node would need its own
`free`, and a flush would have to walk the list to release it.

**Merge: fixed buffers.** The `Merger` keeps its cursors and its heap in
arrays of `max_sources = 32` entries inside the struct, and the `Builder`
keeps one block of `max_block_entries = 64` slots. A comptime assertion checks
that the memtable, the level-0 runs and the levels fit into 32 inputs. A scan
or a compaction needs no allocator while it runs.

**Runs: one allocation each**, reserved in `Builder.init` for the sum of the
inputs. That makes compaction all-or-nothing: if the reservation fails,
nothing has been read or written. The tests use `checkAllAllocationFailures`
and a `FailingAllocator` to check that a failed write changes no answer and
that the next write finishes the interrupted maintenance.

**B+tree.** Unchanged from chapter 07. The device adds no allocation; its pin
table is a fixed array of 128 entries.

## Pitfalls

- **Dropping a tombstone too early.** If a tombstone is removed while an older
  value of the key still lies in a deeper level, the deleted key comes back.
  Drop tombstones only when the output of the merge is the deepest data.
- **Searching in the wrong order.** Newer data must always be found first:
  memtable, level 0 from newest to oldest, then deeper levels. Merging two
  runs that are not adjacent in age breaks this.
- **Freeing inputs before the output is complete.** A crash or an allocation
  failure in between would lose data. Build the new run, install it, then
  free the old ones. The price is space for both at once.
- **Comparing unlike things**: a cached B-tree with an uncached LSM-tree, a
  run index held in RAM with tree nodes read from the device, or a durable
  write with one that is still only in RAM.
- **Reading "blocks written per write" as latency.** The LSM-tree's average is
  low and its worst case is enormous unless compaction is paced.
- **Forgetting that a delete first costs space.** A tombstone is data until
  compaction reaches the bottom; a test deletes every key and finds the device
  as full as before.

## Exercises

1. (Easy) After the trace of section 1, how many blocks do `get 3`, `get 14`,
   `get 30` and `get 31` read on each structure? Decide from the dump in
   section 2 of the output before you check.
2. (Easy) From the printed tables: with every index block cached, how many
   times as many blocks per `get` does the LSM-tree read as the B+tree in
   each workload? Compare with the uncached ratio.
3. (Medium) The read-heavy workload prints how many probes were wasted.
   Assume a perfect filter per run that never sends a lookup to a run without
   the key. How many blocks per `get` would remain? What does a real bloom
   filter add to that?
4. (Medium) Insert 10800 keys in ascending order into both structures with the
   benchmark configuration. Predict the B+tree's space amplification and say
   whether the LSM-tree's write amplification improves. Then measure.
5. (Hard) Run the insert-heavy workload with `l0_runs` set to 1, 2, 4 and 8.
   Explain the direction in which write amplification and blocks per `get`
   move.

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [chapter 26, allocators, handles and static memory](../26-allocators-handles-and-static-memory/README.md)
- Next: [chapter 28, radix trees and hash indexes](../28-radix-trees-and-hash-indexes/README.md)
- Visualizations: [B+tree and LSM-tree side by side](viz/index.html) and
  [a buffered (B-epsilon) node](viz/bepsilon.html)
