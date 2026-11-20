# Chapter 30: Tracing a real insert

This is the last chapter. It adds one new idea and otherwise puts the earlier chapters in
the order in which a real `INSERT` meets them.

## What you will learn

- The path of one insert into a B-tree index, from the top-level call to the bytes on the
  page, in PostgreSQL's nbtree and in Turso (SQLite format), with a file and line for
  every step and a link to the chapter that taught it.
- Where the two designs do the same thing and where they differ, and that almost every
  difference follows from one decision: many writers in the tree, or one.
- Why the B-tree code of an engine with asynchronous I/O is written as a resumable
  (re-entrant) state machine, what rules keep such code correct, and how to turn the
  blocking `put` of chapter 12 into one.
- Which lifetime the memory of such an operation needs, and what breaks when it is
  shorter.

Prerequisites: chapter 12 (the disk B+tree whose code this chapter copies), chapter 20
(B-link trees) and chapter 22 (write-ahead log). The trace refers to most other chapters,
but each reference says what it needs from them.

Source checkouts: PostgreSQL commit `11591f2`, Turso commit `469c4f4`, both under
`db_study/`. In this chapter `N/` means `postgres/src/backend/access/nbtree/` and `T/`
means `turso/core/storage/`. Every line number below was opened in those checkouts.

## The idea in plain words

An insert into an index is always the same six jobs:

1. **Find the leaf** that must hold the key.
2. **Check uniqueness**, if the index is unique.
3. **Make room** on that leaf, or find out that there is none.
4. **Split or rebalance** when there is none.
5. **Fix the parent**, which may be full too, and so on up to the root.
6. **Make it durable.**

PostgreSQL and Turso both do all six. They differ in how, and the reason is short.
PostgreSQL lets many backends insert into the same tree at once, so a page can split
while another backend is on its way to it. Everything special about nbtree (high keys,
right links, the incomplete-split flag, one small WAL record per step) exists so that
each step leaves the tree usable by everybody else. Turso admits one writer at a time.
Nobody can be on their way to a page that the writer is changing, so its tree needs no
links and no flags, a rebalance may rewrite three siblings and their parent as one
unit, and the log only has to say which pages a transaction changed.

The second half of the chapter is about a property of the code and not of the tree. The
teaching code of this guide calls `fetchPage` and waits. Turso's code cannot wait: when a
page is not in memory, its B-tree function returns to the caller, and the caller calls it
again later. A function that can be abandoned at any read and called again from the top
has to keep its progress somewhere other than its local variables. That is the whole
reason production B-tree code is full of state enums.

## Part 1. The trace

The statement is `INSERT INTO t (k) VALUES (27)`, where `t` has a unique index on `k`.
The [visualization](viz/index.html) plays this trace on two small trees with the same
keys. Read this section next to it.

### Stage 1: find the leaf (chapters 02, 03, 08, 09, 19, 20)

**PostgreSQL.** `btinsert` (`N/nbtree.c:212`) calls `_bt_doinsert` (`N/nbtinsert.c:105`),
which builds an insertion scan key from the tuple (`:116`) and calls `_bt_search_insert`
(`:320`). That function first tries a shortcut: if this backend last inserted into the
rightmost leaf and the new key belongs there too, it takes that page without a descent
(`:347-352`). Otherwise `_bt_search` (`N/nbtsearch.c:102`) walks down. At every level it
does three things. `_bt_moveright` (`:244`) compares the key with the page's high key and
follows the right link if the page was split after its downlink was read (`:309-313`).
`_bt_binsrch` (`:346`) picks the downlink. Then the lock on the parent is released and
only after that is the child locked (`:185`). So one page lock is held at a time, and the
(block, offset) pairs pushed on the private stack (`:167-174`) are hints for the way back
up, not pins. The leaf is locked in write mode.

**Turso.** The bytecode instruction `IdxInsert` (`turso/core/vdbe/execute.rs:12424`)
positions a cursor with a seek (`T/btree.rs:6928`, descent in `indexbtree_move_to_inner`,
`:2364`). Each page on the way is read through `Pager::read_page` (`T/pager.rs:3672`),
binary-searched through its cell pointer array, and pushed on the cursor's `PageStack`
(`T/btree.rs:8989`), which pins it. There are no latches and no moving right: there are
no sibling links to follow and no other writer to move away from.

