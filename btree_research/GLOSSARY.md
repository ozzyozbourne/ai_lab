# Glossary

Terms used across the 30 chapters of "Understanding B-trees, from simple to complex", in
alphabetical order. Each entry says how the guide uses the word and links the chapter(s)
that introduce it. Where real systems use different words for the same thing, the entry
says so; the table below collects the most common cases.

Chapter 13 has code but no README yet; its entries follow `PLAN.md` and the chapter's
source, and link to the planned path.

## Same thing, different words

| This guide | Postgres | Turso (SQLite format) | Others |
|---|---|---|---|
| page | page, block (`BlockNumber`) | page | DuckDB and TigerBeetle say block, but their blocks are not B-tree lookup pages |
| slot | line pointer, item id (`ItemIdData`, 4 bytes) | cell pointer (2 bytes) | |
| cell | index tuple, item | cell | "record" is the encoded row inside a cell |
| locator | TID / heap TID (block + slot, 6 bytes) | rowid (64-bit key of the table tree) | DuckDB: row id |
| separator | pivot tuple; on the page itself: high key | divider (cell in the parent) | textbook: separator, router, fence |
| interior node | internal page | interior page | inner node |
| leaf chain | left-link and right-link on every level | none on disk | |
| latch | lightweight lock, buffer content lock | not needed: single writer | |
| free list | free space map (FSM) of recyclable pages | freelist of trunk and leaf pages | DuckDB free list, TigerBeetle free set |
| metapage | metapage (block 0) | database header (first 100 bytes of page 1) | DuckDB: two alternating headers; TigerBeetle: superblock |
| checkpoint | checkpoint | checkpoint (WAL frames copied back) | |

## A

**2-3-4 tree.** A B-tree of order 4: every interior node has 2, 3 or 4 children. It is the
guide's default tree (M = 4) and corresponds one to one to a red-black tree. [03]

**Adaptive radix tree (ART).** A radix tree whose nodes come in four sizes (Node4, Node16,
Node48, Node256) and which stores a run of non-branching bytes once, as a prefix. DuckDB's
index is an ART. [28]

**Amortised cost.** Cost averaged over a long sequence of operations. A tree with N keys
took fewer than N / (ceil(M/2) - 1) splits to build, so a split is rare per insert. [04]

**Append fast path.** When the cell that does not fit is the last cell of the rightmost
leaf, give it a fresh page and leave the old page full, instead of balancing. Turso's
`balance_quick`. [15]

**Arena.** Memory that is handed out by bumping an offset and is freed all at once. Also the
single array in which chapter 07 keeps all nodes, addressed by handle. [03] [07]

**`ArenaAllocator`.** Zig's arena: bump allocation in chunks taken from a child allocator;
`deinit` or `reset` frees everything together. Used for per-operation and per-query
scratch. [03] [26]

## B

**B-epsilon tree.** A B-tree in which every internal node also holds a buffer of pending
changes (messages) that are pushed down in batches. The midpoint between a B-tree and an
LSM-tree. [27]

**B-link tree.** Lehman and Yao's B-tree variant: every node has a high key and a right
link, and splits only move keys right, so a search can repair a stale path by moving
right. Postgres nbtree is one. [20]

**B-tree.** A balanced search tree with several sorted keys per node and one more child
than keys, all leaves on one level. In the plain form every key is stored once, with its
value, in a leaf or an interior node. [03]

**B\*-tree.** The textbook idea of looking at siblings before allocating: redistribute
first, and split two full pages into three. [15]

**B+tree.** A B-tree in which every entry lives in a leaf; interior nodes hold only
separators and child links, and the leaves can be chained. [07]

**Balance routine.** One routine that pools the cells of up to three adjacent siblings and
cuts the pool again; depending on the page count out it is a split, a redistribution or a
merge. Turso's `balance_non_root`. [15]

**Binary search tree (BST).** One key and two children per node. Used in chapter 01 to show
why two children per node cost about log2(n) page reads. [01]

**Block.** Same as page in Postgres. In DuckDB and TigerBeetle a block is a much larger
storage unit and not a lookup page. In chapter 27 it is the unit the counted block device
reads and writes. [01] [09] [27]

**Block tree.** A static, pointer-free search tree whose node is one cache line of 8 keys,
so a search touches one line of keys per level. [25]

**Bloom filter.** A small per-run summary that can say "this key is certainly not here",
so a point lookup skips runs that cannot hold the key. [27]

