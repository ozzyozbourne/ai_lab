# 28. Radix trees and hash indexes

Previous: [27 B-tree vs LSM](../27-btree-vs-lsm/README.md) ·
Next: [29 Zone maps and vector indexes](../29-zone-maps-and-vector-indexes/README.md) ·
Visualization: [viz/index.html](viz/index.html)

## What you will learn

- How a radix tree finds a key without comparing two keys, and why its height depends
  on the key length instead of the number of keys.
- The adaptive radix tree (ART): four node layouts, how a node grows from one to the
  next, path compression, ordered iteration and lower-bound seek.
- A hash index: collisions, linear probing, the load factor, and the one thing it
  cannot do.
- Which questions each structure can answer (point lookup, range, prefix, ordered scan)
  and what a B-tree keeps that the other two give up.

Prerequisites: [chapter 02](../02-searching-a-sorted-node/README.md) (lower bound),
[chapter 08](../08-range-scans-and-cursors/README.md) (range scans, a prefix scan is a
range) and [chapter 11](../11-key-and-record-encoding/README.md) (byte-comparable keys).

## The idea in plain words

A B-tree node stores whole keys and asks "is my key smaller or larger than this one?"
several times per node. The two structures of this chapter avoid that question.

A **radix tree** uses the key itself as the route. The first byte of the key picks a
child, the second byte picks again, and after the last byte you are standing on the
value. No stored key is ever compared with the search key. Two consequences:

- The number of steps is at most the key length in bytes. A tree with a thousand 8-byte
  keys and a tree with a billion are both at most 8 levels deep.
- Children are ordered by byte value, so a depth-first walk, smallest byte first,
  visits the keys in byte order. A radix tree is an ordered index, provided byte order
  is the order you want. That is what the encodings of chapter 11 are for.

The naive version wastes space. If every node is an array of 256 child pointers, a node
with two children wastes 254 slots, and a key that shares no bytes with any other key
still needs one node per byte. The **adaptive** radix tree fixes both:

- *Adaptive nodes.* A node comes in four sizes. It starts as a Node4 and is copied into
  the next size when it overflows.
- *Path compression.* A run of bytes with no branching is stored once, as a prefix,
  instead of as a chain of one-child nodes.

A **hash index** goes further in the same direction. It runs the whole key through a hash
function and uses the result as a position in an array of slots: the key's *home slot*.
Two keys can have the same home slot. That is a *collision*, and the second key then
goes into the next free slot (*linear probing*, worked through below). In a table that
is not too full a lookup reads one or two slots, whatever the key length and however
many keys there are. The price is that the hash function scatters neighbouring keys on
purpose. The index can answer "is this exact key here?" and nothing else.

### The four layouts

| Layout | Children | How a byte finds its child |
|---|---|---|
| Node4 | up to 4 | scan up to 4 sorted key bytes |
| Node16 | up to 16 | scan up to 16 sorted key bytes |
| Node48 | up to 48 | `index[byte]` gives a position in a 48-entry child array |
| Node256 | up to 256 | `children[byte]` |

Node4 and Node16 keep their bytes sorted so that in-order iteration is a left-to-right
walk. Node48 and Node256 are ordered for free: iterate the byte value from 0 to 255.

A B-tree node that overflows *splits*: one node becomes two and a separator moves into
the parent, which can overflow in turn. An ART node that overflows is *replaced by a
bigger node*. The parent only stores a new reference. Nothing cascades.

## A worked example by hand

Insert the strings `romane`, `romanus`, `romulus` in that order. Each string gets a
`0x00` terminator (shown as `\x00`), for a reason explained under Pitfalls.

**romane.** The tree is empty, so the whole key becomes one prefix node (it holds up to
7 bytes, and `romane\x00` is exactly 7) pointing at the value:

```
prefix "romane\x00" -> leaf 1
```

**romanus.** Walk the prefix: `r o m a n` match, then the stored byte is `e` and the new
key has `u`. The prefix is split at that position. The shared head `roman` stays, a
Node4 is created for the two bytes that differ, and what is left of each key hangs below:

```
prefix "roman" -> node4 [2]
  'e' -> prefix "\x00" -> leaf 1
  'u' -> prefix "s\x00" -> leaf 2
```

**romulus.** The prefix `roman` now mismatches at its fourth byte (`a` against `u`). Split
again: head `rom`, a new Node4 with children `a` and `u`. The old tail `n` keeps the
subtree that was already there:

```
prefix "rom" -> node4 [2]
  'a' -> prefix "n" -> node4 [2]
    'e' -> prefix "\x00" -> leaf 1
    'u' -> prefix "s\x00" -> leaf 2
  'u' -> prefix "lus\x00" -> leaf 3
```

Looking up `romanus\x00` now visits five nodes: prefix `rom`, Node4 (byte `a`), prefix
`n`, Node4 (byte `u`), prefix `s\x00`, and arrives at leaf 2. Looking up `romantic` fails
at the second Node4: there is no child for `t`.

For growth, insert 256 two-byte keys `'k', b` with every possible `b`. They all branch
at one node below the prefix `k`. It is a Node4 from the 2nd key, is copied into a
Node16 at the 5th, into a Node48 at the 17th and into a Node256 at the 49th (section 2
of the output, and the second preset of the visualization).

### Three keys with one home slot

Now the hash index, with 8 slots. The hash function of this chapter (FNV-1a) sends
`ant`, `fox` and `emu` all to slot 6, and `bee` to slot 7:

```
slot       0    1    2    3    4    5    6    7
put ant    .    .    .    .    .    .   ant   .    home slot 6 is empty
put fox    .    .    .    .    .    .   ant  fox   6 is taken: next slot
put emu   emu   .    .    .    .    .   ant  fox   6 and 7 are taken: wrap around to 0
```

Keeping collided keys in the slot array itself is *open addressing*; the walk from the
home slot is the *probe sequence*. `get emu` reads slots 6, 7 and 0: three probes.
`get bee` starts at 7 and finds `fox`, which is in its way although their home slots
differ. It goes on to `emu` in slot 0 and then to slot 1, which is empty. An insert of
`bee` would have taken the same walk and used that slot, so `bee` is absent. Two things
follow:

- Every unsuccessful search ends at an empty slot, so the table must never fill up.
  Long before that it gets slow, because runs of taken slots grow and merge. The
  *load factor* (keys divided by slots) is therefore kept low: this code doubles the
  table before it would exceed 70%.
- A slot cannot simply be emptied. Empty slot 7 and `get emu` stops there (exercise 4).

A test in each language ("the hand example") checks this layout and the probe counts.

## Code walk-through

Both programs (`zig build run` in `zig/`, `cargo run` in `rust/`) print
[expected_output.txt](expected_output.txt); a test in each language checks that.

| File (Zig / Rust) | Contents |
|---|---|
| `keys.zig` / `keys.rs` | big-endian `u64` keys, escaped and terminated string keys, FNV-1a |
| `art.zig` / `art.rs` | the adaptive radix tree and its iterator |
| `hash_index.zig` / `hash_index.rs` | open addressing with linear probing |
| `sorted_index.zig` / `sorted_index.rs` | sorted array with binary search (the baseline) |
| `scenario.zig` / `scenario.rs` | the fixed scenario that produces the output |

The sorted array stands in for the B-tree: for the questions the programs ask, a
B+tree behaves like a sorted array cut into pages.

### Zig

**References and leaves.** A `Ref` is a tagged union: `none`, `leaf: u64`, or a pointer
to one of five node types. A leaf is not a node: the value sits inside the reference.
The key is stored nowhere in one piece; the path spells it.

**Lookup** (`Art.lookup`) is a loop over three cases. At a prefix node, the next bytes of
the key must equal the stored bytes. At an inner node, `childOf(ref, key[depth])` picks
the child. At a leaf, the key is found if it has been consumed completely. The nodes
visited are counted; that is the cost figure of the comparison.

**Insert** (`Art.insertAt`) is recursive and returns the reference that the parent must
store. Usually that is the node it was given. When a node grew or a prefix was split it
is a different node, and the parent overwrites one field, which keeps every structural
change local. The cases:

- Empty tree: `newChain` turns the rest of the key into prefix nodes ending in a leaf.
- Leaf: the key exists, overwrite the value.
- Prefix: compare byte by byte. On a mismatch call `splitPrefix`, otherwise recurse.
- Inner node: if a child exists for the byte, recurse into it. Otherwise build a chain
  for the rest of the key, `grow` the node if it is full, and `addChild`.

`splitPrefix` handles four shapes, depending on whether the shared head and the old tail
are empty.

**Failure atomicity.** Every path allocates first and modifies last. `insertAt` builds
the new chain, then grows the node, and only then links the chain in; `errdefer` frees
the chain if growing fails. The test "allocation failure at every point leaves the tree
unchanged" fails each allocation index in turn.