### Stage 2: check uniqueness (chapters 07, 18)

**PostgreSQL.** `_bt_check_unique` (`N/nbtinsert.c:411`, called at `:213`) runs while
the leaf is write-locked. That lock is the uniqueness lock: another insert of the same
key must reach the same page and wait. If an equal key belongs to a transaction that is
still running, the page is released, the backend waits for that transaction (`:230`),
and the whole search starts again (`:235`).

**Turso.** The tree does not know about uniqueness. The bytecode does: a `NoConflict`
instruction (`execute.rs:12963`) or the `UniqueConstraintCheck` state of `IdxInsert`
(`:12518-12549`) compares the entry under the cursor with the new key. No lock is
needed because no other writer exists.

### Stage 3: make room (chapters 10, 13, 17, 24)

**PostgreSQL.** `_bt_findinsertloc` (`:827`) finds the slot. If the page is full it first
tries to free space on the page itself with `_bt_delete_or_dedup_one_page` (`:2728`,
called at `:915-916`): remove entries marked dead, bottom-up deletion, deduplication.
`_bt_insertonpg` (`:1117`) then either adds the tuple inside a critical section
(`:1295-1419`: `PageAddItem` at `:1300`, one WAL record at `:1407`) or splits (`:1223`).

**Turso.** `insert_into_page` (`T/btree.rs:3162`) marks the leaf dirty (`add_dirty`,
`:3183`, `T/pager.rs:3919`) and calls `insert_into_cell` (`:3293`). If the cell fits it
is written into the cached page. If not, the page bytes are left alone and the cell is
appended to `page.overflow_cells`, a list in memory (`:10347-10368`). A page with an
overflow cell is, by definition, overfull, and the cursor goes into `balance` (`:3301`).

### Stage 4: split or rebalance (chapters 04, 12, 14, 15, 17, 20)

**PostgreSQL.** `_bt_split` (`:1487`) asks `_bt_findsplitloc` (`N/nbtsplitloc.c:130`,
called at `:1565`) where to cut, builds the new left page in private memory with the
flag `BTP_INCOMPLETE_SPLIT` set (`:1580`), and gives it a new high key, which on a leaf
is the separator shortened by `_bt_truncate` (`N/nbtutils.c:692`, called at `:1680`).
Only then does it allocate the right page (`:1739`), "the last point where splitting the
page may fail" (`:1527-1532`). The right links are set (`:1760`, `:1770`). One critical
section (`:1950-2093`) copies the left half over the original block, which never moves
(`:1954-1959`), fills the right block and writes one WAL record (`:2080-2081`). The
parent has not been touched. A search that arrives at the left page with a key in the
right half sees the high key and moves right.

**Turso.** `balance` (`T/btree.rs:3401`) is a loop over a sub-state machine
(`BalanceSubState`, `:296`). If the overfull page is the root, `balance_root` (`:5410`)
copies it into a new child and empties the root, so the root keeps its page number.
`balance_quick` (`:3526`) appends a new right leaf, but only for table leaves (`:3462`),
not for an index. Everything else is `balance_non_root` (`:3604`): choose up to three
adjacent siblings (`:3693-3713`), read and pin them, put all their cells and the dividers
between them into one array, and deal the cells out again (`:4200-4420`) over as many
pages as are needed, allocating only if the old ones do not suffice (`:4428`). When the
neighbours have room, the "split" allocates nothing. PostgreSQL never redistributes.

### Stage 5: fix the parent (chapters 04, 12, 20)

**PostgreSQL.** `_bt_insert_parent` (`:2128`) is a second, separate atomic action. It
re-finds the parent with `_bt_getstackbuf` (`:2349`, called at `:2223`), which looks for
the downlink to the left child and does not trust the remembered offset, then calls
`_bt_insertonpg` on the parent (`:2247`). That insert clears the child's flag in the
same WAL record (`:1325-1327`). If the parent is full the same code splits it. If the
page that split was the root, `_bt_newlevel` (`:2490`) builds a new root above and
changes the root pointer in the metapage (`:2563`, WAL record at `:2637`). If the process
dies between the two actions, the flag stays, and the next writer that passes finishes
the split (`_bt_finish_split`, `:2270`).

