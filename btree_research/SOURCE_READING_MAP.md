# Source reading map

What to read in the six codebases under `db_study/`, in which order, and which chapter
prepares you for each file. Paths are relative to the checkout named in the section
heading. Line numbers were checked against the pinned commits below; `:N` is where a
function or definition starts, `:A-B` is a range to read. Chapter links are written
`ch NN` and resolve to `chapters/NN-slug/README.md`; the [glossary](GLOSSARY.md) has the
vocabulary.

| Checkout | Commit | Has a B-tree? |
|---|---|---|
| `postgres` | `11591f2` | Yes: `nbtree`, on disk, concurrent (B-link) |
| `turso` | `469c4f4` | Yes: SQLite-format B-trees, on disk, single writer |
| `milvus` | `0d3e77c` | Two small in-memory uses of `google/btree`; nothing on disk |
| `duckdb` | `9d8ecca6` | No (ART index, zone maps) |
| `tigerbeetle` | `a2a3c70` | No (LSM forest) |
| `faiss` | `c8f2838` | No (IVF, HNSW) |

If you have time for only two, read Postgres for concurrency and Turso for the page
format.

---

## 1. Postgres (`postgres`, commit `11591f2`)

Postgres's default index, `nbtree`, is a real on-disk B+tree and the main reference of the
guide. It is Lehman and Yao's B-link tree: every page has a high key and a right link, a
split is two separate atomic actions, and a search holds one page lock at a time and moves
right when a page was split under it. Rows live in a separate heap; an index tuple is
(key, heap TID) and the TID is part of the key. It never merges non-empty pages, chooses
split points with care, truncates separators, deduplicates into posting lists, and logs
every structural step as its own WAL record. All nbtree files are in
`src/backend/access/nbtree/` (abbreviated `N/` below).

### Reading order

1. **`N/README`** (1083 lines). Read this before any code; it is the design document.
   - `:14-56` the basic Lehman and Yao algorithm: right links, high keys, moving right.
     Prepared by ch 19, ch 20.
   - `:57-165` differences from the paper: read locks, scans, the stack as a hint,
     variable-size keys. ch 08, ch 20.
   - `:232-329` deleting whole pages in two stages and why a deleted page cannot be
     recycled at once; `:383` placing deleted pages in the FSM. ch 13, ch 24.
   - `:491` fastpath for rightmost insertion; `:510` simple deletion; `:556` bottom-up
     deletion. ch 15, ch 24.
   - `:620-701` WAL considerations (a split is two records; incomplete splits). ch 22.
   - `:823` suffix truncation; `:904` deduplication; `:990` posting list splits. ch 17.
