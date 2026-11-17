# TigerBeetle research notes for "Understanding B-trees, from simple to complex"

Source studied: `/home/user/ai_lab/db_study/tigerbeetle`, shallow clone at commit `a2a3c70`.
All `file:line` references are relative to that checkout. Snippets are verbatim unless marked
"(abridged)".

Conventions used in these notes:

- **Verified** = read in the source at the cited line.
- **(derived)** = arithmetic I did from verified constants; not asserted anywhere in the source.
- **(unverified)** = from memory, not confirmed in this checkout.

Zig version caveat: the repo pins **Zig 0.16.0** (`zig/download.sh:5`,
`ZIG_RELEASE="0.16.0"`). The guide targets Zig 0.17.1. Idioms quoted here use 0.16 spellings
(for example `allocator.alignedAlloc(u8, .fromByteUnits(n), size)`, `std.mem.Alignment`,
`callconv(.@"inline")`, `@branchHint`, `std.heap.DebugAllocator`, `std.ArrayList` as the unmanaged
list, `pub fn main(init: std.process.Init)`). Re-check every one of them against 0.17.1 before
copying into guide examples.

---

## 0. Verdict: is there a B-tree in TigerBeetle?

### What it does

TigerBeetle stores all state in a **forest of LSM trees**, not B-trees. A case-insensitive search
for `b-tree|btree|b+tree|b+ tree` over `src/` and `docs/` (excluding clients and the changelog)
returns exactly one hit, and it is a comment regretting the absence of one:

### Where

- `src/lsm/tree_fuzz.zig:681-683`
- `docs/ARCHITECTURE.md:378-395` ("LSM" design decision)
- `docs/internals/lsm.md:1-35` (glossary and tables)

### Snippet

```zig
// A tree is a sorted set. The ideal model would have been an in-memory B-tree, but there isn't
// one in Zig's standard library. Use a SortedSegmentedArray instead which is essentially a stunted
// B-tree one-level deep.
```

### B-tree-like structures that do exist (each has its own section below)

| Structure | File | B-tree analogue |
|---|---|---|
| Table = 1 index block + N value blocks | `src/lsm/table.zig`, `src/lsm/schema.zig` | Static, bulk-loaded, 2-level B+tree (root + leaves), never updated in place |
| `SegmentedArray` / `SortedSegmentedArray` | `src/lsm/segmented_array.zig` | A B+tree leaf level with a flat array as the only internal node: split at midpoint, merge/borrow on underflow, half-full invariant |
| `ManifestLevel` | `src/lsm/manifest_level.zig` | An in-memory ordered index (key_max -> table) built from two segmented arrays |
| `NodePool` | `src/lsm/node_pool.zig` | The page allocator of a B-tree: fixed-size nodes, bitset free list |
| `binary_search.zig` | `src/lsm/binary_search.zig` | In-node search (lower/upper bound, branchless, prefetching) |
| `CompositeKey` | `src/lsm/composite_key.zig` | Secondary-index key = (field, primary key) packed into one integer |
| Grid + FreeSet + SuperBlock | `src/vsr/grid.zig`, `src/vsr/free_set.zig`, `src/vsr/superblock.zig` | Pager, free-page map, meta page of a copy-on-write B-tree |

### Teaching idea

Open the "LSM vs B-tree" chapter with this table. The point is that an LSM tree does not remove
the B-tree ideas; it redistributes them. The sorted-node, fan-out, split/merge, and page-allocator
ideas all reappear, but the on-disk part becomes immutable and the mutable part moves to RAM.

---

## 1. Concrete numbers (default production config)

### Where

- `src/config.zig:150-176` (`ConfigCluster` defaults), `src/config.zig:105`, `src/config.zig:258-268`
  (`test_min` overrides)
- `src/constants.zig:585-725`
- `src/lsm/tree.zig:639-680`

### Verified values

| Constant | Value | Reference |
|---|---|---|
| `block_size` | 512 KiB (524,288 bytes) | `src/config.zig:161` |
| `sector_size` | 4096, asserted | `src/constants.zig:493-495` |
| Block header (`vsr.Header`) | 256 bytes | `src/vsr/message_header.zig:72` |
| `lsm_levels` | 7 | `src/config.zig:162` |
| `lsm_growth_factor` | 8 | `src/config.zig:163` |
| `lsm_compaction_ops` (beats per bar) | 32 | `src/config.zig:164` |
| `lsm_snapshots_max` | 32 | `src/config.zig:165` |
| `lsm_table_coalescing_threshold_percent` | 50 | `src/config.zig:167` |
| `lsm_scans_max` | 6 | `src/config.zig:172` |
| `superblock_copies` | 4 | `src/config.zig:160` |
| `cache_line_size` | 64 | `src/config.zig:153` |
| `lsm_manifest_node_size` | 16 KiB | `src/config.zig:105` |
| NodePool alignment | 16 | `src/lsm/tree.zig:12` |
| Default manifest pool | 8192 nodes x 16 KiB = 128 MiB (derived product) | `src/constants.zig:688-693` |
| Tables at level i | `growth_factor^(i+1)`: 8, 64, 512, 4096, 32768, 262144, 2097152 | `src/lsm/tree.zig:656-672` |
| Max tables per tree | 2,396,744 (299592 + 2097152) | `src/lsm/tree.zig:679` |
| Growth factor bounds | 4..16 asserted, levels 2..10 asserted | `src/lsm/tree.zig:641-644` |
| Max value blocks per index block (upper bound) | `(block_size - 256) / (32 + 8)` = 13,100 (derived) | `src/constants.zig:679-686` |
| Compaction input tables max | `1 + lsm_growth_factor` = 9 | `src/lsm/compaction.zig:61` |
| Compaction read/write queue | 16 / 16 blocks | `src/constants.zig:667-668` |
| Grid cache | 16-way set associative | `src/vsr/grid.zig:159` |
| FreeSet shard | 4096 bits (8 cache lines) | `src/vsr/free_set.zig:106-109` |
| On-disk `TableInfo` (manifest log entry) | 128 bytes, align 16, asserted | `src/lsm/schema.zig:573-577` |
| Supported key sizes | 8, 16, 24, 32 bytes, asserted | `src/lsm/table.zig:100-102` |
| `test_min` config (fuzzers) | `block_size = sector_size` (4096), growth factor 4, compaction ops 4 | `src/config.zig:261-263` |

Derived fan-out numbers (block body = 524,288 - 256 = 524,032 bytes):

- 128-byte values (Account/Transfer objects): 4,094 values per value block (derived).
- 64-byte values: 8,188 per block (derived).
- 32-byte values (u128 id tree: `u128` id + `u64` timestamp + `u64` padding, per
  `docs/ARCHITECTURE.md:391-393`): 16,376 per block (derived).
- 16-byte values (u64 composite key): 32,752 per block (derived).
- Index block entry for an 8-byte key = 32 (checksum) + 8 + 8 (key_min, key_max) + 8 (address) =
  56 bytes, per `src/lsm/table.zig:211-212`.

The source comments on why these knobs matter:

```zig
/// - A lower block size increases the memory overhead of table metadata, due to smaller/more
///   tables.
/// - A higher block size increases space amplification due to partially-filled blocks.
pub const block_size = config.cluster.block_size;
```
(`src/constants.zig:587-590`)

```zig
/// A higher growth factor increases write amplification (by increasing the number of tables in
/// level B that overlap a table in level A in a compaction), but decreases read amplification (by
/// reducing the height of the tree and thus the number of levels that must be probed). Since read
/// amplification can be optimized more easily (with caching), we target a growth
/// factor of 8 for lower write amplification rather than the more typical growth factor of 10.
```
(`src/constants.zig:611-615`)

### Teaching idea

Put a B-tree's "page size / fan-out / height" table side by side with this one. In a B-tree, fan-out
is `page_size / (key + pointer)`. Here, a "pointer" costs 40 bytes (32-byte padded checksum + 8-byte
address) instead of a 4 or 8 byte page number, and each child also stores both `key_min` and
`key_max`. A reader can compute both fan-outs by hand.

---

## 2. Table = index block + value blocks: a static 2-level B+tree

### What it does

A table is exactly one index block plus 1..N value blocks (`src/lsm/table.zig:41-44`). Value
blocks are sorted arrays of fixed-size values with the key embedded in the value. The index block
holds, per value block: its checksum, its min key, its max key, and its address, stored
struct-of-arrays. Lookup = binary search `key_max[]` in the index block, check `key_min`, then
binary search the value block. Tables are written once by a `Builder` (bulk load, left to right)
and never modified.

### Where

- Layout comment: `src/lsm/schema.zig:7-16`
- `TableType` generic signature: `src/lsm/table.zig:45-60`
- Comptime layout computation: `src/lsm/table.zig:105-130`
- Comptime layout assertions: `src/lsm/table.zig:207-241`
- Offsets (SoA): `src/lsm/schema.zig:120-158`
- Builder (bulk loader): `src/lsm/table.zig:243-458`
- Index search: `src/lsm/table.zig:483-502`
- Value block search: `src/lsm/table.zig:537-548`
- Two-step async lookup using the above: `src/lsm/tree.zig:416-490`

### Snippet (on-disk schema)

```zig
//! Index block body schema:
//! │ [value_block_count_max]u256   │ checksums of value blocks
//! │ [value_block_count_max]Key    │ the minimum/first key in the respective value block
//! │ [value_block_count_max]Key    │ the maximum/last key in the respective value block
//! │ [value_block_count_max]u64    │ addresses of value blocks
//! │ […]u8{0}                     │ padding (to end of block)
//!
//! Value block body schema:
//! │ [≤value_count_max]Value  │ At least one value (no empty tables).
//! │ […]u8{0}                 │ padding (to end of block)
```
(`src/lsm/schema.zig:7-16`)

