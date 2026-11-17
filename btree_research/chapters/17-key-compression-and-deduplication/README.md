# 17. Key compression and deduplication

Previous: [16 bulk-loading](../16-bulk-loading/README.md) ·
Next: [18 indexes-in-a-database](../18-indexes-in-a-database/README.md) ·
Visualization: [viz/index.html](viz/index.html)

## What you will learn

- Why a separator in an internal page does not have to be a key that exists, and how to
  build the shortest one that still works (suffix truncation).
- How a search stays correct when separators are shorter than the keys it is looking for.
- What fence keys are and what they buy.
- Why real indexes append the row address (heap TID) to every key, and how that makes
  duplicates well ordered.
- How equal keys are folded into posting lists, and what that does to the size of the tree.
- Measured, on the same data: fanout, height and bytes per entry with and without each
  technique.

Prerequisites: B+trees (chapter 07), slotted pages and byte-based fullness (10, 12), split
points (14). The code here is self-contained.

Scope: prefix compression (storing a prefix shared by all keys of a page once) is textbook
material here. None of the six codebases does it in a B-tree; neither does this code.

## The idea in plain words

### Separators are not keys

In a B+tree all data is in the leaves. An internal page only answers one question: "which
child?". When a leaf splits between `blackberry` and `blueberry`, the parent needs something
that sends `blackberry` and everything before it left, and `blueberry` and everything after
it right. `blueberry` would do. So would `blu`, or `bm`, or anything in between. The shortest
byte string `S` with

    last key on the left  <  S  <=  first key on the right

is the common prefix of the two keys plus one more byte of the right key: `blu`. This is
*suffix truncation*: keep the first bytes of the right key, cut the rest. Shorter separators
mean more of them fit in an internal page, so the fanout rises and the tree gets shallower.

Truncated bytes are not gone, they have a defined value: minus infinity. `blu` means
"`blu` followed by the smallest possible rest". With byte strings and lexicographic order
that needs no special code: a string that is a prefix of another already sorts before it.

### The row address is part of the key

A secondary index maps a key to the address of a table row. Postgres calls that address a
TID (block number and slot, 6 bytes). If two rows have the key `apple`, the index holds two
entries. Which one is first? If the answer is "any order", a split in the middle of a run of
equal keys has no usable separator, and deleting the entry of one particular row means
scanning the whole run.

The fix is to treat the TID as the last column of the key. The tuple is `(key, tid)`, every
tuple is unique, and a run of duplicates is simply sorted by TID. A separator may then need
a TID as well: between `(cherry, 12)` and `(cherry, 17)` no byte of the key differs, so
nothing can be truncated and the separator is `(cherry, 12)`. A truncated TID is, again,
minus infinity.

This chapter uses one comparison everywhere, `compareTuple`: key bytes first, then TID,
with a missing TID below every real one. One routing rule follows from it and holds for
every page:

    low fence  <  every tuple on the page  <=  high fence

### Fence keys

The two bounds in that rule are stored on the page itself: copies of the separators that
bracket the page in its parent. They are called fence keys. The low fence of the leftmost
page is minus infinity and the high fence of the rightmost page is plus infinity; neither
takes space.

Fences make a page self-describing. `validate` checks that every tuple of a page lies
between its fences and that the fences equal the parent's separators. A search that lands
on a page can tell from the high fence alone whether it is on the right page (chapter 20
builds concurrency on that test). Fences cost space on every page, one more reason to
truncate: a fence is as short as the separator it copies.

