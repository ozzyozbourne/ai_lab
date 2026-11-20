# Chapter 27: B-tree vs LSM-tree

## What you will learn

- How a log-structured merge tree (LSM-tree) works: memtable, sorted runs,
  levels, compaction, k-way merge and tombstones.
- What write, read and space amplification are, and how to measure them by
  counting blocks instead of timing anything.
- Why a B+tree pays for a write at once and an LSM-tree pays later, in bulk,
  and what that does to reads and to space.
- What the growth factor trades, what a Bloom filter per run does to
  lookups, and when each structure is the better choice.
- Where B-epsilon (buffered) trees sit between the two designs.

Prerequisites: chapter 07 (the B+tree whose code is reused here) and chapter 09
(pages and blocks). Chapter 16 (bulk loading) helps: a sorted run is a
bulk-loaded tree. Chapter 26 explains the arena used by the memtable.

## The idea in plain words

A B+tree keeps one sorted copy of the data and changes it in place. To insert
a key it finds the leaf where the key belongs, changes it, and writes that
whole block back: one block write per small change, at a position on the
device decided by the key.

An LSM-tree refuses to change anything in place.

1. A write goes into the **memtable**, a sorted structure in RAM. Nothing is
   read from the device and nothing is written to it.
2. A full memtable is **flushed**: written out once, in key order, as an
   immutable **sorted run**. The memtable starts again empty.
3. Runs pile up, so they are organised in **levels**. Level 0 collects flushed
   runs; each deeper level holds one larger run. A full level is merged into
   the next one: **compaction**. Each level may hold `growth` times as much
   as the level above; that number is the **growth factor**.
4. A **delete** cannot remove a key from an immutable run. It writes a
   **tombstone**: an entry that says "this key is gone". A tombstone hides
   every older version of the key below it.
5. A **point lookup** searches the newest place first (memtable, level 0
   from the newest run to the oldest, then level 1, 2, ...) and stops at the
   first place that knows the key, as a value or as a tombstone.
6. A **range scan** cannot stop early. The next key in order may be in any
   place, so it merges all of them.

Merging several sorted inputs into one sorted output is a **k-way merge**.
Compaction is a k-way merge written out as a new run; a range scan is one
that stops at the end of the range. Of several versions of a key only the
newest is kept: that is when an overwrite or a delete finally frees space.

The three costs have names:

| | Definition used in this chapter |
|---|---|
| Write amplification | entry slots written per entry the user wrote: blocks written by puts and deletes x slots per block / puts and deletes |
| Read amplification | blocks read by gets / gets |
| Space amplification | blocks on the device / `ceil(live keys / slots per block)`, the data blocks the live keys would fill if packed. "At the peak": the largest block count, divided by the keys live at that moment |

Ratios are rounded to two decimals.

A B+tree organises at write time. An LSM-tree postpones the work and does it
in batches.

## A worked example by hand

