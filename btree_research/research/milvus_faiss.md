# Milvus and FAISS: what vector-search engines teach about B-trees

Research notes for the guide "Understanding B-trees, from simple to complex".
Sources: `/home/user/ai_lab/db_study/milvus` (commit 0d3e77c) and
`/home/user/ai_lab/db_study/faiss` (commit c8f2838), both shallow clones.
Paths below are relative to those roots (`milvus/...`, `faiss/...`).

Honesty statement: neither project is a B-tree database. Milvus uses a real
B-tree in exactly two small in-memory places (via `github.com/google/btree`)
and depends on B+tree / LSM stores for metadata. FAISS contains no B-tree and
no kd-tree at all. Their value for the guide is mostly *by contrast*: they show
what you build when the assumptions behind a B-tree (a total order that
preserves "nearness", cheap in-place updates, page-sized nodes) do not hold.

Everything not marked **(unverified)** was read in the source at the cited
lines. Claims marked **(unverified)** come from general knowledge, not these
checkouts.

Contents

1. Milvus: the only real B-trees (google/btree)
2. Milvus: metadata stores (etcd, TiKV, RocksDB)
3. Milvus: STL_SORT, the sorted-array scalar index
4. Milvus: galloping search for `IN (...)` on a sorted array
5. Milvus: bitmap index = ordered dictionary + Roaring postings
6. Milvus: inverted (Tantivy), Marisa trie, R-tree, and the Hybrid selector
7. Milvus: skip index (min/max + bloom) = a one-level "B-tree of statistics"
8. Milvus: primary-key lookup (ordered map vs ordered array vs zero storage)
9. Milvus: segments, L0 deltas and compaction (LSM, not B-tree)
10. FAISS: IndexFlat, the honest baseline
11. FAISS: IndexIVF, a one-level tree whose root is not ordered
12. FAISS: HNSW, a skip list generalised to a metric space
13. FAISS: other partition structures, and the absent kd-tree
14. Why B-trees fail for vector similarity
15. Cross-cutting: SIMD scanning inside a "node"
16. Cross-cutting: flat arrays and offsets instead of pointers
17. Cross-cutting: mmap and on-disk inverted lists
18. Cross-cutting: GPU layouts
19. Comparison table
20. Most important insights for a learner
21. Things that are easy to get wrong

---

## 1. Milvus: the only real B-trees (google/btree)

### What it does

A word-boundary grep for `btree` / `b+tree` / `b-tree` over Go, C++, Rust and
TOML in the Milvus tree finds exactly two non-test users, both of the in-memory
Go library `github.com/google/btree`:

- `MemoryKV`: an in-memory key-value store used as a test double for the
  metadata KV interface. Keys are strings; the B-tree gives ordered iteration,
  which is what makes prefix scans and range loads possible.
- `schemaTaskIndex`: per-collection ordered set of pending schema-change
  tasks keyed by `BroadcastID`; the code only ever needs "insert", "delete",
  and "minimum", i.e. it uses the B-tree as an ordered priority set.

Both are created with degree 2 (`btree.New(2)`, `btree.NewG(2, less)`), i.e.
the smallest legal B-tree, a 2-3-4 tree **(unverified: that google/btree
degree 2 means 1 to 3 items per node; this is the library's documented
behaviour, the library source is not in the checkout)**.

### Where

- `milvus/go.mod:19` — `github.com/google/btree v1.1.2` (direct dependency)
- `milvus/internal/kv/mem/mem_kv.go:37-55` — struct and constructor
- `milvus/internal/kv/mem/mem_kv.go:87-92` — `Less` on the key
- `milvus/internal/kv/mem/mem_kv.go:140-153` — range scan with limit
- `milvus/internal/kv/mem/mem_kv.go:297-307` — prefix walk
- `milvus/internal/streamingcoord/server/broadcaster/schema.go:58-98`

### Snippet

```go
// internal/kv/mem/mem_kv.go:37-41, 90-92
// MemoryKV implements BaseKv interface and relies on underling btree.BTree.
type MemoryKV struct {
	sync.RWMutex
	tree *btree.BTree
}
func (s memoryKVItem) Less(than btree.Item) bool {
	return s.key < than.(memoryKVItem).key
}
```

```go
// internal/kv/mem/mem_kv.go:297-307  (prefix scan = seek + iterate + stop)
kv.tree.AscendGreaterOrEqual(memoryKVItem{key: prefix}, func(i btree.Item) bool {
	...
	item := i.(memoryKVItem)
	if !strings.HasPrefix(item.key, prefix) {
		return false
	}
	walkErr = fn([]byte(item.key), item.value.ByteSlice())
	return walkErr == nil
})
```

```go
// internal/streamingcoord/server/broadcaster/schema.go:90-97
tasks = &collectionSchemaTasks{pending: btree.NewG(2, func(a, b *SchemaTarget) bool {
	return a.BroadcastID < b.BroadcastID
})}
...
tasks.pending.ReplaceOrInsert(snapshot)
tasks.head, _ = tasks.pending.Min()
```

### Teaching idea

- Early chapter "What an ordered map buys you": the three operations Milvus
  actually calls are `Get`, `AscendRange(lo, hi)` and
  `AscendGreaterOrEqual(prefix)` with an early-stop callback. A hash map can do
  only the first. This is the cleanest real-world motivation for a B-tree API.
- Exercise (Zig and Rust): implement `scan_prefix(prefix)` on the guide's
  B-tree as "seek to lower bound, iterate while `starts_with`". Compare with
  Rust `BTreeMap::range(prefix..)`.
- Second exercise: "B-tree as priority queue" — `min()` is the leftmost leaf's
  first key; compare with a binary heap (no delete-by-key).
- Note for the chapter on concurrency: `MemoryKV` wraps the whole tree in one
  `sync.RWMutex` (mem_kv.go:40) — the simplest possible scheme, before latch
  crabbing.

---

## 2. Milvus: metadata stores (etcd, TiKV, RocksDB)

### What it does

Milvus keeps its catalog (collections, segments, indexes) in an external
ordered KV store. The config accepts `etcd` (default) or `tikv`. All catalog
access is shaped as ordered-key operations: prefix load, sorted paginated
walk. Separately, a RocksDB-backed KV and message queue ("rocksmq") exist.

- etcd's backend is bbolt, a copy-on-write B+tree; bbolt appears in go.mod as
  an *indirect* dependency. **(unverified that etcd stores via bbolt — the
  etcd server source is not in this checkout; only the dependency line is.)**
- TiKV and RocksDB are LSM-trees **(unverified, general knowledge)**.

### Where

- `milvus/pkg/util/paramtable/service_param.go:647-652` — `metastore.type`,
  default etcd, valid `[etcd, tikv]`
- `milvus/internal/kv/etcd/etcd_kv.go:87-96` — sorted, paginated prefix walk
- `milvus/internal/kv/etcd/etcd_kv.go:128-134` — `LoadWithPrefix`
- `milvus/go.mod:272` — `go.etcd.io/bbolt v1.5.0 // indirect`
- `milvus/go.mod:35` — `github.com/tikv/client-go/v2`
- `milvus/pkg/kv/rocksdb/rocksdb_kv.go`, `milvus/pkg/mq/mqimpl/rocksmq/server/rocksmq_impl.go:204`

### Snippet

```go
// internal/kv/etcd/etcd_kv.go:91-95
opts := []clientv3.OpOption{
	clientv3.WithSort(clientv3.SortByKey, clientv3.SortAscend),
	clientv3.WithLimit(batch),
	clientv3.WithRange(clientv3.GetPrefixRangeEnd(prefix)),
}
```

### Teaching idea

- Chapter "Where B-trees actually live in a modern system": the vector
  database delegates its *small, ordered, transactional* data (metadata) to a
  B+tree/LSM KV store and builds bespoke structures only for the *big,
  immutable* data. `GetPrefixRangeEnd(prefix)` is the same trick as section 3's
  `PrefixRange` (increment the last byte) — a nice recurring motif:
  "prefix query = range query `[p, successor(p))`".
- The `MemoryKV` (B-tree) from section 1 is the test stand-in for etcd: same
  interface, same ordering semantics. Good illustration that the *interface*
  of a B-tree store is "ordered KV".

---

## 3. Milvus: STL_SORT, the sorted-array scalar index

### What it does

The "sorted" scalar index family for numeric fields is literally a
`std::sort`ed array of `(value, row_offset)` pairs. Point lookups use
`std::equal_range`; range filters use `lower_bound` / `upper_bound` and then
set one bit per matching row in a result bitmap. It is built once from the
complete input of a sealed (immutable) segment; there is no insert path.