### Snippet (routing in the "internal node")

```zig
inline fn index_value_block_for_key(index_block: BlockPtrConst, key: Key) ?u32 {
    // Because we search key_max in the index block we can use the `upsert_index`
    // binary search here and avoid the extra comparison.
    const value_block_index = binary_search.binary_search_keys_upsert_index(
        Key,
        Table.index_value_keys_used(index_block, .key_max),
        key,
        .{},
    );
    assert(value_block_index < index.value_blocks_used(index_block));

    const key_min = Table.index_value_keys_used(index_block, .key_min)[value_block_index];
    return if (key < key_min) null else value_block_index;
}
```
(`src/lsm/table.zig:486-502`, comment abridged)

### Snippet (comptime layout)

```zig
pub const layout = layout: {
    assert(block_size % constants.sector_size == 0);
    assert(math.isPowerOfTwo(block_size));
    ...
    const block_value_count_max = @divFloor(block_body_size, value_size);

    // We need enough blocks to hold `value_count_max` values.
    const value_blocks = div_ceil(value_count_max, block_value_count_max);
    assert(value_blocks >= 1);
    assert(value_blocks <= constants.lsm_table_value_blocks_max);

    break :layout .{
        .block_value_count_max = block_value_count_max,
        .value_block_count_max = value_blocks,
    };
};
```
(`src/lsm/table.zig:105-130`, abridged)

### Differences from a textbook B+tree leaf/internal pair

1. **Separator = max key, plus a stored min key.** A B+tree internal node stores n-1 separators for
   n children. TigerBeetle stores both `key_min` and `key_max` per child, so the index block can
   answer "definitely not here" for a key that falls in a gap between two value blocks
   (`return if (key < key_min) null`). This substitutes for a bloom filter in some cases; there is
   no bloom filter in `src/lsm/` (the only mention is a TODO at `src/lsm/scan_tree.zig:831-833`).
2. **Struct-of-arrays.** Keys are contiguous, so the binary search touches only key cache lines.
   A slotted B-tree page interleaves keys and pointers.
3. **Fixed-size keys and values only.** `comptime assert(@typeInfo(TableKey) == .int ...)`
   (`src/lsm/table.zig:61`). No slot directory, no variable-length cells, no overflow pages.
4. **Height is fixed at 2.** Table capacity is bounded by one index block
   (`docs/internals/data_file.md:138-141`). The levels and the manifest supply the rest of the
   "height".
5. **No sibling pointers.** Range scans walk the index block's address array.
6. **Bulk-loaded and immutable.** `Builder.value_block_finish` appends one child entry and asserts
   that the new block's first key is strictly greater than the previous block's max key
   (`src/lsm/table.zig:373-377`). There is no split.
7. **Schema parameters travel in the block header** so that blocks can be decoded without the
   comptime type (`src/lsm/schema.zig:82-87`), which matters for scrubbing and repair.

### Teaching idea

Use this as the "static B+tree" chapter between "sorted array" and "dynamic B-tree": if the data
never changes, you can build the tree bottom-up, fill every leaf 100%, need no split logic, and need
no parent pointers. Then ask: what does it cost to add one key? That question motivates both the
dynamic B-tree (pay with in-place splits) and the LSM (pay with merges later).

Visualization idea: an index block drawn as four parallel strips (checksums, key_min, key_max,
addresses) with a cursor doing binary search on the key_max strip only, then one arrow to a value
block.

---

## 3. SegmentedArray: split, merge and borrow on fixed-size nodes

### What it does

"An array with efficient (amortized) random-insert/remove operations", also called an unrolled
linked list. It is an array of pointers to fixed-capacity nodes, plus a parallel `indexes` array of
prefix counts. A full node is split into two at the midpoint; an underfull node is merged with, or
refilled from, its right neighbour. The sorted variant adds `search` and `insert_element`.

The tree fuzzer calls it "a stunted B-tree one-level deep" (`src/lsm/tree_fuzz.zig:681-683`).

### Where

- Doc comment and types: `src/lsm/segmented_array.zig:14-41`
- `node_capacity` (even, >= 2): `src/lsm/segmented_array.zig:70-80`
- Worst-case node count: `src/lsm/segmented_array.zig:94-115`
- Fields (`nodes`, `indexes`): `src/lsm/segmented_array.zig:117-128`
- `verify()` invariants: `src/lsm/segmented_array.zig:177-211`
- Insert without split: `src/lsm/segmented_array.zig:310-322`
- Split: `src/lsm/segmented_array.zig:324-398` (ASCII cases at 334-365)
- Remove: `src/lsm/segmented_array.zig:476-559`
- Merge or rebalance: `src/lsm/segmented_array.zig:579-637`
- Two-level search: `src/lsm/segmented_array.zig:894-958`
- Absolute index <-> cursor: `src/lsm/segmented_array.zig:715-765`
- Iterator (both directions): `src/lsm/segmented_array.zig:767-814`

### Snippet (the invariants, as executable code)

```zig
for (array.nodes[0..array.node_count], 0..) |_, node_index| {
    const c = array.count(@intCast(node_index));
    // Every node is at most full.
    assert(c <= node_capacity);
    // Every node is at least half-full, except the last.
    if (node_index < array.node_count - 1) {
        assert(c >= @divTrunc(node_capacity, 2));
    }
}
```
(`src/lsm/segmented_array.zig:188-196`)

### Snippet (split)

```zig
// Insert a new node after the node being split.
const b = a + 1;
array.insert_empty_node_at(node_pool, b);
const b_pointer = array.nodes[b].?;

const a_half = div_ceil(total, 2);
const b_half = total - a_half;
assert(a_half >= b_half);
assert(a_half + b_half == total);
```
(`src/lsm/segmented_array.zig:324-332`)

### Snippet (merge, or borrow from the right sibling)

```zig
const total = array.count(a) + @as(u32, @intCast(b_elements.len));
if (total <= node_capacity) {
    stdx.copy_disjoint(.inexact, T, a_pointer[array.count(a)..], b_elements);

    array.indexes[b] = array.indexes[b + 1];
    array.remove_empty_node_at(node_pool, b);

    assert(array.count(a) >= half or a == array.node_count - 1);
} else if (array.count(a) < half) {
    const a_half = div_ceil(total, 2);
    const b_half = total - a_half;
    ...
    assert(array.count(a) >= half);
    assert(array.count(b) >= half);
}
```
(`src/lsm/segmented_array.zig:607-633`, abridged)

### Snippet (two-level search; note the "round down")

```zig
while (length > 1) {
    const half = length / 2;
    const mid = offset + half;

    const node = &array.nodes[mid].?[0];

    if (key_from_value(node) < key) {
        @branchHint(.unpredictable);
        offset = mid;
    }

    length -= half;
}

// Unlike a normal binary search, don't increment the offset when "key" is higher
// than the element — "round down" to the previous node.
// This guarantees that the node result is never "== node_count".
```
(`src/lsm/segmented_array.zig:911-927`)

### Design details worth pointing out

- **No stored separators.** The first-level search dereferences the first element of each candidate
  node (`&array.nodes[mid].?[0]`). A B-tree would copy that key into the parent. Trade-off: one
  extra pointer chase per probe versus no separator maintenance on split/merge/delete.
- **Counts are derived, not stored.** `count(node) = indexes[node+1] - indexes[node]`
  (`src/lsm/segmented_array.zig:665-669`), with one extra slot so the last node needs no special
  case (`:124-128`). This is exactly the "order statistic tree" augmentation, flattened.
- **The cost of being one level deep:** inserting a node shifts the pointer array and the index
  array (`insert_empty_node_at`, `:423-449`), and every insert/remove updates all later prefix
  counts in O(nodes) (`increment_indexes_after`, `:671-673`). A real B-tree makes this O(height).
- **Capacity is forced even** so split and join are symmetric at the midpoint (`:73-79`).
- **Batching rule that bounds the blast radius:** removal batches are capped at half a node so
  that at most two nodes are touched and at most one can become empty (`:484-487`, `:524-526`).
- **The last node is exempt from the half-full rule**, like a B-tree root.
- **Worst-case node count is computed at comptime** from `element_count_max` and the half-full
  invariant (`:94-115`), which is what allows the pointer array to be allocated once.
- **Duplicates are allowed** in the sorted variant; search is left-biased
  (test at `src/lsm/segmented_array.zig:962-1047`).
- Node capacities at production settings (derived, assuming a 64-byte `TreeTableInfo` for u64
  keys): keys array 16384 / 8 = 2048 keys per node; tables array 16384 / 64 = 256 per node.

### Teaching idea

This is the best single file to imitate for the guide's "B+tree leaf operations in Zig" chapter.
Suggested progression:

1. Chapter "leaf level only": implement exactly this (array of leaf pointers, split at midpoint,
   merge/borrow, half-full invariant, `verify()`).
2. Next chapter: observe that `insert_empty_node_at` is O(node_count). Fix it by applying the same
   trick recursively to the pointer array. That is a B+tree.

The ASCII split cases at `:334-365` are a ready-made model for an HTML step-through visualization.

---

## 4. NodePool: a fixed-size node allocator with a bitset free list

### What it does

Allocates one contiguous aligned buffer of `node_count * node_size` bytes at init, plus a bitset
with one bit per node. `acquire` finds the first set bit and returns a pointer into the buffer;
`release` recovers the index by pointer arithmetic and sets the bit. Running out is fatal, with an
operator-facing message. `deinit` asserts that every node was returned.

### Where