Postgres stores only the upper one and calls it the high key. Storing both, as here, is the
textbook form (Graefe's "fence keys"; unverified against any of the six codebases).

### Posting lists

With `(key, tid)` tuples, a thousand rows with the key `apple` store the bytes `apple` a
thousand times. A *posting list* stores the key once, followed by the sorted TIDs:

    apple@2  apple@4  apple@7        three cells, 45 bytes
    apple@[2,4,7]                    one cell,   29 bytes

The logical content is the same, only the representation changes. The cost is a more
complicated insert: a new TID may fall *inside* the range of an existing list.

Deduplication is done lazily, as in Postgres: only when a leaf is full and would otherwise
split. A split is permanent in a tree that never merges pages; a posting list is free.

## A worked example by hand

Sizes used below (and by the programs): page header 8 bytes; each cell has a 2-byte slot
and a 2-byte length; a TID is 6 bytes; a child page id is 4 bytes; a posting list has a
2-byte count. So a plain leaf cell costs `10 + len(key)` and a posting list with n TIDs
costs `6 + len(key) + 6n`.

**Truncation.** A full leaf holds, in order,

    apricot@18  avocado@32  banana@11  blackberry@3 | blueberry@6  cherry@1  cherry@8 ...

Cutting at `|`: the common prefix of `blackberry` and `blueberry` is `bl` (2 bytes), so the
separator is the first 3 bytes of `blueberry`: `blu`, with no TID. As a pivot in the parent
it costs 2 + 2 + 3 + 4 = 11 bytes. Without truncation the separator is the whole last-left
tuple, `"blackberry"@3`: 2 + 2 + 10 + 6 + 4 = 24 bytes.

Cutting one position earlier (`banana` | `blackberry`) gives `bl`; one later (`blueberry` |
`cherry`) gives `c`. The cut decides the separator length, so the split code looks at
several cuts near the middle and prefers the shortest separator.

**Routing.** The parent now contains `... "blu" ...`. Look up `blackberry`: the search tuple
is `(blackberry, 0)`. Compare the key bytes with `blu`: `bla < blu`, so the tuple is below
the separator and goes left. Look up `blueberry`: `blu` is a prefix of `blueberry`, a prefix
sorts first, so the separator is below the tuple and the search goes right. Look up `blu`
itself (not in the index): the key bytes are equal, the separator has no TID, the search
tuple has TID 0, minus infinity is below 0, so it goes right, where `blu` would be if it
existed.

**Equal keys.** A page holds only `cherry` tuples and splits between `cherry@12` and
`cherry@17`. The keys are equal, so the separator is `"cherry"@12`. A later lookup of
`cherry` searches for `(cherry, 0)`, which is below `(cherry, 12)`: it starts in the left
page and walks right along the leaf chain until the key changes.

**Deduplication.** A 256-byte leaf holds `apple@2 apple@4 apple@7 apple@10 apple@13` and
other cells, and is full. Five plain cells cost 5 × 15 = 75 bytes. One posting list
`apple@[2,4,7,10,13]` costs 6 + 5 + 30 = 41 bytes. The pass frees 34 bytes and the insert
goes ahead without a split.

**A TID inside a posting list.** The leaf holds `cherry@[1,8,12,17]` and `(cherry, 9)`
arrives. It belongs between 8 and 12. Growing the list would change its size; instead 9
takes its place in the list and the list's largest TID is pushed out: `cherry@[1,8,9,12]`
followed by a new plain cell `cherry@17`. Whatever the case, an insert adds exactly one
plain cell to the page.

## Code walk-through

Layout (Zig; Rust has the same files with `.rs`):

| File | Content |
|------|---------|
| `src/tree.zig` | the page model, `put`, `get`, `range`, `delete`, `validate`, `stats` |
| `src/demo.zig` | the fixed scenario and the measurements printed by `run` |
| `src/tests.zig` | unit tests, model test against an oracle, allocation-failure tests |
| `src/prng.zig` | copied from `common/` |

### Zig

`compareTuple(a_key, a_tid, b_key, b_tid)` is the total order. `std.mem.order` already puts
a prefix first; a `null` TID is handled in two lines.

`separator(truncate, last_left, first_right)` is the heart of the chapter:

```zig
if (truncate) {
    const n = commonPrefixLen(last_left.key, first_right.key);
    if (n < first_right.key.len) return .{ .key = first_right.key[0 .. n + 1], .tid = null };
}
return .{ .key = last_left.key, .tid = last_left.tids[last_left.tids.len - 1] };
```

If the keys differ, byte `n` of the right key is either where they differ or lies beyond the
end of the left key; in both cases the `n + 1` byte prefix is above the left key. If the
keys are equal, `n` equals the key length and the function falls through to the full
last-left tuple, TID included. With `truncate = false` it always returns the full last-left
tuple, which is the choice of Lehman and Yao and the baseline for the measurements.

A `Page` has an arena, two optional fences, a right link and either a list of
`LeafCell { key, tids }` or lists of separators and children. `usedBytes` adds up what the
cells would cost in a slotted page.

Search: `childIndex` returns the number of separators strictly below the tuple, by binary
search. It does not know whether separators are truncated. `range(lo, hi)` descends with
`(lo, 0)` and iterates along the leaf chain; `get(key)` collects TIDs while the key matches.

`put(key, tid)`:

1. `findLeaf` descends and records the path. `locate` finds the tuple's slot in the leaf:
   `found`, `insert_at` (a new plain cell) or `inside` (within a posting list's TID range).
2. Fast path: if one more plain cell fits, allocate its bytes in the page's arena and
   insert. For `inside`, `swapIntoPosting` first exchanges the new TID for the list's
   largest one.
3. Slow path (`putSlow`): flatten the page's cells plus the new one into scratch memory.
   If deduplication is on, `dedupPass` merges neighbouring cells with equal keys up to the
   posting size limit. If the result fits, the page is rebuilt and the put is done.
4. Otherwise `chooseLeafSplit` picks the cut: among cuts that leave both halves between 40%
   and 60% of the bytes, the one with the shortest separator. Two new leaves are built; the
   separator becomes the high fence of the left one, the low fence of the right one, and a
   pivot in the parent.
5. If the parent overflows, it splits too. The separator that moves up is **not** truncated
   again: it must remain byte-identical to the fences below it, or `validate`'s fence check
   (and any search relying on the fences) would break.

All new pages are collected in a `Txn` and installed together by `commit`, so a put either
happens completely or not at all.

`delete(key, tid)` removes one TID from its cell and never merges pages (chapters 15 and 24
discuss why real engines often do not either).

`validate` walks the tree with the expected fences of each page and checks fences, tuple
order, posting lists, size limits, leaf depth, the leaf chain and the entry count.

**Why one sixth.** No cell may exceed one sixth of the usable page, and keys are limited so
that a pivot *with* a TID still fits in that (`maxKeyLen`). Then an overflowing page holds at
most 7/6 of a page in cells, the larger half of the most balanced cut holds at most
7/12 + 1/12 = 2/3, and two fences add at most 1/3: both halves always fit. Posting lists
obey the same limit, so a long run of duplicates becomes several lists.

### Rust

Same structure, names and tests (`snake_case`). The differences:

- A `Page` owns `Vec`s; each key is its own `Vec<u8>`. There are no arenas: replacing a
  page is `self.pages[id] = new_page`, and the old value is dropped as a whole. That is the
  "drop the `Vec`" idiom standing in for a per-page arena.
- No scratch allocator: `put_slow` clones the cell list into a local `Vec`.
- `separator` returns borrowed parts `(&[u8], Option<Tid>)`, so the split-point search does
  not allocate; `Sep` is the owned form.
- `Option<Tid>` already orders `None` before `Some(_)`, so `compare_tuple` is one line.
- Allocation failure is mirrored by a page budget (`max_pages`): a put that needs more
  pages returns `Err(Error::OutOfPages)`. The pending pages and the pending parent insert
  are applied only after the budget check, so the tree is unchanged on error.
- Zig tracks bytes made unreachable by deletes and rebuilds the leaf (see Allocator notes).
  Rust frees each `Vec` when it is removed and needs nothing of the kind.

### Output

Both programs print `expected_output.txt`; a test in each language checks it. The fixed
scenario (39 puts into 256-byte pages, truncation and deduplication on) ends as:

```
page 2 internal low=-inf high=+inf used=46/256
  separators: "apr" "c" "cr"
  page 0 leaf low=-inf high="apr" used=150/256
    apple@1 apple@[2,4,7,10,13] apple@15 apple@[16,19,22,25,28] apple@[31,35]
  page 4 leaf low="apr" high="c" used=131/256
    apricot@18 avocado@32 banana@11 blackberry@3 blackcurrant@29 blueberry@6
  page 1 leaf low="c" high="cr" used=148/256
    cherry@[1,8,9,12] cherry@17 cherry@[21,24,27,30] cherry@[33,36] coconut@37
  page 3 leaf low="cr" high=+inf used=130/256
    cranberry@20 date@23 elderberry@14 fig@5 grape@9 grapefruit@26 guava@34
```

and the measurements with 4096-byte pages are:

```
A. 20000 unique 32-byte keys (hex hashes), random order
  config            height  leaves  internal  fanout  sep bytes  bytes/entry  leaf splits  dedup passes
  neither                3     302         5    61.2       38.0         44.1          301             0
  truncate               2     300         1   300.0        2.4         42.5          299             0
B. 20000 rows over 50 distinct keys ("category-NN")
  neither                3     183         3    61.7       17.0         21.7          182             0
  truncate               3     187         3    63.0       15.9         21.7          186             0
  dedup                  2      45         1    45.0       17.0          7.3           44           706
  truncate + dedup       2      50         1    50.0       11.9          7.9           49           727
C. 20000 hierarchical keys ("user/NNNNNN/order/NNNNNN"), random order
  neither                3     248         5    50.4       30.0         35.4          247             0
  truncate               3     234         3    78.7       10.3         34.6          233             0
```

(repeated headers and the rows where deduplication changes nothing are omitted here). How to
read it:

- **A.** Random 32-byte keys differ in their first bytes. Separators shrink from 38 bytes
  (32 of key plus a 6-byte TID) to 2.4 on average, all 300 children fit in one root, and the
  tree loses a level. Leaves barely change: truncation does not touch them, apart from
  shorter fences. Deduplication has nothing to merge.
- **B.** With 400 rows per key, truncation has almost nothing to cut (most splits fall
  inside a run of equal keys and need the TID). Deduplication cuts the leaf count to a
  quarter and the bytes per entry from 21.7 to 7.3; a bare TID is 6. With both on, the
  separators that do fall between different keys get shorter (17.0 to 11.9 bytes on
  average) but the leaf count is 50 instead of 45: the split-point rule gives up a little
  balance for a shorter separator, and shorter fences shift which page splits when. With
  only 45 to 50 leaves, each holding a few large posting lists, that difference is small
  change (exercise 4 separates the two effects).
- **C.** Hierarchical keys share long prefixes. Truncation still cuts the suffix
  (`/order/NNNNNN`), but every separator keeps `user/00...`: 10.3 bytes where A needs 2.4.
  Removing a shared *prefix* is a different technique.

### Prefix compression (textbook, not implemented)

If every key of a page starts with `user/0012`, those bytes can be stored once in the page
header and stripped from every cell. With fence keys the shared prefix is known without
looking at the cells: it is the common prefix of the low and high fence, because every key
of the page lies between them. This is the "prefix B-tree" of Bayer and Unterauer; what this
chapter implements is their simpler variant, the "simple prefix B-tree", which only
shortens separators.

## In real databases

**Postgres (nbtree), commit `11591f2`.**

- Heap TID as the last key column since index version 4, so that all keys are unique:
  `src/backend/access/nbtree/README:42-49`; TID comparison in `_bt_compare`,
  `nbtsearch.c:797-857`.
- Suffix truncation: `_bt_truncate`, `nbtutils.c:692` onwards; called for leaf splits at
  `nbtinsert.c:1657-1682`. Prose in `README:823-902`. Postgres truncates whole columns
  only, not bytes inside a string; the README says byte-level truncation "would be
  straightforward" to add through operator class support (`README:851-856`). This chapter's
  keys are single byte strings, so byte-level truncation is the only kind there is. It is
  the textbook form, not what Postgres does to a `text` column.
- Equal keys: when nothing can be truncated, the pivot gets the last-left tuple's TID
  (`nbtutils.c:771-778`), as here. The key size limit reserves room for that TID:
  `BTMaxItemSize`, `src/include/access/nbtree.h:165-173`.
- No truncation in internal splits, and the reason (an unbroken "seam" of identical
  separators at every level): `nbtinsert.c:1683-1699`.
- A search key without a TID compared with a pivot whose TID was truncated is treated as
  greater, so the search does not visit the left page for nothing: `nbtsearch.c:812-830`.
  Seeking with TID 0 in this chapter has the same effect.
- The split point is chosen to make truncation effective: among acceptably balanced
  candidates, the penalty of a leaf split is the number of columns the separator must keep
  (`_bt_split_penalty`, `nbtsplitloc.c:1132`; chapter 14).
- High key: `nbtree.h:349-366`. Postgres has no low fence.
- Deduplication: `_bt_dedup_pass`, `nbtdedup.c:59`; lazy, as the last defence before a leaf
  split (`README:904-948`, `_bt_delete_or_dedup_one_page`, `nbtinsert.c:2728`). A posting
  list is limited to `BTMaxItemSize / 2`, about one sixth of a page (`nbtdedup.c:80-89`).
  TIDs are stored uncompressed on purpose (`README:931-942`).
- Posting list split (the swap): `_bt_swap_posting`, `nbtdedup.c:1022`; the reasoning is in
  `README:990-1042`.
- Not modelled here: deduplication is only allowed when equal keys are byte-identical
  (`_bt_allequalimage`, `nbtutils.c:1175`), dead-tuple removal runs first, and unique
  indexes use deduplication differently (`README:950-988`).

**DuckDB, as a contrast.** DuckDB has no B-tree. Its ART index compresses *paths* instead of
separators: a run of key bytes with no branching is stored in a `PREFIX` node
(`src/include/duckdb/execution/index/art/prefix.hpp:18-29`,
`src/execution/index/art/prefix.cpp:57-69`). Both techniques exploit shared prefixes; the
B-tree shortens what it stores in internal pages, the radix tree skips levels. Chapter 28
covers ART.

**Turso, TigerBeetle, Milvus, FAISS.** Nothing found in the research notes on separator
truncation or posting lists in a B-tree for these; not claimed.

## Allocator notes

Two allocators carry this chapter in Zig.

**One `ArenaAllocator` per page** owns every byte the page refers to: fence keys, cell keys,
TID arrays and the cell lists themselves. A split or a deduplication pass never edits a page
in place. It builds the replacement in a new arena (`buildLeaf`, `buildInternal`) and
`commit` drops the old arena in one call. That makes failure handling trivial: an aborted put deinitialises the arenas of its pending pages and the tree
has not been touched. With a general-purpose allocator the same code would need one `free`
per key and per TID array and an `errdefer` for each.

The price: an arena cannot free a single cell. A delete leaves the key bytes unreachable
inside the arena. The page counts them in `dead_bytes` and, once they exceed a page size,
rebuilds itself into a new arena. This is compaction of a slotted page (chapter 10) under
another name. The test "deletes do not grow a leaf's arena without bound" covers it.

**A `FixedBufferAllocator` for scratch.** The slow path needs temporary lists: the page's
cells plus the new one, the deduplicated list, merged TID arrays, and one internal page's
separators per level. All of it is bounded by the page size, so `Tree.init` allocates
`16 × page_size` bytes once and every `putSlow` resets a `FixedBufferAllocator` over it. No
allocator call can fail in the middle for lack of system memory, and nothing has to be
freed. The buffer is a stack: the loop over internal levels saves `end_index`, uses the
space, and restores it. A general-purpose allocator here would add a dozen fallible, individually freed
allocations to the most delicate code path.

Lifetimes: scratch memory lives for one put; a page arena until the page is next rebuilt.

Failure tests: `checkAllAllocationFailures` fails every allocation of a 70-put build in turn
and checks for leaks; a second test fails the 1st, 2nd, 3rd ... allocation of each put
until it succeeds and checks after each failure that `validate` passes and `stats` are
unchanged.

## Pitfalls

- **Truncating in internal splits.** A separator that moves up must stay identical to the
  fences below it. Truncate only when a *leaf* splits.
- **Comparing a truncated separator with `<=` on the key alone.** The lookup key `c` and the
  separator `c` have equal bytes, but the tuples `(c, anything)` live to the right. The TID
  (minus infinity in the separator) decides.
- **Using the first-right key in full as the separator** while routing `<=` left: the first
  tuple of the right page would be searched for in the left page. Either truncate (the
  result is strictly below first-right) or use last-left.
- **Forgetting room for the TID in the key size limit.** A split between equal keys makes
  the separator longer than a truncated one, not shorter.
- **Growing a posting list in place.** The page-space arithmetic of the caller assumes one
  plain cell per insert; the swap keeps that true.
- **Byte order must be key order.** Truncating bytes is only valid if comparing bytes is
  comparing keys (chapter 11). With a comparator that is not bytewise (case-insensitive
  collations, for example) a byte prefix may not be a valid separator.

## Exercises

1. (easy) By hand, give the truncated separator for a split between: `fig@5` and
   `grape@9`; `grape@9` and `grapefruit@26`; `date@3` and `date@8`; `a@1` and `b@1`.
   State the pivot size in bytes for each.
2. (easy) The parent holds the separators `"apr"`, `"c"`, `"cr"`. Which child (0 to 3) does
   a lookup of `apple`, `apr`, `apricot`, `c`, `coconut`, `cr` and `zebra` follow?
3. (medium) `separator` returns the shortest *prefix of the right key*. For `banana` and
   `cherry` it returns `c`. Is there a shorter valid separator? When the two keys first
   differ at byte n, can a valid separator be shorter than n + 1 bytes? Prove your answer.
4. (medium) Change `chooseLeafSplit` to ignore separator length (always the most balanced
   legal cut) and rerun workload B with truncation and deduplication. Explain the change
   in "leaves" and "sep bytes".
5. (hard) Implement prefix compression for leaves: compute the common prefix of a page's
   two fences, charge it once, and charge each cell only for the rest of its key. Which
   pages cannot benefit, and why does the model need fences for this? Measure workload C.

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [16 bulk-loading](../16-bulk-loading/README.md)
- Next: [18 indexes-in-a-database](../18-indexes-in-a-database/README.md)
- Visualization: [viz/index.html](viz/index.html) (separator shrinking at a split; duplicates
  collapsing into a posting list)
- Run: `cd zig && zig build test && zig build run`, `cd rust && cargo test && cargo run`
