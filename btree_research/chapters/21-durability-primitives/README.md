# Chapter 21: Durability primitives

## What you will learn

- What `write` promises (very little) and what `fsync` promises (that the bytes survive
  a power cut).
- What a *torn write* is and why a 4096-byte page is exposed to it.
- How a per-page checksum detects a torn or misplaced page, and why detection is not
  repair.
- The two classic repairs, both of which keep a second complete copy: the double write
  (built here) and full-page images in a log (previewed here, built in chapter 22).
- How to test all of this without pulling a power cord: a simulated disk with seeded
  crashes.

Prerequisites: chapter 09 (a file as an array of 4096-byte pages). Chapter 12 showed a
disk B+tree that is "explicitly not crash-safe"; this chapter supplies the tools and
chapter 22 uses them to fix it.

The code in this chapter is the base that chapter 22 copies: `storage`, `sim_disk`,
`page` (and `file_storage`) are small standalone files with their API documented at the
top of each.

## The idea in plain words

A B-tree page travels through several layers before it is safe:

```
your buffer --write--> OS page cache --(later, or on fsync)--> drive cache --> platter / flash
```

`write` returns as soon as the bytes are in the operating system's cache. From then on
every `read` sees the new bytes, which makes it very easy to believe they are stored.
They are not. If the power fails, each write that was not followed by a completed
`fsync` has one of three fates:

1. **Dropped.** It never left the cache. The disk still holds the old page.
2. **Kept.** The OS happened to flush it in time. The disk holds the new page.
3. **Torn.** The drive was in the middle of it. The disk holds *part* of the new page
   and part of the old one.

The third fate exists because a database page is larger than the unit the drive writes
atomically. This chapter uses the textbook model: a page is eight 512-byte sectors, each
sector is written entirely or not at all, and the sectors of one page need not arrive in
order. (Real devices vary: TigerBeetle, for example, asserts a 4096-byte sector,
`tigerbeetle/src/constants.zig:488-495`.) The model's point is only that *some* unit
smaller than or equal to a page is atomic and nothing larger is.

You do not control which fate a write gets. You control one thing: after `fsync`
returns, every earlier write is in fate 2. So the rules of the game are:

- Until `fsync`, assume any subset of your writes may vanish, and any of them, several
  at once, may be half done.
- A torn page is garbage that looks like a page. You need a **checksum** to notice.
- Noticing is not enough. The old version was overwritten and the new version is
  incomplete, so the page is lost unless **another complete copy** exists somewhere.
  Every crash-safe design is a plan for where that copy lives.

## A worked example by hand

Page 0 holds version A, durably. We overwrite it with version B and the power fails
during the write. Draw the page as eight sectors:

```
on disk before:   A A A A A A A A     checksum of A in the last 4 bytes (sector 7)
write issued:     B B B B B B B B     checksum of B in the last 4 bytes
power fails; the drive had finished sectors 1, 2, 6 and 7:
on disk after:    A B B A A A B B
```

Read the page back. Its last four bytes are B's checksum (sector 7 is new), but the
payload is a mix, so the checksum computed over what is actually there does not match.
The reader knows the page is damaged. It does *not* know which sectors to trust: every
sector looks like plausible data.

Now the same update with a double write. Reserve a second location, the *slot*.

```
step 1: write B to the slot, fsync      slot: B B B B B B B B   home: A A A A A A A A
step 2: write B to home, fsync          slot: B B B B B B B B   home: B B B B B B B B
```

Crash during step 1: the slot may be torn, home is still a perfect A. Crash during
step 2: home may be torn, but the slot is a perfect, durable B. After a crash, recovery
looks at the slot: if its checksum is good, copy it over home; if not, leave home alone.
Either way home ends up as all A or all B. One page write has been made atomic, at the
price of writing everything twice.

## Code walk-through

Run it:

```
cd zig  && zig build test --summary all && zig build run
cd rust && cargo test && cargo run
```

Both programs print exactly `expected_output.txt`:

```
Chapter 21: durability primitives
page = 4096 bytes = 8 sectors of 512; one letter per sector; SimDisk seed 2121

== 1. A write is not durable until sync ==
write page 0 = A: pending=1 durable_pages=0
read  page 0 -> AAAAAAAA ok
crash(drop): dropped=1 kept=0 torn=0
read  page 0 -> out of bounds (size=0)
write page 0 = A, sync: pending=0 durable_pages=1
crash(drop): dropped=0 kept=0 torn=0
read  page 0 -> AAAAAAAA ok

== 2. A torn write, caught by the checksum ==
write page 0 = B: pending=1 durable_pages=1
read  page 0 -> BBBBBBBB ok
crash(tear): dropped=0 kept=0 torn=1
read  page 0 -> ABBAAABB corrupt
checksum: stored=a6ca308e computed=11258b39

== 3. The checksum binds a page to its address ==
page sealed for address 0: checksum=70fea20f
verified at address 0: ok
verified at address 1: corrupt (expected checksum 8eec239b)

== 4. Double write: a second copy makes repair possible ==
layout: slot = page 0, home = page 1
update to A: writes=2 syncs=2
update to B, power off after 2 writes: PowerLoss
crash(tear): dropped=0 kept=0 torn=1
read  page 0 -> BBBBBBBB ok
read  page 1 -> ABBAAABB corrupt
recover: intact=0 rolled_forward=0 restored=1 blank=0
read  page 1 -> BBBBBBBB ok

== 5. Crash at every write: 4 crash modes x 100 seeds per line ==
in-place update (1 write, 1 sync):
  power off after 0 writes: old=400 new=0 corrupt=0
  power off after 1 writes: old=125 new=133 corrupt=142
double write (2 writes, 2 syncs), after recover:
  power off after 0 writes: old=400 new=0 corrupt=0
  power off after 1 writes: old=267 new=133 corrupt=0
  power off after 2 writes: old=0 new=400 corrupt=0
```

Section 5 is the result to remember. Updating in place, 142 of 400 simulated power cuts
leave a corrupt page (these are counts from this simulator's fault model, not a
statistic about real disks). Through the double write the count is zero at every crash
point, and once the first sync has passed (2 writes issued) the new version always wins.

### Zig

| File | What it holds |
|------|---------------|
| `storage.zig` | `Storage`: `readPage`, `writePage`, `sync`, `size`; constants `page_size`, `sector_size` |
| `file_storage.zig` | `FileStorage`: the interface over a real file (`pwrite`, `fsync`) |
| `sim_disk.zig` | `SimDisk`: durable image + pending writes, `crash(mode)`, `powerOffAfterWrites(n)` |
| `page.zig` | `seal`, `verify`, `readChecked`: CRC-32 in the last 4 bytes |
| `doublewrite.zig` | `DoubleWrite.update`, `recover`, `read` |
| `main.zig` | the five experiments |

**The interface.** Zig has no interface keyword. `Storage` is a struct with an opaque
pointer and a pointer to a table of four functions, the same shape as
`std.mem.Allocator`:

```zig
pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub fn writePage(self: Storage, page_no: u64, page: *const Page) Error!void {
        return self.vtable.writePage(self.ptr, page_no, page);
    }
    // readPage, sync, size likewise
};
```

`disk.storage()` and `file.storage()` return this value; everything above it
(`readChecked`, `DoubleWrite`) takes a `Storage` and cannot tell which it got. The test
"the same code runs on SimDisk and on a real file" checks that both end with
byte-identical pages.

For that to work the two implementations must agree on the corner cases, so the
contract is written down at the top of `storage.zig` and tested ("SimDisk and
FileStorage answer every call alike" runs one random stream of writes, reads and syncs
against both and compares every answer):

- `size()` is the highest page number ever written plus one, counting writes that are
  not durable yet.
- Reading below `size()` always succeeds. A page that was never written (a *hole*, left
  by writing page 2 into an empty store) reads as zeroes. Reading at or beyond `size()`
  is `error.OutOfBounds`.
- A write to a page number at or beyond the implementation's `max_pages` is
  `error.OutOfBounds`. A write refused with `OutOfBounds`, `OutOfMemory` or `PowerLoss`
  changes nothing. `error.InputOutput`, which only the real file can return, is
  different: part of the page may have reached the file, so treat that page as torn.
- On a powered-off `SimDisk`, `error.PowerLoss` comes before every other check.

**The simulator.** `SimDisk` keeps the two states of the plain-words section apart, in
two of its fields:

```zig
/// The platter: a whole number of pages.
durable: std.ArrayList(u8) = .empty,
/// Unsynced writes, oldest first.
pending: std.ArrayList(Pending) = .empty,
```

- `writePage` copies the page and appends it to `pending`. `durable` is untouched.
- `readPage` returns the newest pending write for that page, else the durable bytes,
  else zeroes for a hole. This is the OS cache answering, and the reason an unsynced
  write looks stored.