- Whole implementation: `src/lsm/node_pool.zig:10-84`
- Instantiation: `NodePoolType(constants.lsm_manifest_node_size, 16)` at `src/lsm/tree.zig:12`,
  `src/lsm/manifest.zig:21`, `src/lsm/forest.zig:12`, `src/lsm/groove.zig:17`
- One pool for the whole forest: `src/lsm/forest.zig:212`, `:242-243`, passed down at `:280-286`
- Leak check on reset: `src/lsm/forest.zig:308-309`
- Test with sentinel fill and shadow map: `src/lsm/node_pool.zig:86-247`

### Snippet

```zig
pub fn NodePoolType(comptime _node_size: u32, comptime _node_alignment: u13) type {
    return struct {
        const NodePool = @This();

        pub const node_size = _node_size;
        pub const node_alignment = _node_alignment;
        pub const Node = *align(node_alignment) [node_size]u8;

        comptime {
            assert(node_size > 0);
            assert(node_alignment > 0);
            assert(node_alignment <= 4096);
            assert(math.isPowerOfTwo(node_size));
            assert(math.isPowerOfTwo(node_alignment));
            assert(node_size % node_alignment == 0);
        }

        buffer: []align(node_alignment) u8,
        free: std.bit_set.DynamicBitSetUnmanaged,
```
(`src/lsm/node_pool.zig:10-28`)

```zig
pub fn release(pool: *NodePool, node: Node) void {
    ...
    assert(@intFromPtr(node) >= @intFromPtr(pool.buffer.ptr));
    assert(@intFromPtr(node) + node_size <= @intFromPtr(pool.buffer.ptr) + pool.buffer.len);

    const node_offset = @intFromPtr(node) - @intFromPtr(pool.buffer.ptr);
    const node_index = @divExact(node_offset, node_size);
    assert(!pool.free.isSet(node_index));
    pool.free.set(node_index);
}
```
(`src/lsm/node_pool.zig:70-82`, abridged)

### Things to notice

- `Node` is a **pointer to a fixed-size, explicitly aligned byte array**, not a slice. The consumer
  casts it to its typed node and proves the cast safe at comptime
  (`src/lsm/segmented_array.zig:442-447`).
- The pool is **not** a `std.mem.Allocator`. It is a purpose-built interface with two infallible
  methods. The `Allocator` is used only once, in `init`.
- The pool is passed **explicitly to every mutating call** (`insert_element(node_pool, ...)`,
  `remove_elements(node_pool, ...)`), not stored in each array. Many arrays share one pool.
- `@divExact` in `release` turns a misaligned pointer into a crash.
- Double free and foreign pointers are caught by assertions.
- The test fills the buffer with a random sentinel, writes a unique id into each acquired node,
  and checks on release that nothing else overwrote it (`src/lsm/node_pool.zig:104-116` and the
  `acquire`/`release` helpers that follow).

### Teaching idea

This should be the guide's first custom allocator: "a B-tree needs nodes of one size, so a general
allocator is overkill". Have readers implement `NodePool`, then a variant that implements the
`std.mem.Allocator` vtable, and compare. Then show the same thing on disk in section 9 (FreeSet).

---

## 5. ManifestLevel: an ordered in-memory index over tables

### What it does

For one level of one tree, keeps the metadata of every table, ordered by `(key_max,
snapshot_min)`. It is implemented as two **parallel** sorted segmented arrays sharing one
`NodePool`: `keys` (just `key_max`, densely packed for fast search) and `tables` (the full
`TableInfo`). The same absolute index refers to the same table in both, although node boundaries
differ because element sizes differ.

### Where

- Type and the two arrays: `src/lsm/manifest_level.zig:16-54`
- Composite ordering key as a packed struct: `src/lsm/manifest_level.zig:56-71`
- "Parallel arrays" comment: `src/lsm/manifest_level.zig:152-158`
- Insert: `src/lsm/manifest_level.zig:208-251`
- Remove: `src/lsm/manifest_level.zig:283-322`
- Range iterator start: `src/lsm/manifest_level.zig:475-510`
- Duplicate-key boundary scan: `src/lsm/manifest_level.zig:512-546`
- Generation counter for dangling references: `src/lsm/manifest_level.zig:73-74`, `:172-174`,
  `:228`, `:264`, `:308`
- Least-overlap compaction victim: `src/lsm/manifest_level.zig:584-...`
- Point lookup across levels: `src/lsm/manifest.zig:400-442`
- Worked 2D example (key range x snapshot range): `docs/internals/lsm.md:256-310`

### Snippet (composite sort key via packed struct + @bitCast)

```zig
pub const KeyMaxSnapshotMin = packed struct(KeyMaxSnapshotMin.Int) {
    pub const Int = std.meta.Int(
        .unsigned,
        @bitSizeOf(u64) + @bitSizeOf(Key),
    );

    // The tables are ordered by (key_max,snapshot_min),
    // fields are declared from the least significant to the most significant:

    snapshot_min: u64,
    key_max: Key,

    pub inline fn key_from_value(value: KeyMaxSnapshotMin) Int {
        return @bitCast(value);
    }
};
```
(`src/lsm/manifest_level.zig:56-71`)

### Snippet (pointer invalidation guard)

```zig
// A direct reference to a TableInfo within the Tables array.
pub const TableInfoReference = struct { table_info: *TableInfo, generation: u32 };
...
assert(table_ref.generation == level.generation);
```
(`src/lsm/manifest_level.zig:73-74`, `:264`)

### Snippet (point lookup: at most one table per level)

```zig
if (inner.next()) |table| {
    assert(table.visible(it.snapshot));
    assert(table.key_min <= it.key);
    assert(it.key <= table.key_max);
    assert(inner.next() == null);

    it.level += 1;
    return table;
}
```
(`src/lsm/manifest.zig:428-436`)

### Teaching idea

- **Key/payload separation.** The dense `keys` array is the same idea as a B+tree keeping only
  keys in internal nodes: more keys per cache line during search.
- **Iterator invalidation.** Any insert or remove can move elements between nodes, so raw pointers
  into nodes are only valid until the next mutation. TigerBeetle makes this checkable with a
  generation counter. The guide should teach the same hazard for B-tree cursors, and this cheap
  runtime check. Note also `remove_table`'s assertion that the argument is not a pointer into the
  array it is about to mutate (`src/lsm/manifest_level.zig:296-299`).
- **MVCC by interval.** Each entry carries `[snapshot_min, snapshot_max]`; "delete" is setting
  `snapshot_max` (`:257-279`), and physical removal happens later. This gives an alternative to
  copy-on-write B-tree snapshots worth a sidebar.
- **Per-level key range short-circuit**: `key_range_contains` lets a lookup skip a whole level
  (`src/lsm/manifest.zig:419`), the same role as fence keys.

---

## 6. binary_search.zig: in-node search

### What it does

One generic routine, `binary_search_values_upsert_index`, returns the insertion index for a key in
a slice sorted by an inlined `key_from_value`. Variants are thin wrappers: exact-match lookup,
keys-only, `[key_min, key_max]` range. Features: a comptime `Config{ mode, prefetch }`; a loop
whose length is halved unconditionally so the only data-dependent step is a conditional move;
software prefetch of both possible next probes; full invariant assertions guarded by
`constants.verify`.

### Where

- Config: `src/lsm/binary_search.zig:9-12`
- Contract doc comment: `src/lsm/binary_search.zig:17-32`
- Core loop: `src/lsm/binary_search.zig:33-147`
- Prefetch block: `src/lsm/binary_search.zig:59-98`
- Exact-match wrapper: `src/lsm/binary_search.zig:174-201`
- Range wrappers: `src/lsm/binary_search.zig:221-350`
- Exhaustive tests against a linear scan: `src/lsm/binary_search.zig:352-...`
- Benchmark scenarios (64 values in-cache vs 4096 values out-of-cache):
  `src/lsm/binary_search_benchmark.zig:26-37`

### Snippet (core loop, assertions and prefetch removed)

```zig
var offset: usize = 0;
var length: usize = values.len;
while (length > 1) {
    const half = length / 2;
    const mid = offset + half;

    // For exact matches, takes the first half if `mode == .lower_bound`,
    // or the second half if `mode == .upper_bound`.
    const take_upper_half: bool = (switch (comptime config.mode) {
        .lower_bound => key_from_value(&values[mid]) < key,
        .upper_bound => key_from_value(&values[mid]) <= key,
    });

    if (take_upper_half) {
        @branchHint(.unpredictable);
        offset = mid;
    }

    length -= half;
}
...
offset += @intFromBool(key_from_value(&values[offset]) < key);
```
(`src/lsm/binary_search.zig:43-131`, abridged)

### Snippet (prefetching both grandchildren)

```zig
// We need to use pointer arithmetic and disable runtime safety to avoid bounds checks,
// otherwise prefetching would harm the performance instead of improving it.
// Since these pointers are never dereferenced, it's safe to dismiss this extra cost
// here.
@setRuntimeSafety(constants.verify);
const one_quarter = values.ptr + offset + half / 2;
const three_quarters = one_quarter + half;
```
(`src/lsm/binary_search.zig:70-76`)

The prefetch reference in the source is "ARRAY LAYOUTS FOR COMPARISON-BASED SEARCHING, page 18"
(`:61-62`). Values wider than a cache line get one prefetch per line via `inline for` (`:78-97`).

### Snippet (loop invariant as an assertion)

```zig
if (constants.verify) {
    assert(offset == 0 or switch (comptime config.mode) {
        .lower_bound => key_from_value(&values[offset - 1]) < key,
        .upper_bound => key_from_value(&values[offset - 1]) <= key,
    });

    assert(offset + length == values.len or switch (comptime config.mode) {
        .lower_bound => key <= key_from_value(&values[offset + length]),
        .upper_bound => key < key_from_value(&values[offset + length]),
    });
}
```
(`src/lsm/binary_search.zig:46-56`)

