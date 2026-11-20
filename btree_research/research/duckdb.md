# DuckDB research notes: what an engine WITHOUT a B-tree teaches about B-trees

Source studied: `/home/user/ai_lab/db_study/duckdb`, shallow clone at commit `9d8ecca6dac5b82e49648c45cd5134bb7342d018` ("Add `LogicalType::GEOGRAPHY` (and v2.1.0 storage version)"). All paths below are relative to that directory. Line numbers are from that commit.

Conventions used in these notes:

- "Verified" = read in the source at the cited file:line.
- "(computed)" = a number I derived by re-running the source's arithmetic or by compiling a struct with the same field layout on x86-64 (g++); it is not written as a literal in the source.
- "(unverified)" = from memory / general database knowledge, not checked in this tree.
- Zig/Rust fragments are teaching sketches written for these notes. They were not compiled.

Contents

1. Is there a B-tree anywhere in DuckDB? (verification)
2. The 64-bit tagged node pointer (IndexPointer / NodePtr)
3. ART inner nodes: Node4 / Node16 / Node48 / Node256
4. Grow and shrink (with hysteresis) versus B-tree split and merge
5. Prefix compression (path compression) and prefix splitting
6. Leaves: inlined row IDs, "gates" and nested ARTs for duplicates
7. Key encoding: turning values into binary-comparable bytes
8. Point lookup
9. Insert
10. Delete and the four-handle pin window
11. Range scan: the iterator (no sibling pointers)
12. Bulk build from sorted keys, and structural merge of two ARTs
13. FixedSizeAllocator: a bitmap slab allocator on buffer-managed blocks
14. Vacuum: compaction for a pointer-based tree
15. Serialization: how the ART goes to disk (checkpoint, lazy load, WAL)
16. Concurrency: one mutex per index
17. Zone maps: min/max statistics instead of a secondary index
18. When does DuckDB actually use the index? (the scan threshold)
19. Single-file storage: fixed-size blocks, double header, free list
20. Metadata blocks, partial blocks, buffer pool
21. Finding a row group by row id: a sorted array, not a tree
22. Sorting and merging (brief)
23. Comparison: B+tree vs ART vs zone maps, and why OLAP chooses this
24. Numbers cheat sheet
25. Most important insights for a learner
26. Things that are easy to get wrong

---

## 1. Is there a B-tree anywhere in DuckDB? (verification)

### What it does

The claim "DuckDB has no B-tree" holds for this commit. A case-insensitive search for `b-tree`, `b+tree`, `btree`, `BTreeMap`, `btree_map`, `bplus` over the whole tree (excluding `.git`, data and test files) finds exactly four hits, and all four are the same comment listing possible index types. There is no B-tree implementation in `src/`, `extension/` or `third_party/`.

The only built-in index type is `ART` (`src/execution/index/art/`). The ordered structures that do exist are:

- `std::set` / `std::map` from the C++ standard library (a balanced binary tree in common implementations, typically red-black (unverified)). The block free list is one of these, see section 19.
- `third_party/skiplist/`, a skip list used only by the quantile aggregate (`extension/core_functions/include/core_functions/aggregate/quantile_state.hpp` includes it).
- `third_party/jemalloc/include/jemalloc/internal/rb.h` (by its name a red-black tree; not opened in detail, (unverified)).
- Sorted arrays with binary search (row group lookup, section 21) and sorted runs (section 22).

### Where (file:line)

- `src/include/duckdb/execution/index/bound_index.hpp:75`
- `src/include/duckdb/storage/index.hpp:63`
- `src/include/duckdb/catalog/catalog_entry/index_catalog_entry.hpp:33`
- `src/include/duckdb/parser/parsed_data/create_index_info.hpp:38`
- `src/include/duckdb/execution/index/art/art.hpp:48` (`TYPE_NAME = "ART"`)
- `src/include/duckdb/storage/single_file_block_manager.hpp:216` (`set<block_id_t> free_list;`)

### Snippet

```cpp
// bound_index.hpp:75 (the same comment appears in the three other files)
//! The index type (ART, B+-tree, Skip-List, ...)
```

### Teaching idea

Open the "beyond B-trees" chapter with this fact: a widely used analytical database ships no B-tree at all. Then ask the reader to predict which B-tree jobs still have to be done by something else. The list is the outline of the chapter: ordered lookup (ART), range pruning (zone maps), page allocation (free list), locating a row by position (sorted array), ordered output (sort and merge).

---

## 2. The 64-bit tagged node pointer (IndexPointer / NodePtr)

### What it does

ART nodes do not hold raw memory addresses. A child reference is one 64-bit word split into three fields: 8 bits of metadata (node type, plus one "gate" bit), a 24-bit segment offset, and a 32-bit buffer id. The pair (buffer id, offset) names a slot in a slab allocator (section 13), so the same word is valid in memory and on disk: there is no pointer swizzling step when a tree is loaded.

`NodePtr` adds ART meaning on top: the low 7 metadata bits are the node type (`NType`), the top bit `0x80` is the gate flag. For the type `LEAF_INLINED` the lower 56 bits are not a location at all, they are the row id itself.

### Where (file:line)

- `src/include/duckdb/execution/index/index_pointer.hpp:19-24` (shifts and masks), `:86-98` (layout diagram), `:101` (`static_assert` that it is 8 bytes)
- `src/include/duckdb/execution/index/art/node.hpp:24-35` (`NType`), `:120-122` (`AND_GATE`, `AND_ROW_ID`), `:194-196` (`GetType`), `:206-212` (`GetRowId` / `SetRowId`)
- `src/common/constants.cpp:10-11` (`MAX_ROW_ID`, `MAX_ROW_ID_LOCAL`, commented as 2^55 and 2^56)

### Snippet

```cpp
// index_pointer.hpp:87-93
//! Bit layout:
//! MSB                                                                        LSB
//! 63         56 55                      32 31                                  0
//! +------------+--------------------------+------------------------------------+
//! |  Metadata  |           Offset         |           Buffer ID                |
//! |   8 bits   |          24 bits         |            32 bits                 |
//! +------------+--------------------------+------------------------------------+
```

```cpp
// node.hpp:24-35
enum class NType : uint8_t {
	PREFIX = 1, LEAF = 2, NODE_4 = 3, NODE_16 = 4, NODE_48 = 5, NODE_256 = 6,
	LEAF_INLINED = 7, NODE_7_LEAF = 8, NODE_15_LEAF = 9, NODE_256_LEAF = 10,
};
```
(the enum is reflowed onto fewer lines here; values are as in the source)

### Teaching idea

Chapter idea: "pointers that survive a restart". Compare three ways to refer to a child node:

1. a raw pointer (fast, useless on disk),
2. a B-tree page number (works on disk, needs a buffer pool lookup),
3. this tagged (type, slot, buffer) handle.

Zig sketch using a packed struct, which makes the bit layout explicit and checked at compile time:

```zig
const NodeType = enum(u7) { prefix = 1, leaf = 2, node4 = 3, node16 = 4, node48 = 5,
                            node256 = 6, leaf_inlined = 7, node7_leaf = 8, node15_leaf = 9, node256_leaf = 10 };

const NodePtr = packed struct(u64) {
    buffer_id: u32, // bits 0..31
    offset: u24,    // bits 32..55
    node_type: u7,  // bits 56..62
    gate: bool,     // bit 63

    fn isEmpty(self: NodePtr) bool { return @as(u64, @bitCast(self)) >> 56 == 0; }
    fn rowId(self: NodePtr) u56 { return @truncate(@as(u64, @bitCast(self))); }
};
comptime { std.debug.assert(@sizeOf(NodePtr) == 8); }
```

Animation: a 64-cell bit strip; hovering a field highlights which allocator and which slot it selects.

---

## 3. ART inner nodes: Node4 / Node16 / Node48 / Node256

### What it does

An inner node consumes exactly one key byte and maps it to a child. There are four physical layouts, chosen by how many children the node has:

| Type | Capacity | Layout | Child search |
|---|---|---|---|
| Node4 | 4 | `count`, sorted `key[4]`, `children[4]` | linear scan over `key[]` |
| Node16 | 16 | `count`, sorted `key[16]`, `children[16]` | linear scan over `key[]` (plain loop in this code, no SIMD) |
| Node48 | 48 | `count`, `child_index[256]` (byte to slot, 48 = empty), `children[48]` | one array index, then one more |
| Node256 | 256 | `count`, `children[256]` | one array index |

Node4 and Node16 are the same template, `BaseNode<CAPACITY, TYPE>`. In Node4 and Node16 the key bytes are kept sorted, so in-order iteration is a left-to-right walk. In Node48 and Node256 order comes for free by iterating the byte value 0..255.

Segment sizes (computed, x86-64 layout): Node4 = 40 bytes, Node16 = 152, Node48 = 648, Node256 = 2056.

### Where (file:line)

- `src/include/duckdb/execution/index/art/base_node.hpp:17-33` (template and fields), `:72-82` (`GetChildNode`), `:160-166` (Node4), `:179-185` (Node16)
- `src/include/duckdb/execution/index/art/node48.hpp:25-39` (constants and fields), `:89-97` (`GetChildNode`)
- `src/include/duckdb/execution/index/art/node256.hpp:22-34`, `:80-85`
- `src/execution/index/art/node.cpp:375-384` (`GetInternalNodeType`: pick a type for a child count)

### Snippet

```cpp
// base_node.hpp:30-33
private:
	uint8_t count;
	uint8_t key[CAPACITY];
	NodePtr children[CAPACITY];
```