Both programs start with this trace. The B+tree has order M = 4: 3 entries
per leaf block. The LSM-tree has data blocks of 3 slots, index blocks of 4
first-keys, a memtable of 4 keys, 2 runs in level 0 and growth factor 2. `r`
and `w` are the blocks one operation read and wrote, index blocks included;
the next section says what is left out.

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
...
```

LSM column: the first four puts cost nothing. `put 12` finds the memtable
full, so `5 6 10 20` is flushed first: two data blocks and one index block.
`put 3` triggers the second flush (`7 12 17 30`). Level 0 now holds two runs,
its limit, so they are compacted: all six blocks are read, and the eight keys
are written as the level-1 run, three data blocks and one index block. That
one operation read 6 and wrote 3 + 4 = 7 blocks. Eight earlier writes had
cost nothing; this is their bill, and until then they existed only in RAM.

B+tree column: every put reads the path to its leaf and writes at least that
leaf before it returns. `put 3` splits a leaf and dirties four blocks: both
halves, the parent, and the right-hand neighbour, whose back link changes.

Three more puts follow (25, 1 and 15; the memtable then holds `1 3 15 25`).
The rest of the trace shows reads and deletes:

```
get 15      | btree r=3 w=0 | lsm r= 0 w= 0 | = 1500
get 12      | btree r=3 w=0 | lsm r= 2 w= 0 | = 1200
get 13      | btree r=3 w=0 | lsm r= 2 w= 0 | = none
delete 15   | btree r=3 w=1 | lsm r= 0 w= 3 | lsm: flush.
...
put 14      | btree r=3 w=1 | lsm r=10 w=11 | lsm: flush. lsm: compact level 0 into level 1.
get 15      | btree r=3 w=0 | lsm r= 3 w= 0 | = none
```

`get 15` is free for the LSM-tree: 15 is still in the memtable. `get 12` reads
the index block and one data block of the level-1 run. `get 13` reads the
same two blocks in vain: 13 lies inside that run's key range but is not in
it. `delete 15` writes a tombstone without looking for the key; the 3 writes
on its line are the flush of `1 3 15 25`, which the delete found full. The
last compaction merges `(1 3 15 25)`, `(11 13 ~15 20')` and level 1; it drops
the old 15, the old 20 and, because nothing lies below level 1, the tombstone
itself:

```
lsm compaction dropped 2 stale version(s) and 1 tombstone(s)
```

The new level-1 run has 13 slots in 5 data blocks. An index block holds 4
first-keys, so it needs 2 index blocks and a root above them: 8 blocks. A
lookup in that run now reads 3 blocks (root, index, data), which is what the
last `get 15` pays. A run is a small static tree, and it grows taller.

## The counting model, and what it leaves out

Both structures live on a **counted block device** (`device.zig`,
`device.rs`). It holds no bytes; it counts blocks read, written and
allocated. Only counts are printed, never timings.

One rule for both structures:

- **Every block an operation looks at is read, and every block it changed is
  written before it returns**, once at most per operation. That includes
  every index block, of the B+tree and of every run.
- **Same block size.** A data block holds M - 1 entries and an index block M
  first-keys, like a leaf and an internal node.
- **Free, in RAM, for both:** the B+tree's root handle; the LSM-tree's
  memtable and, per run, its smallest key, its largest key and the address of
  its root block. The root block itself is on the device; every probe reads
  it.

Read every number below with these five limits:

1. **No cache.** Real engines keep the upper levels of a B+tree, and the
   index blocks of runs, in a buffer pool (chapter 09). The row "data blocks
   per get" is the cost with every index block of either structure cached.
2. **No write-ahead log, and so not the same durability.** A B+tree `put` is
   on the device when it returns. An LSM `put` is in RAM only until the next
   flush: a crash loses the acknowledged writes to up to 60 keys in the
   benchmark configuration. Part of the LSM-tree's low write cost is that
   weaker promise. The row "+ 1 log block per LSM write" equalises it in the
   crudest way, as if each write wrote the last block of a log at once (no
   group commit). It is computed from the counts, not run.
3. **The B+tree's writes are an upper bound.** With a log and a buffer pool
   (chapter 21; textbook, not modelled) a hot page changed many times is
   written once per checkpoint.
4. **Bloom filters only in separate rows.** Without a filter, a lookup probes
   every run whose key range covers the key. Real LSM-trees rely on a **Bloom
   filter** per run, in RAM, that answers "certainly not here" for most
   absent keys (textbook; Milvus keeps one per segment, TigerBeetle none).
   That one feature decides the read comparison, so read amplification is
   printed twice: without filters, and measured on a second LSM-tree with a
   filter per run (10 bits of RAM per slot, 7 hash functions). The filter
   rows do not count that RAM.
5. **A block is a block.** One appended in sequence by a flush or a
   compaction counts the same as one written at a position chosen by the
   key. On real devices the two can cost differently; that is a textbook
   argument for LSM-trees and is not modelled. Also, whole levels are merged
   in one operation.

## Code walk-through

### Zig

`base_*.zig` is the B+tree of chapter 07; every change is marked `ch27:`.
The tree gets a `dev: Device` field and hooks: `touch(id)` wherever the
algorithms look at a node (one block read), `dirty(id)` wherever they change
one. Each operation ends with `dev.endOp()`, which writes each dirty block
once.

`memtable.zig` is a skip list (textbook) whose nodes come from an arena; see
"Allocator notes". A tombstone is a node with `value == null`.

`run.zig` holds `Run`, an immutable sorted array of slots, `Geometry`, which
says how many data and index blocks a run of n slots has (`indexHeight`,
`indexBlocks`), and `Builder`, which writes a run a block at a time.

`filter.zig` is the Bloom filter: a bit array of `slots x bits_per_key` bits.
`add` sets 7 bits per key and `mayContain` tests them; the positions come
from one 64-bit hash by double hashing (`h1 + i * h2`). A clear bit proves the
key was never added, so a filter never hides a key; it says "maybe" for about
1% of the absent ones. `Builder.finish` builds it in RAM from the keys just
written. `filter_bits_per_key = 0`, the default, means no filter.

`merge.zig` is the k-way merge. Inputs are added newest first, so an input's
number is its age. A binary min-heap orders the inputs by (current key, age);
`next` returns the top slot and skips every older version of the same key.
Each cursor charges the device as it enters a new data block, and for each
index block it newly moves under.

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
inputs. `get` asks each run's min/max keys, then its filter, and only then
reads blocks (`probe`).

### Rust

The Rust crate has the same files, names, tests and output. The differences:

- **Memtable.** Safe std Rust has no arena allocator. The skip list uses two
  `Vec`s as bump arenas: `nodes`, indexed by `u32`, and `towers`, which holds
  every node's links back to back. `reset` is two `clear()` calls.
- **Allocation failure.** Zig tests inject failures into the allocator. Rust
  gives the B+tree a node budget (`OutOfNodes`) and the LSM-tree a
  `slot_budget` checked by `Builder::new` (`OutOfMemory`).

### What the programs measure

Three seeded workloads run on a B+tree of order 16 and an LSM-tree with
15-slot blocks, a memtable of 60 keys, 4 runs in level 0 and growth factor 4.
A second LSM-tree with filters gets the same operations; it writes the same
blocks and differs only in what its gets read. The headline rows of the
insert-heavy table (90% puts of mostly new keys), without the lookup rows,
which come next; all rows and the printed limits are in
`expected_output.txt`.

```
                                              B+tree       LSM
  WRITE AMPLIFICATION (slots per entry)        19.45      8.39
    same, + 1 log block per LSM write          19.45     23.39
  most blocks written by one write                 8      1115
  blocks read per scan                          4.92      9.97
  SPACE AMPLIFICATION (at the end)              1.54      1.07
  SPACE AMPLIFICATION (at the peak)             1.54      2.14
```

Limits 1 to 5 apply to every row; "When to choose which" below reads them.

**Point lookups** depend on the filter and on how many gets ask for a key
that does not exist. Blocks per get, from the three tables:

| Workload | Gets for an absent key | B+tree | LSM, no filter | LSM, bloom filters | False-positive rate |
|---|---|---|---|---|---|
| insert-heavy | 941 of 947 (99%) | 3.81 | 9.42 | 0.10 | 0.81% |
| read-heavy | 4686 of 9588 (49%) | 4.00 | 10.96 | 1.86 | 0.94% |
| update-heavy | 290 of 1186 (24%) | 4.00 | 7.52 | 2.32 | 1.08% |

- **Without filters** the LSM-tree reads 1.9 to 2.7 times as many blocks as
  the B+tree. Each run is a tree of its own, and most probes are in vain:
  `3322 runs probed, 3316 of those without finding the key` (insert-heavy).
- **With filters** the result reverses in all three. An absent key costs
  nothing unless a filter gives a false positive (27 of those 3316 probes
  remain), and a present key costs one run's index path plus one data block.
- **Neither column is "the" answer.** The first leaves out a feature real
  LSM-trees rely on. The second leaves out its price, 10 bits of RAM per slot
  (107550 bits here), while the B+tree gets no RAM at all: with its index
  blocks cached it would read 1.00 block per get. The fewer lookups miss,
  the less a filter saves.

All three workloads report 0 answers that differ from the oracle.

The last table varies the growth factor (LSM-tree only; same rule, same
limits):

```
growth    levels   write amp   blocks per get   with filters   blocks per scan
2              5        8.11            10.80           0.13             11.48
4              3        8.39             9.42           0.10              9.97
8              2        9.80             8.57           0.12              9.15
16             2       11.28             8.20           0.09              8.76
```

A larger growth factor means fewer levels to search and more rewriting inside
each level. With filters the lookup column no longer shows it: nearly every
get here is for an absent key, and 0.09 to 0.13 is a few dozen false
positives. Scans still pay for every level.

## When to choose which

By these counts, within the five limits:

- **An LSM-tree fits when writes dominate.** It writes 8.39 slots per entry
  against 19.45, all in flushes and compactions, appended in sequence, which
  the count does not reward (limit 5). Part of that gap is the missing log:
  with one log block per write it is at 23.39 (limits 2 and 3). Data at rest
  is more compact too: packed runs (1.07) against partly empty leaves (1.54).
- **Its price** is RAM for filters if point lookups matter, and spare device
  space: a compaction holds its inputs and its output at once (2.14 at the
  peak). Overwrites and deletes add to it: the update-heavy workload ends at
  1.35 and peaks at 2.50, with 7409 stale versions and 1401 tombstones
  dropped on the way.
- **A B+tree fits when reads dominate**, above all short scans: 4.92 blocks
  against 9.97, because the LSM-tree merges every overlapping run and no
  filter helps. It also fits when every write should cost about the same
  (8 blocks at worst against 1115; pacing spreads the LSM-tree's work but
  does not remove it) and when the device has no room to spare.
- **A cache narrows the read gap for both**, and TigerBeetle counts on it
  (see below).

These are block counts from one small model, not measurements of an engine.
Trust the direction of each row more than its size.

## B-epsilon trees: the midpoint

Textbook material (usually credited to Brodal and Fagerberg, the name to
Bender and others; from memory, the papers were not opened). None of the
guide's code bases has one and there is no Zig or Rust code here, only a
small JavaScript model on the second visualization page.

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

So it batches writes like an LSM-tree and keeps one path per lookup like a
B-tree.

The page's model is one node with four leaves and a buffer of 2, 4, 8 or 16.
Two limits: the buffer is in RAM, so a buffered message is lost in a crash
while the B+tree beside it has every key on the device; and the node keeps 3
pivots whatever the buffer size, so the page shows the gain of a larger
buffer and not the taller tree that pays for it.

## In real databases

**TigerBeetle** stores all its state in a forest of LSM-trees and has no
B-tree (see `research/tigerbeetle.md`, section 0).

- *Why an LSM.* It is "particularly good at writes and TigerBeetle's workload
  is write-heavy" (`tigerbeetle/docs/ARCHITECTURE.md:384-387`).
- *Growth factor and levels.* The defaults are 7 levels and growth factor 8
  (`tigerbeetle/src/config.zig:162-163`). The comment on the constant states
  the trade-off measured above: a higher growth factor "increases write
  amplification ... but decreases read amplification", and read amplification
  "can be optimized more easily (with caching)"
  (`tigerbeetle/src/constants.zig:611-615`). The limits are asserted with
  their reasons: growth factor at most 16, "Limit excessive write
  amplification", and at most 10 levels, "Limit excessive read amplification"
  (`tigerbeetle/src/lsm/tree.zig:641-644`).
- *Tables, not whole levels.* A level is a set of tables; a table is one index
  block plus value blocks (`tigerbeetle/src/lsm/table.zig:41-44`). A
  compaction takes one table from level A and at most `lsm_growth_factor`
  overlapping tables from level B
  (`tigerbeetle/src/lsm/compaction.zig:55-61`), and the work is spread over
  "bars" of 32 beats by default (`tigerbeetle/src/config.zig:164`) so that
  "At the end of every beat, there is space in mutable table for the next
  beat" (`tigerbeetle/docs/internals/lsm.md:61`). Merging a whole level at
  once, as here, is simpler and produces the 1115-block spike.
- *Lookups and scans.* A lookup finds at most one table per level
  (`tigerbeetle/src/lsm/manifest.zig:428-432`). The research notes found no
  bloom filter in `src/lsm/`, only a TODO
  (`tigerbeetle/src/lsm/scan_tree.zig:831-833`). Range scans use a k-way
  merge (`tigerbeetle/src/lsm/k_way_merge.zig:1-5`).

**Milvus** looks similar and is not an LSM-tree
(`research/milvus_faiss.md`, section 9). Data is written to growing segments
that are sealed into immutable ones; deletes are recorded separately and
applied when compaction rewrites segments
(`milvus/internal/compaction/entity_filter.go:89-99`). But its segment levels
`L0`, `L1`, `L2` are kinds of segment, not sorted key levels
(`milvus/pkg/proto/data_coord.proto:27-32`), and there is no key order across
segments: finding a primary key means asking every segment's statistics, a
bloom filter plus `MinPK` and `MaxPK`
(`milvus/internal/storage/pk_statistics.go:32-34`). That is this chapter's
per-run min/max check and filter, without the levels.

## Allocator notes

**Memtable: an arena, reset on flush.** A memtable only grows, one small node
per new key, and then all nodes die together at the flush. `Memtable` owns a
`std.heap.ArenaAllocator`; `put` allocates the node and its tower from it and
`reset` calls `arena.reset(.retain_capacity)`, so the next memtable reuses the
same memory (a test checks that the capacity does not grow). A failed `put`
needs no cleanup: a half-made node is dead bytes until the next reset.

**Merge: fixed buffers.** The `Merger` keeps its cursors and its heap in
arrays of `max_sources = 32` entries inside the struct, and the `Builder`
keeps one block of 64 slots. A scan or a compaction needs no allocator while
it runs.

**Runs: everything reserved up front.** `Builder.init` makes the only
allocations of a flush or compaction: the slots, sized for the sum of the
inputs, and the filter's bits (`errdefer` frees the slots when the second
fails). If a reservation fails, nothing has been read or written.
`Filter.seal` later hands back the surplus with `resize`, which may refuse
but cannot fail. The tests inject failures (`checkAllAllocationFailures`,
`FailingAllocator`), with and without filters: a failed write changes no
answer, and the next write finishes the interrupted work.