### Teaching idea

A full chapter section, "searching inside a node":

1. Textbook `lo/hi` binary search with an early-exit equality branch.
2. The "offset + length, halve unconditionally" form: the iteration count depends only on `len`,
   so the branch predictor sees a fixed loop and the comparison becomes a conditional move.
3. Return an **upsert index**, not `?index`. One routine then serves lookup, insert position,
   child selection in an internal node, and range bounds. Exactness is one extra comparison that
   only callers who need it pay for (`:190`).
4. Lower bound vs upper bound for duplicates, as a comptime parameter.
5. Prefetch. Be honest that it is only worthwhile for nodes larger than cache; the repo keeps a
   benchmark with an in-cache and an out-of-cache scenario for this reason.
6. Write the loop invariant as assertions and test exhaustively against a linear scan.

Note that the generic `key_from_value` is required to be `callconv(.@"inline")` in the function
type itself (`:36`); this is how the code forces per-instantiation inlining of the comparator.

---

## 7. Composite keys for secondary indexes

### What it does

A secondary index tree stores only keys: `(field value, timestamp)` where the timestamp is the
object's primary key. The pair is packed into a single unsigned integer with the field in the high
bits, so ordinary integer comparison gives lexicographic order, and all entries for one field value
are contiguous. The top bit of the timestamp is a tombstone flag, masked off when forming the key.

### Where

- `CompositeKeyType`: `src/lsm/composite_key.zig:7-94`
- `IndexTreeType` wiring with `.secondary_index` usage: `src/lsm/groove.zig:72-91`
- Field type normalisation to `void | u64 | u128`: `src/lsm/groove.zig:93-116`
- Object tree keyed by timestamp: `src/lsm/groove.zig:25-49`
- `TableUsage.secondary_index` optimisation rules: `src/lsm/table.zig:16-30`
- Architecture description of the lookup path: `docs/ARCHITECTURE.md:59-65`
- Prefix scans cannot be pruned by table key range: `src/lsm/scan_tree.zig:831-833`
- Intersection of several index scans (zig-zag merge join): `src/lsm/zig_zag_merge.zig:11-39`

### Snippet

```zig
pub inline fn key_from_value(value: *const CompositeKey) Key {
    assert(value.padding == 0);
    if (Field == void) {
        comptime assert(Key == u64);
        return value.timestamp & ~tombstone_bit;
    } else {
        comptime assert(@sizeOf(Key) == @sizeOf(Field) * 2);
        return (@as(Key, value.field) << 64) | @as(Key, value.timestamp & ~tombstone_bit);
    }
}

pub inline fn key_prefix(key: Key) Field {
    return if (Field == void) {} else @truncate(key >> 64);
}
```
(`src/lsm/composite_key.zig:64-77`)

```zig
comptime {
    assert(@sizeOf(CompositeKey) == @sizeOf(Key));
    ...
    assert(@alignOf(CompositeKey) == field_bitsize_alignment);
    assert(stdx.no_padding(CompositeKey));
}
```
(`src/lsm/composite_key.zig:51-62`, abridged)

### Teaching idea

For the "secondary indexes" chapter:

- A non-unique index over a B-tree is made unique by appending the primary key. TigerBeetle shows
  the smallest possible version: key == value, no payload.
- "All transfers for account X" is a range scan from `(X, 0)` to `(X, maxInt)`; the prefix is
  recovered with a shift.
- Packing into one integer makes the comparator a single machine comparison (a u128 or u256
  compare), rather than a field-by-field comparator function. Mention the cost: only fixed-width
  fields, and a u128 field needs 8 bytes of explicit zeroed padding to reach a 32-byte key.
- Two-step lookup: index tree gives timestamps, object tree gives objects. This is the
  non-clustered index pattern.
- Multi-condition queries intersect sorted streams by "probing" each stream to the other's
  current key (`stream_probe`, `src/lsm/zig_zag_merge.zig:34-38`). A B-tree cursor's `seek` is the
  same primitive.

---

## 8. Memory-management style

### 8.1 Static allocation, enforced by an allocator wrapper

#### What it does

All memory is allocated during `init`, sized from explicit upper bounds. After init, the replica
flips a wrapper allocator into a state where any `alloc`/`resize` trips an assertion. On shutdown
it flips again so only `free` is allowed.

#### Where

- Policy text: `docs/TIGER_STYLE.md:151-156`
- Rationale and precise definition: `docs/ARCHITECTURE.md:189-230`
- `StaticAllocator`: `src/static_allocator.zig:1-82`
- Used by the replica: `src/vsr/replica.zig:664-665` (wrap), `:738-739` (lock), `:1472` (unlock
  for deinit)
- `CountingAllocator` (reports live bytes): `src/counting_allocator.zig:1-72`, wired at
  `src/tigerbeetle/main.zig:319-320`, read at `:500` and `:567`
- Process root allocator backed by a huge-page allocator: `src/tigerbeetle/main.zig:67-69`

#### Snippet

```zig
const State = enum {
    /// Allow `alloc` and `resize`.
    /// (To make errdefer cleanup easier to write we also allow calling `free`,
    ///  in which case we switch state to `.deinit` and no longer allow `alloc` or `resize`.)
    init,
    /// Don't allow any calls.
    static,
    /// Allow `free` but not `alloc` and `resize`.
    deinit,
};
```
(`src/static_allocator.zig:14-23`)

```zig
fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
    assert(self.state == .init);
    return self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
}
```
(`src/static_allocator.zig:58-62`)

```zig
// Disable all dynamic allocation from this point onwards.
self.static_allocator.transition_from_init_to_static();
```
(`src/vsr/replica.zig:738-739`)

"Static" here does not mean an arena with a cap:

> This is also different from arena allocation. Some systems allocate a fixed-sized arena at the
> start and fail with an 'out of memory' error if the limit is ever exceeded. [...] In TigerBeetle,
> the amount of memory used is a consequence of everything having an explicit upper bound.
(`docs/ARCHITECTURE.md:203-206`)

#### Teaching idea

Both wrappers are roughly 80 lines and implement the four-function `std.mem.Allocator` vtable
(`alloc`, `resize`, `remap`, `free` in 0.16). They are ideal first "write your own allocator"
exercises for the guide: a counting allocator to measure a B-tree's footprint, and a
"freeze after init" allocator to prove that insert/delete never allocate once the node pool exists.
Check the vtable shape against Zig 0.17.1.

### 8.2 Which allocators appear where

Verified by grep over `src/`:

- In the storage engine (`src/lsm/*.zig`, `src/vsr/grid.zig`, `src/vsr/free_set.zig`) the only
  allocator type is a `std.mem.Allocator` parameter named `allocator` or `gpa`, used in
  `init`/`deinit` only.
- `ArenaAllocator` appears only in tests, benchmarks, CLI flag parsing, build scripts, the shell
  helper and formatting tools, for example `src/lsm/binary_search_benchmark.zig:43`,
  `src/lsm/segmented_array_benchmark.zig:68`, `src/stdx/flags.zig:47-53`.
- `FixedBufferAllocator` appears twice: `src/stdx/process.zig:150` and `src/multiversion.zig:1661`.
- Tests use `std.testing.allocator`; the fuzz driver uses `std.heap.DebugAllocator`
  (`src/fuzz_tests.zig:73-74`).

So TigerBeetle is a good model for **explicit allocator passing, pools, and freeze-after-init**,
and a weak source for arena or fixed-buffer examples inside data structures. The guide will need
other sources (or its own designs) for those.

### 8.3 How allocators are threaded

#### Where

- Naming rule: `docs/TIGER_STYLE.md:297-299`
- Positional threading rule: `docs/TIGER_STYLE.md:353-354`
- In-place init via out-pointer: `docs/TIGER_STYLE.md:381-392`
- Group allocation with its `defer`: `docs/TIGER_STYLE.md:440-441`

#### Snippet (the init pattern used everywhere)

```zig
pub fn init(pool: *NodePool, allocator: mem.Allocator, node_count: u32) !void {
    assert(node_count > 0);

    pool.* = .{
        .buffer = undefined,
        .free = undefined,
    };
    const size = node_size * node_count;
    pool.buffer = try allocator.alignedAlloc(u8, .fromByteUnits(node_alignment), size);
    errdefer allocator.free(pool.buffer);

    pool.free = try std.bit_set.DynamicBitSetUnmanaged.initFull(allocator, node_count);
    errdefer pool.free.deinit(allocator);
}
```
(`src/lsm/node_pool.zig:30-43`)

#### Snippet (partial-initialisation cleanup in a loop)

```zig
for (&manifest.levels, 0..) |*level, i| {
    errdefer for (manifest.levels[0..i]) |*l| l.deinit(allocator, node_pool);
    try level.init(allocator, node_pool);
}
errdefer for (&manifest.levels) |*level| level.deinit(allocator, node_pool);
```
(`src/lsm/manifest.zig:212-216`)

Rules visible in the code:

1. The allocator is **not stored** in the struct; `deinit` takes it again
   (`src/lsm/node_pool.zig:45`, `src/lsm/segmented_array.zig:150`). Std "Unmanaged" containers are
   used for the same reason.
2. Dependencies are positional and ordered general to specific: `(self, allocator, node_pool, grid,
   ...)` (`src/lsm/tree.zig:102-110`). Everything else goes in an `options` struct.
3. Large structs are initialised in place through `self: *T`, with fields first set to `undefined`
   and then filled, each followed by its `errdefer`.
4. After init, the working resources are pools with infallible `acquire`/`release`:
   `NodePool`, `ScratchMemory` (`src/lsm/scratch_memory.zig:35-62`), the compaction `ResourcePool`
   (`src/lsm/compaction.zig:78-90`), `IOPSType` slots.