```cpp
// node48.hpp:36-39 and :89-97 (GetChildNode, error check removed)
	uint8_t count;
	uint8_t child_index[Node256::CAPACITY];
	NodePtr children[CAPACITY];
...
	if (n.child_index[byte] != EMPTY_MARKER) {
		return n.children[n.child_index[byte]];
	}
	return OptionalNodePtr();
```

### Teaching idea

This is the cleanest contrast with a B-tree node:

- A B-tree node holds many full keys and does a binary search by comparing whole keys. Fan-out depends on key size.
- An ART node holds no keys at all, only single bytes. Fan-out is at most 256 and the "search" is an array index or a scan over at most 16 bytes. Tree height depends on key length, not on the number of keys.

Rust sketch of the four layouts as one enum (boxed so the enum stays small):

```rust
enum Inner {
    N4   { count: u8, keys: [u8; 4],  children: [NodePtr; 4]  },
    N16  { count: u8, keys: [u8; 16], children: [NodePtr; 16] },
    N48  { count: u8, index: Box<[u8; 256]>, children: Box<[NodePtr; 48]> }, // 48 = empty
    N256 { count: u16, children: Box<[NodePtr; 256]> },
}
```

Visualization: four panels showing the same set of child bytes stored in each layout, with a "find byte 0x6B" button that lights up the cells each layout touches (4 compares, up to 16 compares, 2 lookups, 1 lookup).

---

## 4. Grow and shrink (with hysteresis) versus B-tree split and merge

### What it does

When a node is full and another child arrives, it is copied into the next larger layout and the old segment is freed. Nothing propagates to the parent except the changed pointer value: the parent's slot is passed by reference and overwritten. This is the ART counterpart of a B-tree split, but it is always local to one node.

Shrinking uses thresholds that are lower than the smaller node's capacity, so a node that sits on a boundary does not grow and shrink on every alternate insert and delete:

- Node256 shrinks to Node48 when `count <= 36` (`Node256::SHRINK_THRESHOLD`)
- Node48 shrinks to Node16 when `count < 12` (`Node48::SHRINK_THRESHOLD`)
- Node16 shrinks to Node4 when `count < 4`
- Node4 with a single remaining child is removed and its byte is folded into a prefix (section 5)

Node48 has one extra detail: after deletes its `children` array has holes, so an insert first tries slot `count` and otherwise scans for the first empty slot.

### Where (file:line)

- `src/execution/index/art/base_node.cpp:61-76` (Node4 insert, grow), `:78-102` (Node4 delete, one-way compression), `:142-153` (Node16 delete, shrink), `:155-171` (`GrowNode4`)
- `src/execution/index/art/node48.cpp:8-36` (insert, hole search, grow), `:38-56` (delete, shrink), `:58-74`
- `src/execution/index/art/node256.cpp:14-31` (delete, shrink), `:33-50` (`GrowNode48`)
- `src/include/duckdb/execution/index/art/node48.hpp:29`, `node256.hpp:25` (thresholds)

### Snippet

```cpp
// base_node.cpp:61-76
void Node4::InsertChild(ART &art, NodePtr &node_ptr, const uint8_t byte, const NodePtr child_ptr) {
	{
		NodeHandle handle(art, node_ptr);
		auto &n = handle.Get<Node4>();
		if (n.count != CAPACITY) {
			InsertChildInternal(n, byte, child_ptr);
			return;
		}
	}
	// The node is full.
	// Grow to Node16.
	auto node4_ptr = node_ptr;
	Node16::GrowNode4(art, node_ptr, node4_ptr);
	Node16::InsertChild(art, node_ptr, byte, child_ptr);
}
```
(one blank line removed)

### Teaching idea

Side-by-side animation: insert the same 20 keys into a B-tree of order 4 and into an ART. In the B-tree a split pushes a separator key upward and can cascade to the root. In the ART a node changes shape in place and the parent only sees a new pointer value. Then delete keys one by one and show a counter of "node reallocations" with and without hysteresis (thresholds 4/16/48 versus 3/11/36).

Exercise: explain why a B-tree needs a minimum fill of about half a node and an ART does not (the ART layouts are the fill classes).

---

## 5. Prefix compression (path compression) and prefix splitting

### What it does

A chain of nodes with one child each would waste a level per key byte. DuckDB stores such a run of bytes in a separate node type, `PREFIX`. A prefix segment is `prefix_count` data bytes, one count byte, and one child `NodePtr`. If the run is longer than `prefix_count` bytes, several prefix nodes are chained.

`prefix_count` is chosen per index from the key type so that a typical key suffix fits in one segment (`ART::SetPrefixCount`): the compound key width is rounded up to a multiple of 8, minus 1, capped at 239. For a single 8-byte integer key this gives 7 data bytes, and a 16-byte segment (7 + 1 count + 8 child) (computed from the formula). Older files used a fixed 15.

When a new key diverges in the middle of a prefix, the prefix is split: the bytes before the mismatch stay, a new Node4 is inserted at the mismatch, and the remaining bytes become a new prefix under that Node4.

Unlike the original ART paper's inner-node header prefix (unverified description of the paper), here a prefix is its own node, so every prefix costs one more pointer hop.

### Where (file:line)

- `src/include/duckdb/execution/index/art/prefix.hpp:18-29` (layout constants)
- `src/execution/index/art/prefix.cpp:42-55` (`NewInternal`), `:57-69` (`New`, chaining), `:71-94` (`Reduce`)
- `src/execution/index/art/art.cpp:1258-1287` (`SetPrefixCount`), `:126` (prefix segment size)
- `src/execution/index/art/prefix_handle.cpp:143-188` (`Split`)
- `src/include/duckdb/execution/index/art/art_operator.hpp:475-485` (`InsertIntoPrefix`)

### Snippet

```cpp
// prefix.cpp:57-69
void Prefix::New(ART &art, reference<NodePtr> &node_ptr_ref, const ARTKey &key, const idx_t depth, idx_t count) {
	idx_t offset = 0;
	while (count) {
		auto min = MinValue(UnsafeNumericCast<idx_t>(art.PrefixCount()), count);
		auto this_count = UnsafeNumericCast<uint8_t>(min);
		auto prefix = NewInternal(art, node_ptr_ref, key.data, this_count, offset + depth);
		node_ptr_ref = *prefix.child_slot;
		offset += this_count;
		count -= this_count;
	}
}
```
(two blank lines removed)

```cpp
// art_operator.hpp:479-484
	NodePtr branching_node4_ptr;
	Node4::New(art, branching_node4_ptr);
	auto child_ptr = PrefixHandle::Split(art, node_ptr, branching_node4_ptr, cast_pos);

	Node4::InsertChild(art, branching_node4_ptr, byte, child_ptr);
	InsertIntoNode(art, branching_node4_ptr, key, row_id, depth, status);
```

### Teaching idea

Relate this to B-tree prefix truncation: a B+tree compresses separators (it stores only as many bytes as are needed to distinguish neighbours), an ART compresses paths (it skips levels with no branching). Both exploit shared prefixes.

Animation: insert `"romane"`, then `"romanus"`, then `"romulus"`. Show the single prefix node being split twice. A first key in an empty ART is exactly one prefix chain ending in an inlined leaf (`art_operator.hpp:143-147`).

---

## 6. Leaves: inlined row IDs, "gates" and nested ARTs for duplicates

### What it does

There are three kinds of leaf (comment at `leaf.hpp:17-22`):

1. `LEAF_INLINED`: the row id lives inside the 8-byte `NodePtr` itself. A unique index needs no leaf allocation at all.
2. `LEAF`: deprecated linked list of 4 row ids per node, kept for old files.
3. Nested leaves behind a "gate": when one key maps to several row ids (non-unique index), the row ids are treated as 8-byte keys of a second ART that hangs below the key. The pointer into that nested tree has the gate bit set. When traversal crosses a gate it switches from "key bytes" to "row id bytes" and resets depth to 0.

At the bottom of a nested ART the last row id byte is stored in a compact set node, not in child pointers: `Node7Leaf` (7 sorted bytes), `Node15Leaf` (15 sorted bytes), `Node256Leaf` (a 256-bit bitmap). Sizes (computed): 8, 16 and 40 bytes.

### Where (file:line)

- `src/include/duckdb/execution/index/art/leaf.hpp:17-39`
- `src/execution/index/art/leaf.cpp:16-21` (`Leaf::New` inlines a row id), `:23-79` (`MergeInlined`: two row ids under one key become a gate)
- `src/include/duckdb/execution/index/art/base_leaf.hpp:30-32`, `:80-87`, `:100-107`
- `src/include/duckdb/execution/index/art/node256_leaf.hpp:32-34`
- `src/include/duckdb/execution/index/art/art_operator.hpp:159-166` (entering a gate during insert)

### Snippet

```cpp
// leaf.cpp:16-21
void Leaf::New(NodePtr &node_ptr, const row_t row_id) {
	D_ASSERT(row_id < MAX_ROW_ID_LOCAL);
	node_ptr.Clear();
	node_ptr.SetMetadata(static_cast<uint8_t>(INLINED));
	node_ptr.SetRowId(row_id);
}
```

```cpp
// art_operator.hpp:159-166 (inside Insert)
		if (status == GateStatus::GATE_NOT_SET && active_node_ptr.GetGateStatus() == GateStatus::GATE_SET) {
			if (!art.IsUnique()) {
				// Enter a gate.
				active_key_ref = row_id;
				depth = 0;
				status = GateStatus::GATE_SET;
				continue;
			}
```

### Teaching idea