**Borrow.** Repairing an underfull node by rotating one key through the parent: the
separator moves down, the sibling's nearest key moves up. Also called rotation or
redistribution. [05]

**Bottom-up deletion.** Postgres: before splitting a full leaf with no hinted entries, ask
the table which entries on this one page are dead and remove them. [24]

**Bottom-up loader.** See bulk loading.

**Bottom-up splitting.** Insert into the leaf first, then repair upwards along the
remembered path. What this guide, Postgres and Turso do. [04] [12]

**Bounds matrix.** The nine combinations of unbounded, included and excluded range ends,
reduced to four kinds of seek (`ge`, `gt`, `le`, `lt`). [08]

**Branchless search.** A binary search whose loop runs a fixed number of times and whose
comparison only selects a value (the "halving" search). Whether it is branchless is a
property of the machine code, not of the source. [25]

**`BrkAllocator` (`brk_allocator`).** Zig allocator that grows the program break, for
single-threaded builds; `wasm_allocator` is an alias of it in 0.17.1. [26]

**Buddy allocator.** Serves power-of-two sizes from one region by halving blocks, and on
free glues a block back to its other half (its buddy) when that is free too. [26]

**Buffer pool.** A fixed set of page-sized frames in memory plus a page table; `fetch`
returns a pinned frame, reading the page from the file on a miss. [09]

**`BufferFirstAllocator`.** Zig allocator that uses a fixed buffer first and a fallback
allocator when the buffer is full. Used for keys of unknown size. [11] [26]

**Bulk loading.** Building a tree bottom-up from sorted input: fill leaves left to right
to the fill factor and hand one (first key, page id) pair per finished page to the level
above. Every page is written once. [16]

**`BumpAllocator`.** The hand-written allocator of chapter 03: a buffer and an offset. [03]

**Byte-comparable key.** A key encoding designed so that comparing the encoded bytes as
unsigned bytes gives the logical order; the tree then needs no schema. DuckDB's ART keys
work this way. [11]

## C

**`c_allocator`.** libc `malloc` and `free` behind Zig's allocator interface. [26]

**Cache line.** The 64-byte unit in which memory reaches the CPU cache. Chapter 25 counts
distinct lines the way chapter 01 counts distinct pages. [25]

**Cell.** One record inside a slotted page: lengths, key bytes, value bytes (or a child
page id in an interior page). Postgres says index tuple or item. [10] [12]

**Cell pointer.** Turso's name for a slot. See slot.

**Centroid.** A representative point chosen by k-means; an IVF index stores each vector in
the list of its nearest centroid. [29]

**`checkAllAllocationFailures`.** Zig test helper that reruns a function once per
allocation, failing from that allocation on. Used to test every insert path under
out-of-memory. [04]

**Checkpoint.** Copying logged pages to the main file, syncing it, and then emptying the
log. In DuckDB and TigerBeetle a checkpoint is also the moment after which freed blocks
become reusable. [22] [23]

**Checksum.** A value stored with a page that lets a reader notice a torn or corrupted
page. It detects damage; it does not repair it. [21]

**Checksum chain.** Each log record's checksum also covers the checksum of the record
before it, so a record is valid only if everything before it is. Turso seeds each WAL
frame's checksum with the previous frame's. [22]

**CLOCK eviction.** A hand sweeps the frames in a circle: pinned frames are skipped, a set
referenced bit is cleared (second chance), a clear one marks the victim. [09]

**Clustered table.** The whole row is the value in the primary-key tree, so the tree is the
table. Turso's rowid table. [18]

**Commit.** The single instant at which an operation takes effect: the commit record
reaching disk (WAL) or the metapage write (copy-on-write). [22] [23]

**Commit record.** The small log record that ends an operation's records; recovery redoes
only operations that have one. Turso marks the last frame of a transaction instead. [22]

**Compaction (LSM).** Merging a full level into the next one and writing the result as a
new run. This is when overwritten and deleted entries finally free space. [27]

**Compaction (page).** Sliding every cell to the end of a slotted page so that all free
bytes become one gap. Slot numbers stay; offsets change. [10]

**Comparator-based key.** Keys stored in a compact format and compared by decoding the
columns with knowledge of the schema. Postgres and Turso work this way. [11]

**Composite key.** A key made of several columns, sorted by the first, then the second, and
so on. Equality on a leading prefix plus a range on the next column is one range of the
index. [11] [18]