**Iteration** (`Iterator`). There are no sibling links between leaves, so the iterator
keeps a stack with one frame per inner node on the current path: the node and the next
byte value to try. `nextChild(ref, from)`, the first child with a byte greater than or
equal to `from`, is the only layout-specific operation it needs. `seek(lo)` positions
the iterator on the first key greater than or equal to `lo`: at each prefix it decides
whether the whole subtree is smaller than `lo` (skip it), greater (take all of it) or
still undecided (continue down).

**`validate`** checks node invariants (sorted bytes, the Node48 `index`, counts), that
the number of leaves equals `len`, and that the nodes reachable from the root are
exactly the nodes the pools consider live.

**Hash index.** `probe` is the walk of the hand example: from `hash & (capacity - 1)` to
the key or to the first empty slot. `put` doubles the table before the load factor
would exceed 70%, and growing re-places every entry, because the home slot depends on
the capacity. `scanRange` is the honest implementation of a range query on a hash
table: visit every slot, filter, and leave the sorting to the caller.

### Rust

The same functions with snake_case names, and the same tests. Differences:

- **Indices instead of pointers.** `Ref::N4(u32)` is an index into a `Slab<Node4>`, a
  `Vec` plus a free list of indices; one slab per node type mirrors the five Zig pools.
- **Operations live on the tree.** A Zig `Ref` contains the pointer, so `childOf(ref,
  byte)` is a free function. A Rust node is reached through the tree, so `child_of` and
  its relatives are methods on `Art`.
- **Node budget instead of allocation failure.** Rust's `Vec` aborts when memory runs
  out, so `Art::with_node_budget(n)` models the failure: `put` returns
  `Err(ArtError::OutOfNodes)` when a node would exceed the budget, and the matching
  test runs every budget from 0 upward. Nothing else can fail in Rust, so the six Zig
  tests that inject allocation failures into the hash index, the sorted index,
  `encodeStr`, the oracle and the ART iterator have no twin.
- **The iterator lends.** `Iter::next` returns an `Entry` whose key borrows the
  iterator's own buffer, which `std::iter::Iterator` cannot express, so it is an
  inherent method. The borrow checker enforces what Zig only documents: the tree
  cannot be modified while an iterator exists.

### What the programs print

Section 3 stores 1000 integer keys twice, as 8 big-endian bytes. The dense keys 0..999
share their first six bytes (one prefix node), differ in the seventh (a Node4) and fill
the last byte (four Node256): 1004 of 1028 child slots are used. Random keys differ in
the first byte already, so the root is a Node256 and almost every key ends in a prefix
node holding its unshared tail: 1001 prefix nodes, 1248 of 2232 slots used. Either way
a lookup visits three or four nodes.

Section 4 loads 596 keys such as `cat/0042` into all three indexes (`...` marks lines
left out here):

```
...
point lookups (596 hits, 300 misses)
                found  steps  unit of a step
  sorted array    596   9219  whole-key comparison
  art             596   4823  node visited
  hash index      596   1702  slot probed
...
first 4 keys
  sorted array  ant/0273 ant/0310 ant/0334 ant/0348
  art           ant/0273 ant/0310 ant/0334 ant/0348
  hash index    bee/0557 cat/6589 cat/8700 dog/4053  (slot order)

what each index can answer
                point  range        prefix       ordered scan
  sorted array  yes    yes          yes          yes
  art           yes    yes          yes          yes
  hash index    yes    scan + sort  scan + sort  scan + sort
```

The step counts are counts of different things and must not be read as a speed ranking:
a whole-key comparison, a node visit and a slot probe have different costs. What the
output does show is the shape. The hash index needs about two probes per lookup (1702
for 896 lookups, in a table that is 58% full). Its first four keys in slot order belong
to three different tenants, which is the scattering at work, and it has to inspect all
1024 slots for the 113 keys that start with `cat/` (in the lines left out), which the
sorted array finds as a slice between two binary searches.

The sorted array and the ART have identical rows in the last table, which only asks
which questions can be answered. That does not make the ART a B-tree with fewer steps;
the end of the next section says what a B-tree keeps.

## In real databases

**DuckDB** has no B-tree. Its only built-in index type is an ART
(`duckdb/src/include/duckdb/execution/index/art/art.hpp:48`), and this chapter's code
follows its design:

- Four inner layouts with capacities 4, 16, 48 and 256
  (`base_node.hpp:166`, `:185`, `node48.hpp:27`, `node256.hpp:24`). Node4 and Node16 are
  one template with sorted key bytes (`base_node.hpp:17-33`).