Chapter idea: "what goes in the leaf?" Compare the classic choices for duplicate keys in a B+tree (repeat the key, append the row id to the key to make it unique, or store a posting list (unverified as a survey)) with DuckDB's answer, which is the second option in disguise: the row id is a key suffix, and the gate bit marks where the user key ends.

Visualization: a non-unique index on a `status` column with three distinct values and thousands of rows. Show the tiny top tree, three gates, and three large nested trees. This also motivates why low-cardinality columns are poor index candidates.

---

## 7. Key encoding: turning values into binary-comparable bytes

### What it does

A radix tree compares keys byte by byte from the left, as unsigned bytes. So every supported type is transformed so that plain `memcmp` order equals the type's value order:

- Unsigned integers: byte-swap to big-endian.
- Signed integers: byte-swap to big-endian, then flip the sign bit (XOR the first byte with 0x80).
- Floats and doubles: map zero to a fixed pattern, NaN to all ones, +infinity to all ones minus one, -infinity to 0; otherwise set the sign bit for non-negative values and bitwise-invert negative values; then big-endian.
- Strings: copy the bytes, but put the escape byte `0x01` in front of every byte that is `0x00` or `0x01`, and append a `0x00` terminator. The terminator guarantees that no key is a strict prefix of another key, which a radix tree with values only at the leaves requires.
- 128-bit integers: upper half (signed or unsigned), then lower half unsigned.
- Compound keys: concatenate the encoded columns (`ARTKey::Concat`).
- NULLs: produce an empty key, and empty keys are skipped on insert.

Accepted key types are fixed in the constructor: BOOL, INT8..INT128, UINT8..UINT128, FLOAT, DOUBLE, VARCHAR.

### Where (file:line)

- `src/include/duckdb/common/radix.hpp:45-47` (`FlipSign`), `:49-78` (`EncodeFloat`), `:103-` (`EncodeDouble`), `:165-172` (`EncodeSigned`), `:201-225` (unsigned and 128-bit)
- `src/execution/index/art/art_key.cpp:20-49` (string escaping), `:66-110` (dispatch by physical type), `:146-152` (`Concat`)
- `src/execution/index/art/art.cpp:100-119` (allowed types), `:352-371` (key generation, NULL to empty key), `:634-637` (empty keys skipped)

### Snippet

```cpp
// radix.hpp:165-172
template <class T>
void Radix::EncodeSigned(data_ptr_t dataptr, T value) {
	using UNSIGNED = typename MakeUnsigned<T>::type;
	UNSIGNED bytes;
	Store<T>(value, data_ptr_cast(&bytes));
	Store<UNSIGNED>(BSwapIfLE(bytes), dataptr);
	dataptr[0] = FlipSign(dataptr[0]);
}
```

```cpp
// art_key.cpp:36-48
	// Copy over the data and add escapes.
	idx_t pos = 0;
	for (idx_t i = 0; i < string_len; i++) {
		if (string_data[i] <= 1) {
			// Add escape.
			key_data[pos++] = '\01';
		}
		key_data[pos++] = string_data[i];
	}

	// End with a null-terminator.
	key_data[pos] = '\0';
	return ARTKey(key_data, key_len);
```

### Teaching idea

This topic belongs in a B-tree guide too: a B-tree that stores order-preserving byte strings can use `memcmp` as its only comparator, and gets prefix truncation for free. Give it its own short chapter, "one comparator to rule them all".

Rust sketch:

```rust
fn encode_i64(v: i64) -> [u8; 8] {
    let mut b = v.to_be_bytes();
    b[0] ^= 0x80; // flip the sign bit: negatives now sort before positives
    b
}

fn encode_str(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() + 1);
    for &c in s {
        if c <= 1 { out.push(1); } // escape 0x00 and 0x01
        out.push(c);
    }
    out.push(0); // terminator: no key is a prefix of another
    out
}
```

Interactive widget: type two numbers or strings, see both encodings as hex, and see the first differing byte highlighted. Test cases worth including: -1 versus 1, -0.0 versus 0.0, NaN, `"a"` versus `"a\0"`, `"ab"` versus `"a"`.

Exercise: why must byte `0x01` be escaped as well as `0x00`? (Otherwise an escaped `0x00` could not be told apart from a literal `0x01` followed by `0x00`.)

---

## 8. Point lookup

### What it does

`ARTOperator::Lookup` walks from the root. At a prefix node it compares the stored bytes with the key bytes one by one and fails on the first mismatch. At an inner node it asks for the child at `key[depth]`. It stops when it reaches any leaf or a gate. There are no key comparisons against stored full keys and no binary search.

The cost is bounded by the encoded key length (at most 8 inner nodes for an 8-byte key, usually fewer because of prefixes), independent of the number of keys in the index.

A lookup returns a leaf pointer; row ids are then collected through the iterator so that a gate (many row ids) and an inlined leaf (one row id) are handled by the same code (`ART::SearchEqual`).

### Where (file:line)

- `src/include/duckdb/execution/index/art/art_operator.hpp:25-61` (`Lookup`), `:63-120` (`LookupInLeaf`)
- `src/execution/index/art/art.cpp:801-812` (`SearchEqual`)

### Snippet

```cpp
// art_operator.hpp:30-34 and :49-57 (the prefix branch at :35-47 is omitted)
		while (current_ptr.HasMetadata()) {
			if (current_ptr.IsAnyLeaf() || current_ptr.GetGateStatus() == GateStatus::GATE_SET) {
				return current_ptr;
			}
			...
			auto child_ptr = current_ptr.GetChildNode(art, key[depth]);
			if (!child_ptr) {
				return OptionalNodePtr();
			}

			current_ptr = child_ptr.Get();
			depth++;
		}
```

### Teaching idea

Two counters next to each tree in a visualization: "key comparisons" and "nodes visited". For a B+tree with n keys and fan-out f the search does about log_f(n) node visits and log2(f) comparisons in each (unverified, textbook). For the ART it is "at most key length" node visits and zero full-key comparisons. Let the reader slide n from 10^3 to 10^9 and watch only the B-tree number change.

Point out the cost that the counters hide: every ART step is a dependent load from a different slab, so an ART lookup is a short chain of likely cache misses, where a B+tree lookup is a shorter chain of misses with a longer in-node search.

---

## 9. Insert

### What it does

`ARTOperator::Insert` is an iterative loop with five cases on the node type under the cursor:

- empty tree: create a prefix chain for the whole key and an inlined leaf;
- `LEAF_INLINED`: a key already exists here. For a unique index this is a constraint violation (with special cases for delete-then-reinsert inside one transaction); otherwise the two row ids are merged into a gate;
- nested leaf node: add the last row id byte;
- inner node: descend if the child exists, otherwise `InsertIntoNode` adds a new child (a prefix chain plus inlined leaf for the rest of the key);
- prefix: compare bytes; on a mismatch, split the prefix (section 5).

A whole chunk is inserted key by key; if one key violates a constraint, the keys inserted so far in that chunk are deleted again (`ART::InsertKeys`).

The loop keeps the parent node pinned while it holds a reference to the child slot inside it (`parent_node_handle`), because that slot may be rewritten when the child grows.

### Where (file:line)

- `src/include/duckdb/execution/index/art/art_operator.hpp:126-252` (`Insert`), `:410-448` (`InsertIntoInlined`), `:450-473` (`InsertIntoNode`)
- `src/execution/index/art/art.cpp:626-680` (`InsertKeys`, rollback of a partial chunk at `:646-656`)

### Snippet

```cpp
// art_operator.hpp:461-472 (InsertIntoNode, outside a gate)
		NodePtr leaf_ptr;
		if (depth + 1 < key.len) {
			// Outside of gates, we create a prefix for the inlined leaf.
			auto count = key.len - depth - 1;
			auto chain = PrefixHandle::New(art, key, depth + 1, count);
			Leaf::New(chain.tail.Child(art), row_id.GetRowId());
			leaf_ptr = chain.root_ptr;
		} else {
			Leaf::New(leaf_ptr, row_id.GetRowId());
		}

		NodePtr::InsertChild(art, node_ptr, key[depth], leaf_ptr);
```

### Teaching idea

Contrast the write pattern with a B+tree leaf insert. A B+tree insert shifts entries inside one page and occasionally splits; write amplification is "one page". An ART insert touches a few small segments in different slabs (a prefix, a Node4, perhaps a grown node), each of which dirties a whole 256 KiB buffer for the next checkpoint (section 15).

Exercise for the Zig or Rust implementation: implement insert with a `*NodePtr` (Zig) or `&mut NodePtr` (Rust) cursor that always points at the slot to be overwritten. This "pointer to the parent's slot" idiom is what makes grow and split local, and it is the same idiom a B-tree implementation needs for root replacement.

---

## 10. Delete and the four-handle pin window

### What it does

Delete walks down to the leaf, then repairs the path: removing a child can shrink a node, and a Node4 left with one child is replaced by a prefix that concatenates the byte into its neighbours (`PrefixHandle::Concat`). To do that, the code needs access to up to three levels above the leaf. It keeps a sliding window of four handles (great-grandparent, grandparent, parent, current) so that the number of pinned nodes stays constant no matter how deep the tree is.

Because nodes can be freed during the repair, each handle owns a pin on the node that stores the pointer, and the callee releases that pin before freeing.

### Where (file:line)

- `src/include/duckdb/execution/index/art/art_operator.hpp:257-285` (window setup), `:298-327` (leaf found, repair)
- `src/execution/index/art/base_node.cpp:78-102` (Node4 one-way compression)
- `src/include/duckdb/execution/index/art/node_handle.hpp:89-125` (`NodePtrHandle`)

### Snippet