**Convoy.** Threads queuing behind a thread that is itself only waiting for a latch. Not a
deadlock, but it can close the whole tree for a while. [19]

**Copy-on-write (COW).** A page reachable from a committed root is never modified; a change
writes new versions of the pages on the path into free pages. [23]

**Copy-up.** A leaf split in a B+tree: a copy of the right half's first key goes to the
parent, and the entry stays in the leaf. Compare push-up. [07]

**Cost model.** The cost of an operation is the number of different pages it touches. The
guide counts page reads, never timings. [01]

**Counted block device.** The in-memory device of chapter 27 that counts block reads and
writes, so the LSM-tree and the B+tree are measured in the same unit. [27]

**Coverage assert.** A test counts how often each interesting branch ran and fails if a
count is zero, so "no failures" cannot mean "never got there". [06]

**Covering scan.** A scan that needs only columns present in the index key and so never
follows a locator. Also called index-only scan. [18]

**Cursor.** The thing that walks a range scan: a position in the tree that can step to the
neighbouring entry. See leaf-link cursor and stack cursor. [08]

## D

**Dead entry.** An index entry whose row version fails the visibility test for every open
and future snapshot ("dead to everyone"). It is garbage that hint bits, deletion passes and
VACUUM remove. [24]

**`DebugAllocator`.** Zig's older checking allocator, deprecated in favour of
`SafeAllocator`. [26]

**Deduplication.** Turning several leaf tuples with the same key into one posting-list
tuple. As in Postgres it is lazy: it runs only when a full leaf would otherwise split. [17]

**Depth.** The code's name for level minus 1: the root has depth 0. The prose always says
level. [03]

**Directory.** The small sorted array with one slot per chunk in the one-level structure of
chapter 01. Stacking directories on directories is what builds a tree. [01]

**Dirty.** A frame whose page was modified in memory and not yet written to the file. It
must be written before the frame is reused. [09]

**Divider.** Turso's (SQLite's) word for the separator cell in the parent between two
siblings. [15]

**Double write.** A torn-write defence: write the page to a reserved second location and
sync, then write it in place. A complete copy exists at every moment. [21]

**Downlink.** The entry in a parent that points to a child: the separator plus the child's
handle or page id. [20] [24]

## E

**Epoch.** A value of the transaction counter kept as a timestamp. A deleted page is
stamped with one and may be recycled when the horizon has reached it. [24]

**Eviction.** Choosing a cached page to drop so that its frame can hold another page. [09]

**Exclusive latch.** See shared and exclusive.

**Eytzinger layout.** A sorted array stored in breadth-first order of its implicit search
tree, so the lines a search will touch next are predictable and can be prefetched. [25]

## F

**`FailingAllocator`.** `std.testing.FailingAllocator`: a wrapper that lets N allocations
succeed and fails every later one. Aims an out-of-memory at one step of an operation. [05]
[06]

**Fan-out (fanout).** The number of children a node actually has. Higher fanout means a
shorter tree. [01]

**Fast root.** Postgres: the lowest single-page level of the tree, recorded in the metapage
so that searches can start there after mass deletion left the top levels as single
pages. [12]

**Fault injection.** Making allocations or disk writes fail on purpose, at chosen steps, to
test the error paths. [06] [21]

**Fence keys.** Copies, stored on a page, of the separators that bracket it in its parent
(low fence and high fence). Postgres stores only the upper one, the high key. [17]

**Fill factor.** The target fullness of a page, as a percentage of its capacity: where to
stop when bulk loading, and how much to leave on the left when the rightmost page splits.
It is a target, not a bound. [14] [16]

**`FixedBufferAllocator`.** Zig bump allocator over a caller-supplied buffer; no system
calls, `OutOfMemory` when the buffer is full. [01] [26]

**Fragment.** A sliver of 1 to 3 free bytes in a slotted page, too small to describe
itself; only counted. [10]

**Frame.** One page-sized slot of memory in the buffer pool. [09]

**Frame (WAL).** Turso: one log entry holding a whole page plus a header with page number,
commit marker, salts and checksum. [21] [22]

**Free block.** A hole of 4 bytes or more left in a slotted page by a deleted cell; its
first bytes hold the offset of the next free block and its own size. Turso says
freeblock. [10]

**Free list.** A list of reusable slots or pages. In memory: each free slot stores the
handle of the next one. On disk (chapter 13, as in the SQLite format): a chain of trunk
pages, each an array of free page ids. [07] [13]