- `sync` applies all pending writes in order and empties the list.
- `crash(mode)` decides each pending write's fate, empties the list and "reboots".
  `.drop` and `.keep` are fates 1 and 2 for everything. `.tear` gives every pending
  write a random sector mask between 1 and 254 (at least one sector new, at least one
  old). `.random` picks one of the three fates per write. All draws come from the
  SplitMix64 seeded in `init`, so a failure is reproduced by its seed.

The heart of it is the loop in `apply`, which copies only the sectors selected by the
mask; a sector whose bit is 0 keeps its old bytes:

```zig
for (0..sectors_per_page) |s| {
    if (mask & (@as(u8, 1) << @intCast(s)) == 0) continue;
    const at = s * sector_size;
    @memcpy(dst[at..][0..sector_size], w.data[at..][0..sector_size]);
}
```

`powerOffAfterWrites(n)` is how tests reach every crash point: `n` more writes succeed,
then every operation returns `error.PowerLoss` until `crash` is called. A test runs the
operation under test with n = 0, 1, 2, ... and checks the recovered state each time.
Chapter 22 uses exactly this loop on a B-tree split.

**Checksummed pages.** `seal(page, page_no)` stores CRC-32 of *(page number, payload)*
in the last four bytes; `verify` returns `.ok`, `.blank` (all zeroes: never written) or
`.corrupt`. The page number is mixed in so that a correct page at the wrong address
fails too (experiment 3). The tests check that every single-bit flip (all 32768 bits of
a page, one at a time) and all 254 torn mixes of two sealed versions are detected.
`readChecked(storage, page_no, out)` is `readPage` plus `verify`; a page at or beyond
the end of the store counts as `.blank`, which is what recovery wants on a fresh store.

**Double write.** `update` is the two steps of the hand example; the comment on the
first `sync` says why it cannot be skipped. `recover` reads slot and home for each
logical page and applies the rule "slot ok: copy it home; otherwise keep home". If both
copies are damaged it returns `error.Unrecoverable` rather than hand back garbage. The
test "crash at every write, every mode" runs 480 crashes and requires a clean old or new
version every time; another test crashes *recovery itself* and recovers again; a seeded
model test runs 40 updates over three logical pages per seed, with crashes in every mode
and interrupted recoveries, and compares all three pages with an oracle after each step.

One limit to remember: `recover` cannot see which of two intact copies is newer. It
assumes the slot is, which is true only because `update` writes the slot first. So
`recover` is correct for pages written through `update` and for nothing else; a home
page written directly is replaced by the slot's older image at the next recovery (there
is a test for this too, and the sandbox in the visualization lets you do it).

### Rust

Same files, names in snake_case, same tests, same output. The differences:

- **Interface.** `trait Storage` with `&mut dyn Storage` is the pointer-plus-vtable pair
  that Zig spells out by hand. `size` takes `&self`, the rest `&mut self`.
- **Borrowing.** `DoubleWrite<'a>` holds `&'a mut dyn Storage`, so while it exists the
  test cannot touch the `SimDisk` to cut the power. The tests therefore build a
  `DoubleWrite` for each call (`DoubleWrite::new(&mut disk, 1).update(..)`). In Zig the
  interface value is a copyable pointer pair and nothing stops two holders; Rust makes
  the aliasing visible.
- **Pending writes.** Instead of an arena, a bump `Vec<u8>`: write number `i` lives at
  offset `i * PAGE_SIZE`, and `clear()` drops them all while keeping the capacity.
- **Scratch memory.** `recover` takes `&mut [Page]` instead of an allocator; a slice
  shorter than two pages is its `OutOfMemory`.
- **Allocation failure.** Zig tests `writePage` with `checkAllAllocationFailures` and a
  `FailingAllocator`. Rust mirrors this with `set_pending_limit`, a budget of pending
  writes after which `write_page` returns `OutOfMemory` and changes nothing.
- **Layout.** A `lib.rs` (modules and `run`) plus a seven-line `main.rs`, so that public
  items used only by tests are not dead code.

## In real databases

