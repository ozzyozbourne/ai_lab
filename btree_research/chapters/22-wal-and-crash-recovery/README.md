# Chapter 22: write-ahead log and crash recovery

## What you will learn

- Why a B-tree split cannot be made safe by writing its pages "carefully": the file
  receives them one at a time, and a power cut can come between any two.
- The write-ahead rule, and the four words that go with it: LSN, commit, checkpoint, redo.
- How a log with full page images and a commit record makes a multi-page split atomic.
- How a checksum chain finds the end of the usable log: a torn tail, or records left over
  from an earlier use of the file.
- How to test all of this: stop the simulated machine after every single write, in four
  crash modes, and compare the recovered tree with an oracle.

Prerequisites: [chapter 12](../12-disk-backed-bplus-tree/README.md) (the disk-backed
B+tree, the pager and the buffer pool; its last demo part is this chapter's starting
point) and [chapter 21](../21-durability-primitives/README.md) (`SimDisk`, sync, torn
writes, page checksums). The code of both is copied into this chapter unchanged.

## The idea in plain words

Chapter 12 ends with an uncomfortable demo. A leaf split changes four pages: the left
leaf, the new right leaf, their parent and the metapage. `flush` hands them to the file
one after the other and then syncs. If the power fails after two of the four, the file
contains a parent that points to a leaf that was never written. No ordering of the
writes fixes this: every prefix except "none" and "all" is a tree that never existed.

The fix is to stop treating the main file as the place where changes first land.

1. **Log first.** Before any page of the main file is touched, write the new contents of
   every changed page to a second file, the log, as a sequence of records. End the
   sequence with a small **commit record**. Sync the log.
2. **Then the main file.** Only now may the changed pages be written to their real
   places. This is the **write-ahead rule**: a page reaches the main file only after the
   log record describing its change is durable.
3. **Recover on open.** After a crash, read the log from the start. Every operation that
   has a commit record is applied again to the main file (**redo**). An operation
   without one is ignored.

Now look at a power cut at each moment. Before the log sync finished: the main file was
never touched, the log has no commit record for the operation, recovery ignores it, the
tree is the old one. After the log sync: the log holds complete images of all four pages,
so whatever mess the main file is in, recovery overwrites those four pages and the tree
is the new one. There is no third case. The commit record's arrival on disk is the single
instant at which the operation happens.

Some vocabulary:

- **LSN** (log sequence number): the position of a record in the log. Here it is a
  counter, 1, 2, 3, ..., that is never reused.
- **Checkpoint**: copying the logged pages to the main file, syncing it, and then
  emptying the log. Without it the log grows forever and recovery takes longer and longer.
- **Redo is idempotent**: writing the same page image twice gives the same page. So a
  crash during a checkpoint, or during recovery itself, is harmless. Run recovery again.
- **Physical redo with full page images**: the record contains the whole 4096-byte page.
  The simplest kind of record, and the most expensive (see "What this design costs").

### How does recovery know where the log ends?

A power cut can leave the last record half written. Worse, this chapter reuses the log
file after a checkpoint, so behind the new records lie old ones that look perfectly
healthy. Two devices deal with both:

- Every record carries a CRC that covers the record **and the CRC of the record before
  it**. The first record covers the CRC of the log header. This is a **checksum chain**:
  a record is valid only if everything before it is. The scan stops at the first record
  that does not chain.
- The header contains a **generation** number that goes up at every reset. An old record
  has a good CRC of its own, but it chains from the old header, so it is rejected.

## A worked example by hand

The scenario is chapter 12's: eleven keys are stored, key 15 is put next and splits the
leaf on page 2. `zig build run` and `cargo run` print the following (the full text is
[expected_output.txt](expected_output.txt)).

**Without a log** the split is five page writes and a sync:

```
  write 1: main page 4  (zeroes: the file grows by one page)
  write 2: main page 0
  write 3: main page 1
  write 4: main page 2
  write 5: main page 4
  sync main
```

Cut the power after N of them. `drop`, `keep` and `tear` are chapter 21's crash modes:
the writes not yet synced are all lost, all on disk, or each partly on disk.

