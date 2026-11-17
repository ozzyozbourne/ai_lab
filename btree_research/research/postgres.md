# PostgreSQL nbtree: source-grounded research notes

Source tree: `/home/user/ai_lab/db_study/postgres` (shallow clone, commit `11591f2`).
All `file:line` references are to that commit. Path shorthand used below:

- `N/` = `src/backend/access/nbtree/`
- `nbtree.h` = `src/include/access/nbtree.h`
- `nbtxlog.h` = `src/include/access/nbtxlog.h`
- `bufpage.h` = `src/include/storage/bufpage.h`, `itemid.h` = `src/include/storage/itemid.h`
- `README` = `N/README` (1083 lines, read in full)

Conventions in these notes:

- Everything stated was read in the source unless tagged **(unverified)** (from memory) or
  **(derived)** (my own arithmetic from verified struct definitions and constants, not a value
  printed by the code or measured on a running server).
- Snippets are trimmed (blank lines and some comments removed), so a snippet may span slightly
  more source lines than it shows. Line ranges given are the real source ranges.
- File layout note: this commit has two files that older PostgreSQL versions do not have as
  separate files: `N/nbtreadpage.c` (3717 lines: `_bt_readpage`, `_bt_checkkeys`, array-key
  advancement) and `N/nbtpreprocesskeys.c` (2856 lines: scan key preprocessing, skip arrays).
  Guides written against PG <= 17 put this code in `nbtsearch.c` / `nbtutils.c`.

Terminology used by the source (README:31-40):

- **pivot tuple**: a tuple used only for navigation (all tuples on internal pages, plus the high
  key on leaf pages). Holds a separator key and/or a downlink.
- **non-pivot tuple**: a leaf tuple that points to the heap (table) via a TID.
- **downlink**: child block number stored in a pivot tuple.
- **high key**: upper bound on keys allowed on a page.
- **TID / heap TID**: (block number, line pointer number) address of a table row; 6 bytes.

---

## 1. On-disk page layout

### What it does

Every nbtree page is a standard PostgreSQL slotted page: a fixed header, an array of 4-byte line
pointers ("slots", `ItemIdData`) growing forward from the header, tuples growing backward from the
end, and a "special space" trailer that nbtree uses for `BTPageOpaqueData` (sibling links, level,
flags). Sorted order is the order of the line pointer array, not the physical order of tuples, so
inserting in the middle only shifts 4-byte slots.

nbtree-specific conventions layered on top:

- Block 0 is the **metapage**. It stores the root location and level, plus the **fast root**
  location and level.
- On a non-rightmost page, slot 1 (`P_HIKEY`) is the high key and data starts at slot 2
  (`P_FIRSTKEY`). On a rightmost page there is no high key (it is implicitly +infinity) and data
  starts at slot 1.
- On an internal page, the first data item's key is treated as minus infinity and is physically
  truncated to zero attributes; only its downlink matters. This gives the L&Y "one more pointer
  than keys" shape using an array of (key, pointer) tuples.
- Levels count up from 0 at the leaves, so a root split never renumbers existing pages
  (README:1049-1051).
- Index tuple header is 8 bytes: a 6-byte TID field `t_tid` and a 2-byte `t_info` (13 bits of
  size, plus has-nulls, has-varwidth and one AM-reserved bit). nbtree overloads `t_tid`:
  - non-pivot plain tuple: `t_tid` = heap TID
  - pivot tuple: block part = downlink; offset part = number of key attributes kept (low 12 bits)
    plus status bits
  - posting list tuple: block part = byte offset of the TID array inside the tuple; offset part =
    number of TIDs plus the `BT_IS_POSTING` bit

### Where (file:line)

- Slotted page diagram and rationale: `bufpage.h:24-78`
- `PageHeaderData`: `bufpage.h:184-197`; "write xlog before data" LSN rule: `bufpage.h:150-155`;
  32KB max page because `lp_off`/`lp_len` are 15 bits: `bufpage.h:180-181`
- `ItemIdData` (line pointer): `itemid.h:25-30`; states `LP_UNUSED/NORMAL/REDIRECT/DEAD`:
  `itemid.h:38-41`
- `IndexTupleData`: `src/include/access/itup.h:35-51`; `INDEX_SIZE_MASK 0x1FFF`,
  `INDEX_AM_RESERVED_BIT 0x2000`: `itup.h:65-66`
- `BTPageOpaqueData` and flag bits: `nbtree.h:63-85`
- `BTMetaPageData`: `nbtree.h:104-120`; `BTREE_METAPAGE 0`, `BTREE_MAGIC`, `BTREE_VERSION 4`:
  `nbtree.h:149-153`
- `P_NONE`, `P_LEFTMOST`, `P_RIGHTMOST`, `P_IGNORE`, ...: `nbtree.h:213-229`
- `P_HIKEY`, `P_FIRSTKEY`, `P_FIRSTDATAKEY`: `nbtree.h:368-370`
- Tuple format notes (pivot / non-pivot / posting): `nbtree.h:372-459`; masks `nbtree.h:460-467`
- `BTreeTupleIsPivot`, `BTreeTupleIsPosting`, `BTreeTupleGetDownLink`, `BTreeTupleSetNAtts`,
  `BTreeTupleGetHeapTID`: `nbtree.h:480-502, 556-566, 595-611, 640-657`