```cpp
// art_operator.hpp:277-285
		// Moves the window one level down: each level takes the handle of the level below it, so current becomes the
		// parent and the great-grandparent's pin is dropped. current is left empty; the caller sets it to a child.
		auto move_window_down = [&]() {
			great_grandparent = std::move(grandparent);
			grandparent = std::move(parent);
			parent = std::move(current);
			grandparent_depth = parent_depth;
			parent_depth = depth;
		};
```

### Teaching idea

Good material for the chapter on ownership and lifetimes in a tree implementation. In a B-tree, delete needs the parent (to borrow from a sibling or merge). Here it needs up to the great-grandparent. In Rust this is exactly the situation where recursive `&mut` descent is easy and iterative descent with parent access is hard; show both designs and why an index-based arena (section 13) makes the iterative one tractable.

---

## 11. Range scan: the iterator (no sibling pointers)

### What it does

A B+tree range scan finds the first leaf and then follows leaf sibling links. An ART has no sibling links, so its iterator keeps an explicit stack of `(node, current byte)` entries from the root to the current position, plus the bytes of the current key. `Next()` increments the byte at the top of the stack, asks the node for the first child with a byte greater or equal, and pops when a node is exhausted. `FindMinimum` descends to the leftmost leaf of a subtree. `LowerBound` positions the iterator on the first key greater than (or equal to) a bound.

The four range forms map to combinations of these (`SearchGreater`, `SearchLess`, `SearchCloseRange`, `SearchEqual`). The upper bound is checked by comparing the iterator's accumulated key bytes with the bound.

A scan has an output capacity. If more row ids match than the capacity, the scan reports `CAPACITY_EXCEEDED` and the caller abandons the index and does a table scan (section 18).

### Where (file:line)

- `src/include/duckdb/execution/index/art/iterator.hpp:151-212`
- `src/execution/index/art/iterator.cpp:79-158` (`Scan`), `:165-222` (`FindMinimum`), `:224-310` (`LowerBound`), `:312-348` (`Next`), `:350-380` (`PopNode`)
- `src/execution/index/art/art.cpp:814-870` (range searches), `:930-961` (`ScanRange`)

### Snippet

```cpp
// iterator.cpp:329-345 (inside Next, blank lines removed)
		top.byte++;
		auto child_ptr = top.node_ptr.GetNextChildNode(art, top.byte);
		if (!child_ptr) {
			// No more children of this node.
			// Move up the tree by popping the key byte of the current node.
			PopNode();
			continue;
		}
		current_key.Pop(1);
		current_key.Push(top.byte);
		if (status == GateStatus::GATE_SET) {
			row_id[nested_depth - 1] = top.byte;
		}
		FindMinimum(child_ptr.Get());
		return true;
```

### Teaching idea

Animation with two trees and one query, `WHERE k BETWEEN 40 AND 60`:

- B+tree: one descent, then a horizontal sweep along the leaf level. Sequential, prefetch-friendly, and the leaf already contains the keys.
- ART: one descent, then a depth-first walk that goes up and down the tree. The key must be reassembled from the path, and each leaf is a separate small object.

Then make the real point for DuckDB: neither scan returns data. Both return row ids, and fetching the rows by id from compressed columnar storage is random access. That is why DuckDB only uses the index for very selective predicates.

---

## 12. Bulk build from sorted keys, and structural merge of two ARTs

### What it does

`CREATE INDEX` can sort the keys first. For each chunk of sorted keys, `ARTBuilder` builds a small ART without any per-key descent: it treats `[start, end]` as a slice of sorted keys, advances `depth` while the first and last key agree on the byte (that run becomes a prefix), then partitions the slice by the byte at `depth` and creates one node of exactly the right type for the number of partitions. An explicit stack replaces recursion.

Each chunk's ART is then merged into the thread-local ART with `MergeIndexes`. Merging is structural, node against node, not key by key. Before two ARTs can be merged their allocators are merged: the other tree's buffers are re-numbered by adding an offset to every buffer id, and every pointer in the other tree is rewritten by one preorder pass (`IncreaseBufferId`).

If the keys are not sorted, the sink falls back to ordinary per-key inserts.

### Where (file:line)

- `src/execution/index/art/art_builder.cpp:10-89`
- `src/execution/index/art/art_index.cpp:94-109` (unsorted sink), `:111-128` (sorted sink: build, then merge)
- `src/execution/index/art/art.cpp:1404-1447` (`InitializeMerge`, pointer rewrite), `:1449-1492` (`MergeIndexes`)
- `src/execution/index/fixed_size_allocator.cpp:174-193` (`Merge` of two allocators)
- `src/include/duckdb/execution/index/art/art_merger.hpp` (merger interface)

### Snippet

```cpp
// art_builder.cpp:64-73
		vector<idx_t> child_offsets;
		child_offsets.emplace_back(entry.start);
		for (idx_t i = entry.start + 1; i <= entry.end; i++) {
			if (keys[i - 1].data[entry.depth] != keys[i].data[entry.depth]) {
				child_offsets.emplace_back(i);
			}
		}

		// Create a new node containing the children.
		NodePtr::New(art, node_ptr_ref, NodePtr::GetInternalNodeType(child_offsets.size()));
```

```cpp
// fixed_size_allocator.cpp:177-181
	// remember the buffer count and merge the buffers
	idx_t upper_bound_id = GetUpperBoundBufferId();
	for (auto &buffer : other.buffers) {
		buffers.insert(make_pair(buffer.first + upper_bound_id, std::move(buffer.second)));
	}
```

### Teaching idea

Pair this with the B+tree bulk-loading chapter. Both structures can be built bottom-up from sorted input with no node ever being split: a B+tree by filling leaves left to right and emitting separators, an ART by recursive partitioning on the next byte. Give the reader the 30-line recursive version first, then the explicit-stack version.

The allocator merge is a memorable trick for the allocator chapter: because pointers are (buffer id, offset) pairs, two arenas can be merged by renumbering one side, with no copying of node bytes.

---

## 13. FixedSizeAllocator: a bitmap slab allocator on buffer-managed blocks

### What it does

Each ART owns nine `FixedSizeAllocator`s, one per node type, each handing out segments of one fixed size (`ART::ALLOCATOR_COUNT = 9`). An allocator owns a map from buffer id to `FixedSizeBuffer`. One buffer is one storage block (262,136 usable bytes by default) laid out as:

```
[ bitmask: bitmask_count 64-bit words ][ segment 0 ][ segment 1 ] ... [ segment N-1 ]
```

In the bitmask, bit = 1 means the slot is free (the code reuses `ValidityMask`, so "valid" means free).

Sizing (constructor): find how many segments fit when each 64-bit mask word is followed by up to 64 segments.

Allocation (`New`):

1. If no buffer has free space, create one and mark all slots free.
2. In the cached "buffer with free space", call `AllocateSegment`. Fast path: if slot number `segment_count` is free, take it, so a fresh buffer fills sequentially. Slow path: scan mask words for a non-zero word and find its lowest set bit with a six-step binary reduction (`BASE` / `SHIFT` tables).
3. If the buffer became full, pick another buffer with free space.
4. Return `IndexPointer(buffer_id, offset)`.

Free: set the bit, decrement counts. A buffer that becomes completely empty is dropped, except that the last buffer with free space is kept to avoid allocate/free oscillation.

Dereference: `ptr.GetOffset() * segment_size + bitmask_offset` inside the buffer found by `buffers.find(buffer_id)` (a hash map lookup on every node access). Out-of-range pointers raise a corruption error, since pointers come from disk.

Access goes through `SegmentHandle`, an RAII handle that loads the buffer from disk if needed, increments an atomic `readers` count, and can mark the buffer dirty.

Segments per 256 KiB buffer (computed by re-running the constructor arithmetic with block size 262,136):

| Node type | Segment bytes | Segments per buffer | Bitmask words |
|---|---|---|---|
| Node7Leaf | 8 | 32,262 | 505 |
| Prefix (prefix_count 7) | 16 | 16,256 | 255 |
| Node15Leaf | 16 | 16,256 | 255 |
| Prefix (prefix_count 15) | 24 | 10,865 | 170 |
| Node4 | 40 | 6,532 | 103 |
| Node256Leaf (current) | 40 | 6,532 | 103 |
| Leaf (deprecated) | 48 | 5,446 | 86 |
| Node16 | 152 | 1,723 | 27 |
| Node256Leaf (legacy layout) | 264 | 992 | 16 |
| Node48 | 648 | 404 | 7 |
| Node256 | 2,056 | 127 | 2 |

### Where (file:line)

- `src/execution/index/art/art.cpp:130-140` (the nine allocators), `src/include/duckdb/execution/index/art/art.hpp:50`
- `src/execution/index/art/node.cpp:105-128` (`GetAllocatorIdx`: node type to allocator index)
- `src/execution/index/fixed_size_allocator.cpp:13-54` (sizing), `:56-94` (`New`), `:96-138` (`Free`), `:423-430` (`GetAvailableBufferId`), `:460-466` (`NextBufferWithFreeSpace`)
- `src/include/duckdb/execution/index/fixed_size_allocator.hpp:50-54` (`GetHandle`), `:164-170` (`GetBuffer`, validation), `:173-201` (fields)
- `src/execution/index/fixed_size_buffer.cpp:145-199` (`AllocateSegment`), `:201-214` (`FreeSegment`), `:245-257` (`SegmentHandle` constructor)
- `src/include/duckdb/execution/index/fixed_size_buffer.hpp:29-30` (`BASE`, `SHIFT`), `:104-126` (buffer fields), `:134-144` (`SegmentHandle` destructor and its FIXME)