```
N = 0: drop: before | keep: before | tear: before
N = 1: drop: before | keep: invalid (UnreachablePage) | tear: invalid (UnreachablePage)
N = 2: drop: before | keep: invalid (UnreachablePage) | tear: invalid (UnreachablePage)
N = 3: drop: before | keep: invalid (KeyOutOfBounds) | tear: invalid (UnreachablePage)
N = 4: drop: before | keep: invalid (BadPage) | tear: invalid (BadPage)
N = 5: drop: before | keep: after | tear: invalid (BadPage)
```

`drop` always gives the old tree, but only because every unsynced write vanished
together. An operating system writes its cache out in whatever order it likes, so any
subset of the five writes can be what a power cut leaves. The program tries all 32:

```
of the 32 subsets: 1 before, 2 after, 4 cannot be opened, 25 invalid, 0 valid with wrong contents
```

**With the log**, the same put produces five records and ten page writes:

```
  LSN 39  log bytes 4096..8216  image of page 0  crc 9f89b3f1
  LSN 40  log bytes 8216..12336  image of page 1  crc dad04a9e
  LSN 41  log bytes 12336..16456  image of page 2  crc 4144ab2b
  LSN 42  log bytes 16456..20576  image of page 4  crc 3154f203
  LSN 43  log bytes 20576..20600  commit (4 pages)  crc 2791045f
```

Each page record is a 24-byte header plus 4096 bytes; the commit record is the header
alone. The records are packed back to back from byte 4096 of the log file (the header has
the first 4096 bytes to itself), so the five records occupy log pages 1 to 5. The storage
calls are: five log page writes, `sync log` (the commit point), four main page writes,
`sync main`, one write of a new log header, `sync log` (the checkpoint is complete).

Do the crash table by hand for `keep`, where every unsynced write reached the disk:

- N = 3: log pages 1, 2, 3 are on disk. LSN 39 (pages 1 and 2) and LSN 40 (pages 2 and 3)
  are complete. LSN 41 runs into page 4, which is missing: its CRC fails, the scan stops.
  Two valid records, no commit record: ignored. The main file was never touched. Before.
- N = 5: all five log pages are on disk although the sync never ran. The chain is intact
  up to and including the commit record. Recovery replays four pages. After. Nobody was
  told that this put succeeded, yet it did; see "Pitfalls".
- N = 7: the checkpoint had written pages 0 and 1 of the main file: a broken tree, exactly
  as in the no-log table. But the log still holds the commit. Recovery rewrites all four
  pages. After.
- N = 10: the new log header is on disk. Nothing chains from it, so recovery finds zero
  records; the main file was synced before the header was written. After.

The program prints the same:

```
N = 3: drop: before [0 records, 0 commit] | keep: before [2 records, 0 commit] | tear: before [0 records, 0 commit]
N = 5: drop: before [0 records, 0 commit] | keep: after [5 records, 1 commit] | tear: before [0 records, 0 commit]
N = 7: drop: after [5 records, 1 commit] | keep: after [5 records, 1 commit] | tear: after [5 records, 1 commit]
N = 10: drop: after [5 records, 1 commit] | keep: after [0 records, 0 commit] | tear: after [5 records, 1 commit]
```

## Code walk-through

New in this chapter (Zig file names; the Rust files have the same names with `.rs`):

| File | What it is |
|---|---|
| `machine.zig` | `Machine`: two `SimDisk`s (main file, log file) with one power switch and a write counter |
| `adapter.zig` | `PageFile`: chapter 12's storage interface served by chapter 21's |
| `wal.zig` | `Wal`: log format, commit, checkpoint, recovery; `LogScanner` |
| `db.zig` | `Db`: recovery on open, then the tree; `put`, `putBatch` |
| `crash.zig` | the crash loop, with the log and without |

### Two storage interfaces, one adapter