**B+tree.** As in chapter 07. The device's pin table is a fixed array.

## Pitfalls

- **Dropping a tombstone too early.** If a tombstone is removed while an older
  value of the key still lies in a deeper level, the deleted key comes back.
  Drop tombstones only when the output of the merge is the deepest data.
- **Searching in the wrong order.** Newer data must always be found first.
  Merging two runs that are not adjacent in age breaks this.
- **Quoting a read number without its filter.** "LSM reads cost more" and
  "LSM reads cost less" are both in the table above. Say whether filters and
  a cache were on, and how many lookups missed.
- **Forgetting that a delete first costs space.** A tombstone is data until
  compaction reaches the bottom; a test deletes every key and finds the device
  as full as before.

## Exercises

1. (Easy) After the trace, how many blocks do `get 3`, `get 14`, `get 30` and
   `get 31` read on each structure? Decide from the dump in section 2 of the
   output.
2. (Easy) From the printed tables: with every index block cached, how many
   times as many blocks per `get` does the LSM-tree read as the B+tree in
   each workload? Compare with the uncached ratio.
3. (Medium) The read-heavy table prints 1.86 blocks per `get` with filters
   of 10 bits per slot. Predict what 5 and 20 bits per slot would give, and
   what a perfect filter (no false positives) would leave. Then set
   `bench_filter_bits` and measure.
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