5. Capacity reserved up front, then `...AssumeCapacity` (`src/vsr/grid.zig:309-321`,
   `putAssumeCapacityNoClobber`).
6. Scratch space for the radix sort is one buffer shared by all trees, sized at **comptime** as the
   maximum over all tree types (`src/lsm/forest.zig:257-268`), with a `free`/`busy` state enum
   asserted on every acquire and release.

### 8.4 Comptime-parameterised generic types

#### Where

- `TableType(Key, Value, key_from_value, sentinel_key, tombstone, tombstone_from_key,
  value_count_max, usage)`: `src/lsm/table.zig:45-60`
- Re-export of generic arguments: `src/lsm/table.zig:66-74`
- `TreeType(Table, Storage)`: `src/lsm/tree.zig:39-57`
- `ManifestLevelType(NodePool, Key, TableInfo, table_count_max_tree)`:
  `src/lsm/manifest_level.zig:16-21`
- Optional comptime parameter selecting API surface (`Key: ?type`):
  `src/lsm/segmented_array.zig:49-58`, `:220`, `:244`, `:894-900`
- `Storage` as a comptime parameter so tests swap in a simulated disk:
  `src/lsm/tree_fuzz.zig:19`, `:31-32`
- Per-structure `Options{ verify: bool }`: `src/lsm/segmented_array.zig:43-47`

#### Snippet

```zig
pub fn TableType(
    comptime TableKey: type,
    comptime TableValue: type,
    /// Returns the key for a value. For example, given `object` returns `object.id`.
    /// Since most objects contain an id, this avoids duplicating the key when storing the value.
    comptime table_key_from_value: fn (*const TableValue) callconv(.@"inline") TableKey,
    /// Must compare greater than all other keys.
    comptime table_sentinel_key: TableKey,
    ...
) type {
    comptime assert(@typeInfo(TableKey) == .int or @typeInfo(TableKey) == .comptime_int);

    return struct {
        const Table = @This();

        // Re-export all the generic arguments.
        pub const Key = TableKey;
        pub const Value = TableValue;
        pub const key_from_value = table_key_from_value;
```
(`src/lsm/table.zig:45-69`, abridged)

#### Teaching idea

