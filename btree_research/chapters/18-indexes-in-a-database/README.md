# Chapter 18: Indexes in a database

## What you will learn

- What a database puts into the key and the value of a B+tree to turn it into a table and
  into an index.
- The two ways to store a table: **clustered** (index-organized: the rows are inside the
  primary tree, as in Turso and SQLite) and **heap plus index** (the rows are in an
  unordered heap and every index, the primary key included, stores an address, as in
  Postgres).
- What "going back to the row" costs in each layout, counted in tree descents and row
  fetches.
- How a unique constraint is checked, what a covering (index-only) scan is, and which
  predicates a composite key can answer with one contiguous scan.

Prerequisites: [chapter 07](../07-bplus-trees/README.md) (B+tree, leaf chain, the
tie-breaker idea). Composite keys as byte strings are the subject of
[chapter 11](../11-key-and-record-encoding/README.md); here a composite key is packed into
one `u64`, which needs no encoding theory. Range scans are used in their simplest form;
[chapter 08](../08-range-scans-and-cursors/README.md) treats cursors properly.

## The idea in plain words

A B+tree is a sorted map from a key to a value. A table is a set of rows with several
columns, and you want to find rows by more than one of them. Everything in this chapter
follows from two decisions.

**Decision 1: where do the rows live?**

- *Clustered.* Pick one key, the primary key, and store each whole row as the value in
  that tree. The tree **is** the table. Finding a row by primary key is one descent, and
  the descent ends at the row.
- *Heap.* Put the rows in a pile of pages in arrival order and never move them. A row's
  name is its address, the **TID** (tuple identifier: page number and slot number). No
  tree is special. The primary key is an index like any other.

**Decision 2: what does an index entry point at?** An index on column `c` is a second
tree whose keys are sorted by `c`. Each entry must lead back to its row, so it carries a
**locator**:

- in the clustered layout the locator is the primary key (the row id);
- in the heap layout the locator is the TID.

That is the whole difference, and it decides the cost of the step "back to the row":

| | locator is | following it costs |
|---|---|---|
| clustered | a **key** of the primary tree | one more descent of the primary tree |
| heap | an **address** | one heap page read, no search |

The locator is stored as the *last part of the index key*, not as the value. Chapter 07
introduced this as the tie-breaker: many rows may share one customer, and
(customer, locator) is unique where customer alone is not. So every index key is unique,
equal column values sit next to each other ordered by locator, and one specific entry can
be found by an exact descent. Deleting a row depends on that.

Three more ideas ride on the same structure.

**Unique constraint.** To enforce "no two rows with the same code", search the index for
the code *without* a locator, before inserting. If any entry with that code exists, refuse.
The search is "position at (code, smallest possible locator) and look at the next entry".

**Covering scan.** If the query asks only for columns that are in the index key, the scan
never follows a locator. It is called index-only. Both layouts then do the same work.

**Composite keys and prefixes.** An index on (customer, day) is sorted by customer, then
by day inside one customer. Entries matching `customer = 7` are one contiguous run. So are
those matching `customer = 7 AND day BETWEEN 10 AND 20`. Entries matching `day = 12` alone
are scattered, one small group per customer, and no single range contains them. The rule:
equality on a leading prefix of the columns, optionally followed by a range on the next
column, is one range of the index.

## A worked example by hand

The table of this chapter:

```sql
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer, day, amount, code UNIQUE);
CREATE INDEX by_customer_day ON orders (customer, day);
```

Twelve rows are inserted. Their ids are the canonical keys of chapters 03 to 08, in the
canonical order 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, so with order M = 4 the
clustered primary tree is the tree chapter 07 drew. Customer 7 has five rows:

| id | customer | day | amount | arrival |
|---|---|---|---|---|
| 10 | 7 | 12 | 250 | 1st |
| 5 | 7 | 12 | 75 | 3rd |
| 12 | 7 | 3 | 120 | 5th |
| 7 | 7 | 21 | 35 | 7th |
| 25 | 7 | 17 | 125 | 10th |