**Turso.** The last phase of `balance_non_root` puts the new dividers into the parent
(`:4583-4704`) with the same `insert_into_cell`. If the parent has no room, the divider
becomes an overflow cell of the parent, and the loop in `balance` runs again one level
up (`:3427-3449`). There is no moment at which a page exists that the parent does not
point to.

### Stage 6: make it durable (chapters 21, 22)

**PostgreSQL.** Each step above already wrote its own WAL record. At commit `XLogFlush`
(`postgres/src/backend/access/transam/xact.c:1548`) forces the log to disk. Recovery
replays the records one at a time (`btree_xlog_insert` `N/nbtxlog.c:158`,
`btree_xlog_split` `:247`, `btree_xlog_newroot` `:927`).

**Turso.** Until commit only cached pages changed and the pager collected their ids. At
commit `commit_wal_inner` (`T/pager.rs:4562`, states at `:1228-1259`) writes every dirty
page as a whole-page WAL frame and fsyncs. The last frame carries the database size,
which makes it the commit frame (`T/sqlite3_ondisk.rs:481-500`). Readers and recovery
accept frames only up to the last commit frame, so all pages of the transaction appear
together or not at all.

### The trace table

| Stage | PostgreSQL function (file:line) | Turso function (file:line) | Guide chapter |
|---|---|---|---|
| 0 entry | `btinsert` `N/nbtree.c:212`; `_bt_doinsert` `N/nbtinsert.c:105` | `op_idx_insert` `turso/core/vdbe/execute.rs:12424`; `BTreeCursor::insert` `T/btree.rs:7012` | [18](../18-indexes-in-a-database/README.md) |
| 1 find the leaf | `_bt_search` `N/nbtsearch.c:102`; `_bt_moveright` `:244`; `_bt_binsrch` `:346` | `seek` `T/btree.rs:6928`; `indexbtree_move_to_inner` `:2364`; `PageStack` `:8989`; `read_page` `T/pager.rs:3672` | [02](../02-searching-a-sorted-node/README.md), [03](../03-btree-structure-and-search/README.md), [08](../08-range-scans-and-cursors/README.md), [09](../09-pages-and-the-buffer-pool/README.md), [19](../19-latching-and-lock-coupling/README.md), [20](../20-blink-trees/README.md) |
| 2 check uniqueness | `_bt_check_unique` `N/nbtinsert.c:411` | `op_no_conflict` `execute.rs:12963`; `UniqueConstraintCheck` `:12518` | [07](../07-bplus-trees/README.md), [18](../18-indexes-in-a-database/README.md) |
| 3 make room | `_bt_findinsertloc` `:827`; `_bt_delete_or_dedup_one_page` `:2728`; `_bt_insertonpg` `:1117` | `insert_into_page` `T/btree.rs:3162`; `insert_into_cell` `:10413`; overflow cell `:10347-10368` | [10](../10-slotted-pages/README.md), [13](../13-overflow-and-free-space/README.md), [17](../17-key-compression-and-deduplication/README.md), [24](../24-mvcc-vacuum-and-page-deletion/README.md) |
| 4 split or rebalance | `_bt_split` `:1487`; `_bt_findsplitloc` `N/nbtsplitloc.c:130`; `_bt_truncate` `N/nbtutils.c:692` | `balance` `:3401`; `balance_root` `:5410`; `balance_quick` `:3526`; `balance_non_root` `:3604` | [04](../04-insertion-and-splitting/README.md), [12](../12-disk-backed-bplus-tree/README.md), [14](../14-split-policies-and-fill-factor/README.md), [15](../15-redistribution-and-merge-policies/README.md), [17](../17-key-compression-and-deduplication/README.md), [20](../20-blink-trees/README.md) |
| 5 fix the parent | `_bt_insert_parent` `:2128`; `_bt_getstackbuf` `:2349`; `_bt_newlevel` `:2490`; `_bt_finish_split` `:2270` | divider insertion in `balance_non_root` `:4583-4704`; loop in `balance` `:3427-3449` | [04](../04-insertion-and-splitting/README.md), [12](../12-disk-backed-bplus-tree/README.md), [20](../20-blink-trees/README.md) |
| 6 make it durable | `XLogInsert` calls `:1407`, `:2081`, `:2637`; `XLogFlush` `xact.c:1548`; redo `N/nbtxlog.c:1004` | `commit_tx` `T/pager.rs:3421`; `commit_wal_inner` `:4562`; commit frame `T/sqlite3_ondisk.rs:481-500` | [21](../21-durability-primitives/README.md), [22](../22-wal-and-crash-recovery/README.md) |