- Child search in Node4 and Node16 is a plain loop over the key bytes
  (`base_node.hpp:72-82`). There are no SIMD intrinsics anywhere in the ART directory
  (checked with a search of the source). The original ART paper describes a SIMD
  comparison for Node16 (textbook, not verified here).
- Growing replaces the node and overwrites the parent's reference, which is passed by
  reference (`duckdb/src/execution/index/art/base_node.cpp:61-76`).
- Shrinking uses thresholds below the smaller capacity, so a node on a boundary does not
  flip on every insert and delete: Node256 shrinks at 36 or fewer children
  (`node256.hpp:25`), Node48 below 12 (`node48.hpp:29`), Node16 below 4
  (`base_node.cpp:142-153`). Exercise 5 adds delete.
- A prefix is a separate node type holding up to `prefix_count` bytes, a count byte and
  one child (`prefix.hpp:18-29`). `prefix_count` depends on the key type
  (`art.cpp:1258-1287`); for one 8-byte integer column it is 7, hence `prefix_cap` = 7
  here. Longer runs chain several prefix nodes (`prefix.cpp:57-69`).
- A leaf is a row id stored inside the node pointer (`leaf.cpp:16-21`). Strings are
  escaped and terminated as in `keys.zig`
  (`duckdb/src/execution/index/art/art_key.cpp:20-49`).
- Lookup walks prefixes and inner nodes without full-key comparisons
  (`art_operator.hpp:25-61`). The iterator keeps a stack of nodes and bytes
  (`iterator.cpp:312-348`).
- Each node type has its own fixed-size allocator (`art.cpp:120-135`), the slab
  allocator of [chapter 26](../26-allocators-handles-and-static-memory/README.md).

Left out here: duplicate keys (nested trees behind a "gate"), delete, bulk build,
serialization and locking (`research/duckdb.md`, sections 6, 10, 12, 15, 16).

**Postgres** ships a hash index next to its B-tree, and states the trade-off in its
access method tables: the hash method declares `amcanorder = false`
(`postgres/src/backend/access/hash/hash.c:77`) where the B-tree declares
`amcanorder = true` (`postgres/src/backend/access/nbtree/nbtree.c:131`). The hash method
also sets `amcanunique = false` and `amcanmulticol = false` (`hash.c:83-84`). It is not
an open-addressing table but a set of buckets, each a chain of pages, that grows by
splitting one bucket at a time (`postgres/src/backend/access/hash/README:14-22`); its
entries store only the hash code (`README:36-37`).

That hash lookups take a constant expected number of probes is textbook material and
assumes a good hash function and a bounded load factor.

### B-tree, ART, hash index: what each gives up

The B+tree column is the tree of chapters 07 to 12, not one engine; the ART is DuckDB's.

| | B+tree | ART | Hash index |
|---|---|---|---|
| A node is | a disk page full of whole keys | a small node for one key byte | one slot |
| Steps to a key grow with | the logarithm of the key count, counted in pages | the key length in bytes | the load factor |
| Next key in order | same page, or the linked next leaf | another node somewhere else; no sibling links | an unrelated slot |
| A scan yields | keys with their values, in order | row ids in byte order; the rows are fetched one by one | nothing in order |
| Keys must have | a comparison function | a byte-comparable encoding (chapter 11) | equality and a hash |

An ART's nodes are small and scattered, so every level is a jump to a different place.
That suits memory and not disk, where a B-tree reads one page and finds many
neighbouring keys in it. DuckDB writes its ART to disk as whole allocator buffers at a
checkpoint (`art.cpp:1197-1218`), not as a tree of pages. Long keys make the tree deep: the 596 `cat/0042` keys above already need paths
of up to 7 nodes. A scan yields row ids, not data, and DuckDB abandons the index for a
table scan when more than 2,048 rows or 0.1% of the table match, whichever is larger
(`duckdb/src/function/table/table_scan.cpp:1015-1020`, `art.cpp:896-902`; see chapter
29). Its main job there is checking PRIMARY KEY and UNIQUE constraints
(`art.cpp:663-667`), which are point lookups.

The hash index gives up order altogether: ranges, prefixes, `min`, `max`, sorted
output. The B-tree is not the fastest at any single question here. It is the one
structure that answers all of them from pages on disk, with the data next to the keys.

## Allocator notes

The ART allocates five kinds of objects, each of one fixed size: prefix nodes and the
four inner layouts. That is the textbook case for **size-class pools**: the Zig code
uses one `std.heap.MemoryPool(T)` per node type (`Pools` in `art.zig`).