Pattern for the guide's `BTreeType(comptime Key, comptime Value, comptime key_from_value, comptime
NodePool, comptime options)`:

- Name type-returning functions `...Type`, and write `const Self = @This()` with the real name
  (`const Table = @This();`).
- Re-export every generic argument as a `pub const` so dependent generics can take one type
  argument (`TreeType(Table, Storage)` reads `Table.Key`, `Table.Value`, ...).
- Validate parameters with `comptime assert` at the top, and layout with a `comptime { ... }`
  block.
- Use a comptime `options.verify` flag so expensive whole-structure checks compile away outside
  tests and fuzzers.
- Store the key inside the value and take `key_from_value` rather than separate key and value
  arrays, when keys are part of the record.

### 8.5 Assertions and invariants

#### Where

- Policy: `docs/TIGER_STYLE.md:104-149`
- When to guard with `constants.verify`: `src/constants.zig:775-795`
- `maybe()`: `src/stdx/stdx.zig:396-403`
- `no_padding()`: `src/stdx/stdx.zig:503-...`
- `copy_left` / `copy_right` / `copy_disjoint`: `src/stdx/stdx.zig:119-200`
- Read-side re-validation of written data: `src/lsm/tree.zig:437-444`, `:474-482`

#### Snippets

```zig
/// In the data plane (eg, lsm tree), finer grained judgement is required. Do an unconditional O(1)
/// assert before an O(N) loop (e.g, a bounds check). Inside the loop, it might or might not be
/// feasible to add an extra assert per iteration. In the latter case, guard the assert with `if
/// (constants.verify)`, but prefer an unconditional assert unless benchmarks prove it to be costly.
```
(`src/constants.zig:783-787`)

```zig
/// `maybe` is the dual of `assert`: it signals that condition is sometimes true
///  and sometimes false.
pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}
```
(`src/stdx/stdx.zig:396-403`, abridged)

```zig
pub inline fn copy_left(
    comptime precision: SizePrecision,
    comptime T: type,
    target: []T,
    source: []const T,
) void {
    switch (precision) {
        .exact => assert(target.len == source.len),
        .inexact => assert(target.len >= source.len),
    }

    if (!disjoint_slices(T, T, target, source)) {
        assert(@intFromPtr(target.ptr) < @intFromPtr(source.ptr));
    }
    ...
```
(`src/stdx/stdx.zig:121-134`)

#### Teaching idea

Shifting elements inside a node is where most B-tree memory bugs live. Wrapping the raw copy in
`copy_left` / `copy_right` / `copy_disjoint`, which assert direction and overlap, is a small
investment the guide's Zig examples should make from the first chapter. Also adopt: split compound
asserts, `if (a) assert(b)` for implications, pre- and postcondition count checks around each
mutation (`src/lsm/segmented_array.zig:223-232`), and "pair assertions" on write and on read.

---

## 9. Grid: block storage, checksummed pointers, free set, superblock

### 9.1 Blocks and block pointers

#### What it does

The grid is an array of equal-size blocks addressed by a `u64` starting at 1 (0 is a sentinel).
A reference to a block is `(address, checksum)`. The checksum is stored in the **parent**, not
trusted from the child, so a block read is validated against what the parent expected. Each block
starts with a 256-byte header carrying its own checksum, a body checksum, its address, a block
type, and schema metadata.

#### Where

- `BlockPtr` type: `src/vsr/grid.zig:23-24`
- Grid doc comment: `src/vsr/grid.zig:26-29`
- Address to file offset: `src/vsr/grid.zig:1579-1583`
- Header layout: `src/vsr/message_header.zig:1560-1586`
- Read validation: `src/vsr/grid.zig:1421-1446`
- Failure taxonomy: `src/vsr/grid.zig:122-136`
- `BlockType` enum: `src/lsm/schema.zig:54-73`
- Header accessor with assertions: `src/lsm/schema.zig:41-52`
- Design text: `docs/internals/data_file.md:17-44`, `docs/ARCHITECTURE.md:565-590`
- Checksum is AEGIS-128L based MAC: `src/vsr/checksum.zig:12-41`

#### Snippet

```zig
pub const BlockPtr = *align(constants.sector_size) [constants.block_size]u8;
pub const BlockPtrConst = *align(constants.sector_size) const [constants.block_size]u8;
```
(`src/vsr/grid.zig:23-24`)

```zig
fn read_block_validate(block: BlockPtrConst, expect: struct {
    address: u64,
    checksum: u128,
}) ReadBlockResult {
    const header = mem.bytesAsValue(vsr.Header.Block, block[0..@sizeOf(vsr.Header)]);

    if (!header.valid_checksum()) return .invalid_checksum;
    if (header.command != .block) return .unexpected_command;
    ...
    const block_body = block[@sizeOf(vsr.Header)..header.size];
    if (!header.valid_checksum_body(block_body)) {
        return .invalid_checksum_body;
    }

    if (header.checksum != expect.checksum) return .unexpected_checksum;
    ...
    assert(header.address == expect.address);
    return .{ .valid = block };
}
```
(`src/vsr/grid.zig:1421-1446`, abridged)

> The block checksum is stored outside of the block itself, to protect from misdirected writes.
(`docs/internals/data_file.md:39`)

#### Contrast with B-tree page pointers

| | Classic B-tree | TigerBeetle grid |
|---|---|---|
| Child pointer | page number (4-8 bytes) | address `u64` + checksum `u128` padded to 32 bytes = 40 bytes |
| Detects torn/corrupt page | page-local checksum | yes (header + body checksums) |
| Detects misdirected or stale-but-valid page | no | yes, parent holds the expected checksum |
| In-place update of a child | cheap | impossible without rewriting the parent, hence copy-on-write |
| Fan-out cost | low | 40 bytes per child plus two keys |

The chain is a Merkle tree: superblock -> manifest log blocks -> index blocks -> value blocks
(`docs/internals/data_file.md:196-203`).

### 9.2 Copy-on-write and the free set

#### What it does

Blocks are never overwritten in place while they are reachable from the current checkpoint.
New state is written to newly acquired blocks. Released blocks stay allocated until the *next*
checkpoint is durable, so that a crash can always recover from the last checkpoint. The free set is
a bitset (plus a coarse index bitset of 4096-bit shards), itself persisted into grid blocks at
checkpoint. Compactions **reserve** an upper bound of blocks in a deterministic order before running
concurrently, so that block addresses are identical on every replica.

#### Where

- Reservation lifecycle: `src/vsr/free_set.zig:29-44`
- Bitsets: `src/vsr/free_set.zig:63-80`
- Deferred free: `src/vsr/free_set.zig:509-533`
- Grid wrappers `reserve` / `acquire` / `release`: `src/vsr/grid.zig:675-725`
- Out-of-space is fatal with an operator message: `src/vsr/grid.zig:678-690`
- "Purely functional, persistent, garbage collected": `docs/internals/data_file.md:41-44`
- Write path summary: `docs/ARCHITECTURE.md:72-78`

#### Snippet

```zig
/// Leave the address acquired for now, but free it when the next checkpoint becomes durable.
/// This ensures that it will not be overwritten during the current checkpoint — the block may
/// still be needed if we crash and recover from the current checkpoint.
pub fn release(set: *FreeSet, address: u64) void {
    assert(set.opened);

    const block = address - 1;
    assert(set.blocks_acquired.isSet(block));
    assert(!set.blocks_released.isSet(block));
```
(`src/vsr/free_set.zig:509-521`, abridged)

### 9.3 Superblock

#### What it does

A fixed-location root that stores, among other things, the references (address + checksum) to the
oldest and newest manifest log blocks and to the persisted free set. It is written as 4 copies; on
startup the replica picks the latest sequence that has a quorum of copies. Each superblock stores
the checksum of its predecessor (`parent`), forming a hash chain across checkpoints.

#### Where

- Header fields: `src/vsr/superblock.zig:53-79`
- Invariants doc comment: `src/vsr/superblock.zig:1-28`
- Copy count restricted to 4, 6 or 8: `src/vsr/superblock.zig:595-597`
- Why "latest copy" alone is wrong: `docs/internals/data_file.md:75-79`
- Checkpoint cadence and WAL replay: `docs/internals/data_file.md:63-94`

#### Snippet

```zig
/// A monotonically increasing counter to locate the latest superblock at startup.
sequence: u64,

/// Protects against writing to or reading from the wrong data file.
cluster: u128,

/// The checksum of the previous superblock to hash chain across sequence numbers.
parent: u128,
```
(`src/vsr/superblock.zig:71-78`)

### 9.4 Block cache

`src/lsm/set_associative_cache.zig` is a fixed-size, 16-way set-associative cache with 8-bit tags
and a 2-bit CLOCK counter per way (`:15-22`, `:131-136`). The grid uses it keyed by block address
(`src/vsr/grid.zig:148-175`). `src/lsm/cache_map.zig:11-25` layers it over a hash-map "stash" so
that evicted-but-still-needed values are not lost.

### Teaching idea

For the guide's "pager, free list, crash safety" chapters:

- The FreeSet is the on-disk twin of `NodePool`. Teach them back to back: same bitset, but the
  disk version must delay reuse until a checkpoint is durable.
- Contrast three crash-safety strategies for a B-tree: WAL + in-place update, shadow paging /
  copy-on-write with a root swap (LMDB style; TigerBeetle's grid is this, applied to an LSM), and
  double-write. The superblock is the "meta page"; multiple copies plus a sequence number is the
  generalisation of LMDB's two meta pages (LMDB comparison is from memory, **unverified** here).
- The 40-byte pointer is a concrete, quantifiable cost of checksummed pointers; let readers compute
  the fan-out loss for a 4 KiB B-tree page.
- A fixed-size set-associative cache with CLOCK eviction is a good statically allocated buffer pool
  for the guide's examples, as an alternative to an LRU list that allocates.

---

## 10. Testing: model-based fuzzing and deterministic simulation

### 10.1 The pattern (as implemented for SegmentedArray)

#### Where

- Fuzz context: `src/lsm/segmented_array.zig:1051-1424`
- Driver and configurations: `src/lsm/segmented_array.zig:1426-1510`
- Entry point (7 lines): `src/lsm/segmented_array_fuzz.zig:1-7`
- Registry of all fuzzers: `src/fuzz_tests.zig:35-56`
- Seed handling: `src/fuzz_tests.zig:136-160`
- Fuzzers always run with `constants.verify` and the `test_min` config:
  `src/fuzz_tests.zig:11-23`, `:69`

#### Precise recipe

1. **Seeded PRNG is the only source of randomness.** `var prng = stdx.PRNG.from_seed(seed);`
   (`:1427`). The seed is printed (`src/fuzz_tests.zig:145`) and can be passed back on the command
   line to reproduce.
2. **Reference model**: the simplest structure with the same observable behaviour. Here a flat
   `std.ArrayList(T)` with capacity reserved for `element_count_max` (`:1088`, `:1113-1115`).
3. **Random weighted operations in phases.** A growth phase (insert 60 / remove 40), then a
   shrink phase (40 / 60), then remove everything (`:1125-1162`). Phases make sure both the full and
   the empty boundary are reached.
4. **Apply each operation to both** the structure under test and the model
   (`:1204-1210`, `:1240-1242`).
5. **After every operation, compare everything observable** (`verify`, `:1295-1370`):
   - length;
   - full forward iteration equals the model;
   - full reverse iteration equals the model reversed;
   - `absolute_index_for_cursor(cursor_for_absolute_index(i)) == i` for every i (round trip);
   - model stays sorted (sorted variant);
   - structural invariants: empty implies zero nodes, unused node slots are null, every node but
     the last is at least half full;
   - 20 random searches plus the two extreme keys `0` and `maxInt(Key)` agree with a binary
     search over the model (`:1372-1385`).
6. **Internal `verify()` also runs before and after every public call** because the fuzz entry
   passes `.{ .verify = true }` (`src/lsm/segmented_array_fuzz.zig:6`).
7. **Sweep tiny configurations** so that boundaries are hit constantly: node sizes of 8, 16, 32,
   64 bytes for `u32` (capacity 2 to 16), element limits of 3, 4, 5, 6 and 1024, and a 128-byte
   struct type in 256/512/1024-byte nodes (`:1466-1480`).
8. **Assert the fuzzer covered what it was meant to cover**: `assert(tested_padding);
   assert(tested_node_capacity_min);` (`:1508-1509`).
9. **Directed worst case**: for the unsorted variant, deliberately drive the structure to
   `node_count_max` and assert it got there (`:1164-1184`).
10. **Over-align test nodes** to catch missing `@alignCast` at compile time (`:1068-1069`).

#### Snippet

```zig
.sorted => {
    for (buffer[0..count]) |value| {
        const index_actual = context.array.insert_element(&context.pool, value);
        const index_expect = context.reference_index(key_from_value(&value));
        context.reference.insert(
            context.gpa,
            index_expect,
            value,
        ) catch unreachable;
        try std.testing.expectEqual(index_expect, index_actual);
    }
},
```
(`src/lsm/segmented_array.zig:1212-1223`)

### 10.2 The same pattern one level up: tree_fuzz

#### Where

- Model definition: `src/lsm/tree_fuzz.zig:681-807`
- Operation type: `src/lsm/tree_fuzz.zig:66-84`
- Generate all operations up front: `src/lsm/tree_fuzz.zig:816-897`
- Apply and compare: `src/lsm/tree_fuzz.zig:547-636`
- Scan comparison: `src/lsm/tree_fuzz.zig:638-676`
- Simulated storage with random latencies: `src/lsm/tree_fuzz.zig:942-950`
- Hot/cold key generator: `src/stdx/testing/fuzz.zig:57-69`, used at `src/lsm/tree_fuzz.zig:809-814`
- RAM cap for fuzzers (20 GiB address space on Linux): `src/stdx/testing/fuzz.zig:131-140`

#### Details worth copying

- **Operations are data.** `FuzzOp = union(enum) { compact, put, remove, get, scan }`. The whole
  sequence is generated first, then replayed. This makes shrinking and logging straightforward.
- **Swarm testing.** Per run, each operation's weight is randomly either zero or non-zero:
  `.remove = if (prng.boolean()) 0 else constants.lsm_compaction_ops` (`:826-837`). Some runs have
  no removes at all, some no scans, which reaches states a uniform mix rarely does.
- **Key distribution with deliberate collisions**: flip a coin between a tiny "hot" id space
  (average 8) and a huge "cold" one (`src/stdx/testing/fuzz.zig:57-69`).
- **The model for the big structure is the already-fuzzed small structure**
  (`SortedSegmentedArray`), a layered trust argument.
- **Run length is itself random**: `fuzz.random_int_exponential(&prng, usize, 1E6)` capped by
  `events_max` (`:934-937`).
- **Space amplification is logged** by comparing bytes used on the simulated disk with the model's
  size (`:559-566`).
- The system under test is the production `TreeType`, instantiated with the simulated `Storage`
  type (`:19`, `:114`).

### 10.3 Other variants of the oracle idea

- **Brute-force oracle for an optimised algorithm**: the O(n_a + n_b) two-pointer
  `table_with_least_overlap` is checked against an O(n_a * n_b) nested loop
  (`src/lsm/manifest_level.zig:1509-1545`, test at `:1595`).
- **Exhaustive oracle for a small domain**: binary search is checked for every key count and every
  target key against a linear scan (`src/lsm/binary_search.zig:363-402`).
- **Shadow-memory oracle for an allocator**: the NodePool test (section 4).
- **Documented strategy at the top of the fuzzer**: `src/lsm/manifest_level_fuzz.zig:1-24` states
  the strategy and the invariants in prose before any code.
- **Smoke mode**: every fuzzer runs briefly with seed 123 as part of normal tests
  (`src/fuzz_tests.zig:91-126`), and a `canary` fuzzer that fails on purpose checks the
  infrastructure (`:52-53`, `:151-155`).

### 10.4 Deterministic simulation (VOPR)

#### Where

- `docs/internals/vopr.md:1-62`
- `docs/ARCHITECTURE.md:281-327`
- `docs/TIGER_STYLE.md:142-149`

#### What it does

The whole cluster runs on one thread with clock, network and disk replaced by seeded simulations
that inject faults (dropped and reordered packets, partitions, corrupted reads and writes). A
failure is reproduced from the seed plus the git commit. Assertions stay enabled in production and
turn silent corruption into crashes that the simulator finds. Extra checkers verify cross-replica
properties, for example that caught-up replicas' data files are byte-for-byte identical.

> Assertions are a force multiplier when used with simulation testing and fuzzing.
(`docs/internals/vopr.md:56`)

> But a fuzzer can prove only the presence of bugs, not their absence.
(`docs/TIGER_STYLE.md:143-144`)

### Teaching idea: "How to test a B-tree"

A chapter can be built directly on this:

1. Write `verify()` first: sorted within nodes, sorted across nodes, occupancy bounds, separator
   bounds, uniform leaf depth, count bookkeeping, no leaked nodes in the pool.
2. Reference model: a sorted `ArrayList` (Zig) or `BTreeMap` (Rust).
3. Seeded PRNG, operations as a tagged union, weighted phases (grow, shrink, drain).
4. Compare after every operation: point lookups, full forward and reverse scans, random range
   scans, lower-bound results.
5. Use tiny node capacities (2, 3, 4) so every insert splits and every delete merges.
6. Swarm weights and hot/cold keys.
7. Assert coverage goals at the end (reached maximum height, reached empty, exercised borrow-left
   and borrow-right).
8. For the on-disk chapters: make storage a comptime parameter, write an in-memory `Storage` that
   injects latency, torn writes and corruption from the same seed, and after a simulated crash
   reopen and compare with the model as of the last durable commit.
9. End the run with the pool's leak assertion (`deinit` asserts all nodes are free).

---

## 11. LSM vs B-tree trade-offs, as evidenced by the design

### What the source says about why LSM

```
- Particularly good at writes and TigerBeetle's workload is write-heavy
- Organized around batches of data, just like the rest of TigerBeetle
- Keeps hot data near the root while colder data sinks down to the lower level. This matches
  Pareto-distributed workload.
```
(`docs/ARCHITECTURE.md:384-387`)

The docs do not contain an explicit "we rejected B-trees because..." statement; the comparison
below is my reading of mechanisms that are verified in the source.

### Write path and write amplification

- All writes go to an in-memory mutable table that is an **append-only array**, sorted lazily per
  beat (`src/lsm/table_memory.zig:7-9`, `src/lsm/tree.zig:199-205`, `:564-566`). Delete is a put
  of a tombstone (`src/lsm/tree.zig:203-205`). There is no random in-place page write, so no
  page split on the commit path.
- A bar is 32 commits; a table is sized to one bar of updates (`src/constants.zig:646-654`,
  `docs/internals/lsm.md:26`).
- Each compaction merges **one** table from level A with at most `lsm_growth_factor` tables from
  level B (`docs/internals/lsm.md:122-138`, `src/lsm/compaction.zig:55-61`). So each value is
  rewritten up to about `growth_factor` times per level it descends, across up to 7 levels. The
  growth factor of 8 rather than 10 is an explicit choice to lower write amplification
  (`src/constants.zig:611-615`). `table_count_max_for_tree` asserts `growth_factor <= 16` with the
  comment "Limit excessive write amplification" (`src/lsm/tree.zig:642`).
- **Move-table optimisation**: if the chosen table overlaps nothing below, only metadata changes.
  "performance [approaches] that of an append-only log" for sorted inserts
  (`docs/internals/lsm.md:111-120`). TigerBeetle's object trees are keyed by timestamp, which is
  the favourable case.
- A small immutable table may be kept in memory and absorbed into the next bar instead of flushed
  (`src/lsm/table_memory.zig:24-27`, `src/lsm/tree.zig:583-597`).

B-tree contrast for the guide: a B-tree's write amplification is roughly one page write per
modified leaf (plus WAL, plus occasional splits), but each of those writes is random. Sequential
key inserts are also a B-tree's best case (right-edge appends).

### Read path and read amplification

- Lookup order: object cache/stash -> immutable table -> levels 0..6
  (`src/lsm/cache_map.zig:82-86`, `src/lsm/tree.zig:253-298`).
- Per level there is at most one candidate table (`src/lsm/manifest.zig:428-432`), and each costs
  an index block read plus a value block read. Worst case is 7 levels x 2 blocks = 14 block reads
  of 512 KiB each (derived), before caching. `table_count_max_for_tree` asserts `levels <= 10`:
  "Limit excessive read amplification" (`src/lsm/tree.zig:644`).
- Mitigations in the code: tree-wide and per-level key-range checks
  (`src/lsm/tree.zig:220-227`, `src/lsm/manifest.zig:419`); `key_min` check inside the index block;
  the grid block cache; a synchronous cache-only fast path that returns
  `negative | positive | possible` (`src/lsm/tree.zig:59-63`, `:253-298`); and prefetching all keys
  for a batch before executing it (groove prefetch, `src/lsm/cache_map.zig:21-23`).
- No bloom filters.
- Range scans must k-way merge `lsm_levels + 2` streams (`src/lsm/scan_tree.zig:25-35`, `:64-65`)
  using a loser tree (`src/lsm/k_way_merge.zig:1-19`). A B+tree range scan follows one leaf chain.

B-tree contrast: a point read is `height` page reads with no merging and no tombstones.

### Space

- Old and new copies coexist: compaction "does not modify tables in place — it copies data"
  (`docs/internals/lsm.md:152`), and released blocks are only reusable after the next checkpoint is
  durable (`src/vsr/free_set.zig:509-511`).
- Tombstones occupy space until they reach a level with nothing beneath them
  (`src/lsm/compaction.zig:27-30`, `src/lsm/manifest.zig:636-664`).
- Blocks may be partially filled; larger blocks increase this (`src/constants.zig:589`). Tables
  under 50% full are candidates for coalescing (`src/constants.zig:713-715`).
- On the other side, leaves are packed densely at build time, where a B-tree under random inserts
  settles at roughly 2/3 full (the 2/3 figure is general knowledge, **unverified** here).

### Pacing and determinism

- Compaction is scheduled by commit number, not by a background thread: `beat = op %
  lsm_compaction_ops`; even levels in the first half-bar, odd levels plus the immutable-table flush
  in the second (`docs/internals/lsm.md:44-52`).
- Work per beat is a **quota of input values**, known at the start of the half-bar and required to
  be deterministic, separate from physical IO counters that may differ between replicas
  (`src/lsm/compaction.zig:362-392`).
- Blocks for a half-bar are reserved up front in deterministic order
  (`docs/internals/lsm.md:70-71`, `src/vsr/free_set.zig:31-43`).
- Invariant: "At the end of every beat, there is space in mutable table for the next beat"
  (`docs/internals/lsm.md:61`). There are no write stalls by construction.
- Purpose: replicas converge on byte-identical data files, which permits repairing a single
  corrupt block from a peer by checksum (`docs/ARCHITECTURE.md:292-305`).

### Teaching idea

Frame the comparison chapter with a three-row scorecard (write amp, read amp, space amp) and fill
in each cell with a *mechanism* from this section and its B-tree counterpart. Then make the less
obvious point: TigerBeetle's choice is driven as much by **immutability** (checksummed
pointers, copy-on-write checkpoints, byte-identical replicas, bounded pre-allocated memory) as by
raw write throughput. Immutable sorted runs are far easier to make deterministic than a B-tree
whose page layout depends on the history of splits. A copy-on-write B-tree is the nearest B-tree
design that recovers some of these properties.

---

## 12. Smaller items a guide can borrow

- **Loser tree for k-way merge** stored in Eytzinger layout, struct-of-arrays, 64-byte aligned
  (`src/lsm/k_way_merge.zig:1-39`). Relevant to bulk-loading a B-tree from sorted runs and to
  the Eytzinger-layout discussion in an in-node search chapter.
- **Sentinel key** "must compare greater than all other keys" as a comptime parameter
  (`src/lsm/table.zig:51-52`), an alternative to optional/infinite separators.
- **Tombstone as a bit inside the value** (`src/lsm/composite_key.zig:30`, `:79-82`;
  `src/lsm/groove.zig:35-39`), so that "deleted" records keep the fixed record size.
- **`snapshot_latest = maxInt(u64) - 1`** with `maxInt` reserved to mean "not deleted"
  (`src/lsm/tree.zig:19-24`).
- **Three-way lookup result** `union(enum) { negative, positive: *const Value, possible: u8 }`
  (`src/lsm/tree.zig:59-63`): a clean way to express "cannot answer without IO", useful for a
  buffer-pool-backed B-tree.
- **Scopes with rollback** on the in-memory table: save `(count, run_tracker)`, restore on discard
  (`src/lsm/table_memory.zig:55-61`), a minimal transaction abort for an append-only buffer.
- **Schema in the block header** (`src/lsm/schema.zig:82-99`): self-describing pages.
- **`compile_log_layout` switch** that dumps the computed layout as a `@compileError`
  (`src/lsm/table.zig:146-205`): a neat debugging trick for comptime page layouts.

---

## Most important insights for a learner

1. **An on-disk LSM table is a static two-level B+tree.** Index block = internal node, value
   block = leaf. Bulk-built, 100% dense, immutable. Everything hard about B-trees (split, merge,
   concurrency on a page) is absent *because* it is immutable.
2. **Split/merge logic does not disappear; it moves to RAM.** `SegmentedArray` carries the
   B-tree leaf algorithms (midpoint split, merge-or-rebalance with the right sibling, half-full
   invariant) and is a compact, heavily asserted reference implementation.
3. **A one-level "tree" is O(nodes) per structural change.** Shifting the pointer array and
   updating prefix counts is what recursion (more levels) fixes. This is the cleanest motivation
   for tree height that I found in the codebase.
4. **Fan-out is arithmetic.** Block size, key size, and pointer size determine it; here a pointer
   is 40 bytes because it includes a checksum. Compute it at comptime and assert it.
5. **Pointers that carry checksums force copy-on-write** and buy detection of misdirected and
   stale reads, which a page-local checksum cannot detect.
6. **In-node search deserves care**: return an insertion index, keep the loop count data
   independent, make the comparison a conditional move, prefetch for large nodes, and assert the
   loop invariant.
7. **Secondary index = composite key (field, primary key) packed so integer order is
   lexicographic order.**
8. **A fixed-size node pool with a bitset** is all the allocator a B-tree needs after startup. The
   on-disk free set is the same idea with a delayed-reuse rule.
9. **Model-based fuzzing finds what unit tests do not**: seeded PRNG, simple reference model,
   compare after every step, tiny node sizes, and a `verify()` of every structural invariant.
10. **The trade-off triangle is visible in constants**: growth factor 8 (write amp), 7 levels
    (read amp), 512 KiB blocks (space vs metadata). Each has a comment explaining the direction.

---

## Zig idioms worth imitating in the guide's examples

(All from the pinned Zig 0.16.0 code base; re-verify syntax on 0.17.1.)

1. **Type-returning functions named `...Type`**, with `const Name = @This();` inside
   (`src/lsm/node_pool.zig:10-12`).
2. **Re-export generic parameters** as `pub const` (`src/lsm/table.zig:66-74`).
3. **`comptime { assert(...) }` blocks for layout and parameter sanity**
   (`src/lsm/node_pool.zig:18-25`, `src/lsm/table.zig:207-241`).
4. **Typed node pointer**: `*align(node_alignment) [node_size]u8` rather than `[]u8`
   (`src/lsm/node_pool.zig:16`); block pointer `*align(sector_size) [block_size]u8`
   (`src/vsr/grid.zig:23`).
5. **Comptime proof before `@ptrCast(@alignCast(...))`**
   (`src/lsm/segmented_array.zig:442-447`).
6. **Allocator passed positionally to `init` and again to `deinit`, never stored**
   (`src/lsm/node_pool.zig:30`, `:45`).
7. **In-place init through `self: *T`**, `self.* = .{ .field = undefined, ... }`, then fill each
   field followed immediately by its `errdefer` (`src/lsm/tree.zig:121-149`).
8. **`errdefer` loop for partially initialised arrays** (`src/lsm/manifest.zig:212-216`).
9. **`deinit` asserts no leaks** (`src/lsm/node_pool.zig:46-48`) and ends with
   `self.* = undefined` (`src/lsm/manifest_level.zig:193`).
10. **Pool passed per call** (`insert_element(node_pool, ...)`), so many structures share one pool
    (`src/lsm/segmented_array.zig:215-219`).
11. **`options: struct` for named arguments**, anonymous struct parameters for ad hoc ones
    (`src/lsm/tree.zig:341-347`).
12. **`comptime options: Options` with `verify: bool`**; `if (options.verify) array.verify();` at
    entry and exit of each public function (`src/lsm/segmented_array.zig:43-47`, `:221`, `:229`).
13. **Global `constants.verify`** gating O(n) asserts in hot loops
    (`src/lsm/binary_search.zig:46`).
14. **Checked copy helpers** with `.exact` / `.inexact` precision
    (`src/stdx/stdx.zig:119-200`).
15. **`maybe(cond)`** to document that both outcomes are expected (`src/stdx/stdx.zig:396-403`).
16. **`packed struct(Int)` + `@bitCast` for composite sort keys**
    (`src/lsm/manifest_level.zig:56-71`).
17. **`extern struct` + `no_padding` assertion + explicit zero padding fields for anything written
    to disk** (`src/lsm/composite_key.zig:22-62`, `src/lsm/schema.zig:573-577`).
18. **Typed views over a byte block**: `mem.bytesAsSlice(Key, block[offset..][0..size])`
    (`src/lsm/table.zig:460-469`); the `values[start..][0..count]` slicing idiom
    (`src/lsm/binary_search.zig:298`).
19. **Optional pointers purely for safety checks**: `nodes: *[node_count_max]?*[node_capacity]T`
    with the comment "We only use optional pointers here to get safety checks"
    (`src/lsm/segmented_array.zig:118-120`).
20. **Explicit integer widths** (`u32` counts and indexes) and saturating ops (`-|`) where intended
    (`docs/TIGER_STYLE.md:102`, `src/lsm/segmented_array.zig:110`, `:410`).
21. **`@divExact`** wherever divisibility is an invariant (`src/lsm/node_pool.zig:79`).
22. **`@branchHint(.unpredictable)`** on the binary-search step (`src/lsm/binary_search.zig:110`).
23. **Result as `union(enum)`** instead of error codes or nullable-with-flags
    (`src/vsr/grid.zig:122-136`, `src/lsm/tree.zig:310-320`).
24. **`@fieldParentPtr` for intrusive callbacks and embedded sub-structs**
    (`src/lsm/tree.zig:432`, `src/lsm/manifest_level.zig:105`).
25. **Names with units last, most significant word first**: `value_count_max`,
    `table_count_visible`, `node_count_max_naive` (`docs/TIGER_STYLE.md:291-295`).
26. **Allocator names carry meaning**: `gpa` vs `arena` (`docs/TIGER_STYLE.md:297-299`).
27. **State enums asserted on every transition** for resources (`ScratchMemory.state`,
    `Builder.state`, `StaticAllocator.state`): `src/lsm/scratch_memory.zig:38-42`,
    `src/lsm/table.zig:256-274`, `src/static_allocator.zig:14-44`.
28. **No recursion** (`docs/TIGER_STYLE.md:90-92`): search and iteration are loops. For the guide,
    this suggests iterative descent with an explicit bounded path array sized by a comptime maximum
    height.
29. **Operator-facing fatal error rather than `error.OutOfMemory` after init**
    (`src/lsm/node_pool.zig:57-62`). Note the TODO there: the intended design is to reject requests
    earlier so that the pool can never be exhausted.

---

## Things that are easy to get wrong

1. **Calling TigerBeetle's storage a B-tree.** It is an LSM forest. The B-tree-like parts are the
   per-table index/value blocks and the in-memory segmented array.
2. **Assuming the half-full invariant holds for every node.** The last node is exempt
   (`src/lsm/segmented_array.zig:192-195`), as a B-tree root is.
3. **Odd node capacity.** Capacity is rounded down to even so midpoint split/join is symmetric
   (`src/lsm/segmented_array.zig:73-79`). With an odd capacity the "two halves always fit in one
   node" reasoning breaks.
4. **Unbounded batch removes.** Batches are limited to half a node so at most two nodes are touched
   and at most one empties (`src/lsm/segmented_array.zig:484-487`).
5. **Off-by-one in the first-level search.** It must round *down* to the node whose first key is
   `<=` the target and never return `node_count`; then, if the in-node result is one past the end
   and a next node exists, normalise to `(node + 1, 0)` (`src/lsm/segmented_array.zig:925-957`).
6. **`key_max` routing vs separator routing.** Searching `key_max[]` with a lower-bound search
   yields the child directly, but the result must still be checked against `key_min` because gaps
   exist between children (`src/lsm/table.zig:498-501`). For range scans, the end index needs a
   similar adjustment (`src/lsm/scan_tree.zig:822-829`).
7. **Lower bound vs upper bound with duplicates.** The mode is a comptime parameter and the two
   differ only in `<` vs `<=`. Descending iteration from a left-biased search result is surprising;
   the test comment says "Descending iterators are weird"
   (`src/lsm/segmented_array.zig:1006-1008`), and `ManifestLevel` needs an explicit boundary scan
   to compensate (`src/lsm/manifest_level.zig:512-546`).
8. **Holding pointers into nodes across a mutation.** Splits and merges move elements. TigerBeetle
   guards with a generation counter and with an assertion that `remove_table`'s argument does not
   alias the array (`src/lsm/manifest_level.zig:264`, `:296-299`).
9. **Prefetching "for free".** It only pays when bounds checks are removed for the prefetch address
   computation, and only for nodes that do not fit in cache (`src/lsm/binary_search.zig:70-74`,
   `src/lsm/binary_search_benchmark.zig:26-37`).
10. **Padding bytes in on-disk structs.** Uninitialised padding breaks checksums and determinism;
    hence `extern struct`, explicit padding fields, `no_padding` asserts, and zeroing the unused
    tail of a block (`src/lsm/table.zig:94-96`, `:435-437`, `docs/TIGER_STYLE.md:436-438`).
11. **Trusting a page's own checksum.** It cannot detect a valid page at the wrong address or a
    stale version. The expected checksum must come from the parent
    (`src/vsr/grid.zig:1438`, `docs/internals/data_file.md:39-41`).
12. **Reusing freed pages immediately.** With checkpoint-based recovery a freed block must stay
    untouched until the next checkpoint is durable (`src/vsr/free_set.zig:509-533`).
13. **Confusing "static allocation" with "arena with a limit".** The source distinguishes them
    explicitly (`docs/ARCHITECTURE.md:200-206`): limits are derived for every object type, so the
    pool is meant never to run out.
14. **Storing the allocator in every struct.** The code base passes it to `init` and `deinit`
    only; runtime paths use pools.
15. **O(n) assertions in hot loops with no guard.** They reduce fuzzing throughput and therefore
    coverage (`src/constants.zig:789-791`). Guard with a comptime flag.
16. **Tombstones dropped too early.** A tombstone may only be dropped when no deeper level can
    contain the key (`src/lsm/manifest.zig:636-664`). The analogous B-tree mistake is physically
    removing a record that an older snapshot can still see.
17. **Fuzzing only with realistic node sizes.** Node capacity 2 to 16 is where the bugs are
    (`src/lsm/segmented_array.zig:1466-1480`); production-size nodes almost never split or merge in
    a short run.
18. **Not checking that the fuzzer reached the interesting states.** See the coverage assertions
    at `src/lsm/segmented_array.zig:1508-1509` and `:1181`.
19. **Comparing sizes across configs.** Fuzzers and unit tests use the `test_min` config
    (4 KiB blocks, growth factor 4, 4 beats per bar; `src/config.zig:258-268`), so numbers observed
    in tests differ from production numbers in section 1.
20. **Copying 0.16 syntax into a 0.17.1 guide unchanged.** Allocator vtable fields, alignment
    types, `std.ArrayList` management style, `callconv(.@"inline")` and `main` signatures are the
    likely points of drift.