### Where the designs agree and where they differ

| | PostgreSQL nbtree | Turso (SQLite format) |
|---|---|---|
| Writers in one tree | many | one (`T/wal.rs:3587-3589` returns `Busy` to a second) |
| Held on the way down | one page lock at a time | pins on the whole path, no locks |
| Sibling links, high key | both, on every page | neither |
| A full page | splits in two; never redistributes | is rebalanced with up to two siblings |
| Between "split" and "parent knows" | a visible, legal state with a flag | does not exist for anyone else |
| Root page | changes when the root splits | keeps its page number |
| Uniqueness | page lock inside the tree | bytecode outside the tree |
| Log | one record per step, as it happens | whole pages, at commit |
| Same in both | bottom-up restructuring, a remembered path, the left or original page stays in place, fullness measured in bytes | |

## Part 2. Why production code looks nothing like the teaching code

### The problem

Chapter 12's `put` is a straight line: `findLeaf`, put into the leaf, and on overflow
`pushRootDown`, `splitLeaf`, then a loop of `insertSeparator` and `splitInterior`. Each
of these calls `pool.fetchPage`, and a miss blocks the thread in `read()`.

Turso is built on asynchronous I/O and cooperative yielding instead. Its rule
(`turso/docs/agent-guides/async-io-model.md:10-23`): a function that may need I/O returns
`IOResult::Done(value)` or `IOResult::IO(completions)`, and the caller must call it
again until it says `Done` (`turso/core/types.rs:3797-3804`). It does not use Rust's
`async`. The macro `return_if_io!` (`types.rs:3831`) is the `?` of this scheme: it
returns the `IO` to the caller's caller, all the way up to the statement loop.

The consequence is in the same guide under "Re-Entrancy: The Critical Pitfall"
(`async-io-model.md:117-160`): the function restarts from the top, so anything it
changed before the yield is changed again. `vec.push(x); return_if_io!(...)` grows the
vector on every re-entry (`:162-169`). The cure is to record progress in a state enum
and to mutate only after the last point that can yield. That is why `btree.rs` contains
`WriteState` (`:359`), `BalanceSubState` (`:296`) and a dozen others, why
`balance_non_root` is cut into states exactly at its reads, allocations and frees, and
why its redistribution arithmetic is one uninterrupted block. Turso also has a test hook
that forces a yield at a chosen point (`inject_io_yield!`, `T/btree.rs:3312-3315`).

### The same thing in this chapter

`resumable.zig` and `resumable.rs` turn chapter 12's `put` into an `InsertOp` with

```
step() -> Done            the insert is complete
       -> Io(page id)     this page is not in the buffer pool; nothing was read;
                          call me again when it is there
```

The blocking steps of chapter 12 are reused unchanged. Each was already all-or-nothing,
which makes each a natural state. Before calling one, the state machine asks whether the
page that step will fetch is in the pool. If it is, the fetch inside the step is a hit
and cannot block. If not, `step` returns `Io`. Three rules keep this correct:

- **R1.** A state asks for its page first and changes nothing before that.
- **R2.** Whatever a state changes, it changes after its last yield point, together with
  the new state. (`insert_separator` looks at the top of the path, may yield, and pops
  only after the parent was updated.)
- **R3.** No page stays pinned across a yield.

### A worked example by hand

A 2-frame pool, six keys in a root that is a leaf (page 1), nothing cached. Insert `07`:

```
call 1: descend -> Io(page 1)
        the disk reads page 1 into the pool
call 2: descend, leaf_put, push_root_leaf, split_leaf, insert_separator -> Io(page 1)
        the disk reads page 1 into the pool
call 3: insert_separator -> Done
```