- *Why a pool per size.* Nodes are created and freed constantly as they grow. A pool
  keeps a free list of blocks of exactly its size, so a freed Node4 is the next Node4
  (test "a freed node is reused by its pool"). In one general-purpose allocator a freed
  Node4 block is useless to the Node48 that is wanted next.
- *Lifetime.* All nodes live exactly as long as the tree. `Art.deinit` calls `deinit`
  on the five pools and each releases its memory in bulk, without a tree walk.
- *The backing allocator* is passed to `Art.init` and must outlive the tree. Each pool
  asks it for chunks, not for single nodes.
- *What would go wrong with others.* An `ArenaAllocator` alone cannot give a single node
  back, so every outgrown Node4, Node16 and Node48 would stay allocated until the tree
  dies. A `FixedBufferAllocator` has the same problem plus a hard size limit. Plain
  `gpa.create` per node is correct, at the cost of one general allocation per node.
- *Leak checking.* Tests use `std.testing.allocator`. It cannot see a node that was
  dropped from the tree but never returned to its pool, because the pool still owns
  the memory; `validate` catches that by comparing reachable nodes with the pools'
  live counters.

The hash index owns one slot array, the sorted index an `ArrayList`, and each a copy of
every key; both use the general-purpose allocator directly. Iterators take their own
allocator for the stack and the key buffer.

Rust: one `Slab<T>` per node type, with a node budget standing in for allocation failure.

## Pitfalls

- **A key that is a prefix of another key.** Values live only at the end of a path. If
  `ab` and `abc` were both keys, the value of `ab` would need a home in the middle of
  the path to `abc`. The cure is an encoding in which no key is a prefix of another:
  fixed-width integers, or strings with a `0x00` terminator (with `0x00` and `0x01`
  inside the string escaped by a leading `0x01`, so the terminator stays unambiguous).
  Otherwise `put` returns `error.PrefixKey` and leaves the tree unchanged.
- **Byte order is the only order.** Little-endian integers, signed integers without a
  flipped sign bit, or case-insensitive text iterate in the wrong order. The encoding
  is wrong, not the tree.
- **Recursion depth follows key length.** `insertAt`, `census`, `validate` and `dump`
  recurse once per node, and a path can have one node per key byte. Long keys overflowed
  the stack (at 20,000 bytes in Rust, at some hundreds of thousands in Zig), so `put`
  refuses keys longer than `max_key_len` (512 bytes) with `error.KeyTooLong`. `lookup`
  and the iterator are loops.
- **Forgetting to store the returned reference.** `insertAt` returns a new reference
  when a node grows. Dropping it leaves the parent pointing at a freed node.
- **A lower bound is not a lookup.** `seek("rube")` must find `rubens` although the
  descent for `rube` fails. The three-way decision at each prefix node is where
  implementations go wrong.
- **Hash tables and deletion.** Emptying a slot cuts every probe sequence that passed
  through it, as in the hand example. Deletion needs tombstones or a backward shift
  (exercise 4).
- **A full hash table.** A search for an absent key in a full table never meets an
  empty slot and never ends. The load factor limit is not only about speed.

## Exercises

Solutions are in [solutions.md](solutions.md).

1. (easy) Insert `team`, `tea`, `ten` in this order, each with a `\x00` terminator. Draw
   the tree after each insert in the dump format used above. Which insert splits a
   prefix where the old tail is empty?
2. (easy) For each of the four layouts, how many array elements does a lookup of one
   byte read in the worst case? Why does Node48 use a 256-entry index of one-byte
   positions instead of 48 sorted key bytes?
3. (medium) Add `min` and `max` to the ART (the smallest and largest key with its value)
   without using the iterator. What single helper do you need besides `nextChild`?
4. (medium) Add `delete` to the hash index. First explain with a three-key example why
   setting the slot to empty is wrong, then implement either tombstones or backward
   shift deletion and extend `validate`.
5. (hard) Add `delete` to the ART with DuckDB's shrink thresholds (Node256 at 36 or
   fewer, Node48 below 12, Node16 below 4) and fold a Node4 with one remaining child
   into a prefix. Explain why the thresholds are lower than the capacities 48, 16, 4.

## Where next

Previous: [27 B-tree vs LSM](../27-btree-vs-lsm/README.md) ·
Next: [29 Zone maps and vector indexes](../29-zone-maps-and-vector-indexes/README.md) ·
Visualization: [viz/index.html](viz/index.html)