For strings the layout is a sorted dictionary of unique values, each with a
posting list of row ids (small-vector with inline capacity 4), and the layout
can be backed by heap vectors or by packed mmap bytes.

A notable optimisation: when a range selects more than half of all rows, the
reader starts from the validity bitmap and *clears* the rows outside the range
instead of setting the rows inside it.

### Where

- `milvus/internal/core/src/index/scalar/sort/IndexStructure.h:22-52` — the
  `(a_, idx_)` pair, compared by value only
- `milvus/internal/core/src/index/scalar/sort/SortedIndexBuilder.cpp:302-322`
  — build: append valid rows, then `std::sort`
- `milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:534-546`
  — equality via `std::equal_range`
- `milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:622-655`
  — two-sided range
- `milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:364-379`
  — `PrefixRange` for strings
- `milvus/internal/core/src/index/scalar/sort/SortedIndexReader.h:86-123` —
  `SortedStringLayout` (heap / packed heap / packed mmap)
- `milvus/internal/core/src/index/scalar/sort/SortedStringPostingList.h:26-28`

### Snippet

```cpp
// sort/SortedIndexReader.cpp:637-655
const auto first =
    lo_inc ? std::lower_bound(begin, end, IndexStructure<T>(lo))
           : std::upper_bound(begin, end, IndexStructure<T>(lo));
const auto last = hi_inc
                      ? std::upper_bound(begin, end, IndexStructure<T>(hi))
                      : std::lower_bound(begin, end, IndexStructure<T>(hi));
if (value_lookup && static_cast<size_t>(last - first) > count / 2) {
    result = validity.clone();
    for (auto it = begin; it != first; ++it) {
        SetNumericRow(result, static_cast<size_t>(it->idx_), false);
    }
    ...
} else {
    for (auto it = first; it != last; ++it) {
        SetNumericRow(result, static_cast<size_t>(it->idx_), true);
    }
}
```

```cpp
// sort/SortedIndexReader.cpp:364-379  (prefix -> [prefix, successor(prefix)))
PrefixRange(const SortedStringLayout& layout, std::string_view prefix) {
    ...
    const auto start = LowerBound(layout, prefix);
    std::string next(prefix);
    for (size_t i = next.size(); i > 0; --i) {
        const auto byte = static_cast<unsigned char>(next[i - 1]);
        if (byte != std::numeric_limits<unsigned char>::max()) {
            next[i - 1] = static_cast<char>(byte + 1);
            next.resize(i);
            return {start, LowerBound(layout, next)};
        }
    }
    return {start, layout.UniqueCount()};
}
```

### Teaching idea

- This is the ideal **chapter 1** of the guide: "A sorted array is a B-tree
  with one node". It supports every B-tree read (point, range, prefix,
  ordered scan) at `O(log n)` with perfect locality and zero pointer overhead.
  The only thing it cannot do is insert cheaply — and Milvus sidesteps that by
  only indexing immutable segments. A B-tree is then introduced as "the fix
  for the O(n) insert: cut the array into page-sized pieces and index the
  pieces".
- The four `lo_inc`/`hi_inc` combinations mapping onto
  `lower_bound`/`upper_bound` is a compact table worth reproducing; inclusive
  vs exclusive bounds is a classic source of off-by-one bugs in B-tree range
  scans.
- Small Zig/Rust example: `fn range(sorted: []const Entry, lo: Bound, hi: Bound) []const Entry`
  using `partition_point` (Rust) / `std.sort.lowerBound` (Zig).
- Animation: bar chart of sorted values; two binary searches converge on the
  boundaries, then the slice between lights up and "rains" bits into a row
  bitmap. A toggle shows the "> half the rows" inversion path.
- Design note: the index returns a **bitmap of row offsets**, not rows. This
  is the secondary-index/heap-file split that B+tree chapters describe as
  "leaf holds RID".

---

## 4. Milvus: galloping search for `IN (...)` on a sorted array

### What it does

For `field IN (v1, v2, ...)` the sorted index sorts and de-duplicates the query
values, then walks the index with one moving cursor. To advance the cursor to
the next query value it uses exponential ("galloping") search to bracket the
position and a binary search inside the bracket. This is a merge-style
intersection that costs `O(m log(n/m))` rather than `m` independent
`O(log n)` searches from the start.

### Where

- `milvus/internal/core/src/index/scalar/sort/SortedMembership.h:30-71`

### Snippet

```cpp
// sort/SortedMembership.h:45-62
if (value_at(cursor) < value) {
    const size_t remaining = size - cursor;
    size_t lo = 1;
    size_t hi = 1;
    while (hi < remaining && value_at(cursor + hi) < value) {
        lo = hi + 1;
        hi = hi > remaining / 2 ? remaining : hi * 2;
    }
    // Lower bound inside the galloped bracket. Never subtract values:
    // signed extremes and infinities are ordinary comparison operands.
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;
        if (value_at(cursor + mid) < value) { lo = mid + 1; } else { hi = mid; }
    }
    cursor += lo;
}
```

### Teaching idea

- B-tree analogue: a **multi-key lookup with a sorted batch** should not
  restart from the root for every key. After finding key *i*, key *i+1* is
  usually in the same leaf or a right sibling — follow the leaf chain or
  re-descend from the lowest common ancestor. Chapter idea: "Batched lookups
  and finger search".
- The comment "Never subtract values" and `mid = lo + (hi - lo) / 2` are two
  correctness lessons to carry into the binary-search-within-node chapter
  (comparator must be `<`, never `a - b`; midpoint must not overflow).
- Zig/Rust exercise: `gallop_lower_bound(slice, from, key)`; benchmark against
  restarting binary search for sorted probe sets of different densities.

---

## 5. Milvus: bitmap index = ordered dictionary + Roaring postings

### What it does

The bitmap index maps each distinct value to a bitmap of the rows holding it.
The mapping is a `std::map` (an ordered, pointer-based balanced tree — a
red-black tree in common standard libraries **(unverified, implementation
detail of libstdc++/libc++)**) whose values are `roaring::Roaring` compressed
bitmaps or plain bitsets. Because the dictionary is *ordered*, range
predicates still work: take `lower_bound`/`upper_bound` iterators in the map
and OR together every posting bitmap in between. A prefix-sum of posting
cardinalities (`range_prefix`) lets it decide to clear the complement instead
when the range covers most rows.

### Where

- `milvus/internal/core/src/index/scalar/bitmap/BitmapIndexReader.h:70-76` —
  `BitmapPostingMap = std::map<T, Posting, std::less<>>`
- `milvus/internal/core/src/index/scalar/bitmap/BitmapIndexReader.cpp:126-155`
  — `UnionKeyRange`
- `milvus/internal/core/src/index/scalar/bitmap/BitmapIndexReader.cpp:344-355`
  — two-sided range
- `milvus/internal/core/src/index/scalar/bitmap/BitmapIndexReader.h:83` —
  frozen Roaring file kept mmapped

### Snippet

```cpp
// bitmap/BitmapIndexReader.cpp:350-354
const auto begin = lo_inc ? storage.postings.lower_bound(lo)
                          : storage.postings.upper_bound(lo);
const auto end = hi_inc ? storage.postings.upper_bound(hi)
                        : storage.postings.lower_bound(hi);
return UnionKeyRange(storage, begin, end);
```

```cpp
// bitmap/BitmapIndexReader.cpp:151-155
TargetBitmap result(storage.options.total_num_rows, false);
for (auto it = begin; it != end; ++it) {
    UnionPosting(result, it->second);
}
return result;
```

### Teaching idea

- Chapter "Duplicate keys in a B-tree": there are two designs — store
  `(key, rid)` once per row (section 3's sorted array, a classic non-unique
  B+tree) or store each key once with a *posting list / bitmap* of rids (this
  section). The second is exactly a B-tree whose leaf value is a bitmap; cost
  of a range query becomes proportional to the number of *distinct keys* in
  the range, not the number of rows.
- Cardinality intuition: with 10 distinct values and 1M rows, the dictionary
  has 10 entries (any structure works) and the work is all bitmap OR — which
  is word-parallel. With 1M distinct values the bitmaps degenerate to one bit
  each and the sorted array wins. See section 6 (Hybrid).
- Animation: a tiny ordered dictionary on the left, a stack of bitmaps on the
  right; dragging a range slider ORs the selected rows into a result bitmap.

---

## 6. Milvus: inverted (Tantivy), Marisa trie, R-tree, and the Hybrid selector

### What it does