**Freeze.** The moment after start-up from which a static allocator refuses every further
allocation. [26]

**fsync.** The call after which every earlier write to the file is durable. Until it
returns, any subset of the writes may vanish or be torn. [21]

**Full-page image.** A log record that contains a whole page. Postgres logs one for the
first change to a page after a checkpoint; chapter 22's log uses only these. [21] [22]

## G

**Galloping search.** Exponential search: probe at growing distances from a known position,
then binary search inside the bracket. Good when the answer is near that position. [02]

**Gap.** The unused bytes of a slotted page between the slot array and the lowest cell. [10]

**Generation.** A number in the log header that goes up at every reset, so that old records
left behind in a reused log file are rejected. (The generation counter of a slab handle in
chapter 26 is a different thing: it detects stale handles.) [22] [26]

**Growth factor.** How many times larger each LSM level may be than the one above.
TigerBeetle targets 8. [27]

## H

**Half-dead page.** Postgres page deletion, phase 1: the page's downlink is removed from
the parent, but the page is still linked to its siblings. [24]

**Half-open range.** A range that includes its start and excludes its end, written
`[a, b)` or `keys[a..b]`. [02]

**Handle.** A small integer that names a node instead of a pointer: an index into the node
array (chapter 07), or a (class, slab id, slot) triple packed into 32 bits (chapter 26).
It stays valid when memory moves, and it is what an on-disk tree stores as a page id. [07]
[26]

**Hash index.** An index that hashes the whole key to a home slot in an array. It answers
"is this exact key here?" and nothing else: no order, no ranges. [28]

**Heap (table).** Rows stored in a pile of pages in arrival order and never moved; a row is
named by its address (TID). Postgres's layout. Not the heap of a memory allocator. [18]

**Height.** The number of levels of a tree, which is the number of page reads for one
lookup. A single leaf has height 1 (CLRS would say 0). [01] [03]

**High key.** An upper bound on the keys a node may hold, stored in the node. In chapter 20
it is exclusive; in Postgres it is inclusive and is item 1 of every non-rightmost page. [20]

**Hint bit.** One bit on an index entry saying "this version is dead to everyone", set by a
scan that found out. Postgres: `LP_DEAD`. [24]

**HNSW.** A graph index for vectors: every vector gets a random top level and links to a
few near neighbours per level; search moves greedily to a closer neighbour and drops a
level at a local minimum. Approximate. [29]

**Home slot.** The array position a key's hash points to. [28]

**Horizon.** The oldest snapshot any reader still holds, or the current counter value if
there are none. Every clean-up step is justified by a comparison against it. [24]

## I

**Imaginary page.** The full page with the new cell already in its sorted place: slightly
too long, and every gap between two cells is a candidate split point. [14]

**Incomplete split.** A split whose step 1 (new right sibling linked in) is done and whose
step 2 (downlink in the parent) is not. A flag on the left node (`INCOMPLETE_SPLIT`,
Postgres `BTP_INCOMPLETE_SPLIT`) marks it, and the next writer that meets it finishes the
split. [20]

**Index-only scan.** See covering scan.

**Insertion index.** The position where an absent key must be inserted to keep the array
sorted. It is the lower bound. [02]

**Interior node.** A node with children. Also internal node (Postgres), interior page
(Turso), inner node. [03]

**Invariant.** A structural promise that must hold after every operation (key order, fill,
all leaves on one level). `validate` checks invariants as code. [03] [06]

**IVF (inverted file).** A vector index with one level: k-means centroids as an unordered
root and one flat list per centroid. A search scans the `nprobe` nearest lists. [29]

## K

**k-way merge.** Merging several sorted inputs into one sorted output. Compaction and LSM
range scans are k-way merges. [27]

**Key.** What entries are sorted and looked up by. Part I uses `u64` keys; on-disk chapters
use byte strings. Compare separator: a key belongs to an entry, a separator only routes. [03]
[07]

## L

**Latch.** A short-lived lock on an in-memory structure (a node, a page), held for one step
of one operation, with deadlock avoided by a fixed acquisition order. Compare lock. [19]

**Latch coupling.** To move from a node to its child, latch the child first, then release
the parent. Also called crabbing. Textbook; Postgres does not do it. [19]

**Leaf.** A node without children. In a B+tree all entries live in leaves. [03]