2. **`src/include/storage/bufpage.h`** and **`src/include/storage/itemid.h`**. The generic
   slotted page under every index.
   - `bufpage.h:31-43` the page diagram; `:184-197` `PageHeaderData` with `pd_lower`,
     `pd_upper`, `pd_special` (`:191-193`); `:269` `PageGetItemId`; `:397`
     `PageGetMaxOffsetNumber`.
   - `itemid.h:25` `ItemIdData`, the 4-byte line pointer (the guide's slot).
   - `src/include/storage/itemptr.h:36` `ItemPointerData`, the 6-byte TID.
   - `src/backend/storage/page/bufpage.c:42` `PageInit`, `:205` `PageAddItemExtended`,
     `:1063` `PageIndexTupleDelete`, `:1172` `PageIndexMultiDelete`. ch 09, ch 10.
3. **`src/include/access/nbtree.h`** (1334 lines). The data structures.
   - `:63-70` `BTPageOpaqueData` (left and right links, level, flags) kept in the special
     space; `:77-84` flag bits including `BTP_HALF_DEAD` (`:81`) and
     `BTP_INCOMPLETE_SPLIT` (`:84`). ch 10, ch 20.
   - `:104` `BTMetaPageData` (root, fast root, level); `:149` `BTREE_METAPAGE`. ch 12.
   - `:165` `BTMaxItemSize`, the one-third-of-a-page limit. ch 12, ch 13.
   - `:201-203` the three fill factors (90 leaf, 70 non-leaf, 96 single value). ch 14, ch 16.
   - `:292` `BTPageIsRecyclable`. ch 13, ch 24.
   - `:350-370` the high key comment and `P_HIKEY`, `P_FIRSTKEY`, `P_FIRSTDATAKEY`. ch 20.
   - `:372` onward "Notes on B-Tree tuple format"; `:481` `BTreeTupleIsPivot`, `:493`
     `BTreeTupleIsPosting`, `:639` `BTreeTupleGetHeapTID`. ch 17.
   - `:743` `BTStackData` (the descent stack), `:795` `BTScanInsertData` (the insertion
     scan key), `:876` `BTDedupStateData`. ch 04, ch 11, ch 17.
4. **`N/nbtsearch.c`** (2284 lines). Descent and scans.
   - `:102` `_bt_search`: the loop down the tree; one lock at a time. ch 03, ch 20.
   - `:244` `_bt_moveright`: compare with the high key, follow the right link, finish an
     incomplete split if met. ch 20.
   - `:346` `_bt_binsrch` and `:477` `_bt_binsrch_insert`: binary search over line
     pointers; `:691` `_bt_compare`: scan key against a tuple, with minus infinity and
     truncated attributes. ch 02, ch 11, ch 17.
   - `:885` `_bt_first` (seek for a scan), `:1593` `_bt_next`, `:1654` `_bt_steppage`,
     `:1847` `_bt_readnextpage`: page-at-a-time scans along the leaf links. ch 08.
5. **`N/nbtinsert.c`** (3060 lines). The insert path; chapter 30 traces it end to end.
   - `:105` `_bt_doinsert`: the top level. `:320` `_bt_search_insert` (rightmost-leaf
     fastpath, then `_bt_search`). ch 30.
   - `:411` `_bt_check_unique`: uniqueness under the leaf's write lock. ch 18.
   - `:827` `_bt_findinsertloc`; `:2728` `_bt_delete_or_dedup_one_page` (free space on
     the page before splitting). ch 17, ch 24.
   - `:1117` `_bt_insertonpg`: insert in a critical section (`:1295-1419`, WAL record at
     `:1407`) or call the split.
   - `:1487` `_bt_split`: asks `_bt_findsplitloc` (`:1565`), sets
     `BTP_INCOMPLETE_SPLIT` on the left half (`:1580`), truncates the new high key
     (`:1680`), allocates the right page (`:1739`), then one critical section
     (`:1950-2093`) with one WAL record (`:2081`). The left half keeps its block. ch 04,
     ch 14, ch 20, ch 22.
   - `:2128` `_bt_insert_parent`: the second atomic action; `:2349` `_bt_getstackbuf`
     re-finds the parent; `:2270` `_bt_finish_split`; `:2490` `_bt_newlevel` builds a new
     root. ch 20.
6. **`N/nbtsplitloc.c`** (1185 lines). Where to cut a full page.
   - `:20-26` the three strategies (`SPLIT_DEFAULT`, `SPLIT_MANY_DUPLICATES`,
     `SPLIT_SINGLE_VALUE`).
   - `:130` `_bt_findsplitloc`: builds the candidate list over the imaginary page;
     rightmost-page fill factor at `:284-287`.
   - `:450` `_bt_recsplitloc` (record one legal candidate), `:631`
     `_bt_afternewitemoff` (append-like patterns in the middle of the tree), `:789`
     `_bt_bestsplitloc`, `:935` `_bt_strategy`, `:1132` `_bt_split_penalty`. ch 14, ch 17.
7. **`N/nbtutils.c`** (1218 lines).
   - `:61` `_bt_mkscankey` builds the insertion scan key. ch 11.
   - `:692` `_bt_truncate` and `:837` `_bt_keep_natts`: suffix truncation of a new high
     key or pivot; `:1118` `_bt_check_third_page`: the size limit error. ch 17.
   - `:191` `_bt_killitems`: setting `LP_DEAD` hints after a scan. ch 24.
8. **`N/nbtdedup.c`** (1105 lines).
   - `:59` `_bt_dedup_pass`: merge equal keys of a full leaf into posting lists; `:435`,
     `:486`, `:557` the pending-list helpers; `:864` `_bt_form_posting`; `:1022`
     `_bt_swap_posting` (a TID that falls inside an existing list). ch 17.
   - `:309` `_bt_bottomupdel_pass`: bottom-up deletion. ch 24.
9. **`N/nbtpage.c`** (3138 lines). Page allocation, the metapage, page deletion.
   - `:68` `_bt_initmetapage`, `:347` `_bt_getroot` (uses the fast root), `:585`
     `_bt_gettrueroot`. ch 12.
   - `:854` `_bt_allocbuf`: take a recyclable page from the FSM or extend the file. ch 13.
   - `:1162` `_bt_delitems_vacuum`, `:1293` `_bt_delitems_delete`. ch 24.
   - `:1812` `_bt_pagedel`, `:2101` `_bt_mark_page_halfdead` (stage 1), `:2328`
     `_bt_unlink_halfdead_page` (stage 2). ch 24.
   - VACUUM's driver is in `N/nbtree.c`: `:1153` `btbulkdelete`, `:1271`
     `btvacuumscan`, `:1446` `btvacuumpage`.
10. **`N/nbtsort.c`** (1971 lines). Bulk loading for `CREATE INDEX`.
    - `:1-25` the header comment; `:299` `btbuild`; `:1139` `_bt_load` (the loop over
      sorted tuples); `:789` `_bt_buildadd` (add to the open page of a level, finish it
      and hand a downlink up); `:652` `_bt_pagestate` with the per-level fill target
      (`:669-671`); `:1067` `_bt_uppershutdown` (finish every level, write the metapage).
      ch 16.
11. **`N/nbtxlog.c`** (1117 lines). Redo, one function per record type.
    - `:1004` `btree_redo` (the dispatch); `:158` `btree_xlog_insert`; `:247`
      `btree_xlog_split`; `:137` `_bt_clear_incomplete_split`; `:927`
      `btree_xlog_newroot`; `:705` `btree_xlog_mark_page_halfdead`; `:789`
      `btree_xlog_unlink_page`; `:454` `btree_xlog_dedup`. Record layouts are in
      `src/include/access/nbtxlog.h` (`:153` `xl_btree_split`). ch 21, ch 22.

---

## 2. Turso (`turso`, commit `469c4f4`)

Turso is a Rust rewrite of SQLite that reads and writes the SQLite file format. It has
real on-disk B-trees of two kinds in one file: a table is a B+tree keyed by a 64-bit
rowid with rows in the leaves, and an index is a classic B-tree whose interior cells also
carry keys. Pages are slotted pages with 2-byte cell pointers; there are no sibling links,
so cursors keep a page stack. One writer at a time, so there are no latches in the tree.
Overflow and underflow are both repaired by one `balance` routine over up to three
siblings. Durability is a WAL of whole-page frames. The code is written as explicit
state machines because any page read may have to yield. `btree.rs` is 16,279 lines, so it
is listed by region.

### Reading order

1. **`core/storage/sqlite3_ondisk.rs`** (2749 lines). The file format.
   - `:1-42` module comment with the page and WAL diagrams. ch 09, ch 10.
   - `:82-97` layout constants: cell pointer size (`:84`), page header sizes
     (`:85-86`), freelist trunk layout (`:93-97`). ch 10, ch 13.
   - `:312` `DatabaseHeader` (the first 100 bytes of page 1); `:506` `PageType` (the four
     page kinds). ch 07, ch 12.
   - `:794-838` `BTreeCell` and the four cell structs (`TableInteriorCell` `:813`,
     `TableLeafCell` `:819`, `IndexInteriorCell` `:829`, `IndexLeafCell` `:838`); `:847`
     `read_btree_cell`. ch 07, ch 10, ch 18.
   - `:1353` `read_varint`, `:1470` `write_varint`; `:1016` `read_value` (record
     columns). ch 11.
   - `:2263` `payload_overflows` (does a payload spill, and how much stays local). ch 13.
   - `:417` `WalHeader`, `:477` `WalFrameHeader`, `:2300` `checksum_wal` (the checksum
     chain). ch 21, ch 22.
2. **`docs/agent-guides/async-io-model.md`** (213 lines). Read before `btree.rs`.
   - `:9` `IOResult` (`Done` or `IO`); `:74` the state machine pattern; `:117`
     re-entrancy, "the critical pitfall" (mutate after the yield, or record progress in
     the state). ch 30.
3. **`core/storage/btree.rs`, region: types and cursor state** (`:200-900`).
   - `:204` `DeleteState`, `:296` `BalanceSubState`, `:359` `WriteState`, `:513`
     `CursorState`: the state enums the rest of the file steps through. ch 30.
   - `:873` `BTreeCursor`; `:8989` `PageStack` (the root-to-leaf path with a cell index
     per level). ch 08.
4. **`btree.rs`, region: seek and iteration** (`:1450-3000`, `:6750-7000`).
   - `:6928` `seek` (the cursor entry point), `:1912` `do_seek`.
   - `:2054` `tablebtree_move_to` and `:2547` `tablebtree_seek`: descent by rowid, binary
     search through the cell pointer array. `:2364` `indexbtree_move_to_inner` and
     `:2935` `indexbtree_seek_inner`: the same with a record comparator; in an index tree
     the key may be found in an interior page. ch 02, ch 03, ch 07, ch 11.
   - `:1759` `get_next_record`, `:1453` `get_prev_record`: stepping with the page stack
     (pop to the parent, advance, descend); `:6757` `next`, `:6853` `prev`. ch 08.
   - `:6521` `save_context`, `:6562` `restore_context`: remember the key, re-seek after
     the tree changed. ch 08.
5. **`btree.rs`, region: insert** (`:3160-3400`, `:10400-10620`).
   - `:7012` `insert` (entry point), `:3162` `insert_into_page` (the write state machine;
     checks `overflow_cells` at `:3301`).
   - `:10413` `insert_into_cell`: write the cell into the page, or park it in the
     in-memory overflow-cell list when it does not fit; `:10516` `allocate_cell_space`,
     `:9288` `find_free_slot` (freeblock search), `:10433` `compute_free_space`. ch 04,
     ch 10, ch 12.
   - `:6276` `overwrite_cell`. ch 12.
6. **`btree.rs`, region: balance** (`:3400-5500`). The core of the file.
   - `:3401` `balance`: the loop that climbs while a page is overfull or underfull.
   - `:3526` `balance_quick`: the append fast path for the rightmost table leaf. ch 15.
   - `:3604` `balance_non_root`: pick up to three siblings (`:3693-3713`), collect all
     cells and dividers, redistribute over as many pages as needed, rewrite the parent's
     dividers. `:9436` `edit_page`, `:9552` `page_free_array`, `:9666`
     `page_insert_array` do the per-page rewriting. ch 05, ch 14, ch 15.
   - `:5410` `balance_root`: push the root's content into a new child so the root keeps
     its page number. ch 12.
7. **`btree.rs`, region: delete** (`:7041-7410`).
   - `:7041` `delete`: the `DeleteState` machine (`:204`): find the cell, clear its
     overflow pages, replace an interior cell with one taken from a leaf
     (`InteriorNodeReplacement`), balance if needed, then restore the cursor by key. `:10852` `drop_cell`, `:9797` `free_cell_range` (put the bytes on the
     freeblock chain or count them as fragments), `:10125` `defragment_page`. ch 05,
     ch 10, ch 15.
8. **`btree.rs`, region: overflow** (`:1617`, `:5499`, `:10609-10850`).
   - `:10609` `fill_cell_payload` (build a cell, spilling into an overflow chain);
     `:10808` `payload_overflow_threshold_max`, `:10829` `payload_overflow_threshold_min`;
     `:1617` `process_overflow_read` (follow the chain); `:5499` `clear_overflow_pages`
     (free it). ch 13.
9. **`core/storage/pager.rs`, freelist and page access** (7430 lines).
   - `:3672` `read_page` (cache hit as the fast path, otherwise a read that may
     yield); `:3919` `add_dirty`. ch 09.
   - `:5588` `free_page` and `:5853` `allocate_page`: the freelist of trunk and leaf
     pages (states at `:1809` `AllocatePageState`, `:1846` `FreePageState`). ch 13.
   - `:2922` `btree_create`; `:3311` `begin_read_tx`, `:3357` `begin_write_tx`; `:5053`
     `checkpoint`; `:6138` `rollback`. ch 12, ch 22.
   - `:390-433` and `:736-756` the `PageContent` accessors (`first_freeblock`,
     `cell_content_area`, `num_frag_free_bytes`, `cell_get_raw_region`). ch 10.
10. **`core/storage/page_cache.rs`** (2013 lines).
    - `:91-101` the comment and `PageCache` struct: a SIEVE variant with a small
      reference counter per entry (`:45-47`); `:208` `insert`, `:421` `get`, `:649`
      `make_room_for`, `:665` `evictable` (not dirty unless spilled, not locked, not
      pinned). ch 09.
11. **`core/storage/wal.rs`** (10,583 lines).
    - `:641` the `Wal` trait: `find_frame` (`:676`), `read_frame` (`:680`),
      `prepare_frames` (`:734`), `commit_prepared_frames` (`:744`), `checkpoint`
      (`:767`). Read the trait first.
    - `:2852` `WalFile`, `:3063` `WalFileShared`; `:3506` `begin_read_tx`, `:3571`
      `begin_write_tx`; `:3684` `find_frame` (newest frame of a page visible to this
      reader); `:4559` `prepare_frames`; `:160` `CheckpointMode`, `:4175` `checkpoint`,
      `:5001` `checkpoint_inner`. ch 21, ch 22.
12. **`btree.rs`, tests and checker** (`:8405`, `:10891` onward).
    - `:8405` `integrity_check` (walks tree pages, overflow chains and the freelist);
      `:11560` `validate_btree`; `:12181` `btree_insert_fuzz_run`, `:12478`
      `btree_index_insert_delete_fuzz_run`. ch 06.

---

## 3. TigerBeetle (`tigerbeetle`, commit `a2a3c70`)

TigerBeetle is a financial transactions database written in Zig. It has no B-tree: all
state is in a forest of LSM-trees over a grid of large checksummed blocks, with
copy-on-write block allocation and a superblock. It is in the guide for technique. A
table (one index block plus value blocks) is a static two-level index; the segmented
array is a one-level structure with split, merge and borrow on fixed-size nodes; the
in-node binary search, the bitset node pool, static allocation after start-up, and the
fuzzing style are all reusable in a B-tree engine.

### Reading order

1. **`docs/internals/lsm.md`** (310 lines) and **`docs/TIGER_STYLE.md`** (511 lines).
   - `lsm.md:18-36` tree and tables; `:37-139` compaction (selection policy `:93`, move
     table `:111`); `:140` snapshots; `:224-264` manifest and manifest level. ch 27.
   - `TIGER_STYLE.md:81-230` "Safety": assertions (`:100-112`) and static allocation
     (`:151`). ch 06, ch 26.
2. **`src/lsm/binary_search.zig`** (859 lines).
   - `:9-11` `Config` (mode, prefetch); `:33` `binary_search_values_upsert_index`: the
     halving search for a lower or upper bound, with an `.unpredictable` branch hint
     (`:109-112`) and prefetch of the next probes (`:59-96`); `:174`
     `binary_search_values`; `:230` and `:300` the range variants; `:561` onward the
     exhaustive and random tests. ch 02, ch 25.
3. **`src/lsm/node_pool.zig`** (247 lines).
   - `:10` `NodePoolType`; `:27-28` one buffer and a `free` bitset (a set bit means
     free); `:54` `acquire`, `:70` `release`. ch 05, ch 26.
4. **`src/lsm/segmented_array.zig`** (1510 lines).
   - `:18` and `:70-110` the design comments: nodes split at the midpoint, every node but
     the last at least half full. ch 01.
   - `:177` `verify` (invariants as code). ch 06.
   - `:238` `insert_elements`, `:282` `insert_elements_batch` (split at `:324-332`);
     `:451` `remove_elements`, `:561` `maybe_remove_or_merge_node_with_next`, `:579`
     `maybe_merge_nodes` (merge, or borrow from the next node). ch 04, ch 05.
   - `:894` `search`: two-level search, first over node boundaries, then inside a node.
   - `:1051` `FuzzContextType` and `:1426` `run_fuzz`: a model-based fuzzer with a
     reference array (`src/lsm/segmented_array_fuzz.zig` is only its 7-line entry
     point). ch 06.
5. **`src/lsm/table.zig`** (672 lines).
   - `:41-44` what a table is; `:105` `layout` (sizes computed at compile time); `:136`
     `index`; `:243` `Builder` (`:301` `value_block_finish`, `:406`
     `index_block_finish`): filling blocks left to right, like a bulk load; `:486`
     `index_value_block_for_key` and `:514` `index_blocks_for_key` (routing in the index
     block); `:537` `value_block_search`. ch 16, ch 27.
6. **`src/lsm/manifest_level.zig`** (1597 lines) and `src/lsm/manifest.zig`.
   - `manifest_level.zig:16` `ManifestLevelType`; `:27-40` `Keys` and `Tables`, two
     sorted segmented arrays; `:208` `insert_table`, `:283` `remove_table`.
   - `manifest.zig:400` `lookup`: tables within a level are disjoint, so a point lookup
     meets at most one table per level. ch 27.
7. **`src/lsm/compaction.zig`** (2378 lines).
   - `:1-30` the overview comment (move or merge; when a tombstone may be dropped);
     `:58-61` input table bound from the growth factor; `:288` `CompactionType`; `:565`
     `half_bar_commence`; `:1547` `merge` (`:1572` `merge_immutable`, `:1640`
     `merge_disk`). The merge itself is `src/lsm/k_way_merge.zig:209`. The memtable is
     `src/lsm/table_memory.zig:42`. `src/constants.zig:610-616` explains the growth
     factor of 8. ch 27.
8. **`src/lsm/tree_fuzz.zig`** (961 lines).
   - `:66-85` `FuzzOp` (compact, put, remove, get, scan); `:100` `EnvironmentType` (a
     real tree on simulated storage); `:547` `apply` (run each op and compare with the
     model); `:698-793` the `Model`; `:816` `generate_fuzz_ops` (swarm-style op mix);
     `:920` `main`. All fuzzers are registered in `src/fuzz_tests.zig:41-43`. ch 06.
9. **`src/vsr/grid.zig`** (1741 lines), **`src/vsr/free_set.zig`** (1381 lines),
   **`src/vsr/superblock.zig`** (1611 lines).
   - `grid.zig:30` `GridType`; `:678` `reserve`, `:700` `acquire`, `:712` `release`;
     `:918` `create_block`; `:1201` `read_block`; `:1421-1446` `read_block_validate`: a
     block is addressed by (address, checksum) and checked against both. ch 09, ch 23.
   - `free_set.zig:45-62` the two bitsets and `checkpoint_durable`; `:347` `reserve`,
     `:411` `acquire`, `:516` `release` (released blocks stay acquired), `:600`
     `mark_checkpoint_durable` (now they are free). ch 13, ch 23.
   - `superblock.zig:53-80` `SuperBlockHeader`: checksum, `copy`, `sequence` (`:72`),
     `parent` checksum (`:78`). ch 21, ch 23.
   - `src/lsm/set_associative_cache.zig:15-18` the cache layout (16 ways, 8-bit tags,
     2-bit clock counters). ch 09.
10. **`src/static_allocator.zig`** (82 lines). Read all of it.
    - `:12-24` the three states (`init`, `static`, `deinit`); `:36`
      `transition_from_init_to_static`. ch 26.
11. **`src/lsm/composite_key.zig:13`** `CompositeKeyType`: a (field, timestamp) pair
    packed into one integer so that integer order is key order. ch 11.

---

## 4. DuckDB (`duckdb`, commit `9d8ecca6`)

DuckDB is an analytical, column-oriented database. It has no B-tree. Its index is an
adaptive radix tree (ART) over byte-comparable keys, guarded by one index-wide lock;
most filtering is done without any index, by per-segment min/max statistics (zone maps).
Its storage never overwrites live blocks: a checkpoint writes new blocks and then
alternates between two database headers. The guide uses it for the ART, for handles
into slab buffers (`IndexPointer`, `FixedSizeAllocator`), and for the checkpoint design.

### Reading order

1. **`src/execution/index/art/art_key.cpp`** (170 lines).
   - `:66` `ARTKey::CreateKey`: a value becomes a byte string whose byte order is the
     value order; `:21` the string variant; `:159` `GetMismatchPos`. ch 11.
2. **`src/include/duckdb/execution/index/index_pointer.hpp`** (103 lines) and
   **`src/include/duckdb/execution/index/art/node.hpp`**.
   - `index_pointer.hpp:15-24` the 64-bit handle: 32-bit buffer id, 24-bit offset, 8
     bits of metadata. `node.hpp:24-35` `NType`, the node kinds. ch 09, ch 26.
3. **Node types**: `src/include/duckdb/execution/index/art/base_node.hpp`,
   `node48.hpp`, `node256.hpp`; `src/execution/index/art/base_node.cpp`, `node48.cpp`,
   `node256.cpp`, `node.cpp`.
   - `base_node.hpp:32-33` the sorted `key[]` and `children[]` of Node4 and Node16
     (capacities at `:166`, `:185`); `node48.hpp:27-39` capacity, `SHRINK_THRESHOLD` 12
     and the 256-entry `child_index`; `node256.hpp:24-25` capacity and
     `SHRINK_THRESHOLD` 36.
   - `base_node.cpp:61` `Node4::InsertChild`, `:155` `Node16::GrowNode4`, `:104`
     `Node4::ShrinkNode16`; `node48.cpp:58` `GrowNode16`; `node256.cpp:33` `GrowNode48`.
   - `node.cpp:152` `NodePtr::InsertChild` (dispatch by type), `:229` `GetChild`,
     `:276` `GetNextChildNode`. ch 28.
4. **`src/include/duckdb/execution/index/art/art_operator.hpp`**.
   - `:27` `Lookup`, `:126` `Insert`, `:257` `Delete`: the per-key descent, byte by byte,
     through prefixes and nodes; `:475` `InsertIntoPrefix` (split a compressed path).
     Prefix nodes: `src/execution/index/art/prefix.cpp:57` `Prefix::New`, `:71`
     `Reduce`. ch 17, ch 28.
5. **`src/execution/index/art/art.cpp`** (1649 lines). The index as the engine sees it.
   - `:579` `Build` (sorted bulk construction, see `art_builder.cpp:10`); `:612`
     `Insert`; `:753` `DeleteKeys`; `:801` `SearchEqual`, `:814` `SearchGreater`, `:833`
     `SearchLess`, `:852` `SearchCloseRange`; `:1086` `VerifyConstraint` (unique
     checks); `:1345` `Vacuum`. ch 16, ch 18, ch 28.
6. **`src/execution/index/art/iterator.cpp`** (382 lines).
   - `:224` `LowerBound` (seek), `:312` `Next`, `:165` `FindMinimum`, `:80` `Scan` with
     an upper bound: an ordered scan with a node stack. ch 08.
7. **`src/execution/index/fixed_size_allocator.cpp`** (468 lines).
   - `:56` `New` and `:96` `Free`: fixed-size segments in buffers with a free bitmask;
     `:195` `InitializeVacuum` (threshold at `:225-233`, `VACUUM_THRESHOLD` = 10 in
     `fixed_size_allocator.hpp:31`), `:269` `VacuumPointer` (move a segment and return
     its new handle), `:260` `FinalizeVacuum`. ch 26.
8. **`src/storage/single_file_block_manager.cpp`** (1532 lines).
   - `:527` `CreateNewDatabase`: two headers written at `:600-636`; `:639`
     `LoadExistingDatabase`, picking the header with the higher iteration at
     `:721-728`; `:993-1030` `MarkBlockAsModified` (a freed block is not reusable
     until the next checkpoint); `:1356` `WriteHeader`: iteration bump at `:1366`, the
     other header slot chosen at `:1443-1448`. ch 13, ch 21, ch 23.
9. **Zone maps and statistics**.
   - `src/storage/statistics/numeric_stats.cpp:210` `CheckZonemapTemplated`: min/max
     against a constant gives always true, always false or no pruning possible.
   - `src/storage/table/row_group.cpp:735` `RowGroup::CheckZonemap` and
     `src/storage/table/column_data.cpp:469` `ColumnData::CheckZonemap`: where a scan
     skips a row group or segment.
   - `src/function/table/table_scan.cpp:1015-1020`: the index-scan cut-off (an index
     scan is used only up to a maximum row count derived from two settings). ch 29.

---

## 5. Milvus (`milvus`, commit `0d3e77c`)

Milvus is a distributed vector database (Go coordination, C++ segment core). It does
contain B-trees, but only as two small in-memory uses of the Go library
`github.com/google/btree` (`go.mod:19`), both created with degree 2. Everything else is
contrast: scalar indexes are sorted arrays, data lives in growing segments that are
sealed and later rewritten by compaction (LSM-like, not a true LSM), and per-chunk
min/max metrics play the part of zone maps.

### Reading order

1. **`internal/kv/mem/mem_kv.go`** (420 lines). B-tree use 1: an in-memory key-value
   store.
   - `:37-41` `MemoryKV`: a `sync.RWMutex` around a `*btree.BTree`; `:53`
     `btree.New(2)`; `:90` `Less`; `:144` `AscendRange` (a range scan); `:297`
     `AscendGreaterOrEqual` (a prefix scan as a range). ch 03, ch 08, ch 19.
2. **`internal/streamingcoord/server/broadcaster/schema.go`** (146 lines). B-tree use 2:
   an ordered set of pending schema tasks.
   - `:59` `pending *btree.BTreeG[*SchemaTarget]`; `:90` `btree.NewG(2, less)`; `:95`
     `ReplaceOrInsert`; `:84`, `:96` `Min`. ch 03.
3. **The scalar sort index**, `internal/core/src/index/scalar/sort/`.
   - `IndexStructure.h:22` the (value, row offset) pair.
   - `SortedIndexBuilder.cpp:322` build is `std::sort`.
   - `SortedIndexReader.cpp:542` equality by `std::equal_range`; `:638-642` a two-sided
     range chooses `lower_bound` or `upper_bound` by bound inclusivity (the bounds
     matrix); `:365` `PrefixRange`.
   - `SortedMembership.h:33-71` `VisitOrderedMatches`: galloping search for a sorted
     `IN (...)` list. ch 01, ch 02, ch 08.
4. **Primary-key lookup**, `internal/core/src/segcore/InsertRecord.h`.
   - `:306` `OffsetOrderedMap` (growing segment: an ordered map), `:620`
     `OffsetOrderedArray` (sealed segment: a sorted array, `seal` at `:728`). "Mutable
     map, sealed sorted array". ch 01.
5. **Skip index**, `internal/core/src/index/skipindex_stats/SkipIndexStats.h` and
   `internal/core/src/index/SkipIndex.h`.
   - `SkipIndexStats.h:170` `RangeShouldSkip`; `:491` `IntFieldChunkMetrics` (min, max,
     Bloom filter); `SkipIndex.h:96`, `:112` the per-chunk `CanSkip...` calls. ch 29.
6. **Segment compaction**.
   - `pkg/proto/data_coord.proto:27-32` `SegmentLevel` (L0 holds deletes, L1, L2).
   - `internal/datanode/compactor/l0_compactor.go:117` `Compact`, `:194`
     `splitAndWrite`, `:374` `applyBFInParallel` (route deletes to segments by Bloom
     filter).
   - `internal/datanode/compactor/merge_sort.go:24` `mergeSortMultipleSegments` (a k-way
     merge); `internal/compaction/entity_filter.go:50` `Filtered`, `:89`
     `isEntityDeleted` (where deleted rows are finally dropped). Also in that directory:
     `mix_compactor.go`, `clustering_compactor.go`, `sort_compaction.go`. ch 27.

---

## 6. FAISS (`faiss`, commit `c8f2838`)

FAISS is a C++ library for nearest-neighbour search over dense vectors. It has no B-tree
and no ordered index at all, and that is why it is here: no total order keeps near
vectors near, so its indexes replace comparison by distance. IVF is a one-level tree
whose root (the centroids) is scanned instead of searched, and HNSW is a skip-list-like
graph. Both are approximate. Its storage shows flat arrays with offsets in place of
pointers.

### Reading order

1. **`faiss/IndexIVF.h`** (674 lines) and **`faiss/IndexIVF.cpp`** (1851 lines).
   - `IndexIVF.h:30-35` `Level1Quantizer` (the coarse quantizer and `nlist`); `:97`
     `nprobe = 1`; `:202-221` the class comment; `:222` `IndexIVF`.
   - `IndexIVF.cpp:340` `add_core` (assign each vector to its nearest centroid's list);
     `:433` `search`: `quantizer->search` over all centroids (`:464`), then
     `prefetch_lists` (`:473`); `:532` `search_preassigned` with `scan_one_list`
     (`:669`) calling `scanner->scan_codes` (`:737`). ch 29.
2. **`faiss/impl/HNSW.h`** (454 lines) and **`faiss/impl/HNSW.cpp`** (2056 lines).
   - `HNSW.h:114-138` the fields: `assign_probas`, `levels`, `offsets`, `neighbors` (one
     flat array for the whole graph), `entry_point`, `max_level`; `:141-144`
     `efConstruction`, `efSearch`.
   - `HNSW.cpp:52` `neighbor_range` (offsets instead of pointers); `:67` `random_level`
     (the coin flips); `:702` `greedy_update_nearest_impl` (move to a closer neighbour
     until none is closer); `:1752` `search_impl`: greedy descent through the upper
     levels at `:1776-1784`, then a candidate search on level 0; `:1974` `HNSW::search`.
     ch 25, ch 29.
3. **`faiss/invlists/OnDiskInvertedLists.h`** (156 lines) and **`.cpp`** (831 lines).
   - `.h:25` `OnDiskOneList`; `:31-59` the layout comment; `:66-74` `Slot` and the free
     `slots` list.
   - `.cpp:269` `do_mmap`; `:445` `resize_locked` (free the old slot, allocate a larger
     one, copy); `:487` `allocate_slot`, `:523` `free_slot`: a free-space list for
     variable-size regions in a file. ch 10, ch 13.

---

## Three paths through the sources

### "I want to see a real page split"

Read ch 04, ch 12, ch 14 and ch 20 first; ch 30 walks the same path with commentary.

1. `postgres` `N/README:14-56`: why a split may be seen half done.
2. `postgres` `N/nbtinsert.c:1117` `_bt_insertonpg`: the page is full, so it calls
   `_bt_split`.
3. `postgres` `N/nbtsplitloc.c:130` `_bt_findsplitloc`: where to cut.
4. `postgres` `N/nbtinsert.c:1487` `_bt_split`: build the left half in scratch memory,
   set the flag, truncate the high key, allocate the right page, critical section
   `:1950-2093`.
5. `postgres` `N/nbtinsert.c:2128` `_bt_insert_parent`, then `:2490` `_bt_newlevel` if
   the root split.
6. `postgres` `N/nbtxlog.c:247` `btree_xlog_split`: the same split replayed from the
   log.
7. For the other design: `turso` `core/storage/btree.rs:10413` `insert_into_cell`
   (overflow cell), `:3401` `balance`, `:3604` `balance_non_root`, `:5410`
   `balance_root`. No flag, no right link, up to three siblings rewritten as one unit.

### "I want to see how a real engine tests this"

Read ch 06 first, then ch 21 and ch 22 for the crash side.

1. `tigerbeetle` `src/lsm/segmented_array.zig:177` `verify` and `:1051-1426` the fuzz
   context: invariants as code plus a reference model, in one file.
2. `tigerbeetle` `src/lsm/tree_fuzz.zig:66`, `:547`, `:698`, `:816`: op generation,
   apply-and-compare, the model.
3. `tigerbeetle` `src/testing/storage.zig:1-24`: in-memory storage with injected faults;
   `docs/internals/vopr.md` describes the deterministic simulator around it.
4. `tigerbeetle` `src/lsm/binary_search.zig:561-853`: exhaustive tests of a small
   function.
5. `turso` `core/storage/btree.rs:8405` `integrity_check`, then the fuzz tests from
   `:12082` (`btree_insert_fuzz_run` at `:12181`). The simulator lives in
   `testing/simulator/`.
6. `postgres` `contrib/amcheck/verify_nbtree.c:365` `bt_check_every_level`, `:1226`
   `bt_target_page_check`, `:2381` `bt_child_check`: a `validate` for a live production
   tree. SQL-level tests are in `src/test/regress/sql/btree_index.sql`.

### "I want to see the alternatives to a B-tree"

Read ch 27, ch 28 and ch 29 first.

1. Sorted array: `milvus`
   `internal/core/src/index/scalar/sort/SortedIndexReader.cpp:542`, `:638-642`.
2. One-level structure with split and merge: `tigerbeetle`
   `src/lsm/segmented_array.zig:282`, `:579`, `:894`.
3. LSM-tree: `tigerbeetle` `docs/internals/lsm.md`, then `src/lsm/table.zig:41-44`,
   `:486`; `src/lsm/compaction.zig:1-30`, `:1547`; `src/lsm/k_way_merge.zig:209`.
   LSM-like segments: `milvus` `internal/datanode/compactor/l0_compactor.go:117`.
4. Radix tree: `duckdb` `src/include/duckdb/execution/index/art/art_operator.hpp:27`,
   `:126`; `src/execution/index/art/base_node.cpp:61`, `:155`;
   `src/execution/index/art/iterator.cpp:224`.
5. No index, only summaries: `duckdb` `src/storage/statistics/numeric_stats.cpp:210`,
   `src/storage/table/row_group.cpp:735`; `milvus`
   `internal/core/src/index/skipindex_stats/SkipIndexStats.h:170`.
6. No order at all: `faiss` `faiss/IndexIVF.cpp:433` and `faiss/impl/HNSW.cpp:702`,
   `:1752`.
7. Copy-on-write storage instead of overwrite plus log: `duckdb`
   `src/storage/single_file_block_manager.cpp:993-1030`, `:1356`; `tigerbeetle`
   `src/vsr/free_set.zig:516`, `:600` and `src/vsr/superblock.zig:53-80`.