### Snippet

```cpp
// fixed_size_allocator.cpp:26-32
	// each full validity_t value is followed by bits_per_value segments: skip all of them at once
	const idx_t full_value_bytes = sizeof(validity_t) + bits_per_value * segment_size;
	const idx_t full_value_count = block_size / full_value_bytes;
	idx_t byte_count = full_value_count * full_value_bytes;

	bitmask_count = full_value_count;
	available_segments_per_buffer = full_value_count * bits_per_value;
```

```cpp
// fixed_size_buffer.cpp:156-162
	// fills up a buffer sequentially before searching for free bits
	if (mask.RowIsValid(segment_count)) {
		const auto offset = segment_count;
		mask.SetInvalid(offset);
		segment_count++;
		return UnsafeNumericCast<uint32_t>(offset);
	}
```

```cpp
// fixed_size_allocator.hpp:50-54
	inline SegmentHandle GetHandle(const IndexPointer ptr) {
		auto &buffer = GetBuffer(ptr);
		auto offset = ptr.GetOffset() * segment_size + bitmask_offset;
		return SegmentHandle(buffer, offset);
	}
```

### Teaching idea

This is the strongest input for a Zig allocator chapter. Build it in three steps:

1. A slab: one page, a bitmap, fixed-size slots, `alloc` returns a slot index.
2. A pool of slabs with a "has free space" set; handles are `(slab_id, slot)`.
3. One pool per node size class; the tree stores handles, not pointers.

Zig sketch of step 1 (using `@ctz` where DuckDB hand-rolls a find-first-set):

```zig
fn Slab(comptime T: type, comptime slots: usize) type {
    const words = (slots + 63) / 64;
    return struct {
        free: [words]u64 = [_]u64{~@as(u64, 0)} ** words, // 1 = free
        used: usize = 0,
        data: [slots]T = undefined,

        fn alloc(self: *@This()) ?u24 {
            for (&self.free, 0..) |*w, i| {
                if (w.* == 0) continue;
                const bit: u6 = @intCast(@ctz(w.*));
                const slot = i * 64 + bit;
                if (slot >= slots) return null;
                w.* &= ~(@as(u64, 1) << bit);
                self.used += 1;
                return @intCast(slot);
            }
            return null;
        }

        fn release(self: *@This(), slot: u24) void {
            self.free[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
            self.used -= 1;
        }
    };
}
```

Discussion points to put next to it:

- Why this suits trees: all nodes of one type have one size, so there is no external fragmentation inside a class and no per-allocation header.
- Why handles and not pointers: the slab can be written to disk byte for byte, reloaded at a different address, merged with another pool, or compacted.
- The costs: every dereference is a hash lookup plus a multiply; a 2,056-byte Node256 wastes little, but a tree with a single Node256 still occupies a whole 256 KiB buffer in memory (`GetInMemorySize` counts whole blocks, `fixed_size_allocator.cpp:154-162`).
- B-tree contrast: a B-tree needs only one allocator (pages of one size), and its free list is the simplest possible slab. An ART needs nine size classes because its nodes are deliberately of different sizes.

Visualization: a grid per size class where cells fill sequentially, holes appear on delete, and the next allocation drops into the lowest hole.

---

## 14. Vacuum: compaction for a pointer-based tree

### What it does

After many deletes, buffers are sparsely filled. `InitializeVacuum` sums the free segments over in-memory buffers, converts them to "whole buffers that could be saved", and only proceeds if that is at least 10% of the allocator's in-memory size (`VACUUM_THRESHOLD = 10`). It then selects the emptiest buffers as victims and removes them from the set of buffers that may receive allocations.

`ART::Vacuum` walks the tree in preorder. For every child pointer that points into a victim buffer it allocates a new segment elsewhere, `memcpy`s the node, and overwrites the pointer in the parent. Afterwards the victim buffers are dropped whole.

Because the tree has exactly one pointer to each node (no sibling links, no parent pointers), moving a node needs only one pointer update.

### Where (file:line)

- `src/include/duckdb/execution/index/fixed_size_allocator.hpp:31`
- `src/execution/index/fixed_size_allocator.cpp:195-258` (`InitializeVacuum`), `:260-267`, `:269-283` (`VacuumPointer`)
- `src/execution/index/art/art.cpp:1326-1343` (`VacuumPointerIfNeeded`), `:1345-1391` (`ART::Vacuum`)

### Snippet

```cpp
// fixed_size_allocator.cpp:269-283 (comments shortened)
IndexPointer FixedSizeAllocator::VacuumPointer(const IndexPointer old_ptr) {
	auto new_ptr = New();
	// new increases the allocation count, we need to counter that here
	total_segment_count--;

	auto old_handle = GetHandle(old_ptr);
	auto new_handle = GetHandle(new_ptr);
	new_handle.MarkModified();

	memcpy(new_handle.GetPtr(), old_handle.GetPtr(), segment_size);
	return new_ptr;
}
```

### Teaching idea

Compare with B-tree space reclamation: a B-tree merges underfull siblings and puts whole pages on a free list; it rarely moves a live page, because that would require fixing the parent and both sibling links. Here relocation is cheap, so compaction is "evacuate the emptiest slabs". Exercise: how many pointers must be updated to move one node in (a) this ART, (b) a B+tree with doubly linked leaves, (c) a B-tree with parent pointers?

---

## 15. Serialization: how the ART goes to disk (checkpoint, lazy load, WAL)

### What it does

The ART is not serialized as a tree. Its slab buffers are written as they are:

- Checkpoint: for each allocator, `Persist` builds a new allocator that shares clean buffers with the live one and writes only buffers that are dirty or have never been written (`RequiresPersist`). A buffer is written through the `PartialBlockManager`, which packs several small allocations into one storage block. Only the used front part of a buffer is written: `GetNewAllocationSize` finds the highest occupied slot.
- What is recorded in the table metadata (`IndexStorageInfo`): the root `NodePtr` as a 64-bit integer, and for each allocator its segment size and, per buffer, the buffer id, block pointer (block id and offset), segment count and allocation size, plus the list of buffers with free space.
- Load: constructing an ART from `IndexStorageInfo` only registers the buffers. No index block is read. A buffer is read the first time a `SegmentHandle` touches it (`LoadFromDisk`), which copies the partial block into a fresh in-memory block.
- WAL: `SerializeToWAL` hands out the raw buffer memory for each allocator.
- Old formats: files before storage version 1.2.0 use the "V1_0_0" format with six allocators and linked-list leaves; the in-memory tree is transformed before writing (`TransformToDeprecated`).

Dropping a `SegmentHandle` only decrements `readers`; unpinning a buffer when its reader count reaches zero is an open FIXME in the source, so this code does not page index buffers back out per access.

### Where (file:line)

- `src/execution/index/art/art.cpp:1163-1187` (`PrepareSerialize`), `:1189-1195`, `:1197-1218` (`Checkpoint`), `:1220-1238` (`SerializeToWAL`), `:150-158` (construct from storage info)
- `src/execution/index/fixed_size_allocator.cpp:285-311` (`GetInfo`), `:313-343` (`Persist`), `:361-399` (`Init`)
- `src/execution/index/fixed_size_buffer.cpp:90-114` (buffer `Persist`), `:116-143` (`LoadFromDisk`), `:225-243` (`GetNewAllocationSize`)
- `src/include/duckdb/storage/index_storage_info.hpp:49-75`
- `src/include/duckdb/execution/index/fixed_size_buffer.hpp:80-83` (`RequiresPersist`), `:142-143` (FIXME)

### Snippet

```cpp
// fixed_size_allocator.cpp:327-333
		D_ASSERT(buffer->readers == 0);
		if (buffer->RequiresPersist()) {
			result->buffers[buffer_id] =
			    buffer->Persist(partial_block_manager, available_segments_per_buffer, segment_size, bitmask_offset);
		} else {
			result->buffers[buffer_id] = buffer;
		}
```

### Teaching idea

Chapter idea: "three ways to persist an index".

1. B+tree: the index is the file. Every node is a page; updates write pages in place or copy-on-write, and a WAL makes them atomic.
2. ART in DuckDB: an in-memory structure whose arenas are dumped at checkpoint and faulted in lazily.
3. Rebuild on load (what an in-memory-only index does).

The key observation for learners: because nodes of one type are packed into shared 256 KiB buffers in allocation order, tree neighbours are not disk neighbours. A B+tree page keeps a node's keys together on one page by construction. This is why the ART is "serializable" but not "disk-friendly" in the sense a B+tree is.

---

## 16. Concurrency: one mutex per index

### What it does

Every index operation, including read-only scans, takes one `std::mutex` for the whole index. `IndexLock` is a scoped `lock_guard` on `index.lock`. There is no latch crabbing, no optimistic lock coupling and no per-node latch in this code. The atomic `readers` counter on a buffer is a pin count for memory management, not a concurrency control mechanism.

Parallelism for index creation comes from elsewhere: each thread builds its own ART and the ARTs are merged (section 12).

### Where (file:line)

- `src/include/duckdb/execution/index/index_lock.hpp:17-35`
- `src/execution/index/art/art.cpp:886`, `:915`, `:936` (scans take `IndexLock`)
- `src/include/duckdb/execution/index/fixed_size_buffer.hpp:104-105` (`atomic<idx_t> readers`)

### Snippet

```cpp
// index_lock.hpp:17-22
struct DUCKDB_CAPABILITY("mutex") DUCKDB_SCOPED_CAPABILITY IndexLock {
public:
	explicit IndexLock(const BoundIndex &index) DUCKDB_ACQUIRE(index.lock)
	    : index_guard(index.lock), locked_index(index) {
	}
	~IndexLock() DUCKDB_RELEASE() = default;
```