**Leaf chain.** Links from each leaf to its neighbours, giving a sorted list of all
entries. Postgres links every level in both directions; Turso has no sibling links; a
copy-on-write tree cannot have them. [07] [23]

**Leaf-link cursor.** A cursor whose position is (leaf, index) and which leaves a leaf by
following its `next` or `prev` link. [08]

**Level.** Counted from the top, starting at 1: the root is on level 1. (Postgres numbers
levels from 0 at the leaves.) [03]

**Level (LSM).** A tier of runs; level 0 collects flushed runs and each deeper level is
larger by the growth factor. [27]

**Line pointer.** Postgres's name for a slot: 4 bytes holding offset, state and length. See
slot. [10]

**Linear probing.** Hash-table collision handling: a key whose home slot is taken goes into
the next free slot. [28]

**Load factor.** Keys divided by slots in a hash table; kept low so that probes stay
short. [28]

**Locator.** What an index entry carries to lead back to its row: the primary key (rowid)
in a clustered layout, the TID in a heap layout. Stored as the last part of the index
key. [18]

**Lock.** Protection of a logical thing (a row, a key range) on behalf of a transaction,
held until the transaction ends and managed by a lock manager. Compare latch. [19]

**Lower bound.** The number of elements smaller than the key: the index of the first
element `>=` key, and the insertion index. [02]

**LSM-tree.** Log-structured merge tree: writes go to a memtable, which is flushed as
immutable sorted runs that compaction merges level by level. Nothing is changed in
place. [27]

**LSN (log sequence number).** The position of a record in the log. In chapter 22 a
counter that is never reused. [22]

## M

**Median.** The middle key of an overfull node; in a classic B-tree split it moves up into
the parent. [04]

**`MemoryPool`.** Zig pool for one item type: a free list threaded through freed items,
O(1) create and destroy. Used for the nodes of the pointer-based trees. [04] [26]

**Memtable.** The sorted in-memory structure that receives LSM writes until it is full and
flushed. [27]

**Merge.** Repairing an underfull node by combining it, one sibling and the separator
between them into one node; one node is freed and the parent loses a key. [05]

**Metapage.** The fixed starting point of the file (page 0): magic number, format version,
root page id, counters. In the copy-on-write tree it has two checksummed slots written
alternately. [12] [23]

**Minimisation.** Shrinking a failing operation sequence to a short one that still fails in
the same way. [06]

**Minimum fill.** Every non-root node holds at least ceil(M/2) - 1 keys. An invariant in
the textbook tree; in real engines a policy, measured in bytes. [03] [15]

**Minus infinity.** The value of a key part that is absent: the ignored first key of an
interior page, and the truncated suffix or TID of a separator. It sorts below every real
value. [16] [17]

**Miss / hit.** A fetch that finds its page in a frame is a hit; one that must read the
file is a miss. [09]

**Model test.** Run the same operations on the tree and on an obviously correct structure
(the oracle, a sorted array) and compare every answer. [03] [06]

**Move right.** In a B-link tree: on arriving at a node whose high key is not above the
search key, follow the right link and look again. [20]

**`MultiArrayList`.** Zig container that stores each field of a struct in its own array
(struct of arrays). [25]

**MVCC (multi-version concurrency control).** Never change a row in place: an update writes
a new version, and each reader sees the versions its snapshot allows. [24]

## N

**Node.** One unit of the tree: a struct in Part I, a slotted page from chapter 12 on. [03]

**Node budget.** The Rust code's stand-in for allocation failure: a limit on the number of
nodes, with `Err(OutOfNodes)` when it is exceeded. [04]

**Node4, Node16, Node48, Node256.** The four ART node layouts, named after their child
capacity. A node that overflows is replaced by the next size; nothing cascades. [28]

**`nprobe`.** The number of IVF lists a search scans. Raising it trades work for
recall. [29]

## O

**Optimistic descent.** Readers take no latch: they note a node's version counter, read,
and retry if the version changed. Textbook; described and visualised, not implemented. [19]

**Oracle.** The simple reference structure of a model test. [03] [06]