Call 1 stops at once: the root is not in memory. Call 2 enters at `descend` again, now
finds the root, sees that it is a full leaf, moves its content down to page 2 and splits
that into pages 2 and 3. Those two pages fill both frames, so the root has been evicted
when `insert_separator` wants it, and the call returns `Io(page 1)` a second time, with
the tree half-split in memory. Call 3 enters at `insert_separator` and not at the top:
the split is not repeated. What call 3 needs from call 2 is the separator and the two
page ids (`carry`) and the path. None of that can be a local variable of call 2.

## Code walk-through

Files: `disk_btree`, the four `base_*` files, `prng` and `workload` are copied from
chapter 12 (each header says what changed: the steps of `put` became callable from
another file, and the buffer pool got `evictUnpinned` for the tests). New files:
`resumable` (the operations), `scheduler` (the simulated disk and the scheduler),
`demo`, `tests`.

### Zig

`State` is a plain enum with seven suspendable states: `descend`, `leaf_put`,
`push_root_leaf`, `split_leaf`, `insert_separator`, `push_root_interior`,
`split_interior`. The data lives in fields of `InsertOp`: `cur`, `path`, `parent`,
`carry`, and an `ArenaAllocator` that owns all of it.

`advance` is one transition and `step` loops over it. Every arm has the same shape:

```zig
.insert_separator => {
    const parent = self.path.getLast();                  // look, do not pop
    if (self.need(parent.id)) |id| return .{ .io = id }; // R1: ask first
    const fitted = try tree.insertSeparator(self.scratch(), parent, self.carry);
    _ = self.path.pop();                                 // R2: change after the yield point
    if (fitted) return self.finish();
    self.parent = parent;
    self.state = if (self.path.items.len == 0) .push_root_interior else .split_interior;
    return .again;
},
```

`need` only looks into the page table (`pool.frameOf`); it changes no counter. `step`
has `errdefer self.fail()`: any error ends the operation, frees its arena and poisons
the tree handle if a page had already been changed, exactly like chapter 12.

`scheduler.zig` has two parts. `SimDisk` keeps a list of pending reads; `completeOne`
picks one with the seeded generator and only then reads the page into the pool. This is
the only place in the chapter where a page is read. `Scheduler` admits operations in
submission order, steps each until it yields, and after every completed read steps the
operation that asked for that page before completing another read, which guarantees
progress even with two frames. It asserts after every `step` that the pager's read
counter did not move and that no frame is pinned.

**Who may interleave.** Any number of lookups (`GetOp`) run together and their reads
complete in any order. An insert runs alone. The reason is Part 4 of the program
output: an insert that waits between `split_leaf` and `insert_separator` has left a right
half that no parent points to, and a lookup let in at that moment does not find a key
that is in the tree. PostgreSQL makes that state legal with right links. Turso avoids
exposing it: one writer, and readers read their snapshot through the WAL. This chapter
does the simplest thing and makes readers wait.

### Rust

The structure, names, tests and output are the same. The differences:

- **The state enum owns its data.** `State::InsertSeparator { carry }`,
  `State::SplitInterior { parent, carry }`: each variant holds what is live in that
  state, and `Carry` holds an owned `Vec<u8>`. `advance` takes the state out with
  `std::mem::replace(&mut self.state, State::Failed)` and puts a state back before it
  returns. A yield puts the same state back; an error leaving through `?` leaves
  `Failed` in place, which is what a failed operation should be. Turso uses the same
  take-and-put-back idiom (`T/btree.rs:3329-3331`).
- **No arena.** Ownership gives each piece of data the lifetime of the state that holds
  it; `release` drops the rest when the operation ends.
- **What `async fn` would generate.** The compiler would produce the same thing: an enum
  with one variant per `await`, each holding the locals that are live across it, and a
  `poll` that matches on it. Two things would differ. Locals that borrow other locals
  make that enum self-referential, which is why futures must be pinned; and the states
  would have no names. Turso writes the enum by hand, so states can be printed, tested
  one by one and forced to yield. This chapter uses std only, with no async runtime.
- The operations do not hold a reference to the tree (two `&mut` could not coexist); the
  scheduler lends the tree to the operation it steps.
- Safe Rust cannot make a `Vec` allocation fail, so the out-of-memory test of Zig has
  no twin; the failed page allocation (a write fault) covers the same code paths.