- Data representation prose: README:1044-1083
- `_bt_pageinit` (PageInit with `sizeof(BTPageOpaqueData)` special space): `N/nbtpage.c:1137-1140`
- `_bt_initmetapage`: `N/nbtpage.c:67-97`
- Leaf-page-under-construction diagram: `N/nbtsort.c:750-763`

### Snippet

`bufpage.h:31-44`:

```
 * +----------------+---------------------------------+
 * | PageHeaderData | linp1 linp2 linp3 ...           |
 * +-----------+----+---------------------------------+
 * | ... linpN |                                      |
 * +-----------+--------------------------------------+
 * |           ^ pd_lower                             |
 * |                                                  |
 * |             v pd_upper                           |
 * +-------------+------------------------------------+
 * |             | tupleN ...                         |
 * +-------------+------------------+-----------------+
 * |       ... tuple3 tuple2 tuple1 | "special space" |
 * +--------------------------------+-----------------+
 *                                  ^ pd_special
```

`nbtree.h:63-70`:

```c
typedef struct BTPageOpaqueData
{
	BlockNumber btpo_prev;		/* left sibling, or P_NONE if leftmost */
	BlockNumber btpo_next;		/* right sibling, or P_NONE if rightmost */
	uint32		btpo_level;		/* tree level --- zero for leaf pages */
	uint16		btpo_flags;		/* flag bits, see below */
	BTCycleId	btpo_cycleid;	/* vacuum cycle ID of latest split */
} BTPageOpaqueData;
```

`nbtree.h:104-111` (metapage, first six fields):

```c
typedef struct BTMetaPageData
{
	uint32		btm_magic;		/* should contain BTREE_MAGIC */
	uint32		btm_version;	/* nbtree version (always <= BTREE_VERSION) */
	BlockNumber btm_root;		/* current root location */
	uint32		btm_level;		/* tree level of the root page */
	BlockNumber btm_fastroot;	/* current "fast" root location */
	uint32		btm_fastlevel;	/* tree level of the "fast" root page */
```

`nbtree.h:368-370`:

```c
#define P_HIKEY				((OffsetNumber) 1)
#define P_FIRSTKEY			((OffsetNumber) 2)
#define P_FIRSTDATAKEY(opaque)	(P_RIGHTMOST(opaque) ? P_HIKEY : P_FIRSTKEY)
```

Why the high key is at the *front* (README:1062-1068): "Putting the high key at the left, rather
than the right, may seem odd, but it avoids moving the high key as we add data items."

Fast root (README:365-381): because the rightmost page of a level is never deleted, tree height
never shrinks. After mass deletion the top of the tree can be a chain of single-page levels. The
metapage therefore stores the lowest single-page level as the "fast root" and searches start
there. `_bt_getroot` reads `btm_fastroot` (`N/nbtpage.c:376-378`) and caches the metapage in the
relcache (`rel->rd_amcache`, `N/nbtpage.c:365-404`), validating the cached pointer by checking the
page is live, on the expected level, and alone on its level (`N/nbtpage.c:391-394`).

### Teaching idea

- Chapter "A page is an array of slots": build a 4KB/8KB slotted page in Zig/Rust as a `[N]u8`
  with `lower`/`upper` cursors, `insert_at(slot, bytes)` that memmoves only the slot array, and a
  16-byte trailer struct. Show that a sorted insert is O(slots) of 4-byte moves, not tuple moves.
- Visualization: one page as a horizontal bar; slots grow from the left, tuples from the right,
  free space shrinking in the middle; trailer box on the far right with prev/next/level/flags.
- Second visualization: same page drawn "logically" (high key | item 1 | item 2 ...) next to the
  physical bar, with lines from slot to tuple, to show the indirection.
- Exercise: explain why slot 1 is the high key and why a rightmost page has none; have the reader
  write `first_data_key(page)`.
- Small Rust example of the `t_tid` overloading as an enum
  `enum Tuple { Leaf{tid}, Pivot{downlink, natts, heap_tid: Option<Tid>}, Posting{tids} }` and a
  note that PostgreSQL packs this into the same 8 header bytes with bit flags.

---

## 2. Search: descent, binary search, scan keys, moving right

### What it does

`_bt_search` descends from the (fast) root to the first leaf page that could contain the key. At
each level it (1) calls `_bt_moveright` to recover from a concurrent split, (2) binary-searches the
page for the downlink to follow, (3) optionally pushes (block, offset) onto a private stack,
(4) releases the lock and pin on the parent and then locks the child. Only one page lock is held
at a time during descent; no lock is held "between" levels.

Two kinds of scan key (README:798-821):

- **search scankey**: what the executor passes (`WHERE a >= 5`), boolean operators, used on the
  leaf level to filter tuples and decide when to stop.
- **insertion scankey** (`BTScanInsertData`): one 3-way comparator per column, plus `nextkey`
  (find first item `>` key instead of `>=`), `backward`, and `scantid` (heap TID tiebreaker).
  Used for descending the tree, for both scans and inserts.

`_bt_binsrch` is one loop for both page kinds; the only difference is the post-processing: on a
leaf it returns the first slot `>=` key (or `>` when `nextkey`); on an internal page it returns the
slot *before* that, i.e. the last pivot `<` key, whose downlink to follow.

