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

---

## 6. Suffix truncation, heap TID tiebreaker, deduplication / posting lists

### 6.1 Heap TID as a tiebreaker column

#### What it does

Since `BTREE_VERSION 4`, the heap TID is logically the last key column of every index
(`heapkeyspace`). Consequences:

- Every leaf tuple is unique in the keyspace, so "all btree keys are unique" (the L&Y
  requirement) holds even for non-unique indexes (README:42-49).
- Duplicates of a user key are stored in TID order, and a specific (key, TID) has exactly one
  correct position. This lets VACUUM-style deletion find a given entry by descent and makes
  splits among duplicates well-defined.
- An insertion scankey carries `scantid`; `_bt_compare` compares it after all user columns.

#### Where (file:line)

- Version notes: `nbtree.h:125-153`
- `scantid` semantics: `nbtree.h:782-788`
- TID comparison in `_bt_compare`: `N/nbtsearch.c:797-857`
- `BTreeTupleGetHeapTID` (handles pivot / posting / plain): `nbtree.h:640-657`

#### Snippet

`N/nbtsearch.c:847-857` (posting list tuples compare as a TID *range*):

```c
	result = ItemPointerCompare(key->scantid, heapTid);
	if (result <= 0 || !BTreeTupleIsPosting(itup))
		return result;
	else
	{
		result = ItemPointerCompare(key->scantid,
									BTreeTupleGetMaxHeapTID(itup));
		if (result > 0)
			return 1;
	}
	return 0;
```

### 6.2 Suffix truncation of pivot tuples

#### What it does

When a **leaf** page splits, the new high key for the left page (which is then copied up as the
separator/downlink in the parent) does not need to be a full tuple. It only needs to satisfy
`lastleft <= highkey < firstright`. `_bt_truncate` keeps the attributes of `firstright` up to and
including the first one that differs from `lastleft`, and drops the rest. Dropped attributes read
as minus infinity. INCLUDE (non-key) columns are always dropped from pivots.

If lastleft and firstright are equal on all user key columns, nothing can be truncated and a heap
TID must be appended to the pivot; the code uses lastleft's (max) TID, which is the L&Y choice of
"high key = last item on the left".

Truncation is only whole-attribute (no prefix-of-a-string truncation); README:851-856 notes that
would be a possible extension.

Never done on internal page splits: separators above the leaf level are copied verbatim from the
level below, because there must be an unbroken "seam" of identical separators at every level
(`N/nbtinsert.c:1685-1699`).

Benefits (README:871-876): smaller pivots, so higher fan-out and later internal splits; and
less-restrictive separators.

#### Where (file:line)

- `_bt_truncate`: `N/nbtutils.c:691-823`
- `_bt_keep_natts` (uses opclass comparison): `N/nbtutils.c:836-886`
- `_bt_keep_natts_fast` (bitwise datum equality, used for split-point penalty and dedup):
  `N/nbtutils.c:910-941`
- Caller in split: `N/nbtinsert.c:1657-1682`; internal case `:1683-1712`
- Caller in bulk build: `N/nbtsort.c:905-946`
- Pivot attribute count stored in `t_tid` offset: `nbtree.h:595-611`
- Prose: README:823-902
- Size limit that reserves room for an appended TID: `BTMaxItemSize`, `nbtree.h:165-173`

#### Snippet

`N/nbtutils.c:709-718, 737-741`:

```c
	/* Determine how many attributes must be kept in truncated tuple */
	keepnatts = _bt_keep_natts(rel, lastleft, firstright, itup_key);
	...
	pivot = index_truncate_tuple(itupdesc, firstright,
								 Min(keepnatts, nkeyatts));
	...
	if (keepnatts <= nkeyatts)
	{
		BTreeTupleSetNAtts(pivot, keepnatts, false);
		return pivot;
	}
```

`N/nbtutils.c:853-876` (trimmed):

```c
	scankey = itup_key->scankeys;
	keepnatts = 1;
	for (int attnum = 1; attnum <= nkeyatts; attnum++, scankey++)
	{
		datum1 = index_getattr(lastleft, attnum, itupdesc, &isNull1);
		datum2 = index_getattr(firstright, attnum, itupdesc, &isNull2);
		if (isNull1 != isNull2)
			break;
		if (!isNull1 &&
			DatumGetInt32(FunctionCall2Coll(&scankey->sk_func,
											scankey->sk_collation,
											datum1, datum2)) != 0)
			break;
		keepnatts++;
	}
```

`N/nbtutils.c:771-778`:

```c
	/*
	 * Lehman & Yao use lastleft as the leaf high key in all cases, but don't
	 * consider suffix truncation.  It seems like a good idea to follow that
	 * example in cases where no truncation takes place -- use lastleft's heap
	 * TID.  (This is also the closest value to negative infinity that's
	 * legally usable.)
	 */
	ItemPointerCopy(BTreeTupleGetMaxHeapTID(lastleft), pivotheaptid);
```

### 6.3 Deduplication and posting lists

#### What it does

A **posting list tuple** stores one copy of the key followed by a sorted array of heap TIDs. It
is a purely physical compression of N equal leaf tuples: "Deduplication alters the physical
representation of tuples without changing the logical contents of the index" (README:910-912).

Key design decisions (README:904-948):

- **Lazy**: a deduplication pass runs only when a leaf page is full and would otherwise split,
  after LP_DEAD items were removed and (if applicable) bottom-up deletion was tried.
- One pass rewrites the whole page into a temp page, merging adjacent equal tuples, then swaps it
  in and writes one `XLOG_BTREE_DEDUP` record containing only an array of
  `(baseoff, nitems)` intervals (`nbtree.h:852-856`), not the tuples.
- Only safe when equality implies identical bytes for every key column
  (`btm_allequalimage`, `_bt_allequalimage` at `N/nbtutils.c:1175`); the merge test is
  `_bt_keep_natts_fast(...) > nkeyatts`.
- A posting tuple is capped at `Min(BTMaxItemSize / 2, INDEX_SIZE_MASK)` bytes
  (`N/nbtdedup.c:89`).
- TIDs are stored uncompressed (6 bytes each) on purpose; compression would break the "same
  size" assumption of posting list splits and slow down partial deletion (README:931-942).
- In **unique** indexes dedup is used only to buy time for garbage collection, and only when a
  duplicate was actually observed (README:950-988).
- `LP_DEAD` can be set on a posting tuple only when all its TIDs are dead (README:546-548).
  VACUUM can remove a subset of TIDs by rewriting the tuple (`_bt_update_posting`,
  `N/nbtdedup.c:923`).

**Posting list split**: inserting a (key, TID) whose TID falls *inside* the range of an existing
posting list. Instead of growing the posting tuple, the code swaps: the new TID is placed into
the posting list at its sorted position, the posting list's old maximum TID is pushed out, and
that pushed-out TID becomes the tuple that is actually inserted, immediately to the right of the
posting tuple. The posting tuple's size does not change, so page space accounting and split-point
logic need no special case (README:990-1042). Done in the same critical section and WAL record
as the insert (`XLOG_BTREE_INSERT_POST`), and WAL logs the *original* new tuple plus the offset;
redo re-runs `_bt_swap_posting`.

During a page split, a posting list in `firstright` is simply dropped from the new high key (it
is "extra payload that suffix truncation will reliably truncate away", README:924-926;
`N/nbtutils.c:720-731`).

#### Where (file:line)

- Posting tuple format: `nbtree.h:433-459`; accessors `nbtree.h:492-548`
- `_bt_dedup_pass`: `N/nbtdedup.c:58-280`
- `_bt_dedup_save_htid`: `N/nbtdedup.c:485-...`; `_bt_dedup_finish_pending`: `:556-...`
- `_bt_form_posting`: `N/nbtdedup.c:863-911`
- `_bt_swap_posting`: `N/nbtdedup.c:1021-1070`
- `_bt_binsrch_posting` (find offset inside posting list): `N/nbtsearch.c:605`
- Posting split in insert path: `N/nbtinsert.c:1169-1214`, applied at `:1297-1298`
- Single-value strategy for dedup (leave a few tuples unmerged so a 96:4 split works well):
  `N/nbtdedup.c:34-44, 175-198, 821-842`