### What the tests prove

- **Same result.** 700 puts that build three levels are run through the scheduler with
  pools of 2 to 16 frames, different disk seeds, with and without forced eviction,
  mixed with lookups. After a flush the file is byte-identical to the one the blocking
  `put` writes, and every lookup returns what a one-by-one execution would.
- **Every suspension point.** With eviction forced between transitions, each of the
  seven states suspends at least once. Left alone, a single writer suspends only in
  `descend` and `insert_separator`; the test asserts that too, so the forcing is
  visibly necessary.
- **Re-entry is harmless.** At every yield, in every state, `step` is called three more
  times without the page. It returns the same `Io`, and a snapshot of everything
  observable (state, path length, tree and pool counters, pager counters, the file) is
  unchanged.
- **Failures leave nothing behind.** Read faults, write faults and (Zig) allocation
  faults are swept over every position. After each, no frame is pinned; either the
  insert had not changed a page, the tree validates and the key is absent, or the handle
  is poisoned. `std.testing.allocator` fails the Zig tests on any leaked arena.

### Program output

Both programs print [expected_output.txt](expected_output.txt). Part 2 and Part 5:

```
== Part 2: 2000 puts, blocking and resumable (4-frame pools) ==
blocking put: 1451 keys, 106 pages, height 3; splits: 101 leaf, 1 interior, 2 root
resumable insert:
  3852 calls of step, 1852 of them returned Io
  suspended in: descend 1831, leaf_put 0, push_root_leaf 0, split_leaf 0, insert_separator 21, push_root_interior 0, split_interior 0
  pages read by the disk: 1957; file identical to the blocking one: true
resumable insert, every unpinned page dropped between transitions:
  8152 calls of step, 6152 of them returned Io
  suspended in: descend 3946, leaf_put 2000, push_root_leaf 1, split_leaf 101, insert_separator 102, push_root_interior 1, split_interior 1
  pages read by the disk: 6258; file identical to the blocking one: true

== Part 5: where the scratch memory of a split must live ==
owned by the operation, 2-frame pool: 30 inserts, validate ok after each
buffer reused per call, 64-frame pool: 30 inserts, validate ok after each
buffer reused per call, 2-frame pool: tree broken after insert 10 (KeyOutOfBounds)
```

## In real databases

- Turso persists far smaller things than this chapter does. Binary-search bounds live in
  the cursor so that a seek can resume inside a page; `iteration_pending_descent`
  (`T/btree.rs:974`) exists because the stack had already advanced when a child read
  yielded; `sibling_load_group` lives in `BalanceState` and not on the stack so that
  reads issued before a yield are still awaited afterwards (`:336-341`).
- Turso's pager remembers reads that are in flight (`pending_reads`,
  `T/pager.rs:1627`), so that re-entry does not issue the same read twice. `SimDisk`
  here does not: two lookups that want the same page submit two requests, and the second
  completion finds the page cached.
- PostgreSQL's nbtree is ordinary blocking code: a backend that needs a page sleeps in
  the buffer manager while other backends, which are separate processes, keep running.
  Its tree pays for concurrency inside the data structure; Turso's code pays for it in
  the shape of every function. This comparison is the author's summary, not a statement
  from either code base.
- This chapter yields only on reads. `pool.newPage` still writes synchronously. Turso
  yields on writes, allocations and frees as well (the states of `balance_non_root`).

## Allocator notes

The Zig operation owns one `ArenaAllocator`, created in `init` and emptied by
`finish` or `fail` with `reset(.free_all)`. It holds the copies of the key and the value,
the path, and the scratch memory of every split: the copy of the page being split and
the cell lists. `carry.sep`, the separator handed to the parent, is a slice into that
page copy.

This is the natural allocator because all of that memory has one lifetime, the
operation's, and that lifetime is neither a function call nor the tree's.

- Chapter 12 used the tree's arena and reset it when `put` returned. A resumable `put`
  returns many times before it is finished, so that arena would be reset under a live
  separator.