`_bt_compare` encodes three sentinel rules:

1. The first data item on an internal page is always less than any scankey (minus infinity).
2. Attributes truncated away from a pivot compare as minus infinity (scankey is greater).
3. Heap TID is compared last, as one more key column; a truncated TID is also minus infinity.

### Where (file:line)

- `_bt_search`: `N/nbtsearch.c:101-216`
- `_bt_moveright`: `N/nbtsearch.c:243-331`
- `_bt_binsrch`: `N/nbtsearch.c:345-451`
- `_bt_binsrch_insert` (caches `low`/`stricthigh` bounds for reuse after the unique check):
  `N/nbtsearch.c:476-594`
- `_bt_compare`: `N/nbtsearch.c:690-860`
- `BTScanInsertData`: `nbtree.h:794-805` (commentary `nbtree.h:757-793`)
- `BTStackData`: `nbtree.h:748-755`
- `_bt_mkscankey`: `N/nbtutils.c:60-150` (sets `scantid` from the tuple's TID at `:97-98`)
- `_bt_first` (builds the insertion scankey from search keys, then calls `_bt_search` and
  `_bt_binsrch`): `N/nbtsearch.c:884-1576`; the calls are at `:1515` and `:1549`
- `_bt_getroot`: `N/nbtpage.c:346-568`

### Snippet

Descent step, `N/nbtsearch.c:163-195` (trimmed):

```c
		offnum = _bt_binsrch(rel, key, *bufP);
		itemid = PageGetItemId(page, offnum);
		itup = (IndexTuple) PageGetItem(page, itemid);
		child = BTreeTupleGetDownLink(itup);
		...
		if (opaque->btpo_level == 1 && access == BT_WRITE)
			page_access = BT_WRITE;

		/* drop the read lock on the page, then acquire one on its child */
		*bufP = _bt_relandgetbuf(rel, *bufP, child, page_access);
```

Binary search core, `N/nbtsearch.c:389-407`:

```c
	high++;						/* establish the loop invariant for high */
	cmpval = key->nextkey ? 0 : 1;	/* select comparison value */
	while (high > low)
	{
		OffsetNumber mid = low + ((high - low) / 2);
		/* We have low <= mid < high, so mid points at a real slot */
		result = _bt_compare(rel, key, page, mid);
		if (result >= cmpval)
			low = mid + 1;
		else
			high = mid;
	}
```

Loop invariant as stated at `N/nbtsearch.c:382-386`: for `nextkey=false`, "all slots before 'low'
are < scan key, all slots at or after 'high' are >= scan key".

Internal page result, `N/nbtsearch.c:448-450`:

```c
	Assert(low > P_FIRSTDATAKEY(opaque));
	return OffsetNumberPrev(low);
```

Minus-infinity rule, `N/nbtsearch.c:710-715`:

```c
	/*
	 * Force result ">" if target item is first data item on an internal page
	 * --- see NOTE above.
	 */
	if (!P_ISLEAF(opaque) && offnum == P_FIRSTDATAKEY(opaque))
		return 1;
```

Truncated attributes, `N/nbtsearch.c:794-795`:

```c
	if (key->keysz > ntupatts)
		return 1;
```

Small but important details:

- For a write descent, the leaf is locked in write mode directly: when on level 1 the next lock is
  taken as `BT_WRITE` (`N/nbtsearch.c:187-188`). Only when the root is itself a leaf does the code
  upgrade read to write by unlock + relock and then re-run `_bt_moveright`
  (`N/nbtsearch.c:203-213`). PostgreSQL has no atomic lock upgrade here.
- `_bt_search` returns "locked and pinned" leaf; "No locks are held on the parent pages"
  (`N/nbtsearch.c:87-88`).
- The stack is advisory. It "can become stale due to concurrent page splits and page deletions,
  but it should never give us an irredeemably bad picture" (`nbtree.h:744-746`).

### Teaching idea

- Chapter "One binary search, two meanings": implement `binsrch(page, key, nextkey) -> slot` in
  Zig/Rust with the exact invariant, then show leaf vs internal post-processing as a two-line
  difference. Property-test it against a linear scan.
- Animation: descent with a moving "lock token" that is on exactly one page at a time; highlight
  the moment between releasing the parent and locking the child, where the reader holds nothing.
  That gap is what the next chapter (B-link) makes safe.
- Table to print in the guide: comparison outcomes for scankey `('foo')` vs pivot `('foo', -inf)`
  to motivate rule 2; the source's own worked example is at `N/nbtsearch.c:813-821`.

---

## 3. Lehman & Yao B-link tree: right links, high keys, move right, lock coupling

### What it does

L&Y add two things to each page: a right-sibling pointer and a high key. A split always moves the
upper half of a page to a *new right sibling* and never moves data left, so any key that used to be
on page P is afterwards either on P or reachable by following right links from P. A reader that
arrives at P via a stale downlink compares its key with P's high key; if key > high key the page
was split and the reader follows the right link. This is the whole reason readers need no lock
coupling during descent.

PostgreSQL's deviations from the paper (README:57-164):

- Buffers are shared, so readers take a page-level shared lock while examining one page
  (README:63-68). Still only one lock at a time.
- A left link is added for backward scans (README:70-86).
- Root split is defined: split normally, then build a new root above and swing the metapage
  pointer; safe because the old root is still reachable and has a right link (README:112-123).
- Parent is re-found by child block number, not by separator key, so no lock coupling is needed
  between internal pages on the same level when moving right during the ascent (README:139-156).
- Keys are variable size: "we just stuff in as many as will fit" and split by bytes
  (README:158-164).
- Keys must be unique for the L&Y invariant `Ki < v <= Ki+1`; PostgreSQL makes them unique by
  appending heap TID as a tiebreaker column (README:42-49).

Lock ordering rules actually used:

| Situation | Rule | Where |
|---|---|---|
| Descending | release parent, then lock child (no coupling) | `N/nbtsearch.c:194-195` |
| Reader moving right | release current, then lock right sibling | `N/nbtsearch.c:320-325` |
| Inserter stepping right on leaf level | lock right sibling *before* releasing current | `N/nbtinsert.c:1055, 1081` |
| Split | hold left (original); allocate right; then lock old right sibling. Left to right. | `N/nbtinsert.c:1739, 1905-1912` |
| Inserting downlink | hold both children while locking parent (child to parent = "up"); release right child once parent is locked; left child released by parent insert | `N/nbtinsert.c:2223-2249` |
| Metapage | always locked last | README:378-381, `N/nbtinsert.c:2475-2481` |
| General | locking next before releasing current "is safe when moving right or up, but not when moving left or down" | README:106-110 |

Why the inserter couples locks when stepping right but the reader does not: a unique-check
inserter relies on holding a write lock continuously from the check to the insert, "else someone
else's _bt_check_unique scan could fail to see our insertion" (`N/nbtinsert.c:1029-1031`).

Half-dead and deleted pages are handled by the same mechanism: `P_IGNORE(opaque)` forces a move
right (`N/nbtsearch.c:320`).

### Where (file:line)

- README:14-55 (basic algorithm), 57-164 (differences), 106-110 (lock ordering)
- `_bt_moveright`: `N/nbtsearch.c:243-331`
- High key definition and guarantee: `nbtree.h:349-366`
- `_bt_stepright`: `N/nbtinsert.c:1038-1084`
- `_bt_getstackbuf` (re-find parent by downlink, move right without coupling):
  `N/nbtinsert.c:2348-2453`

### Snippet

`N/nbtsearch.c:320-327`:

```c
		if (P_IGNORE(opaque) || _bt_compare(rel, key, page, P_HIKEY) >= cmpval)
		{
			/* step right one page */
			buf = _bt_relandgetbuf(rel, buf, opaque->btpo_next, access);
			continue;
		}
		else
			break;
```

`N/nbtsearch.c:247-251`:

```
 * When we follow a pointer to reach a page, it is possible that
 * the page has changed in the meanwhile.  If this happens, we're
 * guaranteed that the page has "split right" -- that is, that any
 * data that appeared on the page originally is either on the page
 * or strictly to the right of it.
```

README:17-22:

```
Compared to a classic B-tree, L&Y adds a right-link pointer to each page,
to the page's right sibling.  It also adds a "high key" to each page, which
is an upper bound on the keys that are allowed on that page.  These two
additions make it possible to detect a concurrent page split, which allows
the tree to be searched without holding any read locks (except to keep a
single page from being modified while reading it).
```

### Teaching idea

- This is the conceptual centre of a "concurrency" chapter. Build it in stages in Rust:
  (a) single-threaded B+tree; (b) add `right: Option<PageId>` and `high_key`; (c) put each page
  behind an `RwLock` and descend holding one lock at a time; (d) write a test that splits a leaf
  between a reader's "release parent" and "lock child" and show the reader recovering via
  `move_right`.
- Animation "the stale downlink": reader R reads parent, gets pointer to P. Writer W splits P into
  P and P'. R lands on P, sees key > high key, slides right to P'. Show the same sequence without
  right links to demonstrate the wrong answer.
- State the invariant in one line for the guide: "A split only ever moves keys to the right, and a
  page's high key only ever decreases."  (`nbtree.h:359-361`: "Once a page is created, its high
  key changes only if the page is split.")
- A table like the one above is a good guide artifact: it turns "lock coupling" into five concrete
  rules, each with a deadlock-freedom argument (everyone orders locks left-to-right and
  bottom-to-top, metapage last).

---

## 4. Insert: finding the leaf, unique checks, page split, parent downlink, root split

### 4.1 Finding the leaf and the insert position

#### What it does

`_bt_doinsert` builds an insertion scankey from the new tuple, descends with `_bt_search(...,
BT_WRITE, returnstack=true)`, optionally runs the unique check, finds the exact slot with
`_bt_findinsertloc`, and calls `_bt_insertonpg`.

Rightmost-leaf fastpath: each backend caches the block number of the rightmost leaf it last
inserted into. The next insert tries a *conditional* lock on that block and, if it is still the
rightmost leaf, has room, and the new key is greater than the page's first item, inserts without
descending. Only used when tree height is at least `BTREE_FASTPATH_MIN_LEVEL` (2).

Before splitting a full leaf, `_bt_findinsertloc` calls `_bt_delete_or_dedup_one_page`, which tries
in order: delete `LP_DEAD` items, bottom-up deletion, deduplication (section 6).

#### Where (file:line)

- `_bt_doinsert`: `N/nbtinsert.c:104-272`
- `_bt_search_insert` (fastpath): `N/nbtinsert.c:319-388`; fastpath conditions `:356-361`
- `BTREE_FASTPATH_MIN_LEVEL`: `N/nbtinsert.c:31-32`; cache set at `:1445-1447`
- `_bt_findinsertloc`: `N/nbtinsert.c:826-1024`; "avoid split" hook at `:911-918`
- `_bt_delete_or_dedup_one_page`: `N/nbtinsert.c:2727-2827`
- README:491-508 (fastpath rationale)

#### Snippet

`N/nbtinsert.c:356-361`:

```c
			if (P_RIGHTMOST(opaque) &&
				P_ISLEAF(opaque) &&
				!P_IGNORE(opaque) &&
				PageGetFreeSpace(page) > insertstate->itemsz &&
				PageGetMaxOffsetNumber(page) >= P_HIKEY &&
				_bt_compare(rel, insertstate->itup_key, page, P_HIKEY) > 0)
```

(On a rightmost page `P_HIKEY` is the first data item, so the last line compares against the
smallest key on the page.)

`N/nbtinsert.c:915-918`:

```c
		if (PageGetFreeSpace(page) < insertstate->itemsz)
			_bt_delete_or_dedup_one_page(rel, heapRel, insertstate, false,
										 checkingunique, uniquedup,
										 indexUnchanged);
```

### 4.2 Unique checks

#### What it does

Uniqueness is enforced by a page lock, not by a key lock. For a unique insert the scankey's
`scantid` is cleared so the descent lands on the *first* leaf page where an equal key could be
(`N/nbtinsert.c:118-124`). The inserter holds that page's write lock while it scans all equal
index tuples and, for each TID, asks the table whether a live row exists
(`table_fetch_tid` with a dirty snapshot). Outcomes:

- no live conflicting row: proceed; restore `scantid` and insert at the TID-ordered position
- conflicting row whose inserting/deleting transaction is still in progress: release the page
  lock, wait for that transaction, then **restart the whole search** (`goto search`)
- committed live conflict: raise `duplicate key value violates unique constraint`

Because equal keys are ordered by TID and may spill to the next page, the check can continue onto
the right sibling (read-locked) when the new key equals the page's high key
(`N/nbtinsert.c:732-760`).

Index tuples whose heap row is dead to everyone are marked `LP_DEAD` in passing
(`N/nbtinsert.c:700-707`), so the unique check doubles as garbage detection.

NULLs: with default NULLS DISTINCT semantics a key containing NULL skips the unique check
entirely (`N/nbtinsert.c:125-141`).

#### Where (file:line)

- Protocol explanation: `N/nbtinsert.c:166-204`
- `_bt_check_unique`: `N/nbtinsert.c:410-788`
- Wait-and-retry: `N/nbtinsert.c:209-235`
- Error report: `N/nbtinsert.c:667-670`

#### Snippet

`N/nbtinsert.c:185-193`:

```
	 * NOTE: obviously, _bt_check_unique can only detect keys that are already
	 * in the index; so it cannot defend against concurrent insertions of the
	 * same key.  We protect against that by means of holding a write lock on
	 * the first page the value could be on, with omitted/-inf value for the
	 * implicit heap TID tiebreaker attribute.  Any other would-be inserter of
	 * the same key must acquire a write lock on the same page, so only one
	 * would-be inserter can be making the check at one time.
```

`N/nbtinsert.c:216-234` (trimmed):

```c
		if (unlikely(TransactionIdIsValid(xwait)))
		{
			/* Have to wait for the other guy ... */
			_bt_relbuf(rel, insertstate.buf);
			insertstate.buf = InvalidBuffer;
			...
				XactLockTableWait(xwait, rel, &itup->t_tid, XLTW_InsertIndex);
			/* start over... */
			if (stack)
				_bt_freestack(stack);
			goto search;
		}
```

### 4.3 `_bt_insertonpg` and `_bt_split`

#### What it does

`_bt_insertonpg` handles both leaf inserts and downlink inserts on internal pages (it is
recursive via `_bt_insert_parent`). If the item fits it adds it inside a critical section and
writes one WAL record. Otherwise it calls `_bt_split`.

`_bt_split` steps (all verified in source order):

1. Choose the split point with `_bt_findsplitloc` (`:1565`). The result is `firstrightoff` plus
   `newitemonleft`; think of it as a point *between* two tuples on an imaginary page that already
   contains the new item.
2. Build the new **left** page in a private temp buffer, not in the shared buffer (`:1568-1570`).
   Set `BTP_INCOMPLETE_SPLIT` on it (`:1580`).
3. Compute the left page's new high key:
   - leaf: `_bt_truncate(lastleft, firstright)` (suffix truncation, `:1680`)
   - internal: `firstright` itself, untruncated (`:1711`)
4. Only now allocate the new right page with `_bt_allocbuf` (`:1739`): this is "the last point
   where splitting the page may fail" (`:1527-1532`), so a failure before it leaves no trace.
   The right page is also assembled in a temp copy.
5. Right page gets the original page's old high key (if not rightmost) (`:1783-1800`).
6. Distribute items left/right, inserting the new item on the way (`:1817-1903`). On an internal
   split the first data item on the right page is truncated to a minus-infinity item by
   `_bt_pgaddtup(..., newfirstdataitem=true)`.
7. Lock the old right sibling (to fix its left link) (`:1910-1912`).
8. `START_CRIT_SECTION` (`:1950`): memcpy the temp left page over the original buffer
   (`:1959`), copy the right page into its buffer (`:1968-1969`), update the old right sibling's
   `btpo_prev` (`:1977`), clear the *child's* `INCOMPLETE_SPLIT` if this is an internal split
   (`:1985-1992`), write one WAL record (`:1995-2082`), set LSNs, end critical section.
9. Return the right buffer; both halves stay write-locked.

"The algorithm requires that the left page never move during a split" (`:1954-1955`): the left
half keeps the original block number, so existing downlinks and left neighbours' right links stay
valid.

Internal split conceptually splits *inside* a pivot tuple: its key goes up/left as the left page's
high key, its downlink becomes the minus-infinity first item on the right
(`N/nbtinsert.c:1701-1709`, README:1053-1060).

#### Where (file:line)

- `_bt_insertonpg`: `N/nbtinsert.c:1116-1457`; split branch `:1223-1262`; no-split branch
  `:1263-1448`
- `_bt_split`: `N/nbtinsert.c:1486-2109`
- `_bt_pgaddtup`: `N/nbtinsert.c:2675-2697`

#### Snippet

`N/nbtinsert.c:1577-1583`:

```c
	lopaque->btpo_flags = oopaque->btpo_flags;
	lopaque->btpo_flags &= ~(BTP_ROOT | BTP_SPLIT_END | BTP_HAS_GARBAGE);
	/* set flag in leftpage indicating that rightpage has no downlink yet */
	lopaque->btpo_flags |= BTP_INCOMPLETE_SPLIT;
	lopaque->btpo_prev = oopaque->btpo_prev;
	/* handle btpo_next after rightpage buffer acquired */
	lopaque->btpo_level = oopaque->btpo_level;
```

`N/nbtinsert.c:1760-1772` (sibling links):

```c
	lopaque->btpo_next = rightpagenumber;
	lopaque->btpo_cycleid = _bt_vacuum_cycleid(rel);
	...
	ropaque->btpo_prev = origpagenumber;
	ropaque->btpo_next = oopaque->btpo_next;
	ropaque->btpo_level = oopaque->btpo_level;
	ropaque->btpo_cycleid = lopaque->btpo_cycleid;
```

`N/nbtinsert.c:1950-1959` (trimmed):

```c
	START_CRIT_SECTION();
	/*
	 * By here, the original data page has been split into two new halves, and
	 * these are correct.  The algorithm requires that the left page never
	 * move during a split, so we copy the new left page back on top of the
	 * original. ...
	 */
	memcpy(origpage, leftpage, BLCKSZ);
```

`N/nbtinsert.c:2684-2691` (minus-infinity truncation on internal right page):

```c
	if (newfirstdataitem)
	{
		trunctuple = *itup;
		trunctuple.t_info = sizeof(IndexTupleData);
		BTreeTupleSetNAtts(&trunctuple, 0, false);
		itup = &trunctuple;
		itemsize = sizeof(IndexTupleData);
	}
```

### 4.4 Inserting the downlink, incomplete-split flag, root split

#### What it does

After `_bt_split`, `_bt_insert_parent` completes the split in a **second, separate atomic
action**:

- New downlink tuple = copy of the left page's high key with its downlink set to the right page's
  block number (`:2206-2212`). The high key of the left page is "a strict lower bound for new
  right page".
- Parent is re-found with `_bt_getstackbuf(stack, leftblk)`: start at the remembered
  (block, offset), scan the page for a pivot whose downlink equals the left child's block number
  (right of the remembered offset first, then left), and if not found move right along the parent
  level (`:2348-2453`). It also finishes any incomplete split it meets on the parent level
  (`:2368-2372`).
- The new downlink goes at `stack->bts_offset + 1`, immediately after the left child's downlink
  (`:2247-2249`).
- Inserting it clears `BTP_INCOMPLETE_SPLIT` on the left child in the same critical section and
  the same WAL record (`:1320-1328`, `:1360-1361`).
- If the parent is full this recurses: `_bt_insertonpg` -> `_bt_split` -> `_bt_insert_parent`.

Incomplete splits: if the process dies (or errors, e.g. out of disk) between the two actions, the
right page has no downlink. Searches still work because of the right link. The left page carries
`BTP_INCOMPLETE_SPLIT`; the *next writer* that passes through finishes the split
(`_bt_moveright` with `forupdate`, `N/nbtsearch.c:304-322`; `_bt_stepright`
`N/nbtinsert.c:1065-1070`; `_bt_getstackbuf` `:2368-2372`). Readers never do, to keep reads
read-only (README:652-655). VACUUM normally does not either, to avoid needing disk space
(README:656-664).

Root split (`isroot`): `_bt_newlevel` allocates a new root, locks the metapage, and builds a root
with exactly two items: a minus-infinity pivot pointing to the old root (left half), and a copy of
the left half's high key pointing to the right half. Metapage `btm_root`, `btm_level`,
`btm_fastroot`, `btm_fastlevel` are updated and the left child's incomplete-split flag is cleared,
all in one WAL record (`XLOG_BTREE_NEWROOT`).

If the stack is empty but the page is no longer the root (someone else already built a level
above), the code finds the leftmost page of the level above with `_bt_get_endpoint` and uses a
fake stack (`:2174-2204`).

Splitting a non-root page that is alone on its level (possible when it is the fast root) also
updates the fast root in the metapage as part of the parent insert (`:1277-1292`, `:1306-1314`).

#### Where (file:line)

- `_bt_insert_parent`: `N/nbtinsert.c:2127-2254`
- `_bt_finish_split`: `N/nbtinsert.c:2269-2315`
- `_bt_getstackbuf`: `N/nbtinsert.c:2348-2453`
- `_bt_newlevel`: `N/nbtinsert.c:2489-2655`
- README:642-700 (incomplete split design), README:112-137 (root split, re-descending)

#### Snippet

`N/nbtinsert.c:2206-2212`:

```c
		/* get high key from left, a strict lower bound for new right page */
		ritem = (IndexTuple) PageGetItem(page,
										 PageGetItemId(page, P_HIKEY));

		/* form an index tuple that points at the new right page */
		new_item = CopyIndexTuple(ritem);
		BTreeTupleSetDownLink(new_item, rbknum);
```

`N/nbtinsert.c:2412-2418` (re-find by block number):

```c
				if (BTreeTupleGetDownLink(item) == child)
				{
					/* Return accurate pointer to where link is now */
					stack->bts_blkno = blkno;
					stack->bts_offset = offnum;
					return buf;
				}
```

`N/nbtinsert.c:2555-2566` (new root):

```c
	rootopaque = BTPageGetOpaque(rootpage);
	rootopaque->btpo_prev = rootopaque->btpo_next = P_NONE;
	rootopaque->btpo_flags = BTP_ROOT;
	rootopaque->btpo_level =
		(BTPageGetOpaque(lpage))->btpo_level + 1;
	rootopaque->btpo_cycleid = 0;

	/* update metapage data */
	metad->btm_root = rootblknum;
	metad->btm_level = rootopaque->btpo_level;
	metad->btm_fastroot = rootblknum;
	metad->btm_fastlevel = rootopaque->btpo_level;
```

README:666-672:

```
To identify missing downlinks, when a page is split, the left page is
flagged to indicate that the split is not yet complete (INCOMPLETE_SPLIT).
When the downlink is inserted to the parent, the flag is cleared atomically
with the insertion.  The child page is kept locked until the insertion in
the parent is finished and the flag in the child cleared, but can be
released immediately after that, before recursing up the tree if the parent
also needs to be split.
```

### Teaching idea (for all of section 4)

- Chapter "A split is two small transactions, not one big one". Step-through animation with four
  frames: (1) full leaf; (2) left+right exist, linked, left flagged INCOMPLETE, parent unchanged;
  (3) parent gets downlink, flag cleared; (4) optional cascade. Pause on frame 2 and run a search
  for a key in the right half to show it still succeeds via the right link.
- Rust/Zig exercise: implement `split(page) -> (sep_key, right_id)` that builds both halves in
  scratch buffers and only then overwrites the original; inject a failure before the overwrite
  and assert the tree is unchanged.
- Exercise: implement `find_parent(stack, child_id)` that tolerates the parent having split,
  matching on child id rather than on key.
- Root split deserves its own small animation: the root never moves "up"; a new page is created
  above and the metapage pointer flips. Emphasise that levels are numbered from the leaves.
- Uniqueness sidebar: "the lock that enforces UNIQUE is the write lock on the first leaf page the
  key could be on". Good place to explain why the key is searched without the TID first.

---

## 5. Choosing split points (`nbtsplitloc.c`)

### What it does

`_bt_findsplitloc` enumerates every legal split point (each gap between adjacent items, with the
new item imagined in place), computes the free space each side would have, and then picks one in
two phases: first restrict to an "interval" of candidates that are acceptably balanced, then pick
the candidate in that interval with the lowest *penalty*.

Space accounting per candidate (`_bt_recsplitloc`): the first-right tuple is charged to **both**
sides because a copy of it becomes the left page's high key; on leaves an extra
`MAXALIGN(sizeof(ItemPointerData))` is charged to the left side as the worst case of having to
append a heap TID; on internal pages the right side gets credit because the first-right key is
truncated to a bare downlink.

Target balance ("delta"):

- **Rightmost page**: weight the split so the left page ends up `fillfactor`% full (leaf default
  90, internal fixed 70). This is the append-only optimisation: with ever-increasing keys pages
  end up ~fillfactor full "instead of the 50% full result".
- **Non-rightmost leaf, "split after new item"** (`_bt_afternewitemoff`): for multi-column
  indexes with fixed-width tuples, if the new item looks like part of a localized ascending run
  (e.g. `(customer_id, order_no)` where each customer's orders ascend), split right after the new
  item or apply leaf fillfactor. Detected using equal leading attribute(s) and heap-TID adjacency
  with the previous tuple.
- **Otherwise**: 50:50.

Interval: candidates sorted by delta; accept those within a tolerance of the space-optimal one.
`LEAF_SPLIT_DISTANCE 0.050`, `INTERNAL_SPLIT_DISTANCE 0.075` (fractions of the page's item
space); "about 10% of nsplits in the common case" for leaves.

Penalty:

- leaf: number of attributes that must be kept in the new high key to distinguish lastleft from
  firstright (`_bt_keep_natts_fast`). Lower = more suffix truncation. A value of nkeyatts+1 means
  a heap TID must be appended.
- internal: byte size of the firstright pivot (smaller separator goes up to the parent).

Strategies for duplicates (`_bt_strategy`):

- `SPLIT_DEFAULT`: interval contains at least one split between tuples that differ in a user key
  column.
- `SPLIT_MANY_DUPLICATES`: default interval is all duplicates, but somewhere on the page there is
  a boundary between distinct values. Widen the interval to all candidates and take the
  lowest-delta split that does not require a heap TID in the high key, i.e. split at the edge of
  the duplicate group even if that is lopsided.
- `SPLIT_SINGLE_VALUE`: page is entirely one value and looks like the rightmost page for that
  value. Split with left page 96% full (`BTREE_SINGLEVAL_FILLFACTOR`), anticipating that new
  duplicates arrive in ascending TID order to the right.

### Where (file:line)

- Strategy enum and structs: `N/nbtsplitloc.c:22-61`
- `_bt_findsplitloc`: `N/nbtsplitloc.c:129-429`; fill-factor selection `:281-336`; strategy
  handling `:365-417`
- `_bt_recsplitloc`: `N/nbtsplitloc.c:449-560`
- `_bt_deltasortsplits`: `N/nbtsplitloc.c:566-589`
- `_bt_afternewitemoff`: `N/nbtsplitloc.c:630-740`; `_bt_adjacenthtid`: `:749-...`
- `_bt_bestsplitloc`: `N/nbtsplitloc.c:788-848`
- `LEAF_SPLIT_DISTANCE`, `INTERNAL_SPLIT_DISTANCE`: `N/nbtsplitloc.c:850-851`;
  `_bt_defaultinterval`: `:876-921`
- `_bt_strategy`: `N/nbtsplitloc.c:934-1045`
- `_bt_split_penalty`: `N/nbtsplitloc.c:1131-1154`
- Fill factor constants: `nbtree.h:190-203`
- Prose: README:858-902

### Snippet

`N/nbtsplitloc.c:281-292, 330-336` (trimmed):

```c
	if (!state.is_leaf)
	{
		/* fillfactormult only used on rightmost page */
		usemult = state.is_rightmost;
		fillfactormult = BTREE_NONLEAF_FILLFACTOR / 100.0;
	}
	else if (state.is_rightmost)
	{
		/* Rightmost leaf page --  fillfactormult always used */
		usemult = true;
		fillfactormult = leaffillfactor / 100.0;
	}
	...
		/* Other leaf page.  50:50 page split. */
		usemult = false;
```

`N/nbtsplitloc.c:575-582`:

```c
		if (usemult)
			delta = fillfactormult * split->leftfree -
				(1.0 - fillfactormult) * split->rightfree;
		else
			delta = split->leftfree - split->rightfree;

		if (delta < 0)
			delta = -delta;
```

`N/nbtsplitloc.c:524-535` (space accounting):

```c
	if (state->is_leaf)
		leftfree -= (int16) (firstrightsz +
							 MAXALIGN(sizeof(ItemPointerData)) -
							 postingsz);
	else
		leftfree -= (int16) firstrightsz;

	/* account for the new item */
	if (newitemonleft)
		leftfree -= (int16) state->newitemsz;
	else
		rightfree -= (int16) state->newitemsz;
```

`N/nbtsplitloc.c:407-417`:

```c
	else if (strategy == SPLIT_SINGLE_VALUE)
	{
		Assert(state.is_leaf);
		/* Split near the end of the page */
		usemult = true;
		fillfactormult = BTREE_SINGLEVAL_FILLFACTOR / 100.0;
		/* Resort split points with new delta */
		_bt_deltasortsplits(&state, fillfactormult, usemult);
		/* Appending a heap TID is unavoidable, so interval of 1 is fine */
		state.interval = 1;
	}
```

`nbtree.h:200-203`:

```c
#define BTREE_MIN_FILLFACTOR		10
#define BTREE_DEFAULT_FILLFACTOR	90
#define BTREE_NONLEAF_FILLFACTOR	70
#define BTREE_SINGLEVAL_FILLFACTOR	96
```

### Teaching idea

- Chapter "Where to cut": start from the textbook "split in the middle", then show three
  workloads where the middle is wrong, each as an interactive HTML experiment with a slider/toggle:
  1. sequential inserts: 50:50 gives ~50% full pages forever; rightmost 90:10 gives ~90%.
  2. many duplicates: splitting inside a duplicate group forces a TID into the separator;
     splitting at the group edge does not.
  3. one value filling many pages: 96:4.
- Zig/Rust mini-implementation: `candidates()` -> `Vec<{left_free, right_free, penalty}>`, sort by
  `|ff*left_free - (1-ff)*right_free|`, take the first k within tolerance, choose min penalty.
  This is ~60 lines and reproduces the real algorithm's structure.
- Call out the subtle accounting point as a "gotcha" box: the split calculation must include the
  incoming item, "otherwise it is possible to find that the incoming item doesn't fit on the split
  page where it needs to go!" (README:162-164).