### Teaching idea

Use this as the "level 0" of the concurrency chapter: the simplest correct design is a single lock, and a real system ships it because its workload (few, selective index probes; bulk loads done thread-locally and merged) does not need more. Then build up: reader-writer lock, latch crabbing in a B+tree, B-link trees, optimistic lock coupling (unverified here; these are not in DuckDB).

---

## 17. Zone maps: min/max statistics instead of a secondary index

### What it does

Tables are stored as row groups of 122,880 rows (60 vectors of 2,048 rows). Each column in a row group is a list of column segments, and every segment (and the column as a whole) carries statistics including min and max. A filter pushed into the scan is tested against these statistics before any data is decompressed:

- `RowGroup::CheckZonemap` runs when a scan enters a row group. If any filter is "always false" for the row group's statistics, the whole row group is skipped.
- `RowGroup::CheckZonemapSegments` runs during the scan and tests the current column segment; on "always false" it advances the scan past that segment in units of whole vectors.
- The test returns three outcomes. Besides "skip", "always true" lets the scan drop the filter for that row group and not evaluate it per row.

For strings, min and max are truncated to 12 bytes (8 in the legacy format).

A zone map has no order, no pointers and no per-key cost. Its usefulness depends entirely on how well the physical row order correlates with the filter column.

### Where (file:line)

- `src/include/duckdb/storage/storage_info.hpp:23` (`DEFAULT_ROW_GROUP_SIZE`), `:403-408` (must be a multiple of the vector size); `src/include/duckdb/common/vector_size.hpp:16`
- `src/storage/statistics/numeric_stats.cpp:209-278` (`CheckZonemapTemplated`)
- `src/include/duckdb/storage/statistics/numeric_stats.hpp:29-37` (`NumericStatsData`: has_min, has_max, min, max)
- `src/include/duckdb/storage/statistics/string_stats.hpp:35-36`
- `src/storage/table/row_group.cpp:385-389` (check on entering a row group), `:735-805`, `:807-830`
- `src/storage/table/column_data.cpp:469-492` (segment-level check)
- `src/include/duckdb/storage/data_pointer.hpp:51-69` (a persisted segment pointer carries its statistics)

### Snippet

```cpp
// numeric_stats.cpp:231-241
	case ExpressionType::COMPARE_GREATERTHANOREQUALTO:
		// GreaterThanEquals::Operation(X, C)
		// this can be true only if max(X) >= C
		// if min(X) >= C, then this is always true
		if (GreaterThanEquals::Operation(min_value, constant)) {
			return FilterPropagateResult::FILTER_ALWAYS_TRUE;
		} else if (GreaterThanEquals::Operation(max_value, constant)) {
			return FilterPropagateResult::NO_PRUNING_POSSIBLE;
		} else {
			return FilterPropagateResult::FILTER_ALWAYS_FALSE;
		}
```

```cpp
// row_group.cpp:791-794
		if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE ||
		    prune_result == FilterPropagateResult::FILTER_FALSE_OR_NULL) {
			return false;
		}
```

### Teaching idea

Present a zone map as "a B+tree with the leaves deleted and the inner levels flattened": the separator keys of a B+tree's bottom inner level say "everything in this child lies between k1 and k2". A zone map keeps only that sentence, per block, and gives up the guarantee that the blocks are sorted.

Rust sketch:

```rust
#[derive(Clone, Copy)]
struct Zone { min: i64, max: i64 }

enum Prune { AlwaysTrue, AlwaysFalse, Unknown }

fn check_ge(z: Zone, c: i64) -> Prune {
    if z.min >= c { Prune::AlwaysTrue }
    else if z.max >= c { Prune::Unknown }
    else { Prune::AlwaysFalse }
}
```

Interactive visualization: 100 row groups drawn as horizontal [min, max] bars, with a draggable predicate range. A toggle switches the data between "inserted in key order" (bars form a staircase, almost everything is pruned) and "random order" (every bar spans the whole domain, nothing is pruned). This single picture explains when a zone map replaces an index and when it does not.

---

## 18. When does DuckDB actually use the index? (the scan threshold)

### What it does

The table scan considers an ART only when there is exactly one pushed-down filter set entry and the table has indexes. It then probes the ART with a row id output whose capacity is `max(index_scan_max_count, index_scan_percentage * total_rows)`. Defaults: 2,048 rows and 0.001 (0.1%). If the probe would return more row ids than that, the collected ids are discarded and the scan falls back to a sequential table scan with zone maps.

So for a 100-million-row table, the index is used only if at most 100,000 rows match.

### Where (file:line)

- `src/function/table/table_scan.cpp:1005-1024`
- `src/include/duckdb/main/settings.hpp:2027-2038` (`index_scan_max_count`, default "2048"), `:2041-2052` (`index_scan_percentage`, default "0.001")
- `src/execution/index/art/art.cpp:896-902` (`Scan` returns false and resets the output when capacity is exceeded)

### Snippet

```cpp
// table_scan.cpp:1015-1020
	auto scan_percentage = Settings::Get<IndexScanPercentageSetting>(context);
	auto scan_max_count = Settings::Get<IndexScanMaxCountSetting>(context);

	auto total_rows = storage.GetTotalRows();
	auto total_rows_from_percentage = LossyNumericCast<idx_t>(double(total_rows) * scan_percentage);
	auto max_count = MaxValue(scan_max_count, total_rows_from_percentage);
```

### Teaching idea

A short "index or scan?" section with a cost model the reader can play with: cost of index path = probe + (matching rows x random fetch); cost of scan = (row groups not pruned) x sequential read. Plot both against selectivity and show the crossover. Mention that the row-store rule of thumb (use a secondary index below a few percent selectivity (unverified)) becomes far stricter in a column store, and DuckDB hard-codes a 0.1% default.

Also state plainly what the ART is mainly for in DuckDB: enforcing PRIMARY KEY and UNIQUE constraints (the insert path returns `ARTConflictType::CONSTRAINT`, `art.cpp:663-667`), with selective lookups as a secondary use.

---

## 19. Single-file storage: fixed-size blocks, double header, free list

### What it does

A DuckDB database is one file:

```
offset 0      : MainHeader      (4096 bytes: magic "DUCK", version, flags, ...)
offset 4096   : DatabaseHeader 1 (4096 bytes)
offset 8192   : DatabaseHeader 2 (4096 bytes)
offset 12288  : block 0, block 1, ... each block_alloc_size bytes (default 262144)
```

Block `i` lives at `12288 + i * block_alloc_size`. Each block begins with an 8-byte header (a checksum (unverified what exactly the 8 bytes hold; the size is verified)), leaving 262,136 usable bytes. The block size is configurable between 16,384 and 262,144 bytes and must be a power of two.

Atomic checkpoint by header flip: a `DatabaseHeader` holds an iteration counter, the root metadata block pointer, the free list pointer and the block count. On open, the header with the higher iteration wins. A checkpoint writes all new data into blocks that the active header does not reference, calls fsync, writes the other header slot with `iteration + 1`, and calls fsync again. A crash before the second fsync leaves the old header, and therefore the old state, intact.

Free list: an in-memory `set<block_id_t>`. Allocation takes the smallest free id, or extends the file. A block that was referenced by the last checkpoint and is no longer needed is not reusable immediately: it goes to `modified_blocks` and joins the free list only after the next header is durable. The free list itself is written into metadata blocks and pointed to by the header. Trailing free blocks are cut off by truncating the file.

There is no page-level WAL with in-place page updates. Data blocks are written once and replaced, never patched.

### Where (file:line)

- `src/include/duckdb/storage/storage_info.hpp:23-32`, `:48-65` (constants), `:374-399` (`DatabaseHeader`)
- `src/include/duckdb/storage/single_file_block_manager.hpp:70` (`BLOCK_START`), `:216-226` (free list and friends)
- `src/storage/single_file_block_manager.cpp:1189-1191` (`GetBlockLocation`), `:721-729` (choose active header), `:916-935` (allocate a block id), `:993-1030` (`MarkBlockAsModified`), `:1258-1278` (`Truncate`), `:1356-1463` (`WriteHeader`)
- `src/storage/checkpoint_manager.cpp:332-337` (header written last), `:373-374` (truncate), `:380-381` (WAL)

### Snippet

```cpp
// single_file_block_manager.cpp:1189-1191
idx_t SingleFileBlockManager::GetBlockLocation(block_id_t block_id) const {
	return BLOCK_START + NumericCast<idx_t>(block_id) * GetBlockAllocSize();
}
```

```cpp
// single_file_block_manager.cpp:1423-1424 and :1443-1450
	// We need to fsync BEFORE we write the header to ensure that all the previous blocks are written as well
	handle->Sync();
	...
	// now write the header to the file, active_header determines whether we write to h1 or h2
	// note that if active_header is h1 we write to h2, and vice versa
	auto location = active_header == 1 ? Storage::FILE_HEADER_SIZE : Storage::FILE_HEADER_SIZE * 2;
	ChecksumAndWrite(context, header_buffer, location);
	// switch active header to the other header
	active_header = 1 - active_header;
	//! Ensure the header write ends up on disk
	handle->Sync();
```

```cpp
// single_file_block_manager.cpp:1023-1028
	} else {
		// this block was used in storage, we cannot directly re-use it
		// add it to the modified blocks indicating it will be re-usable after the next checkpoint
		// so is a committed newly used block, which the WAL of its commit refers to until a header includes it
		newly_used_blocks.erase(block_id);
		modified_blocks.insert(block_id);
	}
```