- Trigger order: `N/nbtinsert.c:2819-2826`
- WAL redo: `btree_xlog_dedup`, `N/nbtxlog.c:454`

#### Snippet

`N/nbtdedup.c:151-159` (merge test, trimmed):

```c
		else if (state->deduplicate &&
				 _bt_keep_natts_fast(rel, state->base, itup) > nkeyatts &&
				 _bt_dedup_save_htid(state, itup))
		{
			/* Tuple is equal to base tuple; its TIDs were saved in state */
		}
```

`N/nbtdedup.c:880-899` (trimmed):

```c
	if (nhtids > 1)
		newsize = MAXALIGN(keysize +
						   nhtids * sizeof(ItemPointerData));
	else
		newsize = keysize;
	itup = palloc0(newsize);
	memcpy(itup, base, keysize);
	itup->t_info &= ~INDEX_SIZE_MASK;
	itup->t_info |= newsize;
	if (nhtids > 1)
	{
		BTreeTupleSetPosting(itup, nhtids, keysize);
		memcpy(BTreeTupleGetPosting(itup), htids,
			   sizeof(ItemPointerData) * nhtids);
	}
```

`N/nbtdedup.c:1052-1063` (posting list split = swap):

```c
	nposting = CopyIndexTuple(oposting);
	replacepos = (char *) BTreeTupleGetPostingN(nposting, postingoff);
	replaceposright = (char *) BTreeTupleGetPostingN(nposting, postingoff + 1);
	nmovebytes = (nhtids - postingoff - 1) * sizeof(ItemPointerData);
	memmove(replaceposright, replacepos, nmovebytes);

	/* Fill the gap at postingoff with TID of new item (original new TID) */
	ItemPointerCopy(&newitem->t_tid, (ItemPointer) replacepos);

	/* Now copy oposting's rightmost/max TID into new item (final new TID) */
	ItemPointerCopy(BTreeTupleGetMaxHeapTID(oposting), &newitem->t_tid);
```

### Teaching idea (section 6)

- Chapter "Separators are not keys": show that an internal key only has to *separate*. Demo with
  a two-column index `(last_name, first_name)`: splitting between `('Smith','Zoe')` and
  `('Stone','Al')` yields pivot `('Stone')`; and for strings mention that PostgreSQL does not
  shorten within an attribute. Rust function `truncate(last_left, first_right) -> Pivot` with the
  three outcomes (k attributes kept / all attributes kept / all + TID).
- Visualization: fan-out counter before/after truncation for a wide composite key.
- Chapter "Duplicates": first show why duplicates break naive B-trees (which page does a
  duplicate go on? how do you find one to delete?), then introduce TID-as-last-column as the fix,
  then posting lists as compression on top. Animation of a leaf page collapsing 30 tuples of
  `status='shipped'` into one tuple with 30 TIDs.
- Posting-list-split puzzle for the reader: "insert TID 15 into a tuple holding [10, 12, 20, 30]
  without changing the tuple's size". The answer ([10, 12, 15, 20] + separate tuple for 30) is a
  nice, small Zig example.

---

## 7. Deletion

### 7.1 LP_DEAD hints and simple deletion

#### What it does

PostgreSQL indexes hold entries for all row versions; there is no synchronous delete from the
index when a row is deleted. Garbage is removed lazily in layers.

Layer 1, **LP_DEAD hints**: when an index scan follows a TID and the table reports the row is
dead to all transactions, the executor sets `kill_prior_tuple`; the scan records the item, and
when it leaves the page `_bt_killitems` sets the `LP_DEAD` bit in the line pointer. This is done
under a *shared* lock and is not WAL-logged (it is a hint). Later scans skip `LP_DEAD` items
(`N/nbtreadpage.c:249`). The unique check sets the same bit (`N/nbtinsert.c:700-707`).

Safety detail: if the scan dropped its pin on the leaf, it only sets hints if the page LSN is
unchanged since it read the page (`N/nbtutils.c:241-245`), because a TID could have been
recycled by VACUUM and reused by an unrelated new tuple (README:474-489).

Layer 2, **simple deletion**: when an insert finds its leaf page full, all `LP_DEAD` items are
physically removed under the exclusive lock already held (`_bt_simpledel_pass`). It also checks
"extra" nearby tuples that point into the same table blocks, since the table access method has
to visit those blocks anyway to compute the WAL record's `snapshotConflictHorizon`.

Because index scans stop "between" pages (they copy all matches off a leaf before releasing the
lock), a marked item "can actually be deleted from the index immediately" without confusing any
scan (README:525-527).

#### Where (file:line)

- README:510-554
- `btgettuple` records killed items: `N/nbtree.c:261-276`
- `_bt_killitems`: `N/nbtutils.c:190-390`; `ItemIdMarkDead` at `:361`; flag at `:378`
- `ItemIdIsDead` / `ItemIdMarkDead`: `itemid.h:113, 179`
- `_bt_delete_or_dedup_one_page`: `N/nbtinsert.c:2727-2827`
- `_bt_simpledel_pass`: `N/nbtinsert.c:2856-...`
- `_bt_delitems_delete_check` / `_bt_delitems_delete` (WAL `XLOG_BTREE_DELETE`):
  `N/nbtpage.c:1523`, `:1292-1377`
- Hot standby ignores LP_DEAD: README:736-746

#### Snippet

`N/nbtutils.c:347-363` (trimmed):

```c
			if (killtuple && !ItemIdIsDead(iid))
			{
				if (!killedsomething)
				{
					if (!BufferBeginSetHintBits(buf))
						goto unlock_page;
				}
				/* found the item/all posting list items */
				ItemIdMarkDead(iid);
				killedsomething = true;
				break;			/* out of inner search loop */
			}
```

`N/nbtinsert.c:2756-2770` (trimmed):

```c
	for (offnum = minoff; offnum <= maxoff; offnum = OffsetNumberNext(offnum))
	{
		ItemId		itemId = PageGetItemId(page, offnum);

		if (ItemIdIsDead(itemId))
			deletable[ndeletable++] = offnum;
	}
	if (ndeletable > 0)
	{
		_bt_simpledel_pass(rel, buffer, heapRel, deletable, ndeletable,
						   insertstate->itup, minoff, maxoff);
```

### 7.2 Bottom-up deletion

#### What it does

Targets "version churn": UPDATEs that do not change the indexed columns still need a new index
entry per row version (when heap-only-tuple updates are not possible). Those entries are
duplicates that soon become garbage. When a leaf is about to split and the executor passed the
`indexUnchanged` hint (or a unique index saw a duplicate), `_bt_bottomupdel_pass` groups the
page's duplicates, hands the candidate TIDs to the table AM, which visits a few of the most
promising table blocks and reports which TIDs are dead; those are deleted. It is heuristic and
may find nothing.

Success criterion is deliberately generous: asks for `Max(BLCKSZ/16, newitemsz)` free space and
returns true if at least `Max(BLCKSZ/24, newitemsz)` was freed.

Order of defences before a leaf split (`N/nbtinsert.c:2766-2826`): simple deletion -> bottom-up
deletion (if hinted) -> deduplication (if enabled and safe) -> split.

#### Where (file:line)

- README:556-618
- `_bt_bottomupdel_pass`: `N/nbtdedup.c:308-423`; thresholds `:358`, `:422`
- Trigger: `N/nbtinsert.c:2819-2821`

#### Snippet

`N/nbtinsert.c:2819-2826`:

```c
	if ((indexUnchanged || uniquedup) &&
		_bt_bottomupdel_pass(rel, buffer, heapRel, insertstate->itemsz))
		return;

	/* Perform deduplication pass (when enabled and index-is-allequalimage) */
	if (BTGetDeduplicateItems(rel) && itup_key->allequalimage)
		_bt_dedup_pass(rel, buffer, insertstate->itup, insertstate->itemsz,
					   (indexUnchanged || uniquedup));
```

`N/nbtdedup.c:358, 422`:

```c
	delstate.bottomupfreespace = Max(BLCKSZ / 16, newitemsz);
	...
	return PageGetExactFreeSpace(page) >= Max(BLCKSZ / 24, newitemsz);
```

### 7.3 VACUUM (bulk delete)

#### What it does

`btbulkdelete` -> `btvacuumscan` reads the index in **physical block order** (block 1 to end),
not in key order. For each leaf page it takes a **cleanup lock** (exclusive lock + no other pins),
calls the callback for each TID ("is this TID dead?"), and deletes dead items / rewrites posting
lists with `_bt_delitems_vacuum`.

Two concurrency problems and their solutions:

1. A concurrent split can move tuples from a not-yet-visited page to a lower-numbered block the
   scan already passed (a recycled page). Solution: **vacuum cycle ID**. Each VACUUM gets a
   16-bit id; any split during it stamps both halves (`btpo_cycleid`,
   `N/nbtinsert.c:1761, 1772`). If VACUUM sees a page stamped with its own id whose right link
   points to a lower block number, it backtracks to that block (`N/nbtree.c:1581-1586`,
   `:1751-1766`). `BTP_SPLIT_END` bounds the chase.
2. Index scans that keep TIDs in local memory must not have those TIDs recycled under them.
   Solution: scans that need protection keep a pin on the leaf while visiting the table; VACUUM
   must get a cleanup lock on **every** leaf page, even ones with nothing to delete
   (README:166-202).

VACUUM also: records already-deleted-and-now-recyclable pages in the free space map
(`N/nbtree.c:1527-1533`), retries half-dead pages (`:1542-1545`), and attempts page deletion on
leaves it emptied (`:1720`, `:1729-1743`).

#### Where (file:line)

- README:166-230
- `btbulkdelete`: `N/nbtree.c:1152-1175`; `btvacuumscan`: `:1270-1431`; `btvacuumpage`:
  `:1445-1780`
- Cleanup lock: `N/nbtree.c:1564-1570`; `_bt_upgradelockbufcleanup` `N/nbtpage.c:1116-1128`;
  `LockBufferForCleanup` `src/backend/storage/buffer/bufmgr.c:6682-6699`
- `_bt_delitems_vacuum` (WAL `XLOG_BTREE_VACUUM`): `N/nbtpage.c:1161-1272`
- Cycle id in opaque: `nbtree.h:45-53`; `MAX_BT_CYCLE_ID`: `nbtree.h:94`

#### Snippet

`N/nbtree.c:1581-1586`:

```c
		if (vstate->cycleid != 0 &&
			opaque->btpo_cycleid == vstate->cycleid &&
			!(opaque->btpo_flags & BTP_SPLIT_END) &&
			!P_RIGHTMOST(opaque) &&
			opaque->btpo_next < scanblkno)
			backtrack_to = opaque->btpo_next;
```

`bufmgr.c:6685-6691`:

```
 * Items may be deleted from a disk page only when the caller (a) holds an
 * exclusive lock on the buffer and (b) has observed that no other backend
 * holds a pin on the buffer.  If there is a pin, then the other backend
 * might have a pointer into the buffer (for example, a heapscan reference
 * to an item --- see README for more details).  It's OK if a pin is added
 * after the cleanup starts, however; the newly-arrived backend will be
 * unable to look at the page until we release the exclusive lock.
```

### 7.4 Page deletion: half-dead, two phases, recycling, FSM; no merging

#### What it does

nbtree **never merges or rebalances** partly full pages. A page is removed only when it is
completely empty, and only by VACUUM. The stated reason (README:235-239): "Merging partly-full
pages would allow better space reuse, but it seems impractical to move existing data items left
or right to make this happen --- a scan moving in the opposite direction might miss the items if
so." Moving items across page boundaries would break the property that scans rely on: "items are
never moved across pre-existing page boundaries" (README:96-98).

Restrictions (`N/nbtpage.c:1906-1908`, README:239-245, 270-277):

- never the rightmost page of a level (so never the root, and height never shrinks)
- page must be an empty leaf, not part of an incomplete split
- the rightmost child of a parent cannot be deleted unless it is the *only* child, in which case
  the parent is deleted with it (and so on upward): a "skinny" subtree, one page per level

Two phases, each its own WAL record / atomic action:

**Phase 1, `_bt_mark_page_halfdead`**: with the leaf locked, lock the parent. In the parent,
overwrite the target's downlink value so that the pivot that used to point at the target now
points at the target's right sibling, and delete the *next* pivot (which was the right sibling's
own entry). Net effect: the target's key range is merged into its right sibling's, with no key
changes needed on either sibling. Mark the leaf `BTP_HALF_DEAD`; reuse its high key slot to stash
the "top parent" block number if a chain of internal pages is being removed. Searches that land
on a half-dead page move right.

**Phase 2, `_bt_unlink_halfdead_page`**: lock left sibling, target, right sibling (left to right),
then metapage if the fast root must change. Set left's `btpo_next` and right's `btpo_prev` to
bypass the target. Mark target `BTP_DELETED` and store `safexid = ReadNextFullTransactionId()`
in the page body. The target's *own* sibling links are left intact so that a scan that was "in
flight" to it can still escape rightward.

**Recycling** is a third, separate step. The deleted page is a tombstone until no scan could
still hold a pointer to it: `BTPageIsRecyclable` checks `GlobalVisCheckRemovableFullXid(safexid)`
(`nbtree.h:291-319`). Only then is it put in the free space map (`RecordFreeIndexPage`), from
where `_bt_allocbuf` hands it to a future split. PostgreSQL 14+ lets the same VACUUM try this at
the end of its scan using an in-memory list (`_bt_pendingfsm_finalize`, README:417-424).
`_bt_allocbuf` re-checks recyclability and uses a *conditional* lock because the FSM is only a
hint (`N/nbtpage.c:862-885`).

Lanin & Shasha's "drain technique" is the cited origin (README:386-392).

#### Where (file:line)

- README:232-328 (deletion), 330-360 (backward scans), 362-381 (fast root), 383-441 (FSM)
- `_bt_pagedel`: `N/nbtpage.c:1811-2080`; eligibility test `:1906-1915`
- `_bt_mark_page_halfdead`: `N/nbtpage.c:2100-2300`; parent surgery `:2229-2237`; flag `:2246`
- `_bt_lock_subtree_parent` (rightmost-child rule, recursion): `N/nbtpage.c:2837-2962`
- `_bt_unlink_halfdead_page`: `N/nbtpage.c:2327-2800`; lock order comment `:2408-2416`; link
  updates `:2631-2637`; `safexid` `:2671-2672`; fast root `:2581-2610, 2675-2681`
- `BTPageSetDeleted`, `BTDeletedPageData`: `nbtree.h:231-258`
- `BTPageIsRecyclable`: `nbtree.h:291-319`
- `_bt_pendingfsm_finalize`: `N/nbtpage.c:3019-3080`
- `_bt_allocbuf`: `N/nbtpage.c:853-973`
- WAL: `XLOG_BTREE_MARK_PAGE_HALFDEAD` (`N/nbtpage.c:2286`), `XLOG_BTREE_UNLINK_PAGE[_META]`
  (`:2737-2740`), `XLOG_BTREE_REUSE_PAGE` (`:938`)

#### Snippet

`N/nbtpage.c:1906-1908`:

```c
		if (P_RIGHTMOST(opaque) || P_ISROOT(opaque) ||
			P_FIRSTDATAKEY(opaque) <= PageGetMaxOffsetNumber(page) ||
			P_INCOMPLETE_SPLIT(opaque))
```