- **Inverted**: delegates to the Tantivy engine (Rust full-text library) for
  term, range and prefix queries. The reader just forwards
  `lower_bound_range_query`, `upper_bound_range_query`, `range_query`,
  `prefix_query`. Tantivy's term dictionary is an FST and numeric range
  handling is its own **(unverified, Tantivy internals not studied)**.
- **Marisa**: a succinct trie (MARISA library) for strings. Exact lookup is a
  trie walk to a key id; rows per key come from a CSR array
  (`csr_index[key_id] .. csr_index[key_id+1]`). Range queries are the weak
  point: the reader enumerates keys with `predictive_search` and compares each
  one, with an early `break` only when the trie is in label (lexicographic)
  order and the operator is `<`/`<=`.
- **R-tree**: spatial index using Boost.Geometry `rtree` with R*-tree
  splitting and max 16 entries per node, built by bulk packing.
- **Hybrid**: at build time counts distinct values and picks a family:
  below `cardinality_limit` use BITMAP; otherwise SORT for integers and
  INVERTED for strings/others (legacy defaults; newer versions read the two
  families from config).

### Where

- `milvus/internal/core/src/index/scalar/inverted/InvertedIndexReader.cpp:406-434, 457-460, 491`
- `milvus/internal/core/src/index/scalar/marisa/MarisaIndexReader.cpp:50-53`
  (lookup), `:83-98` (CSR rows), `:346-390` (range by enumeration)
- `milvus/internal/core/src/index/scalar/spatial/RTreeEngine.h:49` —
  `bgi::rtree<Value, bgi::rstar<16>>`; `:70-72` bulk load
- `milvus/internal/core/src/index/scalar/hybrid/HybridIndexBuilder.cpp:468-482`
  (family defaults), `:531-535` (`SelectFamily`)

### Snippet

```cpp
// hybrid/HybridIndexBuilder.cpp:531-535
HybridIndexBuilder<T>::SelectFamily(size_t distinct_count) const {
    return distinct_count >= static_cast<size_t>(params_.cardinality_limit)
               ? params_.high_cardinality_family
               : params_.low_cardinality_family;
```

```cpp
// marisa/MarisaIndexReader.cpp:358-389 (abridged): range = enumerate + compare
while (storage->trie->predictive_search(agent)) {
    const std::string_view key(agent.key().ptr(), agent.key().length());
    bool matches = false;
    switch (op) { case CompareOp::GreaterThan: matches = key > value; break; ... }
    if (matches) {
        SetRowsForKey(*storage, agent.key().id(), true, result);
    } else if (ordered &&
               (op == CompareOp::LessThan || op == CompareOp::LessEqual) &&
               key >= value) {
        break;
    }
}
```

### Teaching idea

- Chapter "B-tree vs trie vs R-tree: what is the node's separator?"
  - B-tree node: sorted scalar separators, children cover disjoint key
    intervals — one path per lookup.
  - Trie node: one byte of the key — great for exact/prefix, poor for range
    unless traversal order is lexicographic (the Marisa code shows the cost:
    full key enumeration).
  - R-tree node: bounding rectangles that may **overlap** — a lookup can
    descend several children. This is the stepping stone to section 14:
    once regions overlap, the "one root-to-leaf path" guarantee is gone.
- The Hybrid selector is a concrete, quotable rule for the "choose an index"
  chapter: **cardinality decides**. Reproduce it as a 5-line Rust `match`.
- The R-tree's `rstar<16>` + bulk load mirrors B-tree fanout and bulk-loading
  (sorted fill of leaves, then build parents) — good cross-reference from the
  bulk-load chapter.

---

## 7. Milvus: skip index (min/max + bloom) = a one-level "B-tree of statistics"

### What it does

For every chunk of every field Milvus keeps tiny metrics: `min`, `max`, and
for integers/strings an optional bloom filter (strings also an n-gram bloom
filter). Before evaluating a predicate on a chunk the executor asks
`CanSkipUnaryRange` / `CanSkipBinaryRange` / `CanSkipInQuery`; if the
predicate interval does not intersect `[min, max]` (or the bloom filter says
"definitely absent" for equality), the whole chunk is skipped.

Nothing orders the chunks, so every chunk's metrics are tested: it prunes,
it does not navigate.

### Where

- `milvus/internal/core/src/index/SkipIndex.h:95-131` — per-chunk skip checks
- `milvus/internal/core/src/index/skipindex_stats/SkipIndexStats.h:168-187` —
  `RangeShouldSkip`
- `milvus/internal/core/src/index/skipindex_stats/SkipIndexStats.h:491-527` —
  `IntFieldChunkMetrics` (min, max, bloom; bloom used for `Equal`)
- `milvus/internal/core/src/index/skipindex_stats/SkipIndexStats.h:621-630` —
  string metrics incl. n-gram bloom

### Snippet

```cpp
// skipindex_stats/SkipIndexStats.h:176-186
bool should_skip = false;
if (lower_inclusive && upper_inclusive) {
    should_skip = (lower_val > upper_bound) || (upper_val < lower_bound);
} else if (lower_inclusive && !upper_inclusive) {
    should_skip = (lower_val > upper_bound) || (upper_val <= lower_bound);
} else if (!lower_inclusive && upper_inclusive) {
    should_skip = (lower_val >= upper_bound) || (upper_val < lower_bound);
} else {
    should_skip = (lower_val >= upper_bound) || (upper_val <= lower_bound);
}
```

### Teaching idea

- Chapter "What an internal node really is": a B-tree internal node is a
  *sorted, non-overlapping* list of `[min, max)` summaries of its children.
  A zone map / skip index is the same summary **without** the sortedness or
  disjointness — so you must test all of them (`O(#chunks)`) instead of binary
  searching (`O(log)`). If the data happens to be sorted by that column, the
  zone map *becomes* a B-tree root. Great "aha" visual: same picture, shuffle
  the children, watch binary search stop working.
- Animation: chunks as horizontal `[min,max]` bars on a number line; a query
  interval sweeps; non-intersecting bars grey out. Toggle "data clustered"
  vs "data random" to show when zone maps are useless (all bars span
  everything).
- Bloom filter as the point-lookup complement: min/max handles ranges, bloom
  handles equality — B-trees handle both with one structure, at the cost of
  maintaining order.

---

## 8. Milvus: primary-key lookup (ordered map vs ordered array vs zero storage)

### What it does

Each segment needs `pk -> row offset`. Three implementations of one
interface (`OffsetMap`):

- **Growing (mutable) segment**: `OffsetOrderedMap` — a `std::map<T,
  vector<int64>>` under a `shared_mutex`. Pointer-based ordered tree because
  inserts arrive continuously.
- **Sealed (immutable) segment**: `OffsetOrderedArray` — a
  `vector<pair<T, int32>>`; `insert` just appends, `seal()` sorts once, and
  searching before `seal()` or inserting after it is an error. Lookups use
  `std::lower_bound`.
- **External collections**: `VirtualPKOffsetMap` — the PK *encodes* the offset
  (`pk & 0xFFFFFFFF`), so no structure at all; the comment claims ~17 GB saved
  per 1B rows.

Across segments (Go side) there is no global PK index. Each segment has
`PkStatistics {bloom filter, MinPK, MaxPK}`; "which segments may contain this
PK?" is answered by testing every segment's stats (`BloomFilterSet.MayPkExist`).
The bloom filter has basic and *blocked* variants (blocked = one cache line
per probe **(unverified: the cache-line property is general knowledge about
blocked bloom filters)**).

### Where

- `milvus/internal/core/src/segcore/InsertRecord.h:305-312` — `OffsetOrderedMap`
- `milvus/internal/core/src/segcore/InsertRecord.h:619-632, 717-730` —
  `OffsetOrderedArray` (`contain`, `insert`, `seal`)
- `milvus/internal/core/src/segcore/InsertRecord.h:902-914` — `VirtualPKOffsetMap`
- `milvus/internal/core/src/segcore/InsertRecord.h:1140-1148` (sealed picks
  array), `:1465-1472` (growing picks map)
- `milvus/internal/storage/pk_statistics.go:31-35, 85-110, 129-142`
- `milvus/internal/querynodev2/pkoracle/bloom_filter_set.go:58-72`
- `milvus/internal/util/bloomfilter/bloom_filter.go:41-46`

### Snippet

```cpp
// segcore/InsertRecord.h:717-730
void insert(const PkType& pk, int64_t offset) override {
    if (is_sealed) {
        ThrowInfo(Unsupported, "OffsetOrderedArray could not insert after seal");
    }
    array_.push_back(
        std::make_pair(std::get<T>(pk), static_cast<int32_t>(offset)));
}
void seal() override {
    sort(array_.begin(), array_.end());
    is_sealed = true;
}
```