Chapter 12's pager talks to a byte-addressed storage (`read(offset, buffer)`, errors
`ShortRead` and `StorageFailure`). Chapter 21's `SimDisk` is page-addressed
(`readPage(page_no, *Page)`, errors `PowerLoss`, `OutOfBounds`, ...). The pager only ever
moves whole pages at page-aligned offsets, so the first interface can be served by the
second with one division. `PageFile` in `adapter.zig` does exactly that and nothing else;
it is how the "no log" experiments run chapter 12's tree on a disk that can lose power.
`OutOfBounds` on a read becomes `ShortRead`; every other error becomes `StorageFailure`.

### The log is slid in underneath the pager

`Wal` is the second implementation of chapter 12's storage interface. The tree, the
buffer pool and the pager are not changed at all:

```
DiskBTree -> BufferPool -> Pager -> Wal -+-> log file   (appended, synced at commit)
                                         +-> main file  (written only by checkpoint)
```

- `write(page)` copies the image into `pending`, a table in memory. No file is touched.
- `sync()` is **commit**. Chapter 12's `flush` already means "write every dirty page,
  then sync", so `Db.put` is `tree.put` followed by `tree.flush`.
- `read(page)` returns the newest image: `pending`, then `index` (committed, in the log,
  not yet checkpointed), then the main file, whose page checksum is verified.

This answers the buffer-pool question. Chapter 12's pool evicts dirty pages in the middle
of an operation. Either eviction of dirty pages is forbidden until commit (and the pool
sized for the largest operation), or it is routed through the log. This chapter routes
it: an evicted page arrives at `Wal.write` and waits in `pending` like any other, so the
pool can stay at 2 frames, and the central test runs with exactly that. The test
"eviction goes through the log" checks that 36 puts with a 2-frame pool and no checkpoint
do not write the main file once.

### Commit

```zig
var fba: std.heap.FixedBufferAllocator = .init(self.record_buffer);
const a = fba.allocator();
for (self.pending.entries.items) |e| {
    checksum.seal(e.image, e.id);                       // chapter 21's page checksum
    const rec = a.alloc(u8, record_header_len + page_size) catch return error.CommitTooLarge;
    @memcpy(rec[record_header_len..], e.image);
    chain = encodeRecord(rec, lsn, kind_page, e.id, chain);  // CRC covers `chain`
    lsn += 1;
}
// ... one more 24-byte allocation for the commit record ...
try self.appendToLog(self.record_buffer[0..fba.end_index]);
try self.log.sync();   // the commit point
```

The image is sealed with its page checksum before it is logged, so checkpoint and
recovery copy log images to the main file byte for byte. The log file is page-addressed
but records are not page-sized, so `appendToLog` usually rewrites the last, partly
filled log page first. Under chapter 21's sector model that is safe: the bytes of
earlier records are rewritten unchanged, so a torn sector there is the same either way.

After the sync the images move from `pending` to `index`. Pages are always processed in
page-id order (the tables are sorted), which is what makes the Zig and Rust programs
issue identical writes.

### Checkpoint and recovery

`checkpoint` writes every image of `index` to the main file, syncs it, and then starts a
new log generation with one header write and one sync. The header fits in the first
512-byte sector of its page, which is written atomically. Until the new header is
durable, the old log is complete and a crash simply replays it.

`recover` scans with `LogScanner.next`, which returns `null` at the first record whose
LSN is not the expected one or whose CRC does not chain. Page records are collected in
`open_op`; a commit record moves them to `committed` (newest image per page wins);
whatever is left in `open_op` at the end is the interrupted operation and is dropped.
Then `committed` is written to the main file, synced, and the log is reset: recovery
always ends with a checkpoint.

**Page LSNs** are absent here on purpose. With full images, redo never has to ask "was
this change already applied?", because applying it again is harmless. A system whose
records are *deltas* ("insert this tuple at offset 7") cannot redo blindly: inserting
twice is wrong. So every page stores the LSN of the last record applied to it, and redo
skips a record when the page's LSN is already at or beyond it. Postgres does exactly
this; see below.

### Rust differences