`N/nbtpage.c:2232-2246` (phase 1, trimmed):

```c
	itemid = PageGetItemId(page, poffset);
	itup = (IndexTuple) PageGetItem(page, itemid);
	BTreeTupleSetDownLink(itup, topparentrightsib);

	nextoffset = OffsetNumberNext(poffset);
	PageIndexTupleDelete(page, nextoffset);
	...
	page = BufferGetPage(leafbuf);
	opaque = BTPageGetOpaque(page);
	opaque->btpo_flags |= BTP_HALF_DEAD;
```

`N/nbtpage.c:2408-2410`:

```
	 * We have to lock the pages we need to modify in the standard order:
	 * moving right, then up.  Else we will deadlock against other writers.
```

`nbtree.h:299-316` (trimmed):

```c
	/* Recycling okay iff page is deleted and safexid is old enough */
	opaque = BTPageGetOpaque(page);
	if (P_ISDELETED(opaque))
	{
		FullTransactionId safexid = BTPageGetDeleteXid(page);
		...
		return GlobalVisCheckRemovableFullXid(heaprel, safexid);
	}
	return false;
```

README:319-325:

```
A deleted page cannot be recycled immediately, since there may be other
processes waiting to reference it (ie, search processes that just left the
parent, or scans moving right or left from one of the siblings).  These
processes must be able to observe a deleted page for some time after the
deletion operation, in order to be able to at least recover from it (they
recover by moving right, as with concurrent page splits).
```

### Teaching idea (section 7)

- Chapter "Deleting is harder than inserting". Contrast the textbook algorithm (borrow from
  sibling / merge on underflow) with what a production engine does and why. The single sentence
  to land: with lock-free-ish readers that sit between pages, you may add pages to the right but
  you may not move existing items across page boundaries.
- Four-layer diagram ("garbage pipeline"): hint bit -> simple deletion -> bottom-up deletion ->
  VACUUM; with what lock each needs (shared / exclusive / exclusive / cleanup) and whether it is
  WAL-logged.
- Page-deletion animation as a state machine on one page: `LIVE(empty)` -> `HALF_DEAD` (no
  downlink, still in sibling chain) -> `DELETED` (out of sibling chain, own links intact,
  tombstone with safexid) -> `in FSM` -> reused as right half of a split. For each state show
  what a concurrent forward scan, backward scan and descent do when they hit it.
- Rust/Zig example: implement phase 1 as "redirect my parent entry to my right sibling and delete
  my right sibling's entry" on a simple internal node array; assert the key ranges before/after.
  The trick (key space moves right, no sibling keys change) is surprising and worth an exercise.
- A simplified teaching implementation can use epoch-based reclamation for the tombstone step;
  note that PostgreSQL uses transaction-id horizons for the same purpose.

---

## 8. Bulk loading (`nbtsort.c`)

### What it does

`CREATE INDEX` sorts all index tuples with tuplesort (key columns then TID), then builds the tree
**bottom-up, left to right, in one pass**, writing each page exactly once:

- One `BTPageState` per level, linked leaf -> parent -> ... Each holds the page being filled,
  its future block number, and the page's **low key** (strict lower bound; minus infinity for the
  first page on a level).
- `_bt_buildadd(state, itup)`: if the current page is "full" (hard limit: item does not fit;
  soft limit: free space below the fill-factor target and the page has at least two items), finish
  it:
  1. Allocate the next page on this level.
  2. Move the last item of the old page to the new page as its first item; the old page's copy
     becomes the old page's **high key** (on leaves, suffix-truncated against the previous item).
  3. Insert the old page's low key, with downlink = old page's block, into the parent level by a
     recursive `_bt_buildadd` (creating the parent level on first use).
  4. Remember the old page's high key as the new page's low key; set sibling links; write the old
     page out.
- `_bt_uppershutdown`: at end of input, walk the levels bottom to top, add each level's last page
  to its parent, write it; the top level's single page is the root; write the metapage.
- Fill targets: leaf pages to `fillfactor` (default 90%: stop when free space
  `< BLCKSZ*(100-ff)/100`), internal pages to 70%.
- Deduplication happens inline while loading (posting tuples capped at about 10% of a page,
  `N/nbtsort.c:1307`); not for unique indexes.
- Pages bypass the buffer cache via the bulk-write facility (`smgr_bulk_write`,
  `N/nbtsort.c:643`), which WAL-logs whole pages when required
  (`src/backend/storage/smgr/bulk_write.c:253-273`). No per-tuple WAL, no locks, no splits.
- Slot 1 is reserved for the high key from the start (`btps_lastoff = P_HIKEY`); if the page turns
  out to be rightmost, `_bt_slideleft` shifts the slot array down by one.
- Parallel builds: workers scan and sort, the leader merges and runs the same `_bt_load`
  (`N/nbtsort.c:1399` onward; not studied in detail).

### Where (file:line)

- File header overview: `N/nbtsort.c:3-30`
- `BTPageState`: `N/nbtsort.c:235-245`
- `_bt_leafbuild`: `N/nbtsort.c:541-577`
- `_bt_pagestate` (fill thresholds): `N/nbtsort.c:651-677`
- `_bt_slideleft`: `N/nbtsort.c:688-706`
- `_bt_buildadd`: `N/nbtsort.c:788-1023`; fullness test `:858-859`
- `_bt_uppershutdown`: `N/nbtsort.c:1066-1132`
- `_bt_load`: `N/nbtsort.c:1138-1380`
- `BTGetTargetPageFreeSpace`: `nbtree.h:1133-1134`

### Snippet

`N/nbtsort.c:8-15`:

```
 * We use tuplesort.c to sort the given index tuples into order.
 * Then we scan the index tuples in order and build the btree pages
 * for each level.  We load source tuples into leaf-level pages.
 * Whenever we fill a page at one level, we add a link to it to its
 * parent level (starting a new parent level if necessary).  When
 * done, we write out each final page on each level, adding it to
 * its parent level.  When we have only one page on a level, it must be
 * the root -- it can be attached to the btree metapage and we are done.
```

`N/nbtsort.c:668-671`:

```c
	if (level > 0)
		state->btps_full = (BLCKSZ * (100 - BTREE_NONLEAF_FILLFACTOR) / 100);
	else
		state->btps_full = BTGetTargetPageFreeSpace(wstate->index);
```

`N/nbtsort.c:858-859`:

```c
	if (pgspc < itupsz + (isleaf ? MAXALIGN(sizeof(ItemPointerData)) : 0) ||
		(pgspc + last_truncextra < state->btps_full && last_off > P_FIRSTKEY))
```

`N/nbtsort.c:952-969` (trimmed):

```c
		if (state->btps_next == NULL)
			state->btps_next = _bt_pagestate(wstate, state->btps_level + 1);
		...
		BTreeTupleSetDownLink(state->btps_lowkey, oblkno);
		_bt_buildadd(wstate, state->btps_next, state->btps_lowkey, 0);
		pfree(state->btps_lowkey);

		/*
		 * Save a copy of the high key from the old page.  It is also the low
		 * key for the new page.
		 */
		state->btps_lowkey = CopyIndexTuple(oitup);
```

Why not 100% full (`N/nbtsort.c:17-24`): "then *any* insertion would cause a split (and not only
of the leaf page; the need for a split would cascade right up the tree)".

### Teaching idea

- Chapter "Building a tree from sorted data": the cleanest B-tree algorithm in the whole code
  base and a good *early* chapter after page layout, because it needs no splits and no
  concurrency. ~80 lines of Zig/Rust: `struct Level { page, low_key, next: ?*Level }` and a
  recursive `add(level, item)`.
- Animation: a conveyor of sorted keys filling the leftmost leaf; when it reaches 90% a new leaf
  appears to its right and one entry pops up into the level above; periodically the level above
  fills to 70% and pops an entry further up. Final frame: `uppershutdown` zipping the right spine
  closed and writing the metapage.