**Order (M).** The maximum number of children of a node (Knuth's definition). A node holds
at most M - 1 keys. CLRS's minimum degree t and Bayer and McCreight's k describe the same
trees with other parameters. [01] [03]

**Overflow (node).** A node that holds one key or cell too many (overfull) and must split
or be balanced. [04]

**Overflow cell.** Turso: a cell that did not fit and is kept in an in-memory list on the
page until `balance` has made room. [04] [30]

**Overflow page, overflow chain.** Pages that hold the tail of one value too large for a
leaf cell, linked from the cell and from page to page. Postgres nbtree has none and caps a
tuple at a third of a page. [13]

## P

**Page.** A fixed-size block of the file (4096 bytes in the guide and by default in Turso,
8192 in Postgres); the unit of reading, writing and caching, and one tree node. [01] [09]

**`page_allocator`.** Zig allocator that maps whole pages from the operating system, one
system call each way. [01] [26]

**Page id.** A page's number in the file; the on-disk form of a pointer. Postgres:
`BlockNumber`. [09]

**Page table.** The hash table of the buffer pool that says which page sits in which
frame. [09]

**Pager.** The layer that turns a page id into a byte offset and reads or writes whole
pages. [09]

**Path compression.** In a radix tree, storing a run of bytes with no branching once, as a
prefix, instead of as a chain of one-child nodes. [28]

**Path copying.** The copy-on-write update: a changed leaf needs a new parent pointing to
it, and so on up to a new root; everything off the path is shared. [23]

**Pending-free list.** Pages freed by a copy-on-write transaction that may not be reused
yet, because an older snapshot or the previous meta slot can still reach them. [23]

**Pin.** A count on a frame that says someone is using the page; a pinned frame is never
reused for another page. Fetch pins, the caller unpins. [09]

**Pivot.** Postgres's word for a tuple that only routes: a separator in an internal page
or a high key. See separator. [17]

**Point lookup.** A search for one exact key. [27]

**Posting list.** One leaf tuple that stores a key once followed by the sorted TIDs of all
rows with that key. [17]

**Predecessor.** The largest key of the subtree left of a key. Deleting from an interior
node overwrites the key with its predecessor and deletes that from its leaf. [05]

**Prefetch.** Asking for a cache line before it is known to be needed. [25]

**Prefix compression.** Storing the bytes shared by all keys of a page once. Textbook only
in this guide; none of the six codebases' B-trees does it. [17]

**Prefix scan.** "All keys starting with p" expressed as the range from p to the next
prefix. [08]

**Push-up.** An internal split: the middle separator itself moves to the parent and is not
kept below. Compare copy-up. [07]

## R

**Radix tree.** A tree in which the bytes of the key choose the path; no stored key is
compared with the search key, and depth is bounded by key length. [28]

**Range scan.** Seek to the first entry of a range, step to the neighbour repeatedly, stop
at the first entry past the far bound. [08]

**Read amplification.** Blocks read per lookup. [27]

**Recall.** The fraction of the true k nearest neighbours that an approximate index
returned. [29]

**Record.** A row encoded compactly: per column a small type code and only as many bytes as
the value needs. [11]

**Recycle.** Putting a deleted page on the free list for reuse, which is safe only when no
reader can still arrive at it. Postgres calls such a page recyclable. [13] [24]

**Red-black tree.** A balanced binary search tree with red and black nodes; every 2-3-4
tree is one in disguise. [03]

**Redistribution.** Moving cells between siblings without changing the page count. See
borrow and balance routine. [15]

**Redo.** Applying logged changes again during recovery. With full page images it is
idempotent: doing it twice gives the same page. [22]

**Referenced bit.** A per-frame bit set on every fetch; all the history CLOCK keeps. [09]

**Re-seek.** After the tree changed, a cursor throws away its physical position and seeks
again by the key it saved. [08]

**Reserved tail.** Bytes at the end of a slotted page that the page never touches, for
example for a checksum. Postgres's special space plays this role. [10]

**Resumable state machine.** A function that can return "need I/O" at any read and be
called again from the top, keeping its progress in a state enum instead of local
variables. Turso's B-tree code is written this way. [30]

**Right link.** The handle or page id of the next node on the same level. [20]

**Root.** The node without a parent. A B-tree grows (root split) and shrinks (root shrink)
only at the root. On disk the root keeps its page id: its content is pushed down into a
new child. [03] [04] [05] [12]

**Root flip.** The copy-on-write commit: one small metapage write makes the new root the
current one. [23]

**Rowid.** Turso's 64-bit key of a table B+tree, and so the locator in its indexes. Chapter
07 uses "row id" for any unique row identifier used as a tie-breaker. [07] [18]

**Run.** See sorted run.

## S

**Safe node.** A node that has room for one more key. When a latch-coupling writer latches
a safe child it may release all latches above it. [19]

**`SafeAllocator`.** Zig's checking general-purpose allocator; `std.testing.allocator` is
one. It fails a test on a leak and aborts on a double free. [05] [26]

**Search-tree property.** Every key in the subtree below child i lies between the
separators on either side of that child. [03]

**Sector.** The unit a drive writes atomically in the guide's model (512 bytes; a page is
eight of them). [21]