**Page checksums.** Turso has an optional per-page checksum: XXH3-64 of the first 4088
bytes, stored little-endian in the last 8 bytes, only for 4096-byte pages
(`turso/core/storage/checksum.rs:4-6`, `:35-48`, `:82-84`). Our layout is the same shape
with a 4-byte CRC. Reserving the tail shrinks the usable page, which every B-tree
capacity formula must respect. Postgres stores a 16-bit checksum in the page header
(`postgres/src/include/storage/bufpage.h:189`) and mixes in the block number "to detect
the case where a page is somehow moved to a different location"
(`postgres/src/include/storage/checksum_impl.h:160-193`, the XOR is at `:193`), which is
what `seal(page, page_no)` imitates. Data checksums are optional in Postgres; when
they are enabled the checksum is verified as a page is read (`PageIsVerified`,
`postgres/src/backend/storage/page/bufpage.c:94`; the call at `:120` sits under
`if (DataChecksumsNeedVerify())` at `:118`).

**Full-page images (Postgres).** Postgres does not double-write. Its second copy lives
in the write-ahead log (WAL): a file to which a description of every change, a *WAL
record*, is appended and synced before the changed page itself is written. Chapter 22
builds one. A *checkpoint* is the moment at which all pages changed so far have been
written to their homes and synced, so that the log before that point is no longer needed.
The first time a page is modified after a checkpoint, the WAL record carries a complete
image of the page (`needs_backup = (page_lsn <= RedoRecPtr)`,
`postgres/src/backend/access/transam/xloginsert.c:698`; described in
`postgres/src/backend/access/transam/README:562-578`). The setting's own description
states the problem: "A page write in process during an operating system crash might be
only partially written to disk. During recovery, the row changes stored in WAL are not
enough to recover" (`postgres/src/backend/utils/misc/guc_parameters.dat:1133-1135`).
A record that describes only the change (a *delta*, such as "insert this tuple") can
only be replayed onto an intact page; a full image can be replayed onto anything. Compared with the double write: the image is
written once per page per checkpoint cycle instead of on every update, and it shares the
log's sequential write and its fsync. Chapter 22 builds a log made only of such images.

**Whole-page log frames (Turso).** Turso's WAL, in the SQLite format, logs every changed
page as a whole frame, and each frame's checksum is seeded with the previous frame's, so
a torn or stale frame ends the valid log (`checksum_wal`,
`turso/core/storage/sqlite3_ondisk.rs:2280-2325`; frame preparation `:2157-2215`;
`research/turso.md` section 14). Details in chapter 22.

**Double write.** The technique is textbook; the well-known implementation is InnoDB's
doublewrite buffer, which is not among the code bases studied here, so nothing about it
is claimed beyond the idea. Our one-slot-per-page layout is the simplest thing that
shows it.

**Never overwrite (DuckDB, TigerBeetle).** A third answer is to never overwrite a live
page at all. DuckDB writes new blocks, fsyncs, and only then writes a header that points
at them: "We need to fsync BEFORE we write the header to ensure that all the previous
blocks are written as well" (`duckdb/src/storage/single_file_block_manager.cpp:1423`);
headers are checksummed (`:598-629`). TigerBeetle stores each block's checksum in its
*parent* to catch misdirected and stale blocks, which a page-local checksum cannot
(`research/tigerbeetle.md`, section 9).

**Simulated faults (TigerBeetle).** `SimDisk` is a small cousin of TigerBeetle's test
storage, "In-memory storage, with simulated faults and latency"
(`tigerbeetle/src/testing/storage.zig:1`). Its options include probabilities for
corrupting a sector on read or write, misdirecting a write, and corrupting "a sector of
a pending write's target" on a crash (`:68-79`); on `reset` it walks the pending writes
and corrupts target sectors from its seeded PRNG (`:269-285`). The same seed gives the
same faults, which is what makes a failure debuggable.

## Allocator notes

**Arena in the simulator.** Pending writes are born one by one and die together: at a
`sync` (all applied) or a `crash` (all resolved). That is the lifetime an
`ArenaAllocator` models, so `SimDisk` puts the page copies and the pending list in one
and calls `reset(.retain_capacity)` at those two points; after the first few writes the
simulator stops asking the parent allocator for memory. With a general-purpose allocator
we would have to free every page copy individually and a missed free would be a leak;
with the arena there is nothing to forget. What would go wrong the other way: putting
the *durable* image in the arena. It must outlive every reset, so it belongs to the
general-purpose allocator passed to `init`.