```go
// internal/storage/pk_statistics.go:85-93 (abridged)
func (st *PkStatistics) PkExist(pk PrimaryKey) bool {
	...
	// check pk range first, ugly but key it for now
	if st.MinPK.GT(pk) || st.MaxPK.LT(pk) {
		return false
	}
	// if in range, check bloom filter
```

### Teaching idea

- Chapter "Mutable vs immutable ordered structures": the same lookup
  interface gets a tree while data is changing and a sorted array once it is
  frozen. A B-tree is the structure that tries to be *both* at once (array
  inside the node, tree between nodes). This pair is a perfect motivating
  example, and the guide's Zig/Rust code can mirror it:
  `trait OffsetMap { insert, seal, find }` with two impls, then the B-tree as
  a third impl that needs no `seal`.
- "A primary index over many segments" — a relational DB has one B-tree for
  the PK; Milvus has N per-segment structures plus N bloom filters and
  min/max pairs, costing `O(N)` probes per lookup. This is exactly the LSM
  read path and motivates section 9.
- `VirtualPKOffsetMap` is a reminder for the "do you need an index at all?"
  sidebar: if the key can be made to encode the location (dense ids, clustered
  storage), the best index is arithmetic.

---

## 9. Milvus: segments, L0 deltas and compaction (LSM, not B-tree)

### What it does

Data is written into growing segments, which are sealed/flushed into
immutable segments (sections 3 and 8 show that every sealed-segment index is
build-once). Deletes are never applied in place: they are recorded as
`(pk, timestamp)` delta logs. Segment levels are an explicit enum:

- `L0`: "contains delta data for current channel" — delete records only
- `L1`: normal segment
- `L2`: segment with extra data-distribution info (clustering)

Compaction then rewrites:

- **L0 compaction** takes delete records, uses the per-segment PK bloom
  filters to decide which L1/L2 segments each deleted PK may live in, and
  writes per-segment delta logs.
- **Mix / merge-sort compaction** reads several segments, drops rows that are
  deleted (a delete applies only if `row_ts < delete_ts`) or TTL-expired, and
  writes new segments (`mergeSortMultipleSegments` keeps PK order).

### Where

- `milvus/pkg/proto/data_coord.proto:27-32` — `SegmentLevel`
- `milvus/internal/datanode/compactor/l0_compactor.go:194-213, 374-392` —
  split deletes by bloom filter
- `milvus/internal/compaction/entity_filter.go:50-67, 89-101` — drop
  deleted/expired rows
- `milvus/internal/datanode/compactor/merge_sort.go:24` —
  `mergeSortMultipleSegments`
- `milvus/internal/datanode/compactor/` — `mix_compactor.go`,
  `clustering_compactor.go`, `sort_compaction.go`
- `milvus/internal/datacoord/compaction/policy/` — `l0.go`, `single.go`,
  `clustering.go`, `forcemerge.go` (trigger policies; file list only, logic
  not studied)

### Snippet

```proto
// pkg/proto/data_coord.proto:27-32
enum SegmentLevel {
  Legacy = 0; // zero value for legacy logic
  L0 = 1; // L0 segment, contains delta data for current channel
  L1 = 2; // L1 segment, normal segment, with no extra compaction attribute
  L2 = 3; // L2 segment, segment with extra data distribution info
}
```

```go
// internal/compaction/entity_filter.go:89-99 (abridged)
func (filter *EntityFilterImpl) isEntityDeleted(pk interface{}, pkTs typeutil.Timestamp) bool {
	if deleteTs, ok := filter.deletedPkTs[pk]; ok {
		...
		effectiveTs := tsoutil.EffectiveTimestamp(pkTs, filter.commitTs)
		if effectiveTs < deleteTs {
			return true
		}
	}
	return false
}
```

### Teaching idea

- Late chapter "B-tree vs LSM, seen through a system that had no choice":
  vector indexes (HNSW, IVF) are expensive to build and bad at in-place
  update/delete, so Milvus *must* use immutable runs + tombstones +
  background merge. B-tree = pay at write time (find the page, modify in
  place, maybe split); LSM = pay later (append now, merge in background, read
  from several runs with bloom filters).
- Careful wording for the guide: Milvus levels are **not** RocksDB's sorted,
  size-tiered key levels. L0 here means "delete deltas", L1 segments are not
  globally sorted by key against each other. It is LSM-*like* (immutable
  runs, tombstones with timestamps, compaction), not an LSM-tree over keys.
- Animation: a B-tree absorbing a delete (leaf shrinks, maybe merges) next to
  the Milvus path (tombstone appended to L0 → bloom filters route it → next
  compaction physically drops the row).

---

## 10. FAISS: IndexFlat, the honest baseline

### What it does

`IndexFlat` stores all vectors in one contiguous byte array (`codes`,
`code_size = sizeof(float) * d`) and answers a k-NN query by computing the
distance to **every** vector, keeping the best k in a heap. No structure, no
approximation, `O(n * d)` per query — but the inner loop is a SIMD/BLAS
kernel over contiguous memory.

### Where

- `faiss/faiss/IndexFlat.cpp:26-27` — constructor (`code_size`)
- `faiss/faiss/IndexFlat.cpp:29-45` — `search`
- `faiss/faiss/utils/distances.cpp:327` (`exhaustive_L2sqr_seq`),
  `:429` (`exhaustive_L2sqr_blas_tiles`)

### Snippet

```cpp
// faiss/IndexFlat.cpp:38-45
// we see the distances and labels as heaps
if (metric_type == METRIC_INNER_PRODUCT) {
    float_minheap_array_t res = {size_t(n), size_t(k), labels, distances};
    knn_inner_product(x, get_xb(), d, n, ntotal, &res, sel);
} else if (metric_type == METRIC_L2) {
    float_maxheap_array_t res = {size_t(n), size_t(k), labels, distances};
    knn_L2sqr(x, get_xb(), d, n, ntotal, &res, nullptr, sel);
}
```

### Teaching idea