- Zig's `Db` is one heap-allocated struct whose parts point at each other (pager to wal,
  pool to pager, tree to pool). In Rust the tree owns the pool, which owns the pager,
  which owns a `Box<dyn Storage>`. The `Db` needs a second handle to the log for
  checkpoints, so the `Wal` lives in an `Rc<RefCell<Wal>>` and the pager holds a
  `WalStorage` wrapper. The same goes for the `Machine` shared by its two storage ports.
- Zig's `PageTable` is a hand-written sorted array (its images come from two different
  allocators); Rust uses `BTreeMap<PageId, Box<Page>>`.
- Zig merges error sets (`Db.Error = DiskBTree.Error || Wal.Error`); Rust wraps them in
  `DbError::{Tree, Wal}`. Both lose information at the storage interface, which only
  knows `StorageFailure`; `Wal.last_error` keeps the real cause.
- Rust has no failing allocator in std, so the allocation-failure test exists only in Zig.
- `Cargo.toml` sets `opt-level = 2` for the dev and test profiles: unoptimised, the
  crash loop's checksumming makes `cargo run` several times slower. Overflow checks and
  debug assertions stay on.

### The crash loop

`crash.zig` is the chapter's central test. One run: a fresh seeded `Machine`, power off
after N page writes (counted over both files), apply the workload until a put fails,
`crash(mode)`, reopen, `validate`, compare every key and value with the oracle. The
loop does this for every N from 0 to the total number of writes and for all four crash
modes. The workload is 36 seeded puts of long keys and large values, enough for 16 leaf
splits, an interior split and two root splits.

The oracle accepts exactly two states: the first `acked` puts (those that returned
success), or those plus the one in flight. Nothing else. From the program:

```
WITH the log (3-frame pool, checkpoint every 4 commits): 211 page writes, power cut after N = 0..211
  mode    runs  before  after  open fails  invalid  wrong contents
  drop     212     147     65           0        0               0
  keep     212     111    101           0        0               0
  tear     212     147     65           0        0               0
  random   212     147     65           0        0               0
WITHOUT the log (chapter 12: put, then flush): 129 page writes, power cut after N = 0..129
  mode    runs  before  after  open fails  invalid  wrong contents
  drop     130     130      0           0        0               0
  keep     130       7     37           2       84               0
  tear     130      21      3           2      104               0
  random   130       7     10           2       97              14
exactly the before or the after state: with the log 848 of 848 runs, without 215 of 520
a second power cut during recovery (every 5th N, after each recovery write, keep and random): 524 of 524 runs exact
```

The 14 runs in the last column of the control experiment are the worst outcome of all: a
tree that passes `validate` but has lost a key whose put had returned success.

A larger loop (120 puts) runs with `zig build test -Dlong=true` or
`cargo test --features long`.

## In real databases

**Turso (SQLite format): whole-page frames, commit marker, checksum chain.** This
chapter's log is a simplified version of SQLite's WAL as Turso implements it. A WAL
frame is a 24-byte header plus one page, after a 32-byte file header
(`turso/core/storage/sqlite3_ondisk.rs:404-405`). The frame header holds the page number,
a `db_size` field, two salts copied from the file header and a two-word checksum
(`sqlite3_ondisk.rs:476-496`). There is no separate commit record: the last frame of a
transaction carries the database size in `db_size`, and a frame with `db_size > 0` *is*
the commit marker (`sqlite3_ondisk.rs:499-501`). The checksum is cumulative: each frame's
checksum is seeded with the previous frame's (`sqlite3_ondisk.rs:1924-1925`,
`checksum_wal` at `:2300-2325`). When Turso scans a WAL it stops at the first frame whose
salt does not match the header or whose checksum does not chain
(`sqlite3_ondisk.rs:1909-1937`), and it only advances "last valid frame" at a commit frame
(`:1945-1947`). The salts play the role of this chapter's generation number. Reads go
through the WAL first: the pager asks `find_frame` for the newest frame of a page and
falls back to the database file (`turso/core/storage/pager.rs:3610`,
`turso/core/storage/wal.rs:3684`). The commit path is `commit_wal_inner`
(`pager.rs:4562`). Summary in `research/turso.md`, section 14.