One more decision: `writePage` reserves the durable space its page may need before
accepting the write. `sync` and `crash` therefore never allocate and cannot fail with
`OutOfMemory`, which keeps "apply pending writes" a simple infallible loop. The test "a
failed write leaves the disk unchanged" checks the other half: an allocation failure in
`writePage` changes nothing. The decision has a price. A pending write to page p
reserves p + 1 pages at once, and the reservation is kept even if a crash drops the
write: one write to page 1000 holds 4 MiB before anything is durable. `reserveDurable`
asks for exactly that much on such a jump (and grows by half when pages are appended one
by one), but a test that writes to very high page numbers still pays for the whole
range. A second consequence: the reservation may move the durable buffer, so the pointer
returned by `durablePage` is only valid until the next `writePage`, `sync` or `crash`.
(Rust's `Vec::resize` aborts on a failed allocation instead of returning an error, so
reserving would buy nothing there: the Rust version grows the image when a write lands.)

**`FixedBufferAllocator` for sector buffers.** `DoubleWrite.recover` needs exactly two
page buffers, aligned to a sector (direct I/O, meaning writes that bypass the OS cache
and go straight to the device, requires sector-aligned buffers; the simulator does not,
but the habit is cheap). It takes them from a caller-supplied
allocator, and every caller passes a `FixedBufferAllocator` over
`DoubleWrite.scratch_bytes` of stack. Recovery runs when the system is at its most
fragile; a fixed buffer means its memory need is known at compile time and it cannot
fail half way because the heap is exhausted. If the buffer is too small, `recover`
returns `OutOfMemory` before touching the disk (tested). A general-purpose allocator
would work but adds a failure mode for no benefit; an arena would work but has nothing
to free in bulk.

`update` allocates nothing: it seals the caller's buffer in place, twice.

## Pitfalls

- **Believing a read.** Reading back what you wrote proves the cache works, nothing
  more. Only a completed sync makes a statement about the disk.
- **Sealing too early.** Change one payload byte after `seal` and the page is corrupt.
  Seal last, immediately before `writePage`.
- **Treating a checksum as repair.** It answers "is this page whole?", never "what
  should it be?".
- **Trusting a page's own checksum too much.** It cannot detect a *lost* write: the old
  page is intact and verifies. Mixing in the page number catches misplacement, not
  staleness. That needs the expected checksum or a version stored elsewhere
  (TigerBeetle's parent pointers, or an LSN, a position in the log used as a page
  version, as in chapter 22).
- **A torn write that verifies.** If a write changes few sectors, a tear can produce
  exactly the old or the new page. That is not a missed error: the page really is one of
  the two versions.
- **Skipping the first sync of the double write.** Without it both copies can be in
  flight at once and both can tear.
- **Ignoring an fsync error.** After a failed fsync the kernel may have discarded the
  dirty pages, so retrying and getting success proves nothing (general OS behaviour, not
  verified against a source in `research/`). Treat it as a crash.
- **All-zero pages.** A hole is not corruption. `verify` reports `.blank`; the caller
  must decide whether a blank page is acceptable at that place.
- **What the simulator leaves out.** No bit rot, no misdirected writes, no lost file
  metadata (a real file's *length* is also only durable after fsync, and a new file's
  directory entry needs an fsync of the directory). `SimDisk` tests the write/sync
  discipline, not every way hardware fails.

## Exercises

1. (easy) In experiment 2 the torn page is `ABBAAABB`. Which sector holds the stored
   checksum, and is it the old or the new one? Would the page verify if the mask had
   been `AAAAAAAB`?
2. (easy) `DoubleWrite.update` syncs twice. Remove the first sync in your copy and run
   the tests. Which test fails, and what is the sequence of events that breaks it?
3. (medium) Add a crash mode `.tear_prefix` in which a torn write keeps a random
   non-empty proper *prefix* of its sectors (sectors arrive in order). Does any test in
   this chapter need to change? Why is the arbitrary-subset mode the safer one to test
   against?
4. (medium) A lost write: page 0 holds sealed A; a sealed B is written, the crash mode
   is `.drop`. Show with a test that `verify` returns `.ok`. Then design the smallest
   change that lets a reader detect that the page is stale, and say where the extra
   information must live.
5. (hard) Extend `DoubleWrite` to update *two* logical pages atomically (both new or
   both old), as a B-tree split needs. Explain why two independent `update` calls are
   not enough, then make it work with a slot area that holds both images plus a commit
   mark. You have just invented a tiny write-ahead log; chapter 22 does it properly.

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [Chapter 20: B-link trees](../20-blink-trees/README.md)
- Next: [Chapter 22: WAL and crash recovery](../22-wal-and-crash-recovery/README.md)
- Visualization: [viz/index.html](viz/index.html) (pending vs durable writes, with a
  crash button)
