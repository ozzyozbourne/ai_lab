# Chapter 21: solutions

## 1. Which sector holds the checksum?

The checksum is the last 4 bytes of the page, so it is in sector 7 (bytes 3584 to
4095). In `ABBAAABB` sector 7 is `B`: the stored checksum is the *new* one
(`a6ca308e`, the checksum of the all-B payload at address 0). The payload in front of
it is a mix, so the computed value (`11258b39`) differs and the page is corrupt.

With `AAAAAAAB` the stored checksum is again B's, but now seven sectors of payload are
old. Still corrupt. The only masks that verify are "nothing new" and "everything new",
and `crash(.tear)` never draws those (the mask is 1 to 254). The test "every torn mix of
two sealed versions is detected" checks all 254 masks.

Note what makes this so clear-cut: versions A and B differ in every sector. Suppose
instead a write changed only sector 3 (and therefore the checksum in sector 7). A tear
with exactly one of the two sectors new is corrupt. A tear with both new *is* the
complete new page, and a tear with neither *is* the complete old page; both verify, and
both are correct answers.

## 2. Remove the first sync

```zig
page_mod.seal(page, self.slotPage(i));
try self.storage.writePage(self.slotPage(i), page);
// try self.storage.sync();          <- removed
page_mod.seal(page, self.homePage(i));
try self.storage.writePage(self.homePage(i), page);
try self.storage.sync();
```

Four tests fail. Two are bookkeeping (the demo output and the "2 syncs" count in "update
then read"). The other two are the real damage:

- "crash at every write, every mode" fails first in `.drop` mode with `crash_after = 2`:
  it expects B and finds A. With the first sync in place, two accepted writes meant the
  slot was durable, so the update had to win. Without it, both writes are still pending
  and both are dropped. That alone is harmless (the update was never acknowledged), but
  the assertion documents a guarantee that is now gone.
- "recovery interrupted by a second crash" fails with `error.Unrecoverable`. Sequence:
  slot write pending, home write pending, power off, `crash(.tear)` tears *both*. The
  slot is corrupt, home is corrupt, and the old version A that home used to hold has been
  partly overwritten. No complete copy of either version is left. (The first test would
  hit the same error once it reached `.tear`.)

The first sync is what guarantees that at most one of the two copies is ever in flight.

## 3. A prefix-only tear mode

Implementation: draw `k = 1 + below(7)` and use the mask `(1 << k) - 1`.

```zig
.tear_prefix => {
    const k: u3 = @intCast(1 + self.prng.below(7));
    self.apply(w, (@as(u8, 1) << k) - 1);
    report.torn += 1;
},
```

No test needs to change: every prefix mask is one of the 254 masks `.tear` can already
draw, so all properties proved for arbitrary subsets hold for prefixes.

Why test against arbitrary subsets: it is the weaker assumption about the hardware. A
format that is only safe when sectors arrive in order has a hidden dependency. The
classic example is a checksum at the *start* of a page combined with the belief "if the
first sector is new and the last sector is new, everything between is new". With
prefix tears that belief is true; with arbitrary tears it is false. Code that survives
the arbitrary-subset adversary survives both.

## 4. A lost write

```zig
test "a lost write verifies" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    var page: Page = @splat('A');
    page_mod.seal(&page, 0);
    try disk.writePage(0, &page);
    try disk.sync();
    page = @splat('B');
    page_mod.seal(&page, 0);
    try disk.writePage(0, &page);
    _ = disk.crash(.drop);
    try testing.expectEqual(page_mod.Check.ok, try page_mod.readChecked(disk.storage(), 0, &page));
    try testing.expectEqual('A', page[0]); // intact, valid, and stale
}
```

The page is internally consistent, so nothing *inside* it can reveal that it is old.
The information must live outside the page:

- In whoever points at the page. Store the expected checksum (or a version number) next
  to the page number in the parent. A stale child then fails the parent's expectation.
  This is TigerBeetle's design (`research/tigerbeetle.md` section 9) and it forces
  copy-on-write, because changing a child changes its checksum and therefore its parent.
- In a log. Give every page a version (an LSN) and record in the log which LSN each
  change produced. After a crash, replay brings every page up to the logged version, so
  a stale page is not detected so much as overwritten. This is chapter 22.

For a write that was *never synced*, a lost write is not an error at all: the caller was
not promised anything. It becomes an error only if the caller acted on the assumption
that the write was durable, which is exactly the bug that `sync` exists to prevent.

## 5. Two pages atomically

Two independent `update` calls give four possible outcomes after a crash: (old, old),
(new, old), (new, new) and, depending on order, never (old, new). The state (new, old)
is the problem: for a B-tree split it is a left page that has given away half its keys
and a right page that does not exist yet. Each page is individually perfect and the
pair is inconsistent. Atomicity of single pages does not compose.

Fix: make the *decision* a single atomic event.

```
slot area:  [image of page X] [image of page Y] [commit page: "X, Y, 2 images", sealed]

update2(X, Y):
  1. write both images to the slot area, write the commit page, sync
  2. write both home pages, sync
  3. (optional) clear the commit page, sync

recover():
  commit page ok and both slot images ok  -> copy both images home (redo)
  otherwise                               -> do nothing; no home page was touched
```

The commit page is one page, so it is either complete or not (its checksum says which);
it must also name the images it covers and, to be strict, carry their checksums, so that
a commit page left over from an earlier update cannot validate newer, torn images.
Before the commit page is durable no home page has been written, so the state is (old,
old). After it, recovery can always finish the job, so the state becomes (new, new).

That is a write-ahead log with full-page images, a commit record and redo, limited to
one transaction at a time. Chapter 22 removes the limit: the slot area becomes an
append-only log, the "which version" question is answered by LSNs, and clearing the
commit page becomes a checkpoint.