- Comparison experiment for the guide: N sorted inserts via top-down insert (with and without the
  rightmost-split optimisation) vs bulk load; plot page count and average fill.
- Point out that "low key of page i+1 == high key of page i == separator in the parent" is visible
  directly in this code.

---

## 9. Range scans: sibling links, forward/backward, array keys, skip scan

### 9.1 Forward and backward scans

#### What it does

A scan descends once (`_bt_first`), then walks the leaf level via sibling links, never touching
internal pages again. It processes **one whole leaf page at a time**: under a shared lock,
`_bt_readpage` evaluates the scan keys against every tuple and copies matching TIDs (expanding
posting lists) into backend-local `so->currPos.items[]`, along with the page's `prevPage` /
`nextPage` links as of that moment. Then the lock is dropped. Tuples are returned to the executor
from the local array with no index lock held (README:88-104).

Remembering the right link at read time matters: "if we move right to the current right-link then
we'd re-scan any items moved by a page split" (README:99-101).

Stopping: scan keys are marked "required" in a direction (`SK_BT_REQFWD` / `SK_BT_REQBKWD`); when
a required key fails, `continuescan` is set false and `moreRight` / `moreLeft` cleared. The page
high key is also checked so a scan can often stop without visiting the next page.

Start position (`_bt_first`): the search keys are turned into an insertion scankey with
`nextkey`/`backward` chosen by strategy (e.g. `>=` -> `nextkey=false`; `>` -> `nextkey=true`,
`N/nbtsearch.c:1486-1502`). With no usable boundary key, `_bt_endpoint` walks down the leftmost
or rightmost edge (`N/nbtsearch.c:2125, 2211`).

Forward step: `_bt_getbuf(nextPage, BT_READ)`; skip pages with `P_IGNORE`.

Backward step is harder because there is no "high key on the left" to validate against, and the
left sibling may have split (new pages appear to *its* right, between it and us) or we may have
been deleted. `_bt_lock_and_validate_left` implements the README's 4-step algorithm: go to the
remembered left link; if that page's right link is not us, walk right up to 4 times looking for
the page whose right link is us; if not found, go back to the original page, and if it is deleted
walk right to a live page and restart from *its* left link.