**Postgres: logical records, page LSNs, and two records per split.** Postgres states the
write-ahead rule in the page header documentation: the LSN enforces "thou shalt write
xlog before data", and "A dirty buffer cannot be dumped to disk until xlog has been
flushed at least as far as the page's LSN" (`postgres/src/include/storage/bufpage.h:152-154`). Its buffer manager
enforces it per page, by comparing the page's LSN with the flushed position of the log;
that is the "forbid until logged" alternative to this chapter's routing.

A nbtree split is **not** one atomic unit in the log. The split of one level is one
record (`XLOG_BTREE_SPLIT_L` or `_R`, `postgres/src/include/access/nbtxlog.h:27-43`,
replayed by `btree_xlog_split` at `postgres/src/backend/access/nbtree/nbtxlog.c:246`),
and the insertion of the new downlink into the parent is a second record. Between the
two, the left page carries the flag `BTP_INCOMPLETE_SPLIT`: set by the split
(`nbtinsert.c:1580`) and by its redo (`nbtxlog.c:415`), cleared by the parent insertion
and its redo (`nbtinsert.c:1317`, `_bt_clear_incomplete_split` at `nbtxlog.c:136-155`).
A crash between the records leaves a valid B-link tree (chapter 20): searches reach the
right half through the right link, and the next writer that passes finishes the split.
The nbtree README says "A single WAL entry is effectively an atomic action"
(`postgres/src/backend/access/nbtree/README:625-626`); a split is two such actions with a
well-defined state between them. This chapter makes the whole put one atomic action,
which is simpler and only possible because there is one writer.

Postgres records are mostly deltas, so redo consults the page LSN: if the page's LSN is
already at or past the record's, the block is skipped
(`postgres/src/backend/access/transam/xlogutils.c:444-445`). Deltas alone cannot repair a
torn page, so the first change to a page after a checkpoint logs a full image of it
(`needs_backup = (page_lsn <= RedoRecPtr)`,
`postgres/src/backend/access/transam/xloginsert.c:698`), minus the unused "hole" in the
middle of the page (`xloginsert.c:738-743`). Summary in `research/postgres.md`, section 10.

**TigerBeetle: the testing style.** TigerBeetle has no B-tree, but its deterministic
simulator is the model for the crash loop: "Because our simulator is deterministic based
on a _seed_ number and the Git commit, we can perfectly reproduce any bugs discovered in
testing" (`tigerbeetle/docs/internals/vopr.md:6-8`; see `research/tigerbeetle.md`,
section 10.4). Our loop is far smaller: one process, no network, and a fault schedule
that is exhaustive over N instead of random.

### What this design costs, and how real systems pay less

Part 4 of the program output measures it for the 36-put workload:

```
the puts carry 39385 bytes of keys and values
  checkpoint  log bytes  largest  page     log page  main page  syncs
  every       appended   log      records  writes    writes
  1              445848    24744      108       182        106    110
  4              445848    66016      108       155         56     56
  (largest commit: 6 page images; 37 commits)
  16             445848   198144      108       148         24     42
  never          445848   445848      108       146          0     38
without the log: 129 page writes in place, no second copy, and Part 3's failures
```

- **Every dirtied page is logged in full.** 39385 bytes of data became 445848 bytes of
  log, about eleven times as much, because a put that changes 300 bytes of a leaf logs
  the whole leaf and the whole metapage. Postgres logs a delta unless it is the first
  change after a checkpoint (source above). Logging only the changed byte ranges, or
  compressing images, are textbook refinements not shown here.
- **Every page is written twice**, to the log and to the main file. Rare checkpoints
  soften this: with one every 16 commits the main file receives 24 page writes instead
  of 106, because a page changed by several commits is copied once. The price is a log
  that grows until the checkpoint ("largest log"), and a longer recovery.
- **One sync per put.** Real systems batch several transactions' commit records into one
  sync (group commit; textbook, not verified in the sources here). `putBatch` shows the
  single-writer version: several puts, one commit record.