**Seek.** Positioning a cursor at the first entry of a range by one descent from the
root. [08]

**Separator.** A key in an interior node that divides the key space between two children.
In a B+tree it is a signpost, not an entry: it may be stale, and it may be shortened. [01]
[07] [17]

**Shared and exclusive.** The two modes of a reader-writer latch: shared (S) for any number
of readers, exclusive (X) for one writer. [19]

**Sibling.** A neighbouring node on the same level; a direct sibling has the same
parent. [05]

**`SimDisk`.** The simulated disk of chapters 21 and 22: at a crash it drops, keeps or
tears each unsynced write. [21]

**Simple deletion.** Postgres: before splitting a full leaf, remove the entries whose hint
bit is set. [24]

**Size class.** A group of allocations of one size served by its own pool; leaves and
interior nodes are two classes. [26]

**Skip list.** A sorted linked list with express lanes chosen by coin flips. Explained in
chapter 29 as the ordered ancestor of HNSW. [29]

**Skip scan.** Using an index on (x, y) for a condition on y alone by seeking once per
distinct x. A sidebar. [08]

**Slab.** A block of memory cut into equal slots with one bit per slot that says "free".
DuckDB's `FixedSizeAllocator` and TigerBeetle's `NodePool` are slabs. [26]

**Slot.** In a slotted page, a 2-byte offset that says where one cell starts; slots are
kept in key order. Turso says cell pointer; Postgres says line pointer or item id.
Elsewhere "slot" means one position in a slab, a hash table or the two-slot
metapage. [10]

**Slotted page.** A page with a slot array growing from the front and cells growing from
the back, so variable-length cells can be binary-searched and inserted without moving
other cells. [10]

**`smp_allocator` (`SmpAllocator`).** Zig's general-purpose multi-threaded allocator with
per-thread free lists. Used by the concurrent chapters. [19] [26]

**Snapshot.** A reader's fixed view. In the copy-on-write tree it is a registered old root;
in MVCC it is the counter value noted when the reader started. [23] [24]

**Sorted run.** An immutable sorted file written by flushing a memtable or by
compaction. [27]

**Space amplification.** Blocks on the device divided by the blocks the live keys would
fill if packed. [27]

**Special space.** Postgres: an area at the end of a page owned by the access method;
nbtree keeps sibling links, level and flags there. [10]

**Split.** Repairing an overfull node by moving its upper half to a new right sibling and
giving the parent a separator between the two. [04]

**Split point.** The gap between two cells where a full page is cut. Choosing it is the
split policy: 50:50 by bytes, fill factor on the rightmost page, away from the middle of a
run of equal keys. [14]

**Stack cursor.** A cursor whose position is the whole root-to-leaf path; it needs no
sibling links. Turso's `PageStack`. [08]

**Stale separator.** A separator left in an interior node after the key it was copied from
was deleted. Still a correct signpost. [07]

**Static memory.** All memory is reserved during start-up and the allocator is then frozen,
so memory use cannot grow. TigerBeetle's `StaticAllocator`. [26]

**Struct of arrays.** Keeping each field in its own array so that a cache line of keys
contains only keys. [25]

**Subtree.** A child and everything reachable from it. [03]

**Suffix truncation.** Shortening a separator to the shortest prefix that still separates
the last key on the left from the first key on the right. [17]

**Swarm testing.** Letting each fuzz seed pick its own operation mix, key range and
length. [06]

## T

**TID (tuple identifier).** Postgres's address of a heap row: block number and slot number,
6 bytes. It is the locator and the tie-breaker of every index tuple. [17] [18]

**Tie-breaker.** A unique last part of the key (row id, TID) that makes entries with equal
user keys distinct and ordered. [07]

**Tombstone.** An entry that says "this key is gone". An LSM delete writes one, and it must
survive until no older version can lie below it. [27]

**Top-down splitting.** Splitting every full node on the way down so that a parent always
has room. A textbook alternative that does not carry over to variable-length keys. [04]
[12]

**Torn write.** A page that a crash left partly new and partly old, because a page is
larger than the unit the drive writes atomically. [21]