**Clustered.** The index holds (customer, day, id). For customer 7, in order:
(7,3,#12) (7,12,#5) (7,12,#10) (7,17,#25) (7,21,#7). The two rows of day 12 are ordered
by id.

**Heap.** Rows are stored four per page in arrival order, so id 10 is at TID (0,1), id 5
at (0,3), id 12 at (1,1), id 7 at (1,3), id 25 at (2,2). The index holds
(customer, day, TID): (7,3,(1,1)) (7,12,(0,1)) (7,12,(0,3)) (7,17,(2,2)) (7,21,(1,3)).
The two rows of day 12 are now ordered by address, which is arrival order: id 10 first.

Now `SELECT * FROM orders WHERE customer = 7`. All three trees involved have height 3.

- Both layouts: one descent of the index for (7, smallest day, smallest locator), 3
  nodes. It ends in the leaf just left of customer 7, because the seek key is smaller
  than the separator (7,3,#12). The five entries are in the next two leaves, and the scan
  looks into one more to see that customer 7 has ended: 3 leaf hops. So far 6 nodes.
- Clustered: each of the 5 entries holds an id. Search the primary tree for it: 5
  descents of 3 nodes, 15 nodes. Total **21** page reads.
- Heap: each of the 5 entries holds a TID. Read that heap page: 5 reads. Total **11**.

And `SELECT * FROM orders WHERE id = 17`:

- Clustered: one descent of the primary tree, 3 nodes, and the row is in the leaf. **3**.
- Heap: one descent of the primary key index, 3 nodes, gives TID (1,4); one heap read.
  **4**.

The clustered layout wins the primary-key lookup by one page and loses the secondary
lookup by (height of the primary tree minus one) pages per row. The programs print these
numbers:

```
== 2. Point lookup: SELECT * FROM orders WHERE id = 17 ==
clustered: id=17 customer=9 day=15 amount=510 code=170
  cost: descents=1 tree nodes=3 index entries=0 row fetches=0 heap reads=0 -> 3 page reads
heap     : id=17 customer=9 day=15 amount=510 code=170
  cost: descents=1 tree nodes=3 index entries=1 row fetches=1 heap reads=1 -> 4 page reads

== 3. Secondary index, then back to the row: SELECT * WHERE customer = 7 ==
clustered: ids 12 5 10 25 7, amounts 120 75 250 125 35
  cost: descents=6 tree nodes=21 index entries=5 row fetches=5 heap reads=0 -> 21 page reads
heap     : ids 12 10 5 25 7, amounts 120 250 75 125 35
  cost: descents=1 tree nodes=6 index entries=5 row fetches=5 heap reads=5 -> 11 page reads

```

The covering query `SELECT day WHERE customer = 7` (section 4 of the output) costs 6 page
reads in both layouts: the index part only.

"Page reads" is tree nodes plus heap reads, as if nothing were cached. That is a count of
the work, not a prediction of disk I/O: a buffer pool
([chapter 09](../09-pages-and-the-buffer-pool/README.md)) keeps the upper levels of a tree
in memory, which makes repeated descents much cheaper than this count suggests, and two
rows on the same heap page cost one read, not two.

The full output is in [`expected_output.txt`](expected_output.txt). Section 8 repeats the
queries on 2000 random rows with M = 16:

```
layout     query                                rows  descents  tree nodes  row fetches  heap reads  page reads
clustered  2000 x WHERE id = ?                  2000      2000        6000            0           0        6000
heap       2000 x WHERE id = ?                  2000      2000        6186         2000        2000        8186
clustered  50 x SELECT * WHERE customer = ?     2000      2050        6346         2000           0        6346
heap       50 x SELECT * WHERE customer = ?     2000        50         346         2000        2000        2346
clustered  1 x SELECT count(*) WHERE day = 180     2         1         186            0           0         186
heap       1 x SELECT count(*) WHERE day = 180     2         1         186            0           0         186
```

The last pair is the non-prefix predicate: 186 nodes and all 2000 entries read to find 2.

## Code walk-through

### The base tree and the packed keys

`base_*.zig` and `base_*.rs` are the chapter 07 B+tree, copied unchanged except for import
paths. It maps `u64` to `u64`. That is enough, because every key here is a composite packed
into 64 bits (`row.zig`, `row.rs`):

```
by_customer_day key:  customer:16 | day:16 | locator:32
by_code key:          0:16        | code:16 | locator:32
heap primary key:     id:32                 | locator:32
```

With the first column in the most significant bits, comparing the integers compares the
columns one after another. A prefix scan is then a range scan between the smallest and the
largest key with that prefix:

```zig
pub fn customerDaysRange(customer: u16, day_lo: u16, day_hi: u16) KeyRange {
    return .{
        .lo = customerDayKey(customer, day_lo, 0),
        .hi = customerDayKey(customer, day_hi, any_locator),
    };
}
```

`KeyRange` is a closed interval. A half-open one would need the key after the last key of
customer 65535, which does not fit in a `u64`.

The clustered layout packs the four `u16` columns of a row into the `u64` value
(`packRow`). A real engine stores a variable-length record there.

### The counting cursor

`cursor.zig` holds the counters and the one scan primitive, `Cursor`. `seek` does a
descent to the first key not below `range.lo` and charges `height` nodes; `next` returns
keys along the leaf chain, charges one node per leaf hop, and stops at the first key above
`range.hi`. It returns index keys and never looks at a row. Whether the keys are enough is
the caller's decision.

### The table

`table.zig` has one `Table` type with a `layout` field instead of two types, because
almost all of the code is shared. Three functions contain every difference.

`fetch` is the step back to the row:

```zig
fn fetch(self: *Table, locator: Locator) ?Row {
    self.counters.row_fetches += 1;
    switch (self.layout) {
        // The locator is a KEY of another tree: search that tree.
        .clustered => {
            chargeDescent(&self.counters, &self.primary);
            const value = self.primary.get(locator) orelse return null;
            return row_.unpackRow(locator, value);
        },
        // The locator is an ADDRESS: go there.
        .heap => {
            self.counters.heap_reads += 1;
            return self.heap.fetch(locator);
        },
    }
}
```

`getById` is a plain `primary.get` in the clustered layout and "probe the primary key
index, then `fetch`" in the heap layout. The third is the "store the row" step of
`insert`, which decides the locator: the id itself, or the TID returned by `heap.append`.

Everything about secondary indexes is layout-independent:

- `probe(tree, value)` seeks `columnRange(value)` and returns the first locator, if any.
  It is the equality lookup of a one-column index and also the unique check.
- `fetchScan(arena, range)` is "for each key the cursor returns, `fetch` its locator".
- `indexOnlyScan(arena, range)` returns the keys and never calls `fetch`.
- `countOnDay(day)` scans the whole index, because `day` is not a prefix.

`insert` checks both constraints before it writes anything, then performs up to four
writes (heap slot, primary tree, two indexes). Each tree write can fail for lack of
memory. `errdefer` undoes the earlier ones:

```zig
errdefer if (self.layout == .heap) self.heap.kill(locator);
try self.putNew(gpa, &self.primary, primary_key, primary_value);
errdefer _ = self.primary.delete(primary_key);
try self.putNew(gpa, &self.by_customer_day, customer_day_key, 0);
errdefer _ = self.by_customer_day.delete(customer_day_key);
try self.putNew(gpa, &self.by_code, row_.columnKey(row.code, locator), 0);
```

The undo cannot fail, because the chapter 07 `delete` never allocates. In the heap layout
a failed insert leaves a dead heap slot behind. That is not an accident of this code: a
heap is append-only, and a slot once handed out is not taken back.

`delete` has to *read the row first*. The index entries are named by the row's column
values plus its locator, and nothing else says where they are. Section 7 of the output
shows it: 4 descents in both layouts, plus one heap read in the heap layout.

`validate` checks the three trees, that each has one entry per row, and that every index
entry leads to a live row with the same column values.

### The heap

`heap.zig` is an append-only list of pages with four slots each. `append` returns a TID,
`fetch(tid)` is an array access, `kill(tid)` marks a slot dead. Dead slots are never
reused here; that is VACUUM, [chapter 24](../24-mvcc-vacuum-and-page-deletion/README.md).

### Rust, and the differences

The Rust crate has the same files, names, tests and output. The differences:

- **Counters.** In Zig a query takes `*Table` only because it increments counters. In Rust
  the counters are a `Cell<Counters>`, so queries take `&self` and the compiler still
  guarantees that a query changes nothing else.
- **Rollback.** Rust has no `errdefer`. `insert` runs the three `put`s in a closure that
  records how far it got, and undoes that many steps on `Err`.
- **Borrowing.** `put_new` and `remove` are associated functions taking the tree and the
  counters as separate arguments, so the borrow checker sees two different fields. A
  `Cursor` borrows its tree, so "do not modify the tree during a scan" is enforced; in Zig
  it is a comment.
- **Allocation failure.** A Rust `Vec` aborts when memory runs out. The Zig tests make the
  allocator fail; the Rust tests give one of the three trees a node budget
  (`Table::with_node_budgets`) and get `InsertError::OutOfNodes`. `Heap::append` cannot
  fail in Rust.
- **Query results.** Zig queries allocate from an arena passed by the caller. Rust queries
  fill a `&mut Vec` passed by the caller, cleared first.

### Tests

Both languages assert the cost claims above, run a seeded model test of both layouts
against a plain list of rows (M = 3, 4, 16, exact result order checked), fail an insert at
every possible point and check that the row is in all trees or in none, and show two
corruptions that `validate` reports. The chapter 07 tests of the base tree run as well.

## In real databases

### Turso: the table is a B+tree keyed by rowid

- A table B-tree stores rows in its leaves under a 64-bit rowid. The leaf cell carries
  rowid and payload; the interior cell carries only a child page and a rowid
  (`turso/core/storage/sqlite3_ondisk.rs:813-826`). This is the clustered layout.
- An index B-tree is a different tree kind: its cells carry a record and no separate
  rowid field (`sqlite3_ondisk.rs:829-843`). The research notes (`research/turso.md`,
  section 4) describe the key as the index columns followed by the rowid, and note that
  index trees keep entries in interior pages too. That is a classic B-tree, not a B+tree.
  This chapter's index is a B+tree for simplicity; the locator-last key is the same idea.
- Going back to the row is an explicit instruction. `DeferredSeek` positions the table
  cursor at the rowid of the index cursor's current entry, and does it lazily, "if no
  reads occur, no unnecessary I/O happens" (`turso/core/vdbe/insn.rs:1295-1300`;
  implementation `turso/core/vdbe/execute.rs:6421`). `IdxRowId` reads the rowid out of an
  index entry and `SeekRowid` searches the table tree (`insn.rs:1279-1290`).
- Covering: the planner asks `index_is_covering` (`turso/core/translate/plan.rs:3672`).
  `index_covers_columns` skips the rowid alias column with the comment "rowid is always
  implicitly covered by the index" (`plan.rs:3698-3723`). That is section 4's "clustered
  only" line. The cost model charges the table lookup only when the index is not covering
  (`turso/core/translate/optimizer/cost.rs:233-240`).
- Unique: before inserting, the generated program probes each unique index with
  `NoConflict`, which checks whether any entry has a matching key prefix and always
  passes if the key contains a NULL (`insn.rs:1645-1660`; emitted by the "preflight
  phase", `turso/core/translate/insert.rs:3592`).
- An `INTEGER PRIMARY KEY` column is an alias for the rowid and gets no separate index
  (`turso/core/schema.rs:3721-3723`). `WITHOUT ROWID` tables are behind an experimental
  flag at this commit (`turso/core/translate/schema.rs:1205`).

### Postgres: heap, TIDs, and every index is secondary

- A TID is `ItemPointerData`: a block number and an offset number, six bytes
  (`postgres/src/include/storage/itemptr.h:36`). Every leaf tuple of an nbtree index
  points to the heap through one (`research/postgres.md`, section "Terms").
- The heap TID is the last key column of every index, as a tie-breaker, so that all keys
  are unique and duplicates are kept in TID order
  (`postgres/src/backend/access/nbtree/README:42-49`). This is the locator-last key of
  this chapter.
- Unique check: `_bt_doinsert` clears the insertion key's `scantid` so the descent lands
  on the first place an equal key could be (`nbtree/nbtinsert.c:118-124`).
  `_bt_check_unique` (`nbtinsert.c:410-788`) then walks the equal entries and asks the
  heap whether each one's row is live. That second half has no counterpart here: Postgres
  indexes also contain entries of dead row versions, so "an entry exists" is not yet "a
  row exists". See [chapter 24](../24-mvcc-vacuum-and-page-deletion/README.md).
- Index-only scans are also conditional for that reason. For each TID the heap access
  method checks the visibility map; only if the page is all-visible is the heap skipped,
  otherwise the row is fetched after all
  (`postgres/src/backend/access/heap/heapam_indexscan.c:358-375`). A plain index scan
  always calls `heapam_index_heap_fetch` (`heapam_indexscan.c:350-355`). In this chapter
  an index-only scan never touches the heap, because there are no row versions.
- `INCLUDE` columns are extra payload in leaf tuples that is not part of the search key;
  they are dropped from pivot tuples (`nbtree/README:834-838`). Exercise 3 builds a small
  version.
- A primary key is a unique index plus a constraint entry in the catalog
  (`index_constraint_create`, `postgres/src/backend/catalog/index.c:1918`). There is no
  clustered table storage in the heap access method.
- Skip scan: this Postgres version can answer a predicate on a non-leading column by
  generating a "skip array" on the leading column
  (`nbtree/nbtpreprocesskeys.c:130-137`). Exercise 5 measures the idea on this chapter's
  table.

### Textbook, not verified in these sources

- "A clustered secondary lookup costs two tree traversals" is standard textbook material
  (InnoDB is the usual example; it is not in `db_study/`).
- When a heap row is updated, Postgres writes a new version at a new TID, so every index
  needs a new entry unless the HOT optimisation applies. `README.HOT` exists at
  `postgres/src/backend/access/heap/README.HOT`; this chapter did not study it. The
  general trade-off is: a TID is fast to follow but changes when the row moves; a primary
  key is slower to follow but stable.

## Allocator notes

Plan row: "Arena per query; pool for rows".

- **Arena per query.** `fetchScan` and `indexOnlyScan` return slices allocated from an
  allocator the caller passes. The demo and the tests pass a `std.heap.ArenaAllocator`
  and call `reset(.retain_capacity)` before the next query. The lifetime of a result is
  "until the next query", which is exactly what an arena expresses, and the query code
  needs no `errdefer` and no free path. With the general-purpose allocator instead, every
  caller would have to free every result, and under `std.testing.allocator` a forgotten
  one fails the test as a leak. The arena must not be used for the table itself: a reset
  would free tree nodes that are still linked.
- **Pool for rows.** In the heap layout rows live in fixed-size pages taken from a
  `std.heap.MemoryPool(Page)`; a separate `ArrayList(*Page)` maps page number to page.
  Pages are allocated one at a time, never move and are all released by `pool.deinit`.
  An `ArrayList(Row)` would also work for TIDs, since a TID is an index and not a
  pointer, but it copies every row each time it grows, which a heap file never does.
- **Failure.** `heap.append` reserves the slot in the page list before it takes a page
  from the pool, so a failure leaves the heap unchanged. The table-level test runs 40
  inserts with the allocator failing at every possible point and validates the table after
  each failure.
- **Rust.** Pages are `Vec<Box<Page>>` (same reasoning; `clippy::vec_box` is allowed there
  with a comment). The per-query arena is a caller-owned `Vec` that each query clears and
  refills.

## Pitfalls

- **The probe must leave the locator out.** Searching for (code, this row's locator)
  finds nothing even when another row has the code. The unique check and the heap layout's
  primary-key lookup are prefix searches.
- **A prefix search can land one leaf early.** The descent for (17, smallest locator) may
  end in the leaf to the left of the entry (17, (1,4)), when that entry is the separator
  copy and the first key of the next leaf. The cursor has to step to the next leaf
  instead of reporting "not found". Section 8 shows it: 6186 tree nodes for 2000 heap
  primary-key lookups, 186 more than 2000 descents of height 3. Postgres handles the same
  case by continuing the unique check onto the right sibling (`nbtinsert.c:732-760`).
- **Column order in a composite index is not symmetric.** (customer, day) answers
  `customer = ?` and not `day = ?`.
- **Delete needs the old row.** Forgetting to remove an index entry leaves an entry whose
  locator leads nowhere, or, worse, to a different row once ids or slots are reused.
- **Partial inserts.** Without the rollback a failed insert leaves a row that one index
  can find and another cannot.

## Exercises

1. (easy) Without running anything, work out the cost line of
   `SELECT * FROM orders WHERE customer = 3` on the 12-row table for both layouts, from
   the leaf listing in section 1 of the output. Then check.
2. (easy) `probe` is given a code and returns the first locator filed under it. Explain
   why `by_code.get(columnKey(code, 0))` is not a correct unique check, and why
   `by_code.get(columnKey(code, locator))` is not one either.
3. (medium) The index trees leave their `u64` value unused. Store `amount` there for
   `by_customer_day` and add a query `amountsOfCustomer` that is index-only. Which
   functions must change? What does the new query cost compared with section 3?
4. (medium) Add `updateDay(id, new_day)`. Count the descents in each layout. Then suppose
   the heap layout wrote the changed row to a *new* slot, as an engine with row versions
   does: which entries change now?
5. (harder) Implement a skip scan for `WHERE day = ?`: for each distinct customer, seek
   (customer, day). Compare its counters with `countOnDay` on the 12-row table and on the
   2000-row table. When does it win?

Solutions: [`solutions.md`](solutions.md).

## Links

- Previous: [chapter 17, key compression and deduplication](../17-key-compression-and-deduplication/README.md)
- Next: [chapter 19, latching and lock coupling](../19-latching-and-lock-coupling/README.md)
- Visualization: [`viz/index.html`](viz/index.html) runs one query on both layouts, step
  by step, with the same counters. Its table has no `code` column and no delete.