- A buffer on the stack of `step` dies at every yield. Part 5 and the test "scratch
  memory that is reused at every yield breaks the tree, but only when the insert yields"
  show it: with `Scratch.step_buffer` the split's scratch comes from a buffer that is
  overwritten whenever `step` returns `Io`, as a stack frame would be. With a 64-frame
  pool no split ever waits and 30 inserts pass. With a 2-frame pool the first split
  whose parent was evicted hands the parent a separator of `0xAA` bytes, and `validate`
  reports `KeyOutOfBounds`. The bug is invisible until the operation actually yields.
- A general-purpose allocator would work but needs one `free` per piece on every exit
  path, including cancellation; the arena makes "the operation is over" one call. The
  tests check that `queryCapacity()` is zero after completion, failure and cancel.

Also: `init` copies the key and the value. The blocking `put` could borrow them, because
it returned before the caller's buffers went away. Rust expresses the same lifetimes
with ownership; its version of the stale buffer is an index into a reused `Vec<u8>`,
which is the form this bug takes in safe Rust.

## Pitfalls

- **Mutating before a yield.** Appending to the path before asking for the page, or
  popping it before the parent is updated, corrupts the operation on re-entry without
  any error.
- **Trusting the state before.** "The previous state just used this page, so it is in
  the pool" is true only while nothing else runs and the pool is large enough. Each
  state must ask.
- **Holding a pin while waiting.** A cancelled operation would leak it, and a small pool
  could run out of evictable frames.
- **Letting a reader in during a half-split.** It is not a crash; it is a wrong answer.
- **Borrowing the caller's key.** The call that created the operation returns long
  before the operation ends.
- **Testing only with a large pool.** Nothing yields, so none of the above shows.

## Exercises

1. (Easy) Break rule R2 on purpose: in `descend`, append to `path` before calling
   `need`. Which test fails first, and what does the path contain when it does?
2. (Easy) In `insert_separator`, pop the path before `need`. Predict what happens on
   the first yield in that state, then run the tests.
3. (Medium) Make `SimDisk` remember in-flight reads so that two operations waiting for
   the same page share one request, as Turso's `pending_reads` does. Check with Part 3.
4. (Medium) `step` still blocks in `pool.newPage`. Sketch the states you would add so
   that a page allocation also yields. Which of the three rules is hardest to keep?
5. (Hard) Let lookups run while an insert is in flight, safely, without a WAL. One way
   is a right link on every page plus a high key, as in chapter 20. State what a lookup
   must check and where.

Solutions are in [solutions.md](solutions.md).

## Where to go from here

The guide-wide map is [SOURCE_READING_MAP.md](../../SOURCE_READING_MAP.md). For the
insert path alone, read the real files in this order:

1. `postgres/src/backend/access/nbtree/README`: the design, before any code.
2. `postgres/src/include/access/nbtree.h:60-90` and `:349-366`: the page's special
   space, the flags, the high key.
3. `N/nbtsearch.c:102-331`: `_bt_search` and `_bt_moveright`.
4. `N/nbtinsert.c:105-272`, then `:1117-1457`, `:1487-2109`, `:2128-2315`,
   `:2490-2655`: `_bt_doinsert`, `_bt_insertonpg`, `_bt_split`, `_bt_insert_parent`,
   `_bt_newlevel`.
5. `N/nbtsplitloc.c:130-429` and `N/nbtutils.c:692`: the split point and truncation.
6. `N/nbtxlog.c:158`, `:247`, `:927`: what each WAL record replays.
7. `turso/docs/agent-guides/async-io-model.md`: the rules, in two hundred lines.
8. `turso/core/storage/btree.rs:296-400`: the state enums, to see what must be remembered.
9. `T/btree.rs:3162-3390`, `:3401-3600`, `:5410-5490`: `insert_into_page`, `balance`,
   `balance_quick`, `balance_root`.
10. `T/btree.rs:3604-4938`: `balance_non_root`, one state at a time.
11. `T/pager.rs:3672`, `:3919`, `:4562` and `T/wal.rs:3571`: reading a page, dirtying
    it, committing, and the write lock.

## Links

- Previous: [chapter 29, zone maps and vector indexes](../29-zone-maps-and-vector-indexes/README.md)
- Next: none. Back to the [guide index](../../README.md) ([index.html](../../index.html)).
- Visualization: [two swim lanes and the resumable insert](viz/index.html)