**Transaction id.** The next number from one counter, given to every write; row versions
and snapshots are compared by it. [24]

**Trunk page.** A page of the on-disk free list: a pointer to the next trunk and an array
of free page ids. The term is SQLite's. [13]

## U

**Underflow.** A node with fewer keys than the minimum (underfull). Repaired by borrow or
merge; many real engines tolerate it. [05] [15]

**Unique constraint.** Enforced by searching the index for the key without a locator
before inserting. [18]

**Unlink.** Postgres page deletion, phase 2: the left sibling's right link is made to skip
the half-dead page. [24]

**Upper bound.** The number of elements smaller than or equal to the key: the index of the
first element `>` key. [02]

## V

**VACUUM.** Postgres's background pass that removes every index entry whose version is dead
to the horizon and deletes pages that became empty. It does not shrink the tree by
merging. [24]

**Vacuum (slab).** Evacuating the emptiest slab by moving its nodes, which only handles
make possible. DuckDB's `FixedSizeAllocator` does this. [26]

**`validate`.** The checker every structure in the guide has: it walks the whole structure
and reports whether every invariant holds. [03] [06]

**`ValidationAllocator`.** `std.mem.ValidationAllocator`: a wrapper that asserts the
allocator interface contract, used around hand-written allocators. [26]

**Varint.** An integer written in 1 byte when small and more bytes when large. Used inside
records, never inside byte-comparable keys. [11]

**Version (row).** One state of a row under MVCC, with the transaction that created it
(`xmin`) and the one that ended it (`xmax`). [24]

**Version counter.** A number that goes up on every change, so that a holder of an old
position can detect the change. The tree-wide `version` of chapter 08; per-node in
optimistic descent. [08] [19]

## W

**WAL (write-ahead log).** A second file that receives the description of every change
before the main file does. [22]

**`wasm_allocator`.** See `BrkAllocator`.

**Write amplification.** Entry slots written to the device per entry the user wrote. [27]

**Write-ahead rule.** A page reaches the main file only after the log record describing
its change is durable. [22]

## X, Z

**`xmin`, `xmax`.** The transaction ids that created and ended a row version. [24]

**Z-order.** A total order on grid cells made by interleaving the bits of the coordinates.
Like every such order it separates some touching cells widely. [29]

**Zone map.** Per-chunk minimum and maximum of a column, tested before the chunk's rows are
read: the answer is always false, always true or maybe. DuckDB keeps them for every
column; Milvus's skip index is the same idea. [29]

[01]: chapters/01-why-btrees/README.md
[02]: chapters/02-searching-a-sorted-node/README.md
[03]: chapters/03-btree-structure-and-search/README.md
[04]: chapters/04-insertion-and-splitting/README.md
[05]: chapters/05-deletion-and-rebalancing/README.md
[06]: chapters/06-testing-a-btree/README.md
[07]: chapters/07-bplus-trees/README.md
[08]: chapters/08-range-scans-and-cursors/README.md
[09]: chapters/09-pages-and-the-buffer-pool/README.md
[10]: chapters/10-slotted-pages/README.md
[11]: chapters/11-key-and-record-encoding/README.md
[12]: chapters/12-disk-backed-bplus-tree/README.md
[13]: chapters/13-overflow-and-free-space/README.md
[14]: chapters/14-split-policies-and-fill-factor/README.md
[15]: chapters/15-redistribution-and-merge-policies/README.md
[16]: chapters/16-bulk-loading/README.md
[17]: chapters/17-key-compression-and-deduplication/README.md
[18]: chapters/18-indexes-in-a-database/README.md
[19]: chapters/19-latching-and-lock-coupling/README.md
[20]: chapters/20-blink-trees/README.md
[21]: chapters/21-durability-primitives/README.md
[22]: chapters/22-wal-and-crash-recovery/README.md
[23]: chapters/23-copy-on-write-btrees/README.md
[24]: chapters/24-mvcc-vacuum-and-page-deletion/README.md
[25]: chapters/25-cache-conscious-search-and-layout/README.md
[26]: chapters/26-allocators-handles-and-static-memory/README.md
[27]: chapters/27-btree-vs-lsm/README.md
[28]: chapters/28-radix-trees-and-hash-indexes/README.md
[29]: chapters/29-zone-maps-and-vector-indexes/README.md
[30]: chapters/30-tracing-a-real-insert/README.md