### Teaching idea

This section is directly reusable for a B-tree storage chapter, because the same three mechanisms appear in copy-on-write B-tree stores (two alternating meta pages, a free list of page ids, and "pages freed in this transaction are not reusable until it is durable"; the comparison to specific products is (unverified)).

Animation: a strip of blocks coloured by state (live, free, modified-pending, newly written) and two header boxes. Step through a checkpoint; add a "crash now" button at each step and show which header would win on restart.

Zig exercise: implement `Pager` with `allocate() -> BlockId`, `markModified(id)`, `commit()` and the dual-header write. About 150 lines, and it is the foundation for both a B-tree file and this kind of store.

Page-size contrast to state explicitly: a B-tree for point lookups wants pages near the device and OS page size (4 to 16 KiB is typical (unverified)) so that one lookup reads little. DuckDB's default block is 256 KiB because its unit of work is "decompress and scan a column segment", not "find one key".

---

## 20. Metadata blocks, partial blocks, buffer pool

### What it does

Three smaller mechanisms that manage pages differently from a B-tree store:

- Metadata blocks. Catalog and table metadata is a byte stream, not a tree. A storage block is divided into 64 metadata sub-blocks (`METADATA_BLOCK_COUNT = 64`), each `floor8(block_size / 64)` bytes, which is 4,088 for the default block (computed). A stream is a linked list: the first 8 bytes of each sub-block hold the pointer to the next, with -1 as terminator. A `MetadataPointer` packs a 56-bit block index and an 8-bit sub-block index.
- Partial blocks. Small allocations (small column segments, index buffers) are packed together into shared blocks by the `PartialBlockManager` during a checkpoint. A block shared by several owners is tracked in `multi_use_blocks` with a reference count, and is freed only when the count drops.
- Buffer pool. Blocks are pinned through the buffer manager; unpinned blocks go onto eviction queues (a lock-free concurrent queue type from `third_party/concurrentqueue`). The default memory limit is 80% of available memory (comment at `src/main/config.cpp:686`).

### Where (file:line)

- `src/include/duckdb/storage/metadata/metadata_manager.hpp:45-48` (`MetadataPointer`), `:58`
- `src/storage/metadata/metadata_manager.cpp:359-361` (`GetMetadataBlockSize`)
- `src/storage/metadata/metadata_writer.cpp:45-63` (`NextBlock`: chaining)
- `src/include/duckdb/storage/partial_block_manager.hpp:29-35`
- `src/storage/single_file_block_manager.cpp:998-1009` (multi-use reference counting)
- `src/storage/buffer/buffer_pool.cpp:63` (`eviction_queue_t`)

### Snippet

```cpp
// metadata_writer.cpp:49-59
	// write the block id of the new block to the start of the current block
	if (capacity > 0) {
		auto disk_block = manager.GetDiskPointer(new_handle.pointer);
		Store<idx_t>(disk_block.block_pointer, BasePtr());
	}
	// now update the block id of the block
	block = std::move(new_handle);
	current_pointer = block.pointer;
	offset = sizeof(idx_t);
	capacity = GetManager().GetMetadataBlockSize();
	Store<idx_t>(static_cast<idx_t>(-1), BasePtr());
```

### Teaching idea

A small "overflow pages" sidebar: a linked chain of fixed-size chunks is how B-tree stores hold values larger than a page, and it is how DuckDB holds all of its metadata. The reader can implement a `ChainWriter`/`ChainReader` pair in Zig in under 60 lines on top of the `Pager` from section 19.

---

## 21. Finding a row group by row id: a sorted array, not a tree

### What it does

Given a row id from the ART, the engine must find the row group that contains it. Row groups are held in a vector ordered by starting row, and the lookup is a binary search over that vector. With 122,880 rows per group, a billion-row table has about 8,138 row groups (computed), so the search takes about 13 steps over one contiguous array.

### Where (file:line)

- `src/include/duckdb/storage/table/segment_tree.hpp:279-296`

### Snippet

```cpp
// segment_tree.hpp:279-290
		idx_t lower = 0;
		idx_t upper = nodes.size();
		// binary search to find the node. Searches using half-open interval [lower, upper).
		while (lower < upper) {
			idx_t index = lower + (upper - lower) / 2;
			auto &entry = *nodes[index];
			if (row_number < entry.GetRowStart()) {
				// This node and all nodes to the right are excluded.
				upper = index;
			} else if (row_number >= entry.GetRowEnd()) {
				// This node and all nodes to the left are excluded.
				lower = index + 1;
```

### Teaching idea

Use this in chapter 1 of the guide ("from sorted array to B-tree"): a sorted array with binary search is a one-node B-tree, and it is the right answer when the array is small, append-mostly and fits in memory. A B-tree is what you build when the array no longer fits in one node. DuckDB's large row groups keep this array small enough that it never needs to become a tree.

---

## 22. Sorting and merging (brief)

### What it does

Ordered output and ordered joins are produced by sorting at query time, not by reading an ordered index:

- Sort keys are normalized into binary-comparable form, the same idea as ART keys (section 7), so runs can be sorted with radix sort (`ska_sort`) and compared bytewise; `vergesort` and `pdqsort` from `third_party/` are also used.
- Sorted runs are merged in parallel using a K-way Merge Path partitioning step.
- There are merge-based join operators (`physical_piecewise_merge_join.cpp`, `physical_iejoin.cpp`, `physical_asof_join.cpp`); file names only, not studied.
- `CREATE INDEX` on an ART can use the sorted path (section 12).

### Where (file:line)

- `src/common/sort/sorted_run.cpp:14-15` (includes), `:361`, `:397-399` (ska_sort, vergesort calls)
- `src/common/sort/sorted_run_merger.cpp:16-17`, `:165` ("K-way Merge Path")
- `src/function/scalar/create_sort_key.cpp` (sort key normalization; file located, not read)
- `src/execution/operator/join/` (operator list)

### Snippet

```cpp
// sorted_run_merger.cpp:165
	//! Computes upper partition boundaries using K-way Merge Path
```

### Teaching idea

One paragraph in the comparison chapter: a B+tree pays for order at write time and gets ordered reads for free; a column store pays nothing at write time and sorts when a query asks for order. Sorted runs plus merge is also the bridge to LSM trees, if the guide has such a chapter.

---

## 23. Comparison: B+tree vs ART vs zone maps, and why OLAP chooses this

B+tree entries in this table are general knowledge about typical disk B+trees and are (unverified) against any source in this tree. ART and zone map entries are grounded in the sections above; estimates are marked.

| Property | B+tree (typical, unverified) | ART (DuckDB) | Zone map (DuckDB) |
|---|---|---|---|
| What it stores | sorted (key, value) entries in pages | one byte per level, row id in the leaf pointer | min and max per segment and row group |
| Point lookup | about log_f(n) pages, binary search in each | at most key-length nodes (8 for int64, fewer with prefixes); no key comparisons; then fetch the row by id | cannot find a row; can only exclude blocks, then scan up to 122,880 rows per surviving row group |
| Range scan | one descent, then walk linked leaves; keys and values are in the leaves | lower bound, then stack-based depth-first walk; yields row ids only, capped (section 18) | sequential scan of row groups whose [min, max] overlaps the range |
| Insert | find leaf, shift within page, occasional split that can cascade | descend, add a child; node may be copied into the next size; no cascade | update min and max of the segment being appended to |
| Delete | remove, maybe borrow or merge | remove child, maybe shrink, maybe fold into a prefix; vacuum later | nothing (statistics stay conservative) |
| Memory per key | key + value + slot overhead, at roughly 50 to 70% page fill | dense int64 keys: about 8 bytes (one slot of a Node256, row id inlined) (estimate). Sparse random keys: a 16-byte prefix segment plus a 9-byte slot in a Node4/16, about 25 to 40 bytes (estimate) | two values per segment, independent of row count |
| Cache behaviour | few, large nodes; in-node search is contiguous | many small nodes; each level is a dependent load from a different slab | one tiny check per block, then purely sequential data |
| On-disk friendliness | designed for it: node = page, neighbours co-located | arenas dumped at checkpoint, loaded lazily per 256 KiB buffer; tree neighbours are not disk neighbours | stored inside the metadata that must be read anyway |
| Ordered output | yes, by leaf order | yes, by byte order (needs order-preserving key encoding) | no |
| Needs sorted data to be useful | no | no | yes: effectiveness depends on physical clustering |
| Concurrency in this code | (varies by system) | one mutex per index (section 16) | read-only metadata, no locking concern for readers |
| Bulk load | bottom-up from sorted input | build per sorted chunk, then structural merge (section 12) | free, computed while writing |
| Main use in DuckDB | not present | PRIMARY KEY / UNIQUE enforcement, very selective lookups | the default access path for every filtered scan |

### Why an OLAP engine makes this choice

Stated as reasoning from what the code shows:

1. The unit of work is a block of column values, not a row. Storage is organised around 122,880-row groups and 256 KiB blocks (section 19). An index that returns row ids one at a time fights that design: each id means locating a row group, a segment, and a position inside compressed data.
2. Most analytical predicates are not selective enough. The engine itself refuses to use the index unless at most 0.1% of rows (or 2,048 rows) match (section 18). Below that threshold a pointer index helps; above it a sequential scan with pruning wins.
3. Zone maps cost almost nothing. They are computed during writes, live in metadata that is read anyway, need no maintenance on delete, and compose with every column at once. A secondary B+tree per column would multiply write cost and storage.
4. The index that remains has one main job, constraint checking, which is a point lookup on a fixed-width or short key held in memory. That is the case an ART is built for: lookup cost bounded by key length, compact nodes for dense integer keys, and no dependence on page size.
5. Writes are bulk appends and checkpoints, not in-place page updates. With blocks written once and swapped in by a header flip (section 19), a structure that is "dump the arenas at checkpoint" (section 15) fits better than a page-update-in-place B+tree with its own WAL protocol.
6. Order is produced on demand by sorting (section 22), so the engine does not need an index that is also a sorted container of the data.