- One commit is limited to `max_commit_pages` images (default 32), the size of the record
  buffer. A larger operation fails with `CommitTooLarge`.

## Allocator notes

- **`FixedBufferAllocator` for assembling log records** (`Wal.commit`). The `Wal`
  allocates one slab at `init`; each commit wraps it in a fresh `FixedBufferAllocator`
  and allocates the records one by one. A bump allocator hands out adjacent memory, so
  the used prefix of the slab *is* the byte run to append, and "reset" is free. Running
  out is the documented size limit (`CommitTooLarge`, pinned by a test). A
  general-purpose allocator would allocate and free 4 KiB per record, could fail in the
  middle of a commit, and would not give contiguous records. The slab lives as long as
  the `Wal`; its contents mean nothing after `commit` returns.
- **An arena for recovery** (`Wal.recover`). Recovery reads an unknown number of page
  images and drops pointers along the way (a newer image of a page replaces an older
  one). All come from one `ArenaAllocator`, destroyed by a single `defer` on success and
  on every error path. Freeing images one by one would need bookkeeping for exactly the
  replaced ones. Nothing read during recovery is needed afterwards, because recovery
  ends with a checkpoint.
- **General-purpose allocator** for `pending` and `index`: their images are created and
  destroyed one at a time over the life of the database. `commit` reserves the `index`
  capacity it needs *before* writing to the log, so that nothing after the commit point
  can fail for lack of memory.
- Tests use `std.testing.allocator`. The test "allocation failure at any point leaves a
  recoverable database and leaks nothing" fails every allocation of `Db.open` and of
  twelve puts in turn, and then reopens the files with a working allocator.

## Pitfalls

- **An error from `put` does not mean "not stored".** If the power fails after the commit
  record is durable but before `put` returns, the caller sees an error and the key is
  there after recovery. That is why the oracle allows "after" for the put in flight. The
  only promises are: a put that returned success is never lost, and a put is never half
  applied.
- **Syncing in the wrong order.** Resetting the log before the main file is synced loses
  committed pages; writing main-file pages before the log is synced leaves a torn tree
  with nothing to repair it. The test "write-ahead rule" checks the order on a trace.
- **Trusting a record because its own checksum is good.** After a reset the file is full
  of valid-looking old records; only the chain from the current header makes a record
  current (test "records of an earlier generation are stale": 9 old records, 3 accepted).
- **The chain cuts both ways.** A damaged record in the middle of the log hides every
  committed operation behind it (test "recovery stops at the first record whose checksum
  chain breaks"). A power cut only damages the unsynced tail; a failing disk can do this.
- **This fault model is limited.** Sector-atomic writes, sync that really syncs, no
  bit rot, one writer. Recovery is exactly as trustworthy as those assumptions.

## Exercises

1. (easy) In the worked example, what does recovery find after a power cut at N = 4 in
   mode `keep`? Predict the number of valid records and the state, then check the output.
2. (easy) Swap the last two steps of `checkpoint` in your head: reset the log, then sync
   the main file. Describe a crash that now loses a committed key.
3. (medium) Change `Db.put` so that it checkpoints after every commit. Which numbers of
   the crash-loop table change, and which cannot change?
4. (medium) Add a `rollback` to `Db`: discard the uncommitted puts of a batch. What must
   be thrown away besides `Wal.pending`?
5. (hard) Replace the full image of the metapage by a small logical record "set page
   count and key count". What must recovery now know that it did not need before, and
   which of Postgres's mechanisms does this lead to?

Solutions: [solutions.md](solutions.md).

## Where next

- Previous: [chapter 21, durability primitives](../21-durability-primitives/README.md).
- Next: [chapter 23, copy-on-write B-trees](../23-copy-on-write-btrees/README.md), the
  other way to make a multi-page change atomic: never overwrite, and switch one root
  pointer.
- Visualization: [page 1, a split torn without a log](viz/index.html) and
  [page 2, the log timeline with a crash scrubber](viz/log.html).

Run it:

```
cd zig  && zig build test --summary all && zig build run
cd rust && cargo test && cargo run
```