- Use as the "unsorted heap file / full table scan" of the vector world. In
  1-D the scan is beaten by a sorted array and then a B-tree; in 128-D it is
  the reference everything is measured against (recall = fraction of the
  flat index's answers an approximate index returns).
- Exercise (Rust/Zig): k-NN by linear scan with a bounded max-heap; then set
  d = 1 and show that sorting + binary search gives the same answer in
  `O(log n)`; then explain why that trick does not survive d = 2.

---

## 11. FAISS: IndexIVF, a one-level tree whose root is not ordered

### What it does

Training runs k-means to get `nlist` centroids (the "coarse quantizer",
itself an `Index`). Each added vector goes into the inverted list of its
nearest centroid. A query (1) asks the quantizer for the `nprobe` nearest
centroids, (2) scans those lists fully, (3) merges into a top-k heap.

Structurally this is a two-level tree: the root holds `nlist` routing entries
(centroids), each leaf is a flat array (`codes`, `ids`). The differences from
a B-tree root are the whole lesson:

- The routing step is itself a nearest-neighbour **search** over all centroids
  (`quantizer->search`), not a binary search over sorted separators.
- The partition cells (Voronoi regions) do not guarantee the answer is in
  one cell, so `nprobe > 1` leaves are visited — a deliberate
  recall-for-time trade.
- The default `nprobe` is 1.

The coarse quantizer can be made hierarchical: the factory string
`IVF<n>_HNSW<M>` uses an HNSW graph over the centroids, i.e. a navigation
structure on top of the root.

### Where

- `faiss/faiss/IndexIVF.h:30-35` — `Level1Quantizer` (`quantizer`, `nlist`)
- `faiss/faiss/IndexIVF.h:96-97` — `nprobe = 1`
- `faiss/faiss/IndexIVF.h:202-221` — doc comment (quoted below)
- `faiss/faiss/IndexIVF.cpp:910-921` — coarse search then `prefetch_lists`
- `faiss/faiss/IndexIVF.cpp:669, 737` — `scan_one_list` → `scanner->scan_codes`
- `faiss/faiss/invlists/InvertedLists.h:264-266` — `ArrayInvertedLists`
- `faiss/faiss/index_factory.cpp:318-322` — `IVF..._HNSW..`

### Snippet

```cpp
// faiss/IndexIVF.h:212-217
 * At search time, the vector to be searched is also quantized, and
 * only the list corresponding to the quantization index is
 * searched. This speeds up the search by making it
 * non-exhaustive. This can be relaxed using multi-probe search: a few
 * (nprobe) quantization indices are selected and several inverted
 * lists are visited.
```

```cpp
// faiss/IndexIVF.cpp:916-921
quantizer->search(
        nx, x, cur_nprobe, coarse_dis.get(), keys.get(), quantizer_params);
...
invlists->prefetch_lists(keys.get(), static_cast<int>(nx * cur_nprobe));
```

```cpp
// faiss/invlists/InvertedLists.h:264-266
struct ArrayInvertedLists : InvertedLists {
    std::vector<MaybeOwnedVector<uint8_t>> codes; // binary codes, size nlist
    std::vector<MaybeOwnedVector<idx_t>> ids; ///< Inverted lists for indexes
```

### Teaching idea

- Chapter "A B-tree is a partition; so is IVF": draw both as "root routes to
  one of N buckets". In the B-tree the buckets are disjoint *intervals* and
  the query key falls in exactly one; in IVF the buckets are Voronoi cells
  and the query's true neighbours can sit across a cell boundary.
- Interactive HTML: 2-D points coloured by nearest centroid; click a query
  near a boundary; with `nprobe=1` the true nearest neighbour (in the
  adjacent cell) is missed; slide `nprobe` up and recall recovers. Next to it
  a 1-D B-tree where the same "boundary" problem cannot arise for point
  lookup — and note that a 1-D *nearest* query needs at most the two
  neighbouring leaves (predecessor/successor), which is the last dimension in
  which that is bounded.
- `prefetch_lists` after routing = the B-tree idea of issuing read-ahead for
  the leaves once the internal node tells you which ones you need.

---

## 12. FAISS: HNSW, a skip list generalised to a metric space

### What it does

HNSW is a layered proximity graph. Every vector is on level 0; each is
assigned a random maximum level with exponentially decaying probability, so
upper levels are sparse "express lanes". Search starts at a single
`entry_point` on the top level, greedily hops to whichever neighbour is
closer to the query until no neighbour improves, drops a level, and repeats;
on level 0 it runs a best-first search with a candidate queue of size
`efSearch`.

Storage is not pointer-based: all adjacency lists of all nodes live in one
flat `neighbors` array; node `i` owns `neighbors[offsets[i] .. offsets[i+1])`
and the slice for a given level is found with a cumulative per-level table.
Level 0 gets `2*M` links, upper levels `M`. Unused slots are `-1`.

### Where

- `faiss/faiss/impl/HNSW.h:113-138` — fields (`assign_probas`,
  `cum_nneighbor_per_level`, `levels`, `offsets`, `neighbors`, `entry_point`,
  `max_level`)
- `faiss/faiss/impl/HNSW.cpp:52-60` — `neighbor_range`
- `faiss/faiss/impl/HNSW.cpp:62-65` — default `levelMult = 1/log(M)`
- `faiss/faiss/impl/HNSW.cpp:67-78` — `random_level`
- `faiss/faiss/impl/HNSW.cpp:80-92` — `set_default_probas`
- `faiss/faiss/impl/HNSW.cpp:702-760` — `greedy_update_nearest_impl`
- `faiss/faiss/impl/HNSW.cpp:1775-1796` — descent through levels, then
  level-0 candidate search
- `faiss/faiss/impl/HNSW.cpp:1181` — visited-table prefetch for neighbours

### Snippet

```cpp
// faiss/impl/HNSW.cpp:80-92
void HNSW::set_default_probas(int M, float levelMult) {
    int nn = 0;
    cum_nneighbor_per_level.push_back(0);
    for (int level = 0;; level++) {
        float proba = exp(-level / levelMult) * (1 - exp(-1 / levelMult));
        if (proba < 1e-9) {
            break;
        }
        assign_probas.push_back(proba);
        nn += level == 0 ? M * 2 : M;
        cum_nneighbor_per_level.push_back(nn);
    }
}
```

```cpp
// faiss/impl/HNSW.cpp:1775-1783
//  greedy search on upper levels
storage_idx_t nearest = hnsw.entry_point;
float d_nearest = qdis(nearest);

for (int level = hnsw.max_level; level >= 1; level--) {
    HNSWStats local_stats = greedy_update_nearest_impl<C>(
            hnsw, qdis, level, nearest, d_nearest);
    stats.combine(local_stats);
}
```

```cpp
// faiss/impl/HNSW.cpp:57-59
size_t o = offsets[no];
*begin = o + cum_nb_neighbors(layer_no);
*end = o + cum_nb_neighbors(layer_no + 1);
```

### Teaching idea

- Chapter "Skip lists, B-trees and HNSW are the same idea three times":
  a sparse upper layer lets you take big steps, then you refine below.
  - Skip list: random level per key, each level a *sorted linked list*; you
    move right while `next.key <= target` — the order tells you when to stop.
  - B-tree: deterministic levels, each node a sorted array; one comparison
    sequence picks one child.
  - HNSW: random level per vector (same geometric distribution — with
    `levelMult = 1/ln M`, P(level >= l) = M^-l, so each level is ~M times
    sparser: the "fanout"), but there is no order, so "move right while
    smaller" becomes "move to any neighbour that is closer", and termination
    is a local minimum rather than a proof.
- The guarantee changes: B-tree/skip list search is exact; HNSW's greedy
  descent can stop in a local minimum, hence `efSearch` (keep several
  candidates) and "recall" as a metric.
- Side-by-side animation: the same 1-D keys as a skip list and as a 1-D HNSW;
  then move the points into 2-D and watch the skip list become meaningless
  while HNSW still works.
- Zig/Rust mini-example: `random_level()` shared by a skip list and a toy
  HNSW; CSR-style `offsets`/`neighbors` adjacency instead of
  `Vec<Vec<u32>>` / pointer nodes.
- Updates: grep finds no `remove_ids` override in `IndexHNSW.h/.cpp`; graph
  deletion is hard because other nodes' links route *through* the deleted
  node — contrast with B-tree delete (borrow/merge is local to a node and its
  siblings).

---

## 13. FAISS: other partition structures, and the absent kd-tree

### What it does

- **No kd-tree / ball tree**: a case-insensitive grep for `kd-tree`,
  `kdtree`, `ball tree` over `faiss/faiss` `.h`/`.cpp` returns nothing. The
  library that defines the state of practice for high-dimensional search
  simply does not ship space-partitioning trees.
- **IndexBinaryHash**: "just uses the b first bits as a hash value"; buckets
  are an `unordered_map<idx_t, InvertedList>`; near matches are found by
  flipping up to `nflip` bits of the query hash (multi-probe).
- **Index2Layer / IndexHNSW2Level**: two-level quantisation (coarse
  `Level1Quantizer` + PQ) — hierarchy of *codes*, not of ordered keys.
- **IVF with HNSW coarse quantizer** (section 11): the closest thing to a
  multi-level tree — graph over centroids, then flat leaves.

### Where

- `faiss/faiss/IndexBinaryHash.h:25-37`; `faiss/faiss/IndexBinaryHash.cpp:71-72`
- `faiss/faiss/Index2Layer.h:29-39`
- `faiss/faiss/index_factory.cpp:318-322, 634-644`

### Snippet

```cpp
// faiss/IndexBinaryHash.h:25-37 (abridged)
/** just uses the b first bits as a hash value */
struct IndexBinaryHash : IndexBinary {
    struct InvertedList {
        std::vector<idx_t> ids;
        std::vector<uint8_t> vecs;
        ...
    };
    using InvertedListMap = std::unordered_map<idx_t, InvertedList>;
    InvertedListMap invlists;
    int b, nflip;
```

### Teaching idea

- Sidebar "Hash index vs B-tree, vector edition": hashing on a prefix of bits
  is the vector analogue of a hash index — exact-bucket lookup is O(1), but
  "nearby" keys are in unrelated buckets, so the code must enumerate
  bit-flipped buckets. Same reason a hash index cannot do range scans.
- The absence of kd-trees is itself the lesson for section 14; mention it
  explicitly so readers do not assume "trees for vectors" is the default.

---

## 14. Why B-trees fail for vector similarity

A B-tree's correctness rests on three facts. Each can be tied to code above.

1. **A total order in which "close in order" means "close in value".**
   In section 3 the answer to a range query is one contiguous slice
   `[first, last)` of the sorted array (`SortedIndexReader.cpp:637-642`).
   For vectors there is no ordering of R^d (d >= 2) in which every metric
   ball is a contiguous run: any linearisation (lexicographic, Z-order,
   Hilbert) puts some near neighbours arbitrarily far apart in the order.
   **(unverified: standard result; not something the source states.)**
   What the code does instead: IVF replaces "compare with separators" by
   "search for the nearest centroids" (`IndexIVF.cpp:916`), HNSW replaces
   "move right in sorted order" by "move to a closer neighbour"
   (`HNSW.cpp:702-727`).

2. **One child per level is enough.** In a B-tree the separators partition
   the key space into disjoint intervals; the query key lies in exactly one.
   For a nearest-neighbour query the ball around the query can straddle
   partition boundaries. IVF admits this in its own doc comment
   ("multi-probe search", `IndexIVF.h:215-217`) and exposes `nprobe`; the
   R-tree in Milvus (section 6) already shows overlap in 2-D.

3. **Pruning is effective.** A B-tree comparison discards (fanout-1)/fanout
   of the remaining keys. In high dimensions distances concentrate: the
   nearest and farthest points are at nearly the same distance, so
   bounding-box / bounding-ball tests rarely exclude a subtree and a
   kd-tree degenerates to scanning most leaves **(unverified: "curse of
   dimensionality", general knowledge)**. The evidence in source is
   indirect but strong: FAISS ships a highly optimised exhaustive scan
   (`IndexFlat`), partition+scan (IVF), and graphs (HNSW, NSG, NNDescent),
   and no kd-tree (section 13); and every non-flat index is *approximate*,
   with explicit recall knobs (`nprobe`, `efSearch`).

A fourth, softer point: **the comparison itself is expensive.** A B-tree
compare is one integer/string comparison; a vector "compare" is an O(d)
distance computation, so the engineering effort moves from "fewer
comparisons" to "cheaper comparisons" — SIMD kernels, quantised codes
(section 15).

### Teaching idea

- A dedicated closing chapter "Where B-trees stop". Three interactive demos:
  1. Z-order curve through a 2-D grid: pick a point, highlight its 8 spatial
     neighbours and show their positions along the 1-D curve (some far).
  2. IVF boundary miss (section 11).
  3. Distance concentration: histogram of distances from a random query to
     10k random points for d = 2, 8, 32, 128; the histogram narrows, so a
     pruning threshold stops excluding anything. (Simple to compute in the
     page; no source dependency.)
- Scalar filter + vector search in Milvus is the synthesis: scalar indexes
  (ordered, exact, bitmaps out) AND-ed with vector index results. Ordered
  structures still own everything that *has* an order.

---

## 15. Cross-cutting: SIMD scanning inside a "node"

### What it does

FAISS spends its effort on making the linear scan of a bucket extremely
fast, because every index ends in "scan a contiguous block":

- **Plain kernels**: `fvec_L2sqr` reference is a simple loop written so the
  compiler auto-vectorises it; ISA-specific files exist for AVX2, AVX-512,
  NEON, SVE, RVV with runtime dispatch.
- **Transposed (SoA) layout kernel**: `fvec_L2sqr_ny_y_transposed_D` reads
  dimension `j` of 8 different vectors with one load (`y + j * d_offset`),
  computing 8 distances per iteration via `|x|^2 - 2<x,y> + |y|^2` with
  precomputed `y_sqlen`. Specialised for D in {1,2,3,4,6,8,12,16}.
- **Batch of 4**: HNSW buffers 4 neighbour ids and calls
  `distances_batch_4` instead of 4 scalar calls.
- **FastScan**: 4-bit PQ codes are regrouped into blocks of `bbs` (multiple
  of 32) so that a 16-entry lookup table fits in a SIMD register and
  `_mm256_shuffle_epi8` performs 32 table lookups in one instruction.
  Codes are in an `AlignedTable`.

### Where

- `faiss/faiss/utils/simd_impl/distances_autovec-inl.h:44-53` — reference
- `faiss/faiss/utils/simd_impl/distances_avx2.cpp:122-170` — transposed
  kernel; `:209-227` — dimension dispatch
- `faiss/faiss/impl/HNSW.cpp:727-750` — batch-of-4
- `faiss/faiss/IndexFastScan.h:21-26, 50-55` — blocked code layout
- `faiss/faiss/impl/simdlib/simdlib_avx2.h:506-508` — `lookup_2_lanes`
- `faiss/faiss/impl/fast_scan/accumulate_loops.h:68, 92-93` — `bbs = 32*BB`,
  alignment checks

### Snippet

```cpp
// faiss/utils/simd_impl/distances_avx2.cpp:151-161
for (; i < ny8 * 8; i += 8) {
    // collect dim 0 for 8 D4-vectors.
    const __m256 v0 = _mm256_loadu_ps(y + 0 * d_offset);
    // this is x^2 - 2x[0]*y[0]
    __m256 dp = _mm256_fnmadd_ps(m[0], v0, x_sqlen_ymm);
    for (size_t j = 1; j < DIM; j++) {
        // collect dim j for 8 D4-vectors.
        const __m256 vj = _mm256_loadu_ps(y + j * d_offset);
        dp = _mm256_fnmadd_ps(m[j], vj, dp);
    }
```

```cpp
// faiss/IndexFastScan.h:21-26
/** Fast scan version of IndexPQ and IndexAQ. Works for 4-bit PQ and AQ for now.
 *
 * The codes are not stored sequentially but grouped in blocks of size bbs.
 * This makes it possible to compute distances quickly with SIMD instructions.
 * The trailing codes (padding codes that are added to complete the last code)
 * are garbage.
```

```cpp
// faiss/impl/simdlib/simdlib_avx2.h:506-508
simd32uint8_tpl lookup_2_lanes(simd32uint8_tpl idx) const {
    return simd32uint8_tpl(_mm256_shuffle_epi8(i, idx.i));
}
```

### Teaching idea

- Chapter "Searching inside a node": for small fixed-width keys, a
  branch-free SIMD *linear* scan of the node ("count keys < target" with a
  compare + movemask + popcount) can beat binary search, because there are
  no unpredictable branches and the node is 1-4 cache lines. FAISS is the
  proof that "linear scan of a contiguous block" is a first-class strategy.
- Layout lesson to transfer directly: **keys separate from payloads, and
  struct-of-arrays inside the node** (`keys[]`, `children[]`, not
  `[(key, child)]`), plus padding to the SIMD width (FastScan pads the last
  block with garbage codes; a B-tree node can pad with `MAX_KEY` sentinels so
  the compare loop needs no tail handling).
- Zig example: `@Vector(8, u32)` compare + `@popCount(@as(u8, @bitCast(mask)))`
  to find the child index. Rust: portable `std::simd` (nightly) or
  `core::arch::x86_64::_mm256_cmpgt_epi32` + `movemask`; keep a scalar
  fallback, mirroring FAISS's per-ISA files + dispatch.
- Batch-of-4 lesson: when the *access* is random (neighbour ids), batch the
  work so the CPU can overlap cache misses — applicable to B-tree multi-get
  (descend several keys level by level in lockstep).

---

## 16. Cross-cutting: flat arrays and offsets instead of pointers

### What it does

Recurring pattern in both codebases: variable-size per-item data is stored
as one big array plus an offsets array (CSR), and items refer to each other
by 32-bit integer ids, not pointers.

- FAISS HNSW: `offsets` + `neighbors` (`storage_idx_t`, with the comment
  "internal storage of vectors (32 bits: this is expensive)").
- FAISS IVF: per list, a `codes` byte array and a parallel `ids` array.
- Milvus Marisa: `csr_index[key_id] .. csr_index[key_id + 1]` into
  `csr_offsets`.
- Milvus sorted index: `(value, int32 idx)` pairs; string postings use
  `uint32_t` with inline capacity 4.
- Milvus sealed PK map: `vector<pair<T, int32_t>>`.

### Where

- `faiss/faiss/impl/HNSW.h:64, 123-129`
- `faiss/faiss/invlists/InvertedLists.h:264-266`
- `milvus/internal/core/src/index/scalar/marisa/MarisaIndexReader.cpp:83-98`
- `milvus/internal/core/src/index/scalar/sort/IndexStructure.h:50-51`
- `milvus/internal/core/src/segcore/InsertRecord.h:900`

### Snippet

```cpp
// faiss/impl/HNSW.h:123-129
/// offsets[i] is the offset in the neighbors array where vector i is stored
/// size ntotal + 1
std::vector<size_t> offsets;

/// neighbors[offsets[i]:offsets[i+1]] is the list of neighbors of vector i
/// for all levels. this is where all storage goes.
MaybeOwnedVector<storage_idx_t> neighbors;
```

### Teaching idea

- Chapter "Pointers are a disk-hostile idea": B-tree nodes refer to children
  by **page id**, not by address, for the same reasons these arrays use
  indices: the structure can be written to disk / mmapped / moved / sent to
  a GPU without fix-ups; ids are half the size of pointers; and the whole
  thing is one allocation. In Rust this is also the idiomatic answer to
  ownership ("arena + `u32` indices" instead of `Box`/`Rc` child pointers);
  in Zig, `std.ArrayList(Node)` + `enum(u32) NodeId`.
- Show the guide's B-tree twice: `Box<Node>` children vs
  `Vec<Node>` + `NodeId(u32)`; the second maps 1:1 onto a page file.
- Slotted-page chapter link: `offsets[i]..offsets[i+1]` is the same
  "offset directory + packed payload" idea as variable-length keys in a
  B-tree page.

---

## 17. Cross-cutting: mmap and on-disk inverted lists

### What it does

`OnDiskInvertedLists` keeps all IVF lists in one mmapped file. Each list is
a region `codes[capacity * code_size]` followed by `ids[capacity]`, described
in memory by `{size, capacity, offset}`. Growth is handled by rounding
capacity up to a power of two, relocating the list into a bigger slot, and
keeping a free list of `Slot{offset, capacity}`. The header comment is blunt
that incremental adds are slow and recommends building in RAM and converting
with `merge_from`. `prefetch_lists` warms the lists a query will touch.

Milvus does the analogous thing for scalar indexes: sorted string layouts
and frozen Roaring bitmaps can be served straight from an mmapped file
(sections 3, 5), and Marisa's row-id array is mmapped
(`MarisaIndexReader.cpp:161` `munmap`).

### Where

- `faiss/faiss/invlists/OnDiskInvertedLists.h:24-29` — `OnDiskOneList`
- `faiss/faiss/invlists/OnDiskInvertedLists.h:31-59` — layout comment
- `faiss/faiss/invlists/OnDiskInvertedLists.h:66-74` — `Slot`, `slots`
- `faiss/faiss/invlists/OnDiskInvertedLists.cpp:269-281` — `do_mmap`
- `faiss/faiss/invlists/OnDiskInvertedLists.cpp:456-478` — resize: free old
  slot, double capacity, allocate, `memcpy`
- `faiss/faiss/invlists/OnDiskInvertedLists.cpp:487, 523` —
  `allocate_slot` / `free_slot`

### Snippet

```cpp
// faiss/invlists/OnDiskInvertedLists.h:42-54
 * Addition and resize are supported by:
 * - roundind up the capacity of the lists to a power of two
 * - maintaining a list of empty slots, sorted by size.
 * - resizing the mmapped block is adjusted as needed.
 * ...
 * Addition to the invlists is slow. For incremental add it is better
 * to use a default ArrayInvertedLists object and convert it to an
 * OnDisk with merge_from.
```

### Teaching idea

- Chapter "Why B-tree pages are fixed-size": this file is the
  counter-example. Variable-size on-disk regions need an allocator (free
  list of slots), relocation on growth (`memcpy` whole list), and
  fragmentation management ("compact if size == capacity for all lists").
  A B-tree avoids all three by making every node one fixed-size page and
  turning "grow" into "split" — a free-page list is a trivial stack.
- Compare free lists: FAISS `std::list<Slot>` of (offset, capacity) vs a
  B-tree file's freelist of page numbers (e.g. bbolt/SQLite style
  **(unverified reference)**).
- mmap caveat for the guide: the FAISS file contains no crash-consistency
  machinery in the parts read here (no WAL seen in
  `OnDiskInvertedLists.h/.cpp` grep) — it is a *read-mostly* format. A
  B-tree storage engine needs WAL or copy-on-write on top of pages; do not
  present "mmap a file" as a complete storage design.

---

## 18. Cross-cutting: GPU layouts

### What it does

FAISS's GPU directory contains Flat, IVF-Flat, IVF-PQ, IVF-SQ, binary flat,
and CAGRA (a graph index via cuVS) — and no tree index. IVF lists on the GPU
default to an "interleaved by `kWarpSize`" layout: instead of
`(v0 d0)(v0 d1)...`, storage is dimension-major within groups of 32 vectors,
so that the 32 threads of a warp each process one vector and read adjacent
memory. List lengths are padded to a multiple of the group size.
(`kWarpSize` = 32 is implied by the "(v31 d0)" comment and by
`InterleavedCodes.h:14` "interleaved by 32 encodings".)

### Where

- `faiss/faiss/gpu/` file list: `GpuIndexFlat`, `GpuIndexIVFFlat`,
  `GpuIndexIVFPQ`, `GpuIndexIVFScalarQuantizer`, `GpuIndexBinaryFlat`,
  `GpuIndexCagra`, `GpuIndexBinaryCagra`
- `faiss/faiss/gpu/GpuIndexIVFFlat.h:28` — `interleavedLayout = true`
- `faiss/faiss/gpu/impl/IVFBase.cuh:247-256` — layout comment
- `faiss/faiss/gpu/impl/InterleavedCodes.h:13-14`

### Snippet

```cpp
// faiss/gpu/impl/IVFBase.cuh:247-255
/// Whether or not our index uses an interleaved by kWarpSize layout:
/// The default memory layout is [vector][PQ/SQ component]:
/// (v0 d0) (v0 d1) ... (v0 dD-1) (v1 d0) (v1 d1) ...
///
/// The interleaved by kWarpSize memory layout is:
/// [vector / kWarpSize][PQ/SQ component][vector % kWarpSize] with padding:
/// (v0 d0) (v1 d0) ... (v31 d0) (v0 d1) (v1 d1) ... (v31 dD-1) (v32 d0)
/// (v33 d0) ... so the list length is always a multiple of num quantizers *
/// kWarpSize
```

### Teaching idea

- Sidebar "Why there is no GPU B-tree here": a root-to-leaf descent is a
  chain of *dependent* memory reads, each deciding the next address; it is
  latency-bound and branchy, so thousands of GPU cores cannot help a single
  lookup. Flat and IVF are throughput-bound, regular, data-parallel loops.
  (Reasoning is ours; the source evidence is the index list and the layout
  comment.) GPU graph search (CAGRA) works by expanding many candidates per
  step in parallel **(unverified, cuVS internals not in this checkout)**.
- The interleaved layout is the GPU version of section 15's transposed SoA
  kernel: 8 lanes for AVX2, 32 for a warp. One diagram can show AoS → SoA
  blocks for "SIMD width W", then reuse it for B-tree node key layout.
- If the guide wants a GPU/batch angle for B-trees: process a *batch* of
  lookups level by level (all queries at depth 0, then depth 1, ...), which
  turns pointer chasing into a data-parallel gather per level.

---

## 19. Comparison table

`n` = entries, `B` = B-tree fanout, `u` = distinct keys, `r` = matching rows,
`d` = vector dimension, `M`/`ef` = HNSW parameters. Rows for B+tree and skip
list are textbook values **(unverified against these sources; neither
codebase implements them)**; the others reflect the code read above.

| Structure | Query types | Lookup cost | Update cost | Memory | Disk-friendliness |
|---|---|---|---|---|---|
| **B+tree** (textbook; etcd/bbolt in Milvus's metadata path) | point, range, prefix, ordered scan, min/max; exact | `O(log_B n)` node reads, binary/SIMD search in node | `O(log_B n)`, in place, occasional split/merge | keys + child ids; nodes ~50-100% full | Excellent: fixed-size pages, 1 page per level |
| **Sorted array** (Milvus STL_SORT, `OffsetOrderedArray`) | point, range, prefix, IN (galloping); exact | `O(log n)` binary search; result is one contiguous slice | Insert `O(n)`; in Milvus build-once (`seal()`), no updates | Minimal: `(value, int32)` pairs, no pointers | Very good read-only (mmap); binary search touches `log n` scattered pages |
| **Inverted index** (Milvus INVERTED via Tantivy; string sorted dictionary + postings) | term, IN, range, prefix, text match; exact | dictionary lookup + posting read, `O(r)` | Append-friendly per segment; immutable segments + merge | dictionary + compressed postings | Good: segment files, mmap |
| **Bitmap index** (Milvus BITMAP: `std::map` + Roaring) | equality, IN, range (OR of `u_range` bitmaps), fast AND/OR/NOT between predicates; exact | `O(log u)` dictionary + bitmap ops over rows | Build-once here; in general costly for high-cardinality | Tiny for low cardinality; poor when `u ~ n` | Good: frozen Roaring mmapped |
| **Skip list** (textbook; not in either repo) | point, range, ordered scan; exact | `O(log n)` expected, pointer hops | `O(log n)` expected, no rebalancing, easy lock-free | pointers per level (~1.33-2 per key) | Poor: one node per key, random access |
| **HNSW** (FAISS `impl/HNSW.cpp`) | approximate k-NN (and range by threshold); no order queries | ~`O(log n)` greedy hops on upper levels + `ef`-bounded search on level 0; each hop is `O(M)` distance computations of `O(d)` | Insert = search + link + prune (`efConstruction`); no delete in `IndexHNSW` | vectors + `2M` int32 links on level 0, `M` above | Poor as-is: random access per hop (needs graph-aware layouts) |
| **IVF** (FAISS `IndexIVF`) | approximate k-NN / range; recall tuned by `nprobe` | coarse search over `nlist` centroids + scan `nprobe` lists ≈ `O(nlist*d + nprobe*(n/nlist)*d)` | Insert = assign + append to one list (cheap); needs retraining if distribution drifts | vectors/codes + ids; centroids | Good: each list is a contiguous run (`OnDiskInvertedLists`), sequential reads |
| **Flat scan** (FAISS `IndexFlat`) | exact k-NN / range | `O(n*d)`, SIMD/BLAS | Append `O(1)` | raw vectors only | Sequential scan; trivially mmap/GPU friendly |
| **Zone map / skip index** (Milvus `SkipIndex`) | prunes chunks for range / equality / IN; not a locator | `O(#chunks)` tests, then scan survivors | Recomputed per chunk at load/build | a few bytes + optional bloom per chunk | Excellent (tiny, kept in memory) |

---

## 20. Most important insights for a learner

1. **A sorted array is the degenerate B-tree, and immutability makes it
   sufficient.** Milvus's STL_SORT index and sealed PK map are just
   `sort` + `lower_bound` (`SortedIndexBuilder.cpp:322`,
   `InsertRecord.h:726-730`). The B-tree exists to make that structure
   *updatable* without `O(n)` shifts. If you never update, you do not need
   the tree.

2. **Mutable → pointer tree, immutable → flat array; a B-tree is the
   hybrid.** Growing segments use `std::map`, sealed ones a sorted vector
   (`InsertRecord.h:1467` vs `:1142`). A B-tree node is a small sorted array
   (cache-friendly, binary/SIMD searchable); the tree part exists only to
   bound the cost of change.

3. **An internal node is a summary of its children; ordering is what makes
   the summary navigable.** Zone maps (`SkipIndexStats.h:170-187`) and
   per-segment PK min/max + bloom (`pk_statistics.go:85-110`) are the same
   summaries without ordering/disjointness, so every summary must be
   tested. B-tree separators are min/max summaries you can binary-search.

4. **B-trees need a total order that preserves nearness; vectors have
   none.** IVF keeps the "partition into buckets" half of a B-tree but must
   *search* for the bucket and probe several (`IndexIVF.cpp:916`,
   `nprobe`); HNSW keeps the "sparse upper levels" half of a skip list but
   must navigate greedily and accept approximate answers
   (`HNSW.cpp:1779-1783`).

5. **Layout beats asymptotics inside a block.** Contiguous arrays, 32-bit
   ids, struct-of-arrays, SIMD-width padding and alignment recur everywhere
   (`distances_avx2.cpp:151-161`, `IndexFastScan.h:21-26`,
   `IVFBase.cuh:247-255`, `HNSW.h:123-129`). The same techniques apply to
   B-tree node design.

6. **Duplicates: `(key, rid)` entries vs `key → posting list/bitmap`.**
   Cardinality decides which is better, and Milvus encodes the rule in code
   (`HybridIndexBuilder.cpp:531-535`).

7. **Prefix query = range query.** `[p, successor(p))` appears in the
   sorted index (`SortedIndexReader.cpp:364-379`), in the B-tree-backed
   `MemoryKV` (`mem_kv.go:297-307`) and in the etcd client call
   (`etcd_kv.go:95`).

8. **Write-path choice: in place (B-tree) vs immutable runs + tombstones +
   compaction (LSM-like).** Milvus chooses the latter because its indexes
   are build-once (`data_coord.proto:27-32`, `entity_filter.go:89-101`), and
   pays with bloom-filter fan-out on reads (`bloom_filter_set.go:58-72`).

9. **Fixed-size pages are a feature.** `OnDiskInvertedLists` shows the cost
   of variable-size on-disk regions: slot allocator, relocation, and an
   explicit warning that adds are slow (`OnDiskInvertedLists.h:42-54`).

10. **Even a vector database uses a real B-tree where data is small,
    ordered and mutable** — `google/btree` for an in-memory KV and a pending
    task queue (`mem_kv.go:41`, `schema.go:59`), and a B+tree/LSM store for
    metadata.

---

## 21. Things that are easy to get wrong

- **"Milvus uses B-trees for scalar indexes."** It does not. Scalar index
  families are sorted array, bitmap (`std::map` + Roaring), Tantivy
  inverted, Marisa trie, n-gram, FM-index, R-tree
  (`internal/core/src/index/scalar/`). The only B-trees are two in-memory
  `google/btree` uses in Go.
- **"etcd is in the repo, so bbolt's B+tree is too."** Only the dependency
  line is (`go.mod:272`, indirect). Do not cite Milvus for bbolt internals.
- **Calling Milvus "an LSM-tree".** It is LSM-*like*. L0/L1/L2 are not
  sorted key levels: L0 holds delete deltas, L2 marks clustered segments
  (`data_coord.proto:27-32`). There is no global key order across segments.
- **Calling IVF "an inverted index" in the text-search sense.** Same
  shape (key → posting list), but the key is a learned centroid id and
  lookup is a nearest-centroid search, not a dictionary lookup.
- **Treating IVF as a tree with exact routing.** Default `nprobe` is 1
  (`IndexIVF.h:97`), which is the "one child per level" B-tree behaviour —
  and precisely the setting with the worst recall.
- **"HNSW is a tree" / "HNSW is a skip list".** It is a graph with cycles
  and no key order. The skip-list analogy covers only the random level
  assignment and coarse-to-fine descent. Level numbering also differs:
  `levels[i]` uses "base level = 1" (`HNSW.h:120`) while search loops
  address layers from 0 (`HNSW.cpp:1779`).
- **Assuming HNSW's level probability is 1/2 like a classic skip list.**
  It is governed by `levelMult = 1/log(M)` (`HNSW.cpp:63`), i.e. roughly a
  1/M chance of promotion per level.
- **Thinking HNSW in FAISS is pointer-based.** It is two flat arrays with
  offset arithmetic (`HNSW.h:123-129`, `HNSW.cpp:57-59`).
- **Assuming tries are good at range queries.** Milvus's Marisa range
  enumerates keys and compares each (`MarisaIndexReader.cpp:358-389`),
  with early exit only for `<`/`<=` in label order.
- **Forgetting the inclusive/exclusive matrix.** Both the sorted index
  (`SortedIndexReader.cpp:637-642`) and the skip index
  (`SkipIndexStats.h:177-185`) spell out all four cases. Mapping:
  `>= lo` → `lower_bound(lo)`, `> lo` → `upper_bound(lo)`,
  `<= hi` → `upper_bound(hi)`, `< hi` → `lower_bound(hi)`.
- **Comparing by subtraction** (`a - b < 0`) in a binary search — the
  galloping code explicitly warns against it for signed extremes and
  infinities (`SortedMembership.h:53-54`).
- **Believing bloom filters or min/max can replace an index.** They only
  say "definitely not here"; a positive still needs a real lookup, and the
  cost is linear in the number of segments/chunks. `PkExist` even returns
  `true` for unknown key types as a deliberate false positive
  (`pk_statistics.go:108-109`).
- **Reading `std::map` as "B-tree".** It is a node-per-key pointer tree;
  Milvus uses it where the key count is small (bitmap dictionary) or data
  is still mutable (growing PK map), and switches to arrays when sealed.
- **Assuming mmap gives durability or cheap updates.**
  `OnDiskInvertedLists` is mmapped yet documents that additions are slow
  and recommends offline build + merge (`OnDiskInvertedLists.h:52-54`).
- **Quoting the big-O for IVF/HNSW as guarantees.** They are approximate
  indexes; costs in the table are typical/expected and depend on `nprobe`,
  `efSearch` and data distribution. B-tree bounds are worst-case and exact.
- **Line numbers.** All references are to the commits named at the top;
  both repositories move quickly (Milvus's scalar index directory was
  recently reorganised into Builder/Artifact/Loader/Reader families, see
  `internal/core/src/index/scalar/README.md`).