What a learner should take from this for B-trees: the B+tree's defining strengths are exactly the things DuckDB does not need. It keeps keys and values co-located in page-sized nodes, it gives short paths measured in page reads, it supports cheap in-place updates, and it gives ordered scans over the data itself. Take away the need for those (columnar data, bulk writes, scans over large fractions of a table) and the argument for a B+tree weakens.

---

## 24. Numbers cheat sheet

Literal constants (verified):

| Quantity | Value | Where |
|---|---|---|
| Vector size | 2,048 rows | `src/include/duckdb/common/vector_size.hpp:16` |
| Row group size | 122,880 rows (60 vectors) | `src/include/duckdb/storage/storage_info.hpp:23` |
| Maximum row group size | 2^30 rows | `storage_info.hpp:55` |
| Default block allocation size | 262,144 bytes (256 KiB) | `storage_info.hpp:30` |
| Minimum / maximum block allocation size | 16,384 / 262,144 bytes | `storage_info.hpp:57-59` |
| Block header | 8 bytes (so 262,136 usable) | `storage_info.hpp:32`, `:61-65` |
| File header size | 4,096 bytes each, three of them | `storage_info.hpp:53` |
| First block offset | 12,288 | `single_file_block_manager.hpp:70` |
| Metadata sub-blocks per block | 64 | `metadata_manager.hpp:58` |
| ART allocators | 9 (6 in the deprecated format) | `art.hpp:50-52` |
| Node capacities | 4, 16, 48, 256 | `base_node.hpp:166`, `:185`; `node48.hpp:27`; `node256.hpp:24` |
| Nested leaf capacities | 7, 15, 256 | `base_leaf.hpp:86`, `:107`; `node256_leaf.hpp:25` |
| Shrink thresholds | Node48 below 12; Node256 at or below 36; Node16 below 4 | `node48.hpp:29`, `node256.hpp:25`, `base_node.cpp:146` |
| Node48 empty marker | 48 | `node48.hpp:28` |
| IndexPointer fields | 8 bits metadata, 24 bits offset, 32 bits buffer id | `index_pointer.hpp:19-24` |
| Row id bits in an inlined leaf | 56 | `node.hpp:122` |
| Deprecated prefix bytes / leaf size | 15 / 4 row ids | `prefix.hpp:27`, `leaf.hpp:29` |
| Vacuum threshold | 10% | `fixed_size_allocator.hpp:31` |
| Index scan thresholds | 2,048 rows, 0.001 of the table | `settings.hpp:2037`, `:2051` |
| String min/max length in statistics | 12 bytes (legacy 8) | `string_stats.hpp:35-36` |

Derived values (computed):

| Quantity | Value |
|---|---|
| Node sizes in bytes | Node4 40, Node16 152, Node48 648, Node256 2,056, Node7Leaf 8, Node15Leaf 16, Node256Leaf 40 |
| Prefix segment for an int64 key | 7 data bytes + 1 count + 8 child = 16 bytes |
| Maximum prefix bytes per node | 239 |
| Metadata sub-block size at default block size | 4,088 bytes |
| Node4 segments per 256 KiB buffer | 6,532 |
| Node256 segments per 256 KiB buffer | 127 |
| Row groups for 10^9 rows | about 8,138 |

---

## 25. Most important insights for a learner

1. A B-tree is a bundle of answers to separate questions: how to find a key, how to scan a range, how to lay nodes out on pages, how to allocate and free pages, how to stay consistent across a crash. DuckDB answers each question with a different, simpler mechanism. Seeing them unbundled makes it clearer what each part of a B-tree is for.
2. Order-preserving key encoding is a tool for every ordered index. Once keys are byte strings that sort with `memcmp`, a B-tree needs one comparator and a radix tree becomes possible at all.
3. Adaptive node sizes are the radix tree's version of fill factor. A B-tree keeps nodes between half full and full; an ART picks one of four layouts and uses lower shrink thresholds to avoid thrashing.
4. Tree height can depend on n (B-tree) or on key length (radix tree). Each choice moves the cost: B-trees pay in comparisons and page reads that grow slowly with n; radix trees pay one dependent memory access per key byte that is not compressed away.
5. Storing handles (slab id, slot) in place of pointers buys persistence, relocation, compaction and arena merging, at the price of an indirection on every access. This is the central design decision for a Zig or Rust tree implementation, and it is also the shape that satisfies Rust's borrow checker.
6. A zone map is the cheapest possible index: the upper levels of a B+tree with the sorted leaves removed. It works only as well as the data is physically clustered on the filter column.
7. "Use the index" is a cost decision. DuckDB's default cut-off of 0.1% of the table shows how narrow the useful range of a row-id index is once the base data is columnar and compressed.
8. Atomic durability does not require a page-level WAL. Write new blocks, sync, flip between two headers by an iteration counter, sync, and only then recycle the old blocks.
9. Range scans need either sibling links (B+tree) or a stack (ART). The B+tree's linked leaves are a deliberate feature paid for on every split, and the ART iterator shows what the alternative costs.
10. Coarse locking is a legitimate design when the workload allows it. One mutex per index plus thread-local builds that are merged covers bulk loading and occasional probes.

---

## 26. Things that are easy to get wrong

About DuckDB's ART specifically:

- Assuming ART prefixes live in the inner node header as in the original paper. Here `PREFIX` is a separate node type with its own allocator and its own pointer hop (`prefix.hpp:18-21`).
- Assuming Node16 uses SIMD. In this code the search is a plain loop shared with Node4 (`base_node.hpp:72-82`).
- Reading the free bitmap the wrong way round. A set bit means the slot is free: `New()` calls `SetAllValid` on a fresh buffer and `AllocateSegment` calls `SetInvalid` (`fixed_size_allocator.cpp:72-73`, `fixed_size_buffer.cpp:159`).
- Treating a `NodePtr` as always being a location. For `LEAF_INLINED` the low 56 bits are a row id, so such a pointer must never be dereferenced, vacuumed or re-based (`art.cpp:1328-1330`, `:1411-1413`).
- Forgetting the gate bit when replacing a child. Grow, shrink and `ReplaceChild` all copy the gate status to the new pointer (`base_node.cpp:162`, `base_node.hpp:60-65`).
- Thinking shrink happens at capacity minus one. The thresholds are 36 and 12, not 48 and 16; only Node16 to Node4 shrinks just below the smaller capacity.
- Expecting a Node48's `children` array to be dense. Deletes leave holes; insert must search for one (`node48.cpp:16-22`).
- Believing the ART is paged in and out per node. The unit of I/O is a 256 KiB buffer of same-type nodes, loaded on first touch; unpin-on-idle is a FIXME (`fixed_size_buffer.hpp:142`).
- Believing ART lookups are lock-free or use optimistic lock coupling. Scans take the index mutex (`art.cpp:915`).
- Expecting NULLs in the index. A NULL produces an empty key and is skipped (`art.cpp:368-369`, `:635-637`).
- Forgetting that string keys are longer than the string: one terminator byte plus one byte per `0x00` or `0x01` (`art_key.cpp:33`).

About key encoding in general:

- Using little-endian integers as radix or `memcmp` keys. The most significant byte must come first.
- Forgetting the sign-bit flip for signed integers, which makes negatives sort after positives.
- Treating floats like integers. Negative floats need all bits inverted, not only the sign bit, and NaN and the infinities need explicit placement (`radix.hpp:49-78`).
- Allowing one key to be a prefix of another in a radix tree whose values live only at the leaves. The terminator and escaping exist to prevent this.

About the comparison with B-trees:

- Saying "ART is faster than a B-tree" without stating the workload. Bounded-by-key-length lookups help in-memory point probes; they do not help when the result is a large set of row ids to fetch from compressed columns.
- Saying "zone maps replace indexes". They replace range pruning on clustered columns. They do nothing for point lookups on unclustered columns and cannot enforce uniqueness, which is why the ART still exists.
- Comparing node counts without comparing node sizes. An ART has many more nodes than a B+tree over the same keys; the fair comparisons are bytes per key and cache misses per lookup.
- Assuming a 256 KiB block is a "page" in the B-tree sense. It is the unit of allocation and I/O for column segments; a point-lookup structure with nodes of that size would read far too much per probe.
- Assuming crash safety implies a redo log of page changes. DuckDB has a WAL for committed changes between checkpoints, but its data file is updated by writing new blocks and switching headers (`single_file_block_manager.cpp:1423-1450`), not by patching pages.
- Reusing freed blocks immediately. A block referenced by the last durable header must stay untouched until the next header is durable (`single_file_block_manager.cpp:1023-1028`, `:1454-1458`). The same rule applies to any copy-on-write B-tree.

Limits of these notes:

- `art_merger.cpp`, `prefix_handle.cpp` (apart from `Split`), `node.cpp` delete dispatch, the buffer pool eviction logic, the partial block manager internals and the sort code were located and skimmed, not read line by line.
- Node byte sizes and segments-per-buffer are computed on x86-64, not asserted by the source (the source only asserts that `IndexPointer` is 8 bytes).
- No DuckDB code was built or run; behaviour is inferred from reading the source at this commit.