Pins: a scan either keeps a pin on the current leaf (blocks VACUUM's cleanup lock on that page)
or drops it (`so->dropPin`) and relies on its MVCC snapshot plus the page-LSN check for hint
bits. Index-only scans cannot drop the pin (README:443-472; `N/nbtree.c:423-425`).

#### Where (file:line)

- README:70-110, 330-360
- `_bt_first`: `N/nbtsearch.c:884-1576`
- `_bt_next`: `N/nbtsearch.c:1593`; `_bt_steppage`: `:1654-1731`; `_bt_readnextpage`:
  `:1846-1964`
- `_bt_lock_and_validate_left`: `N/nbtsearch.c:1987-2115`; the "4 tries" limit at `:2029`
- `_bt_readpage`: `N/nbtreadpage.c:134-...`; `_bt_saveitem`: `:1033`; LP_DEAD skip: `:249, :405`
- `BTScanPosItem`, `BTScanPosData`: `nbtree.h:955-1000`
- `_bt_drop_lock_and_maybe_pin`: `N/nbtsearch.c:56-75`

#### Snippet

`N/nbtsearch.c:1715-1719`:

```c
	if (ScanDirectionIsForward(dir))
		blkno = so->currPos.nextPage;
	else
		blkno = so->currPos.prevPage;
	lastcurrblkno = so->currPos.currPage;
```

`N/nbtsearch.c:2021-2030` (trimmed):

```c
		for (;;)
		{
			if (likely(!P_ISDELETED(opaque) &&
					   opaque->btpo_next == lastcurrblkno))
			{
				/* Found desired page, return it */
				return buf;
			}
			if (P_RIGHTMOST(opaque) || ++tries > 4)
				break;
```

README:339-345:

```
0. Remember the page we are on as the "original page".
1. Follow the original page's left-link (we're done if this is zero).
2. If the current page is live and its right-link matches the "original
   page", we are done.
3. Otherwise, move right one or more times looking for a live page whose
   right-link matches the "original page".  If found, we are done.
```

`nbtree.h:962-970` (trimmed):

```c
typedef struct BTScanPosData
{
	Buffer		buf;			/* currPage buf (invalid means unpinned) */
	/* page details as of the saved position's call to _bt_readpage */
	BlockNumber currPage;		/* page referenced by items array */
	BlockNumber prevPage;		/* currPage's left link */
	BlockNumber nextPage;		/* currPage's right link */
	XLogRecPtr	lsn;			/* currPage's LSN (when so->dropPin) */
```

### 9.2 Array keys (`IN` lists) and skip scan

#### What it does

Both are present in this commit.

- **SAOP array keys**: `WHERE a IN (1, 5, 9)` becomes an equality scan key with an array of
  values. The scan keeps a "current element" per array; as it reads leaf tuples in order it
  advances the arrays to match (`_bt_advance_array_keys`). Array keys "ratchet forwards": they
  only advance as the scan advances through the key space. If the next matching value is likely on
  the same or next leaf page the scan just keeps reading; otherwise it ends the current
  "primitive index scan" and starts a new descent (`so->needPrimScan`, loop in `btgettuple`).
- **Skip scan** (comment says new in Postgres 18): for an index on `(x, y)` and `WHERE y = 4`,
  preprocessing invents a *skip array* on `x`, logically `x = ANY(every possible x)`. The array
  has no stored elements (`num_elems = -1`); its "current element" is taken from the index
  itself, and it is incremented/decremented either via an opclass "skip support" routine or by
  using sentinel states (`SK_BT_MINVAL`, `SK_BT_MAXVAL`, `SK_BT_NEXT`, `SK_BT_PRIOR`) that make
  `_bt_first` reposition to "the first tuple > current x". Inequalities on `x` become the
  array's `low_compare` / `high_compare`.

Both reuse the same machinery: repeated descents, each one a normal `_bt_search`, chosen
adaptively against simply continuing along the leaf level.

#### Where (file:line)

- `BTArrayKeyInfo`: `nbtree.h:1034-1051`; scan state flags `nbtree.h:1060-1066`
- Flags: `nbtree.h:1104-1112`
- Preprocessing overview incl. skip arrays: `N/nbtpreprocesskeys.c:106-137`
- `_bt_advance_array_keys`: `N/nbtreadpage.c:2119-2180` (header comment), body from `:2180`
- `_bt_array_increment` / `_bt_array_decrement`: `N/nbtreadpage.c:2934, 3067`
- Primitive scan loop: `N/nbtree.c:246-288`; `_bt_start_prim_scan`: `N/nbtree.c:651-...`
- Positioning rules with skip arrays in `_bt_first`: `N/nbtsearch.c:984-1004`

#### Snippet

`N/nbtpreprocesskeys.c:130-137`:

```
 * If we never generated skip array scan keys, it would be possible for "gaps"
 * to appear that make it unsafe to mark any subsequent input scan keys
 * (copied from scan->keyData[]) as required to continue the scan.  Prior to
 * Postgres 18, a qual like "WHERE y = 4" always resulted in a full scan.
 * This qual now becomes "WHERE x = ANY('{every possible x value}') and y = 4"
 * on output.  In other words, preprocessing now adds a skip array on "x".
 * This has the potential to be much more efficient than a full index scan
 * (though it behaves like a full scan when there's many distinct "x" values).
```

`N/nbtree.c:246-288` (trimmed):

```c
	/* Each loop iteration performs another primitive index scan */
	do
	{
		if (!BTScanPosIsValid(so->currPos))
			res = _bt_first(scan, dir);
		else
			res = _bt_next(scan, dir);
		if (res)
			break;
	} while (so->numArrayKeys && _bt_start_prim_scan(scan));
```

`nbtree.h:1106-1112`:

```c
#define SK_BT_SKIP		0x00040000	/* skip array on column without input = */

/* SK_BT_SKIP-only flags (set and unset by array advancement) */
#define SK_BT_MINVAL	0x00080000	/* invalid sk_argument, use low_compare */
#define SK_BT_MAXVAL	0x00100000	/* invalid sk_argument, use high_compare */
#define SK_BT_NEXT		0x00200000	/* positions the scan > sk_argument */
#define SK_BT_PRIOR		0x00400000	/* positions the scan < sk_argument */
```

### Teaching idea (section 9)

- Chapter "Range scans": first the easy forward iterator in Rust (`struct Cursor { page, items:
  Vec<Tid>, next_page }`) that copies a page's matches and releases the latch; test that
  concurrent inserts/splits to the right never cause a missed or duplicated key, and explain why
  the saved `next_page` is the one to use.
- Animation for backward scan: scanner on page C moving left to B; meanwhile B splits into B, B'.
  Scanner lands on B, sees `B.next != C`, steps right to B', sees `B'.next == C`, done. A second
  scenario where C itself was deleted.
- "Advanced" sidebar: skip scan as "many small range scans glued together". Interactive: index on
  `(country, city)`, query `city = 'Paris'`; highlight each re-descent to "first key > current
  country". Slider for number of distinct `country` values shows when it degenerates into a full
  scan.
- Keep array-key advancement out of the core chapters; it is intricate (the function header alone
  is ~60 lines) and not needed to understand B-trees.

---

## 10. WAL and crash safety

### What it does

General contract: every change to a shared page happens inside a critical section in this order:
modify page(s) in shared buffers -> `MarkBufferDirty` -> build and insert one WAL record that
*registers* each modified buffer -> stamp each page with the record's LSN -> end critical section
-> unlock. The buffer manager will not write a dirty page to disk until WAL is flushed up to the
page's LSN ("thou shalt write xlog before data", `bufpage.h:150-155`). An error inside a critical
section is escalated to PANIC, so a half-applied multi-page change can never be observed after
recovery.

"A single WAL entry is effectively an atomic action --- we can redo it from the log if it fails
to complete" (README:625-626).

**Full-page images**: when a registered page is modified for the first time after a checkpoint
(`page_lsn <= RedoRecPtr`), XLogInsert includes a full image of the page in the record instead of
(or in addition to) the delta; this protects against torn pages. `REGBUF_STANDARD` lets it omit
the free-space "hole" between `pd_lower` and `pd_upper`. `REGBUF_WILL_INIT` means redo rebuilds
the page from scratch so no image is needed. This is why `_bt_split` copies the original LSN onto
its temp left page (`N/nbtinsert.c:1586-1591`).

What a **leaf split** writes (one record, `XLOG_BTREE_SPLIT_L` or `_R` depending on which side
the new item went):

| Block ref | Page | Flags | Payload |
|---|---|---|---|
| 0 | original / left page | `REGBUF_STANDARD` | new item (only if it went left), then the left page's new high key |
| 1 | new right page | `REGBUF_WILL_INIT` | all of the right page's tuples (the bytes from `pd_upper` to `pd_special`) |
| 2 | old right sibling (if any) | `REGBUF_STANDARD` | none (only its `btpo_prev` changes) |
| 3 | child whose split this insert completes (internal splits only) | `REGBUF_STANDARD` | none (flag clear) |

Main data: `xl_btree_split {level, firstrightoff, newitemoff, postingoff}`.

The left page's contents are *not* logged: redo reconstructs the left half from the existing
on-disk page by keeping items `< firstrightoff`, inserting the new item if needed, and adding the
logged high key (`N/nbtxlog.c:303-423`). The right page is rebuilt from the logged tuples by
`_bt_restore_page`. Redo sets `BTP_INCOMPLETE_SPLIT` on the left page (`N/nbtxlog.c:415`).

Then a **second record** for the parent: `XLOG_BTREE_INSERT_UPPER` (block 0 = parent with the new
downlink tuple, block 1 = left child to clear the incomplete-split flag; optionally block 2 =
metapage -> `XLOG_BTREE_INSERT_META`), or another `SPLIT_L/R` if the parent splits, or
`XLOG_BTREE_NEWROOT` for a root split (block 0 = new root `WILL_INIT` with its two tuples, block
1 = left child, block 2 = metapage).

Atomicity of multi-page operations, summarised (README:620-700):

| Operation | WAL records | State if crash between records |
|---|---|---|
| Insert, no split | 1 | n/a |
| Split | 1 for the level (left + right + right sibling's left link), then 1 for the parent (recursively) | right page has no downlink; left page flagged `INCOMPLETE_SPLIT`; searches work via right link; next inserter finishes it |
| Root split | split record, then `NEWROOT` | same as above; old root is still the root per metapage, with a right sibling |
| Page deletion | 1 for mark-half-dead (leaf + parent), then 1 per unlinked page | half-dead leaf remains; searches skip it; next VACUUM finishes |
| Dedup pass | 1 (intervals only) | n/a |
| LP_DEAD hint | none (hint; may ride along in a full-page image) | hint lost, harmless |

Before 9.4, recovery tracked and finished incomplete splits at end of recovery; that was replaced
by the flag + lazy completion, which also covers non-crash failures such as out-of-disk during
the parent insert (README:694-700).

Redo locking: split redo releases the three same-level buffers together "so that readers cannot
observe inconsistencies" (`N/nbtxlog.c:444-450`), which matters for hot standby queries. Redo
does not reproduce the parent/child lock coupling (README:712-727).

Unlogged/temporary indexes still need monotonically changing page LSNs for the
drop-pin/LP_DEAD check, so they use fake LSNs (`XLogGetFakeLSN`, e.g. `N/nbtinsert.c:1410`;
README:484-489).

### Where (file:line)

- README:620-770
- Record type list: `nbtxlog.h:27-43`
- `xl_btree_insert`: `nbtxlog.h:79-85`; `xl_btree_split` and block reference docs:
  `nbtxlog.h:88-161`
- Split WAL construction: `N/nbtinsert.c:1994-2084`
- Insert WAL construction: `N/nbtinsert.c:1330-1410`
- New root WAL: `N/nbtinsert.c:2602-2644`
- `btree_xlog_split`: `N/nbtxlog.c:246-451`; `_bt_restore_page`: `:35-...`;
  `_bt_clear_incomplete_split`: `:136-155`; `btree_redo` dispatcher: `:1004`
- FPI decision: `src/backend/access/transam/xloginsert.c:670-700` (`needs_backup = (page_lsn <=
  RedoRecPtr)` at `:698`); hole removal `:738-756`
- `REGBUF_*` flags: `src/include/access/xloginsert.h:32-38`
- `MarkBufferDirty`: `src/backend/storage/buffer/bufmgr.c:3172`

### Snippet

`N/nbtinsert.c:2008-2017`:

```c
		XLogBeginInsert();
		XLogRegisterData(&xlrec, SizeOfBtreeSplit);

		XLogRegisterBuffer(0, buf, REGBUF_STANDARD);
		XLogRegisterBuffer(1, rbuf, REGBUF_WILL_INIT);
		/* Log original right sibling, since we've changed its prev-pointer */
		if (!isrightmost)
			XLogRegisterBuffer(2, sbuf, REGBUF_STANDARD);
		if (!isleaf)
			XLogRegisterBuffer(3, cbuf, REGBUF_STANDARD);
```

`N/nbtinsert.c:2063-2081` (trimmed):

```c
		XLogRegisterBufData(0, lefthighkey,
							MAXALIGN(IndexTupleSize(lefthighkey)));
		...
		XLogRegisterBufData(1,
							(char *) rightpage + ((PageHeader) rightpage)->pd_upper,
							((PageHeader) rightpage)->pd_special - ((PageHeader) rightpage)->pd_upper);

		xlinfo = newitemonleft ? XLOG_BTREE_SPLIT_L : XLOG_BTREE_SPLIT_R;
		recptr = XLogInsert(RM_BTREE_ID, xlinfo);
```

`nbtxlog.h:153-159`:

```c
typedef struct xl_btree_split
{
	uint32		level;			/* tree level of page being split */
	OffsetNumber firstrightoff; /* first origpage item on rightpage */
	OffsetNumber newitemoff;	/* new item's offset */
	uint16		postingoff;		/* offset inside orig posting tuple */
} xl_btree_split;
```

`N/nbtxlog.c:414-418` (redo marks the split incomplete):

```c
		/* Fix opaque fields */
		oopaque->btpo_flags = BTP_INCOMPLETE_SPLIT;
		if (isleaf)
			oopaque->btpo_flags |= BTP_LEAF;
		oopaque->btpo_next = rightpagenumber;
```

README:633-637:

```
An insertion that causes a page split is logged as a single WAL entry for
the changes occurring on the insertion's level --- including update of the
right sibling's left-link --- followed by a second WAL entry for the
insertion on the parent level (which might itself be a page split, requiring
an additional insertion above that, etc).
```

### Teaching idea

- Chapter "Surviving a crash": present the design problem as "a split touches 3-4 pages and the
  parent; you cannot write them atomically". Then the solution in two ideas: (1) make each
  *level's* change one logical log record; (2) make the in-between state a legal tree (the B-link
  right link already guarantees that), and leave a flag so someone finishes the job later.
- Teaching implementation in Rust/Zig: a tiny redo-only WAL with records
  `Insert{page, slot, tuple}`, `Split{left, right, old_right, first_right, high_key,
  right_tuples}`, `InsertUpper{parent, slot, tuple, child_to_unflag}`, `NewRoot{...}`; a crash
  simulator that truncates the log at every record boundary and checks (a) all keys findable,
  (b) a subsequent insert repairs the incomplete split.
- Animation: timeline with two log records; a "crash here" marker that can be dragged between
  them; the tree view shows the flagged left page and the orphan right page reachable only by the
  right link.
- Sidebar on full-page images / torn pages with a single picture: page half old/half new on
  disk, repaired by the image in the first post-checkpoint record.

---

## 11. Concrete numbers

Verified constants:

| Quantity | Value | Where |
|---|---|---|
| Default block size `BLCKSZ` | 8 kB (choices 1,2,4,8,16,32) | `meson_options.txt:5-8` |
| Max page size | 32 kB (15-bit `lp_off`/`lp_len`) | `bufpage.h:180-181` |
| Leaf fill factor (default / min) | 90% / 10% | `nbtree.h:200-201` |
| Internal page fill factor (fixed) | 70% | `nbtree.h:202` |
| "Single value" fill factor | 96% | `nbtree.h:203` |
| Split interval tolerance | 5% leaf, 7.5% internal | `N/nbtsplitloc.c:850-851` |
| Max tuple size rule | 1/3 of page (3 items must fit: high key + 2) | `nbtree.h:155-173`, README:792-796 |
| Pivot attribute count / posting TID count field | 12 bits (`BT_OFFSET_MASK 0x0FFF`) | `nbtree.h:463` |
| Tuple size field | 13 bits (`INDEX_SIZE_MASK 0x1FFF`) | `itup.h:65` |
| Vacuum cycle id | 16 bits, max `0xFF7F` | `nbtree.h:30, 94` |
| Fastpath min tree height | 2 | `N/nbtinsert.c:32` |
| Backward-scan move-right tries | 4 | `N/nbtsearch.c:2029` |
| Posting tuple max size (dedup pass) | `Min(BTMaxItemSize/2, INDEX_SIZE_MASK)` | `N/nbtdedup.c:89` |
| Bottom-up deletion target / success threshold | `BLCKSZ/16` / `BLCKSZ/24` (or new item size) | `N/nbtdedup.c:358, 422` |
| Pre-v4 "getting tired" move-right probability | 0.99 | `N/nbtinsert.c:945-947, 983` |
| Metapage block | 0 | `nbtree.h:149` |
| Current btree version | 4 (min supported 2) | `nbtree.h:151-152` |

Struct sizes **(derived)** from the definitions, assuming a typical 64-bit build with 8-byte
MAXALIGN and the default 8 kB block:

| Thing | Bytes | Basis |
|---|---|---|
| `PageHeaderData` (`SizeOfPageHeaderData`) | 24 | 8 (lsn) + 2+2+2+2+2+2 + 4 (`bufpage.h:184-197`) |
| `ItemIdData` (line pointer) | 4 | 15+2+15 bits (`itemid.h:25-30`) |
| `BTPageOpaqueData` | 16 | 4+4+4+2+2 (`nbtree.h:63-70`) |
| `IndexTupleData` header | 8 | 6-byte TID + 2-byte `t_info` |
| `ItemPointerData` (TID) | 6 | three 16-bit fields (`itemptr.h:36`) |
| Usable bytes per page | 8152 | 8192 - 24 - 16 |
| Leaf tuple, one `int4` or one `int8` key | 16 + 4 line pointer = 20 | MAXALIGN(8+4) = MAXALIGN(8+8) = 16 |
| `BTMaxItemSize` | 2704 | MAXALIGN_DOWN((8192 - MAXALIGN(24+12) - 16)/3) - 8 |
| `MaxTIDsPerBTreePage` | 1358 | (8192 - 24 - 16) / 6 (`nbtree.h:186-188`) |
| `MaxIndexTuplesPerPage` | 408 | (8192 - 24) / (16 + 4) (`itup.h:182-184`) |

Fan-out and height estimates **(derived, not measured)** for a single-integer-key index:

- Leaf page at 100%: about 8152 / 20 = 407 tuples. At the default 90% fill used by bulk build and
  rightmost splits (target free space = 8192 x 10% = 819 bytes): about (8152 - 819) / 20 = 366.
- Internal page: a truncated pivot with one integer key is also 16 + 4 = 20 bytes. At the 70%
  build/rightmost target (free space 2457 bytes): about (8152 - 2457) / 20 = 284 downlinks per
  internal page; at 100%: about 407.
- Freshly built tree capacity with those numbers (leaf 366, internal 284):

  | Levels (incl. leaf) | Approx rows |
  |---|---|
  | 1 (root is a leaf) | up to ~366-407 |
  | 2 | 284 x 366 = ~104,000 |
  | 3 | 284^2 x 366 = ~29.5 million |
  | 4 | 284^3 x 366 = ~8.4 billion |

  So for a small fixed-width key, 3 levels cover tens of millions of rows and 4 levels cover
  billions. Add one more page access for the metapage unless it is cached in the relcache
  (`N/nbtpage.c:360-404`).
- Random (non-rightmost) inserts split 50:50, so steady-state fill is lower than 90%; the source
  cites the classic estimate: "The steady-state load factor for btrees is usually estimated at
  70%" (`N/nbtsort.c:19-20`).
- With deduplication, a leaf holding one distinct value stores 6 bytes per row instead of 20, so
  low-cardinality indexes are roughly 3x smaller **(derived)**; upper bound 1358 TIDs per page.
- Wide keys: the 1/3-page limit means at least 2 data items + high key per page, so worst-case
  fan-out is 2. Suffix truncation exists precisely to keep internal-page fan-out high when leaf
  tuples are wide.

### Teaching idea

- A "numbers" page in the guide with an interactive calculator: page size, key size, fill factor
  -> items per leaf, fan-out, height for N rows. Make the reader predict the height for 1 billion
  rows before revealing it.
- Zig comptime exercise: compute `usable_bytes`, `max_item_size`, `leaf_capacity(key_len)` from
  struct layouts and assert they match the numbers above.

---

## Most important insights for a learner

1. **A B-tree page is a slotted page.** Sort order lives in a small slot array; tuples are
   variable-size and unordered physically. Fan-out is "as many as fit", not a fixed order `m`.
2. **The high key + right link are what make concurrency cheap.** Readers and writers hold one
   page lock at a time while descending. A stale pointer is detected by comparing with the high
   key and repaired by moving right. Splits only ever move data rightward.
3. **A split is two atomic steps, and the intermediate state is a valid tree.** Step 1 creates
   the right sibling (one WAL record for the level). Step 2 inserts the downlink into the parent
   (a second record). A flag on the left page marks "step 2 pending", and any later writer
   completes it. The same idea handles crashes, errors and concurrency.
4. **Internal keys are separators, not copies of data.** They only need to satisfy
   `left <= sep < right`, so they can be truncated. The first key on each internal page is minus
   infinity; a rightmost page's high key is plus infinity.
5. **Every key is unique because the row address is the last key column.** That one decision
   makes duplicates well-ordered, makes separators strict, and enables posting-list compression.
6. **Where you split matters as much as how.** 50:50 is right for random inserts, wrong for
   sequential inserts (use ~90:10 on the rightmost page), and wrong inside a run of duplicates
   (split at the run's edge, or 96:4 when the page is a single value).
7. **Production B-trees do not merge on underflow.** PostgreSQL deletes only completely empty
   pages, in two phases, and keeps the deleted page as a tombstone until no scan can still reach
   it. The price is possible bloat; the gain is that items never move across existing page
   boundaries, which is what lets scans run with almost no locks.
8. **Deletion is garbage collection.** Dead entries are first *hinted* (LP_DEAD, cheap, under a
   shared lock), then physically removed opportunistically right before a page would split, then
   swept by VACUUM. "Try to avoid the split" is a pipeline: delete hinted items -> bottom-up
   deletion -> deduplicate -> split.
9. **Scans work page-at-a-time and stop "between" pages.** Copy all matches from a leaf into
   private memory, remember its sibling links, release the lock. Forward scans are trivial;
   backward scans need a validation loop because splits happen to the right.
10. **Bulk loading is a different, much simpler algorithm.** Sort, then fill pages left to right,
    one open page per level, pushing a separator up whenever a page closes. No splits at all.
11. **Tree height is tiny.** With 8 kB pages and small keys, fan-out is in the hundreds, so 3-4
    levels cover millions to billions of rows; the root and upper levels stay cached.
12. **Lock ordering is the deadlock argument.** Left-to-right on a level, child-before-parent
    going up, metapage last; never hold a lock while going left or down.

## Things that are easy to get wrong

- **Thinking the high key is the largest key on the page.** It is an upper *bound* and is stored
  in slot 1, before the data items. On a leaf it may be greater than every item on the page (after
  truncation) or equal to the last one. Rightmost pages have none, which shifts every slot index
  by one (`P_FIRSTDATAKEY`).
- **Off-by-one in internal-page binary search.** The search finds the first pivot `>=` key and
  then steps *back* one; this only works because the first pivot is forced to compare as minus
  infinity (`N/nbtsearch.c:714-715, 448-450`).
- **Comparing a truncated pivot as if missing attributes were equal.** Missing attributes are
  minus infinity, so a scankey with more attributes is *greater* (`N/nbtsearch.c:794-795`). A
  search for `'foo'` must go right of a pivot `('foo', -inf)`. Backward scans treat this case
  differently (`N/nbtsearch.c:436-446`).
- **Truncating separators during internal page splits.** Only leaf splits create new separator
  values; internal splits must move the existing pivot up unchanged
  (`N/nbtinsert.c:1685-1699`).
- **Forgetting the incoming tuple when choosing the split point**, then discovering it does not
  fit on its half (README:162-164). Also forgetting that the first-right tuple costs space on
  *both* sides (it becomes the left high key).
- **Moving the left half to a new page.** The left half must stay at the original block number;
  only the right half is new (`N/nbtinsert.c:1954-1955`). Otherwise stale downlinks and sibling
  links break.
- **Building the split in place.** PostgreSQL builds both halves in scratch memory and acquires
  the new page as late as possible, so every failure before the critical section leaves the tree
  untouched (`N/nbtinsert.c:1521-1533`).
- **Finding the parent by key or by the remembered offset.** The stack is only a hint; the parent
  may have split or the downlink may have shifted. Re-find by child block number and be ready to
  move right (`N/nbtinsert.c:2348-2453`).
- **Assuming "root" means level 0 or block 1.** Leaves are level 0; the root's block number
  changes on every root split and is found through the metapage; searches actually start at the
  *fast* root, which may be below the true root.
- **Upgrading a read lock to a write lock "atomically".** nbtree unlocks and relocks, then
  re-checks with `_bt_moveright` because the page may have split in between
  (`N/nbtsearch.c:203-213`).
- **Following the *current* right link after processing a leaf.** A scan must follow the right
  link it saw when it read the page, or it will re-read items moved by a later split
  (README:99-101).
- **Walking left like walking right.** Moving left needs the validate-and-move-right loop and a
  fallback for a deleted origin page (README:333-360).
- **Reusing a deleted page immediately.** A reader may still be about to land on it. Deleted
  pages must keep their sibling links and stay unreusable until no such reader can exist
  (README:319-325, 386-401).
- **Deleting the rightmost page of a level, or the rightmost child of a parent that has other
  children.** Both are forbidden; the second would change the parent's key range
  (README:270-277; `N/nbtpage.c:2910-2926`).
- **Treating LP_DEAD as durable or authoritative.** It is an un-logged hint; standbys ignore it;
  a scan that dropped its pin may only set it if the page LSN did not change (README:484-489,
  736-746).
- **Confusing the three kinds of "truncation" in the source**: suffix truncation of new leaf
  high keys (`_bt_truncate`); the minus-infinity first item on internal pages (`_bt_pgaddtup`,
  explicitly "nothing to do with suffix truncation", `N/nbtinsert.c:2672-2673`); and dropping a
  posting list from a high key.
- **Assuming unique indexes contain no duplicates.** Physically they often do (several row
  versions of the same logical row); uniqueness is checked against *live* rows in the table while
  holding the leaf's write lock (`N/nbtinsert.c:166-204`).
- **Assuming VACUUM walks the index in key order.** It scans in physical block order and uses
  the per-page vacuum cycle id to chase tuples moved by concurrent splits (README:204-230).
- **Reading the classic "minimum degree t / at least half full" invariant into nbtree.** There is
  no minimum occupancy invariant here; the only hard rule is that three items must be able to fit
  on a page (hence the 1/3-page tuple limit).

## Coverage notes and limits of this study

- Read in full: `N/README`. Read closely: `nbtinsert.c` (all main functions), `nbtsearch.c`
  (`_bt_search`, `_bt_moveright`, `_bt_binsrch`, `_bt_compare`, scan stepping),
  `nbtsplitloc.c`, `nbtutils.c` (`_bt_truncate`, `_bt_keep_natts*`, `_bt_killitems`),
  `nbtsort.c` (`_bt_buildadd`, `_bt_uppershutdown`), `nbtxlog.c` (`btree_xlog_split`),
  `nbtree.h` (lines 25-830 and scan structs), `bufpage.h`, `itemid.h`.
- Read selectively (code paths confirmed, not every line): `nbtpage.c` page deletion
  (`_bt_unlink_halfdead_page` in particular was read through a filter that kept lock/link/WAL
  lines and comments), `nbtdedup.c`, `nbtree.c` (`btvacuumpage`), `_bt_first`,
  `nbtreadpage.c`, `nbtpreprocesskeys.c`, `xloginsert.c`.
- Not studied: parallel index scan coordination, parallel build internals, `nbtvalidate.c`,
  `nbtcompare.c`, amcheck, the table-AM side of index deletion
  (`heap_index_delete_tuples`), predicate locking.
- Nothing here was executed against a running PostgreSQL; all sizes and capacities in section 11
  marked (derived) are arithmetic from the source definitions.
